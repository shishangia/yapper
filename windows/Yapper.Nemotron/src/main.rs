// The inference and cache implementation follows omarchy-meeting-recorder's
// MIT-licensed Nemotron 3 integration by Jankees van Woezik.
use ort::session::Session;
use ort::value::Tensor;
use realfft::RealFftPlanner;
use serde_json::json;
use std::io::{Read, Write};

#[cfg(target_os = "windows")]
use ort::ep::DirectML;

const HOP: usize = 160;
const N_FFT: usize = 512;
const WIN: usize = 400;
const BINS: usize = N_FFT / 2 + 1;
const MELS: usize = 128;
const RATE: f64 = 16_000.0;

struct Config {
    hidden: usize,
    speakers: usize,
    factor: usize,
    chunk: usize,
    right: usize,
    fifo: usize,
    update: usize,
    cache: usize,
    silence_per_speaker: usize,
    prediction_threshold: f32,
    latest_boost: f32,
    min_positive_rate: f32,
    strong_rate: f32,
    weak_rate: f32,
}

const CONFIG: Config = Config {
    hidden: 512,
    speakers: 8,
    factor: 8,
    chunk: 128,
    right: 4,
    fifo: 40,
    update: 40,
    cache: 264,
    silence_per_speaker: 1,
    prediction_threshold: 0.25,
    latest_boost: 0.05,
    min_positive_rate: 0.5,
    strong_rate: 0.75,
    weak_rate: 1.5,
};

fn main() {
    if let Err(error) = run() {
        eprintln!("{error}");
        std::process::exit(2);
    }
}

fn run() -> Result<(), String> {
    let model_path = std::env::args()
        .nth(1)
        .ok_or("usage: Yapper.Nemotron <model.onnx>")?;
    let mut model = Model::load(&model_path)?;
    let mut input = std::io::stdin().lock();
    let mut output = std::io::stdout().lock();
    loop {
        let mut length = [0u8; 8];
        match input.read_exact(&mut length) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::UnexpectedEof => break,
            Err(error) => return Err(error.to_string()),
        }
        let byte_count =
            usize::try_from(u64::from_le_bytes(length)).map_err(|_| "audio input is too large")?;
        if byte_count % 4 != 0 || byte_count > 4 * 16000 * 60 * 60 * 2 {
            return Err("audio input is not bounded Float32 PCM".into());
        }
        let mut bytes = vec![0u8; byte_count];
        input.read_exact(&mut bytes).map_err(|e| e.to_string())?;
        let samples: Vec<f32> = bytes
            .chunks_exact(4)
            .map(|b| f32::from_le_bytes([b[0], b[1], b[2], b[3]]))
            .collect();
        let probabilities = model.probabilities(&samples)?;
        let turns: Vec<_> = segments(&probabilities, CONFIG.speakers)
            .into_iter()
            .map(|(start, end, speaker)| {
                json!({"speakerId": (speaker + 1).to_string(),
                "start": start as f64 / 1000.0, "end": end as f64 / 1000.0})
            })
            .collect();
        writeln!(
            output,
            "{}",
            serde_json::to_string(&turns).map_err(|e| e.to_string())?
        )
        .map_err(|e| e.to_string())?;
        output.flush().map_err(|e| e.to_string())?;
    }
    Ok(())
}

struct Model {
    session: Session,
    silence: Vec<f32>,
}

impl Model {
    fn load(path: &str) -> Result<Self, String> {
        let threads = std::thread::available_parallelism()
            .map_or(4, |n| n.get())
            .min(8);
        let mut builder = Session::builder()
            .map_err(err)?
            .with_intra_threads(threads)
            .map_err(err)?;
        #[cfg(target_os = "windows")]
        {
            builder = builder
                .with_memory_pattern(false)
                .map_err(err)?
                .with_execution_providers([DirectML::default().build().fail_silently()])
                .map_err(err)?;
        }
        let session = builder.commit_from_file(path).map_err(err)?;
        Ok(Self {
            session,
            silence: Vec::new(),
        })
    }

    fn probabilities(&mut self, samples: &[f32]) -> Result<Vec<f32>, String> {
        let spectrum = Spectrum::new(samples);
        let mel = MelFilters::new();
        let frames = spectrum.frames;
        let valid = samples.len() / HOP;
        let steps = frames.div_ceil(CONFIG.factor);
        let mut cache = Cache::new();
        let mut logits = Vec::with_capacity(steps * CONFIG.factor * CONFIG.speakers);
        let mut start = 0;
        while start < steps {
            let end = (start + CONFIG.chunk).min(steps);
            let chunk_steps = end - start;
            let with_lookahead = (end + CONFIG.right).min(steps);
            let rows = (with_lookahead - start) * CONFIG.factor;
            let first = start * CONFIG.factor;
            let features = mel.log_mel(&spectrum, first, (first + rows).min(frames), valid, rows);
            let cached = cache.embeds();
            let cached_len = cached.len() / CONFIG.hidden;
            let total = cached_len + with_lookahead - start;
            let outputs = self.session.run(ort::inputs![
                "input_features" => Tensor::from_array(([1usize, rows, MELS], features)).map_err(err)?,
                "cached_embeds" => Tensor::from_array(([1usize, cached_len, CONFIG.hidden], cached.clone())).map_err(err)?,
                "attention_mask" => Tensor::from_array(([1usize, total], vec![1i64; total])).map_err(err)?,
            ]).map_err(err)?;
            let (_, step_logits) = outputs["logits"].try_extract_tensor::<f32>().map_err(err)?;
            let (_, chunk_embeds) = outputs["chunk_embeds"]
                .try_extract_tensor::<f32>()
                .map_err(err)?;
            if self.silence.is_empty() {
                let (_, silence) = outputs["silence_embeds"]
                    .try_extract_tensor::<f32>()
                    .map_err(err)?;
                self.silence = silence.to_vec();
            }
            logits.extend_from_slice(
                &step_logits[cached_len * CONFIG.factor * CONFIG.speakers
                    ..(cached_len + chunk_steps) * CONFIG.factor * CONFIG.speakers],
            );
            let mut input = cached;
            input.extend_from_slice(chunk_embeds);
            cache.update(&input, step_logits, chunk_steps, &self.silence);
            start = end;
        }
        Ok(logits[..(frames * CONFIG.speakers).min(logits.len())]
            .iter()
            .map(|l| 1.0 / (1.0 + (-l).exp()))
            .collect())
    }
}

fn err(error: impl std::fmt::Display) -> String {
    format!("speaker model: {error}")
}

struct MelFilters {
    bands: Vec<(usize, Vec<f32>)>,
}

impl MelFilters {
    fn new() -> Self {
        fn hz_to_mel(hz: f64) -> f64 {
            let (scale, transition) = (200.0 / 3.0, 1000.0);
            if hz >= transition {
                transition / scale + (hz / transition).ln() / (6.4f64.ln() / 27.0)
            } else {
                hz / scale
            }
        }
        fn mel_to_hz(mel: f64) -> f64 {
            let (scale, transition) = (200.0 / 3.0, 1000.0);
            let boundary = transition / scale;
            if mel >= boundary {
                transition * ((6.4f64.ln() / 27.0) * (mel - boundary)).exp()
            } else {
                scale * mel
            }
        }
        let top = hz_to_mel(RATE / 2.0);
        let points: Vec<f64> = (0..MELS + 2)
            .map(|i| mel_to_hz(top * i as f64 / (MELS + 1) as f64))
            .collect();
        let frequencies: Vec<f64> = (0..BINS)
            .map(|i| i as f64 * RATE / 2.0 / (BINS - 1) as f64)
            .collect();
        let bands = (0..MELS)
            .map(|m| {
                let (low, center, high) = (points[m], points[m + 1], points[m + 2]);
                let row: Vec<f32> = frequencies
                    .iter()
                    .map(|hz| {
                        (((hz - low) / (center - low))
                            .min((high - hz) / (high - center))
                            .max(0.0)
                            * 2.0
                            / (high - low)) as f32
                    })
                    .collect();
                let first = row.iter().position(|v| *v > 0.0).unwrap_or(0);
                let last = row.iter().rposition(|v| *v > 0.0).unwrap_or(first);
                (first, row[first..=last].to_vec())
            })
            .collect();
        Self { bands }
    }

    fn log_mel(
        &self,
        spectrum: &Spectrum,
        from: usize,
        to: usize,
        valid: usize,
        rows: usize,
    ) -> Vec<f32> {
        let power = spectrum.power(from, to);
        let mut out = vec![0.0; rows * MELS];
        for frame in 0..to - from {
            if from + frame >= valid {
                break;
            }
            let bins = &power[frame * BINS..(frame + 1) * BINS];
            for (m, (first, weights)) in self.bands.iter().enumerate() {
                let energy: f32 = weights
                    .iter()
                    .zip(&bins[*first..])
                    .map(|(a, b)| a * b)
                    .sum();
                out[frame * MELS + m] = (energy + 2f32.powi(-24)).ln();
            }
        }
        out
    }
}

struct Spectrum<'a> {
    samples: &'a [f32],
    window: Vec<f32>,
    frames: usize,
}

impl<'a> Spectrum<'a> {
    fn new(samples: &'a [f32]) -> Self {
        let offset = (N_FFT - WIN) / 2;
        let window = (0..N_FFT)
            .map(|i| {
                if i < offset || i >= offset + WIN {
                    0.0
                } else {
                    let k = (i - offset) as f32;
                    0.5 - 0.5 * (2.0 * std::f32::consts::PI * k / (WIN - 1) as f32).cos()
                }
            })
            .collect();
        Self {
            samples,
            window,
            frames: 1 + samples.len() / HOP,
        }
    }

    fn at(&self, i: usize) -> f32 {
        let Some(j) = i.checked_sub(N_FFT / 2).filter(|j| *j < self.samples.len()) else {
            return 0.0;
        };
        if j == 0 {
            self.samples[0]
        } else {
            self.samples[j] - 0.97 * self.samples[j - 1]
        }
    }

    fn power(&self, start: usize, end: usize) -> Vec<f32> {
        let fft = RealFftPlanner::<f32>::new().plan_fft_forward(N_FFT);
        let mut input = fft.make_input_vec();
        let mut output = fft.make_output_vec();
        let mut power = Vec::with_capacity((end - start) * BINS);
        for frame in start..end {
            let at = frame * HOP;
            for (i, value) in input.iter_mut().enumerate() {
                *value = self.at(at + i) * self.window[i];
            }
            fft.process(&mut input, &mut output)
                .expect("matching FFT buffers");
            power.extend(output.iter().map(|value| value.norm_sqr()));
        }
        power
    }
}

struct Cache {
    embeds: Vec<f32>,
    probabilities: Vec<f32>,
    fifo: Vec<f32>,
    compressed: bool,
}

impl Cache {
    fn new() -> Self {
        Self {
            embeds: Vec::new(),
            probabilities: Vec::new(),
            fifo: Vec::new(),
            compressed: false,
        }
    }
    fn embeds(&self) -> Vec<f32> {
        let mut out = self.embeds.clone();
        out.extend_from_slice(&self.fifo);
        out
    }

    fn update(&mut self, input: &[f32], logits: &[f32], chunk_frames: usize, silence: &[f32]) {
        let cache_len = self.embeds.len() / CONFIG.hidden;
        let fifo_len = self.fifo.len() / CONFIG.hidden;
        let probs = pool_probs(logits);
        let chunk_start = cache_len + fifo_len;
        let mut fifo = self.fifo.clone();
        fifo.extend_from_slice(
            &input[chunk_start * CONFIG.hidden..(chunk_start + chunk_frames) * CONFIG.hidden],
        );
        let rows = fifo.len() / CONFIG.hidden;
        let popped = if rows <= CONFIG.fifo {
            0
        } else {
            CONFIG.update.max(rows - CONFIG.fifo).min(rows)
        };
        if popped > 0 {
            let fifo_probs =
                &probs[cache_len * CONFIG.speakers..(cache_len + rows) * CONFIG.speakers];
            let mut cache_probs = if self.compressed {
                self.probabilities[..cache_len * CONFIG.speakers].to_vec()
            } else {
                probs[..cache_len * CONFIG.speakers].to_vec()
            };
            let mut cache_embeds = self.embeds.clone();
            cache_embeds.extend_from_slice(&fifo[..popped * CONFIG.hidden]);
            cache_probs.extend_from_slice(&fifo_probs[..popped * CONFIG.speakers]);
            fifo.drain(..popped * CONFIG.hidden);
            if cache_embeds.len() / CONFIG.hidden > CONFIG.cache {
                (cache_embeds, cache_probs) = Self::compress(&cache_embeds, &cache_probs, silence);
                self.compressed = true;
            }
            self.embeds = cache_embeds;
            self.probabilities = cache_probs;
        }
        self.fifo = fifo;
    }

    fn compress(embeds: &[f32], probs: &[f32], silence_embed: &[f32]) -> (Vec<f32>, Vec<f32>) {
        let frames = embeds.len() / CONFIG.hidden;
        let budget = CONFIG.cache / CONFIG.speakers - CONFIG.silence_per_speaker;
        let minimum = (budget as f32 * CONFIG.min_positive_rate).floor() as usize;
        let mut scores = vec![0.0; frames * CONFIG.speakers];
        for frame in 0..frames {
            let row = &probs[frame * CONFIG.speakers..(frame + 1) * CONFIG.speakers];
            let complement: Vec<f32> = row
                .iter()
                .map(|p| (1.0 - p).max(CONFIG.prediction_threshold).ln())
                .collect();
            let sum: f32 = complement.iter().sum();
            for speaker in 0..CONFIG.speakers {
                let p = row[speaker];
                scores[frame * CONFIG.speakers + speaker] = if p > 0.5 {
                    p.max(CONFIG.prediction_threshold).ln() - complement[speaker] + sum
                        - 0.5f32.ln()
                } else {
                    f32::NEG_INFINITY
                };
            }
        }
        for speaker in 0..CONFIG.speakers {
            let positives = (0..frames)
                .filter(|f| scores[f * CONFIG.speakers + speaker] > 0.0)
                .count();
            if positives >= minimum {
                for frame in 0..frames {
                    let value = &mut scores[frame * CONFIG.speakers + speaker];
                    if *value != f32::NEG_INFINITY && *value <= 0.0 {
                        *value = f32::NEG_INFINITY;
                    }
                }
            }
        }
        for frame in CONFIG.cache..frames {
            for speaker in 0..CONFIG.speakers {
                scores[frame * CONFIG.speakers + speaker] += CONFIG.latest_boost;
            }
        }
        boost(
            &mut scores,
            frames,
            (budget as f32 * CONFIG.strong_rate).floor() as usize,
            -2.0 * 0.5f32.ln(),
        );
        boost(
            &mut scores,
            frames,
            (budget as f32 * CONFIG.weak_rate).floor() as usize,
            -0.5f32.ln(),
        );
        let scored = frames + CONFIG.silence_per_speaker;
        let mut order = Vec::with_capacity(scored * CONFIG.speakers);
        for speaker in 0..CONFIG.speakers {
            for frame in 0..scored {
                let score = if frame < frames {
                    scores[frame * CONFIG.speakers + speaker]
                } else {
                    f32::INFINITY
                };
                order.push((score, speaker * scored + frame));
            }
        }
        order.sort_by(|a, b| b.0.total_cmp(&a.0));
        let sentinel = scored * CONFIG.speakers;
        let mut picked: Vec<usize> = order[..CONFIG.cache]
            .iter()
            .map(|(score, index)| {
                if *score == f32::NEG_INFINITY {
                    sentinel
                } else {
                    *index
                }
            })
            .collect();
        picked.sort_unstable();
        let mut out_embeds = Vec::with_capacity(CONFIG.cache * CONFIG.hidden);
        let mut out_probs = Vec::with_capacity(CONFIG.cache * CONFIG.speakers);
        for index in picked {
            let frame = if index == sentinel {
                frames
            } else {
                (index % scored).min(frames)
            };
            if frame < frames {
                out_embeds
                    .extend_from_slice(&embeds[frame * CONFIG.hidden..(frame + 1) * CONFIG.hidden]);
                out_probs.extend_from_slice(
                    &probs[frame * CONFIG.speakers..(frame + 1) * CONFIG.speakers],
                );
            } else {
                out_embeds.extend_from_slice(silence_embed);
                out_probs.extend(std::iter::repeat_n(0.0, CONFIG.speakers));
            }
        }
        (out_embeds, out_probs)
    }
}

fn boost(scores: &mut [f32], frames: usize, count: usize, amount: f32) {
    for speaker in 0..CONFIG.speakers {
        let mut order: Vec<usize> = (0..frames).collect();
        order.sort_by(|a, b| {
            scores[b * CONFIG.speakers + speaker].total_cmp(&scores[a * CONFIG.speakers + speaker])
        });
        for frame in &order[..count.min(frames)] {
            scores[frame * CONFIG.speakers + speaker] += amount;
        }
    }
}

fn pool_probs(logits: &[f32]) -> Vec<f32> {
    logits
        .chunks(CONFIG.factor * CONFIG.speakers)
        .flat_map(|step| {
            (0..CONFIG.speakers).map(move |speaker| {
                (0..CONFIG.factor)
                    .map(|i| 1.0 / (1.0 + (-step[i * CONFIG.speakers + speaker]).exp()))
                    .sum::<f32>()
                    / CONFIG.factor as f32
            })
        })
        .collect()
}

fn segments(probabilities: &[f32], speakers: usize) -> Vec<(i64, i64, usize)> {
    let frames = probabilities.len() / speakers;
    let mut output = Vec::new();
    for speaker in 0..speakers {
        let mut runs: Vec<(i64, i64)> = Vec::new();
        let mut start = None;
        for frame in 0..=frames {
            let active = frame < frames && probabilities[frame * speakers + speaker] > 0.5;
            match (active, start) {
                (true, None) => start = Some(frame),
                (false, Some(from)) => {
                    let (from, to) = (from as i64 * 10, frame as i64 * 10);
                    if let Some(last) = runs.last_mut().filter(|last| from - last.1 < 500) {
                        last.1 = to;
                    } else {
                        runs.push((from, to));
                    }
                    start = None;
                }
                _ => {}
            }
        }
        output.extend(
            runs.into_iter()
                .filter(|(start, end)| end - start >= 300)
                .map(|(start, end)| (start, end, speaker)),
        );
    }
    output.sort_by_key(|(start, _, _)| *start);
    output
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn segments_keep_overlap_and_drop_short_blips() {
        let mut probabilities = vec![0.0; 125 * 2];
        for frame in 0..50 {
            probabilities[frame * 2] = 0.9;
        }
        for frame in 20..60 {
            probabilities[frame * 2 + 1] = 0.9;
        }
        for frame in 115..120 {
            probabilities[frame * 2 + 1] = 0.9;
        }
        assert_eq!(
            segments(&probabilities, 2),
            vec![(0, 500, 0), (200, 600, 1)]
        );
    }

    #[test]
    fn segments_bridge_short_gaps() {
        let mut probabilities = vec![0.0; 120];
        for value in &mut probabilities[0..35] {
            *value = 0.9;
        }
        for value in &mut probabilities[70..110] {
            *value = 0.9;
        }
        assert_eq!(segments(&probabilities, 1), vec![(0, 1100, 0)]);
    }
}

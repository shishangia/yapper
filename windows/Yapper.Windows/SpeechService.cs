using System.IO;
using SherpaOnnx;
using Whisper.net;
using Yapper.Core;

namespace Yapper.Windows;

public sealed class SpeechService(ModelStore models)
{
    private readonly SemaphoreSlim gate = new(1);

    public async Task<Transcript> Transcribe(float[] samples, SpeechModel model, string language, bool speakers, bool single,
        IProgress<(string Stage, double Value)> progress, CancellationToken cancellation)
    {
        await gate.WaitAsync(cancellation);
        try
        {
            if (!models.Ready(model)) throw new InvalidOperationException("Download the selected model first.");
            if (model.Id == "parakeet-v3" && language is not ("auto" or "en")) throw new InvalidOperationException("Choose Whisper for Hindi, Gujarati, or Chinese.");
            cancellation.ThrowIfCancellationRequested();
            progress.Report(("Transcribing locally", 0));
            var words = await Task.Run(async () => model.Id == "parakeet-v3"
                ? Parakeet(samples, model) : await Whisper(samples, model, language, speakers && !single, progress), CancellationToken.None);
            cancellation.ThrowIfCancellationRequested();
            var transcript = Alignment.Align(words, [], speakers, single);
            if (speakers && !single && transcript.PlainText.Trim().Length > 0)
            {
                try
                {
                    if (!models.SpeakersReady) throw new InvalidOperationException("Speaker models have not been downloaded.");
                    progress.Report(("Separating speakers locally", 0));
                    var turns = await Task.Run(() => Diarize(samples, progress), CancellationToken.None);
                    cancellation.ThrowIfCancellationRequested();
                    transcript = Alignment.Align(words, turns, true);
                }
                catch (Exception error) when (error is not OperationCanceledException)
                {
                    cancellation.ThrowIfCancellationRequested();
                    transcript = transcript with { Warning = "Speaker detection failed. The full unlabeled transcript was kept. " + error.Message };
                }
            }
            return transcript;
        }
        finally { gate.Release(); }
    }

    private async Task<List<SpeechWord>> Whisper(float[] samples, SpeechModel model, string language, bool detailed,
        IProgress<(string, double)> progress)
    {
        using var factory = WhisperFactory.FromPath(models.PathFor(model, model.Required[0]));
        var builder = factory.CreateBuilder().WithLanguage(language).WithProgressHandler(p => progress.Report(("Transcribing locally", p / 100d)));
        if (detailed) builder.WithTokenTimestamps();
        using var processor = builder.Build();
        var result = new List<SpeechWord>();
        await foreach (var segment in processor.ProcessAsync(samples))
        {
            if (segment.Text.Trim() is "[BLANK_AUDIO]" or "[SILENCE]") continue;
            if (!detailed)
            {
                result.Add(new(segment.Text, segment.Start.TotalSeconds, segment.End.TotalSeconds));
                continue;
            }
            var offset = 0;
            foreach (var token in segment.Tokens)
            {
                if (string.IsNullOrEmpty(token.Text) || token.Text.StartsWith("[_") || token.Text.StartsWith("<|")) continue;
                var index = segment.Text.IndexOf(token.Text, offset, StringComparison.Ordinal);
                if (index < 0) continue;
                if (index > offset) result.Add(new(segment.Text[offset..index], segment.Start.TotalSeconds, segment.End.TotalSeconds, false));
                var start = token.Start / 100d;
                var end = token.End / 100d;
                var reliable = start >= segment.Start.TotalSeconds - .1 && end <= segment.End.TotalSeconds + .1 && end > start;
                result.Add(new(token.Text, start, end, reliable));
                offset = index + token.Text.Length;
            }
            if (offset < segment.Text.Length) result.Add(new(segment.Text[offset..], segment.Start.TotalSeconds, segment.End.TotalSeconds, false));
        }
        return result;
    }

    private List<SpeechWord> Parakeet(float[] samples, SpeechModel model)
    {
        var config = new OfflineRecognizerConfig();
        config.ModelConfig.Transducer.Encoder = models.PathFor(model, "encoder.int8.onnx");
        config.ModelConfig.Transducer.Decoder = models.PathFor(model, "decoder.int8.onnx");
        config.ModelConfig.Transducer.Joiner = models.PathFor(model, "joiner.int8.onnx");
        config.ModelConfig.Tokens = models.PathFor(model, "tokens.txt");
        config.ModelConfig.ModelType = "nemo_transducer";
        config.ModelConfig.NumThreads = Math.Clamp(Environment.ProcessorCount / 2, 1, 8);
        using var recognizer = new OfflineRecognizer(config);
        using var stream = recognizer.CreateStream();
        stream.AcceptWaveform(16000, samples);
        recognizer.Decode(stream);
        var result = stream.Result;
        var words = new List<SpeechWord>();
        var offset = 0;
        for (var i = 0; i < result.Tokens.Length; i++)
        {
            var text = result.Tokens[i].Replace('▁', ' ');
            var index = result.Text.IndexOf(text, offset, StringComparison.Ordinal);
            if (index < 0 || text.Length == 0) continue;
            var start = i < result.Timestamps.Length ? result.Timestamps[i] : 0;
            var end = i < result.Durations.Length ? start + result.Durations[i] : start;
            if (index > offset) words.Add(new(result.Text[offset..index], start, end, false));
            words.Add(new(text, start, end, end > start));
            offset = index + text.Length;
        }
        if (offset < result.Text.Length) words.Add(new(result.Text[offset..], 0, samples.Length / 16000d, false));
        return words;
    }

    private List<SpeakerTurn> Diarize(float[] samples, IProgress<(string, double)> progress)
    {
        var config = new OfflineSpeakerDiarizationConfig();
        config.Segmentation.Pyannote.Model = Path.Combine(models.DirectoryFor("speakers"), "model.onnx");
        config.Embedding.Model = Path.Combine(models.DirectoryFor("speakers"), "speaker.onnx");
        config.Clustering.NumClusters = -1;
        config.Clustering.Threshold = .5f;
        using var diarizer = new OfflineSpeakerDiarization(config);
        var callback = new OfflineSpeakerDiarizationProgressCallback((done, total, _) =>
        {
            progress.Report(("Separating speakers locally", (double)done / Math.Max(1, total)));
            return 0;
        });
        return diarizer.ProcessWithCallback(samples, callback, IntPtr.Zero).Select(s => new SpeakerTurn(s.Speaker.ToString(), s.Start, s.End)).ToList();
    }
}

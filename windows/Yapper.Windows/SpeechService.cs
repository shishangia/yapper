using System.IO;
using System.Diagnostics;
using SherpaOnnx;
using Whisper.net;
using Yapper.Core;

namespace Yapper.Windows;

public sealed record SpeechResult(Transcript Transcript, double QueueSeconds, double ModelPreparationSeconds,
    double InferenceSeconds, double SpeakerDetectionSeconds);

public sealed class SpeechService(ModelStore models, TimeProvider? timeProvider = null) : IDisposable
{
    private readonly SemaphoreSlim gate = new(1);
    private WhisperFactory? whisperFactory;
    private WhisperProcessor? whisperProcessor;
    private string? whisperModel;
    private string? whisperLanguage;
    private bool whisperDetailed;
    private bool whisperCpu;
    private string whisperPrompt = "";
    private readonly TimeProvider clock = timeProvider ?? TimeProvider.System;
    private long lastActivity = (timeProvider ?? TimeProvider.System).GetTimestamp();
    private int recording;
    private int disposeRequested;
    public void SetRecording(bool active) { Interlocked.Exchange(ref recording, active ? 1 : 0); Touch(); }
    private void Touch() => Interlocked.Exchange(ref lastActivity, clock.GetTimestamp());
    public Task UnloadIfIdle(int minutes) => Task.Run(async () =>
    {
        if (minutes <= 0 || Volatile.Read(ref recording) != 0 || Volatile.Read(ref disposeRequested) != 0) return;
        if (!await gate.WaitAsync(0).ConfigureAwait(false)) return;
        try
        {
            if (Volatile.Read(ref disposeRequested) != 0 || Volatile.Read(ref recording) != 0 || clock.GetElapsedTime(Interlocked.Read(ref lastActivity)).TotalMinutes < minutes) return;
            DisposeWhisper(); DisposeParakeet(); diarizer?.Dispose(); diarizer = null;
        }
        finally { gate.Release(); }
    });
    private IProgress<(string Stage, double Value)>? whisperProgress;
    private OfflineRecognizer? parakeetRecognizer;
    private string? parakeetModel;
    private NemotronDiarizer? diarizer;

    public Task Warm(SpeechModel model, string language, bool detailed, CancellationToken cancellation, string vocabulary = "")
        => Task.Run(async () =>
    {
        await gate.WaitAsync(cancellation).ConfigureAwait(false);
        try
        {
            ObjectDisposedException.ThrowIf(Volatile.Read(ref disposeRequested) != 0, this);
            Touch();
            if (!models.Ready(model)) return;
            cancellation.ThrowIfCancellationRequested();
            if (model.Id == "parakeet-v3") EnsureParakeet(model);
            else EnsureWhisper(model, language, detailed, new Progress<(string, double)>(), cancellation, vocabulary);
            cancellation.ThrowIfCancellationRequested();
        }
        finally { Touch(); gate.Release(); }
    }, CancellationToken.None);

    public Task<SpeechResult> Transcribe(float[] samples, SpeechModel model, string language, bool speakers, bool single,
        IProgress<(string Stage, double Value)> progress, CancellationToken cancellation, string vocabulary = "")
    {
        var queued = Stopwatch.StartNew();
        return Task.Run(async () =>
        {
            await gate.WaitAsync(cancellation).ConfigureAwait(false);
            var queueSeconds = queued.Elapsed.TotalSeconds;
            try
            {
                ObjectDisposedException.ThrowIf(Volatile.Read(ref disposeRequested) != 0, this);
                Touch();
                if (!models.Ready(model)) throw new InvalidOperationException("Download the selected model first.");
                if (model.Id == "parakeet-v3" && language is not ("auto" or "en")) throw new InvalidOperationException("Choose Whisper for Hindi, Gujarati, or Chinese.");
                if (model.Id == "whisper-hinglish" && language is "gu" or "zh")
                    throw new InvalidOperationException("Choose a multilingual Whisper model for Gujarati or Chinese.");
                cancellation.ThrowIfCancellationRequested();
                progress.Report(("Transcribing locally", 0));
                var prepare = Stopwatch.StartNew();
                var prepared = model.Id == "parakeet-v3" ? EnsureParakeet(model)
                    : EnsureWhisper(model, language, speakers && !single, progress, cancellation, vocabulary);
                var preparationSeconds = prepared ? prepare.Elapsed.TotalSeconds : 0;
                cancellation.ThrowIfCancellationRequested();
                var inference = Stopwatch.StartNew();
                List<SpeechWord> words;
                try
                {
                    words = model.Id == "parakeet-v3" ? Parakeet(samples) : await Whisper(samples);
                }
                catch (Exception error) when (model.Id != "parakeet-v3" && !whisperCpu && error is not OperationCanceledException)
                {
                    // The GPU backend can fail at inference time; retry once on CPU and stay there for this session.
                    cancellation.ThrowIfCancellationRequested();
                    whisperCpu = true;
                    DisposeWhisper();
                    EnsureWhisper(model, language, speakers && !single, progress, cancellation, vocabulary);
                    cancellation.ThrowIfCancellationRequested();
                    words = await Whisper(samples);
                }
                var inferenceSeconds = inference.Elapsed.TotalSeconds;
                cancellation.ThrowIfCancellationRequested();
                var transcript = Alignment.Align(words, [], speakers, single);
                var speakerSeconds = 0d;
                if (speakers && !single && transcript.PlainText.Trim().Length > 0)
                {
                    try
                    {
                        if (!models.SpeakersReady) throw new InvalidOperationException("Speaker models have not been downloaded.");
                        progress.Report(("Separating speakers locally", 0));
                        var speakerClock = Stopwatch.StartNew();
                        var turns = Diarize(samples, progress, cancellation);
                        speakerSeconds = speakerClock.Elapsed.TotalSeconds;
                        cancellation.ThrowIfCancellationRequested();
                        transcript = Alignment.Align(words, turns, true);
                    }
                    catch (Exception error) when (error is not OperationCanceledException)
                    {
                        cancellation.ThrowIfCancellationRequested();
                        transcript = transcript with { Warning = "Speaker detection failed. The full unlabeled transcript was kept. " + error.Message };
                    }
                }
                return new SpeechResult(transcript, queueSeconds, preparationSeconds, inferenceSeconds, speakerSeconds);
            }
            finally { Touch(); gate.Release(); }
        }, CancellationToken.None);
    }

    private bool EnsureWhisper(SpeechModel model, string language, bool detailed, IProgress<(string, double)> progress, CancellationToken cancellation, string vocabulary = "")
    {
        cancellation.ThrowIfCancellationRequested();
        var decodingLanguage = model.Id == "whisper-hinglish" ? "en" : language;
        var prompt = PreferredVocabulary.Prompt(vocabulary);
        if (whisperModel == model.Id && whisperLanguage == decodingLanguage && whisperDetailed == detailed
            && whisperPrompt == prompt
            && whisperFactory is not null && whisperProcessor is not null)
        {
            whisperProgress = progress;
            return false;
        }
        var loadedModel = whisperModel != model.Id || whisperFactory is null;
        whisperProcessor?.Dispose();
        whisperProcessor = null;
        try
        {
            if (loadedModel)
            {
                whisperFactory?.Dispose();
                whisperFactory = null;
                whisperFactory = WhisperFactory.FromPath(models.PathFor(model, model.Required[0]),
                    new WhisperFactoryOptions { UseGpu = !whisperCpu });
            }
            whisperProgress = progress;
            var factory = whisperFactory ?? throw new InvalidOperationException("Whisper model is not loaded.");
            var builder = factory.CreateBuilder()
                .WithThreads(Math.Clamp(Environment.ProcessorCount / 2, 1, 8))
                .WithProgressHandler(p => whisperProgress?.Report(("Transcribing locally", p / 100d)));
            if (model.Id == "whisper-hinglish") builder.WithLanguage("en");
            else if (language == "auto") builder.WithLanguageDetection();
            else builder.WithLanguage(language);
            if (detailed) builder.WithTokenTimestamps();
            if (prompt.Length > 0) builder.WithPrompt(prompt);
            whisperProcessor = builder.Build();
        }
        catch (Exception error) when (!whisperCpu && error is not OperationCanceledException)
        {
            // A GPU backend that loads but cannot initialize the model falls back to CPU for this session.
            cancellation.ThrowIfCancellationRequested();
            whisperCpu = true;
            DisposeWhisper();
            return EnsureWhisper(model, language, detailed, progress, cancellation, vocabulary);
        }
        whisperModel = model.Id; whisperLanguage = decodingLanguage; whisperDetailed = detailed; whisperPrompt = prompt;
        DisposeParakeet();
        return true;
    }

    private async Task<List<SpeechWord>> Whisper(float[] samples)
    {
        var processor = whisperProcessor ?? throw new InvalidOperationException("Whisper model is not loaded.");
        var result = new List<SpeechWord>();
        await foreach (var segment in processor.ProcessAsync(samples))
        {
            if (segment.Text.Trim() is "[BLANK_AUDIO]" or "[SILENCE]") continue;
            if (!whisperDetailed)
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

    private bool EnsureParakeet(SpeechModel model)
    {
        if (parakeetModel == model.Id && parakeetRecognizer is not null) return false;
        DisposeParakeet();
        var config = new OfflineRecognizerConfig();
        config.ModelConfig.Transducer.Encoder = models.PathFor(model, "encoder.int8.onnx");
        config.ModelConfig.Transducer.Decoder = models.PathFor(model, "decoder.int8.onnx");
        config.ModelConfig.Transducer.Joiner = models.PathFor(model, "joiner.int8.onnx");
        config.ModelConfig.Tokens = models.PathFor(model, "tokens.txt");
        config.ModelConfig.ModelType = "nemo_transducer";
        config.ModelConfig.NumThreads = Math.Clamp(Environment.ProcessorCount / 2, 1, 8);
        parakeetRecognizer = new OfflineRecognizer(config);
        parakeetModel = model.Id;
        DisposeWhisper();
        return true;
    }

    private List<SpeechWord> Parakeet(float[] samples)
    {
        var recognizer = parakeetRecognizer ?? throw new InvalidOperationException("Parakeet model is not loaded.");
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

    private List<SpeakerTurn> Diarize(float[] samples, IProgress<(string, double)> progress, CancellationToken cancellation)
    {
        var directory = models.DirectoryFor("speakers-nemotron");
        diarizer ??= new NemotronDiarizer(Path.Combine(directory, ModelStore.NemotronGraph.File));
        List<SpeakerTurn> turns;
        try { turns = diarizer.Process(samples, cancellation).ToList(); }
        catch
        {
            // The helper's stream state is unknown after any failure; the next job starts a fresh one.
            diarizer.Dispose(); diarizer = null;
            throw;
        }
        progress.Report(("Separating speakers locally", 1));
        return turns;
    }

    public async Task Unload(string modelId)
    {
        await gate.WaitAsync();
        try
        {
            if (Volatile.Read(ref disposeRequested) != 0) return;
            if (whisperModel == modelId) DisposeWhisper();
            if (parakeetModel == modelId) DisposeParakeet();
            if (modelId is "speakers" or "speakers-nemotron") { diarizer?.Dispose(); diarizer = null; }
        }
        finally { gate.Release(); }
    }

    private void DisposeWhisper()
    {
        whisperProcessor?.Dispose(); whisperProcessor = null;
        whisperFactory?.Dispose(); whisperFactory = null;
        whisperModel = whisperLanguage = null; whisperDetailed = false; whisperProgress = null;
    }

    private void DisposeParakeet()
    {
        parakeetRecognizer?.Dispose(); parakeetRecognizer = null; parakeetModel = null;
    }

    public void Dispose()
    {
        if (Interlocked.Exchange(ref disposeRequested, 1) != 0) return;
        // Never free native models under a running job; if it will not finish soon, process exit reclaims them.
        if (!gate.Wait(TimeSpan.FromSeconds(3))) return;
        try { DisposeWhisper(); DisposeParakeet(); diarizer?.Dispose(); diarizer = null; }
        finally { gate.Release(); }
    }
}

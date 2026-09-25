using System.IO;
using System.Diagnostics;
using SherpaOnnx;
using Whisper.net;
using Yapper.Core;

namespace Yapper.Windows;

public sealed record SpeechResult(Transcript Transcript, double QueueSeconds, double ModelPreparationSeconds,
    double InferenceSeconds, double SpeakerDetectionSeconds);

public sealed class SpeechService(ModelStore models) : IDisposable
{
    private readonly SemaphoreSlim gate = new(1);
    private WhisperFactory? whisperFactory;
    private WhisperProcessor? whisperProcessor;
    private string? whisperModel;
    private string? whisperLanguage;
    private bool whisperDetailed;
    private IProgress<(string Stage, double Value)>? whisperProgress;
    private OfflineRecognizer? parakeetRecognizer;
    private string? parakeetModel;
    private NemotronDiarizer? diarizer;

    public async Task Warm(SpeechModel model, string language, bool detailed, CancellationToken cancellation)
    {
        await gate.WaitAsync(cancellation);
        try
        {
            if (!models.Ready(model)) return;
            if (model.Id == "parakeet-v3") EnsureParakeet(model);
            else EnsureWhisper(model, language, detailed, new Progress<(string, double)>());
        }
        finally { gate.Release(); }
    }

    public async Task<SpeechResult> Transcribe(float[] samples, SpeechModel model, string language, bool speakers, bool single,
        IProgress<(string Stage, double Value)> progress, CancellationToken cancellation)
    {
        var queued = Stopwatch.StartNew();
        await gate.WaitAsync(cancellation);
        var queueSeconds = queued.Elapsed.TotalSeconds;
        try
        {
            if (!models.Ready(model)) throw new InvalidOperationException("Download the selected model first.");
            if (model.Id == "parakeet-v3" && language is not ("auto" or "en")) throw new InvalidOperationException("Choose Whisper for Hindi, Gujarati, or Chinese.");
            if (model.Id == "whisper-hinglish" && language is "gu" or "zh")
                throw new InvalidOperationException("Choose a multilingual Whisper model for Gujarati or Chinese.");
            cancellation.ThrowIfCancellationRequested();
            progress.Report(("Transcribing locally", 0));
            var prepare = Stopwatch.StartNew();
            var prepared = model.Id == "parakeet-v3" ? EnsureParakeet(model)
                : EnsureWhisper(model, language, speakers && !single, progress);
            var preparationSeconds = prepared ? prepare.Elapsed.TotalSeconds : 0;
            var inference = Stopwatch.StartNew();
            var words = await Task.Run(async () => model.Id == "parakeet-v3"
                ? Parakeet(samples) : await Whisper(samples), CancellationToken.None);
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
                    var turns = await Task.Run(() => Diarize(samples, progress, cancellation), CancellationToken.None);
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
            return new(transcript, queueSeconds, preparationSeconds, inferenceSeconds, speakerSeconds);
        }
        finally { gate.Release(); }
    }

    private bool EnsureWhisper(SpeechModel model, string language, bool detailed, IProgress<(string, double)> progress)
    {
        var decodingLanguage = model.Id == "whisper-hinglish" ? "en" : language;
        if (whisperModel == model.Id && whisperLanguage == decodingLanguage && whisperDetailed == detailed
            && whisperFactory is not null && whisperProcessor is not null)
        {
            whisperProgress = progress;
            return false;
        }
        var loadedModel = whisperModel != model.Id || whisperFactory is null;
        whisperProcessor?.Dispose();
        whisperProcessor = null;
        if (loadedModel)
        {
            whisperFactory?.Dispose();
            whisperFactory = WhisperFactory.FromPath(models.PathFor(model, model.Required[0]));
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
        whisperProcessor = builder.Build();
        whisperModel = model.Id; whisperLanguage = decodingLanguage; whisperDetailed = detailed;
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
        DisposeWhisper(); DisposeParakeet(); diarizer?.Dispose(); diarizer = null; gate.Dispose();
    }
}

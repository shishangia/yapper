// Controlled dependencies for the real SpeechService, compiled from the app source.
// These fakes never load models, use the network, or read a production library.
internal static class NativeCalls
{
    public static Action<bool>? OnLoad;
    public static Action<bool>? OnInference;
    public static List<bool> Loads = [];
    public static List<bool> Inferences = [];
    public static List<string> Prompts = [];
    public static void Reset() { OnLoad = null; OnInference = null; Loads.Clear(); Inferences.Clear(); Prompts.Clear(); }
}

namespace Yapper.Windows
{
    public sealed record SpeechModel(string Id, string[] Required);
    public sealed class ModelStore
    {
        public bool Ready(SpeechModel model) => true;
        public bool SpeakersReady => true;
        public string DirectoryFor(string id) => id;
        public string PathFor(SpeechModel model, string file) => file;
        public static class NemotronGraph { public static string File => "unused"; }
    }
    internal sealed class NemotronDiarizer : IDisposable
    {
        public NemotronDiarizer(string path) { }
        public IReadOnlyList<Yapper.Core.SpeakerTurn> Process(float[] samples, CancellationToken cancellation)
        {
            cancellation.ThrowIfCancellationRequested();
            return [new("1", 0, 1)];
        }
        public void Dispose() { }
    }
}

namespace Whisper.net
{
    public sealed class WhisperFactoryOptions { public bool UseGpu { get; set; } }
    public sealed class WhisperFactory(bool gpu) : IDisposable
    {
        public static WhisperFactory FromPath(string path, WhisperFactoryOptions options)
        {
            NativeCalls.Loads.Add(options.UseGpu);
            NativeCalls.OnLoad?.Invoke(options.UseGpu);
            return new(options.UseGpu);
        }
        public WhisperProcessorBuilder CreateBuilder() => new(gpu);
        public void Dispose() { }
    }
    public sealed class WhisperProcessorBuilder(bool gpu)
    {
        public WhisperProcessorBuilder WithThreads(int threads) => this;
        public WhisperProcessorBuilder WithProgressHandler(Action<int> progress) => this;
        public WhisperProcessorBuilder WithLanguage(string language) => this;
        public WhisperProcessorBuilder WithLanguageDetection() => this;
        public WhisperProcessorBuilder WithTokenTimestamps() => this;
        public WhisperProcessorBuilder WithPrompt(string prompt) { NativeCalls.Prompts.Add(prompt); return this; }
        public WhisperProcessor Build() => new(gpu);
    }
    public sealed record Token(string Text, long Start, long End);
    public sealed record Segment(string Text, TimeSpan Start, TimeSpan End, Token[] Tokens);
    public sealed class WhisperProcessor(bool gpu) : IDisposable
    {
        public async IAsyncEnumerable<Segment> ProcessAsync(float[] samples)
        {
            await Task.Yield();
            NativeCalls.Inferences.Add(gpu);
            NativeCalls.OnInference?.Invoke(gpu);
            yield return new("Hello", TimeSpan.Zero, TimeSpan.FromSeconds(1), []);
        }
        public void Dispose() { }
    }
}

namespace SherpaOnnx
{
    public sealed class TransducerConfig { public string Encoder = "", Decoder = "", Joiner = ""; }
    public sealed class ModelConfig
    {
        public TransducerConfig Transducer = new();
        public string Tokens = "", ModelType = "";
        public int NumThreads;
    }
    public sealed class OfflineRecognizerConfig { public ModelConfig ModelConfig = new(); }
    public sealed class RecognitionResult
    {
        public string Text = "Hello";
        public string[] Tokens = [];
        public float[] Timestamps = [], Durations = [];
    }
    public sealed class RecognitionStream : IDisposable
    {
        public RecognitionResult Result = new();
        public void AcceptWaveform(int rate, float[] samples) { }
        public void Dispose() { }
    }
    public sealed class OfflineRecognizer : IDisposable
    {
        public OfflineRecognizer(OfflineRecognizerConfig config) { NativeCalls.OnLoad?.Invoke(false); }
        public RecognitionStream CreateStream() => new();
        public void Decode(RecognitionStream stream) { }
        public void Dispose() { }
    }
}

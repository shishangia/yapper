using Yapper.Windows;
using Yapper.Core;
using System.Diagnostics;

if (args.Length == 3 && args[0] == "--verify-update-download")
{
    var release = System.Text.Json.JsonSerializer.Deserialize<ReleaseInfo>(File.ReadAllText(args[1]))!;
    var update = UpdatePolicy.Select([release], "0.0.0-preview.1") ?? throw new Exception("Release rejected");
    var path = await new AppUpdates().Download(update, args[2], new Progress<double>(), CancellationToken.None);
    Console.WriteLine("PASS downloaded and verified Windows update: " + new FileInfo(path).Length + " bytes");
    return;
}
if (args.Length == 1 && args[0] == "--check-updates")
{
    var update = await new AppUpdates().Check(CancellationToken.None);
    Console.WriteLine(update is null ? "PASS live GitHub check: no newer Windows update" : "PASS live GitHub check: " + update.Version);
    return;
}
if (args.Length < 2) throw new ArgumentException("Usage: native-tests <isolated-root> <16k-mono-pcm16-wav> [model-id]");
var root = Path.GetFullPath(args[0]);
var audio = Path.GetFullPath(args[1]);
if (!Directory.Exists(root)) Directory.CreateDirectory(root);
var helper = Environment.GetEnvironmentVariable("YAPPER_NEMOTRON_HELPER") ?? Path.Combine(AppContext.BaseDirectory, "Yapper.Nemotron.exe");
if (OperatingSystem.IsWindows() && (!File.Exists(helper)
    || !File.Exists(Path.Combine(Path.GetDirectoryName(helper)!, "DirectML.dll"))))
    throw new Exception("The packaged Nemotron DirectML runtime is missing.");
var model = ModelStore.Catalog.Single(m => m.Id == (args.Length > 2 ? args[2] : "whisper-tiny"));
var models = new ModelStore(root);
var progress = new Progress<(string Stage, double Value)>(p => { if (p.Value >= .99) Console.WriteLine(p.Stage); });
await models.Download(model, true, progress, CancellationToken.None);
byte[] data = File.ReadAllBytes(audio);
using var reader = new BinaryReader(new MemoryStream(data));
if (new string(reader.ReadChars(4)) != "RIFF") throw new InvalidDataException("Expected RIFF WAV");
reader.ReadInt32(); reader.ReadBytes(4);
short channels = 0, bits = 0, format = 0; int rate = 0; byte[]? pcm = null;
while (reader.BaseStream.Position + 8 <= reader.BaseStream.Length)
{
    var chunk = new string(reader.ReadChars(4)); var length = reader.ReadInt32(); var end = reader.BaseStream.Position + length;
    if (length < 0 || end > data.Length) throw new InvalidDataException("Invalid WAV chunk");
    if (chunk == "fmt ") { format = reader.ReadInt16(); channels = reader.ReadInt16(); rate = reader.ReadInt32(); reader.ReadBytes(6); bits = reader.ReadInt16(); }
    if (chunk == "data") pcm = reader.ReadBytes(length);
    reader.BaseStream.Position = end + (length % 2);
}
if (format != 1 || channels != 1 || bits != 16 || rate != 16000 || pcm is null) throw new InvalidDataException("Expected 16k mono PCM16");
var samples = Enumerable.Range(0, pcm.Length / 2).Select(i => BitConverter.ToInt16(pcm, i * 2) / 32768f).ToArray();
var captured = Path.Combine(root, "captured.wav");
File.Copy(audio, captured, true);
var capturedLength = new FileInfo(captured).Length;
var decodedCapture = AudioDecoder.Decode(captured, captured);
if (decodedCapture.Length == 0 || new FileInfo(captured).Length != capturedLength)
    throw new Exception("Already-normalized microphone WAV was rewritten or lost.");
using var service = new SpeechService(models);
var clock = Stopwatch.StartNew();
var singleResult = await service.Transcribe(samples, model, "en", true, true, progress, CancellationToken.None);
var single = singleResult.Transcript;
if (string.IsNullOrWhiteSpace(single.PlainText) || single.Segments.Any(s => s.SpeakerId != "1")) throw new Exception("Single-speaker transcription failed");
var multiResult = await service.Transcribe(samples, model, "en", true, false, progress, CancellationToken.None);
var multi = multiResult.Transcript;
if (string.IsNullOrWhiteSpace(multi.PlainText) || multi.Warning is not null) throw new Exception("Native speaker pipeline failed: " + multi.Warning);
if (model.Id == "whisper-hinglish" && multi.PlainText.Any(c => c is >= '\u0900' and <= '\u097F'))
    throw new Exception("Hinglish model returned Devanagari output.");
var reused = await service.Transcribe(samples, model, "en", true, false, progress, CancellationToken.None);
if (reused.ModelPreparationSeconds != 0) throw new Exception("Resident model and processor were rebuilt.");
if (reused.SpeakerDetectionSeconds <= 0 || reused.SpeakerDetectionSeconds > multiResult.SpeakerDetectionSeconds * 1.5 + .25)
    throw new Exception("Resident Nemotron helper was not reused.");
var canceled = new CancellationTokenSource(); canceled.Cancel();
try { await service.Transcribe(samples, model, "en", false, false, progress, canceled.Token); throw new Exception("Cancellation ignored"); }
catch (OperationCanceledException) { }
var peak = Process.GetCurrentProcess().PeakWorkingSet64;
Console.WriteLine($"PASS native {model.Id}; {multi.Segments.Count} passages; {multi.SpeakerIds.Count()} speaker labels; resident processor reused; inference {reused.InferenceSeconds:F2}s; {clock.Elapsed.TotalSeconds:F1}s total; peak working set {(peak > 0 ? (peak / 1024 / 1024) + " MiB" : "unavailable on this platform")}");

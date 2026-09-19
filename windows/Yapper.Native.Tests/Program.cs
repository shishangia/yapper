using Yapper.Windows;
using Yapper.Core;
using System.Diagnostics;

if (args.Length < 2) throw new ArgumentException("Usage: native-tests <isolated-root> <16k-mono-pcm16-wav> [model-id]");
var root = Path.GetFullPath(args[0]);
var audio = Path.GetFullPath(args[1]);
if (!Directory.Exists(root)) Directory.CreateDirectory(root);
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
var service = new SpeechService(models);
var clock = Stopwatch.StartNew();
var single = await service.Transcribe(samples, model, "en", true, true, progress, CancellationToken.None);
if (string.IsNullOrWhiteSpace(single.PlainText) || single.Segments.Any(s => s.SpeakerId != "1")) throw new Exception("Single-speaker transcription failed");
var multi = await service.Transcribe(samples, model, "en", true, false, progress, CancellationToken.None);
if (string.IsNullOrWhiteSpace(multi.PlainText) || multi.Warning is not null) throw new Exception("Native speaker pipeline failed: " + multi.Warning);
var canceled = new CancellationTokenSource(); canceled.Cancel();
try { await service.Transcribe(samples, model, "en", false, false, progress, canceled.Token); throw new Exception("Cancellation ignored"); }
catch (OperationCanceledException) { }
Console.WriteLine($"PASS native {model.Id}; {multi.Segments.Count} passages; {multi.SpeakerIds.Count()} speaker labels; {clock.Elapsed.TotalSeconds:F1}s; peak working set {Process.GetCurrentProcess().PeakWorkingSet64 / 1024 / 1024} MiB");

using System.IO;
using System.Net.Http;
using System.Security.Cryptography;
using SharpCompress.Common;
using SharpCompress.Readers;

namespace Yapper.Windows;

public sealed record ModelAsset(string File, string Url, string Sha256, long Size, bool Archive = false);
public sealed record SpeechModel(string Id, string Name, string Description, double Speed, double Accuracy, ModelAsset Asset, string[] Required)
{
    public override string ToString() => Name;
}

public sealed class ModelStore
{
    private const string Whisper = "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/";
    public static readonly SpeechModel[] Catalog =
    [
        new("whisper-tiny", "Whisper Tiny", "Multilingual · 78 MB · quickest CPU option", 9.5, 6,
            new("ggml-tiny.bin", Whisper + "ggml-tiny.bin", "be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21", 77691713), ["ggml-tiny.bin"]),
        new("whisper-small", "Whisper Small", "Multilingual · 488 MB · balanced CPU option", 8, 8.5,
            new("ggml-small.bin", Whisper + "ggml-small.bin", "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b", 487601967), ["ggml-small.bin"]),
        new("whisper-turbo", "Whisper Large v3 Turbo", "Multilingual · 1.6 GB · needs more memory and time on CPU", 7, 9.5,
            new("ggml-large-v3-turbo.bin", Whisper + "ggml-large-v3-turbo.bin", "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69", 1624555275), ["ggml-large-v3-turbo.bin"]),
        new("whisper-hinglish", "Whisper Hinglish Turbo", "Hindi and English · natural Latin script · 624 MB", 7.5, 8.8,
            new("ggml-hindi2hinglish-apex-q5_1.bin",
                "https://huggingface.co/voquill/whisper-hindi2hinglish-apex-ggml/resolve/c088f27bb726fd6335eab0041787564045c1ef48/ggml-hindi2hinglish-apex-q5_1.bin",
                "be4392ef7d61721933868bbf7824a2c06f341f22238616067a2719ef62b79d1d", 624065675),
            ["ggml-hindi2hinglish-apex-q5_1.bin"]),
        new("whisper-large", "Whisper Large v3", "Multilingual · 3.1 GB · at least 16 GB RAM recommended", 4, 9.5,
            new("ggml-large-v3.bin", Whisper + "ggml-large-v3.bin", "64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2", 3095033483), ["ggml-large-v3.bin"]),
        new("parakeet-v3", "Parakeet TDT v3", "25 European languages · 487 MB · not Hindi/Gujarati/Chinese", 9.7, 9.2,
            new("parakeet.tar.bz2", "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8.tar.bz2", "5793d0fd397c5778d2cf2126994d58e9d56b1be7c04d13c7a15bb1b4eafb16bf", 487170055, true),
            ["encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx", "tokens.txt"])
    ];
    private const string Nemotron = "https://huggingface.co/onnx-community/Nemotron-3-Diarization-ONNX/resolve/353b6f8ad2cac3580e982d7fbdf0a010786b0406/onnx/";
    public static readonly ModelAsset NemotronGraph = new("model_quantized.onnx", Nemotron + "model_quantized.onnx",
        "fff7d18c7439c9fdc1c6c4dfec924cb42d3344264ca879780dfaf7ee886e6c1e", 364375);
    public static readonly ModelAsset NemotronWeights = new("model_quantized.onnx_data", Nemotron + "model_quantized.onnx_data",
        "002d7483e1c865c35c82220fdb378f185ff213c6d35922b38ae421c8ec72c338", 120479872);
    public string Root { get; }
    private static readonly HttpClient Client = new() { Timeout = Timeout.InfiniteTimeSpan };
    public ModelStore(string root) { Root = Path.Combine(root, "Models"); Directory.CreateDirectory(Root); }
    public string DirectoryFor(string id) => Path.Combine(Root, id);
    public string PathFor(SpeechModel model, string file) => Path.Combine(DirectoryFor(model.Id), file);
    public bool Ready(SpeechModel model) => model.Required.All(f => File.Exists(PathFor(model, f))) && File.Exists(Path.Combine(DirectoryFor(model.Id), ".complete"));
    public bool SpeakersReady => File.Exists(Path.Combine(DirectoryFor("speakers-nemotron"), NemotronGraph.File))
        && File.Exists(Path.Combine(DirectoryFor("speakers-nemotron"), NemotronWeights.File))
        && File.Exists(Path.Combine(DirectoryFor("speakers-nemotron"), ".complete"));

    public async Task Download(SpeechModel model, bool speakers, IProgress<(string Stage, double Value)> progress, CancellationToken cancellation)
    {
        if (!Ready(model)) await DownloadSet(model.Id, [model.Asset], model.Required, progress, cancellation);
        if (speakers && !SpeakersReady)
        {
            await DownloadSet("speakers-nemotron", [NemotronGraph, NemotronWeights],
                [NemotronGraph.File, NemotronWeights.File], progress, cancellation);
        }
    }

    private async Task DownloadSet(string id, ModelAsset[] assets, string[] required, IProgress<(string, double)> progress, CancellationToken cancellation)
    {
        var destination = DirectoryFor(id);
        var staging = Path.Combine(Root, ".download-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(staging);
        try
        {
            foreach (var asset in assets)
            {
                var download = Path.Combine(staging, asset.File);
                using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
                timeout.CancelAfter(TimeSpan.FromHours(2));
                using var request = new HttpRequestMessage(HttpMethod.Get, asset.Url);
                request.Headers.UserAgent.ParseAdd("Yapper-Windows/0.1");
                using var response = await Client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token);
                response.EnsureSuccessStatusCode();
                await using var source = await response.Content.ReadAsStreamAsync(timeout.Token);
                await using (var output = new FileStream(download, FileMode.CreateNew, FileAccess.Write, FileShare.None, 81920, true))
                {
                    var buffer = new byte[81920];
                    long total = 0;
                    int read;
                    while ((read = await source.ReadAsync(buffer, timeout.Token)) > 0)
                    {
                        total += read;
                        if (total > asset.Size) throw new InvalidDataException("Model download exceeded its expected size.");
                        await output.WriteAsync(buffer.AsMemory(0, read), timeout.Token);
                        progress.Report(("Downloading " + id, Math.Min(.95, (double)total / asset.Size * .95)));
                    }
                    if (total != asset.Size) throw new InvalidDataException("Model download was incomplete.");
                }
                await using (var file = File.OpenRead(download))
                {
                    var hash = Convert.ToHexString(await SHA256.HashDataAsync(file, cancellation));
                    if (!hash.Equals(asset.Sha256, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("Model checksum mismatch. Please retry.");
                }
                if (asset.Archive)
                {
                    progress.Report(("Extracting " + id, .96));
                    using var stream = File.OpenRead(download);
                    using var reader = ReaderFactory.OpenReader(stream);
                    long expanded = 0;
                    while (reader.MoveToNextEntry())
                    {
                        cancellation.ThrowIfCancellationRequested();
                        if (reader.Entry.IsDirectory) continue;
                        if (!string.IsNullOrEmpty(reader.Entry.LinkTarget)) throw new InvalidDataException("Links are not allowed in model archives.");
                        var name = Path.GetFileName((reader.Entry.Key ?? "").Replace('\\', '/'));
                        if (string.IsNullOrEmpty(name) || !required.Contains(name)) continue;
                        expanded += reader.Entry.Size;
                        if (expanded > 4L * 1024 * 1024 * 1024) throw new InvalidDataException("Model archive is too large.");
                        reader.WriteEntryToFile(Path.Combine(staging, name), new ExtractionOptions { Overwrite = false });
                    }
                }
            }
            if (!required.All(f => File.Exists(Path.Combine(staging, f)))) throw new InvalidDataException("Required model files were missing.");
            cancellation.ThrowIfCancellationRequested();
            await File.WriteAllTextAsync(Path.Combine(staging, ".complete"), string.Join('\n', assets.Select(a => a.Sha256)), cancellation);
            if (Directory.Exists(destination)) throw new IOException("The model folder already exists. Remove that model through Settings before retrying.");
            foreach (var asset in assets.Where(a => a.Archive)) File.Delete(Path.Combine(staging, asset.File));
            Directory.Move(staging, destination);
            progress.Report(("Model ready", 1));
        }
        finally { if (Directory.Exists(staging)) Directory.Delete(staging, true); }
    }
}

using System.IO;
using System.Net.Http;
using System.Reflection;
using System.Security.Cryptography;
using System.Text.Json;
using Yapper.Core;

namespace Yapper.Windows;

public sealed class AppUpdates
{
    public static string CurrentVersion => (Assembly.GetExecutingAssembly().GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion ?? "1.1.1").Split('+')[0];
    private static readonly HttpClient Client = new(new HttpClientHandler { AllowAutoRedirect = false }) { Timeout = TimeSpan.FromMinutes(10) };
    public async Task<WindowsUpdate?> Check(CancellationToken token)
    {
        var releases = new List<ReleaseInfo>();
        for (var page = 1; page <= 5; page++)
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, $"https://api.github.com/repos/shishangia/yapper/releases?per_page=100&page={page}");
            request.Headers.UserAgent.ParseAdd("Yapper-Windows/" + CurrentVersion);
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token);
            timeout.CancelAfter(TimeSpan.FromSeconds(30));
            using var response = await Client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token);
            response.EnsureSuccessStatusCode();
            await using var stream = await response.Content.ReadAsStreamAsync(timeout.Token);
            using var data = new MemoryStream();
            var buffer = new byte[81920];
            int read;
            while ((read = await stream.ReadAsync(buffer, timeout.Token)) > 0)
            {
                if (data.Length + read > 4_000_000) throw new InvalidDataException("GitHub release response was too large.");
                await data.WriteAsync(buffer.AsMemory(0, read), timeout.Token);
            }
            var batch = JsonSerializer.Deserialize<ReleaseInfo[]>(data.ToArray()) ?? throw new InvalidDataException("Invalid release response.");
            releases.AddRange(batch);
            if (batch.Length < 100) break;
        }
        return UpdatePolicy.Select(releases, CurrentVersion);
    }

    public async Task<string> Download(WindowsUpdate update, string directory, IProgress<double> progress, CancellationToken token)
    {
        var asset = update.Asset;
        if (!UpdatePolicy.TrustedAsset(asset.Url, update.Tag, asset.Name) || asset.Digest is null
            || !System.Text.RegularExpressions.Regex.IsMatch(asset.Digest, "^sha256:[a-fA-F0-9]{64}$") || asset.Size <= 0 || asset.Size > 1_000_000_000)
            throw new InvalidDataException("Untrusted update asset.");
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, Guid.NewGuid().ToString("N") + ".exe");
        try
        {
            var url = new Uri(asset.Url);
            HttpResponseMessage? response = null;
            for (var redirects = 0; redirects <= 5; redirects++)
            {
                response?.Dispose();
                using var request = new HttpRequestMessage(HttpMethod.Get, url);
                request.Headers.UserAgent.ParseAdd("Yapper-Windows/" + CurrentVersion);
                response = await Client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, token);
                if ((int)response.StatusCode is not (301 or 302 or 303 or 307 or 308)) break;
                var location = response.Headers.Location ?? throw new InvalidDataException("Missing download redirect.");
                url = location.IsAbsoluteUri ? location : new Uri(url, location);
                if (url.Scheme != "https" || !url.IsDefaultPort || url.UserInfo.Length != 0 ||
                    url.Host is not ("github.com" or "release-assets.githubusercontent.com" or "objects.githubusercontent.com"))
                    throw new InvalidDataException("Untrusted download redirect.");
            }
            using (response)
            {
                response!.EnsureSuccessStatusCode();
                await using var source = await response.Content.ReadAsStreamAsync(token);
                await using (var output = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None, 81920, true))
                {
                    var buffer = new byte[81920];
                    long total = 0;
                    int read;
                    while ((read = await source.ReadAsync(buffer, token)) > 0)
                    {
                        total += read;
                        if (total > asset.Size) throw new InvalidDataException("Update exceeded expected size.");
                        await output.WriteAsync(buffer.AsMemory(0, read), token);
                        progress.Report((double)total / asset.Size);
                    }
                    if (total != asset.Size) throw new InvalidDataException("Update download was incomplete.");
                }
            }
            await using var file = File.OpenRead(path);
            var hash = Convert.ToHexString(await SHA256.HashDataAsync(file, token));
            if (!hash.Equals(asset.Digest[7..], StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("Update checksum did not match GitHub.");
            return path;
        }
        catch { if (File.Exists(path)) File.Delete(path); throw; }
    }
}

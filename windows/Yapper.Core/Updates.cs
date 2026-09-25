using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace Yapper.Core;

public sealed record ReleaseAsset(
    [property: JsonPropertyName("name")] string Name,
    [property: JsonPropertyName("browser_download_url")] string Url,
    [property: JsonPropertyName("size")] long Size,
    [property: JsonPropertyName("digest")] string? Digest);
public sealed record ReleaseInfo(
    [property: JsonPropertyName("tag_name")] string Tag,
    [property: JsonPropertyName("body")] string? Body,
    [property: JsonPropertyName("draft")] bool Draft,
    [property: JsonPropertyName("prerelease")] bool Prerelease,
    [property: JsonPropertyName("assets")] ReleaseAsset[] Assets);
public sealed record WindowsUpdate(string Tag, string Version, string Notes, ReleaseAsset Asset);

public static partial class UpdatePolicy
{
    [GeneratedRegex(@"^(?:windows-)?v(\d+\.\d+\.\d+)(?:-preview\.(\d+))?$")]
    private static partial Regex TagPattern();
    [GeneratedRegex(@"^sha256:[a-fA-F0-9]{64}$")]
    private static partial Regex DigestPattern();

    public static (Version Version, int Preview)? Parse(string tag)
    {
        var match = TagPattern().Match(tag);
        if (!match.Success || !Version.TryParse(match.Groups[1].Value, out var version)) return null;
        if (!match.Groups[2].Success) return (version, int.MaxValue);
        return int.TryParse(match.Groups[2].Value, out var preview) && preview > 0 ? (version, preview) : null;
    }

    public static WindowsUpdate? Select(IEnumerable<ReleaseInfo> releases, string currentVersion)
    {
        var current = Parse("windows-v" + currentVersion) ?? throw new ArgumentException("Invalid installed version.");
        var candidates = new List<(WindowsUpdate Update, Version Version, int Preview)>();
        foreach (var release in releases)
        {
            var parsed = Parse(release.Tag);
            if (release.Draft || parsed is null || (current.Preview == int.MaxValue && release.Prerelease)) continue;
            if (release.Prerelease != (parsed.Value.Preview != int.MaxValue)) continue;
            if (parsed.Value.Version < current.Version || parsed.Value.Version == current.Version && parsed.Value.Preview <= current.Preview) continue;
            var version = release.Tag[(release.Tag.StartsWith("windows-") ? "windows-v" : "v").Length..];
            var name = $"Yapper-{version}-win-x64-setup.exe";
            var matches = release.Assets.Where(a => a.Name == name).ToArray();
            if (matches.Length != 1) continue;
            var asset = matches[0];
            if (asset.Size <= 0 || asset.Size > 1_000_000_000 || asset.Digest is null || !DigestPattern().IsMatch(asset.Digest)) continue;
            if (!TrustedAsset(asset.Url, release.Tag, name)) continue;
            candidates.Add((new(release.Tag, version, release.Body ?? "", asset), parsed.Value.Version, parsed.Value.Preview));
        }
        return candidates.OrderByDescending(c => c.Version).ThenByDescending(c => c.Preview).Select(c => c.Update).FirstOrDefault();
    }
    public static bool TrustedAsset(string value, string tag, string name) => Uri.TryCreate(value, UriKind.Absolute, out var uri)
        && uri.Scheme == "https" && uri.Host == "github.com" && uri.IsDefaultPort && uri.UserInfo.Length == 0
        && uri.Query.Length == 0 && uri.Fragment.Length == 0 && uri.AbsolutePath == $"/shishangia/yapper/releases/download/{tag}/{name}";
}

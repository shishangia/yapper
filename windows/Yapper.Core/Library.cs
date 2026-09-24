using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace Yapper.Core;

public sealed record ProcessingTiming(double Decode, double Queue, double ModelPreparation, double Inference,
    double SpeakerDetection, double Cleanup)
{
    [JsonIgnore] public double Total => Decode + Queue + ModelPreparation + Inference + SpeakerDetection + Cleanup;
}
public sealed record Recording(Guid Id, DateTimeOffset Date, string Text, double Duration, string AudioPath, string Model,
    Transcript? Conversation = null, ProcessingTiming? Timing = null)
{
    [JsonIgnore] public string DisplayText => Conversation?.FormattedText() ?? Text;
    [JsonIgnore] public string Label => $"{Date.LocalDateTime:g} · {Model} · {Text.Replace('\n', ' ')[..Math.Min(Text.Length, 70)]}";
}
public sealed record UsageEntry(Guid Id, DateTimeOffset Date, int Words, double Seconds);
public sealed record DictionaryRule(string Trigger, string Replacement, bool Enabled = true);
public sealed record Preferences(string SelectedModel = "whisper-small", string Language = "auto", bool ToggleRecording = true,
    bool RestoreClipboard = true, bool TrimPeriod = true, string Hotkey = "Control+Alt+Space", bool AutoEdit = false, string Theme = "System",
    bool AutoCheckUpdates = true, DateTimeOffset? LastUpdateCheck = null, bool IncludeTimestamps = false);
public sealed record LibraryData
{
    public int Version { get; init; } = 1;
    public List<Recording> Recordings { get; init; } = [];
    public List<UsageEntry> Usage { get; init; } = [];
    public List<DictionaryRule> Dictionary { get; init; } = [];
    public Preferences Preferences { get; init; } = new();
}

public sealed class LibraryStore
{
    public string Root { get; }
    public LibraryData Data { get; private set; }
    private string FilePath => Path.Combine(Root, "library.json");
    private static readonly JsonSerializerOptions Options = new() { WriteIndented = true, PropertyNameCaseInsensitive = true };
    public LibraryStore(string root)
    {
        Root = Path.GetFullPath(root);
        Directory.CreateDirectory(Root);
        Directory.CreateDirectory(Path.Combine(Root, "Recordings"));
        Data = File.Exists(FilePath) ? JsonSerializer.Deserialize<LibraryData>(File.ReadAllText(FilePath), Options)
            ?? throw new InvalidDataException("The library is empty or invalid; it was not overwritten.") : new();
        if (Data.Version != 1) throw new InvalidDataException("This library requires a different version of Yapper.");
    }

    public void Save(LibraryData updated)
    {
        var temp = FilePath + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            using (var stream = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                JsonSerializer.Serialize(stream, updated, Options);
                stream.Flush(true);
            }
            if (File.Exists(FilePath)) File.Replace(temp, FilePath, FilePath + ".backup");
            else File.Move(temp, FilePath);
            Data = updated;
        }
        finally { if (File.Exists(temp)) File.Delete(temp); }
    }

    public void Add(Recording item)
    {
        if (Data.Recordings.Any(x => x.Id == item.Id)) throw new InvalidOperationException("Recording already saved.");
        var words = item.Text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Length;
        Save(Data with { Recordings = [item, .. Data.Recordings], Usage = [new(item.Id, item.Date, words, item.Duration), .. Data.Usage] });
    }
    public void UpdateConversation(Guid id, Func<Transcript, Transcript> update)
    {
        var old = Data.Recordings.Single(x => x.Id == id);
        var transcript = old.Conversation ?? throw new InvalidOperationException("This recording has no speaker turns.");
        var updated = old with { Conversation = update(transcript) };
        Save(Data with { Recordings = Data.Recordings.Select(x => x.Id == id ? updated : x).ToList() });
    }
    public void Delete(Guid id)
    {
        Save(Data with { Recordings = Data.Recordings.Where(x => x.Id != id).ToList() });
    }
}

public static class DictationText
{
    public static string Process(string text, IReadOnlyList<DictionaryRule> rules, bool trimPeriod, bool autoEdit)
    {
        text = text.Replace("\r\n", "\n").Replace('\r', '\n');
        if (autoEdit) text = AutoEdit(text);
        foreach (var rule in rules.Where(r => r.Enabled && !string.IsNullOrWhiteSpace(r.Trigger)))
        {
            var pattern = Regex.Escape(rule.Trigger.Trim()).Replace("\\ ", @"\s+");
            if (char.IsLetterOrDigit(rule.Trigger.Trim()[0])) pattern = @"\b" + pattern;
            if (char.IsLetterOrDigit(rule.Trigger.Trim()[^1])) pattern += @"\b";
            text = Regex.Replace(text, pattern, _ => rule.Replacement, RegexOptions.IgnoreCase);
        }
        if (!trimPeriod || !text.EndsWith('.') || text.EndsWith("..")) return text;
        var stem = text[..^1];
        if (stem.Length == 0 || stem.Any(char.IsWhiteSpace)) return text;
        var token = Regex.IsMatch(stem, @"^[\p{L}\p{N}_'’\-]+$");
        var number = Regex.IsMatch(stem, @"^[+-]?[0-9]+([.,][0-9]+)*%?$");
        var email = Regex.IsMatch(stem, @"^[^@\s]+@[^@\s]+\.[^@\s]+$");
        var url = (stem.StartsWith("https://") || stem.StartsWith("http://") || stem.StartsWith("www."))
            && Uri.TryCreate(stem.StartsWith("www.") ? "https://" + stem : stem, UriKind.Absolute, out _);
        return token || number || email || url ? stem : text;
    }

    private static string AutoEdit(string text)
    {
        text = Scratch(text);
        text = Regex.Replace(text, @"(?i)(^|[\s,.;:!?])(?:uh+|um+|umm+|uhm+|erm+|hmm+)(?=$|[\s,.;:!?])[,.;:!?]?", "$1");
        text = Regex.Replace(text, @"(?i)\bnew paragraph\b[,.]?", "\n\n");
        text = Regex.Replace(text, @"(?i)\bnew line\b[,.]?", "\n");
        text = FormatBullets(text);
        text = FormatNumbers(text);
        text = Regex.Replace(text, @"[ \t]+([,.;:!?])", "$1");
        text = Regex.Replace(text, @"[ \t]+", " ");
        text = Regex.Replace(text, @" *\n *", "\n");
        text = Regex.Replace(text, @"\n{3,}", "\n\n").Trim();
        return Capitalize(text);
    }

    private static string Scratch(string text)
    {
        var command = new Regex(@"(?i)\b(?:scratch that|scratch it)\b[\s,:;-]*");
        while (command.Match(text) is { Success: true } match)
        {
            var prefix = text[..match.Index];
            var boundary = prefix.LastIndexOfAny(['.', '!', '?', '\n']);
            var kept = boundary >= 0 ? prefix[..(boundary + 1)].Trim() : "";
            var correction = text[(match.Index + match.Length)..].Trim();
            text = string.Join(kept.Length == 0 ? "" : " ", new[] { kept, correction }.Where(x => x.Length > 0));
        }
        return text;
    }

    private static string FormatBullets(string text)
    {
        var regex = new Regex(@"(?i)\b(?:bullet point|bullet item)\b[\s,:-]*");
        return regex.Matches(text).Count < 2 ? text : regex.Replace(text, "\n• ").Trim();
    }

    private static string FormatNumbers(string text)
    {
        var names = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase)
        { ["one"] = 1, ["two"] = 2, ["three"] = 3, ["four"] = 4, ["five"] = 5,
          ["six"] = 6, ["seven"] = 7, ["eight"] = 8, ["nine"] = 9, ["ten"] = 10 };
        var regex = new Regex(@"(?i)\b(?:number|item)\s+(one|two|three|four|five|six|seven|eight|nine|ten|[1-9]|10)\b[\s,:-]*");
        var matches = regex.Matches(text);
        var values = matches.Select(m => int.TryParse(m.Groups[1].Value, out var n) ? n : names[m.Groups[1].Value]).ToArray();
        if (values.Length < 2 || values.Where((value, index) => value != values[0] + index).Any()) return text;
        var index = 0;
        var output = regex.Replace(text, _ => "\n" + values[index++] + ". ").Trim();
        return Regex.Replace(output, @"[ \t]+(?=\n\d+[.] )", "");
    }

    private static string Capitalize(string text)
    {
        foreach (var pattern in new[] { @"(?m)^([ \t]*(?:[•*-]|\d+[.)])?[ \t]*)([a-z])", @"([.!?][ \t]+)([a-z])" })
            text = Regex.Replace(text, pattern, match =>
            {
                var rest = text[(match.Groups[2].Index)..];
                var end = rest.IndexOfAny([' ', '\t', '\r', '\n', ',', ';', ':', '!', '?']);
                var token = end >= 0 ? rest[..end] : rest;
                if (token.Contains('@') || token.Skip(1).Any(char.IsUpper)) return match.Value;
                return match.Groups[1].Value + match.Groups[2].Value.ToUpperInvariant();
            });
        return text;
    }
}

public sealed class JobGate
{
    private Guid? active;
    public bool IsBusy => active is not null;
    public bool CancellationRequested { get; private set; }
    public Guid Begin()
    {
        if (IsBusy) throw new InvalidOperationException("Another recording is still being processed.");
        active = Guid.NewGuid();
        CancellationRequested = false;
        return active.Value;
    }
    public void Cancel() { if (IsBusy) CancellationRequested = true; }
    public bool CanCommit(Guid id) => active == id && !CancellationRequested;
    public void Finish(Guid id) { if (active == id) active = null; }
}

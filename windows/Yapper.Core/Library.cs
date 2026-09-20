using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace Yapper.Core;

public sealed record Recording(Guid Id, DateTimeOffset Date, string Text, double Duration, string AudioPath, string Model, Transcript? Conversation = null)
{
    [JsonIgnore] public string DisplayText => Conversation?.FormattedText() ?? Text;
    [JsonIgnore] public string Label => $"{Date.LocalDateTime:g} · {Model} · {Text.Replace('\n', ' ')[..Math.Min(Text.Length, 70)]}";
}
public sealed record UsageEntry(Guid Id, DateTimeOffset Date, int Words, double Seconds);
public sealed record DictionaryRule(string Trigger, string Replacement, bool Enabled = true);
public sealed record Preferences(string SelectedModel = "whisper-small", string Language = "auto", bool ToggleRecording = true,
    bool RestoreClipboard = true, bool TrimPeriod = true, string Hotkey = "Control+Alt+Space", bool AutoEdit = false, string Theme = "System", bool AutoCheckUpdates = true, DateTimeOffset? LastUpdateCheck = null);
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
        if (autoEdit) text = Regex.Replace(text, @"\b(um|uh)\b[, ]*", "", RegexOptions.IgnoreCase);
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

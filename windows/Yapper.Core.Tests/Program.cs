using System.Text.Json;
using Yapper.Core;

var tests = new (string Name, Action Run)[]
{
    ("lossless alignment and overlap", () =>
    {
        var words = new[] { new SpeechWord("Hello", 0, .5), new SpeechWord(" there", .5, 1), new SpeechWord(" friend", 1, 1.5) };
        var transcript = Alignment.Align(words, [new("a", 0, 1.5), new("b", .6, .9)], true);
        Equal("Hello there friend", transcript.PlainText);
        True(transcript.Segments.Any(s => s.SpeakerId is null));
        Equal("1", transcript.Segments[0].SpeakerId);
    }),
    ("single speaker and reading continuity", () =>
    {
        var transcript = new Transcript { SpeakerDetectionRequested = true, Segments = [new(0, 0, 1, "Hello", "1"), new(1, 1, 1.2, " um"), new(2, 1.2, 2, " there", "1")] };
        Equal(1, transcript.FormattedText().Split("[00:").Length - 1);
        True(transcript.FormattedText().Contains("um†"));
        True(transcript.Segments[1].SpeakerId is null);
        var corrected = transcript.ConfirmSingleSpeaker();
        True(corrected.Segments.All(s => s.SpeakerId == "1"));
        Equal(transcript.PlainText, corrected.PlainText);
        Equal(transcript.FormattedText(), corrected.UndoSingleSpeaker().FormattedText());
    }),
    ("paragraph presentation preserves words and timestamps can return", () =>
    {
        var transcript = new Transcript { SpeakerDetectionRequested = true, Segments =
            [new(0, 0, 1, "Hello", "1"), new(1, 4, 5, " again", "1"), new(2, 7, 8, " Reply", "2")] };
        var paragraph = transcript.WithTimestamps(false);
        True(!paragraph.FormattedText().Contains("[00:"));
        True(paragraph.FormattedText().Contains("Speaker 1: Hello again"));
        Equal(transcript.PlainText, paragraph.PlainText);
        True(paragraph.WithTimestamps(true).FormattedText().Contains("[00:00:00]"));
        var legacy = JsonSerializer.Deserialize<Transcript>("{\"segments\":[],\"speakerDetectionRequested\":false}")!;
        True(legacy.ShowsTimestamps);
    }),
    ("rename edit merge and persisted undo", () =>
    {
        var transcript = new Transcript { SpeakerDetectionRequested = true, Segments = [new(0, 0, 1, "One", "1"), new(1, 2, 3, " two", "2")] };
        var named = transcript.Rename("1", "Alice");
        True(named.FormattedText().Contains("Alice:"));
        True(!transcript.FormattedText().Contains("Alice:"));
        var edited = named.ConfirmSingleSpeaker().Edit(0, "Corrected", "1");
        var reopened = JsonSerializer.Deserialize<Transcript>(JsonSerializer.Serialize(edited))!;
        var undone = reopened.UndoSingleSpeaker();
        Equal("Corrected", undone.Segments[0].Text);
        Equal("One", undone.Segments[0].OriginalText);
        Equal("2", undone.Segments[1].SpeakerId);
        True(undone.Merge("2", "1").Segments.All(s => s.SpeakerId == "1"));
    }),
    ("history updates do not duplicate statistics", () =>
    {
        WithLibrary(root =>
        {
            var store = new LibraryStore(root);
            var id = Guid.NewGuid();
            store.Add(new(id, DateTimeOffset.UtcNow, "Hello", 1, "fixture.wav", "test", new() { SpeakerDetectionRequested = true, Segments = [new(0, 0, 1, "Hello", "1")] }));
            store.UpdateConversation(id, t => t.Rename("1", "Alice"));
            var reopened = new LibraryStore(root);
            Equal(1, reopened.Data.Recordings.Count); Equal(1, reopened.Data.Usage.Count);
            True(reopened.Data.Recordings[0].DisplayText.Contains("Alice:"));
            reopened.Delete(id);
            Equal(0, reopened.Data.Recordings.Count); Equal(1, reopened.Data.Usage.Count);
        });
    }),
    ("legacy history without conversation", () =>
    {
        WithLibrary(root =>
        {
            File.WriteAllText(Path.Combine(root, "library.json"), "{\"Version\":1,\"Recordings\":[{\"Id\":\"" + Guid.NewGuid() + "\",\"Date\":\"2026-01-01T00:00:00Z\",\"Text\":\"Legacy\",\"Duration\":2,\"AudioPath\":\"a.wav\",\"Model\":\"test\"}]}");
            Equal("Legacy", new LibraryStore(root).Data.Recordings[0].DisplayText);
        });
    }),
    ("dictionary literal replacement and punctuation", () =>
    {
        Equal("me@example.com", DictationText.Process("my email.", [new("my email", "me@example.com")], true, false));
        Equal("$1\\folder", DictationText.Process("path", [new("path", "$1\\folder")], false, false));
        foreach (var text in new[] { "A full sentence.", "U.S.", "Wait...", "Really?" }) Equal(text, DictationText.Process(text, [], true, false));
        Equal("3.14", DictationText.Process("3.14.", [], true, false));
        Equal("Hello.", DictationText.Process("Hello.", [], false, false));
        Equal("This is a sentence. Another one\n\n• Apples\n• Bananas", DictationText.Process(
            "um this is a sentence. another one new paragraph bullet point apples bullet point bananas", [], false, true));
        Equal("Shopping list\n1. Milk\n2. Eggs\n3. Tea", DictationText.Process(
            "shopping list number one milk number two eggs number three tea", [], false, true));
        Equal("Keep this sentence. Corrected words", DictationText.Process(
            "Keep this sentence. wrong words scratch that corrected words", [], false, true));
        Equal("I like this, you know number one reason", DictationText.Process(
            "i like this, you know number one reason", [], false, true));
        Equal("me@example.com works on iPhone", DictationText.Process(
            "me@example.com works on iPhone", [], false, true));
    }),
    ("cancellation keeps busy ownership and rejects stale finish", () =>
    {
        var gate = new JobGate(); var first = gate.Begin(); gate.Cancel();
        True(gate.IsBusy); True(!gate.CanCommit(first));
        Throws(() => gate.Begin()); gate.Finish(first); var second = gate.Begin(); gate.Finish(first);
        True(gate.IsBusy); True(gate.CanCommit(second)); gate.Finish(second); True(!gate.IsBusy);
    }),
    ("theme and automatic-check preferences survive old libraries", () =>
    {
        var preferences = JsonSerializer.Deserialize<Preferences>("{\"SelectedModel\":\"whisper-small\"}")!;
        Equal("System", preferences.Theme); True(preferences.AutoCheckUpdates); True(!preferences.IncludeTimestamps);
        Equal("hinglish", preferences.Language);
        Equal("hinglish", new Preferences().Language); True(new Preferences().AutoEdit);
        var explicitChoices = JsonSerializer.Deserialize<Preferences>("{\"Language\":\"auto\",\"AutoEdit\":false}")!;
        Equal("auto", explicitChoices.Language); True(!explicitChoices.AutoEdit);
        WithLibrary(root =>
        {
            var store = new LibraryStore(root);
            store.Save(store.Data with { Preferences = preferences with { Theme = "Dark", AutoCheckUpdates = false } });
            var reopened = new LibraryStore(root);
            Equal("Dark", reopened.Data.Preferences.Theme); True(!reopened.Data.Preferences.AutoCheckUpdates);
        });
    }),
    ("processing timing is optional and survives persistence", () =>
    {
        WithLibrary(root =>
        {
            var store = new LibraryStore(root);
            var oldId = Guid.NewGuid();
            store.Add(new(oldId, DateTimeOffset.UtcNow, "Legacy", 1, "old.wav", "test"));
            var timing = new ProcessingTiming(.1, .2, .3, .4, .5, .6);
            store.Add(new(Guid.NewGuid(), DateTimeOffset.UtcNow, "Measured", 1, "new.wav", "test", Timing: timing));
            var reopened = new LibraryStore(root);
            True(reopened.Data.Recordings.First(r => r.Id == oldId).Timing is null);
            Equal(timing, reopened.Data.Recordings.First().Timing);
            Equal(2, reopened.Data.Usage.Count);
        });
    }),
    ("updates select only verified newer Windows assets", () =>
    {
        ReleaseInfo Release(string version, bool prerelease = true)
        {
            var tag = "windows-v" + version; var name = "Yapper-" + version + "-win-x64-setup.exe";
            return new(tag, "notes", false, prerelease, [new(name, $"https://github.com/shishangia/yapper/releases/download/{tag}/{name}", 100, "sha256:" + new string('a', 64))]);
        }
        var newer = Release("0.1.0-preview.3");
        Equal("0.1.0-preview.3", UpdatePolicy.Select([Release("0.1.0-preview.1"), newer], "0.1.0-preview.2")!.Version);
        True(UpdatePolicy.Select([newer], "0.1.0") is null);
        True(UpdatePolicy.Select([newer with { Draft = true }], "0.1.0-preview.2") is null);
        True(UpdatePolicy.Select([newer with { Tag = "v1.0.3" }], "0.1.0-preview.2") is null);
        True(UpdatePolicy.Select([newer with { Assets = [newer.Assets[0] with { Digest = null }] }], "0.1.0-preview.2") is null);
        True(UpdatePolicy.Select([newer with { Assets = [newer.Assets[0] with { Url = "https://example.com/update.exe" }] }], "0.1.0-preview.2") is null);
        Equal("0.1.0", UpdatePolicy.Select([Release("0.1.0", false)], "0.1.0-preview.2")!.Version);
        var shared = newer with { Tag = "v1.1.1", Prerelease = false,
            Assets = [new("Yapper-1.1.1-win-x64-setup.exe", "https://github.com/shishangia/yapper/releases/download/v1.1.1/Yapper-1.1.1-win-x64-setup.exe", 100, "sha256:" + new string('b', 64))] };
        Equal("1.1.1", UpdatePolicy.Select([shared], "0.1.0-preview.2")!.Version);
        Equal("v1.1.1", UpdatePolicy.Select([shared], "0.1.0-preview.2")!.Tag);
        True(!UpdatePolicy.TrustedAsset("https://github.com.evil.test/shishangia/yapper/releases/download/a/b", "a", "b"));
    }),
    ("corrupt library is not overwritten", () =>
    {
        WithLibrary(root => { var path = Path.Combine(root, "library.json"); File.WriteAllText(path, "broken"); Throws(() => new LibraryStore(root)); Equal("broken", File.ReadAllText(path)); });
    })
};
var failures = 0;
foreach (var (name, run) in tests)
{
    try { run(); Console.WriteLine("PASS " + name); }
    catch (Exception error) { failures++; Console.Error.WriteLine("FAIL " + name + ": " + error); }
}
Console.WriteLine($"{tests.Length - failures}/{tests.Length} checks passed");
return failures == 0 ? 0 : 1;
static void Equal<T>(T expected, T actual) { if (!EqualityComparer<T>.Default.Equals(expected, actual)) throw new Exception($"Expected {expected}, got {actual}"); }
static void True(bool condition) { if (!condition) throw new Exception("Assertion failed"); }
static void Throws(Action action) { try { action(); } catch { return; } throw new Exception("Expected exception"); }
static void WithLibrary(Action<string> test)
{
    var root = Path.Combine(Path.GetTempPath(), "Yapper-test-" + Guid.NewGuid()); Directory.CreateDirectory(root);
    try { test(root); } finally { Directory.Delete(root, true); }
}

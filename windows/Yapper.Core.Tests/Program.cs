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
    }),
    ("cancellation keeps busy ownership and rejects stale finish", () =>
    {
        var gate = new JobGate(); var first = gate.Begin(); gate.Cancel();
        True(gate.IsBusy); True(!gate.CanCommit(first));
        Throws(() => gate.Begin()); gate.Finish(first); var second = gate.Begin(); gate.Finish(first);
        True(gate.IsBusy); True(gate.CanCommit(second)); gate.Finish(second); True(!gate.IsBusy);
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

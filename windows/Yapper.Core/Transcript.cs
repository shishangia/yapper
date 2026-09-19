using System.Text;

namespace Yapper.Core;

public sealed record TranscriptSegment(int Id, double Start, double End, string Text, string? SpeakerId = null, string? OriginalText = null);
public sealed record SpeechWord(string Text, double Start, double End, bool Reliable = true);
public sealed record SpeakerTurn(string SpeakerId, double Start, double End);
public sealed record SpeakerSnapshot(string?[] SpeakerIds, Dictionary<string, string> Names, bool DetectionRequested);

public sealed record Transcript
{
    public List<TranscriptSegment> Segments { get; init; } = [];
    public Dictionary<string, string> SpeakerNames { get; init; } = [];
    public bool SpeakerDetectionRequested { get; init; }
    public string? Warning { get; init; }
    public SpeakerSnapshot? SingleSpeakerUndo { get; init; }
    public string PlainText => string.Concat(Segments.Select(s => s.Text));
    public string SpeakerName(string? id) => id is null ? "Needs review" : SpeakerNames.GetValueOrDefault(id, "Speaker " + id);
    public IEnumerable<string> SpeakerIds => Segments.Select(s => s.SpeakerId).OfType<string>().Concat(SpeakerNames.Keys).Distinct();

    public string FormattedText()
    {
        var blocks = new List<(string? Speaker, double Start, double End, StringBuilder Text)>();
        var uncertain = false;
        for (var i = 0; i < Segments.Count; i++)
        {
            var first = Segments[i];
            var end = first.End;
            var text = first.Text;
            var speaker = first.SpeakerId;
            if (SpeakerDetectionRequested && speaker is null)
            {
                while (i + 1 < Segments.Count && Segments[i + 1].SpeakerId is null && Segments[i + 1].Start - end <= 1)
                {
                    var next = Segments[++i];
                    text += next.Text;
                    end = next.End;
                }
                uncertain = true;
                var shortRun = end - first.Start <= 2 && text.Length <= 48 && text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Length <= 4;
                if (shortRun && blocks.Count > 0 && blocks[^1].Speaker is not null && first.Start - blocks[^1].End <= 1)
                    speaker = blocks[^1].Speaker;
                else if (shortRun && i + 1 < Segments.Count && Segments[i + 1].Start - end <= 1)
                    speaker = Segments[i + 1].SpeakerId;
                var trailing = text.Length - text.TrimEnd().Length;
                text = text.TrimEnd() + "†" + (trailing > 0 ? text[^trailing..] : "");
            }
            if (blocks.Count > 0 && blocks[^1].Speaker == speaker && first.Start - blocks[^1].End <= 1)
            {
                var block = blocks[^1];
                block.Text.Append(text);
                blocks[^1] = (speaker, block.Start, end, block.Text);
            }
            else blocks.Add((speaker, first.Start, end, new StringBuilder(text)));
        }
        var result = string.Join(Environment.NewLine, blocks.Select(b =>
            $"[{TimeSpan.FromSeconds(Math.Max(0, b.Start)):hh\\:mm\\:ss}]{(SpeakerDetectionRequested ? " " + SpeakerName(b.Speaker) + ":" : "")} {b.Text.ToString().Trim()}"));
        return uncertain ? result + "\n\n† Speaker attribution needs review for the marked words." : result;
    }

    public Transcript Rename(string id, string name)
    {
        if (!SpeakerIds.Contains(id)) throw new ArgumentException("Speaker not found.");
        var names = new Dictionary<string, string>(SpeakerNames) { [id] = name.Trim() };
        if (names[id].Length == 0) names.Remove(id);
        return this with { SpeakerNames = names, SingleSpeakerUndo = null };
    }

    public Transcript Edit(int id, string text, string? speakerId)
    {
        var index = Segments.FindIndex(s => s.Id == id);
        if (index < 0) throw new ArgumentException("Passage not found.");
        var old = Segments[index];
        if (speakerId is not null && !SpeakerIds.Contains(speakerId)) throw new ArgumentException("Speaker not found.");
        var segments = Segments.ToList();
        segments[index] = old with { Text = text, SpeakerId = speakerId, OriginalText = old.OriginalText ?? old.Text };
        return this with { Segments = segments, SingleSpeakerUndo = old.SpeakerId == speakerId ? SingleSpeakerUndo : null };
    }

    public Transcript Merge(string from, string into)
    {
        if (from == into || !SpeakerIds.Contains(from) || !SpeakerIds.Contains(into)) throw new ArgumentException("Choose two different speakers.");
        var names = new Dictionary<string, string>(SpeakerNames);
        names.Remove(from);
        return this with { Segments = Segments.Select(s => s.SpeakerId == from ? s with { SpeakerId = into } : s).ToList(), SpeakerNames = names, SingleSpeakerUndo = null };
    }

    public Transcript AddSpeaker(string name)
    {
        var id = 1;
        while (SpeakerIds.Contains(id.ToString())) id++;
        var names = new Dictionary<string, string>(SpeakerNames) { [id.ToString()] = name.Trim().Length == 0 ? "Speaker " + id : name.Trim() };
        return this with { SpeakerNames = names, SingleSpeakerUndo = null };
    }

    public Transcript ConfirmSingleSpeaker()
    {
        if (SingleSpeakerUndo is not null) return this;
        var id = SpeakerIds.FirstOrDefault() ?? "1";
        return this with
        {
            SingleSpeakerUndo = new(Segments.Select(s => s.SpeakerId).ToArray(), new(SpeakerNames), SpeakerDetectionRequested),
            SpeakerDetectionRequested = true,
            Segments = Segments.Select(s => s with { SpeakerId = id }).ToList(),
            SpeakerNames = new() { [id] = SpeakerName(id) }
        };
    }

    public Transcript UndoSingleSpeaker()
    {
        var snapshot = SingleSpeakerUndo ?? throw new InvalidOperationException("No correction to undo.");
        if (snapshot.SpeakerIds.Length != Segments.Count) throw new InvalidOperationException("Passages changed.");
        return this with { Segments = Segments.Select((s, i) => s with { SpeakerId = snapshot.SpeakerIds[i] }).ToList(), SpeakerNames = new(snapshot.Names), SpeakerDetectionRequested = snapshot.DetectionRequested, SingleSpeakerUndo = null };
    }
}

public static class Alignment
{
    public static Transcript Align(IReadOnlyList<SpeechWord> words, IReadOnlyList<SpeakerTurn> turns, bool detect, bool single = false)
    {
        var names = new Dictionary<string, string>();
        var segments = new List<TranscriptSegment>();
        foreach (var word in words.Where(w => w.Text.Length > 0))
        {
            var start = double.IsFinite(word.Start) ? Math.Max(0, word.Start) : segments.LastOrDefault()?.End ?? 0;
            var end = double.IsFinite(word.End) ? Math.Max(start, word.End) : start;
            string? speaker = single && detect ? "1" : null;
            if (detect && !single && word.Reliable && end > start)
            {
                var intersecting = turns.Where(t => double.IsFinite(t.Start) && double.IsFinite(t.End) && Math.Min(t.End, end) > Math.Max(t.Start, start)).ToList();
                var candidates = intersecting.Select(t => t.SpeakerId).Distinct().ToArray();
                if (candidates.Length == 1 && intersecting.Any(t => t.Start <= start + .05 && t.End >= end - .05))
                {
                    if (!names.TryGetValue(candidates[0], out speaker)) names[candidates[0]] = speaker = (names.Count + 1).ToString();
                }
            }
            if (segments.Count > 0 && segments[^1].SpeakerId == speaker && start >= segments[^1].Start && start - segments[^1].End <= 1)
                segments[^1] = segments[^1] with { Text = segments[^1].Text + word.Text, End = Math.Max(end, segments[^1].End) };
            else segments.Add(new(segments.Count, start, end, word.Text, speaker));
        }
        return new() { Segments = segments, SpeakerDetectionRequested = detect };
    }
}

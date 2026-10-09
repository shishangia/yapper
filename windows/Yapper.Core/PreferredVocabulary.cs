namespace Yapper.Core;

public static class PreferredVocabulary
{
    public static string[] Parse(string text) => text.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries)
        .Select(line => string.Join(" ", line.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries)))
        .Where(word => word.Length is > 0 and <= 60).Distinct(StringComparer.OrdinalIgnoreCase).Take(50).ToArray();
    public static string Prompt(string text)
    {
        var prompt = string.Join(", ", Parse(text));
        return prompt[..Math.Min(1000, prompt.Length)];
    }
}

/// Learns a vocabulary correction from a hand edit of a saved transcript, e.g. a mis-transcribed
/// name the user retyped. Fires only on an explicit save, never while typing.
public static class PreferredWordLearner
{
    private static readonly HashSet<string> Common = new(StringComparer.OrdinalIgnoreCase)
    {
        "a", "an", "the", "is", "are", "was", "were", "be", "been", "am", "i", "you", "he", "she", "it", "we", "they",
        "my", "your", "his", "her", "its", "our", "their", "this", "that", "these", "those", "to", "of", "in", "on",
        "at", "for", "with", "and", "or", "but", "so", "if", "as", "by", "from", "not", "no", "do", "does", "did",
        "have", "has", "had", "will", "would", "can", "could", "should", "there", "here", "what", "who", "which", "um", "uh"
    };

    /// Returns the corrected phrase (1-3 words) worth remembering, or null when the edit is a
    /// whole rewrite, a grammar tweak, a pure insertion/deletion, or too different from the
    /// original to plausibly be the same word.
    public static string? Learn(string original, string edited)
    {
        var from = Tokenize(original);
        var to = Tokenize(edited);
        // ponytail: O(n*m) alignment table; this cap keeps it cheap and also rules out a whole rewrite.
        if (from.Length == 0 || to.Length == 0 || from.Length > 400 || to.Length > 400) return null;
        var gaps = Gaps(from, to);
        if (gaps.Count != 1) return null;
        var (fromRun, toRun) = gaps[0];
        if (fromRun.Length is 0 or > 3 || toRun.Length is 0 or > 3) return null;
        if (fromRun.All(Common.Contains)) return null;
        var fromText = string.Join(' ', fromRun);
        var toText = string.Join(' ', toRun);
        var distance = Levenshtein(fromText.ToLowerInvariant(), toText.ToLowerInvariant());
        return distance <= Math.Max(fromText.Length, toText.Length) * 0.65 ? toText : null;
    }

    private static string[] Tokenize(string text) =>
        System.Text.RegularExpressions.Regex.Matches(text, @"[\w'-]+").Select(m => m.Value).ToArray();

    // Aligns the two token sequences on their longest common subsequence (case-insensitive) and
    // returns each contiguous run where they diverge, paired on both sides.
    private static List<(string[] From, string[] To)> Gaps(string[] from, string[] to)
    {
        var n = from.Length; var m = to.Length;
        var table = new int[n + 1, m + 1];
        for (var i = 1; i <= n; i++)
            for (var j = 1; j <= m; j++)
                table[i, j] = string.Equals(from[i - 1], to[j - 1], StringComparison.OrdinalIgnoreCase)
                    ? table[i - 1, j - 1] + 1 : Math.Max(table[i - 1, j], table[i, j - 1]);
        var matches = new List<(int I, int J)>();
        int ii = n, jj = m;
        while (ii > 0 && jj > 0)
        {
            if (string.Equals(from[ii - 1], to[jj - 1], StringComparison.OrdinalIgnoreCase) && table[ii, jj] == table[ii - 1, jj - 1] + 1)
            { matches.Add((ii - 1, jj - 1)); ii--; jj--; }
            else if (table[ii - 1, jj] >= table[ii, jj - 1]) ii--;
            else jj--;
        }
        matches.Reverse();
        var gaps = new List<(string[] From, string[] To)>();
        int prevI = 0, prevJ = 0;
        foreach (var (i, j) in matches)
        {
            if (i > prevI || j > prevJ) gaps.Add((from[prevI..i], to[prevJ..j]));
            prevI = i + 1; prevJ = j + 1;
        }
        if (prevI < n || prevJ < m) gaps.Add((from[prevI..n], to[prevJ..m]));
        return gaps;
    }

    private static int Levenshtein(string a, string b)
    {
        var table = new int[a.Length + 1, b.Length + 1];
        for (var i = 0; i <= a.Length; i++) table[i, 0] = i;
        for (var j = 0; j <= b.Length; j++) table[0, j] = j;
        for (var i = 1; i <= a.Length; i++)
            for (var j = 1; j <= b.Length; j++)
                table[i, j] = a[i - 1] == b[j - 1] ? table[i - 1, j - 1]
                    : 1 + Math.Min(table[i - 1, j - 1], Math.Min(table[i - 1, j], table[i, j - 1]));
        return table[a.Length, b.Length];
    }
}

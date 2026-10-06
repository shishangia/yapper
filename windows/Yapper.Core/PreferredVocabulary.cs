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

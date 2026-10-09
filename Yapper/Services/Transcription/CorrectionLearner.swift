import Foundation

/// Finds names and jargon a user fixed by hand after dictation, so they can become preferred words.
enum CorrectionLearner {
    struct Substitution: Equatable {
        let heard: [String]
        let fixed: [String]
    }

    private static let commonWords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "if", "so", "to", "of", "in", "on", "at", "by", "for", "with",
        "from", "as", "is", "are", "was", "were", "be", "been", "am", "do", "does", "did", "have", "has", "had",
        "i", "you", "he", "she", "it", "we", "they", "me", "him", "her", "us", "them", "my", "your", "his",
        "its", "our", "their", "there", "here", "this", "that", "these", "those", "what", "which", "who",
        "when", "where", "why", "how", "not", "no", "yes", "can", "will", "would", "should", "could", "may",
        "just", "then", "than", "too", "also", "very", "all", "some", "any", "more", "most", "one", "two",
        "up", "down", "out", "about", "into", "over", "now", "new", "good", "get", "got", "go", "know",
        "think", "like", "want", "need", "make", "see", "say", "said", "time", "day", "way", "thing", "okay",
        "ok", "well", "right", "let", "let's", "it's", "i'm", "don't", "can't", "i'll", "we'll", "you're",
    ]

    /// Corrected words or short phrases worth remembering, deduplicated case-insensitively.
    static func learnedWords(original: String, edited: String) -> [String] {
        let heard = tokens(original), fixed = tokens(edited)
        guard !heard.isEmpty, !fixed.isEmpty else { return [] }
        let changes = substitutions(heard, fixed)
        // A rewrite is not a correction: most of what was dictated changed.
        guard changes.reduce(0, { $0 + $1.heard.count }) * 2 <= heard.count else { return [] }
        var seen = Set<String>()
        return changes.compactMap { change in
            // Pure insertions and deletions are rewording, not a misheard word.
            guard (1...3).contains(change.heard.count), (1...3).contains(change.fixed.count) else { return nil }
            let phrase = change.fixed.joined(separator: " ")
            let lowered = change.fixed.map { $0.lowercased() }
            guard phrase.contains(where: \.isLetter), !lowered.allSatisfy(commonWords.contains) else { return nil }
            let before = change.heard.joined(separator: " ").lowercased(), after = phrase.lowercased()
            guard Double(editDistance(before, after)) <= 0.65 * Double(max(before.count, after.count)),
                  seen.insert(after).inserted else { return nil }
            return phrase
        }
    }

    /// Words with surrounding punctuation removed; the LCS compares them case-insensitively.
    static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).compactMap { raw in
            let word = raw.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
            return word.isEmpty ? nil : word
        }
    }

    /// Changed runs (replaced, inserted, or deleted) between the words both texts share, found with a longest common subsequence.
    static func substitutions(_ a: [String], _ b: [String]) -> [Substitution] {
        let x = a.map { $0.lowercased() }, y = b.map { $0.lowercased() }
        // ponytail: O(n*m) table; dictations are a few hundred words at most.
        var table = Array(repeating: Array(repeating: 0, count: y.count + 1), count: x.count + 1)
        for i in stride(from: x.count - 1, through: 0, by: -1) {
            for j in stride(from: y.count - 1, through: 0, by: -1) {
                table[i][j] = x[i] == y[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var result: [Substitution] = []
        var i = 0, j = 0, heard: [String] = [], fixed: [String] = []
        func flush() {
            if !heard.isEmpty || !fixed.isEmpty { result.append(Substitution(heard: heard, fixed: fixed)) }
            heard = []; fixed = []
        }
        while i < x.count || j < y.count {
            if i < x.count, j < y.count, x[i] == y[j] {
                flush(); i += 1; j += 1
            } else if j < y.count, i == x.count || table[i][j + 1] >= table[i + 1][j] {
                fixed.append(b[j]); j += 1
            } else {
                heard.append(a[i]); i += 1
            }
        }
        flush()
        return result
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var previous = row[0]
            row[0] = i
            for j in stride(from: 1, through: b.count, by: 1) {
                let current = row[j]
                row[j] = a[i - 1] == b[j - 1] ? previous : min(previous, row[j], row[j - 1]) + 1
                previous = current
            }
        }
        return row[b.count]
    }
}

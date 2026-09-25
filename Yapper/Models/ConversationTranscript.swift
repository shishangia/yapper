import Foundation

struct ConversationSegment: Identifiable, Codable, Equatable, Sendable {
    let id: Int
    let start: TimeInterval
    var end: TimeInterval
    var text: String
    var speakerID: String?
    var originalText: String? = nil
}

struct ConversationTranscript: Codable, Equatable, Sendable {
    var segments: [ConversationSegment]
    var speakerNames: [String: String] = [:]
    var speakerDetectionRequested: Bool
    var warning: String?
    var singleSpeakerUndo: SpeakerAssignmentSnapshot? = nil
    /// Optional for backward-compatible decoding. Existing transcripts keep
    /// the timestamped presentation they were saved with before this setting.
    var timestampsVisible: Bool? = nil

    var plainText: String { segments.map(\.text).joined() }
    var speakerIDs: [String] {
        (segments.compactMap(\.speakerID) + speakerNames.keys.sorted()).reduce(into: []) { ids, id in
            if !ids.contains(id) { ids.append(id) }
        }
    }

    func speakerName(for id: String?) -> String {
        guard let id else { return "Speaker uncertain" }
        return speakerNames[id] ?? "Speaker \(id)"
    }

    var unassignedCount: Int { speakerDetectionRequested ? segments.filter { $0.speakerID == nil }.count : 0 }
    var showsTimestamps: Bool { timestampsVisible ?? true }

    var readingBlocks: [ConversationReadingBlock] {
        var blocks: [ConversationReadingBlock] = []
        var index = 0
        func isContinuous(_ previous: ConversationSegment, _ next: ConversationSegment) -> Bool {
            next.start >= previous.start && next.start - previous.end <= 1
        }
        while index < segments.count {
            let first = segments[index]
            if speakerDetectionRequested && first.speakerID == nil {
                var passage = [first]
                index += 1
                while index < segments.count, segments[index].speakerID == nil,
                      isContinuous(passage[passage.count - 1], segments[index]) {
                    passage.append(segments[index])
                    index += 1
                }
                let text = passage.map(\.text).joined()
                let last = passage[passage.count - 1]
                let isShort = last.end - first.start <= 2 && text.count <= 48
                    && text.split(whereSeparator: \.isWhitespace).count <= 4
                if isShort, let previous = blocks.last, previous.speakerID != nil,
                   let previousEnd = previous.segments.last, isContinuous(previousEnd, first) {
                    blocks[blocks.count - 1].segments.append(contentsOf: passage)
                } else if isShort, index < segments.count, let speaker = segments[index].speakerID,
                          isContinuous(last, segments[index]) {
                    passage.append(segments[index])
                    blocks.append(ConversationReadingBlock(segments: passage, speakerID: speaker))
                    index += 1
                } else {
                    blocks.append(ConversationReadingBlock(segments: passage, speakerID: nil))
                }
            } else {
                if let previous = blocks.last, let last = previous.segments.last,
                   (!speakerDetectionRequested || previous.speakerID == first.speakerID),
                   isContinuous(last, first) {
                    blocks[blocks.count - 1].segments.append(first)
                } else {
                    blocks.append(ConversationReadingBlock(segments: [first], speakerID: first.speakerID))
                }
                index += 1
            }
        }
        return blocks
    }

    /// Paragraph mode ignores silent gaps. It keeps real speaker changes, but
    /// a transcript without speaker labels becomes one continuous paragraph.
    var paragraphBlocks: [ConversationReadingBlock] {
        guard speakerDetectionRequested else {
            return segments.isEmpty ? [] : [ConversationReadingBlock(segments: segments, speakerID: nil)]
        }
        return readingBlocks.reduce(into: []) { blocks, block in
            if let previous = blocks.last, previous.speakerID == block.speakerID {
                blocks[blocks.count - 1].segments.append(contentsOf: block.segments)
            } else {
                blocks.append(block)
            }
        }
    }

    var displayedBlocks: [ConversationReadingBlock] {
        showsTimestamps ? readingBlocks : paragraphBlocks
    }

    func readingText(for block: ConversationReadingBlock) -> String {
        block.segments.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var formattedText: String {
        let text = displayedBlocks.map { block in
            let passage = block.segments.map { segment in
                guard speakerDetectionRequested && segment.speakerID == nil else { return segment.text }
                let trailing = String(segment.text.reversed().prefix(while: \.isWhitespace).reversed())
                return String(segment.text.dropLast(trailing.count)) + "†" + trailing
            }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            if showsTimestamps {
                let label = speakerDetectionRequested
                    ? " \(block.speakerID.map { speakerName(for: $0) } ?? "Needs review"):" : ""
                return "[\(Self.timestamp(block.start))]\(label) \(passage)"
            }
            if speakerDetectionRequested {
                return "\(block.speakerID.map { speakerName(for: $0) } ?? "Needs review"): \(passage)"
            }
            return passage
        }.joined(separator: showsTimestamps ? "\n" : "\n\n")
        return unassignedCount > 0 ? text + "\n\n† Speaker attribution needs review for the marked words." : text
    }

    static func timestamp(_ seconds: TimeInterval) -> String {
        let value = seconds.isFinite ? Int(max(0, seconds)) : 0
        return String(format: "%02d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
    }
}

struct SpeakerAssignmentSnapshot: Codable, Equatable, Sendable {
    let segmentIDs: [Int]
    let speakerIDs: [String?]
    let speakerNames: [String: String]
    let speakerDetectionRequested: Bool
}

struct ConversationReadingBlock: Identifiable {
    var segments: [ConversationSegment]
    let speakerID: String?
    var id: Int { segments[0].id }
    var start: TimeInterval { segments[0].start }
}

struct ConversationWord: Equatable, Sendable {
    let text: String
    let start: TimeInterval
    let end: TimeInterval
    var hasReliableTiming = true
    /// A model without word-alignment heads may still provide a trustworthy
    /// timestamp for the whole segment. Attribute it only when one speaker turn
    /// covers that complete range.
    var allowsWholeRangeAssignment = false
}

struct ConversationSpeakerTurn: Sendable {
    let speakerID: String
    let start: TimeInterval
    let end: TimeInterval
}

enum ConversationAlignment {
    static func speechChunks(_ regions: [Range<Int>], sampleCount: Int, maxSamples: Int) -> [Range<Int>] {
        guard sampleCount > 0, maxSamples > 0, !regions.isEmpty else { return [] }
        if sampleCount <= maxSamples { return [0..<sampleCount] }
        var chunks: [Range<Int>] = []
        for region in regions {
            var lower = max(chunks.last?.upperBound ?? 0, max(0, region.lowerBound))
            let upper = min(sampleCount, region.upperBound)
            guard lower < upper else { continue }
            if let last = chunks.last, upper - last.lowerBound <= maxSamples {
                chunks[chunks.count - 1] = last.lowerBound..<upper
                continue
            }
            while lower < upper {
                let end = min(upper, lower + maxSamples)
                chunks.append(lower..<end)
                lower = end
            }
        }
        return chunks
    }

    static func align(words: [ConversationWord], turns: [ConversationSpeakerTurn], detectSpeakers: Bool) -> ConversationTranscript {
        let sortedTurns = turns.filter { $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start }
            .sorted { $0.start == $1.start ? $0.speakerID < $1.speakerID : $0.start < $1.start }
        var validTurns: [ConversationSpeakerTurn] = []
        for turn in sortedTurns {
            if let previous = validTurns.last, previous.speakerID == turn.speakerID, turn.start - previous.end <= 0.5,
               !sortedTurns.contains(where: { $0.speakerID != turn.speakerID && $0.start < turn.end && $0.end > previous.start }) {
                validTurns[validTurns.count - 1] = ConversationSpeakerTurn(speakerID: turn.speakerID,
                    start: previous.start, end: max(previous.end, turn.end))
            } else {
                validTurns.append(turn)
            }
        }
        var names: [String: String] = [:]
        var segments: [ConversationSegment] = []
        for word in words where !word.text.isEmpty {
            var speaker: String?
            if detectSpeakers, (word.hasReliableTiming || word.allowsWholeRangeAssignment),
               word.start.isFinite, word.end.isFinite, word.end > word.start {
                let intersecting = validTurns.filter { min($0.end, word.end) > max($0.start, word.start) }
                let speakers = Set(intersecting.map(\.speakerID))
                // Never force overlapping voices or a boundary word onto one speaker.
                if speakers.count == 1, let candidate = speakers.first,
                   intersecting.contains(where: { $0.start <= word.start + 0.05 && $0.end >= word.end - 0.05 }) {
                    if names[candidate] == nil { names[candidate] = String(names.count + 1) }
                    speaker = names[candidate]
                }
            }
            let start = word.start.isFinite ? max(0, word.start) : (segments.last?.end ?? 0)
            let end = word.end.isFinite ? max(start, word.end) : start
            if let last = segments.last, last.speakerID == speaker, start >= last.start, start - last.end <= 1 {
                segments[segments.count - 1].text += word.text
                segments[segments.count - 1].end = max(last.end, end)
            } else {
                segments.append(ConversationSegment(id: segments.count, start: start, end: end, text: word.text, speakerID: speaker))
            }
        }
        return ConversationTranscript(segments: segments, speakerDetectionRequested: detectSpeakers)
    }

    static func preservingText(_ text: String, words: [ConversationWord], start: TimeInterval, end: TimeInterval) -> [ConversationWord] {
        guard !text.isEmpty else { return [] }
        var cursor = text.startIndex
        var output: [ConversationWord] = []
        for word in words {
            let token = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { continue }
            guard let range = text.range(of: token, range: cursor..<text.endIndex) else { break }
            let gap = String(text[cursor..<range.lowerBound])
            let whitespaceOnly = gap.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if !whitespaceOnly {
                output.append(ConversationWord(text: gap, start: output.last?.end ?? start, end: word.start, hasReliableTiming: false))
            }
            output.append(ConversationWord(text: (whitespaceOnly ? gap : "") + String(text[range]), start: word.start, end: word.end,
                hasReliableTiming: word.hasReliableTiming, allowsWholeRangeAssignment: word.allowsWholeRangeAssignment))
            cursor = range.upperBound
        }
        if cursor < text.endIndex {
            output.append(ConversationWord(text: String(text[cursor...]), start: output.last?.end ?? start, end: end, hasReliableTiming: false))
        }
        return output
    }
}

import XCTest
import WhisperKit
@testable import Yapper

@MainActor
final class ConversationAlignmentTests: XCTestCase {
    func testRepeatedTurnsAndOverlapPreserveEveryWord() {
        let words = [
            ConversationWord(text: " Hello", start: 0, end: 0.4),
            ConversationWord(text: " yes", start: 1, end: 1.2),
            ConversationWord(text: " again", start: 2, end: 2.5),
            ConversationWord(text: " overlap", start: 3, end: 3.5),
            ConversationWord(text: " unassigned", start: 4, end: 4.3)
        ]
        let turns = [
            ConversationSpeakerTurn(speakerID: "a", start: 0, end: 0.8),
            ConversationSpeakerTurn(speakerID: "b", start: 1, end: 1.5),
            ConversationSpeakerTurn(speakerID: "a", start: 2, end: 3.8),
            ConversationSpeakerTurn(speakerID: "b", start: 3, end: 3.8)
        ]
        let result = ConversationAlignment.align(words: words, turns: turns, detectSpeakers: true)
        XCTAssertEqual(result.plainText, words.map(\.text).joined())
        XCTAssertEqual(result.segments.map(\.speakerID), ["1", "2", "1", nil])
        XCTAssertEqual(result.speakerIDs, ["1", "2"])
        XCTAssertFalse(result.formattedText.contains("Speaker uncertain"))
        XCTAssertTrue(result.formattedText.contains("†"))
    }

    func testSingleSpeakerAndShortReply() {
        let words = [ConversationWord(text: " Yes", start: 0, end: 0.15), ConversationWord(text: ", hello", start: 0.2, end: 1)]
        let result = ConversationAlignment.align(words: words, turns: [.init(speakerID: "a", start: 0, end: 1)], detectSpeakers: true)
        XCTAssertEqual(result.segments.count, 1)
        XCTAssertEqual(result.segments[0].text, " Yes, hello")
        XCTAssertEqual(result.segments[0].speakerID, "1")
    }

    func testSilenceAndInvalidTimingsRemainUnattributed() {
        XCTAssertTrue(ConversationAlignment.align(words: [], turns: [], detectSpeakers: true).segments.isEmpty)
        for word in [
            ConversationWord(text: "word", start: 1, end: 1),
            ConversationWord(text: "word", start: .nan, end: .infinity),
            ConversationWord(text: "word", start: 0, end: 1, hasReliableTiming: false)
        ] {
            let result = ConversationAlignment.align(words: [word], turns: [.init(speakerID: "a", start: 0, end: 3)], detectSpeakers: true)
            XCTAssertEqual(result.plainText, "word")
            XCTAssertNil(result.segments.first?.speakerID)
            XCTAssertTrue(result.segments[0].start.isFinite)
            XCTAssertTrue(result.segments[0].end.isFinite)
        }
    }

    func testBoundaryWordIsUnknownRatherThanGuessed() {
        let result = ConversationAlignment.align(words: [.init(text: " reply", start: 0.9, end: 1.1)], turns: [
            .init(speakerID: "a", start: 0, end: 1), .init(speakerID: "b", start: 1, end: 2)
        ], detectSpeakers: true)
        XCTAssertNil(result.segments.first?.speakerID)
        XCTAssertEqual(result.plainText, " reply")
    }

    func testPartialWordMetadataPreservesAllSourceText() {
        let text = "  um hello, missing words world!  "
        for words in [
            [ConversationWord(text: "hello,", start: 1, end: 2), .init(text: "world!", start: 3, end: 4)],
            [ConversationWord(text: "unmatched", start: 1, end: 2)],
            []
        ] {
            let recovered = ConversationAlignment.preservingText(text, words: words, start: 0, end: 5)
            XCTAssertEqual(recovered.map(\.text).joined(), text)
            XCTAssertTrue(recovered.contains { !$0.hasReliableTiming })
        }
    }

    func testMultilingualTextAndNamesRoundTrip() throws {
        let text = " नमस्ते ગુજરાતી 你好 English"
        let words = ConversationAlignment.preservingText(text, words: [], start: 0, end: 8)
        let transcript = ConversationAlignment.align(words: words, turns: [], detectSpeakers: false)
        let decoded = try JSONDecoder().decode(ConversationTranscript.self, from: JSONEncoder().encode(transcript))
        XCTAssertEqual(decoded.plainText, text)
        XCTAssertFalse(decoded.formattedText.contains("Speaker uncertain"))
        XCTAssertEqual(ConversationTranscript.timestamp(3661), "01:01:01")
    }

    func testLegacyTranscriptDefaultsToTimestampedPresentation() throws {
        let raw = #"{"segments":[{"id":0,"start":0,"end":1,"text":" Hello","speakerID":null}],"speakerNames":{},"speakerDetectionRequested":false}"#
        let decoded = try JSONDecoder().decode(ConversationTranscript.self, from: Data(raw.utf8))
        XCTAssertTrue(decoded.showsTimestamps)
        XCTAssertTrue(decoded.formattedText.hasPrefix("[00:00:00] Hello"))
    }

    func testParagraphPresentationPreservesTextAndGroupsBySpeaker() {
        let segments = [
            ConversationSegment(id: 0, start: 0, end: 1, text: " Hello", speakerID: "1"),
            ConversationSegment(id: 1, start: 4, end: 5, text: " again", speakerID: "1"),
            ConversationSegment(id: 2, start: 7, end: 8, text: " Reply", speakerID: "2"),
            ConversationSegment(id: 3, start: 8, end: 8.2, text: " yes", speakerID: nil),
        ]
        var transcript = ConversationTranscript(segments: segments, speakerNames: ["1": "Alice"],
            speakerDetectionRequested: true, timestampsVisible: false)
        XCTAssertFalse(transcript.showsTimestamps)
        XCTAssertEqual(transcript.paragraphBlocks.map(\.speakerID), ["1", "2"] )
        XCTAssertEqual(transcript.paragraphBlocks.flatMap(\.segments), segments)
        XCTAssertFalse(transcript.formattedText.contains("[00:"))
        XCTAssertTrue(transcript.formattedText.contains("Alice: Hello again"))
        XCTAssertTrue(transcript.formattedText.contains("Speaker 2: Reply yes†"))

        transcript.speakerDetectionRequested = false
        XCTAssertEqual(transcript.paragraphBlocks.count, 1)
        XCTAssertEqual(transcript.paragraphBlocks[0].segments, segments)
        XCTAssertEqual(transcript.formattedText, "Hello again Reply yes")
        XCTAssertEqual(transcript.plainText, segments.map(\.text).joined())
    }

    func testSpeechChunksPreserveRegionsWithinAudioBounds() {
        let ranges = ConversationAlignment.speechChunks([0..<10, 12..<20, 18..<35, 40..<100], sampleCount: 55, maxSamples: 20)
        XCTAssertEqual(ranges, [0..<20, 20..<35, 40..<55])
        XCTAssertTrue(ConversationAlignment.speechChunks([], sampleCount: 0, maxSamples: 20).isEmpty)
        XCTAssertTrue(ConversationAlignment.speechChunks([0..<10], sampleCount: 10, maxSamples: 0).isEmpty)
    }

    func testShortAudioPreservesLeadingContext() {
        XCTAssertEqual(ConversationAlignment.speechChunks([106..<3232], sampleCount: 3232, maxSamples: 12000), [0..<3232])
        XCTAssertTrue(ConversationAlignment.speechChunks([], sampleCount: 3232, maxSamples: 12000).isEmpty)
    }

    func testShortPauseWithinSameSpeakerDoesNotSplitGreeting() {
        let words = [ConversationWord(text: "Hi,", start: 2.34, end: 2.90),
                     .init(text: " how's it going?", start: 3.06, end: 3.92)]
        let turns = [ConversationSpeakerTurn(speakerID: "a", start: 0.96, end: 2.4),
                     .init(speakerID: "a", start: 2.8, end: 4.88)]
        let transcript = ConversationAlignment.align(words: words, turns: turns, detectSpeakers: true)
        XCTAssertEqual(transcript.segments.count, 1)
        XCTAssertEqual(transcript.segments[0].speakerID, "1")
        XCTAssertEqual(transcript.plainText, "Hi, how's it going?")
        let overlap = turns + [.init(speakerID: "b", start: 2.5, end: 2.7)]
        let uncertain = ConversationAlignment.align(words: words, turns: overlap, detectSpeakers: true)
        XCTAssertNil(uncertain.segments.first?.speakerID)
    }

    func testReadingBlocksPreserveEvidenceAndMarkUnassignedText() throws {
        let segments = [
            ConversationSegment(id: 7, start: 0, end: 1, text: "Hello", speakerID: "1"),
            ConversationSegment(id: 9, start: 1, end: 1.4, text: " there", speakerID: nil),
            ConversationSegment(id: 12, start: 1.4, end: 2, text: ", friend.", speakerID: "1"),
            ConversationSegment(id: 14, start: 2.2, end: 3, text: " Yes.", speakerID: "2")
        ]
        var transcript = ConversationTranscript(segments: segments, speakerDetectionRequested: true)
        XCTAssertEqual(transcript.readingBlocks.count, 2)
        XCTAssertEqual(transcript.readingBlocks.flatMap(\.segments), segments)
        XCTAssertEqual(transcript.plainText, "Hello there, friend. Yes.")
        XCTAssertEqual(transcript.readingText(for: transcript.readingBlocks[0]), "Hello there, friend.")
        XCTAssertTrue(transcript.formattedText.contains(" there†, friend."))
        XCTAssertFalse(transcript.formattedText.contains("unassigned:"))
        transcript.speakerNames["1"] = "Alice"
        XCTAssertTrue(transcript.formattedText.contains("Alice:"))
        XCTAssertNil(transcript.segments[1].speakerID)
        let reopened = try JSONDecoder().decode(ConversationTranscript.self, from: JSONEncoder().encode(transcript))
        XCTAssertEqual(reopened.formattedText, transcript.formattedText)
    }

    func testReadingBlocksDoNotBridgeSpeakerChangesOrLongPauses() {
        for (nextSpeaker, pause, expected) in [("2", 0.1, 2), ("1", 3.0, 2)] {
            let transcript = ConversationTranscript(segments: [
                .init(id: 0, start: 0, end: 1, text: "One", speakerID: "1"),
                .init(id: 1, start: 1, end: 1.3, text: " unclear", speakerID: nil),
                .init(id: 2, start: 1.3 + pause, end: 5, text: " next", speakerID: nextSpeaker)
            ], speakerDetectionRequested: true)
            XCTAssertEqual(transcript.readingBlocks.count, expected)
            XCTAssertEqual(transcript.readingBlocks.flatMap(\.segments), transcript.segments)
        }
        let unknown = ConversationTranscript(segments: [.init(id: 0, start: 0, end: 1, text: "Unknown", speakerID: nil)], speakerDetectionRequested: true)
        XCTAssertEqual(unknown.readingBlocks.count, 1)
        XCTAssertTrue(unknown.formattedText.contains("Needs review"))
        XCTAssertTrue(unknown.formattedText.contains("Unknown†"))
    }

    func testBriefUncertaintyAtStartMiddleAndEndKeepsReadingFlow() {
        let segments: [ConversationSegment] = [
            .init(id: 0, start: 0, end: 0.2, text: "Well, ", speakerID: nil),
            .init(id: 1, start: 0.2, end: 1, text: "I think", speakerID: "1"),
            .init(id: 2, start: 1, end: 1.2, text: " so.", speakerID: nil),
            .init(id: 3, start: 1.2, end: 2, text: " Yes", speakerID: "2"),
            .init(id: 4, start: 2, end: 2.2, text: ", exactly.", speakerID: nil)
        ]
        let transcript = ConversationTranscript(segments: segments, speakerDetectionRequested: true)
        XCTAssertEqual(transcript.readingBlocks.count, 2)
        XCTAssertEqual(transcript.readingBlocks.map(\.speakerID), ["1", "2"])
        XCTAssertEqual(transcript.readingBlocks.flatMap(\.segments), segments)
        XCTAssertEqual(transcript.readingBlocks.map { transcript.readingText(for: $0) }, ["Well, I think so.", "Yes, exactly."])
        XCTAssertEqual(transcript.segments.map(\.speakerID), [nil, "1", nil, "2", nil])
        XCTAssertTrue(transcript.formattedText.contains("Well,† I think so.†"))
        XCTAssertFalse(transcript.formattedText.contains("Needs review:"))
    }

    func testLongUnknownPassageStaysSeparateAndTextRemainsExact() {
        let segments: [ConversationSegment] = [
            .init(id: 0, start: 0, end: 1, text: "Hello", speakerID: "1"),
            .init(id: 1, start: 1, end: 6, text: " नमस्ते ગુજરાતી 你好 unsure passage here", speakerID: nil),
            .init(id: 2, start: 6, end: 7, text: " again", speakerID: "2")
        ]
        let transcript = ConversationTranscript(segments: segments, speakerDetectionRequested: true)
        XCTAssertEqual(transcript.readingBlocks.count, 3)
        XCTAssertEqual(transcript.readingBlocks.flatMap(\.segments), segments)
        XCTAssertEqual(transcript.plainText, segments.map(\.text).joined())
        XCTAssertTrue(transcript.formattedText.contains("Needs review:"))
    }

    func testSingleSpeakerDecodeSkipsWordAlignmentButKeepsSegmentTimes() {
        let options = WhisperService.conversationDecodingOptions(wordTimestamps: false)
        XCTAssertFalse(options.wordTimestamps)
        XCTAssertFalse(options.withoutTimestamps)
        XCTAssertTrue(options.detectLanguage)
        XCTAssertEqual(options.task, .transcribe)
    }

    func testConversationUsesAutomaticLanguageAndWordTimestamps() {
        let options = WhisperService.conversationDecodingOptions()
        XCTAssertNil(options.language)
        XCTAssertTrue(options.detectLanguage)
        XCTAssertTrue(options.wordTimestamps)
        XCTAssertFalse(options.withoutTimestamps)
        XCTAssertEqual(options.task, .transcribe)
        XCTAssertEqual(options.concurrentWorkerCount, 1)
        XCTAssertTrue(AIModel.availableModels.contains { $0.variant == "openai_whisper-large-v3" })
        XCTAssertTrue(AIModel.availableModels.contains { $0.variant == "openai_whisper-large-v3-v20240930_turbo" })
    }
}

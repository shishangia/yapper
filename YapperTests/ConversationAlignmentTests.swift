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
        XCTAssertTrue(result.formattedText.contains("Speaker uncertain"))
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

    func testConversationUsesAutomaticLanguageAndWordTimestamps() {
        let options = WhisperService.conversationDecodingOptions()
        XCTAssertNil(options.language)
        XCTAssertTrue(options.detectLanguage)
        XCTAssertTrue(options.wordTimestamps)
        XCTAssertFalse(options.withoutTimestamps)
        XCTAssertEqual(options.task, .transcribe)
        XCTAssertEqual(options.concurrentWorkerCount, 1)
        XCTAssertTrue(AIModel.availableModels.contains { $0.variant == "openai_whisper-large-v3" })
        XCTAssertTrue(AIModel.availableModels.contains { $0.variant == "openai_whisper-large-v3_turbo" })
    }
}

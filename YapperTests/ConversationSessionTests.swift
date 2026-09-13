import AVFoundation
import XCTest
@testable import Yapper

@MainActor
private final class WaitingProcessor: ConversationProcessing {
    let started: XCTestExpectation
    var continuation: CheckedContinuation<Void, Never>?

    init(started: XCTestExpectation) { self.started = started }

    func transcribe(_ url: URL, variant: String, language: String, wordTimestamps: Bool, progress: @escaping @Sendable (Double) -> Void) async throws -> [ConversationWord] {
        await withCheckedContinuation {
            continuation = $0
            started.fulfill()
        }
        return [.init(text: "Hello from the test.", start: 0, end: 1)]
    }

    func diarize(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> [ConversationSpeakerTurn] {
        [.init(speakerID: "speaker", start: 0, end: 1)]
    }
}

@MainActor
final class ConversationSessionTests: XCTestCase {
    func testSessionOutlivesItsViewsAndSavesOnce() async throws {
        let suite = "Yapper-Session-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("openai_whisper-large-v3_turbo", forKey: ModelSelection.defaultsKey)
        let history = HistoryService(defaults: defaults)
        let started = expectation(description: "processing started")
        let processor = WaitingProcessor(started: started)
        let session = ConversationSession(service: ConversationService(processor: processor, gate: NativeInferenceGate()), history: history, defaults: defaults)
        let audio = try makeAudio()
        defer { try? FileManager.default.removeItem(at: audio) }
        session.importFile(audio)
        await fulfillment(of: [started], timeout: 3)
        XCTAssertTrue(session.isBusy)
        XCTAssertEqual(session.phase, .processing)
        defaults.set("openai_whisper-tiny", forKey: ModelSelection.defaultsKey)
        XCTAssertEqual(session.activeModel, "openai_whisper-large-v3_turbo")
        processor.continuation?.resume()
        await session.waitUntilFinished()
        XCTAssertEqual(session.phase, .completed)
        XCTAssertEqual(history.items.count, 1)
        XCTAssertEqual(history.statsEntries.count, 1)
        let item = try XCTUnwrap(history.items.first)
        XCTAssertEqual(item.modelUsed, "Whisper Large v3 Turbo")
        history.addConversation(try XCTUnwrap(item.conversation), duration: 1, id: item.id)
        XCTAssertEqual(history.items.count, 1)
        XCTAssertEqual(history.statsEntries.count, 1)
        XCTAssertEqual(session.resultID, item.id)
    }

    func testCancelRemainsPendingUntilInferenceFinishes() async throws {
        let suite = "Yapper-Session-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("openai_whisper-large-v3_turbo", forKey: ModelSelection.defaultsKey)
        let history = HistoryService(defaults: defaults)
        let started = expectation(description: "processing started")
        let processor = WaitingProcessor(started: started)
        let session = ConversationSession(service: ConversationService(processor: processor, gate: NativeInferenceGate()), history: history, defaults: defaults)
        let audio = try makeAudio()
        defer { try? FileManager.default.removeItem(at: audio) }
        session.importFile(audio)
        await fulfillment(of: [started], timeout: 3)
        session.cancel()
        XCTAssertEqual(session.phase, .canceling)
        XCTAssertNil(session.message)
        XCTAssertTrue(session.isBusy)
        processor.continuation?.resume()
        await session.waitUntilFinished()
        XCTAssertEqual(session.phase, .canceled)
        XCTAssertFalse(session.isBusy)
        XCTAssertTrue(history.items.isEmpty)
        XCTAssertTrue(history.statsEntries.isEmpty)
    }

    private func makeAudio() throws -> URL {
        let root = AppEnvironment.applicationSupportDirectory
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("\(UUID().uuidString).wav")
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000))
        buffer.frameLength = 16000
        buffer.floatChannelData![0].initialize(repeating: 0, count: 16000)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }
}

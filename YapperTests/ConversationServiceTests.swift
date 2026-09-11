import XCTest
@testable import Yapper

@MainActor
private final class ControlledConversationProcessor: ConversationProcessing {
    var words = [ConversationWord(text: " um German", start: 0, end: 1)]
    var turns = [ConversationSpeakerTurn(speakerID: "a", start: 0, end: 1)]
    var transcribeError: Error?
    var diarizeError: Error?
    var transcriptionStarted: XCTestExpectation?
    var diarizationStarted: XCTestExpectation?
    var holdTranscription = false
    var holdDiarization = false
    var release: CheckedContinuation<Void, Never>?
    var diarizationCount = 0

    func transcribe(_ url: URL, language: String, progress: @escaping @Sendable (Double) -> Void) async throws -> [ConversationWord] {
        transcriptionStarted?.fulfill()
        if holdTranscription { await withCheckedContinuation { release = $0 } }
        if let transcribeError { throw transcribeError }
        progress(1)
        return words
    }

    func diarize(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> [ConversationSpeakerTurn] {
        diarizationCount += 1
        diarizationStarted?.fulfill()
        if holdDiarization { await withCheckedContinuation { release = $0 } }
        if let diarizeError { throw diarizeError }
        return turns
    }
}

@MainActor
final class ConversationServiceTests: XCTestCase {
    private let audio = URL(fileURLWithPath: "/unused-test-fixture.wav")

    func testSuccessAndDiarizationDisabled() async throws {
        let processor = ControlledConversationProcessor()
        let service = ConversationService(processor: processor, gate: NativeInferenceGate())
        let result = try await service.process(audio, detectSpeakers: true)
        XCTAssertEqual(result.plainText, " um German")
        XCTAssertEqual(result.speakerIDs, ["1"])
        XCTAssertFalse(service.isProcessing)
        let unlabeled = try await service.process(audio, detectSpeakers: false)
        XCTAssertFalse(unlabeled.speakerDetectionRequested)
        XCTAssertEqual(unlabeled.plainText, result.plainText)
        XCTAssertEqual(processor.diarizationCount, 1)
    }

    func testSpeakerFailurePreservesUnlabeledTranscript() async throws {
        let processor = ControlledConversationProcessor()
        processor.diarizeError = ConversationError.invalidSpeakerModels
        let service = ConversationService(processor: processor, gate: NativeInferenceGate())
        let result = try await service.process(audio, detectSpeakers: true)
        XCTAssertEqual(result.plainText, " um German")
        XCTAssertTrue(result.speakerIDs.isEmpty)
        XCTAssertTrue(result.warning?.contains("full unlabeled transcript was kept") == true)
        XCTAssertFalse(service.isProcessing)
    }

    func testTranscriptionFailureAndSilence() async throws {
        let processor = ControlledConversationProcessor()
        processor.transcribeError = ConversationError.invalidAudio
        let service = ConversationService(processor: processor, gate: NativeInferenceGate())
        do {
            _ = try await service.process(audio, detectSpeakers: true)
            XCTFail("Expected the transcription error")
        } catch { XCTAssertFalse(service.isProcessing) }
        processor.transcribeError = nil
        processor.words = []
        let result = try await service.process(audio, detectSpeakers: true)
        XCTAssertTrue(result.segments.isEmpty)
        XCTAssertEqual(processor.diarizationCount, 0)
    }

    func testCancellationWaitsForNativeInferenceAndRejectsAnotherJob() async throws {
        for duringDiarization in [false, true] {
            let processor = ControlledConversationProcessor()
            let started = expectation(description: "native inference started")
            processor.holdTranscription = !duringDiarization
            processor.holdDiarization = duringDiarization
            if duringDiarization { processor.diarizationStarted = started }
            else { processor.transcriptionStarted = started }
            let gate = NativeInferenceGate()
            let service = ConversationService(processor: processor, gate: gate)
            let task = Task { try await service.process(audio, detectSpeakers: true) }
            await fulfillment(of: [started], timeout: 3)
            service.cancel()
            XCTAssertTrue(service.isProcessing)
            XCTAssertTrue(service.cancellationRequested)
            do {
                _ = try await service.process(audio, detectSpeakers: false)
                XCTFail("Must reject overlapping job")
            } catch { XCTAssertEqual(error.localizedDescription, ConversationError.busy.localizedDescription) }
            var nextInferenceStarted = false
            let next = Task { await gate.run { nextInferenceStarted = true } }
            await Task.yield()
            XCTAssertFalse(nextInferenceStarted)
            processor.release?.resume()
            processor.release = nil
            do {
                _ = try await task.value
                XCTFail("Canceled results must be discarded")
            } catch { XCTAssertEqual(error.localizedDescription, ConversationError.cancelled.localizedDescription) }
            await next.value
            XCTAssertTrue(nextInferenceStarted)
            XCTAssertFalse(service.isProcessing)
            XCTAssertEqual(processor.diarizationCount, duringDiarization ? 1 : 0)
        }
    }

    func testSingleSpeakerBypassesDiarizerWithoutChangingText() async throws {
        let processor = ControlledConversationProcessor()
        processor.words.append(.init(text: " again", start: 3, end: 4, hasReliableTiming: false))
        let service = ConversationService(processor: processor, gate: NativeInferenceGate())
        let result = try await service.process(audio, detectSpeakers: true, singleSpeaker: true)
        XCTAssertEqual(result.plainText, " um German again")
        XCTAssertEqual(result.segments.map(\.speakerID), ["1", "1"])
        XCTAssertEqual(processor.diarizationCount, 0)
        XCTAssertTrue(result.speakerDetectionRequested)
    }

    func testMissingModelsFailWithoutDownload() async throws {
        XCTAssertTrue(AppEnvironment.usesIsolatedStorage)
        XCTAssertFalse(LocalConversationProcessor.transcriptionModelsReady)
        let processor = LocalConversationProcessor()
        do {
            _ = try await processor.transcribe(audio, language: "auto") { _ in }
            XCTFail("Missing models must not trigger a download")
        } catch { XCTAssertEqual(error.localizedDescription, ConversationError.modelsMissing.localizedDescription) }
    }
}

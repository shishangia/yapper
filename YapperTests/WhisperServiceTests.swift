import XCTest
import FluidAudio
import WhisperKit
@testable import Yapper

@MainActor
private final class StubSpeechEngine: SpeechToTextEngine {
    var isInitialized = false
    var isLoading = false
    var isTranscribing = false
    var loadingStage = ""
    var currentModelVariant = ""
    var structuredCalls = 0
    var failLoad = false
    func loadModel(variant: String) async throws {
        if failLoad { throw ConversationError.modelsMissing }
        currentModelVariant = variant
        isInitialized = true
    }
    func unload() async { isInitialized = false; currentModelVariant = "" }
    func transcribe(audioFile: URL, language: String) async throws -> String { "raw words" }
    func transcribeConversation(audioFile: URL, language: String, wordTimestamps: Bool, progress: @escaping @Sendable (Double) -> Void) async throws -> [ConversationWord] {
        structuredCalls += 1
        return [.init(text: " raw words", start: 0, end: 1)]
    }
}

@MainActor
final class WhisperServiceTests: XCTestCase {
    
    var service: WhisperService?
    
    override func setUpWithError() throws {
        service = WhisperService()
    }

    override func tearDownWithError() throws {
        // Rely on automatic deallocation
    }

    func testModelLanguagesAndTokenizerMapping() throws {
        let turbo = try XCTUnwrap(AIModel.availableModels.first { $0.variant == "openai_whisper-large-v3_turbo" })
        XCTAssertTrue(turbo.supports(language: "hi"))
        XCTAssertTrue(turbo.supports(language: "mixed"))
        XCTAssertEqual(ModelStorage.whisperVariant(for: turbo.variant)?.description, "large-v3")
        let english = try XCTUnwrap(AIModel.availableModels.first { $0.variant == "openai_whisper-small.en" })
        XCTAssertFalse(english.supports(language: "hi"))
        XCTAssertTrue(english.supports(language: "auto"))
        XCTAssertEqual(ModelStorage.whisperVariant(for: english.variant)?.description, "small.en")
        let parakeet = try XCTUnwrap(AIModel.availableModels.first { $0.variant == ParakeetCatalog.v3Variant })
        XCTAssertTrue(parakeet.supports(language: "fr"))
        XCTAssertFalse(parakeet.supports(language: "gu"))
        XCTAssertThrowsError(try TranscriptionManager.validate(variant: parakeet.variant, language: "zh"))
        XCTAssertThrowsError(try TranscriptionManager.validate(variant: "", language: "auto"))
    }

    func testParakeetTimingsPreserveUnmatchedText() {
        let result = ASRResult(text: "Hello, bright world!", confidence: 1, duration: 0, processingTime: 1,
            tokenTimings: [.init(token: "Hello", tokenId: 1, startTime: 0, endTime: 0.5, confidence: 1),
                           .init(token: "world", tokenId: 2, startTime: 2, endTime: 2.5, confidence: 1)])
        let words = ParakeetEngine.words(from: result, duration: 3)
        XCTAssertEqual(words.map(\.text).joined(), result.text)
        XCTAssertTrue(words.contains { !$0.hasReliableTiming })
        XCTAssertTrue(words.contains { $0.hasReliableTiming })
        let missing = ASRResult(text: "No timing", confidence: 1, duration: 2, processingTime: 1)
        XCTAssertEqual(ParakeetEngine.words(from: missing, duration: 2).map(\.text).joined(), "No timing")
        XCTAssertFalse(ParakeetEngine.words(from: missing, duration: 2)[0].hasReliableTiming)
    }

    func testSharedEngineReusesAndReleasesModels() async throws {
        let whisper = StubSpeechEngine()
        let parakeet = StubSpeechEngine()
        let gate = NativeInferenceGate()
        let manager = TranscriptionManager(whisper: whisper, parakeet: parakeet, gate: gate)
        let url = URL(fileURLWithPath: "/unused.wav")
        _ = try await gate.run {
            try await manager.transcribeConversationWhileLocked(audioFile: url, variant: "openai_whisper-large-v3_turbo", language: "auto") { _ in }
        }
        XCTAssertEqual(whisper.currentModelVariant, "openai_whisper-large-v3_turbo")
        XCTAssertEqual(whisper.structuredCalls, 1)
        _ = try await gate.run {
            try await manager.transcribeConversationWhileLocked(audioFile: url, variant: ParakeetCatalog.v3Variant, language: "en") { _ in }
        }
        XCTAssertFalse(whisper.isInitialized)
        XCTAssertEqual(parakeet.structuredCalls, 1)
        XCTAssertEqual(manager.currentModelVariant, ParakeetCatalog.v3Variant)
        parakeet.failLoad = true
        do { try await manager.loadModel(variant: ParakeetCatalog.v2Variant); XCTFail("Expected failure") }
        catch { XCTAssertFalse(manager.isInitialized) }
    }

    func testNativeWhisperAndParakeetUseIsolatedCopies() async throws {
        guard ProcessInfo.processInfo.environment["YAPPER_NATIVE_TESTS"] == "1" else {
            throw XCTSkip("Opt-in local model smoke test")
        }
        let fm = FileManager.default
        let home = URL(fileURLWithPath: String(cString: getpwuid(getuid()).pointee.pw_dir))
        let fixtures = home.appendingPathComponent("Library/Application Support/Yapper-Dev")
        let root = AppEnvironment.applicationSupportDirectory.appendingPathComponent("NativeSmoke")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let audio = root.appendingPathComponent("conversation.wav")
        try fm.copyItem(at: fixtures.appendingPathComponent("TestAudio/conversation.wav"), to: audio)
        let directories = ["models", "SpeechModels", "FluidAudio"]
        defer {
            for name in directories { try? fm.removeItem(at: AppEnvironment.applicationSupportDirectory.appendingPathComponent(name)) }
        }
        for name in directories {
            let destination = AppEnvironment.applicationSupportDirectory.appendingPathComponent(name)
            XCTAssertFalse(fm.fileExists(atPath: destination.path))
            try fm.copyItem(at: fixtures.appendingPathComponent(name), to: destination)
        }
        let manager = TranscriptionManager.shared
        for variant in ["openai_whisper-large-v3_turbo", ParakeetCatalog.v3Variant] {
            let words = try await NativeInferenceGate.shared.run {
                try await manager.transcribeConversationWhileLocked(audioFile: audio, variant: variant, language: "en") { _ in }
            }
            XCTAssertFalse(words.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertTrue(words.contains { $0.hasReliableTiming })
            XCTAssertEqual(manager.currentModelVariant, variant)
        }
        await NativeInferenceGate.shared.run { await manager.unloadWhileLocked(variant: ParakeetCatalog.v3Variant) }
    }

    func testDefaultInitialization() {
        guard let service = service else { return XCTFail("Service should be initialized") }
        XCTAssertFalse(service.isInitialized)
        XCTAssertEqual(service.currentModelVariant, "")
    }
    
    // Note: detailed loadModel tests require mocking the WhisperKit dependency
    // which is external. We test the state management around it.
    
    func testStateFlags() {
        guard let service = service else { return XCTFail("Service should be initialized") }
        XCTAssertFalse(service.isTranscribing)
        // Simulate transcription start
        service.isTranscribing = true
        XCTAssertTrue(service.isTranscribing)
    }

    func testNormalizedTranscriptionRemovesBlankAudioPlaceholders() {
        let normalized = WhisperService.normalizedTranscription(
            from: " [BLANK_AUDIO]  hello   <|nospeech|> [SILENCE] "
        )

        XCTAssertEqual(normalized, "hello")
    }

    func testNormalizedTranscriptionRemovesBracketedNoiseLabels() {
        let normalized = WhisperService.normalizedTranscription(
            from: "[wind blowing] (heartbeat) answer [S]"
        )

        XCTAssertEqual(normalized, "answer")
    }

    func testNormalizedTranscriptionRemovesNoiseOnlyArtifacts() {
        let normalized = WhisperService.normalizedTranscription(
            from: "[wind] (Loud noise) (indistinct)"
        )

        XCTAssertEqual(normalized, "")
    }
}

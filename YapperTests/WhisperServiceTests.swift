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
    var loads: [String] = []
    var onUnload: (() async -> Void)?
    func loadModel(variant: String) async throws {
        loads.append(variant)
        if failLoad { throw ConversationError.modelsMissing }
        currentModelVariant = variant
        isInitialized = true
    }
    func unload() async { await onUnload?(); isInitialized = false; currentModelVariant = "" }
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
        let turbo = try XCTUnwrap(AIModel.availableModels.first { $0.name == "Whisper Large v3 Turbo" })
        XCTAssertEqual(turbo.variant, "openai_whisper-large-v3-v20240930_turbo")
        XCTAssertTrue(turbo.supports(language: "hi"))
        XCTAssertTrue(turbo.supports(language: "mixed"))
        XCTAssertEqual(ModelStorage.whisperVariant(for: turbo.variant)?.description, "large-v3")
        let legacy = try XCTUnwrap(AIModel.availableModels.first { $0.variant == "openai_whisper-large-v3_turbo" })
        XCTAssertTrue(legacy.isLegacy)
        XCTAssertNotEqual(AIModel.recommendedModel(for: .current, useCase: .dictation).variant, legacy.variant)
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

    func testWarmupDeduplicatesAndRechecksSelectionAfterUnload() async throws {
        let whisper = StubSpeechEngine()
        var selection = "openai_whisper-large-v3_turbo"
        let manager = TranscriptionManager(whisper: whisper, parakeet: StubSpeechEngine(), gate: NativeInferenceGate(),
            selectedVariant: { selection }, modelReady: { _ in true })
        var resume: CheckedContinuation<Void, Never>?
        let unloading = expectation(description: "Unload suspended")
        whisper.onUnload = {
            await withCheckedContinuation { resume = $0; unloading.fulfill() }
        }
        let first = manager.warmSelectedModel()
        let joined = manager.warmSelectedModel()
        await fulfillment(of: [unloading], timeout: 2)
        selection = ParakeetCatalog.v3Variant
        whisper.onUnload = nil
        let latest = manager.warmSelectedModel()
        resume?.resume()
        await first?.value
        await joined?.value
        await latest?.value
        XCTAssertTrue(whisper.loads.isEmpty)
        XCTAssertEqual(manager.currentModelVariant, selection)
        XCTAssertNil(manager.warmingVariant)
        await manager.warmSelectedModel()?.value
    }

    func testWarmupWaitsForInferenceAndSkipsMissingOrDeselectedModel() async throws {
        let whisper = StubSpeechEngine()
        let gate = NativeInferenceGate()
        var selection = "openai_whisper-large-v3_turbo"
        let manager = TranscriptionManager(whisper: whisper, parakeet: StubSpeechEngine(), gate: gate,
            selectedVariant: { selection }, modelReady: { !$0.isEmpty })
        let occupied = expectation(description: "Gate occupied")
        var resume: CheckedContinuation<Void, Never>?
        let active = Task { await gate.run { await withCheckedContinuation { resume = $0; occupied.fulfill() } } }
        await fulfillment(of: [occupied], timeout: 2)
        let warm = manager.warmSelectedModel()
        await Task.yield()
        XCTAssertTrue(whisper.loads.isEmpty)
        selection = ""
        XCTAssertNil(manager.warmSelectedModel())
        resume?.resume()
        await active.value
        await warm?.value
        XCTAssertTrue(whisper.loads.isEmpty)
        XCTAssertEqual(selection, "")
    }

    func testReselectingResidentModelDuringUnloadQueuesItsWarmup() async throws {
        let whisper = StubSpeechEngine()
        let parakeet = StubSpeechEngine()
        let turbo = "openai_whisper-large-v3_turbo"
        let selection = NSMutableString(string: turbo)
        let manager = TranscriptionManager(whisper: whisper, parakeet: parakeet, gate: NativeInferenceGate(),
            selectedVariant: { selection as String }, modelReady: { _ in true })
        try await manager.loadModel(variant: turbo)
        let unloading = expectation(description: "Resident model unloading")
        var resume: CheckedContinuation<Void, Never>?
        whisper.onUnload = { await withCheckedContinuation { resume = $0; unloading.fulfill() } }
        selection.setString(ParakeetCatalog.v3Variant)
        let obsolete = manager.warmSelectedModel()
        await fulfillment(of: [unloading], timeout: 2)
        selection.setString(turbo)
        let latest = manager.warmSelectedModel()
        XCTAssertNotNil(latest)
        whisper.onUnload = nil
        resume?.resume()
        await obsolete?.value
        await latest?.value
        XCTAssertTrue(parakeet.loads.isEmpty)
        XCTAssertTrue(manager.isInitialized)
        XCTAssertEqual(manager.currentModelVariant, turbo)
    }

    func testDictationPunctuationIsConservativeAndOptional() {
        for (original, expected) in ["hello.": "hello", "42.": "42", "3.14.": "3.14",
            "me@example.com.": "me@example.com", "https://example.com/path.": "https://example.com/path",
            "www.example.com.": "www.example.com", "  hello.\n": "  hello\n"] {
            XCTAssertEqual(DictationPunctuation.apply(to: original, enabled: true), expected)
            XCTAssertEqual(DictationPunctuation.apply(to: original, enabled: false), original)
        }
        for original in ["A full sentence.", "Wait...", "Really?", "Yes!", "U.S.", "e.g.", ".", "", "hello.world.", "Hello. Goodbye."] {
            XCTAssertEqual(DictationPunctuation.apply(to: original, enabled: true), original)
        }
    }

    func testAutomaticLanguageDetectionIsExplicitForMultilingualWhisper() {
        let automatic = WhisperService.dictationDecodingOptions(language: "auto")
        XCTAssertNil(automatic.language)
        XCTAssertTrue(automatic.detectLanguage)
        let selected = WhisperService.dictationDecodingOptions(language: "zh")
        XCTAssertEqual(selected.language, "zh")
        XCTAssertFalse(selected.detectLanguage)
        let englishOnly = WhisperService.dictationDecodingOptions(language: "auto", englishOnly: true)
        XCTAssertEqual(englishOnly.language, "en")
        XCTAssertFalse(englishOnly.detectLanguage)
    }

    func testSharedDictationCleanupFormatsExplicitCommands() {
        let raw = "um this is a sentence. another one new paragraph bullet point apples bullet point bananas"
        XCTAssertEqual(DictationCleanup.apply(to: raw, enabled: true),
            "This is a sentence. Another one\n\n• Apples\n• Bananas")
        XCTAssertEqual(DictationCleanup.apply(
            to: "shopping list number one milk number two eggs number three tea", enabled: true),
            "Shopping list\n1. Milk\n2. Eggs\n3. Tea")
        XCTAssertEqual(DictationCleanup.apply(to: "first idea scratch that corrected idea", enabled: true),
            "Corrected idea")
        XCTAssertEqual(DictationCleanup.apply(to: "Keep this sentence. wrong words scratch that corrected words", enabled: true),
            "Keep this sentence. Corrected words")
    }

    func testCleanupDoesNotGuessAmbiguousFillersOrLists() {
        let text = "i like this, you know number one reason"
        XCTAssertEqual(DictationCleanup.apply(to: text, enabled: true),
            "I like this, you know number one reason")
        XCTAssertEqual(DictationCleanup.apply(to: text, enabled: false), text)
        XCTAssertEqual(DictationCleanup.apply(to: "visit https://example.com next", enabled: true),
            "Visit https://example.com next")
        XCTAssertEqual(DictationCleanup.apply(to: "me@example.com works on iPhone", enabled: true),
            "me@example.com works on iPhone")
        XCTAssertEqual(DictationCleanup.apply(to: "hello ગુજરાતી 你好", enabled: true),
            "Hello ગુજરાતી 你好")
    }

    func testDetailedDictationSharesCleanupAcrossEnginesAndReportsTiming() async throws {
        let whisper = StubSpeechEngine()
        let parakeet = StubSpeechEngine()
        let manager = TranscriptionManager(whisper: whisper, parakeet: parakeet,
            gate: NativeInferenceGate(), autoEditEnabled: { true })
        let output = try await manager.transcribeDetailed(audioFile: URL(fileURLWithPath: "/unused.wav"),
            variant: "openai_whisper-large-v3_turbo", language: "auto")
        XCTAssertEqual(output.text, "Raw words")
        XCTAssertGreaterThanOrEqual(output.timing.queue, 0)
        XCTAssertGreaterThanOrEqual(output.timing.modelPreparation, 0)
        XCTAssertGreaterThanOrEqual(output.timing.inference, 0)
        XCTAssertGreaterThanOrEqual(output.timing.cleanup, 0)
        XCTAssertGreaterThanOrEqual(output.timing.total, output.timing.inference)

        let parakeetOutput = try await manager.transcribeDetailed(
            audioFile: URL(fileURLWithPath: "/unused.wav"), variant: ParakeetCatalog.v3Variant, language: "en")
        XCTAssertEqual(parakeetOutput.text, "Raw words")
        XCTAssertEqual(manager.currentModelVariant, ParakeetCatalog.v3Variant)
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

    func testNormalizedTranscriptionPreservesParagraphBreaks() {
        let normalized = WhisperService.normalizedTranscription(
            from: " first line  \n \n \n second line "
        )
        XCTAssertEqual(normalized, "first line\n\nsecond line")
    }
}

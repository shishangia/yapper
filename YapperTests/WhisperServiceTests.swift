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
    var preferredWords: [String]?
    func setPreferredWords(_ words: [String]) { preferredWords = words }
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
    func testIdleModelsUnloadAndRecordingKeepsThemResident() async throws {
        let whisper = StubSpeechEngine()
        let manager = TranscriptionManager(whisper: whisper, parakeet: StubSpeechEngine(), gate: NativeInferenceGate(),
            selectedVariant: { "openai_whisper-large-v3" }, modelReady: { _ in true }, idleDelay: { 0.03 })
        try await manager.loadModel(variant: "openai_whisper-large-v3")
        let recording = UUID()
        manager.beginRecording(recording)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(whisper.isInitialized)
        manager.endRecording(recording)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertFalse(whisper.isInitialized)
        try await manager.loadModel(variant: "openai_whisper-large-v3")
        XCTAssertTrue(whisper.isInitialized)
        XCTAssertEqual(whisper.loads.count, 2)
    }

    func testPreviewDoesNotPromptWithPreferredWords() async throws {
        let whisper = StubSpeechEngine()
        whisper.preferredWords = ["stale"]
        let manager = TranscriptionManager(whisper: whisper, parakeet: StubSpeechEngine(), gate: NativeInferenceGate(),
            modelReady: { _ in true }, idleDelay: { 0 })
        _ = try await manager.preview(audioFile: URL(fileURLWithPath: "/unused"),
            variant: "openai_whisper-large-v3", language: "en", isCurrent: { true })
        XCTAssertEqual(whisper.preferredWords, [])
    }

    func testVocabularyAndSmartCleanupSafety() {
        XCTAssertEqual(DictationPreferences.normalizeWords(" Yapper \nYAPPER\n  work   station \n"), ["Yapper", "work station"])
        XCTAssertFalse(AppleDictationCleanup.acceptable("Pay 123", original: "Pay 12"))
        XCTAssertFalse(AppleDictationCleanup.acceptable("Pay 12", original: "Pay 12 and 12"))
        XCTAssertFalse(AppleDictationCleanup.acceptable("", original: "important text"))
        XCTAssertTrue(AppleDictationCleanup.acceptable("Pay 12.50 tomorrow.", original: "um pay 12.50 tomorrow"))
    }

    func testSmartCleanupKeepsOriginalAndFallsBackWithoutLosingDictation() async throws {
        let manager = TranscriptionManager(whisper: StubSpeechEngine(), parakeet: StubSpeechEngine(), gate: NativeInferenceGate(),
            autoEditEnabled: { true }, idleDelay: { 0 }, smartCleanup: { raw in
                XCTAssertEqual(raw, "raw words")
                return "Edited words"
            })
        let result = try await manager.transcribeDetailed(audioFile: URL(fileURLWithPath: "/unused"), variant: "openai_whisper-large-v3", language: "en")
        XCTAssertEqual(result.text, "Edited words")
        XCTAssertEqual(result.rawText, "raw words")
        let unavailable = TranscriptionManager(whisper: StubSpeechEngine(), parakeet: StubSpeechEngine(), gate: NativeInferenceGate(),
            autoEditEnabled: { true }, idleDelay: { 0 }, smartCleanup: { _ in throw AppleDictationCleanup.CleanupError.unavailable })
        let fallback = try await unavailable.transcribeDetailed(audioFile: URL(fileURLWithPath: "/unused"), variant: "openai_whisper-large-v3", language: "en")
        XCTAssertEqual(fallback.text, "Raw words")
        XCTAssertEqual(fallback.rawText, "raw words")
        XCTAssertNotNil(fallback.cleanupNote)
    }
    
    var service: WhisperService?
    
    override func setUpWithError() throws {
        service = WhisperService()
    }

    override func tearDownWithError() throws {
        // Rely on automatic deallocation
    }

    func testModelLanguagesAndTokenizerMapping() throws {
        let hinglish = try XCTUnwrap(AIModel.availableModels.first { $0.variant == AIModel.hinglishVariant })
        XCTAssertTrue(hinglish.isHinglish)
        XCTAssertTrue(hinglish.supports(language: "auto"))
        XCTAssertTrue(hinglish.supports(language: "hi"))
        XCTAssertFalse(hinglish.supports(language: "zh"))
        XCTAssertEqual(ModelStorage.whisperVariant(for: hinglish.variant)?.description, "large-v3")
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

    func testWholeRangeAssignmentMetadataSurvivesTextPreservation() {
        let words = ConversationAlignment.preservingText(
            " whole phrase",
            words: [.init(text: " whole phrase", start: 1, end: 2,
                hasReliableTiming: false, allowsWholeRangeAssignment: true)],
            start: 1, end: 2)
        XCTAssertEqual(words.count, 1)
        XCTAssertFalse(words[0].hasReliableTiming)
        XCTAssertTrue(words[0].allowsWholeRangeAssignment)
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
        let hinglish = WhisperService.dictationDecodingOptions(language: "hinglish")
        XCTAssertEqual(hinglish.language, "en")
        XCTAssertFalse(hinglish.detectLanguage)
    }

    func testRegisteredDefaultsKeepUpgradersAndExplicitChoices() throws {
        func profile(_ values: [String: Any]) throws -> (UserDefaults, String) {
            let suite = "Yapper-Model-Defaults-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            values.forEach { defaults.set($1, forKey: $0) }
            ModelSelection.registerDefaults(defaults, domain: suite)
            return (defaults, suite)
        }

        let (fresh, freshSuite) = try profile([:])
        defer { fresh.removePersistentDomain(forName: freshSuite) }
        XCTAssertEqual(fresh.string(forKey: "transcriptionLanguage"), "hinglish")
        XCTAssertTrue(fresh.bool(forKey: "enableAutoEdit"))
        XCTAssertNil(fresh.persistentDomain(forName: freshSuite)?["transcriptionLanguage"])
        // Finishing onboarding after the first launch must not turn a fresh install into an upgrader.
        fresh.set(true, forKey: "hasCompletedOnboarding")
        ModelSelection.registerDefaults(fresh, domain: freshSuite)
        XCTAssertEqual(fresh.string(forKey: "transcriptionLanguage"), "hinglish")

        let (upgrader, upgraderSuite) = try profile(
            ["hasCompletedOnboarding": true, ModelSelection.defaultsKey: "openai_whisper-large-v3"])
        defer { upgrader.removePersistentDomain(forName: upgraderSuite) }
        XCTAssertEqual(upgrader.string(forKey: "transcriptionLanguage"), "auto")
        XCTAssertFalse(upgrader.bool(forKey: "enableAutoEdit"))
        XCTAssertEqual(upgrader.string(forKey: ModelSelection.defaultsKey), "openai_whisper-large-v3")
        XCTAssertEqual(ModelSelection.selectedVariant(upgrader), "openai_whisper-large-v3")

        let (explicit, explicitSuite) = try profile(["hasCompletedOnboarding": true,
            "transcriptionLanguage": "hinglish", "enableAutoEdit": true])
        defer { explicit.removePersistentDomain(forName: explicitSuite) }
        XCTAssertEqual(explicit.string(forKey: "transcriptionLanguage"), "hinglish")
        XCTAssertTrue(explicit.bool(forKey: "enableAutoEdit"))

        XCTAssertEqual(ModelSelection.resolvedVariant("openai_whisper-large-v3", language: "hinglish"),
            AIModel.hinglishVariant)
        XCTAssertEqual(ModelSelection.resolvedVariant("openai_whisper-large-v3", language: "zh"),
            "openai_whisper-large-v3")
    }

    func testImplicitHinglishUpgradeDoesNotCreateAnEmptyModelSelection() throws {
        for selection in [nil, "", AIModel.hinglishVariant] as [String?] {
            let suite = "Yapper-Hinglish-Upgrade-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(true, forKey: "hasCompletedOnboarding")
            if let selection { defaults.set(selection, forKey: ModelSelection.defaultsKey) }
            // This is the saved state of 1.1.1 after using its implicit Hinglish model.
            defaults.set(Data("[]".utf8), forKey: "history_items")
            ModelSelection.registerDefaults(defaults, domain: suite)
            XCTAssertEqual(defaults.string(forKey: "transcriptionLanguage"), "hinglish")
            XCTAssertTrue(defaults.bool(forKey: "enableAutoEdit"))
            XCTAssertEqual(ModelSelection.selectedVariant(defaults), AIModel.hinglishVariant)
            ModelSelection.registerDefaults(defaults, domain: suite)
            XCTAssertEqual(ModelSelection.selectedVariant(defaults), AIModel.hinglishVariant)
        }
    }

    func testStrandedAutoRepairsToHinglishOnlyWithoutAGeneralModel() throws {
        func profile(selected: String?, hinglishReady: Bool) throws -> (UserDefaults, String) {
            let suite = "Yapper-Stranded-Auto-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
            // The saved state after 1.1.2's first migration ran on a fresh 1.1.1 install.
            defaults.set(true, forKey: "hasCompletedOnboarding")
            defaults.set(true, forKey: "didKeepLegacyLanguageDefaults")
            defaults.set("auto", forKey: "transcriptionLanguage")
            defaults.set(false, forKey: "enableAutoEdit")
            if let selected { defaults.set(selected, forKey: ModelSelection.defaultsKey) }
            ModelSelection.registerDefaults(defaults, domain: suite, hinglishReady: { hinglishReady })
            return (defaults, suite)
        }

        let (stranded, strandedSuite) = try profile(selected: nil, hinglishReady: true)
        XCTAssertEqual(stranded.string(forKey: "transcriptionLanguage"), "hinglish")
        XCTAssertEqual(ModelSelection.selectedVariant(stranded), AIModel.hinglishVariant)
        XCTAssertFalse(stranded.bool(forKey: "enableAutoEdit"))
        // One time only: a later explicit Auto choice is kept.
        stranded.set("auto", forKey: "transcriptionLanguage")
        ModelSelection.registerDefaults(stranded, domain: strandedSuite, hinglishReady: { true })
        XCTAssertEqual(stranded.string(forKey: "transcriptionLanguage"), "auto")

        XCTAssertEqual(try profile(selected: "", hinglishReady: true).0.string(forKey: "transcriptionLanguage"), "hinglish")
        XCTAssertEqual(try profile(selected: nil, hinglishReady: false).0.string(forKey: "transcriptionLanguage"), "auto")
        XCTAssertEqual(try profile(selected: AIModel.hinglishVariant, hinglishReady: true).0.string(forKey: "transcriptionLanguage"), "auto")
        let (general, _) = try profile(selected: "openai_whisper-large-v3", hinglishReady: true)
        XCTAssertEqual(general.string(forKey: "transcriptionLanguage"), "auto")
        XCTAssertEqual(ModelSelection.selectedVariant(general), "openai_whisper-large-v3")
    }

    func testSharedMacAndWindowsCleanupContract() throws {
        struct Example: Decodable { let input: String; let expected: String }
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../Tests/Fixtures/dictation-cleanup.json")
        let examples = try JSONDecoder().decode([Example].self, from: Data(contentsOf: path))
        for example in examples {
            XCTAssertEqual(DictationCleanup.apply(to: example.input, enabled: true), example.expected, example.input)
            XCTAssertEqual(DictationCleanup.apply(to: example.input, enabled: false), example.input)
        }
    }

    func testSharedDictationCleanupFormatsExplicitCommands() {
        let raw = "um this is a sentence. another one, new paragraph, bullet point apples bullet point bananas"
        XCTAssertEqual(DictationCleanup.apply(to: raw, enabled: true),
            "This is a sentence. Another one\n\n• Apples\n• Bananas")
        XCTAssertEqual(DictationCleanup.apply(
            to: "shopping list number one milk number two eggs number three tea", enabled: true),
            "Shopping list\n1. Milk\n2. Eggs\n3. Tea")
        XCTAssertEqual(DictationCleanup.apply(to: "first idea, scratch that, corrected idea", enabled: true),
            "Corrected idea")
        XCTAssertEqual(DictationCleanup.apply(to: "Keep this sentence. wrong words, scratch that. corrected words", enabled: true),
            "Keep this sentence. Corrected words")
    }

    func testCleanupCommandsRequireTheirOwnClause() {
        XCTAssertEqual(DictationCleanup.apply(to: "I need to scratch that itch", enabled: true),
            "I need to scratch that itch")
        XCTAssertEqual(DictationCleanup.apply(to: "we launched a new line of shoes", enabled: true),
            "We launched a new line of shoes")
        XCTAssertEqual(DictationCleanup.apply(to: "we need a new paragraph for this", enabled: true),
            "We need a new paragraph for this")
        XCTAssertEqual(DictationCleanup.apply(to: "first line. New line. second line", enabled: true),
            "First line.\nSecond line")
        XCTAssertEqual(DictationCleanup.apply(to: "Scratch that. Start over", enabled: true), "Start over")
        XCTAssertEqual(DictationCleanup.apply(to: "Keep this. Wrong words. Scratch that. Right words.", enabled: true),
            "Keep this. Right words.")
        XCTAssertEqual(DictationCleanup.apply(to: "first idea, scratch that", enabled: true), "")
        XCTAssertEqual(DictationCleanup.apply(to: "email foo@example.com scratch that", enabled: true),
            "Email foo@example.com scratch that")
        XCTAssertEqual(DictationCleanup.apply(
            to: "Write to foo@example.com. Wrong address, scratch that, use bar@example.com", enabled: true),
            "Write to foo@example.com. Use bar@example.com")
        XCTAssertEqual(DictationCleanup.apply(to: "Contact foo@example.com, scratch that, call me", enabled: true),
            "Call me")
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
        let sourceAudio = ProcessInfo.processInfo.environment["YAPPER_NATIVE_AUDIO_FIXTURE"]
            .map(URL.init(fileURLWithPath:))
            ?? fixtures.appendingPathComponent("TestAudio/conversation.wav")
        let copiedAudio = root.appendingPathComponent("conversation")
            .appendingPathExtension(sourceAudio.pathExtension)
        try fm.copyItem(at: sourceAudio, to: copiedAudio)
        let prepared = try await ConversationAudioStorage.prepareForProcessing(copiedAudio)
        defer { prepared.removeTemporaryFile() }
        let audio = prepared.processingURL
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
        let variants = (ProcessInfo.processInfo.environment["YAPPER_NATIVE_VARIANT"]).map { [$0] }
            ?? ["openai_whisper-large-v3_turbo", AIModel.hinglishVariant, ParakeetCatalog.v3Variant]
        for variant in variants {
            let words = try await NativeInferenceGate.shared.run {
                try await manager.transcribeConversationWhileLocked(
                    audioFile: audio, variant: variant,
                    language: variant == AIModel.hinglishVariant ? "hinglish" : "en") { _ in }
            }
            XCTAssertFalse(words.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if variant == AIModel.hinglishVariant {
                XCTAssertTrue(words.contains { $0.hasReliableTiming || $0.allowsWholeRangeAssignment })
                let text = words.map(\.text).joined()
                XCTAssertFalse(text.unicodeScalars.contains { (0x0900...0x097F).contains(Int($0.value)) })
                let expected = ProcessInfo.processInfo.environment["YAPPER_HINGLISH_EXPECTED"]?
                    .split(separator: ",").map(String.init) ?? []
                for phrase in expected {
                    XCTAssertTrue(text.localizedCaseInsensitiveContains(phrase),
                        "Missing expected phrase: \(phrase)")
                }
            } else {
                XCTAssertTrue(words.contains { $0.hasReliableTiming })
            }
            XCTAssertEqual(manager.currentModelVariant, variant)
        }
        if ProcessInfo.processInfo.environment["YAPPER_SKIP_NATIVE_DIARIZATION"] != "1" {
            XCTAssertTrue(FileManager.default.fileExists(atPath: LocalConversationProcessor.speakerModelURL.path),
                LocalConversationProcessor.speakerModelURL.path)
            let processor = LocalConversationProcessor()
            let first = try await processor.diarize(audio) { _ in }
            let second = try await processor.diarize(audio) { _ in }
            XCTAssertFalse(first.isEmpty)
            XCTAssertEqual(second.map(\.speakerID), first.map(\.speakerID))
            XCTAssertLessThanOrEqual(Set(first.map(\.speakerID)).count, 8)
            XCTAssertTrue(first.allSatisfy { $0.start >= 0 && $0.end > $0.start })
        }
        await NativeInferenceGate.shared.run { await manager.unloadWhileLocked(variant: ParakeetCatalog.v3Variant) }
    }

    func testNativeDictationHintPreviewAndReloadWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["YAPPER_NATIVE_DICTATION"] == "1" else { throw XCTSkip("Opt-in native dictation smoke") }
        let fm = FileManager.default
        let root = AppEnvironment.applicationSupportDirectory
        let home = URL(fileURLWithPath: String(cString: getpwuid(getuid()).pointee.pw_dir))
        let source = home.appendingPathComponent("Library/Application Support/Yapper-Dev")
        let variant = AIModel.hinglishVariant
        let model = ModelStorage.transcriptionModelDirectory(for: variant)
        let tokenizer = root.appendingPathComponent("models/openai")
        try fm.createDirectory(at: model.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: source.appendingPathComponent("models/shrimalmadhur/whisperkit-hinglish/Oriserve_Whisper-Hindi2Hinglish-Apex"), to: model)
        try fm.copyItem(at: source.appendingPathComponent("models/openai"), to: tokenizer)
        defer { try? fm.removeItem(at: root) }
        let audio = root.appendingPathComponent("fixture.wav")
        try fm.copyItem(at: source.appendingPathComponent("TestAudio/conversation.wav"), to: audio)
        let engine = WhisperService()
        try await engine.loadModel(variant: variant)
        engine.setPreferredWords(["Yapper", "workstation"])
        let first = try await engine.transcribe(audioFile: audio, language: "hinglish")
        XCTAssertFalse(first.isEmpty)
        await engine.unload()
        XCTAssertNil(engine.pipe)
        XCTAssertFalse(engine.isInitialized)
        try await engine.loadModel(variant: variant)
        let second = try await engine.transcribe(audioFile: audio, language: "hinglish")
        XCTAssertFalse(second.isEmpty)
        await engine.unload()
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

import Foundation
import WhisperKit
import FluidAudio
import CoreML
import ArgmaxCore

@Observable
class WhisperService {
    // Shared singleton instance - use this everywhere
    static let shared = WhisperService()
    private static let autoEditEnabledKey = "enableAutoEdit"
    private static let placeholderPatterns = [
        #"\[(?:BLANK_AUDIO|SILENCE)\]"#,
        #"<\|nospeech\|>"#,
        #"\[\s*S\s*\]"#,
    ]
    private static let fillerWordPattern =
        #"(?i)(^|[\s,.;:!?])(?:uh+|um+|umm+|uhm+|erm+|hmm+)(?=$|[\s,.;:!?])[,.;:!?]?"#
    private static let noiseLabelTerms = [
        "applause",
        "background noise",
        "blank audio",
        "breathing",
        "cough",
        "coughing",
        "exhale",
        "heartbeat",
        "indistinct",
        "inaudible",
        "inhale",
        "laughing",
        "laughter",
        "loud noise",
        "muffled speech",
        "music",
        "noise",
        "silence",
        "sigh",
        "sighs",
        "sniffing",
        "static",
        "unclear speech",
        "unintelligible",
        "wind",
        "wind blowing",
        "wind noise",
    ]
    private static let bracketedNoisePattern: String = {
        let escaped = noiseLabelTerms.map(NSRegularExpression.escapedPattern(for:)).joined(
            separator: "|")
        return #"[\[\(]\s*(?:"# + escaped + #")\s*[\]\)]"#
    }()

    var pipe: WhisperKit?
    var isInitialized = false
    var isTranscribing = false
    var isLoading = false
    var loadingStage: String = ""  // Descriptive stage for UI
    var loadingModelVariant: String = ""
    var loadingStartedAt: Date?

    var currentModelVariant: String = ""  // No default - must be explicitly set
    private var lastLoadDuration: TimeInterval?

    @MainActor private var activeLoadTask: Task<Void, Error>?
    @MainActor private var activeLoadVariant: String = ""
    @MainActor private var activeLoadToken: UUID?

    /// Device RAM in GB (cached on init)
    static let deviceRAMGB: Int = {
        Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))
    }()

    enum TranscriptionError: Error, LocalizedError {
        case notInitialized
        case fileNotFound
        case alreadyLoading
        case loadingTimeout

        var errorDescription: String? {
            switch self {
            case .notInitialized: return "Model is not initialized"
            case .fileNotFound: return "Audio file not found"
            case .alreadyLoading: return "Model loading already in progress"
            case .loadingTimeout:
                return "Model loading timed out — your Mac may not have enough RAM for this model"
            }
        }
    }

    // Init is internal to allow testing, but prefer using .shared in production
    init() {}

    // Default initialization (loads default or saved model)
    @MainActor
    func initialize() async throws {
        try await loadModel(variant: currentModelVariant)
    }

    // Dynamic model loading with optimized WhisperKitConfig
    @MainActor
    func loadModel(variant: String) async throws {
        // Already loaded this exact model
        if isInitialized && variant == currentModelVariant && pipe != nil {
            print("✅ Model \(variant) already loaded, skipping")
            return
        }

        if let activeLoadTask {
            let inFlightVariant = activeLoadVariant

            if inFlightVariant == variant {
                loadingStage = "Model is still warming up..."
                print("⏳ Model \(variant) load already in progress, waiting for completion")
                try await activeLoadTask.value
                return
            }

            loadingStage = "Finishing current model load..."
            print("⏳ Waiting for current model load (\(inFlightVariant)) to finish before loading \(variant)")
            do {
                try await activeLoadTask.value
            } catch {
                // If another model failed to warm up, still try the model the caller asked for.
                print(
                    "⚠️ In-flight model load (\(inFlightVariant)) failed while waiting: \(error.localizedDescription). Continuing with \(variant)."
                )
            }

            if isInitialized && variant == currentModelVariant && pipe != nil {
                print("✅ Model \(variant) became ready while waiting, skipping duplicate load")
                return
            }
        }

        let token = UUID()
        let task = Task { @MainActor in
            try await self.performModelLoad(variant: variant)
        }
        activeLoadTask = task
        activeLoadVariant = variant
        activeLoadToken = token

        defer {
            if activeLoadToken == token {
                activeLoadTask = nil
                activeLoadVariant = ""
                activeLoadToken = nil
            }
        }

        try await task.value
    }

    @MainActor
    private func performModelLoad(variant: String) async throws {
        let ramGB = Self.deviceRAMGB
        print("🔄 Initializing WhisperKit with model: \(variant)...")
        print("💻 Device RAM: \(ramGB) GB")

        if let model = AIModel.availableModels.first(where: { $0.variant == variant }),
            ramGB < model.minimumRAMGB
        {
            print(
                "⚠️ WARNING: Model \(variant) recommends \(model.minimumRAMGB)GB+ RAM, device has \(ramGB)GB. Loading may fail or be very slow."
            )
        }

        isLoading = true
        isInitialized = false
        loadingModelVariant = variant
        loadingStartedAt = Date()
        loadingStage = "Preparing \(modelDisplayName(for: variant))..."

        // Release existing model to free memory
        if pipe != nil {
            loadingStage = "Switching models and freeing memory..."
            print("🗑️ Releasing previous model from memory...")
            pipe = nil
        }

        do {
            // Prefer the current Application Support location; fall back to the legacy
            // Documents location so users who downloaded before the move keep working.
            let newModelFolder = ModelStorage.whisperKitModelsDir
                .appendingPathComponent(variant)
            var modelFolder = newModelFolder
            if !FileManager.default.fileExists(atPath: newModelFolder.path),
                let legacyFolder = ModelStorage.legacyModelsDir?.appendingPathComponent(variant),
                FileManager.default.fileExists(atPath: legacyFolder.path)
            {
                modelFolder = legacyFolder
            }

            guard ModelStorage.transcriptionModelReady(variant),
                  let tokenizer = ModelStorage.tokenizerDirectory(for: variant) else {
                throw ConversationError.modelsMissing
            }
            _ = try await AutoTokenizerWrapper.from(modelFolder: tokenizer)

            // Use WhisperKitConfig with optimized settings.
            // `downloadBase` keeps any tokenizer configs WhisperKit fetches out of
            // ~/Documents (the root cause of model-load failures on macOS 15, #38).
            let config = WhisperKitConfig(
                model: variant,
                downloadBase: ModelStorage.whisperKitBase,
                modelFolder: modelFolder.path,
                tokenizerFolder: ModelStorage.whisperKitBase,
                computeOptions: ModelComputeOptions(),  // Uses GPU + Neural Engine
                verbose: false,
                logLevel: .error,
                prewarm: true,  // Built-in model specialization (replaces manual warmup)
                load: true,
                download: false  // Already downloaded via ModelDownloadService
            )

            loadingStage = "Loading model into memory..."

            // Start a watchdog timer that will flag a timeout
            let loadStart = Date()

            pipe = try await WhisperKit(config)

            let loadDuration = Date().timeIntervalSince(loadStart)
            lastLoadDuration = loadDuration
            print("⏱️ Model loaded in \(String(format: "%.1f", loadDuration))s")

            currentModelVariant = variant
            isInitialized = true
            isLoading = false
            loadingStage = ""
            loadingModelVariant = ""
            loadingStartedAt = nil
            print("✅ WhisperKit initialized and prewarmed with \(variant)")
        } catch {
            isLoading = false
            loadingStage = ""
            loadingModelVariant = ""
            loadingStartedAt = nil
            print(
                "❌ Failed to initialize WhisperKit with \(variant): \(error.localizedDescription)")
            throw error
        }
    }

    private func modelDisplayName(for variant: String) -> String {
        AIModel.availableModels.first(where: { $0.variant == variant })?.name ?? variant
    }

    func transcribe(audioFile: URL, language: String = "auto") async throws -> String {
        guard let pipe = pipe, isInitialized else {
            throw TranscriptionError.notInitialized
        }

        guard FileManager.default.fileExists(atPath: audioFile.path) else {
            throw TranscriptionError.fileNotFound
        }

        isTranscribing = true
        defer { isTranscribing = false }

        print("Starting transcription for: \(audioFile.lastPathComponent)")

        do {
            let options = decodingOptions(for: language)
            let results = try await pipe.transcribe(audioPath: audioFile.path, decodeOptions: options)
            let text = Self.normalizedTranscription(
                from: results.map { $0.text }.joined(separator: " "))

            print("Transcription complete: \(text.prefix(50))...")
            return text
        } catch {
            print("Transcription failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// Transcribe a background audio chunk without affecting the global `isTranscribing` flag.
    /// Chunk files are automatically deleted after transcription.
    func transcribeChunk(audioFile: URL, language: String = "auto") async throws -> String {
        guard let pipe = pipe, isInitialized else {
            throw TranscriptionError.notInitialized
        }

        guard FileManager.default.fileExists(atPath: audioFile.path) else {
            // Chunk file may have been cleaned up already - return empty gracefully
            return ""
        }

        print("🔪 Chunk transcription started: \(audioFile.lastPathComponent)")

        let results = try await pipe.transcribe(
            audioPath: audioFile.path,
            decodeOptions: decodingOptions(for: language)
        )
        let text = Self.normalizedTranscription(from: results.map { $0.text }.joined(separator: " "))

        print("🔪 Chunk done: \(text.prefix(40))...")
        // Clean up temp chunk file after transcription
        try? FileManager.default.removeItem(at: audioFile)
        return text
    }

    @MainActor
    func transcribeConversation(audioFile: URL, language: String = "auto", progress: @escaping @Sendable (Double) -> Void) async throws -> [ConversationWord] {
        guard let pipe, isInitialized else { throw TranscriptionError.notInitialized }
        isTranscribing = true
        defer { isTranscribing = false }
        let samples = try await Task.detached(priority: .userInitiated) {
            try AudioConverter().resampleAudioFile(audioFile)
        }.value
        guard samples.contains(where: { $0 != 0 }) else { return [] }
        let modelURL = LocalConversationProcessor.speechModelURL
        let speech = try await Task.detached(priority: .userInitiated) {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuOnly
            let model = try MLModel(contentsOf: modelURL, configuration: configuration)
            let vad = VadManager(config: VadConfig(defaultThreshold: 0.5), vadModel: model)
            return try await vad.segmentSpeech(samples,
                config: VadSegmentationConfig(minSpeechDuration: 0.15, minSilenceDuration: 0.5,
                    maxSpeechDuration: 10, speechPadding: 0.15))
        }.value
        let ranges = ConversationAlignment.speechChunks(
            speech.map { $0.startSample(sampleRate: 16000)..<$0.endSample(sampleRate: 16000) },
            sampleCount: samples.count, maxSamples: 12 * 16000)
        var output: [ConversationWord] = []
        for (index, range) in ranges.enumerated() {
            let audio = Array(samples[range])
            let offset = Double(range.lowerBound) / 16000
            let end = Double(range.upperBound) / 16000
            var options = Self.conversationDecodingOptions()
            if AIModel.availableModels.first(where: { $0.variant == currentModelVariant })?.isEnglishOnly == true {
                options.language = "en"
                options.detectLanguage = false
            } else if language == "mixed" {
                let detected = try await pipe.detectLangauge(audioArray: audio)
                options.language = detected.langProbs.filter { ["en", "hi", "gu"].contains($0.key) }
                    .max(by: { $0.value < $1.value })?.key
                options.detectLanguage = false
            } else if language != "auto" {
                options.language = language
                options.detectLanguage = false
            }
            let results = try await pipe.transcribe(audioArray: audio, decodeOptions: options)
            for result in results where !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let words = result.segments.flatMap { segment in
                    ConversationAlignment.preservingText(segment.text,
                        words: (segment.words ?? []).map {
                            ConversationWord(text: $0.word, start: offset + Double($0.start), end: offset + Double($0.end))
                        }, start: offset + Double(segment.start), end: offset + Double(segment.end))
                }
                let preserved = ConversationAlignment.preservingText(
                    (output.isEmpty ? "" : " ") + result.text, words: words, start: offset, end: end)
                output.append(contentsOf: preserved.map { word in
                    let reliable = word.start >= offset && word.end <= end + 0.2 && word.end > word.start
                    return ConversationWord(text: word.text, start: min(end, max(offset, word.start)),
                        end: min(end, max(offset, word.end)), hasReliableTiming: word.hasReliableTiming && reliable)
                })
            }
            progress(Double(index + 1) / Double(max(1, ranges.count)))
        }
        return output
    }

    static func conversationDecodingOptions() -> DecodingOptions {
        var options = DecodingOptions()
        options.task = .transcribe
        options.language = nil
        options.detectLanguage = true
        options.wordTimestamps = true
        options.skipSpecialTokens = true
        options.withoutTimestamps = false
        options.concurrentWorkerCount = 1
        return options
    }

    @MainActor
    func unload() async {
        await pipe?.unloadModels()
        pipe = nil
        isInitialized = false
        currentModelVariant = ""
    }

    private func decodingOptions(for language: String) -> DecodingOptions {
        var options = DecodingOptions()
        options.task = .transcribe
        options.language = (language == "auto") ? nil : language
        return options
    }

    static func normalizedTranscription(from rawText: String) -> String {
        var normalized = rawText

        for pattern in placeholderPatterns {
            normalized = normalized.replacingOccurrences(
                of: pattern,
                with: " ",
                options: .regularExpression
            )
        }

        normalized = normalized.replacingOccurrences(
            of: bracketedNoisePattern,
            with: " ",
            options: [.regularExpression, .caseInsensitive]
        )

        normalized = normalized.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )

        normalized = applyAutoEdit(to: normalized)

        return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Filler-word removal + punctuation tidy, gated by the "Auto Edit" toggle.
    ///
    /// Custom word replacements and spoken snippets are applied separately by
    /// `DictionaryService` in `TranscriptionManager`, so they run once for
    /// every engine (not just Whisper) and independently of this toggle.
    private static func applyAutoEdit(to text: String) -> String {
        guard UserDefaults.standard.bool(forKey: autoEditEnabledKey) else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var edited = text.replacingOccurrences(
            of: fillerWordPattern,
            with: "$1",
            options: .regularExpression
        )

        edited = edited.replacingOccurrences(
            of: #"\s+([,.;:!?])"#,
            with: "$1",
            options: .regularExpression
        )
        edited = edited.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        return edited.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

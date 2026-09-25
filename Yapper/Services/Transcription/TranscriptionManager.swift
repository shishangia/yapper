import Foundation

@MainActor
@Observable
class TranscriptionManager {
    static let shared = TranscriptionManager()
    private let whisper: any SpeechToTextEngine
    private let parakeet: any SpeechToTextEngine
    private let gate: NativeInferenceGate
    private(set) var activeKind: TranscriptionEngineKind = .whisper
    private(set) var warmingVariant: String?
    private(set) var warmupError: String?
    private(set) var warmupStartedAt: Date?
    private var warmupID = UUID()
    private var warmupTask: Task<Void, Never>?
    private let selectedVariant: @MainActor () -> String
    private let modelReady: @MainActor (String) -> Bool
    private let autoEditEnabled: @MainActor () -> Bool

    init(whisper: (any SpeechToTextEngine)? = nil, parakeet: (any SpeechToTextEngine)? = nil,
         gate: NativeInferenceGate? = nil,
         selectedVariant: @escaping @MainActor () -> String = { ModelSelection.selectedVariant() },
         modelReady: @escaping @MainActor (String) -> Bool = { ModelStorage.transcriptionModelReady($0) },
         autoEditEnabled: @escaping @MainActor () -> Bool = { UserDefaults.standard.bool(forKey: "enableAutoEdit") }) {
        self.whisper = whisper ?? WhisperService.shared
        self.parakeet = parakeet ?? ParakeetEngine.shared
        self.gate = gate ?? .shared
        self.selectedVariant = selectedVariant
        self.modelReady = modelReady
        self.autoEditEnabled = autoEditEnabled
    }

    @discardableResult
    func warmSelectedModel() -> Task<Void, Never>? {
        guard !UpdateService.shared.isInstalling else { return nil }
        let variant = selectedVariant()
        if warmingVariant == variant, let warmupTask { return warmupTask }
        let id = UUID()
        warmupID = id
        warmupError = nil
        warmingVariant = nil
        warmupStartedAt = nil
        warmupTask = nil
        guard modelReady(variant) else { return nil }
        warmingVariant = variant
        warmupStartedAt = Date()
        let task = Task {
            defer {
                if warmupID == id { warmingVariant = nil; warmupTask = nil; warmupStartedAt = nil }
            }
            do {
                try await gate.run {
                    try await prepare(variant: variant) {
                        self.warmupID == id && self.selectedVariant() == variant && self.modelReady(variant)
                    }
                }
            } catch is CancellationError {
            } catch {
                if warmupID == id, selectedVariant() == variant { warmupError = error.localizedDescription }
            }
        }
        warmupTask = task
        return task
    }

    private var activeEngine: any SpeechToTextEngine { activeKind == .whisper ? whisper : parakeet }
    var isInitialized: Bool { activeEngine.isInitialized }
    var isLoading: Bool { activeEngine.isLoading }
    var isTranscribing: Bool { activeEngine.isTranscribing }
    var loadingStage: String { activeEngine.loadingStage }
    var currentModelVariant: String { activeEngine.currentModelVariant }

    func initialize() async throws {
        try await loadModel(variant: ModelSelection.selectedVariant())
    }

    func loadModel(variant: String) async throws {
        try await gate.run { try await prepare(variant: variant) }
    }

    func unloadWhileLocked(variant: String) async {
        if currentModelVariant == variant { await activeEngine.unload() }
    }

    private func prepare(variant: String, shouldContinue: () -> Bool = { true }) async throws {
        guard shouldContinue() else { throw CancellationError() }
        guard let model = AIModel.availableModels.first(where: { $0.variant == variant }) else {
            throw ModelError.noSelection
        }
        if activeKind == model.engine, currentModelVariant == variant, isInitialized { return }
        await activeEngine.unload()
        guard shouldContinue() else { throw CancellationError() }
        activeKind = model.engine
        do { try await activeEngine.loadModel(variant: variant) }
        catch { await activeEngine.unload(); throw error }
    }

    static func validate(variant: String, language: String) throws {
        guard let model = AIModel.availableModels.first(where: { $0.variant == variant }) else {
            throw ModelError.noSelection
        }
        guard model.supports(language: language) else { throw ModelError.unsupportedLanguage(model.name) }
    }

    func transcribe(audioFile: URL, variant: String, language: String = "auto") async throws -> String {
        try await transcribeDetailed(audioFile: audioFile, variant: variant, language: language).text
    }

    func transcribeDetailed(audioFile: URL, variant: String, language: String = "auto") async throws -> DictationOutput {
        try Self.validate(variant: variant, language: language)
        let queuedAt = Date()
        return try await gate.run {
            let enteredGateAt = Date()
            let modelStart = Date()
            try await prepare(variant: variant)
            let modelSeconds = Date().timeIntervalSince(modelStart)
            let inferenceStart = Date()
            let raw = try await activeEngine.transcribe(audioFile: audioFile, language: language)
            let inferenceSeconds = Date().timeIntervalSince(inferenceStart)
            let cleanupStart = Date()
            let normalized = WhisperService.normalizedTranscription(from: raw)
            let edited = DictationCleanup.apply(to: normalized, enabled: autoEditEnabled())
            let text = DictionaryService.apply(to: edited)
            let cleanupSeconds = Date().timeIntervalSince(cleanupStart)
            return DictationOutput(text: text, timing: DictationTiming(
                queue: enteredGateAt.timeIntervalSince(queuedAt), modelPreparation: modelSeconds,
                inference: inferenceSeconds, cleanup: cleanupSeconds))
        }
    }

    // ConversationService already holds this non-reentrant gate for the whole native job.
    func transcribeConversationWhileLocked(audioFile: URL, variant: String, language: String,
        wordTimestamps: Bool = true, progress: @escaping @Sendable (Double) -> Void) async throws -> [ConversationWord] {
        try Self.validate(variant: variant, language: language)
        try await prepare(variant: variant)
        return try await activeEngine.transcribeConversation(audioFile: audioFile, language: language,
            wordTimestamps: wordTimestamps, progress: progress)
    }

    enum ModelError: LocalizedError {
        case noSelection, unsupportedLanguage(String)
        var errorDescription: String? {
            switch self {
            case .noSelection: return "Choose a model in AI Models before recording or importing audio."
            case .unsupportedLanguage(let name): return "\(name) does not support this language. Choose a compatible model in AI Models. Your selection has not been changed."
            }
        }
    }
}

extension WhisperService: SpeechToTextEngine {}

struct DictationTiming: Codable, Equatable, Sendable {
    let queue: TimeInterval
    let modelPreparation: TimeInterval
    let inference: TimeInterval
    let cleanup: TimeInterval
    var total: TimeInterval { queue + modelPreparation + inference + cleanup }
}

struct DictationOutput: Equatable, Sendable {
    let text: String
    let timing: DictationTiming
}

enum DictationCleanup {
    private static let filler =
        #"(?i)(^|[\s,.;:!?])(?:uh+|um+|umm+|uhm+|erm+|hmm+)(?=$|[\s,.;:!?])[,.;:!?]?"#
    private static let bullet = #"(?i)\b(?:bullet point|bullet item)\b[\s,:-]*"#
    private static let numbered = #"(?i)\b(?:number|item)\s+(one|two|three|four|five|six|seven|eight|nine|ten|[1-9]|10)\b[\s,:-]*"#
    private static let numberValues = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
                                       "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10]

    static func apply(to text: String, enabled: Bool) -> String {
        guard enabled else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        var edited = applyScratchThat(in: text)
        edited = edited.replacingOccurrences(of: filler, with: "$1", options: .regularExpression)
        edited = edited.replacingOccurrences(of: #"(?i)\bnew paragraph\b[,.]?"#,
            with: "\n\n", options: .regularExpression)
        edited = edited.replacingOccurrences(of: #"(?i)\bnew line\b[,.]?"#,
            with: "\n", options: .regularExpression)
        edited = formatRepeatedMarkers(in: edited, pattern: bullet) { _ in "• " }
        edited = formatNumberedList(in: edited)
        edited = edited.replacingOccurrences(
            of: #"[ \t]+([,.;:!?])"#, with: "$1", options: .regularExpression)
        edited = edited.replacingOccurrences(
            of: #"[ \t]+"#, with: " ", options: .regularExpression)
        edited = edited.replacingOccurrences(
            of: #" *\n *"#, with: "\n", options: .regularExpression)
        edited = edited.replacingOccurrences(
            of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return capitalizeSentences(in: edited.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func formatRepeatedMarkers(
        in text: String, pattern: String, replacement: (NSTextCheckingResult) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: range)
        guard matches.count >= 2 else { return text }
        var output = text
        for match in matches.reversed() {
            guard let swiftRange = Range(match.range, in: output) else { continue }
            output.replaceSubrange(swiftRange, with: "\n" + replacement(match))
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func applyScratchThat(in text: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?i)\b(?:scratch that|scratch it)\b[\s,:;-]*"#) else { return text }
        var output = text
        while let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..<output.endIndex, in: output)),
              let command = Range(match.range, in: output) {
            let prefix = output[..<command.lowerBound]
            let sentenceBoundary = prefix.lastIndex(where: { ".!?\n".contains($0) })
            let keepEnd = sentenceBoundary.map { output.index(after: $0) } ?? output.startIndex
            let kept = output[..<keepEnd].trimmingCharacters(in: .whitespacesAndNewlines)
            let correction = output[command.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            output = [kept, correction].filter { !$0.isEmpty }.joined(separator: kept.isEmpty ? "" : " ")
        }
        return output
    }

    private static func formatNumberedList(in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: numbered) else { return text }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
        let values = matches.compactMap { match -> Int? in
            guard let range = Range(match.range(at: 1), in: text) else { return nil }
            let value = String(text[range]).lowercased()
            return Int(value) ?? numberValues[value]
        }
        guard values.count >= 2, values == Array(values[0]..<(values[0] + values.count)) else { return text }
        var output = text
        for (match, value) in zip(matches, values).reversed() {
            guard let range = Range(match.range, in: output) else { continue }
            output.replaceSubrange(range, with: "\n\(value). ")
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"[ \t]+(?=\n\d+[.][ \t])"#,
                with: "", options: .regularExpression)
    }

    private static func capitalizeSentences(in text: String) -> String {
        var output = text
        for pattern in [#"(?m)^([ \t]*(?:[•*-]|\d+[.)])?[ \t]*)([a-z])"#,
                        #"([.!?][ \t]+)([a-z])"#] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let matches = regex.matches(in: output, range: NSRange(output.startIndex..<output.endIndex, in: output))
            for match in matches.reversed() {
                guard let range = Range(match.range(at: 2), in: output) else { continue }
                let suffix = output[range.lowerBound...].lowercased()
                if suffix.hasPrefix("http://") || suffix.hasPrefix("https://")
                    || suffix.hasPrefix("www.") { continue }
                let token = output[range.lowerBound...].prefix { !$0.isWhitespace && !",;:!?".contains($0) }
                if token.contains("@") || token.dropFirst().contains(where: \.isUppercase) { continue }
                output.replaceSubrange(range, with: output[range].uppercased())
            }
        }
        return output
    }
}

enum DictationPunctuation {
    static func apply(to text: String, enabled: Bool) -> String {
        guard enabled else { return text }
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard content.hasSuffix("."), !content.hasSuffix("..") else { return text }
        let stem = String(content.dropLast())
        guard !stem.isEmpty, !stem.contains(where: { $0.isWhitespace }) else { return text }
        let email = stem.range(of: #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#, options: .regularExpression) != nil
        let url = (stem.hasPrefix("https://") || stem.hasPrefix("http://") || stem.hasPrefix("www."))
            && URL(string: stem.hasPrefix("www.") ? "https://" + stem : stem)?.host != nil
        let number = stem.range(of: #"^[+-]?[0-9]+([.,][0-9]+)*%?$"#, options: .regularExpression) != nil
        let word = stem.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "'" || $0 == "’" || $0 == "_" }
        guard email || url || number || word else { return text }
        guard let period = text.lastIndex(of: ".") else { return text }
        var result = text
        result.remove(at: period)
        return result
    }
}

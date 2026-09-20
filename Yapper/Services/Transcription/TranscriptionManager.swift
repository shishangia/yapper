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

    init(whisper: (any SpeechToTextEngine)? = nil, parakeet: (any SpeechToTextEngine)? = nil,
         gate: NativeInferenceGate? = nil,
         selectedVariant: @escaping @MainActor () -> String = { UserDefaults.standard.string(forKey: ModelSelection.defaultsKey) ?? "" },
         modelReady: @escaping @MainActor (String) -> Bool = { ModelStorage.transcriptionModelReady($0) }) {
        self.whisper = whisper ?? WhisperService.shared
        self.parakeet = parakeet ?? ParakeetEngine.shared
        self.gate = gate ?? .shared
        self.selectedVariant = selectedVariant
        self.modelReady = modelReady
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
        try await loadModel(variant: UserDefaults.standard.string(forKey: ModelSelection.defaultsKey) ?? "")
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
        try Self.validate(variant: variant, language: language)
        return try await gate.run {
            try await prepare(variant: variant)
            let text = try await activeEngine.transcribe(audioFile: audioFile, language: language)
            return DictionaryService.apply(to: text)
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

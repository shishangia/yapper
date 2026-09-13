import Foundation

@MainActor
@Observable
class TranscriptionManager {
    static let shared = TranscriptionManager()
    private let whisper: any SpeechToTextEngine
    private let parakeet: any SpeechToTextEngine
    private let gate: NativeInferenceGate
    private(set) var activeKind: TranscriptionEngineKind = .whisper

    init(whisper: (any SpeechToTextEngine)? = nil, parakeet: (any SpeechToTextEngine)? = nil,
         gate: NativeInferenceGate? = nil) {
        self.whisper = whisper ?? WhisperService.shared
        self.parakeet = parakeet ?? ParakeetEngine.shared
        self.gate = gate ?? .shared
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

    private func prepare(variant: String) async throws {
        guard let model = AIModel.availableModels.first(where: { $0.variant == variant }) else {
            throw ModelError.noSelection
        }
        if activeKind == model.engine, currentModelVariant == variant, isInitialized { return }
        await activeEngine.unload()
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
        progress: @escaping @Sendable (Double) -> Void) async throws -> [ConversationWord] {
        try Self.validate(variant: variant, language: language)
        try await prepare(variant: variant)
        return try await activeEngine.transcribeConversation(audioFile: audioFile, language: language, progress: progress)
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

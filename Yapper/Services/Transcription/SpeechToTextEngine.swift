import Foundation

@MainActor
protocol SpeechToTextEngine: AnyObject {
    var isInitialized: Bool { get }
    var isLoading: Bool { get }
    var isTranscribing: Bool { get }
    var loadingStage: String { get }
    var currentModelVariant: String { get }
    func loadModel(variant: String) async throws
    func unload() async
    func transcribe(audioFile: URL, language: String) async throws -> String
    func transcribeConversation(audioFile: URL, language: String, wordTimestamps: Bool, progress: @escaping @Sendable (Double) -> Void) async throws -> [ConversationWord]
}

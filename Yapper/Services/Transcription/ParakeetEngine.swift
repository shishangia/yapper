import Foundation
import FluidAudio
import CoreML

enum ParakeetCatalog {
    static let v3Variant = "parakeet-tdt-0.6b-v3"
    static let v2Variant = "parakeet-tdt-0.6b-v2"
    static let ctc110mVariant = "parakeet-tdt-ctc-110m"
    static let variants = [v3Variant, v2Variant, ctc110mVariant]

    static func version(for variant: String) -> AsrModelVersion {
        switch variant {
        case v2Variant: return .v2
        case ctc110mVariant: return .tdtCtc110m
        default: return .v3
        }
    }
}

@MainActor
@Observable
class ParakeetEngine: SpeechToTextEngine {
    static let shared = ParakeetEngine()
    var isInitialized = false
    var isTranscribing = false
    var isLoading = false
    var loadingStage = ""
    var currentModelVariant = ""
    private var manager: AsrManager?
    private init() {}

    func loadModel(variant: String) async throws {
        if isInitialized, currentModelVariant == variant, manager != nil { return }
        guard ModelStorage.transcriptionModelReady(variant) else { throw ConversationError.modelsMissing }
        await unload()
        isLoading = true
        loadingStage = "Loading Parakeet model…"
        defer { isLoading = false; loadingStage = "" }
        let version = ParakeetCatalog.version(for: variant)
        let directory = ModelStorage.parakeetCacheDirectory(for: version)
        let models = try await Task.detached(priority: .userInitiated) {
            // FluidAudio's convenience loader can download optional CTC weights even from a populated cache.
            let config = MLModelConfiguration()
            config.computeUnits = .cpuAndNeuralEngine
            func load(_ name: String, cpu: Bool = false) throws -> MLModel {
                let settings = MLModelConfiguration()
                settings.computeUnits = cpu ? .cpuOnly : config.computeUnits
                return try MLModel(contentsOf: directory.appendingPathComponent(name), configuration: settings)
            }
            let data = try Data(contentsOf: directory.appendingPathComponent(ModelNames.ASR.vocabularyFile))
            let json = try JSONSerialization.jsonObject(with: data)
            let vocabulary: [Int: String]
            if let array = json as? [String] { vocabulary = Dictionary(uniqueKeysWithValues: array.enumerated().map { ($0.offset, $0.element) }) }
            else if let values = json as? [String: String] {
                vocabulary = Dictionary(uniqueKeysWithValues: values.compactMap { key, value in Int(key).map { ($0, value) } })
            } else { throw ASRError.modelLoadFailed }
            return try AsrModels(
                encoder: version.hasFusedEncoder ? nil : load(version == .v3 ? ParakeetEncoderPrecision.int8.encoderFileName : ModelNames.ASR.encoderFile),
                preprocessor: load(ModelNames.ASR.preprocessorFile, cpu: !version.hasFusedEncoder),
                decoder: load(ModelNames.ASR.decoderFile),
                joint: load(version == .v3 ? ModelNames.ASR.jointV3File : ModelNames.ASR.jointFile),
                configuration: config, vocabulary: vocabulary, version: version)
        }.value
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.manager = manager
        currentModelVariant = variant
        isInitialized = true
    }

    func unload() async {
        await manager?.cleanup()
        manager = nil
        isInitialized = false
        currentModelVariant = ""
    }

    private func result(audioFile: URL, language: String, progress: @escaping @Sendable (Double) -> Void) async throws -> ASRResult {
        guard let manager else { throw ASRError.notInitialized }
        isTranscribing = true
        defer { isTranscribing = false }
        let stream = await manager.transcriptionProgressStream
        let updates = Task {
            do { for try await value in stream { progress(value) } } catch {}
        }
        defer { updates.cancel() }
        var state = try TdtDecoderState(decoderLayers: ParakeetCatalog.version(for: currentModelVariant).decoderLayers)
        let result = try await manager.transcribe(audioFile, decoderState: &state, language: Language(rawValue: language))
        progress(1)
        return result
    }

    func transcribe(audioFile: URL, language: String) async throws -> String {
        try await result(audioFile: audioFile, language: language) { _ in }.text
    }

    func transcribeConversation(audioFile: URL, language: String, wordTimestamps: Bool = true, progress: @escaping @Sendable (Double) -> Void) async throws -> [ConversationWord] {
        let duration = try await ConversationAudioStorage.duration(audioFile)
        let result = try await result(audioFile: audioFile, language: language, progress: progress)
        return Self.words(from: result, duration: duration)
    }

    static func words(from result: ASRResult, duration: TimeInterval) -> [ConversationWord] {
        // FluidAudio's chunked results report duration zero despite valid token timestamps.
        let tokens = (result.tokenTimings ?? []).map {
            ConversationWord(text: $0.token, start: $0.startTime, end: $0.endTime,
                hasReliableTiming: $0.startTime.isFinite && $0.endTime.isFinite && $0.startTime >= 0
                    && $0.endTime > $0.startTime && $0.endTime <= duration + 0.2)
        }
        return ConversationAlignment.preservingText(result.text, words: tokens, start: 0, end: duration)
    }
}

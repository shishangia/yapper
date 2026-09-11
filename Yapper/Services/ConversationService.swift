import AVFoundation
import CoreML
import FluidAudio
import Foundation
import WhisperKit

@MainActor
protocol ConversationProcessing {
    func transcribe(_ url: URL, language: String, progress: @escaping @Sendable (Double) -> Void) async throws -> [ConversationWord]
    func diarize(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> [ConversationSpeakerTurn]
}

@MainActor
final class LocalConversationProcessor: ConversationProcessing {
    static let variant = "openai_whisper-large-v3"
    static let speakerModelName = "SortformerNvidiaLow_v2.1.mlmodelc"
    static var diarizerDirectory: URL { ModelStorage.whisperKitBase.appendingPathComponent("SpeakerModels") }
    static var speakerModelURL: URL { diarizerDirectory.appendingPathComponent("sortformer/\(speakerModelName)") }
    static var tokenizerDirectory: URL { ModelStorage.whisperKitBase.appendingPathComponent("models/openai/whisper-large-v3") }
    static var speechModelURL: URL {
        ModelStorage.whisperKitBase.appendingPathComponent("SpeechModels/silero-vad/\(ModelNames.VAD.sileroVadFile)")
    }

    static var speechModelReady: Bool {
        ["coremldata.bin", "model.mil", "weights/weight.bin"].allSatisfy {
            FileManager.default.fileExists(atPath: speechModelURL.appendingPathComponent($0).path)
        }
    }

    static var transcriptionModelsReady: Bool {
        let model = ModelStorage.whisperKitModelsDir.appendingPathComponent(variant)
        return ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc"].allSatisfy {
            FileManager.default.fileExists(atPath: model.appendingPathComponent($0).path)
        } && ["tokenizer.json", "tokenizer_config.json"].allSatisfy {
            FileManager.default.fileExists(atPath: tokenizerDirectory.appendingPathComponent($0).path)
        } && speechModelReady
    }

    static var speakerModelsReady: Bool {
        ["coremldata.bin", "model0/weights/0-weight.bin", "model1/weights/1-weight.bin"].allSatisfy {
            FileManager.default.fileExists(atPath: speakerModelURL.appendingPathComponent($0).path)
        }
    }

    static func downloadModels(speakers: Bool, progress: @escaping @Sendable (String, Double) -> Void) async throws {
        if !transcriptionModelsReady {
            _ = try await WhisperKit.download(variant: variant, downloadBase: ModelStorage.whisperKitBase) {
                progress("Downloading Whisper Large v3", $0.fractionCompleted)
            }
            progress("Downloading language tokenizer", 0)
            _ = try await ModelUtilities.loadTokenizer(for: .largev3, tokenizerFolder: ModelStorage.whisperKitBase)
        }
        if !speechModelReady {
            try await DownloadUtils.downloadRepo(.vad, to: ModelStorage.whisperKitBase.appendingPathComponent("SpeechModels")) {
                progress("Downloading speech detection model", $0.fractionCompleted)
            }
        }
        if speakers && !speakerModelsReady {
            try await DownloadUtils.downloadRepo(.sortformer, to: diarizerDirectory, variant: speakerModelName) {
                progress("Downloading speaker models", $0.fractionCompleted)
            }
        }
    }

    func transcribe(_ url: URL, language: String, progress: @escaping @Sendable (Double) -> Void) async throws -> [ConversationWord] {
        guard Self.transcriptionModelsReady else { throw ConversationError.modelsMissing }
        let whisper = WhisperService()
        do {
            try await whisper.loadModel(variant: Self.variant)
            let words = try await whisper.transcribeConversation(audioFile: url, language: language, progress: progress)
            await whisper.unload()
            return words
        } catch {
            await whisper.unload()
            throw error
        }
    }

    func diarize(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> [ConversationSpeakerTurn] {
        guard Self.speakerModelsReady else { throw ConversationError.modelsMissing }
        let modelURL = Self.speakerModelURL
        return try await Task.detached(priority: .userInitiated) {
            let config = SortformerConfig.balancedV2_1
            let mlConfig = MLModelConfiguration()
            mlConfig.computeUnits = .all
            let model = try MLModel(contentsOf: modelURL, configuration: mlConfig)
            let models = try SortformerModels(config: config, main: model)
            let diarizer = SortformerDiarizer(config: config)
            diarizer.initialize(models: models)
            let timeline = try diarizer.processComplete(audioFileURL: url) { completed, total, _ in
                progress(Double(completed) / Double(max(1, total)))
            }
            return timeline.speakers.flatMap { id, speaker in
                speaker.finalizedSegments.map {
                    ConversationSpeakerTurn(speakerID: String(id), start: Double($0.startTime), end: Double($0.endTime))
                }
            }.sorted { $0.start < $1.start }
        }.value
    }
}

enum ConversationError: LocalizedError {
    case busy, cancelled, modelsMissing, invalidSpeakerModels, invalidAudio
    var errorDescription: String? {
        switch self {
        case .busy: return "Another recording is still being processed."
        case .cancelled: return "Canceled. No transcript was saved."
        case .modelsMissing: return "Download the conversation models before transcribing."
        case .invalidSpeakerModels: return "The speaker models are incomplete or damaged."
        case .invalidAudio: return "The file does not contain a readable audio track."
        }
    }
}

@MainActor
@Observable
final class ConversationService {
    private(set) var isProcessing = false
    private(set) var cancellationRequested = false
    private(set) var stage = ""
    private(set) var progress: Double = 0
    private var jobID: UUID?
    private let processor: any ConversationProcessing
    private let gate: NativeInferenceGate

    init(processor: (any ConversationProcessing)? = nil, gate: NativeInferenceGate? = nil) {
        self.processor = processor ?? LocalConversationProcessor()
        self.gate = gate ?? .shared
    }

    func cancel() {
        guard isProcessing else { return }
        cancellationRequested = true
        stage = "Canceling. Waiting for the current operation to finish…"
    }

    func downloadModels(speakers: Bool) async throws {
        let id = try begin()
        defer { finish() }
        try await gate.run {
            try checkCancellation()
            try await LocalConversationProcessor.downloadModels(speakers: speakers) { stage, value in
                Task { @MainActor in self.report(id: id, stage: stage, progress: value) }
            }
            try checkCancellation()
        }
        await ModelDownloadService.shared.refreshDownloadedModels()
    }

    func process(_ url: URL, detectSpeakers: Bool, singleSpeaker: Bool = false, language: String = "auto") async throws -> ConversationTranscript {
        let id = try begin()
        defer { finish() }
        return try await gate.run {
            try checkCancellation()
            report(id: id, stage: "Loading and transcribing with Whisper Large v3", progress: 0)
            let words = try await processor.transcribe(url, language: language) { value in
                Task { @MainActor in self.report(id: id, stage: "Transcribing in the spoken language", progress: value) }
            }
            try checkCancellation()
            var transcript = ConversationAlignment.align(words: words, turns: [], detectSpeakers: detectSpeakers)
            let languageWarning = language == "mixed"
                ? "Experimental mixed-language transcription. Gujarati and rapid language switching can produce omissions, repetition or translation. Review against the recording." : nil
            transcript.warning = languageWarning
            if detectSpeakers && singleSpeaker {
                for index in transcript.segments.indices { transcript.segments[index].speakerID = "1" }
                return transcript
            }
            if detectSpeakers && !transcript.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                report(id: id, stage: "Separating speakers locally", progress: 0)
                do {
                    let turns = try await processor.diarize(url) { value in
                        Task { @MainActor in self.report(id: id, stage: "Separating speakers locally", progress: value) }
                    }
                    try checkCancellation()
                    transcript = ConversationAlignment.align(words: words, turns: turns, detectSpeakers: true)
                    let speakerWarning = transcript.segments.contains(where: { $0.speakerID == nil })
                        ? "Some words have an uncertain speaker assignment. This does not indicate an additional person. Use Edit to assign them, or choose One speaker before recording." : nil
                    transcript.warning = [languageWarning, speakerWarning].compactMap { $0 }.joined(separator: " ")
                } catch {
                    try checkCancellation()
                    transcript.warning = [languageWarning, "Speaker detection failed. The full unlabeled transcript was kept. \(error.localizedDescription)"].compactMap { $0 }.joined(separator: " ")
                }
            }
            try checkCancellation()
            return transcript
        }
    }

    private func begin() throws -> UUID {
        guard !isProcessing else { throw ConversationError.busy }
        let id = UUID()
        jobID = id
        isProcessing = true
        cancellationRequested = false
        stage = "Waiting for other transcription to finish"
        progress = 0
        return id
    }

    private func finish() {
        isProcessing = false
        jobID = nil
        stage = ""
    }

    private func checkCancellation() throws {
        if cancellationRequested || Task.isCancelled { throw ConversationError.cancelled }
    }

    private func report(id: UUID, stage: String, progress: Double) {
        guard jobID == id, !cancellationRequested else { return }
        self.stage = stage
        self.progress = min(1, max(0, progress))
    }
}

@MainActor
enum ConversationAudioStorage {
    static func importAudio(_ source: URL) throws -> URL {
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        let directory = AppEnvironment.applicationSupportDirectory.appendingPathComponent("Recordings")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(source.pathExtension)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    static func duration(_ url: URL) async throws -> TimeInterval {
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw ConversationError.invalidAudio }
        return duration
    }
}

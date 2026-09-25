@preconcurrency import AVFoundation
import CoreML
import FluidAudio
import Foundation
import WhisperKit

@MainActor
protocol ConversationProcessing {
    func transcribe(_ url: URL, variant: String, language: String, wordTimestamps: Bool, progress: @escaping @Sendable (Double) -> Void) async throws -> [ConversationWord]
    func diarize(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> [ConversationSpeakerTurn]
}

@MainActor
final class LocalConversationProcessor: ConversationProcessing {
    static let speakerConfig = Nemotron3Config.fast128
    static var diarizerDirectory: URL { ModelStorage.nemotronSpeakerDirectory }
    static var speakerModelURL: URL {
        diarizerDirectory.appendingPathComponent("monolithic/\(speakerConfig.modelFileName)")
    }
    static var speakerVersionURL: URL {
        diarizerDirectory.appendingPathComponent(ModelNames.Nemotron3.weightsVersionFile)
    }
    static var speechModelURL: URL {
        ModelStorage.whisperKitBase.appendingPathComponent("SpeechModels/silero-vad/\(ModelNames.VAD.sileroVadFile)")
    }
    private let speakerEngine = LocalNemotronSpeakerEngine()

    static var speechModelReady: Bool {
        ["coremldata.bin", "model.mil", "weights/weight.bin"].allSatisfy {
            FileManager.default.fileExists(atPath: speechModelURL.appendingPathComponent($0).path)
        }
    }

    static func transcriptionModelsReady(variant: String) -> Bool {
        ModelStorage.transcriptionModelReady(variant)
            && (AIModel.engineKind(for: variant) == .parakeet || speechModelReady)
    }

    static var speakerModelsReady: Bool {
        let version = try? String(contentsOf: speakerVersionURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return version == ModelNames.Nemotron3.weightsVersion && ["coremldata.bin", "weights/weight.bin"].allSatisfy {
            FileManager.default.fileExists(atPath: speakerModelURL.appendingPathComponent($0).path)
        } && FileManager.default.fileExists(atPath:
            diarizerDirectory.appendingPathComponent(ModelNames.Nemotron3.silenceEmbeddingFile).path)
    }

    static func downloadModels(variant: String, speakers: Bool, progress: @escaping @Sendable (String, Double) -> Void) async throws {
        try await ModelDownloadService.shared.downloadAndWait(variant: variant) { value in
            progress("Downloading transcription model", value)
        }
        if AIModel.engineKind(for: variant) == .whisper && !speechModelReady {
            _ = try await ModelHub.loadModels(
                .vad, modelNames: Array(ModelNames.VAD.requiredModels),
                directory: ModelStorage.whisperKitBase.appendingPathComponent("SpeechModels"),
                progressHandler: { progress("Downloading speech detection model", $0.fractionCompleted) })
        }
        if speakers && !speakerModelsReady {
            _ = try await Nemotron3Models.loadFromHuggingFace(
                config: speakerConfig, cacheDirectory: ModelStorage.fluidAudioModelsDir) {
                progress("Downloading speaker models", $0.fractionCompleted)
            }
        }
    }

    func transcribe(_ url: URL, variant: String, language: String, wordTimestamps: Bool, progress: @escaping @Sendable (Double) -> Void) async throws -> [ConversationWord] {
        guard Self.transcriptionModelsReady(variant: variant) else { throw ConversationError.modelsMissing }
        return try await TranscriptionManager.shared.transcribeConversationWhileLocked(
            audioFile: url, variant: variant, language: language, wordTimestamps: wordTimestamps, progress: progress)
    }

    func diarize(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> [ConversationSpeakerTurn] {
        guard Self.speakerModelsReady else { throw ConversationError.modelsMissing }
        let result = try await speakerEngine.process(
            url, config: Self.speakerConfig, modelURL: Self.speakerModelURL,
            silenceURL: Self.diarizerDirectory.appendingPathComponent(
                ModelNames.Nemotron3.silenceEmbeddingFile))
        progress(1)
        return result
    }
}

/// Keeps the compiled speaker model resident between jobs without running model
/// preparation or inference on the main actor. Each call creates a fresh diarizer,
/// so speaker-cache state never leaks between recordings.
private actor LocalNemotronSpeakerEngine {
    private var models: Nemotron3Models?

    func process(
        _ url: URL, config: Nemotron3Config, modelURL: URL, silenceURL: URL
    ) async throws -> [ConversationSpeakerTurn] {
        let samples = try AudioConverter().resampleAudioFile(url)
        let loaded: Nemotron3Models
        if let models {
            loaded = models
        } else {
            let mlConfig = MLModelConfiguration()
            mlConfig.computeUnits = .all
            let model = try MLModel(contentsOf: modelURL, configuration: mlConfig)
            let data = try Data(contentsOf: silenceURL)
            guard data.count == config.preEncoderDims * MemoryLayout<Float>.size else {
                throw ConversationError.invalidSpeakerModels
            }
            let silenceEmbedding = data.withUnsafeBytes {
                Array($0.bindMemory(to: Float.self))
            }
            loaded = try Nemotron3Models(
                config: config, model: model, silenceEmbedding: silenceEmbedding)
            models = loaded
        }
        let diarizer = Nemotron3Diarizer(config: config, models: loaded)
        let output = try diarizer.processComplete(samples)
        return Nemotron3Diarizer.segments(
            probabilities: output.probabilities, frameCount: output.frameCount
        ).map {
            ConversationSpeakerTurn(
                speakerID: String($0.speakerIndex + 1),
                start: Double($0.startSeconds),
                end: Double($0.endSeconds))
        }
    }
}

enum ConversationError: LocalizedError {
    case busy, cancelled, modelsMissing, invalidSpeakerModels, invalidAudio
    var errorDescription: String? {
        switch self {
        case .busy: return "Another recording is still being processed."
        case .cancelled: return "Canceled. No transcript was saved."
        case .modelsMissing: return "The selected model or its support files are missing. Download the required files before transcribing."
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

    func downloadModels(variant: String, speakers: Bool) async throws {
        let id = try begin()
        defer { finish() }
        try checkCancellation()
        try await LocalConversationProcessor.downloadModels(variant: variant, speakers: speakers) { stage, value in
            Task { @MainActor in self.report(id: id, stage: stage, progress: value) }
        }
        try checkCancellation()
        await ModelDownloadService.shared.refreshDownloadedModels()
    }

    func process(_ url: URL, variant: String, detectSpeakers: Bool, singleSpeaker: Bool = false, language: String = "auto") async throws -> ConversationTranscript {
        let id = try begin()
        defer { finish() }
        return try await gate.run {
            try checkCancellation()
            let modelName = AIModel.availableModels.first { $0.variant == variant }?.name ?? variant
            report(id: id, stage: "Transcribing with \(modelName)", progress: 0)
            let words = try await processor.transcribe(url, variant: variant, language: language,
                wordTimestamps: detectSpeakers && !singleSpeaker) { value in
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
                    transcript.warning = languageWarning
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
    struct PreparedAudio {
        let sourceURL: URL
        let processingURL: URL
        let temporaryURL: URL?

        func removeTemporaryFile() {
            guard let temporaryURL else { return }
            try? FileManager.default.removeItem(at: temporaryURL)
        }
    }

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

    /// `AVURLAsset` can identify and play WhatsApp's Ogg/Opus files, while
    /// `AVAudioFile` fails when FluidAudio tries to read their decoded frames.
    /// Keep the imported original for playback/history and use a temporary,
    /// 16 kHz PCM WAV only for local inference. This avoids another lossy encode.
    static func prepareForProcessing(
        _ source: URL,
        transcode: ((URL, URL) async throws -> Void)? = nil
    ) async throws -> PreparedAudio {
        guard source.pathExtension.lowercased() == "opus" else {
            return PreparedAudio(sourceURL: source, processingURL: source, temporaryURL: nil)
        }

        let directory = AppEnvironment.applicationSupportDirectory
            .appendingPathComponent("Processing", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        do {
            if let transcode {
                try await transcode(source, output)
            } else {
                try await transcodeOpus(source, toWAV: output)
            }
            guard FileManager.default.fileExists(atPath: output.path),
                  (try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 0 else {
                throw ConversationError.invalidAudio
            }
            return PreparedAudio(sourceURL: source, processingURL: output, temporaryURL: output)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    private static func transcodeOpus(_ source: URL, toWAV output: URL) async throws {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw ConversationError.invalidAudio
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        guard reader.canAdd(readerOutput) else { throw ConversationError.invalidAudio }
        reader.add(readerOutput)
        let writer = try AVAssetWriter(outputURL: output, fileType: .wav)
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        guard writer.canAdd(writerInput) else { throw ConversationError.invalidAudio }
        writer.add(writerInput)
        guard writer.startWriting(), reader.startReading() else {
            throw writer.error ?? reader.error ?? ConversationError.invalidAudio
        }
        writer.startSession(atSourceTime: .zero)
        do {
            while let sample = readerOutput.copyNextSampleBuffer() {
                try Task.checkCancellation()
                while !writerInput.isReadyForMoreMediaData {
                    try await Task.sleep(for: .milliseconds(2))
                }
                guard writerInput.append(sample) else {
                    throw writer.error ?? ConversationError.invalidAudio
                }
            }
            guard reader.status == .completed else {
                throw reader.error ?? ConversationError.invalidAudio
            }
            writerInput.markAsFinished()
            await writer.finishWriting()
            guard writer.status == .completed else {
                throw writer.error ?? ConversationError.invalidAudio
            }
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            throw error
        }
    }
}

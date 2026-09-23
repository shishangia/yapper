import AVFoundation
import Foundation
import Observation
import Combine

@MainActor
@Observable
final class ConversationSession {
    static let shared = ConversationSession()

    enum Phase: Equatable {
        case idle, preparing, recording, processing, canceling, canceled, completed, failed
    }

    var detectSpeakers = true
    var singleSpeaker = false
    var language = "auto"
    private(set) var phase: Phase = .idle
    private(set) var resultID: UUID?
    private(set) var sourceName = ""
    private(set) var message: String?
    private(set) var retainedAudioURL: URL?
    private(set) var startedAt: Date?
    private(set) var modelsReady = false
    private(set) var activeModel: String?
    private var jobLanguage = "auto"
    private var jobDetectSpeakers = true
    private var jobSingleSpeaker = false
    @ObservationIgnored private let defaults: UserDefaults
    var selectedModel: String { defaults.string(forKey: ModelSelection.defaultsKey) ?? ModelSelection.none }
    var modelName: String {
        let variant = isBusy ? (activeModel ?? selectedModel) : selectedModel
        return AIModel.availableModels.first { $0.variant == variant }?.name ?? "No model selected"
    }
    let service: ConversationService

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var activeID: UUID?
    @ObservationIgnored private var recorder: AudioRecordingService?
    @ObservationIgnored private var recorderObservation: AnyCancellable?
    @ObservationIgnored private let suppliedHistory: HistoryService?

    init(service: ConversationService? = nil, history: HistoryService? = nil, defaults: UserDefaults = .standard) {
        self.service = service ?? ConversationService()
        self.suppliedHistory = history
        self.defaults = defaults
    }

    var isBusy: Bool {
        [.preparing, .recording, .processing, .canceling].contains(phase)
    }

    var status: String {
        switch phase {
        case .idle: return "Ready to transcribe"
        case .preparing: return "Preparing audio"
        case .recording: return "Recording microphone"
        case .processing: return service.stage.isEmpty ? "Preparing local models" : service.stage
        case .canceling: return "Canceling safely"
        case .canceled: return "Canceled"
        case .completed: return "Transcript saved"
        case .failed: return "Needs attention"
        }
    }

    var progress: Double? {
        guard phase == .processing, service.progress > 0 else { return nil }
        return service.progress
    }

    func refreshModels() {
        modelsReady = LocalConversationProcessor.transcriptionModelsReady(variant: selectedModel)
            && (!detectSpeakers || singleSpeaker || LocalConversationProcessor.speakerModelsReady)
    }

    func importFile(_ source: URL) {
        guard let id = begin(name: source.lastPathComponent) else { return }
        task = Task {
            do {
                let copy = try ConversationAudioStorage.importAudio(source)
                await process(copy, id: id)
            } catch {
                finishFailure(error, audio: nil, id: id)
            }
        }
    }

    func retry() {
        guard let audio = retainedAudioURL, let id = begin(name: sourceName) else { return }
        task = Task { await process(audio, id: id) }
    }

    func startRecording() {
        guard let id = begin(name: "Microphone recording") else { return }
        task = Task {
            let allowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
                ? true : await AVCaptureDevice.requestAccess(for: .audio)
            guard activeID == id else { return }
            if phase == .canceling { finishCanceled(id: id); return }
            guard allowed else {
                finishFailure(SessionError.microphonePermission, audio: nil, id: id)
                return
            }
            if recorder == nil {
                recorder = AudioRecordingService(generatesChunks: false)
                recorderObservation = recorder?.$isRecording.dropFirst()
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] recording in
                        guard let self, !recording, self.phase == .recording, let id = self.activeID else { return }
                        self.finishFailure(SessionError.noRecording, audio: nil, id: id)
                    }
            }
            recorder?.startRecording()
            phase = .recording
            task = nil
        }
    }

    func stopRecording() {
        guard phase == .recording, let id = activeID, let recorder else { return }
        phase = .preparing
        task = Task {
            guard let audio = await recorder.stopRecording() else {
                finishFailure(SessionError.noRecording, audio: nil, id: id)
                return
            }
            await process(audio, id: id)
        }
    }

    func downloadModels() {
        guard let id = begin(name: "Conversation models") else { return }
        phase = .processing
        let speakers = jobDetectSpeakers && !jobSingleSpeaker
        let variant = activeModel ?? selectedModel
        task = Task {
            do {
                if phase != .canceling { try await service.downloadModels(variant: variant, speakers: speakers) }
                guard activeID == id else { return }
                if phase == .canceling { finishCanceled(id: id) }
                else { phase = .idle; clearJob(id: id) }
                refreshModels()
            } catch { finishFailure(error, audio: nil, id: id) }
        }
    }

    func cancel() {
        guard isBusy, phase != .canceling, let id = activeID else { return }
        let wasRecording = phase == .recording
        phase = .canceling
        message = nil
        service.cancel()
        if wasRecording, let recorder {
            task = Task {
                _ = await recorder.stopRecording(discardOutput: true)
                finishCanceled(id: id)
            }
        }
    }

    func waitUntilFinished() async {
        await task?.value
    }

    private var history: HistoryService { suppliedHistory ?? .shared }

    private func begin(name: String) -> UUID? {
        guard !isBusy, !UpdateService.shared.isInstalling else { return nil }
        do { try TranscriptionManager.validate(variant: selectedModel, language: language) }
        catch { phase = .failed; message = error.localizedDescription; return nil }
        activeModel = selectedModel
        jobLanguage = language
        jobDetectSpeakers = detectSpeakers
        jobSingleSpeaker = singleSpeaker
        let id = UUID()
        activeID = id
        phase = .preparing
        sourceName = name
        startedAt = Date()
        message = nil
        return id
    }

    private func process(_ audio: URL, id: UUID) async {
        guard activeID == id else { return }
        var keepAudio = false
        var preparedAudio: ConversationAudioStorage.PreparedAudio?
        defer {
            preparedAudio?.removeTemporaryFile()
            if !keepAudio && retainedAudioURL != audio { try? FileManager.default.removeItem(at: audio) }
        }
        do {
            if phase == .canceling { finishCanceled(id: id); return }
            let prepared = try await ConversationAudioStorage.prepareForProcessing(audio)
            preparedAudio = prepared
            if phase == .canceling { finishCanceled(id: id); return }
            let duration = try await ConversationAudioStorage.duration(prepared.processingURL)
            if phase == .canceling { finishCanceled(id: id); return }
            phase = .processing
            let start = Date()
            let variant = activeModel ?? selectedModel
            let transcript = try await service.process(prepared.processingURL, variant: variant, detectSpeakers: jobDetectSpeakers,
                singleSpeaker: jobSingleSpeaker, language: jobLanguage)
            guard activeID == id else { return }
            if phase == .canceling { finishCanceled(id: id); return }
            guard let item = history.addConversation(transcript, duration: duration, audioFileURL: audio,
                modelUsed: AIModel.availableModels.first { $0.variant == variant }?.name ?? variant,
                transcriptionTime: Date().timeIntervalSince(start), id: id) else {
                keepAudio = true
                retainedAudioURL = audio
                finishFailure(SessionError.noSpeech, audio: audio, id: id)
                return
            }
            keepAudio = true
            retainedAudioURL = nil
            resultID = item.id
            phase = .completed
            clearJob(id: id)
        } catch {
            keepAudio = phase != .canceling
            finishFailure(error, audio: keepAudio ? audio : nil, id: id)
        }
    }

    private func finishFailure(_ error: Error, audio: URL?, id: UUID) {
        guard activeID == id else { return }
        if phase == .canceling { finishCanceled(id: id); return }
        phase = .failed
        if let audio { retainedAudioURL = audio }
        message = error.localizedDescription
        clearJob(id: id)
    }

    private func finishCanceled(id: UUID) {
        guard activeID == id else { return }
        phase = .canceled
        message = "No new transcript was saved."
        clearJob(id: id)
    }

    private func clearJob(id: UUID) {
        guard activeID == id else { return }
        activeID = nil
        task = nil
    }

    enum SessionError: LocalizedError {
        case microphonePermission, noRecording, noSpeech
        var errorDescription: String? {
            switch self {
            case .microphonePermission: return "Enable Yapper in System Settings > Privacy & Security > Microphone."
            case .noRecording: return "No audio was captured. Check the selected microphone and try again."
            case .noSpeech: return "No speech was transcribed. Your audio is retained so you can review or retry it."
            }
        }
    }
}

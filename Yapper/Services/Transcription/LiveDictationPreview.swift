import Foundation

@MainActor
@Observable
final class LiveDictationPreview {
    private(set) var text = ""
    private var sessionID: UUID?
    private(set) var captureID: UUID?
    private var activeTask: Task<Void, Never>?
    private var activeCapture: UUID?
    private var skippedChunk = false
    private let transcribe: (URL, RecorderJob.Snapshot, @escaping () -> Bool) async throws -> String
    init(transcribe: @escaping (URL, RecorderJob.Snapshot, @escaping () -> Bool) async throws -> String = { url, snapshot, current in
        try await TranscriptionManager.shared.preview(audioFile: url, variant: snapshot.model, language: snapshot.language, isCurrent: current)
    }) { self.transcribe = transcribe }
    @discardableResult
    func begin(_ id: UUID) -> UUID {
        let capture = UUID(); captureID = capture
        sessionID = id; text = ""; skippedChunk = false
        return capture
    }
    /// Cancels the in-flight chunk so the final transcription does not queue behind it.
    func stop() { sessionID = nil; captureID = nil; activeTask?.cancel(); activeTask = nil; activeCapture = nil }
    func accept(_ url: URL, snapshot: RecorderJob.Snapshot) {
        guard sessionID == snapshot.id else {
            try? FileManager.default.removeItem(at: url); return
        }
        guard activeTask == nil else { skippedChunk = true; try? FileManager.default.removeItem(at: url); return }
        let gap = skippedChunk; skippedChunk = false
        let capture = captureID
        activeCapture = capture
        activeTask = Task {
            defer {
                try? FileManager.default.removeItem(at: url)
                if activeCapture == capture { activeTask = nil; activeCapture = nil }
            }
            do {
                let draft = try await transcribe(url, snapshot, { self.sessionID == snapshot.id && self.captureID == capture })
                guard sessionID == snapshot.id, captureID == capture else { return }
                let result = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                if !result.isEmpty { text = String((text + (text.isEmpty ? "" : gap ? " … " : " ") + result).suffix(500)) }
            } catch { } // The full recording remains authoritative if preview fails.
        }
    }
}

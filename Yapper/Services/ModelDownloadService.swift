import Foundation
import Combine
import FluidAudio
import WhisperKit

struct ModelCacheCleanupReport {
    let deletedPaths: [URL]
    let checkedPaths: [URL]
}

/// Resolves and removes cache directories for a WhisperKit model variant.
///
/// Safety (from #65): cleanup is limited to the exact per-variant subdirectories
/// Yapper itself owns — never a broad substring match over generic locations
/// (Caches root, home dir, temp, `.cache/huggingface`) that could delete unrelated
/// files. Storage layout (from #90 / `ModelStorage`): the only roots Yapper
/// writes CoreML variants into are the current Application Support location and the
/// legacy `~/Documents/huggingface` location.
enum ModelCachePathResolver {
    /// The WhisperKit model roots Yapper owns and is allowed to clean up:
    /// `<AppSupport>/Yapper/models/argmaxinc/whisperkit-coreml` plus the legacy
    /// `~/Documents/huggingface/models/argmaxinc/whisperkit-coreml`.
    static func repoOwnedModelRoots() -> [URL] {
        var roots = [ModelStorage.whisperKitModelsDir]
        if let legacy = ModelStorage.legacyModelsDir { roots.append(legacy) }
        return roots
    }

    /// Exact per-variant candidate directories under the given repo-owned roots.
    ///
    /// For each root we consider both the slash ("openai/whisper-medium") and the
    /// underscore ("openai_whisper-medium") spelling of the variant, plus any exact
    /// `variant`-named directory found nested under the root (e.g. a hub-style
    /// `.../snapshots/<hash>/<variant>` layout). Directories whose names merely
    /// *contain* the variant (e.g. "<variant>-backup") are never matched.
    static func candidatePaths(
        for variant: String,
        roots: [URL],
        fileManager: FileManager = .default
    ) -> [URL] {
        var candidates = Set<URL>()

        for root in roots {
            for name in variantDirectoryNames(for: variant) {
                candidates.insert(root.appendingPathComponent(name, isDirectory: true))
            }
            for match in exactVariantDirectories(named: variant, under: root, fileManager: fileManager) {
                candidates.insert(match)
            }
        }

        return candidates.sorted { $0.path < $1.path }
    }

    static func removeVariantDirectories(
        for variant: String,
        roots: [URL],
        fileManager: FileManager = .default,
        log: ((String) -> Void)? = nil
    ) -> ModelCacheCleanupReport {
        let candidates = candidatePaths(for: variant, roots: roots, fileManager: fileManager)
        var deletedPaths: [URL] = []

        for candidate in candidates where fileManager.fileExists(atPath: candidate.path) {
            do {
                try fileManager.removeItem(at: candidate)
                deletedPaths.append(candidate)
                log?("✅ Deleted cache: \(candidate.path)")
            } catch {
                log?("❌ Failed to delete \(candidate.path): \(error)")
            }
        }

        return ModelCacheCleanupReport(deletedPaths: deletedPaths, checkedPaths: candidates)
    }

    private static func variantDirectoryNames(for variant: String) -> [String] {
        Array(Set([variant, variant.replacingOccurrences(of: "/", with: "_")]))
    }

    private static func exactVariantDirectories(
        named variant: String,
        under root: URL,
        fileManager: FileManager = .default
    ) -> [URL] {
        guard fileManager.fileExists(atPath: root.path) else { return [] }

        guard
            let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return []
        }

        var matches: [URL] = []

        for case let url as URL in enumerator {
            guard url.lastPathComponent == variant else { continue }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { continue }
            matches.append(url)
            enumerator.skipDescendants()
        }

        return matches
    }
}

@MainActor
final class ModelDownloadService: ObservableObject {
    static let shared = ModelDownloadService()

    @Published private(set) var downloadProgress: [String: Double] = [:]
    @Published private(set) var downloadError: [String: String] = [:]
    @Published private(set) var isDownloading: [String: Bool] = [:]
    @Published private(set) var isCanceling: [String: Bool] = [:]

    private struct Job {
        let id: UUID
        let task: Task<Void, Error>
    }

    private var jobs: [String: Job] = [:]
    private var tokenizerJobs: [URL: Task<Void, Error>] = [:]
    private var deletingVariants = Set<String>()
    private let downloadWeights: (String, @escaping @Sendable (Double) -> Void) async throws -> Void
    private let downloadTokenizer: (String) async throws -> Void
    private let isReady: (String) -> Bool
    private let didDownload: (String) -> Void

    init(
        downloadWeights: @escaping (String, @escaping @Sendable (Double) -> Void) async throws -> Void,
        downloadTokenizer: @escaping (String) async throws -> Void,
        isReady: @escaping (String) -> Bool,
        didDownload: @escaping (String) -> Void = { _ in }
    ) {
        self.downloadWeights = downloadWeights
        self.downloadTokenizer = downloadTokenizer
        self.isReady = isReady
        self.didDownload = didDownload
    }

    private convenience init() {
        self.init(downloadWeights: { variant, progress in
            if AIModel.engineKind(for: variant) == .parakeet {
                let version = ParakeetCatalog.version(for: variant)
                _ = try await AsrModels.download(to: ModelStorage.parakeetCacheDirectory(for: version),
                    version: version, progressHandler: { progress($0.fractionCompleted) })
            } else {
                ModelStorage.ensureWhisperKitModelsDir()
                _ = try await WhisperKit.download(variant: variant, downloadBase: ModelStorage.whisperKitBase,
                    progressCallback: { progress($0.fractionCompleted) })
            }
        }, downloadTokenizer: { variant in
            guard let model = ModelStorage.whisperVariant(for: variant) else { throw ConversationError.modelsMissing }
            _ = try await ModelUtilities.loadTokenizer(for: model, tokenizerFolder: ModelStorage.whisperKitBase)
        }, isReady: { variant in
            guard ModelStorage.transcriptionModelReady(variant) else { return false }
            if AIModel.engineKind(for: variant) == .parakeet { return true }
            let bytes = Self.calculateDirectorySize(at: ModelStorage.whisperKitModelsDir.appendingPathComponent(variant))
            return bytes >= Int64(Double(AIModel.expectedSize(for: variant)) * 0.8)
        }, didDownload: { _ in
            TranscriptionManager.shared.warmSelectedModel()
        })
        Task { await refreshDownloadedModels() }
    }

    func refreshDownloadedModels() async {
        var merged = downloadProgress.filter { jobs[$0.key] != nil }
        for model in AIModel.availableModels where jobs[model.variant] == nil && !deletingVariants.contains(model.variant) {
            if isReady(model.variant) { merged[model.variant] = 1 }
        }
        downloadProgress = merged
    }

    func downloadAndWait(variant: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        try Task.checkCancellation()
        guard AIModel.availableModels.contains(where: { $0.variant == variant }) else {
            throw TranscriptionManager.ModelError.noSelection
        }
        guard !deletingVariants.contains(variant) else { throw ConversationError.busy }
        if jobs[variant] == nil, isReady(variant) { progress(1); return }
        downloadModel(variant: variant)
        guard let job = jobs[variant] else { throw ConversationError.modelsMissing }
        let observation = $downloadProgress.sink { progress($0[variant] ?? 0) }
        defer { observation.cancel() }
        try await job.task.value
        try Task.checkCancellation()
    }

    func downloadModel(variant: String) {
        guard jobs[variant] == nil, !deletingVariants.contains(variant),
              AIModel.availableModels.contains(where: { $0.variant == variant }) else { return }
        let id = UUID()
        isDownloading[variant] = true
        isCanceling[variant] = false
        downloadProgress[variant] = 0
        downloadError[variant] = nil
        let task = Task<Void, Error> {
            do {
                try await downloadWeights(variant) { value in
                    Task { @MainActor in self.report(value, variant: variant, id: id) }
                }
                try Task.checkCancellation()
                if AIModel.engineKind(for: variant) == .whisper {
                    report(1, variant: variant, id: id)
                    try await ensureTokenizer(for: variant)
                }
                try Task.checkCancellation()
                guard isReady(variant) else { throw ConversationError.modelsMissing }
                finish(variant: variant, id: id, error: nil)
                didDownload(variant)
            } catch {
                let outcome: Error = Task.isCancelled ? CancellationError() : error
                finish(variant: variant, id: id, error: outcome)
                throw outcome
            }
        }
        jobs[variant] = Job(id: id, task: task)
    }

    private func ensureTokenizer(for variant: String) async throws {
        guard let key = ModelStorage.tokenizerDirectory(for: variant) else { throw ConversationError.modelsMissing }
        if let task = tokenizerJobs[key] { try await task.value; return }
        // Large v3 and Turbo share files; canceling either job must not cancel the shared writer.
        let task = Task { try await downloadTokenizer(variant) }
        tokenizerJobs[key] = task
        defer { tokenizerJobs[key] = nil }
        try await task.value
    }

    private func report(_ value: Double, variant: String, id: UUID) {
        guard jobs[variant]?.id == id, isCanceling[variant] != true, value.isFinite else { return }
        downloadProgress[variant] = max(downloadProgress[variant] ?? 0, min(0.99, max(0, value)))
    }

    private func finish(variant: String, id: UUID, error: Error?) {
        guard jobs[variant]?.id == id else { return }
        jobs[variant] = nil
        isDownloading[variant] = false
        isCanceling[variant] = false
        downloadProgress[variant] = error == nil ? 1 : 0
        downloadError[variant] = error.map { $0 is CancellationError ? "Download canceled. You can retry when ready." : Self.message(for: $0) }
    }

    func cancelDownload(for variant: String) {
        guard let job = jobs[variant] else { return }
        isCanceling[variant] = true
        job.task.cancel()
    }

    func deleteModel(variant: String) async -> String {
        guard jobs[variant] == nil, !deletingVariants.contains(variant) else { return "Wait for the download to finish before deleting this model." }
        deletingVariants.insert(variant)
        defer { deletingVariants.remove(variant) }
        return await NativeInferenceGate.shared.run {
            await TranscriptionManager.shared.unloadWhileLocked(variant: variant)
            let result = removeModelFiles(variant: variant)
            downloadProgress[variant] = isReady(variant) ? 1 : 0
            downloadError[variant] = nil
            return result
        }
    }

    private func removeModelFiles(variant: String) -> String {
        if AIModel.engineKind(for: variant) == .parakeet {
            let cacheDir = ModelStorage.parakeetCacheDirectory(for: ParakeetCatalog.version(for: variant))
            do {
                if FileManager.default.fileExists(atPath: cacheDir.path) { try FileManager.default.removeItem(at: cacheDir) }
                return "Deleted Parakeet model cache for \(variant)"
            } catch { return error.localizedDescription }
        }
        let report = ModelCachePathResolver.removeVariantDirectories(for: variant,
            roots: ModelCachePathResolver.repoOwnedModelRoots())
        return "Deleted \(report.deletedPaths.count) model caches"
    }

    nonisolated static func message(for error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost:
                return "The download could not connect. Check your internet connection and retry."
            case NSURLErrorTimedOut:
                return "The download timed out. Check your connection and retry."
            default: break
            }
        }
        if (nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteOutOfSpaceError)
            || (nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOSPC)) {
            return "There is not enough disk space. Free some space and retry."
        }
        let description = error.localizedDescription
        if description.range(of: #"\b429\b|too many requests"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return "The model server is busy. Wait a little and retry."
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error { return message(for: underlying) }
        return "Download failed. \(description) You can retry without deleting other models."
    }

    nonisolated static func calculateDirectorySize(at url: URL) -> Int64 {
        let fileManager = FileManager.default
        var totalSize: Int64 = 0
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [.skipsHiddenFiles]) else { return 0 }
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true else { continue }
            totalSize += Int64(values.fileSize ?? 0)
        }
        return totalSize
    }

    nonisolated static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

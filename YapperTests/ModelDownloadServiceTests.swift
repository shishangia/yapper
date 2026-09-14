import XCTest
@testable import Yapper

final class ModelDownloadServiceTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }
    
    @MainActor
    func testInitialState() {
        let service = ModelDownloadService.shared
        
        // Ensure no lingering downloads from other runs
        // (Note: Shared singleton might have state if tests run in parallel or sequence without clearing)
        // We can't easily clear private vars, but we can check types.
        
        XCTAssertNotNil(service.downloadProgress)
        XCTAssertNotNil(service.isDownloading)
    }

    func testCandidatePathsStayWithinRepoOwnedRoots() throws {
        // Simulate the two repo-owned WhisperKit model roots (current App Support +
        // legacy Documents), matching ModelStorage's `.../models/argmaxinc/whisperkit-coreml`.
        let currentRoot = try createDirectory(
            at: tempRoot.appendingPathComponent(
                "AppSupport/Yapper/models/argmaxinc/whisperkit-coreml"))
        let legacyRoot = try createDirectory(
            at: tempRoot.appendingPathComponent(
                "Documents/huggingface/models/argmaxinc/whisperkit-coreml"))
        let roots = [currentRoot, legacyRoot]
        let variant = "openai_whisper-medium"

        let directPath = try createDirectory(at: currentRoot.appendingPathComponent(variant))
        // A hub-style nested layout under a repo-owned root should still be found by
        // exact-name matching.
        let nestedPath = try createDirectory(
            at: legacyRoot.appendingPathComponent("snapshots/123/\(variant)"))
        // A directory that only *contains* the variant name must NOT be a candidate.
        _ = try createDirectory(at: currentRoot.appendingPathComponent("\(variant)-backup"))
        // A model outside any repo-owned root must NOT be a candidate.
        _ = try createDirectory(at: tempRoot.appendingPathComponent(variant))

        let candidatePaths = ModelCachePathResolver.candidatePaths(
            for: variant,
            roots: roots
        )
        let normalizedCandidatePaths = Set(candidatePaths.map(normalizedPath))

        XCTAssertTrue(normalizedCandidatePaths.contains(normalizedPath(directPath)))
        XCTAssertTrue(normalizedCandidatePaths.contains(normalizedPath(nestedPath)))
        XCTAssertFalse(
            normalizedCandidatePaths.contains(
                normalizedPath(currentRoot.appendingPathComponent("\(variant)-backup"))
            )
        )
        XCTAssertFalse(
            normalizedCandidatePaths.contains(
                normalizedPath(tempRoot.appendingPathComponent(variant))
            )
        )
    }

    func testRemoveVariantDirectoriesOnlyDeletesExactRepoOwnedMatches() throws {
        let currentRoot = try createDirectory(
            at: tempRoot.appendingPathComponent(
                "AppSupport/Yapper/models/argmaxinc/whisperkit-coreml"))
        let legacyRoot = try createDirectory(
            at: tempRoot.appendingPathComponent(
                "Documents/huggingface/models/argmaxinc/whisperkit-coreml"))
        let roots = [currentRoot, legacyRoot]
        let variant = "openai_whisper-medium"

        let directPath = try createDirectory(at: currentRoot.appendingPathComponent(variant))
        let nestedPath = try createDirectory(
            at: legacyRoot.appendingPathComponent("snapshots/abc123/\(variant)"))
        // "<variant>-backup" lives inside a repo-owned root but its name only contains
        // the variant — it must survive.
        let backupPath = try createDirectory(
            at: currentRoot.appendingPathComponent("\(variant)-backup"))
        // An unrelated directory outside any repo-owned root must survive.
        let unrelatedPath = try createDirectory(
            at: tempRoot.appendingPathComponent("\(variant)-notes"))

        let report = ModelCachePathResolver.removeVariantDirectories(
            for: variant,
            roots: roots
        )

        XCTAssertEqual(
            Set(report.deletedPaths.map(normalizedPath)),
            Set([directPath, nestedPath].map(normalizedPath))
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: directPath.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: nestedPath.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupPath.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedPath.path))
    }

    @MainActor
    func testRefreshPreservesProgressUntilSupportFilesFinish() async throws {
        let variant = "openai_whisper-large-v3_turbo"
        var ready = false
        var resumeTokenizer: CheckedContinuation<Void, Never>?
        let started = expectation(description: "Tokenizer started")
        let service = ModelDownloadService(downloadWeights: { _, report in report(1) }, downloadTokenizer: { _ in
            await withCheckedContinuation { resumeTokenizer = $0; started.fulfill() }
        }, isReady: { _ in ready })
        let task = Task { try await service.downloadAndWait(variant: variant) { _ in } }
        await fulfillment(of: [started], timeout: 2)
        ready = true
        await service.refreshDownloadedModels()
        XCTAssertEqual(service.downloadProgress[variant], 0.99)
        XCTAssertEqual(service.isDownloading[variant], true)
        resumeTokenizer?.resume()
        try await task.value
        XCTAssertEqual(service.downloadProgress[variant], 1)
        XCTAssertEqual(service.isDownloading[variant], false)
    }

    @MainActor
    func testCanceledJobRetainsOwnershipAndRejectsLateProgress() async throws {
        let variant = "openai_whisper-large-v3_turbo"
        var ready = false
        var resumes: [CheckedContinuation<Void, Never>] = []
        var reports: [@Sendable (Double) -> Void] = []
        let firstStarted = expectation(description: "First download started")
        let secondStarted = expectation(description: "Retry started")
        let service = ModelDownloadService(downloadWeights: { _, report in
            reports.append(report)
            await withCheckedContinuation {
                resumes.append($0)
                if resumes.count == 1 { firstStarted.fulfill() } else { secondStarted.fulfill() }
            }
        }, downloadTokenizer: { _ in }, isReady: { _ in ready })
        let first = Task { try await service.downloadAndWait(variant: variant) { _ in } }
        await fulfillment(of: [firstStarted], timeout: 2)
        service.cancelDownload(for: variant)
        service.downloadModel(variant: variant)
        XCTAssertEqual(service.isDownloading[variant], true)
        XCTAssertEqual(service.isCanceling[variant], true)
        XCTAssertEqual(resumes.count, 1)
        ready = true
        resumes[0].resume()
        do { try await first.value; XCTFail("Cancellation must not become success because files exist") }
        catch { XCTAssertTrue(error is CancellationError) }
        ready = false
        let second = Task { try await service.downloadAndWait(variant: variant) { _ in } }
        await fulfillment(of: [secondStarted], timeout: 2)
        reports[0](1)
        await Task.yield()
        XCTAssertEqual(service.downloadProgress[variant], 0)
        ready = true
        resumes[1].resume()
        try await second.value
        XCTAssertNil(service.downloadError[variant])
    }

    @MainActor
    func testSharedTokenizerSurvivesOneCanceledDownload() async throws {
        let large = "openai_whisper-large-v3"
        let turbo = "openai_whisper-large-v3_turbo"
        var ready = false
        var tokenizerCalls = 0
        var resume: CheckedContinuation<Void, Never>?
        let tokenizerStarted = expectation(description: "Shared tokenizer started")
        let turboWeights = expectation(description: "Turbo weights ready")
        let service = ModelDownloadService(downloadWeights: { variant, _ in
            if variant == turbo { turboWeights.fulfill() }
        }, downloadTokenizer: { _ in
            tokenizerCalls += 1
            await withCheckedContinuation { resume = $0; tokenizerStarted.fulfill() }
        }, isReady: { _ in ready })
        let first = Task { try await service.downloadAndWait(variant: large) { _ in } }
        await fulfillment(of: [tokenizerStarted], timeout: 2)
        let second = Task { try await service.downloadAndWait(variant: turbo) { _ in } }
        await fulfillment(of: [turboWeights], timeout: 2)
        service.cancelDownload(for: large)
        XCTAssertEqual(tokenizerCalls, 1)
        ready = true
        resume?.resume()
        do { try await first.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        try await second.value
        XCTAssertEqual(service.downloadProgress[turbo], 1)
        XCTAssertEqual(tokenizerCalls, 1)
    }

    @MainActor
    func testJoinedDownloadPropagatesFailure() async {
        let variant = "openai_whisper-large-v3_turbo"
        let started = expectation(description: "Download started")
        var resume: CheckedContinuation<Void, Never>?
        let service = ModelDownloadService(downloadWeights: { _, _ in
            await withCheckedContinuation { resume = $0; started.fulfill() }
            throw URLError(.notConnectedToInternet)
        }, downloadTokenizer: { _ in XCTFail("Must not start tokenizer") }, isReady: { _ in false })
        service.downloadModel(variant: variant)
        await fulfillment(of: [started], timeout: 2)
        let waiter = Task { try await service.downloadAndWait(variant: variant) { _ in } }
        await Task.yield()
        resume?.resume()
        do { try await waiter.value; XCTFail("Expected download error") }
        catch { XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet) }
        XCTAssertTrue(service.downloadError[variant]?.contains("internet") == true)
        XCTAssertEqual(service.isDownloading[variant], false)
    }

    @MainActor
    func testDownloadCompletionDoesNotSelectOrWaitForWarmup() async throws {
        let variant = ParakeetCatalog.v3Variant
        var ready = false
        var completed: [String] = []
        let service = ModelDownloadService(downloadWeights: { _, _ in ready = true },
            downloadTokenizer: { _ in XCTFail("Parakeet must not use a Whisper tokenizer") },
            isReady: { _ in ready }, didDownload: { completed.append($0) })
        try await service.downloadAndWait(variant: variant) { _ in }
        XCTAssertEqual(completed, [variant])
        XCTAssertEqual(service.downloadProgress[variant], 1)
        XCTAssertEqual(service.isDownloading[variant], false)
    }

    func testFriendlyDownloadErrors() {
        XCTAssertTrue(ModelDownloadService.message(for: URLError(.timedOut)).contains("timed out"))
        XCTAssertTrue(ModelDownloadService.message(for: CocoaError(.fileWriteOutOfSpace)).contains("disk space"))
        let rateLimit = NSError(domain: "server", code: 429, userInfo: [NSLocalizedDescriptionKey: "HTTP 429"])
        XCTAssertTrue(ModelDownloadService.message(for: rateLimit).contains("server is busy"))
    }

    @discardableResult
    private func createDirectory(at url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func normalizedPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        if path.hasPrefix("/private/var/") {
            return path.replacingOccurrences(
                of: "/private/var/",
                with: "/var/",
                options: [.anchored]
            )
        }
        return path
    }
}

import XCTest
@testable import Yapper

@MainActor
final class LiveDictationPreviewTests: XCTestCase {
    func testPreviewDropsBacklogAndRejectsOldRecordingResults() async throws {
        var resume: CheckedContinuation<String, Never>?
        var calls = 0
        let preview = LiveDictationPreview { _, _, _ in
            calls += 1
            return await withCheckedContinuation { resume = $0 }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = RecorderJob.Snapshot(model: "unused", language: "en", targetPID: nil)
        let old = root.appendingPathComponent("old.wav")
        let excess = root.appendingPathComponent("excess.wav")
        try Data().write(to: old); try Data().write(to: excess)
        preview.begin(first.id); preview.accept(old, snapshot: first)
        while resume == nil { await Task.yield() }
        preview.accept(excess, snapshot: first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: excess.path))
        XCTAssertEqual(calls, 1)
        preview.stop()
        let next = RecorderJob.Snapshot(model: "unused", language: "en", targetPID: nil)
        preview.begin(next.id)
        resume?.resume(returning: "stale text")
        while FileManager.default.fileExists(atPath: old.path) { await Task.yield() }
        XCTAssertTrue(preview.text.isEmpty)
    }

    func testStopCancelsInFlightPreviewChunk() async throws {
        let started = expectation(description: "chunk started")
        let cancelled = expectation(description: "chunk cancelled")
        let preview = LiveDictationPreview { _, _, _ in
            started.fulfill()
            do { try await Task.sleep(for: .seconds(30)) } catch { cancelled.fulfill(); throw error }
            return "late"
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try Data().write(to: url)
        let snapshot = RecorderJob.Snapshot(model: "unused", language: "en", targetPID: nil)
        preview.begin(snapshot.id); preview.accept(url, snapshot: snapshot)
        await fulfillment(of: [started], timeout: 2)
        preview.stop()
        await fulfillment(of: [cancelled], timeout: 2)
        XCTAssertTrue(preview.text.isEmpty)
    }
}

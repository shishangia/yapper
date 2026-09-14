import XCTest
import AVFoundation
@testable import Yapper

final class AudioRecordingServiceTests: XCTestCase {
    
    var service: AudioRecordingService!
    
    override func setUpWithError() throws {
        service = AudioRecordingService()
    }

    override func tearDownWithError() throws {
        service = nil
    }

    func testInitialization() {
        XCTAssertNotNil(service)
        XCTAssertFalse(service.isRecording)
        XCTAssertEqual(service.audioLevel, 0.0)
    }
    
    func testStopRecordingWhenNotRecording() async {
        let url = await service.stopRecording()
        XCTAssertNil(url, "Should return nil url when not recording")
    }
    
    @MainActor
    func testRecorderCancellationKeepsOwnershipUntilNativeWorkEnds() async throws {
        let job = RecorderJob()
        let first = try XCTUnwrap(job.begin(model: "first", language: "en", targetPID: 1))
        XCTAssertTrue(job.transition(first.id, from: .preparing, to: .recording))
        XCTAssertTrue(job.transition(first.id, from: .recording, to: .stopping))
        XCTAssertFalse(job.transition(first.id, from: .recording, to: .stopping))
        job.cancel()
        XCTAssertFalse(job.isPresented)
        XCTAssertTrue(job.isBusy)
        XCTAssertFalse(job.canCommit(first.id))
        XCTAssertNil(job.begin(model: "second", language: "hi", targetPID: 2))
        XCTAssertTrue(job.transition(first.id, from: .stopping, to: .processing))
        job.finish(first.id)
        let second = try XCTUnwrap(job.begin(model: "second", language: "hi", targetPID: 2))
        job.finish(first.id)
        job.dismiss(first.id)
        XCTAssertFalse(job.transition(first.id, from: .processing, to: .committing))
        XCTAssertTrue(job.isPresented)
        XCTAssertTrue(job.canCommit(second.id))
        XCTAssertEqual(job.snapshot?.model, "second")
        XCTAssertEqual(job.snapshot?.targetPID, 2)
    }

    @MainActor
    func testEscapeSuppressesPendingPasteWhileKeepingAdmissionClosed() async throws {
        let job = RecorderJob()
        let snapshot = try XCTUnwrap(job.begin(model: "model", language: "auto", targetPID: 1))
        XCTAssertTrue(job.transition(snapshot.id, from: .preparing, to: .processing))
        XCTAssertTrue(job.transition(snapshot.id, from: .processing, to: .committing))
        job.dismiss(snapshot.id)
        XCTAssertTrue(job.isBusy)
        job.cancel()
        XCTAssertFalse(job.canCommit(snapshot.id))
        XCTAssertNil(job.begin(model: "other", language: "en", targetPID: 2))
        job.finish(snapshot.id)
        XCTAssertFalse(job.isBusy)
    }

    @MainActor
    func testFailedPlaybackClearsPreviouslyLoadedAudio() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600))
        buffer.frameLength = 1600
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
        let player = AudioPlayerService.shared
        defer { player.reset() }
        player.loadAudio(from: url)
        XCTAssertEqual(player.currentAudioURL, url)
        XCTAssertGreaterThan(player.duration, 0)
        player.loadAudio(from: url.appendingPathExtension("missing"))
        XCTAssertNil(player.currentAudioURL)
        XCTAssertEqual(player.duration, 0)
        player.play()
        XCTAssertFalse(player.isPlaying)
    }

    func testShortcutHintUsesSelectedKeyAndMode() {
        XCTAssertEqual(HotkeyOption.default.recordingHint(mode: 0), "Hold Fn to record, then release to transcribe.")
        XCTAssertEqual(HotkeyOption.rightOption.recordingHint(mode: 1), "Press Right ⌥ to record, then press again to transcribe.")
    }
}

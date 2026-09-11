import XCTest
@testable import Yapper

@MainActor
final class HistoryServiceTests: XCTestCase {
    var service: HistoryService!
    var defaults: UserDefaults!
    var suite: String!

    override func setUp() {
        super.setUp()
        suite = "Yapper-Tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        service = HistoryService(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        service = nil
        defaults = nil
        super.tearDown()
    }
    
    func testAddItem() {
        XCTAssertTrue(service.items.isEmpty)
        
        let transcript = "Test Transcript"
        let duration: TimeInterval = 10.0
        
        service.addItem(transcript: transcript, duration: duration)
        
        XCTAssertEqual(service.items.count, 1)
        XCTAssertEqual(service.items.first?.transcript, transcript)
        XCTAssertEqual(service.items.first?.duration, duration)
    }
    
    func testPersistence() {
        let transcript = "Persistent Item"
        service.addItem(transcript: transcript, duration: 5.0)
        
        // Simulate app restart by re-initializing (or checking UserDefaults directly)
        // Since 'init' loads from UserDefaults, creating a new instance isn't easy with singleton,
        // but we can check if UserDefaults has the data.
        
        guard let data = defaults.data(forKey: "history_items"),
              let decoded = try? JSONDecoder().decode([HistoryItem].self, from: data) else {
            XCTFail("Failed to load from UserDefaults")
            return
        }
        
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.transcript, transcript)
    }
    
    func testDeleteItem() {
        service.addItem(transcript: "Item 1", duration: 1.0)
        service.addItem(transcript: "Item 2", duration: 2.0)
        
        XCTAssertEqual(service.items.count, 2)
        
        let itemToDelete = service.items.last! // "Item 1" (since newest is first)
        service.deleteItem(id: itemToDelete.id)
        
        XCTAssertEqual(service.items.count, 1)
        XCTAssertEqual(service.items.first?.transcript, "Item 2")
    }

    func testDeleteItemRemovesAudioFileWhenPresent() throws {
        try FileManager.default.createDirectory(at: AppEnvironment.applicationSupportDirectory, withIntermediateDirectories: true)
        let audioURL = AppEnvironment.applicationSupportDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")
        try Data("audio".utf8).write(to: audioURL)

        service.addItem(
            transcript: "Item with audio",
            duration: 1.0,
            audioFileURL: audioURL
        )

        let itemID = try XCTUnwrap(service.items.first?.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))

        service.deleteItem(id: itemID)

        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertTrue(service.items.isEmpty)
    }

    func testClearAllPreservesStatsHistory() {
        service.addItem(transcript: "One short note", duration: 10.0)
        service.addItem(transcript: "Another slightly longer note", duration: 20.0)

        let countBeforeClear = service.transcriptionCount()
        let wordsBeforeClear = service.totalWordCount()
        let durationBeforeClear = service.totalDuration()

        service.clearAll()

        XCTAssertTrue(service.items.isEmpty)
        XCTAssertEqual(service.transcriptionCount(), countBeforeClear)
        XCTAssertEqual(service.totalWordCount(), wordsBeforeClear)
        XCTAssertEqual(service.totalDuration(), durationBeforeClear)
    }

    func testLegacyHistoryLoadsWithoutRewriting() async throws {
        let raw = "[{\"id\":\"00000000-0000-0000-0000-000000000001\",\"date\":0,\"transcript\":\"  um [SILENCE] original  \",\"duration\":3}]".data(using: .utf8)!
        defaults.set(raw, forKey: "history_items")
        let reopened = HistoryService(defaults: defaults)
        XCTAssertNil(reopened.items.first?.conversation)
        XCTAssertEqual(reopened.items.first?.transcript, "  um [SILENCE] original  ")
        XCTAssertEqual(defaults.data(forKey: "history_items"), raw)
        XCTAssertEqual(reopened.statsEntries.count, 1)
        XCTAssertEqual(HistoryService(defaults: defaults).statsEntries.count, 1)
    }

    func testConversationRenamePersistsWithoutChangingStatsOrOtherRecordings() async throws {
        let conversation = ConversationTranscript(segments: [
            .init(id: 0, start: 0, end: 1, text: " um German", speakerID: "1"),
            .init(id: 1, start: 1, end: 2, text: " hello", speakerID: "2"),
            .init(id: 2, start: 2, end: 3, text: " again", speakerID: "1")
        ], speakerDetectionRequested: true)
        let first = try XCTUnwrap(service.addConversation(conversation, duration: 3))
        let second = try XCTUnwrap(service.addConversation(conversation, duration: 3))
        let stats = defaults.data(forKey: "history_stats_entries")
        XCTAssertTrue(service.renameSpeaker(itemID: first.id, speakerID: "1", name: "  Alice  "))
        let reopened = HistoryService(defaults: defaults)
        let renamed = try XCTUnwrap(reopened.items.first { $0.id == first.id })
        XCTAssertEqual(renamed.transcript, " um German hello again")
        XCTAssertEqual(renamed.conversation?.segments, conversation.segments)
        XCTAssertEqual(renamed.displayText.components(separatedBy: "Alice:").count - 1, 2)
        XCTAssertEqual(reopened.items.first { $0.id == second.id }?.conversation?.speakerName(for: "1"), "Speaker 1")
        XCTAssertEqual(reopened.items.count, 2)
        XCTAssertEqual(reopened.statsEntries.count, 2)
        XCTAssertEqual(defaults.data(forKey: "history_stats_entries"), stats)
        XCTAssertEqual(renamed.date, first.date)
    }

    func testRenameValidationAndReset() throws {
        let transcript = ConversationTranscript(segments: [.init(id: 0, start: 0, end: 1, text: "hi", speakerID: "1")], speakerDetectionRequested: true)
        let item = try XCTUnwrap(service.addConversation(transcript, duration: 1))
        for invalid in ["Alice\nBob", "A\tB", String(repeating: "x", count: 81)] {
            XCTAssertFalse(service.renameSpeaker(itemID: item.id, speakerID: "1", name: invalid))
        }
        XCTAssertFalse(service.renameSpeaker(itemID: item.id, speakerID: "missing", name: "Alice"))
        XCTAssertFalse(service.renameSpeaker(itemID: UUID(), speakerID: "1", name: "Alice"))
        XCTAssertTrue(service.renameSpeaker(itemID: item.id, speakerID: "1", name: "Alice"))
        XCTAssertTrue(service.renameSpeaker(itemID: item.id, speakerID: "1", name: "Alice"))
        XCTAssertTrue(service.renameSpeaker(itemID: item.id, speakerID: "1", name: "   "))
        XCTAssertEqual(service.items.first?.conversation?.speakerName(for: "1"), "Speaker 1")
    }

    func testEmptyConversationDoesNotCreateHistoryOrStats() {
        let transcript = ConversationTranscript(segments: [.init(id: 0, start: 0, end: 1, text: " \n", speakerID: nil)], speakerDetectionRequested: true)
        XCTAssertNil(service.addConversation(transcript, duration: 1))
        XCTAssertTrue(service.items.isEmpty)
        XCTAssertTrue(service.statsEntries.isEmpty)
    }

    func testIsolatedDeletionNeverFollowsLegacyAudioPath() throws {
        let external = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("copied fixture".utf8).write(to: external)
        defer { try? FileManager.default.removeItem(at: external) }
        service.addItem(transcript: "legacy path", duration: 1, audioFileURL: external)
        service.clearAll()
        XCTAssertTrue(FileManager.default.fileExists(atPath: external.path))
    }

    func testCorrectionsPreserveOriginalAndStatistics() async throws {
        let transcript = ConversationTranscript(segments: [
            .init(id: 0, start: 0, end: 1, text: " Original", speakerID: "1"),
            .init(id: 1, start: 1, end: 2, text: " reply", speakerID: "2")
        ], speakerDetectionRequested: true)
        let item = try XCTUnwrap(service.addConversation(transcript, duration: 2))
        let other = try XCTUnwrap(service.addConversation(transcript, duration: 2))
        let stats = defaults.data(forKey: "history_stats_entries")
        XCTAssertTrue(service.updateSegment(itemID: item.id, segmentID: 0, text: " Corrected", speakerID: "2"))
        XCTAssertTrue(service.updateSegment(itemID: item.id, segmentID: 0, text: " Revised", speakerID: nil))
        let added = try XCTUnwrap(service.addSpeaker(itemID: item.id, name: "Alice"))
        XCTAssertTrue(service.updateSegment(itemID: item.id, segmentID: 0, text: " Revised", speakerID: added))
        XCTAssertTrue(service.mergeSpeakers(itemID: item.id, sourceID: "2", targetID: added))
        let reopened = HistoryService(defaults: defaults)
        let saved = try XCTUnwrap(reopened.items.first { $0.id == item.id })
        XCTAssertEqual(saved.transcript, " Original reply")
        XCTAssertEqual(saved.conversation?.segments[0].originalText, " Original")
        XCTAssertEqual(saved.conversation?.plainText, " Revised reply")
        XCTAssertEqual(saved.conversation?.segments.map(\.speakerID), [added, added])
        XCTAssertEqual(saved.displayText.components(separatedBy: "Alice:").count - 1, 2)
        XCTAssertEqual(reopened.items.first { $0.id == other.id }?.conversation, transcript)
        XCTAssertEqual(defaults.data(forKey: "history_stats_entries"), stats)
        XCTAssertEqual(reopened.items.count, 2)
        XCTAssertFalse(service.updateSegment(itemID: item.id, segmentID: 0, text: " ", speakerID: nil))
        XCTAssertFalse(service.updateSegment(itemID: item.id, segmentID: 0, text: "text", speakerID: "missing"))
        XCTAssertFalse(service.mergeSpeakers(itemID: item.id, sourceID: added, targetID: added))
        XCTAssertNil(service.addSpeaker(itemID: item.id, name: ""))
    }

    func testStatsPersistenceUsesSeparateStore() {
        service.addItem(transcript: "Persistent stats entry", duration: 5.0)

        guard let data = defaults.data(forKey: "history_stats_entries"),
              let decoded = try? JSONDecoder().decode([HistoryStatsEntry].self, from: data) else {
            XCTFail("Failed to load stats from UserDefaults")
            return
        }

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.wordCount, 3)
        XCTAssertEqual(decoded.first?.duration, 5.0)
    }
}

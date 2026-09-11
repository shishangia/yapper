import Foundation
import Combine
import SwiftUI // For IndexSet operations if needed, though Foundation usually covers it, but error says missing import.

struct HistoryStatsEntry: Identifiable, Codable, Hashable {
    let id: UUID
    let date: Date
    let wordCount: Int
    let duration: TimeInterval
}

struct HistoryItem: Identifiable, Codable, Hashable {
    let id: UUID
    let date: Date
    let transcript: String
    let duration: TimeInterval
    let audioFileURL: URL?
    let modelUsed: String?
    let transcriptionTime: TimeInterval?
    var conversation: ConversationTranscript? = nil

    var displayText: String { conversation?.formattedText ?? transcript }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    static func == (lhs: HistoryItem, rhs: HistoryItem) -> Bool {
        lhs.id == rhs.id
    }
}

class HistoryService: ObservableObject {
    static let shared = HistoryService()
    
    @Published var items: [HistoryItem] = []
    @Published private(set) var statsEntries: [HistoryStatsEntry] = []
    
    private let saveKey = "history_items"
    private let statsSaveKey = "history_stats_entries"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        precondition(!AppEnvironment.isRunningTests || defaults !== UserDefaults.standard,
                     "HistoryService tests must use an isolated UserDefaults suite.")
        self.defaults = defaults
        loadStats()
        loadHistory()
        NotificationCenter.default.addObserver(self, selector: #selector(reloadAfterImport), name: .legacyLibraryImported, object: nil)
    }

    @objc private func reloadAfterImport() {
        loadStats()
        loadHistory()
    }
    
    func addItem(transcript: String, duration: TimeInterval, audioFileURL: URL? = nil, modelUsed: String? = nil, transcriptionTime: TimeInterval? = nil) {
        let normalizedTranscript = WhisperService.normalizedTranscription(from: transcript)
        guard !normalizedTranscript.isEmpty else { return }

        let timestamp = Date()
        let wordCount = normalizedTranscript.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .count

        let newItem = HistoryItem(
            id: UUID(),
            date: timestamp,
            transcript: normalizedTranscript,
            duration: duration,
            audioFileURL: audioFileURL,
            modelUsed: modelUsed,
            transcriptionTime: transcriptionTime
        )
        let statsEntry = HistoryStatsEntry(
            id: newItem.id,
            date: timestamp,
            wordCount: wordCount,
            duration: duration
        )
        items.insert(newItem, at: 0) // Newest first
        statsEntries.insert(statsEntry, at: 0)
        saveHistory()
        saveStats()
    }
    
    @discardableResult
    func addConversation(_ conversation: ConversationTranscript, duration: TimeInterval, audioFileURL: URL? = nil, modelUsed: String? = nil, transcriptionTime: TimeInterval? = nil, id: UUID = UUID()) -> HistoryItem? {
        if let existing = items.first(where: { $0.id == id }) { return existing }
        let transcript = conversation.plainText
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let newItem = HistoryItem(
            id: id,
            date: Date(),
            transcript: transcript,
            duration: duration,
            audioFileURL: audioFileURL,
            modelUsed: modelUsed,
            transcriptionTime: transcriptionTime,
            conversation: conversation
        )
        let statsEntry = HistoryStatsEntry(
            id: newItem.id,
            date: newItem.date,
            wordCount: transcript.components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }.count,
            duration: duration
        )
        items.insert(newItem, at: 0)
        statsEntries.insert(statsEntry, at: 0)
        saveHistory()
        saveStats()
        return newItem
    }

    @discardableResult
    func renameSpeaker(itemID: UUID, speakerID: String, name: String) -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedName.count <= 80,
              trimmedName.rangeOfCharacter(from: CharacterSet.controlCharacters.union(.newlines)) == nil,
              let index = items.firstIndex(where: { $0.id == itemID }),
              var conversation = items[index].conversation,
              conversation.speakerIDs.contains(speakerID) else { return false }

        let savedName = trimmedName.isEmpty ? nil : trimmedName
        guard conversation.speakerNames[speakerID] != savedName else { return true }
        conversation.speakerNames[speakerID] = savedName
        items[index].conversation = conversation
        saveHistory()
        return true
    }

    @discardableResult
    func updateSegment(itemID: UUID, segmentID: Int, text: String, speakerID: String?) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let itemIndex = items.firstIndex(where: { $0.id == itemID }),
              var transcript = items[itemIndex].conversation,
              let segmentIndex = transcript.segments.firstIndex(where: { $0.id == segmentID }),
              speakerID == nil || transcript.speakerIDs.contains(speakerID!) else { return false }
        if transcript.segments[segmentIndex].text != text {
            if transcript.segments[segmentIndex].originalText == nil {
                transcript.segments[segmentIndex].originalText = transcript.segments[segmentIndex].text
            }
            let previous = transcript.segments[segmentIndex].text
            let leading = String(previous.prefix(while: { $0.isWhitespace }))
            let trailing = String(previous.reversed().prefix(while: { $0.isWhitespace }).reversed())
            transcript.segments[segmentIndex].text = leading + text.trimmingCharacters(in: .whitespacesAndNewlines) + trailing
        }
        transcript.segments[segmentIndex].speakerID = speakerID
        items[itemIndex].conversation = transcript
        saveHistory()
        return true
    }

    @discardableResult
    func addSpeaker(itemID: UUID, name: String) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80,
              name.rangeOfCharacter(from: CharacterSet.controlCharacters.union(.newlines)) == nil,
              let index = items.firstIndex(where: { $0.id == itemID }),
              var transcript = items[index].conversation else { return nil }
        var number = 1
        while transcript.speakerIDs.contains(String(number)) { number += 1 }
        let id = String(number)
        transcript.speakerNames[id] = name
        transcript.speakerDetectionRequested = true
        items[index].conversation = transcript
        saveHistory()
        return id
    }

    @discardableResult
    func mergeSpeakers(itemID: UUID, sourceID: String, targetID: String) -> Bool {
        guard sourceID != targetID,
              let index = items.firstIndex(where: { $0.id == itemID }),
              var transcript = items[index].conversation,
              transcript.speakerIDs.contains(sourceID), transcript.speakerIDs.contains(targetID) else { return false }
        for segment in transcript.segments.indices where transcript.segments[segment].speakerID == sourceID {
            transcript.segments[segment].speakerID = targetID
        }
        transcript.speakerNames.removeValue(forKey: sourceID)
        items[index].conversation = transcript
        saveHistory()
        return true
    }

    func deleteItem(at offsets: IndexSet, deleteAudioFile: Bool = true) {
        let itemsToDelete = offsets.compactMap { items.indices.contains($0) ? items[$0] : nil }
        items.remove(atOffsets: offsets)
        if deleteAudioFile {
            itemsToDelete.forEach(removeAudioFileIfNeeded(for:))
        }
        saveHistory()
    }
    
    func deleteItem(id: UUID, deleteAudioFile: Bool = true) {
        let itemToDelete = items.first { $0.id == id }
        items.removeAll { $0.id == id }
        if deleteAudioFile, let itemToDelete {
            removeAudioFileIfNeeded(for: itemToDelete)
        }
        saveHistory()
    }
    
    func clearAll() {
        // Delete the audio files backing every transcript so they don't leak on
        // disk (matches `deleteItem`'s `deleteAudioFile: true` default). Stats are
        // intentionally preserved — the Clear All dialog promises to keep them.
        items.forEach(removeAudioFileIfNeeded(for:))
        items.removeAll()
        saveHistory()
    }

    func totalWordCount() -> Int {
        statsEntries.reduce(0) { $0 + $1.wordCount }
    }
    
    func transcriptionCount(since startDate: Date? = nil) -> Int {
        filteredStatsEntries(since: startDate).count
    }
    
    func totalDuration(since startDate: Date? = nil) -> TimeInterval {
        filteredStatsEntries(since: startDate).reduce(0) { $0 + $1.duration }
    }
    
    func wordCount(on day: Date, calendar: Calendar = .current) -> Int {
        let startOfDay = calendar.startOfDay(for: day)
        return statsEntries
            .filter { calendar.isDate($0.date, inSameDayAs: startOfDay) }
            .reduce(0) { $0 + $1.wordCount }
    }
    
    func statsEntries(since startDate: Date) -> [HistoryStatsEntry] {
        filteredStatsEntries(since: startDate)
    }
    
    private func saveHistory() {
        if let encoded = try? JSONEncoder().encode(items) {
            defaults.set(encoded, forKey: saveKey)
        }
    }

    private func saveStats() {
        if let encoded = try? JSONEncoder().encode(statsEntries) {
            defaults.set(encoded, forKey: statsSaveKey)
        }
    }
    
    private func loadHistory() {
        if let data = defaults.data(forKey: saveKey),
           let decoded = try? JSONDecoder().decode([HistoryItem].self, from: data) {
            items = decoded
            migrateStatsIfNeeded(from: decoded)
        }
    }

    private func loadStats() {
        if let data = defaults.data(forKey: statsSaveKey),
           let decoded = try? JSONDecoder().decode([HistoryStatsEntry].self, from: data) {
            statsEntries = decoded.sorted { $0.date > $1.date }
        }
    }
    
    private func migrateStatsIfNeeded(from historyItems: [HistoryItem]) {
        guard defaults.object(forKey: statsSaveKey) == nil, !historyItems.isEmpty else { return }

        statsEntries = historyItems.map { item in
            HistoryStatsEntry(
                id: item.id,
                date: item.date,
                wordCount: (item.conversation?.plainText ?? item.transcript)
                    .components(separatedBy: .whitespacesAndNewlines)
                    .filter { !$0.isEmpty }
                    .count,
                duration: item.duration
            )
        }
        saveStats()
    }
    
    private func filteredStatsEntries(since startDate: Date?) -> [HistoryStatsEntry] {
        guard let startDate else { return statsEntries }
        return statsEntries.filter { $0.date >= startDate }
    }

    private func removeAudioFileIfNeeded(for item: HistoryItem) {
        guard let audioFileURL = item.audioFileURL, audioFileURL.isFileURL else { return }
        if AppEnvironment.usesIsolatedStorage {
            let root = AppEnvironment.applicationSupportDirectory.standardizedFileURL
            guard audioFileURL.standardizedFileURL.path.hasPrefix(root.path + "/"),
                  audioFileURL.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(
                    root.resolvingSymlinksInPath().standardizedFileURL.path + "/") else { return }
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: audioFileURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return }
        try? FileManager.default.removeItem(at: audioFileURL)
    }

#if DEBUG
    func resetAllDataForTesting() {
        items = []
        statsEntries = []
        defaults.removeObject(forKey: saveKey)
        defaults.removeObject(forKey: statsSaveKey)
    }
#endif
}

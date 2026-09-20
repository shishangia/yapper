import CryptoKit
import AppKit
import Foundation

extension Notification.Name {
    static let legacyLibraryImported = Notification.Name("yapper.legacyLibraryImported")
}

@MainActor
@Observable
final class LegacyImportService {
    static let shared = LegacyImportService()
    private(set) var isImporting = false
    private(set) var error: String?
    private(set) var completed = false

    static let legacyDomain = "com.2048labs.speaktype"
    static let markerKey = "legacyLibraryImported"
    static var legacyDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SpeakType")
    }

    var canImport: Bool {
        !AppEnvironment.usesIsolatedStorage
            && !UserDefaults.standard.bool(forKey: Self.markerKey)
            && !Self.hasLibraryData(in: UserDefaults.standard.persistentDomain(forName: AppEnvironment.defaultsDomain) ?? [:])
            && FileManager.default.fileExists(atPath: Self.legacyDirectory.path)
    }

    static func hasLibraryData(in values: [String: Any]) -> Bool {
        ["history_items", "dictionary_entries", "history_stats_entries"].contains { values[$0] != nil }
    }

    func importLibrary() async {
        guard canImport, !isImporting, !UpdateService.shared.isInstalling else { return }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: Self.legacyDomain).isEmpty else {
            error = "Quit the previous app before importing so its library cannot change during the copy."
            return
        }
        isImporting = true
        error = nil
        defer { isImporting = false }
        do {
            let values = UserDefaults.standard.persistentDomain(forName: Self.legacyDomain) ?? [:]
            let source = Self.legacyDirectory
            let destination = AppEnvironment.applicationSupportDirectory
            let tokenizers = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/huggingface/models/openai")
            let fluidModels = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("FluidAudio/Models")
            let imported = try Self.preparedPreferences(values, source: source, destination: destination)
            try await Task.detached(priority: .userInitiated) {
                try Self.copyVerifiedLibrary(from: source, to: destination,
                    additional: [(tokenizers, "models/openai"), (fluidModels, "FluidAudio/Models")])
            }.value
            var domain = UserDefaults.standard.persistentDomain(forName: AppEnvironment.defaultsDomain) ?? [:]
            domain.merge(imported) { _, imported in imported }
            domain[Self.markerKey] = true
            UserDefaults.standard.setPersistentDomain(domain, forName: AppEnvironment.defaultsDomain)
            completed = true
            NotificationCenter.default.post(name: .legacyLibraryImported, object: nil)
        } catch {
            self.error = "Import was not completed. Your original library is unchanged. \(error.localizedDescription)"
        }
    }

    static func preparedPreferences(_ sourceValues: [String: Any], source: URL, destination: URL) throws -> [String: Any] {
        let keys: Set<String> = [
            "history_items", "history_stats_entries", "dictionary_entries", "dictionaryDidMigrateAutoEditRules",
            "enableAutoEdit", "hasCompletedOnboarding", "hasShownModelPrompt", "selectedModelVariant",
            "selectedAudioDeviceId", "recordingMode", "alwaysShowRecorderPill", "showMenuBarIcon", "appTheme",
            "transcriptionLanguage", "hotkeyConfiguration", "selectedHotkey", "modelUseCase", "app_first_launch_date",
            "recentTranscriptionLanguages", "restoreClipboardAfterAutoPaste", "customReplacementRules"
        ]
        var values = sourceValues.filter { keys.contains($0.key) || $0.key.hasPrefix("KeyboardShortcuts_") }
        if let history = values["history_items"] as? Data {
            guard var entries = try JSONSerialization.jsonObject(with: history) as? [[String: Any]] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            for index in entries.indices {
                guard let path = entries[index]["audioFileURL"] as? String,
                      let url = URL(string: path), url.isFileURL else { continue }
                let root = source.standardizedFileURL.path + "/"
                if url.standardizedFileURL.path.hasPrefix(root) {
                    let relative = String(url.standardizedFileURL.path.dropFirst(root.count))
                    entries[index]["audioFileURL"] = destination.appendingPathComponent(relative).absoluteString
                }
            }
            values["history_items"] = try JSONSerialization.data(withJSONObject: entries, options: [.sortedKeys])
        }
        return values
    }

    // Existing files are accepted only when byte-identical, making interrupted copies safe to retry.
    nonisolated static func copyVerifiedLibrary(from source: URL, to destination: URL, additional: [(URL, String)] = []) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        for name in ["Recordings", "Chunks", "models", "SpeechModels", "SpeakerModels"] {
            let original = source.appendingPathComponent(name)
            if fm.fileExists(atPath: original.path) {
                try copyDirectory(original, to: destination.appendingPathComponent(name))
            }
        }
        for (original, relative) in additional where fm.fileExists(atPath: original.path) {
            try copyDirectory(original, to: destination.appendingPathComponent(relative))
        }
    }

    nonisolated private static func copyDirectory(_ source: URL, to destination: URL) throws {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: source.path) else {
            throw CocoaError(.fileReadUnknown)
        }
        if fm.fileExists(atPath: destination.path), try destination.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
            throw CocoaError(.fileWriteNoPermission)
        }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        for case let relative as String in enumerator {
            let file = source.appendingPathComponent(relative)
            let properties = try file.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard properties.isSymbolicLink != true else { throw CocoaError(.fileReadUnsupportedScheme) }
            let target = destination.appendingPathComponent(relative)
            if fm.fileExists(atPath: target.path), try target.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                throw CocoaError(.fileWriteNoPermission)
            }
            if properties.isDirectory == true {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            if fm.fileExists(atPath: target.path) {
                guard try digest(file) == digest(target) else {
                    throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: target.path])
                }
            } else {
                let temporary = target.deletingLastPathComponent().appendingPathComponent(".import-\(UUID().uuidString)")
                do {
                    try fm.copyItem(at: file, to: temporary)
                    guard try digest(file) == digest(temporary) else { throw CocoaError(.fileReadCorruptFile) }
                    try fm.moveItem(at: temporary, to: target)
                } catch {
                    try? fm.removeItem(at: temporary)
                    throw error
                }
            }
        }
    }

    nonisolated private static func digest(_ url: URL) throws -> SHA256.Digest {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize()
    }
}

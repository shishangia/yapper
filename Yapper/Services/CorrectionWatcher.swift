import AppKit
import ApplicationServices
import Carbon

extension Notification.Name {
    /// userInfo: "words": [String], "full": Bool (true when preferred words had no room).
    static let yapperLearnedWords = Notification.Name("yapper.learnedWords")
}

/// After an auto-paste, briefly watches the target text field and learns names the user fixes.
/// Field text stays in memory only: it is never persisted or logged.
@MainActor
final class CorrectionWatcher {
    static let shared = CorrectionWatcher()
    private var task: Task<Void, Never>?

    func watch(pid: pid_t, pasted: String) {
        task?.cancel()
        guard !pasted.isEmpty, AXIsProcessTrusted() else { return }
        task = Task {
            var anchor: (prefix: String, suffix: String)?
            var latest = pasted
            for _ in 0..<60 {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, AXIsProcessTrusted(), !IsSecureEventInputEnabled(),
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                      let value = Self.focusedValue(pid: pid) else { break }
                if let current = anchor {
                    guard let inserted = Self.insertedText(in: value, prefix: current.prefix, suffix: current.suffix) else { break }
                    latest = inserted
                } else if let range = value.range(of: pasted, options: .backwards) {
                    anchor = (String(value[..<range.lowerBound]), String(value[range.upperBound...]))
                }
            }
            // Learn once the user is done, so half-typed words are never saved.
            if latest != pasted { Self.learn(original: pasted, edited: latest) }
        }
    }

    /// The pasted region after edits: whatever sits between the text that surrounded it.
    nonisolated static func insertedText(in value: String, prefix: String, suffix: String) -> String? {
        guard value.count >= prefix.count + suffix.count, value.hasPrefix(prefix), value.hasSuffix(suffix) else { return nil }
        return String(value.dropFirst(prefix.count).dropLast(suffix.count))
    }

    static func learn(original: String, edited: String, defaults: UserDefaults = .standard) {
        let words = CorrectionLearner.learnedWords(original: original, edited: edited)
        guard !words.isEmpty else { return }
        let result = DictationPreferences.addLearnedWords(words, defaults: defaults)
        guard !result.added.isEmpty || result.full else { return }
        NotificationCenter.default.post(name: .yapperLearnedWords, object: nil,
            userInfo: ["words": result.full && result.added.isEmpty ? words : result.added, "full": result.full])
    }

    private static func focusedValue(pid: pid_t) -> String? {
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute as CFString,
                                            &focused) == .success, let focused,
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXValueAttribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }
}

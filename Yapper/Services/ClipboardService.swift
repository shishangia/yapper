import ApplicationServices
import Cocoa

class ClipboardService {
    static let shared = ClipboardService()

    enum PasteOutcome: Equatable {
        case pasteRequested, copiedPermissionMissing, copiedTargetUnavailable, copiedEventUnavailable, canceled

        var message: String? {
            switch self {
            case .pasteRequested, .canceled: return nil
            case .copiedPermissionMissing: return "Copied. Enable Accessibility to paste."
            case .copiedTargetUnavailable: return "Copied. Focus your text field and press ⌘V."
            case .copiedEventUnavailable: return "Copied. Press ⌘V to paste."
            }
        }
    }

    @MainActor
    static func deliver(
        text: String, restoreClipboard: Bool, canCommit: () -> Bool,
        accessibilityTrusted: () -> Bool, activateTarget: () -> Bool, targetIsFocused: () -> Bool,
        copy: (String) -> ClipboardSnapshot?, sendPaste: () -> Bool,
        restore: (ClipboardSnapshot, String) -> Void,
        wait: (Duration) async -> Void
    ) async -> PasteOutcome {
        guard canCommit(), !Task.isCancelled else { return .canceled }
        guard accessibilityTrusted() else { _ = copy(text); return .copiedPermissionMissing }
        guard activateTarget() else { _ = copy(text); return .copiedTargetUnavailable }
        await wait(.milliseconds(500))
        guard canCommit(), !Task.isCancelled else { return .canceled }
        guard accessibilityTrusted() else { _ = copy(text); return .copiedPermissionMissing }
        guard targetIsFocused() else { _ = copy(text); return .copiedTargetUnavailable }
        let previous = copy(text)
        guard sendPaste() else { return .copiedEventUnavailable }
        if restoreClipboard, let previous {
            await wait(.milliseconds(350))
            restore(previous, text)
        }
        return .pasteRequested
    }

    @MainActor
    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    struct ClipboardSnapshot {
        fileprivate let items: [ClipboardItemSnapshot]
    }

    fileprivate struct ClipboardItemSnapshot {
        let dataByType: [NSPasteboard.PasteboardType: Data]
    }

    private init() {}

    func copy(text: String) {
        let finalText = text

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(finalText, forType: .string)

        // Verify write
        if let check = pasteboard.string(forType: .string), check == finalText {
            print("Clipboard write verified")
        } else {
            print("❌ Clipboard Write FAILED!")
        }
    }

    @discardableResult
    func copyForTemporaryPaste(text: String) -> ClipboardSnapshot {
        let snapshot = currentSnapshot()
        copy(text: text)
        return snapshot
    }

    func restore(_ snapshot: ClipboardSnapshot, ifCurrentStringMatches expectedText: String) {
        let pasteboard = NSPasteboard.general
        let expectedFinalText = expectedText

        guard pasteboard.string(forType: .string) == expectedFinalText else {
            print("Skipping clipboard restore because pasteboard changed after paste")
            return
        }

        restore(snapshot)
    }

    private func currentSnapshot() -> ClipboardSnapshot {
        let pasteboard = NSPasteboard.general
        let items: [ClipboardItemSnapshot] = pasteboard.pasteboardItems?.map { item in
            var dataByType: [NSPasteboard.PasteboardType: Data] = [:]

            for type in item.types {
                if let data = item.data(forType: type) {
                    dataByType[type] = data
                }
            }

            return ClipboardItemSnapshot(dataByType: dataByType)
        } ?? []

        return ClipboardSnapshot(items: items)
    }

    private func restore(_ snapshot: ClipboardSnapshot) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        guard !snapshot.items.isEmpty else {
            print("Restored empty clipboard")
            return
        }

        let restoredItems = snapshot.items.map { snapshotItem in
            let item = NSPasteboardItem()
            for (type, data) in snapshotItem.dataByType {
                item.setData(data, forType: type)
            }
            return item
        }

        pasteboard.writeObjects(restoredItems)
        print("Restored previous clipboard contents")
    }

    // Paste content (Simulate Cmd+V)
    @MainActor
    @discardableResult
    func paste() -> Bool {
        guard isAccessibilityTrusted,
              let source = CGEventSource(stateID: .hidSystemState),
              let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: true),
              let vDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let vUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false),
              let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: false) else { return false }
        cmdDown.flags = .maskCommand
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand
        // Synchronous posting keeps the caller's focus and cancellation checks adjacent.
        for event in [cmdDown, vDown, vUp, cmdUp] { event.post(tap: .cghidEventTap) }
        return true
    }

    // Fallback using AppleScript (more robust for some apps)
    func appleScriptPaste() {
        let script = "tell application \"System Events\" to keystroke \"v\" using command down"
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
            if let error = error {
                print("AppleScript Paste Error: \(error)")
            } else {
                print("Executed AppleScript Paste")
            }
        }
    }

    // Check if we have permission to send keystrokes
    var isAccessibilityTrusted: Bool {
        return AXIsProcessTrusted()
    }

    // Request permission via system prompt
    func requestAccessibilityPermission() {
        let options =
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}

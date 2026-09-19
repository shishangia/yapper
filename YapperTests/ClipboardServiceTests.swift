import XCTest
import Cocoa
@testable import Yapper

final class ClipboardServiceTests: XCTestCase {
    private var savedItems: [NSPasteboardItem] = []

    override func setUp() {
        super.setUp()
        savedItems = NSPasteboard.general.pasteboardItems?.map { original in
            let copy = NSPasteboardItem()
            for type in original.types {
                if let data = original.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        } ?? []
    }

    override func tearDown() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(savedItems)
        super.tearDown()
    }
    
    func testCopy() {
        let text = "me@example.com."

        ClipboardService.shared.copy(text: text)
        
        let pasteboard = NSPasteboard.general
        let copied = pasteboard.string(forType: .string)
        
        XCTAssertEqual(copied, text, "Clipboard content should match copied text")
    }

    func testTemporaryPasteCanRestorePreviousClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("https://example.com/original", forType: .string)

        let snapshot = ClipboardService.shared.copyForTemporaryPaste(text: "Dictated text")
        XCTAssertEqual(pasteboard.string(forType: .string), "Dictated text")

        ClipboardService.shared.restore(snapshot, ifCurrentStringMatches: "Dictated text")
        XCTAssertEqual(pasteboard.string(forType: .string), "https://example.com/original")
    }

    func testRestoreDoesNotOverwriteClipboardChangedAfterPaste() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("Original clipboard", forType: .string)

        let snapshot = ClipboardService.shared.copyForTemporaryPaste(text: "Dictated text")
        pasteboard.clearContents()
        pasteboard.setString("User copied something else", forType: .string)

        ClipboardService.shared.restore(snapshot, ifCurrentStringMatches: "Dictated text")
        XCTAssertEqual(pasteboard.string(forType: .string), "User copied something else")
    }
    
    @MainActor
    func testPasteOutcomesPreserveFallbackAndCancellation() async {
        for scenario in 0..<6 {
            var allowed = scenario != 0
            var trusted = scenario != 1
            var copies = 0
            var pastes = 0
            var restores = 0
            let result = await ClipboardService.deliver(text: "test phrase", restoreClipboard: true,
                canCommit: { allowed }, accessibilityTrusted: { trusted }, activateTarget: { scenario != 2 },
                targetIsFocused: { scenario != 3 },
                copy: { text in copies += 1; return ClipboardService.shared.copyForTemporaryPaste(text: text) },
                sendPaste: { pastes += 1; return true }, restore: { _, _ in restores += 1 },
                wait: { duration in
                    if duration == .milliseconds(500) {
                        if scenario == 4 { allowed = false }
                        if scenario == 5 { trusted = false }
                    }
                })
            let expected: [ClipboardService.PasteOutcome] = [.canceled, .copiedPermissionMissing,
                .copiedTargetUnavailable, .copiedTargetUnavailable, .canceled, .copiedPermissionMissing]
            XCTAssertEqual(result, expected[scenario])
            XCTAssertEqual(copies, [0, 1, 1, 1, 0, 1][scenario])
            XCTAssertEqual(pastes, 0)
            XCTAssertEqual(restores, 0)
        }
    }

    @MainActor
    func testPasteRequestRestoresOnlyAfterPosting() async {
        var events: [String] = []
        let result = await ClipboardService.deliver(text: "test phrase", restoreClipboard: true,
            canCommit: { true }, accessibilityTrusted: { true }, activateTarget: { true }, targetIsFocused: { true },
            copy: { text in events.append("copy"); return ClipboardService.shared.copyForTemporaryPaste(text: text) },
            sendPaste: { events.append("post"); return true }, restore: { _, _ in events.append("restore") },
            wait: { _ in events.append("wait") })
        XCTAssertEqual(result, .pasteRequested)
        XCTAssertEqual(events, ["wait", "copy", "post", "wait", "restore"])
        XCTAssertNil(result.message)
    }
}

import AppKit
import ApplicationServices
import XCTest

final class YapperUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testConversationImportRenameAndRestart() throws {
        let app = XCUIApplication()
        // NSHomeDirectory() resolves inside the sandboxed UI test runner's container.
        let home = String(cString: try XCTUnwrap(getpwuid(getuid())).pointee.pw_dir)
        let fixture = URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Application Support/Yapper-Dev/TestAudio/conversation.wav")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.path), fixture.path)
        app.launchArguments = ["--uitesting", "-ApplePersistenceIgnoreState", "YES"]
        addTeardownBlock { @MainActor in app.terminate() }
        app.launch()
        app.open(URL(string: "yapper-dev://open")!)
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["sidebarSignature"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["sidebarSignature"].firstMatch.value as? String, "Shivam")
        let navigation = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Transcribe Audio")).firstMatch
        let pid = try XCTUnwrap(NSRunningApplication.runningApplications(withBundleIdentifier: "com.shishangia.yapper.dev").first?.processIdentifier)
        let element = AXUIElementCreateApplication(pid)
        var windows: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &windows)
        var point = CGPoint(x: 100, y: 100)
        let position = AXValueCreate(.cgPoint, &point)!
        for window in (windows as? [AXUIElement]) ?? [] {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
        }
        XCTAssertTrue(navigation.waitForExistence(timeout: 5))
        navigation.click()
        XCTAssertTrue(app.buttons["importConversation"].waitForExistence(timeout: 5))
        app.buttons["importConversation"].click()
        let panel = app.sheets.firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        app.typeKey("g", modifierFlags: [.command, .shift])
        let pathField = panel.sheets.textFields.firstMatch
        XCTAssertTrue(pathField.waitForExistence(timeout: 5))
        pathField.click()
        pathField.typeKey("a", modifierFlags: .command)
        pathField.typeText(fixture.path)
        XCTAssertEqual(pathField.value as? String, fixture.path)
        pathField.typeKey(.return, modifierFlags: [])
        let panelDescription = XCTAttachment(string: panel.debugDescription)
        panelDescription.name = "Import panel after selecting fixture"
        panelDescription.lifetime = .keepAlways
        add(panelDescription)
        XCTAssertTrue(pathField.waitForNonExistence(timeout: 5))
        let open = panel.buttons["Open"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: open)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
        open.click()
        let progress = app.staticTexts["conversationProgress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 10))
        app.buttons["sidebar.aiModels"].click()
        XCTAssertTrue(app.buttons["returnToTranscription"].waitForExistence(timeout: 5))
        app.buttons["sidebar.settings"].click()
        app.buttons["returnToTranscription"].click()
        let copy = app.buttons["copyConversation"]
        XCTAssertTrue(copy.waitForExistence(timeout: 300))
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "Conversation transcript"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let rename = app.buttons["renameSpeaker-1"].firstMatch
        XCTAssertTrue(rename.exists)
        rename.click()
        let name = app.textFields["speakerName"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        let speakerName = "Test Alice \(UUID().uuidString.prefix(8))"
        name.typeText(speakerName)
        app.buttons["saveSpeakerName"].click()
        XCTAssertTrue(name.waitForNonExistence(timeout: 5))
        let pasteboard = NSPasteboard.general
        let initialChangeCount = pasteboard.changeCount
        copy.click()
        XCTAssertGreaterThan(pasteboard.changeCount, initialChangeCount)
        let copiedTranscript = try XCTUnwrap(pasteboard.string(forType: .string))
        XCTAssertTrue(copiedTranscript.contains("\(speakerName):"))
        let edit = app.buttons["editTranscript-0"].firstMatch
        XCTAssertTrue(edit.exists)
        edit.click()
        let editor = app.textViews["editedTranscript"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.click()
        editor.typeKey("a", modifierFlags: .command)
        let corrected = "Corrected local transcript \(UUID().uuidString.prefix(6))"
        editor.typeText(corrected)
        app.buttons["saveTranscript"].click()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 5))
        copy.click()
        XCTAssertTrue(pasteboard.string(forType: .string)?.contains(corrected) == true)
        app.terminate()
        app.launch()
        app.open(URL(string: "yapper-dev://open")!)
        let history = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "History")).firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 10))
        history.click()
        // A collapsed history card exposes its transcript as the button's label, not StaticText.
        let savedConversation = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "\(speakerName):")).firstMatch
        XCTAssertTrue(savedConversation.waitForExistence(timeout: 5))
        savedConversation.click()
        let savedSpeaker = app.buttons.matching(NSPredicate(format: "label == %@", "Rename \(speakerName)")).firstMatch
        XCTAssertTrue(savedSpeaker.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[corrected].waitForExistence(timeout: 5))
        let historyDescription = XCTAttachment(string: app.windows.firstMatch.debugDescription)
        historyDescription.name = "Imported conversation after restart"
        historyDescription.lifetime = .keepAlways
        add(historyDescription)
    }
}

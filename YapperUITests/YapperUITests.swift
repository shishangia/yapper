import AppKit
import ApplicationServices
import XCTest

final class YapperUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCandyNavigationAndMenuAppearance() throws {
        for appearance in ["Light", "Dark"] {
            let app = XCUIApplication()
            addTeardownBlock { @MainActor in app.terminate() }
            app.launchArguments = ["--uitesting", "-ApplePersistenceIgnoreState", "YES", "-appTheme", appearance,
                "-showMenuBarIcon", "YES", "-selectedModelVariant", "openai_whisper-large-v3_turbo"]
            app.launch()
            openDashboard()
            XCTAssertTrue(app.buttons["sidebar.aiModels"].waitForExistence(timeout: 10))
            let pid = try XCTUnwrap(NSRunningApplication.runningApplications(withBundleIdentifier: "com.shishangia.yapper.dev").first?.processIdentifier)
            let element = AXUIElementCreateApplication(pid)
            var windows: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &windows)
            if let window = (windows as? [AXUIElement])?.first {
                var size = CGSize(width: 900, height: 720)
                AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &size)!)
            }
            app.buttons["sidebar.aiModels"].click()
            XCTAssertTrue(app.descendants(matching: .any)["model.metric.speed.parakeet-tdt-0.6b-v3"].waitForExistence(timeout: 5))
            capture(app.windows.firstMatch, name: "\(appearance) model comparison narrow")
            if let window = (windows as? [AXUIElement])?.first {
                var size = CGSize(width: 1200, height: 800)
                AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &size)!)
            }
            capture(app.windows.firstMatch, name: "\(appearance) model comparison wide")
            for route in ["transcribeAudio", "dictionary", "statistics", "settings"] {
                app.buttons["sidebar.\(route)"].click()
                capture(app.windows.firstMatch, name: "\(appearance) \(route)")
            }
            let statusItem = app.statusItems.firstMatch
            XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
            statusItem.click()
            XCTAssertTrue(app.buttons["menu.open"].waitForExistence(timeout: 5))
            let popup = try XCTUnwrap(app.descendants(matching: .any)
                .containing(.button, identifier: "menu.open").allElementsBoundByIndex.first {
                    $0.frame.width > 300 && $0.frame.width < 450 && $0.frame.height > 200
                })
            capture(popup, name: "\(appearance) menu popup")
            app.buttons["menu.open"].click()
            app.terminate()
            for phase in ["idle", "recording", "processing", "warming"] {
                app.launchArguments = ["--uitesting", "-ApplePersistenceIgnoreState", "YES", "-appTheme", appearance,
                    "-alwaysShowRecorderPill", "YES", "-selectedModelVariant", ""]
                app.launchEnvironment["YAPPER_RECORDER_PREVIEW"] = phase
                app.launch()
                openDashboard()
                XCTAssertTrue(app.buttons["sidebar.transcribeAudio"].waitForExistence(timeout: 10))
                app.buttons["sidebar.transcribeAudio"].click()
                let recorder = app.dialogs["yapper.recorder"]
                XCTAssertTrue(recorder.waitForExistence(timeout: 10))
                capture(recorder, name: "\(appearance) recorder \(phase)")
                app.terminate()
            }
            app.launchEnvironment.removeValue(forKey: "YAPPER_RECORDER_PREVIEW")
        }
    }

    @MainActor
    private func openDashboard() {
        NSWorkspace.shared.open(URL(string: "yapper-dev://open")!)
    }

    @MainActor
    private func capture(_ element: XCUIElement, name: String) {
        let attachment = XCTAttachment(screenshot: element.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testSingleSpeakerTranscriptionHasNoUncertainLabels() throws {
        let app = XCUIApplication()
        let home = String(cString: try XCTUnwrap(getpwuid(getuid())).pointee.pw_dir)
        let fixture = home + "/Library/Application Support/Yapper-Dev/TestAudio/conversation.wav"
        app.launchArguments = ["--uitesting", "-ApplePersistenceIgnoreState", "YES", "-selectedModelVariant", "openai_whisper-large-v3_turbo"]
        addTeardownBlock { @MainActor in app.terminate() }
        app.launch()
        openDashboard()
        XCTAssertTrue(app.buttons["sidebar.transcribeAudio"].waitForExistence(timeout: 10))
        app.buttons["sidebar.transcribeAudio"].click()
        let speakers = app.popUpButtons["speakerMode"]
        XCTAssertTrue(speakers.waitForExistence(timeout: 5))
        speakers.click()
        app.menuItems["One speaker"].click()
        app.buttons["importConversation"].click()
        let panel = app.sheets.firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        app.typeKey("g", modifierFlags: [.command, .shift])
        let path = panel.sheets.textFields.firstMatch
        XCTAssertTrue(path.waitForExistence(timeout: 5))
        path.click()
        path.typeKey("a", modifierFlags: .command)
        path.typeText(fixture)
        path.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(path.waitForNonExistence(timeout: 5))
        panel.buttons["Open"].click()
        let copy = app.buttons["copyConversation"]
        XCTAssertTrue(copy.waitForExistence(timeout: 180))
        copy.click()
        let text = try XCTUnwrap(NSPasteboard.general.string(forType: .string))
        XCTAssertTrue(text.contains("Speaker 1:"))
        XCTAssertFalse(text.contains("†"))
        XCTAssertFalse(text.contains("Needs review"))
        XCTAssertFalse(app.buttons["confirmSingleSpeaker"].exists)
        capture(app.windows.firstMatch, name: "Single-speaker segment timing")
    }

    @MainActor
    func testConversationImportRenameAndRestart() throws {
        let app = XCUIApplication()
        // NSHomeDirectory() resolves inside the sandboxed UI test runner's container.
        let home = String(cString: try XCTUnwrap(getpwuid(getuid())).pointee.pw_dir)
        let fixture = URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Application Support/Yapper-Dev/TestAudio/conversation.wav")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.path), fixture.path)
        app.launchArguments = ["--uitesting", "-ApplePersistenceIgnoreState", "YES", "-selectedModelVariant", "openai_whisper-large-v3_turbo"]
        addTeardownBlock { @MainActor in app.terminate() }
        app.launch()
        openDashboard()
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
        app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -520)
        capture(app.windows.firstMatch, name: "Continuous transcript reading")
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
        app.buttons["reviewSpeakers"].click()
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
        app.buttons["reviewSpeakers"].click()
        app.buttons["confirmSingleSpeaker"].click()
        XCTAssertTrue(app.buttons["applySingleSpeaker"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].click()
        XCTAssertFalse(app.buttons["undoSingleSpeaker"].exists)
        app.buttons["confirmSingleSpeaker"].click()
        app.buttons["applySingleSpeaker"].click()
        XCTAssertTrue(app.buttons["undoSingleSpeaker"].waitForExistence(timeout: 5))
        copy.click()
        XCTAssertFalse(pasteboard.string(forType: .string)?.contains("†") == true)
        capture(app.windows.firstMatch, name: "Confirmed one-speaker transcript")
        app.terminate()
        app.launch()
        openDashboard()
        let history = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "History")).firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 10))
        history.click()
        // A collapsed history card exposes its transcript as the button's label, not StaticText.
        let savedConversation = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "\(speakerName):")).firstMatch
        XCTAssertTrue(savedConversation.waitForExistence(timeout: 5))
        savedConversation.click()
        let savedSpeaker = app.buttons.matching(NSPredicate(format: "label == %@", "Rename \(speakerName)")).firstMatch
        XCTAssertTrue(savedSpeaker.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["undoSingleSpeaker"].exists)
        app.buttons["undoSingleSpeaker"].click()
        XCTAssertTrue(app.buttons["confirmSingleSpeaker"].waitForExistence(timeout: 5))
        capture(app.windows.firstMatch, name: "Readable speaker review after undo")
        app.buttons["reviewSpeakers"].click()
        XCTAssertTrue(app.staticTexts[corrected].waitForExistence(timeout: 5))
        let historyDescription = XCTAttachment(string: app.windows.firstMatch.debugDescription)
        historyDescription.name = "Imported conversation after restart"
        historyDescription.lifetime = .keepAlways
        add(historyDescription)
    }
}

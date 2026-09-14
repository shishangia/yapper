import Cocoa
import SwiftUI

@MainActor
@Observable
final class RecorderJob {
    enum Phase { case preparing, recording, switchingInput, stopping, processing, committing }
    struct Snapshot {
        let id = UUID()
        let model: String
        let language: String
        let targetPID: pid_t?
    }
    private(set) var snapshot: Snapshot?
    private(set) var phase: Phase = .preparing
    private(set) var isPresented = false
    private(set) var commitAllowed = false
    var isBusy: Bool { snapshot != nil }

    func begin(model: String, language: String, targetPID: pid_t?) -> Snapshot? {
        guard !isBusy else { return nil }
        let value = Snapshot(model: model, language: language, targetPID: targetPID)
        snapshot = value
        phase = .preparing
        isPresented = true
        commitAllowed = true
        return value
    }

    func transition(_ id: UUID, from: Phase, to: Phase) -> Bool {
        guard snapshot?.id == id, phase == from else { return false }
        phase = to
        return true
    }

    func cancel() { commitAllowed = false; isPresented = false }
    func canCommit(_ id: UUID) -> Bool { snapshot?.id == id && commitAllowed }
    func dismiss(_ id: UUID) { if snapshot?.id == id { isPresented = false } }
    func finish(_ id: UUID) {
        guard snapshot?.id == id else { return }
        snapshot = nil
        isPresented = false
        commitAllowed = false
    }
}

@MainActor
class MiniRecorderWindowController: NSObject {
    let job = RecorderJob()
    var isBusy: Bool { job.isBusy }
    private var panel: NSPanel?
    private var hostingController: NSHostingController<AnyView>?
    private var shouldRestoreClipboardAfterAutoPaste: Bool {
        UserDefaults.standard.object(forKey: "restoreClipboardAfterAutoPaste") as? Bool ?? true
    }

    /// When on, the resting pill stays on screen even when idle. Default off:
    /// the recorder appears only while dictating and hides afterward (issue #100).
    private var alwaysShowIdlePill: Bool {
        UserDefaults.standard.bool(forKey: "alwaysShowRecorderPill")
    }

    /// Prepare the resting pill. Called once at launch. When "always show" is on
    /// the pill lives on screen and morphs into the recording HUD; when off it
    /// stays hidden until recording starts.
    func showIdleRecorder() {
        if panel == nil {
            setupPanel()
        }
        guard let panel = panel else { return }

        centerPanel()
        // Idle pill is a passive indicator — let clicks pass through to whatever is
        // behind it so the transparent window never blocks the desktop or dock.
        panel.ignoresMouseEvents = true

        if alwaysShowIdlePill, !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    /// React to the "always show recorder pill" preference changing at runtime.
    func applyIdleVisibilityPreference() {
        if panel == nil {
            setupPanel()
        }
        guard let panel = panel else { return }

        if alwaysShowIdlePill {
            centerPanel()
            panel.ignoresMouseEvents = true
            if !panel.isVisible {
                panel.orderFrontRegardless()
            }
        } else if panel.ignoresMouseEvents {
            // Only hide when idle — during an active session the panel is
            // interactive (ignoresMouseEvents == false), so leave it alone.
            panel.orderOut(nil)
        }
    }

    // Start recording - show panel and begin recording
    func startRecording() {
        guard !job.isBusy else { return }
        let defaults = UserDefaults.standard
        guard job.begin(model: defaults.string(forKey: ModelSelection.defaultsKey) ?? "",
                        language: defaults.string(forKey: "transcriptionLanguage") ?? "auto",
                        targetPID: NSWorkspace.shared.frontmostApplication?.processIdentifier) != nil else { return }

        if panel == nil {
            setupPanel()
        }

        guard let panel = panel else { return }

        centerPanel()
        // Become interactive so the recording HUD (stop dot, hover controls) works.
        panel.ignoresMouseEvents = false

        if !panel.isVisible {
            print("Showing Mini Recorder Panel")
            panel.orderFrontRegardless()
        }

        // Trigger instant recording
        NotificationCenter.default.post(name: .recordingStartRequested, object: nil)
    }

    /// Center the panel horizontally on its current screen, floating just above
    /// the dock. Safe to call repeatedly (on show and on every resize).
    private func centerPanel() {
        guard let panel = panel else { return }
        let screen = panel.screen ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else {
            panel.center()
            return
        }
        let x = visibleFrame.midX - (panel.frame.width / 2)
        let y = visibleFrame.minY + 4  // sit low & discreet, just above the dock
        let origin = NSPoint(x: (x).rounded(), y: (y).rounded())
        if panel.frame.origin != origin {
            panel.setFrameOrigin(origin)
        }
    }

    /// Return the pill to its passive resting state. When "always show" is off
    /// (the default) this hides the recorder so it only appears while dictating.
    private func returnToIdle() {
        guard let panel = panel else { return }
        panel.ignoresMouseEvents = true
        if !alwaysShowIdlePill {
            panel.orderOut(nil)
        }
    }

    // Stop recording - trigger transcription and paste
    func stopRecording() {
        // 1. Hide recorder immediately - REMOVED so it shows "Transcribing..."
        // panel?.orderOut(nil)

        // Keep focus unchanged while the hotkey is still being released.
        // Re-activation happens later during commit, right before auto-paste.
        NotificationCenter.default.post(name: .recordingStopRequested, object: nil)
    }

    func cancelRecording() {
        NotificationCenter.default.post(name: .recordingCancelRequested, object: nil)
    }

    private func setupPanel() {
        // Initialize View with callbacks
        let recorderView = MiniRecorderView(
            job: job,
            onCommit: { [weak self] text, snapshot in
                self?.handleCommit(text: text, snapshot: snapshot)
            },
            onCancel: { [weak self] in
                // Don't hide — the pill stays on screen and settles back to idle.
                guard let self, !self.job.isPresented else { return }
                self.returnToIdle()
            }
        )

        // Initialize hosting controller with transparent background view
        // Wrap in AnyView because .background() changes the type from MiniRecorderView to some View
        hostingController = NSHostingController(
            rootView: AnyView(recorderView.background(Color.clear)))

        // Fixed window, big enough for the largest phase. The pill morphs purely in
        // SwiftUI, centered inside. A window that never resizes means the animation
        // is smooth with no boundary clipping.
        let fixedSize = NSSize(width: 520, height: 84)
        let p = NSPanel(
            contentRect: NSRect(origin: .zero, size: fixedSize),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )

        p.isOpaque = false
        p.backgroundColor = .clear
        p.ignoresMouseEvents = true  // idle by default — clicks pass through

        // Use the hosting view directly as the content view (NOT contentViewController)
        // so the window size is never driven by the SwiftUI content, and clamp the
        // size so nothing can resize it.
        if let hostView = hostingController?.view {
            hostView.frame = NSRect(origin: .zero, size: fixedSize)
            hostView.autoresizingMask = [.width, .height]
            hostView.wantsLayer = true
            hostView.layer?.backgroundColor = NSColor.clear.cgColor
            p.contentView = hostView
        }
        p.minSize = fixedSize
        p.maxSize = fixedSize
        p.title = "Yapper Recorder"
        p.identifier = NSUserInterfaceItemIdentifier("yapper.recorder")
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = false  // stay put — always screen-centered
        p.hasShadow = false  // Disable system shadow to avoid transparency artifacts (View has its own shadow)

        // Window Behavior
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false  // Keep floating even if focus lost
        p.standardWindowButton(.closeButton)?.isHidden = true
        p.standardWindowButton(.miniaturizeButton)?.isHidden = true
        p.standardWindowButton(.zoomButton)?.isHidden = true

        self.panel = p
    }

    private func handleCommit(text: String, snapshot: RecorderJob.Snapshot) {
        guard job.canCommit(snapshot.id), job.transition(snapshot.id, from: .processing, to: .committing) else { return }
        job.dismiss(snapshot.id)
        returnToIdle()
        Task {
            defer { job.finish(snapshot.id) }
            guard job.canCommit(snapshot.id) else { return }
            let clipboard = ClipboardService.shared
            guard clipboard.isAccessibilityTrusted,
                  let pid = snapshot.targetPID, let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
                clipboard.copy(text: text)
                return
            }
            app.activate()
            try? await Task.sleep(for: .milliseconds(500))
            guard job.canCommit(snapshot.id), !Task.isCancelled else { return }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
                clipboard.copy(text: text)
                return
            }
            let previous = shouldRestoreClipboardAfterAutoPaste ? clipboard.copyForTemporaryPaste(text: text) : nil
            if previous == nil { clipboard.copy(text: text) }
            clipboard.paste()
            if let previous {
                try? await Task.sleep(for: .milliseconds(350))
                clipboard.restore(previous, ifCurrentStringMatches: text)
            }
        }
    }

    private func showAccessibilityAlert() {
        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Required"
        alert.informativeText =
            "Yapper needs Accessibility permission to automatically paste transcriptions into the active app.\n\nYour transcription has been copied to the clipboard.\n\nTo enable auto-paste, grant permission in:\nSystem Settings → Privacy & Security → Accessibility"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "OK")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let url = URL(
                string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            {
                NSWorkspace.shared.open(url)
            }
        }
    }
}

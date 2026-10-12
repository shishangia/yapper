import AVFoundation
import SwiftUI

struct OnboardingView: View {
    @AppStorage("hasCompletedOnboarding") var hasCompletedOnboarding: Bool = false
    @State private var currentPage = 0

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Background - Match main app exactly
                Color.bgApp.ignoresSafeArea()

                // Content ZStack
                ZStack {
                    if currentPage == 0 {
                        WelcomePage(action: {
                            withAnimation(.easeInOut(duration: 0.5)) { currentPage = 1 }
                        })
                        .transition(.opacity)
                    } else if currentPage == 1 {
                        GlobeKeyOptimizationPage(action: {
                            withAnimation(.easeInOut(duration: 0.5)) { currentPage = 2 }
                        })
                        .transition(.opacity)
                    } else {
                        PermissionsPage(finishAction: {
                            completeOnboarding()
                        })
                        .transition(.opacity)
                    }
                }
                .padding(40)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 600, minHeight: 500)  // Lower minimum size
        .frame(minWidth: 600, minHeight: 500)  // Lower minimum size
    }

    func completeOnboarding() {
        withAnimation {
            hasCompletedOnboarding = true
        }
    }
}

struct WelcomePage: View {
    let action: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Icon / Hero with refined shadow
            Image("AppLogo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 88, height: 88)
                .shadow(color: Color.black.opacity(0.08), radius: 20, x: 0, y: 8)

            VStack(spacing: 14) {
                Text("Yapper")
                    .font(.system(size: 48, weight: .regular, design: .rounded))
                    .foregroundStyle(Color.textPrimary)
                    .tracking(-0.5)

                Text("Speak in any app and Yapper types it for you, right on this Mac.")
                    .font(Typography.bodyLarge)
                    .foregroundStyle(Color.textSecondary)
                    .frame(maxWidth: 480)
            }
            .multilineTextAlignment(.center)
            .padding(.top, 32)

            Spacer()

            Button(action: action) {
                Text("Get started").frame(minWidth: 128)
            }
            .buttonStyle(.stPrimary)
            .keyboardShortcut(.defaultAction)
            .padding(.bottom, 48)
        }
        .padding(.horizontal, 60)
        .padding(.vertical, 40)
    }
}

struct PermissionsPage: View {
    var finishAction: () -> Void
    @State private var micStatus: AVAuthorizationStatus = .notDetermined
    @State private var accessibilityStatus: Bool = false
    @State private var timer: Timer?

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 16) {
                Text("Permissions")
                    .font(.system(size: 40, weight: .regular, design: .rounded))
                    .foregroundStyle(Color.textPrimary)

                Text("Enable recording and auto-paste, or continue without permissions to import audio files.")
                    .font(Typography.bodyLarge)
                    .foregroundStyle(Color.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }

            VStack(spacing: 12) {
                // Microphone
                OnboardingPermissionRow(
                    icon: "mic.fill",
                    title: "Microphone",
                    description: "To hear and transcribe your voice",
                    isGranted: micStatus == .authorized,
                    action: requestMicPermission
                )

                // Accessibility
                OnboardingPermissionRow(
                    icon: "hand.raised.fill",
                    title: "Accessibility",
                    description: "To type transcribed text into any app",
                    isGranted: accessibilityStatus,
                    action: requestAccessibilityPermission
                )
            }
            .frame(maxWidth: 520)
            .padding(.top, 48)

            Spacer()

            ContinueButton(
                isEnabled: true,
                action: finishAction
            )
            .padding(.bottom, 48)
        }
        .padding(.horizontal, 60)
        .padding(.vertical, 40)
        .onAppear {
            checkPermissions()
            startPolling()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            print("App became active, checking permissions...")
            checkPermissions()
        }
        .onDisappear {
            timer?.invalidate()
        }
    }

    // ... Copy-paste existing helpers (checkPermissions, request, polling) ...
    // Note: Re-implementing them inline for the tool call

    func startPolling() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            DispatchQueue.main.async {
                self.checkPermissions()
            }
        }
        RunLoop.current.add(timer!, forMode: .common)
    }

    func checkPermissions() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--test-permissions-denied") {
            micStatus = .denied
            accessibilityStatus = false
            return
        }
        #endif
        micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let newAccessStatus = AXIsProcessTrusted()
        if newAccessStatus != accessibilityStatus {
            print("🔐 Accessibility status changed: \(accessibilityStatus) → \(newAccessStatus)")
        }
        accessibilityStatus = newAccessStatus
    }

    func requestMicPermission() {
        // Check current status
        let currentStatus = AVCaptureDevice.authorizationStatus(for: .audio)

        switch currentStatus {
        case .authorized:
            // Already granted
            micStatus = .authorized
            return

        case .notDetermined:
            // Show native permission prompt
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    self.checkPermissions()
                }
            }

        case .denied, .restricted:
            // User previously denied - open System Settings
            openSettings(for: "Privacy_Microphone")

        @unknown default:
            break
        }
    }

    func requestAccessibilityPermission() {
        print("DEBUG: Requesting Accessibility Permission")

        // First check current status
        let currentStatus = AXIsProcessTrusted()

        if currentStatus {
            // Already granted
            accessibilityStatus = true
            return
        }

        // Show the native macOS prompt (will appear automatically)
        let options: NSDictionary = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ]
        let accessEnabled = AXIsProcessTrustedWithOptions(options)
        accessibilityStatus = accessEnabled

        // Note: We don't manually open System Settings here because
        // the native prompt will show. Only open manually if user
        // needs to re-enable after denying (handled by polling)
    }

    func openSettings(for pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")
        {
            NSWorkspace.shared.open(url)
        }
    }
}

struct OnboardingPermissionRow: View {
    let icon: String
    let title: String
    let description: String
    let isGranted: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 16) {
            // Clean icon
            Image(systemName: isGranted ? "checkmark.circle.fill" : icon)
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(isGranted ? Color.accentSuccess : Color.textPrimary.opacity(0.7))
                .frame(width: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.textPrimary)

                Text(description)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Color.textSecondary)
            }

            Spacer()

            if isGranted {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentSuccess)
            } else {
                Button("Allow", action: action)
                    .buttonStyle(.stSecondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.bgCard)
                .shadow(
                    color: Color.black.opacity(isHovered ? 0.08 : 0.04), radius: isHovered ? 8 : 4,
                    x: 0, y: 2)
        )
        .scaleEffect(isHovered ? 1.01 : 1.0)
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

struct ContinueButton: View {
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("Continue").frame(minWidth: 128)
        }
        .buttonStyle(.stPrimary)
        .keyboardShortcut(.defaultAction)
        .disabled(!isEnabled)
    }
}

struct GlobeKeyOptimizationPage: View {
    let action: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 16) {
                Text("The Globe key")
                    .font(.system(size: 40, weight: .regular, design: .rounded))
                    .foregroundStyle(Color.textPrimary)

                VStack(spacing: 12) {
                    Text("macOS uses the Globe key to open the emoji picker, which interrupts Yapper.")
                    Text("Open Keyboard settings and set “Press \(Image(systemName: "globe")) key to” to “Do Nothing”.")
                }
                .font(Typography.bodyLarge)
                .foregroundStyle(Color.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
                .lineSpacing(4)
            }

            Button("Open Keyboard settings", systemImage: "switch.2", action: openKeyboardSettings)
                .buttonStyle(.stSecondary)
                .padding(.top, 40)

            Spacer()

            ContinueButton(
                isEnabled: true,
                action: action
            )
            .padding(.bottom, 48)
        }
        .padding(.horizontal, 60)
        .padding(.vertical, 40)
    }

    private func openKeyboardSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.keyboard") {
            NSWorkspace.shared.open(url)
        }
    }
}

#Preview {
    OnboardingView()
}

//
//  YapperApp.swift
//  Yapper
//
//  Created by Karan Singh on 7/1/26.
//

import KeyboardShortcuts
import SwiftData
import SwiftUI

/// Hosted unit tests need an AppKit run loop, not SwiftUI app initialization.
/// This avoids constructing shared managers, windows, or microphone observers.
@main
enum YapperLauncher {
    @MainActor
    static func main() {
        if AppEnvironment.isRunningTests {
            NSApplication.shared.run()
        } else {
            ModelSelection.registerDefaults()
            YapperApp.main()
        }
    }
}

struct YapperApp: App {
    @AppStorage("hasCompletedOnboarding") var hasCompletedOnboarding: Bool = false
    @AppStorage("appTheme") private var appTheme: AppTheme = .system
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon: Bool = true
    @AppStorage("legacyImportOffered") private var legacyImportOffered = false

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var conversation = ConversationSession.shared

    init() {
        // For UI testing: bypass onboarding automatically
        if AppEnvironment.isDevelopment, ProcessInfo.processInfo.arguments.contains("--uitesting") {
            hasCompletedOnboarding = !ProcessInfo.processInfo.arguments.contains("--test-onboarding")
        }
    }

    var body: some Scene {
        // Main Dashboard Window (Hidden by default, opened via Menu Bar or Dock)
        WindowGroup(AppEnvironment.displayName, id: "main-dashboard") {
            ThemeProvider {
                Group {
                    if !legacyImportOffered && LegacyImportService.shared.canImport {
                        LegacyImportView()
                    } else if hasCompletedOnboarding {
                        MainView()
                    } else {
                        OnboardingView()
                    }
                }
            }
            .environment(conversation)
            .preferredColorScheme(appTheme.colorScheme)
            .tint(Color.navyInk)
        }
        .defaultSize(width: 1200, height: 800)
        .windowStyle(.hiddenTitleBar)
        .handlesExternalEvents(matching: ["main-dashboard", "open"])  // Only open for matching IDs
        .commands {
            SidebarCommands()
        }

        // Note: Mini Recorder is now managed manually by AppDelegate -> MiniRecorderWindowController
        // to prevent SwiftUI from auto-opening the main dashboard on activation.

        // Menu Bar Extra (Always running listener)
        MenuBarExtra(isInserted: $showMenuBarIcon) {
            ThemeProvider {
                VStack(spacing: 12) {
                    if !legacyImportOffered && LegacyImportService.shared.canImport {
                        Button("Open Yapper", action: openDashboard).buttonStyle(.stPrimary).padding()
                    } else {
                    if conversation.isBusy {
                        Button(action: openDashboard) {
                            Label(conversation.status, systemImage: "waveform")
                                .font(Typography.labelMedium)
                        }
                        .buttonStyle(.stSecondary)
                        .padding(.top, 12)
                    }
                    MenuBarDashboardView(
                    openDashboard: openDashboard,
                    quit: { NSApplication.shared.terminate(nil) }
                    )
                    }
                }
            }
            .preferredColorScheme(appTheme.colorScheme)
        } label: {
            Image(systemName: "text.bubble.fill")
                .accessibilityLabel(AppEnvironment.displayName)
                .help(AppEnvironment.displayName)
        }
        .menuBarExtraStyle(.window)
    }

    private func openDashboard() {
        // Using URL forces the specific window group to handle the request consistently.
        if let url = URL(string: "\(AppEnvironment.urlScheme)://open") {
            NSWorkspace.shared.open(url)
        }
    }
}

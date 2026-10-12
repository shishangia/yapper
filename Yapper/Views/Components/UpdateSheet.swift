import SwiftUI

/// Update dialog sheet for prompting users to install new versions
struct UpdateSheet: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var updateService = UpdateService.shared
    @AppStorage("autoUpdate") private var autoUpdate = true

    let update: AppVersion
    var close: (() -> Void)? = nil
    let appName = "Yapper"

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text("\(appName) \(update.version) is available")
                        .font(Typography.headlineLarge)
                        .foregroundStyle(Color.textPrimary)
                    Text("You have \(AppVersion.currentVersion).")
                        .font(Typography.bodySmall)
                        .foregroundStyle(Color.textSecondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("What's new")
                    .font(Typography.headlineSmall)
                    .foregroundStyle(Color.textPrimary)

                // A short changelog takes only its own height; a long one scrolls
                // so it can never push the buttons off screen.
                ViewThatFits(in: .vertical) {
                    releaseNotes
                    ScrollView { releaseNotes }
                }
                .frame(maxHeight: 240)
            }

            if updateService.isInstalling {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(updateService.installPhase)
                            .font(Typography.labelMedium)
                            .foregroundStyle(Color.textPrimary)
                        Spacer()
                        Text("\(Int(updateService.installProgress * 100))%")
                            .font(Typography.bodySmall)
                            .monospacedDigit()
                            .foregroundStyle(Color.textSecondary)
                    }

                    ProgressView(value: updateService.installProgress)
                        .progressViewStyle(.linear)
                        .tint(Color.accentPrimary)

                    Text(updateService.installStatus)
                        .font(Typography.bodySmall)
                        .foregroundStyle(Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let error = updateService.installError {
                Label {
                    Text(error)
                        .font(Typography.bodySmall)
                        .foregroundStyle(Color.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.accentWarning)
                }
            }

            if !updateService.isInstalling {
                Toggle(isOn: $autoUpdate) {
                    Text("Check for updates automatically (ask before installing)")
                        .font(Typography.bodySmall)
                        .foregroundStyle(Color.textSecondary)
                }
                .toggleStyle(.checkbox)
            }

            HStack(spacing: 12) {
                if updateService.isInstalling {
                    Text("Update in progress…")
                        .font(Typography.bodySmall)
                        .foregroundStyle(Color.textSecondary)
                } else {
                    Button("Skip this version") {
                        updateService.skipVersion(update.version)
                        if let close { close() } else { dismiss() }
                    }
                    .buttonStyle(.stGhost)

                    Spacer()

                    Button("Remind me later") {
                        updateService.markReminderShown()
                        if let close { close() } else { dismiss() }
                    }
                    .buttonStyle(.stSecondary)
                    .keyboardShortcut(.cancelAction)

                    Button("Download and install") {
                        updateService.installUpdate(url: update.downloadURL)
                    }
                    .buttonStyle(.stPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(updateService.isInstalling)
                }
            }
        }
        .padding(24)
        .frame(width: 520, alignment: .leading)
        .background(Color.bgApp)
        // Allow the sheet to grow for the progress area
        .fixedSize(horizontal: false, vertical: true)
    }

    private var releaseNotes: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(update.releaseNotes, id: \.self) { note in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("•")
                    Text(note)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(Typography.bodyMedium)
                .foregroundStyle(Color.textPrimary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Preview

#Preview {
    UpdateSheet(update: AppVersion.mockUpdate)
}

import SwiftUI

struct DictationPerformanceSettings: View {
    @AppStorage(DictationPreferences.idleMinutesKey) private var idleMinutes = 5
    @AppStorage(DictationPreferences.previewKey) private var livePreview = true

    var body: some View {
        SettingsSection {
            SettingsSectionHeader(
                icon: "memorychip", title: "Dictation performance",
                subtitle: "Live drafts and idle memory use")

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Unload speech model after")
                            .font(Typography.bodyMedium)
                            .foregroundStyle(Color.textPrimary)
                        Spacer()
                        Picker("Unload speech model after", selection: $idleMinutes) {
                            Text("Never").tag(0)
                            ForEach([2, 5, 10, 15], id: \.self) { Text("\($0) minutes idle").tag($0) }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                        .accessibilityIdentifier("modelIdleMinutes")
                        .onChange(of: idleMinutes) { TranscriptionManager.shared.scheduleIdleUnload() }
                    }
                    Text("Frees idle model memory. Your next recording reloads it; model files stay on disk.")
                        .font(Typography.captionSmall)
                        .foregroundStyle(Color.textMuted)
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Show live draft text while recording")
                            .font(Typography.bodyMedium)
                            .foregroundStyle(Color.textPrimary)
                        Spacer()
                        Toggle("Show live draft text while recording", isOn: $livePreview)
                            .labelsHidden()
                            .accessibilityIdentifier("liveDictationPreview")
                    }
                    Text("Drafts update every few seconds and can change. The complete recording produces the saved transcript.")
                        .font(Typography.captionSmall)
                        .foregroundStyle(Color.textMuted)
                }
            }
        }
    }
}

struct SmartCleanupSettings: View {
    @AppStorage(DictationPreferences.smartCleanupKey) private var smartCleanup = false
    @AppStorage(DictationPreferences.promptKey) private var cleanupPrompt = DictationPreferences.defaultPrompt

    var body: some View {
        SettingsSection {
            SettingsSectionHeader(
                icon: "sparkles", title: "Smart cleanup",
                subtitle: "Optional text editing with Apple Intelligence")

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Use Apple Intelligence after dictation")
                            .font(Typography.bodyMedium)
                            .foregroundStyle(Color.textPrimary)
                        Spacer()
                        Toggle("Use Apple Intelligence after dictation", isOn: $smartCleanup)
                            .labelsHidden()
                            .accessibilityIdentifier("appleDictationCleanup")
                    }
                    Text("Edits text on this Mac and keeps the original in History. Standard cleanup is used if unavailable. Conversation transcripts stay unchanged.")
                        .font(Typography.captionSmall)
                        .foregroundStyle(Color.textMuted)
                }

                if let message = AppleDictationCleanup.availabilityMessage {
                    Label(message, systemImage: "info.circle")
                        .font(Typography.captionSmall)
                        .foregroundStyle(Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if smartCleanup {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Cleanup instructions")
                            .font(Typography.labelLarge)
                            .foregroundStyle(Color.textPrimary)
                        ThemedTextEditor(text: $cleanupPrompt)
                            .frame(minHeight: 130, maxHeight: 180)
                            .accessibilityLabel("Smart cleanup instructions")
                            .accessibilityIdentifier("cleanupInstructions")
                        Button("Reset instructions") { cleanupPrompt = DictationPreferences.defaultPrompt }
                            .buttonStyle(.stSecondary)
                    }
                }
            }
        }
    }
}

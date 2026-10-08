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
                        .font(Typography.caption)
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
                            .toggleStyle(.switch)
                            .accessibilityIdentifier("liveDictationPreview")
                    }
                    Text("Drafts update every few seconds and can change. The complete recording produces the saved transcript.")
                        .font(Typography.caption)
                        .foregroundStyle(Color.textMuted)
                }
            }
        }
    }
}

struct CleanupSettings: View {
    @AppStorage("enableAutoEdit") private var enableAutoEdit: Bool = true
    @AppStorage(DictationPreferences.smartCleanupKey) private var smartCleanup = false
    @AppStorage(DictationPreferences.promptKey) private var cleanupPrompt = DictationPreferences.defaultPrompt
    @AppStorage("trimDictationPeriod") private var trimDictationPeriod = true
    @State private var showsInstructions = false

    var body: some View {
        SettingsSection {
            SettingsSectionHeader(
                icon: "text.badge.checkmark", title: "Cleanup",
                subtitle: "Tidy dictated text before it is pasted")

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Auto edit")
                            .font(Typography.bodyMedium)
                            .foregroundStyle(Color.textPrimary)
                        Spacer()
                        Toggle("Auto edit", isOn: $enableAutoEdit)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    Text("Removes safe filler words, capitalizes sentences, and formats spoken commands such as “new paragraph,” “bullet point,” and “number one.” Runs on this Mac. Conversation transcripts stay unchanged.")
                        .font(Typography.caption)
                        .foregroundStyle(Color.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Use Apple Intelligence")
                            .font(Typography.bodyMedium)
                            .foregroundStyle(Color.textPrimary)
                        Spacer()
                        Toggle("Use Apple Intelligence", isOn: $smartCleanup)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .accessibilityIdentifier("appleDictationCleanup")
                    }
                    Text("Edits text on this Mac after dictation and keeps the original in History. If it is unavailable, your Auto edit setting applies. Conversation transcripts stay unchanged.")
                        .font(Typography.caption)
                        .foregroundStyle(Color.textMuted)
                        .fixedSize(horizontal: false, vertical: true)

                    if let message = AppleDictationCleanup.availabilityMessage {
                        Label(message, systemImage: "info.circle")
                            .font(Typography.caption)
                            .foregroundStyle(Color.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }

                    if smartCleanup {
                        DisclosureGroup(isExpanded: $showsInstructions) {
                            VStack(alignment: .leading, spacing: 8) {
                                ThemedTextEditor(text: $cleanupPrompt)
                                    .frame(minHeight: 130, maxHeight: 180)
                                    .accessibilityLabel("Cleanup instructions")
                                    .accessibilityIdentifier("cleanupInstructions")
                                Button("Reset instructions") { cleanupPrompt = DictationPreferences.defaultPrompt }
                                    .buttonStyle(.stSecondary)
                            }
                            .padding(.top, 8)
                        } label: {
                            Text("Customize instructions")
                                .font(Typography.labelLarge)
                                .foregroundStyle(Color.textSecondary)
                        }
                        .padding(.top, 6)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Trim final period on short dictation")
                            .font(Typography.bodyMedium)
                            .foregroundStyle(Color.textPrimary)
                        Spacer()
                        Toggle("Trim final period on short dictation", isOn: $trimDictationPeriod)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .accessibilityIdentifier("trimDictationPeriod")
                    }
                    Text("Removes a lone final period from an email, web address, number, or single word. Sentences and conversation transcripts stay unchanged.")
                        .font(Typography.caption)
                        .foregroundStyle(Color.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "character.book.closed")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.textMuted)
                        .padding(.top, 2)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Custom replacements & snippets")
                            .font(Typography.bodyMedium)
                            .foregroundStyle(Color.textPrimary)
                        Text("Word replacements and spoken snippets (say “my email” → your address) now live in the Dictionary tab in the sidebar. They apply on every model, always on.")
                            .font(Typography.caption)
                            .foregroundStyle(Color.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)
                }
            }
        }
    }
}

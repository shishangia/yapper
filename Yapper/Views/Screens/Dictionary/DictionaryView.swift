import Combine
import SwiftUI

/// Preferred words first, then snippets: say a phrase, paste something else.
/// Everything runs offline on this Mac.
struct DictionaryView: View {
    static let recentlyLearnedKey = "recentlyLearnedWords"

    @AppStorage(DictationPreferences.preferredWordsKey) private var preferredWords = ""
    @StateObject private var dictionary = DictionaryService.shared
    @State private var recentlyLearned: [String] = []
    @State private var editorEntry: DictionaryEntry?
    @State private var isPresentingEditor = false
    @State private var entryPendingDeletion: DictionaryEntry?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Dictionary")
                    .font(Typography.displayLarge)
                    .foregroundStyle(Color.textPrimary)

                preferredWordsCard
                snippetsCard
            }
            .padding(24)
        }
        .onAppear(perform: loadRecentlyLearned)
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: RunLoop.main)) { _ in
            loadRecentlyLearned()
        }
        .sheet(isPresented: $isPresentingEditor) {
            DictionaryEntryEditor(entry: editorEntry) { result in
                if dictionary.entries.contains(where: { $0.id == result.id }) {
                    dictionary.update(result)
                } else {
                    dictionary.addEntry(
                        trigger: result.trigger,
                        replacement: result.replacement,
                        matchWholeWord: result.matchWholeWord
                    )
                }
            }
        }
        .alert(
            "Delete snippet?",
            isPresented: Binding(
                get: { entryPendingDeletion != nil },
                set: { if !$0 { entryPendingDeletion = nil } }
            ),
            presenting: entryPendingDeletion
        ) { entry in
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                dictionary.delete(id: entry.id)
                entryPendingDeletion = nil
            }
        } message: { entry in
            Text("“\(entry.trimmedTrigger)” will no longer be replaced.")
        }
    }

    // MARK: - Preferred words

    private var preferredWordsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            cardHeader(title: "Preferred words", help: "Names and terms Yapper should spell correctly.")

            ThemedTextEditor(text: $preferredWords)
                .frame(minHeight: 110, maxHeight: 160)
                .accessibilityLabel("Preferred words, one per line")
                .accessibilityIdentifier("preferredWords")
            Text("One per line, up to 50.")
                .font(Typography.caption)
                .foregroundStyle(Color.textMuted)

            if !recentlyLearned.isEmpty {
                Divider().padding(.vertical, 4)
                Text("Recently learned")
                    .font(Typography.labelSmall)
                    .foregroundStyle(Color.textSecondary)
                VStack(spacing: 0) {
                    ForEach(recentlyLearned.prefix(10), id: \.self) { word in
                        HStack {
                            Text(word)
                                .font(Typography.bodyMedium)
                                .foregroundStyle(Color.textPrimary)
                                .lineLimit(1)
                            Spacer()
                            Button("Remove") { forget(word) }
                                .buttonStyle(.stGhost)
                                .accessibilityLabel("Remove \(word)")
                        }
                        .padding(.vertical, 2)
                    }
                }
                .accessibilityIdentifier("recentlyLearned")
            }
        }
        .themedCard()
    }

    // MARK: - Snippets

    private var snippetsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                cardHeader(title: "Snippets", help: "Say a phrase, paste something else (say “my email” to paste your address).")
                Spacer(minLength: 16)
                Button("Add snippet", systemImage: "plus") { present(nil) }
                    .buttonStyle(.stSecondary)
                    .accessibilityIdentifier("addSnippet")
            }

            if dictionary.entries.isEmpty {
                Text("No snippets yet.")
                    .font(Typography.bodySmall)
                    .foregroundStyle(Color.textMuted)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(dictionary.entries) { entry in
                        if entry.id != dictionary.entries.first?.id { Divider() }
                        DictionaryRuleCard(
                            entry: entry,
                            onToggle: { dictionary.setEnabled($0, for: entry.id) },
                            onEdit: { present(entry) },
                            onDelete: { entryPendingDeletion = entry }
                        )
                    }
                }
            }
        }
        .themedCard()
    }

    private func cardHeader(title: String, help: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(Typography.headlineLarge)
                .foregroundStyle(Color.textPrimary)
            Text(help)
                .font(Typography.bodySmall)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Helpers

    private func present(_ entry: DictionaryEntry?) {
        editorEntry = entry
        isPresentingEditor = true
    }

    private func loadRecentlyLearned() {
        let words = UserDefaults.standard.stringArray(forKey: Self.recentlyLearnedKey) ?? []
        if words != recentlyLearned { recentlyLearned = words }
    }

    /// Forget a learned word everywhere: the recent list and Preferred words.
    private func forget(_ word: String) {
        recentlyLearned.removeAll { $0 == word }
        UserDefaults.standard.set(recentlyLearned, forKey: Self.recentlyLearnedKey)
        preferredWords = preferredWords.components(separatedBy: .newlines)
            .filter { $0.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(word) != .orderedSame }
            .joined(separator: "\n")
    }
}

// MARK: - Rule Card

private struct DictionaryRuleCard: View {
    let entry: DictionaryEntry
    let onToggle: (Bool) -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var isHovered = false

    private var replacementDisplay: String {
        entry.replacement.isEmpty ? "(deleted)" : entry.replacement
    }

    var body: some View {
        HStack(spacing: 16) {
            // Trigger → replacement
            HStack(spacing: 12) {
                Text(entry.trimmedTrigger)
                    .font(Typography.bodyMedium.weight(.medium))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)

                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.textMuted)

                Text(replacementDisplay)
                    .font(Typography.bodyMedium)
                    .foregroundStyle(entry.replacement.isEmpty ? Color.textMuted : Color.textSecondary)
                    .lineLimit(1)
                    .italic(entry.replacement.isEmpty)
            }
            .opacity(entry.isEnabled ? 1 : 0.45)

            Spacer(minLength: 12)

            // Attribute chips
            HStack(spacing: 6) {
                if !entry.matchWholeWord {
                    RuleChip(text: "partial")
                }
            }
            .opacity(entry.isEnabled ? 1 : 0.45)

            // Actions (revealed on hover)
            HStack(spacing: 4) {
                if isHovered {
                    IconButton(systemName: "pencil", action: onEdit)
                    IconButton(systemName: "trash", action: onDelete)
                }
            }
            .frame(width: isHovered ? 56 : 0, alignment: .trailing)
            .clipped()

            Toggle("", isOn: Binding(get: { entry.isEnabled }, set: onToggle))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture(perform: onEdit)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
        }
    }
}

private struct RuleChip: View {
    let text: String
    var body: some View {
        Text(text)
            .font(Typography.captionSmall)
            .foregroundStyle(Color.textMuted)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.bgHover)
            .clipShape(Capsule())
    }
}

private struct IconButton: View {
    let systemName: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12))
                .foregroundStyle(isHovered ? Color.textPrimary : Color.textMuted)
                .frame(width: 24, height: 24)
                .background(isHovered ? Color.bgHover : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Editor Sheet

private struct DictionaryEntryEditor: View {
    /// nil when adding a brand-new rule.
    let entry: DictionaryEntry?
    let onSave: (DictionaryEntry) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var trigger: String
    @State private var replacement: String
    @State private var matchWholeWord: Bool

    init(entry: DictionaryEntry?, onSave: @escaping (DictionaryEntry) -> Void) {
        self.entry = entry
        self.onSave = onSave
        _trigger = State(initialValue: entry?.trigger ?? "")
        _replacement = State(initialValue: entry?.replacement ?? "")
        _matchWholeWord = State(initialValue: entry?.matchWholeWord ?? true)
    }

    private var isValid: Bool {
        !trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(entry == nil ? "New snippet" : "Edit snippet")
                .font(Typography.displaySmall)
                .foregroundStyle(Color.textPrimary)
                .padding(.bottom, 20)

            VStack(alignment: .leading, spacing: 18) {
                field(
                    title: "When I say",
                    subtitle: "The word or phrase to listen for"
                ) {
                    TextField("", text: $trigger, prompt: Text("my email"))
                        .textFieldStyle(.plain)
                }

                field(
                    title: "Replace with",
                    subtitle: "The text to paste. Leave empty to remove the phrase."
                ) {
                    TextField(
                        "", text: $replacement, prompt: Text("john.doe@example.com"),
                        axis: .vertical
                    )
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                }

                Divider()

                Toggle(isOn: $matchWholeWord) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Match whole words only")
                            .font(Typography.bodyMedium)
                            .foregroundStyle(Color.textPrimary)
                        Text("Won't fire inside longer words.")
                            .font(Typography.captionSmall)
                            .foregroundStyle(Color.textMuted)
                    }
                }
                .toggleStyle(.switch)
            }

            Spacer(minLength: 24)

            HStack(spacing: 12) {
                Spacer()

                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .font(Typography.labelMedium)
                    .foregroundStyle(Color.textSecondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.bgHover)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                Button("Save") { save() }
                    .buttonStyle(.plain)
                    .font(Typography.labelMedium)
                    .foregroundStyle(Color.btnPrimaryFg)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(isValid ? Color.btnPrimaryBg : Color.bgHover)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .disabled(!isValid)
            }
        }
        .padding(28)
        .frame(width: 440)
        .background(Color.bgContent)
    }

    @ViewBuilder
    private func field<Content: View>(
        title: String, subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Typography.labelLarge)
                    .foregroundStyle(Color.textPrimary)
                Text(subtitle)
                    .font(Typography.captionSmall)
                    .foregroundStyle(Color.textMuted)
            }

            ZStack(alignment: .topLeading) {
                content()
                    .font(Typography.bodyMedium)
                    .foregroundStyle(Color.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
            .background(Color.bgHover)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.border.opacity(0.6), lineWidth: 1)
            )
        }
    }

    private func save() {
        guard isValid else { return }
        var result = entry ?? DictionaryEntry(trigger: "", replacement: "")
        result.trigger = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        result.replacement = replacement
        result.matchWholeWord = matchWholeWord
        onSave(result)
        dismiss()
    }
}

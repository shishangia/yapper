import SwiftUI

struct ConversationTranscriptView: View {
    let itemID: UUID
    @ObservedObject private var historyService = HistoryService.shared
    @State private var speakerToRename: String?
    @State private var speakerName = ""
    @State private var addingSpeaker = false
    @State private var editingSegment: Int?
    @State private var editedText = ""
    @State private var editedSpeaker = ""
    @State private var merging = false
    @State private var mergeSource = ""
    @State private var mergeTarget = ""
    @State private var error: String?

    private var conversation: ConversationTranscript? {
        historyService.items.first { $0.id == itemID }?.conversation
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let conversation {
                if let warning = conversation.warning, !warning.isEmpty {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(Typography.bodySmall)
                        .foregroundStyle(Color.textSecondary)
                }
                HStack {
                    Button("Add Speaker") {
                        speakerName = ""
                        error = nil
                        addingSpeaker = true
                    }
                    .buttonStyle(.stSecondary)
                    .accessibilityIdentifier("addSpeaker")
                    if conversation.speakerIDs.count > 1 {
                        Button("Merge Speakers") {
                            mergeSource = conversation.speakerIDs[0]
                            mergeTarget = conversation.speakerIDs[1]
                            error = nil
                            merging = true
                        }
                        .buttonStyle(.stSecondary)
                        .accessibilityIdentifier("mergeSpeakers")
                    }
                }
                ForEach(conversation.segments) { segment in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(ConversationTranscript.timestamp(segment.start))
                                .font(Typography.captionSmall)
                                .foregroundStyle(Color.textMuted)
                                .monospacedDigit()
                            if conversation.speakerDetectionRequested {
                                if let id = segment.speakerID {
                                    Button {
                                        speakerName = conversation.speakerNames[id] ?? ""
                                        error = nil
                                        speakerToRename = id
                                    } label: {
                                        Label(conversation.speakerName(for: id), systemImage: "pencil")
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Rename \(conversation.speakerName(for: id))")
                                    .accessibilityIdentifier("renameSpeaker-\(id)")
                                } else {
                                    Text("Speaker uncertain").foregroundStyle(Color.textSecondary)
                                }
                            }
                            Spacer()
                            if segment.originalText != nil {
                                Text("Edited").font(Typography.captionSmall).foregroundStyle(Color.textMuted)
                            }
                            Button("Edit") {
                                editedText = segment.text
                                editedSpeaker = segment.speakerID ?? ""
                                error = nil
                                editingSegment = segment.id
                            }
                            .buttonStyle(.stSecondary)
                            .accessibilityIdentifier("editTranscript-\(segment.id)")
                        }
                        .font(Typography.labelSmall)
                        Text(segment.text.trimmingCharacters(in: .whitespacesAndNewlines))
                            .font(Typography.bodyMedium)
                            .foregroundStyle(Color.textPrimary)
                            .textSelection(.enabled)
                            .lineSpacing(4)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .sheet(isPresented: Binding(get: { speakerToRename != nil || addingSpeaker }, set: {
            if !$0 { speakerToRename = nil; addingSpeaker = false }
        })) {
            VStack(alignment: .leading, spacing: 16) {
                Text(addingSpeaker ? "Add Speaker" : "Rename Speaker").font(Typography.headlineMedium)
                Text("Names apply only to this recording. Leave a renamed speaker blank to restore the default.")
                    .font(Typography.bodySmall).foregroundStyle(Color.textSecondary)
                TextField("Speaker name", text: $speakerName)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("speakerName")
                    .onSubmit(saveName)
                errorMessage
                HStack {
                    Spacer()
                    Button("Cancel") { speakerToRename = nil; addingSpeaker = false }.keyboardShortcut(.cancelAction)
                    Button("Save", action: saveName).keyboardShortcut(.defaultAction).accessibilityIdentifier("saveSpeakerName")
                }
            }
            .padding(24).frame(width: 400)
        }
        .sheet(isPresented: Binding(get: { editingSegment != nil }, set: { if !$0 { editingSegment = nil } })) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Edit Transcript Turn").font(Typography.headlineMedium)
                TextEditor(text: $editedText).frame(minHeight: 160).accessibilityIdentifier("editedTranscript")
                if let conversation, conversation.speakerDetectionRequested {
                    Picker("Speaker", selection: $editedSpeaker) {
                        Text("Speaker uncertain").tag("")
                        ForEach(conversation.speakerIDs, id: \.self) { id in
                            Text(conversation.speakerName(for: id)).tag(id)
                        }
                    }
                    .accessibilityIdentifier("editedSpeaker")
                }
                if let segment = conversation?.segments.first(where: { $0.id == editingSegment }), let original = segment.originalText {
                    DisclosureGroup("Original text") { Text(original).textSelection(.enabled) }
                }
                errorMessage
                HStack {
                    Spacer()
                    Button("Cancel") { editingSegment = nil }.keyboardShortcut(.cancelAction)
                    Button("Save") {
                        guard let id = editingSegment,
                              historyService.updateSegment(itemID: itemID, segmentID: id, text: editedText,
                                  speakerID: editedSpeaker.isEmpty ? nil : editedSpeaker) else {
                            error = "Enter nonempty text and select an existing speaker."
                            return
                        }
                        editingSegment = nil
                    }
                    .keyboardShortcut(.defaultAction).accessibilityIdentifier("saveTranscript")
                }
            }
            .padding(24).frame(width: 520)
        }
        .sheet(isPresented: $merging) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Merge Speakers").font(Typography.headlineMedium)
                Text("All turns for the first speaker will use the second speaker's name in this recording.")
                    .font(Typography.bodySmall).foregroundStyle(Color.textSecondary)
                if let conversation {
                    Picker("Replace", selection: $mergeSource) {
                        ForEach(conversation.speakerIDs, id: \.self) { Text(conversation.speakerName(for: $0)).tag($0) }
                    }
                    Picker("With", selection: $mergeTarget) {
                        ForEach(conversation.speakerIDs, id: \.self) { Text(conversation.speakerName(for: $0)).tag($0) }
                    }
                }
                errorMessage
                HStack {
                    Spacer()
                    Button("Cancel") { merging = false }.keyboardShortcut(.cancelAction)
                    Button("Merge") {
                        guard historyService.mergeSpeakers(itemID: itemID, sourceID: mergeSource, targetID: mergeTarget) else {
                            error = "Select two different speakers."
                            return
                        }
                        merging = false
                    }
                    .disabled(mergeSource == mergeTarget)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24).frame(width: 420)
        }
    }

    @ViewBuilder private var errorMessage: some View {
        if let error { Text(error).font(Typography.bodySmall).foregroundStyle(.red) }
    }

    private func saveName() {
        let saved: Bool
        if addingSpeaker {
            saved = historyService.addSpeaker(itemID: itemID, name: speakerName) != nil
        } else if let id = speakerToRename {
            saved = historyService.renameSpeaker(itemID: itemID, speakerID: id, name: speakerName)
        } else { return }
        guard saved else {
            error = "Use a valid name up to 80 characters without line breaks."
            return
        }
        speakerToRename = nil
        addingSpeaker = false
    }
}

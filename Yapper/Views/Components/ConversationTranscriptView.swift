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
    @State private var reviewing = false
    @State private var confirmingSingleSpeaker = false
    @State private var singleSpeakerID = "1"

    private var conversation: ConversationTranscript? {
        historyService.items.first { $0.id == itemID }?.conversation
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let conversation {
                Toggle("Show timestamps", isOn: Binding(
                    get: { conversation.showsTimestamps },
                    set: { _ = historyService.setTimestampsVisible(itemID: itemID, visible: $0) }
                ))
                .toggleStyle(.switch)
                .accessibilityIdentifier("showTranscriptTimestamps")
                if conversation.unassignedCount > 0 {
                    HStack {
                        Label("Underlined words need speaker review", systemImage: "person.crop.circle.badge.questionmark")
                            .font(Typography.caption).foregroundStyle(Color.textSecondary)
                        Spacer()
                        Button(reviewing ? "Reading view" : "Review") { reviewing.toggle() }
                            .buttonStyle(.stSecondary).accessibilityIdentifier("reviewSpeakers")
                    }
                }
                if let warning = conversation.warning, !warning.isEmpty {
                    DisclosureGroup("Transcription notes") {
                        Text(warning).font(Typography.bodySmall).foregroundStyle(Color.textSecondary)
                    }
                }
                HStack {
                    if conversation.singleSpeakerUndo != nil {
                        Button("Undo one-speaker correction") {
                            if !historyService.undoSingleSpeaker(itemID: itemID) { error = "This correction can no longer be undone." }
                        }
                        .buttonStyle(.stSecondary).accessibilityIdentifier("undoSingleSpeaker")
                    } else if !conversation.segments.isEmpty && (conversation.unassignedCount > 0 || conversation.speakerIDs.count > 1) {
                        Button("One speaker…") {
                            singleSpeakerID = conversation.speakerIDs.first ?? "1"
                            error = nil
                            confirmingSingleSpeaker = true
                        }
                        .buttonStyle(.stSecondary).accessibilityIdentifier("confirmSingleSpeaker")
                    }
                    if conversation.unassignedCount == 0 {
                        Button(reviewing ? "Reading view" : "Edit turns") { reviewing.toggle() }
                            .buttonStyle(.stSecondary).accessibilityIdentifier("reviewSpeakers")
                    }
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
                if !reviewing {
                    ForEach(conversation.displayedBlocks) { block in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 10) {
                                if conversation.showsTimestamps {
                                    Text(ConversationTranscript.timestamp(block.start))
                                        .font(Typography.captionSmall).monospacedDigit().foregroundStyle(Color.textMuted)
                                }
                                if conversation.speakerDetectionRequested {
                                    if let id = block.speakerID {
                                        Button(conversation.speakerName(for: id)) {
                                            speakerName = conversation.speakerNames[id] ?? ""
                                            error = nil
                                            speakerToRename = id
                                        }
                                        .buttonStyle(.plain)
                                        .foregroundStyle(Color.accentPrimary)
                                        .accessibilityLabel("Rename \(conversation.speakerName(for: id))")
                                        .accessibilityIdentifier("renameSpeaker-\(id)")
                                    } else {
                                        Text("Needs review").foregroundStyle(Color.textSecondary)
                                    }
                                }
                                Spacer()
                            }
                            .font(Typography.labelSmall)
                            Text(readingText(block, markUncertainty: conversation.speakerDetectionRequested))
                                .font(Typography.bodyMedium).foregroundStyle(Color.textPrimary)
                                .textSelection(.enabled).lineSpacing(5)
                                .help(block.segments.contains { $0.speakerID == nil } && conversation.speakerDetectionRequested
                                    ? "Underlined words have uncertain speaker attribution. Review to correct them." : "")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                    }
                } else {
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
        .sheet(isPresented: $confirmingSingleSpeaker) {
            VStack(alignment: .leading, spacing: 16) {
                Text("This recording has one speaker").font(Typography.headlineMedium)
                Text("Only confirm if one person speaks throughout. Every passage will use the selected speaker, including words that need review. The text and timestamps will not change.")
                    .font(Typography.bodySmall).foregroundStyle(Color.textSecondary)
                if let conversation {
                    Picker("Speaker", selection: $singleSpeakerID) {
                        if conversation.speakerIDs.isEmpty { Text("Speaker 1").tag("1") }
                        ForEach(conversation.speakerIDs, id: \.self) { id in
                            Text(conversation.speakerName(for: id)).tag(id)
                        }
                    }
                    .accessibilityIdentifier("singleSpeakerSelection")
                }
                Text("You can undo this correction until you change a speaker name or assignment.")
                    .font(Typography.caption).foregroundStyle(Color.textSecondary)
                errorMessage
                HStack {
                    Spacer()
                    Button("Cancel") { confirmingSingleSpeaker = false }.keyboardShortcut(.cancelAction)
                    Button("Confirm one speaker") {
                        guard historyService.confirmSingleSpeaker(itemID: itemID, speakerID: singleSpeakerID) else {
                            error = "Select an existing speaker and try again."
                            return
                        }
                        confirmingSingleSpeaker = false
                    }
                    .keyboardShortcut(.defaultAction).accessibilityIdentifier("applySingleSpeaker")
                }
            }
            .padding(24).frame(width: 460)
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

    private func readingText(_ block: ConversationReadingBlock, markUncertainty: Bool) -> AttributedString {
        block.segments.reduce(into: AttributedString()) { output, segment in
            var text = AttributedString(segment.text)
            if markUncertainty && segment.speakerID == nil {
                text.underlineStyle = .single
            }
            output += text
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

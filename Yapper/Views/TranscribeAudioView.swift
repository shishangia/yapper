import SwiftUI
import UniformTypeIdentifiers

struct TranscribeAudioView: View {
    @Environment(ConversationSession.self) private var session
    @ObservedObject private var history = HistoryService.shared
    @AppStorage(ModelSelection.defaultsKey) private var selectedModel = ModelSelection.none
    @State private var showImporter = false
    @State private var isDropTargeted = false
    @State private var importError: String?

    private var result: HistoryItem? { history.items.first { $0.id == session.resultID } }

    var body: some View {
        @Bindable var session = session
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Transcribe Audio").font(Typography.displayLarge)
                    Text("Conversations, in your own words.")
                        .font(Typography.bodyLarge).foregroundStyle(Color.textSecondary)
                }
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "waveform").font(.title2).foregroundStyle(Color.accentPrimary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Local conversation transcription").font(Typography.headlineMedium)
                            Text("\(session.modelName) · on your Mac · no dictionary replacements")
                                .font(Typography.bodySmall).foregroundStyle(Color.textSecondary)
                        }
                    }
                    Divider()
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 16) {
                        GridRow {
                            Text("Language").foregroundStyle(Color.textSecondary)
                            Picker("Spoken language", selection: $session.language) {
                                Text("Detect automatically").tag("auto")
                                Text("English").tag("en")
                                Text("Hindi").tag("hi")
                                Text("Gujarati").tag("gu")
                                Text("Chinese").tag("zh")
                                Text("Hindi, Gujarati & English (experimental)").tag("mixed")
                            }
                            .labelsHidden().accessibilityIdentifier("conversationLanguage")
                        }
                        GridRow {
                            Text("Speaker labels").foregroundStyle(Color.textSecondary)
                            Toggle("Detect speakers", isOn: $session.detectSpeakers)
                                .accessibilityIdentifier("detectSpeakers")
                        }
                        if session.detectSpeakers {
                            GridRow {
                                Text("Participants").foregroundStyle(Color.textSecondary)
                                Picker("Speakers", selection: $session.singleSpeaker) {
                                    Text("Automatic · up to 4 speakers").tag(false)
                                    Text("One speaker").tag(true)
                                }
                                .labelsHidden().accessibilityIdentifier("speakerMode")
                            }
                        }
                    }
                    .disabled(session.isBusy)
                    Text("Mixed languages and overlapping speech can produce errors. You can edit words and speaker labels after processing.")
                        .font(Typography.bodySmall).foregroundStyle(Color.textSecondary)
                    if session.isBusy || session.phase != .idle {
                        ConversationStatusView()
                    }
                    if !session.isBusy {
                        HStack(spacing: 12) {
                            if session.modelsReady {
                                Button("Import audio or video", systemImage: "square.and.arrow.down") { showImporter = true }
                                    .buttonStyle(.stPrimary).accessibilityIdentifier("importConversation")
                                Button("Record microphone", systemImage: "mic", action: session.startRecording)
                                    .buttonStyle(.stSecondary).accessibilityIdentifier("startConversationRecording")
                            } else if selectedModel.isEmpty {
                                Text("Choose a model in AI Models to get started.")
                                    .font(Typography.bodySmall).foregroundStyle(Color.textSecondary)
                            } else {
                                Button("Download required models", systemImage: "arrow.down.circle", action: session.downloadModels)
                                    .buttonStyle(.stPrimary)
                            }
                        }
                    }
                    Label("Record only with everyone's consent. Microphone audio only, not system sound.", systemImage: "lock.shield")
                        .font(Typography.caption).foregroundStyle(Color.textSecondary)
                }
                .themedCard()
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(isDropTargeted ? Color.accentPrimary : .clear, lineWidth: 2))
                .dropDestination(for: URL.self) { urls, _ in
                    guard !session.isBusy, session.modelsReady, let url = urls.first else { return false }
                    session.importFile(url)
                    return true
                } isTargeted: { isDropTargeted = $0 }

                if let importError { Text(importError).foregroundStyle(Color.accentError) }
                if let result {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Transcript").font(Typography.headlineLarge)
                                Text(result.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(Typography.caption).foregroundStyle(Color.textSecondary)
                            }
                            Spacer()
                            Button("Copy transcript", systemImage: "doc.on.doc") {
                                ClipboardService.shared.copy(text: result.displayText)
                            }
                            .buttonStyle(.stSecondary).accessibilityIdentifier("copyConversation")
                        }
                        ConversationTranscriptView(itemID: result.id)
                    }
                    .themedCard()
                }
            }
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(28)
        }
        .foregroundStyle(Color.textPrimary)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio, .movie]) { result in
            switch result {
            case .success(let url): importError = nil; session.importFile(url)
            case .failure(let error): importError = error.localizedDescription
            }
        }
        .onAppear { session.refreshModels() }
        .onChange(of: selectedModel) { session.refreshModels() }
        .onChange(of: session.detectSpeakers) { session.refreshModels() }
        .onChange(of: session.singleSpeaker) { session.refreshModels() }
    }
}

struct ConversationStatusView: View {
    @Environment(ConversationSession.self) private var session

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                if session.phase == .recording {
                    Image(systemName: "record.circle.fill").foregroundStyle(Color.accentError)
                } else if session.isBusy && session.progress == nil {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: session.phase == .completed ? "checkmark.circle" : "waveform")
                        .foregroundStyle(Color.accentPrimary)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.status).font(Typography.labelLarge).accessibilityIdentifier("conversationProgress")
                    Text(session.sourceName).font(Typography.caption).foregroundStyle(Color.textSecondary).lineLimit(1)
                }
                Spacer()
                if session.phase == .recording {
                    Button("Stop & transcribe", action: session.stopRecording)
                        .buttonStyle(.stPrimary).accessibilityIdentifier("stopConversationRecording")
                    Button("Discard", action: session.cancel).buttonStyle(.stSecondary)
                } else if session.isBusy {
                    Button(session.phase == .canceling ? "Canceling…" : "Cancel", action: session.cancel)
                        .buttonStyle(.stSecondary).disabled(session.phase == .canceling)
                        .accessibilityIdentifier("cancelConversation")
                }
            }
            if let progress = session.progress {
                ProgressView(value: progress).tint(Color.accentPrimary)
                    .accessibilityLabel("Current processing stage")
            }
            if session.phase == .canceling {
                Text("Finishing the current native operation before releasing the models. No result will be saved.")
                    .font(Typography.caption).foregroundStyle(Color.textSecondary)
            } else if let message = session.message {
                Text(message).font(Typography.bodySmall).foregroundStyle(Color.textSecondary)
                    .accessibilityIdentifier("conversationMessage")
            }
            if let audio = session.retainedAudioURL, !session.isBusy {
                HStack {
                    Button("Retry", action: session.retry).buttonStyle(.stSecondary)
                    Button("Show retained audio") { NSWorkspace.shared.activateFileViewerSelecting([audio]) }
                        .buttonStyle(.stSecondary)
                }
            }
        }
        .padding(16)
        .background(Color.bgHover, in: RoundedRectangle(cornerRadius: 12))
    }
}

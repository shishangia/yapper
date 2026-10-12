import SwiftUI
import UniformTypeIdentifiers

struct TranscribeAudioView: View {
    var showModels: () -> Void = {}
    @Environment(ConversationSession.self) private var session
    @ObservedObject private var history = HistoryService.shared
    @AppStorage(ModelSelection.defaultsKey) private var selectedModel = ModelSelection.none
    @State private var showImporter = false
    @State private var isDropTargeted = false
    @State private var importError: String?
    @State private var showCopySuccess = false

    private var result: HistoryItem? { history.items.first { $0.id == session.resultID } }

    private var missingModelReason: String {
        if session.selectedModel.isEmpty { return "Choose a transcription model in Settings to import or record." }
        if !LocalConversationProcessor.transcriptionModelsReady(variant: session.selectedModel) {
            return "\(session.modelName) is not downloaded yet."
        }
        return "Speaker detection needs its own model, which is not downloaded yet."
    }

    var body: some View {
        @Bindable var session = session
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Transcribe audio").font(Typography.displayLarge)
                    if !session.selectedModel.isEmpty {
                        Text("Runs on this Mac with \(session.modelName).")
                            .font(Typography.bodySmall).foregroundStyle(Color.textSecondary)
                    }
                }
                VStack(alignment: .leading, spacing: 20) {
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 16) {
                        GridRow {
                            Text("Language").foregroundStyle(Color.textSecondary)
                            Picker("Spoken language", selection: $session.language) {
                                ForEach(["auto", "hinglish", "en", "hi", "gu", "zh", "mixed"], id: \.self) {
                                    Text(ModelSelection.languageName(for: $0)).tag($0)
                                }
                            }
                            .labelsHidden().accessibilityIdentifier("conversationLanguage")
                            .onChange(of: session.language) { session.selectLanguage(session.language) }
                        }
                        GridRow {
                            Text("Detect speakers").foregroundStyle(Color.textSecondary)
                            Toggle("Detect speakers", isOn: $session.detectSpeakers)
                                .labelsHidden()
                                .accessibilityIdentifier("detectSpeakers")
                                .toggleStyle(.switch)
                        }
                        GridRow {
                            Text("Include timestamps").foregroundStyle(Color.textSecondary)
                            Toggle("Include timestamps", isOn: $session.includeTimestamps)
                                .labelsHidden()
                                .accessibilityIdentifier("includeTimestamps")
                                .toggleStyle(.switch)
                        }
                    }
                    .disabled(session.isBusy)
                    Text("After processing, you can edit words and speaker labels and switch between paragraphs and timestamps. Mixed languages and overlapping speech can cause mistakes.")
                        .font(Typography.caption).foregroundStyle(Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if session.isBusy || session.phase != .idle {
                        ConversationStatusView()
                    }
                    if !session.isBusy {
                        if !session.modelsReady {
                            Label(missingModelReason, systemImage: "info.circle")
                                .font(Typography.bodySmall).foregroundStyle(Color.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("conversationModelMissing")
                        }
                        HStack(spacing: 12) {
                            if session.modelsReady {
                                Button("Import audio or video", systemImage: "square.and.arrow.down") { showImporter = true }
                                    .buttonStyle(.stPrimary).accessibilityIdentifier("importConversation")
                                Button("Record microphone", systemImage: "mic", action: session.startRecording)
                                    .buttonStyle(.stSecondary).accessibilityIdentifier("startConversationRecording")
                            } else if session.selectedModel.isEmpty {
                                Button("Choose a model", systemImage: "cpu", action: showModels)
                                    .buttonStyle(.stPrimary)
                            } else {
                                Button("Download required models", systemImage: "arrow.down.circle", action: session.downloadModels)
                                    .buttonStyle(.stPrimary)
                                Button("Open Models", action: showModels)
                                    .buttonStyle(.stSecondary)
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
                            Button(showCopySuccess ? "Copied" : "Copy transcript",
                                   systemImage: showCopySuccess ? "checkmark" : "doc.on.doc") {
                                ClipboardService.shared.copy(text: result.displayText)
                                withAnimation { showCopySuccess = true }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                    withAnimation { showCopySuccess = false }
                                }
                            }
                            .buttonStyle(.stSecondary).accessibilityIdentifier("copyConversation")
                        }
                        ConversationTranscriptView(itemID: result.id)
                    }
                    .themedCard()
                }
            }
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(PageLayout.padding)
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
        .onChange(of: session.language) { session.refreshModels() }
        .onChange(of: session.detectSpeakers) { session.refreshModels() }
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
                Text("Finishing up. Nothing will be saved.")
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

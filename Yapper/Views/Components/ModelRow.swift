import SwiftUI

/// Model details and explicit download, selection, and removal actions.
struct ModelRow: View {
    let model: AIModel
    @Binding var selectedModel: String
    var isRecommended: Bool = false

    @ObservedObject var downloadService = ModelDownloadService.shared
    private var transcription: TranscriptionManager { TranscriptionManager.shared }

    private var isLoadingModel: Bool { transcription.warmingVariant == model.variant }
    @State private var isDeletingModel = false
    @State private var showingDeleteConfirmation = false

    var progress: Double { downloadService.downloadProgress[model.variant] ?? 0 }
    var isDownloading: Bool { downloadService.isDownloading[model.variant] ?? false }
    var isDownloaded: Bool { progress >= 1 && ModelStorage.transcriptionModelReady(model.variant) }
    var isActive: Bool { selectedModel == model.variant }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    modelSummary
                    Spacer(minLength: 12)
                    actions.fixedSize()
                }
                VStack(alignment: .leading, spacing: 12) {
                    modelSummary
                    actions
                }
            }

            HStack(spacing: 24) {
                metric("Speed", value: model.speed, tint: .accentBlue)
                metric("Accuracy", value: model.accuracy, tint: .accentPrimary)
            }
            .frame(maxWidth: 420)

            if let warning = model.ramWarning(deviceRAMGB: WhisperService.deviceRAMGB) {
                note(icon: "exclamationmark.triangle", text: warning, tint: .accentWarning)
            }
            if let error = downloadService.downloadError[model.variant] ?? (isActive ? transcription.warmupError : nil) {
                note(icon: "exclamationmark.circle", text: error, tint: .accentError)
            }
            if isLoadingModel { loadingIndicator }
            if isDownloading { downloadProgressSection }
        }
        .padding(16)
        .background(Color.bgCard)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isActive ? Color.accentPrimary : Color.border, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("model.\(model.variant)")
        .confirmationDialog("Delete \(model.name)?", isPresented: $showingDeleteConfirmation) {
            Button("Delete Model", role: .destructive, action: deleteModel)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the downloaded model, not your recordings or transcripts. You can download it again.\(isActive ? " Your model selection will be cleared." : "")")
        }
    }

    private func metric(_ label: String, value: Double, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(Typography.caption).foregroundStyle(Color.textSecondary)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.bgHover)
                    Capsule().fill(tint).frame(width: geometry.size.width * min(1, max(0, value / 10)))
                }
            }
            .frame(height: 5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), relative estimate \(value.formatted()) out of 10, not a benchmark")
        .accessibilityIdentifier("model.metric.\(label.lowercased()).\(model.variant)")
    }

    private var modelSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.name)
                .font(Typography.modelName)
                .foregroundStyle(Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Text(model.details)
                .font(Typography.bodySmall)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("\(model.size) download · \(model.languageSupportLabel)")
                .font(Typography.caption)
                .foregroundStyle(Color.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            if isActive {
                Label(isDownloaded ? "Selected for all transcription" : "Selected · download needed", systemImage: "checkmark.circle.fill")
                    .font(Typography.labelSmall)
                    .foregroundStyle(Color.accentPrimary)
            } else if isRecommended {
                Text("Suggested for this Mac")
                    .font(Typography.labelSmall)
                    .foregroundStyle(Color.accentPrimary)
            } else if isDownloaded {
                Text("Downloaded")
                    .font(Typography.caption)
                    .foregroundStyle(Color.textSecondary)
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 8) {
            if isDownloaded {
                if !isActive {
                    Button("Use", action: loadAndSelectModel)
                        .buttonStyle(.stSecondary)
                        .disabled(isLoadingModel || isDeletingModel)
                        .help("Use \(model.name) for all transcription")
                        .accessibilityLabel("Use \(model.name) for all transcription")
                        .accessibilityIdentifier("model.use.\(model.variant)")
                }
                Button {
                    showingDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                        .frame(width: 16, height: 18)
                }
                .buttonStyle(.stGhost)
                .disabled(isLoadingModel || isDeletingModel || ConversationSession.shared.isBusy)
                .help("Delete \(model.name)")
                .accessibilityLabel("Delete \(model.name)")
                .accessibilityIdentifier("model.delete.\(model.variant)")
            } else if isDownloading {
                Button(downloadService.isCanceling[model.variant] == true ? "Canceling…" : "Cancel") {
                    downloadService.cancelDownload(for: model.variant)
                }
                .buttonStyle(.stSecondary)
                .disabled(downloadService.isCanceling[model.variant] == true)
                .accessibilityLabel("Cancel \(model.name) download")
                .accessibilityIdentifier("model.cancel.\(model.variant)")
            } else {
                Button {
                    downloadService.downloadModel(variant: model.variant)
                } label: {
                    Label(downloadService.downloadError[model.variant] == nil ? "Download" : "Retry", systemImage: "arrow.down")
                }
                .buttonStyle(.stSecondary)
                .disabled(isDeletingModel)
                .accessibilityLabel("Download \(model.name)")
                .accessibilityIdentifier("model.download.\(model.variant)")
            }
        }
    }

    private var loadingIndicator: some View {
        HStack(alignment: .top, spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(transcription.isLoading ? "Preparing selected model…" : "Waiting to prepare selected model…")
                    .font(Typography.bodySmall)
                    .foregroundStyle(Color.textSecondary)
                if let start = transcription.warmupStartedAt {
                    TimelineView(.periodic(from: start, by: 1)) { context in
                        Text("\(max(0, Int(context.date.timeIntervalSince(start)))) seconds elapsed")
                            .font(Typography.caption)
                            .monospacedDigit()
                            .foregroundStyle(Color.textMuted)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var downloadProgressSection: some View {
        let fraction = min(1, max(0, progress))
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(downloadService.isCanceling[model.variant] == true ? "Canceling…" : (fraction >= 0.99 ? "Finishing model files…" : "Downloading…"))
                Spacer()
                Text("\(Int(fraction * 100))%")
                    .monospacedDigit()
            }
            .font(Typography.caption)
            .foregroundStyle(Color.textSecondary)
            .accessibilityHidden(true)

            ProgressView(value: fraction, total: 1)
                .tint(Color.accentPrimary)
                .accessibilityLabel("Downloading \(model.name)")
                .accessibilityValue("\(Int(fraction * 100)) percent")
        }
    }

    private func note(icon: String, text: String, tint: Color) -> some View {
        Label(text, systemImage: icon)
            .font(Typography.bodySmall)
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func deleteModel() {
        isDeletingModel = true
        Task { @MainActor in
            _ = await downloadService.deleteModel(variant: model.variant)
            if selectedModel == model.variant { selectedModel = ModelSelection.none }
            isDeletingModel = false
        }
    }

    private func loadAndSelectModel() {
        selectedModel = model.variant
        transcription.warmSelectedModel()
    }
}

import SwiftUI

/// Manage downloaded models without changing a saved selection implicitly.
struct AIModelsView: View {
    @ObservedObject private var downloadService = ModelDownloadService.shared
    @AppStorage(ModelSelection.defaultsKey) private var selectedModel: String = ModelSelection.none
    @AppStorage("transcriptionLanguage") private var transcriptionLanguage = ModelSelection.defaultLanguage

    private var capability: DeviceCapability { .current }
    private var recommendedModel: AIModel { AIModel.recommendedModel(for: capability) }
    private var selectedModelObject: AIModel? {
        let variant = ModelSelection.displayedVariant(selectedModel, language: transcriptionLanguage)
        return AIModel.availableModels.first { $0.variant == variant }
    }

    /// Hinglish first, then the general models in catalog order.
    private var models: [AIModel] {
        AIModel.availableModels.filter(\.isHinglish) + AIModel.availableModels.filter { !$0.isHinglish }
    }

    @State private var unusedFolders: [URL] = []
    @State private var unusedBytes: Int64 = 0
    @State private var isRemovingUnused = false
    @State private var confirmingUnusedRemoval = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                currentSelection
                modelList
                if !unusedFolders.isEmpty { unusedFilesRow }
            }
            .padding(24)
        }
        .tint(Color.accentPrimary)
        .accessibilityIdentifier("aiModels")
        .task {
            await downloadService.refreshDownloadedModels()
            await findUnusedFiles()
        }
    }

    private var currentSelection: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Your transcription model")
                    .font(Typography.labelMedium)
                    .foregroundStyle(Color.textSecondary)

                Text(selectedModelObject?.name ?? "No model selected")
                    .font(Typography.headlineLarge)
                    .foregroundStyle(Color.textPrimary)
                    .accessibilityIdentifier("models.dictationSelection")

                if let model = selectedModelObject {
                    if !ModelStorage.transcriptionModelReady(model.variant) {
                        Text("Download this model below before using dictation.")
                            .font(Typography.bodySmall)
                            .foregroundStyle(Color.textSecondary)
                    }
                } else {
                    Text("Download a model, then choose Use to select it for dictation and conversations.")
                        .font(Typography.bodySmall)
                        .foregroundStyle(Color.textSecondary)
                }
            }

            Divider()

            Label {
                Text("One selection for dictation, microphone conversations, and imported files. Changes apply to the next recording. Speaker detection uses a separate local model.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "person.2")
                    .accessibilityHidden(true)
            }
            .font(Typography.bodySmall)
            .foregroundStyle(Color.textSecondary)
            .accessibilityIdentifier("models.conversationModelNote")
        }
        .themedCard(padding: 18)
    }

    private var modelList: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(models) { model in
                ModelRow(
                    model: model,
                    selectedModel: $selectedModel,
                    isRecommended: model.variant == recommendedModel.variant
                )
            }
        }
    }

    private var unusedFilesRow: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Remove unused model files")
                    .font(Typography.labelLarge)
                    .foregroundStyle(Color.textPrimary)
                Text("\(ByteCountFormatter.string(fromByteCount: unusedBytes, countStyle: .file)) from models Yapper no longer offers.")
                    .font(Typography.caption)
                    .foregroundStyle(Color.textSecondary)
            }
            Spacer(minLength: 12)
            Button(isRemovingUnused ? "Removing…" : "Remove") { confirmingUnusedRemoval = true }
                .buttonStyle(.stSecondary)
                .disabled(isRemovingUnused || downloadService.isDownloading.values.contains(true))
                .accessibilityIdentifier("models.removeUnused")
        }
        .themedCard(padding: 16)
        .confirmationDialog("Remove unused model files?", isPresented: $confirmingUnusedRemoval) {
            Button("Remove files", role: .destructive) { Task { await removeUnusedFiles() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This frees \(ByteCountFormatter.string(fromByteCount: unusedBytes, countStyle: .file)). Your recordings, transcripts, and current models stay.")
        }
    }

    private func findUnusedFiles() async {
        let (folders, bytes) = await Task.detached(priority: .utility) {
            let folders = AIModel.unusedModelFolders()
            return (folders, AIModel.allocatedSize(of: folders))
        }.value
        unusedFolders = folders
        unusedBytes = bytes
    }

    private func removeUnusedFiles() async {
        isRemovingUnused = true
        let folders = unusedFolders
        await Task.detached(priority: .userInitiated) {
            for folder in folders { try? FileManager.default.removeItem(at: folder) }
        }.value
        await downloadService.refreshDownloadedModels()
        await findUnusedFiles()
        isRemovingUnused = false
    }
}

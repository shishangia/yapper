import SwiftUI

/// Manage downloaded models without changing a saved selection implicitly.
struct AIModelsView: View {
    @ObservedObject private var downloadService = ModelDownloadService.shared
    @AppStorage(ModelSelection.defaultsKey) private var selectedModel: String = ModelSelection.none
    @AppStorage("modelUseCase") private var useCaseRaw: String = AIModel.UseCase.dictation.rawValue

    private var capability: DeviceCapability { .current }
    private var useCase: AIModel.UseCase { AIModel.UseCase(rawValue: useCaseRaw) ?? .dictation }
    private var recommendedModel: AIModel { AIModel.recommendedModel(for: capability, useCase: useCase) }
    private var selectedModelObject: AIModel? {
        AIModel.availableModels.first { $0.variant == selectedModel }
    }

    private var engineGroups: [(title: String, subtitle: String, models: [AIModel])] {
        [
            ("Parakeet", "NVIDIA · on-device speech recognition", AIModel.models(for: .parakeet)),
            ("Whisper", "OpenAI · on-device speech recognition", AIModel.models(for: .whisper)),
        ]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("AI Models")
                        .font(Typography.displayLarge)
                        .foregroundStyle(Color.textPrimary)
                    Text("Download and manage the models used on this Mac.")
                        .font(Typography.bodyMedium)
                        .foregroundStyle(Color.textSecondary)
                }

                currentSelection
                recommendationControls
                modelList
            }
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(28)
        }
        .background(Color.bgContent)
        .tint(Color.accentPrimary)
        .accessibilityIdentifier("aiModels")
        .task {
            await downloadService.refreshDownloadedModels()
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

    private var recommendationControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Model suggestions")
                .font(Typography.headlineMedium)
                .foregroundStyle(Color.textPrimary)

            Picker("Recommendation preference", selection: $useCaseRaw) {
                ForEach(AIModel.UseCase.allCases) { useCase in
                    Text(useCase.title).tag(useCase.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 420)
            .accessibilityIdentifier("models.useCase")

            Text("Suggested: \(recommendedModel.name)")
                .font(Typography.labelMedium)
                .foregroundStyle(Color.textPrimary)

            Text("Speed and accuracy bars are relative estimates, not benchmarks or accuracy percentages. Suggestions consider your Mac (\(capability.summary)); changing this preference does not select a model.")
                .font(Typography.bodySmall)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var modelList: some View {
        VStack(alignment: .leading, spacing: 24) {
            ForEach(engineGroups, id: \.title) { group in
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(group.title)
                            .font(Typography.sectionTitle)
                            .foregroundStyle(Color.textPrimary)
                        Text(group.subtitle)
                            .font(Typography.bodySmall)
                            .foregroundStyle(Color.textSecondary)
                    }

                    ForEach(group.models) { model in
                        ModelRow(
                            model: model,
                            selectedModel: $selectedModel,
                            isRecommended: model.variant == recommendedModel.variant
                        )
                    }
                }
            }
        }
    }
}

import AppKit
import SwiftUI

struct MenuBarDashboardView: View {
    @ObservedObject private var history = HistoryService.shared
    @AppStorage(ModelSelection.defaultsKey) private var selectedModel = ModelSelection.none
    @AppStorage("transcriptionLanguage") private var transcriptionLanguage = ModelSelection.defaultLanguage
    let openDashboard: () -> Void
    let quit: () -> Void

    private var modelName: String {
        let variant = ModelSelection.resolvedVariant(selectedModel, language: transcriptionLanguage)
        guard let name = AIModel.availableModels.first(where: { $0.variant == variant })?.name else {
            return "Choose a model to start"
        }
        return ModelStorage.transcriptionModelReady(variant) ? name : "\(name) (not downloaded)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(decorative: "AppLogo").resizable().frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Yapper").font(.system(size: 21, weight: .semibold, design: .rounded))
                    Text("A little less typing.").font(Typography.caption).foregroundStyle(Color.textSecondary)
                }
                Spacer()
                Button("Open", action: openDashboard)
                    .buttonStyle(.stSecondary).accessibilityIdentifier("menu.open")
            }
            HStack(spacing: 0) {
                statistic("Today", value: history.transcriptionCount(since: Calendar.current.startOfDay(for: Date())), tint: .candyBlush)
                statistic("Total", value: history.transcriptionCount(), tint: .candyLilac)
                statistic("Words", value: history.totalWordCount(), tint: .candyCloud)
                statistic("Saved min", value: history.totalWordCount() / 40, tint: .candyBlue)
            }
            .padding(.vertical, 12)
            .background(Color.bgCard, in: RoundedRectangle(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Recent words").font(Typography.headlineMedium)
                    Spacer()
                    Text("Click to copy").font(Typography.captionSmall).foregroundStyle(Color.textSecondary)
                }
                if history.items.isEmpty {
                    Text("Your latest transcripts will appear here.")
                        .font(Typography.bodySmall).foregroundStyle(Color.textSecondary)
                        .padding(.vertical, 18)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(history.items.prefix(5))) { item in
                            MenuBarTranscriptRow(item: item)
                        }
                    }
                    .background(Color.bgCard, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            Label(modelName, systemImage: "cpu")
                .font(Typography.caption).foregroundStyle(Color.textSecondary)
                .lineLimit(2).accessibilityIdentifier("menu.selectedModel")
            Divider()
            HStack {
                Text("Shivam").font(Typography.labelSmall).foregroundStyle(Color.textSecondary)
                Spacer()
                Button("Open Dashboard", action: openDashboard).buttonStyle(.stGhost)
                Button("Quit", action: quit).buttonStyle(.stGhost).accessibilityIdentifier("menu.quit")
            }
        }
        .foregroundStyle(Color.textPrimary)
        .padding(20).frame(width: 390)
        .background(Color.bgApp)
    }

    private func statistic(_ label: String, value: Int, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Capsule().fill(tint).frame(width: 22, height: 4).accessibilityHidden(true)
            Text(value.formatted(.number.notation(.compactName)))
                .font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(label).font(Typography.captionSmall).foregroundStyle(Color.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(value)")
    }
}

private struct MenuBarTranscriptRow: View {
    let item: HistoryItem
    @State private var hovered = false

    var body: some View {
        Button {
            ClipboardService.shared.copy(text: item.displayText)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "text.bubble").foregroundStyle(Color.accentPrimary)
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.displayText.isEmpty ? "Empty transcription" : item.displayText)
                        .font(Typography.bodySmall).lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack {
                        Text(item.date, style: .relative)
                        Spacer()
                        Text("\(item.transcript.split(whereSeparator: \.isWhitespace).count) words")
                        Image(systemName: "doc.on.doc")
                    }
                    .font(Typography.captionSmall).foregroundStyle(Color.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(hovered ? Color.bgHover : .clear, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("Copy transcript")
        .accessibilityIdentifier("menu.transcript.\(item.id)")
    }
}

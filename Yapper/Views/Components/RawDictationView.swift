import SwiftUI

struct RawDictationView: View {
    let item: HistoryItem
    var body: some View {
        if let raw = item.rawTranscription, item.conversation == nil {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 12) {
                    if let note = item.cleanupNote {
                        Text(note)
                            .font(Typography.captionSmall)
                            .foregroundStyle(Color.textMuted)
                    }
                    Text(raw)
                        .font(Typography.bodyMedium)
                        .foregroundStyle(Color.textPrimary)
                        .textSelection(.enabled)
                    Button("Copy original") { ClipboardService.shared.copy(text: raw) }
                        .buttonStyle(.stSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
            } label: {
                Text("Original recognition")
                    .font(Typography.labelLarge)
                    .foregroundStyle(Color.textSecondary)
            }
            .accessibilityIdentifier("rawDictation")
        }
    }
}

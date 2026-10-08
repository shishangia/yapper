import SwiftUI

struct RawDictationView: View {
    let item: HistoryItem

    /// The recognized text before cleanup, only when cleanup actually changed it.
    static func original(for item: HistoryItem) -> String? {
        guard item.conversation == nil, let raw = item.rawTranscription else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != item.transcript.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return raw
    }

    var body: some View {
        if let raw = Self.original(for: item) {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 12) {
                    if let note = item.cleanupNote {
                        Text(note)
                            .font(Typography.caption)
                            .foregroundStyle(Color.textMuted)
                    }
                    Text(raw)
                        .font(Typography.bodyMedium)
                        .foregroundStyle(Color.textPrimary)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
            } label: {
                Text("Before cleanup")
                    .font(Typography.labelLarge)
                    .foregroundStyle(Color.textSecondary)
            }
            .accessibilityIdentifier("rawDictation")
        }
    }
}

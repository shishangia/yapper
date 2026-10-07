import SwiftUI

struct RawDictationView: View {
    let item: HistoryItem
    var body: some View {
        if let raw = item.rawTranscription, item.conversation == nil {
            DisclosureGroup("Original recognition") {
                VStack(alignment: .leading, spacing: 8) {
                    if let note = item.cleanupNote { Text(note).font(Typography.caption).foregroundStyle(Color.textSecondary) }
                    Text(raw).textSelection(.enabled)
                    Button("Copy original") { ClipboardService.shared.copy(text: raw) }.buttonStyle(.stSecondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.accessibilityIdentifier("rawDictation")
        }
    }
}

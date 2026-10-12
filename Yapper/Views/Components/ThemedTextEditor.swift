import SwiftUI

struct ThemedTextEditor: View {
    @Binding var text: String
    var placeholder = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextEditor(text: $text)
            .font(Typography.bodyMedium)
            .foregroundStyle(Color.textPrimary)
            .scrollContentBackground(.hidden)
            .focused($isFocused)
            .padding(10)
            .overlay(alignment: .topLeading) {
                if text.isEmpty && !placeholder.isEmpty {
                    // Inset to the editor's first line: 10pt padding plus the text view's 5pt line padding.
                    Text(placeholder)
                        .font(Typography.bodyMedium)
                        .foregroundStyle(Color.textMuted)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 10)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .background(Color.bgHover)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isFocused ? Color.borderActive : Color.border.opacity(0.6), lineWidth: 1)
            }
    }
}

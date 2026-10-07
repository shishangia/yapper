import SwiftUI

struct ThemedTextEditor: View {
    @Binding var text: String
    @FocusState private var isFocused: Bool

    var body: some View {
        TextEditor(text: $text)
            .font(Typography.bodyMedium)
            .foregroundStyle(Color.textPrimary)
            .scrollContentBackground(.hidden)
            .focused($isFocused)
            .padding(10)
            .background(Color.bgHover)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isFocused ? Color.borderActive : Color.border.opacity(0.6), lineWidth: 1)
            }
    }
}

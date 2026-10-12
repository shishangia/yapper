import SwiftUI

/// A short, quiet confirmation pinned to the bottom of a screen.
struct Toast: View {
    let message: String
    var systemImage = "checkmark.circle.fill"

    var body: some View {
        HStack(spacing: 8) {
            // The capsule is dark in both themes, so the icon uses the light blue.
            Image(systemName: systemImage)
                .foregroundStyle(Color.candyBlue)
            Text(message)
                .font(Typography.labelMedium)
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.ink, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        .shadow(radius: 10)
        .padding(.bottom, 30)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityElement(children: .combine)
    }
}

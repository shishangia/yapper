import SwiftUI

/// A short, quiet confirmation pinned to the bottom of a screen.
struct Toast: View {
    let message: String
    var systemImage = "checkmark.circle.fill"

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(Color.accentBlue)
            Text(message)
                .font(Typography.labelMedium)
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Material.ultraThinMaterial)
        .background(Color.black.opacity(0.8))
        .clipShape(Capsule())
        .shadow(radius: 10)
        .padding(.bottom, 30)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityElement(children: .combine)
    }
}

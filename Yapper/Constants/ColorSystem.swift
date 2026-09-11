import SwiftUI

// MARK: - Yapper Design System

extension Color {
    // MARK: - Surfaces

    static let bgApp = Color(light: "F6F7FA", dark: "15181F")
    static let bgContent = Color(light: "F9FAFC", dark: "191D25")
    static let bgSidebar = Color(light: "F0F2F6", dark: "14171D")
    static let bgSurface = Color(light: "FFFFFF", dark: "222731")
    static let bgCard = bgSurface
    static let bgHover = Color(light: "E8ECF3", dark: "2D3440")
    static let bgSelected = Color(light: "E4EEFF", dark: "253F64")

    // MARK: - Borders

    static let border = Color(light: "CAD1DC", dark: "434D5D")
    static let borderSubtle = Color(light: "DDE2EA", dark: "343D4A")
    static let borderCard = border
    static let borderActive = accentPrimary

    // MARK: - Text

    static let textPrimary = Color(light: "182230", dark: "F2F5FA")
    static let textSecondary = Color(light: "4F5D70", dark: "B8C4D6")
    static let textMuted = Color(light: "5E6B7C", dark: "A5B3C7")
    static let textDisabled = Color(light: "697586", dark: "8792A2")
    static let sidebarItem = textSecondary
    static let sidebarItemHoverBg = bgHover

    // MARK: - Accents

    static let accentPrimary = Color(light: "1F5DB8", dark: "9AC0FF")
    static let brandAccent = accentPrimary
    static let brandAccentSoft = bgSelected
    static let accentSuccess = Color(light: "227344", dark: "86D5A2")
    static let accentWarning = Color(light: "8A510A", dark: "F2C078")
    static let accentError = Color(light: "B52D3B", dark: "FFABB3")
    static let accentBlue = accentPrimary

    static let chartRed = accentError
    static let chartBlue = accentPrimary
    static let chartGreen = accentSuccess

    // MARK: - Buttons

    // Button fill is separate from the text accent to keep white labels readable.
    static let btnPrimaryBg = Color(light: "215FBA", dark: "2A65BE")
    static let btnPrimaryFg = Color.white
    static let btnSecondaryBg = Color(light: "EDF0F5", dark: "2D3440")
    static let btnSecondaryHover = Color(light: "E0E6EF", dark: "394352")

    // MARK: - Badges

    static let badgeVoiceBg = Color(light: "E5F2E9", dark: "203D2D")
    static let badgeVoiceText = accentSuccess
    static let badgeMusicBg = bgSelected
    static let badgeMusicText = accentPrimary
    static let badgeMutedBg = bgHover
    static let badgeMutedText = textSecondary

    // Existing names remain available to screens that use the shared palette.
    static let cream = Color(hex: "F6F7FA")
    static let creamWarm = Color(hex: "F0F2F6")
    static let ink = Color(hex: "15181F")
    static let inkLight = Color(hex: "222731")
    static let inkSurface = Color(hex: "2D3440")
    static let lavender = Color(hex: "E4EEFF")
    static let lavenderDark = Color(hex: "253F64")
    static let navyInk = accentPrimary
    static let navyLight = accentPrimary
    static let navyMuted = textSecondary
    static let charcoal = ink
    static let charcoalLight = inkLight
    static let charcoalSurface = inkSurface
    static let accentWarm = accentWarning
    static let accentCool = accentPrimary
    static let accentRed = accentError
    static let accentRedSoft = Color(light: "FAE9EC", dark: "462930")
    static let accentBlueSoft = bgSelected

    // Flat fills preserve the gradient API used by existing components.
    static let gradientPrimary = LinearGradient(
        colors: [btnPrimaryBg, btnPrimaryBg], startPoint: .leading, endPoint: .trailing)
    static let gradientButton = gradientPrimary
    static let gradientSidebarActive = LinearGradient(
        colors: [bgSelected, bgSelected], startPoint: .leading, endPoint: .trailing)
    static let gradientWarm = LinearGradient(
        colors: [.clear, .clear], startPoint: .leading, endPoint: .trailing)
}

// MARK: - Surface Modifiers

extension View {
    func cardShadow() -> some View {
        shadow(color: .black.opacity(0.03), radius: 2, x: 0, y: 1)
    }

    func softShadow() -> some View {
        shadow(color: .black.opacity(0.03), radius: 2, x: 0, y: 1)
    }

    func elevatedShadow() -> some View {
        shadow(color: .black.opacity(0.10), radius: 12, x: 0, y: 4)
    }
}

struct ThemedCardModifier: ViewModifier {
    var padding: CGFloat = 24
    var cornerRadius: CGFloat = 14

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Color.bgCard)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.border, lineWidth: 1)
            )
    }
}

extension View {
    func themedCard(padding: CGFloat = 24, cornerRadius: CGFloat = 14) -> some View {
        modifier(ThemedCardModifier(padding: padding, cornerRadius: cornerRadius))
    }
}

// MARK: - Button Styles

struct STButtonPrimary: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.buttonLabel)
            .foregroundStyle(isEnabled ? Color.btnPrimaryFg : Color.textDisabled)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .frame(minHeight: 36)
            .background(isEnabled ? Color.btnPrimaryBg : Color.bgHover)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .opacity(isEnabled && configuration.isPressed ? 0.85 : 1)
    }
}

struct STButtonSecondary: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.buttonLabel)
            .foregroundStyle(isEnabled ? Color.textPrimary : Color.textDisabled)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .frame(minHeight: 36)
            .background(configuration.isPressed && isEnabled ? Color.btnSecondaryHover : Color.btnSecondaryBg)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.border, lineWidth: 1)
            )
    }
}

struct STButtonGhost: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.bodySmall)
            .foregroundStyle(isEnabled ? Color.textSecondary : Color.textDisabled)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minHeight: 34)
            .background(configuration.isPressed && isEnabled ? Color.bgHover : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

extension ButtonStyle where Self == STButtonPrimary {
    static var stPrimary: STButtonPrimary { STButtonPrimary() }
}

extension ButtonStyle where Self == STButtonSecondary {
    static var stSecondary: STButtonSecondary { STButtonSecondary() }
}

extension ButtonStyle where Self == STButtonGhost {
    static var stGhost: STButtonGhost { STButtonGhost() }
}

struct SelectionBackground: View {
    let isSelected: Bool
    let isHovered: Bool
    var cornerRadius: CGFloat = 12

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(isSelected ? Color.bgSelected : (isHovered ? Color.bgHover : Color.clear))
    }
}

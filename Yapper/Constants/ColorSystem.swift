import SwiftUI

extension Color {
    static let candyLilac = Color(hex: "CDB4DA")
    static let candyBlush = Color(hex: "FFC8DC")
    static let candyPink = Color(hex: "FFAFCC")
    static let candyCloud = Color(hex: "BEE0FE")
    static let candyBlue = Color(hex: "A2D2FF")

    static let bgApp = Color(light: "FCF8FB", dark: "201C25")
    static let bgContent = Color(light: "FFFCFE", dark: "241F2B")
    static let bgSidebar = Color(light: "F5EDF7", dark: "211B28")
    static let bgSurface = Color(light: "FFFFFF", dark: "302837")
    static let bgCard = bgSurface
    static let bgHover = Color(light: "F2E7F0", dark: "3D3245")
    static let bgSelected = Color(light: "FFC8DC", dark: "523449")
    static let border = Color(light: "D9CBDC", dark: "65536E")
    static let borderSubtle = Color(light: "EBE1ED", dark: "493B52")
    static let borderCard = border
    static let borderActive = accentPrimary

    static let textPrimary = Color(light: "302438", dark: "FCF2FA")
    static let textSecondary = Color(light: "63526C", dark: "D8C7E1")
    static let textMuted = Color(light: "706078", dark: "C3B0CE")
    static let textDisabled = Color(light: "796B81", dark: "AB96B5")
    static let sidebarItem = textSecondary
    static let sidebarItemHoverBg = bgHover

    static let accentPrimary = Color(light: "8B365F", dark: "FFAFCC")
    static let brandAccent = accentPrimary
    static let brandAccentSoft = bgSelected
    static let accentSuccess = Color(light: "227344", dark: "86D5A2")
    static let accentWarning = Color(light: "8A510A", dark: "F2C078")
    static let accentError = Color(light: "B52D3B", dark: "FFABB3")
    static let accentBlue = Color(light: "285E91", dark: "A2D2FF")
    static let chartRed = accentError
    static let chartBlue = accentBlue
    static let chartGreen = accentSuccess

    static let btnPrimaryBg = candyPink
    static let btnPrimaryFg = Color(hex: "302438")
    static let btnSecondaryBg = Color(light: "F4EAF5", dark: "3D3245")
    static let btnSecondaryHover = Color(light: "EADBED", dark: "51415B")
    static let badgeVoiceBg = Color(light: "E5F2E9", dark: "203D2D")
    static let badgeVoiceText = accentSuccess
    static let badgeMusicBg = bgSelected
    static let badgeMusicText = accentPrimary
    static let badgeMutedBg = bgHover
    static let badgeMutedText = textSecondary

    static let cream = Color(hex: "FCF8FB")
    static let creamWarm = Color(hex: "F5EDF7")
    static let ink = Color(hex: "201C25")
    static let inkLight = Color(hex: "302837")
    static let inkSurface = Color(hex: "3D3245")
    static let lavender = candyLilac
    static let lavenderDark = Color(hex: "523449")
    static let navyInk = accentPrimary
    static let navyLight = accentPrimary
    static let navyMuted = textSecondary
    static let charcoal = ink
    static let charcoalLight = inkLight
    static let charcoalSurface = inkSurface
    static let accentWarm = accentWarning
    static let accentCool = accentBlue
    static let accentRed = accentError
    static let accentRedSoft = Color(light: "FAE9EC", dark: "462930")
    static let accentBlueSoft = Color(light: "E4F2FF", dark: "293D53")

    static let gradientPrimary = LinearGradient(colors: [btnPrimaryBg, btnPrimaryBg], startPoint: .leading, endPoint: .trailing)
    static let gradientButton = gradientPrimary
    static let gradientSidebarActive = LinearGradient(colors: [bgSelected, bgSelected], startPoint: .leading, endPoint: .trailing)
    static let gradientWarm = LinearGradient(colors: [.clear, .clear], startPoint: .leading, endPoint: .trailing)
}

extension View {
    func cardShadow() -> some View { shadow(color: .black.opacity(0.03), radius: 2, x: 0, y: 1) }
    func softShadow() -> some View { shadow(color: .black.opacity(0.03), radius: 2, x: 0, y: 1) }
    func elevatedShadow() -> some View { shadow(color: .black.opacity(0.10), radius: 12, x: 0, y: 4) }
}

struct ThemedCardModifier: ViewModifier {
    var padding: CGFloat = 24
    var cornerRadius: CGFloat = 14

    func body(content: Content) -> some View {
        content.padding(padding)
            .background(Color.bgCard)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Color.border, lineWidth: 1))
    }
}

extension View {
    func themedCard(padding: CGFloat = 24, cornerRadius: CGFloat = 14) -> some View {
        modifier(ThemedCardModifier(padding: padding, cornerRadius: cornerRadius))
    }
}

struct STButtonPrimary: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(Typography.buttonLabel)
            .foregroundStyle(isEnabled ? Color.btnPrimaryFg : Color.textDisabled)
            .padding(.horizontal, 16).padding(.vertical, 9).frame(minHeight: 36)
            .background(isEnabled ? Color.btnPrimaryBg : Color.bgHover)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .opacity(isEnabled && configuration.isPressed ? 0.85 : 1)
    }
}

struct STButtonSecondary: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(Typography.buttonLabel)
            .foregroundStyle(isEnabled ? Color.textPrimary : Color.textDisabled)
            .padding(.horizontal, 16).padding(.vertical, 9).frame(minHeight: 36)
            .background(configuration.isPressed && isEnabled ? Color.btnSecondaryHover : Color.btnSecondaryBg)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.border, lineWidth: 1))
    }
}

struct STButtonGhost: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(Typography.bodySmall)
            .foregroundStyle(isEnabled ? Color.textSecondary : Color.textDisabled)
            .padding(.horizontal, 12).padding(.vertical, 8).frame(minHeight: 34)
            .background(configuration.isPressed && isEnabled ? Color.bgHover : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

extension ButtonStyle where Self == STButtonPrimary { static var stPrimary: STButtonPrimary { STButtonPrimary() } }
extension ButtonStyle where Self == STButtonSecondary { static var stSecondary: STButtonSecondary { STButtonSecondary() } }
extension ButtonStyle where Self == STButtonGhost { static var stGhost: STButtonGhost { STButtonGhost() } }

struct SelectionBackground: View {
    let isSelected: Bool
    let isHovered: Bool
    var cornerRadius: CGFloat = 12
    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(isSelected ? Color.bgSelected : (isHovered ? Color.bgHover : Color.clear))
    }
}

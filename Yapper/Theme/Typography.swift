import SwiftUI

/// System typography shared by the window, menus, and recorder.
/// Keep token names stable so every screen uses the same native font family.
enum Typography {
    // MARK: - Display

    static let displayLarge = Font.system(.largeTitle, design: .default, weight: .semibold)
    static let displayMedium = Font.system(.title, design: .default, weight: .semibold)
    static let displaySmall = Font.system(.title2, design: .default, weight: .semibold)

    // MARK: - Headings

    static let headlineLarge = Font.system(.title3, design: .default, weight: .semibold)
    static let headlineMedium = Font.system(.headline, design: .default, weight: .semibold)
    static let headlineSmall = Font.system(.body, design: .default, weight: .semibold)
    static let titleLarge = Font.system(size: 15, weight: .semibold)
    static let titleMedium = Font.system(size: 14, weight: .medium)
    static let titleSmall = Font.system(.body, design: .default, weight: .medium)

    // MARK: - Body and Labels

    static let bodyLarge = Font.system(size: 15)
    static let bodyMedium = Font.system(size: 14)
    static let bodySmall = Font.body
    static let labelLarge = Font.system(size: 14, weight: .medium)
    static let labelMedium = Font.system(.body, design: .default, weight: .medium)
    static let labelSmall = Font.system(.callout, design: .default, weight: .medium)
    static let caption = Font.callout
    static let captionSmall = Font.caption
    static let captionBold = Font.system(.caption, design: .default, weight: .semibold)

    // MARK: - Values and Recorder

    static let mono = Font.system(.body, design: .monospaced)
    static let monoSmall = Font.system(.caption, design: .monospaced)
    static let statValue = Font.system(size: 34, weight: .semibold).monospacedDigit()
    static let statLabel = Font.body
    static let badge = Font.system(.caption, design: .default, weight: .medium)
    static let pillLabel = Font.system(size: 13, weight: .medium)
    static let pillTime = Font.system(size: 12, weight: .medium).monospacedDigit()
    static let pillControl = Font.system(size: 11, weight: .semibold)

    // MARK: - Sized Helpers

    static func display(_ size: CGFloat) -> Font { .system(size: size, weight: .semibold) }
    static func displayMedium(_ size: CGFloat) -> Font { .system(size: size, weight: .medium) }
    static func ui(_ size: CGFloat) -> Font { .system(size: size) }
    static func uiMedium(_ size: CGFloat) -> Font { .system(size: size, weight: .medium) }
    static func uiBold(_ size: CGFloat) -> Font { .system(size: size, weight: .semibold) }

    static let heroName = displayLarge
    static let sectionTitle = headlineLarge
    static let modelName = Font.system(size: 15, weight: .semibold)

    // MARK: - Cards

    static let cardTitle = Font.system(size: 16, weight: .semibold)
    static let cardSubtitle = bodyMedium
    static let cardMeta = caption
    static let cardMetaBold = labelSmall
    static let cardDescription = bodySmall
    static let buttonLabel = Font.system(.body, design: .default, weight: .semibold)
    static let buttonLabelSmall = Font.system(.callout, design: .default, weight: .medium)

    // MARK: - Sidebar

    static let sidebarLogo = Font.system(size: 20, weight: .semibold)
    static let sidebarItem = Font.system(size: 14)
    static let sidebarItemActive = Font.system(size: 14, weight: .semibold)
    static let sidebarBadge = badge
    static let sidebarPromoTitle = headlineSmall
    static let sidebarPromoSubtitle = bodySmall
    static let sidebarPromoButton = buttonLabel
}

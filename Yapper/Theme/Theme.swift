//
//  Theme.swift
//  Yapper
//
//  Native surfaces and typography shared with the semantic color system.
//

import SwiftUI

// MARK: - Theme Environment Key

struct ThemeKey: EnvironmentKey {
    static let defaultValue: YapperTheme = .light
}

extension EnvironmentValues {
    var theme: YapperTheme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

// MARK: - Yapper Theme

enum YapperTheme {
    case light
    case dark
    
    // MARK: - Semantic Colors
    
    var background: Color { resolved(.bgApp) }
    var surface: Color { resolved(.bgSurface) }
    var textPrimary: Color { resolved(.textPrimary) }
    var textSecondary: Color { resolved(.textSecondary) }
    var border: Color { resolved(.border) }
    var accent: Color { resolved(.accentPrimary) }

    private func resolved(_ color: Color) -> Color {
        let appearance = NSAppearance(named: self == .dark ? .darkAqua : .aqua)!
        var resolved = NSColor(color)
        appearance.performAsCurrentDrawingAppearance {
            resolved = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        }
        return Color(nsColor: resolved)
    }
}

// MARK: - Theme Provider

struct ThemeProvider<Content: View>: View {
    @Environment(\.colorScheme) private var systemColorScheme
    @AppStorage("appTheme") private var appTheme: AppTheme = .system
    
    let content: Content
    
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }
    
    private var activeTheme: YapperTheme {
        switch appTheme {
        case .light: return .light
        case .dark: return .dark
        case .system: return systemColorScheme == .dark ? .dark : .light
        }
    }
    
    var body: some View {
        content
            .environment(\.theme, activeTheme)
            .tint(Color.accentPrimary)
    }
}

// MARK: - View Modifier

extension View {
    func themed() -> some View {
        ThemeProvider { self }
    }
}

// MARK: - Clean Card Style

extension View {
    func cleanCard(theme: YapperTheme) -> some View {
        self
            .background(theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(theme.border, lineWidth: 1)
            )
    }
}

import SwiftUI
import AISwitcherCore

private struct AppThemeKey: EnvironmentKey {
    static let defaultValue: AppTheme = .light
}
extension EnvironmentValues {
    var appTheme: AppTheme {
        get { self[AppThemeKey.self] }
        set { self[AppThemeKey.self] = newValue }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
    }
}

struct ThemePalette {
    let theme: AppTheme
    var ink: Color { Color(hex: theme.colors.ink) }
    var secondary: Color { Color(hex: theme.colors.secondary) }
    var accent: Color { Color(hex: theme.colors.accent) }
    var onAccent: Color { Color(hex: theme.colors.onAccent) }
    var canvas: Color { Color(hex: theme.colors.canvas) }
    var surface: Color { Color(hex: theme.colors.surface) }
    var sidebar: Color { Color(hex: theme.colors.sidebar) }
    var line: Color { Color(hex: theme.colors.line) }
}

extension AppTheme {
    var colorScheme: ColorScheme { isDark ? .dark : .light }
    var nsAppearance: NSAppearance? { NSAppearance(named: isDark ? .darkAqua : .aqua) }
    func font(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: size, weight: weight, design: monospaced ? .monospaced : design)
    }
    func radius(_ original: CGFloat) -> CGFloat { monospaced ? min(original, CGFloat(cornerRadius)) : original }
}

extension AccountColor {
    func tint(for theme: AppTheme) -> Color {
        let pair: (UInt32, UInt32)
        switch self {
        case .mint: pair = (0x147864, 0x6cd4b4)
        case .blue: pair = (0x3b6ebd, 0x82b8ff)
        case .violet: pair = (0x7d5cb5, 0xc4a2f3)
        case .peach: pair = (0xb85d2d, 0xf4ac7b)
        case .rose: pair = (0xb85275, 0xf39cb9)
        case .gold: pair = (0x8c6b14, 0xe8ce7b)
        }
        return Color(hex: theme.isDark ? pair.1 : pair.0)
    }
    func pale(for theme: AppTheme) -> Color { tint(for: theme).opacity(theme.isDark ? 0.14 : 0.10) }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.appTheme) private var appearanceTheme
    private var palette: ThemePalette { ThemePalette(theme: appearanceTheme) }
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(appearanceTheme.font(size: compact ? 12 : 13, weight: .semibold))
            .foregroundColor(palette.onAccent)
            .padding(.horizontal, compact ? 13 : 18)
            .padding(.vertical, compact ? 9 : 12)
            .background(palette.accent.opacity(configuration.isPressed ? 0.8 : 1))
            .clipShape(RoundedRectangle(cornerRadius: appearanceTheme.radius(9)))
    }
}

struct AccountAvatar: View {
    @Environment(\.appTheme) private var appearanceTheme
    let account: Account
    var size: CGFloat = 46
    var body: some View {
        Text(account.initials)
            .font(appearanceTheme.font(size: size * 0.32, weight: .semibold, design: .rounded))
            .foregroundColor(account.color.tint(for: appearanceTheme))
            .frame(width: size, height: size)
            .background(account.color.pale(for: appearanceTheme))
            .clipShape(RoundedRectangle(cornerRadius: appearanceTheme.radius(size * 0.29)))
            .accessibilityHidden(true)
    }
}

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

extension View {
    func appAppearance(_ preferences: AppPreferences) -> some View {
        environment(\.appTheme, preferences.theme)
            .modifier(ThemeControls(theme: preferences.theme))
            .preferredColorScheme(preferences.theme.colorScheme)
            .environment(\.locale, preferences.language.locale)
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
    var yellow: Color { Color(hex: RetroColors.yellow) }
    var pink: Color { Color(hex: RetroColors.pink) }
    var blue: Color { Color(hex: RetroColors.blue) }
    var mint: Color { Color(hex: RetroColors.mint) }
    var action: Color { theme.isPlayfulRetro ? yellow : accent }
    var onAction: Color { theme.isPlayfulRetro ? ink : onAccent }
}

extension AppTheme {
    var colorScheme: ColorScheme { isDark ? .dark : .light }
    var nsAppearance: NSAppearance? { NSAppearance(named: isDark ? .darkAqua : .aqua) }
    func font(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: size, weight: isPlayfulRetro && weight == .semibold ? .bold : weight,
                design: monospaced ? .monospaced : isPlayfulRetro ? .rounded : design)
    }
    func radius(_ original: CGFloat) -> CGFloat {
        monospaced ? min(original, CGFloat(cornerRadius)) : isPlayfulRetro ? max(original, 12) : original
    }
    var dividerWidth: CGFloat { isPlayfulRetro ? 2.5 : 1 }
    var buttonRadius: CGFloat { isPlayfulRetro ? 100 : radius(9) }
}

/// Opt-in decorations: the original themes retain their existing surfaces and controls.
private struct ThemeControls: ViewModifier {
    let theme: AppTheme
    @ViewBuilder func body(content: Content) -> some View {
        if theme.isPlayfulRetro {
            content.buttonStyle(RetroButtonStyle()).tint(ThemePalette(theme: theme).accent)
                .font(theme.font(size: 13))
        } else if theme.seasonal != nil {
            content.tint(ThemePalette(theme: theme).accent).buttonStyle(SeasonalButtonStyle())
        } else { content }
    }
}

/// Clamp each corner before insetting so circles and short pills have clean edges on macOS.
private struct RetroRoundedRectangle: InsettableShape {
    var radius: CGFloat
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let corner = min(radius, min(rect.width, rect.height) / 2)
        return RoundedRectangle(cornerRadius: max(0, corner - insetAmount))
            .path(in: rect.insetBy(dx: insetAmount, dy: insetAmount))
    }

    func inset(by amount: CGFloat) -> RetroRoundedRectangle {
        var shape = self
        shape.insetAmount += amount
        return shape
    }
}

private struct RetroOutline: ViewModifier {
    @Environment(\.appTheme) private var theme
    var radius: CGFloat
    var shadow: Bool
    var enabled: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if theme.isPlayfulRetro && enabled {
            content
                .overlay(RetroRoundedRectangle(radius: radius).strokeBorder(ThemePalette(theme: theme).ink, lineWidth: theme.outlineWidth).allowsHitTesting(false))
                .background {
                    if shadow {
                        RetroRoundedRectangle(radius: radius).fill(ThemePalette(theme: theme).ink)
                            .offset(x: theme.hardShadowOffset, y: theme.hardShadowOffset)
                    }
                }
        } else { content }
    }
}

extension View {
    func retroOutline(radius: CGFloat = 12, shadow: Bool = true, enabled: Bool = true) -> some View {
        modifier(RetroOutline(radius: radius, shadow: shadow, enabled: enabled))
    }
    func themedTextField() -> some View { modifier(ThemeTextField()) }
    func retroPanel(fill: Color, radius: CGFloat, padding: CGFloat) -> some View {
        modifier(RetroPanel(fill: fill, radius: radius, padding: padding))
    }
}

private struct RetroPanel: ViewModifier {
    @Environment(\.appTheme) private var theme
    let fill: Color
    let radius: CGFloat
    let padding: CGFloat
    @ViewBuilder func body(content: Content) -> some View {
        if theme.isPlayfulRetro {
            content.padding(padding).frame(maxWidth: .infinity, alignment: .leading)
                .background(fill).clipShape(RoundedRectangle(cornerRadius: radius))
                .retroOutline(radius: radius)
        } else { content }
    }
}

private struct ThemeTextField: ViewModifier {
    @Environment(\.appTheme) private var theme
    @ViewBuilder func body(content: Content) -> some View {
        if theme.isPlayfulRetro {
            content.textFieldStyle(.plain).padding(11)
                .background(ThemePalette(theme: theme).canvas)
                .clipShape(RoundedRectangle(cornerRadius: 12)).retroOutline(shadow: false)
        } else { content.textFieldStyle(.roundedBorder) }
    }
}

private struct RetroButtonFace: ViewModifier {
    @Environment(\.appTheme) private var theme
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    let pressed: Bool
    let fill: Color
    var compact = true
    private var shift: CGFloat { pressed && enabled ? 4 : hovering && enabled ? -1 : 0 }

    func body(content: Content) -> some View {
        content
            .font(theme.font(size: compact ? 12 : 13, weight: .bold))
            .foregroundColor(ThemePalette(theme: theme).ink)
            .padding(.horizontal, compact ? 14 : 18).padding(.vertical, compact ? 9 : 12)
            .background(fill).clipShape(RetroRoundedRectangle(radius: theme.buttonRadius))
            .overlay(RetroRoundedRectangle(radius: theme.buttonRadius).strokeBorder(ThemePalette(theme: theme).ink, lineWidth: theme.outlineWidth).allowsHitTesting(false))
            .background {
                RetroRoundedRectangle(radius: theme.buttonRadius).fill(ThemePalette(theme: theme).ink)
                    .offset(x: pressed ? 0 : theme.hardShadowOffset, y: pressed ? 0 : theme.hardShadowOffset)
            }
            .offset(x: shift, y: shift).opacity(enabled ? 1 : 0.45)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: pressed)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 }
    }
}

struct RetroButtonStyle: ButtonStyle {
    @Environment(\.appTheme) private var theme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(RetroButtonFace(pressed: configuration.isPressed, fill: ThemePalette(theme: theme).surface))
    }
}

/// Keeps custom label layouts while giving retro icon, navigation, and card actions a press response.
struct ThemedPlainButtonStyle: PrimitiveButtonStyle {
    @Environment(\.appTheme) private var theme
    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        if theme.isPlayfulRetro {
            Button(configuration).buttonStyle(RetroPressStyle())
        } else { Button(configuration).buttonStyle(.plain) }
    }
}

private struct RetroPressStyle: ButtonStyle {
    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .offset(x: theme.isPlayfulRetro && configuration.isPressed ? 2 : 0,
                    y: theme.isPlayfulRetro && configuration.isPressed ? 2 : 0)
            .animation(reduceMotion || !theme.isPlayfulRetro ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
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
    func pale(for theme: AppTheme) -> Color {
        if theme.isPlayfulRetro {
            let hex: UInt32
            switch self {
            case .mint: hex = RetroColors.mint
            case .blue: hex = RetroColors.blue
            case .violet: hex = RetroColors.violet
            case .peach: hex = RetroColors.peach
            case .rose: hex = RetroColors.pink
            case .gold: hex = RetroColors.yellow
            }
            return Color(hex: hex)
        }
        return tint(for: theme).opacity(theme.isDark ? 0.14 : 0.10)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.appTheme) private var appearanceTheme
    private var palette: ThemePalette { ThemePalette(theme: appearanceTheme) }
    var compact = false
    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        if appearanceTheme.isPlayfulRetro {
            configuration.label.modifier(RetroButtonFace(pressed: configuration.isPressed, fill: palette.action, compact: compact))
        } else {
            configuration.label
            .font(appearanceTheme.font(size: compact ? 12 : 13, weight: .semibold))
            .foregroundColor(palette.onAccent)
            .padding(.horizontal, compact ? 13 : 18)
            .padding(.vertical, compact ? 9 : 12)
            .background(palette.accent.opacity(configuration.isPressed ? 0.8 : 1))
            .clipShape(RoundedRectangle(cornerRadius: appearanceTheme.radius(9)))
        }
    }
}

struct AccountAvatar: View {
    @Environment(\.appTheme) private var appearanceTheme
    let account: Account
    var size: CGFloat = 46
    var body: some View {
        Text(account.initials)
            .font(appearanceTheme.font(size: size * 0.32, weight: .semibold, design: .rounded))
            .foregroundColor(appearanceTheme.isPlayfulRetro ? ThemePalette(theme: appearanceTheme).ink : account.color.tint(for: appearanceTheme))
            .frame(width: size, height: size)
            .background(account.color.pale(for: appearanceTheme))
            .clipShape(RoundedRectangle(cornerRadius: appearanceTheme.radius(size * 0.29)))
            .retroOutline(radius: appearanceTheme.radius(size * 0.29), shadow: size >= 40)
            .accessibilityHidden(true)
    }
}

private struct SeasonalButtonStyle: ButtonStyle {
    @Environment(\.appTheme) private var theme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.padding(.horizontal, 12).padding(.vertical, 7)
            .background(ThemePalette(theme: theme).accent.opacity(configuration.isPressed ? 0.22 : 0.09))
            .clipShape(RoundedRectangle(cornerRadius: theme == .blackFriday ? 3 : 9))
            .overlay(RoundedRectangle(cornerRadius: theme == .blackFriday ? 3 : 9).strokeBorder(ThemePalette(theme: theme).line))
    }
}

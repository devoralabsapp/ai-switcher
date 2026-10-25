import SwiftUI
import AISwitcherCore

enum Palette {
    static let ink = Color(red: 0.10, green: 0.14, blue: 0.17)
    static let secondary = Color(red: 0.43, green: 0.48, blue: 0.51)
    static let accent = Color(red: 0.08, green: 0.47, blue: 0.39)
    static let canvas = Color(red: 0.965, green: 0.973, blue: 0.973)
    static let line = Color(red: 0.88, green: 0.91, blue: 0.91)
}

extension AccountColor {
    var tint: Color {
        switch self {
        case .mint: return Color(red: 0.08, green: 0.48, blue: 0.39)
        case .blue: return Color(red: 0.23, green: 0.43, blue: 0.74)
        case .violet: return Color(red: 0.49, green: 0.36, blue: 0.71)
        case .peach: return Color(red: 0.76, green: 0.40, blue: 0.21)
        case .rose: return Color(red: 0.72, green: 0.32, blue: 0.46)
        case .gold: return Color(red: 0.63, green: 0.48, blue: 0.13)
        }
    }
    var pale: Color { tint.opacity(0.10) }
}

struct PrimaryButtonStyle: ButtonStyle {
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12 : 13, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, compact ? 13 : 18)
            .padding(.vertical, compact ? 9 : 12)
            .background(Palette.accent.opacity(configuration.isPressed ? 0.8 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 9))
    }
}

struct AccountAvatar: View {
    let account: Account
    var size: CGFloat = 46
    var body: some View {
        Text(account.initials)
            .font(.system(size: size * 0.32, weight: .semibold, design: .rounded))
            .foregroundColor(account.color.tint)
            .frame(width: size, height: size)
            .background(account.color.pale)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.29))
            .accessibilityHidden(true)
    }
}

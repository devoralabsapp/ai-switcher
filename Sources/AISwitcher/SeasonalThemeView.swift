import SwiftUI
import AISwitcherCore

struct SeasonalArtwork: View {
    let theme: AppTheme
    var body: some View {
        Canvas { context, size in
            let scale = min(size.width / 360, size.height / 210)
            context.translateBy(x: (size.width - 360 * scale) / 2, y: (size.height - 210 * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            for mark in theme.seasonal?.marks ?? [] {
                if mark.kind == "text", let text = mark.text {
                    context.draw(Text(text).font(.system(size: mark.size ?? 20, weight: .black, design: .monospaced))
                        .foregroundColor(color(mark.color)), at: CGPoint(x: mark.x ?? 0, y: mark.y ?? 0), anchor: .topLeading)
                    continue
                }
                let rect = CGRect(x: mark.x ?? 0, y: mark.y ?? 0, width: mark.w ?? 0, height: mark.h ?? 0)
                var path = Path()
                if mark.kind == "ellipse" { path.addEllipse(in: rect) }
                else if mark.kind == "rect" { path.addRoundedRect(in: rect, cornerSize: CGSize(width: mark.radius ?? 0, height: mark.radius ?? 0)) }
                else if let points = mark.points, let first = points.first {
                    path.move(to: CGPoint(x: first.x, y: first.y))
                    for point in points.dropFirst() { path.addLine(to: CGPoint(x: point.x, y: point.y)) }
                    if mark.closed == true { path.closeSubpath() }
                }
                if mark.color != "clear" { context.fill(path, with: .color(color(mark.color))) }
                if let stroke = mark.stroke { context.stroke(path, with: .color(color(stroke)), style: StrokeStyle(lineWidth: mark.width ?? 2, lineCap: .round, lineJoin: .round)) }
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
    private func color(_ value: String) -> Color {
        Color(hex: UInt32(value.replacingOccurrences(of: "#", with: ""), radix: 16) ?? 0)
    }
}

struct SeasonalHero: View {
    let theme: AppTheme
    private var palette: ThemePalette { ThemePalette(theme: theme) }
    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 14) {
                Label(L10n.text(theme.seasonal?.label ?? ""), systemImage: theme.seasonal?.symbol ?? "sparkles")
                    .font(theme.font(size: 10, weight: .bold)).tracking(1.5).foregroundColor(palette.accent)
                Text(L10n.text("Multiple accounts.\nOne click."))
                    .font(theme.font(size: 31, weight: .bold)).tracking(-0.8).fixedSize(horizontal: false, vertical: true)
                Text(L10n.text("Sign in to each account once.\nSwitch freely, keep your conversations going."))
                    .font(theme.font(size: 12)).lineSpacing(4).foregroundColor(palette.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            SeasonalArtwork(theme: theme).frame(width: 255, height: 176)
        }
        .padding(22).foregroundColor(palette.ink)
        .background(LinearGradient(colors: [palette.surface, palette.canvas], startPoint: .topLeading, endPoint: .bottomTrailing))
        .clipShape(RoundedRectangle(cornerRadius: theme == .blackFriday ? 4 : 20))
        .overlay(RoundedRectangle(cornerRadius: theme == .blackFriday ? 4 : 20).strokeBorder(palette.line, lineWidth: 1))
        .overlay(alignment: .bottom) { SeasonalRibbon(theme: theme).frame(height: 4).padding(.horizontal, 20) }
    }
}

struct SeasonalRibbon: View {
    let theme: AppTheme
    var body: some View {
        if let style = theme.seasonal {
            HStack(spacing: 4) {
                ForEach(0..<12) { i in
                    Capsule().fill(Color(hex: i % 3 == 0 ? style.companion : theme.colors.accent)).opacity(i % 3 == 2 ? 0.35 : 1)
                }
            }.allowsHitTesting(false).accessibilityHidden(true)
        }
    }
}

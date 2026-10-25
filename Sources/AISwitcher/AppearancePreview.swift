import AppKit
import SwiftUI
import AISwitcherCore

/// Renders only app-owned, offscreen views with fictional data. No screen capture.
@MainActor
enum AppearancePreview {
    static func render(root: URL, output: URL) throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let now = Int(Date().timeIntervalSince1970)
        let object: [String: Any] = ["accountId": "demo", "rateLimits": [
            "primary": ["usedPercent": 23, "windowDurationMins": 300, "resetsAt": now + 7_200],
            "secondary": ["usedPercent": 41, "windowDurationMins": 10_080, "resetsAt": now + 345_600]]]
        let limits = try JSONDecoder().decode(CodexRateLimits.self, from: JSONSerialization.data(withJSONObject: object))
        for theme in AppTheme.allCases {
            let data = root.appendingPathComponent(theme.rawValue)
            let connection = CodexConnection(identity: CodexIdentity(email: "demo@example.test", planType: "plus"), quota: CodexQuotaSnapshot(limits: limits))
            let accounts = [Account(name: "Demo Personal", emailHint: "personal@example.test", color: .mint, isFavorite: true, launchMode: .desktop, desktopCodexConnection: connection),
                            Account(name: "Demo Work", emailHint: "work@example.test", color: .blue, launchMode: .desktop),
                            Account(name: "Demo Study", emailHint: "study@example.test", color: .violet, launchMode: .desktop)]
            try ProfileRepository(root: data).save(AccountSnapshot(accounts: accounts))
            let model = AppModel(root: data, preferences: AppPreferences(language: L10n.language, theme: theme), monitoring: false)
            NSApp.appearance = theme.nsAppearance
            try renderView(Dashboard(model: model), size: NSSize(width: 1120, height: 850), to: output.appendingPathComponent("\(theme.rawValue)-\(L10n.language.rawValue).png"))
            try renderView(PreferencesView(model: model), size: NSSize(width: 580, height: 720), to: output.appendingPathComponent("settings-\(theme.rawValue)-\(L10n.language.rawValue).png"))
        }
        print("Rendered appearance previews with fictional profiles: \(output.path)")
    }

    private static func renderView<Content: View>(_ content: Content, size: NSSize, to destination: URL) throws {
        let hosting = NSHostingView(rootView: content.frame(width: size.width, height: size.height))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw ProfileError.invalidSelection }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw ProfileError.invalidSelection }
        try png.write(to: destination, options: .atomic)
        window.contentView = nil
    }
}

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
                            Account(name: "Demo Study", emailHint: "study@example.test", color: theme.isPlayfulRetro ? .rose : .violet, launchMode: .desktop)]
            try ProfileRepository(root: data).save(AccountSnapshot(accounts: accounts))
            let model = AppModel(root: data, preferences: AppPreferences(language: L10n.language, theme: theme), monitoring: false)
            NSApp.appearance = theme.nsAppearance
            try renderView(Dashboard(model: model), size: NSSize(width: 1120, height: theme.isPlayfulRetro ? 960 : 850), to: output.appendingPathComponent("\(theme.rawValue)-\(L10n.language.rawValue).png"))
            try renderView(PreferencesView(model: model), size: NSSize(width: 580, height: 720), to: output.appendingPathComponent("settings-\(theme.rawValue)-\(L10n.language.rawValue).png"))
            try renderView(AccountEditorView(model: model, editor: AccountEditor(account: nil)),
                           size: NSSize(width: 520, height: 760),
                           to: output.appendingPathComponent("add-account-\(theme.rawValue)-\(L10n.language.rawValue).png"))
            try renderView(AccountEditorView(model: model, editor: AccountEditor(account: accounts[0])),
                           size: NSSize(width: 520, height: 760),
                           to: output.appendingPathComponent("edit-account-\(theme.rawValue)-\(L10n.language.rawValue).png"))
            let overviewData = data.appendingPathComponent("overview")
            var overviewAccounts = accounts
            overviewAccounts[0].defaultAction = .connectSession
            overviewAccounts[0].connectOnStartup = true
            overviewAccounts[1].desktopCodexConnection = connection
            overviewAccounts.append(Account(name: "Demo Archive", color: .gold, launchMode: .desktop,
                desktopCodexConnection: CodexConnection(identity: connection.identity,
                    quota: CodexQuotaSnapshot(limits: limits, fetchedAt: Date().addingTimeInterval(-1_800)))))
            try ProfileRepository(root: overviewData).save(AccountSnapshot(accounts: overviewAccounts))
            let overview = AppModel(root: overviewData, preferences: AppPreferences(language: L10n.language, theme: theme,
                quotaOnlyMode: true, workspaceLayout: .quotaTable), monitoring: false,
                desktopQuotaSource: PreviewQuotaSource(background: accounts[0].id, window: accounts[1].id))
            try renderView(Dashboard(model: overview), size: NSSize(width: 1120, height: 800),
                           to: output.appendingPathComponent("overview-\(theme.rawValue)-\(L10n.language.rawValue).png"))
            overview.refreshDiagnostics()
            try renderView(SessionDiagnosticsView(model: overview).appAppearance(overview.preferences),
                           size: NSSize(width: 680, height: 660),
                           to: output.appendingPathComponent("diagnostics-\(theme.rawValue)-\(L10n.language.rawValue).png"))
            try renderView(QuotaNotificationSettingsView(model: overview).padding(24).appAppearance(overview.preferences),
                           size: NSSize(width: 580, height: 360),
                           to: output.appendingPathComponent("notifications-\(theme.rawValue)-\(L10n.language.rawValue).png"))
            if theme == .light || theme.isPlayfulRetro {
                let agentData = data.appendingPathComponent("agents")
                let agentAccounts = [accounts[0],
                    Account(name: "Claude Work", emailHint: "work@example.test", color: .peach, isFavorite: true, agent: .claude),
                    Account(name: "Claude Personal", emailHint: "personal@example.test", color: .rose, agent: .claude),
                    Account(name: "Gemini Study", color: .blue, agent: .gemini),
                    Account(name: "Antigravity", color: .violet, agent: .antigravity),
                    Account(name: "Perplexity Research", color: .mint, agent: .perplexity),
                    Account(name: "DeepSeek Work", color: .gold, agent: .deepseek)]
                try ProfileRepository(root: agentData).save(.init(accounts: agentAccounts))
                let agents = AppModel(root: agentData, preferences: .init(language: L10n.language, theme: theme), monitoring: false)
                try renderView(Dashboard(model: agents), size: NSSize(width: 1120, height: 1000),
                               to: output.appendingPathComponent("agents-\(theme.rawValue)-\(L10n.language.rawValue).png"))
                let claude = AppModel(root: agentData, preferences: .init(language: L10n.language, theme: theme, agentFilter: .claude), monitoring: false)
                try renderView(Dashboard(model: claude), size: NSSize(width: 900, height: 760),
                               to: output.appendingPathComponent("agent-filter-\(theme.rawValue)-\(L10n.language.rawValue).png"))
                try renderView(AccountEditorView(model: claude, editor: AccountEditor(account: nil, defaultAgent: .claude)),
                               size: NSSize(width: 520, height: 760),
                               to: output.appendingPathComponent("add-agent-\(theme.rawValue)-\(L10n.language.rawValue).png"))
                try renderView(Dashboard(model: overview), size: NSSize(width: 900, height: 640),
                               to: output.appendingPathComponent("overview-compact-\(theme.rawValue)-\(L10n.language.rawValue).png"))
                try renderView(AccountEditorView(model: overview, editor: AccountEditor(account: overviewAccounts[0])),
                               size: NSSize(width: 520, height: 760),
                               to: output.appendingPathComponent("session-settings-\(theme.rawValue)-\(L10n.language.rawValue).png"))
            }
            if theme.isPlayfulRetro {
                try renderView(Dashboard(model: model), size: NSSize(width: 900, height: 640),
                               to: output.appendingPathComponent("compact-\(theme.rawValue)-\(L10n.language.rawValue).png"))
                try renderView(GuideView().appAppearance(model.preferences), size: NSSize(width: 530, height: 850),
                               to: output.appendingPathComponent("guide-\(theme.rawValue)-\(L10n.language.rawValue).png"))
                try renderView(QuotaDetailView(model: model, accountID: accounts[0].id).appAppearance(model.preferences),
                               size: NSSize(width: 530, height: 600),
                               to: output.appendingPathComponent("quota-\(theme.rawValue)-\(L10n.language.rawValue).png"))
                let emptyModel = AppModel(root: data.appendingPathComponent("empty"), preferences: model.preferences, monitoring: false)
                try renderView(Dashboard(model: emptyModel), size: NSSize(width: 900, height: 800),
                               to: output.appendingPathComponent("empty-\(theme.rawValue)-\(L10n.language.rawValue).png"))
            }
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

@MainActor
private struct PreviewQuotaSource: DesktopQuotaSource {
    let background: UUID
    let window: UUID
    func hasBackend(_ id: UUID) -> Bool { id == background || id == window }
    func hasDesktopWindow(_ account: Account) -> Bool { account.id == window }
    func installationVersion() throws -> String { "Preview" }
    func connectSession(_ account: Account) async throws { throw DesktopProfileError.backendFailed }
    func quotaClient(_ id: UUID) throws -> CodexRPCClient { throw DesktopProfileError.backendFailed }
}

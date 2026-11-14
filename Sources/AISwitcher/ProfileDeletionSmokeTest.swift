import AppKit
import WebKit
import AISwitcherCore

/// A fresh app process exercises the cold-WebKit path from the crash report.
/// All profiles and cookies are disposable; no account is signed in.
@MainActor
enum ProfileDeletionSmokeTest {
    static func run(root: URL) async throws {
        guard CommandLine.arguments.contains("--data-dir"), root.lastPathComponent.hasPrefix("ai-switcher-smoke."),
              !FileManager.default.fileExists(atPath: root.appendingPathComponent("accounts.json").path) else { throw ProfileError.invalidSelection }
        let suite = "ai-switcher.delete-smoke." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let repo = ProfileRepository(root: root)
        let store = AppPreferencesStore(defaults: defaults)
        func require(_ condition: @autoclosure () -> Bool) throws {
            guard condition() else { throw ProfileError.invalidSelection }
        }
        let a = Account(name: "Cold Claude", agent: .claude).withDesktopSignIn(.desktop)
        let b = Account(name: "Other Claude", agent: .claude).withDesktopSignIn(.cli)
        for account in [a, b] {
            try repo.prepareClaudeProfile(for: account.id)
            try Data(account.name.utf8).write(to: repo.claudeUserDataURL(for: account.id).appendingPathComponent("preserved.fixture"))
        }
        try repo.save(.init(accounts: [a, b]))
        let model = AppModel(root: root, monitoring: false, preferencesStore: store)
        // Nothing has created a WKWebView or WKWebsiteDataStore before this call.
        model.delete(a)
        await model.shutdownQuota()
        try require(model.accounts.map(\.id) == [b.id])
        try require(!FileManager.default.fileExists(atPath: repo.claudeProfileURL(for: a.id).path))
        try require(FileManager.default.fileExists(atPath: repo.claudeUserDataURL(for: b.id).appendingPathComponent("preserved.fixture").path))
        print("PASS: deleting a Desktop-only Claude profile in a cold WebKit process survives and preserves the other profile")

        if #available(macOS 14.0, *) {
            let first = WKWebsiteDataStore(forIdentifier: ClaudeWebAccountService.storeIdentifier(root: root, accountID: a.id))
            let second = WKWebsiteDataStore(forIdentifier: ClaudeWebAccountService.storeIdentifier(root: root, accountID: b.id))
            let cookieA = HTTPCookie(properties: [.domain: "claude.ai", .path: "/", .name: "delete-fixture", .value: "A", .secure: "TRUE"])!
            let cookieB = HTTPCookie(properties: [.domain: "claude.ai", .path: "/", .name: "delete-fixture", .value: "B", .secure: "TRUE"])!
            await first.httpCookieStore.setCookie(cookieA); await second.httpCookieStore.setCookie(cookieB)
            let service = ClaudeWebAccountService(repository: repo)
            await service.remove(a)
            let removed = await first.httpCookieStore.allCookies()
            let retained = await second.httpCookieStore.allCookies()
            try require(!removed.contains { $0.name == "delete-fixture" })
            try require(retained.contains { $0.name == "delete-fixture" && $0.value == "B" })
            await service.remove(b)
            let remaining = await second.httpCookieStore.allCookies()
            try require(!remaining.contains { $0.name == "delete-fixture" })
            print("PASS: legacy WebKit cleanup clears only the selected profile's cookies and survives repeated cleanup")
        }
        let reopened = AppModel(root: root, monitoring: false, preferencesStore: store)
        reopened.delete(b)
        await reopened.shutdownQuota()
        let saved = try repo.load()
        try require(saved.accounts.isEmpty)
        print("PASS: deleting after manager reload completes without an app crash")
    }
}

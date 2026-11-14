import XCTest
@testable import AISwitcher
import AISwitcherCore

@MainActor
final class DesktopSignInTests: XCTestCase {
    func testBrowserAuthorizationWritesOnlySelectedDesktopHome() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("desktop-signin-\(UUID())")
        let backends = URL(fileURLWithPath: "/tmp/dsi-" + UUID().uuidString.prefix(12))
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: backends) }
        let repository = ProfileRepository(root: root, desktopBackendBase: backends)
        let fixture = Bundle.module.url(forResource: "codex_app_server", withExtension: "py", subdirectory: "Fixtures")!
        var opened: [URL] = []
        let service = DesktopSignInService(repository: repository, desktop: DesktopService(repository: repository), browsers: BrowserService(repository: repository), clientFactory: { home in
            CodexRPCClient(executable: URL(fileURLWithPath: "/usr/bin/python3"), home: home, arguments: ["-u", fixture.path])
        }, openLogin: { opened.append($0) })
        let a = Account(name: "A").withDesktopSignIn(.browser)
        let b = Account(name: "B").withDesktopSignIn(.browser)
        let first = try await service.signInChatGPT(a), second = try await service.signInChatGPT(b)
        XCTAssertNotEqual(first.identity.email, second.identity.email)
        XCTAssertEqual(opened.count, 2)
        XCTAssertTrue(opened.allSatisfy { $0.host == "auth.openai.com" && $0.query == "fixture=true" })
        for account in [a, b] {
            let home = repository.desktopHomeURL(for: account.id)
            XCTAssertEqual(account.usesCodexDesktop, true)
            XCTAssertEqual(try String(contentsOf: home.appendingPathComponent("methods.txt")), "initialize\ninitialized\naccount/login/start\naccount/read\naccount/rateLimits/read\n")
            XCTAssertFalse(FileManager.default.fileExists(atPath: repository.codexHomeURL(for: account.id).path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: repository.profileURL(for: account.id).path))
        }
    }

    func testBrowserLaunchFailureCancelsLoginAndPreservesDesktopFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("desktop-signin-\(UUID())")
        let backends = URL(fileURLWithPath: "/tmp/dsi-" + UUID().uuidString.prefix(12))
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: backends) }
        let repo = ProfileRepository(root: root, desktopBackendBase: backends)
        let a = Account(name: "A").withDesktopSignIn(.browser)
        try repo.prepareDesktopProfile(for: a.id)
        let saved = repo.desktopHomeURL(for: a.id).appendingPathComponent("preserved.fixture")
        try Data("preserve".utf8).write(to: saved)
        let fixture = Bundle.module.url(forResource: "codex_app_server", withExtension: "py", subdirectory: "Fixtures")!
        let service = DesktopSignInService(repository: repo, desktop: DesktopService(repository: repo), browsers: BrowserService(repository: repo), clientFactory: { home in
            CodexRPCClient(executable: URL(fileURLWithPath: "/usr/bin/python3"), home: home, arguments: ["-u", fixture.path])
        }, openLogin: { _ in throw CancellationError() })
        do { _ = try await service.signInChatGPT(a); XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try String(contentsOf: saved), "preserve")
        XCTAssertTrue(try String(contentsOf: repo.desktopHomeURL(for: a.id).appendingPathComponent("methods.txt")).contains("account/login/cancel"))
    }

    func testLegacyWebMigrationPreservesSeparateIdentitiesAndRequiresDesktopSignIn() throws {
        let web = CodexConnection(identity: .init(email: "web@example.test", planType: "plus"))
        let native = CodexConnection(identity: .init(email: "desktop@example.test", planType: "free"))
        for agent in [AIAgent.chatgpt, .claude] {
            let old = Account(name: "Existing", codexConnection: web, launchMode: .browser, desktopCodexConnection: native, agent: agent)
            let decoded = try JSONDecoder().decode(Account.self, from: JSONEncoder().encode(old))
            XCTAssertEqual(decoded.effectiveLaunchMode, .browser)
            let migrated = decoded.withDesktopSignIn()
            XCTAssertEqual(migrated.id, old.id)
            XCTAssertEqual(migrated.effectiveSignInMethod, .browser)
            XCTAssertEqual(migrated.effectiveLaunchMode, .desktop)
            XCTAssertEqual(migrated.desktopSignInPending, true)
            XCTAssertEqual(migrated.codexConnection, web)
            XCTAssertEqual(migrated.desktopCodexConnection, native)
            for method in AccountSignInMethod.allCases {
                let selected = migrated.withDesktopSignIn(method)
                let saved = try JSONDecoder().decode(Account.self, from: JSONEncoder().encode(selected))
                XCTAssertEqual(saved.effectiveLaunchMode, .desktop)
                XCTAssertEqual(saved.effectiveSignInMethod, method)
            }
        }
        let gemini = Account(name: "Gemini", agent: .gemini)
        XCTAssertEqual(gemini.withDesktopSignIn(.cli), gemini)
    }
}

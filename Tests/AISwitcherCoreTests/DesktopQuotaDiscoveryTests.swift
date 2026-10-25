import XCTest
@testable import AISwitcher
import AISwitcherCore

@MainActor
final class DesktopQuotaDiscoveryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Desktop Quota \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func setup(_ mode: String, launchMode: LaunchMode = .desktop) throws -> (AppModel, Account, FixtureDesktopQuotaSource) {
        let account = Account(name: "Fixture", launchMode: launchMode)
        let data = root.appendingPathComponent("metadata")
        try ProfileRepository(root: data).save(AccountSnapshot(accounts: [account]))
        let home = root.appendingPathComponent(mode)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let source = FixtureDesktopQuotaSource(home: home)
        return (AppModel(root: data, monitoring: false, desktopQuotaSource: source), account, source)
    }

    private func waitForQuota(_ model: AppModel, account: Account) async throws {
        let deadline = Date().addingTimeInterval(5)
        while model.quotaBusyIDs.contains(account.id), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(model.quotaBusyIDs.contains(account.id), "Quota operation should finish")
    }

    func testDesktopLoginIsDiscoveredAutomaticallyWithoutAnotherOAuthFlow() async throws {
        let (model, account, source) = try setup("desktop-login")
        model.refreshDesktopQuotaIfNeeded()
        model.refreshDesktopQuotaIfNeeded()
        try await waitForQuota(model, account: account)
        XCTAssertEqual(source.reads, 1, "Lifecycle ticks must not overlap quota operations")
        XCTAssertEqual(model.quotaErrors[account.id] as? CodexQuotaError, .notSignedIn)
        XCTAssertNil(model.accounts.first?.desktopCodexConnection)
        XCTAssertNil(model.connectingID)

        // The Desktop app completes its own sign-in after the initial read.
        try Data().write(to: source.home.appendingPathComponent("signed-in"))
        model.refreshDesktopQuotaIfNeeded(now: Date().addingTimeInterval(4))
        try await waitForQuota(model, account: account)
        let connection = try XCTUnwrap(model.accounts.first?.desktopCodexConnection)
        XCTAssertEqual(connection.identity.email, "desktop-login@example.test")
        XCTAssertEqual(connection.quota?.limits.buckets.first?.value.primary?.remainingPercent, 77)
        XCTAssertNil(model.quotaErrors[account.id])
        XCTAssertNil(model.accounts.first?.codexConnection)
        XCTAssertTrue(model.pendingConnections.isEmpty)
        XCTAssertEqual(source.reads, 2)

        model.refreshDesktopQuotaIfNeeded(now: Date().addingTimeInterval(10))
        XCTAssertFalse(model.quotaBusyIDs.contains(account.id))
        XCTAssertEqual(source.reads, 2, "Once quota is available, use the regular five-minute refresh")
        let methods = try String(contentsOf: source.home.appendingPathComponent("methods.txt")).split(separator: "\n").map(String.init)
        XCTAssertEqual(methods, ["initialize", "initialized", "account/read",
                                 "initialize", "initialized", "account/read", "account/rateLimits/read", "account/read"])
        await model.shutdownQuota()
    }

    func testQuotaFailureBacksOffAndDoesNotAskForAnotherLogin() async throws {
        let (model, account, source) = try setup("error")
        source.persistedSessionEnabled = true
        model.refreshDesktopQuotaIfNeeded()
        try await waitForQuota(model, account: account)
        XCTAssertEqual(model.quotaErrors[account.id] as? CodexQuotaError, .rpc(-32001))
        XCTAssertEqual(model.quotaErrorDescription(for: account), L10n.text("Could not read quota from this Desktop session. AI Switcher will retry automatically."))

        model.refreshDesktopQuotaIfNeeded(now: Date().addingTimeInterval(4))
        XCTAssertFalse(model.quotaBusyIDs.contains(account.id))
        XCTAssertEqual(source.reads, 1)
        model.refreshQuota(account)
        try await waitForQuota(model, account: account)
        XCTAssertEqual(source.reads, 2, "A manual refresh bypasses automatic retry backoff")
        model.refreshDesktopQuotaIfNeeded(now: Date().addingTimeInterval(31))
        try await waitForQuota(model, account: account)
        XCTAssertEqual(source.reads, 3)
        XCTAssertEqual(source.persistedReads, 0, "Quota errors must not select a different authentication source")
        await model.shutdownQuota()
    }

    func testPersistedDesktopLoginIsReadWhenDaemonStillReportsSignedOut() async throws {
        let (model, account, source) = try setup("desktop-login")
        source.daemonSignedOut = true
        source.persistedSessionEnabled = true
        try Data().write(to: source.home.appendingPathComponent("signed-in"))
        model.refreshDesktopQuotaIfNeeded()
        try await waitForQuota(model, account: account)

        let connection = try XCTUnwrap(model.accounts.first?.desktopCodexConnection)
        XCTAssertEqual(connection.identity.email, "desktop-login@example.test")
        XCTAssertEqual(connection.identity.accountId, "desktop-login")
        XCTAssertEqual(connection.quota?.limits.buckets.first?.value.primary?.remainingPercent, 77)
        XCTAssertNil(model.quotaErrors[account.id])
        XCTAssertNil(model.accounts.first?.codexConnection)
        XCTAssertNil(model.connectingID)
        XCTAssertTrue(model.pendingConnections.isEmpty)
        XCTAssertEqual(source.reads, 1)
        XCTAssertEqual(source.persistedReads, 1)
        let methods = try String(contentsOf: source.home.appendingPathComponent("methods.txt")).split(separator: "\n").map(String.init)
        XCTAssertEqual(methods, ["initialize", "initialized", "account/read",
                                 "initialize", "initialized", "account/read", "account/rateLimits/read", "account/read"])
        await model.shutdownQuota()
    }

    func testMissingPersistedSessionStillWaitsWithoutStartingLogin() async throws {
        let (model, account, source) = try setup("unauthed")
        source.persistedSessionEnabled = true
        model.refreshDesktopQuotaIfNeeded()
        try await waitForQuota(model, account: account)
        XCTAssertEqual(model.quotaErrors[account.id] as? CodexQuotaError, .notSignedIn)
        XCTAssertNil(model.accounts.first?.desktopCodexConnection)
        XCTAssertNil(model.connectingID)
        XCTAssertEqual(source.persistedReads, 1)
        let methods = try String(contentsOf: source.home.appendingPathComponent("methods.txt")).split(separator: "\n").map(String.init)
        XCTAssertEqual(methods, ["initialize", "initialized", "account/read", "initialize", "initialized", "account/read"])
        await model.shutdownQuota()
    }

    func testDiscoverySkipsStoppedBackendsAndBrowserProfiles() async throws {
        let (desktop, account, source) = try setup("stopped")
        source.running = false
        desktop.refreshDesktopQuotaIfNeeded()
        XCTAssertFalse(desktop.quotaBusyIDs.contains(account.id))
        XCTAssertEqual(source.reads, 0)
        await desktop.shutdownQuota()

        let (browser, _, browserSource) = try setup("browser", launchMode: .browser)
        browser.refreshDesktopQuotaIfNeeded()
        XCTAssertEqual(browserSource.reads, 0)
        await browser.shutdownQuota()
    }
}

@MainActor
private final class FixtureDesktopQuotaSource: DesktopQuotaSource {
    let home: URL
    var running = true
    var daemonSignedOut = false
    var persistedSessionEnabled = false
    private(set) var reads = 0
    private(set) var persistedReads = 0

    init(home: URL) { self.home = home }

    func hasBackend(_ id: UUID) -> Bool { running }

    func quotaClient(_ id: UUID) throws -> CodexRPCClient {
        reads += 1
        return makeClient(signedOut: daemonSignedOut)
    }

    func persistedSessionQuotaClient(_ id: UUID) throws -> CodexRPCClient? {
        guard persistedSessionEnabled else { return nil }
        persistedReads += 1
        return makeClient(signedOut: false)
    }

    private func makeClient(signedOut: Bool) -> CodexRPCClient {
        let fixture = Bundle.module.url(forResource: "codex_app_server", withExtension: "py", subdirectory: "Fixtures")!
        return CodexRPCClient(executable: URL(fileURLWithPath: "/usr/bin/python3"), home: home,
                              arguments: ["-u", fixture.path] + (signedOut ? ["--signed-out"] : []), timeout: 2)
    }
}

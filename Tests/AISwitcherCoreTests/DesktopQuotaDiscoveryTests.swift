import XCTest
@testable import AISwitcher
import AISwitcherCore

@MainActor
final class DesktopQuotaDiscoveryTests: XCTestCase {
    private var root: URL!
    private var defaultsSuite: String!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Desktop Quota \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defaultsSuite = "ai-switcher-session-tests.\(UUID())"
    }

    override func tearDownWithError() throws {
        UserDefaults(suiteName: defaultsSuite)?.removePersistentDomain(forName: defaultsSuite)
        try FileManager.default.removeItem(at: root)
    }

    private func setup(_ mode: String, launchMode: LaunchMode = .desktop, notifications: (any QuotaNotificationSending)? = nil) throws -> (AppModel, Account, FixtureDesktopQuotaSource) {
        let account = Account(name: "Fixture", launchMode: launchMode)
        let data = root.appendingPathComponent("metadata")
        try ProfileRepository(root: data).save(AccountSnapshot(accounts: [account]))
        let home = root.appendingPathComponent(mode)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let source = FixtureDesktopQuotaSource(home: home)
        return (AppModel(root: data, monitoring: false, desktopQuotaSource: source,
                         preferencesStore: AppPreferencesStore(defaults: UserDefaults(suiteName: defaultsSuite)!), notifications: notifications), account, source)
    }

    func testQuotaNotificationsRequestPermissionAndDeliverOnlyFreshTransitions() async throws {
        let notifications = FixtureNotifications()
        let (model, account, source) = try setup("quota-alerts", notifications: notifications)
        model.setQuotaAlertThreshold(80)
        await model.setQuotaNotifications(true)
        XCTAssertEqual(notifications.requests, 1)
        XCTAssertTrue(model.preferences.quotaAlerts.enabled)
        model.refreshQuota(account)
        try await waitForQuota(model, account: account)
        XCTAssertEqual(notifications.events.map(\.kind), [.low])
        model.refreshQuota(account)
        try await waitForQuota(model, account: account)
        XCTAssertEqual(notifications.events.count, 1, "Repeated low readings must not spam")
        try Data("5".utf8).write(to: source.home.appendingPathComponent("used-percent"))
        model.refreshQuota(account)
        try await waitForQuota(model, account: account)
        XCTAssertEqual(notifications.events.map(\.kind), [.low, .recovered])
        await model.setQuotaNotifications(false)
        XCTAssertEqual(notifications.clears, 1)
        try Data("99".utf8).write(to: source.home.appendingPathComponent("used-percent"))
        model.refreshQuota(account)
        try await waitForQuota(model, account: account)
        XCTAssertEqual(notifications.events.count, 2)
        await model.shutdownQuota()
    }

    func testDeniedNotificationsDoNotEnableOrSend() async throws {
        let notifications = FixtureNotifications()
        notifications.value = .denied
        let (model, account, _) = try setup("alerts-denied", notifications: notifications)
        await model.setQuotaNotifications(true)
        XCTAssertFalse(model.preferences.quotaAlerts.enabled)
        XCTAssertEqual(model.notificationPermission, .denied)
        XCTAssertEqual(notifications.requests, 0)
        model.refreshQuota(account)
        try await waitForQuota(model, account: account)
        XCTAssertTrue(notifications.events.isEmpty)
        await model.shutdownQuota()
    }

    func testRestartOnlyStopsAndConnectsSelectedAccountWithoutChangingRecents() async throws {
        let (model, account, source) = try setup("restart-session")
        let other = Account(name: "Other", launchMode: .desktop)
        XCTAssertTrue(model.saveAccount(other))
        model.restartSession(account)
        model.restartSession(account)
        try await waitForQuota(model, account: account)
        XCTAssertEqual(source.closedIDs, [account.id])
        XCTAssertEqual(source.connectedIDs, [account.id])
        XCTAssertEqual(source.reads, 1)
        XCTAssertNotNil(model.accounts.first(where: { $0.id == account.id })?.desktopCodexConnection?.quota)
        XCTAssertNil(model.snapshot.lastOpenedID)
        XCTAssertTrue(model.closingSessionIDs.isEmpty)
        XCTAssertTrue(model.connectingSessionIDs.isEmpty)
        XCTAssertEqual(model.sessionStatus(for: account), .background)
        await model.shutdownQuota()
    }

    func testRestartRefusalKeepsDataAndDoesNotStartAnotherBackend() async throws {
        let (model, account, source) = try setup("restart-refused")
        source.closeError = DesktopProfileError.profileRunning
        let before = model.snapshot
        model.restartSession(account)
        try await waitForQuota(model, account: account)
        XCTAssertEqual(source.closedIDs, [account.id])
        XCTAssertTrue(source.connectedIDs.isEmpty)
        XCTAssertEqual(model.snapshot, before)
        XCTAssertNotNil(model.quotaErrors[account.id])
        await model.shutdownQuota()
    }

    func testDiagnosticsAreReadOnlyAndReportCompatibility() async throws {
        let (model, _, source) = try setup("diagnostics")
        let before = model.snapshot
        model.refreshDiagnostics()
        XCTAssertEqual(model.desktopCompatibility, .available("fixture"))
        XCTAssertEqual(source.reads, 0)
        XCTAssertEqual(source.connects, 0)
        XCTAssertEqual(model.snapshot, before)
        source.compatibilityError = DesktopProfileError.unsupportedApp
        model.refreshDiagnostics()
        guard case .unavailable? = model.desktopCompatibility else { return XCTFail("Should report incompatible Desktop") }
        XCTAssertEqual(model.snapshot, before)
        await model.shutdownQuota()
    }

    func testMenuBarHasQuotaAndTargetedQuickActions() async throws {
        let (model, account, _) = try setup("quick-menu")
        model.refreshQuota(account)
        try await waitForQuota(model, account: account)
        let menu = AccountQuickMenu.make(account: model.accounts[0], model: model, target: AppDelegate())
        let selectors = menu.items.compactMap { $0.action.map(NSStringFromSelector) }
        XCTAssertTrue(selectors.contains("openDesktopAccount:"))
        XCTAssertTrue(selectors.contains("connectAccount:"))
        XCTAssertTrue(selectors.contains("closeAccount:"))
        XCTAssertTrue(selectors.contains("showAccountQuota:"))
        XCTAssertTrue(menu.items.contains { $0.title.contains("77") && $0.action == nil })
        for item in menu.items where item.action != nil { XCTAssertEqual(item.representedObject as? UUID, account.id) }
        await model.shutdownQuota()
    }

    func testQuotaOnlyModeChangesDefaultActionWithoutOpeningDesktopAndPersistsView() async throws {
        let (model, account, source) = try setup("quota-only")
        source.running = false
        XCTAssertEqual(model.defaultAction(for: account), .openDesktop)
        model.setQuotaOnlyMode(true)
        XCTAssertEqual(model.preferences.workspaceLayout, .quotaTable)
        XCTAssertEqual(model.defaultAction(for: account), .connectSession)
        model.performDefaultAction(account)
        try await waitForQuota(model, account: account)
        XCTAssertEqual(source.connects, 1)
        XCTAssertNil(model.snapshot.lastOpenedID)
        let stored = AppPreferencesStore(defaults: UserDefaults(suiteName: defaultsSuite)!).load()
        XCTAssertTrue(stored.quotaOnlyMode)
        XCTAssertEqual(stored.workspaceLayout, .quotaTable)
        model.setQuotaOnlyMode(false)
        XCTAssertEqual(model.preferences.workspaceLayout, .cards)
        XCTAssertEqual(AppPreferencesStore(defaults: UserDefaults(suiteName: defaultsSuite)!).load().workspaceLayout, .cards)
        XCTAssertEqual(model.defaultAction(for: account), .openDesktop)
        var edited = model.accounts[0]
        edited.defaultAction = .connectSession
        XCTAssertTrue(model.saveAccount(edited))
        XCTAssertEqual(model.defaultAction(for: model.accounts[0]), .connectSession)
        let browser = Account(name: "Browser", launchMode: .browser, defaultAction: .connectSession)
        model.setQuotaOnlyMode(true)
        XCTAssertEqual(model.defaultAction(for: browser), .openDesktop)
        await model.shutdownQuota()
    }

    func testQuotaOnlyRestoresEitherPreviousLayoutAcrossRelaunchAndRepeatedToggles() async throws {
        let store = AppPreferencesStore(defaults: UserDefaults(suiteName: defaultsSuite)!)
        for layout in WorkspaceLayout.allCases {
            let (model, _, source) = try setup("restore-\(layout.rawValue)")
            model.setWorkspaceLayout(layout)
            model.setAgentFilter(.claude)
            model.setQuotaOnlyMode(true)
            model.setQuotaOnlyMode(true)
            XCTAssertEqual(model.preferences.workspaceLayout, .quotaTable)
            XCTAssertEqual(model.preferences.workspaceLayoutBeforeQuotaOnly, layout)
            // Other preference edits and an active-mode layout choice must not
            // replace the view that existed before quota-only mode was enabled.
            model.setLanguage(.english)
            model.setTheme(.playfulRetro)
            model.setQuotaSort(.nextReset)
            model.setWorkspaceLayout(.cards)
            let reopened = AppModel(root: model.repository.root, monitoring: false,
                desktopQuotaSource: source, preferencesStore: store)
            XCTAssertTrue(reopened.preferences.quotaOnlyMode)
            XCTAssertEqual(reopened.preferences.workspaceLayoutBeforeQuotaOnly, layout)
            reopened.setQuotaOnlyMode(false)
            reopened.setQuotaOnlyMode(false)
            XCTAssertEqual(reopened.preferences.workspaceLayout, layout)
            XCTAssertEqual(store.load().workspaceLayout, layout)
            XCTAssertNil(store.load().workspaceLayoutBeforeQuotaOnly)
            XCTAssertEqual(reopened.preferences.language, .english)
            XCTAssertEqual(reopened.preferences.theme, .playfulRetro)
            XCTAssertEqual(reopened.preferences.agentFilter, .claude)
            XCTAssertEqual(reopened.preferences.quotaSortKey, .nextReset)
            // A second cycle must capture the restored view again.
            reopened.setQuotaOnlyMode(true)
            reopened.setQuotaOnlyMode(false)
            XCTAssertEqual(reopened.preferences.workspaceLayout, layout)
            await model.shutdownQuota()
            await reopened.shutdownQuota()
        }
    }

    func testLegacyQuotaOnlyModeReturnsToCardsWithoutAStoredPreviousLayout() async throws {
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        defaults.set(true, forKey: "ui.quotaOnlyMode")
        defaults.set(WorkspaceLayout.quotaTable.rawValue, forKey: "ui.workspaceLayout")
        let (model, _, _) = try setup("legacy-quota-layout")
        XCTAssertNil(model.preferences.workspaceLayoutBeforeQuotaOnly)
        model.setQuotaOnlyMode(true)
        model.setQuotaOnlyMode(false)
        XCTAssertEqual(model.preferences.workspaceLayout, .cards)
        XCTAssertFalse(AppPreferencesStore(defaults: defaults).load().quotaOnlyMode)
        XCTAssertNil(defaults.object(forKey: "ui.workspaceLayoutBeforeQuotaOnly"))
        await model.shutdownQuota()
    }

    func testStartupOnlyConnectsOptedInDesktopProfilesOnceAndKeepsRecents() async throws {
        let (model, original, source) = try setup("startup-selected")
        source.running = false
        var selected = original
        selected.connectOnStartup = true
        let unselected = Account(name: "Not selected", launchMode: .desktop)
        let browser = Account(name: "Browser", launchMode: .browser, connectOnStartup: true)
        XCTAssertTrue(model.saveAccount(selected))
        XCTAssertTrue(model.saveAccount(unselected))
        XCTAssertTrue(model.saveAccount(browser))
        await model.connectStartupAccounts()
        await model.connectStartupAccounts()
        XCTAssertEqual(source.connectedIDs, [selected.id])
        XCTAssertEqual(source.reads, 1)
        XCTAssertNil(model.snapshot.lastOpenedID)
        XCTAssertNil(model.accounts.first(where: { $0.id == unselected.id })?.desktopCodexConnection)
        XCTAssertNil(model.accounts.first(where: { $0.id == browser.id })?.codexConnection)
        await model.shutdownQuota()
    }

    func testStartupFailureIsVisibleInStatusWithoutAnAlertOrDesktopLaunch() async throws {
        let (model, account, source) = try setup("startup-error")
        source.running = false
        source.connectError = DesktopProfileError.backendFailed
        var edited = account
        edited.connectOnStartup = true
        XCTAssertTrue(model.saveAccount(edited))
        await model.connectStartupAccounts()
        XCTAssertEqual(model.sessionStatus(for: edited), .connectionFailed)
        XCTAssertNotNil(model.quotaErrors[account.id])
        XCTAssertNil(model.notice)
        XCTAssertNil(model.snapshot.lastOpenedID)
        await model.shutdownQuota()
    }

    func testSessionStatusSeparatesBackgroundWindowsDisconnectedAndSignedOut() async throws {
        let (model, account, source) = try setup("session-status")
        source.running = false
        model.refreshRunning()
        XCTAssertEqual(model.sessionStatus(for: account), .disconnected)
        source.running = true
        model.refreshRunning()
        XCTAssertEqual(model.sessionStatus(for: account), .background)
        source.windowOpen = true
        model.refreshRunning()
        XCTAssertEqual(model.sessionStatus(for: account), .desktopOpen)
        source.windowOpen = false
        source.daemonSignedOut = true
        model.refreshQuota(account)
        try await waitForQuota(model, account: account)
        XCTAssertEqual(model.sessionStatus(for: account), .needsSignIn)
        source.daemonSignedOut = false
        model.refreshQuota(account)
        try await waitForQuota(model, account: account)
        XCTAssertEqual(model.sessionStatus(for: account), .background)
        await model.shutdownQuota()
    }

    func testQuotaSortSelectionAndDirectionPersist() async throws {
        let (model, _, _) = try setup("sort-preferences")
        model.setQuotaSort(.nextReset)
        XCTAssertTrue(model.preferences.quotaSortAscending)
        model.setQuotaSort(.nextReset)
        XCTAssertFalse(model.preferences.quotaSortAscending)
        model.setQuotaSort(.lastUpdated)
        XCTAssertFalse(model.preferences.quotaSortAscending)
        model.setWorkspaceLayout(.quotaTable)
        let saved = AppPreferencesStore(defaults: UserDefaults(suiteName: defaultsSuite)!).load()
        XCTAssertEqual(saved.quotaSortKey, .lastUpdated)
        XCTAssertFalse(saved.quotaSortAscending)
        XCTAssertEqual(saved.workspaceLayout, .quotaTable)
        await model.shutdownQuota()
    }

    private func waitForQuota(_ model: AppModel, account: Account) async throws {
        let deadline = Date().addingTimeInterval(5)
        while (model.quotaBusyIDs.contains(account.id) || model.launchingIDs.contains(account.id)), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(model.quotaBusyIDs.contains(account.id), "Quota operation should finish")
        XCTAssertFalse(model.launchingIDs.contains(account.id), "Session connection should finish")
    }

    func testHeadlessConnectStartsStoppedSessionReadsQuotaAndPreservesRecents() async throws {
        let (model, account, source) = try setup("headless")
        source.running = false
        model.connectSession(account)
        model.connectSession(account)
        XCTAssertTrue(model.connectingSessionIDs.contains(account.id))
        try await waitForQuota(model, account: account)
        XCTAssertEqual(source.connects, 1, "Repeated clicks must not start overlapping sessions")
        XCTAssertEqual(source.reads, 1)
        XCTAssertTrue(model.runningIDs.contains(account.id))
        XCTAssertEqual(model.accounts.first?.desktopCodexConnection?.identity.email, "headless@example.test")
        XCTAssertNil(model.accounts.first?.lastOpenedAt, "Reading quota must not mark Desktop as opened")
        XCTAssertNil(model.snapshot.lastOpenedID)
        XCTAssertNil(model.connectingID)
        XCTAssertTrue(model.pendingConnections.isEmpty)
        XCTAssertNil(model.notice)
        XCTAssertTrue(model.connectingSessionIDs.isEmpty)
        let methods = try String(contentsOf: source.home.appendingPathComponent("methods.txt")).split(separator: "\n").map(String.init)
        XCTAssertEqual(methods, ["initialize", "initialized", "account/read", "account/rateLimits/read", "account/read"])
        await model.shutdownQuota()
    }

    func testManualRefreshConnectsStoppedSessionWithoutOpeningDesktop() async throws {
        let (model, account, source) = try setup("refresh-stopped")
        source.running = false
        model.refreshQuota(account)
        try await waitForQuota(model, account: account)
        XCTAssertEqual(source.connects, 1)
        XCTAssertEqual(source.reads, 1)
        XCTAssertNotNil(model.accounts.first?.desktopCodexConnection?.quota)
        XCTAssertNil(model.snapshot.lastOpenedID)
        await model.shutdownQuota()
    }

    func testHeadlessConnectFailureDoesNotReadQuotaOrOpenDesktop() async throws {
        let (model, account, source) = try setup("connect-failed")
        source.running = false
        source.connectError = DesktopProfileError.backendFailed
        model.connectSession(account)
        try await waitForQuota(model, account: account)
        XCTAssertEqual(source.connects, 1)
        XCTAssertEqual(source.reads, 0)
        XCTAssertFalse(model.runningIDs.contains(account.id))
        XCTAssertNotNil(model.quotaErrors[account.id])
        XCTAssertEqual(model.notice?.title, L10n.text("Could not connect account session"))
        XCTAssertNil(model.accounts.first?.desktopCodexConnection)
        XCTAssertNil(model.snapshot.lastOpenedID)
        await model.shutdownQuota()
    }

    func testHeadlessUnsignedSessionDoesNotLaunchOAuthOrDesktop() async throws {
        let (model, account, source) = try setup("unauthed")
        source.running = false
        model.connectQuota(account)
        try await waitForQuota(model, account: account)
        XCTAssertEqual(source.connects, 1)
        XCTAssertEqual(model.quotaErrors[account.id] as? CodexQuotaError, .notSignedIn)
        XCTAssertNil(model.accounts.first?.desktopCodexConnection)
        XCTAssertNil(model.connectingID)
        XCTAssertNil(model.snapshot.lastOpenedID)
        XCTAssertTrue(model.pendingConnections.isEmpty)
        XCTAssertNotNil(model.quotaErrorDescription(for: account))
        await model.shutdownQuota()
    }

    func testShutdownCancelsSessionConnectionBeforeReadingQuota() async throws {
        let (model, account, source) = try setup("cancel-connect")
        source.running = false
        source.connectDelay = 10_000_000_000
        model.connectSession(account)
        await Task.yield()
        await model.shutdownQuota()
        XCTAssertEqual(source.reads, 0)
        XCTAssertTrue(model.launchingIDs.isEmpty)
        XCTAssertTrue(model.connectingSessionIDs.isEmpty)
        XCTAssertNil(model.notice)
    }

    func testSessionConnectDoesNotStartBrowserProfiles() async throws {
        let (model, account, source) = try setup("browser-connect", launchMode: .browser)
        source.running = false
        model.connectSession(account)
        XCTAssertTrue(model.launchingIDs.isEmpty)
        XCTAssertEqual(source.connects, 0)
        XCTAssertEqual(source.reads, 0)
        await model.shutdownQuota()
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
    var connectError: Error?
    var closeError: Error?
    var compatibilityError: Error?
    private(set) var closedIDs: [UUID] = []
    var connectDelay: UInt64 = 0
    var windowOpen = false
    private(set) var connectedIDs: [UUID] = []
    private(set) var connects = 0
    private(set) var reads = 0
    private(set) var persistedReads = 0

    init(home: URL) { self.home = home }

    func connectSession(_ account: Account) async throws {
        connects += 1
        connectedIDs.append(account.id)
        if connectDelay > 0 { try await Task.sleep(nanoseconds: connectDelay) }
        if let connectError { throw connectError }
        running = true
    }

    func hasBackend(_ id: UUID) -> Bool { running }
    func hasDesktopWindow(_ account: Account) -> Bool { windowOpen }
    func installationVersion() throws -> String {
        if let compatibilityError { throw compatibilityError }
        return "fixture"
    }
    func closeSession(_ account: Account) async throws {
        closedIDs.append(account.id)
        if let closeError { throw closeError }
        running = false
        windowOpen = false
    }

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

@MainActor
private final class FixtureNotifications: QuotaNotificationSending {
    var value: QuotaNotificationPermission = .notRequested
    var requests = 0
    var clears = 0
    var events: [QuotaAlertEvent] = []
    func permission() async -> QuotaNotificationPermission { value }
    func requestPermission() async throws -> Bool { requests += 1; value = .allowed; return true }
    func send(_ events: [QuotaAlertEvent], accountName: String, sound: Bool) async throws { self.events += events }
    func clearPending() { clears += 1 }
}

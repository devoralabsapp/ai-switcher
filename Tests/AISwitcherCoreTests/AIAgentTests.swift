import XCTest
@testable import AISwitcher
import AISwitcherCore

@MainActor
final class AIAgentTests: XCTestCase {
    private var root: URL!
    private var suite: String!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-tests-\(UUID())")
        suite = "ai-switcher-agents.\(UUID())"
    }
    override func tearDownWithError() throws {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }
    private var store: AppPreferencesStore { .init(defaults: UserDefaults(suiteName: suite)!) }
    private func model(_ accounts: [Account], source: AgentFixtureSource? = nil) throws -> AppModel {
        try ProfileRepository(root: root).save(.init(accounts: accounts))
        return AppModel(root: root, monitoring: false, desktopQuotaSource: source ?? AgentFixtureSource(), preferencesStore: store)
    }

    func testOldProfilesRemainChatGPTWithUnchangedLaunchBehavior() throws {
        let old = Account(name: "Old", launchMode: .desktop)
        let decoded = try JSONDecoder().decode(Account.self, from: JSONEncoder().encode(old))
        XCTAssertNil(decoded.agent)
        XCTAssertEqual(decoded.effectiveAgent, .chatgpt)
        XCTAssertTrue(decoded.usesCodexDesktop)
        XCTAssertEqual(decoded.effectiveDefaultAction, .openDesktop)
        XCTAssertFalse(decoded.automaticallyConnects)
        for agent in AIAgent.allCases {
            let profile = Account(name: agent.name, agent: agent)
            XCTAssertEqual(try JSONDecoder().decode(Account.self, from: JSONEncoder().encode(profile)), profile)
        }
    }

    func testOtherAgentsCannotExposeOrUseCodexDataEvenWithForgedSettings() async throws {
        let source = AgentFixtureSource()
        let connection = CodexConnection(identity: .init(email: "old@example.test", planType: "plus"))
        let profiles = AIAgent.allCases.filter { $0 != .chatgpt }.map { agent in
            Account(name: agent.name, codexConnection: connection, launchMode: .desktop,
                desktopCodexConnection: connection, sharesLocalWorkspace: true,
                defaultAction: .connectSession, connectOnStartup: true, agent: agent)
        }
        let model = try model(profiles, source: source)
        model.setQuotaOnlyMode(true)
        for account in profiles {
            XCTAssertNil(account.displayedCodexConnection)
            XCTAssertFalse(account.usesCodexDesktop)
            XCTAssertFalse(account.usesSharedLocalWorkspace)
            XCTAssertFalse(account.automaticallyConnects)
            XCTAssertEqual(model.defaultAction(for: account), .openDesktop)
            model.connectSession(account)
            model.connectQuota(account)
            model.refreshQuota(account)
            model.restartSession(account)
        }
        await model.connectStartupAccounts()
        model.refreshAllQuotas()
        await Task.yield()
        XCTAssertEqual(source.connects, 0)
        XCTAssertEqual(source.reads, 0)
        XCTAssertEqual(source.closes, 0)
        XCTAssertTrue(model.launchingIDs.isEmpty)
        XCTAssertTrue(model.quotaBusyIDs.isEmpty)
        XCTAssertNil(model.connectingID)
        await model.shutdownQuota()
    }

    func testAgentFilterCombinesWithFavoritesSearchAndPersists() async throws {
        let chatgpt = Account(name: "Work", isFavorite: true)
        let claudeWork = Account(name: "Work Claude", isFavorite: true, agent: .claude)
        let claudePersonal = Account(name: "Personal", agent: .claude)
        let gemini = Account(name: "Work Gemini", isFavorite: true, agent: .gemini)
        let model = try model([chatgpt, claudeWork, claudePersonal, gemini])
        model.setAgentFilter(.claude)
        XCTAssertEqual(model.visibleAccounts.map(\.id), [claudeWork.id, claudePersonal.id])
        model.filter = .favorites
        model.search = "work"
        XCTAssertEqual(model.visibleAccounts.map(\.id), [claudeWork.id])
        XCTAssertEqual(model.agentCount(.claude), 2)
        XCTAssertEqual(model.agentCount(nil), 4)
        XCTAssertEqual(store.load().agentFilter, .claude)
        model.addAccount()
        XCTAssertEqual(model.editor?.defaultAgent, .claude)
        model.setAgentFilter(nil)
        XCTAssertEqual(Set(model.visibleAccounts.map(\.id)), [chatgpt.id,claudeWork.id,gemini.id])
        XCTAssertNil(store.load().agentFilter)
        await model.shutdownQuota()
    }

    func testSharedApplicationCannotBeClosedOrDuplicated() async throws {
        let profile = Account(name: "Antigravity", agent: .antigravity)
        let source = AgentFixtureSource()
        let model = try model([profile], source: source)
        model.closeSession(profile)
        model.restartSession(profile)
        XCTAssertFalse(model.hasRunningSession(profile), "The shared application is never owned by this entry")
        XCTAssertEqual(source.closes, 0)
        XCTAssertFalse(model.saveAccount(Account(name: "Another", agent: .antigravity)))
        XCTAssertEqual(model.accounts.count, 1)
        await model.shutdownQuota()
    }

    func testExistingAgentCannotChangeAndBrowserDestinationsAreSpecific() async throws {
        let profile = Account(name: "Existing")
        let model = try model([profile])
        var edited = profile
        edited.agent = .claude
        XCTAssertFalse(model.saveAccount(edited))
        XCTAssertEqual(model.accounts.first?.effectiveAgent, .chatgpt)
        let expected: [AIAgent: String] = [.chatgpt: "chatgpt.com", .claude: "claude.ai", .gemini: "gemini.google.com", .perplexity: "www.perplexity.ai", .deepseek: "chat.deepseek.com"]
        for (agent, host) in expected {
            XCTAssertEqual(agent.webURL.host, host)
            XCTAssertEqual(agent.webURL.scheme, "https")
            let args = BrowserLaunch.arguments(profileURL: root.appendingPathComponent(agent.rawValue), url: agent.webURL)
            XCTAssertTrue(args.contains("--app=\(agent.webURL.absoluteString)"))
            if agent != .chatgpt { XCTAssertFalse(args.contains(where: { $0.contains("chatgpt.com") })) }
        }
        await model.shutdownQuota()
    }

    func testUnsupportedAgentQuickMenuHasNoCodexOrCloseActionsEnabled() async throws {
        let claude = Account(name: "Claude", agent: .claude)
        let shared = Account(name: "Antigravity", agent: .antigravity)
        let model = try model([claude, shared])
        for profile in [claude,shared] {
            let menu = AccountQuickMenu.make(account: profile, model: model, target: AppDelegate())
            let selectors = menu.items.compactMap { $0.action.map(NSStringFromSelector) }
            XCTAssertFalse(selectors.contains("connectAccount:"))
            XCTAssertFalse(selectors.contains("refreshAccountQuota:"))
            XCTAssertFalse(selectors.contains("showAccountQuota:"))
        }
        await model.shutdownQuota()
    }
}

@MainActor
private final class AgentFixtureSource: DesktopQuotaSource {
    var connects = 0, reads = 0, closes = 0
    func hasBackend(_ id: UUID) -> Bool { false }
    func connectSession(_ account: Account) async throws { connects += 1 }
    func closeSession(_ account: Account) async throws { closes += 1 }
    func quotaClient(_ id: UUID) throws -> CodexRPCClient { reads += 1; throw DesktopProfileError.backendFailed }
}

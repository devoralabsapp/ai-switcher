import XCTest
@testable import AISwitcherCore

final class ClaudeProfileTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws { root = FileManager.default.temporaryDirectory.appendingPathComponent("Claude Profiles \(UUID())") }
    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }
    func testExistingBrowserProfilesKeepTheirModeAndDesktopNeverGetsCodexFeatures() throws {
        var account = Account(name: "Existing Claude", launchMode: .browser, agent: .claude)
        XCTAssertEqual(account.effectiveLaunchMode, .browser)
        account.launchMode = nil
        XCTAssertEqual(account.effectiveLaunchMode, .browser)
        account.launchMode = .desktop
        account.connectOnStartup = true
        account.defaultAction = .connectSession
        account.sharesLocalWorkspace = true
        XCTAssertTrue(account.usesClaudeDesktop)
        XCTAssertFalse(account.usesCodexDesktop)
        XCTAssertFalse(account.automaticallyConnects)
        XCTAssertFalse(account.usesSharedLocalWorkspace)
        XCTAssertEqual(account.effectiveDefaultAction, .openDesktop)
        XCTAssertNil(account.displayedCodexConnection)
        XCTAssertEqual(try JSONDecoder().decode(Account.self, from: JSONEncoder().encode(account)), account)
    }
    func testProfileStoragePersistsIndependentlyAndDeletionOnlyRemovesSelectedProfile() throws {
        let repository = ProfileRepository(root: root), a = UUID(), b = UUID()
        for id in [a,b] { try repository.prepareClaudeProfile(for: id) }
        let markerA = repository.claudeUserDataURL(for: a).appendingPathComponent("fixture")
        let markerB = repository.claudeUserDataURL(for: b).appendingPathComponent("fixture")
        try Data("A".utf8).write(to: markerA)
        try Data("B".utf8).write(to: markerB)
        try repository.prepareClaudeProfile(for: a)
        XCTAssertEqual(try Data(contentsOf: markerA), Data("A".utf8))
        _ = try repository.remove(a, from: .init())
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerA.path))
        XCTAssertEqual(try Data(contentsOf: markerB), Data("B".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.desktopHomeURL(for: a).path))
    }
    func testReplacedStorageAndForgedOwnershipCannotLaunchOrDelete() throws {
        let repository = ProfileRepository(root: root), id = UUID()
        try repository.prepareClaudeProfile(for: id)
        let home = repository.claudeProfileURL(for: id)
        let marker = home.appendingPathComponent("ai-switcher-profile.json")
        let original = try Data(contentsOf: marker)
        try Data("{}".utf8).write(to: marker)
        XCTAssertThrowsError(try repository.prepareClaudeProfile(for: id))
        XCTAssertThrowsError(try repository.remove(id, from: .init()))
        try original.write(to: marker)
        let userData = repository.claudeUserDataURL(for: id)
        try FileManager.default.removeItem(at: userData)
        let target = root.appendingPathComponent("unrelated")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: userData, withDestinationURL: target)
        XCTAssertThrowsError(try repository.prepareClaudeProfile(for: id))
        XCTAssertThrowsError(try repository.remove(id, from: .init()))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }
    func testRoutingMatchesExactProfileAndDoesNotInheritAuthenticationOverrides() {
        let userData = root.appendingPathComponent("A/UserData"), other = root.appendingPathComponent("B/UserData")
        let args = ClaudeLaunch.arguments(userData: userData)
        XCTAssertTrue(ClaudeLaunch.ownsProcess(arguments: args, userData: userData))
        XCTAssertFalse(ClaudeLaunch.ownsProcess(arguments: args, userData: other))
        XCTAssertFalse(ClaudeLaunch.ownsProcess(arguments: args + ["--type=renderer"], userData: userData))
        let config = root.appendingPathComponent("A/CodeConfig")
        let environment = ClaudeLaunch.environment(base: ["PATH":"/usr/bin", "HOME":"/test", "ANTHROPIC_API_KEY":"fixture", "CLAUDE_USER_DATA_DIR":"/wrong", "CLAUDE_CODE_OAUTH_TOKEN":"fixture", "ELECTRON_RUN_AS_NODE":"1", "NODE_OPTIONS":"fixture"], config: config)
        XCTAssertEqual(environment, ["PATH":"/usr/bin", "HOME":"/test", "CLAUDE_CONFIG_DIR":config.path])
    }
}

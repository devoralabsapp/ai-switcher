import XCTest
@testable import AISwitcherCore

final class DesktopProfileTests: XCTestCase {
    var root: URL!
    var backend: URL!
    var repository: ProfileRepository!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Desktop Tests \(UUID().uuidString)")
        backend = URL(fileURLWithPath: "/tmp/as-\(UUID().uuidString.prefix(8))")
        repository = ProfileRepository(root: root, desktopBackendBase: backend)
    }

    override func tearDownWithError() throws {
        for url in [root!, backend!] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    func testDesktopEnvironmentIsolatedFromHostAndUsesSharedProfileDaemon() {
        let id = UUID(), home = repository.desktopHomeURL(for: id), data = repository.desktopUserDataURL(for: id)
        let env = DesktopLaunch.environment(base: ["HOME": "/Users/test", "CODEX_HOME": "/default",
            "OPENAI_API_KEY": "fixture", "CODEX_CLI_PATH": "/other", "CODEX_APP_SERVER_FORCE_CLI": "1",
            "CODEX_ELECTRON_USER_DATA_PATH": "/default-ui"], home: home, userData: data)
        XCTAssertEqual(env["HOME"], "/Users/test")
        XCTAssertEqual(env["CODEX_HOME"], home.path)
        XCTAssertEqual(env["CODEX_ELECTRON_USER_DATA_PATH"], data.path)
        XCTAssertEqual(env["CODEX_APP_SERVER_USE_LOCAL_DAEMON"], "1")
        for key in ["OPENAI_API_KEY", "CODEX_CLI_PATH", "CODEX_APP_SERVER_FORCE_CLI"] { XCTAssertNil(env[key]) }
        XCTAssertEqual(DesktopLaunch.bridgeArguments(home: home), ["--quota-socket-bridge", home.appendingPathComponent(DesktopLaunch.socketRelativePath).path])
    }

    func testRoutingRejectsDefaultApplicationOtherProfilesAndHelpers() {
        let data = repository.desktopUserDataURL(for: UUID())
        let args = ["ChatGPT"] + DesktopLaunch.arguments(userData: data)
        XCTAssertTrue(DesktopLaunch.ownsProcess(arguments: args, userData: data))
        XCTAssertFalse(DesktopLaunch.ownsProcess(arguments: ["ChatGPT"], userData: data))
        XCTAssertFalse(DesktopLaunch.ownsProcess(arguments: args + ["--type=renderer"], userData: data))
        XCTAssertFalse(DesktopLaunch.ownsProcess(arguments: args, userData: data.appendingPathComponent("other")))
        XCTAssertEqual(args.count, 2, "A path containing spaces must remain a single argument")
    }

    func testShortBackendPathsAreStableUniqueAndPersistent() throws {
        let a = UUID(), b = UUID()
        try repository.prepareDesktopProfile(for: a)
        try repository.prepareDesktopProfile(for: b)
        let home = repository.desktopHomeURL(for: a)
        XCTAssertNotEqual(home, repository.desktopHomeURL(for: b))
        XCTAssertNotEqual(home, ProfileRepository(root: root.appendingPathComponent("other"), desktopBackendBase: backend).desktopHomeURL(for: a))
        XCTAssertLessThan(home.appendingPathComponent(DesktopLaunch.socketRelativePath).path.utf8.count, 104)
        let fixture = home.appendingPathComponent("fixture")
        let config = home.appendingPathComponent("config.toml")
        XCTAssertTrue(try String(contentsOf: config).contains("cli_auth_credentials_store = \"file\""))
        let original = try String(contentsOf: config) + "\n# retained preference\n"
        try original.write(to: config, atomically: true, encoding: .utf8)
        try Data("kept".utf8).write(to: fixture)
        try repository.prepareDesktopProfile(for: a)
        XCTAssertEqual(try String(contentsOf: fixture), "kept")
        XCTAssertEqual(try String(contentsOf: config), original)
        XCTAssertEqual(try String(contentsOf: repository.desktopProfileURL(for: a).appendingPathComponent("backend-location.txt")), home.path)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: home.path)[.posixPermissions] as? Int, 0o700)
    }

    func testExistingUnownedBackendCannotBeAdoptedOrDeleted() throws {
        let a = Account(name: "A"), home = repository.desktopHomeURL(for: a.id)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let fixture = home.appendingPathComponent("fixture")
        try Data("untouched".utf8).write(to: fixture)
        XCTAssertThrowsError(try repository.prepareDesktopProfile(for: a.id))
        XCTAssertThrowsError(try repository.remove(a.id, from: AccountSnapshot(accounts: [a])))
        XCTAssertEqual(try String(contentsOf: fixture), "untouched")
    }

    func testSymlinkedBackendAndUserDataAreRejected() throws {
        let a = UUID(), home = repository.desktopHomeURL(for: a)
        try FileManager.default.createDirectory(at: backend, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home, withDestinationURL: root)
        XCTAssertThrowsError(try repository.prepareDesktopProfile(for: a))
        try FileManager.default.removeItem(at: home)
        let data = repository.desktopUserDataURL(for: a)
        try FileManager.default.removeItem(at: data)
        try FileManager.default.createSymbolicLink(at: data, withDestinationURL: backend)
        XCTAssertThrowsError(try repository.prepareDesktopProfile(for: a))
    }

    func testOwnershipMarkerMustMatchProfile() throws {
        let a = UUID(), b = UUID()
        try repository.prepareDesktopProfile(for: a)
        try FileManager.default.copyItem(at: repository.desktopHomeURL(for: a), to: repository.desktopHomeURL(for: b))
        XCTAssertThrowsError(try repository.validateDesktopOwnership(for: b))
    }

    func testDeletionAndRollbackCoverAllFourStorageDirectories() throws {
        let a = Account(name: "A")
        try repository.prepareDesktopProfile(for: a.id)
        _ = try repository.prepareProfile(for: a.id)
        _ = try repository.prepareCodexHome(for: a.id)
        let directories = [repository.desktopProfileURL(for: a.id), repository.desktopHomeURL(for: a.id),
                           repository.profileURL(for: a.id), repository.codexHomeURL(for: a.id)]
        for url in directories { try Data("preserved".utf8).write(to: url.appendingPathComponent("fixture")) }
        XCTAssertThrowsError(try repository.remove(a.id, from: AccountSnapshot(accounts: [a], version: 99)))
        for url in directories { XCTAssertEqual(try String(contentsOf: url.appendingPathComponent("fixture")), "preserved") }
        _ = try repository.remove(a.id, from: AccountSnapshot(accounts: [a]))
        for url in directories { XCTAssertFalse(FileManager.default.fileExists(atPath: url.path)) }
    }

    func testOldMetadataDefaultsToDesktopButRetainsBrowserQuotaSeparately() throws {
        var account = Account(name: "Existing", launchMode: .browser)
        let browser = CodexConnection(identity: CodexIdentity(email: "browser@example.com", planType: "plus"))
        let desktop = CodexConnection(identity: CodexIdentity(email: "desktop@example.com", planType: "pro"))
        account.codexConnection = browser
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(account)) as? [String: Any])
        json.removeValue(forKey: "launchMode")
        var decoded = try JSONDecoder().decode(Account.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.effectiveLaunchMode, .desktop)
        XCTAssertNil(decoded.displayedCodexConnection)
        XCTAssertEqual(decoded.codexConnection, browser)
        decoded.desktopCodexConnection = desktop
        XCTAssertEqual(decoded.displayedCodexConnection, desktop)
        decoded.launchMode = .browser
        XCTAssertEqual(decoded.displayedCodexConnection, browser)
        try repository.save(AccountSnapshot(accounts: [decoded]))
        XCTAssertEqual(try repository.load().accounts.first, decoded)
    }

    func testOverlongSocketPathIsRejectedBeforeCreatingDirectories() {
        let base = root.appendingPathComponent(String(repeating: "a", count: 100))
        let other = ProfileRepository(root: root, desktopBackendBase: base)
        XCTAssertThrowsError(try other.prepareDesktopProfile(for: UUID()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testDeletionHandlesReadOnlyRuntimeDirectoriesWithoutFollowingSymlinks() throws {
        let a = Account(name: "A"), profile = try repository.prepareProfile(for: a.id)
        let external = root.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let nested = profile.appendingPathComponent("readonly/nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: nested.appendingPathComponent("file"))
        try FileManager.default.createSymbolicLink(at: profile.appendingPathComponent("external-link"), withDestinationURL: external)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: nested.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: external.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: external.path) }
        _ = try repository.remove(a.id, from: AccountSnapshot(accounts: [a]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: profile.path))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: external.path)[.posixPermissions] as? Int, 0o500)
    }
}

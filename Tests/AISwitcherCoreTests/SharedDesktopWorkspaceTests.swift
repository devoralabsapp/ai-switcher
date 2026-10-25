import XCTest
import SQLite3
@testable import AISwitcherCore

final class SharedDesktopWorkspaceTests: XCTestCase {
    private var root: URL!
    private var source: URL!
    private var repository: ProfileRepository!
    private var workspace: SharedDesktopWorkspace!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/tmp/ws-\(UUID().uuidString.prefix(8))")
        source = root.appendingPathComponent("original")
        repository = ProfileRepository(root: root.appendingPathComponent("manager"), desktopBackendBase: root.appendingPathComponent("homes"))
        workspace = SharedDesktopWorkspace(repository: repository, sourceHome: source, sourceUserData: root.appendingPathComponent("original-ui"))
        try fm.createDirectory(at: source.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        try fm.createDirectory(at: source.appendingPathComponent("archived_sessions"), withIntermediateDirectories: true)
        try createDatabase(source.appendingPathComponent("state_5.sqlite"))
    }

    override func tearDownWithError() throws { try fm.removeItem(at: root) }

    private func profile() throws -> Account {
        let account = Account(name: "Fixture", sharesLocalWorkspace: true)
        try repository.prepareDesktopProfile(for: account.id)
        var snapshot = try repository.load()
        snapshot.accounts.append(account)
        try repository.save(snapshot)
        return account
    }

    private func write(_ object: [String: Any], in home: URL) throws {
        try JSONSerialization.data(withJSONObject: object).write(to: home.appendingPathComponent(".codex-global-state.json"))
    }

    private func read(in home: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: home.appendingPathComponent(".codex-global-state.json"))) as? [String: Any])
    }

    private func createDatabase(_ url: URL, path: String? = nil) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT NOT NULL)", nil, nil, nil), SQLITE_OK)
        if let path {
            var statement: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(db, "INSERT INTO threads VALUES ('fixture', ?)", -1, &statement, nil), SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(statement, 1, path, -1, transient)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        }
    }

    func testSharedStoragePreservesAuthenticationAndFiltersMetadata() throws {
        let account = try profile(), home = repository.desktopHomeURL(for: account.id)
        try Data("original auth fixture".utf8).write(to: source.appendingPathComponent("auth.json"))
        try Data("profile auth fixture".utf8).write(to: home.appendingPathComponent("auth.json"))
        try write(["projectless-thread-ids": ["work-a"], "local-projects": ["project-a": ["rootPaths": ["/fixture/repo"]]],
                   "electron-persisted-atom-state": ["unrelated": "original"], "unrelated": "not copied"], in: source)
        try write(["unrelated": "profile", "electron-persisted-atom-state": ["unrelated": "profile"]], in: home)
        let original = try Data(contentsOf: source.appendingPathComponent(".codex-global-state.json"))
        XCTAssertEqual(try workspace.prepare(account.id), source)
        let state = try read(in: home)
        XCTAssertEqual(state["projectless-thread-ids"] as? [String], ["work-a"])
        XCTAssertNotNil((state["local-projects"] as? [String: Any])?["project-a"])
        XCTAssertEqual(state["unrelated"] as? String, "profile")
        XCTAssertEqual((state["electron-persisted-atom-state"] as? [String: String])?["unrelated"], "profile")
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent(".codex-global-state.json")), original)
        XCTAssertEqual(try String(contentsOf: home.appendingPathComponent("auth.json")), "profile auth fixture")
        XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("auth.json")), "original auth fixture")
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: home.appendingPathComponent("sessions").path), source.appendingPathComponent("sessions").path)
        let env = DesktopLaunch.environment(base: ["CODEX_HOME": "/other", "CODEX_SQLITE_HOME": "/other"], home: home,
                                            userData: repository.desktopUserDataURL(for: account.id), sharedDatabaseHome: source)
        XCTAssertEqual(env["CODEX_HOME"], home.path)
        XCTAssertEqual(env["CODEX_SQLITE_HOME"], source.path)
    }

    func testNewLocalWorkIsAvailableToOtherProfilesWithoutCopyingTranscripts() throws {
        let first = try profile(), second = try profile()
        let firstHome = repository.desktopHomeURL(for: first.id), secondHome = repository.desktopHomeURL(for: second.id)
        try workspace.prepare(first.id)
        try write(["projectless-thread-ids": ["new-work"]], in: firstHome)
        try Data("transcript fixture".utf8).write(to: firstHome.appendingPathComponent("sessions/new.jsonl"))
        try workspace.prepare(second.id)
        XCTAssertEqual(try read(in: secondHome)["projectless-thread-ids"] as? [String], ["new-work"])
        XCTAssertEqual(try String(contentsOf: secondHome.appendingPathComponent("sessions/new.jsonl")), "transcript fixture")
        try workspace.prepare(second.id)
        XCTAssertEqual(try read(in: secondHome)["projectless-thread-ids"] as? [String], ["new-work"])
    }

    func testDeletionKeepsSharedHistoryAndCanonicalizesItsPaths() throws {
        let account = try profile(), home = repository.desktopHomeURL(for: account.id)
        try workspace.prepare(account.id)
        try write(["projectless-thread-ids": ["saved-work"]], in: home)
        let transcript = home.appendingPathComponent("sessions/kept.jsonl")
        try Data("kept".utf8).write(to: transcript)
        try fm.removeItem(at: source.appendingPathComponent("state_5.sqlite"))
        try createDatabase(source.appendingPathComponent("state_5.sqlite"), path: transcript.path)
        _ = try repository.remove(account.id, from: repository.load())
        XCTAssertFalse(fm.fileExists(atPath: home.path))
        XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("sessions/kept.jsonl")), "kept")
        var db: OpaquePointer?, statement: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(source.appendingPathComponent("state_5.sqlite").path, &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT rollout_path FROM threads", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(String(cString: sqlite3_column_text(statement, 0)), source.appendingPathComponent("sessions/kept.jsonl").path)
        let next = try profile()
        try workspace.prepare(next.id)
        XCTAssertEqual(try read(in: repository.desktopHomeURL(for: next.id))["projectless-thread-ids"] as? [String], ["saved-work"])
    }

    func testRestoringPrivateWorkspaceKeepsSettingsAndSharedTranscripts() throws {
        let account = try profile(), home = repository.desktopHomeURL(for: account.id)
        try write(["unrelated": "original", "project-order": ["private-project"]], in: home)
        try write(["projectless-thread-ids": ["source-work"]], in: source)
        try fm.createDirectory(at: home.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        try workspace.prepare(account.id)
        var state = try read(in: home); state["unrelated"] = "changed"; try write(state, in: home)
        try Data("shared".utf8).write(to: home.appendingPathComponent("sessions/shared.jsonl"))
        try workspace.restorePrivateWorkspace(account.id)
        let restored = try read(in: home)
        XCTAssertEqual(restored["unrelated"] as? String, "changed")
        XCTAssertEqual(restored["project-order"] as? [String], ["private-project"])
        XCTAssertNil(restored["projectless-thread-ids"])
        XCTAssertFalse(workspace.isPrepared(account.id))
        XCTAssertTrue(try fm.contentsOfDirectory(atPath: home.appendingPathComponent("sessions").path).isEmpty)
        XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("sessions/shared.jsonl")), "shared")
        XCTAssertNoThrow(try workspace.prepare(account.id))
    }

    func testPrivateHistoryIsNeverOverwrittenOrHidden() throws {
        let account = try profile(), home = repository.desktopHomeURL(for: account.id)
        try createDatabase(home.appendingPathComponent("state_5.sqlite"), path: "/private/transcript")
        try write(["projectless-thread-ids": ["private-work"]], in: home)
        XCTAssertThrowsError(try workspace.prepare(account.id)) { XCTAssertTrue($0 is SharedWorkspaceError) }
        XCTAssertFalse(workspace.isPrepared(account.id))
        XCTAssertEqual(try read(in: home)["projectless-thread-ids"] as? [String], ["private-work"])
    }

    func testSymlinkReplacementAndSymlinkedSourceAreRejected() throws {
        let account = try profile(), home = repository.desktopHomeURL(for: account.id)
        try workspace.prepare(account.id)
        let sessions = home.appendingPathComponent("sessions")
        try fm.removeItem(at: sessions)
        try fm.createSymbolicLink(at: sessions, withDestinationURL: root)
        XCTAssertThrowsError(try workspace.prepare(account.id))
        XCTAssertThrowsError(try workspace.restorePrivateWorkspace(account.id))
        let other = root.appendingPathComponent("source-link")
        try fm.createSymbolicLink(at: other, withDestinationURL: source)
        XCTAssertThrowsError(try SharedDesktopWorkspace(repository: repository, sourceHome: other, sourceUserData: root.appendingPathComponent("original-ui")).prepare(account.id))
    }

    func testCustomSQLiteLocationAndInheritedOverrideIsolation() throws {
        let account = try profile(), home = repository.desktopHomeURL(for: account.id)
        let databaseHome = root.appendingPathComponent("custom db")
        let literal = String(data: try JSONEncoder().encode(databaseHome.path), encoding: .utf8)!
        try "sqlite_home = \(literal) # configured by the user\n[analytics]\nenabled = false\n".write(to: source.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try workspace.prepare(account.id), databaseHome)
        let env = DesktopLaunch.environment(base: ["CODEX_SQLITE_HOME": source.path], home: home, userData: root)
        XCTAssertNil(env["CODEX_SQLITE_HOME"], "Private profiles must not inherit another workspace")
    }

    func testOldProfilesRemainPrivateUntilExplicitlyEnabled() throws {
        let legacy = try JSONDecoder().decode(Account.self, from: JSONEncoder().encode(Account(name: "Existing")))
        XCTAssertFalse(legacy.usesSharedLocalWorkspace)
        var enabled = legacy; enabled.sharesLocalWorkspace = true
        try repository.save(AccountSnapshot(accounts: [enabled]))
        XCTAssertTrue(try repository.load().accounts[0].usesSharedLocalWorkspace)
    }

    func testWorkArtifactsAreSharedAndPrivateCachesCanBeRestored() throws {
        let first = try profile(), second = try profile()
        let privateArtifacts = repository.desktopUserDataURL(for: first.id).appendingPathComponent("artifact-sessions")
        try fm.createDirectory(at: privateArtifacts, withIntermediateDirectories: true)
        try Data("private cache".utf8).write(to: privateArtifacts.appendingPathComponent("cache"))
        try workspace.prepare(first.id)
        try Data("document state".utf8).write(to: privateArtifacts.appendingPathComponent("document"))
        try workspace.prepare(second.id)
        let secondArtifacts = repository.desktopUserDataURL(for: second.id).appendingPathComponent("artifact-sessions")
        XCTAssertEqual(try String(contentsOf: secondArtifacts.appendingPathComponent("document")), "document state")
        try workspace.restorePrivateWorkspace(first.id)
        XCTAssertEqual(try String(contentsOf: privateArtifacts.appendingPathComponent("cache")), "private cache")
        XCTAssertFalse(fm.fileExists(atPath: privateArtifacts.appendingPathComponent("document").path))
        XCTAssertEqual(try String(contentsOf: secondArtifacts.appendingPathComponent("document")), "document state")
        _ = try repository.remove(second.id, from: repository.load())
        XCTAssertEqual(try String(contentsOf: workspace.sourceUserData.appendingPathComponent("artifact-sessions/document")), "document state")
    }

    func testEquivalentDirectoryURLRepresentationsRemainValidAfterReload() throws {
        let account = try profile(), home = repository.desktopHomeURL(for: account.id)
        try workspace.prepare(account.id)
        let marker = home.appendingPathComponent("ai-switcher-workspace.json")
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: marker)) as? [String: Any])
        value["sourceHome"] = URL(fileURLWithPath: source.path, isDirectory: true).absoluteString
        value["databaseHome"] = URL(fileURLWithPath: source.path, isDirectory: false).absoluteString
        try JSONSerialization.data(withJSONObject: value).write(to: marker)
        XCTAssertEqual(try workspace.prepare(account.id).path, source.path)
        XCTAssertNoThrow(try workspace.archiveMetadata(account.id))
        XCTAssertNoThrow(try workspace.restorePrivateWorkspace(account.id))
    }
}

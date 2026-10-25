import XCTest
@testable import AISwitcherCore

final class ProfileRepositoryTests: XCTestCase {
    var root: URL!
    var repository: ProfileRepository!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AI Switcher Tests \(UUID().uuidString)")
        repository = ProfileRepository(root: root)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }

    func testEmptyFirstLaunchDoesNotCreateData() throws {
        XCTAssertEqual(try repository.load(), AccountSnapshot())
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testAccountsAndSelectionSurviveRestart() throws {
        let a = Account(name: "Cá nhân", emailHint: "me@example.com", color: .violet, isFavorite: true)
        let b = Account(name: "Công việc", browser: .brave)
        let snapshot = AccountSnapshot(accounts: [a, b], lastOpenedID: b.id)
        try repository.save(snapshot)
        XCTAssertEqual(try ProfileRepository(root: root).load(), snapshot)
    }

    func testEveryAccountHasIsolatedStableDirectory() throws {
        let a = UUID(), b = UUID()
        let aURL = try repository.prepareProfile(for: a)
        let bURL = try repository.prepareProfile(for: b)
        XCTAssertNotEqual(aURL, bURL)
        XCTAssertEqual(aURL, try repository.prepareProfile(for: a))
        try Data("A-session".utf8).write(to: aURL.appendingPathComponent("session"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: bURL.appendingPathComponent("session").path))
    }

    func testInvalidSavePreservesExistingData() throws {
        let account = Account(name: "Work")
        let valid = AccountSnapshot(accounts: [account])
        try repository.save(valid)
        XCTAssertThrowsError(try repository.save(AccountSnapshot(accounts: [account, account])))
        XCTAssertEqual(try repository.load(), valid)
    }

    func testCorruptMetadataIsNeverReplacedOnLoad() throws {
        try repository.save(AccountSnapshot())
        let corrupt = Data("not-json".utf8)
        try corrupt.write(to: repository.metadataURL)
        XCTAssertThrowsError(try repository.load())
        XCTAssertEqual(try Data(contentsOf: repository.metadataURL), corrupt)
    }

    func testUnsupportedVersionIsRejected() throws {
        XCTAssertThrowsError(try repository.save(AccountSnapshot(version: 99)))
    }

    func testMissingSelectionIsRejected() throws {
        XCTAssertThrowsError(try repository.save(AccountSnapshot(lastOpenedID: UUID())))
    }

    func testRemovingOneProfileLeavesOtherSessionIntact() throws {
        let a = Account(name: "A"), b = Account(name: "B")
        let aURL = try repository.prepareProfile(for: a.id)
        let bURL = try repository.prepareProfile(for: b.id)
        try Data("cookie-A".utf8).write(to: aURL.appendingPathComponent("cookies"))
        try Data("cookie-B".utf8).write(to: bURL.appendingPathComponent("cookies"))
        let initial = AccountSnapshot(accounts: [a, b], lastOpenedID: a.id)
        try repository.save(initial)
        let updated = try repository.remove(a.id, from: initial)
        XCTAssertEqual(updated.accounts, [b])
        XCTAssertNil(updated.lastOpenedID)
        XCTAssertEqual(try repository.load(), updated)
        XCTAssertFalse(FileManager.default.fileExists(atPath: aURL.path))
        XCTAssertEqual(try String(contentsOf: bURL.appendingPathComponent("cookies")), "cookie-B")
    }

    func testMetadataAndDirectoriesArePrivateToOSUser() throws {
        try repository.save(AccountSnapshot())
        let folder = try repository.prepareProfile(for: UUID())
        let metadataMode = try FileManager.default.attributesOfItem(atPath: repository.metadataURL.path)[.posixPermissions] as? Int
        let folderMode = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int
        XCTAssertEqual(metadataMode, 0o600)
        XCTAssertEqual(folderMode, 0o700)
    }

    func testFailedRemovalRestoresCompleteSession() throws {
        let account = Account(name: "Keep this session")
        let initial = AccountSnapshot(accounts: [account])
        try repository.save(initial)
        let profile = try repository.prepareProfile(for: account.id)
        let cookies = profile.appendingPathComponent("cookies")
        try Data("retained-session".utf8).write(to: cookies)
        var invalid = initial
        invalid.version = 99
        XCTAssertThrowsError(try repository.remove(account.id, from: invalid))
        XCTAssertEqual(try String(contentsOf: cookies), "retained-session")
        XCTAssertEqual(try repository.load(), initial)
    }

    func testProcessRoutingRequiresExactProfileAndMainProcess() {
        let profile = URL(fileURLWithPath: "/tmp/AI Switcher/Profiles/ABC")
        XCTAssertTrue(BrowserLaunch.ownsProcess(arguments: ["chrome", "--user-data-dir=\(profile.path)"], profileURL: profile))
        XCTAssertFalse(BrowserLaunch.ownsProcess(arguments: ["chrome", "--user-data-dir=\(profile.path)-other"], profileURL: profile))
        XCTAssertFalse(BrowserLaunch.ownsProcess(arguments: ["chrome", "--user-data-dir=\(profile.path)", "--type=renderer"], profileURL: profile))
    }

    func testLaunchArgumentsKeepPathsWithSpacesAsOneArgument() {
        let url = URL(fileURLWithPath: "/tmp/AI Switcher/Profiles/ID")
        let arguments = BrowserLaunch.arguments(profileURL: url)
        XCTAssertEqual(arguments.first, "--user-data-dir=/tmp/AI Switcher/Profiles/ID")
        XCTAssertTrue(arguments.contains("--app=https://chatgpt.com/"))
        XCTAssertFalse(arguments.contains { $0.hasPrefix("--remote-debugging") || $0 == "--no-sandbox" })
    }

    func testLabelsAreTrimmedAndValidated() throws {
        let account = Account(name: "  Công việc  ", emailHint: "  work@example.com ")
        XCTAssertEqual(account.name, "Công việc")
        XCTAssertEqual(account.initials, "CV")
        XCTAssertEqual(account.emailHint, "work@example.com")
        XCTAssertThrowsError(try Account(name: "  ").validate())
        XCTAssertThrowsError(try Account(name: String(repeating: "a", count: 49)).validate())
    }
}

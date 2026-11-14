import XCTest
import SQLite3
import CommonCrypto
import CryptoKit
@testable import AISwitcher
@testable import AISwitcherCore

@MainActor
final class ClaudeDesktopQuotaTests: XCTestCase {
    private let org = "34343434-3434-4434-8434-343434343434"
    private let identity = "12121212-1212-4212-8212-121212121212"
    private func repository() throws -> ProfileRepository {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("claude-quota-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return ProfileRepository(root: root)
    }
    private func database(_ repository: ProfileRepository, _ account: Account, token: String, encrypted: Data = Data(), version: Int = 24, host: String = ".claude.ai", expires: Int64 = 0) throws {
        try repository.prepareClaudeProfile(for: account.id)
        var db: OpaquePointer?, statement: OpaquePointer?
        let path = repository.claudeUserDataURL(for: account.id).appendingPathComponent("Cookies")
        XCTAssertEqual(sqlite3_open(path.path, &db), SQLITE_OK)
        defer { sqlite3_finalize(statement); sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS meta(key TEXT,value TEXT); DELETE FROM meta; INSERT INTO meta VALUES('version','\(version)'); CREATE TABLE IF NOT EXISTS cookies(name TEXT,host_key TEXT,value TEXT,encrypted_value BLOB,expires_utc INTEGER,path TEXT); DELETE FROM cookies;", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_prepare_v2(db, "INSERT INTO cookies VALUES('sessionKey',?,?,?,?,'/')", -1, &statement, nil), SQLITE_OK)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, host, -1, transient); sqlite3_bind_text(statement, 2, token, -1, transient)
        encrypted.withUnsafeBytes { bytes in _ = sqlite3_bind_blob(statement, 3, bytes.baseAddress, Int32(encrypted.count), transient) }
        sqlite3_bind_int64(statement, 4, expires)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
    }
    private func encrypted(_ token: String, password: Data, host: String? = ".claude.ai") throws -> Data {
        let salt = Array("saltysalt".utf8); var key = [UInt8](repeating: 0, count: 16)
        let derivation = password.withUnsafeBytes { bytes in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), bytes.baseAddress?.assumingMemoryBound(to: Int8.self), password.count, salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, &key, 16)
        }
        XCTAssertEqual(derivation, Int32(kCCSuccess))
        let data = (host.map { Data(SHA256.hash(data: Data($0.utf8))) } ?? Data()) + Data(token.utf8)
        var output = [UInt8](repeating: 0, count: data.count + 16); var count = 0
        let status = data.withUnsafeBytes { bytes in CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding), key, key.count, [UInt8](repeating: 32, count: 16), bytes.baseAddress, data.count, &output, output.count, &count) }
        XCTAssertEqual(status, Int32(kCCSuccess))
        return Data("v10".utf8) + Data(output.prefix(count))
    }
    private func metadata(email: String = "free@example.test", id: String? = nil) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["uuid": id ?? identity, "email_address": email])
    }
    private var organizations: Data { Data("[{\"uuid\":\"\(org)\",\"plan_display_name\":\"Free\"}]".utf8) }

    func testEncryptedProfileCookieUsesKeychainPasswordOnlyInMemoryAndRestrictsRequests() throws {
        let repo = try repository(); defer { try? FileManager.default.removeItem(at: repo.root) }
        let account = Account(name: "Free", agent: .claude).withDesktopSignIn(.browser)
        let secret = "sk-ant-sid-disposable-fixture", password = Data("fixture-password".utf8)
        try database(repo, account, token: "", encrypted: encrypted(secret, password: password))
        let jar = try ClaudeDesktopCookies.read(userData: repo.claudeUserDataURL(for: account.id), password: { password })
        XCTAssertEqual(try jar.request(path: "/api/account").value(forHTTPHeaderField: "Cookie"), "sessionKey=" + secret)
        XCTAssertFalse(String(describing: jar).contains(secret)); XCTAssertFalse(String(reflecting: jar).contains(secret))
        for path in ["https://example.test/", "//example.test/", "/api/chat_conversations", "/api/organizations/not-a-uuid/usage", "/api/account?next=https://example.test/"] { XCTAssertThrowsError(try jar.request(path: path)) }
        XCTAssertThrowsError(try ClaudeDesktopCookies.decrypt(try encrypted(secret, password: password, host: "example.test"), password: password, host: ".claude.ai", requiresHostDigest: true))
        XCTAssertThrowsError(try ClaudeDesktopCookies.decrypt(try encrypted(secret, password: password), password: Data("wrong".utf8), host: ".claude.ai", requiresHostDigest: true))
    }
    func testAllThreeSignInMethodsReadFreeQuotaWithoutCLIOrAnotherWebLogin() async throws {
        let repo = try repository(); defer { try? FileManager.default.removeItem(at: repo.root) }
        for method in AccountSignInMethod.allCases {
            let account = Account(name: method.rawValue, agent: .claude).withDesktopSignIn(method)
            let token = "fixture-" + method.rawValue
            try database(repo, account, token: token)
            var paths: [String] = []
            let service = ClaudeDesktopQuotaService(repository: repo, password: { _ in XCTFail("Plain fixture must not access Keychain"); return Data() }, fetch: { request in
                paths.append(request.url!.path)
                XCTAssertEqual(request.httpMethod, "GET"); XCTAssertEqual(request.url?.host, "claude.ai")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "sessionKey=" + token)
                if request.url!.path == "/api/account" { return (try self.metadata(), 200) }
                if request.url!.path == "/api/organizations" { return (self.organizations, 200) }
                return (Data(#"{"five_hour":{"utilization":23,"resets_at":"2030-01-01T00:00:00Z"},"seven_day":{"utilization":0}}"#.utf8), 200)
            })
            let result = try await service.read(account)
            XCTAssertEqual(result.identity.planType, "free"); XCTAssertEqual(result.identity.email, "free@example.test")
            XCTAssertEqual(result.quota?.limits.buckets.first?.value.primary?.remainingPercent, 77)
            XCTAssertEqual(result.quota?.limits.buckets.first?.value.secondary?.remainingPercent, 100)
            XCTAssertTrue(paths.contains("/api/organizations/\(org)/usage"))
            XCTAssertEqual(paths.filter { $0 == "/api/account" }.count, 2)
            XCTAssertFalse(String(decoding: try JSONEncoder().encode(result), as: UTF8.self).contains(token))
        }
    }
    func testFreeWithoutProviderNumbersKeepsIdentityAndNeverInventsQuota() async throws {
        let repo = try repository(); defer { try? FileManager.default.removeItem(at: repo.root) }
        let account = Account(name: "Free", agent: .claude).withDesktopSignIn(.desktop)
        try database(repo, account, token: "fixture-free")
        var usageRequested = false
        let service = ClaudeDesktopQuotaService(repository: repo, fetch: { request in
            if request.url!.path == "/api/account" { return (try self.metadata(), 200) }
            if request.url!.path == "/api/organizations" { return (self.organizations, 200) }
            usageRequested = true; return (Data("{}".utf8), 403)
        })
        let result = try await service.read(account)
        XCTAssertTrue(usageRequested); XCTAssertEqual(result.identity.planType, "free"); XCTAssertNotNil(result.identity.email)
        XCTAssertNil(result.quota)
    }
    func testSignedOutAndConflictingHostsNeverReadAnotherProfileOrCallKeychain() throws {
        let repo = try repository(); defer { try? FileManager.default.removeItem(at: repo.root) }
        let a = Account(name: "A", agent: .claude).withDesktopSignIn(.desktop), b = Account(name: "B", agent: .claude).withDesktopSignIn(.desktop)
        try database(repo, a, token: "private-A")
        XCTAssertThrowsError(try ClaudeDesktopCookies.read(userData: repo.claudeUserDataURL(for: b.id), password: { XCTFail("No sign-in must not read Keychain"); return Data() }))
        try database(repo, a, token: "", encrypted: Data("v20unsupported".utf8))
        XCTAssertThrowsError(try ClaudeDesktopCookies.read(userData: repo.claudeUserDataURL(for: a.id), password: { XCTFail("Unknown encryption must not read Keychain"); return Data() }))
        try database(repo, a, token: "expired", expires: 1)
        XCTAssertThrowsError(try ClaudeDesktopCookies.read(userData: repo.claudeUserDataURL(for: a.id), password: { XCTFail(); return Data() }))
    }
    func testIdentityChangingDuringUsageReadIsRejected() async throws {
        let repo = try repository(); defer { try? FileManager.default.removeItem(at: repo.root) }
        let account = Account(name: "A", agent: .claude).withDesktopSignIn(.cli)
        try database(repo, account, token: "private-A")
        var reads = 0
        let service = ClaudeDesktopQuotaService(repository: repo, fetch: { request in
            if request.url!.path == "/api/account" { reads += 1; return (try self.metadata(id: reads == 1 ? self.identity : "56565656-5656-4656-8656-565656565656"), 200) }
            if request.url!.path == "/api/organizations" { return (self.organizations, 200) }
            return (Data(#"{"five_hour":{"utilization":0}}"#.utf8), 200)
        })
        do { _ = try await service.read(account); XCTFail("Expected identity mismatch") }
        catch { XCTAssertEqual(error as? ProviderQuotaError, .identityChanged) }
    }
}

@MainActor
private final class ClaudeQuotaFixture: ClaudeDesktopQuotaReading {
    var reads = 0
    var result: CodexConnection
    var interactive: [Bool] = []
    var sessionAvailable = true
    var failNextRead = false
    init(_ result: CodexConnection) { self.result = result }
    func hasSession(_ account: Account) -> Bool { sessionAvailable }
    func read(_ account: Account, interactive: Bool, onIdentity: ((CodexIdentity) throws -> Void)?) async throws -> CodexConnection {
        reads += 1
        self.interactive.append(interactive)
        if failNextRead {
            failNextRead = false
            throw ProviderQuotaError.timeout
        }
        try onIdentity?(result.identity)
        return result
    }
}

@MainActor
final class ClaudeQuotaRoutingTests: XCTestCase {
    func testSavedAndNewlyCompletedLoginsAutoConnectAllMethodsWithoutClickingConnect() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("claude-auto-" + UUID().uuidString)
        let suite = "claude-auto-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let identity = CodexIdentity(email: "free@example.test", planType: "free", accountId: "fixture-user")
        let parsed = try ClaudeWebAccount.parseUsage(Data(#"{"five_hour":{"utilization":23}}"#.utf8), identity: identity)
        let result = CodexConnection(identity: identity, quota: parsed.quota, identityFetchedAt: Date(), providerSessionKind: "claudeDesktop")
        let source = ClaudeQuotaFixture(result)
        source.sessionAvailable = false
        let accounts = AccountSignInMethod.allCases.map { Account(name: $0.rawValue, agent: .claude).withDesktopSignIn($0) }
        try ProfileRepository(root: root).save(.init(accounts: accounts))
        let model = AppModel(root: root, monitoring: false, claudeDesktopQuotaSource: source, preferencesStore: AppPreferencesStore(defaults: defaults))
        model.refreshClaudeQuotaIfNeeded()
        XCTAssertEqual(source.reads, 0, "Do not read or request authorization before Desktop saves its session")
        source.sessionAvailable = true
        source.failNextRead = true
        let firstAttempt = Date()
        model.refreshClaudeQuotaIfNeeded(now: firstAttempt)
        for _ in 0..<200 { if model.quotaBusyIDs.isEmpty { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(source.reads, 3)
        XCTAssertEqual(source.interactive, [true, true, true], "The first automatic connection may request OS authorization")
        XCTAssertEqual(model.providerSessionIDs.count, 2)
        model.refreshClaudeQuotaIfNeeded(now: firstAttempt.addingTimeInterval(10))
        XCTAssertTrue(model.quotaBusyIDs.isEmpty, "A temporary failure must respect the retry interval")
        model.refreshClaudeQuotaIfNeeded(now: firstAttempt.addingTimeInterval(61))
        for _ in 0..<200 { if model.quotaBusyIDs.isEmpty { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(source.reads, 4)
        XCTAssertEqual(source.interactive.last, false, "Automatic retries must not ask for authorization again")
        for account in accounts {
            XCTAssertEqual(model.accounts.first { $0.id == account.id }?.providerQuotaConnection, result)
            XCTAssertTrue(model.providerSessionIDs.contains(account.id))
        }
        model.refreshClaudeQuotaIfNeeded()
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(source.reads, 4, "Fresh connected sessions must not be read repeatedly")
        await model.shutdownQuota()
    }

    func testConnectRefreshAndCloseUseDesktopForAllMethodsAndRetainRealFreeCache() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("claude-routing-" + UUID().uuidString)
        let suite = "claude-routing-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let identity = CodexIdentity(email: "free@example.test", planType: "free", accountId: "12121212-1212-4212-8212-121212121212")
        let quota = try ClaudeWebAccount.parseUsage(Data(#"{"five_hour":{"utilization":41}}"#.utf8), identity: identity)
        let value = CodexConnection(identity: identity, quota: quota.quota, identityFetchedAt: Date(), providerSessionKind: "claudeDesktop")
        let source = ClaudeQuotaFixture(value)
        let accounts = AccountSignInMethod.allCases.map { Account(name: $0.rawValue, agent: .claude).withDesktopSignIn($0) }
        try ProfileRepository(root: root).save(.init(accounts: accounts))
        let model = AppModel(root: root, monitoring: false, claudeDesktopQuotaSource: source, preferencesStore: AppPreferencesStore(defaults: defaults))
        func wait(_ id: UUID) async throws {
            for _ in 0..<200 { if !model.quotaBusyIDs.contains(id) { return }; try await Task.sleep(nanoseconds: 10_000_000) }
            XCTFail("Quota operation timed out")
        }
        for account in accounts {
            model.connectSession(account); try await wait(account.id)
            XCTAssertEqual(model.accounts.first { $0.id == account.id }?.providerQuotaConnection, value)
            XCTAssertNil(model.quotaErrors[account.id])
        }
        XCTAssertEqual(source.reads, 3); XCTAssertEqual(source.interactive, [true, true, true])
        source.result = CodexConnection(identity: identity, identityFetchedAt: Date(), providerSessionKind: "claudeDesktop")
        model.refreshQuota(accounts[0]); try await wait(accounts[0].id)
        XCTAssertEqual(model.accounts[0].providerQuotaConnection?.quota, value.quota, "A failed/no-data refresh must not erase real Free quota")
        XCTAssertNotNil(model.quotaErrors[accounts[0].id], "Retained data must be marked stale")
        XCTAssertEqual(source.interactive.last, false)
        for account in accounts { model.closeSession(account) }
        for _ in 0..<100 { if model.launchingIDs.isEmpty { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        let count = source.reads
        model.refreshClaudeQuotaIfNeeded(now: Date().addingTimeInterval(120))
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(source.reads, count, "Close session must not be undone by background polling")
        await model.shutdownQuota()
    }
}

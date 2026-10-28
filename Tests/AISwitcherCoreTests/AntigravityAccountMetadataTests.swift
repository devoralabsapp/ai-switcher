import XCTest
@testable import AISwitcherCore
@testable import AISwitcher

final class AntigravityAccountMetadataTests: XCTestCase {
    private func record(email: String = "gravity@example.test", subject: String = "123456789", issuer: String = "https://accounts.google.com", method: String = "consumer", verified: Bool = true) throws -> Data {
        func encode(_ value: [String: Any]) throws -> String {
            try JSONSerialization.data(withJSONObject: value).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        let header = try encode(["alg": "RS256"])
        let claims = try encode(["iss": issuer, "email": email, "email_verified": verified, "sub": subject, "iat": 1, "exp": 2])
        return try JSONSerialization.data(withJSONObject: ["auth_method": method, "id_token": header + "." + claims + ".fixture-signature", "token": ["access_token": "do-not-forward", "refresh_token": "do-not-forward"]])
    }
    func testSavedGoogleEmailSurvivesIDTokenExpiryWithoutBecomingAuthenticationOrPlan() throws {
        let identity = try XCTUnwrap(AntigravityAccountMetadata.identity(from: record()))
        XCTAssertEqual(identity.email, "gravity@example.test")
        XCTAssertEqual(identity.accountId, "google:123456789")
        XCTAssertNil(identity.planType)
        let persisted = String(decoding: try JSONEncoder().encode(identity), as: UTF8.self)
        XCTAssertFalse(persisted.contains("do-not-forward"))
        XCTAssertFalse(persisted.contains("fixture-signature"))
    }
    func testUnknownAuthAndInvalidIdentityNeverUseAccountLabelsAsEmail() throws {
        for data in [try record(issuer: "https://example.test"), try record(method: "api_key"), try record(verified: false), try record(email: "not-an-email"), try record(email: "a\nb@example.test"), try record(subject: ""), Data(#"{"email":"label@example.test","auth_method":"consumer","id_token":"broken"}"#.utf8), Data(repeating: 32, count: 131_073)] {
            XCTAssertNil(AntigravityAccountMetadata.identity(from: data))
        }
    }
    func testChangedProfileOrHintCannotBeAttachedToAnotherAccountsQuota() throws {
        let a = AntigravityAccountMetadata.identity(from: try record())
        let b = AntigravityAccountMetadata.identity(from: try record(email: "other@example.test", subject: "other"))
        for (before, after) in [(a,b),(a,nil),(nil,a)] {
            XCTAssertThrowsError(try AntigravityAccountMetadata.consistentIdentity(before: before, after: after, emailHint: "")) { XCTAssertEqual($0 as? ProviderQuotaError, .identityChanged) }
        }
        XCTAssertThrowsError(try AntigravityAccountMetadata.consistentIdentity(before: a, after: a, emailHint: "other@example.test"))
        XCTAssertEqual(try AntigravityAccountMetadata.consistentIdentity(before: a, after: a, emailHint: "GRAVITY@example.test"), a)
        XCTAssertNil(try AntigravityAccountMetadata.consistentIdentity(before: nil, after: nil, emailHint: "label@example.test").email)
    }
    @MainActor
    func testProductionReaderAttachesEmailOnlyAfterUsageAndRejectsIdentitySwitch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ai-switcher-agy-email-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let metadata = root.appendingPathComponent("identity.json")
        try record().write(to: metadata)
        let executable = root.appendingPathComponent("antigravity-fixture")
        let script = """
        #!/usr/bin/python3
        import sys,json,pathlib
        if sys.argv[1:]==['--version']: print('1.4.9');sys.exit()
        assert sys.argv[1:]==['-p','/usage','--output-format','json']
        root=pathlib.Path(__file__).parent
        if (root/'changed.json').exists(): (root/'identity.json').write_bytes((root/'changed.json').read_bytes())
        print(json.dumps({'num_turns':0,'command':{'name':'usage','data':{'groups':[{'name':'Gemini models','buckets':[{'id':'gemini-weekly','remaining_fraction':0.99}]}]}}}))
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let dataRoot = root.appendingPathComponent("Data")
        try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        let service = ProviderQuotaService(repository: ProfileRepository(root: dataRoot), antigravityIdentityURL: metadata)
        let account = Account(name: "My label", agent: .antigravity)
        let value = try await service.read(account, override: executable.path)
        XCTAssertEqual(value.identity.email, "gravity@example.test")
        XCTAssertEqual(try XCTUnwrap(value.quota?.limits.buckets.first?.value.primary?.remainingPercent), 99, accuracy: 0.001)
        try record(email: "other@example.test", subject: "other").write(to: root.appendingPathComponent("changed.json"))
        do { _ = try await service.read(account, override: executable.path);XCTFail("Changed sign-in must be rejected") }
        catch { XCTAssertEqual(error as? ProviderQuotaError, .identityChanged) }
        try FileManager.default.removeItem(at: metadata)
        try FileManager.default.removeItem(at: root.appendingPathComponent("changed.json"))
        let withoutMetadata = try await service.read(account, override: executable.path)
        XCTAssertNil(withoutMetadata.identity.email)
        XCTAssertNotNil(withoutMetadata.quota, "Missing email must not break existing quota reads")
    }
    @MainActor
    func testInstalledAntigravityOfficialQuotaAndSavedEmail() async throws {
        guard let path = ProcessInfo.processInfo.environment["AISWITCHER_TEST_ANTIGRAVITY_CLI"] else { throw XCTSkip("Enable explicitly for a read-only official CLI usage check") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ai-switcher-agy-live-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let service = ProviderQuotaService(repository: ProfileRepository(root: root))
        let value = try await service.read(Account(name: "Shared sign-in", agent: .antigravity), override: path)
        XCTAssertTrue(value.identity.email?.contains("@") == true, "The saved Google profile should provide an email")
        XCTAssertNotNil(value.quota)
    }
}

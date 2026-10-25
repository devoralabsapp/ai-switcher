import XCTest
@testable import AISwitcherCore

final class CodexQuotaTests: XCTestCase {
    private func limits(_ json: String) throws -> CodexRateLimits {
        try JSONDecoder().decode(CodexRateLimits.self, from: Data(json.utf8))
    }

    func testRemainingMeansOneHundredMinusUsedAndIsClamped() {
        XCTAssertEqual(CodexQuotaWindow(usedPercent: 23, windowDurationMins: 300, resetsAt: nil).remainingPercent, 77)
        XCTAssertEqual(CodexQuotaWindow(usedPercent: 125, windowDurationMins: nil, resetsAt: nil).remainingPercent, 0)
        XCTAssertEqual(CodexQuotaWindow(usedPercent: -5, windowDurationMins: nil, resetsAt: nil).remainingPercent, 100)
        XCTAssertNil(CodexQuotaWindow(usedPercent: nil, windowDurationMins: nil, resetsAt: nil).remainingPercent)
        XCTAssertNil(CodexQuotaWindow(usedPercent: .infinity, windowDurationMins: nil, resetsAt: nil).remainingPercent)
    }

    func testMultiBucketResponseTakesPrecedenceAndIsNotMerged() throws {
        let value = try limits(#"{"rateLimits":{"primary":{"usedPercent":90}},"rateLimitsByLimitId":{"other":{"primary":{"usedPercent":55}},"codex":{"primary":{"usedPercent":20}}}}"#)
        XCTAssertEqual(value.buckets.map(\.id), ["codex", "other"])
        XCTAssertEqual(value.buckets[0].value.primary?.remainingPercent, 80)
        XCTAssertEqual(value.buckets[1].value.primary?.remainingPercent, 45)
    }

    func testLegacyAndEmptyResponsesPreserveUnknownWindows() throws {
        XCTAssertEqual(try limits(#"{"rateLimits":{"primary":{"usedPercent":12}}}"#).buckets.count, 1)
        let unknown = try limits(#"{"rateLimits":{"primary":null,"secondary":null},"rateLimitsByLimitId":{}}"#)
        XCTAssertNil(unknown.buckets.first?.value.primary)
        XCTAssertNil(unknown.buckets.first?.value.secondary)
        XCTAssertTrue(try limits("{}").buckets.isEmpty)
    }

    func testResetNeverAssumesQuotaRefilled() throws {
        let value = try limits(#"{"rateLimits":{"primary":{"usedPercent":100,"windowDurationMins":300,"resetsAt":1000}}}"#)
        let snapshot = CodexQuotaSnapshot(limits: value, fetchedAt: Date(timeIntervalSince1970: 999))
        XCTAssertTrue(snapshot.isStale(at: Date(timeIntervalSince1970: 1000)))
        XCTAssertEqual(value.buckets[0].value.primary?.remainingPercent, 0)
        XCTAssertTrue(CodexQuotaSnapshot(limits: try limits("{}"), fetchedAt: .distantPast).isStale(at: Date()))
    }

    func testWindowLabelsComeFromServerDuration() {
        XCTAssertEqual(CodexQuotaWindow(usedPercent: 0, windowDurationMins: 300, resetsAt: nil).durationLabel, "5 giờ")
        XCTAssertEqual(CodexQuotaWindow(usedPercent: 0, windowDurationMins: 10080, resetsAt: nil).durationLabel, "Tuần")
        XCTAssertEqual(CodexQuotaWindow(usedPercent: 0, windowDurationMins: 15, resetsAt: nil).durationLabel, "15 phút")
        XCTAssertEqual(CodexQuotaWindow(usedPercent: 0, windowDurationMins: nil, resetsAt: nil).durationLabel, "Cửa sổ hạn mức")
    }

    func testIdentityPinsBackendAccountWhenAvailable() {
        let expected = CodexIdentity(email: "same@example.test", planType: "plus", accountId: "workspace-A")
        XCTAssertFalse(expected.matches(CodexIdentity(email: "same@example.test", planType: "plus", accountId: "workspace-B")))
        XCTAssertFalse(expected.matches(CodexIdentity(email: "same@example.test", planType: "plus")))
        XCTAssertTrue(expected.matches(CodexIdentity(email: "new@example.test", planType: "pro", accountId: "workspace-A")))
        XCTAssertTrue(CodexIdentity(email: "SAME@example.test", planType: nil).matches(CodexIdentity(email: "same@example.test", planType: "plus")))
        XCTAssertFalse(CodexIdentity(email: nil, planType: nil).matches(CodexIdentity(email: nil, planType: nil)))
    }

    func testChildEnvironmentNeverImportsGlobalCredentialOverrides() {
        let env = CodexProcessConfiguration.environment(base: ["HOME": "/Users/test", "PATH": "/bin", "CODEX_HOME": "/global",
            "OPENAI_API_KEY": "private", "CODEX_API_KEY": "private", "CODEX_AUTH_TOKEN": "private"], home: URL(fileURLWithPath: "/tmp/profile-A"))
        XCTAssertEqual(env["CODEX_HOME"], "/tmp/profile-A")
        XCTAssertEqual(env["HOME"], "/Users/test")
        XCTAssertNil(env["OPENAI_API_KEY"])
        XCTAssertNil(env["CODEX_API_KEY"])
        XCTAssertNil(env["CODEX_AUTH_TOKEN"])
        XCTAssertTrue(CodexProcessConfiguration.arguments.contains("cli_auth_credentials_store=\"file\""))
    }

    func testLoginURLRequiresOfficialHTTPSOrigin() throws {
        XCTAssertNoThrow(try CodexProcessConfiguration.validatedLoginURL("https://auth.openai.com/authorize?state=fixture"))
        XCTAssertNoThrow(try CodexProcessConfiguration.validatedLoginURL("https://chatgpt.com/authorize"))
        for url in ["http://auth.openai.com/", "https://auth.openai.com.evil.test/", "file:///tmp/login", "https://user@auth.openai.com/", "https://auth.openai.com:8443/"] {
            XCTAssertThrowsError(try CodexProcessConfiguration.validatedLoginURL(url))
        }
    }

    func testOldMetadataDecodesWithoutConnectingAnyAccount() throws {
        let account = Account(name: "Existing browser profile")
        let encoder = JSONEncoder()
        let json = try JSONSerialization.jsonObject(with: encoder.encode(account)) as! [String: Any]
        XCTAssertNil(json["codexConnection"])
        let decoded = try JSONDecoder().decode(Account.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.codexConnection)
        XCTAssertEqual(decoded.id, account.id)
    }
}

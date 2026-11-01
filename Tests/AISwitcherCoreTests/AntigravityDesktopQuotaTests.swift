import XCTest
@testable import AISwitcherCore
@testable import AISwitcher

final class AntigravityDesktopQuotaTests: XCTestCase {
    private func status(_ email: String = "desktop@example.test") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["userStatus":["email":email,"planStatus":["planInfo":["planName":"Google AI Pro"]]]])
    }
    private var quota: Data { Data(#"{"response":{"groups":[{"displayName":"Gemini models","buckets":[{"bucketId":"gemini-weekly","displayName":"Weekly Limit Remaining","window":"weekly","remainingFraction":0.99,"resetTime":"2026-11-03T00:00:00Z"}]},{"displayName":"Claude and ChatGPT models","buckets":[{"bucketId":"3p-weekly","window":"weekly","remainingFraction":0.91}]}]}}"#.utf8) }
    func testNativeDesktopIdentityPlanAndIndependentQuotaGroups() throws {
        let status = try status()
        let value = try AntigravityDesktopQuota.connection(statusBefore: status, quota: quota, statusAfter: status, emailHint: "")
        XCTAssertEqual(value.identity.email,"desktop@example.test")
        XCTAssertEqual(value.identity.planType,"Google AI Pro")
        XCTAssertEqual(value.providerSessionKind,AntigravityLaunch.desktopQuotaSessionKind)
        let rows = try XCTUnwrap(value.quota?.limits.buckets)
        XCTAssertEqual(rows.count,2)
        for (id,name,remaining) in [("gemini-weekly","Gemini models",99.0),("3p-weekly","Claude and ChatGPT models",91.0)] {
            let row = try XCTUnwrap(rows.first(where: { $0.id == id }))
            XCTAssertEqual(row.value.limitName,name)
            XCTAssertEqual(try XCTUnwrap(row.value.primary?.remainingPercent),remaining,accuracy:0.001)
        }
        var profile = Account(name:"Desktop",agent:.antigravity,antigravityUsesPrivateHome:true)
        profile.providerQuotaConnection = value
        XCTAssertNotNil(profile.displayedCodexConnection?.quota)
    }
    func testSignedOutChangedAccountAndInvalidQuotaNeverBecomeAFullQuota() throws {
        XCTAssertThrowsError(try AntigravityDesktopQuota.identity(Data(#"{"userStatus":{}}"#.utf8)))
        XCTAssertThrowsError(try AntigravityDesktopQuota.connection(statusBefore: status(), quota: quota, statusAfter: status("other@example.test"), emailHint:""))
        XCTAssertThrowsError(try AntigravityDesktopQuota.connection(statusBefore: status(), quota: quota, statusAfter: status(), emailHint:"wrong@example.test"))
        let noQuota = try AntigravityDesktopQuota.connection(statusBefore: status(), quota: Data(#"{"response":{"groups":[]}}"#.utf8), statusAfter: status(), emailHint:"")
        XCTAssertNil(noQuota.quota)
        XCTAssertEqual(noQuota.identity.email,"desktop@example.test")
        XCTAssertThrowsError(try AntigravityDesktopQuota.connection(statusBefore: status(), quota: Data(#"{"response":{"groups":[{"buckets":[{"bucketId":"x","remainingFraction":true}]}]}}"#.utf8), statusAfter: status(), emailHint:""))
    }
    @MainActor
    func testExistingLoggedInDesktopReturnsEmailAndQuotaWithoutCLIWhenEnabled() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let root = env["AISWITCHER_TEST_ANTIGRAVITY_DESKTOP_ROOT"], let raw = env["AISWITCHER_TEST_ANTIGRAVITY_DESKTOP_ID"], let id = UUID(uuidString: raw) else { throw XCTSkip("Explicit read-only opt in for an existing Desktop session") }
        let repo = ProfileRepository(root: URL(fileURLWithPath:root))
        let profile = try XCTUnwrap(repo.load().accounts.first(where: { $0.id == id && $0.usesIsolatedAntigravity }))
        let service = AntigravityDesktopQuotaService(applications: AgentApplicationService(repository: repo), repository: repo)
        let value = try await service.read(profile)
        XCTAssertTrue(value.identity.email?.contains("@") == true)
        XCTAssertNotNil(value.quota)
        XCTAssertEqual(value.providerSessionKind,AntigravityLaunch.desktopQuotaSessionKind)
    }
}

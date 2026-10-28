import XCTest
import WebKit
@testable import AISwitcher
@testable import AISwitcherCore

final class ClaudeWebAccountTests: XCTestCase {
    private let accountID = "12121212-1212-4212-8212-121212121212"
    private let orgID = "34343434-3434-4434-8434-343434343434"
    private func metadata(_ organizations: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["state": "ok", "account": ["uuid": accountID, "email_address": "fixture@example.test"], "organizations": organizations])
    }
    func testFreeIsVerifiedFromAccountMetadataWithoutQuota() throws {
        let value = try ClaudeWebAccount.parse(metadata([["uuid": orgID, "capabilities": ["chat"], "billing_type": NSNull()]]))
        XCTAssertEqual(value.identity.email, "fixture@example.test")
        XCTAssertEqual(value.identity.planType, "free")
        XCTAssertEqual(value.organizationID, orgID)
    }
    func testExplicitPlanAndPaidEntitlementsTakePrecedence() throws {
        XCTAssertEqual(try ClaudeWebAccount.parse(metadata([["uuid": orgID, "plan_display_name": "Claude Free"]])).identity.planType, "free")
        XCTAssertEqual(try ClaudeWebAccount.parse(metadata([["uuid": orgID, "capabilities": ["chat", "claude_pro"], "billing_type": NSNull()]])).identity.planType, "pro")
        XCTAssertEqual(try ClaudeWebAccount.parse(metadata([["uuid": orgID, "capabilities": ["chat", "claude_max"]]])).identity.planType, "max")
    }
    func testUnknownPlanAndMultipleOrganizationsAreNotGuessed() throws {
        XCTAssertNil(try ClaudeWebAccount.parse(metadata([["uuid": orgID, "capabilities": ["chat"]]])).identity.planType)
        let two: [[String: Any]] = [["uuid": orgID, "plan_display_name": "Free"], ["uuid": accountID, "plan_display_name": "Pro"]]
        let value = try ClaudeWebAccount.parse(metadata(two))
        XCTAssertNil(value.organizationID);XCTAssertNil(value.identity.planType)
    }
    func testSignedOutAndWrongEmailCannotBecomeVerifiedIdentity() throws {
        XCTAssertThrowsError(try ClaudeWebAccount.parse(Data(#"{"state":"signedOut"}"#.utf8))) { XCTAssertEqual($0 as? ProviderQuotaError, .signedOut) }
        XCTAssertThrowsError(try ClaudeWebAccount.parse(metadata([]), emailHint: "other@example.test")) { XCTAssertEqual($0 as? ProviderQuotaError, .identityChanged) }
        XCTAssertThrowsError(try ClaudeWebAccount.parse(Data(#"{"state":"ok","account":{"email_address":"fixture@example.test"}}"#.utf8)))
    }
    @MainActor
    func testWebStoresAreStableAndSeparateBetweenProfilesAndManagerRoots() {
        let root = URL(fileURLWithPath: "/tmp/web-fixture")
        let a = UUID(), b = UUID()
        let id = ClaudeWebAccountService.storeIdentifier(root: root, accountID: a)
        XCTAssertEqual(id, ClaudeWebAccountService.storeIdentifier(root: root, accountID: a))
        XCTAssertNotEqual(id, ClaudeWebAccountService.storeIdentifier(root: root, accountID: b))
        XCTAssertNotEqual(id, ClaudeWebAccountService.storeIdentifier(root: URL(fileURLWithPath: "/tmp/another-manager"), accountID: a))
    }
    func testIdentityOnlyWebMetadataRoundTripsWithoutInventingQuota() throws {
        let original = CodexConnection(identity: .init(email: "fixture@example.test", planType: "free"), identityFetchedAt: Date(timeIntervalSince1970: 1000), providerSessionKind: "claudeWeb")
        let copy = try JSONDecoder().decode(CodexConnection.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(copy, original);XCTAssertNil(copy.quota)
        let old = try JSONDecoder().decode(CodexConnection.self, from: Data(#"{"identity":{"email":"fixture@example.test"}}"#.utf8))
        XCTAssertNil(old.providerSessionKind);XCTAssertNil(old.identityFetchedAt)
    }
    @MainActor
    func testActualWebKitProbeReturnsOnlyAllowlistedMetadataAndNoSecrets() async throws {
        _ = NSApplication.shared
        let config = WKWebViewConfiguration();config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .init(x: 0, y: 0, width: 600, height: 500), configuration: config)
        web.loadHTMLString("<html><body>Fixture</body></html>", baseURL: URL(string: "https://claude.ai/"))
        for _ in 0..<100 { if !web.isLoading && web.url != nil { break };try await Task.sleep(nanoseconds: 100_000_000) }
        let fake = #"globalThis.fetch = async path => ({status:200,ok:true,json:async()=>({uuid:'12121212-1212-4212-8212-121212121212',email_address:'fixture@example.test',session_key:'never-forward-this-secret',memberships:[{organization:{uuid:'34343434-3434-4434-8434-343434343434',plan_display_name:'Free',api_key:'never-forward-this-secret'}}]})}); true;"#
        _ = try await web.evaluateJavaScript(fake)
        let raw = try await web.callAsyncJavaScript(try ClaudeWebAccount.probeScript, arguments: [:], in: nil, contentWorld: .page)
        let text = try XCTUnwrap(raw as? String)
        XCTAssertFalse(text.contains("never-forward-this-secret"));XCTAssertFalse(text.contains("session_key"));XCTAssertFalse(text.contains("api_key"))
        XCTAssertEqual(try ClaudeWebAccount.parse(Data(text.utf8)).identity.planType, "free")
        web.stopLoading()
    }
}

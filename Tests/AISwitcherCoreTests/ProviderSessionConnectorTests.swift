import XCTest
@testable import AISwitcherCore

@MainActor
final class ProviderSessionConnectorTests: XCTestCase {
    private var connection: CodexConnection { .init(identity: .init(email: "fixture@example.test", planType: nil)) }

    func testAlreadySignedInConnectReadsWithoutOpeningLogin() async throws {
        var reads = 0, logins = 0, pauses = 0
        let result = try await ProviderSessionConnector.connect(read: { reads += 1;return self.connection }, signIn: { logins += 1 }, pause: { pauses += 1 })
        XCTAssertEqual(result.identity.email, "fixture@example.test")
        XCTAssertEqual(reads, 1);XCTAssertEqual(logins, 0);XCTAssertEqual(pauses, 0)
    }
    func testSignedOutConnectOpensLoginOnceAndWaitsForAuthenticatedRead() async throws {
        var reads = 0, logins = 0
        let result = try await ProviderSessionConnector.connect(read: {
            reads += 1
            if reads < 3 { throw ProviderQuotaError.signedOut }
            return self.connection
        }, signIn: { logins += 1 }, pause: {})
        XCTAssertEqual(result.identity.email, "fixture@example.test")
        XCTAssertEqual(reads, 3);XCTAssertEqual(logins, 1)
    }
    func testNonAuthenticationFailuresNeverStartLogin() async {
        for error in [ProviderQuotaError.unavailable, .cliMissing, .cliOutdated, .identityChanged, .timeout] {
            var logins = 0
            do {
                _ = try await ProviderSessionConnector.connect(read: { throw error }, signIn: { logins += 1 }, pause: {})
                XCTFail("Expected failure")
            } catch let actual { XCTAssertEqual(actual as? ProviderQuotaError, error) }
            XCTAssertEqual(logins, 0)
        }
    }
    func testFailedLoginLaunchDoesNotPollOrDiscardItsError() async {
        var reads = 0, pauses = 0
        do {
            _ = try await ProviderSessionConnector.connect(read: { reads += 1;throw ProviderQuotaError.signedOut }, signIn: { throw ProviderQuotaError.cliMissing }, pause: { pauses += 1 })
            XCTFail("Expected failure")
        } catch { XCTAssertEqual(error as? ProviderQuotaError, .cliMissing) }
        XCTAssertEqual(reads, 1);XCTAssertEqual(pauses, 0)
    }
    func testUnfinishedLoginIsBoundedAndNeverRelaunchesTerminal() async {
        var reads = 0, logins = 0
        do {
            _ = try await ProviderSessionConnector.connect(read: { reads += 1;throw ProviderQuotaError.signedOut }, signIn: { logins += 1 }, maxAttempts: 3, pause: {})
            XCTFail("Expected failure")
        } catch { XCTAssertEqual(error as? ProviderQuotaError, .signedOut) }
        XCTAssertEqual(reads, 4);XCTAssertEqual(logins, 1)
    }
    func testCancellationDuringLoginWaitStopsPolling() async {
        var reads = 0, logins = 0
        do {
            _ = try await ProviderSessionConnector.connect(read: { reads += 1;throw ProviderQuotaError.signedOut }, signIn: { logins += 1 }, pause: { throw CancellationError() })
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(reads, 1);XCTAssertEqual(logins, 1)
    }
    func testCancellationBeforeLoginCannotLaunchTerminal() async {
        var logins = 0
        let task = Task {
            try await ProviderSessionConnector.connect(read: {
                withUnsafeCurrentTask { $0?.cancel() }
                throw ProviderQuotaError.signedOut
            }, signIn: { logins += 1 }, pause: {})
        }
        do { _ = try await task.value;XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(logins, 0)
    }
    func testAntigravityAuthMarkersDoNotConfuseQuotaOrNetworkFailuresWithLogin() {
        for text in ["Error: authentication required. Run 'agy' to log in.", "Print mode: not logged in and no controlling terminal; cannot complete interactive login", "not authenticated: no stored credentials found", "You are not logged into Antigravity."] {
            XCTAssertTrue(ProviderCLIConfiguration.antigravityRequiresSignIn(Data(text.utf8)))
        }
        for text in ["quota remaining 0%", "network timeout", "permission denied", "Print mode: not authenticated, trying silent auth"] {
            XCTAssertFalse(ProviderCLIConfiguration.antigravityRequiresSignIn(Data(text.utf8)))
        }
    }
}

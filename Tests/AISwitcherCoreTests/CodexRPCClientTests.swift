import XCTest
@testable import AISwitcherCore

final class CodexRPCClientTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AI Switcher RPC \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func client(_ mode: String, timeout: TimeInterval = 2) throws -> CodexRPCClient {
        let home = root.appendingPathComponent(mode)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let fixture = Bundle.module.url(forResource: "codex_app_server", withExtension: "py", subdirectory: "Fixtures")!
        return CodexRPCClient(executable: URL(fileURLWithPath: "/usr/bin/python3"), home: home,
                              arguments: ["-u", fixture.path], timeout: timeout)
    }

    func testFragmentedJSONLAndCorrectRemainingValue() async throws {
        let client = try client("fragmented")
        try await client.start()
        let identity = try await client.readIdentity()
        let limits = try await client.readLimits()
        await client.stop()
        XCTAssertEqual(identity.email, "fragmented@example.test")
        XCTAssertEqual(limits.buckets.first?.value.primary?.remainingPercent, 77)
        let methods = try String(contentsOf: root.appendingPathComponent("fragmented/methods.txt"))
        XCTAssertEqual(methods.split(separator: "\n").map(String.init), ["initialize", "initialized", "account/read", "account/rateLimits/read"])
    }

    func testSeparateHomesCannotMixAccountResponses() async throws {
        let a = try client("account-A"), b = try client("account-B")
        try await a.start()
        try await b.start()
        let first = try await a.readIdentity(), second = try await b.readIdentity()
        await a.stop()
        await b.stop()
        XCTAssertEqual(first.email, "account-A@example.test")
        XCTAssertEqual(second.email, "account-B@example.test")
        XCTAssertNotEqual(first, second)
    }

    func testLoginNotificationCanArriveBeforeRequestResponse() async throws {
        let client = try client("login")
        try await client.start()
        let login = try await client.startLogin()
        try await client.waitForLogin(login.loginId, timeout: 1)
        await client.stop()
        XCTAssertEqual(login.loginId, "fixture-login")
    }

    func testNotSignedInDoesNotReturnAnotherAccount() async throws {
        let client = try client("unauthed")
        try await client.start()
        do { _ = try await client.readIdentity(); XCTFail("Expected sign-in requirement") }
        catch { XCTAssertEqual(error as? CodexQuotaError, .notSignedIn) }
        await client.stop()
    }

    func testTimeoutCompletesInsteadOfHanging() async throws {
        let client = try client("timeout", timeout: 0.2)
        try await client.start()
        do { _ = try await client.readLimits(); XCTFail("Expected timeout") }
        catch { XCTAssertEqual(error as? CodexQuotaError, .timeout) }
        await client.stop()
    }

    func testCancellationCompletesPendingRequest() async throws {
        let client = try client("timeout", timeout: 5)
        try await client.start()
        let read = Task { try await client.readLimits() }
        try await Task.sleep(nanoseconds: 40_000_000)
        read.cancel()
        do { _ = try await read.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        await client.stop()
    }

    func testProcessExitFailsPendingRequest() async throws {
        let client = try client("exit")
        try await client.start()
        do { _ = try await client.readLimits(); XCTFail("Expected closed connection") }
        catch { XCTAssertEqual(error as? CodexQuotaError, .disconnected) }
        await client.stop()
    }

    func testRawServerErrorsNeverReachUserMessages() async throws {
        let client = try client("error")
        try await client.start()
        do { _ = try await client.readLimits(); XCTFail("Expected RPC error") }
        catch {
            XCTAssertEqual(error as? CodexQuotaError, .rpc(-32001))
            XCTAssertFalse(error.localizedDescription.contains("private-detail"))
        }
        await client.stop()
    }
}

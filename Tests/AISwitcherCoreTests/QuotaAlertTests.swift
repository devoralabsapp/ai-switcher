import XCTest
@testable import AISwitcherCore

final class QuotaAlertTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let id = UUID()
    private func account(_ used: Double?, fetched: Date, reset: Int = 2_000_000_500, email: String = "a@example.test",
                         mode: LaunchMode = .desktop) throws -> Account {
        let object: [String: Any] = ["rateLimitsByLimitId": ["codex": ["primary": ["usedPercent": used.map { $0 as Any } ?? NSNull(), "windowDurationMins": 300, "resetsAt": reset]],
                                                                  "other": ["secondary": ["usedPercent": 1, "windowDurationMins": 10080]]]]
        let limits = try JSONDecoder().decode(CodexRateLimits.self, from: JSONSerialization.data(withJSONObject: object))
        let connection = CodexConnection(identity: CodexIdentity(email: email, planType: "plus"), quota: .init(limits: limits, fetchedAt: fetched))
        return Account(id: id, name: "Fixture", codexConnection: mode == .browser ? connection : nil, launchMode: mode,
                       desktopCodexConnection: mode == .desktop ? connection : nil)
    }
    private func evaluate(_ tracker: inout QuotaAlertTracker, _ account: Account, settings: QuotaAlertSettings = .init(enabled: true), at: Date? = nil) -> [QuotaAlertEvent] {
        tracker.evaluate(account: account, snapshot: account.displayedCodexConnection!.quota!, settings: settings, now: at ?? now)
    }
    func testLowAlertsOnlyOnceAndRecoveryNeedsARealNewReading() throws {
        var tracker = QuotaAlertTracker()
        let low = try account(80, fetched: now)
        XCTAssertEqual(evaluate(&tracker, low).map(\.kind), [.low])
        XCTAssertTrue(evaluate(&tracker, low).isEmpty)
        let stillLow = try account(90, fetched: now.addingTimeInterval(1))
        XCTAssertTrue(evaluate(&tracker, stillLow, at: now.addingTimeInterval(1)).isEmpty)
        let expired = try account(0, fetched: now.addingTimeInterval(2), reset: 1_999_999_900)
        XCTAssertTrue(evaluate(&tracker, expired, at: now.addingTimeInterval(2)).isEmpty)
        let recovered = try account(40, fetched: now.addingTimeInterval(3))
        XCTAssertEqual(evaluate(&tracker, recovered, at: now.addingTimeInterval(3)).map(\.kind), [.recovered])
        XCTAssertTrue(evaluate(&tracker, recovered, at: now.addingTimeInterval(3)).isEmpty)
        let againLow = try account(95, fetched: now.addingTimeInterval(4))
        XCTAssertEqual(evaluate(&tracker, againLow, at: now.addingTimeInterval(4)).map(\.kind), [.low])
    }
    func testDisabledMissingOrStaleQuotaDoesNotNotifyOrChangeBaseline() throws {
        var tracker = QuotaAlertTracker()
        XCTAssertTrue(evaluate(&tracker, try account(99, fetched: now), settings: .init()).isEmpty)
        XCTAssertTrue(evaluate(&tracker, try account(nil, fetched: now)).isEmpty)
        XCTAssertTrue(evaluate(&tracker, try account(99, fetched: now.addingTimeInterval(-400))).isEmpty)
        XCTAssertEqual(evaluate(&tracker, try account(99, fetched: now)).count, 1)
    }
    func testPersistenceDedupesAndIdentityChangeCannotInventRecovery() throws {
        var tracker = QuotaAlertTracker()
        _ = evaluate(&tracker, try account(95, fetched: now))
        tracker = try JSONDecoder().decode(QuotaAlertTracker.self, from: JSONEncoder().encode(tracker))
        XCTAssertTrue(evaluate(&tracker, try account(95, fetched: now.addingTimeInterval(1)), at: now.addingTimeInterval(1)).isEmpty)
        XCTAssertTrue(evaluate(&tracker, try account(1, fetched: now.addingTimeInterval(2), email: "different@example.test"), at: now.addingTimeInterval(2)).isEmpty)
        XCTAssertEqual(evaluate(&tracker, try account(99, fetched: now.addingTimeInterval(3), mode: .browser), at: now.addingTimeInterval(3)).map(\.kind), [.low])
    }
    func testRecoveryCanBeMutedAndThresholdChangesStartANewBaseline() throws {
        var tracker = QuotaAlertTracker()
        _ = evaluate(&tracker, try account(90, fetched: now))
        XCTAssertTrue(evaluate(&tracker, try account(40, fetched: now.addingTimeInterval(1)), settings: .init(enabled: true, notifyRecovery: false), at: now.addingTimeInterval(1)).isEmpty)
        XCTAssertEqual(evaluate(&tracker, try account(40, fetched: now.addingTimeInterval(2)), settings: .init(enabled: true, threshold: 70), at: now.addingTimeInterval(2)).map(\.kind), [.low])
    }
    func testSettingsAndTrackerPersistWithCompatibleDefaults() throws {
        let suite = "ai-switcher-alert-tests.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppPreferencesStore(defaults: defaults)
        XCTAssertEqual(store.load().quotaAlerts, QuotaAlertSettings())
        var settings = store.load()
        settings.quotaAlerts = .init(enabled: true, threshold: 12, notifyRecovery: false)
        store.save(settings)
        XCTAssertEqual(store.load().quotaAlerts, settings.quotaAlerts)
        var tracker = QuotaAlertTracker()
        let low = try account(99, fetched: now)
        _ = evaluate(&tracker, low)
        store.saveAlertTracker(tracker)
        tracker = store.loadAlertTracker()
        XCTAssertTrue(evaluate(&tracker, low).isEmpty)
        tracker.retainAccounts([])
        XCTAssertEqual(evaluate(&tracker, low).count, 1)
        XCTAssertEqual(QuotaAlertSettings(threshold: 200).threshold, 95)
        XCTAssertEqual(QuotaAlertSettings(threshold: -1).threshold, 1)
    }
}

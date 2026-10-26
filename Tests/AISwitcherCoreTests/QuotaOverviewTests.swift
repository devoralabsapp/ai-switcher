import XCTest
@testable import AISwitcherCore

final class QuotaOverviewTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func account(_ name: String, used: Double? = 20, secondaryUsed: Double? = 40,
                         reset: Int = 2_000_000_100, age: TimeInterval = 0, mode: LaunchMode = .desktop) throws -> Account {
        let primary: [String: Any] = ["usedPercent": used.map { $0 as Any } ?? NSNull(), "windowDurationMins": 300, "resetsAt": reset]
        let secondary: [String: Any] = ["usedPercent": secondaryUsed.map { $0 as Any } ?? NSNull(), "windowDurationMins": 10080, "resetsAt": reset + 100]
        let object: [String: Any] = ["rateLimits": ["primary": primary, "secondary": secondary]]
        let limits = try JSONDecoder().decode(CodexRateLimits.self, from: JSONSerialization.data(withJSONObject: object))
        let connection = CodexConnection(identity: CodexIdentity(email: "fixture@example.test", planType: "plus"),
            quota: CodexQuotaSnapshot(limits: limits, fetchedAt: now.addingTimeInterval(-age)))
        return Account(name: name, codexConnection: mode == .browser ? connection : nil, launchMode: mode,
                       desktopCodexConnection: mode == .desktop ? connection : nil)
    }

    func testOldProfilesRetainOpenActionAndDoNotAutomaticallyConnect() throws {
        let old = Data(#"{"id":"22222222-2222-2222-2222-222222222222","name":"Old","emailHint":"","browser":"chrome","color":"mint","isFavorite":false,"createdAt":0}"#.utf8)
        let profile = try JSONDecoder().decode(Account.self, from: old)
        XCTAssertEqual(profile.effectiveDefaultAction, .openDesktop)
        XCTAssertFalse(profile.automaticallyConnects)
        var edited = profile
        edited.defaultAction = .connectSession
        edited.connectOnStartup = true
        XCTAssertEqual(try JSONDecoder().decode(Account.self, from: JSONEncoder().encode(edited)), edited)
        edited.launchMode = .browser
        XCTAssertFalse(edited.automaticallyConnects)
        XCTAssertEqual(edited.effectiveDefaultAction, .openDesktop)
    }

    func testQuotaOnlyAndSortingPreferencesPersistWithIndependentFallbacks() {
        let suite = "ai-switcher-overview.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppPreferencesStore(defaults: defaults)
        let preferences = AppPreferences(language: .english, theme: .playfulRetro, quotaOnlyMode: true,
            workspaceLayout: .quotaTable, quotaSortKey: .secondaryRemaining, quotaSortAscending: false)
        store.save(preferences)
        XCTAssertEqual(AppPreferencesStore(defaults: UserDefaults(suiteName: suite)!).load(), preferences)
        defaults.set("unknown", forKey: "ui.workspaceLayout")
        defaults.set("unknown", forKey: "ui.quotaSortKey")
        defaults.set("unknown", forKey: "ui.workspaceLayoutBeforeQuotaOnly")
        XCTAssertEqual(store.load().workspaceLayout, .cards)
        XCTAssertEqual(store.load().quotaSortKey, .name)
        XCTAssertTrue(store.load().quotaOnlyMode)
        XCTAssertFalse(store.load().quotaSortAscending)
    }

    func testLegacyDisabledQuotaTableIsRepairedOnceWithoutLosingOtherPreferences() {
        let suite = "ai-switcher-layout-migration.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "ui.quotaOnlyMode")
        defaults.set("quotaTable", forKey: "ui.workspaceLayout")
        defaults.set("quotaTable", forKey: "ui.workspaceLayoutBeforeQuotaOnly")
        defaults.set("en", forKey: "ui.language")
        defaults.set("playfulRetro", forKey: "ui.theme")
        defaults.set("claude", forKey: "ui.agentFilter")
        let store = AppPreferencesStore(defaults: defaults)
        var repaired = store.load()
        XCTAssertEqual(repaired.workspaceLayout, .cards)
        XCTAssertEqual(defaults.string(forKey: "ui.workspaceLayout"), "cards")
        XCTAssertNil(defaults.object(forKey: "ui.workspaceLayoutBeforeQuotaOnly"))
        XCTAssertEqual(repaired.language, .english)
        XCTAssertEqual(repaired.theme, .playfulRetro)
        XCTAssertEqual(repaired.agentFilter, .claude)
        // An explicit layout choice made after repair remains available.
        repaired.workspaceLayout = .quotaTable
        store.save(repaired)
        XCTAssertEqual(AppPreferencesStore(defaults: UserDefaults(suiteName: suite)!).load(), repaired)
    }

    func testSortingKeepsMissingStaleAndFailedValuesLastInBothDirections() throws {
        let low = try account("Low", used: 90), high = try account("High", used: 10)
        let stale = try account("Stale", used: 99, age: 361), failed = try account("Failed", used: 99)
        let missing = Account(name: "Missing")
        let all = [missing, failed, stale, high, low]
        for ascending in [true, false] {
            let sorted = AccountQuotaOverview.sorted(all, key: .primaryRemaining, ascending: ascending, now: now, failedIDs: [failed.id])
            XCTAssertEqual(Array(sorted.prefix(2).map(\.id)), ascending ? [low.id, high.id] : [high.id, low.id])
            XCTAssertEqual(Set(sorted.suffix(3).map(\.id)), Set([stale.id, failed.id, missing.id]))
        }
    }

    func testExpiredResetDoesNotInventRemainingQuotaOrFutureReset() throws {
        let expired = try account("Expired", reset: 1_999_999_000)
        let row = AccountQuotaOverview(account: expired, now: now)
        XCTAssertTrue(row.stale)
        XCTAssertNil(row.remaining(row.bucket?.primary))
        XCTAssertNil(row.remaining(row.bucket?.secondary))
        XCTAssertNil(row.nextReset)
        let unknown = AccountQuotaOverview(account: try account("Unknown", used: nil), now: now)
        XCTAssertNil(unknown.remaining(unknown.bucket?.primary))
    }

    func testBothWindowsResetAndUpdatedSortUseActualValues() throws {
        let a = try account("A", secondaryUsed: 90, reset: 2_000_000_200, age: 10)
        let b = try account("B", secondaryUsed: 10, reset: 2_000_000_100, age: 20, mode: .browser)
        XCTAssertEqual(AccountQuotaOverview.sorted([a,b], key: .secondaryRemaining, ascending: true, now: now).map(\.id), [a.id,b.id])
        XCTAssertEqual(AccountQuotaOverview.sorted([a,b], key: .nextReset, ascending: true, now: now).map(\.id), [b.id,a.id])
        XCTAssertEqual(AccountQuotaOverview.sorted([a,b], key: .lastUpdated, ascending: false, now: now).map(\.id), [a.id,b.id])
        XCTAssertEqual(AccountQuotaOverview.sorted([a,b], key: .name, ascending: false, now: now).map(\.id), [b.id,a.id])
    }

    func testMultipleLimitGroupsStaySeparateAndPreferCodex() throws {
        let data = Data(#"{"rateLimitsByLimitId":{"other":{"primary":{"usedPercent":99}},"codex":{"primary":{"usedPercent":20}}}}"#.utf8)
        let limits = try JSONDecoder().decode(CodexRateLimits.self, from: data)
        let connection = CodexConnection(identity: CodexIdentity(email: nil, planType: nil), quota: .init(limits: limits, fetchedAt: now))
        let row = AccountQuotaOverview(account: Account(name: "Multi", desktopCodexConnection: connection), now: now)
        XCTAssertEqual(row.bucketCount, 2)
        XCTAssertEqual(row.bucketName, "codex")
        XCTAssertEqual(row.remaining(row.bucket?.primary), 80)
    }
}

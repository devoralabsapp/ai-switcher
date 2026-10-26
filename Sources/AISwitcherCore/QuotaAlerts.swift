import Foundation

public struct QuotaAlertSettings: Equatable, Sendable {
    public var enabled: Bool
    public var threshold: Int
    public var notifyRecovery: Bool
    public init(enabled: Bool = false, threshold: Int = 20, notifyRecovery: Bool = true) {
        self.enabled = enabled
        self.threshold = min(95, max(1, threshold))
        self.notifyRecovery = notifyRecovery
    }
}

public struct QuotaAlertEvent: Equatable, Sendable {
    public enum Kind: String, Sendable { case low, recovered }
    public let accountID: UUID
    public let bucket: String
    public let window: CodexQuotaWindow
    public let remaining: Double
    public let kind: Kind
}

/// Persists only observed threshold state. Reset dates never schedule a recovery.
public struct QuotaAlertTracker: Codable {
    private struct Observation: Codable {
        let identity: CodexIdentity
        let fetchedAt: Date
        let low: Bool
        let threshold: Int
    }
    private var observations: [String: Observation] = [:]
    public init() {}

    public mutating func evaluate(account: Account, snapshot: CodexQuotaSnapshot, settings: QuotaAlertSettings,
                                  now: Date = Date()) -> [QuotaAlertEvent] {
        guard settings.enabled, !snapshot.isStale(at: now), let identity = account.displayedCodexConnection?.identity,
              identity.accountId != nil || !(identity.email ?? "").isEmpty else { return [] }
        var events: [QuotaAlertEvent] = []
        for bucket in snapshot.limits.buckets {
            for (slot, window) in [("primary", bucket.value.primary), ("secondary", bucket.value.secondary)] {
                guard let window, !window.resetHasPassed(at: now), let remaining = window.remainingPercent else { continue }
                let key = account.id.uuidString + ":" + account.effectiveLaunchMode.rawValue + ":" + bucket.id + ":" + slot + ":" + String(window.windowDurationMins ?? 0)
                let previous = observations[key]
                let same = previous.map { $0.identity.matches(identity) && $0.threshold == settings.threshold } ?? false
                if same, let previous, snapshot.fetchedAt <= previous.fetchedAt { continue }
                let low = remaining <= Double(settings.threshold)
                if low && (!same || previous?.low == false) {
                    events.append(.init(accountID: account.id, bucket: bucket.value.limitName ?? bucket.id,
                                        window: window, remaining: remaining, kind: .low))
                } else if !low && same && previous?.low == true && settings.notifyRecovery {
                    events.append(.init(accountID: account.id, bucket: bucket.value.limitName ?? bucket.id,
                                        window: window, remaining: remaining, kind: .recovered))
                }
                observations[key] = .init(identity: identity, fetchedAt: snapshot.fetchedAt, low: low, threshold: settings.threshold)
            }
        }
        return events
    }

    public mutating func retainAccounts(_ ids: Set<UUID>) {
        let prefixes = Set(ids.map(\.uuidString))
        observations = observations.filter { prefixes.contains(String($0.key.prefix(36))) }
    }
}

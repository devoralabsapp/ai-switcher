import Foundation

public enum AccountAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case openDesktop, connectSession
    public var id: String { rawValue }
    public var title: String { self == .connectSession ? L10n.text("Connect in background") : L10n.text("Open ChatGPT") }
}

public enum WorkspaceLayout: String, CaseIterable, Identifiable, Sendable {
    case cards, quotaTable
    public var id: String { rawValue }
    public var title: String { self == .cards ? L10n.text("Account cards") : L10n.text("Quota overview") }
}

public enum QuotaSortKey: String, CaseIterable, Identifiable, Sendable {
    case name, primaryRemaining, secondaryRemaining, nextReset, lastUpdated
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .name: return L10n.text("Account")
        case .primaryRemaining: return L10n.text("Short window")
        case .secondaryRemaining: return L10n.text("Long window")
        case .nextReset: return L10n.text("Next reset")
        case .lastUpdated: return L10n.text("Last updated")
        }
    }
}

public enum SessionStatus: String, CaseIterable, Sendable {
    case disconnected, connecting, opening, closing, background, desktopOpen, browserOpen, applicationRunning, needsSignIn, connectionFailed
    public var title: String {
        switch self {
        case .disconnected: return L10n.text("Disconnected")
        case .connecting: return L10n.text("Connecting session…")
        case .opening: return L10n.text("Opening…")
        case .closing: return L10n.text("Closing session…")
        case .background: return L10n.text("Running in background")
        case .desktopOpen: return L10n.text("Desktop window open")
        case .browserOpen: return L10n.text("Browser running")
        case .applicationRunning: return L10n.text("Application running")
        case .needsSignIn: return L10n.text("Sign-in required")
        case .connectionFailed: return L10n.text("Connection failed")
        }
    }
}

/// One representative bucket per account; separate limit groups are never added together.
public struct AccountQuotaOverview {
    public let snapshot: CodexQuotaSnapshot?
    public let bucket: CodexQuotaBucket?
    public let bucketName: String?
    public let bucketCount: Int
    public let stale: Bool
    public let now: Date

    public init(account: Account, now: Date = Date(), readFailed: Bool = false) {
        let snapshot = account.displayedCodexConnection?.quota
        self.snapshot = snapshot
        let buckets = snapshot?.limits.buckets ?? []
        self.bucket = buckets.first?.value
        self.bucketName = buckets.first.map { $0.value.limitName ?? $0.id }
        self.bucketCount = buckets.count
        self.stale = snapshot.map { readFailed || $0.isStale(at: now) } ?? false
        self.now = now
    }

    public func remaining(_ window: CodexQuotaWindow?) -> Double? {
        guard let window, !window.resetHasPassed(at: now) else { return nil }
        return window.remainingPercent
    }

    public var nextReset: Date? {
        [bucket?.primary, bucket?.secondary].compactMap { $0?.resetDate }.filter { $0 > now }.min()
    }

    public static func sorted(_ accounts: [Account], key: QuotaSortKey, ascending: Bool,
                              now: Date = Date(), failedIDs: Set<UUID> = []) -> [Account] {
        let summaries = Dictionary(uniqueKeysWithValues: accounts.map {
            ($0.id, Self(account: $0, now: now, readFailed: failedIDs.contains($0.id)))
        })
        func value(_ summary: Self) -> Double? {
            switch key {
            case .name: return nil
            case .primaryRemaining: return summary.stale ? nil : summary.remaining(summary.bucket?.primary)
            case .secondaryRemaining: return summary.stale ? nil : summary.remaining(summary.bucket?.secondary)
            case .nextReset: return summary.stale ? nil : summary.nextReset?.timeIntervalSince1970
            case .lastUpdated: return summary.snapshot?.fetchedAt.timeIntervalSince1970
            }
        }
        return accounts.sorted { a, b in
            if key != .name {
                let x = value(summaries[a.id]!), y = value(summaries[b.id]!)
                // Unknown or stale values stay last in both directions.
                if (x == nil) != (y == nil) { return x != nil }
                if let x, let y, x != y { return ascending ? x < y : x > y }
            }
            let order = a.name.localizedStandardCompare(b.name)
            if order != .orderedSame { return key == .name && !ascending ? order == .orderedDescending : order == .orderedAscending }
            return a.id.uuidString < b.id.uuidString
        }
    }
}

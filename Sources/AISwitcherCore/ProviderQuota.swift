import Foundation
import CoreFoundation

public enum ProviderQuotaError: LocalizedError, Equatable {
    case cliMissing, invalidExecutable, cliOutdated, signedOut, unavailable, invalidResponse, identityChanged, timeout
    public var errorDescription: String? {
        switch self {
        case .cliMissing: return L10n.text("Install Claude Code or Antigravity CLI, or select its executable in quota settings.")
        case .invalidExecutable: return L10n.text("Choose the Claude Code or Antigravity CLI file, not a Desktop .app or folder.")
        case .cliOutdated: return L10n.text("Update the provider CLI to read quota without starting a model turn.")
        case .signedOut: return L10n.text("The provider session is signed out. Choose Sign in with official CLI, then connect again.")
        case .unavailable: return L10n.text("The provider has not returned subscription quota. Previous data is kept.")
        case .invalidResponse: return L10n.text("The provider quota response could not be verified. Previous data is kept.")
        case .identityChanged: return L10n.text("The provider account does not match this profile. Verify the email before reconnecting.")
        case .timeout: return L10n.text("The provider quota request timed out. Try again.")
        }
    }
}

/// Only subscription limits are accepted. Token/cost counters and model text are never quota.
public enum ProviderQuotaParser {
    public static func parse(_ data: Data, agent: AIAgent, identity: CodexIdentity, now: Date = Date()) throws -> CodexConnection {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ProviderQuotaError.invalidResponse }
        let payload = (root["data"] as? [String: Any]) ?? root
        var buckets: [String: Any] = [:]
        func number(_ x: Any?) -> Double? {
            guard let n = x as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
            return n.doubleValue
        }
        func reset(_ value: Any?) -> Int? {
            if let n = number(value), n > 0, n < 253402300800 { return Int(n) }
            guard let s = value as? String else { return nil }
            let parser = ISO8601DateFormatter()
            parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let date = parser.date(from: s) ?? { parser.formatOptions = [.withInternetDateTime]; return parser.date(from: s) }()
            return date.map { Int($0.timeIntervalSince1970) }
        }
        func window(_ object: [String: Any], minutes: Int?, fraction: Bool = false) -> [String: Any]? {
            let raw = number(object[fraction ? "remaining_fraction" : "utilization"]) ?? (fraction ? nil : number(object["used_percentage"]))
            let amount = fraction ? number(object["remaining_amount"]) : nil
            let used: Double?
            if let raw, raw >= 0, raw <= (fraction ? 1 : 100) { used = fraction ? 100 * (1 - raw) : raw } else { used = nil }
            guard used != nil || (amount != nil && amount! >= 0) else { return nil }
            var value: [String: Any] = [:]
            if let used { value["usedPercent"] = used }
            if let amount, amount >= 0 { value["remainingAmount"] = amount }
            if let minutes { value["windowDurationMins"] = minutes }
            if let at = reset(object["resets_at"] ?? object["reset_time"]) { value["resetsAt"] = at }
            else if let seconds = number(object["reset_in_seconds"]), seconds >= 0, seconds < 31_536_000 { value["resetsAt"] = Int(now.timeIntervalSince1970 + seconds) }
            return value
        }
        if agent == .claude {
            guard payload["rate_limits_available"] as? Bool != false, let limits = payload["rate_limits"] as? [String: Any] else { throw ProviderQuotaError.unavailable }
            var main: [String: Any] = ["limitId": "claude", "limitName": "Claude"]
            if let raw = limits["five_hour"] as? [String: Any], let w = window(raw, minutes: 300) { main["primary"] = w }
            if let raw = limits["seven_day"] as? [String: Any], let w = window(raw, minutes: 10080) { main["secondary"] = w }
            if main["primary"] != nil || main["secondary"] != nil { buckets["claude"] = main }
            for (key, raw) in limits where !["five_hour", "seven_day", "extra_usage", "model_scoped"].contains(key) {
                if let raw = raw as? [String: Any], let w = window(raw, minutes: key.hasPrefix("seven_day") ? 10080 : nil) { buckets[key] = ["limitId": key, "limitName": key.replacingOccurrences(of: "_", with: " "), "primary": w] }
            }
            for (i, raw) in (limits["model_scoped"] as? [[String: Any]] ?? []).enumerated() {
                if let w = window(raw, minutes: nil) { let id = "claude-model-\(i)"; buckets[id] = ["limitId": id, "limitName": raw["display_name"] as? String ?? id, "primary": w] }
            }
        } else if agent == .antigravity {
            var rows: [(String, [String: Any])] = []
            if let command = root["command"] as? [String: Any] {
                guard command["name"] as? String == "usage", (root["num_turns"] as? Int ?? 0) == 0,
                      let body = command["data"] as? [String: Any], let groups = body["groups"] as? [[String: Any]] else { throw ProviderQuotaError.invalidResponse }
                for group in groups { for raw in group["buckets"] as? [[String: Any]] ?? [] {
                    if let id = raw["id"] as? String { rows.append((id, raw)) }
                }}
            } else if let quotas = payload["quota"] as? [String: Any] {
                rows = quotas.compactMap { key, value in (value as? [String: Any]).map { (key, $0) } }
            } else { throw ProviderQuotaError.unavailable }
            for (id, raw) in rows {
                guard id.count <= 160, raw["disabled"] as? Bool != true else { continue }
                let label = raw["window"] as? String ?? id
                let duration = label.lowercased().contains("week") || label == "7d" ? 10080 : ["5h", "5 hours", "five_hour"].contains(label.lowercased()) ? 300 : nil
                guard let w = window(raw, minutes: duration, fraction: true) else { continue }
                guard buckets[id] == nil else { throw ProviderQuotaError.invalidResponse }
                buckets[id] = ["limitId": id, "limitName": raw["name"] as? String ?? id.replacingOccurrences(of: "-", with: " "), "primary": w]
            }
        } else { throw ProviderQuotaError.invalidResponse }
        guard !buckets.isEmpty else { throw ProviderQuotaError.unavailable }
        let normalized = try JSONSerialization.data(withJSONObject: ["rateLimitsByLimitId": buckets])
        let limits = try JSONDecoder().decode(CodexRateLimits.self, from: normalized)
        return CodexConnection(identity: identity, quota: CodexQuotaSnapshot(limits: limits, fetchedAt: now))
    }
}

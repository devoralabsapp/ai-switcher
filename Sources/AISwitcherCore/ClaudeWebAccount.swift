import Foundation

/// Parses only the allowlisted account/plan metadata returned by the profile's own Claude web session.
public struct ClaudeWebAccount: Equatable, Sendable {
    public let identity: CodexIdentity
    public let organizationID: String?
    public static var probeScript: String { get throws { try String(contentsOf: Bundle.module.url(forResource: "ClaudeAccountProbe", withExtension: "js")!, encoding: .utf8) } }
    public static var usageScript: String { get throws { try String(contentsOf: Bundle.module.url(forResource: "ClaudeUsageProbe", withExtension: "js")!, encoding: .utf8) } }
    public static func parse(_ data: Data, emailHint: String = "") throws -> Self {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ProviderQuotaError.invalidResponse }
        if root["state"] as? String == "signedOut" { throw ProviderQuotaError.signedOut }
        if root["state"] as? String == "unavailable" { throw ProviderQuotaError.unavailable }
        guard root["state"] as? String == "ok", let account = root["account"] as? [String: Any],
              let email = account["email_address"] as? String, email.contains("@"), email.count <= 320,
              let id = account["uuid"] as? String, UUID(uuidString: id) != nil else { throw ProviderQuotaError.invalidResponse }
        if emailHint.contains("@"), emailHint.caseInsensitiveCompare(email) != .orderedSame { throw ProviderQuotaError.identityChanged }
        let organizations = root["organizations"] as? [[String: Any]] ?? []
        // Never silently pick a workspace when an account has multiple organizations.
        let organization = organizations.count == 1 ? organizations.first : nil
        let plan = organization.flatMap(planType) ?? namedPlan(account["subscription_type"] as? String)
        let orgID = organization?["uuid"] as? String
        return .init(identity: .init(email: email, planType: plan, accountId: id), organizationID: orgID.flatMap { UUID(uuidString: $0) == nil ? nil : $0 })
    }
    private static func namedPlan(_ value: String?) -> String? {
        guard let value = value?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        for plan in ["free", "pro", "max", "team", "enterprise"] {
            if value == plan || value == "claude " + plan { return plan }
        }
        return nil
    }
    private static func planType(_ org: [String: Any]) -> String? {
        if let plan = namedPlan(org["plan_display_name"] as? String) ?? namedPlan(org["subscription_type"] as? String) { return plan }
        let capabilities = org["capabilities"] as? [String] ?? []
        if let raven = namedPlan(org["raven_type"] as? String), ["team", "enterprise"].contains(raven) { return raven }
        for (flag, plan) in [("claude_enterprise", "enterprise"), ("claude_team", "team"), ("claude_max", "max"), ("claude_pro", "pro")] {
            if capabilities.contains(flag) { return plan }
        }
        if let raven = org["raven_type"] as? String, !raven.isEmpty { return namedPlan(raven) }
        if org["billing_type"] as? String == "free" { return "free" }
        // Explicit no-billing plus the complete chat entitlement list; quota absence alone is never Free.
        if org["billing_type"] is NSNull, capabilities.contains("chat"), !capabilities.contains(where: { flag in ["pro", "max", "team", "enterprise"].contains(where: { flag.lowercased().contains($0) }) }) { return "free" }
        return nil
    }
}

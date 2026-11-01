import Foundation

/// Only the identity and quota endpoints of the selected local Desktop backend.
public enum AntigravityDesktopQuota {
    public static func identity(_ data: Data) throws -> CodexIdentity {
        guard data.count <= 1_048_576,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let user = root["userStatus"] as? [String: Any],
              let email = user["email"] as? String, email.count <= 320,
              email.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil else { throw ProviderQuotaError.signedOut }
        let plan = ((user["planStatus"] as? [String: Any])?["planInfo"] as? [String: Any])?["planName"] as? String
        return CodexIdentity(email: email, planType: plan?.isEmpty == false ? plan : nil)
    }

    public static func connection(statusBefore: Data, quota: Data, statusAfter: Data, emailHint: String, now: Date = Date()) throws -> CodexConnection {
        let before = try identity(statusBefore), after = try identity(statusAfter)
        guard before == after, !emailHint.contains("@") || after.email?.caseInsensitiveCompare(emailHint) == .orderedSame else { throw ProviderQuotaError.identityChanged }
        guard quota.count <= 1_048_576,
              let root = try JSONSerialization.jsonObject(with: quota) as? [String: Any],
              let response = root["response"] as? [String: Any], let groups = response["groups"] as? [[String: Any]] else { throw ProviderQuotaError.invalidResponse }
        if groups.isEmpty {
            return CodexConnection(identity: after, identityFetchedAt: now, providerSessionKind: AntigravityLaunch.desktopQuotaSessionKind)
        }
        let normalized = groups.map { group -> [String: Any] in
            var result: [String: Any] = [:]
            result["name"] = group["displayName"];result["description"] = group["description"]
            result["buckets"] = (group["buckets"] as? [[String: Any]] ?? []).map { bucket -> [String: Any] in
                var value: [String: Any] = [:]
                for (native, common) in [("bucketId","id"),("displayName","name"),("window","window"),("remainingFraction","remaining_fraction"),("resetTime","reset_time")] { value[common] = bucket[native] }
                return value
            }
            return result
        }
        let envelope = try JSONSerialization.data(withJSONObject: ["num_turns":0,"command":["name":"usage","data":["groups":normalized]]])
        let value = try ProviderQuotaParser.parse(envelope, agent: .antigravity, identity: after, now: now)
        return CodexConnection(identity: value.identity, quota: value.quota, identityFetchedAt: now, providerSessionKind: AntigravityLaunch.desktopQuotaSessionKind)
    }
}

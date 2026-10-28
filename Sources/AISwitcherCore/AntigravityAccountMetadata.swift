import Foundation

/// Display metadata from Antigravity's own shared Google sign-in record.
/// These claims identify the saved profile, not an independently authenticated session.
/// A successful official CLI quota read is required before attaching them to a snapshot.
public enum AntigravityAccountMetadata {
    public static func identity(from data: Data) -> CodexIdentity? {
        guard data.count <= 131_072,
              let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              record["auth_method"] as? String == "consumer",
              let token = record["id_token"] as? String else { return nil }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[2].isEmpty else { return nil }
        func object(_ text: Substring) -> [String: Any]? {
            var value = String(text).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            value += String(repeating: "=", count: (4 - value.count % 4) % 4)
            guard let bytes = Data(base64Encoded: value) else { return nil }
            return (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
        }
        guard let header = object(parts[0]), header["alg"] as? String == "RS256",
              let claims = object(parts[1]),
              let issuer = claims["iss"] as? String, ["accounts.google.com", "https://accounts.google.com"].contains(issuer),
              claims["email_verified"] as? Bool == true,
              let email = claims["email"] as? String, email.count <= 320,
              email.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil,
              let subject = claims["sub"] as? String, !subject.isEmpty, subject.count <= 160 else { return nil }
        // ID tokens can expire while Antigravity refreshes its session. Only their saved
        // identity is used here; they are never sent to an API or used to authenticate.
        return CodexIdentity(email: email, planType: nil, accountId: "google:" + subject)
    }
    public static func read(at url: URL) -> CodexIdentity? {
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 131_073) else { return nil }
        return identity(from: data)
    }
    public static func consistentIdentity(before: CodexIdentity?, after: CodexIdentity?, emailHint: String) throws -> CodexIdentity {
        guard before == after else { throw ProviderQuotaError.identityChanged }
        if let email = after?.email, emailHint.contains("@"), email.caseInsensitiveCompare(emailHint) != .orderedSame { throw ProviderQuotaError.identityChanged }
        return after ?? CodexIdentity(email: nil, planType: nil)
    }
}

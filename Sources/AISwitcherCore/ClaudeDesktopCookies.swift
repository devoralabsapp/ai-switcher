import Foundation
import SQLite3
import CommonCrypto
import CryptoKit

public enum ClaudeDesktopQuotaError: LocalizedError {
    case accessRequired, unsupportedEncryption, unavailable, unsafeStorage
    public var errorDescription: String? {
        switch self {
        case .accessRequired: return L10n.text("Connect to allow access to this Claude Desktop session for quota. macOS may ask for Claude Safe Storage access.")
        case .unsupportedEncryption: return L10n.text("This Claude Desktop session uses unsupported encryption. Its sign-in has been preserved.")
        case .unavailable: return L10n.text("Claude did not return numeric usage limits for this account. Email and plan are still shown when available.")
        case .unsafeStorage: return L10n.text("The Claude profile storage could not be verified. Its data has been preserved.")
        }
    }
}

/// Only the selected profile's Claude session cookie is read. No cookie database
/// is copied and no credential is included in persisted identity/quota records.
public enum ClaudeDesktopCookies {
    public struct Session: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        private let token: String
        public let organizationID: String?
        public let fingerprint: Data
        public var description: String { "Claude Desktop session (redacted)" }
        public var debugDescription: String { description }
        init(token: String, organizationID: String?, fingerprint: Data) {
            self.token = token; self.organizationID = organizationID; self.fingerprint = fingerprint
        }
        public func request(path: String) throws -> URLRequest {
            let usage = path.hasPrefix("/api/organizations/") && path.hasSuffix("/usage")
                && UUID(uuidString: String(path.dropFirst("/api/organizations/".count).dropLast("/usage".count))) != nil
            guard ["/api/account", "/api/organizations"].contains(path) || usage,
                  let url = URL(string: "https://claude.ai" + path) else { throw ProviderQuotaError.invalidResponse }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            request.httpMethod = "GET"
            request.setValue("sessionKey=" + token, forHTTPHeaderField: "Cookie")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("https://claude.ai", forHTTPHeaderField: "Origin")
            request.setValue("https://claude.ai/settings/usage", forHTTPHeaderField: "Referer")
            request.httpShouldHandleCookies = false
            return request
        }
    }
    private struct Row {
        let name: String; let host: String; let value: String; let encrypted: Data; let expires: Int64; let requiresHostDigest: Bool
    }
    private static func rows(userData: URL) throws -> [Row] {
        let fm = FileManager.default
        let candidates = [userData.appendingPathComponent("Network/Cookies"), userData.appendingPathComponent("Cookies")]
        guard let file = candidates.first(where: { fm.fileExists(atPath: $0.path) }) else { throw ProviderQuotaError.signedOut }
        let boundary = userData.deletingLastPathComponent().standardizedFileURL.path
        for suffix in ["", "-wal", "-shm"] {
            var path = URL(fileURLWithPath: file.path + suffix)
            while path.path == boundary || path.path.hasPrefix(boundary + "/") {
                if let attributes = try? fm.attributesOfItem(atPath: path.path), attributes[.type] as? FileAttributeType == .typeSymbolicLink { throw ClaudeDesktopQuotaError.unsafeStorage }
                path.deleteLastPathComponent()
            }
        }
        // SQLite NOFOLLOW also rejects macOS's system /var and /tmp aliases.
        // Canonicalize those prefixes only, after rejecting links in the profile.
        let sqlPath = file.path.hasPrefix("/var/") || file.path.hasPrefix("/tmp/") ? "/private" + file.path : file.path
        var db: OpaquePointer?, statement: OpaquePointer?
        guard sqlite3_open_v2(sqlPath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK else {
            if db != nil { sqlite3_close(db) }; throw ClaudeDesktopQuotaError.unavailable
        }
        defer { sqlite3_finalize(statement); sqlite3_close(db) }
        sqlite3_busy_timeout(db, 500)
        var metadata: OpaquePointer?
        var version: Int32 = 0
        if sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key='version'", -1, &metadata, nil) == SQLITE_OK,
           sqlite3_step(metadata) == SQLITE_ROW { version = sqlite3_column_int(metadata, 0) }
        sqlite3_finalize(metadata)
        let sql = "SELECT name,host_key,value,encrypted_value,expires_utc FROM cookies WHERE host_key IN ('.claude.ai','claude.ai') AND name IN ('sessionKey','lastActiveOrg') AND path='/' ORDER BY host_key,name LIMIT 8"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw ClaudeDesktopQuotaError.unavailable }
        var rows: [Row] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw ClaudeDesktopQuotaError.unavailable }
            func text(_ column: Int32) throws -> String {
                guard sqlite3_column_bytes(statement, column) <= 8192 else { throw ClaudeDesktopQuotaError.unsafeStorage }
                return sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
            }
            let count = sqlite3_column_bytes(statement, 3)
            guard count >= 0 && count <= 8192 else { throw ClaudeDesktopQuotaError.unsafeStorage }
            let blob = sqlite3_column_blob(statement, 3).map { Data(bytes: $0, count: Int(count)) } ?? Data()
            rows.append(try Row(name: text(0), host: text(1), value: text(2), encrypted: blob, expires: sqlite3_column_int64(statement, 4), requiresHostDigest: version >= 24))
        }
        return rows
    }
    private static func fingerprint(_ rows: [Row]) -> Data {
        var hash = SHA256()
        for row in rows {
            for data in [Data(row.name.utf8), Data(row.host.utf8), Data(row.value.utf8), row.encrypted, Data(String(row.expires).utf8)] {
                hash.update(data: Data(String(data.count).utf8)); hash.update(data: Data([0])); hash.update(data: data)
            }
        }
        return Data(hash.finalize())
    }
    public static func fingerprint(userData: URL) throws -> Data { fingerprint(try rows(userData: userData)) }
    public static func hasSession(userData: URL) -> Bool {
        let now = Date().timeIntervalSince1970
        return (try? rows(userData: userData).contains { $0.name == "sessionKey" && (!$0.value.isEmpty || !$0.encrypted.isEmpty)
            && ($0.expires == 0 || Double($0.expires) / 1_000_000 - 11_644_473_600 > now) }) == true
    }
    public static func read(userData: URL, password: () throws -> Data, now: Date = Date()) throws -> Session {
        let values = try rows(userData: userData)
        var key: Data?
        func value(_ row: Row) throws -> String {
            let expires = Double(row.expires) / 1_000_000 - 11_644_473_600
            guard row.expires == 0 || expires > now.timeIntervalSince1970 else { throw ProviderQuotaError.signedOut }
            if !row.value.isEmpty && row.encrypted.isEmpty { return row.value }
            guard row.encrypted.starts(with: Data("v10".utf8)) else { throw ClaudeDesktopQuotaError.unsupportedEncryption }
            if key == nil { key = try password() }
            return try decrypt(row.encrypted, password: key!, host: row.host, requiresHostDigest: row.requiresHostDigest)
        }
        let valid = values.filter { $0.expires == 0 || Double($0.expires) / 1_000_000 - 11_644_473_600 > now.timeIntervalSince1970 }
        let sessions = try valid.filter { $0.name == "sessionKey" && (!$0.value.isEmpty || !$0.encrypted.isEmpty) }.map(value)
        guard let token = sessions.first, !token.isEmpty else { throw ProviderQuotaError.signedOut }
        guard sessions.allSatisfy({ $0 == token }), token.utf8.count <= 8192,
              token.utf8.allSatisfy({ $0 > 32 && $0 < 127 && $0 != 59 && $0 != 44 }) else { throw ProviderQuotaError.identityChanged }
        let organizations = try valid.filter { $0.name == "lastActiveOrg" }.compactMap { row -> String? in
            let text = try value(row); return UUID(uuidString: text) != nil ? text : nil
        }
        let org = Set(organizations).count == 1 ? organizations.first : nil
        return Session(token: token, organizationID: org, fingerprint: fingerprint(values))
    }
    static func decrypt(_ encrypted: Data, password: Data, host: String, requiresHostDigest: Bool = false) throws -> String {
        guard encrypted.starts(with: Data("v10".utf8)), encrypted.count > 3 else { throw ClaudeDesktopQuotaError.unsupportedEncryption }
        let salt = Array("saltysalt".utf8); var key = [UInt8](repeating: 0, count: 16)
        let derivation = password.withUnsafeBytes { bytes in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), bytes.baseAddress?.assumingMemoryBound(to: Int8.self), password.count, salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, &key, key.count)
        }
        guard derivation == kCCSuccess else { throw ClaudeDesktopQuotaError.unsupportedEncryption }
        defer { _ = key.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        let ciphertext = encrypted.dropFirst(3); var output = [UInt8](repeating: 0, count: ciphertext.count + 16); var count = 0
        let iv = [UInt8](repeating: 32, count: 16)
        let status = ciphertext.withUnsafeBytes { input in
            CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding), key, key.count, iv, input.baseAddress, ciphertext.count, &output, output.count, &count)
        }
        guard status == kCCSuccess else { throw ClaudeDesktopQuotaError.unsupportedEncryption }
        defer { _ = output.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        var data = Data(output.prefix(count))
        let digest = Data(SHA256.hash(data: Data(host.utf8)))
        if data.starts(with: digest) { data.removeFirst(digest.count) }
        else if requiresHostDigest { throw ClaudeDesktopQuotaError.unsupportedEncryption }
        guard let value = String(data: data, encoding: .utf8), !value.isEmpty else { throw ClaudeDesktopQuotaError.unsupportedEncryption }
        return value
    }
}

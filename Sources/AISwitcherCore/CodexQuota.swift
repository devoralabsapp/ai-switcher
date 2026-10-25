import Foundation

public struct CodexIdentity: Codable, Equatable, Sendable {
    public let email: String?
    public let planType: String?
    public let accountId: String?

    public init(email: String?, planType: String?, accountId: String? = nil) {
        self.email = email
        self.planType = planType
        self.accountId = accountId
    }

    public func matches(_ other: CodexIdentity) -> Bool {
        if let a = accountId { return a == other.accountId }
        guard let a = email, let b = other.email, !a.isEmpty else { return false }
        return a.caseInsensitiveCompare(b) == .orderedSame
    }
}

public struct CodexQuotaWindow: Codable, Equatable, Sendable {
    public let usedPercent: Double?
    public let windowDurationMins: Int?
    public let resetsAt: Int?

    public init(usedPercent: Double?, windowDurationMins: Int?, resetsAt: Int?) {
        self.usedPercent = usedPercent
        self.windowDurationMins = windowDurationMins
        self.resetsAt = resetsAt
    }

    public var remainingPercent: Double? {
        guard let usedPercent, usedPercent.isFinite else { return nil }
        return min(100, max(0, 100 - usedPercent))
    }

    public var resetDate: Date? { resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) } }
    public func resetHasPassed(at date: Date) -> Bool { resetDate.map { $0 <= date } ?? false }

    public var durationLabel: String {
        guard let minutes = windowDurationMins, minutes > 0 else { return "Cửa sổ hạn mức" }
        if minutes == 10_080 { return "Tuần" }
        if minutes % 1_440 == 0 { return "\(minutes / 1_440) ngày" }
        if minutes % 60 == 0 { return "\(minutes / 60) giờ" }
        return "\(minutes) phút"
    }
}

public struct CodexQuotaBucket: Codable, Equatable, Sendable {
    public let limitId: String?
    public let limitName: String?
    public let primary: CodexQuotaWindow?
    public let secondary: CodexQuotaWindow?
    public let planType: String?
    public let rateLimitReachedType: String?
}

public struct CodexRateLimits: Codable, Equatable, Sendable {
    public let accountId: String?
    public let rateLimits: CodexQuotaBucket?
    public let rateLimitsByLimitId: [String: CodexQuotaBucket]?

    public var buckets: [(id: String, value: CodexQuotaBucket)] {
        if let map = rateLimitsByLimitId, !map.isEmpty {
            return map.keys.sorted { a, b in
                if a == "codex" { return b != "codex" }
                if b == "codex" { return false }
                return a < b
            }.map { ($0, map[$0]!) }
        }
        return rateLimits.map { [($0.limitId ?? "codex", $0)] } ?? []
    }
}

public struct CodexQuotaSnapshot: Codable, Equatable, Sendable {
    public let limits: CodexRateLimits
    public let fetchedAt: Date

    public init(limits: CodexRateLimits, fetchedAt: Date = Date()) {
        self.limits = limits
        self.fetchedAt = fetchedAt
    }

    public func isStale(at date: Date) -> Bool {
        date.timeIntervalSince(fetchedAt) > 360 || limits.buckets.contains {
            [$0.value.primary, $0.value.secondary].compactMap { $0 }.contains { $0.resetHasPassed(at: date) }
        }
    }
}

public struct CodexConnection: Codable, Equatable, Sendable {
    public let identity: CodexIdentity
    public var quota: CodexQuotaSnapshot?

    public init(identity: CodexIdentity, quota: CodexQuotaSnapshot? = nil) {
        self.identity = identity
        self.quota = quota
    }
}

public enum CodexQuotaError: LocalizedError, Equatable {
    case executableMissing, notSignedIn, identityChanged, identityUnavailable
    case timeout, disconnected, invalidResponse, loginFailed, invalidLoginURL, unsupportedCLI, rpc(Int)

    public var errorDescription: String? {
        switch self {
        case .executableMissing: return "Chưa tìm thấy Codex CLI. Hãy cài Codex CLI hoặc chọn tệp codex đã cài."
        case .notSignedIn: return "Phiên Codex chưa đăng nhập hoặc đã hết hạn. Hãy kết nối lại tài khoản."
        case .identityChanged: return "Tài khoản Codex đã thay đổi. Hãy ngắt kết nối rồi xác nhận lại đúng tài khoản cho hồ sơ này."
        case .identityUnavailable: return "Codex chưa trả về danh tính để xác nhận tài khoản. Hãy cập nhật Codex CLI và thử lại."
        case .timeout: return "Codex chưa phản hồi kịp. Dữ liệu cũ không được coi là quota hiện tại. Hãy thử làm mới."
        case .disconnected: return "Kết nối với Codex CLI đã đóng. Hãy thử lại."
        case .invalidResponse: return "Không đọc được phản hồi Codex. Hãy cập nhật Codex CLI và thử lại."
        case .loginFailed: return "Đăng nhập Codex chưa hoàn tất. Hãy thử lại hoặc hủy kết nối."
        case .invalidLoginURL: return "Codex trả về đường dẫn đăng nhập không hợp lệ. App đã dừng kết nối."
        case .unsupportedCLI: return "Phiên bản Codex CLI chưa hỗ trợ thao tác này. Hãy cập nhật Codex CLI."
        case .rpc(let code): return "Chưa đọc được quota từ Codex (mã \(code)). Hãy thử lại hoặc kết nối lại tài khoản."
        }
    }
}

public enum CodexProcessConfiguration {
    public static let arguments = ["app-server", "--listen", "stdio://", "-c", "cli_auth_credentials_store=\"file\"", "-c", "analytics.enabled=false"]

    public static func environment(base: [String: String], home: URL) -> [String: String] {
        let allowed = Set(["PATH", "HOME", "USER", "LOGNAME", "LANG", "LC_ALL", "TMPDIR", "TMP", "SHELL",
                           "SSL_CERT_FILE", "SSL_CERT_DIR", "CODEX_CA_CERTIFICATE", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
                           "http_proxy", "https_proxy", "all_proxy", "no_proxy"])
        var result = base.filter { allowed.contains($0.key) }
        // This is the child's actual Codex configuration home, not the host app's.
        result["CODEX_HOME"] = home.path
        return result
    }

    public static func validatedLoginURL(_ value: String) throws -> URL {
        guard let url = URL(string: value), url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              ["auth.openai.com", "chatgpt.com"].contains(url.host?.lowercased() ?? "") else {
            throw CodexQuotaError.invalidLoginURL
        }
        return url
    }
}

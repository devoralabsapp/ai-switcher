import Foundation

public enum BrowserKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case chrome, edge, brave

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .chrome: return "Google Chrome"
        case .edge: return "Microsoft Edge"
        case .brave: return "Brave Browser"
        }
    }

    public var bundleIdentifier: String {
        switch self {
        case .chrome: return "com.google.Chrome"
        case .edge: return "com.microsoft.edgemac"
        case .brave: return "com.brave.Browser"
        }
    }

    public var applicationName: String { name + ".app" }
}

public enum AccountColor: String, Codable, CaseIterable, Identifiable, Sendable {
    case mint, blue, violet, peach, rose, gold
    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .mint: return "Xanh ngọc"
        case .blue: return "Xanh dương"
        case .violet: return "Tím"
        case .peach: return "Cam"
        case .rose: return "Hồng"
        case .gold: return "Vàng"
        }
    }
}

public struct Account: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var emailHint: String
    public let browser: BrowserKind
    public var color: AccountColor
    public var isFavorite: Bool
    public let createdAt: Date
    public var lastOpenedAt: Date?
    public var codexConnection: CodexConnection?

    public init(id: UUID = UUID(), name: String, emailHint: String = "", browser: BrowserKind = .chrome,
                color: AccountColor = .mint, isFavorite: Bool = false, createdAt: Date = Date(),
                lastOpenedAt: Date? = nil, codexConnection: CodexConnection? = nil) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.emailHint = emailHint.trimmingCharacters(in: .whitespacesAndNewlines)
        self.browser = browser
        self.color = color
        self.isFavorite = isFavorite
        self.createdAt = createdAt
        self.lastOpenedAt = lastOpenedAt
        self.codexConnection = codexConnection
    }

    public var initials: String {
        let words = name.split(whereSeparator: { $0.isWhitespace })
        return words.prefix(2).compactMap(\.first).map { String($0).uppercased() }.joined()
    }

    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 48 else {
            throw ProfileError.invalidName
        }
        guard emailHint.count <= 160 else { throw ProfileError.invalidEmailHint }
    }
}

public struct AccountSnapshot: Codable, Equatable, Sendable {
    public var version: Int
    public var accounts: [Account]
    public var lastOpenedID: UUID?

    public init(accounts: [Account] = [], lastOpenedID: UUID? = nil, version: Int = 1) {
        self.version = version
        self.accounts = accounts
        self.lastOpenedID = lastOpenedID
    }

    public func validate() throws {
        guard version == 1 else { throw ProfileError.unsupportedVersion }
        guard Set(accounts.map(\.id)).count == accounts.count else { throw ProfileError.duplicateID }
        if let lastOpenedID, !accounts.contains(where: { $0.id == lastOpenedID }) {
            throw ProfileError.invalidSelection
        }
        try accounts.forEach { try $0.validate() }
    }
}

public enum ProfileError: LocalizedError {
    case invalidName, invalidEmailHint, unsupportedVersion, duplicateID, invalidSelection
    case browserUnavailable(String), browserLaunchFailed, profileRunning

    public var errorDescription: String? {
        switch self {
        case .invalidName: return "Tên tài khoản cần có từ 1 đến 48 ký tự."
        case .invalidEmailHint: return "Email hoặc ghi chú cần ngắn hơn 161 ký tự."
        case .unsupportedVersion: return "Dữ liệu này được tạo bởi phiên bản app mới hơn. Hãy cập nhật AI Switcher."
        case .duplicateID: return "Dữ liệu có hai hồ sơ trùng mã. App giữ nguyên tệp để bạn có thể khôi phục."
        case .invalidSelection: return "Tài khoản được chọn không còn trong danh sách."
        case .browserUnavailable(let name): return "Không tìm thấy \(name). Hãy cài trình duyệt này rồi thử lại."
        case .browserLaunchFailed: return "Chưa mở được cửa sổ ChatGPT. Hãy thử lại hoặc kiểm tra trình duyệt."
        case .profileRunning: return "Hồ sơ này vẫn đang chạy. Hãy thoát phiên trình duyệt của hồ sơ từ menu ⋯ rồi thử xóa lại."
        }
    }
}

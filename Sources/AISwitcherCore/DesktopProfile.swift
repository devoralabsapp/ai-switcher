import Foundation
import CryptoKit

public enum LaunchMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case desktop, browser
    public var id: String { rawValue }
    public var name: String { self == .desktop ? "ChatGPT Desktop" : "Trình duyệt" }
}

public enum DesktopProfileError: LocalizedError {
    case appMissing, unsupportedApp, launchFailed, backendFailed, profileRunning, unsafeStorage, socketPathTooLong
    case backendExit(Int32), backendTimeout

    public var errorDescription: String? {
        switch self {
        case .appMissing: return "Chưa tìm thấy ChatGPT Desktop mới. Hãy cài app có Chat, Work và Codex; ChatGPT Classic chưa được hỗ trợ."
        case .unsupportedApp: return "Bản ChatGPT này chưa có cơ chế tách hồ sơ mà AI Switcher hỗ trợ. App đã dừng mở phiên."
        case .launchFailed: return "Chưa mở được phiên ChatGPT Desktop riêng. App không tự chuyển sang Chrome."
        case .backendFailed: return "Chưa kết nối được backend riêng của hồ sơ Desktop. Hãy thử mở lại hoặc cập nhật ChatGPT Desktop."
        case .backendExit(let code): return "Backend Desktop chưa khởi động được (mã \(code)). Hãy thử lại hoặc cập nhật ChatGPT."
        case .backendTimeout: return "Backend Desktop chưa khởi động sau 90 giây. Lần đầu cần cài backend riêng; hãy thử mở lại."
        case .profileRunning: return "Phiên Desktop hoặc backend của hồ sơ vẫn đang chạy. Hãy đóng hoàn toàn phiên từ menu ⋯ trước khi xóa."
        case .unsafeStorage: return "Thư mục hồ sơ Desktop không khớp thông tin sở hữu. App đã dừng để bảo vệ dữ liệu."
        case .socketPathTooLong: return "Đường dẫn backend Desktop quá dài cho socket macOS. Chế độ này chưa hỗ trợ vị trí thư mục người dùng hiện tại."
        }
    }
}

public enum DesktopLaunch {
    public static let bundleIdentifier = "com.openai.codex"
    public static let socketRelativePath = "app-server-control/app-server-control.sock"

    public static func profileKey(root: URL, id: UUID) -> String {
        let hash = SHA256.hash(data: Data((root.standardizedFileURL.path + "\n" + id.uuidString).utf8))
        return Data(hash.prefix(16)).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    public static func environment(base: [String: String], home: URL, userData: URL) -> [String: String] {
        var environment = CodexProcessConfiguration.environment(base: base, home: home)
        environment["CODEX_ELECTRON_USER_DATA_PATH"] = userData.path
        environment["CODEX_APP_SERVER_USE_LOCAL_DAEMON"] = "1"
        return environment
    }

    public static func arguments(userData: URL) -> [String] { ["--user-data-dir=\(userData.path)"] }

    public static func ownsProcess(arguments: [String], userData: URL) -> Bool {
        BrowserLaunch.ownsProcess(arguments: arguments, profileURL: userData)
    }

    public static func bridgeArguments(home: URL) -> [String] {
        ["--quota-socket-bridge", home.appendingPathComponent(socketRelativePath).path]
    }
}

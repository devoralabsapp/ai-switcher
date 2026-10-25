import Foundation
import CryptoKit

public enum LaunchMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case desktop, browser
    public var id: String { rawValue }
    public var name: String { self == .desktop ? "ChatGPT Desktop" : L10n.text("Browser") }
}

public enum DesktopProfileError: LocalizedError {
    case appMissing, unsupportedApp, launchFailed, backendFailed, profileRunning, unsafeStorage, socketPathTooLong
    case backendExit(Int32), backendTimeout

    public var errorDescription: String? {
        switch self {
        case .appMissing: return L10n.text("The new ChatGPT Desktop app was not found. Install the app with Chat, Work, and Codex; ChatGPT Classic is not supported.")
        case .unsupportedApp: return L10n.text("This ChatGPT version does not have the profile isolation mechanisms AI Switcher needs. The session was not opened.")
        case .launchFailed: return L10n.text("Could not open the separate ChatGPT Desktop session. AI Switcher will not fall back to Chrome.")
        case .backendFailed: return L10n.text("Could not connect to this Desktop profile's backend. Try opening it again or update ChatGPT Desktop.")
        case .backendExit(let code): return L10n.format("The Desktop backend could not start (code %@). Try again or update ChatGPT.", String(describing: code))
        case .backendTimeout: return L10n.text("The Desktop backend did not start within 90 seconds. First launch installs a separate backend; try opening it again.")
        case .profileRunning: return L10n.text("This profile's Desktop session or backend is still running. Close it fully from the ⋯ menu before deleting it.")
        case .unsafeStorage: return L10n.text("The Desktop profile ownership marker does not match. AI Switcher stopped to protect your data.")
        case .socketPathTooLong: return L10n.text("The Desktop backend path is too long for a macOS socket. This mode does not support the current home directory location.")
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

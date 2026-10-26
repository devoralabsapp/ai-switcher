import Foundation

public enum ClaudeLaunch {
    public static let bundleIdentifier = "com.anthropic.claudefordesktop"
    public static func arguments(userData: URL) -> [String] { ["--user-data-dir=\(userData.path)"] }
    public static func ownsProcess(arguments: [String], userData: URL) -> Bool {
        BrowserLaunch.ownsProcess(arguments: arguments, profileURL: userData)
    }
    public static func environment(base: [String: String], config: URL) -> [String: String] {
        var result = base.filter { key, _ in
            !key.hasPrefix("CLAUDE_") && !key.hasPrefix("ANTHROPIC_")
                && !key.hasPrefix("ELECTRON_") && !key.hasPrefix("NODE_")
                && !["OPENAI_API_KEY", "CODEX_API_KEY", "SSLKEYLOGFILE", "sslkeylogfile"].contains(key)
        }
        result["CLAUDE_CONFIG_DIR"] = config.path
        return result
    }
}

public enum ClaudeProfileError: LocalizedError {
    case appMissing, unsupportedApp, launchFailed, unsafeStorage
    public var errorDescription: String? {
        switch self {
        case .appMissing: return L10n.text("Claude Desktop was not found. Install Claude in Applications, then try again.")
        case .unsupportedApp: return L10n.text("This Claude version could not be verified for separate profiles. Update Claude Desktop and try again.")
        case .launchFailed: return L10n.text("Could not open the separate Claude Desktop session. Try again or update Claude Desktop.")
        case .unsafeStorage: return L10n.text("The Claude profile storage could not be verified. Its data has been preserved.")
        }
    }
}

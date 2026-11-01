import Foundation
import Darwin

public enum AntigravitySignInMethod: String, Codable, CaseIterable, Identifiable, Sendable {
    case browser, cli
    public var id: String { rawValue }
    public var title: String { self == .browser ? L10n.text("Sign in with browser") : L10n.text("Sign in with Antigravity CLI") }
}

/// Antigravity stores authentication outside Electron userData, under HOME/.gemini.
/// Both the Desktop language server and the official CLI must use the same private home.
public enum AntigravityLaunch {
    public static let bundleIdentifier = "com.google.antigravity"
    public static let isolationArgument = "--ai-switcher-private-keychain=v2"
    public static let quotaSessionKind = "antigravityPrivateKeychainV2"
    public static let desktopQuotaSessionKind = "antigravityDesktopV1"
    public static let sandboxExecutable = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
    /// The vendor's go-keyring adapter uses /usr/bin/security. Deny that helper
    /// before it starts so token storage uses private files without an OS dialog.
    /// Keep Cocoa Keychain access intact for Chromium certificate verification.
    public static let sandboxProfile = "(version 1)(allow default)(deny process-exec (literal \"/usr/bin/security\"))"
    public static func isolatedArguments(executable: URL, arguments: [String]) -> [String] {
        ["-p", sandboxProfile, executable.path] + arguments
    }
    public static func desktopIsolatedArguments(application: URL, executable: URL, arguments: [String]) -> [String] {
        let helpers = application.appendingPathComponent("Contents/Frameworks").path.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"\"",with:"\\\"")
        // Chromium helpers must enter the vendor's own seatbelt policy. A second
        // inherited policy prevents that initialization. Only the app's bundled
        // helpers leave our extra policy; the auth server and CLI stay restricted.
        let profile = sandboxProfile + "(allow process-exec (with no-sandbox) (subpath \"\(helpers)\"))"
        return ["-p",profile,executable.path] + arguments
    }
    public static func arguments(userData: URL) -> [String] { ["--user-data-dir=\(userData.path)", isolationArgument] }
    public static func ownsProcess(arguments: [String], userData: URL) -> Bool {
        BrowserLaunch.ownsProcess(arguments: arguments, profileURL: userData)
    }
    public static func environment(base: [String: String], home: URL) -> [String: String] {
        var env = base.filter { key, _ in
            !["AGY_", "ANTIGRAVITY_", "JETSKI_", "CODEIUM_", "GOOGLE_", "GEMINI_", "CLAUDE_", "ANTHROPIC_", "CODEX_", "ELECTRON_", "NODE_", "XDG_"].contains(where: key.hasPrefix)
                && !["OPENAI_API_KEY", "OPENAI_BASE_URL", "CODEIUM_API_KEY", "CODEIUM_LANGUAGE_SERVER_BIN", "JETSKI_LS_PORT", "DEV_URL", "SSLKEYLOGFILE", "sslkeylogfile", "BASH_ENV", "ENV", "ZDOTDIR"].contains(key)
        }
        env["HOME"] = home.path
        env["CFFIXED_USER_HOME"] = home.path
        // Desktop imports a login shell environment for its language server. Use a
        // system shell with this empty home so user rc files cannot restore shared auth.
        env["SHELL"] = "/bin/sh"
        env["ZDOTDIR"] = home.path
        env["XDG_CONFIG_HOME"] = home.appendingPathComponent(".config").path
        env["XDG_CACHE_HOME"] = home.appendingPathComponent(".cache").path
        env["XDG_DATA_HOME"] = home.appendingPathComponent(".local/share").path
        return env
    }
}

public enum AntigravityProfileError: LocalizedError {
    case unsafeStorage, unsupportedApp, launchFailed, sessionNeedsReopen
    public var errorDescription: String? {
        switch self {
        case .unsafeStorage: return L10n.text("The Antigravity profile storage could not be verified. Its data has been preserved.")
        case .unsupportedApp: return L10n.text("This Antigravity version could not be verified for separate profiles. Update Antigravity and try again.")
        case .launchFailed: return L10n.text("Could not open the separate Antigravity session. Try again or update Antigravity.")
        case .sessionNeedsReopen: return L10n.text("Close this Antigravity account session once, then open it again to apply separate sign-in storage. Your data is kept.")
        }
    }
}

extension ProfileRepository {
    public func antigravityProfileURL(for id: UUID) -> URL { root.appendingPathComponent("Antigravity").appendingPathComponent(id.uuidString) }
    public func antigravityUserDataURL(for id: UUID) -> URL { antigravityProfileURL(for: id).appendingPathComponent("UserData") }
    public func antigravityHomeURL(for id: UUID) -> URL { antigravityProfileURL(for: id).appendingPathComponent("Home") }
    public func antigravityIdentityURL(for id: UUID) -> URL { antigravityHomeURL(for: id).appendingPathComponent(".gemini/jetski-standalone-oauth-token") }
    public func antigravityCLIIdentityURL(for id: UUID) -> URL { antigravityHomeURL(for: id).appendingPathComponent(".gemini/antigravity-cli/antigravity-oauth-token") }


    private struct AntigravityOwner: Codable { let root: String; let id: UUID }
    private func antigravityDirectories(_ id: UUID) -> [URL] {
        [root, root.appendingPathComponent("Antigravity"), antigravityProfileURL(for: id), antigravityUserDataURL(for: id), antigravityHomeURL(for: id), antigravityHomeURL(for: id).appendingPathComponent(".gemini")]
    }
    private func validateAntigravityDirectory(_ url: URL) throws {
        // Check all profile ancestors as well; never follow a redirected profile root.
        var cursor = url.standardizedFileURL
        while cursor.path != "/" {
            let values = try FileManager.default.attributesOfItem(atPath: cursor.path)
            guard values[.type] as? FileAttributeType == .typeDirectory else { throw AntigravityProfileError.unsafeStorage }
            if cursor.path == root.path || cursor.path.hasPrefix(root.path + "/") {
                guard (values[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid() else { throw AntigravityProfileError.unsafeStorage }
            }
            if cursor.path == root.path { break }
            cursor.deleteLastPathComponent()
        }
    }
    public func validateAntigravityOwnership(for id: UUID) throws {
        let fm = FileManager.default, profile = antigravityProfileURL(for: id)
        guard fm.fileExists(atPath: profile.path) || (try? fm.attributesOfItem(atPath: profile.path)) != nil else { return }
        for url in antigravityDirectories(id) { try validateAntigravityDirectory(url) }
        let marker = profile.appendingPathComponent("ai-switcher-profile.json")
        guard try fm.attributesOfItem(atPath: marker.path)[.type] as? FileAttributeType == .typeRegular,
              let owner = try? JSONDecoder().decode(AntigravityOwner.self, from: Data(contentsOf: marker)),
              owner.root == root.path, owner.id == id else { throw AntigravityProfileError.unsafeStorage }
        for identity in [antigravityIdentityURL(for: id), antigravityCLIIdentityURL(for: id)] {
            if let values = try? fm.attributesOfItem(atPath: identity.path), values[.type] as? FileAttributeType != .typeRegular {
                throw AntigravityProfileError.unsafeStorage
            }
            let parent = identity.deletingLastPathComponent()
            if fm.fileExists(atPath: parent.path) { try validateAntigravityDirectory(parent) }
        }
    }
    public func prepareAntigravityProfile(for id: UUID) throws {
        let fm = FileManager.default
        for url in antigravityDirectories(id).prefix(2) {
            if (try? fm.attributesOfItem(atPath: url.path)) != nil { try validateAntigravityDirectory(url) }
            try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try validateAntigravityDirectory(url)
        }
        let profile = antigravityProfileURL(for: id)
        if (try? fm.attributesOfItem(atPath: profile.path)) != nil { try validateAntigravityOwnership(for: id); return }
        for url in antigravityDirectories(id).dropFirst(2) {
            try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let marker = profile.appendingPathComponent("ai-switcher-profile.json")
        try JSONEncoder().encode(AntigravityOwner(root: root.path, id: id)).write(to: marker, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
    }
}

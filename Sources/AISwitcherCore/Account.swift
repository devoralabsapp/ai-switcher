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
        case .mint: return L10n.text("Mint")
        case .blue: return L10n.text("Blue")
        case .violet: return L10n.text("Violet")
        case .peach: return L10n.text("Orange")
        case .rose: return L10n.text("Rose")
        case .gold: return L10n.text("Gold")
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
    public var launchMode: LaunchMode?
    public var desktopCodexConnection: CodexConnection?
    public var sharesLocalWorkspace: Bool?
    public var defaultAction: AccountAction?
    public var connectOnStartup: Bool?
    public var agent: AIAgent?

    public var effectiveAgent: AIAgent { agent ?? .chatgpt }
    public var effectiveLaunchMode: LaunchMode { effectiveAgent == .chatgpt ? launchMode ?? .desktop : effectiveAgent == .claude ? launchMode ?? .browser : effectiveAgent.isSharedApplication ? .desktop : .browser }
    public var usesClaudeDesktop: Bool { effectiveAgent == .claude && effectiveLaunchMode == .desktop }
    public var usesCodexDesktop: Bool { effectiveAgent.supportsCodexQuota && effectiveLaunchMode == .desktop }
    public var usesSharedLocalWorkspace: Bool { usesCodexDesktop && sharesLocalWorkspace == true }
    public var effectiveDefaultAction: AccountAction { usesCodexDesktop ? defaultAction ?? .openDesktop : .openDesktop }
    public var automaticallyConnects: Bool { usesCodexDesktop && connectOnStartup == true }
    public var displayedCodexConnection: CodexConnection? {
        effectiveAgent.supportsCodexQuota ? (effectiveLaunchMode == .desktop ? desktopCodexConnection : codexConnection) : nil
    }

    public init(id: UUID = UUID(), name: String, emailHint: String = "", browser: BrowserKind = .chrome,
                color: AccountColor = .mint, isFavorite: Bool = false, createdAt: Date = Date(),
                lastOpenedAt: Date? = nil, codexConnection: CodexConnection? = nil,
                launchMode: LaunchMode? = nil, desktopCodexConnection: CodexConnection? = nil,
                sharesLocalWorkspace: Bool? = nil, defaultAction: AccountAction? = nil, connectOnStartup: Bool? = nil,
                agent: AIAgent? = nil) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.emailHint = emailHint.trimmingCharacters(in: .whitespacesAndNewlines)
        self.browser = browser
        self.color = color
        self.isFavorite = isFavorite
        self.createdAt = createdAt
        self.lastOpenedAt = lastOpenedAt
        self.codexConnection = codexConnection
        self.launchMode = launchMode
        self.desktopCodexConnection = desktopCodexConnection
        self.sharesLocalWorkspace = sharesLocalWorkspace
        self.defaultAction = defaultAction
        self.connectOnStartup = connectOnStartup
        self.agent = agent
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
        case .invalidName: return L10n.text("Account names must be 1–48 characters long.")
        case .invalidEmailHint: return L10n.text("Keep the email or note under 161 characters.")
        case .unsupportedVersion: return L10n.text("This data was created by a newer app version. Update AI Switcher.")
        case .duplicateID: return L10n.text("Two profiles have the same ID. The data file has been preserved for recovery.")
        case .invalidSelection: return L10n.text("The selected account is no longer in the list.")
        case .browserUnavailable(let name): return L10n.format("%@ was not found. Install this browser and try again.", String(describing: name))
        case .browserLaunchFailed: return L10n.text("Could not open the AI agent window. Try again or check the browser.")
        case .profileRunning: return L10n.text("This profile is still running. Close its browser session from the ⋯ menu before deleting it.")
        }
    }
}

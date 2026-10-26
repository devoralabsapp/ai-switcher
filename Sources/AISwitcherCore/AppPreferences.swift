import Foundation

public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case vietnamese = "vi", english = "en"
    public var id: String { rawValue }
    public var name: String { self == .english ? "English" : "Tiếng Việt" }
    public var locale: Locale { Locale(identifier: self == .english ? "en_US" : "vi_VN") }
}

public enum AppTheme: String, CaseIterable, Identifiable, Sendable {
    case light, dark, terminal, code, dracula, playfulRetro, terminalBlack
    public var id: String { rawValue }
    public var isDark: Bool { self != .light && self != .playfulRetro }
    public var isTerminal: Bool { self == .terminal || self == .terminalBlack }
    public var isPlayfulRetro: Bool { self == .playfulRetro }
    /// Decoration tokens are zero for the original themes so their styling stays intact.
    public var outlineWidth: Double { isPlayfulRetro ? 2.5 : 0 }
    public var hardShadowOffset: Double { isPlayfulRetro ? 4 : 0 }
    public var monospaced: Bool { isTerminal || self == .code }
    public var cornerRadius: Double { isTerminal ? 3 : self == .code ? 6 : 13 }
    public var name: String {
        switch self {
        case .light: return L10n.text("Light")
        case .dark: return L10n.text("Dark")
        case .terminal: return "Terminal"
        case .terminalBlack: return "Terminal Black"
        case .code: return "Code"
        case .dracula: return "Dracula"
        case .playfulRetro: return "Playful Retro Neo-Brutalism"
        }
    }
    public var detail: String {
        switch self {
        case .light: return L10n.text("Soft light with a mint accent")
        case .dark: return L10n.text("A clear, comfortable dark theme")
        case .terminal: return L10n.text("Monospace with terminal green")
        case .terminalBlack: return L10n.text("Pure black with crisp monospace text")
        case .code: return L10n.text("Inspired by VS Code")
        case .dracula: return L10n.text("Deep purple with pink accents")
        case .playfulRetro: return L10n.text("Cream, candy colors, and bold outlines")
        }
    }
    public var colors: ThemeColors {
        switch self {
        case .light: return .init(canvas: 0xf5f8f8, surface: 0xffffff, sidebar: 0xffffff, ink: 0x19242b, secondary: 0x65737c, accent: 0x147864, onAccent: 0xffffff, line: 0xdce5e5)
        case .dark: return .init(canvas: 0x101419, surface: 0x1a2027, sidebar: 0x151a20, ink: 0xe8edf2, secondary: 0xa5b1bd, accent: 0x6cd4b4, onAccent: 0x10261f, line: 0x343e48)
        case .terminalBlack: return .init(canvas: 0x000000, surface: 0x0b0b0b, sidebar: 0x000000, ink: 0xf5f5f5, secondary: 0xbdbdbd, accent: 0x83ef9a, onAccent: 0x001a07, line: 0x454545)
        case .terminal: return .init(canvas: 0x090e0b, surface: 0x101913, sidebar: 0x0b120d, ink: 0xc5f5ce, secondary: 0x8bb795, accent: 0x65ed85, onAccent: 0x0c2112, line: 0x2c4633)
        case .code: return .init(canvas: 0x1e1e1e, surface: 0x252526, sidebar: 0x181818, ink: 0xe0e0e0, secondary: 0xababab, accent: 0x75beff, onAccent: 0x09243d, line: 0x454545)
        case .dracula: return .init(canvas: 0x20212c, surface: 0x282a36, sidebar: 0x191a23, ink: 0xf8f8f2, secondary: 0xb3afd0, accent: 0xd2afff, onAccent: 0x2b1644, line: 0x4c4e65)
        case .playfulRetro: return .init(canvas: 0xfff7e8, surface: 0xfffdf7, sidebar: 0xf6eddb, ink: 0x171714, secondary: 0x171714, accent: 0x185e52, onAccent: 0xffffff, line: 0x171714)
        }
    }
}

/// Shared candy colors used for retro cards, actions, badges, and previews.
public enum RetroColors {
    public static let yellow: UInt32 = 0xffd84d
    public static let pink: UInt32 = 0xffa6c9
    public static let blue: UInt32 = 0xa8d8f0
    public static let mint: UInt32 = 0xb4edc5
    public static let peach: UInt32 = 0xffb39e
    public static let violet: UInt32 = 0xd5c0f4
}

public struct ThemeColors: Equatable, Sendable {
    public let canvas, surface, sidebar, ink, secondary, accent, onAccent, line: UInt32
}

public struct AppPreferences: Equatable, Sendable {
    public var language: AppLanguage
    public var theme: AppTheme
    public var quotaOnlyMode: Bool
    public var workspaceLayout: WorkspaceLayout
    public var quotaSortKey: QuotaSortKey
    public var quotaSortAscending: Bool
    public var quotaAlerts: QuotaAlertSettings
    public var agentFilter: AIAgent?
    public init(language: AppLanguage = .vietnamese, theme: AppTheme = .light,
                quotaOnlyMode: Bool = false, workspaceLayout: WorkspaceLayout = .cards,
                quotaSortKey: QuotaSortKey = .name, quotaSortAscending: Bool = true,
                quotaAlerts: QuotaAlertSettings = .init(), agentFilter: AIAgent? = nil) {
        self.language = language
        self.theme = theme
        self.quotaOnlyMode = quotaOnlyMode
        self.workspaceLayout = workspaceLayout
        self.quotaSortKey = quotaSortKey
        self.quotaSortAscending = quotaSortAscending
        self.quotaAlerts = quotaAlerts
        self.agentFilter = agentFilter
    }
}

public struct AppPreferencesStore {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func load() -> AppPreferences {
        // Older builds could leave the quota table selected after disabling the
        // mode. Repair that state once, while preserving later explicit choices.
        if !defaults.bool(forKey: "ui.quotaOnlyCardsMigration") {
            if !defaults.bool(forKey: "ui.quotaOnlyMode"),
               defaults.string(forKey: "ui.workspaceLayout") == WorkspaceLayout.quotaTable.rawValue {
                defaults.set(WorkspaceLayout.cards.rawValue, forKey: "ui.workspaceLayout")
            }
            defaults.removeObject(forKey: "ui.workspaceLayoutBeforeQuotaOnly")
            defaults.set(true, forKey: "ui.quotaOnlyCardsMigration")
        }
        return AppPreferences(language: defaults.string(forKey: "ui.language").flatMap(AppLanguage.init(rawValue:)) ?? .vietnamese,
                       theme: defaults.string(forKey: "ui.theme").flatMap(AppTheme.init(rawValue:)) ?? .light,
                       quotaOnlyMode: defaults.bool(forKey: "ui.quotaOnlyMode"),
                       workspaceLayout: defaults.string(forKey: "ui.workspaceLayout").flatMap(WorkspaceLayout.init(rawValue:)) ?? .cards,
                       quotaSortKey: defaults.string(forKey: "ui.quotaSortKey").flatMap(QuotaSortKey.init(rawValue:)) ?? .name,
                       quotaSortAscending: defaults.object(forKey: "ui.quotaSortAscending") as? Bool ?? true,
                       quotaAlerts: .init(enabled: defaults.bool(forKey: "quotaAlerts.enabled"),
                           threshold: defaults.object(forKey: "quotaAlerts.threshold") as? Int ?? 20,
                           notifyRecovery: defaults.object(forKey: "quotaAlerts.recovery") as? Bool ?? true),
                       agentFilter: defaults.string(forKey: "ui.agentFilter").flatMap(AIAgent.init(rawValue:)))
    }
    public func save(_ value: AppPreferences) {
        defaults.set(value.language.rawValue, forKey: "ui.language")
        defaults.set(value.theme.rawValue, forKey: "ui.theme")
        defaults.set(value.quotaOnlyMode, forKey: "ui.quotaOnlyMode")
        defaults.set(value.workspaceLayout.rawValue, forKey: "ui.workspaceLayout")
        defaults.set(value.quotaSortKey.rawValue, forKey: "ui.quotaSortKey")
        defaults.set(value.quotaSortAscending, forKey: "ui.quotaSortAscending")
        defaults.set(value.quotaAlerts.enabled, forKey: "quotaAlerts.enabled")
        defaults.set(value.quotaAlerts.threshold, forKey: "quotaAlerts.threshold")
        defaults.set(value.quotaAlerts.notifyRecovery, forKey: "quotaAlerts.recovery")
        defaults.set(value.agentFilter?.rawValue, forKey: "ui.agentFilter")
        defaults.removeObject(forKey: "ui.workspaceLayoutBeforeQuotaOnly")
        defaults.set(true, forKey: "ui.quotaOnlyCardsMigration")
    }

    public func loadAlertTracker() -> QuotaAlertTracker {
        defaults.data(forKey: "quotaAlerts.observations").flatMap { try? JSONDecoder().decode(QuotaAlertTracker.self, from: $0) } ?? .init()
    }
    public func saveAlertTracker(_ tracker: QuotaAlertTracker) {
        if let data = try? JSONEncoder().encode(tracker) { defaults.set(data, forKey: "quotaAlerts.observations") }
    }
}

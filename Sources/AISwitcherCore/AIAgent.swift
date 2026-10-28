import Foundation

public enum AIAgent: String, Codable, CaseIterable, Identifiable, Sendable {
    case chatgpt, claude, gemini, antigravity, perplexity, deepseek
    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .chatgpt: return "ChatGPT"
        case .claude: return "Claude"
        case .gemini: return "Gemini"
        case .antigravity: return "Antigravity"
        case .perplexity: return "Perplexity"
        case .deepseek: return "DeepSeek"
        }
    }
    public var symbol: String {
        switch self {
        case .chatgpt: return "bubble.left.and.bubble.right"
        case .claude: return "sun.max"
        case .gemini: return "sparkles"
        case .antigravity: return "paperplane"
        case .perplexity: return "magnifyingglass"
        case .deepseek: return "water.waves"
        }
    }
    public var supportsCodexQuota: Bool { self == .chatgpt }
    public var supportsQuota: Bool { supportsCodexQuota || self == .claude || self == .antigravity }
    public var usesProviderQuota: Bool { self == .claude || self == .antigravity }
    public var isSharedApplication: Bool { self == .antigravity }
    public var webURL: URL {
        let value: String
        switch self {
        case .chatgpt: value = "https://chatgpt.com/"
        case .claude: value = "https://claude.ai/"
        case .gemini: value = "https://gemini.google.com/app"
        case .antigravity: value = "https://antigravity.google/"
        case .perplexity: value = "https://www.perplexity.ai/"
        case .deepseek: value = "https://chat.deepseek.com/"
        }
        return URL(string: value)!
    }
    public var openTitle: String { L10n.format("Open %@", name) }
    public var supportDetail: String {
        if supportsCodexQuota { return L10n.text("Desktop sessions, browser profiles, and Codex quota") }
        if self == .claude { return L10n.text("Claude quota uses Claude Code sign-in in this profile. Desktop and browser sessions remain separate.") }
        if isSharedApplication { return L10n.text("Antigravity quota uses the official CLI and shared application sign-in.") }
        return L10n.text("Separate browser sign-in for each profile. Quota and background connections are not available for this agent.")
    }
}

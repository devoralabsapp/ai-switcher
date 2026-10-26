import AppKit
import AISwitcherCore

/// Launch-only integration: never closes a shared app or claims account isolation.
@MainActor
final class AgentApplicationService {
    func applicationURL(for agent: AIAgent) -> URL? {
        guard agent == .antigravity else { return nil }
        let candidates = [URL(fileURLWithPath: "/Applications/Antigravity.app"),
                          FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Antigravity.app")]
        return candidates.first { Bundle(url: $0)?.bundleIdentifier == "com.google.antigravity" }
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.antigravity")
    }
    func isRunning(_ agent: AIAgent) -> Bool {
        agent == .antigravity && !NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.antigravity").isEmpty
    }
    func open(_ agent: AIAgent) async throws {
        guard let url = applicationURL(for: agent) else { throw AgentLaunchError.notInstalled(agent.name) }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }
}

enum AgentLaunchError: LocalizedError {
    case notInstalled(String), fixedAgent, duplicateSharedApplication
    var errorDescription: String? {
        switch self {
        case .notInstalled(let name): return L10n.format("%@ is not installed. Install the app, then try again.", name)
        case .fixedAgent: return L10n.text("The agent of an existing profile cannot change. Create a new profile instead.")
        case .duplicateSharedApplication: return L10n.text("Antigravity uses one shared application sign-in. Edit the existing Antigravity entry instead.")
        }
    }
}

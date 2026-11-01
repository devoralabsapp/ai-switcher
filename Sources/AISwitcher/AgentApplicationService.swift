import AppKit
import AISwitcherCore

/// Keeps legacy launchers shared; new Antigravity profiles have private Desktop and CLI homes.
@MainActor
final class AgentApplicationService {
    let repository: ProfileRepository
    private let launchDiagnostics: FileHandle?
    init(repository: ProfileRepository, launchDiagnostics: FileHandle? = nil) { self.repository = repository;self.launchDiagnostics = launchDiagnostics }
    func applicationURL(for agent: AIAgent) -> URL? {
        guard agent == .antigravity else { return nil }
        let candidates = [URL(fileURLWithPath: "/Applications/Antigravity.app"),
                          FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Antigravity.app")]
        return candidates.first { Bundle(url: $0)?.bundleIdentifier == "com.google.antigravity" }
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.antigravity")
    }
    func isRunning(_ agent: AIAgent) -> Bool {
        guard agent == .antigravity else { return false }
        let privatePrefix = "--user-data-dir=" + repository.root.appendingPathComponent("Antigravity").path + "/"
        return NSRunningApplication.runningApplications(withBundleIdentifier: AntigravityLaunch.bundleIdentifier).contains {
            !ManagedApplications.arguments(for: $0.processIdentifier).contains(where: { $0.hasPrefix(privatePrefix) })
        }
    }
    func runningApplication(for account: Account) -> NSRunningApplication? {
        guard account.usesIsolatedAntigravity else { return nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier: AntigravityLaunch.bundleIdentifier).first {
            AntigravityLaunch.ownsProcess(arguments: ManagedApplications.arguments(for: $0.processIdentifier), userData: repository.antigravityUserDataURL(for: account.id))
        }
    }
    func hasWindow(_ account: Account) -> Bool {
        runningApplication(for: account).map { ManagedApplications.windowCount($0) > 0 } ?? false
    }
    @discardableResult
    func open(_ account: Account) async throws -> NSRunningApplication {
        guard account.usesIsolatedAntigravity else { throw AntigravityProfileError.launchFailed }
        guard let app = applicationURL(for: .antigravity), let executable = Bundle(url: app)?.executableURL else { throw AgentLaunchError.notInstalled(AIAgent.antigravity.name) }
        guard let archive = try? Data(contentsOf: app.appendingPathComponent("Contents/Resources/app.asar"), options: .mappedIfSafe),
              ["requestSingleInstanceLock", "homedir", "getAppDataDir", "shellEnvSync"].allSatisfy({ archive.range(of: Data($0.utf8)) != nil }),
              let server = try? Data(contentsOf: app.appendingPathComponent("Contents/Resources/bin/language_server"), options: .mappedIfSafe),
              server.range(of: Data("falling back to file".utf8)) != nil,
              FileManager.default.isExecutableFile(atPath: AntigravityLaunch.sandboxExecutable.path) else { throw AntigravityProfileError.unsupportedApp }
        try repository.prepareAntigravityProfile(for: account.id)
        if let running = runningApplication(for: account) {
            guard ManagedApplications.arguments(for: running.processIdentifier).contains(AntigravityLaunch.isolationArgument) else { throw AntigravityProfileError.sessionNeedsReopen }
            if hasWindow(account), running.activate(options: [.activateAllWindows, .activateIgnoringOtherApps]) { return running }
        }
        let process = Process()
        process.executableURL = AntigravityLaunch.sandboxExecutable
        process.arguments = AntigravityLaunch.desktopIsolatedArguments(application:app, executable: executable, arguments: AntigravityLaunch.arguments(userData: repository.antigravityUserDataURL(for: account.id)))
        process.environment = AntigravityLaunch.environment(base: ProcessInfo.processInfo.environment, home: repository.antigravityHomeURL(for: account.id))
        process.currentDirectoryURL = repository.antigravityHomeURL(for: account.id)
        process.standardInput = FileHandle.nullDevice;process.standardOutput = launchDiagnostics ?? FileHandle.nullDevice;process.standardError = launchDiagnostics ?? FileHandle.nullDevice
        try process.run()
        for _ in 0..<300 {
            try await Task.sleep(nanoseconds: 200_000_000)
            if let running = runningApplication(for: account), hasWindow(account) {
                running.activate(options: [.activateAllWindows, .activateIgnoringOtherApps]);return running
            }
            if !process.isRunning, process.terminationStatus != 0 { throw AntigravityProfileError.launchFailed }
        }
        throw AntigravityProfileError.launchFailed
    }
    func close(_ account: Account) async throws {
        guard account.usesIsolatedAntigravity, let running = runningApplication(for: account) else { return }
        try repository.validateAntigravityOwnership(for: account.id)
        guard running.terminate() else { throw ProfileError.profileRunning }
        // Hub closes network sessions and its language server before exiting.
        // That cleanup can exceed 15 seconds; keep Closing visible until it exits.
        for _ in 0..<450 {
            if running.isTerminated { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw ProfileError.profileRunning
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

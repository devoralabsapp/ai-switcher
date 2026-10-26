import AppKit
import AISwitcherCore

/// Uses the installed, unmodified signed app with Electron's own profile switch.
@MainActor
final class ClaudeDesktopService {
    let repository: ProfileRepository
    init(repository: ProfileRepository) { self.repository = repository }
    func applicationURL() -> URL? {
        let candidates = [URL(fileURLWithPath: "/Applications/Claude.app"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Claude.app")]
        return candidates.first { Bundle(url: $0)?.bundleIdentifier == ClaudeLaunch.bundleIdentifier }
    }
    func runningApplication(for account: Account) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == ClaudeLaunch.bundleIdentifier
                && ClaudeLaunch.ownsProcess(arguments: ManagedApplications.arguments(for: $0.processIdentifier),
                    userData: repository.claudeUserDataURL(for: account.id))
        }
    }
    func hasWindow(_ account: Account) -> Bool {
        runningApplication(for: account).map { ManagedApplications.windowCount($0) > 0 } ?? false
    }
    @discardableResult
    func open(_ account: Account) async throws -> NSRunningApplication {
        guard account.usesClaudeDesktop else { throw ClaudeProfileError.launchFailed }
        guard let app = applicationURL(), let executable = Bundle(url: app)?.executableURL else { throw ClaudeProfileError.appMissing }
        // Compatibility is rechecked on launch because Claude updates itself.
        guard let archive = try? Data(contentsOf: app.appendingPathComponent("Contents/Resources/app.asar"), options: .mappedIfSafe),
              ["user-data-dir", "requestSingleInstanceLock"].allSatisfy({ archive.range(of: Data($0.utf8)) != nil }) else {
            throw ClaudeProfileError.unsupportedApp
        }
        try repository.prepareClaudeProfile(for: account.id)
        if let running = runningApplication(for: account), ManagedApplications.windowCount(running) > 0,
           running.activate(options: [.activateAllWindows, .activateIgnoringOtherApps]) { return running }
        let process = Process()
        process.executableURL = executable
        process.arguments = ClaudeLaunch.arguments(userData: repository.claudeUserDataURL(for: account.id))
        process.environment = ClaudeLaunch.environment(base: ProcessInfo.processInfo.environment, config: repository.claudeConfigURL(for: account.id))
        process.currentDirectoryURL = repository.claudeProfileURL(for: account.id)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        for _ in 0..<300 {
            try await Task.sleep(nanoseconds: 200_000_000)
            if let running = runningApplication(for: account), ManagedApplications.windowCount(running) > 0 {
                running.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
                return running
            }
            if !process.isRunning, process.terminationStatus != 0 { throw ClaudeProfileError.launchFailed }
        }
        throw ClaudeProfileError.launchFailed
    }
    func close(_ account: Account) async throws {
        guard let running = runningApplication(for: account) else { return }
        try repository.validateClaudeOwnership(for: account.id)
        guard running.terminate() else { throw ProfileError.profileRunning }
        for _ in 0..<100 {
            if running.isTerminated { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw ProfileError.profileRunning
    }
}

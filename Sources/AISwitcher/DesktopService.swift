import AppKit
import AISwitcherCore

struct DesktopInstallation {
    let application: URL
    let executable: URL
    let cli: URL
    let version: String
}

@MainActor
final class DesktopService {
    let repository: ProfileRepository
    private var cachedInstallation: DesktopInstallation?
    private var cachedArchiveDate: Date?

    init(repository: ProfileRepository) { self.repository = repository }

    func installation() throws -> DesktopInstallation {
        let candidates = [URL(fileURLWithPath: "/Applications/ChatGPT.app"),
                          FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/ChatGPT.app")]
        guard let app = candidates.first(where: { Bundle(url: $0)?.bundleIdentifier == DesktopLaunch.bundleIdentifier }),
              let bundle = Bundle(url: app), let executable = bundle.executableURL else { throw DesktopProfileError.appMissing }
        let archive = app.appendingPathComponent("Contents/Resources/app.asar")
        let modified = try? FileManager.default.attributesOfItem(atPath: archive.path)[.modificationDate] as? Date
        if let cachedInstallation, cachedInstallation.application == app, cachedArchiveDate == modified { return cachedInstallation }
        guard let data = try? Data(contentsOf: archive, options: .mappedIfSafe),
              ["CODEX_ELECTRON_USER_DATA_PATH", "CODEX_APP_SERVER_USE_LOCAL_DAEMON"].allSatisfy({ data.range(of: Data($0.utf8)) != nil }) else {
            throw DesktopProfileError.unsupportedApp
        }
        let cli = app.appendingPathComponent("Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
        guard FileManager.default.isExecutableFile(atPath: cli.path) else { throw DesktopProfileError.unsupportedApp }
        let result = DesktopInstallation(application: app, executable: executable, cli: cli,
                                         version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown")
        cachedInstallation = result
        cachedArchiveDate = modified
        return result
    }

    func runningApplication(for account: Account) -> NSRunningApplication? {
        let userData = repository.desktopUserDataURL(for: account.id)
        return NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == DesktopLaunch.bundleIdentifier
                && DesktopLaunch.ownsProcess(arguments: ManagedApplications.arguments(for: $0.processIdentifier), userData: userData)
        }
    }

    func hasBackend(_ id: UUID) -> Bool {
        guard (try? repository.validateDesktopOwnership(for: id)) != nil else { return false }
        // The CLI publishes a symlink to its short runtime socket.
        let socket = repository.desktopHomeURL(for: id).appendingPathComponent(DesktopLaunch.socketRelativePath).resolvingSymlinksInPath()
        return (try? FileManager.default.attributesOfItem(atPath: socket.path)[.type] as? FileAttributeType) == .typeSocket
    }

    @discardableResult
    func open(_ account: Account) async throws -> NSRunningApplication {
        let installed = try installation()
        try repository.prepareDesktopProfile(for: account.id)
        if let running = runningApplication(for: account), ManagedApplications.windowCount(running) > 0,
           running.activate(options: [.activateAllWindows, .activateIgnoringOtherApps]) {
            return running
        }
        // With no windows, launch the same profile again. Electron's per-profile
        // instance lock forwards the request to its own running process.
        let home = repository.desktopHomeURL(for: account.id)
        let environment = DesktopLaunch.environment(base: ProcessInfo.processInfo.environment, home: home,
                                                     userData: repository.desktopUserDataURL(for: account.id))
        try await DesktopCommand.run(executable: installed.cli, arguments: ["app-server", "daemon", "start", "-c", "cli_auth_credentials_store=\"file\"", "-c", "analytics.enabled=false"], environment: environment, directory: home)
        // daemon start publishes a PID before the server binds its socket.
        for _ in 0..<100 {
            if hasBackend(account.id) { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard hasBackend(account.id) else { throw DesktopProfileError.backendFailed }
        let child = Process()
        child.executableURL = installed.executable
        child.arguments = DesktopLaunch.arguments(userData: repository.desktopUserDataURL(for: account.id))
        child.environment = environment
        child.currentDirectoryURL = repository.desktopProfileURL(for: account.id)
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        for _ in 0..<300 {
            try await Task.sleep(nanoseconds: 200_000_000)
            if let running = runningApplication(for: account), ManagedApplications.windowCount(running) > 0 {
                running.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
                return running
            }
            if !child.isRunning, child.terminationStatus != 0 { throw DesktopProfileError.launchFailed }
        }
        throw DesktopProfileError.launchFailed
    }

    func close(_ account: Account) async throws {
        if let running = runningApplication(for: account) {
            guard running.terminate() else { throw DesktopProfileError.profileRunning }
            for _ in 0..<300 {
                if running.isTerminated { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard running.isTerminated else { throw DesktopProfileError.profileRunning }
        }
        // Stop even when a failed/crashed start left no live socket yet.
        if FileManager.default.fileExists(atPath: repository.desktopHomeURL(for: account.id).path) {
            try repository.validateDesktopOwnership(for: account.id)
            let installed = try installation(), home = repository.desktopHomeURL(for: account.id)
            try await DesktopCommand.run(executable: installed.cli, arguments: ["app-server", "daemon", "stop"],
                environment: DesktopLaunch.environment(base: ProcessInfo.processInfo.environment, home: home,
                    userData: repository.desktopUserDataURL(for: account.id)), directory: home)
            for _ in 0..<100 {
                if !hasBackend(account.id) { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard !hasBackend(account.id) else { throw DesktopProfileError.profileRunning }
        }
    }

    func quotaClient(_ id: UUID) throws -> CodexRPCClient {
        try repository.validateDesktopOwnership(for: id)
        guard hasBackend(id) else { throw DesktopProfileError.backendFailed }
        let home = repository.desktopHomeURL(for: id)
        guard let executable = Bundle.main.executableURL else { throw DesktopProfileError.launchFailed }
        return CodexRPCClient(executable: executable, home: home,
                              arguments: DesktopLaunch.bridgeArguments(home: home))
    }
}

enum DesktopCommand {
    static func run(executable: URL, arguments: [String], environment: [String: String], directory: URL) async throws {
        let command = Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = environment
            process.currentDirectoryURL = directory
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            do {
                // First start installs the bundled daemon into this profile.
                let deadline = Date().addingTimeInterval(90)
                while process.isRunning {
                    try Task.checkCancellation()
                    guard Date() < deadline else { throw DesktopProfileError.backendTimeout }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                guard process.terminationStatus == 0 else { throw DesktopProfileError.backendExit(process.terminationStatus) }
            } catch {
                if process.isRunning { process.terminate() }
                throw error
            }
        }
        try await withTaskCancellationHandler(operation: { try await command.value }, onCancel: { command.cancel() })
    }
}

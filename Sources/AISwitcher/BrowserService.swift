import AppKit
import AISwitcherCore
import CoreGraphics
import Darwin

/// Uses real browser profiles so Google/Apple sign-in stays in a full browser.
/// No cookie extraction, credential handling, scripting permission, or debug port.
@MainActor
final class BrowserService {
    let repository: ProfileRepository

    init(repository: ProfileRepository) { self.repository = repository }

    func applicationURL(for browser: BrowserKind) -> URL? {
        let candidates = [
            URL(fileURLWithPath: "/Applications").appendingPathComponent(browser.applicationName),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").appendingPathComponent(browser.applicationName),
        ]
        return candidates.first { Bundle(url: $0)?.bundleIdentifier == browser.bundleIdentifier }
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleIdentifier)
    }

    var installedBrowsers: [BrowserKind] { BrowserKind.allCases.filter { applicationURL(for: $0) != nil } }

    func runningApplication(for account: Account) -> NSRunningApplication? {
        let profile = repository.profileURL(for: account.id)
        return NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == account.browser.bundleIdentifier
                && BrowserLaunch.ownsProcess(arguments: Self.arguments(for: $0.processIdentifier), profileURL: profile)
        }
    }

    func windowCount(for application: NSRunningApplication) -> Int {
        let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.filter {
            ($0[kCGWindowOwnerPID as String] as? Int32) == application.processIdentifier
                && ($0[kCGWindowLayer as String] as? Int) == 0
                && (($0[kCGWindowBounds as String] as? [String: CGFloat])?["Width"] ?? 0) > 100
        }.count
    }

    /// Focus an existing session. Reopen the agent if the browser has no windows.
    @discardableResult
    func open(_ account: Account, forceNewWindow: Bool = false, url: URL? = nil) async throws -> NSRunningApplication {
        guard let bundleURL = applicationURL(for: account.browser),
              let executableURL = Bundle(url: bundleURL)?.executableURL else {
            throw ProfileError.browserUnavailable(account.browser.name)
        }

        if !forceNewWindow, let running = runningApplication(for: account), windowCount(for: running) > 0 {
            if running.activate(options: [.activateAllWindows, .activateIgnoringOtherApps]) { return running }
        }

        let profileURL = try repository.prepareProfile(for: account.id)
        let process = Process()
        process.executableURL = executableURL
        process.arguments = BrowserLaunch.arguments(profileURL: profileURL, url: url ?? account.effectiveAgent.webURL)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        // Chromium may forward the launch to an existing profile and exit with 0.
        for _ in 0..<100 {
            try await Task.sleep(nanoseconds: 150_000_000)
            if let running = runningApplication(for: account), windowCount(for: running) > 0 {
                running.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
                return running
            }
            if !process.isRunning, process.terminationStatus != 0 { throw ProfileError.browserLaunchFailed }
        }
        throw ProfileError.browserLaunchFailed
    }

    func close(_ account: Account) async throws {
        guard let running = runningApplication(for: account) else { return }
        // Only the exact dedicated profile process may be terminated.
        guard running.terminate() else { throw ProfileError.profileRunning }
        for _ in 0..<80 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if running.isTerminated { return }
        }
        // A browser can refuse to quit when it has an unsent form or download.
        throw ProfileError.profileRunning
    }

    private static func arguments(for pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var data = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, u_int(mib.count), &data, &size, nil, 0) == 0 else { return [] }
        let argc = data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc < 4096 else { return [] }
        var cursor = MemoryLayout<Int32>.size
        // The kernel returns argc, the executable path, padding, then argv.
        while cursor < size && data[cursor] != 0 { cursor += 1 }
        while cursor < size && data[cursor] == 0 { cursor += 1 }
        var arguments: [String] = []
        for _ in 0..<argc {
            let start = cursor
            while cursor < size && data[cursor] != 0 { cursor += 1 }
            guard start < size else { break }
            arguments.append(String(decoding: data[start..<cursor], as: UTF8.self))
            cursor += 1
        }
        return arguments
    }
}

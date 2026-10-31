import AppKit
import Darwin
import AISwitcherCore

@MainActor
enum AntigravitySmokeTest {
    static func run(repository: ProfileRepository) async {
        setbuf(stdout, nil)
        guard CommandLine.arguments.contains("--data-dir"), repository.root.lastPathComponent.hasPrefix("ai-switcher-smoke."),
              (try? repository.load().accounts.isEmpty) == true else { Darwin.exit(1) }
        let diagnosticsURL = repository.root.appendingPathComponent("fixture-launch.log")
        FileManager.default.createFile(atPath: diagnosticsURL.path, contents: nil)
        let diagnostics = try? FileHandle(forWritingTo: diagnosticsURL)
        let service = AgentApplicationService(repository: repository, launchDiagnostics: diagnostics)
        let a = Account(name: "Antigravity Smoke A", agent: .antigravity, antigravityUsesPrivateHome: true)
        let b = Account(name: "Antigravity Smoke B", agent: .antigravity, antigravityUsesPrivateHome: true)
        let existing = NSRunningApplication.runningApplications(withBundleIdentifier: AntigravityLaunch.bundleIdentifier)
        var failure: Error?
        do {
            let first = try await service.open(a), second = try await service.open(b)
            guard first.processIdentifier != second.processIdentifier,
                  !existing.contains(where: { $0.processIdentifier == first.processIdentifier || $0.processIdentifier == second.processIdentifier }) else { throw AntigravityProfileError.launchFailed }
            for (account, app) in [(a, first), (b, second)] {
                try await verifyLanguageServerHome(parent: app.processIdentifier, home: repository.antigravityHomeURL(for: account.id))
                guard !FileManager.default.fileExists(atPath: repository.antigravityIdentityURL(for: account.id).path) else { throw AntigravityProfileError.unsafeStorage }
            }
            print("PASS: two separate Antigravity Desktop windows and native language servers use different private homes; no existing sign-in copied")
            let reused = try await service.open(a)
            guard reused.processIdentifier == first.processIdentifier else { throw AntigravityProfileError.launchFailed }
            let marker = repository.antigravityHomeURL(for: a.id).appendingPathComponent("persistence-fixture")
            try Data("A".utf8).write(to: marker)
            try await service.close(a)
            print("PASS: A closed; opening A again")
            guard !second.isTerminated else { throw AntigravityProfileError.launchFailed }
            let reopened = try await service.open(a)
            try await verifyLanguageServerHome(parent: reopened.processIdentifier, home: repository.antigravityHomeURL(for: a.id))
            guard try Data(contentsOf: marker) == Data("A".utf8), service.hasWindow(b) else { throw AntigravityProfileError.launchFailed }
            print("PASS: focus reuses A; closing/reopening A preserves storage and leaves B running")
            let quota = ProviderQuotaService(repository: repository)
            for account in [a,b] {
                do { _ = try await quota.read(account, override: nil);throw AntigravityProfileError.unsafeStorage }
                catch ProviderQuotaError.signedOut { }
            }
            print("PASS: installed official CLI reports signed out for both fresh private homes; does not use shared login")
        } catch { failure = error }
        for account in [a,b] {
            do { try await service.close(account);_ = try repository.remove(account.id, from: .init()) }
            catch { failure = failure ?? error }
        }
        if existing.contains(where: { $0.isTerminated }) { failure = failure ?? AntigravityProfileError.launchFailed }
        if let failure { fputs("FAIL: \(failure.localizedDescription)\n", stderr);Darwin.exit(1) }
        print("PASS: fixture profiles cleaned up; existing Antigravity applications preserved")
        Darwin.exit(0)
    }

    private static func verifyLanguageServerHome(parent: pid_t, home: URL) async throws {
        for _ in 0..<60 {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            process.arguments = ["-P", String(parent)];process.standardOutput = pipe;process.standardError = FileHandle.nullDevice
            try process.run()
            let output = pipe.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit()
            let children = String(decoding: output, as: UTF8.self).split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
            for child in children where ManagedApplications.arguments(for: child).first?.hasSuffix("/language_server") == true {
                guard environmentHome(child) == home.path else { throw AntigravityProfileError.unsafeStorage }
                return
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw AntigravityProfileError.launchFailed
    }

    /// Inspect only HOME from a disposable child; never print or return its other environment values.
    private static func environmentHome(_ pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid], size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var data = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, u_int(mib.count), &data, &size, nil, 0) == 0 else { return nil }
        let argc = data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc < 4096 else { return nil }
        var cursor = 4
        while cursor < size && data[cursor] != 0 { cursor += 1 }
        while cursor < size && data[cursor] == 0 { cursor += 1 }
        for _ in 0..<argc {
            while cursor < size && data[cursor] != 0 { cursor += 1 };cursor += 1
        }
        while cursor < size {
            let start = cursor
            while cursor < size && data[cursor] != 0 { cursor += 1 }
            let entry = String(decoding: data[start..<cursor], as: UTF8.self);cursor += 1
            if entry.hasPrefix("HOME=") { return String(entry.dropFirst(5)) }
        }
        return nil
    }
}

import AppKit
import Darwin
import AISwitcherCore

/// Uses the official CLI against the same auth home as the Desktop profile.
/// No credentials are copied from a personal browser or another account.
@MainActor
final class DesktopSignInService {
    let repository: ProfileRepository
    let desktop: DesktopService
    let browsers: BrowserService
    private let clientFactory: ((URL) throws -> CodexRPCClient)?
    private let openLogin: (URL) async throws -> Void
    init(repository: ProfileRepository, desktop: DesktopService, browsers: BrowserService,
         clientFactory: ((URL) throws -> CodexRPCClient)? = nil,
         openLogin: ((URL) async throws -> Void)? = nil) {
        self.repository = repository; self.desktop = desktop; self.browsers = browsers
        self.clientFactory = clientFactory
        self.openLogin = openLogin ?? { try await browsers.openSignIn($0) }
    }

    static func requirePersonalChromeForClaude() throws {
        guard let handler = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://claude.ai/")!),
              Bundle(url: handler)?.bundleIdentifier == BrowserKind.chrome.bundleIdentifier else {
            throw DesktopSignInError.claudeBrowser
        }
    }

    func signInChatGPT(_ account: Account) async throws -> CodexConnection {
        guard account.usesCodexDesktop else { throw ProfileError.invalidSelection }
        try repository.prepareDesktopProfile(for: account.id)
        let home = repository.desktopHomeURL(for: account.id)
        // A fresh official process writes auth.json in this Desktop home, even
        // when an earlier background daemon cached a signed-out AuthManager.
        let client: CodexRPCClient
        if let clientFactory { client = try clientFactory(home) }
        else { client = CodexRPCClient(executable: try desktop.installation().cli, home: home) }
        var loginID: String?
        do {
            if account.effectiveSignInMethod == .cli {
                try await signInCLI(executable: desktop.installation().cli, home: home, id: account.id)
                try await client.start()
            } else {
                try await client.start()
                let login = try await client.startLogin(); loginID = login.loginId
                try await openLogin(CodexProcessConfiguration.validatedLoginURL(login.authUrl))
                try await client.waitForLogin(login.loginId)
            }
            try Task.checkCancellation()
            let identity = try await client.readIdentity()
            let limits = try? await client.readLimits()
            await client.stop()
            return CodexConnection(identity: CodexIdentity(email: identity.email, planType: identity.planType, accountId: limits?.accountId), quota: limits.map { CodexQuotaSnapshot(limits: $0) })
        } catch {
            if let loginID { await client.cancelLogin(loginID) }
            await client.stop()
            throw error
        }
    }

    private func signInCLI(executable: URL, home: URL, id: UUID) async throws {
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let job = repository.root.appendingPathComponent("desktop-login-\(id.uuidString)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: job, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let script = job.appendingPathComponent("sign-in.command"), result = job.appendingPathComponent("result")
        let pidFile = job.appendingPathComponent("cli.pid"), cancelled = job.appendingPathComponent("cancelled")
        let workingArgument = "--cd=" + job.path
        defer {
            // Covers cancellation before Terminal has even started the script.
            if !FileManager.default.fileExists(atPath: result.path) { try? Data().write(to: cancelled, options: .atomic) }
            if let value = try? String(contentsOf: pidFile, encoding: .utf8), let pid = Int32(value), pid > 0 {
                let arguments = ManagedApplications.arguments(for: pid)
                // PID alone is not ownership. Match the executable and this
                // login's unique private directory before terminating it.
                if arguments.first == executable.path && arguments.contains(workingArgument) && arguments.contains("login") {
                    Darwin.kill(pid, SIGTERM)
                }
            }
            if FileManager.default.fileExists(atPath: result.path) { try? FileManager.default.removeItem(at: job) }
        }
        // Terminal is a separate process: use an explicit minimal environment,
        // rather than inheriting a user's unrelated provider credentials.
        let environment = CodexProcessConfiguration.environment(base: ProcessInfo.processInfo.environment, home: home)
        let keys = ["PATH", "HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "TERM", "CODEX_HOME"]
        let assignments = keys.compactMap { key in environment[key].map { quote(key + "=" + $0) } }.joined(separator: " ")
        let content = """
        #!/bin/sh
        cd \(quote(home.path)) || exit 1
        [ ! -e \(quote(cancelled.path)) ] || exit 130
        /usr/bin/env -i \(assignments) \(quote(executable.path)) \(quote(workingArgument)) -c 'cli_auth_credentials_store="file"' login </dev/tty &
        login_pid=$!
        printf '%s' "$login_pid" > \(quote(pidFile.path))
        if [ -e \(quote(cancelled.path)) ]; then kill -TERM "$login_pid"; fi
        wait "$login_pid"
        status=$?
        printf '%s' "$status" > \(quote(result.path))
        exit "$status"

        """
        try content.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let config = NSWorkspace.OpenConfiguration(); config.activates = true
        _ = try await NSWorkspace.shared.open([script], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"), configuration: config)
        // Completion is reported by the official command's exit status, not by
        // an older auth file. Cancellation stops only this job's verified CLI.
        for _ in 0..<600 {
            try Task.checkCancellation()
            if let value = try? String(contentsOf: result, encoding: .utf8) {
                guard value == "0" else { throw CodexQuotaError.notSignedIn }
                return
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw CodexQuotaError.notSignedIn
    }
}

enum DesktopSignInError: LocalizedError {
    case claudeBrowser
    var errorDescription: String? { L10n.text("Claude Desktop opens authorization in the system default browser. Set Google Chrome as your default browser to use your personal Chrome, then try again.") }
}

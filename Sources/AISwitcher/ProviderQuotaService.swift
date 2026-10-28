import Foundation
import AppKit
import AISwitcherCore

@MainActor
final class ProviderQuotaService {
    let repository: ProfileRepository
    private var commands: [UUID: ProviderCLICommand] = [:]
    init(repository: ProfileRepository) { self.repository = repository }
    /// App bundles and directories can have execute permission on macOS, but are not CLI files.
    static func isCLIExecutable(_ url: URL, agent: AIAgent) -> Bool {
        let path = url.resolvingSymlinksInPath().standardizedFileURL
        guard (try? path.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              FileManager.default.isExecutableFile(atPath: path.path) else { return false }
        var parent = path.deletingLastPathComponent()
        while parent.path != "/" {
            if parent.pathExtension.lowercased() == "app" {
                let infoURL = parent.appendingPathComponent("Contents/Info.plist")
                guard agent == .claude, let data = try? Data(contentsOf: infoURL),
                      let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      info["CFBundleIdentifier"] as? String == "com.anthropic.claude-code" else { return false }
                return true
            }
            parent.deleteLastPathComponent()
        }
        return true
    }
    static func resolveExecutable(_ agent: AIAgent, override: String?, candidates: [URL]) throws -> URL {
        if let override {
            let url = URL(fileURLWithPath: override)
            if isCLIExecutable(url, agent: agent) { return url }
        }
        // Recover from previously saved .app selections rather than reusing the invalid path.
        guard let found = candidates.first(where: { isCLIExecutable($0, agent: agent) }) else { throw ProviderQuotaError.cliMissing }
        return found
    }
    func executable(_ agent: AIAgent, override: String?) throws -> URL {
        if let override, Self.isCLIExecutable(URL(fileURLWithPath: override), agent: agent) { return URL(fileURLWithPath: override) }
        let fm = FileManager.default, home = fm.homeDirectoryForCurrentUser
        let names = agent == .claude ? ["claude"] : ["agy", "antigravity"]
        var candidates = names.flatMap { name in
            [home.appendingPathComponent(".local/bin/\(name)"), URL(fileURLWithPath: "/opt/homebrew/bin/\(name)"), URL(fileURLWithPath: "/usr/local/bin/\(name)")]
        }
        if agent == .claude {
            let root = home.appendingPathComponent("Library/Application Support/Claude/claude-code")
            if let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
                var found: [URL] = []
                for case let path as URL in enumerator where path.lastPathComponent == "claude" && path.path.contains("/Contents/MacOS/") { found.append(path) }
                candidates += found.sorted { $0.path.compare($1.path, options: .numeric) == .orderedDescending }
            }
        }
        return try Self.resolveExecutable(agent, override: override, candidates: candidates)
    }
    func environment(_ account: Account) throws -> [String: String] {
        var env = CodexProcessConfiguration.environment(base: ProcessInfo.processInfo.environment, home: repository.root)
        for key in Array(env.keys) where key.hasPrefix("CLAUDE_") || key.hasPrefix("ANTHROPIC_") || key.hasPrefix("AGY_") || key.hasPrefix("GOOGLE_") || key.hasPrefix("GEMINI_") || key.hasPrefix("CODEX_") { env.removeValue(forKey: key) }
        if account.effectiveAgent == .claude { try repository.prepareClaudeProfile(for: account.id); env["CLAUDE_CONFIG_DIR"] = repository.claudeConfigURL(for: account.id).path }
        return env
    }
    private func command(_ account: Account, executable: URL, arguments: [String]) async throws -> ProviderCLICommand {
        let command = ProviderCLICommand();commands[account.id] = command
        do { try await command.start(executable: executable, arguments: arguments, environment: environment(account), directory: repository.root) }
        catch { await command.stop();commands[account.id] = nil;throw error }
        return command
    }
    private func run(_ account: Account, exe: URL, arguments: [String]) async throws -> Data {
        let c = try await command(account, executable: exe, arguments: arguments)
        do { await c.closeInput();let data = try await c.collect();await c.stop();commands[account.id] = nil;return data }
        catch { await c.stop();commands[account.id] = nil;throw error }
    }
    private func verifiedExecutable(_ account: Account, override: String?) async throws -> URL {
        let exe = try executable(account.effectiveAgent, override: override)
        let version = String(decoding: try await run(account, exe: exe, arguments: ["--version"]), as: UTF8.self)
        guard ProviderCLIConfiguration.accepts(version: version, agent: account.effectiveAgent) else { throw ProviderQuotaError.cliOutdated }
        return exe
    }
    func read(_ account: Account, override: String?) async throws -> CodexConnection {
        let exe = try await verifiedExecutable(account, override: override)
        if account.effectiveAgent == .claude {
            func identity() async throws -> CodexIdentity {
                let data = try await run(account, exe: exe, arguments: ["auth", "status"])
                guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any], value["loggedIn"] as? Bool == true else { throw ProviderQuotaError.signedOut }
                guard value["authMethod"] as? String == "claude.ai", let email = value["email"] as? String, !email.isEmpty else { throw ProviderQuotaError.unavailable }
                guard let config = value["configDirectory"] as? String, URL(fileURLWithPath: config).standardizedFileURL == repository.claudeConfigURL(for: account.id).standardizedFileURL else { throw ProviderQuotaError.identityChanged }
                if account.emailHint.contains("@"), account.emailHint.caseInsensitiveCompare(email) != .orderedSame { throw ProviderQuotaError.identityChanged }
                return CodexIdentity(email: email, planType: value["subscriptionType"] as? String)
            }
            let before = try await identity()
            let c = try await command(account, executable: exe, arguments: ProviderCLIConfiguration.claudeArguments)
            let data: Data
            do { _ = try await c.claudeControl("initialize");data = try await c.claudeControl("get_usage");await c.stop();commands[account.id] = nil }
            catch { await c.stop();commands[account.id] = nil;throw error }
            let after = try await identity();guard before.matches(after) else { throw ProviderQuotaError.identityChanged }
            return try ProviderQuotaParser.parse(data, agent: .claude, identity: after)
        }
        let data = try await run(account, exe: exe, arguments: ProviderCLIConfiguration.antigravityArguments)
        return try ProviderQuotaParser.parse(data, agent: .antigravity, identity: CodexIdentity(email: nil, planType: nil))
    }
    func prepareSignInScript(_ account: Account, override: String?) async throws -> URL {
        let exe = try await verifiedExecutable(account, override: override)
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let script = repository.root.appendingPathComponent("provider-login-\(account.id.uuidString).command")
        var content = "#!/bin/sh\n"
        if account.effectiveAgent == .claude { content += "export CLAUDE_CONFIG_DIR=" + quote(repository.claudeConfigURL(for: account.id).path) + "\n" }
        content += "unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL CLAUDE_CODE_OAUTH_TOKEN GEMINI_API_KEY GOOGLE_API_KEY GOOGLE_APPLICATION_CREDENTIALS AGY_ADC_AUTH\n"
        content += "exec " + quote(exe.path) + (account.effectiveAgent == .claude ? " auth login" : "") + "\n"
        try Task.checkCancellation()
        try content.write(to: script, atomically: true, encoding: .utf8);try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return script
    }
    func signIn(_ account: Account, override: String?) async throws {
        let script = try await prepareSignInScript(account, override: override)
        try Task.checkCancellation()
        let config = NSWorkspace.OpenConfiguration();config.activates = true
        _ = try await NSWorkspace.shared.open([script], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"), configuration: config)
    }
    func stop(_ id: UUID) async { if let command = commands.removeValue(forKey: id) { await command.stop() } }
}

import Foundation

public enum ProviderCLIInstallationError: LocalizedError {
    case failed, stillRunning, unsupported
    public var errorDescription: String? {
        switch self {
        case .failed: return L10n.text("CLI installation failed. Check the installer window, then try again.")
        case .stillRunning: return L10n.text("Installation is still running. Finish it in the installer window, then click Connect again.")
        case .unsupported: return L10n.text("CLI installation is available for Claude and Antigravity.")
        }
    }
}

/// A user-initiated, visible official installer. No login, account data or model prompt is passed to it.
public struct ProviderCLIInstallation: Sendable {
    public let directory: URL
    public let launcher: URL
    public let result: URL
    public let installerURL: URL
    private let agent: AIAgent
    public init(agent: AIAgent, root: URL) throws {
        guard agent.usesProviderQuota else { throw ProviderCLIInstallationError.unsupported }
        self.agent = agent
        directory = root.appendingPathComponent("Installers/" + UUID().uuidString, isDirectory: true)
        launcher = directory.appendingPathComponent("install.command")
        result = directory.appendingPathComponent("exit-status")
        installerURL = URL(string: agent == .claude ? "https://claude.ai/install.sh" : "https://antigravity.google/cli/install.sh")!
    }
    public func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try script.write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)
    }
    public var script: String {
        func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let download = directory.appendingPathComponent("official-installer.sh")
        let temporaryResult = result.appendingPathExtension("tmp")
        return """
        #!/bin/bash
        set -eu
        umask 077
        aisw_finish() {
            aisw_install_exit=$?
            printf '%s\\n' "$aisw_install_exit" > \(quote(temporaryResult.path))
            /bin/mv -f \(quote(temporaryResult.path)) \(quote(result.path))
            if [ "$aisw_install_exit" = 0 ]; then
                printf '\\n%s\\n' \(quote(L10n.text("Installation finished. Return to AI Switcher.")))
            else
                printf '\\n%s\\n' \(quote(L10n.text("CLI installation failed. Check the installer window, then try again.")))
            fi
        }
        trap aisw_finish EXIT
        cd \(quote(directory.path))
        unset CLAUDE_CONFIG_DIR CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL GOOGLE_API_KEY GOOGLE_APPLICATION_CREDENTIALS GEMINI_API_KEY AGY_ADC_AUTH
        /usr/bin/curl --fail --show-error --location --proto '=https' --proto-redir '=https' --connect-timeout 20 --max-time 120 --output \(quote(download.path)) \(quote(installerURL.absoluteString))
        /bin/bash \(quote(download.path))\(agent == .claude ? " latest" : "") </dev/null
        """ + "\n"
    }
    public func wait(timeout: TimeInterval = 600) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: result.path) {
                guard let data = try? Data(contentsOf: result), data.count <= 32,
                      let text = String(data: data, encoding: .utf8), Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) == 0 else { throw ProviderCLIInstallationError.failed }
                return
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw ProviderCLIInstallationError.stillRunning
    }
    public func cleanupIfFinished() {
        if FileManager.default.fileExists(atPath: result.path) { try? FileManager.default.removeItem(at: directory) }
    }
}

import AppKit
import AISwitcherCore

@MainActor
final class CodexQuotaService {
    private let repository: ProfileRepository
    private var active: [UUID: CodexRPCClient] = [:]
    private var logins: [UUID: String] = [:]

    init(repository: ProfileRepository) { self.repository = repository }

    var executableURL: URL? {
        var paths: [String] = []
        if let selected = UserDefaults.standard.string(forKey: "CodexExecutablePath") { paths.append(selected) }
        paths += [
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/codex").path,
        ]
        paths += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/codex" }
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.title = "Chọn Codex CLI đã cài"
        panel.message = "Chọn tệp thực thi codex. App dùng giao thức app-server để đọc quota."
        panel.prompt = "Dùng Codex CLI"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url, FileManager.default.isExecutableFile(atPath: url.path) {
            UserDefaults.standard.set(url.path, forKey: "CodexExecutablePath")
        }
    }

    func connect(_ id: UUID, openLogin: (URL) async throws -> Void) async throws -> CodexConnection {
        let client = try makeClient(id)
        active[id] = client
        do {
            try await client.start()
            let login = try await client.startLogin()
            logins[id] = login.loginId
            let url = try CodexProcessConfiguration.validatedLoginURL(login.authUrl)
            try await openLogin(url)
            try await client.waitForLogin(login.loginId)
            let identity = try await client.readIdentity()
            let limits = try? await client.readLimits()
            let verified = CodexIdentity(email: identity.email, planType: identity.planType, accountId: limits?.accountId)
            guard verified.email?.isEmpty == false || verified.accountId?.isEmpty == false else {
                throw CodexQuotaError.identityUnavailable
            }
            let auth = repository.codexHomeURL(for: id).appendingPathComponent("auth.json")
            if FileManager.default.fileExists(atPath: auth.path) {
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: auth.path)
            }
            await client.stop()
            active[id] = nil
            logins[id] = nil
            return CodexConnection(identity: verified, quota: limits.map { CodexQuotaSnapshot(limits: $0) })
        } catch {
            if let login = logins.removeValue(forKey: id) { await client.cancelLogin(login) }
            await client.stop()
            active[id] = nil
            try? removeHome(id)
            throw error
        }
    }

    func refresh(_ id: UUID, connection: CodexConnection) async throws -> CodexConnection {
        let client = try makeClient(id)
        active[id] = client
        do {
            try await client.start()
            let identity = try await client.readIdentity()
            // Email is available before the quota read; backend account ID is checked below.
            if let expected = connection.identity.email, let actual = identity.email,
               expected.caseInsensitiveCompare(actual) != .orderedSame { throw CodexQuotaError.identityChanged }
            let limits = try await client.readLimits()
            let current = CodexIdentity(email: identity.email, planType: identity.planType, accountId: limits.accountId)
            guard connection.identity.matches(current) else { throw CodexQuotaError.identityChanged }
            await client.stop()
            active[id] = nil
            return CodexConnection(identity: current, quota: CodexQuotaSnapshot(limits: limits))
        } catch {
            await client.stop()
            active[id] = nil
            throw error
        }
    }

    func disconnect(_ id: UUID) async throws {
        await cancel(id)
        // Ask Codex to clear its managed session when possible. Local removal also
        // works if the executable has since been uninstalled or the session expired.
        if let client = try? makeClient(id) {
            try? await client.start()
            try? await client.logout()
            await client.stop()
        }
        try removeHome(id)
    }

    func cancel(_ id: UUID) async {
        guard let client = active.removeValue(forKey: id) else { return }
        if let login = logins.removeValue(forKey: id) { await client.cancelLogin(login) }
        await client.stop()
    }

    func discardUnconfirmed(_ id: UUID) async throws {
        await cancel(id)
        try removeHome(id)
    }

    func stopAll() async {
        for id in Array(active.keys) { await cancel(id) }
    }

    private func makeClient(_ id: UUID) throws -> CodexRPCClient {
        guard let executableURL else { throw CodexQuotaError.executableMissing }
        return CodexRPCClient(executable: executableURL, home: try repository.prepareCodexHome(for: id))
    }

    private func removeHome(_ id: UUID) throws {
        let home = repository.codexHomeURL(for: id)
        if FileManager.default.fileExists(atPath: home.path) { try FileManager.default.removeItem(at: home) }
    }
}

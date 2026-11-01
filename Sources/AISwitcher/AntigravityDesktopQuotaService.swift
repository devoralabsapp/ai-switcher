import AppKit
import Darwin
import AISwitcherCore

@MainActor
final class AntigravityDesktopQuotaService {
    let applications: AgentApplicationService
    let repository: ProfileRepository
    private var backgrounds: [UUID: Background] = [:]
    init(applications: AgentApplicationService, repository: ProfileRepository) { self.applications = applications;self.repository = repository }

    private final class Background {
        let process = Process(), input = Pipe(), output = Pipe(), csrf = UUID().uuidString
        var startup = Data()
        var port: Int? {
            let text = String(decoding:startup,as:UTF8.self)
            guard let regex = try? NSRegularExpression(pattern:#"listening on random port at (\d+) for HTTP\b"#),
                  let match = regex.matches(in:text,range:NSRange(text.startIndex...,in:text)).last,
                  let range = Range(match.range(at:1),in:text) else { return nil }
            return Int(text[range])
        }
    }
    func hasBackend(_ id: UUID) -> Bool { backgrounds[id]?.process.isRunning == true }
    /// Run the vendor's own native server without its Electron window. Do not
    /// use --headless: that flag changes OAuth into a manual paste-code flow.
    func connect(_ account: Account) async throws {
        guard account.usesAntigravityDesktopQuota else { throw ProviderQuotaError.unavailable }
        if applications.runningApplication(for:account) != nil || hasBackend(account.id) { return }
        try repository.prepareAntigravityProfile(for:account.id)
        guard let app = applications.applicationURL(for:.antigravity),
              let version = Bundle(url:app)?.infoDictionary?["CFBundleShortVersionString"] as? String else { throw AgentLaunchError.notInstalled("Antigravity") }
        let executable = app.appendingPathComponent("Contents/Resources/bin/language_server")
        guard FileManager.default.isExecutableFile(atPath:executable.path) else { throw AntigravityProfileError.unsupportedApp }
        let backend = Background()
        backend.process.executableURL = AntigravityLaunch.sandboxExecutable
        let arguments = ["--standalone","--override_ide_name","antigravity","--subclient_type","hub","--override_ide_version",version,"--override_user_agent_name","antigravity","--http_server_port","0","--csrf_token",backend.csrf,"--app_data_dir","antigravity","--api_server_url","https://generativelanguage.googleapis.com","--cloud_code_endpoint","https://daily-cloudcode-pa.googleapis.com","--exit_on_stdin_close"]
        backend.process.arguments = AntigravityLaunch.isolatedArguments(executable:executable,arguments:arguments)
        backend.process.environment = AntigravityLaunch.environment(base:ProcessInfo.processInfo.environment,home:repository.antigravityHomeURL(for:account.id))
        backend.process.currentDirectoryURL = repository.antigravityHomeURL(for:account.id)
        backend.process.standardInput = backend.input
        backend.process.standardOutput = backend.output;backend.process.standardError = backend.output
        backend.output.fileHandleForReading.readabilityHandler = { [weak self,weak backend] file in
            let bytes = file.availableData
            Task { @MainActor in
                guard let self,let backend,self.backgrounds[account.id] === backend else { return }
                if backend.startup.count < 65_536 { backend.startup.append(bytes.prefix(65_536 - backend.startup.count)) }
            }
        }
        backgrounds[account.id] = backend
        do {
            try backend.process.run()
            for _ in 0..<80 {
                try Task.checkCancellation()
                guard backend.process.isRunning else { throw AntigravityProfileError.launchFailed }
                if backend.port != nil { return }
                try await Task.sleep(nanoseconds:250_000_000)
            }
            throw ProviderQuotaError.timeout
        } catch { await stop(account.id);throw error }
    }

    func stop(_ id: UUID) async {
        guard let backend = backgrounds.removeValue(forKey:id) else { return }
        try? backend.input.fileHandleForWriting.close()
        for _ in 0..<30 where backend.process.isRunning { try? await Task.sleep(nanoseconds:100_000_000) }
        if backend.process.isRunning { backend.process.terminate() }
        for _ in 0..<20 where backend.process.isRunning { try? await Task.sleep(nanoseconds:100_000_000) }
        if backend.process.isRunning { Darwin.kill(backend.process.processIdentifier,SIGKILL) }
        backend.output.fileHandleForReading.readabilityHandler = nil
        try? backend.output.fileHandleForReading.close()
    }
    func stopAll() async { for id in Array(backgrounds.keys) { await stop(id) } }

    /// The vendor owns the OAuth state, callback listener, browser launch and
    /// credential persistence. AI Switcher never exchanges or copies tokens.
    func signInWithBrowser(_ account: Account) async throws {
        let endpoint = try await readyEndpoint(account)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:];configuration.httpCookieStorage = nil;configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 600;configuration.timeoutIntervalForResource = 600
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let url = URL(string: "http://127.0.0.1:\(endpoint.port)/exa.language_server_pb.LanguageServerService/Login")!
        var request = URLRequest(url: url);request.httpMethod = "POST";request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue(endpoint.csrf, forHTTPHeaderField: "X-Codeium-Csrf-Token")
        let (data,response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, response.statusCode == 200, data.count <= 1_048_576,
              try self.endpoint(account) == endpoint else { throw ProviderQuotaError.signedOut }
        // Do not persist the login response. The verified identity read follows.
    }

    private struct Endpoint: Equatable {
        let rootPID: pid_t, childPID: pid_t, createdSeconds: Int, createdMicros: Int, port: Int, csrf: String
    }

    func read(_ account: Account) async throws -> CodexConnection {
        let endpoint = try await readyEndpoint(account)
        let savedBefore = AntigravityAccountMetadata.read(at: repository.antigravityIdentityURL(for: account.id))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.httpCookieStorage = nil;configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 15;configuration.timeoutIntervalForResource = 20
        let delegate = NoRedirects(), session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        func request(_ method: String) async throws -> Data {
            try Task.checkCancellation()
            guard try self.endpoint(account) == endpoint else { throw ProviderQuotaError.identityChanged }
            // No caller-provided URL, remote endpoint or arbitrary RPC method.
            guard ["GetUserStatus","RetrieveUserQuotaSummary"].contains(method),
                  let url = URL(string: "http://127.0.0.1:\(endpoint.port)/exa.language_server_pb.LanguageServerService/\(method)") else { throw ProviderQuotaError.invalidResponse }
            var request = URLRequest(url: url);request.httpMethod = "POST";request.httpBody = Data("{}".utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
            request.setValue(endpoint.csrf, forHTTPHeaderField: "X-Codeium-Csrf-Token")
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200, data.count <= 1_048_576,
                  try self.endpoint(account) == endpoint else { throw ProviderQuotaError.invalidResponse }
            return data
        }
        let before = try await request("GetUserStatus")
        _ = try AntigravityDesktopQuota.identity(before)
        let quota = try await request("RetrieveUserQuotaSummary")
        let after = try await request("GetUserStatus")
        let value = try AntigravityDesktopQuota.connection(statusBefore: before, quota: quota, statusAfter: after, emailHint: account.emailHint)
        let savedAfter = AntigravityAccountMetadata.read(at: repository.antigravityIdentityURL(for: account.id))
        guard savedBefore == savedAfter else { throw ProviderQuotaError.identityChanged }
        if let email = savedAfter?.email, value.identity.email?.caseInsensitiveCompare(email) != .orderedSame { throw ProviderQuotaError.identityChanged }
        return value
    }

    private func readyEndpoint(_ account: Account) async throws -> Endpoint {
        for attempt in 0..<40 {
            try Task.checkCancellation()
            do { return try endpoint(account) }
            catch ProviderQuotaError.unavailable {
                guard applications.runningApplication(for: account) != nil || hasBackend(account.id), attempt < 39 else { throw ProviderQuotaError.unavailable }
                try await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        throw ProviderQuotaError.unavailable
    }

    private func endpoint(_ account: Account) throws -> Endpoint {
        try repository.validateAntigravityOwnership(for: account.id)
        if let backend = backgrounds[account.id], backend.process.isRunning, let port = backend.port {
            guard let stamp = processStamp(backend.process.processIdentifier,parent:getpid()),
                  (1024...65535).contains(port),
                  let app = applications.applicationURL(for:.antigravity),
                  ManagedApplications.arguments(for:backend.process.processIdentifier).first == app.appendingPathComponent("Contents/Resources/bin/language_server").path else { throw ProviderQuotaError.unavailable }
            try verifyListener(pid:backend.process.processIdentifier,port:port)
            return Endpoint(rootPID:getpid(),childPID:backend.process.processIdentifier,createdSeconds:stamp.0,createdMicros:stamp.1,port:port,csrf:backend.csrf)
        }
        guard account.usesIsolatedAntigravity, let running = applications.runningApplication(for: account),
              let app = applications.applicationURL(for: .antigravity),
              running.bundleURL?.standardizedFileURL.path == app.standardizedFileURL.path else { throw ProviderQuotaError.unavailable }
        let children = try output("/usr/bin/pgrep", ["-P", String(running.processIdentifier)])
            .split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
        let executable = app.appendingPathComponent("Contents/Resources/bin/language_server").path
        let matches = children.filter { ManagedApplications.arguments(for: $0).first == executable }
        guard matches.count == 1, let pid = matches.first else { throw ProviderQuotaError.unavailable }
        let arguments = ManagedApplications.arguments(for: pid)
        func argument(_ name: String) -> String? {
            if let value = arguments.first(where: { $0.hasPrefix(name + "=") }) { return String(value.dropFirst(name.count + 1)) }
            guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        guard let csrf = argument("--csrf_token"), !csrf.isEmpty, csrf.count <= 256,
              !csrf.contains(where: { $0.isNewline }), let stamp = processStamp(pid, parent: running.processIdentifier) else { throw ProviderQuotaError.unavailable }
        let logURL = repository.antigravityHomeURL(for: account.id).appendingPathComponent("Library/Logs/Antigravity/language_server.log")
        guard (try? logURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
              let handle = try? FileHandle(forReadingFrom: logURL) else { throw ProviderQuotaError.unavailable }
        defer { try? handle.close() }
        // Read only the startup section, never save or expose the backend log.
        let data = try handle.read(upToCount: 65_536) ?? Data(), text = String(decoding: data, as: UTF8.self)
        let regex = try NSRegularExpression(pattern: #"listening on random port at (\d+) for HTTP\b"#)
        guard let match = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).last,
              let range = Range(match.range(at: 1), in: text), let port = Int(text[range]), (1024...65535).contains(port) else { throw ProviderQuotaError.unavailable }
        // Confirm the selected port is listening in this exact verified child.
        try verifyListener(pid:pid,port:port)
        guard let still = processStamp(pid, parent: running.processIdentifier), still == stamp else { throw ProviderQuotaError.unavailable }
        return Endpoint(rootPID: running.processIdentifier, childPID: pid, createdSeconds: stamp.0, createdMicros: stamp.1, port: port, csrf: csrf)
    }

    private func verifyListener(pid:pid_t,port:Int) throws {
        let listeners = try output("/usr/sbin/lsof",["-nP","-a","-p",String(pid),"-iTCP:\(port)","-sTCP:LISTEN","-Fpn"])
        guard listeners.split(separator:"\n").contains("p\(pid)"),listeners.split(separator:"\n").contains(where: { $0.hasPrefix("n") && $0.hasSuffix(":\(port)") }) else { throw ProviderQuotaError.unavailable }
    }

    private func processStamp(_ pid: pid_t, parent: pid_t) -> (Int, Int)? {
        var mib: [Int32] = [CTL_KERN,KERN_PROC,KERN_PROC_PID,pid], info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.size
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0, info.kp_eproc.e_ppid == parent else { return nil }
        return (Int(info.kp_proc.p_starttime.tv_sec),Int(info.kp_proc.p_starttime.tv_usec))
    }

    private func output(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path);process.arguments = arguments
        process.standardOutput = pipe;process.standardError = FileHandle.nullDevice
        try process.run();let data = pipe.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit()
        guard data.count <= 65_536 else { throw ProviderQuotaError.invalidResponse }
        return String(decoding: data, as: UTF8.self)
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

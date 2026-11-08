import AppKit
import Darwin
import Security
import AISwitcherCore

@MainActor
final class AntigravityDesktopQuotaService {
    let applications: AgentApplicationService
    let repository: ProfileRepository
    private let sharedSourceHome: URL?
    private var indexedConversations: [UUID: (Endpoint, Set<String>)] = [:]
    private var backgrounds: [UUID: Background] = [:]
    init(applications: AgentApplicationService, repository: ProfileRepository, sharedSourceHome: URL? = nil) {
        self.applications = applications; self.repository = repository; self.sharedSourceHome = sharedSourceHome
    }

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
        try SharedAntigravityWorkspace(repository:repository, sourceHome:sharedSourceHome).prepare(account)
        guard let app = applications.applicationURL(for:.antigravity),
              let version = Bundle(url:app)?.infoDictionary?["CFBundleShortVersionString"] as? String else { throw AgentLaunchError.notInstalled("Antigravity") }
        let executable = app.appendingPathComponent("Contents/Resources/bin/language_server")
        guard FileManager.default.isExecutableFile(atPath:executable.path) else { throw AntigravityProfileError.unsupportedApp }
        let backend = Background()
        backend.process.executableURL = AntigravityLaunch.sandboxExecutable
        let arguments = ["--standalone","--override_ide_name","antigravity","--subclient_type","hub","--override_ide_version",version,"--override_user_agent_name","antigravity","--http_server_port","0","--csrf_token",backend.csrf,"--app_data_dir","antigravity","--api_server_url","https://generativelanguage.googleapis.com","--cloud_code_endpoint","https://daily-cloudcode-pa.googleapis.com","--exit_on_stdin_close"]
        backend.process.arguments = AntigravityLaunch.isolatedArguments(executable:executable,arguments:arguments)
        var environment = AntigravityLaunch.environment(base: ProcessInfo.processInfo.environment,
                                                       home: repository.antigravityHomeURL(for: account.id))
        // The vendor's no-handoff success page leaves OAuth in this backend.
        // The system-wide antigravity:// link has no private profile identifier.
        environment["ANTIGRAVITY_AUTH_SUCCESS_APP"] = "antigravity-cli"
        backend.process.environment = environment
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
        indexedConversations[id] = nil
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
        _ = try await request(account, endpoint: endpoint, method: "Login")
    }

    private struct Endpoint: Equatable {
        let rootPID: pid_t, childPID: pid_t, createdSeconds: Int, createdMicros: Int, port: Int, csrf: String
    }

    func read(_ account: Account) async throws -> CodexConnection {
        let endpoint = try await readyEndpoint(account)
        let savedBefore = AntigravityAccountMetadata.read(at: repository.antigravityIdentityURL(for: account.id))
        try await indexSharedConversations(account)
        func request(_ method: String) async throws -> Data {
            try await self.request(account, endpoint: endpoint, method: method)
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

    func indexSharedConversations(_ account: Account) async throws {
        guard account.sharesAntigravityProjects else { return }
        let workspace = SharedAntigravityWorkspace(repository: repository, sourceHome: sharedSourceHome)
        let ids = try workspace.conversationIDs()
        guard !ids.isEmpty else { return }
        let endpoint = try await readyEndpoint(account)
        let indexed = indexedConversations[account.id]
        let missing = ids.filter { indexed?.0 != endpoint || indexed?.1.contains($0) != true }
        for id in missing {
            try Task.checkCancellation()
            _ = try await request(account, endpoint: endpoint, method: "GetConversationMetadata",
                                  body: JSONSerialization.data(withJSONObject: ["conversationId": id]))
        }
        indexedConversations[account.id] = (endpoint, Set(ids))
    }

    #if DEBUG
    private var fixtureEnabled: Bool {
        ProcessInfo.processInfo.environment["AISWITCHER_TEST_NATIVE_ANTIGRAVITY"] == "1"
            && repository.root.lastPathComponent.hasPrefix("Antigravity's Profiles ") && sharedSourceHome != nil
    }
    // Signed-out, disposable native history fixture. Never sends a model prompt.
    func fixtureRequest(_ account: Account, method: String, body: [String: Any] = [:]) async throws -> Data {
        guard fixtureEnabled else { throw ProviderQuotaError.unavailable }
        return try await request(account, endpoint: try await readyEndpoint(account), method: method,
                                 body: JSONSerialization.data(withJSONObject: body))
    }
    #endif

    private func request(_ account: Account, endpoint: Endpoint, method: String, body: Data = Data("{}".utf8)) async throws -> Data {
        var allowed = ["GetUserStatus", "RetrieveUserQuotaSummary", "Login", "GetConversationMetadata"]
        #if DEBUG
        if fixtureEnabled { allowed += ["StartCascade", "GetAllCascadeTrajectories", "GetCascadeTrajectory"] }
        #endif
        guard allowed.contains(method),
              try self.endpoint(account) == endpoint else { throw ProviderQuotaError.identityChanged }
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = method == "Login" ? 600 : 20
        config.timeoutIntervalForResource = config.timeoutIntervalForRequest
        let delegate = LocalNativeSession(port: endpoint.port, pid: endpoint.childPID,
                                          parent: endpoint.rootPID, stamp: (endpoint.createdSeconds, endpoint.createdMicros))
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        // Current Hub uses TLS on its local HTTP listener. Older versions use HTTP.
        for scheme in ["http", "https"] {
            try Task.checkCancellation()
            guard try self.endpoint(account) == endpoint else { throw ProviderQuotaError.identityChanged }
            let url = URL(string: "\(scheme)://127.0.0.1:\(endpoint.port)/exa.language_server_pb.LanguageServerService/\(method)")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
            request.setValue(endpoint.csrf, forHTTPHeaderField: "X-Codeium-Csrf-Token")
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse, data.count <= 1_048_576,
                  try self.endpoint(account) == endpoint else { throw ProviderQuotaError.invalidResponse }
            if scheme == "http", response.statusCode == 400,
               String(decoding: data, as: UTF8.self).contains("HTTP request to an HTTPS server") { continue }
            guard response.statusCode == 200 else { throw ProviderQuotaError.unavailable }
            return data
        }
        throw ProviderQuotaError.unavailable
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

private final class LocalNativeSession: NSObject, URLSessionTaskDelegate {
    let port: Int, pid: pid_t, parent: pid_t
    let stamp: (Int, Int)
    private let lock = NSLock()
    private var certificate: Data?
    init(port: Int, pid: pid_t, parent: pid_t, stamp: (Int, Int)) {
        self.port = port
        self.pid = pid
        self.parent = parent
        self.stamp = stamp
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.size
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              space.host == "127.0.0.1", space.port == port,
              sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0,
              info.kp_eproc.e_ppid == parent,
              Int(info.kp_proc.p_starttime.tv_sec) == stamp.0,
              Int(info.kp_proc.p_starttime.tv_usec) == stamp.1,
              let trust = space.serverTrust, let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        let data = SecCertificateCopyData(leaf) as Data
        lock.lock()
        let valid = certificate == nil || certificate == data
        if certificate == nil { certificate = data }
        lock.unlock()
        completionHandler(valid ? .useCredential : .cancelAuthenticationChallenge, valid ? URLCredential(trust: trust) : nil)
    }
}

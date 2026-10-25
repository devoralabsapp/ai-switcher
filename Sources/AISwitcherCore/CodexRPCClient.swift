import Foundation
import Darwin

/// Restricted, quota-only JSONL client. It cannot start threads or model turns.
public actor CodexRPCClient {
    private let executable: URL
    private let home: URL
    private let arguments: [String]
    private let timeout: TimeInterval
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var deadlines: [Int: Task<Void, Never>] = [:]
    private var loginEvents: [String: Data] = [:]
    private var loginWaiters: [String: CheckedContinuation<Data, Error>] = [:]
    private var loginDeadlines: [String: Task<Void, Never>] = [:]

    public init(executable: URL, home: URL, arguments: [String] = CodexProcessConfiguration.arguments,
                timeout: TimeInterval = 20) {
        self.executable = executable
        self.home = home
        self.arguments = arguments
        self.timeout = timeout
    }

    public func start() async throws {
        guard process == nil else { return }
        try Task.checkCancellation()
        let child = Process(), stdinPipe = Pipe(), stdoutPipe = Pipe()
        child.executableURL = executable
        child.arguments = arguments
        child.environment = CodexProcessConfiguration.environment(base: ProcessInfo.processInfo.environment, home: home)
        child.currentDirectoryURL = home
        child.standardInput = stdinPipe
        child.standardOutput = stdoutPipe
        // Authentication URLs and raw RPC errors must never enter app logs.
        child.standardError = FileHandle.nullDevice
        input = stdinPipe.fileHandleForWriting
        output = stdoutPipe.fileHandleForReading
        child.terminationHandler = { [weak self] _ in Task { await self?.failAll(CodexQuotaError.disconnected) } }
        output?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { await self?.receive(data) }
        }
        process = child
        do {
            try child.run()
            _ = try await request("initialize", params: ["clientInfo": ["name": "ai_switcher", "title": "AI Switcher", "version": "1.3.0"]])
            try write(["method": "initialized"])
        } catch {
            await stop()
            throw error
        }
    }

    public func readIdentity() async throws -> CodexIdentity {
        let data = try await request("account/read", params: ["refreshToken": false])
        struct Response: Decodable {
            struct AccountInfo: Decodable { let type: String; let email: String?; let planType: String? }
            let account: AccountInfo?
        }
        let response = try decode(Response.self, data)
        guard let account = response.account, account.type == "chatgpt" else { throw CodexQuotaError.notSignedIn }
        return CodexIdentity(email: account.email, planType: account.planType)
    }

    public func readLimits() async throws -> CodexRateLimits {
        try decode(CodexRateLimits.self, await request("account/rateLimits/read"))
    }

    public struct Login: Decodable, Sendable { public let loginId: String; public let authUrl: String }

    public func startLogin() async throws -> Login {
        try decode(Login.self, await request("account/login/start", params: ["type": "chatgpt"]))
    }

    public func waitForLogin(_ id: String, timeout: TimeInterval = 300) async throws {
        let data: Data
        if let early = loginEvents.removeValue(forKey: id) {
            data = early
        } else {
            data = try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { continuation in
                    loginWaiters[id] = continuation
                    loginDeadlines[id] = Task { [weak self] in
                        do { try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) }
                        catch { return }
                        await self?.finishLogin(id, result: .failure(CodexQuotaError.timeout))
                    }
                    if Task.isCancelled { finishLogin(id, result: .failure(CancellationError())) }
                }
            }, onCancel: { Task { await self.finishLogin(id, result: .failure(CancellationError())) } })
        }
        struct Completion: Decodable { let success: Bool }
        guard try decode(Completion.self, data).success else { throw CodexQuotaError.loginFailed }
    }

    public func cancelLogin(_ id: String) async {
        _ = try? await request("account/login/cancel", params: ["loginId": id])
        finishLogin(id, result: .failure(CancellationError()))
    }

    public func logout() async throws { _ = try await request("account/logout") }

    public func stop() async {
        let child = process
        output?.readabilityHandler = nil
        try? input?.close()
        try? output?.close()
        input = nil
        output = nil
        process = nil
        failAll(CodexQuotaError.disconnected)
        if let child, child.isRunning {
            child.terminate()
            for _ in 0..<20 {
                if !child.isRunning { return }
                // Cleanup must still complete after the caller was cancelled.
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if child.isRunning { Darwin.kill(child.processIdentifier, SIGKILL) }
        }
    }

    private func request(_ method: String, params: [String: Any]? = nil) async throws -> Data {
        try Task.checkCancellation()
        guard process?.isRunning == true else { throw CodexQuotaError.disconnected }
        nextID += 1
        let id = nextID
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                deadlines[id] = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: UInt64((self?.timeout ?? 20) * 1_000_000_000)) }
                    catch { return }
                    await self?.finish(id, result: .failure(CodexQuotaError.timeout))
                }
                do {
                    var message: [String: Any] = ["id": id, "method": method]
                    if let params { message["params"] = params }
                    try write(message)
                    if Task.isCancelled { finish(id, result: .failure(CancellationError())) }
                } catch { finish(id, result: .failure(error)) }
            }
        }, onCancel: { Task { await self.finish(id, result: .failure(CancellationError())) } })
    }

    private func write(_ object: [String: Any]) throws {
        guard let input else { throw CodexQuotaError.disconnected }
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0a)
        try input.write(contentsOf: data)
    }

    private func receive(_ data: Data) {
        guard !data.isEmpty else {
            output?.readabilityHandler = nil
            failAll(CodexQuotaError.disconnected)
            return
        }
        buffer.append(data)
        guard buffer.count <= 8_388_608 else {
            output?.readabilityHandler = nil
            buffer.removeAll()
            failAll(CodexQuotaError.invalidResponse)
            return
        }
        while let end = buffer.firstIndex(of: 0x0a) {
            let line = Data(buffer[..<end])
            buffer.removeSubrange(...end)
            guard !line.isEmpty else { continue }
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                failAll(CodexQuotaError.invalidResponse); continue
            }
            if let id = object["id"] as? Int, object["method"] == nil {
                if let error = object["error"] as? [String: Any] {
                    let code = error["code"] as? Int ?? -1
                    finish(id, result: .failure(code == -32601 ? CodexQuotaError.unsupportedCLI : CodexQuotaError.rpc(code)))
                } else if let result = object["result"], let data = try? JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed]) {
                    finish(id, result: .success(data))
                } else { finish(id, result: .failure(CodexQuotaError.invalidResponse)) }
            } else if object["method"] as? String == "account/login/completed",
                      let params = object["params"] as? [String: Any], let id = params["loginId"] as? String,
                      let data = try? JSONSerialization.data(withJSONObject: params) {
                if loginWaiters[id] != nil { finishLogin(id, result: .success(data)) }
                else {
                    if loginEvents.count >= 8 { loginEvents.removeAll() }
                    loginEvents[id] = data
                }
            } else if let id = object["id"] {
                // This integration never accepts server-initiated actions.
                try? write(["id": id, "error": ["code": -32601, "message": "Unsupported in quota reader"]])
            }
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw CodexQuotaError.invalidResponse }
    }

    private func finish(_ id: Int, result: Result<Data, Error>) {
        deadlines.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(with: result)
    }

    private func finishLogin(_ id: String, result: Result<Data, Error>) {
        loginDeadlines.removeValue(forKey: id)?.cancel()
        loginWaiters.removeValue(forKey: id)?.resume(with: result)
    }

    private func failAll(_ error: Error) {
        for id in Array(pending.keys) { finish(id, result: .failure(error)) }
        for id in Array(loginWaiters.keys) { finishLogin(id, result: .failure(error)) }
    }
}

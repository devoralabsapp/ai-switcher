import Foundation
import Darwin

/// A bounded JSON pipe. The provider adapter supplies fixed read-only commands, never model prompts.
public actor ProviderCLICommand {
    private var child: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var lines: [Data] = []
    private var ended = false
    private var waiter: CheckedContinuation<Data?, Error>?
    private var deadline: Task<Void, Never>?
    public init() {}
    public func start(executable: URL, arguments: [String], environment: [String: String], directory: URL) throws {
        try Task.checkCancellation()
        let process = Process(), stdin = Pipe(), stdout = Pipe()
        process.executableURL = executable; process.arguments = arguments; process.environment = environment; process.currentDirectoryURL = directory
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = FileHandle.nullDevice
        child = process; input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading
        output?.readabilityHandler = { [weak self] file in let bytes = file.availableData; Task { await self?.receive(bytes) } }
        do { try process.run() } catch { output?.readabilityHandler = nil; throw error }
    }
    private func receive(_ bytes: Data) {
        if ended { return }
        if bytes.isEmpty { ended = true; if !buffer.isEmpty { lines.append(buffer); buffer.removeAll() }; deliver(); return }
        buffer.append(bytes)
        guard buffer.count + lines.reduce(0, { $0 + $1.count }) <= 1_048_576 else { finish(error: ProviderQuotaError.invalidResponse); return }
        while let index = buffer.firstIndex(of: 10) { let line = Data(buffer[..<index]); buffer.removeSubrange(...index); if !line.isEmpty { lines.append(line) } }
        deliver()
    }
    private func deliver() { if let waiting = waiter, !lines.isEmpty { waiter = nil; deadline?.cancel(); waiting.resume(returning: lines.removeFirst()) } else if let waiting = waiter, ended { waiter = nil; deadline?.cancel(); waiting.resume(returning: nil) } }
    private func finish(error: Error) { ended = true; let waiting = waiter; waiter = nil; deadline?.cancel(); waiting?.resume(throwing: error); if let child, child.isRunning { child.terminate() } }
    public func next(timeout: TimeInterval = 30) async throws -> Data? {
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            if !lines.isEmpty { return lines.removeFirst() }; if ended { return nil }
            return try await withCheckedThrowingContinuation { continuation in
                waiter = continuation
                deadline = Task { [weak self] in do { try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)); await self?.finish(error: ProviderQuotaError.timeout) } catch {} }
            }
        }, onCancel: { Task { await self.finish(error: CancellationError()) } })
    }
    public func send(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object); data.append(10); try input?.write(contentsOf: data)
    }
    public func closeInput() { try? input?.close(); input = nil }
    public func stop() async {
        finish(error: CancellationError()); output?.readabilityHandler = nil; try? input?.close(); try? output?.close(); input = nil; output = nil
        if let child, child.isRunning { child.terminate(); try? await Task.sleep(nanoseconds: 200_000_000); if child.isRunning { Darwin.kill(child.processIdentifier, SIGKILL) } }
        child = nil
    }
    public func collect(timeout: TimeInterval = 30) async throws -> Data {
        var result = Data()
        while let line = try await next(timeout: timeout) { guard result.count + line.count < 1_048_576 else { throw ProviderQuotaError.invalidResponse }; result.append(line); result.append(10) }
        return result
    }
    public func claudeControl(_ subtype: String) async throws -> Data {
        let id = UUID().uuidString
        var request: [String: Any] = ["subtype": subtype]
        if subtype == "get_usage" { request["skip_behaviors"] = true }
        try send(["type": "control_request", "request_id": id, "request": request])
        for _ in 0..<64 {
            guard let line = try await next(), let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw ProviderQuotaError.invalidResponse }
            guard object["type"] as? String == "control_response", let response = object["response"] as? [String: Any], response["request_id"] as? String == id else { continue }
            guard response["subtype"] as? String == "success", let payload = response["response"] as? [String: Any] else { throw ProviderQuotaError.cliOutdated }
            return try JSONSerialization.data(withJSONObject: payload)
        }
        throw ProviderQuotaError.invalidResponse
    }
}

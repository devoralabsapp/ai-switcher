import Foundation
import CryptoKit
import Darwin

/// WebSocket framing for the Desktop daemon's local Unix socket. No remote listener.
public enum LocalWebSocket {
    public static let maximumMessage = 8_388_608

    public static func acceptKey(_ key: String) -> String {
        Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
    }

    public static func frame(_ payload: Data, opcode: UInt8 = 1, mask: [UInt8]) throws -> Data {
        guard payload.count <= maximumMessage, mask.count == 4 else { throw CodexQuotaError.invalidResponse }
        var result = Data([0x80 | opcode])
        if payload.count < 126 { result.append(0x80 | UInt8(payload.count)) }
        else if payload.count <= 65_535 {
            result.append(0xfe)
            result.append(UInt8(payload.count >> 8)); result.append(UInt8(payload.count & 255))
        } else {
            result.append(0xff)
            let length = UInt64(payload.count)
            for shift in stride(from: 56, through: 0, by: -8) { result.append(UInt8((length >> shift) & 255)) }
        }
        result.append(contentsOf: mask)
        result.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        return result
    }

    /// Runs only in the quota bridge child, relaying JSONL to WebSocket messages.
    public static func run(socketPath: String) throws {
        let connection = try UnixWebSocketConnection(path: socketPath)
        defer { connection.close() }
        try connection.handshake()
        let writer = Thread {
            do {
                var buffer = Data()
                while true {
                    let chunk = FileHandle.standardInput.availableData
                    if chunk.isEmpty { break }
                    buffer.append(chunk)
                    guard buffer.count <= maximumMessage else { throw CodexQuotaError.invalidResponse }
                    while let end = buffer.firstIndex(of: 10) {
                        let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
                        if !line.isEmpty { try connection.send(line) }
                    }
                }
            } catch { }
            connection.close()
        }
        writer.start()
        var message = Data(), receiving = false
        while true {
            let header = try connection.read(2), bytes = Array(header)
            let opcode = bytes[0] & 15, final = bytes[0] & 128 != 0
            guard bytes[0] & 112 == 0, bytes[1] & 128 == 0 else { throw CodexQuotaError.invalidResponse }
            var count = UInt64(bytes[1] & 127)
            if count == 126 { count = try connection.read(2).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } }
            if count == 127 { count = try connection.read(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } }
            guard count <= maximumMessage, opcode < 8 || (final && count <= 125) else { throw CodexQuotaError.invalidResponse }
            let payload = try connection.read(Int(count))
            switch opcode {
            case 8: return
            case 9: try connection.send(payload, opcode: 10)
            case 10: break
            case 0, 1:
                guard opcode == 0 ? receiving : !receiving else { throw CodexQuotaError.invalidResponse }
                message.append(payload)
                guard message.count <= maximumMessage else { throw CodexQuotaError.invalidResponse }
                receiving = !final
                if final {
                    guard String(data: message, encoding: .utf8) != nil else { throw CodexQuotaError.invalidResponse }
                    message.append(10)
                    try FileHandle.standardOutput.write(contentsOf: message)
                    message.removeAll(keepingCapacity: true)
                }
            default: throw CodexQuotaError.invalidResponse
            }
        }
    }
}

private final class UnixWebSocketConnection: @unchecked Sendable {
    private let descriptor: Int32
    private let lock = NSLock()
    private var closed = false

    init(path: String) throws {
        let target = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
        guard attributes[.type] as? FileAttributeType == .typeSocket,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid(), path.hasPrefix("/"),
              path.utf8.count < 104 else { throw CodexQuotaError.disconnected }
        descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw CodexQuotaError.disconnected }
        var flag: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &flag, socklen_t(MemoryLayout.size(ofValue: flag)))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { storage in
            storage.copyBytes(from: Array(path.utf8) + [0])
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { Darwin.close(descriptor); throw CodexQuotaError.disconnected }
    }

    deinit { Darwin.close(descriptor) }

    func close() {
        lock.lock(); defer { lock.unlock() }
        if !closed { closed = true; Darwin.shutdown(descriptor, SHUT_RDWR) }
    }

    func handshake() throws {
        let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        try write(Data("GET /rpc HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n".utf8))
        var response = Data()
        while !response.suffix(4).elementsEqual([13, 10, 13, 10]) {
            response.append(try read(1))
            guard response.count <= 16_384 else { throw CodexQuotaError.invalidResponse }
        }
        let lines = String(decoding: response, as: UTF8.self).components(separatedBy: "\r\n")
        let headers = lines.dropFirst().compactMap { line -> (String, String)? in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            return (line[..<colon].lowercased(), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
        guard lines.first?.hasPrefix("HTTP/1.1 101 ") == true,
              headers.contains(where: { $0.0 == "sec-websocket-accept" && $0.1 == LocalWebSocket.acceptKey(key) }),
              headers.contains(where: { $0.0 == "upgrade" && $0.1.lowercased() == "websocket" }) else {
            throw CodexQuotaError.invalidResponse
        }
    }

    func send(_ payload: Data, opcode: UInt8 = 1) throws {
        let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
        lock.lock(); defer { lock.unlock() }
        guard !closed else { throw CodexQuotaError.disconnected }
        try write(LocalWebSocket.frame(payload, opcode: opcode, mask: mask))
    }

    func read(_ count: Int) throws -> Data {
        var result = Data(count: count), offset = 0
        while offset < count {
            let n = result.withUnsafeMutableBytes { Darwin.recv(descriptor, $0.baseAddress!.advanced(by: offset), count - offset, 0) }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw CodexQuotaError.disconnected }
            offset += n
        }
        return result
    }

    private func write(_ data: Data) throws {
        var offset = 0
        while offset < data.count {
            let n = data.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress!.advanced(by: offset), data.count - offset, 0) }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw CodexQuotaError.disconnected }
            offset += n
        }
    }
}

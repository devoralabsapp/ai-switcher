import XCTest
@testable import AISwitcherCore

final class LocalWebSocketTests: XCTestCase {
    func testRFCHandshakeExample() {
        XCTAssertEqual(LocalWebSocket.acceptKey("dGhlIHNhbXBsZSBub25jZQ=="), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }

    func testClientFramesAreMaskedAcrossLengthBoundaries() throws {
        for count in [0, 125, 126, 65_535, 65_536] {
            let data = Data(repeating: 42, count: count), mask: [UInt8] = [1, 2, 3, 4]
            let framed = Array(try LocalWebSocket.frame(data, mask: mask))
            XCTAssertEqual(framed[0], 0x81)
            let header = count < 126 ? 2 : count <= 65_535 ? 4 : 10
            XCTAssertEqual(framed[1], count < 126 ? 0x80 | UInt8(count) : count <= 65_535 ? 0xfe : 0xff)
            XCTAssertEqual(Array(framed[header..<(header + 4)]), mask)
            XCTAssertEqual(Data(framed.dropFirst(header + 4).enumerated().map { $0.element ^ mask[$0.offset % 4] }), data)
            if count >= 126 {
                XCTAssertEqual(framed[2..<header].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }, UInt64(count))
            }
        }
    }

    func testOversizedMessagesAndInvalidMasksAreRejected() {
        XCTAssertThrowsError(try LocalWebSocket.frame(Data(repeating: 0, count: LocalWebSocket.maximumMessage + 1), mask: [0, 0, 0, 0]))
        XCTAssertThrowsError(try LocalWebSocket.frame(Data(), mask: []))
    }

    func testBridgeHandlesFragmentedMessagesAndPingWithRealJSONLClient() async throws {
        let root = URL(fileURLWithPath: "/tmp/aw-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let socket = root.appendingPathComponent("socket")
        let fixture = Bundle.module.url(forResource: "local_websocket", withExtension: "py", subdirectory: "Fixtures")!
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-u", fixture.path, socket.path]
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.standardError
        try server.run()
        defer { if server.isRunning { server.terminate() } }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: socket.path) { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let binary = project.appendingPathComponent(".build/debug/AISwitcher")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: binary.path))
        let client = CodexRPCClient(executable: binary, home: root, arguments: ["--quota-socket-bridge", socket.path], timeout: 3)
        do {
            try await client.start()
            let identity = try await client.readIdentity(), limits = try await client.readLimits()
            XCTAssertEqual(identity.email, "bridge@example.test")
            XCTAssertEqual(limits.buckets.first?.value.primary?.remainingPercent, 77)
            await client.stop()
        } catch { await client.stop(); throw error }
    }
}

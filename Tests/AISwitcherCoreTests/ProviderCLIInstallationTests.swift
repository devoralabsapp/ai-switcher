import XCTest
@testable import AISwitcherCore

final class ProviderCLIInstallationTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ai-switcher-install ' quoted-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    func testOfficialSourcesAndPrivateLaunchersNeedNoPackageManagerOrAdmin() throws {
        let root = try root();defer { try? FileManager.default.removeItem(at: root) }
        for agent in [AIAgent.claude, .antigravity] {
            let job = try ProviderCLIInstallation(agent: agent, root: root);try job.prepare()
            XCTAssertEqual(job.installerURL.absoluteString, agent == .claude ? "https://claude.ai/install.sh" : "https://antigravity.google/cli/install.sh")
            XCTAssertFalse(job.script.contains("sudo "));XCTAssertFalse(job.script.contains("npm install"));XCTAssertFalse(job.script.contains("auth login"))
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: job.launcher.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
            let process = Process();process.executableURL = URL(fileURLWithPath: "/bin/bash");process.arguments = ["-n", job.launcher.path]
            try process.run();process.waitUntilExit();XCTAssertEqual(process.terminationStatus, 0)
        }
        XCTAssertThrowsError(try ProviderCLIInstallation(agent: .chatgpt, root: root))
    }
    func testGeneratedLauncherRecordsDownloadAndInstallerFailuresInsteadOfFalseSuccess() async throws {
        let root = try root();defer { try? FileManager.default.removeItem(at: root) }
        for scenario in ["success", "download-error", "installer-error"] {
            let job = try ProviderCLIInstallation(agent: .antigravity, root: root);try job.prepare()
            let curl = root.appendingPathComponent("fixture-curl")
            let fake = """
            #!/usr/bin/python3
            import sys,pathlib
            if '\(scenario)'=='download-error': sys.exit(22)
            target=sys.argv[sys.argv.index('--output')+1]
            pathlib.Path(target).write_text('#!/bin/bash\\nexit \(scenario == "installer-error" ? 27 : 0)\\n')
            """
            try fake.write(to: curl, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: curl.path)
            let quoted = "'" + curl.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            // Only the test copy replaces the downloader. Production has a fixed official URL.
            try job.script.replacingOccurrences(of: "/usr/bin/curl", with: quoted).write(to: job.launcher, atomically: true, encoding: .utf8)
            let process = Process();process.executableURL = URL(fileURLWithPath: "/bin/bash");process.arguments = [job.launcher.path]
            process.standardOutput = FileHandle.nullDevice;process.standardError = FileHandle.nullDevice
            try process.run();process.waitUntilExit()
            if scenario == "success" { try await job.wait(timeout: 2);XCTAssertEqual(process.terminationStatus, 0) }
            else {
                do { try await job.wait(timeout: 2);XCTFail("Installer failure must not connect") }
                catch { XCTAssertTrue(error is ProviderCLIInstallationError) }
                XCTAssertNotEqual(process.terminationStatus, 0)
            }
            job.cleanupIfFinished();XCTAssertFalse(FileManager.default.fileExists(atPath: job.directory.path))
        }
    }
    func testCancellationAndMalformedCompletionNeverDeleteAnUnfinishedInstaller() async throws {
        let root = try root();defer { try? FileManager.default.removeItem(at: root) }
        let job = try ProviderCLIInstallation(agent: .claude, root: root);try job.prepare()
        let waiting = Task { try await job.wait() };waiting.cancel()
        do { try await waiting.value;XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        job.cleanupIfFinished();XCTAssertTrue(FileManager.default.fileExists(atPath: job.launcher.path))
        for text in ["invalid", String(repeating: "0", count: 33)] {
            try text.write(to: job.result, atomically: true, encoding: .utf8)
            do { try await job.wait(timeout: 2);XCTFail("Invalid marker must fail") } catch { XCTAssertTrue(error is ProviderCLIInstallationError) }
        }
    }
}

import XCTest
@testable import AISwitcherCore
@testable import AISwitcher

final class AntigravityProfileTests: XCTestCase {
    private func fixtureRoot() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("Antigravity's Profiles \(UUID())") }

    func testPrivateHomesPersistAndDeletingOneProfilePreservesTheOther() throws {
        let root = fixtureRoot();defer { try? FileManager.default.removeItem(at: root) }
        let repo = ProfileRepository(root: root), a = UUID(), b = UUID()
        for (id, text) in [(a,"A"),(b,"B")] {
            try repo.prepareAntigravityProfile(for: id)
            try Data(text.utf8).write(to: repo.antigravityIdentityURL(for: id))
        }
        try repo.prepareAntigravityProfile(for: a)
        XCTAssertEqual(try Data(contentsOf: repo.antigravityIdentityURL(for: a)), Data("A".utf8))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: repo.antigravityHomeURL(for: a).path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        _ = try repo.remove(a, from: .init())
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.antigravityProfileURL(for: a).path))
        XCTAssertEqual(try Data(contentsOf: repo.antigravityIdentityURL(for: b)), Data("B".utf8))
    }

    func testForgedOwnerAndRedirectedAuthenticationStorageAreRejected() throws {
        let root = fixtureRoot();defer { try? FileManager.default.removeItem(at: root) }
        let repo = ProfileRepository(root: root), id = UUID(), fm = FileManager.default
        try repo.prepareAntigravityProfile(for: id)
        let marker = repo.antigravityProfileURL(for: id).appendingPathComponent("ai-switcher-profile.json")
        let original = try Data(contentsOf: marker)
        try Data("{}".utf8).write(to: marker)
        XCTAssertThrowsError(try repo.prepareAntigravityProfile(for: id))
        XCTAssertThrowsError(try repo.remove(id, from: .init()))
        try original.write(to: marker)
        let shared = root.appendingPathComponent("unrelated")
        try fm.createDirectory(at: shared, withIntermediateDirectories: true)
        let gemini = repo.antigravityHomeURL(for: id).appendingPathComponent(".gemini")
        try fm.removeItem(at: gemini);try fm.createSymbolicLink(at: gemini, withDestinationURL: shared)
        XCTAssertThrowsError(try repo.prepareAntigravityProfile(for: id))
        XCTAssertThrowsError(try repo.remove(id, from: .init()))
        XCTAssertTrue(fm.fileExists(atPath: shared.path))
    }

    @MainActor
    func testOfficialCLIReadsEachHomesIdentityAndQuotaAndLoginUsesTheSameHome() async throws {
        let root = fixtureRoot();defer { try? FileManager.default.removeItem(at: root) }
        let repo = ProfileRepository(root: root), fm = FileManager.default
        let a = Account(name: "A", agent: .antigravity, antigravityUsesPrivateHome: true)
        let b = Account(name: "B", agent: .antigravity, antigravityUsesPrivateHome: true)
        for (account, email, percent) in [(a,"a@example.test",0.99),(b,"b@example.test",0.91)] {
            try repo.prepareAntigravityProfile(for: account.id)
            func base64(_ object: [String: Any]) throws -> String {
                try JSONSerialization.data(withJSONObject: object).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            }
            let token = try base64(["alg":"RS256"]) + "." + base64(["iss":"https://accounts.google.com", "email":email,"email_verified":true,"sub":account.id.uuidString]) + ".fixture"
            try JSONSerialization.data(withJSONObject: ["auth_method":"consumer", "id_token":token]).write(to: repo.antigravityIdentityURL(for: account.id))
            try String(percent).write(to: repo.antigravityHomeURL(for: account.id).appendingPathComponent("percent"), atomically: true, encoding: .utf8)
        }
        let executable = root.appendingPathComponent("agy-fixture")
        let script = """
        #!/usr/bin/python3
        import os,sys,json,pathlib
        if sys.argv[1:]==['--version']: print('1.4.9');sys.exit()
        home=pathlib.Path(os.environ['HOME'])
        assert os.environ['CFFIXED_USER_HOME']==str(home)
        if not sys.argv[1:]: (home/'login-home').write_text(str(home));sys.exit()
        assert sys.argv[1:]==['-p','/usage','--output-format','json']
        print(json.dumps({'num_turns':0,'command':{'name':'usage','data':{'groups':[{'name':'Gemini models','buckets':[{'id':'gemini-weekly','remaining_fraction':float((home/'percent').read_text())}]}]}}}))
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        // This tempting shared record must never be read for private accounts.
        let shared = root.appendingPathComponent("shared-identity")
        try Data("shared-invalid".utf8).write(to: shared)
        let service = ProviderQuotaService(repository: repo, antigravityIdentityURL: shared)
        for (account, email, percent) in [(a,"a@example.test",99.0),(b,"b@example.test",91.0)] {
            let result = try await service.read(account, override: executable.path)
            XCTAssertEqual(result.identity.email, email)
            XCTAssertEqual(try XCTUnwrap(result.quota?.limits.buckets.first?.value.primary?.remainingPercent), percent, accuracy: 0.001)
            let login = try await service.prepareSignInScript(account, override: executable.path)
            let process = Process();process.executableURL = URL(fileURLWithPath: "/bin/sh");process.arguments = [login.path]
            try process.run();process.waitUntilExit();XCTAssertEqual(process.terminationStatus,0)
            XCTAssertEqual(try String(contentsOf: repo.antigravityHomeURL(for: account.id).appendingPathComponent("login-home"), encoding: .utf8), repo.antigravityHomeURL(for: account.id).path)
        }
        XCTAssertEqual(try Data(contentsOf: shared), Data("shared-invalid".utf8))
    }

    func testRoutingAndEnvironmentNeverReuseSharedAuthOrRemoteBackend() {
        let home = URL(fileURLWithPath: "/fixture/A"), data = home.appendingPathComponent("UserData")
        let args = AntigravityLaunch.arguments(userData: data)
        XCTAssertTrue(AntigravityLaunch.ownsProcess(arguments: args, userData: data))
        XCTAssertFalse(AntigravityLaunch.ownsProcess(arguments: args, userData: home.appendingPathComponent("B")))
        XCTAssertFalse(AntigravityLaunch.ownsProcess(arguments: args + ["--type=renderer"], userData: data))
        let env = AntigravityLaunch.environment(base: ["HOME":"/shared", "PATH":"/usr/bin:/bin", "AGY_ADC_AUTH":"1", "GOOGLE_APPLICATION_CREDENTIALS":"/shared/secret", "GEMINI_API_KEY":"fixture", "JETSKI_LS_PORT":"12345", "CODEIUM_LANGUAGE_SERVER_BIN":"/wrong", "ELECTRON_RUN_AS_NODE":"1", "NODE_OPTIONS":"bad", "BASH_ENV":"/shared/rc"], home: home)
        XCTAssertEqual(env["HOME"],home.path)
        XCTAssertEqual(env["SHELL"],"/bin/sh")
        XCTAssertEqual(env["PATH"],"/usr/bin:/bin")
        for key in ["AGY_ADC_AUTH","GOOGLE_APPLICATION_CREDENTIALS","GEMINI_API_KEY","JETSKI_LS_PORT","CODEIUM_LANGUAGE_SERVER_BIN","ELECTRON_RUN_AS_NODE","NODE_OPTIONS","BASH_ENV"] { XCTAssertNil(env[key]) }
    }
}

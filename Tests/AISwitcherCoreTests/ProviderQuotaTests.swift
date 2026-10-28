import XCTest
@testable import AISwitcherCore
@testable import AISwitcher

final class ProviderQuotaTests: XCTestCase {
    private func parse(_ json: String, _ agent: AIAgent) throws -> CodexConnection {
        try ProviderQuotaParser.parse(Data(json.utf8), agent: agent, identity: CodexIdentity(email: agent == .claude ? "fixture@example.test" : nil, planType: nil), now: Date(timeIntervalSince1970: 1000))
    }
    func testClaudeSubscriptionWindowsPreserveZeroAndModelLimits() throws {
        let result = try parse(#"{"rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":100,"resets_at":"2030-01-01T00:00:00Z"},"seven_day":{"utilization":35},"model_scoped":[{"display_name":"Sonnet","utilization":12}],"extra_usage":{"utilization":50}}}"#, .claude)
        XCTAssertEqual(result.quota?.limits.buckets.count, 2)
        let bucket = result.quota?.limits.buckets.first { $0.id == "claude" }?.value
        XCTAssertEqual(bucket?.primary?.remainingPercent, 0)
        XCTAssertEqual(bucket?.secondary?.remainingPercent, 65)
        XCTAssertEqual(bucket?.primary?.resetsAt, 1893456000)
    }
    func testClaudeNeverTreatsCostTokensOrMissingWindowsAsQuota() {
        for json in [#"{"session":{"total_cost_usd":10,"total_tokens":100}}"#, #"{"rate_limits_available":false,"rate_limits":{"five_hour":{"utilization":5}}}"#, #"{"rate_limits":{"five_hour":{"utilization":null},"seven_day":{"utilization":true}}}"#] {
            XCTAssertThrowsError(try parse(json, .claude))
        }
    }
    func testAntigravityRealUsageEnvelopeAndZeroRemaining() throws {
        let value = try parse(#"{"num_turns":0,"usage":{"total_tokens":0},"command":{"name":"usage","data":{"groups":[{"name":"Models","buckets":[{"id":"model-five","name":"Pro","window":"weekly","remaining_fraction":0,"reset_time":"2030-01-01T00:00:00Z"},{"id":"flash","name":"Flash","remaining_fraction":0.75}]}]}}}"#, .antigravity)
        XCTAssertNil(value.identity.email)
        XCTAssertEqual(value.quota?.limits.buckets.count, 2)
        let zero = value.quota?.limits.buckets.first { $0.id == "model-five" }?.value.primary
        XCTAssertEqual(zero?.remainingPercent, 0)
        XCTAssertEqual(zero?.windowDurationMins, 10080)
        XCTAssertNil(value.quota?.limits.buckets.first { $0.id == "flash" }?.value.primary?.windowDurationMins)
    }
    func testAntigravityAbsoluteQuotaDoesNotInventPercentAndSkipsDisabled() throws {
        let value = try parse(#"{"quota":{"image":{"remaining_amount":12,"reset_in_seconds":100},"disabled":{"remaining_fraction":1,"disabled":true}}}"#, .antigravity)
        let window = value.quota?.limits.buckets.first?.value.primary
        XCTAssertEqual(window?.remainingAmount, 12)
        XCTAssertNil(window?.remainingPercent)
        XCTAssertEqual(window?.resetsAt, 1100)
        XCTAssertEqual(value.quota?.limits.buckets.count, 1)
    }
    func testInvalidFractionsAndModelTurnsCannotBecomeQuota() {
        for json in [#"{"quota":{"a":{"remaining_fraction":-1}}}"#, #"{"quota":{"a":{"remaining_fraction":1.1}}}"#, #"{"quota":{"a":{"remaining_fraction":true}}}"#, #"{"num_turns":1,"command":{"name":"usage","data":{"groups":[]}}}"#, #"{"response":"Remaining 90%"}"#] {
            XCTAssertThrowsError(try parse(json, .antigravity))
        }
    }
    func testCLICompatibilityBlocksModelTurnFallback() {
        XCTAssertTrue(ProviderCLIConfiguration.accepts(version: "2.1.295 (Claude Code)", agent: .claude))
        XCTAssertFalse(ProviderCLIConfiguration.accepts(version: "2.1.269 (Claude Code)", agent: .claude))
        XCTAssertFalse(ProviderCLIConfiguration.accepts(version: "2.1.295 (Other app)", agent: .claude))
        XCTAssertTrue(ProviderCLIConfiguration.accepts(version: "1.4.9\n", agent: .antigravity))
        XCTAssertFalse(ProviderCLIConfiguration.accepts(version: "1.1.10", agent: .antigravity))
    }
    func testProviderMetadataRoundTripAndOldAccountCompatibility() throws {
        var account = Account(name: "Claude", agent: .claude)
        account.providerQuotaConnection = try parse(#"{"rate_limits":{"five_hour":{"utilization":23}}}"#, .claude)
        let data = try JSONEncoder().encode(account)
        let copy = try JSONDecoder().decode(Account.self, from: data)
        XCTAssertEqual(copy.displayedCodexConnection?.quota?.limits.buckets.first?.value.primary?.remainingPercent, 77)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]);object.removeValue(forKey: "providerQuotaConnection")
        XCTAssertNil(try JSONDecoder().decode(Account.self, from: JSONSerialization.data(withJSONObject: object)).providerQuotaConnection)
    }
    func testClaudeControlPipeUsesNoUserPromptAndSkipsHistory() async throws {
        let script = """
        import sys,json
        initialized=False
        for line in sys.stdin:
            x=json.loads(line); r=x['request']; s=r['subtype']
            assert x['type']=='control_request'
            if s=='initialize': initialized=True; value={}
            else:
                assert initialized and s=='get_usage' and r['skip_behaviors']==True
                value={'rate_limits_available':True,'rate_limits':{'five_hour':{'utilization':100}}}
            print(json.dumps({'type':'control_response','response':{'subtype':'success','request_id':x['request_id'],'response':value}}),flush=True)
        """
        let pipe = ProviderCLICommand()
        do {
            try await pipe.start(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", script], environment: ["PATH": "/usr/bin:/bin"], directory: FileManager.default.temporaryDirectory)
            _ = try await pipe.claudeControl("initialize")
            let value = try await pipe.claudeControl("get_usage")
            XCTAssertEqual(try ProviderQuotaParser.parse(value, agent: .claude, identity: CodexIdentity(email: "fixture@example.test", planType: nil)).quota?.limits.buckets.first?.value.primary?.remainingPercent, 0)
            await pipe.stop()
        } catch { await pipe.stop();throw error }
    }
    @MainActor
    func testClaudeProductionAdapterPinsPrivateConfigAndRejectsWrongEmail() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ai-switcher-provider-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("claude-fixture")
        let script = """
        #!/usr/bin/python3
        import sys,os,json
        if sys.argv[1:]==['--version']:
            print('2.1.295 (Claude Code)');sys.exit()
        if sys.argv[1:]==['auth','status']:
            print(json.dumps({'loggedIn':True,'authMethod':'claude.ai','email':'fixture@example.test','configDirectory':os.environ['CLAUDE_CONFIG_DIR']}));sys.exit()
        for line in sys.stdin:
            x=json.loads(line);s=x['request']['subtype']
            assert x['type']=='control_request'
            if s=='get_usage': assert x['request']['skip_behaviors']
            value={} if s=='initialize' else {'rate_limits_available':True,'rate_limits':{'five_hour':{'utilization':23}}}
            print(json.dumps({'type':'control_response','response':{'subtype':'success','request_id':x['request_id'],'response':value}}),flush=True)
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let service = ProviderQuotaService(repository: ProfileRepository(root: root))
        var account = Account(name: "Fixture", emailHint: "fixture@example.test", agent: .claude)
        let result = try await service.read(account, override: executable.path)
        XCTAssertEqual(result.identity.email, "fixture@example.test")
        XCTAssertEqual(result.quota?.limits.buckets.first?.value.primary?.remainingPercent, 77)
        account.emailHint = "someone-else@example.test"
        do { _ = try await service.read(account, override: executable.path);XCTFail("Wrong account must be rejected") }
        catch { XCTAssertEqual(error as? ProviderQuotaError, .identityChanged) }
    }
    private func temporaryCLI() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ai-switcher-cli-path-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func fixtureExecutable(_ url: URL, version: String = "2.1.295 (Claude Code)") throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let script = "#!/bin/sh\nif [ \"$1\" = --version ]; then printf '%s\\n' '" + version + "'; exit 0; fi\nexit 27\n"
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
    private func fixtureBundle(_ root: URL, identifier: String) throws -> URL {
        let exe = root.appendingPathComponent("Contents/MacOS/claude")
        try fixtureExecutable(exe)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": identifier], format: .xml, options: 0)
        try plist.write(to: root.appendingPathComponent("Contents/Info.plist"))
        return exe
    }
    @MainActor
    func testDirectoriesDesktopAppsAndTheirSymlinksCannotBeQuotaExecutables() throws {
        let root = try temporaryCLI();defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Claude.app")
        let desktop = try fixtureBundle(app, identifier: "com.anthropic.claudefordesktop")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: app.path))
        for path in [root, app, desktop] { XCTAssertFalse(ProviderQuotaService.isCLIExecutable(path, agent: .claude)) }
        let link = root.appendingPathComponent("claude-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: desktop)
        XCTAssertFalse(ProviderQuotaService.isCLIExecutable(link, agent: .claude))
    }
    @MainActor
    func testNativeCLIAndItsSymlinksAreAcceptedWithoutAcceptingDesktop() throws {
        let root = try temporaryCLI();defer { try? FileManager.default.removeItem(at: root) }
        let cli = try fixtureBundle(root.appendingPathComponent("claude.app"), identifier: "com.anthropic.claude-code")
        let link = root.appendingPathComponent("claude")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: cli)
        XCTAssertTrue(ProviderQuotaService.isCLIExecutable(cli, agent: .claude))
        XCTAssertTrue(ProviderQuotaService.isCLIExecutable(link, agent: .claude))
        XCTAssertFalse(ProviderQuotaService.isCLIExecutable(cli, agent: .antigravity))
        let text = root.appendingPathComponent("not-executable");try Data().write(to: text)
        XCTAssertFalse(ProviderQuotaService.isCLIExecutable(text, agent: .claude))
    }
    @MainActor
    func testInvalidSavedAppSelectionRecoversToDiscoveredCLIForBothProviders() throws {
        let root = try temporaryCLI();defer { try? FileManager.default.removeItem(at: root) }
        for agent in [AIAgent.claude, .antigravity] {
            let app = root.appendingPathComponent(agent.name + ".app")
            try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
            let cli = root.appendingPathComponent(agent.rawValue + "-cli");try fixtureExecutable(cli)
            XCTAssertEqual(try ProviderQuotaService.resolveExecutable(agent, override: app.path, candidates: [app, cli]), cli)
            XCTAssertEqual(try ProviderQuotaService.resolveExecutable(agent, override: cli.path, candidates: []), cli)
            XCTAssertThrowsError(try ProviderQuotaService.resolveExecutable(agent, override: app.path, candidates: [app])) { XCTAssertEqual($0 as? ProviderQuotaError, .cliMissing) }
        }
    }
    @MainActor
    func testLoginPreflightRejectsWrongCLIWithoutWritingLauncher() async throws {
        let root = try temporaryCLI();defer { try? FileManager.default.removeItem(at: root) }
        let cli = root.appendingPathComponent("wrong-cli");try fixtureExecutable(cli, version: "Unrelated program 2.1.295")
        let repo = ProfileRepository(root: root.appendingPathComponent("Data"))
        let account = Account(name: "Fixture", agent: .claude)
        do { _ = try await ProviderQuotaService(repository: repo).prepareSignInScript(account, override: cli.path);XCTFail("Expected CLI validation failure") }
        catch { XCTAssertEqual(error as? ProviderQuotaError, .cliOutdated) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.root.appendingPathComponent("provider-login-\(account.id.uuidString).command").path))
    }
    @MainActor
    func testLoginLauncherUsesValidatedCLIAndQuotesPaths() async throws {
        let root = try temporaryCLI();defer { try? FileManager.default.removeItem(at: root) }
        let cli = root.appendingPathComponent("Claude Code's CLI");try fixtureExecutable(cli)
        let repo = ProfileRepository(root: root.appendingPathComponent("Profile Data"))
        let account = Account(name: "Fixture", agent: .claude)
        let script = try await ProviderQuotaService(repository: repo).prepareSignInScript(account, override: cli.path)
        let text = try String(contentsOf: script, encoding: .utf8)
        XCTAssertTrue(text.contains(" auth login"));XCTAssertTrue(text.contains("CLAUDE_CONFIG_DIR="))
        XCTAssertTrue(text.contains("'\\''"))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: script.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let check = Process();check.executableURL = URL(fileURLWithPath: "/bin/sh");check.arguments = ["-n", script.path]
        try check.run();check.waitUntilExit();XCTAssertEqual(check.terminationStatus, 0)
    }
    @MainActor
    func testInstalledClaudeCLIRecoversSavedDesktopAppSelection() async throws {
        guard ProcessInfo.processInfo.environment["AISWITCHER_TEST_INSTALLED_PROVIDER_CLI"] == "1" else { throw XCTSkip("Enable explicitly to check the installed CLI's version only") }
        let root = try temporaryCLI();defer { try? FileManager.default.removeItem(at: root) }
        let repo = ProfileRepository(root: root.appendingPathComponent("Private Fixture"))
        let service = ProviderQuotaService(repository: repo)
        let app = "/Applications/Claude.app"
        let cli = try service.executable(.claude, override: app)
        XCTAssertNotEqual(cli.path, app)
        XCTAssertTrue(ProviderQuotaService.isCLIExecutable(cli, agent: .claude))
        let account = Account(name: "Fixture", agent: .claude)
        let script = try await service.prepareSignInScript(account, override: app)
        XCTAssertTrue(try String(contentsOf: script, encoding: .utf8).contains(" auth login"))
        // The launcher is inspected only. Never open Terminal or start a real login from a test.
    }
    func testProviderPipeTimeoutClosesOwnedProcess() async throws {
        let pipe = ProviderCLICommand()
        try await pipe.start(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [], environment: [:], directory: FileManager.default.temporaryDirectory)
        do { _ = try await pipe.next(timeout: 0.05);XCTFail("Expected timeout") }
        catch { XCTAssertEqual(error as? ProviderQuotaError, .timeout) }
        await pipe.stop()
    }
}

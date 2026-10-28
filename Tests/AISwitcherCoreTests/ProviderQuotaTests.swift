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
    func testProviderPipeTimeoutClosesOwnedProcess() async throws {
        let pipe = ProviderCLICommand()
        try await pipe.start(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [], environment: [:], directory: FileManager.default.temporaryDirectory)
        do { _ = try await pipe.next(timeout: 0.05);XCTFail("Expected timeout") }
        catch { XCTAssertEqual(error as? ProviderQuotaError, .timeout) }
        await pipe.stop()
    }
}

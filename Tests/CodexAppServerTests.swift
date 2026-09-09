import XCTest
@testable import Codenotch

/// Drives the real session code against a fake `codex` executable.
///
/// Nothing here may reach a real Codex install, a real credential, or real
/// quota — the fake speaks the same newline-delimited JSON-RPC and records what
/// it was asked, which is the whole of what these tests need.
final class CodexAppServerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CodexAppServerTests.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    /// A fake `codex`. `rateLimits` is the raw JSON it answers
    /// `account/rateLimits/read` with; `account` likewise for `account/read`.
    private func makeFakeCodex(rateLimits: String = "{}",
                               account: String = "{}",
                               rateLimitsError: String? = nil) throws -> URL {
        let script = root.appendingPathComponent("codex")
        let errorBranch = rateLimitsError.map {
            "reply(mid, error={\"message\": \(jsonString($0))})"
        } ?? "reply(mid, result=\(rateLimits))"

        let source = """
        #!/usr/bin/env python3
        import sys, json, os

        if len(sys.argv) <= 1 or sys.argv[1] != "app-server":
            with open(os.environ["FAKE_CODEX_LOG"], "a") as log:
                log.write("ARGV " + json.dumps(sys.argv[1:]) + "\\n")
                log.write("HOME " + os.environ.get("CODEX_HOME", "") + "\\n")
            sys.stdout.write("OK")
            sys.exit(0)

        with open(os.environ["FAKE_CODEX_LOG"], "a") as log:
            log.write("HOME " + os.environ.get("CODEX_HOME", "") + "\\n")

        def reply(mid, result=None, error=None):
            payload = {"id": mid}
            if error is not None:
                payload["error"] = error
            else:
                payload["result"] = result
            sys.stdout.write(json.dumps(payload) + "\\n")
            sys.stdout.flush()

        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            message = json.loads(line)
            with open(os.environ["FAKE_CODEX_LOG"], "a") as log:
                log.write("RPC " + message.get("method", "") + "\\n")
            mid = message.get("id")
            if mid is None:
                continue
            method = message.get("method")
            if method == "initialize":
                reply(mid, result={})
            elif method == "account/rateLimits/read":
                \(errorBranch)
            elif method == "account/read":
                reply(mid, result=\(account))
            else:
                reply(mid, error={"message": "unexpected " + str(method)})
        """
        try source.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        setenv("FAKE_CODEX_LOG", root.appendingPathComponent("log.txt").path, 1)
        return script
    }

    private func jsonString(_ value: String) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: [value]), encoding: .utf8)!
            .dropFirst().dropLast().description
    }

    private func fakeLog() -> String {
        (try? String(contentsOf: root.appendingPathComponent("log.txt"), encoding: .utf8)) ?? ""
    }

    private var codexHome: URL { root.appendingPathComponent("codex-home") }

    // MARK: - Rate limits

    func testRateLimitsByLimitIdIsPreferredAndKeyedByTheMapKey() throws {
        let binary = try makeFakeCodex(rateLimits: """
        {"rateLimitsByLimitId": {
           "codex": {"primary": {"usedPercent": 22, "windowDurationMins": 300, "resetsAt": 2000},
                     "secondary": {"usedPercent": 44, "windowDurationMins": 10080, "resetsAt": 9000}}},
         "rateLimitResetCredits": {"availableCount": 3}}
        """)
        let session = try CodexAppServerSession(binary: binary, codexHome: codexHome)
        defer { session.shutdown() }

        let snapshot = try session.rateLimits(observedAt: 1_000)
        XCTAssertEqual(snapshot.observedAt, 1_000)
        // The bucket carried no `limitId`; the map key supplies it, and that id
        // is what every target lookup matches on.
        XCTAssertEqual(snapshot.buckets.map(\.limitId), ["codex"])
        XCTAssertEqual(snapshot.fiveHourWindow()?.usedPercent, 22)
        XCTAssertEqual(snapshot.weeklyWindow()?.usedPercent, 44)
        XCTAssertEqual(snapshot.rateLimitResetCredits?.availableCount, 3)
        // Observation time comes from the caller, not the wire.
        XCTAssertEqual(snapshot.weeklyWindow()?.observedAt, 1_000)
    }

    func testASingleRateLimitsObjectFallsBackToTheCodexId() throws {
        let binary = try makeFakeCodex(rateLimits: """
        {"rateLimits": {"primary": {"usedPercent": 5, "windowDurationMins": 300, "resetsAt": 2000},
                        "secondary": {"usedPercent": 6, "windowDurationMins": 10080, "resetsAt": 9000}}}
        """)
        let session = try CodexAppServerSession(binary: binary, codexHome: codexHome)
        defer { session.shutdown() }

        let snapshot = try session.rateLimits(observedAt: 1_000)
        XCTAssertEqual(snapshot.buckets.map(\.limitId), ["codex"])
        XCTAssertEqual(snapshot.weeklyWindow()?.usedPercent, 6)
    }

    /// A single read can never establish that a countdown is running — that is
    /// `reconcileSnapshot`'s job, against the previous observation.
    func testAFreshReadNeverClaimsACountdownIsRunning() throws {
        let binary = try makeFakeCodex(rateLimits: """
        {"rateLimits": {"limitId": "codex",
           "primary": {"usedPercent": 80, "windowDurationMins": 300, "resetsAt": 999999}}}
        """)
        let session = try CodexAppServerSession(binary: binary, codexHome: codexHome)
        defer { session.shutdown() }

        let snapshot = try session.rateLimits(observedAt: 1_000)
        XCTAssertFalse(snapshot.fiveHourWindow()?.countdownActive ?? true)
    }

    func testAnUnknownPercentageStaysUnknown() throws {
        let binary = try makeFakeCodex(rateLimits: """
        {"rateLimits": {"limitId": "codex",
           "primary": {"windowDurationMins": 300, "resetsAt": 2000}}}
        """)
        let session = try CodexAppServerSession(binary: binary, codexHome: codexHome)
        defer { session.shutdown() }

        XCTAssertNil(try session.rateLimits(observedAt: 1_000).fiveHourWindow()?.usedPercent)
    }

    func testARemoteErrorIsReportedRatherThanTreatedAsEmpty() throws {
        let binary = try makeFakeCodex(rateLimitsError: "not signed in")
        let session = try CodexAppServerSession(binary: binary, codexHome: codexHome)
        defer { session.shutdown() }

        XCTAssertThrowsError(try session.rateLimits(observedAt: 1_000)) { error in
            guard case CodexError.remote(_, let message) = error else {
                return XCTFail("expected a remote error, got \(error)")
            }
            XCTAssertEqual(message, "not signed in")
        }
    }

    // MARK: - Handshake and isolation

    func testItHandshakesBeforeAsking() throws {
        let binary = try makeFakeCodex()
        let session = try CodexAppServerSession(binary: binary, codexHome: codexHome)
        defer { session.shutdown() }
        _ = try? session.rateLimits(observedAt: 1)

        let log = fakeLog()
        let initialize = try XCTUnwrap(log.range(of: "RPC initialize"))
        let initialized = try XCTUnwrap(log.range(of: "RPC initialized"))
        let read = try XCTUnwrap(log.range(of: "RPC account/rateLimits/read"))
        XCTAssertTrue(initialize.lowerBound < initialized.lowerBound)
        XCTAssertTrue(initialized.lowerBound < read.lowerBound)
    }

    /// `CODEX_HOME` is the whole of the isolation between accounts.
    func testTheAccountsOwnHomeIsPassedToTheChild() throws {
        let binary = try makeFakeCodex()
        let session = try CodexAppServerSession(binary: binary, codexHome: codexHome)
        defer { session.shutdown() }
        XCTAssertTrue(fakeLog().contains("HOME \(codexHome.path)"), fakeLog())
    }

    // MARK: - Account

    func testAccountIsReadNestedOrFlattened() throws {
        let nested = try makeFakeCodex(account: #"{"account": {"email": "a@example.com", "planType": "pro"}}"#)
        let first = try CodexAppServerSession(binary: nested, codexHome: codexHome)
        XCTAssertEqual(try first.accountInfo(), CodexAccountInfo(email: "a@example.com", planType: "pro"))
        first.shutdown()

        let flat = try makeFakeCodex(account: #"{"email": "b@example.com", "planType": "plus"}"#)
        let second = try CodexAppServerSession(binary: flat, codexHome: codexHome)
        XCTAssertEqual(try second.accountInfo(), CodexAccountInfo(email: "b@example.com", planType: "plus"))
        second.shutdown()
    }

    // MARK: - Fingerprint

    func testFingerprintIsTwelveHexOfTheAccountIdAndNeverTheIdItself() throws {
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        let auth = #"{"tokens": {"account_id": "acct-12345", "access_token": "secret"}}"#
        try Data(auth.utf8).write(to: codexHome.appendingPathComponent("auth.json"))

        let fingerprint = try XCTUnwrap(CodexFingerprint.of(codexHome: codexHome))
        XCTAssertEqual(fingerprint.count, 12)
        XCTAssertTrue(fingerprint.allSatisfy(\.isHexDigit))
        XCTAssertFalse(fingerprint.contains("acct"))
        XCTAssertFalse(fingerprint.contains("secret"))
        // Stable, so an unchanged account keeps its state.
        XCTAssertEqual(CodexFingerprint.of(codexHome: codexHome), fingerprint)
    }

    func testAnAccountWithNoCredentialHasNoFingerprint() {
        XCTAssertNil(CodexFingerprint.of(codexHome: codexHome))
    }

    // MARK: - Poke

    func testPokeArgumentsAreTheAgreedMinimalRequest() {
        let args = CodexPoke.arguments(workingDirectory: URL(fileURLWithPath: "/tmp/work"))
        XCTAssertEqual(args.first, "exec")
        XCTAssertTrue(args.contains("--ephemeral"))
        XCTAssertTrue(args.contains("--sandbox"))
        XCTAssertTrue(args.contains("read-only"))
        XCTAssertTrue(args.contains(Quota.defaultModel))
        XCTAssertTrue(args.contains("approval_policy=\"never\""))
        XCTAssertTrue(args.contains("model_reasoning_effort=\"low\""))
        XCTAssertEqual(args.last, Quota.defaultPrompt)
        // An isolated home has no user config to ignore.
        XCTAssertFalse(args.contains("--ignore-user-config"))
        XCTAssertTrue(CodexPoke.arguments(isolatedHome: false,
                                          workingDirectory: URL(fileURLWithPath: "/tmp"))
            .contains("--ignore-user-config"))
    }

    /// The account can change between deciding to poke and poking. Spending
    /// quota against the wrong account is the failure this prevents.
    func testPokeRefusesWhenTheFingerprintChanged() throws {
        let binary = try makeFakeCodex()
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try Data(#"{"tokens": {"account_id": "acct-now"}}"#.utf8)
            .write(to: codexHome.appendingPathComponent("auth.json"))

        XCTAssertThrowsError(try CodexPoke.run(binary: binary, codexHome: codexHome,
                                               expectedFingerprint: "000000000000")) { error in
            guard case CodexError.fingerprintChanged = error else {
                return XCTFail("expected a fingerprint refusal, got \(error)")
            }
        }
        XCTAssertFalse(fakeLog().contains("ARGV"), "it ran the request anyway")
    }

    func testPokeRunsAndReportsWhatCameBack() throws {
        let binary = try makeFakeCodex()
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try Data(#"{"tokens": {"account_id": "acct-now"}}"#.utf8)
            .write(to: codexHome.appendingPathComponent("auth.json"))
        let fingerprint = CodexFingerprint.of(codexHome: codexHome)

        let result = try CodexPoke.run(binary: binary, codexHome: codexHome,
                                       expectedFingerprint: fingerprint)
        XCTAssertEqual(result.model, Quota.defaultModel)
        XCTAssertEqual(result.response, "OK")
        XCTAssertEqual(result.accountFingerprint, fingerprint)
        XCTAssertTrue(fakeLog().contains("HOME \(codexHome.path)"))
    }

    // MARK: - Binary resolution

    func testAnOverrideWins() throws {
        let binary = try makeFakeCodex()
        let resolved = try CodexBinary.resolve(environment: [CodexBinary.overrideVariable: binary.path])
        XCTAssertEqual(resolved.path, binary.path)
    }

    func testAnOverridePointingAtNothingIsAnErrorRatherThanASilentFallback() {
        XCTAssertThrowsError(try CodexBinary.resolve(
            environment: [CodexBinary.overrideVariable: "/nonexistent/codex"]))
    }
}

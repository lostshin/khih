import XCTest
@testable import Codenotch

/// The boundary between the engine and the interface: which rows get a button,
/// what a press publishes, and what a second press does.
@MainActor
final class QuotaControllerTests: XCTestCase {

    private final class StubBackend: QuotaBackend {
        var fingerprint: String? = "fp1234567890"
        var reads: [RateLimitsSnapshot] = []
        private var index = 0
        var poked = 0

        func accountFingerprint(for account: QuotaAccountConfig) -> String? { fingerprint }

        func readRateLimits(for account: QuotaAccountConfig,
                            observedAt: Int64) throws -> RateLimitsSnapshot {
            guard !reads.isEmpty else { return RateLimitsSnapshot(observedAt: observedAt) }
            let snapshot = reads[min(index, reads.count - 1)]
            index += 1
            var stamped = snapshot
            stamped.observedAt = observedAt
            return stamped
        }

        func poke(for account: QuotaAccountConfig,
                  expectedFingerprint: String?) throws -> CodexPokeResult {
            poked += 1
            return CodexPokeResult(model: Quota.defaultModel, response: "OK",
                                   accountFingerprint: fingerprint)
        }
    }

    private var root: URL!
    private var storage: QuotaStorage!
    private var backend: StubBackend!
    private let clock: Int64 = 1_000_000

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("QuotaControllerTests.\(UUID().uuidString)")
        storage = QuotaStorage(baseDir: root)
        try QuotaStorage.privateDirectory(root)
        backend = StubBackend()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func addAccount(id: String, label: String = "Test",
                            provider: QuotaProvider = .codex,
                            enabled: Bool = true) throws -> QuotaAccountConfig {
        let stateDir = root.appendingPathComponent("accounts/\(id)/monitor")
        try QuotaStorage.privateDirectory(stateDir)
        let account = QuotaAccountConfig(id: id, label: label, provider: provider,
                                         codexHome: root.appendingPathComponent("\(id)-home").path,
                                         stateDir: stateDir.path, enabled: enabled)
        var file = storage.loadAccounts()
        file.accounts.append(account)
        try storage.saveAccounts(file)
        return account
    }

    private func makeController() -> QuotaController {
        let engine = QuotaEngine(storage: storage, backend: backend,
                                 verificationDelay: 0, now: { [clock] in clock })
        return QuotaController(storage: storage, engine: engine)
    }

    private func idleFiveHour() -> RateLimitsSnapshot {
        RateLimitsSnapshot(observedAt: clock, buckets: [
            RateLimitBucket(limitId: "codex",
                            primary: QuotaWindow(usedPercent: 0,
                                                 windowDurationMins: Quota.fiveHourWindowMins,
                                                 resetsAt: clock + Quota.fiveHourWindowMins * 60,
                                                 observedAt: clock),
                            secondary: QuotaWindow(usedPercent: 30,
                                                   windowDurationMins: Quota.weeklyWindowMins,
                                                   resetsAt: clock + 600_000,
                                                   observedAt: clock))])
    }

    private func seedBaseline(_ account: QuotaAccountConfig) throws {
        var state = AccountState(accountFingerprint: backend.fingerprint)
        var snapshot = idleFiveHour()
        snapshot.observedAt = clock - 600
        state.snapshot = snapshot
        try storage.saveState(state, for: account)
    }

    // MARK: - Which rows get a button

    func testOnlyManagedCodexAccountsCanBeStarted() throws {
        _ = try addAccount(id: "account-a", label: "主帳號")
        _ = try addAccount(id: "account-off", label: "停用", enabled: false)
        _ = try addAccount(id: "account-claude", label: "Claude", provider: .claude)
        let controller = makeController()

        XCTAssertTrue(controller.canStartFiveHour("codex-account-a"))
        XCTAssertFalse(controller.canStartFiveHour("codex-account-off"))
        XCTAssertFalse(controller.canStartFiveHour("codex-account-claude"))
        // A plain `~/.codex` profile the engine never adopted has no state
        // directory, so there is nothing to start.
        XCTAssertFalse(controller.canStartFiveHour("codex"))
        XCTAssertFalse(controller.canStartFiveHour("claude"))
    }

    /// No `codex` binary means no way to make the request, and a button that
    /// cannot work must not be offered.
    func testWithoutAnEngineNothingCanBeStarted() async throws {
        _ = try addAccount(id: "account-a")
        let controller = QuotaController(storage: storage, engine: nil)

        XCTAssertFalse(controller.canStartFiveHour("codex-account-a"))
        // And pressing it anyway does nothing rather than crashing.
        await controller.startFiveHour("codex-account-a")
        XCTAssertNil(controller.result(for: "codex-account-a"))
    }

    // MARK: - Pressing it

    func testAPressPublishesItsResult() async throws {
        let account = try addAccount(id: "account-a")
        try seedBaseline(account)
        backend.reads = [idleFiveHour()]
        let controller = makeController()

        XCTAssertNil(controller.result(for: "codex-account-a"))
        await controller.startFiveHour("codex-account-a")

        XCTAssertEqual(controller.result(for: "codex-account-a"), .started(.unverified))
        XCTAssertEqual(backend.poked, 1)
        // It is no longer in flight once the call returns.
        XCTAssertFalse(controller.isRunning("codex-account-a"))
    }

    func testARefusalIsPublishedAsPlainlyAsASuccess() async throws {
        // No baseline seeded: gate 1 refuses.
        _ = try addAccount(id: "account-a")
        backend.reads = [idleFiveHour()]
        let controller = makeController()

        await controller.startFiveHour("codex-account-a")
        XCTAssertEqual(controller.result(for: "codex-account-a"), .refused(.noBaseline))
        XCTAssertEqual(backend.poked, 0)
    }

    func testAnUnmanagedProviderIsIgnoredRatherThanStarted() async throws {
        _ = try addAccount(id: "account-a")
        backend.reads = [idleFiveHour()]
        let controller = makeController()

        await controller.startFiveHour("codex")
        XCTAssertNil(controller.result(for: "codex"))
        XCTAssertEqual(backend.poked, 0)
    }

    // MARK: - Activity

    func testActivityComesFromTheRightAccount() async throws {
        let first = try addAccount(id: "account-a", label: "主帳號")
        _ = try addAccount(id: "account-b", label: "備用")
        try seedBaseline(first)
        backend.reads = [idleFiveHour()]
        let controller = makeController()

        await controller.startFiveHour("codex-account-a")

        XCTAssertFalse(controller.recentActivity("codex-account-a").isEmpty)
        // The press touched one account; the other's log stays empty.
        XCTAssertTrue(controller.recentActivity("codex-account-b").isEmpty)
        XCTAssertTrue(controller.recentActivity("codex-account-a")
            .contains { $0.contains("手動觸發") })
    }
}

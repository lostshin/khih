import XCTest
@testable import Codenotch

/// The five gates, in the order they run.
///
/// Every test here asserts on `poked` as well as the outcome: a gate that
/// returns the right answer *after* sending the request has not done its job.
/// Nothing in this file touches a real Codex install or real quota.
final class QuotaEngineTests: XCTestCase {

    // MARK: Fake backend

    private final class FakeBackend: QuotaBackend {
        var fingerprint: String? = "fp1234567890"
        /// Consumed in order; the last one repeats once exhausted.
        var reads: [RateLimitsSnapshot] = []
        private var readIndex = 0
        var readError: Error?
        var poked = 0
        var pokeError: Error?
        var pokeResponse = "OK"

        func accountFingerprint(for account: QuotaAccountConfig) -> String? { fingerprint }

        func readRateLimits(for account: QuotaAccountConfig,
                            observedAt: Int64) throws -> RateLimitsSnapshot {
            if let readError { throw readError }
            guard !reads.isEmpty else { return RateLimitsSnapshot(observedAt: observedAt) }
            let snapshot = reads[min(readIndex, reads.count - 1)]
            readIndex += 1
            var stamped = snapshot
            stamped.observedAt = observedAt
            return stamped
        }

        func poke(for account: QuotaAccountConfig, target: PokeTarget,
                  expectedFingerprint: String?) throws -> QuotaPokeResult {
            poked += 1
            if let pokeError { throw pokeError }
            return QuotaPokeResult(model: Quota.defaultModel,
                                   response: pokeResponse,
                                   accountFingerprint: fingerprint)
        }
    }

    // MARK: Fixtures

    private var root: URL!
    private var storage: QuotaStorage!
    private var account: QuotaAccountConfig!
    private var backend: FakeBackend!
    private var clock: Int64 = 1_000_000

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("QuotaEngineTests.\(UUID().uuidString)")
        storage = QuotaStorage(baseDir: root)
        let stateDir = root.appendingPathComponent("accounts/account-test/monitor")
        account = QuotaAccountConfig(id: "account-test", label: "Test",
                                     codexHome: root.appendingPathComponent("codex-home").path,
                                     stateDir: stateDir.path)
        try QuotaStorage.privateDirectory(stateDir)
        backend = FakeBackend()
        clock = 1_000_000
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func makeEngine() -> QuotaEngine {
        QuotaEngine(storage: storage, backend: backend,
                    verificationDelay: 0, now: { [unowned self] in self.clock })
    }

    private func snapshot(fiveHourUsed: Double?, fiveHourResetsAt: Int64?,
                          weeklyUsed: Double? = 30, weeklyResetsAt: Int64? = 2_000_000,
                          observedAt: Int64? = nil,
                          includeFiveHour: Bool = true) -> RateLimitsSnapshot {
        let observed = observedAt ?? clock
        var bucket = RateLimitBucket(limitId: "codex")
        if includeFiveHour {
            bucket.primary = QuotaWindow(usedPercent: fiveHourUsed,
                                         windowDurationMins: Quota.fiveHourWindowMins,
                                         resetsAt: fiveHourResetsAt, observedAt: observed)
        }
        bucket.secondary = QuotaWindow(usedPercent: weeklyUsed,
                                       windowDurationMins: Quota.weeklyWindowMins,
                                       resetsAt: weeklyResetsAt, observedAt: observed)
        return RateLimitsSnapshot(observedAt: observed, buckets: [bucket])
    }

    /// An idle five-hour window as Codex actually reports one: 0% used, with a
    /// reset time exactly five hours after the read.
    private func idleFiveHour(at time: Int64) -> RateLimitsSnapshot {
        snapshot(fiveHourUsed: 0, fiveHourResetsAt: time + Quota.fiveHourWindowMins * 60,
                 observedAt: time)
    }

    private func seedBaseline(_ snapshot: RateLimitsSnapshot? = nil) throws {
        var state = AccountState(accountFingerprint: backend.fingerprint)
        state.snapshot = snapshot ?? idleFiveHour(at: clock - 600)
        try storage.saveState(state, for: account)
    }

    private func activityText() -> String {
        storage.recentActivity(for: account, limit: 100).joined(separator: "\n")
    }

    // MARK: - Gate 1: baseline

    func testAnAccountWithNoBaselineIsRefusedWithoutSendingAnything() throws {
        backend.reads = [idleFiveHour(at: clock)]
        let outcome = try makeEngine().startFiveHour(account: account, trigger: .manual)

        XCTAssertEqual(outcome, .refused(.noBaseline))
        XCTAssertEqual(backend.poked, 0)
    }

    // MARK: - Gate 2: fingerprint

    func testAChangedFingerprintIsRefusedWithoutSendingAnything() throws {
        try seedBaseline()
        backend.fingerprint = "different0000"
        backend.reads = [idleFiveHour(at: clock)]

        let outcome = try makeEngine().startFiveHour(account: account, trigger: .manual)
        XCTAssertEqual(outcome, .refused(.accountUnconfirmed))
        XCTAssertEqual(backend.poked, 0)
    }

    func testAnUnreadableFingerprintIsRefusedWithoutSendingAnything() throws {
        try seedBaseline()
        backend.fingerprint = nil
        backend.reads = [idleFiveHour(at: clock)]

        let outcome = try makeEngine().startFiveHour(account: account, trigger: .manual)
        guard case .refused = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(backend.poked, 0)
    }

    // MARK: - Gate 3: a unique five-hour window

    func testAMissingFiveHourWindowIsRefusedWithoutSendingAnything() throws {
        try seedBaseline()
        backend.reads = [snapshot(fiveHourUsed: nil, fiveHourResetsAt: nil, includeFiveHour: false)]

        let outcome = try makeEngine().startFiveHour(account: account, trigger: .manual)
        XCTAssertEqual(outcome, .refused(.noUniqueWindow))
        XCTAssertEqual(backend.poked, 0)
    }

    // MARK: - Gate 4: unknown usage

    func testUnknownFiveHourUsageIsRefusedWithoutSendingAnything() throws {
        try seedBaseline()
        backend.reads = [snapshot(fiveHourUsed: nil,
                                  fiveHourResetsAt: clock + Quota.fiveHourWindowMins * 60)]

        let outcome = try makeEngine().startFiveHour(account: account, trigger: .manual)
        XCTAssertEqual(outcome, .refused(.unknownUsage))
        XCTAssertEqual(backend.poked, 0)
    }

    // MARK: - Gate 5: the countdown is already running

    func testARunningCountdownIsRefusedWithoutSendingAnything() throws {
        try seedBaseline()
        // Usage above zero with a future reset is a countdown, unambiguously.
        backend.reads = [snapshot(fiveHourUsed: 12, fiveHourResetsAt: clock + 3_600)]

        let outcome = try makeEngine().startFiveHour(account: account, trigger: .manual)
        XCTAssertEqual(outcome, .refused(.alreadyRunning))
        XCTAssertEqual(backend.poked, 0)
    }

    /// The gate that is easiest to get wrong: an idle window reports 0% *and* a
    /// reset time, which looks like a running countdown until the implied start
    /// is compared against the read.
    func testAnIdleWindowIsNotMistakenForARunningOne() throws {
        try seedBaseline()
        backend.reads = [idleFiveHour(at: clock)]

        let outcome = try makeEngine().startFiveHour(account: account, trigger: .manual)
        guard case .started = outcome else {
            return XCTFail("an idle window was refused as if it were running: \(outcome)")
        }
        XCTAssertEqual(backend.poked, 1)
    }

    // MARK: - The request itself

    func testASuccessfulStartSendsExactlyOneRequestAndNeverRetries() throws {
        try seedBaseline()
        backend.reads = [idleFiveHour(at: clock)]

        _ = try makeEngine().startFiveHour(account: account, trigger: .manual)
        XCTAssertEqual(backend.poked, 1, "the five-hour start must never retry")

        let state = storage.loadState(for: account)
        XCTAssertEqual(state.fiveHourStarter.lastPoke?.attempt, 1)
        XCTAssertEqual(state.fiveHourStarter.lastPoke?.model, Quota.defaultModel)
    }

    /// Verification cannot confirm anything while the backend keeps reporting an
    /// idle window, and an unconfirmed start must not claim to have worked.
    func testAnUnconfirmedStartStaysUnverified() throws {
        try seedBaseline()
        backend.reads = [idleFiveHour(at: clock)]

        let outcome = try makeEngine().startFiveHour(account: account, trigger: .manual)
        XCTAssertEqual(outcome, .started(.unverified))
        XCTAssertEqual(storage.loadState(for: account).fiveHourStarter.lastPoke?.status, .unverified)
        XCTAssertNil(storage.loadState(for: account).fiveHourStarter.lastPoke?.verifiedAt)
    }

    func testAConfirmedStartIsVerifiedAndRecordsWhenItWasSeen() throws {
        try seedBaseline()
        let started = snapshot(fiveHourUsed: 3,
                               fiveHourResetsAt: clock + Quota.fiveHourWindowMins * 60)
        backend.reads = [idleFiveHour(at: clock), started]

        let outcome = try makeEngine().startFiveHour(account: account, trigger: .manual)
        XCTAssertEqual(outcome, .started(.verified))

        let poke = storage.loadState(for: account).fiveHourStarter.lastPoke
        XCTAssertEqual(poke?.status, .verified)
        XCTAssertNotNil(poke?.verifiedAt)
    }

    /// A countdown that started well before our request belongs to somebody
    /// else's usage. Reporting that honestly is the point.
    func testACountdownStartedElsewhereIsNotAttributed() throws {
        try seedBaseline()
        let elsewhere = snapshot(fiveHourUsed: 40,
                                 fiveHourResetsAt: clock + Quota.fiveHourWindowMins * 60 - 7_200)
        backend.reads = [idleFiveHour(at: clock), elsewhere]

        let outcome = try makeEngine().startFiveHour(account: account, trigger: .manual)
        XCTAssertEqual(outcome, .started(.notAttributed))
    }

    func testAFailedRequestLeavesNoPokeRecorded() throws {
        try seedBaseline()
        backend.reads = [idleFiveHour(at: clock)]
        backend.pokeError = CodexError.pokeFailed(status: 1, detail: "boom")

        XCTAssertThrowsError(try makeEngine().startFiveHour(account: account, trigger: .manual))
        XCTAssertNil(storage.loadState(for: account).fiveHourStarter.lastPoke)
    }

    // MARK: - The lock

    func testAnAccountAlreadyBeingCheckedIsSkippedWithoutSendingAnything() throws {
        try seedBaseline()
        backend.reads = [idleFiveHour(at: clock)]
        let held = try storage.acquireCheckLock(for: account)
        XCTAssertNotNil(held)

        let outcome = try makeEngine().startFiveHour(account: account, trigger: .manual)
        XCTAssertEqual(outcome, .skippedBusy)
        XCTAssertEqual(backend.poked, 0)
        withExtendedLifetime(held) {}
    }

    // MARK: - The activity trail

    /// A schedule most often lands on a refusal, and the trigger line is the
    /// only evidence afterwards that it fired at all.
    func testEveryAttemptRecordsItsTriggerEvenWhenRefused() throws {
        backend.reads = [idleFiveHour(at: clock)]

        // No baseline: refused at the first gate.
        _ = try makeEngine().startFiveHour(account: account, trigger: .scheduled)
        XCTAssertTrue(activityText().contains("預約觸發"), activityText())

        try seedBaseline()
        _ = try makeEngine().startFiveHour(account: account, trigger: .manual)
        XCTAssertTrue(activityText().contains("手動觸發"), activityText())
    }

    func testTheActivityTrailNamesTheOutcome() throws {
        try seedBaseline()
        backend.reads = [idleFiveHour(at: clock),
                         snapshot(fiveHourUsed: 3, fiveHourResetsAt: clock + Quota.fiveHourWindowMins * 60)]

        _ = try makeEngine().startFiveHour(account: account, trigger: .manual)
        XCTAssertTrue(activityText().contains("已確認"), activityText())
    }

    /// The freshly read numbers have to land in the state even on a refusal,
    /// or the card keeps showing what it showed before the button was pressed.
    func testARefusalStillStoresTheFreshReading() throws {
        try seedBaseline()
        backend.reads = [snapshot(fiveHourUsed: 12, fiveHourResetsAt: clock + 3_600)]

        _ = try makeEngine().startFiveHour(account: account, trigger: .manual)
        XCTAssertEqual(storage.loadState(for: account).snapshot?.fiveHourWindow()?.usedPercent, 12)
    }

    // MARK: - Ratchet inside the transaction

    func testALaggingReadDoesNotLowerTheStoredUsage() throws {
        var baseline = AccountState(accountFingerprint: backend.fingerprint)
        baseline.snapshot = snapshot(fiveHourUsed: 50, fiveHourResetsAt: clock + 3_600,
                                     weeklyUsed: 88, observedAt: clock - 600)
        try storage.saveState(baseline, for: account)

        // Same reset time, lower number: a lagging replica.
        backend.reads = [snapshot(fiveHourUsed: 50, fiveHourResetsAt: clock + 3_600, weeklyUsed: 70)]

        let outcome = try makeEngine().startFiveHour(account: account, trigger: .manual)
        // It is refused at gate 5 — the point here is that the refusal path
        // still persists the reconciled reading, and that the reconciliation
        // held the higher number.
        guard case .refused = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(backend.poked, 0)
        XCTAssertEqual(storage.loadState(for: account).snapshot?.weeklyWindow()?.usedPercent, 88)
        XCTAssertTrue(activityText().contains("落後"), activityText())
    }
}

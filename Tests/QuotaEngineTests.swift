import XCTest
@testable import Khih

/// The five gates, in the order they run.
///
/// Every test here asserts on `poked` as well as the outcome: a gate that
/// returns the right answer *after* sending the request has not done its job.
/// Nothing in this file touches a real Codex install or real quota.
final class QuotaEngineTests: XCTestCase {

    // MARK: Fake backend

    private final class FakeBackend: QuotaBackend {
        var fingerprint: String? = "fp1234567890"
        var identityReads = 0
        /// Consumed in order; the last one repeats once exhausted.
        var reads: [RateLimitsSnapshot] = []
        private var readIndex = 0
        var readError: Error?
        var poked = 0
        var pokeError: Error?
        var pokeResponse = "OK"
        var onRead: (() throws -> Void)?
        var onPoke: (() -> Void)?

        func accountFingerprint(for account: QuotaAccountConfig) -> String? {
            identityReads += 1
            return fingerprint
        }

        func readRateLimits(for account: QuotaAccountConfig,
                            observedAt: Int64) throws -> RateLimitsSnapshot {
            try onRead?()
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
            onPoke?()
            poked += 1
            if let pokeError { throw pokeError }
            return QuotaPokeResult(model: Quota.defaultModel,
                                   response: pokeResponse,
                                   accountFingerprint: fingerprint)
        }

        /// Nil unless a test opts in, matching every provider but Claude.
        var observation: RateLimitsSnapshot?
        var observationReads = 0

        func readObservation(for account: QuotaAccountConfig,
                             observedAt: Int64) throws -> RateLimitsSnapshot? {
            observationReads += 1
            guard var observation else { return nil }
            observation.observedAt = observedAt
            return observation
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

    func testAutomaticLatchIsOnDiskBeforePokeAndSaveFailurePreventsPoke() throws {
        try seedBaseline()
        backend.reads = [idleFiveHour(at: clock)]
        backend.onPoke = {
            XCTAssertEqual(self.storage.loadState(for: self.account).fiveHourStarter.automaticAttemptAt, self.clock)
        }
        _ = try makeEngine().startFiveHour(account: account, trigger: .automatic)
        try seedBaseline()
        backend.onRead = {
            let temporary = QuotaStorage.statePath(for: self.account).appendingPathExtension("tmp")
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
            self.backend.onRead = nil
        }
        XCTAssertThrowsError(try makeEngine().startFiveHour(account: account, trigger: .automatic))
        XCTAssertEqual(backend.poked, 1)
    }

    func testAutomaticHonorsCooldownBeforeIdentityOrReads() throws {
        account.provider = .claude
        try seedBaseline()
        var state = storage.loadState(for: account)
        state.checkCooldownUntil = clock + 900
        try storage.saveState(state, for: account)
        backend.onRead = { XCTFail("Cooldown must prevent a backend read") }
        guard case .failed = try makeEngine().startFiveHour(account: account, trigger: .automatic) else { return XCTFail() }
        XCTAssertEqual(backend.identityReads, 0)
        XCTAssertEqual(backend.poked, 0)
    }

    func testExplicitStartCannotBeImmediatelyRepeatedByAutomaticKeeper() throws {
        for trigger in [FiveHourTrigger.manual, .scheduled] {
            try seedBaseline()
            backend.reads = [idleFiveHour(at: clock)]
            let before = backend.poked
            _ = try makeEngine().startFiveHour(account: account, trigger: trigger)
            XCTAssertEqual(try makeEngine().startFiveHour(account: account, trigger: .automatic), .refused(.awaitingConfirmation))
            XCTAssertEqual(backend.poked, before + 1)
        }
    }

    func testFallbackObservationCannotReleasePendingFiveHourAttempt() throws {
        try seedBaseline()
        var state = storage.loadState(for: account)
        state.fiveHourStarter.automaticAttemptAt = clock - 10
        try storage.saveState(state, for: account)
        backend.readError = ClaudeUsageError.accessDenied
        backend.observation = snapshot(fiveHourUsed: 5, fiveHourResetsAt: clock + 100)
        _ = try makeEngine().checkAccount(account: account, mode: .observe)
        XCTAssertEqual(storage.loadState(for: account).fiveHourStarter.automaticAttemptAt, clock - 10)
        XCTAssertEqual(backend.poked, 0)
    }

    func testAutomaticClaudeNeverUsesCredentialFallback() throws {
        account.provider = .claude
        try seedBaseline()
        backend.readError = ClaudeUsageError.accessDenied
        backend.observation = idleFiveHour(at: clock)
        XCTAssertThrowsError(try makeEngine().startFiveHour(account: account, trigger: .automatic))
        XCTAssertEqual(backend.observationReads, 0)
        XCTAssertEqual(backend.poked, 0)
    }

    func testOlderObservationCannotReleaseAutomaticLatch() {
        var starter = FiveHourStarter(automaticAttemptAt: clock)
        var window = QuotaWindow(usedPercent: 5, windowDurationMins: 300,
                                 resetsAt: clock + 100, observedAt: clock - 1)
        window.countdownActive = true
        starter.observe(window)
        XCTAssertEqual(starter.automaticAttemptAt, clock)
        XCTAssertNil(starter.confirmedResetAt)
    }

    func testAutomaticUnverifiedAttemptSurvivesRestartAndMovingReset() throws {
        try seedBaseline()
        backend.reads = [idleFiveHour(at: clock)]
        XCTAssertEqual(try makeEngine().startFiveHour(account: account, trigger: .automatic), .started(.unverified))
        XCTAssertEqual(storage.loadState(for: account).fiveHourStarter.automaticAttemptAt, clock)
        clock += 600
        backend.reads = [idleFiveHour(at: clock)]
        XCTAssertEqual(try makeEngine().startFiveHour(account: account, trigger: .automatic), .refused(.awaitingConfirmation))
        XCTAssertEqual(backend.poked, 1)
    }

    func testAutomaticFailedPokeIsLatchedBeforeSending() throws {
        try seedBaseline()
        backend.reads = [idleFiveHour(at: clock)]
        backend.pokeError = CodexError.pokeFailed(status: 1, detail: "fake failure")
        XCTAssertThrowsError(try makeEngine().startFiveHour(account: account, trigger: .automatic))
        XCTAssertNotNil(storage.loadState(for: account).fiveHourStarter.automaticAttemptAt)
        backend.pokeError = nil
        XCTAssertEqual(try makeEngine().startFiveHour(account: account, trigger: .automatic), .refused(.awaitingConfirmation))
        XCTAssertEqual(backend.poked, 1)
        _ = try makeEngine().startFiveHour(account: account, trigger: .manual)
        XCTAssertEqual(backend.poked, 2, "Explicit manual handling remains available")
    }

    func testAutomaticFirstReadOnlyEstablishesBaseline() throws {
        backend.reads = [idleFiveHour(at: clock)]
        XCTAssertEqual(try makeEngine().startFiveHour(account: account, trigger: .automatic), .refused(.noBaseline))
        XCTAssertNotNil(storage.loadState(for: account).snapshot)
        XCTAssertEqual(backend.poked, 0)
        _ = try makeEngine().startFiveHour(account: account, trigger: .automatic)
        XCTAssertEqual(backend.poked, 1)
    }

    func testAutomaticInUseDoesNotSpendOrLatch() throws {
        try seedBaseline()
        backend.reads = [idleFiveHour(at: clock)]
        let engine = makeEngine()
        engine.isAccountInUse = { _ in true }
        XCTAssertEqual(try engine.startFiveHour(account: account, trigger: .automatic), .refused(.inUse))
        XCTAssertNil(storage.loadState(for: account).fiveHourStarter.automaticAttemptAt)
        XCTAssertEqual(backend.poked, 0)
    }

    func testObservedCountdownReleasesLatchAndExpiryAllowsNextRound() throws {
        try seedBaseline()
        backend.reads = [idleFiveHour(at: clock)]
        _ = try makeEngine().startFiveHour(account: account, trigger: .automatic)
        let reset = clock + 18000
        clock += 300
        backend.reads = [snapshot(fiveHourUsed: 2, fiveHourResetsAt: reset)]
        XCTAssertEqual(try makeEngine().startFiveHour(account: account, trigger: .automatic), .refused(.alreadyRunning))
        let state = storage.loadState(for: account)
        XCTAssertNil(state.fiveHourStarter.automaticAttemptAt)
        XCTAssertEqual(state.fiveHourStarter.confirmedResetAt, reset)
        XCTAssertEqual(backend.poked, 1)
        clock = reset + 1
        backend.reads = [idleFiveHour(at: clock)]
        _ = try makeEngine().startFiveHour(account: account, trigger: .automatic)
        XCTAssertEqual(backend.poked, 2)
    }

    func testAutomaticDoesNotRepeatAnUnconfirmedWeeklyRequest() throws {
        try seedBaseline()
        var state = storage.loadState(for: account)
        state.weeklyKeeper.lastPoke = LastPoke(at: clock, model: "fake", response: "OK",
            accountFingerprint: backend.fingerprint, status: .unverified, attempt: 1, verifiedAt: nil)
        try storage.saveState(state, for: account)
        backend.reads = [idleFiveHour(at: clock)]
        XCTAssertEqual(try makeEngine().startFiveHour(account: account, trigger: .automatic), .refused(.awaitingConfirmation))
        XCTAssertEqual(backend.poked, 0)
    }

    func testHistoricalWeeklyPokeDoesNotBlockFirstAutomaticFiveHourRound() throws {
        try seedBaseline()
        var state = storage.loadState(for: account)
        state.weeklyKeeper.lastPoke = LastPoke(at: clock - 18001, model: "fake", response: "OK",
            accountFingerprint: backend.fingerprint, status: .verified, attempt: 1, verifiedAt: clock - 18000)
        try storage.saveState(state, for: account)
        backend.reads = [idleFiveHour(at: clock)]
        _ = try makeEngine().startFiveHour(account: account, trigger: .automatic)
        XCTAssertEqual(backend.poked, 1)
    }

    func testAutomaticStateSemanticRoundTripAndLegacyDecode() throws {
        let value = FiveHourStarter(automaticAttemptAt: clock, confirmedResetAt: clock + 18000)
        XCTAssertEqual(try JSONDecoder().decode(FiveHourStarter.self, from: JSONEncoder().encode(value)), value)
        XCTAssertEqual(try JSONDecoder().decode(FiveHourStarter.self, from: Data("{}".utf8)), FiveHourStarter())
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

// MARK: - Reading usage without a usable credential

/// Claude Code re-files its keychain item when it rotates a token, and an
/// ad-hoc rebuild changes the identity the keychain ACL recorded — either way
/// the engine can lose the credential while `claude` itself keeps answering.
/// The weekly guard is allowed to run on that; the five-hour starter is not.
extension QuotaEngineTests {

    private func lockedOut() {
        backend.readError = ClaudeUsageError.accessDenied
    }

    func testTheWeeklyGuardRunsOnTheFallbackReading() throws {
        try seedBaseline(snapshot(fiveHourUsed: 40, fiveHourResetsAt: clock + 9_000,
                                  weeklyUsed: 30, weeklyResetsAt: clock - 60,
                                  observedAt: clock - 600))
        lockedOut()
        // The weekly window has rolled over: 0% used, and the reset that was
        // scheduled has passed.
        backend.observation = snapshot(fiveHourUsed: 0, fiveHourResetsAt: clock + 18_000,
                                       weeklyUsed: 0, weeklyResetsAt: nil)

        let outcome = try makeEngine().checkAccount(account: account, mode: .live)

        if case .poked = outcome {} else {
            XCTFail("the guard must still act when only the command can answer, got \(outcome)")
        }
        // The fake keeps answering 0%, so the resend rule runs to its limit —
        // the same limit the endpoint path obeys, not a looser one.
        XCTAssertGreaterThanOrEqual(backend.poked, 1)
        XCTAssertLessThanOrEqual(backend.poked, Quota.pokeAttemptLimit)
        XCTAssertTrue(activityText().contains("改由 CLI 讀取額度"), "the source has to be recorded")
    }

    /// The narrowing. A reset printed to the minute is precise enough for a
    /// seven-day window and not for the sixty-second tolerance a five-hour
    /// attribution is judged by, so this path reads the endpoint or refuses.
    func testTheFiveHourStarterNeverUsesTheFallback() throws {
        try seedBaseline()
        lockedOut()
        backend.observation = snapshot(fiveHourUsed: 0, fiveHourResetsAt: clock + 18_000)

        // It reports the credential failure rather than reaching for the
        // command; the controller turns the throw into a visible failure.
        XCTAssertThrowsError(try makeEngine().startFiveHour(account: account, trigger: .manual))
        XCTAssertEqual(backend.poked, 0)
        XCTAssertEqual(backend.observationReads, 0, "the starter must not even ask")
    }

    func testTheFallbackStillRequiresEveryWeeklyGate() throws {
        // No baseline: the first reading may only establish one.
        lockedOut()
        backend.observation = snapshot(fiveHourUsed: 0, fiveHourResetsAt: clock + 18_000,
                                       weeklyUsed: 0, weeklyResetsAt: nil)

        let outcome = try makeEngine().checkAccount(account: account, mode: .live)

        XCTAssertEqual(outcome, .baseline)
        XCTAssertEqual(backend.poked, 0, "a first observation never pokes, whatever the source")
    }

    func testAnUnusableCredentialWithNoFallbackStillReportsTheFailure() throws {
        try seedBaseline()
        lockedOut()
        backend.observation = nil

        XCTAssertThrowsError(try makeEngine().checkAccount(account: account, mode: .live))
        XCTAssertTrue(activityText().contains("讀取額度失敗"), "the failure has to leave a record")
    }

    func testARateLimitIsNeverAnsweredFromTheFallback() throws {
        try seedBaseline()
        backend.readError = QuotaBackendError.rateLimited(retryAt: clock + 900)
        backend.observation = snapshot(fiveHourUsed: 0, fiveHourResetsAt: clock + 18_000)

        let outcome = try makeEngine().checkAccount(account: account, mode: .live)

        XCTAssertEqual(outcome, .rateLimited(retryAt: clock + 900))
        XCTAssertEqual(backend.observationReads, 0,
                       "a back-off means leave the provider alone; the command spends the same bucket")
    }

    func testTheBurnRateKeepsMeasuringThroughTheFallback() throws {
        // The same five-hour window in both readings: a reset time that moved
        // means a rollover, and a rollover is deliberately not a sample.
        let windowEnds = clock + 17_700
        try seedBaseline(snapshot(fiveHourUsed: 10, fiveHourResetsAt: windowEnds,
                                  weeklyUsed: 30, observedAt: clock - 300))
        lockedOut()
        backend.observation = snapshot(fiveHourUsed: 34, fiveHourResetsAt: windowEnds,
                                       weeklyUsed: 33)

        _ = try makeEngine().checkAccount(account: account, mode: .live)

        let rate = storage.loadState(for: account).burnRate
        XCTAssertEqual(rate.fiveHourDeltaTotal, 24, accuracy: 0.001)
        XCTAssertEqual(rate.weeklyDeltaTotal, 3, accuracy: 0.001)
    }
}

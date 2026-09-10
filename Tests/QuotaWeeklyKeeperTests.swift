import XCTest
@testable import Codenotch

/// The weekly reset transaction.
///
/// Almost every test here asserts on `poked` as well as the outcome. The
/// keeper's job is to send **one** request per reset and none at any other
/// time, so a branch that reaches the right conclusion after sending a request
/// has already failed.
final class QuotaWeeklyKeeperTests: XCTestCase {

    private final class FakeBackend: QuotaBackend {
        var fingerprint: String? = "fp1234567890"
        var reads: [RateLimitsSnapshot] = []
        private var index = 0
        var readError: Error?
        var poked = 0
        var pokeError: Error?

        func accountFingerprint(for account: QuotaAccountConfig) -> String? { fingerprint }

        func readRateLimits(for account: QuotaAccountConfig,
                            observedAt: Int64) throws -> RateLimitsSnapshot {
            if let readError { throw readError }
            guard !reads.isEmpty else { return RateLimitsSnapshot(observedAt: observedAt) }
            let snapshot = reads[min(index, reads.count - 1)]
            index += 1
            var stamped = snapshot
            stamped.observedAt = observedAt
            return stamped
        }

        func poke(for account: QuotaAccountConfig,
                  expectedFingerprint: String?) throws -> QuotaPokeResult {
            poked += 1
            if let pokeError { throw pokeError }
            return QuotaPokeResult(model: Quota.defaultModel, response: "OK",
                                   accountFingerprint: fingerprint)
        }
    }

    private var root: URL!
    private var storage: QuotaStorage!
    private var account: QuotaAccountConfig!
    private var backend: FakeBackend!
    private var clock: Int64 = 2_000_000
    private var inUse = false

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("QuotaWeeklyKeeperTests.\(UUID().uuidString)")
        storage = QuotaStorage(baseDir: root)
        let stateDir = root.appendingPathComponent("accounts/account-test/monitor")
        account = QuotaAccountConfig(id: "account-test", label: "Test",
                                     codexHome: root.appendingPathComponent("home").path,
                                     stateDir: stateDir.path)
        try QuotaStorage.privateDirectory(stateDir)
        backend = FakeBackend()
        clock = 2_000_000
        inUse = false
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func makeEngine() -> QuotaEngine {
        QuotaEngine(storage: storage, backend: backend, verificationDelay: 0,
                    now: { [unowned self] in self.clock },
                    isAccountInUse: { [unowned self] _ in self.inUse })
    }

    /// `weeklyResetsAt: nil` means "a window that follows the reads" — the
    /// unanchored shape Codex reports for a window that has not started.
    private func snapshot(weeklyUsed: Double?, weeklyResetsAt: Int64?,
                          fiveHourUsed: Double? = 10, observedAt: Int64? = nil) -> RateLimitsSnapshot {
        let observed = observedAt ?? clock
        let weeklyReset = weeklyResetsAt ?? (observed + Quota.weeklyWindowMins * 60)
        return RateLimitsSnapshot(observedAt: observed, buckets: [
            RateLimitBucket(limitId: "codex",
                            primary: QuotaWindow(usedPercent: fiveHourUsed,
                                                 windowDurationMins: Quota.fiveHourWindowMins,
                                                 resetsAt: observed + 9_000,
                                                 observedAt: observed),
                            secondary: QuotaWindow(usedPercent: weeklyUsed,
                                                   windowDurationMins: Quota.weeklyWindowMins,
                                                   resetsAt: weeklyReset,
                                                   observedAt: observed))])
    }

    private func seed(_ snapshot: RateLimitsSnapshot,
                      lastHandledResetKey: String? = nil) throws {
        var state = AccountState(accountFingerprint: backend.fingerprint)
        state.snapshot = snapshot
        state.weeklyKeeper.lastHandledResetKey = lastHandledResetKey
        try storage.saveState(state, for: account)
    }

    private func activityText() -> String {
        storage.recentActivity(for: account, limit: 200).joined(separator: "\n")
    }

    /// The shape that means "the weekly window just reset": usage dropped to
    /// zero and the reset time moved.
    ///
    /// `confirmed` decides what the verification reads see afterwards. Left
    /// unconfirmed, the engine correctly retries up to `pokeAttemptLimit` — so
    /// a test about anything else has to let the first request be confirmed, or
    /// it is really a test about retrying.
    private func seedAResetIsAboutToBeSeen(confirmed: Bool = true) throws {
        let before = snapshot(weeklyUsed: 80, weeklyResetsAt: clock + 100, observedAt: clock - 600)
        try seed(before)
        var reads = [snapshot(weeklyUsed: 0, weeklyResetsAt: nil)]
        if confirmed {
            // A window that started when we poked: usage above zero, and a
            // reset time whose implied start is the moment of the request.
            reads.append(snapshot(weeklyUsed: 2,
                                  weeklyResetsAt: clock + Quota.weeklyWindowMins * 60))
        }
        backend.reads = reads
    }

    // MARK: - Nothing to act on

    func testAFirstObservationOnlyBuildsABaseline() throws {
        backend.reads = [snapshot(weeklyUsed: 40, weeklyResetsAt: clock + 500_000)]
        let outcome = try makeEngine().checkAccount(account: account, mode: .live)

        XCTAssertEqual(outcome, .baseline)
        XCTAssertEqual(backend.poked, 0)
        XCTAssertNotNil(storage.loadState(for: account).snapshot)
        XCTAssertNil(storage.loadState(for: account).weeklyKeeper.lastHandledResetKey)
    }

    func testAChangedFingerprintRebuildsTheBaselineAndForgetsTheOldResetKey() throws {
        try seed(snapshot(weeklyUsed: 40, weeklyResetsAt: clock + 500_000, observedAt: clock - 600),
                 lastHandledResetKey: "scheduled:1")
        backend.fingerprint = "someoneelse0"
        backend.reads = [snapshot(weeklyUsed: 5, weeklyResetsAt: clock + 500_000)]

        let outcome = try makeEngine().checkAccount(account: account, mode: .live)
        XCTAssertEqual(outcome, .baseline)
        XCTAssertEqual(backend.poked, 0)
        // Carrying a reset key across accounts is how one account's handled
        // reset silences another's.
        let state = storage.loadState(for: account)
        XCTAssertNil(state.weeklyKeeper.lastHandledResetKey)
        XCTAssertEqual(state.accountFingerprint, "someoneelse0")
    }

    func testASteadyWindowIsLeftAlone() throws {
        try seed(snapshot(weeklyUsed: 40, weeklyResetsAt: clock + 500_000, observedAt: clock - 600))
        backend.reads = [snapshot(weeklyUsed: 41, weeklyResetsAt: clock + 500_000)]

        XCTAssertEqual(try makeEngine().checkAccount(account: account, mode: .live), .noReset)
        XCTAssertEqual(backend.poked, 0)
    }

    func testAMissingWeeklyWindowDisablesTheKeeperRatherThanGuessing() throws {
        try seed(snapshot(weeklyUsed: 40, weeklyResetsAt: clock + 500_000, observedAt: clock - 600))
        backend.reads = [RateLimitsSnapshot(observedAt: clock, buckets: [
            RateLimitBucket(limitId: "codex",
                            primary: QuotaWindow(usedPercent: 5,
                                                 windowDurationMins: Quota.fiveHourWindowMins,
                                                 resetsAt: clock + 9_000, observedAt: clock))])]

        XCTAssertEqual(try makeEngine().checkAccount(account: account, mode: .live), .noReset)
        XCTAssertEqual(backend.poked, 0)
    }

    // MARK: - A reset it should act on

    func testAConfirmedResetSendsOneRequest() throws {
        try seedAResetIsAboutToBeSeen()
        let outcome = try makeEngine().checkAccount(account: account, mode: .live)

        guard case .poked = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(backend.poked, 1)
        XCTAssertNotNil(storage.loadState(for: account).weeklyKeeper.lastHandledResetKey)
    }

    func testTheSameResetIsNeverPokedTwice() throws {
        try seedAResetIsAboutToBeSeen()
        let engine = makeEngine()
        _ = try engine.checkAccount(account: account, mode: .live)
        XCTAssertEqual(backend.poked, 1)

        // The next check sees the same reset. The stored key is what stops it.
        let key = storage.loadState(for: account).weeklyKeeper.lastHandledResetKey
        XCTAssertNotNil(key)
        var state = storage.loadState(for: account)
        state.snapshot = snapshot(weeklyUsed: 80, weeklyResetsAt: clock + 100, observedAt: clock - 600)
        state.weeklyKeeper.countdownActive = false
        try storage.saveState(state, for: account)

        XCTAssertEqual(try engine.checkAccount(account: account, mode: .live), .alreadyHandled)
        XCTAssertEqual(backend.poked, 1, "the same reset was poked twice")
    }

    /// Real use often gets there first, and that is a success, not a miss.
    func testACountdownSomebodyElseStartedIsRecordedRatherThanPoked() throws {
        let before = snapshot(weeklyUsed: 80, weeklyResetsAt: clock + 100, observedAt: clock - 600)
        try seed(before)
        // Reset happened *and* usage has already begun: a running countdown.
        backend.reads = [snapshot(weeklyUsed: 3, weeklyResetsAt: clock + 600_000)]

        let outcome = try makeEngine().checkAccount(account: account, mode: .live)
        XCTAssertEqual(outcome, .countdownAlreadyActive)
        XCTAssertEqual(backend.poked, 0)
        XCTAssertNotNil(storage.loadState(for: account).weeklyKeeper.lastHandledResetKey)
    }

    func testAScheduledResetThatTheBackendHasNotConfirmedOnlyWaits() throws {
        // The reset time has passed, but usage is unchanged — the backend has
        // not caught up.
        try seed(snapshot(weeklyUsed: 80, weeklyResetsAt: clock - 100, observedAt: clock - 600))
        backend.reads = [snapshot(weeklyUsed: 80, weeklyResetsAt: clock - 100)]

        XCTAssertEqual(try makeEngine().checkAccount(account: account, mode: .live), .resetPending)
        XCTAssertEqual(backend.poked, 0)
        XCTAssertEqual(storage.loadState(for: account).weeklyKeeper.pendingScheduledResetAt,
                       clock - 100)
    }

    // MARK: - Verification and retries

    func testAConfirmedCountdownIsAttributedToTheRequest() throws {
        try seedAResetIsAboutToBeSeen()
        XCTAssertEqual(try makeEngine().checkAccount(account: account, mode: .live), .poked(.verified))
        let poke = storage.loadState(for: account).weeklyKeeper.lastPoke
        XCTAssertEqual(poke?.status, .verified)
        XCTAssertNotNil(poke?.verifiedAt)
    }

    func testAnUnconfirmedRequestRetriesUpToTheLimitAndStops() throws {
        try seedAResetIsAboutToBeSeen(confirmed: false)
        // Every read keeps saying the window is unanchored, so nothing is ever
        // confirmed.
        XCTAssertEqual(try makeEngine().checkAccount(account: account, mode: .live),
                       .poked(.unverified))
        XCTAssertEqual(backend.poked, Quota.pokeAttemptLimit)
        XCTAssertEqual(storage.loadState(for: account).weeklyKeeper.lastPoke?.attempt,
                       Quota.pokeAttemptLimit)
    }

    /// The invariant that stops one reset being paid for twice: if the request
    /// itself failed, the reset must not be recorded as handled.
    func testAFailedRequestDoesNotRecordTheResetAsHandled() throws {
        try seedAResetIsAboutToBeSeen()
        backend.pokeError = CodexError.pokeFailed(status: 1, detail: "boom")

        XCTAssertThrowsError(try makeEngine().checkAccount(account: account, mode: .live))
        let state = storage.loadState(for: account)
        XCTAssertNil(state.weeklyKeeper.lastHandledResetKey)
        XCTAssertNil(state.weeklyKeeper.lastPoke)
    }

    // MARK: - Standing aside while the account is in use

    /// The user's own request will anchor the window; ours would be quota spent
    /// for nothing, and is the usual way a poke ends up `not-attributed`.
    func testAnAccountInUseIsLeftToAnchorItsOwnWindow() throws {
        try seedAResetIsAboutToBeSeen()
        inUse = true

        XCTAssertEqual(try makeEngine().checkAccount(account: account, mode: .live), .skippedInUse)
        XCTAssertEqual(backend.poked, 0)
        // Nothing was handled, so the next check will look again.
        XCTAssertNil(storage.loadState(for: account).weeklyKeeper.lastHandledResetKey)
    }

    /// Standing aside is for the automatic path only — the user pressing check
    /// has said what they want.
    func testBeingInUseDoesNotBlockAManualCheck() throws {
        try seedAResetIsAboutToBeSeen()
        inUse = true

        guard case .poked = try makeEngine().checkAccount(account: account, mode: .manual) else {
            return XCTFail("a manual check was skipped as if it were automatic")
        }
        XCTAssertEqual(backend.poked, 1)
    }

    // MARK: - Modes

    func testADryRunDecidesEverythingAndChangesNothing() throws {
        try seedAResetIsAboutToBeSeen()
        let before = storage.loadState(for: account)

        XCTAssertEqual(try makeEngine().checkAccount(account: account, mode: .dryRun),
                       .dryRunWouldPoke)
        XCTAssertEqual(backend.poked, 0)
        XCTAssertEqual(storage.loadState(for: account), before)
    }

    /// A manual check is not a back door: it still needs a weekly window at 0%
    /// with no countdown anchored.
    func testAManualCheckStillObeysTheSafetyConditions() throws {
        try seed(snapshot(weeklyUsed: 40, weeklyResetsAt: clock + 500_000, observedAt: clock - 600))
        backend.reads = [snapshot(weeklyUsed: 41, weeklyResetsAt: clock + 500_000)]

        XCTAssertEqual(try makeEngine().checkAccount(account: account, mode: .manual), .noReset)
        XCTAssertEqual(backend.poked, 0)
    }

    // MARK: - Back-off

    func testACooldownIsAnsweredWithoutTouchingTheBackend() throws {
        var state = AccountState(accountFingerprint: backend.fingerprint)
        state.snapshot = snapshot(weeklyUsed: 40, weeklyResetsAt: clock + 500_000, observedAt: clock - 600)
        state.checkCooldownUntil = clock + 900
        try storage.saveState(state, for: account)
        backend.readError = CodexError.cancelled  // would throw if consulted

        XCTAssertEqual(try makeEngine().checkAccount(account: account, mode: .live),
                       .rateLimited(retryAt: clock + 900))
        XCTAssertEqual(backend.poked, 0)
        // The cached reading stands.
        XCTAssertEqual(storage.loadState(for: account).snapshot?.weeklyWindow()?.usedPercent, 40)
    }

    func testABackendBackOffIsRecordedAndKeepsTheCachedReading() throws {
        try seed(snapshot(weeklyUsed: 40, weeklyResetsAt: clock + 500_000, observedAt: clock - 600))
        backend.readError = QuotaBackendError.rateLimited(retryAt: clock + 600)

        XCTAssertEqual(try makeEngine().checkAccount(account: account, mode: .live),
                       .rateLimited(retryAt: clock + 600))
        let state = storage.loadState(for: account)
        XCTAssertEqual(state.checkCooldownUntil, clock + 600)
        XCTAssertEqual(state.snapshot?.weeklyWindow()?.usedPercent, 40)
        XCTAssertTrue(activityText().contains("429"), activityText())
    }

    // MARK: - The ratchet, inside the transaction

    func testALaggingReadNeverLowersTheStoredUsage() throws {
        try seed(snapshot(weeklyUsed: 88, weeklyResetsAt: clock + 500_000, observedAt: clock - 600))
        // Same reset time, lower number: a lagging replica, not a reset.
        backend.reads = [snapshot(weeklyUsed: 70, weeklyResetsAt: clock + 500_000)]

        XCTAssertEqual(try makeEngine().checkAccount(account: account, mode: .live), .noReset)
        XCTAssertEqual(backend.poked, 0, "a lagging read was mistaken for a reset")
        XCTAssertEqual(storage.loadState(for: account).snapshot?.weeklyWindow()?.usedPercent, 88)
    }
}

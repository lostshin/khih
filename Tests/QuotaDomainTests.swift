import XCTest
@testable import Codenotch

/// Translated from the Rust engine's own suite (`src/domain.rs`, `mod tests`).
///
/// These are the tests that hold the quota safety invariants in place. A
/// failure here does not mean a number is displayed wrong — it means the app
/// may spend quota it should have refused to spend, or refuse to keep a window
/// alive that it should have kept.
final class QuotaDomainTests: XCTestCase {

    private func window(used: Double?, duration: Int64,
                        reset: Int64?, observed: Int64) -> QuotaWindow {
        QuotaWindow(usedPercent: used, windowDurationMins: duration,
                    resetsAt: reset, observedAt: observed, countdownActive: false)
    }

    private func snapshot(_ primary: QuotaWindow, _ secondary: QuotaWindow?) -> RateLimitsSnapshot {
        RateLimitsSnapshot(observedAt: primary.observedAt,
                           buckets: [RateLimitBucket(limitId: "codex",
                                                     primary: primary,
                                                     secondary: secondary)])
    }

    // MARK: - Window selection

    func testWeeklyTargetIsFoundByDurationNotPosition() {
        let first = snapshot(window(used: 12, duration: Quota.fiveHourWindowMins, reset: 2_000, observed: 1_000),
                             window(used: 34, duration: Quota.weeklyWindowMins, reset: 9_000, observed: 1_000))
        XCTAssertEqual(first.weeklyWindow()?.usedPercent, 34)

        let swapped = snapshot(window(used: 34, duration: Quota.weeklyWindowMins, reset: 9_000, observed: 1_000),
                               window(used: 12, duration: Quota.fiveHourWindowMins, reset: 2_000, observed: 1_000))
        XCTAssertEqual(swapped.weeklyWindow()?.usedPercent, 34)
    }

    func testMissingOrDuplicateWeeklyTargetIsRejected() {
        let missing = snapshot(window(used: 12, duration: Quota.fiveHourWindowMins, reset: 2_000, observed: 1_000), nil)
        XCTAssertNil(missing.weeklyWindow())

        let duplicate = snapshot(window(used: 12, duration: Quota.weeklyWindowMins, reset: 2_000, observed: 1_000),
                                 window(used: 34, duration: Quota.weeklyWindowMins, reset: 9_000, observed: 1_000))
        XCTAssertNil(duplicate.weeklyWindow())

        var unknownDuration = window(used: 12, duration: Quota.weeklyWindowMins, reset: 2_000, observed: 1_000)
        unknownDuration.windowDurationMins = nil
        XCTAssertNil(snapshot(unknownDuration, nil).weeklyWindow())
    }

    // MARK: - Ratchet

    func testRatchetsWindowsIndependentlyAcrossPositionSwap() {
        let previous = snapshot(window(used: 80, duration: Quota.fiveHourWindowMins, reset: 2_000, observed: 1_000),
                                window(used: 90, duration: Quota.weeklyWindowMins, reset: 9_000, observed: 1_000))
        // Both windows came back lower *and* swapped slots. Pairing has to
        // follow duration, and both drops have to be rejected.
        let incoming = snapshot(window(used: 70, duration: Quota.weeklyWindowMins, reset: 9_000, observed: 1_300),
                                window(used: 60, duration: Quota.fiveHourWindowMins, reset: 2_000, observed: 1_300))

        let outcome = QuotaDomain.reconcileSnapshot(previous: previous, incoming: incoming)
        XCTAssertEqual(outcome.rejected, 2)
        XCTAssertEqual(outcome.snapshot.weeklyWindow()?.usedPercent, 90)
        XCTAssertEqual(outcome.snapshot.fiveHourWindow()?.usedPercent, 80)
    }

    func testTimestampJitterAndUsageRatchetAreSafe() {
        // One second of drift is the same reset time; three seconds is not.
        XCTAssertFalse(QuotaDomain.resetAtMoved(1_786_166_386, 1_786_166_387))
        XCTAssertTrue(QuotaDomain.resetAtMoved(1_786_166_386, 1_786_166_389))

        let previous = window(used: 100, duration: Quota.weeklyWindowMins,
                              reset: 1_786_160_160, observed: 1_786_069_000)
        let current = window(used: 84, duration: Quota.weeklyWindowMins,
                             reset: 1_786_160_160, observed: 1_786_070_000)
        let outcome = QuotaDomain.reconcileSuspectRead(previous: previous, current: current)
        XCTAssertTrue(outcome.rejected)
        XCTAssertEqual(outcome.window.usedPercent, 100)
    }

    // MARK: - Countdown and reset detection

    func testFirstObservationIsOnlyABaseline() {
        let current = window(used: 0, duration: Quota.weeklyWindowMins, reset: 606_800, observed: 2_000)
        let decision = QuotaDomain.detectReset(previous: nil, current: current,
                                               nowSeconds: 2_000, pendingScheduledResetAt: nil)
        XCTAssertEqual(decision.reason, .baseline)
        XCTAssertFalse(decision.shouldPoke)
    }

    /// The distinction the whole five-hour gate rests on: a 0% window whose
    /// reset time moves with every read has not started, while one whose reset
    /// time stays put has.
    func testStableAndProvisionalZeroWindowsAreDistinguished() {
        let provisional = window(used: 0, duration: Quota.weeklyWindowMins, reset: 606_800, observed: 2_000)
        XCTAssertFalse(QuotaDomain.countdownWindowActive(previous: nil, current: provisional))

        let previous = window(used: 0, duration: Quota.weeklyWindowMins, reset: 606_200, observed: 1_400)
        let stable = window(used: 0, duration: Quota.weeklyWindowMins, reset: 606_200, observed: 2_000)
        XCTAssertTrue(QuotaDomain.countdownWindowActive(previous: previous, current: stable))
    }

    func testRetryIsLimitedAndUnknownUsageNeverResets() {
        let moving = window(used: 0, duration: Quota.weeklyWindowMins, reset: 606_800, observed: 2_000)
        XCTAssertTrue(QuotaDomain.pokeRetryAllowed(window: moving, attempt: 1))
        XCTAssertTrue(QuotaDomain.pokeRetryAllowed(window: moving, attempt: 2))
        XCTAssertFalse(QuotaDomain.pokeRetryAllowed(window: moving, attempt: 3))

        // Usage we cannot read is not usage that reset.
        let previous = window(used: 82, duration: Quota.weeklyWindowMins, reset: 2_000, observed: 1_000)
        let current = window(used: nil, duration: Quota.weeklyWindowMins, reset: 606_800, observed: 2_000)
        XCTAssertFalse(QuotaDomain.detectReset(previous: previous, current: current,
                                               nowSeconds: 2_000, pendingScheduledResetAt: nil).shouldPoke)
    }

    // MARK: - Burn rate

    private static let hour: Int64 = 3_600

    private func burnSnapshot(now: Int64, fiveHourUsed: Double,
                              fiveHourReset: Int64, weeklyUsed: Double) -> RateLimitsSnapshot {
        snapshot(window(used: fiveHourUsed, duration: Quota.fiveHourWindowMins,
                        reset: fiveHourReset, observed: now),
                 window(used: weeklyUsed, duration: Quota.weeklyWindowMins,
                        reset: now + 100 * Self.hour, observed: now))
    }

    private func runningWindow(used: Double, duration: Int64,
                               resetsIn: Int64, now: Int64) -> QuotaWindow {
        QuotaWindow(usedPercent: used, windowDurationMins: duration,
                    resetsAt: now + resetsIn, observedAt: now, countdownActive: true)
    }

    func testBurnRateAccumulatesRisingUsageInsideOneFiveHourWindow() {
        let now: Int64 = 1_000_000
        let reset = now + 4 * Self.hour
        var rate = BurnRate()

        rate.observe(previous: burnSnapshot(now: now, fiveHourUsed: 10, fiveHourReset: reset, weeklyUsed: 20),
                     current: burnSnapshot(now: now + 300, fiveHourUsed: 30, fiveHourReset: reset, weeklyUsed: 23),
                     provider: .codex)
        XCTAssertEqual(rate.fiveHourDeltaTotal, 20)
        XCTAssertEqual(rate.weeklyDeltaTotal, 3)

        // The reported reset time jitters by a second; that is the same window.
        rate.observe(previous: burnSnapshot(now: now + 300, fiveHourUsed: 30, fiveHourReset: reset, weeklyUsed: 23),
                     current: burnSnapshot(now: now + 600, fiveHourUsed: 40, fiveHourReset: reset + 1, weeklyUsed: 24),
                     provider: .codex)
        XCTAssertEqual(rate.fiveHourDeltaTotal, 30)
        XCTAssertEqual(rate.weeklyDeltaTotal, 4)
    }

    func testBurnRateSkipsRolloversLaggingReadsAndWeeklyResets() {
        let now: Int64 = 1_000_000
        let reset = now + 4 * Self.hour
        var rate = BurnRate()

        // A five-hour rollover: usage rose, but across two different windows.
        rate.observe(previous: burnSnapshot(now: now, fiveHourUsed: 40, fiveHourReset: reset, weeklyUsed: 24),
                     current: burnSnapshot(now: now + 300, fiveHourUsed: 45,
                                           fiveHourReset: reset + 5 * Self.hour, weeklyUsed: 25),
                     provider: .codex)
        // A lagging five-hour read.
        rate.observe(previous: burnSnapshot(now: now, fiveHourUsed: 40, fiveHourReset: reset, weeklyUsed: 24),
                     current: burnSnapshot(now: now + 300, fiveHourUsed: 38, fiveHourReset: reset, weeklyUsed: 24),
                     provider: .codex)
        // The weekly window reset between the two reads.
        rate.observe(previous: burnSnapshot(now: now, fiveHourUsed: 40, fiveHourReset: reset, weeklyUsed: 90),
                     current: burnSnapshot(now: now + 300, fiveHourUsed: 50, fiveHourReset: reset, weeklyUsed: 2),
                     provider: .codex)

        XCTAssertEqual(rate, BurnRate())
    }

    func testBurnRateNeedsAFullWindowOfSamplesBeforeItDivides() {
        var rate = BurnRate(fiveHourDeltaTotal: 99, weeklyDeltaTotal: 15)
        XCTAssertNil(rate.weeklyPercentPerFullFiveHour())
        rate.fiveHourDeltaTotal = BurnRate.minSamplePercent
        XCTAssertEqual(rate.weeklyPercentPerFullFiveHour(), 15)
    }

    // MARK: - Weekly deadline

    /// `maxBurnable` counts the partial current window while the deadline
    /// counts only whole ones. Letting the deadline decide `doomed` would
    /// report reachable quota as doomed — the one direction this must never
    /// get wrong.
    func testADeadlineAlreadyPastDoesNotMakeReachableQuotaDoomed() throws {
        let now: Int64 = 1_000_000
        let deadline = try XCTUnwrap(QuotaDomain.weeklyDeadline(
            now: now,
            fiveHour: runningWindow(used: 0, duration: Quota.fiveHourWindowMins,
                                    resetsIn: 4 * Self.hour, now: now),
            weekly: runningWindow(used: 0, duration: Quota.weeklyWindowMins,
                                  resetsIn: 29 * Self.hour, now: now),
            burnPerWindow: 15.7))
        XCTAssertEqual(deadline.maxBurnablePercent, 109.9, accuracy: 0.01)
        XCTAssertEqual(deadline.doomedWastePercent, 0)
        // Past the theoretical start, so: begin immediately.
        XCTAssertEqual(deadline.latestStartAt, now)
    }

    /// At the rate measured on real accounts a full weekly allowance takes
    /// about thirty hours of saturated use to spend.
    func testAFullWeeklyAllowanceIsDoomedInsideTwentyFourHours() throws {
        let now: Int64 = 1_000_000
        let doomed = try XCTUnwrap(QuotaDomain.weeklyDeadline(
            now: now, fiveHour: nil,
            weekly: runningWindow(used: 0, duration: Quota.weeklyWindowMins,
                                  resetsIn: 24 * Self.hour, now: now),
            burnPerWindow: 15.7))
        XCTAssertGreaterThan(doomed.doomedWastePercent, 0)

        let reachable = try XCTUnwrap(QuotaDomain.weeklyDeadline(
            now: now, fiveHour: nil,
            weekly: runningWindow(used: 0, duration: Quota.weeklyWindowMins,
                                  resetsIn: 40 * Self.hour, now: now),
            burnPerWindow: 15.7))
        XCTAssertEqual(reachable.doomedWastePercent, 0)
    }

    /// Thirty hours is exactly six windows; the seventh opens as the quota
    /// resets and absorbs nothing, but is counted on purpose so the bound errs
    /// toward "reachable".
    func testAnExactWindowMultipleErrsTowardReachable() throws {
        let now: Int64 = 1_000_000
        let deadline = try XCTUnwrap(QuotaDomain.weeklyDeadline(
            now: now, fiveHour: nil,
            weekly: runningWindow(used: 0, duration: Quota.weeklyWindowMins,
                                  resetsIn: 30 * Self.hour, now: now),
            burnPerWindow: 15.7))
        XCTAssertEqual(deadline.doomedWastePercent, 0)
    }

    func testOnlyTheCurrentWindowCountsWhenNoRolloverFits() throws {
        let now: Int64 = 1_000_000
        let deadline = try XCTUnwrap(QuotaDomain.weeklyDeadline(
            now: now,
            fiveHour: runningWindow(used: 60, duration: Quota.fiveHourWindowMins,
                                    resetsIn: 3 * Self.hour, now: now),
            weekly: runningWindow(used: 50, duration: Quota.weeklyWindowMins,
                                  resetsIn: 2 * Self.hour, now: now),
            burnPerWindow: 15.7))
        // 40% of one window is all that is reachable, out of the 50 left.
        XCTAssertEqual(deadline.maxBurnablePercent, 15.7 * 0.4, accuracy: 0.01)
        XCTAssertEqual(deadline.doomedWastePercent, 50 - 15.7 * 0.4, accuracy: 0.01)
    }

    func testAComfortableDeadlineLandsFarInTheFuture() throws {
        let now: Int64 = 1_000_000
        let deadline = try XCTUnwrap(QuotaDomain.weeklyDeadline(
            now: now, fiveHour: nil,
            weekly: runningWindow(used: 80, duration: Quota.weeklyWindowMins,
                                  resetsIn: 100 * Self.hour, now: now),
            burnPerWindow: 15.7))
        XCTAssertEqual(deadline.doomedWastePercent, 0)
        XCTAssertEqual(deadline.latestStartAt, now + 95 * Self.hour)
    }

    func testUnknownUsageAnUnanchoredResetOrAnUnmeasuredRateDrawsNoConclusion() {
        let now: Int64 = 1_000_000

        var unknown = runningWindow(used: 0, duration: Quota.weeklyWindowMins,
                                    resetsIn: 40 * Self.hour, now: now)
        unknown.usedPercent = nil
        XCTAssertNil(QuotaDomain.weeklyDeadline(now: now, fiveHour: nil, weekly: unknown, burnPerWindow: 15.7))

        var unanchored = runningWindow(used: 10, duration: Quota.weeklyWindowMins,
                                       resetsIn: 40 * Self.hour, now: now)
        unanchored.resetsAt = nil
        XCTAssertNil(QuotaDomain.weeklyDeadline(now: now, fiveHour: nil, weekly: unanchored, burnPerWindow: 15.7))

        let weekly = runningWindow(used: 10, duration: Quota.weeklyWindowMins,
                                   resetsIn: 40 * Self.hour, now: now)
        XCTAssertNil(QuotaDomain.weeklyDeadline(now: now, fiveHour: nil, weekly: weekly, burnPerWindow: 0))

        // Already past the reset.
        let expired = runningWindow(used: 10, duration: Quota.weeklyWindowMins,
                                    resetsIn: -Self.hour, now: now)
        XCTAssertNil(QuotaDomain.weeklyDeadline(now: now, fiveHour: nil, weekly: expired, burnPerWindow: 15.7))
    }

    // MARK: - Poke attribution

    /// `pokeMatchesWindow` on its own says yes to a five-hour window that never
    /// started, because Codex reports `resetsAt = observedAt + 5h` for one that
    /// is idle — the reasoned-back start is the read itself. This is why the
    /// engine may only consult it once a countdown is independently confirmed.
    func testPokeMatchesWindowAloneCannotDistinguishAnUnstartedWindow() {
        let now: Int64 = 1_000_000
        let idle = window(used: 0, duration: Quota.fiveHourWindowMins,
                          reset: now + Quota.fiveHourWindowMins * 60, observed: now)
        XCTAssertTrue(QuotaDomain.pokeMatchesWindow(pokeAt: now, window: idle))
        // The countdown check is what actually rejects it.
        XCTAssertFalse(QuotaDomain.countdownWindowActive(previous: nil, current: idle))
    }

    func testNormalizeLastPokeNeverPromotesWithoutARunningCountdown() {
        let poke = LastPoke(at: 1_000_000, model: "m", status: .unverified)
        let unchanged = QuotaDomain.normalizeLastPoke(poke, countdownActive: false, window: nil)
        XCTAssertEqual(unchanged?.status, .unverified)

        let started = window(used: 5, duration: Quota.fiveHourWindowMins,
                             reset: 1_000_000 + Quota.fiveHourWindowMins * 60, observed: 1_000_100)
        XCTAssertEqual(QuotaDomain.normalizeLastPoke(poke, countdownActive: true, window: started)?.status,
                       .verified)

        // A countdown someone else started is attributed to nobody.
        let elsewhere = window(used: 5, duration: Quota.fiveHourWindowMins,
                               reset: 1_000_000 + Quota.fiveHourWindowMins * 60 + 600, observed: 1_000_100)
        XCTAssertEqual(QuotaDomain.normalizeLastPoke(poke, countdownActive: true, window: elsewhere)?.status,
                       .notAttributed)
    }

    // MARK: - On-disk format

    /// The engine has to read the state files the Rust app already wrote, and
    /// leave them readable by it during the transition. This is a semantic
    /// round trip rather than a byte comparison: Rust emits `null` for optional
    /// fields without `skip_serializing_if` (`limitName`, `individualLimit`)
    /// while Swift's `encodeIfPresent` omits the key. Both decoders accept
    /// either spelling.
    func testStateSurvivesARoundTripThroughTheRustFormat() throws {
        let json = """
        {"version":2,
         "snapshot":{"observedAt":1786070000,
           "buckets":[{"limitId":"codex","limitName":null,"individualLimit":null,
             "primary":{"usedPercent":12.5,"windowDurationMins":300,"resetsAt":1786088000,"observedAt":1786070000},
             "secondary":{"usedPercent":34,"windowDurationMins":10080,"resetsAt":1786600000,"observedAt":1786070000,"countdownActive":true}}],
           "rateLimitResetCredits":{"availableCount":2,
             "credits":[{"grantedAt":1786000000,"expiresAt":1786600000,"status":"available"}]}},
         "accountFingerprint":"abc123def456",
         "weeklyKeeper":{"countdownActive":true,"lastHandledResetKey":"scheduled:1786000000",
           "lastPoke":{"at":1786000010,"model":"gpt-5.6-luna","response":"OK",
             "status":"not-attributed","attempt":1}},
         "fiveHourStarter":{"lastPoke":{"at":1786000020,"model":"gpt-5.6-luna","response":"OK",
             "status":"verified","attempt":1,"verifiedAt":1786000030}},
         "burnRate":{"fiveHourDeltaTotal":120.5,"weeklyDeltaTotal":18.9}}
        """
        let decoder = JSONDecoder()
        let first = try decoder.decode(AccountState.self, from: Data(json.utf8))
        let second = try decoder.decode(AccountState.self, from: JSONEncoder().encode(first))
        XCTAssertEqual(first, second)

        // Spot-check the fields the safety logic actually reads.
        XCTAssertEqual(first.weeklyKeeper.lastPoke?.status, .notAttributed)
        XCTAssertEqual(first.fiveHourStarter.lastPoke?.status, .verified)
        XCTAssertEqual(first.snapshot?.weeklyWindow()?.usedPercent, 34)
        XCTAssertTrue(second.snapshot?.weeklyWindow()?.countdownActive ?? false)
        XCTAssertEqual(first.snapshot?.rateLimitResetCredits?.availableCount, 2)
    }

    /// Claude's file has no credits and its own bucket ids, plus two fields
    /// Codex never writes: the 429 cooldown and the pending scheduled reset a
    /// missing weekly window leaves behind. A field this decoder does not
    /// declare is dropped on the next save, taking the Rust app's baseline
    /// with it — which is why the assertion is on the re-encoded copy.
    func testAClaudeStateFileSurvivesARoundTrip() throws {
        let json = """
        {"version":2,
         "snapshot":{"observedAt":1786070000,
           "buckets":[
             {"limitId":"claude:five_hour","limitName":null,"individualLimit":null,
              "primary":{"usedPercent":39,"windowDurationMins":300,"resetsAt":1786088000,"observedAt":1786070000,"countdownActive":true}},
             {"limitId":"claude:seven_day","limitName":null,"individualLimit":null,
              "primary":{"usedPercent":18,"windowDurationMins":10080,"resetsAt":1786600000,"observedAt":1786070000,"countdownActive":true}}]},
         "accountFingerprint":"ff115e80c225",
         "weeklyKeeper":{"countdownActive":true,"pendingScheduledResetAt":1786599999,
           "lastHandledResetKey":"scheduled:1786599999"},
         "fiveHourStarter":{"lastPoke":{"at":1786000020,"model":"claude-haiku-4-5-20251001",
             "response":"OK","status":"not-attributed","attempt":1,"verifiedAt":1786000030}},
         "burnRate":{"fiveHourDeltaTotal":0,"weeklyDeltaTotal":0},
         "checkCooldownUntil":1786070900}
        """
        let decoder = JSONDecoder()
        let first = try decoder.decode(AccountState.self, from: Data(json.utf8))
        let second = try decoder.decode(AccountState.self, from: JSONEncoder().encode(first))
        XCTAssertEqual(first, second)

        XCTAssertEqual(second.checkCooldownUntil, 1786070900)
        XCTAssertEqual(second.weeklyKeeper.pendingScheduledResetAt, 1786599999)
        XCTAssertEqual(second.weeklyKeeper.lastHandledResetKey, "scheduled:1786599999")
        XCTAssertEqual(second.fiveHourStarter.lastPoke?.status, .notAttributed)
        XCTAssertEqual(second.snapshot?.uniqueBucket("claude:seven_day")?.primary?.usedPercent, 18)
    }

    /// Antigravity keeps a keeper, a starter and a burn rate *per group*, and
    /// the two groups are at different stages — one has poked, one has not.
    /// Both have to come back, or a save flattens the pool that was mid-flight.
    func testAnAntigravityStateFileKeepsBothGroups() throws {
        let json = """
        {"version":2,
         "snapshot":{"observedAt":1786070000,
           "buckets":[
             {"limitId":"antigravity:gemini",
              "primary":{"usedPercent":0,"windowDurationMins":300,"resetsAt":1786088000,"observedAt":1786070000},
              "secondary":{"usedPercent":94,"windowDurationMins":10080,"resetsAt":1786600000,"observedAt":1786070000,"countdownActive":true}},
             {"limitId":"antigravity:claude_gpt",
              "primary":{"usedPercent":0,"windowDurationMins":300,"resetsAt":1786088000,"observedAt":1786070000},
              "secondary":{"usedPercent":34,"windowDurationMins":10080,"resetsAt":1786500000,"observedAt":1786070000,"countdownActive":true}}]},
         "weeklyKeeper":{},
         "fiveHourStarter":{},
         "burnRate":{"fiveHourDeltaTotal":0,"weeklyDeltaTotal":0},
         "antigravityGroups":{
           "gemini":{"weeklyKeeper":{"countdownActive":true,"lastHandledResetKey":"early:1786000000:1786600000"},
             "fiveHourStarter":{"lastPoke":{"at":1786057903,"model":"gemini-3.8-flash-low",
               "response":"OK.","status":"unverified","attempt":1}},
             "burnRate":{"fiveHourDeltaTotal":557,"weeklyDeltaTotal":91}},
           "claude_gpt":{"weeklyKeeper":{"countdownActive":true},"fiveHourStarter":{},
             "burnRate":{"fiveHourDeltaTotal":90,"weeklyDeltaTotal":31}}}}
        """
        let decoder = JSONDecoder()
        let first = try decoder.decode(AccountState.self, from: Data(json.utf8))
        let second = try decoder.decode(AccountState.self, from: JSONEncoder().encode(first))
        XCTAssertEqual(first, second)

        XCTAssertEqual(Set(second.antigravityGroups.keys), ["gemini", "claude_gpt"])
        let gemini = second.antigravityGroups["gemini"]
        XCTAssertEqual(gemini?.weeklyKeeper.lastHandledResetKey, "early:1786000000:1786600000")
        XCTAssertEqual(gemini?.fiveHourStarter.lastPoke?.status, .unverified)
        XCTAssertEqual(gemini?.burnRate.fiveHourDeltaTotal, 557)
        // The pool that has not poked keeps its own empty state rather than
        // borrowing the other's.
        XCTAssertNil(second.antigravityGroups["claude_gpt"]?.fiveHourStarter.lastPoke)
        XCTAssertEqual(second.antigravityGroups["claude_gpt"]?.burnRate.weeklyDeltaTotal, 31)
    }

    /// `countdownActive: false` is omitted entirely, matching the Rust
    /// `skip_serializing_if = "is_false"`.
    func testFalseCountdownIsOmittedFromTheEncodedForm() throws {
        let state = AccountState(snapshot: snapshot(window(used: 1, duration: Quota.fiveHourWindowMins,
                                                           reset: 2_000, observed: 1_000), nil))
        let encoded = try XCTUnwrap(String(data: JSONEncoder().encode(state), encoding: .utf8))
        XCTAssertFalse(encoded.contains("countdownActive"))
    }

    /// A v1 file is never migrated — it is rebuilt as an empty baseline, and a
    /// baseline can never poke.
    func testAVersionOneFileIsNotTreatedAsUsableState() throws {
        let v1 = #"{"version":1,"snapshot":{"observedAt":1,"buckets":[]}}"#
        let decoded = try JSONDecoder().decode(AccountState.self, from: Data(v1.utf8))
        XCTAssertEqual(decoded.version, 1, "the version gate lives in storage, which must reject this")
    }
}

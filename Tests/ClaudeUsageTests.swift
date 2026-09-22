import XCTest
@testable import Khih

/// Reading `/api/oauth/usage` into the engine's snapshot.
///
/// Every value here feeds a decision about whether to spend quota, so the
/// parser refuses what it cannot read rather than guessing. These tests are
/// mostly about the refusals.
final class ClaudeUsageTests: XCTestCase {
    private let observedAt: Int64 = 1_786_070_000

    private func snapshot(_ json: String) throws -> RateLimitsSnapshot {
        try ClaudeUsage.snapshot(from: Data(json.utf8), observedAt: observedAt)
    }

    // MARK: - Timestamps

    func testWholeSecondsPassThrough() {
        XCTAssertEqual(ClaudeUsage.epochSeconds(from: NSNumber(value: 1_786_088_000)), 1_786_088_000)
    }

    /// Milliseconds are told apart by magnitude, not by a flag in the response.
    func testMillisecondsBecomeSeconds() {
        XCTAssertEqual(ClaudeUsage.epochSeconds(from: NSNumber(value: 1_786_088_000_000)),
                       1_786_088_000)
        XCTAssertEqual(ClaudeUsage.epochSeconds(from: NSNumber(value: 1_786_088_000_500)),
                       1_786_088_000)
    }

    func testRFC3339IsAccepted() {
        XCTAssertEqual(ClaudeUsage.epochSeconds(from: "2026-08-16T04:00:00Z"), 1_786_852_800)
        // Fractional seconds are dropped, never rounded into the next second.
        XCTAssertEqual(ClaudeUsage.epochSeconds(from: "2026-08-16T04:00:00.500Z"), 1_786_852_800)
    }

    func testNonsenseIsNotATimestamp() {
        XCTAssertNil(ClaudeUsage.epochSeconds(from: "soon"))
        XCTAssertNil(ClaudeUsage.epochSeconds(from: NSNumber(value: 0)))
        XCTAssertNil(ClaudeUsage.epochSeconds(from: nil))
    }

    // MARK: - Percentages

    /// Out of range means the field is not what the parser thinks it is. A
    /// clamped 150% would read as an exhausted window and stop a poke that
    /// should have happened.
    func testAPercentageOutsideZeroToAHundredIsRefused() {
        XCTAssertNil(ClaudeUsage.percent(from: NSNumber(value: 150)))
        XCTAssertNil(ClaudeUsage.percent(from: NSNumber(value: -1)))
        XCTAssertEqual(ClaudeUsage.percent(from: NSNumber(value: 0)), 0)
        XCTAssertEqual(ClaudeUsage.percent(from: NSNumber(value: 100)), 100)
    }

    // MARK: - The snapshot

    func testTheTwoHeadlineWindowsBecomeTheirOwnBuckets() throws {
        let snapshot = try snapshot("""
        {"five_hour":{"utilization":39,"resets_at":1786088000},
         "seven_day":{"utilization":18,"resets_at":1786600000}}
        """)

        let fiveHour = snapshot.uniqueBucket("claude:five_hour")?.primary
        XCTAssertEqual(fiveHour?.usedPercent, 39)
        XCTAssertEqual(fiveHour?.windowDurationMins, 300)
        XCTAssertEqual(fiveHour?.resetsAt, 1_786_088_000)
        XCTAssertEqual(fiveHour?.observedAt, observedAt)

        let weekly = snapshot.weeklyWindow(for: .claude)
        XCTAssertEqual(weekly?.usedPercent, 18)
        XCTAssertEqual(weekly?.windowDurationMins, 10080)
    }

    /// A subscriber always has these two. Gone from the response is what a
    /// window that has just rolled over looks like, so it is materialised at
    /// zero with no reset — dropping the bucket would read as "no such limit",
    /// and `checkAccount` is what decides whether it really reset.
    func testAnAbsentHeadlineWindowIsMaterialisedAtZero() throws {
        let snapshot = try snapshot("""
        {"five_hour":{"utilization":39,"resets_at":1786088000}}
        """)

        let weekly = snapshot.weeklyWindow(for: .claude)
        XCTAssertEqual(weekly?.usedPercent, 0)
        XCTAssertNil(weekly?.resetsAt)
        XCTAssertEqual(weekly?.windowDurationMins, 10080)
    }

    /// The scoped windows are plan-dependent. Absent means this plan does not
    /// have one, and inventing a zero would put a limit on screen that the
    /// account does not have.
    func testAnAbsentScopedWindowGetsNoBucketAtAll() throws {
        let snapshot = try snapshot("""
        {"five_hour":{"utilization":1,"resets_at":1786088000},
         "seven_day":{"utilization":2,"resets_at":1786600000}}
        """)

        XCTAssertNil(snapshot.uniqueBucket("claude:seven_day_opus"))
        XCTAssertEqual(snapshot.buckets.count, 2)
    }

    func testAScopedWindowIsKeptWhenTheResponseHasOne() throws {
        let snapshot = try snapshot("""
        {"five_hour":{"utilization":1,"resets_at":1786088000},
         "seven_day":{"utilization":2,"resets_at":1786600000},
         "seven_day_opus":{"utilization":7,"resets_at":1786600000}}
        """)

        XCTAssertEqual(snapshot.uniqueBucket("claude:seven_day_opus")?.primary?.usedPercent, 7)
    }

    /// A window with no readable percentage is not a zero-percent window.
    func testAnUnreadablePercentageFallsBackToTheAbsentRule() throws {
        let snapshot = try snapshot("""
        {"five_hour":{"utilization":"lots","resets_at":1786088000},
         "seven_day":{"utilization":2,"resets_at":1786600000},
         "seven_day_opus":{"utilization":150,"resets_at":1786600000}}
        """)

        // Always present, so it is materialised — but at zero with no reset,
        // never at whatever the unreadable field seemed to say.
        let fiveHour = snapshot.fiveHourWindow(for: .claude)
        XCTAssertEqual(fiveHour?.usedPercent, 0)
        XCTAssertNil(fiveHour?.resetsAt)
        // Not always present, and out of range, so it is dropped.
        XCTAssertNil(snapshot.uniqueBucket("claude:seven_day_opus"))
    }

    /// A reading with no reset time is still a reading. The engine decides what
    /// an anchored window is; the parser does not do it early.
    func testAWindowWithoutAResetKeepsItsPercentage() throws {
        let snapshot = try snapshot("""
        {"five_hour":{"utilization":39},"seven_day":{"utilization":18,"resets_at":1786600000}}
        """)

        XCTAssertEqual(snapshot.fiveHourWindow(for: .claude)?.usedPercent, 39)
        XCTAssertNil(snapshot.fiveHourWindow(for: .claude)?.resetsAt)
    }

    func testABodyThatIsNotAnObjectIsRefused() {
        XCTAssertThrowsError(try snapshot("[]"))
    }
}

/// The signed-in account, without going near the token.
final class ClaudeIdentityTests: XCTestCase {
    private func fingerprint(_ json: String) -> String? {
        ClaudeIdentity.fingerprint(fromStatus: Data(json.utf8))
    }

    func testOrgAndAddressTogetherMakeTheFingerprint() {
        let value = fingerprint(#"{"orgId":"org_1","email":"a@example.com"}"#)
        XCTAssertEqual(value, QuotaFingerprint.short(of: "org_1a@example.com"))
        XCTAssertEqual(value?.count, 12)
    }

    /// The same fields have been seen nested under `account`.
    func testTheNestedShapeIsRead() {
        XCTAssertEqual(fingerprint(#"{"account":{"orgId":"org_1","email":"a@example.com"}}"#),
                       fingerprint(#"{"orgId":"org_1","email":"a@example.com"}"#))
    }

    /// Neither half is optional. A fingerprint made from one of them would be
    /// stable across a genuine account change, which is the one thing it exists
    /// to notice.
    func testHalfAnIdentityIsNoIdentity() {
        XCTAssertNil(fingerprint(#"{"orgId":"org_1"}"#))
        XCTAssertNil(fingerprint(#"{"email":"a@example.com"}"#))
        XCTAssertNil(fingerprint(#"{"orgId":"","email":"a@example.com"}"#))
        XCTAssertNil(fingerprint("not json"))
    }

    /// Neither the address nor the org may appear in what is stored.
    func testTheAddressIsNowhereInTheResult() {
        let value = fingerprint(#"{"orgId":"org_1","email":"a@example.com"}"#)
        XCTAssertEqual(value?.contains("a@example.com"), false)
        XCTAssertEqual(value?.contains("org_1"), false)
    }
}

/// The 429 cooldown, and the minimal request's shape.
final class ClaudeBackendTests: XCTestCase {
    private let now: Int64 = 1_786_070_000

    private func response(_ retryAfter: String?) -> HTTPURLResponse {
        HTTPURLResponse(url: ClaudeBackend.endpoint, statusCode: 429, httpVersion: "HTTP/1.1",
                        headerFields: retryAfter.map { ["Retry-After": $0] } ?? [:])!
    }

    func testAWholeNumberOfSecondsIsObeyed() {
        XCTAssertEqual(ClaudeBackend.cooldown(from: response("90"), now: now), now + 90)
    }

    func testAnHTTPDateIsObeyed() {
        XCTAssertEqual(ClaudeBackend.cooldown(from: response("Sun, 16 Aug 2026 04:00:00 GMT"),
                                              now: now),
                       1_786_852_800)
    }

    /// This endpoint has been seen to answer `Retry-After: 0`, which taken
    /// literally means retrying straight back into the limit that produced it.
    /// No guidance is safer than that guidance.
    func testAZeroOrPastDeadlineIsTreatedAsNoGuidance() {
        XCTAssertEqual(ClaudeBackend.cooldown(from: response("0"), now: now),
                       now + ClaudeBackend.blindCooldown)
        XCTAssertEqual(ClaudeBackend.cooldown(from: response("Sun, 16 Aug 2020 04:00:00 GMT"),
                                              now: now),
                       now + ClaudeBackend.blindCooldown)
    }

    func testNoHeaderMeansTheFixedQuarterHour() {
        XCTAssertEqual(ClaudeBackend.cooldown(from: response(nil), now: now),
                       now + ClaudeBackend.blindCooldown)
        XCTAssertEqual(ClaudeBackend.cooldown(from: response("soon"), now: now),
                       now + ClaudeBackend.blindCooldown)
    }

    // MARK: - The minimal request

    /// Each of these bounds what the request can do or cost. A missing one is
    /// not a style change — it is a request that can run a tool, load settings,
    /// or leave a session behind.
    func testTheRequestIsBoundedOnEverySide() {
        let args = ClaudePoke.arguments()
        for expected in ["--safe-mode", "--strict-mcp-config", "--no-session-persistence"] {
            XCTAssertTrue(args.contains(expected), expected)
        }
        for (flag, value) in [("--tools", ""), ("--setting-sources", ""),
                              ("--max-budget-usd", "0.05"),
                              ("--model", "claude-haiku-4-5-20251001")] {
            guard let index = args.firstIndex(of: flag) else {
                return XCTFail("missing \(flag)")
            }
            XCTAssertEqual(args[index + 1], value, flag)
        }
        XCTAssertEqual(args.first, "-p")
        XCTAssertEqual(args[1], "Reply with exactly: OK")
    }

    /// Billing the request anywhere but the subscription measures a quota this
    /// is not guarding. Removed rather than blanked: an empty key is not
    /// reliably the same as an absent one.
    func testBillingVariablesAreRemovedNotBlanked() {
        let environment = ClaudePoke.environment(from: [
            "ANTHROPIC_API_KEY": "sk-test",
            "CLAUDE_CODE_USE_BEDROCK": "1",
            "AWS_SECRET_ACCESS_KEY": "secret",
            "ANTHROPIC_VERTEX_PROJECT_ID": "p",
            "PATH": "/usr/bin"
        ])

        for key in ClaudePoke.clearedEnvironment {
            XCTAssertNil(environment[key], key)
        }
        XCTAssertEqual(environment["PATH"], "/usr/bin", "the rest of the environment is left alone")
    }
}

/// Resolving something expensive without paying for it at launch, or paying
/// for it again on every poll.
final class LazilyTests: XCTestCase {
    func testItIsMadeOnceAndOnlyWhenAsked() {
        var made = 0
        let value = Lazily<Int> { made += 1; return 7 }

        XCTAssertEqual(made, 0, "creating it must not run the work")
        XCTAssertEqual(value.get(), 7)
        XCTAssertEqual(value.get(), 7)
        XCTAssertEqual(made, 1)
    }

    /// Nil is an answer, not an absence — a Mac without Claude Code installed
    /// must not spawn again hoping for a better one.
    func testNilIsRemembered() {
        var made = 0
        let value = Lazily<String?> { made += 1; return nil }

        XCTAssertNil(value.get())
        XCTAssertNil(value.get())
        XCTAssertEqual(made, 1)
    }
}

// MARK: - The CLI read the engine falls back to

extension ClaudeUsageTests {

    private static let cliOutput = """
    Current session: 38% used · resets Sep 7 at 2:59pm (Asia/Taipei)
    Current week (all models): 4% used · resets Sep 14 at 5:59am (Asia/Taipei)
    Current week (Opus): 12% used · resets Sep 14 at 5:59am (Asia/Taipei)
    """

    func testCLIRowsBecomeTheEnginesOwnBuckets() throws {
        let rows = ClaudeUsageCLI.rows(Self.cliOutput, now: Date(timeIntervalSince1970: 1_757_000_000))
        let snapshot = try ClaudeUsage.observation(rows: rows, observedAt: 1_757_000_000)

        let ids = Set(snapshot.buckets.map(\.limitId))
        XCTAssertEqual(ids, ["claude:five_hour", "claude:seven_day", "claude:seven_day_opus"])

        let fiveHour = try XCTUnwrap(snapshot.buckets.first { $0.limitId == "claude:five_hour" }?.primary)
        XCTAssertEqual(fiveHour.usedPercent, 38)
        XCTAssertEqual(fiveHour.windowDurationMins, Quota.fiveHourWindowMins)

        let weekly = try XCTUnwrap(snapshot.buckets.first { $0.limitId == "claude:seven_day" }?.primary)
        XCTAssertEqual(weekly.usedPercent, 4)
        XCTAssertEqual(weekly.windowDurationMins, Quota.weeklyWindowMins)
    }

    /// Parity with the endpoint path, which materialises an absent
    /// always-present window at zero: Claude drops a window the moment its
    /// reset passes, so absence is what a rollover looks like. The two sources
    /// have to describe one the same way or the guard behaves differently
    /// depending on which answered.
    func testAnAbsentAlwaysPresentWindowIsMaterialisedLikeTheEndpoint() throws {
        let rows = ClaudeUsageCLI.rows("Current session: 5% used", now: Date())
        let snapshot = try ClaudeUsage.observation(rows: rows, observedAt: 1_757_000_000)

        let weekly = try XCTUnwrap(snapshot.buckets.first { $0.limitId == "claude:seven_day" }?.primary)
        XCTAssertEqual(weekly.usedPercent, 0)
        XCTAssertNil(weekly.resetsAt, "materialised, not invented with a reset time")
    }

    func testEmptyOutputIsRejectedWhole() {
        XCTAssertThrowsError(try ClaudeUsage.observation(rows: [], observedAt: 1_757_000_000))
    }

    func testCLIKindsMapOntoTheEngineKeys() {
        XCTAssertEqual(ClaudeUsage.engineKey(forCLIKind: "session"), Quota.claudeFiveHourKey)
        XCTAssertEqual(ClaudeUsage.engineKey(forCLIKind: "weekly_all"), Quota.claudeWeeklyKey)
        XCTAssertEqual(ClaudeUsage.engineKey(forCLIKind: "weekly_opus"), "seven_day_opus")
        XCTAssertNil(ClaudeUsage.engineKey(forCLIKind: "something_else"))
    }
}

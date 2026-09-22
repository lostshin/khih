import XCTest
@testable import Khih

final class QuotaBurnReadingTests: XCTestCase {
    private let now: Int64 = 1_800_000_000
    private var reading: QuotaBurnReading {
        .init(observedAt: now, rate: BurnRate(fiveHourDeltaTotal: 200, weeklyDeltaTotal: 30),
              fiveHour: QuotaWindow(usedPercent: 0, windowDurationMins: 300, resetsAt: now + 18000, observedAt: now),
              weekly: QuotaWindow(usedPercent: 40, windowDurationMins: 10080, resetsAt: now + 604800, observedAt: now))
    }

    func testEstimateUsesRustRatioAndDeadline() throws {
        XCTAssertEqual(reading.rate.weeklyPercentPerFullFiveHour(), 15)
        let lines = reading.lines(now: now)
        XCTAssertEqual(lines[0], "Full 5h ≈ 15.0% weekly")
        XCTAssertTrue(lines[1].hasPrefix("Start by "))
        var doomed = reading
        doomed.weekly?.resetsAt = now + 60
        XCTAssertTrue(doomed.lines(now: now)[1].contains("45.0%"))
    }

    func testUnknownStaleAndInsufficientDataNeverInventAnEstimate() {
        XCTAssertEqual(reading.lines(now: now + 901)[1], "The reading is out of date.")
        var unknown = reading
        unknown.weekly?.usedPercent = nil
        XCTAssertEqual(unknown.lines(now: now)[1], "The usage is unknown.")
        unknown = reading
        unknown.rate = BurnRate(fiveHourDeltaTotal: 99, weeklyDeltaTotal: 20)
        XCTAssertEqual(unknown.lines(now: now)[1], "Not enough usage to estimate yet.")
    }

    func testAntigravityGroupSamplesRemainSeparate() {
        var state = AccountState(snapshot: RateLimitsSnapshot(observedAt: now))
        state.antigravityGroups["gemini"] = AntigravityGroupState(burnRate: BurnRate(fiveHourDeltaTotal: 200, weeklyDeltaTotal: 20))
        state.antigravityGroups["claude_gpt"] = AntigravityGroupState(burnRate: BurnRate(fiveHourDeltaTotal: 200, weeklyDeltaTotal: 40))
        let readings = QuotaBurnReading.readings(from: state, provider: .antigravity)
        XCTAssertEqual(readings.map { $0.rate.weeklyPercentPerFullFiveHour() }, [10,20])
        XCTAssertEqual(readings.map(\.group), ["gemini", "claude_gpt"])
    }
}

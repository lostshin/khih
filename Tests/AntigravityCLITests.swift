import XCTest
@testable import Codenotch

final class AntigravityCLITests: XCTestCase {
    private let rows = [
        "Gemini Models\tWeekly Limit Remaining\t96%\t2026-09-10T07:04:41Z",
        "Gemini Models\tFive Hour Limit Remaining\t93%\t2026-09-03T13:52:32Z",
        "Claude and GPT models\tWeekly Limit Remaining\t100%\t2026-09-10T11:23:20Z",
        "Claude and GPT models\tFive Hour Limit Remaining\t100%\t2026-09-03T16:23:20Z"
    ]

    private func envelope(_ rows: [String], status: String = "SUCCESS") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["status": status, "response": rows.joined(separator: "\n")])
    }

    func testOfficialGroupsAndProvisionalZero() throws {
        let snapshot = try AntigravityUsage.snapshot(from: envelope(rows), observedAt: 1_788_430_000)
        XCTAssertEqual(snapshot.buckets.map(\.limitId), ["antigravity:gemini", "antigravity:claude_gpt"])
        XCTAssertEqual(snapshot.buckets[0].primary?.usedPercent, 7)
        XCTAssertEqual(snapshot.buckets[0].secondary?.usedPercent, 4)
        XCTAssertEqual(snapshot.buckets[0].primary?.windowDurationMins, 300)
        XCTAssertEqual(snapshot.buckets[0].secondary?.windowDurationMins, 10080)
        XCTAssertEqual(snapshot.buckets[1].primary?.countdownActive, false)
        XCTAssertEqual(snapshot.buckets[1].secondary?.countdownActive, false)
    }

    func testRefusesMissingDuplicateInvalidAndFailedResponses() throws {
        var variants = [Array(rows.dropLast()), rows + [rows[0]], Array(rows.prefix(2))]
        for invalid in ["101%", "-1%", "nan%", "inf%", "93"] {
            variants.append(rows.map { $0.replacingOccurrences(of: "93%", with: invalid) })
        }
        variants.append(rows.map { $0.replacingOccurrences(of: "2026-09-03T13:52:32Z", with: "bad") })
        variants.append(rows + ["Gemini Models\tWeekly Limit Remaining"])
        for variant in variants {
            XCTAssertThrowsError(try AntigravityUsage.snapshot(from: envelope(variant), observedAt: 0))
        }
        XCTAssertThrowsError(try AntigravityUsage.snapshot(from: envelope(rows, status: "ERROR"), observedAt: 0))
    }

    func testFractionalTimestampTruncates() throws {
        let plain = try AntigravityUsage.snapshot(from: envelope(rows), observedAt: 0)
        let fractional = rows.map { $0.replacingOccurrences(of: "13:52:32Z", with: "13:52:32.999Z") }
        let snapshot = try AntigravityUsage.snapshot(from: envelope(fractional), observedAt: 0)
        XCTAssertEqual(snapshot.buckets[0].primary?.resetsAt, plain.buckets[0].primary?.resetsAt)
    }

    func testSingleCellKeepsBothGroupsAndQuotesTheGeminiSession() async throws {
        let data = try envelope(rows)
        let provider = AntigravityCLIProvider(read: {
            try AntigravityUsage.snapshot(from: data, observedAt: 0)
        })
        let snapshot = try await provider.fetchSnapshot()
        let cells = snapshot.notchSnapshots
        XCTAssertEqual(cells.map(\.id), ["gemini"])
        XCTAssertEqual(cells.map(\.providerID), ["gemini"])
        XCTAssertEqual(cells.map(\.headlineText), ["93%"])
        XCTAssertEqual(cells.map { $0.windows.count }, [4])
        XCTAssertEqual(provider.minimumRefreshInterval, 300)
        XCTAssertEqual(provider.fetchDeadline, 140)
        var stale = snapshot
        stale.status = .stale(since: Date(timeIntervalSince1970: 1))
        XCTAssertTrue(stale.notchSnapshots.allSatisfy { $0.status.isStale })
    }

    /// The real shape of a week's use: the seven-day window has had seven days
    /// to fill and the five-hour one has just reset. Taking the fullest window
    /// put the weekly figure on the ring almost always, which is not the number
    /// that decides whether the next prompt goes through.
    func testTheRingQuotesTheSessionEvenWhenTheWeekIsNearlyGone() async throws {
        let spent = [
            "Gemini Models\tWeekly Limit Remaining\t6%\t2026-09-10T07:04:41Z",
            "Gemini Models\tFive Hour Limit Remaining\t99%\t2026-09-03T13:52:32Z",
            "Claude and GPT models\tWeekly Limit Remaining\t34%\t2026-09-10T11:23:20Z",
            "Claude and GPT models\tFive Hour Limit Remaining\t100%\t2026-09-03T16:23:20Z"
        ]
        let data = try envelope(spent)
        let provider = AntigravityCLIProvider(read: {
            try AntigravityUsage.snapshot(from: data, observedAt: 0)
        })
        let snapshot = try await provider.fetchSnapshot()
        XCTAssertEqual(snapshot.headlineID, "antigravity:gemini:five-hour")
        XCTAssertEqual(snapshot.headlineText, "99%")
        // All four windows are still in the card; only the ring changed.
        XCTAssertEqual(snapshot.windows.count, 4)
    }

    func testWithoutTheGeminiSessionTheFullestWindowStillNamesTheRing() {
        let windows = [
            LimitWindow(id: "antigravity:gemini:weekly", label: "Weekly", usedFraction: 0.94),
            LimitWindow(id: "antigravity:claude_gpt:weekly", label: "Weekly", usedFraction: 0.34)
        ]
        XCTAssertEqual(AntigravityCLIProvider.headlineID(in: windows), "antigravity:gemini:weekly")
    }

    private func executable(_ body: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("agy")
        try ("#!/bin/sh\n" + body).write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return file
    }

    func testFakeExecutableReceivesOnlyUsageArguments() throws {
        let json = String(decoding: try envelope(rows), as: UTF8.self)
        let binary = try executable("[ \"$*\" = '-p /usage --output-format json' ] || exit 9\ncat <<'JSON'\n\(json)\nJSON\n")
        let data = try QuotaProcess.run(binary: binary, arguments: AntigravityUsage.arguments,
                                        environment: [:], timeout: 2)
        XCTAssertEqual(try AntigravityUsage.snapshot(from: data, observedAt: 0).buckets.count, 2)
        XCTAssertEqual(try AntigravityUsage.resolve(environment: ["CODEX_QUOTA_KEEPER_ANTIGRAVITY_BIN": binary.path]), binary)
        XCTAssertThrowsError(try AntigravityUsage.resolve(environment: ["CODEX_QUOTA_KEEPER_ANTIGRAVITY_BIN": binary.path + "-missing"]))
    }

    func testSilentChildIgnoringTerminationStillTimesOut() throws {
        let binary = try executable("trap '' TERM\nwhile :; do :; done\n")
        let started = Date()
        XCTAssertThrowsError(try QuotaProcess.run(binary: binary, arguments: [], environment: [:], timeout: 0.1))
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    func testTimeoutTerminatesTheWholeProcessGroup() throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: pidFile) }
        let binary = try executable("""
        /bin/sh -c 'trap "" TERM; while :; do sleep 1; done' &
        echo $! > "$1"
        trap '' TERM
        while :; do sleep 1; done
        """)

        XCTAssertThrowsError(try QuotaProcess.run(
            binary: binary, arguments: [pidFile.path], environment: [:], timeout: 0.5))
        let childPID = try XCTUnwrap(Int32(
            String(contentsOf: pidFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)))
        let deadline = Date().addingTimeInterval(1)
        while kill(childPID, 0) == 0, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertEqual(kill(childPID, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testBothPipesDrainBeyondCapacity() throws {
        let binary = try executable("/usr/bin/head -c 200000 /dev/zero >&2\n/usr/bin/head -c 200000 /dev/zero\n")
        XCTAssertEqual(try QuotaProcess.run(binary: binary, arguments: [], environment: [:], timeout: 3).count, 200000)
    }
}

@MainActor
final class AntigravityPollingTests: XCTestCase {
    private final class Provider: UsageProvider {
        let id = "gemini"
        let displayName = "Antigravity"
        let glyph = ProviderGlyph.antigravity
        let minimumRefreshInterval: TimeInterval = 300
        var fetchDeadline: TimeInterval = 0.4
        var calls = 0
        var fails = false
        var blocks = false
        var continuation: CheckedContinuation<Void, Never>?
        func fetchSnapshot() async throws -> ProviderSnapshot {
            calls += 1
            if blocks { await withCheckedContinuation { continuation = $0 } }
            if fails { throw UsageProviderError.badResponse(status: 500) }
            return ProviderSnapshot(id: id, displayName: displayName, glyph: glyph,
                                    fidelity: .official, status: .ok,
                                    windows: [LimitWindow(id: "w", label: "W", usedFraction: 0.1)])
        }
        func release() { continuation?.resume(); continuation = nil }
    }

    private func store(_ provider: Provider, now: @escaping () -> Date) -> UsageStore {
        let name = "AntigravityPollingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return UsageStore(providers: [provider], refreshDeadline: 0.1,
                          archive: UsageArchive(defaults: defaults), pollingNow: now)
    }

    func testAutomaticPollingWaits300SecondsButExplicitRefreshIsFresh() async {
        let provider = Provider()
        var now = Date()
        let store = store(provider, now: { now })
        await store.refresh()
        now = now.addingTimeInterval(299)
        await store.refresh()
        XCTAssertEqual(provider.calls, 1)
        now = now.addingTimeInterval(1)
        await store.refresh()
        XCTAssertEqual(provider.calls, 2)
        await store.refresh(providerID: "gemini")?.value
        XCTAssertEqual(provider.calls, 3)
        store.stop()
    }

    func testFailureKeepsReadingAndImmediatelyMarksItStale() async {
        let provider = Provider()
        let store = store(provider, now: Date.init)
        await store.refresh()
        provider.fails = true
        await store.refresh(providerID: "gemini")?.value
        XCTAssertEqual(store.snapshots.first?.windows.first?.usedFraction, 0.1)
        XCTAssertEqual(store.snapshots.first?.status.isStale, true)
        store.stop()
    }

    func testIndependentDeadlineAndSingleFlight() async throws {
        let provider = Provider()
        provider.blocks = true
        let store = store(provider, now: Date.init)
        store.refreshNow()
        try await Task.sleep(nanoseconds: 220_000_000)
        XCTAssertTrue(store.refreshing.contains("gemini"), "global deadline must allow the slower CLI")
        _ = store.refresh(providerID: "gemini")
        XCTAssertEqual(provider.calls, 1)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(store.refreshing.contains("gemini"))
        XCTAssertTrue(store.inFlightForTesting.contains("gemini"), "retain ownership until process exit")
        _ = store.refresh(providerID: "gemini")
        XCTAssertEqual(provider.calls, 1)
        provider.release()
        store.stop()
    }
}

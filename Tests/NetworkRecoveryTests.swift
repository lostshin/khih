import XCTest
@testable import Khih

@MainActor
final class NetworkRecoveryTests: XCTestCase {
    private final class Provider: UsageProvider {
        let id: String
        let displayName = "Test"
        let glyph = ProviderGlyph.openai
        let minimumRefreshInterval: TimeInterval = 300
        var calls = 0
        var freshCalls = 0
        var delay: UInt64 = 0
        var fails = false
        var active = 0
        var peak = 0
        init(_ id: String) { self.id = id }
        func fetchSnapshot() async throws -> ProviderSnapshot {
            calls += 1
            active += 1
            peak = max(peak, active)
            defer { active -= 1 }
            if delay > 0 { try await Task.sleep(nanoseconds: delay) }
            if fails { throw UsageProviderError.badResponse(status: 500) }
            return ProviderSnapshot(id: id, displayName: displayName, glyph: glyph,
                                    fidelity: .official, status: .ok,
                                    windows: [LimitWindow(id: "5h", label: "5h", usedFraction: 0.2,
                                                          duration: 18000)])
        }
        func fetchSnapshotAfterReconnect() async throws -> ProviderSnapshot {
            freshCalls += 1
            return try await fetchSnapshot()
        }
        func signOut() async {}
    }

    private func store(_ providers: [Provider], disconnected: Set<String> = []) -> UsageStore {
        let suite = "NetworkRecoveryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return UsageStore(providers: providers, archive: UsageArchive(defaults: defaults),
                          disconnected: disconnected)
    }

    func testReconnectFetchesAllEnabledSourcesWithoutWaitingForPollInterval() async throws {
        let a = Provider("a"), b = Provider("b"), disabled = Provider("disabled")
        let store = store([a, b, disabled], disconnected: ["disabled"])
        defer { store.stop() }
        await store.refresh()
        store.networkChanged(available: false)
        store.networkChanged(available: true)
        store.networkChanged(available: true)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(a.freshCalls, 1)
        XCTAssertEqual(b.freshCalls, 1)
        XCTAssertEqual(disabled.calls, 0)
        XCTAssertEqual(store.recoverySucceeded, ["a", "b"])
        XCTAssertEqual(store.recoveryPassed, true)
    }

    func testInitialOnlineEventDoesNotDuplicateStartupRead() async {
        let p = Provider("a")
        let store = store([p])
        store.networkChanged(available: true)
        await Task.yield()
        XCTAssertEqual(p.calls, 0)
        XCTAssertNil(store.recoveryPassed)
        store.stop()
    }

    func testFastSourcePublishesBeforeSlowSourceFinishes() async throws {
        let fast = Provider("fast"), slow = Provider("slow")
        slow.delay = 2_300_000_000
        let store = store([fast, slow])
        defer { store.stop() }
        store.networkChanged(available: false)
        store.networkChanged(available: true)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(store.snapshots.first { $0.id == "fast" }?.status, .ok)
        XCTAssertEqual(store.recoverySucceeded, ["fast"])
        XCTAssertEqual(store.recoveryPending, ["slow"])
        XCTAssertNil(store.recoveryPassed)
    }

    func testSlowSourceFailsTwoSecondRequirementButEventuallyUpdates() async throws {
        let p = Provider("slow")
        p.delay = 2_300_000_000
        let store = store([p])
        defer { store.stop() }
        store.networkChanged(available: false)
        store.networkChanged(available: true)
        try await Task.sleep(nanoseconds: 2_100_000_000)
        XCTAssertEqual(store.recoveryPassed, false)
        XCTAssertEqual(store.recoveryPending, ["slow"])
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(store.snapshots.first?.status, .ok)
        XCTAssertEqual(store.recoveryPassed, false)
        XCTAssertTrue(store.recoverySucceeded.isEmpty)
    }

    func testFailureCannotPassUsingLastGoodCache() async throws {
        let p = Provider("a")
        let actual = store([p])
        defer { actual.stop() }
        await actual.refresh()
        p.fails = true
        actual.networkChanged(available: false)
        actual.networkChanged(available: true)
        try await Task.sleep(nanoseconds: 2_100_000_000)
        XCTAssertFalse(actual.snapshots.isEmpty)
        XCTAssertTrue(actual.recoverySucceeded.isEmpty)
        XCTAssertEqual(actual.recoveryPassed, false)
    }

    func testReconnectWaitsForExistingReadWithoutOverlappingIt() async throws {
        let p = Provider("a")
        p.delay = 100_000_000
        let store = store([p])
        defer { store.stop() }
        store.refreshNow()
        try await Task.sleep(nanoseconds: 20_000_000)
        store.networkChanged(available: false)
        store.networkChanged(available: true)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(p.peak, 1)
        XCTAssertEqual(p.calls, 2)
        XCTAssertEqual(p.freshCalls, 1)
    }

    func testOfflinePollingDoesNotStartUsageReads() async {
        let p = Provider("a")
        let store = store([p])
        defer { store.stop() }
        store.networkChanged(available: false)
        await store.refresh()
        XCTAssertEqual(p.calls, 0)
    }
}

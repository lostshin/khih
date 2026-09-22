import XCTest
@testable import Khih

final class SharedClaudeCooldownTests: XCTestCase {
    private final class Backend: QuotaBackend {
        var fingerprints = 0
        var reads = 0
        var pokes = 0
        var failOnRead = 1
        var snapshot = RateLimitsSnapshot()
        let until: Int64 = 1_800_000_900

        func accountFingerprint(for account: QuotaAccountConfig) -> String? {
            fingerprints += 1
            return "anonymous"
        }
        func readRateLimits(for account: QuotaAccountConfig, observedAt: Int64) throws -> RateLimitsSnapshot {
            reads += 1
            if reads >= failOnRead { throw QuotaBackendError.rateLimited(retryAt: until) }
            return snapshot
        }
        func poke(for account: QuotaAccountConfig, target: PokeTarget,
                  expectedFingerprint: String?) throws -> QuotaPokeResult {
            pokes += 1
            return QuotaPokeResult(model: "fake", response: "OK", accountFingerprint: "anonymous")
        }
    }

    func testEngineAndFiveHourRespectSharedCooldownWithoutReadingIdentity() throws {
        try withFixture { storage, account, cooldown, backend, engine in
            cooldown.record(until: backend.until, now: 1_800_000_000)
            XCTAssertEqual(try engine.checkAccount(account: account, mode: .manual), .rateLimited(retryAt: backend.until))
            guard case .failed = try engine.startFiveHour(account: account, trigger: .manual) else {
                return XCTFail("Expected cooldown refusal")
            }
            XCTAssertEqual(backend.fingerprints, 0)
            XCTAssertEqual(backend.reads, 0)
            XCTAssertEqual(backend.pokes, 0)
        }
    }

    func testEngine429IsSharedAndKeepsTheCachedSnapshot() throws {
        try withFixture { storage, account, cooldown, backend, engine in
            let before = storage.loadState(for: account).snapshot
            XCTAssertEqual(try engine.checkAccount(account: account, mode: .manual), .rateLimited(retryAt: backend.until))
            XCTAssertEqual(cooldown.deadline(now: 1_800_000_000), backend.until)
            let after = storage.loadState(for: account)
            XCTAssertEqual(after.snapshot, before)
            XCTAssertEqual(after.checkCooldownUntil, backend.until)
            let activity = storage.recentActivity(for: account, limit: 100)
            _ = try engine.checkAccount(account: account, mode: .manual)
            XCTAssertEqual(storage.recentActivity(for: account, limit: 100), activity)
            XCTAssertEqual(backend.reads, 1)
            XCTAssertEqual(backend.fingerprints, 1)
        }
    }

    func testSuccessfulReadAfterExpiryClearsTheCooldown() throws {
        try withFixture { storage, account, cooldown, backend, engine in
            _ = try engine.checkAccount(account: account, mode: .manual)
            backend.failOnRead = Int.max
            engine.now = { backend.until }
            _ = try engine.checkAccount(account: account, mode: .observe)
            XCTAssertEqual(backend.reads, 2)
            XCTAssertNil(storage.loadState(for: account).checkCooldownUntil)
            XCTAssertNil(cooldown.deadline(now: backend.until))
        }
    }

    func testVerification429StopsFurtherReadsAndPersistsUnverifiedPoke() throws {
        try withFixture { storage, account, cooldown, backend, engine in
            backend.failOnRead = 2
            XCTAssertEqual(try engine.startFiveHour(account: account, trigger: .manual), .started(.unverified))
            XCTAssertEqual(backend.reads, 2)
            XCTAssertEqual(backend.pokes, 1)
            let state = storage.loadState(for: account)
            XCTAssertEqual(state.fiveHourStarter.lastPoke?.status, .unverified)
            XCTAssertEqual(state.checkCooldownUntil, backend.until)
            XCTAssertEqual(cooldown.deadline(now: 1_800_000_000), backend.until)
        }
    }

    func testSuccessCannotEraseANewer429AndExpiredDeadlineAllowsRecovery() {
        let name = "CooldownRecovery.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let gate = ClaudeCooldown(archive: UsageArchive(defaults: defaults))
        gate.record(until: 2000, now: 1000)
        gate.record(until: 1500, now: 1000)
        gate.succeeded(now: 1100)
        XCTAssertEqual(gate.deadline(now: 1100), 2000)
        XCTAssertNil(gate.deadline(now: 2000))
        gate.succeeded(now: 2000)
        XCTAssertNil(defaults.object(forKey: "backoffUntil"))
    }

    private func withFixture(_ work: (QuotaStorage, QuotaAccountConfig, ClaudeCooldown, Backend, QuotaEngine) throws -> Void) throws {
        let name = "SharedCooldown.\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let defaults = UserDefaults(suiteName: name)!
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: name)
        }
        let storage = QuotaStorage(baseDir: root)
        let account = QuotaAccountConfig(id: "anonymous", label: "Test", provider: .claude,
                                         codexHome: root.appendingPathComponent("home").path,
                                         stateDir: root.appendingPathComponent("state").path)
        let clock: Int64 = 1_800_000_000
        let backend = Backend()
        backend.snapshot = RateLimitsSnapshot(observedAt: clock, buckets: [
            RateLimitBucket(limitId: "claude:five_hour", primary:
                QuotaWindow(usedPercent: 0, windowDurationMins: 300, resetsAt: clock + 18000, observedAt: clock)),
            RateLimitBucket(limitId: "claude:seven_day", primary:
                QuotaWindow(usedPercent: 30, windowDurationMins: 10080, resetsAt: clock + 600000, observedAt: clock))
        ])
        var baseline = AccountState(accountFingerprint: "anonymous")
        baseline.snapshot = backend.snapshot
        baseline.snapshot?.observedAt = clock - 600
        baseline.snapshot?.buckets[0].primary?.observedAt = clock - 600
        baseline.snapshot?.buckets[0].primary?.resetsAt = clock - 600 + 18000
        try storage.saveState(baseline, for: account)
        let cooldown = ClaudeCooldown(archive: UsageArchive(defaults: defaults), persistedUntil: {
            storage.loadState(for: account).checkCooldownUntil
        })
        let engine = QuotaEngine(storage: storage, backend: backend, claudeCooldown: cooldown,
                                 verificationDelay: 0, now: { clock })
        try work(storage, account, cooldown, backend, engine)
    }
}

@MainActor
final class QuotaPublicationRaceTests: XCTestCase {
    private actor DelayedProvider: UsageProvider {
        nonisolated let id = "codex"
        nonisolated let displayName = "Test"
        nonisolated let glyph = ProviderGlyph.openai
        var continuation: CheckedContinuation<ProviderSnapshot, Error>?
        let started: XCTestExpectation
        init(started: XCTestExpectation) { self.started = started }
        func fetchSnapshot() async throws -> ProviderSnapshot {
            try await withCheckedThrowingContinuation {
                continuation = $0
                started.fulfill()
            }
        }
        func finish(failing: Bool) {
            if failing { continuation?.resume(throwing: UsageProviderError.timedOut) }
            else {
                continuation?.resume(returning: ProviderSnapshot(id: id, displayName: displayName, glyph: glyph,
                    fidelity: .official, status: .ok,
                    windows: [LimitWindow(id: "primary", label: "5h", usedFraction: 0.1, duration: 18000)]))
            }
            continuation = nil
        }
    }

    func testOldGlobalDeadlineCannotDegradeANewerEngineReading() async throws {
        let name = "PublicationDeadline.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let started = expectation(description: "Background fetch started")
        let provider = DelayedProvider(started: started)
        var date = Date(timeIntervalSince1970: 1_800_000_000)
        let store = UsageStore(providers: [provider], refreshDeadline: 0.02,
                               archive: UsageArchive(defaults: defaults), pollingNow: { date })
        store.refreshNow()
        await fulfillment(of: [started], timeout: 2)
        let task = try XCTUnwrap(store.refresh(providerID: provider.id))
        let quota = RateLimitsSnapshot(observedAt: 1_800_000_000, buckets: [RateLimitBucket(limitId: "codex",
            primary: QuotaWindow(usedPercent: 40, windowDurationMins: 300,
                                 resetsAt: 1_800_018_000, observedAt: 1_800_000_000))])
        store.publishQuotaSnapshot(providerID: provider.id, quota: quota)
        date = date.addingTimeInterval(120)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(store.isRefreshingForTesting)
        XCTAssertEqual(store.snapshots.first?.status, .ok)
        XCTAssertEqual(store.snapshots.first?.headlineText, "60%")
        await provider.finish(failing: false)
        await task.value
    }

    func testOlderBackgroundSuccessOrFailureCannotReplaceEngineReading() async throws {
        for failing in [false, true] {
            let name = "PublicationRace.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: name)!
            defer { defaults.removePersistentDomain(forName: name) }
            let archive = UsageArchive(defaults: defaults)
            let started = expectation(description: "Background fetch started")
            let provider = DelayedProvider(started: started)
            let store = UsageStore(providers: [provider], archive: archive)
            let task = try XCTUnwrap(store.refresh(providerID: provider.id))
            await fulfillment(of: [started], timeout: 2)
            let clock: Int64 = 1_800_000_000
            let quota = RateLimitsSnapshot(observedAt: clock, buckets: [RateLimitBucket(limitId: "codex",
                primary: QuotaWindow(usedPercent: 40, windowDurationMins: 300,
                                     resetsAt: clock + 18000, observedAt: clock))])
            store.publishQuotaSnapshot(providerID: provider.id, quota: quota)
            await provider.finish(failing: failing)
            await task.value
            XCTAssertEqual(store.snapshots.first?.headlineText, "60%")
            XCTAssertEqual(store.snapshots.first?.status, .ok)
            XCTAssertEqual(archive.load()[provider.id]?.snapshot.headlineText, "60%")
            XCTAssertFalse(store.refreshing.contains(provider.id))
        }
    }
}

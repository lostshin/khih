import XCTest
@testable import Codenotch

final class AntigravityEngineTests: XCTestCase {
    private let clock: Int64 = 1_800_000_000
    private var storage: QuotaStorage!
    private var account: QuotaAccountConfig!
    private var backend: Backend!

    private final class Backend: QuotaBackend {
        var snapshot = RateLimitsSnapshot()
        var targets: [PokeTarget] = []
        var failGemini = false
        var onRead: (() -> Void)?
        func accountFingerprint(for account: QuotaAccountConfig) -> String? { XCTFail("Antigravity must not inspect identity"); return nil }
        func readRateLimits(for account: QuotaAccountConfig, observedAt: Int64) throws -> RateLimitsSnapshot {
            onRead?()
            return snapshot
        }
        func poke(for account: QuotaAccountConfig, target: PokeTarget,
                  expectedFingerprint: String?) throws -> QuotaPokeResult {
            targets.append(target)
            XCTAssertNil(expectedFingerprint)
            guard case .antigravityGroup(let group, _) = target else { throw AntigravityUsage.Failure.invalidUsage }
            if failGemini && group == .gemini { throw AntigravityUsage.Failure.invalidUsage }
            return .init(model: group.model, response: "OK", accountFingerprint: nil)
        }
    }

    override func setUpWithError() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        storage = QuotaStorage(baseDir: directory)
        account = QuotaAccountConfig(id: "test-account", label: "Test", provider: .antigravity,
                                     codexHome: directory.appendingPathComponent("home").path,
                                     stateDir: directory.appendingPathComponent("state").path)
        backend = Backend()
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    }

    private func snapshot(at: Int64, used: Double = 0, expired: Bool = false) -> RateLimitsSnapshot {
        .init(observedAt: at, buckets: AntigravityGroup.allCases.map { group in
            .init(limitId: group.limitID,
                  primary: .init(usedPercent: used, windowDurationMins: 300,
                                 resetsAt: at + 18000, observedAt: at),
                  secondary: .init(usedPercent: used, windowDurationMins: 10080,
                                   resetsAt: expired ? clock - 10 : at + 604800, observedAt: at))
        })
    }
    private func engine() -> QuotaEngine {
        .init(storage: storage, backend: backend, verificationDelay: 0, now: { self.clock })
    }
    private func seed(_ snapshot: RateLimitsSnapshot) throws {
        try storage.saveState(AccountState(snapshot: snapshot), for: account)
    }

    func testFirstObservationNeverPokesEitherGroup() throws {
        backend.snapshot = snapshot(at: clock)
        XCTAssertEqual(try engine().checkAccount(account: account, mode: .manual),
                       .groups(AntigravityGroup.allCases.map { .init(group: $0, outcome: .baseline) }))
        XCTAssertTrue(backend.targets.isEmpty)
        XCTAssertEqual(storage.loadState(for: account).antigravityGroups.count, 2)
    }

    func testWeeklyOrderSingleAttemptAndDurableStateBeforeVerification() throws {
        try seed(snapshot(at: clock - 30, used: 50, expired: true))
        backend.snapshot = snapshot(at: clock)
        backend.onRead = {
            for target in self.backend.targets {
                guard case .antigravityGroup(let group, _) = target else { continue }
                let saved = self.storage.loadState(for: self.account).antigravityGroups[group.rawValue]
                XCTAssertEqual(saved?.weeklyKeeper.lastPoke?.status, .unverified)
                XCTAssertEqual(saved?.weeklyKeeper.lastPoke?.attempt, 1)
                XCTAssertNotNil(saved?.weeklyKeeper.lastHandledResetKey)
            }
        }
        _ = try engine().checkAccount(account: account, mode: .live)
        XCTAssertEqual(backend.targets, [.antigravityGroup(.gemini, weekly: true), .antigravityGroup(.claudeGPT, weekly: true)])
        backend.onRead = nil
        _ = try engine().checkAccount(account: account, mode: .live)
        XCTAssertEqual(backend.targets.count, 2, "persisted reset keys must prevent a resend after restart")
        XCTAssertNil(storage.loadState(for: account).weeklyKeeper.lastPoke)
    }

    func testOneGroupFailureDoesNotBlockTheOtherOrSaveFailedResetKey() throws {
        try seed(snapshot(at: clock - 30, used: 50, expired: true))
        backend.snapshot = snapshot(at: clock)
        backend.failGemini = true
        guard case .groups(let outcomes) = try engine().checkAccount(account: account, mode: .live) else { return XCTFail() }
        XCTAssertEqual(backend.targets.count, 2)
        guard case .failed = outcomes[0].outcome else { return XCTFail() }
        XCTAssertEqual(outcomes[1].outcome, .poked(.unverified))
        let saved = storage.loadState(for: account)
        XCTAssertNil(saved.antigravityGroups["gemini"]?.weeklyKeeper.lastHandledResetKey)
        XCTAssertNotNil(saved.antigravityGroups["claude_gpt"]?.weeklyKeeper.lastHandledResetKey)
    }

    func testFiveHourOrderNoFingerprintNoRetryAndPersistBeforeVerify() throws {
        try seed(snapshot(at: clock - 30))
        backend.snapshot = snapshot(at: clock)
        backend.onRead = {
            for target in self.backend.targets {
                guard case .antigravityGroup(let group, _) = target else { continue }
                XCTAssertEqual(self.storage.loadState(for: self.account).antigravityGroups[group.rawValue]?.fiveHourStarter.lastPoke?.status, .unverified)
            }
        }
        _ = try engine().startFiveHour(account: account, trigger: .manual)
        XCTAssertEqual(backend.targets, [.antigravityGroup(.gemini, weekly: false), .antigravityGroup(.claudeGPT, weekly: false)])
    }

    func testActiveFiveHourGroupIsSkippedIndependently() throws {
        try seed(snapshot(at: clock - 30))
        backend.snapshot = snapshot(at: clock)
        backend.snapshot.buckets[0].primary?.usedPercent = 5
        guard case .groups(let results) = try engine().startFiveHour(account: account, trigger: .manual) else { return XCTFail() }
        XCTAssertEqual(results[0].outcome, .refused(.alreadyRunning))
        XCTAssertEqual(backend.targets, [.antigravityGroup(.claudeGPT, weekly: false)])
    }

    func testMissingDuplicateUnknownAndNoBaselineNeverSpend() throws {
        backend.snapshot = snapshot(at: clock)
        _ = try engine().startFiveHour(account: account, trigger: .scheduled)
        XCTAssertTrue(backend.targets.isEmpty)
        for invalid in 0..<3 {
            try seed(snapshot(at: clock - 30))
            backend.snapshot = snapshot(at: clock)
            for index in 0..<2 {
                if invalid == 0 { backend.snapshot.buckets[index].primary = nil }
                if invalid == 1 { backend.snapshot.buckets[index].primary?.usedPercent = nil }
            }
            if invalid == 2 { backend.snapshot.buckets += backend.snapshot.buckets }
            _ = try engine().startFiveHour(account: account, trigger: .manual)
            XCTAssertTrue(backend.targets.isEmpty)
        }
    }

    func testFixedApprovedModelsPromptAndFlags() {
        XCTAssertEqual(AntigravityGroup.allCases.map(\.model), ["gemini-3.8-flash-low", "claude-sonnet-4-6"])
        for group in AntigravityGroup.allCases {
            XCTAssertEqual(AntigravityClient.pokeArguments(group), ["-p", "Reply with exactly: OK. Do not use tools.", "--model", group.model, "--effort", "low", "--mode", "plan", "--sandbox", "--disable-slash-commands", "--output-format", "json", "--print-timeout", "120s"])
        }
    }
}

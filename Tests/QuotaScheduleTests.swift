import XCTest
@testable import Khih

@MainActor
final class QuotaScheduleTests: XCTestCase {
    private let a = "account-a", b = "account-b"

    func testNotDueBusyExactlyOneHourAndExpired() {
        var writes: [QuotaSettings] = []
        let schedule = QuotaSchedule(settings: .init(fiveHourStartAt: [a: 100]),
                                     save: { writes.append($0) })
        XCTAssertTrue(schedule.takeDue(now: 99, busy: false, targets: [a]).isEmpty)
        XCTAssertTrue(schedule.takeDue(now: 100, busy: true, targets: [a]).isEmpty)
        XCTAssertTrue(writes.isEmpty)
        XCTAssertEqual(schedule.takeDue(now: 3700, busy: false, targets: [a]).fired, [a])
        XCTAssertEqual(writes.last?.fiveHourStartAt, [:])
        XCTAssertEqual(writes.last?.version, 1)
        XCTAssertTrue(schedule.takeDue(now: 3700, busy: false, targets: [a]).isEmpty)

        XCTAssertNil(schedule.set(100, for: [a], now: 99))
        let late = schedule.takeDue(now: 3701, busy: true, targets: [a])
        XCTAssertEqual(late.expired, [a])
        XCTAssertTrue(late.fired.isEmpty)
        XCTAssertNil(schedule.appointment(for: a))
    }

    /// Separate appointments stay separate: one coming due says nothing about
    /// the others, and only the account that ran out of time is dropped.
    func testOnlyTheDueAccountFiresAndOnlyTheLateOneExpires() {
        var writes: [QuotaSettings] = []
        let schedule = QuotaSchedule(settings: .init(fiveHourStartAt: [a: 100, b: 9_000]),
                                     save: { writes.append($0) })
        let due = schedule.takeDue(now: 100, busy: false, targets: [a, b])
        XCTAssertEqual(due.fired, [a])
        XCTAssertTrue(due.expired.isEmpty)
        XCTAssertNil(schedule.appointment(for: a))
        XCTAssertEqual(schedule.appointment(for: b), 9_000)
        XCTAssertEqual(writes.count, 1)

        // Late and on time in the same pass: one is cancelled, one is started,
        // and a single write covers both.
        XCTAssertNil(schedule.set(20_000, for: [a], now: 100))
        let mixed = schedule.takeDue(now: 20_000, busy: false, targets: [a, b])
        XCTAssertEqual(mixed.fired, [a])
        XCTAssertEqual(mixed.expired, [b])
        XCTAssertEqual(schedule.appointments, [:])
    }

    /// An appointment for an account that is switched off — or gone — never
    /// fires, but still expires, which is what eventually clears its key.
    func testAppointmentOutsideTheTargetsWaitsThenExpires() {
        let schedule = QuotaSchedule(settings: .init(fiveHourStartAt: [a: 100]), save: { _ in })
        XCTAssertTrue(schedule.takeDue(now: 100, busy: false, targets: [b]).isEmpty)
        XCTAssertEqual(schedule.appointment(for: a), 100)
        XCTAssertEqual(schedule.takeDue(now: 3_701, busy: false, targets: [b]).expired, [a])
        XCTAssertNil(schedule.appointment(for: a))
    }

    /// A time already gone is refused rather than stored: the one-second tick
    /// would clear it before the row could show it, which is what a button
    /// that "does nothing" looks like from outside.
    func testPastAppointmentIsRefusedWithoutWritingAndLeavesAnyExistingOneAlone() {
        var writes: [QuotaSettings] = []
        let schedule = QuotaSchedule(settings: .init(fiveHourStartAt: [a: 500]),
                                     save: { writes.append($0) })
        XCTAssertNotNil(schedule.set(100, for: [a], now: 100))
        XCTAssertNotNil(schedule.set(99, for: [a], now: 100))
        XCTAssertTrue(writes.isEmpty)
        XCTAssertEqual(schedule.appointment(for: a), 500)
        // Clearing is never refused, however late it is.
        XCTAssertNil(schedule.set(nil, for: [a]))
        XCTAssertNil(schedule.set(101, for: [a], now: 100))
    }

    /// One press, one write: "apply to all" cannot leave half the accounts
    /// scheduled.
    func testApplyToAllWritesEveryAccountOnce() {
        var writes: [QuotaSettings] = []
        let schedule = QuotaSchedule(settings: .init(), save: { writes.append($0) })
        XCTAssertNil(schedule.set(500, for: [a, b], now: 100))
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(schedule.appointments, [a: 500, b: 500])
        XCTAssertNil(schedule.set(nil, for: [a, b]))
        XCTAssertEqual(schedule.appointments, [:])
        XCTAssertNotNil(schedule.set(500, for: [], now: 100))
    }

    func testFailedClearPreservesAppointmentAndCannotFire() {
        let schedule = QuotaSchedule(settings: .init(fiveHourStartAt: [a: 100]),
                                     save: { _ in throw CocoaError(.fileWriteNoPermission) })
        let due = schedule.takeDue(now: 100, busy: false, targets: [a])
        XCTAssertTrue(due.saveFailed)
        XCTAssertTrue(due.fired.isEmpty)
        XCTAssertEqual(schedule.appointment(for: a), 100)
        XCTAssertNotNil(schedule.set(nil, for: [a]))
        XCTAssertTrue(schedule.takeDue(now: 3701, busy: false, targets: [a]).saveFailed)
        XCTAssertEqual(schedule.appointment(for: a), 100)
    }

    func testRestartCancellationAndSemanticRustSettingsRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = QuotaStorage(baseDir: root)
        let schedule = QuotaSchedule(settings: .init(), save: storage.saveSettings)
        XCTAssertNil(schedule.set(200, for: [a], now: 199))
        let restarted = QuotaSchedule(settings: storage.loadSettings(), save: storage.saveSettings)
        XCTAssertEqual(restarted.settings, .init(version: 1, fiveHourStartAt: [a: 200]))
        XCTAssertNil(restarted.set(nil, for: [a]))
        XCTAssertEqual(storage.loadSettings(), .init(version: 1))
        // Nothing scheduled writes no key, so the file Rust reads is the one it
        // has always read.
        XCTAssertEqual(try String(contentsOf: storage.settingsPath, encoding: .utf8)
            .contains("fiveHourStartAt"), false)
        let rustShape = try JSONDecoder().decode(
            QuotaSettings.self, from: Data(#"{"version":1,"fiveHourStartAt":null}"#.utf8))
        XCTAssertEqual(rustShape, storage.loadSettings())
    }

    private final class Backend: QuotaBackend {
        var reads = 0
        var didRead: () -> Void = {}
        func accountFingerprint(for account: QuotaAccountConfig) -> String? { "test" }
        func readRateLimits(for account: QuotaAccountConfig, observedAt: Int64) throws -> RateLimitsSnapshot {
            reads += 1
            didRead()
            return RateLimitsSnapshot(observedAt: observedAt)
        }
        func poke(for account: QuotaAccountConfig, target: PokeTarget, expectedFingerprint: String?) throws -> QuotaPokeResult {
            XCTFail("no baseline: must refuse")
            throw CocoaError(.featureUnsupported)
        }
    }

    func testControllerClearsBeforeReadingAndRecordsScheduledRefusalForEveryEnabledAccount() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = QuotaStorage(baseDir: root)
        let a = try storage.createAccount(label: "A", provider: .codex)
        let b = try storage.createAccount(label: "B", provider: .codex)
        try storage.saveSettings(.init(fiveHourStartAt: [a.id: 100, b.id: 100]))
        let backend = Backend()
        backend.didRead = { XCTAssertNil(storage.loadSettings().fiveHourStartAt[a.id]) }
        let controller = QuotaController(storage: storage, engine: QuotaEngine(storage: storage, backend: backend))
        var reports: [FiveHourResult] = []
        controller.onScheduledResult = { _, _, result in reports.append(result) }
        await controller.runScheduleTick(now: 99)
        XCTAssertEqual(backend.reads, 0)
        await controller.runScheduleTick(now: 100)
        XCTAssertEqual(backend.reads, 2)
        XCTAssertEqual(reports, [.refused(.noBaseline), .refused(.noBaseline)])
        for account in [a, b] {
            XCTAssertTrue(storage.recentActivity(for: account, limit: 20).joined().contains("預約觸發"))
        }
        await controller.runScheduleTick(now: 101)
        XCTAssertEqual(backend.reads, 2)
    }

    /// One account's appointment must not start the others.
    func testControllerStartsOnlyTheAccountWhoseAppointmentCameDue() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = QuotaStorage(baseDir: root)
        let a = try storage.createAccount(label: "A", provider: .codex)
        let b = try storage.createAccount(label: "B", provider: .codex)
        try storage.saveSettings(.init(fiveHourStartAt: [a.id: 100, b.id: 9_000]))
        let backend = Backend()
        let controller = QuotaController(storage: storage, engine: QuotaEngine(storage: storage, backend: backend))
        await controller.runScheduleTick(now: 100)
        XCTAssertEqual(backend.reads, 1)
        XCTAssertTrue(storage.recentActivity(for: a, limit: 20).joined().contains("預約觸發"))
        XCTAssertFalse(storage.recentActivity(for: b, limit: 20).joined().contains("預約觸發"))
        XCTAssertEqual(storage.loadSettings().fiveHourStartAt, [b.id: 9_000])
    }

    /// Only the account whose appointment ran out hears about it. It used to be
    /// written into every enabled account's record.
    func testExpiredAppointmentIsRecordedOnlyForItsOwnAccount() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = QuotaStorage(baseDir: root)
        let a = try storage.createAccount(label: "A", provider: .codex)
        let b = try storage.createAccount(label: "B", provider: .codex)
        try storage.saveSettings(.init(fiveHourStartAt: [a.id: 100]))
        let backend = Backend()
        let controller = QuotaController(storage: storage, engine: QuotaEngine(storage: storage, backend: backend))
        await controller.runScheduleTick(now: 3_701)
        XCTAssertEqual(backend.reads, 0)
        XCTAssertTrue(storage.recentActivity(for: a, limit: 20).joined().contains("預約已超過一小時"))
        XCTAssertTrue(storage.recentActivity(for: b, limit: 20).isEmpty)
        XCTAssertEqual(storage.loadSettings().fiveHourStartAt, [:])
    }
}

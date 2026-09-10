import XCTest
@testable import Codenotch

@MainActor
final class QuotaScheduleTests: XCTestCase {
    func testNotDueBusyExactlyOneHourAndExpired() {
        var writes: [QuotaSettings] = []
        let schedule = QuotaSchedule(settings: .init(fiveHourStartAt: 100), save: { writes.append($0) })
        XCTAssertEqual(schedule.takeDue(now: 99, busy: false), .waiting)
        XCTAssertEqual(schedule.takeDue(now: 100, busy: true), .waiting)
        XCTAssertTrue(writes.isEmpty)
        XCTAssertEqual(schedule.takeDue(now: 3700, busy: false), .fire)
        XCTAssertNil(writes.last?.fiveHourStartAt)
        XCTAssertEqual(writes.last?.version, 1)
        XCTAssertEqual(schedule.takeDue(now: 3700, busy: false), .waiting)
        schedule.set(100)
        XCTAssertEqual(schedule.takeDue(now: 3701, busy: true), .expired)
        XCTAssertNil(schedule.settings.fiveHourStartAt)
    }

    func testFailedClearPreservesAppointmentAndCannotFire() {
        let schedule = QuotaSchedule(settings: .init(fiveHourStartAt: 100), save: { _ in throw CocoaError(.fileWriteNoPermission) })
        XCTAssertEqual(schedule.takeDue(now: 100, busy: false), .failed)
        XCTAssertEqual(schedule.settings.fiveHourStartAt, 100)
        XCTAssertNotNil(schedule.error)
        XCTAssertFalse(schedule.set(nil))
        XCTAssertEqual(schedule.takeDue(now: 3701, busy: false), .failed)
        XCTAssertEqual(schedule.settings.fiveHourStartAt, 100)
    }

    func testRestartCancellationAndSemanticRustSettingsRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = QuotaStorage(baseDir: root)
        let schedule = QuotaSchedule(settings: .init(), save: storage.saveSettings)
        XCTAssertTrue(schedule.set(200))
        let restarted = QuotaSchedule(settings: storage.loadSettings(), save: storage.saveSettings)
        XCTAssertEqual(restarted.settings, .init(version: 1, fiveHourStartAt: 200))
        XCTAssertTrue(restarted.set(nil))
        XCTAssertEqual(storage.loadSettings(), .init(version: 1))
        let rustNull = try JSONDecoder().decode(QuotaSettings.self, from: Data(#"{"version":1,"fiveHourStartAt":null}"#.utf8))
        XCTAssertEqual(rustNull, storage.loadSettings())
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
        try storage.saveSettings(.init(fiveHourStartAt: 100))
        let backend = Backend()
        backend.didRead = { XCTAssertNil(storage.loadSettings().fiveHourStartAt) }
        let controller = QuotaController(storage: storage, engine: QuotaEngine(storage: storage, backend: backend))
        var reports: [FiveHourResult] = []
        controller.onScheduledResult = { _, _, result in reports.append(result) }
        await controller.runScheduleTick(now: 99)
        XCTAssertEqual(backend.reads, 0)
        await controller.runScheduleTick(now: 100)
        XCTAssertEqual(backend.reads, 2)
        XCTAssertEqual(reports, [.refused(.noBaseline), .refused(.noBaseline)])
        for account in [a,b] {
            XCTAssertTrue(storage.recentActivity(for: account, limit: 20).joined().contains("預約觸發"))
        }
        await controller.runScheduleTick(now: 101)
        XCTAssertEqual(backend.reads, 2)
    }
}

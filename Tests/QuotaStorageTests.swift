import XCTest
@testable import Codenotch

/// Storage is where the safety invariants meet the disk. Every test here runs
/// against a temporary directory — none of them may touch the real
/// `~/Library/Application Support/codex-quota-keeper`, which holds live quota
/// state for accounts in use.
final class QuotaStorageTests: XCTestCase {
    private var root: URL!
    private var storage: QuotaStorage!
    private var account: QuotaAccountConfig!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("QuotaStorageTests.\(UUID().uuidString)")
        storage = QuotaStorage(baseDir: root)
        let stateDir = root.appendingPathComponent("accounts/account-test/monitor")
        account = QuotaAccountConfig(id: "account-test", label: "Test",
                                     codexHome: root.appendingPathComponent("codex-home").path,
                                     stateDir: stateDir.path)
        try QuotaStorage.privateDirectory(stateDir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    // MARK: - State

    func testAnAbsentStateFileReadsAsAnEmptyBaseline() {
        let state = storage.loadState(for: account)
        XCTAssertNil(state.snapshot)
        XCTAssertNil(state.accountFingerprint)
        XCTAssertNil(state.weeklyKeeper.lastHandledResetKey)
        XCTAssertEqual(state.version, 2)
    }

    func testStateSurvivesASaveAndLoad() throws {
        var state = AccountState(accountFingerprint: "abc123def456")
        state.snapshot = RateLimitsSnapshot(
            observedAt: 1_786_070_000,
            buckets: [RateLimitBucket(limitId: "codex",
                                      primary: QuotaWindow(usedPercent: 12.5, windowDurationMins: 300,
                                                           resetsAt: 1_786_088_000, observedAt: 1_786_070_000),
                                      secondary: QuotaWindow(usedPercent: 34, windowDurationMins: 10_080,
                                                             resetsAt: 1_786_600_000, observedAt: 1_786_070_000,
                                                             countdownActive: true))])
        state.weeklyKeeper.lastHandledResetKey = "scheduled:1786000000"
        try storage.saveState(state, for: account)

        XCTAssertEqual(storage.loadState(for: account), state)
    }

    /// A v1 file is rebuilt as an empty baseline rather than migrated. Carrying
    /// a `lastHandledResetKey` forward out of a schema we no longer understand
    /// is how the same reset gets poked twice.
    func testAVersionOneStateFileIsRebuiltAsABaseline() throws {
        let v1 = #"{"version":1,"snapshot":{"observedAt":1,"buckets":[]},"weeklyKeeper":{"lastHandledResetKey":"scheduled:1"}}"#
        try Data(v1.utf8).write(to: QuotaStorage.statePath(for: account))

        let state = storage.loadState(for: account)
        XCTAssertEqual(state.version, 2)
        XCTAssertNil(state.snapshot)
        XCTAssertNil(state.weeklyKeeper.lastHandledResetKey)
    }

    func testACorruptStateFileIsRebuiltAsABaseline() throws {
        try Data("{ not json".utf8).write(to: QuotaStorage.statePath(for: account))
        XCTAssertNil(storage.loadState(for: account).snapshot)
    }

    /// The first save has no original to replace — an easy path to get wrong,
    /// and it is the one every new account takes.
    func testTheFirstSaveCreatesTheFile() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: QuotaStorage.statePath(for: account).path))
        try storage.saveState(AccountState(accountFingerprint: "first"), for: account)
        XCTAssertEqual(storage.loadState(for: account).accountFingerprint, "first")
    }

    func testStateIsWrittenOwnerOnly() throws {
        try storage.saveState(AccountState(), for: account)
        let attributes = try FileManager.default
            .attributesOfItem(atPath: QuotaStorage.statePath(for: account).path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
    }

    // MARK: - Accounts

    func testAccountsParseWithProviderAndEnabledDefaults() throws {
        let json = """
        {"version":1,"accounts":[
          {"id":"account-a","label":"A","codexHome":"/tmp/a","stateDir":"/tmp/a/m"},
          {"id":"account-b","label":"B","provider":"claude","codexHome":"/tmp/b","stateDir":"/tmp/b/m","enabled":false},
          {"id":"account-c","label":"C","provider":"google-antigravity","codexHome":"/tmp/c","stateDir":"/tmp/c/m","enabled":true}]}
        """
        try QuotaStorage.privateDirectory(root)
        try Data(json.utf8).write(to: storage.accountsPath)

        let file = storage.loadAccounts()
        XCTAssertEqual(file.accounts.count, 3)
        // A file predating the field describes Codex accounts, and an account
        // with no `enabled` is on.
        XCTAssertEqual(file.accounts[0].provider, .codex)
        XCTAssertTrue(file.accounts[0].enabled)
        XCTAssertEqual(file.accounts[1].provider, .claude)
        XCTAssertFalse(file.accounts[1].enabled)
        XCTAssertEqual(file.accounts[2].provider, .antigravity)
    }

    func testAnAbsentAccountsFileIsEmptyRatherThanAnError() {
        XCTAssertTrue(storage.loadAccounts().accounts.isEmpty)
    }

    // MARK: - Settings

    func testSettingsRoundTripAndClearTheSchedule() throws {
        try storage.saveSettings(QuotaSettings(version: 1, fiveHourStartAt: 1_786_000_000))
        XCTAssertEqual(storage.loadSettings().fiveHourStartAt, 1_786_000_000)

        try storage.saveSettings(QuotaSettings(version: 1, fiveHourStartAt: nil))
        XCTAssertNil(storage.loadSettings().fiveHourStartAt)
    }

    // MARK: - Activity log

    func testActivityAppendsAndReadsBackTheTail() throws {
        for index in 1...5 {
            try storage.appendActivity("第 \(index) 行", for: account)
        }
        XCTAssertEqual(storage.recentActivity(for: account, limit: 3),
                       ["第 3 行", "第 4 行", "第 5 行"])
        XCTAssertEqual(storage.recentActivity(for: account, limit: 99).count, 5)
    }

    func testActivityIsAppendedNotOverwritten() throws {
        try storage.appendActivity("一", for: account)
        try storage.appendActivity("二", for: account)
        XCTAssertEqual(storage.recentActivity(for: account, limit: 10), ["一", "二"])
    }

    func testActivityForAnAccountThatHasNeverRunIsEmpty() {
        XCTAssertEqual(storage.recentActivity(for: account, limit: 10), [])
    }

    func testActivityTimestampIsTaipeiTime() {
        let stamp = QuotaStorage.activityTimestamp(Date(timeIntervalSince1970: 1_786_070_000))
        XCTAssertTrue(stamp.hasSuffix("+08:00"), stamp)
    }

    // MARK: - Check lock

    func testTheLockIsExclusiveWhileHeldAndFreedWhenReleased() throws {
        var first: CheckLock? = try storage.acquireCheckLock(for: account)
        XCTAssertNotNil(first)
        // A second caller must skip rather than wait — three code paths
        // compete for one account's state file.
        XCTAssertNil(try storage.acquireCheckLock(for: account))

        first = nil
        XCTAssertNotNil(try storage.acquireCheckLock(for: account))
    }

    /// A lock left behind by a process that died must not block the account
    /// forever, but a fresh one must be respected.
    func testAStaleLockIsBrokenAndAFreshOneIsNot() throws {
        var held: CheckLock? = try storage.acquireCheckLock(for: account)
        XCTAssertNotNil(held)
        withExtendedLifetime(held) {}

        let path = QuotaStorage.checkLockPath(for: account)
        let old = Date().addingTimeInterval(-700)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: path.path)

        // Still inside the stale window as far as this call is concerned.
        XCTAssertNil(try storage.acquireCheckLock(for: account, staleAfter: 1_200))
        // Past it: the lock is broken and taken over.
        XCTAssertNotNil(try storage.acquireCheckLock(for: account, staleAfter: 600))
        held = nil
    }
}

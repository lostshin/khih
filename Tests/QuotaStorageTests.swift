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

    func testActivityTailHandlesChunkBoundariesBlankLinesAndNoFinalNewline() throws {
        let longLine = String(repeating: "測試🙂", count: 1600)
        let lines = [String(repeating: "old\n", count: 10000), longLine, "", "最後一行"]
        for ending in ["", "\n"] {
            try Data((lines.joined(separator: "\n") + ending).utf8)
                .write(to: QuotaStorage.activityPath(for: account))
            XCTAssertEqual(storage.recentActivity(for: account, limit: 3), [longLine, "", "最後一行"])
            XCTAssertEqual(storage.recentActivity(for: account, limit: 0), [])
            XCTAssertEqual(storage.recentActivity(for: account, limit: -1), [])
        }
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

    func testConcurrentStaleLockRecoveryHasOneWinner() throws {
        let path = QuotaStorage.checkLockPath(for: account)
        XCTAssertTrue(FileManager.default.createFile(atPath: path.path, contents: Data(),
                                                      attributes: [.posixPermissions: 0o600]))
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-700)], ofItemAtPath: path.path)

        let start = DispatchSemaphore(value: 0)
        let finished = DispatchGroup()
        let resultsLock = NSLock()
        var winners: [CheckLock] = []
        for _ in 0..<16 {
            finished.enter()
            DispatchQueue.global().async {
                start.wait()
                if let lock = try? self.storage.acquireCheckLock(for: self.account) {
                    resultsLock.lock()
                    winners.append(lock)
                    resultsLock.unlock()
                }
                finished.leave()
            }
        }
        for _ in 0..<16 { start.signal() }
        XCTAssertEqual(finished.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(winners.count, 1)
        withExtendedLifetime(winners) {}
    }

    // MARK: - Abandoning a sign-in

    func testAnUnfinishedSignInIsTakenBackWithItsDirectory() throws {
        let created = try storage.createAccount(label: "Second", provider: .codex)
        XCTAssertTrue(FileManager.default.fileExists(atPath: created.codexHome))

        try storage.discardUnfinishedAccount(created)

        XCTAssertFalse(storage.loadAccounts().accounts.contains { $0.id == created.id })
        XCTAssertFalse(FileManager.default.fileExists(atPath: created.codexHome))
    }

    func testFailedAccountListSaveDoesNotDeleteTheAccountDirectory() throws {
        let created = try storage.createAccount(label: "Second", provider: .codex)
        let blockedTemporary = storage.accountsPath.appendingPathExtension("tmp")
        try FileManager.default.createDirectory(at: blockedTemporary,
                                                withIntermediateDirectories: false)

        XCTAssertThrowsError(try storage.discardUnfinishedAccount(created))
        XCTAssertTrue(FileManager.default.fileExists(atPath: created.codexHome))
        XCTAssertTrue(storage.loadAccounts().accounts.contains { $0.id == created.id })
    }

    func testAnAccountThatSignedInIsNeverTakenBack() throws {
        let created = try storage.createAccount(label: "Second", provider: .codex)
        // The one thing that distinguishes a finished sign-in from an
        // abandoned one.
        try Data("{}".utf8).write(
            to: created.codexHomeURL.appendingPathComponent("auth.json"))

        try storage.discardUnfinishedAccount(created)

        XCTAssertTrue(storage.loadAccounts().accounts.contains { $0.id == created.id })
        XCTAssertTrue(FileManager.default.fileExists(atPath: created.codexHome))
    }

    /// The delete is derived from the account id, not from the stored path, so
    /// a doctored `accounts.json` cannot aim it somewhere else.
    func testADirectoryOutsideTheConventionIsLeftAlone() throws {
        let elsewhere = root.appendingPathComponent("not-an-account")
        try QuotaStorage.privateDirectory(elsewhere)
        var file = storage.loadAccounts()
        let planted = QuotaAccountConfig(id: "account-planted", label: "Planted",
                                         codexHome: elsewhere.path,
                                         stateDir: elsewhere.path)
        file.accounts.append(planted)
        try storage.saveAccounts(file)

        try storage.discardUnfinishedAccount(planted)

        XCTAssertTrue(FileManager.default.fileExists(atPath: elsewhere.path))
        XCTAssertTrue(storage.loadAccounts().accounts.contains { $0.id == planted.id })
    }

    // MARK: - A second sign-in to the same account

    private func signIn(_ account: QuotaAccountConfig, accountID: String) throws {
        try Data(#"{"tokens":{"account_id":"\#(accountID)"}}"#.utf8)
            .write(to: account.codexHomeURL.appendingPathComponent("auth.json"))
    }

    func testASecondSignInToTheSameChatGPTAccountIsFound() throws {
        let first = try storage.createAccount(label: "First", provider: .codex)
        let second = try storage.createAccount(label: "Second", provider: .codex)
        try signIn(first, accountID: "acct-1")
        try signIn(second, accountID: "acct-1")

        XCTAssertEqual(storage.codexAccount(sharingFingerprintWith: second)?.id, first.id)
    }

    func testADifferentChatGPTAccountIsNotAMatch() throws {
        let first = try storage.createAccount(label: "First", provider: .codex)
        let second = try storage.createAccount(label: "Second", provider: .codex)
        try signIn(first, accountID: "acct-1")
        try signIn(second, accountID: "acct-2")

        XCTAssertNil(storage.codexAccount(sharingFingerprintWith: second))
    }

    func testTheDuplicateIsDiscardedWithItsCredential() throws {
        let first = try storage.createAccount(label: "First", provider: .codex)
        let second = try storage.createAccount(label: "Second", provider: .codex)
        try signIn(first, accountID: "acct-1")
        try signIn(second, accountID: "acct-1")

        try storage.discardDuplicateAccount(second, matching: first)

        XCTAssertFalse(storage.loadAccounts().accounts.contains { $0.id == second.id })
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.codexHome))
        // The one that was already there is untouched.
        XCTAssertTrue(storage.loadAccounts().accounts.contains { $0.id == first.id })
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.codexHome))
    }

    /// The caller saying "duplicate" is not enough to delete a credential.
    func testTwoDifferentAccountsAreNeverDiscardedAsDuplicates() throws {
        let first = try storage.createAccount(label: "First", provider: .codex)
        let second = try storage.createAccount(label: "Second", provider: .codex)
        try signIn(first, accountID: "acct-1")
        try signIn(second, accountID: "acct-2")

        try storage.discardDuplicateAccount(second, matching: first)

        XCTAssertTrue(storage.loadAccounts().accounts.contains { $0.id == second.id })
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.codexHome))
    }
}

extension QuotaStorageTests {
    func testLongTransactionKeepsItsLockFresh() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("check.lock")
        let descriptor = open(path.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        let lock = CheckLock(path: path, descriptor: descriptor, heartbeatInterval: 0.02)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: path.path)
        Thread.sleep(forTimeInterval: 0.1)
        let date = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: path.path)[.modificationDate] as? Date)
        XCTAssertLessThan(Date().timeIntervalSince(date), 1)
        withExtendedLifetime(lock) {}
    }
}

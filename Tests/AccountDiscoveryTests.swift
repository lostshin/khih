import XCTest
@testable import Codenotch

@MainActor
final class AccountDiscoveryTests: XCTestCase {
    private final class Provider: UsageProvider {
        let id: String
        let displayName = "Test"
        let glyph = ProviderGlyph.openai
        var calls = 0
        init(_ id: String) { self.id = id }
        func fetchSnapshot() async throws -> ProviderSnapshot {
            calls += 1
            return .init(id: id, displayName: displayName, glyph: glyph, fidelity: .official,
                         status: .ok, windows: [LimitWindow(id: "primary", label: "5h", usedFraction: 0.2)])
        }
    }

    func testAppendingProvidersPreservesInstancesReadingsAndOrder() async {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let existing = Provider("codex-a"), added = Provider("codex-b")
        let store = UsageStore(providers: [existing], archive: UsageArchive(defaults: defaults), order: ["codex-a"])
        await store.refresh()
        XCTAssertEqual(store.addProviders([Provider("codex-a"), added, Provider("codex-b")]), ["codex-b"])
        await store.refresh(providerID: "codex-b")?.value
        XCTAssertEqual(existing.calls, 1)
        XCTAssertEqual(added.calls, 1)
        XCTAssertEqual(store.snapshots.map(\.id), ["codex-a", "codex-b"])
        XCTAssertEqual(store.providerSummaries.count, 2)
        XCTAssertEqual(store.notchSnapshots.count, 1)
        XCTAssertEqual(store.notchSnapshots[0].windows.count, 2)
        store.stop()
    }

    private func setupLogin(completes: Bool = true, startDelay: Double = 0) throws -> (QuotaStorage, QuotaController, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("codex")
        let source = """
        #!/usr/bin/env python3
        import json,sys,os,time
        for line in sys.stdin:
            m=json.loads(line)
            if 'id' not in m: continue
            method=m.get('method')
            result={}
            if method=='account/login/start':
                time.sleep(\(startDelay))
                result={'loginId':'test','userCode':'TEST','verificationUrl':'https://example.test'}
            print(json.dumps({'id':m['id'],'result':result}),flush=True)
            if method=='account/login/start' and \(completes ? "True" : "False"):
                with open(os.path.join(os.environ['CODEX_HOME'],'auth.json'),'w') as f:
                    json.dump({'tokens':{'account_id':'anonymous-fixture'}},f)
                print(json.dumps({'method':'account/login/completed','params':{'loginId':'test'}}),flush=True)
        """
        try source.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let storage = QuotaStorage(baseDir: root.appendingPathComponent("store"))
        let quota = QuotaController(storage: storage, engine: nil)
        quota.resolveCodexBinary = { binary }
        return (storage, quota, root)
    }

    func testFakeLoginPublishesNewAccountOnceAndDuplicatePublishesNothing() async throws {
        let (storage, quota, root) = try setupLogin()
        let store = UsageStore(providers: [], archive: UsageArchive(defaults: UserDefaults(suiteName: UUID().uuidString)!))
        var discoveries = 0
        quota.onAccountsChanged = {
            discoveries += 1
            let profiles = CodexProfile.discoverManaged(storage: storage)
            _ = store.addProviders(profiles.map { Provider($0.id) })
        }
        await quota.beginAddCodexAccount(label: "Fixture")
        XCTAssertEqual(quota.addAccountState, .added(label: "Fixture"))
        XCTAssertEqual(discoveries, 1)
        XCTAssertEqual(store.providerSummaries.count, 1)
        XCTAssertEqual(CodexProfile.discoverAll(home: root, storage: storage).filter { $0.managedLabel != nil }.count, 1)
        await quota.beginAddCodexAccount(label: "Duplicate")
        XCTAssertEqual(discoveries, 1)
        XCTAssertEqual(storage.loadAccounts().accounts.count, 1)
        XCTAssertEqual(store.providerSummaries.count, 1)
        store.stop()
    }

    func testCancelDuringStartupWaitsForCleanupBeforeReopening() async throws {
        let (storage, quota, _) = try setupLogin(completes: false, startDelay: 0.15)
        let pending = Task { await quota.beginAddCodexAccount(label: "Startup") }
        while quota.addAccountState != .starting { await Task.yield() }
        await quota.cancelAddAccount()
        XCTAssertFalse(quota.isBusy)
        XCTAssertTrue(storage.loadAccounts().accounts.isEmpty)
        await pending.value
        XCTAssertEqual(quota.addAccountState, .idle)
        quota.loginWait = 0
        await quota.beginAddCodexAccount(label: "Reopened")
        XCTAssertTrue(storage.loadAccounts().accounts.isEmpty)
    }

    func testTimeoutAndCancellationRemoveUnfinishedAccount() async throws {
        let (storage, quota, _) = try setupLogin(completes: false)
        quota.loginWait = 0
        await quota.beginAddCodexAccount(label: "Timeout")
        XCTAssertTrue(storage.loadAccounts().accounts.isEmpty)
        quota.loginWait = 10
        let pending = Task { await quota.beginAddCodexAccount(label: "Cancel") }
        for _ in 0..<200 {
            if case .waiting = quota.addAccountState { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await quota.cancelAddAccount()
        await pending.value
        XCTAssertTrue(storage.loadAccounts().accounts.isEmpty)
        XCTAssertEqual(quota.addAccountState, .idle)
    }
}

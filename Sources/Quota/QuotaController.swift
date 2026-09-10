import Combine
import Foundation
import UserNotifications

/// Which providers are mid-turn right now.
///
/// Written on the main actor from the session monitors and read by the engine
/// on a background thread, so it carries its own lock rather than relying on
/// either side's isolation.
final class InUseFlags: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: Set<String> = []

    func update(_ ids: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        self.ids = ids
    }

    func contains(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return ids.contains(id)
    }
}

/// The side end of the weekly keeper.
///
/// The keeper runs unattended, so without a notification the only evidence it
/// ever ran is a log nobody opens. Announced on the same terms as a threshold
/// alert: permission asked on the first real event, never at launch.
enum QuotaAlerts {
    static func scheduledFinished(providerID: String, name: String, result: FiveHourResult) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = L10n.t("\(name) scheduled 5-hour start")
            content.body = FiveHourReport.text(for: result)
            content.threadIdentifier = providerID
            center.add(UNNotificationRequest(identifier: "\(providerID).scheduled", content: content, trigger: nil))
        }
    }

    static func weeklyKeeperFailed(providerID: String, providerName: String, detail: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = L10n.t("\(providerName) weekly check failed")
            content.body = detail
            content.threadIdentifier = providerID
            center.add(UNNotificationRequest(identifier: "\(providerID).weekly.failed", content: content, trigger: nil))
        }
    }

    static func weeklyKeeperFinished(providerID: String, providerName: String,
                                     status: PokeStatus) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = L10n.t("\(providerName) weekly window kept")
            switch status {
            case .verified:
                content.body = L10n.t("A minimal request opened the new weekly window.")
            case .notAttributed:
                // Usually the correct answer rather than a fault: real use got
                // there first.
                content.body = L10n.t("A weekly countdown is running, but something else started it.")
            case .unverified:
                content.body = L10n.t("A request was sent, but the backend has not confirmed the countdown.")
            }
            content.threadIdentifier = providerID
            center.add(UNNotificationRequest(
                identifier: "\(providerID).weekly.\(Int(Date().timeIntervalSince1970))",
                content: content, trigger: nil))
        }
    }
}

/// What the user sees after pressing the button, including the failures the
/// engine reports by throwing.
enum FiveHourResult: Equatable {
    case skippedBusy
    case refused(FiveHourRefusal)
    case started(PokeStatus)
    /// The request could not be made at all — no `codex` binary, a child that
    /// would not start, a timeout.
    case failed(String)
    case groups([AntigravityFiveHourOutcome])

    init(_ outcome: FiveHourOutcome) {
        switch outcome {
        case .skippedBusy:          self = .skippedBusy
        case .refused(let reason):  self = .refused(reason)
        case .started(let status):  self = .started(status)
        case .failed(let detail): self = .failed(detail)
        case .groups(let results): self = .groups(results)
        }
    }
}

/// The boundary between the quota engine and the interface.
///
/// The engine blocks — it holds a file lock, sleeps between verification reads
/// and waits on child processes — so nothing here calls it on the main actor.
/// This object exists to keep that rule in one place, and to publish the little
/// state the UI needs while a request is in flight.
@MainActor
final class QuotaController: ObservableObject {
    /// Provider ids with a request in flight. The button spins on these rather
    /// than a global busy flag: one account's start says nothing about another.
    @Published private(set) var running: Set<String> = []
    /// The last result per provider id, shown under the row until something
    /// replaces it.
    @Published private(set) var results: [String: FiveHourResult] = [:]

    /// Providers with a periodic check in flight.
    @Published private(set) var checking: Set<String> = []
    @Published private(set) var checkResults: [String: CheckOutcome] = [:]

    var onAccountsChanged: (() -> Void)?
    var onBurnReadings: (([String: [QuotaBurnReading]]) -> Void)?
    var onScheduledResult: (String, String, FiveHourResult) -> Void = { QuotaAlerts.scheduledFinished(providerID: $0, name: $1, result: $2) }
    let schedule: QuotaSchedule
    private var scheduleTimer: Timer?
    private var scheduledBatchRunning = false
    var isEnabledInUI: (String) -> Bool = { _ in true }
    private let cancellation: QuotaCancellation
    private let storage: QuotaStorage
    private var accounts: [QuotaAccountConfig]
    private let engine: QuotaEngine?
    /// Updated from the session monitors; read by the engine off the main
    /// actor to decide whether to stand aside.
    let inUse = InUseFlags()
    /// Whether the automatic keeper may send anything. Off unless the user
    /// turned it on — see `Preferences.quotaKeeperEnabledKey`.
    var isKeeperEnabled: () -> Bool = { false }
    private var timer: Timer?
    /// The Rust engine's cadence, and unrelated to the sixty-second usage
    /// poll: this one can spend quota, so it runs as rarely as the job allows.
    static let checkInterval: TimeInterval = 300

    /// Takes the engine as given, `nil` included — that is what "there is no
    /// way to make the request" looks like, and a test needs to be able to say
    /// it without depending on what is installed on the machine.
    init(storage: QuotaStorage, engine: QuotaEngine?, cancellation: QuotaCancellation = QuotaCancellation()) {
        self.storage = storage
        self.cancellation = cancellation
        self.schedule = QuotaSchedule(settings: storage.loadSettings(), save: storage.saveSettings)
        self.accounts = storage.loadAccounts().accounts
        self.engine = engine
        // Read on a background thread, so it goes through the lock rather than
        // reaching back into this actor.
        let flags = inUse
        engine?.isAccountInUse = { account in flags.contains(account.providerID) }
    }

    /// Resolves a backend per provider from what this machine has installed.
    ///
    /// Each provider is read and poked through its own vendor command, so a
    /// missing one takes only that provider out — a Mac with Codex but no
    /// Claude Code still guards its Codex accounts.
    convenience init(storage: QuotaStorage = QuotaStorage.systemDefault()) {
        let cancellation = QuotaCancellation()
        let codex = Lazily { (try? CodexBinary.resolve()).map { CodexBackend(binary: $0, cancelled: { cancellation.isCancelled }) } }
        // Resolved once. Both halves spawn a subprocess, and the answers only
        // change when someone installs or removes a command.
        let claude = Lazily { ClaudeBackend.live(cancelled: { cancellation.isCancelled }) }
        let engine = QuotaEngine(storage: storage, backends: { account in
            switch account.provider {
            case .codex:       return codex.get()
            case .claude:      return claude.get()
            case .antigravity: return AntigravityBackend(cancelled: { cancellation.isCancelled })
            }
        })
        self.init(storage: storage, engine: engine, cancellation: cancellation)
    }

    /// Re-read the account list. Cheap, and the file can change while the app
    /// is running.
    var enabledAccounts: [QuotaAccountConfig] { accounts.filter(\.enabled) }

    func reloadAccounts() {
        accounts = storage.loadAccounts().accounts
    }

    /// The managed account behind a provider id, if there is one.
    ///
    /// Only accounts in `accounts.json` can be started: the engine needs a
    /// state directory to hold the baseline and the lock, and a `~/.codex`
    /// profile the engine never adopted has neither.
    func account(forProviderID id: String) -> QuotaAccountConfig? {
        accounts.enabledAccount(forProviderID: id)
    }

    func canStartFiveHour(_ providerID: String) -> Bool {
        guard let engine, let account = account(forProviderID: providerID) else { return false }
        return engine.canReach(account)
    }

    var isBusy: Bool { scheduledBatchRunning || !running.isEmpty || !checking.isEmpty || login != nil || addAccountState == .starting }
    func isRunning(_ providerID: String) -> Bool { running.contains(providerID) || checking.contains(providerID) }

    func result(for providerID: String) -> FiveHourResult? { results[providerID] }

    /// Starts one account's five-hour countdown.
    ///
    /// A second press while the first is in flight is ignored rather than
    /// queued — the engine would refuse it on the lock anyway, and a queued
    /// press is a press the user has forgotten about by the time it lands.
    func startFiveHour(_ providerID: String, trigger: FiveHourTrigger = .manual) async {
        guard !isBusy || (trigger == .scheduled && scheduledBatchRunning && running.isEmpty && checking.isEmpty) else { results[providerID] = .skippedBusy; return }
        guard let engine,
              let account = account(forProviderID: providerID) else { return }

        running.insert(providerID)
        defer { running.remove(providerID) }

        let cancellation = self.cancellation
        let result = await Self.offMainActor {
            do {
                return FiveHourResult(try engine.startFiveHour(account: account, trigger: trigger, cancelled: { cancellation.isCancelled }))
            } catch {
                return FiveHourResult.failed(error.localizedDescription)
            }
        }
        results[providerID] = result
        await publishBurnReadings()
    }

    // MARK: - Adding an account

    /// Where a device sign-in has got to.
    enum AddAccountState: Equatable {
        case idle
        case starting
        /// Show this code and wait; the user finishes in a browser.
        case waiting(CodexDeviceCode)
        case failed(String)
        /// Signed in; discovery now adds this account without restarting.
        case added(label: String)
    }

    @Published private(set) var addAccountState: AddAccountState = .idle
    private var login: CodexDeviceLogin?
    /// The directory the pending sign-in is writing into, so an attempt that
    /// never finishes can take it away again.
    private var pendingAccount: QuotaAccountConfig?
    /// Long enough for someone to find their browser and sign in, short enough
    /// that an abandoned attempt does not sit open forever.
    static let loginTimeout: TimeInterval = 600
    var loginWait: TimeInterval = loginTimeout
    var resolveCodexBinary: () throws -> URL = { try CodexBinary.resolve() }

    /// Creates an account with a home of its own and starts a device sign-in
    /// against it.
    ///
    /// The account is written before the sign-in, and kept even when the
    /// sign-in fails: the directory is what the user signs in *to*, and a
    /// signed-out account keeps its row so it can say how to finish.
    func beginAddCodexAccount(label: String) async {
        guard !isBusy, addAccountState == .idle || isFinished(addAccountState) else { return }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        guard let binary = try? resolveCodexBinary() else {
            addAccountState = .failed(L10n.t("No codex command was found on this Mac."))
            return
        }
        addAccountState = .starting

        let storage = self.storage
        let started = await Self.offMainActor { () -> Result<(QuotaAccountConfig, CodexDeviceLogin), Error> in
            do {
                let account = try storage.createAccount(label: trimmed, provider: .codex)
                do {
                    return .success((account, try CodexDeviceLogin(binary: binary, codexHome: account.codexHomeURL)))
                } catch {
                    storage.discardUnfinishedAccount(account)
                    throw error
                }
            } catch {
                return .failure(error)
            }
        }

        switch started {
        case .failure(let error):
            addAccountState = .failed(error.localizedDescription)
        case .success(let (account, session)):
            guard addAccountState == .starting else {
                session.cancel()
                storage.discardUnfinishedAccount(account)
                return
            }
            login = session
            pendingAccount = account
            // Not reloaded here: the directory exists but has no credential
            // yet, and the timer could pick the account up mid-sign-in. It
            // joins the list once the login completes.
            addAccountState = .waiting(session.code)
            await awaitLogin(session, account: account)
        }
    }

    func cancelAddAccount() async {
        login?.cancel()
        login = nil
        await discardPendingAccount()
        addAccountState = .idle
    }

    /// Takes back the directory `createAccount` made for a sign-in that did
    /// not complete. Does nothing once one has, because the credential is
    /// there by then and the storage layer refuses.
    private func discardPendingAccount() async {
        guard let pendingAccount else { return }
        self.pendingAccount = nil
        let storage = self.storage
        await Self.offMainActor { storage.discardUnfinishedAccount(pendingAccount) }
    }

    private func isFinished(_ state: AddAccountState) -> Bool {
        if case .failed = state { return true }
        if case .added = state { return true }
        return false
    }

    private func awaitLogin(_ session: CodexDeviceLogin, account: QuotaAccountConfig) async {
        let deadline = Date().addingTimeInterval(loginWait)
        while Date() < deadline {
            // Short waits rather than one long one, so cancelling is felt
            // quickly.
            let event = await Self.offMainActor { (try? session.poll(timeout: 3)) ?? .pending }
            // The user cancelled, or started another attempt, while we waited.
            guard case .waiting = addAccountState, login === session else { return }

            switch event {
            case .pending:
                continue
            case .completed:
                login = nil
                // Which ChatGPT account someone picks is only knowable now.
                // Two entries over one account would each keep a baseline and
                // each run the weekly transaction against the same window.
                let storage = self.storage
                let duplicate = await Self.offMainActor {
                    storage.codexAccount(sharingFingerprintWith: account)
                }
                if let duplicate {
                    // Awaited, not fired off: the failure message says the
                    // account was not added, and `reloadAccounts` elsewhere
                    // would pick it straight back up if it were still there.
                    await Self.offMainActor {
                        storage.discardDuplicateAccount(account, matching: duplicate)
                    }
                    pendingAccount = nil
                    reloadAccounts()
                    addAccountState = .failed(
                        L10n.t("This is the same ChatGPT account as \(duplicate.label). It was not added a second time."))
                    return
                }
                pendingAccount = nil
                reloadAccounts()
                addAccountState = .added(label: account.label)
                onAccountsChanged?()
                return
            case .failed(let message):
                login = nil
                await discardPendingAccount()
                addAccountState = .failed(message)
                return
            }
        }
        guard case .waiting = addAccountState, login === session else { return }
        session.cancel()
        login = nil
        await discardPendingAccount()
        addAccountState = .failed(L10n.t("The sign-in was not completed in time."))
    }

    // MARK: - The periodic check

    /// Check every managed account now, and every five minutes after that.
    ///
    /// Separate from `UsageStore`'s sixty-second usage poll on purpose: that
    /// one only reads, while this one can decide to spend quota.
    func start() {
        Task {
            await runScheduleTick()
            await checkAll(mode: isKeeperEnabled() ? .live : .observe)
        }
        let scheduleTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.runScheduleTick() }
        }
        RunLoop.main.add(scheduleTimer, forMode: .common)
        self.scheduleTimer = scheduleTimer
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval,
                                     repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                await self.checkAll(mode: self.isKeeperEnabled() ? .live : .observe)
            }
        }
        // The keeper has to keep running while a menu is open.
        timer.map { RunLoop.main.add($0, forMode: .common) }
    }

    func stop() {
        cancellation.cancel()
        scheduleTimer?.invalidate()
        scheduleTimer = nil
        login?.cancel()
        timer?.invalidate()
        timer = nil
    }

    func publishBurnReadings() async {
        let storage = self.storage, accounts = self.enabledAccounts
        let readings = await Self.offMainActor {
            Dictionary(uniqueKeysWithValues: accounts.map {
                ($0.providerID, QuotaBurnReading.readings(from: storage.loadState(for: $0), provider: $0.provider))
            })
        }
        onBurnReadings?(readings)
    }

    func runScheduleTick(now: Int64 = Int64(Date().timeIntervalSince1970)) async {
        switch schedule.takeDue(now: now, busy: isBusy) {
        case .waiting, .failed: return
        case .expired:
            for account in enabledAccounts {
                try? storage.appendActivity("\(QuotaStorage.activityTimestamp()) 預約已超過一小時，取消不補送。", for: account)
            }
        case .fire:
            scheduledBatchRunning = true
            defer { scheduledBatchRunning = false }
            reloadAccounts()
            let targets = enabledAccounts.filter { isEnabledInUI($0.providerID) }
            for account in targets {
                if cancellation.isCancelled { break }
                await startFiveHour(account.providerID, trigger: .scheduled)
                if let result = results[account.providerID] {
                    onScheduledResult(account.providerID, account.label, result)
                }
            }
        }
    }

    /// One account failing must not stop the others: they are separate
    /// accounts with separate resets.
    func checkAll(mode: CheckMode) async {
        // The automatic path is opt-in; a check the user asked for is not.
        if mode == .live, !isKeeperEnabled() { return }
        for account in accounts where account.enabled && isEnabledInUI(account.providerID) {
            _ = await check(account.providerID, mode: mode)
        }
    }

    @discardableResult
    func check(_ providerID: String, mode: CheckMode) async -> CheckOutcome? {
        // Checked here as well as in `checkAll`: this is the layer that can
        // reach the backend, so it is the one that has to be switched off.
        if mode == .live, !isKeeperEnabled() { return nil }
        guard !isBusy else { checkResults[providerID] = .skippedBusy; return .skippedBusy }
        guard let engine,
              let account = account(forProviderID: providerID) else { return nil }

        checking.insert(providerID)
        defer { checking.remove(providerID) }

        let cancellation = self.cancellation
        let outcome = await Self.offMainActor {
            do { return try engine.checkAccount(account: account, mode: mode, cancelled: { cancellation.isCancelled }) }
            catch { return CheckOutcome.failed(error.localizedDescription) }
        }
        if mode != .observe { checkResults[providerID] = outcome }
        await publishBurnReadings()
        // Only the unattended path announces itself; a check the user asked for
        // reports on screen instead.
        if mode == .live, case .poked(let status) = outcome {
            QuotaAlerts.weeklyKeeperFinished(providerID: providerID,
                                             providerName: account.label,
                                             status: status)
        }
        if mode == .live, case .groups(let groups) = outcome {
            for result in groups {
                if case .poked(let status) = result.outcome {
                    QuotaAlerts.weeklyKeeperFinished(providerID: providerID + ":" + result.group.rawValue,
                                                     providerName: result.group.name, status: status)
                } else if case .failed(let detail) = result.outcome {
                    QuotaAlerts.weeklyKeeperFailed(providerID: providerID + ":" + result.group.rawValue,
                                                   providerName: result.group.name, detail: detail)
                }
            }
        }
        return outcome
    }

    /// The tail of an account's activity log — the record of what the engine
    /// did and why, including the attempts it refused.
    func recentActivity(_ providerID: String, limit: Int = 20) -> [String] {
        guard let account = account(forProviderID: providerID) else { return [] }
        return storage.recentActivity(for: account, limit: limit)
    }

    /// Runs blocking work off the main actor and comes back on it.
    private static func offMainActor<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: work())
            }
        }
    }
}

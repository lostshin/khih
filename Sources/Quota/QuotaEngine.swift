import Foundation

/// Where a five-hour start came from. Both are explicit user actions — no
/// automatic path may reach the five-hour window.
enum FiveHourTrigger: Equatable {
    case manual
    case scheduled

    var label: String {
        switch self {
        case .manual:    return "手動"
        case .scheduled: return "預約"
        }
    }
}

/// Why a gate refused. A value rather than a sentence, so the log can keep the
/// wording the Rust engine used while the UI says it in the user's language.
enum FiveHourRefusal: Equatable, CaseIterable {
    /// The account has never observed itself, so there is nothing to compare
    /// this reading against.
    case noBaseline
    /// The signed-in account cannot be confirmed, or is not the one this state
    /// belongs to.
    case accountUnconfirmed
    /// The backend did not report exactly one five-hour window.
    case noUniqueWindow
    /// The five-hour percentage came back unreadable.
    case unknownUsage
    /// A countdown is already running; another request buys nothing.
    case alreadyRunning
    /// The command this provider is read through is not installed.
    case noBackend

    /// Written to the account's activity log, in the same wording the Rust
    /// engine used so that a log spanning both reads as one story.
    var activityMessage: String {
        switch self {
        case .noBaseline:         return "尚未建立 baseline；第一次觀測不會啟動 5 小時倒數。"
        case .accountUnconfirmed: return "無法確認登入帳號或帳號已改變；未啟動 5 小時倒數。"
        case .noUniqueWindow:     return "找不到唯一的 5 小時 window；未啟動倒數。"
        case .unknownUsage:       return "5 小時用量為 unknown；未啟動倒數。"
        case .alreadyRunning:     return "5 小時倒數已在進行中；未送出最小請求。"
        case .noBackend:          return "找不到讀取這個帳號所需的指令；未啟動倒數。"
        }
    }
}

enum FiveHourOutcome: Equatable {
    /// Another check holds the account's lock; nothing was sent.
    case skippedBusy
    /// A safety gate refused. No request was sent.
    case refused(FiveHourRefusal)
    /// The request went out; the status says whether the backend attributed
    /// the countdown to it.
    case started(PokeStatus)
    case failed(String)
    case groups([AntigravityFiveHourOutcome])
}

/// Which window a verification is about.
enum PokeTarget: Equatable {
    case fiveHour
    case weekly
    case antigravityGroup(AntigravityGroup, weekly: Bool)

    func window(in snapshot: RateLimitsSnapshot, provider: QuotaProvider) -> QuotaWindow? {
        switch self {
        case .fiveHour: return snapshot.fiveHourWindow(for: provider)
        case .weekly:   return snapshot.weeklyWindow(for: provider)
        case .antigravityGroup(let group, let weekly): return group.window(in: snapshot, weekly: weekly)
        }
    }
}

/// Which path a check came in on.
///
/// Only `live` may poke on its own initiative. `manual` is the user asking, and
/// is **not** a way around the safety conditions — it still needs a baseline, a
/// weekly window at 0%, and an unanchored countdown.
enum CheckMode: Equatable {
    /// Startup and the timer.
    case live
    /// The user pressed check.
    case manual
    /// Decide everything, write nothing, send nothing.
    case dryRun
    /// Refresh baseline and burn-rate without entering a poke transaction.
    case observe
}

enum CheckOutcome: Equatable {
    /// Another check holds this account's lock.
    case skippedBusy
    /// The user is actively running an agent on this account, so their own use
    /// will anchor the window without us spending anything.
    case skippedInUse
    /// The provider asked us to back off. The cached snapshot stands; this is
    /// **not** a completed check.
    case rateLimited(retryAt: Int64)
    /// A first — or rebuilt — baseline. Never pokes.
    case baseline
    /// This reset was already handled; not sending a second request for it.
    case alreadyHandled
    /// Something else started the new countdown.
    case countdownAlreadyActive
    /// The scheduled reset has passed but the backend has not confirmed it.
    case resetPending
    case poked(PokeStatus)
    case dryRunWouldPoke
    case noReset
    /// The command this provider is read through is not installed. Nothing was
    /// read and nothing is wrong with the account — there is simply no way to
    /// reach it from this Mac.
    case noBackend
    case failed(String)
    case groups([AntigravityCheckOutcome])
}

enum QuotaBackendError: Error, Equatable {
    /// HTTP 429 and its retry hint. Not an invalid account — the cached
    /// reading stays authoritative until the cooldown passes.
    case rateLimited(retryAt: Int64)
}

/// The upstream half of the engine, behind a protocol so the transaction can be
/// tested without a real Codex install or real quota.
protocol QuotaBackend {
    func accountFingerprint(for account: QuotaAccountConfig) -> String?
    func readRateLimits(for account: QuotaAccountConfig, observedAt: Int64) throws -> RateLimitsSnapshot
    func poke(for account: QuotaAccountConfig, target: PokeTarget, expectedFingerprint: String?) throws -> QuotaPokeResult
}

struct CodexBackend: QuotaBackend {
    var binary: URL
    var appServerTimeout: TimeInterval = CodexAppServerSession.defaultTimeout
    var pokeTimeout: TimeInterval = CodexPoke.defaultTimeout
    var cancelled: () -> Bool = { false }

    func accountFingerprint(for account: QuotaAccountConfig) -> String? {
        CodexFingerprint.of(codexHome: account.codexHomeURL)
    }

    func readRateLimits(for account: QuotaAccountConfig,
                        observedAt: Int64) throws -> RateLimitsSnapshot {
        let session = try CodexAppServerSession(binary: binary,
                                                codexHome: account.codexHomeURL,
                                                timeout: appServerTimeout,
                                                cancelled: cancelled)
        defer { session.shutdown() }
        return try session.rateLimits(observedAt: observedAt)
    }

    func poke(for account: QuotaAccountConfig, target: PokeTarget,
              expectedFingerprint: String?) throws -> QuotaPokeResult {
        try CodexPoke.run(binary: binary,
                          codexHome: account.codexHomeURL,
                          expectedFingerprint: expectedFingerprint,
                          timeout: pokeTimeout,
                          cancelled: cancelled)
    }
}

/// Runs quota transactions against one account at a time.
///
/// Blocking by design — it holds a file lock, sleeps between verification
/// reads, and waits on child processes. Drive it from a background task, never
/// from the main actor.
final class QuotaEngine {
    let storage: QuotaStorage
    private let backends: (QuotaAccountConfig) -> QuotaBackend?
    /// Two seconds between verification reads, as the Rust engine used: long
    /// enough for the backend to catch up, short enough that the user is still
    /// watching.
    private let claudeCooldown: ClaudeCooldown?
    var verificationDelay: TimeInterval
    var now: () -> Int64
    /// Whether the user is running an agent on this account right now.
    ///
    /// Consulted **only** on the automatic path, and only to decide whether to
    /// stand aside: real use anchors the window without us spending anything,
    /// and a request sent alongside it is quota burned for nothing — which is
    /// also the usual way a poke ends up `not-attributed`. It never feeds a
    /// safety decision; those come from backend readings alone.
    var isAccountInUse: (QuotaAccountConfig) -> Bool

    /// One backend for every account. The shape the tests use, and the shape
    /// the app had while Codex was the only provider.
    convenience init(storage: QuotaStorage,
                     backend: QuotaBackend,
                     claudeCooldown: ClaudeCooldown? = nil,
                     verificationDelay: TimeInterval = 2,
                     now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970) },
                     isAccountInUse: @escaping (QuotaAccountConfig) -> Bool = { _ in false }) {
        self.init(storage: storage,
                  backends: { _ in backend },
                  claudeCooldown: claudeCooldown,
                  verificationDelay: verificationDelay,
                  now: now,
                  isAccountInUse: isAccountInUse)
    }

    /// A backend chosen per account. Nil means this Mac cannot reach that
    /// provider at all — the command is not installed — which is a reason to
    /// leave the account alone, not a failure to report every five minutes.
    init(storage: QuotaStorage,
         backends: @escaping (QuotaAccountConfig) -> QuotaBackend?,
         claudeCooldown: ClaudeCooldown? = nil,
         verificationDelay: TimeInterval = 2,
         now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970) },
         isAccountInUse: @escaping (QuotaAccountConfig) -> Bool = { _ in false }) {
        self.claudeCooldown = claudeCooldown
        self.storage = storage
        self.backends = backends
        self.verificationDelay = verificationDelay
        self.now = now
        self.isAccountInUse = isAccountInUse
    }

    /// Whether this Mac has the command this account is read through. A button
    /// that can only refuse should not be offered.
    func canReach(_ account: QuotaAccountConfig) -> Bool { backends(account) != nil }

    private func cooldownDeadline(account: QuotaAccountConfig, state: AccountState, now: Int64) -> Int64? {
        let shared = account.provider == .claude ? claudeCooldown?.deadline(now: now) : nil
        return [state.checkCooldownUntil, shared].compactMap { $0 }.filter { $0 > now }.max()
    }

    private func readRateLimits(account: QuotaAccountConfig, backend: QuotaBackend,
                                observedAt: Int64) throws -> RateLimitsSnapshot {
        let cooldown = account.provider == .claude ? claudeCooldown : nil
        if let until = cooldown?.deadline(now: observedAt) {
            throw QuotaBackendError.rateLimited(retryAt: until)
        }
        do {
            let snapshot = try backend.readRateLimits(for: account, observedAt: observedAt)
            cooldown?.succeeded(now: now())
            return snapshot
        } catch QuotaBackendError.rateLimited(let retryAt) {
            cooldown?.record(until: retryAt, now: now())
            throw QuotaBackendError.rateLimited(retryAt: retryAt)
        }
    }

    private func poke(account: QuotaAccountConfig, backend: QuotaBackend, target: PokeTarget,
                      expectedFingerprint: String?) throws -> QuotaPokeResult {
        if account.provider == .claude, let until = claudeCooldown?.deadline(now: now()) {
            throw QuotaBackendError.rateLimited(retryAt: until)
        }
        return try backend.poke(for: account, target: target, expectedFingerprint: expectedFingerprint)
    }

    // MARK: - Weekly keeper

    /// One account's periodic check, and the weekly reset transaction it may
    /// lead to.
    ///
    /// The order below is not arrangeable. Reading, reconciling, deciding,
    /// recording the reset key, sending, and only then verifying — each step
    /// exists because the one before it can be wrong, and reordering any two of
    /// them reintroduces a way to spend quota twice for one reset.
    func checkAccount(account: QuotaAccountConfig,
                      mode: CheckMode,
                      cancelled: () -> Bool = { false }) throws -> CheckOutcome {
        if cancelled() { throw CodexError.cancelled }

        guard let lock = try storage.acquireCheckLock(for: account) else {
            try? activity("另一項檢查仍在執行，已略過。", for: account)
            return .skippedBusy
        }
        defer { withExtendedLifetime(lock) {} }

        guard let backend = backends(account) else {
            try? activity("找不到讀取這個帳號所需的指令；未執行檢查。", for: account)
            return .noBackend
        }

        if account.provider == .antigravity {
            return .groups(try checkAntigravity(account: account, backend: backend, mode: mode, cancelled: cancelled))
        }
        let provider = account.provider
        let moment = now()
        var state = storage.loadState(for: account)

        // A cooldown means "do not touch the backend", so it is answered before
        // anything is read — and it is reported as *not connected*, never as a
        // completed check.
        if let cooldown = cooldownDeadline(account: account, state: state, now: moment) {
            return .rateLimited(retryAt: cooldown)
        }

        let fingerprint = backend.accountFingerprint(for: account)
        let incoming: RateLimitsSnapshot
        do {
            incoming = try readRateLimits(account: account, backend: backend, observedAt: moment)
        } catch QuotaBackendError.rateLimited(let retryAt) {
            if mode != .dryRun {
                state.checkCooldownUntil = retryAt
                try storage.saveState(state, for: account)
                try? activity("額度查詢收到 HTTP 429；保留 cached quota，冷卻至 \(Self.taipei(retryAt))（台灣時間）。",
                              for: account)
            }
            return .rateLimited(retryAt: retryAt)
        }
        state.checkCooldownUntil = nil

        // A fingerprint that does not match rebuilds the state from scratch.
        // Carrying a reset key across accounts is how one account's handled
        // reset silences another's.
        if let fingerprint, state.accountFingerprint != fingerprint {
            let message = state.accountFingerprint == nil
                ? "已記錄帳號 fingerprint；只更新 baseline，不送出自動請求。"
                : "登入帳號已改變；只建立新 baseline，不送出自動請求。"
            try? activity(message, for: account)
            if mode != .dryRun {
                var rebuilt = AccountState(accountFingerprint: fingerprint)
                let primed = Self.primeSnapshot(incoming)
                rebuilt.weeklyKeeper.countdownActive =
                    primed.weeklyWindow(for: provider)?.countdownActive ?? false
                rebuilt.snapshot = primed
                try storage.saveState(rebuilt, for: account)
            }
            return .baseline
        }

        let previousSnapshot = state.snapshot
        var current: RateLimitsSnapshot
        if let previousSnapshot {
            let outcome = QuotaDomain.reconcileSnapshot(previous: previousSnapshot, incoming: incoming)
            current = outcome.snapshot
            if outcome.rejected > 0 {
                try? activity("忽略 \(outcome.rejected) 組落後的 rate-limit 讀值；同一 window 保留較高用量。",
                              for: account)
            }
        } else {
            current = Self.primeSnapshot(incoming)
        }
        try? activity(Self.formatSnapshot(current, provider: provider), for: account)

        // Measured from reconciled values, so a lagging read the ratchet
        // rejected contributes nothing. Display only: the burn rate never
        // reaches reset detection or the poke transaction.
        if let previousSnapshot {
            state.burnRate.observe(previous: previousSnapshot, current: current, provider: provider)
        }

        let previousWeekly = previousSnapshot?.weeklyWindow(for: provider)
        guard var currentWeekly = current.weeklyWindow(for: provider) else {
            try? activity("找不到唯一的 \(provider.displayName) 7 天 window；停用每週自動守護，本次不送出請求。",
                          for: account)
            if mode != .dryRun {
                state.accountFingerprint = fingerprint ?? state.accountFingerprint
                state.snapshot = current
                try storage.saveState(state, for: account)
            }
            return previousSnapshot == nil ? .baseline : .noReset
        }

        // A first observation establishes what "before" means. It can never
        // justify spending anything.
        if previousSnapshot == nil || previousWeekly == nil {
            try? activity("已建立雙時段 baseline；第一次觀測不會消耗額度。", for: account)
            if mode != .dryRun {
                state.accountFingerprint = fingerprint
                state.weeklyKeeper.countdownActive = currentWeekly.countdownActive
                state.snapshot = current
                try storage.saveState(state, for: account)
            }
            return .baseline
        }

        state.weeklyKeeper.countdownActive = currentWeekly.countdownActive
        if let existing = state.weeklyKeeper.lastPoke {
            state.weeklyKeeper.lastPoke = QuotaDomain.normalizeLastPoke(
                existing, countdownActive: currentWeekly.countdownActive, window: currentWeekly)
        }

        if mode == .observe {
            state.snapshot = current
            try storage.saveState(state, for: account)
            return .noReset
        }

        let decision = QuotaDomain.detectReset(
            previous: previousWeekly, current: currentWeekly, nowSeconds: moment,
            pendingScheduledResetAt: state.weeklyKeeper.pendingScheduledResetAt)

        // A manual check is not a way around the gates: it still needs a weekly
        // window at 0% with no countdown anchored.
        let claudeAbsent = provider == .claude && currentWeekly.usedPercent == 0 && currentWeekly.resetsAt == nil
        let manualStart = mode == .manual && !currentWeekly.countdownActive
            && QuotaDomain.pokeRetryAllowed(window: currentWeekly, attempt: 0)
            && (!claudeAbsent || decision.scheduledResetAt.map { moment >= $0 } == true)
        let resetKey = manualStart
            ? (decision.resetKey
               ?? state.weeklyKeeper.lastHandledResetKey
               ?? "manual:\(currentWeekly.observedAt)")
            : decision.resetKey

        let outcome: CheckOutcome
        if decision.resetObserved
            && decision.resetKey == state.weeklyKeeper.lastHandledResetKey
            && !manualStart {
            state.weeklyKeeper.pendingScheduledResetAt = nil
            try? activity("這次每週 reset 已處理，不重送自動請求。", for: account)
            outcome = .alreadyHandled

        } else if decision.resetObserved && decision.countdownActive {
            state.weeklyKeeper.lastHandledResetKey = decision.resetKey
            state.weeklyKeeper.pendingScheduledResetAt = nil
            state.weeklyKeeper.countdownActive = true
            try? activity("每週新倒數已由其他使用行為啟動，不送出自動請求。", for: account)
            outcome = .countdownAlreadyActive

        } else if claudeAbsent, let previousWeekly,
                  previousWeekly.usedPercent != 0 || previousWeekly.resetsAt != nil {
            state.weeklyKeeper.pendingScheduledResetAt = decision.scheduledResetAt ?? previousWeekly.resetsAt
            try? activity("Claude weekly window 第一次缺席；等待下一次檢查確認，不送出最小請求。", for: account)
            outcome = .resetPending

        } else if decision.shouldPoke || manualStart {
            guard fingerprint != nil else {
                return .failed(L10n.t("Not sent — the signed-in account could not be confirmed."))
            }
            // Standing aside costs nothing: the user's own request will anchor
            // the window, and this check runs again in five minutes.
            if mode == .live, isAccountInUse(account) {
                try? activity("這個帳號正在使用中；本次不送出自動請求，等下次檢查。", for: account)
                outcome = .skippedInUse
            } else if mode == .dryRun {
                try? activity("Dry run：每週 reset 已確認，本可送出最小請求。", for: account)
                outcome = .dryRunWouldPoke
            } else {
                if manualStart {
                    try? activity("手動檢查：每週額度為 0% 且倒數未啟動，嘗試啟動。", for: account)
                }
                var finalStatus = PokeStatus.unverified
                for attempt in 1...Quota.pokeAttemptLimit {
                    // A failure here propagates before the reset key is
                    // written, so a reset nothing anchored is retried rather
                    // than recorded as handled.
                    let poke = try poke(account: account, backend: backend, target: .weekly, expectedFingerprint: fingerprint)
                    let pokeAt = now()

                    state.weeklyKeeper.lastHandledResetKey = resetKey
                    state.weeklyKeeper.lastPoke = LastPoke(at: pokeAt, model: poke.model,
                                                           response: poke.response,
                                                           accountFingerprint: poke.accountFingerprint,
                                                           status: .unverified,
                                                           attempt: attempt, verifiedAt: nil)
                    state.weeklyKeeper.pendingScheduledResetAt = nil
                    state.weeklyKeeper.countdownActive = false
                    state.accountFingerprint = fingerprint
                    state.snapshot = current
                    // Written before verifying, so a crash in between cannot
                    // lose the fact that a request went out.
                    try storage.saveState(state, for: account)

                    let verification = verifyPoke(account: account, backend: backend, target: .weekly,
                                                  previousSnapshot: current,
                                                  previousWindow: currentWeekly,
                                                  pokeAt: pokeAt, cancelled: cancelled)
                    state.checkCooldownUntil = verification.retryAt
                    current = verification.latest
                    if let latest = current.weeklyWindow(for: provider) { currentWeekly = latest }
                    finalStatus = verification.status
                    if verification.retryAt != nil { break }

                    if finalStatus != .unverified {
                        state.weeklyKeeper.countdownActive = true
                        state.weeklyKeeper.lastPoke?.status = finalStatus
                        state.weeklyKeeper.lastPoke?.verifiedAt = currentWeekly.observedAt
                        try? activity(finalStatus == .verified
                            ? "\(provider.displayName) backend 已確認最小請求啟動每週倒數。"
                            : "\(provider.displayName) backend 已有每週倒數，但無法歸因於這次自動請求。",
                                      for: account)
                        break
                    }
                    try? activity("最小請求 \(attempt)/\(Quota.pokeAttemptLimit) 已完成，但 backend 尚未確認每週倒數。",
                                  for: account)
                    // Only a window still at 0% and still unanchored may be
                    // asked again.
                    guard QuotaDomain.pokeRetryAllowed(window: currentWeekly, attempt: attempt) else {
                        break
                    }
                    try? activity("每週用量仍為 0% 且 window 未錨定；重新送出最小請求。", for: account)
                }
                outcome = .poked(finalStatus)
            }

        } else if decision.resetPending {
            state.weeklyKeeper.pendingScheduledResetAt = decision.scheduledResetAt
            try? activity("每週預定 reset time 已過，但 backend 尚未回報 reset；繼續等待。", for: account)
            outcome = .resetPending

        } else {
            if decision.reason == .noReset {
                try? activity("未偵測到每週 reset；未送出自動請求。", for: account)
            }
            outcome = .noReset
        }

        if mode != .dryRun {
            state.accountFingerprint = fingerprint ?? state.accountFingerprint
            state.weeklyKeeper.countdownActive = currentWeekly.countdownActive
            state.snapshot = current
            try storage.saveState(state, for: account)
        }
        return outcome
    }

    /// A snapshot with no history behind it: every `countdownActive` computed
    /// from the reading alone rather than trusted from the wire.
    static func primeSnapshot(_ snapshot: RateLimitsSnapshot) -> RateLimitsSnapshot {
        QuotaDomain.reconcileSnapshot(previous: RateLimitsSnapshot(), incoming: snapshot).snapshot
    }

    private static func taipei(_ epochSeconds: Int64) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Taipei")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(epochSeconds)))
    }

    // MARK: - Five-hour start

    /// Anchors one account's five-hour window with a single minimal request.
    ///
    /// Deliberately separate from the weekly keeper: reset detection owns the
    /// weekly transaction and must never be able to reach this window. Unlike
    /// the weekly keeper this **never retries** — a lagging backend read almost
    /// certainly still means the first request anchored the window, so a second
    /// one would only spend quota. The user can press the button again.
    func startFiveHour(account: QuotaAccountConfig,
                       trigger: FiveHourTrigger,
                       cancelled: () -> Bool = { false }) throws -> FiveHourOutcome {
        if cancelled() { throw CodexError.cancelled }

        guard let lock = try storage.acquireCheckLock(for: account) else {
            try? activity("另一項檢查仍在執行，未啟動 5 小時倒數。", for: account)
            return .skippedBusy
        }
        defer { withExtendedLifetime(lock) {} }

        // Written before any gate is evaluated, so that a refused attempt
        // leaves a record too. A schedule most often lands on a refusal, and
        // without this line there is no way to tell afterwards whether it fired
        // at all.
        try? activity("\(trigger.label)觸發：開始啟動 5 小時倒數。", for: account)

        // Nothing was read, so there is no snapshot to persist and no state to
        // touch — just the refusal and its line in the log.
        guard let backend = backends(account) else {
            try? activity(FiveHourRefusal.noBackend.activityMessage, for: account)
            return .refused(.noBackend)
        }

        if account.provider == .antigravity {
            return .groups(try startAntigravity(account: account, backend: backend, cancelled: cancelled))
        }
        let provider = account.provider
        var state = storage.loadState(for: account)
        if cooldownDeadline(account: account, state: state, now: now()) != nil {
            return .failed(L10n.t("Not connected — waiting for the rate-limit cooldown."))
        }
        let incoming: RateLimitsSnapshot
        do {
            incoming = try readRateLimits(account: account, backend: backend, observedAt: now())
        } catch QuotaBackendError.rateLimited(let retryAt) {
            state.checkCooldownUntil = retryAt
            try storage.saveState(state, for: account)
            return .failed(L10n.t("Not connected — waiting for the rate-limit cooldown."))
        }
        state.checkCooldownUntil = nil

        // Gate 1: an account that has never observed itself has nothing to
        // compare against, and every other gate reads from that comparison.
        guard let previousSnapshot = state.snapshot else {
            try? activity(FiveHourRefusal.noBaseline.activityMessage, for: account)
            return .refused(.noBaseline)
        }

        // Gate 2: state that belongs to a different account says nothing about
        // this one.
        let fingerprint = backend.accountFingerprint(for: account)
        guard let fingerprint, fingerprint == state.accountFingerprint else {
            try? activity(FiveHourRefusal.accountUnconfirmed.activityMessage, for: account)
            return .refused(.accountUnconfirmed)
        }

        let reconciled = QuotaDomain.reconcileSnapshot(previous: previousSnapshot, incoming: incoming)
        var current = reconciled.snapshot
        if reconciled.rejected > 0 {
            try? activity("忽略 \(reconciled.rejected) 組落後的 rate-limit 讀值；同一 window 保留較高用量。",
                          for: account)
        }
        try? activity(Self.formatSnapshot(current, provider: provider), for: account)
        state.burnRate.observe(previous: previousSnapshot, current: current, provider: provider)

        // Gate 3: a missing or duplicated window means the backend said
        // something we do not understand.
        guard let fiveHour = current.fiveHourWindow(for: provider) else {
            return try refuse(.noUniqueWindow,
                              account: account, state: &state, current: current)
        }
        // Gate 4: an unreadable percentage cannot clear gate 5.
        guard fiveHour.usedPercent != nil else {
            return try refuse(.unknownUsage,
                              account: account, state: &state, current: current)
        }
        // Gate 5: the window is already ticking; another request buys nothing.
        guard !fiveHour.countdownActive else {
            return try refuse(.alreadyRunning,
                              account: account, state: &state, current: current)
        }

        // The same request necessarily spends weekly quota too, so it anchors
        // the weekly window as well when that one has not started. Said out
        // loud here because it happens outside the weekly transaction.
        if let weekly = current.weeklyWindow(for: provider), !weekly.countdownActive {
            try? activity("每週倒數尚未錨定；這次最小請求會同時啟動每週倒數。", for: account)
        }

        let poke = try poke(account: account, backend: backend, target: .fiveHour, expectedFingerprint: fingerprint)
        let pokeAt = now()

        // Persist before verifying. A crash between the request and the
        // verification must not lose the fact that a request went out.
        state.fiveHourStarter.lastPoke = LastPoke(at: pokeAt,
                                                  model: poke.model,
                                                  response: poke.response,
                                                  accountFingerprint: poke.accountFingerprint,
                                                  status: .unverified,
                                                  attempt: 1,
                                                  verifiedAt: nil)
        state.accountFingerprint = fingerprint
        state.snapshot = current
        try storage.saveState(state, for: account)

        let verification = verifyPoke(account: account, backend: backend, target: .fiveHour,
                                      previousSnapshot: current, previousWindow: fiveHour,
                                      pokeAt: pokeAt, cancelled: cancelled)
        state.checkCooldownUntil = verification.retryAt
        current = verification.latest
        if verification.status != .unverified {
            state.fiveHourStarter.lastPoke?.status = verification.status
            state.fiveHourStarter.lastPoke?.verifiedAt =
                current.fiveHourWindow(for: provider)?.observedAt
        }

        let name = provider.displayName
        let message: String
        switch verification.status {
        case .verified:      message = "\(name) backend 已確認最小請求啟動 5 小時倒數。"
        case .notAttributed: message = "\(name) backend 已有 5 小時倒數，但無法歸因於這次請求。"
        case .unverified:    message = "最小請求已完成，但 \(name) backend 尚未確認 5 小時倒數。"
        }
        try? activity(message, for: account)
        try persist(account: account, state: &state, current: current)
        return .started(verification.status)
    }

    private func refuse(_ reason: FiveHourRefusal,
                        account: QuotaAccountConfig,
                        state: inout AccountState,
                        current: RateLimitsSnapshot) throws -> FiveHourOutcome {
        try? activity(reason.activityMessage, for: account)
        try persist(account: account, state: &state, current: current)
        return .refused(reason)
    }

    /// Stores the freshly read snapshot so the UI stops showing the pre-press
    /// values, and keeps the weekly keeper's own view of the countdown honest —
    /// a five-hour start can anchor the weekly window as a side effect.
    private func persist(account: QuotaAccountConfig,
                         state: inout AccountState,
                         current: RateLimitsSnapshot) throws {
        let weekly = current.weeklyWindow(for: account.provider)
        state.weeklyKeeper.countdownActive = weekly?.countdownActive ?? false
        if let existing = state.weeklyKeeper.lastPoke {
            state.weeklyKeeper.lastPoke = QuotaDomain.normalizeLastPoke(
                existing, countdownActive: state.weeklyKeeper.countdownActive, window: weekly)
        }
        state.snapshot = current
        try storage.saveState(state, for: account)
    }

    // MARK: - Verification

    struct Verification {
        var status: PokeStatus
        var latest: RateLimitsSnapshot
        var retryAt: Int64? = nil
    }

    /// Reads the target window back until it confirms an anchored countdown.
    ///
    /// The `usageConfirms || stableZeroConfirms` guard is what keeps a
    /// provisional zero window from being mistaken for a started one: Codex
    /// reports an unstarted five-hour window as `resetsAt = observedAt + 5h`,
    /// whose implied start equals the read time and would therefore satisfy
    /// `pokeMatchesWindow` on its own. Removing this guard makes every
    /// five-hour start report `verified`, including the ones that anchored
    /// nothing.
    func verifyPoke(account: QuotaAccountConfig,
                    backend: QuotaBackend,
                    target: PokeTarget,
                    previousSnapshot: RateLimitsSnapshot,
                    previousWindow: QuotaWindow,
                    pokeAt: Int64,
                    cancelled: () -> Bool = { false }) -> Verification {
        let provider = account.provider
        var latest = previousSnapshot
        var previousVerification: QuotaWindow?

        for _ in 0..<Quota.pokeVerificationAttempts {
            if cancelled() { break }
            Thread.sleep(forTimeInterval: verificationDelay)
            if cancelled() { break }

            let read: RateLimitsSnapshot
            do {
                read = try readRateLimits(account: account, backend: backend, observedAt: now())
            } catch QuotaBackendError.rateLimited(let retryAt) {
                return Verification(status: .unverified, latest: latest, retryAt: retryAt)
            } catch {
                continue
            }
            latest = QuotaDomain.reconcileSnapshot(previous: latest, incoming: read).snapshot
            guard let window = target.window(in: latest, provider: provider) else { continue }

            let active = QuotaDomain.countdownWindowActive(previous: previousWindow, current: window)
            let usageConfirms = (window.usedPercent ?? 0) > 0
            let stableZeroConfirms = provider != .antigravity
                && window.usedPercent == 0
                && previousVerification.map {
                    QuotaDomain.countdownWindowActive(previous: $0, current: window)
                } ?? false

            if active && (usageConfirms || stableZeroConfirms) {
                return Verification(
                    status: QuotaDomain.pokeMatchesWindow(pokeAt: pokeAt, window: window)
                        ? .verified : .notAttributed,
                    latest: latest)
            }
            previousVerification = window
        }
        return Verification(status: .unverified, latest: latest)
    }

    // MARK: - Activity

    func activity(_ message: String, for account: QuotaAccountConfig) throws {
        try storage.appendActivity("\(QuotaStorage.activityTimestamp()) \(message)", for: account)
    }

    /// One line per window, so a later reader can reconstruct what the backend
    /// said at the moment of a decision.
    static func formatSnapshot(_ snapshot: RateLimitsSnapshot, provider: QuotaProvider) -> String {
        func describe(_ label: String, _ window: QuotaWindow?) -> String? {
            guard let window else { return nil }
            let used = window.usedPercent.map { String(format: "%.1f%%", $0) } ?? "unknown"
            let reset = window.resetsAt.map(String.init) ?? "—"
            return "\(label) used=\(used) active=\(window.countdownActive) reset=\(reset)"
        }
        let parts = [describe("5h", snapshot.fiveHourWindow(for: provider)),
                     describe("weekly", snapshot.weeklyWindow(for: provider))].compactMap { $0 }
        return parts.isEmpty ? "讀取到 rate limits，但沒有可辨識的 window。"
                             : "讀取 rate limits：" + parts.joined(separator: "；")
    }
}

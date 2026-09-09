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

    /// Written to the account's activity log, in the same wording the Rust
    /// engine used so that a log spanning both reads as one story.
    var activityMessage: String {
        switch self {
        case .noBaseline:         return "尚未建立 baseline；第一次觀測不會啟動 5 小時倒數。"
        case .accountUnconfirmed: return "無法確認登入帳號或帳號已改變；未啟動 5 小時倒數。"
        case .noUniqueWindow:     return "找不到唯一的 5 小時 window；未啟動倒數。"
        case .unknownUsage:       return "5 小時用量為 unknown；未啟動倒數。"
        case .alreadyRunning:     return "5 小時倒數已在進行中；未送出最小請求。"
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
}

/// Which window a verification is about.
enum PokeTarget: Equatable {
    case fiveHour
    case weekly

    func window(in snapshot: RateLimitsSnapshot, provider: QuotaProvider) -> QuotaWindow? {
        switch self {
        case .fiveHour: return snapshot.fiveHourWindow(for: provider)
        case .weekly:   return snapshot.weeklyWindow(for: provider)
        }
    }
}

/// The upstream half of the engine, behind a protocol so the transaction can be
/// tested without a real Codex install or real quota.
protocol QuotaBackend {
    func accountFingerprint(for account: QuotaAccountConfig) -> String?
    func readRateLimits(for account: QuotaAccountConfig, observedAt: Int64) throws -> RateLimitsSnapshot
    func poke(for account: QuotaAccountConfig, expectedFingerprint: String?) throws -> CodexPokeResult
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

    func poke(for account: QuotaAccountConfig,
              expectedFingerprint: String?) throws -> CodexPokeResult {
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
    let backend: QuotaBackend
    /// Two seconds between verification reads, as the Rust engine used: long
    /// enough for the backend to catch up, short enough that the user is still
    /// watching.
    var verificationDelay: TimeInterval
    var now: () -> Int64

    init(storage: QuotaStorage,
         backend: QuotaBackend,
         verificationDelay: TimeInterval = 2,
         now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970) }) {
        self.storage = storage
        self.backend = backend
        self.verificationDelay = verificationDelay
        self.now = now
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

        let provider = account.provider
        let incoming = try backend.readRateLimits(for: account, observedAt: now())
        var state = storage.loadState(for: account)

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

        let poke = try backend.poke(for: account, expectedFingerprint: fingerprint)
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

        let verification = verifyPoke(account: account, target: .fiveHour,
                                      previousSnapshot: current, previousWindow: fiveHour,
                                      pokeAt: pokeAt, cancelled: cancelled)
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

            guard let read = try? backend.readRateLimits(for: account, observedAt: now()) else {
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

import Foundation

// Pure quota logic: no I/O, no network, no clock of its own. Every decision
// about whether a countdown is running, whether a reset happened, and whether a
// request may be sent is made here and nowhere else — the UI, the engine and
// the verification path all call into these functions rather than reimplementing
// a looser version of them.

enum ResetReason: Equatable {
    case baseline
    case scheduledResetAtZero
    case scheduledResetWithActiveCountdown
    case usageDroppedAndTimestampChanged
    case scheduledResetPending
    case noReset
}

struct ResetDecision: Equatable {
    var resetObserved: Bool
    var countdownActive: Bool
    var resetPending: Bool
    var scheduledResetAt: Int64?
    var shouldPoke: Bool
    var resetKey: String?
    var reason: ResetReason
}

enum QuotaDomain {

    /// Whether a quota window's countdown has genuinely started.
    ///
    /// The whole safety model rests on this one function, and the hard case is a
    /// window reporting 0% with a `resetsAt` in the future. Codex reports
    /// exactly that for a five-hour window that has *not* started yet, with
    /// `resetsAt = observedAt + 5h` — so a naive "has a reset time, must be
    /// running" test marks every idle window as active and disables the gate
    /// that stops us spending quota on a window that is already ticking.
    ///
    /// The distinguishing question is not whether a reset time exists, but
    /// whether it is *fixed*: reasoning back to the window start gives a moment
    /// that stays put once a countdown is really running, and therefore drifts
    /// further into the past on every read. For a window that has not started,
    /// the reasoned-back start equals the moment of the read itself.
    static func countdownWindowActive(previous: QuotaWindow?, current: QuotaWindow) -> Bool {
        guard let usedPercent = current.usedPercent else { return false }
        guard let resetsAt = current.resetsAt else { return false }
        if resetsAt <= current.observedAt { return false }
        // Any usage at all is direct evidence, and the only direct evidence
        // there is.
        if usedPercent > 0 { return true }
        if usedPercent != 0 { return false }

        if let duration = current.windowDurationMins, duration > 0 {
            let windowStart = resetsAt - duration * 60
            // Not `> 0`: at zero the reasoned-back start is the read itself,
            // which is exactly what an unstarted window looks like.
            return current.observedAt - windowStart >= Quota.resetAtJitterSeconds
        }

        // Without a duration there is nothing to reason back from, so fall back
        // to watching whether the reset time follows the reads. A reset time
        // that moves along with every observation belongs to a window that has
        // not started.
        if let previous, let previousReset = previous.resetsAt, let currentReset = current.resetsAt {
            let elapsed = current.observedAt - previous.observedAt
            let movement = abs(currentReset - previousReset)
            return elapsed >= Quota.resetAtJitterSeconds && movement < elapsed
        }
        return false
    }

    /// `resetsAt` jitters by about a second between reads, so it is never
    /// compared for strict equality.
    static func resetAtMoved(_ previous: Int64?, _ current: Int64?) -> Bool {
        switch (previous, current) {
        case let (previous?, current?): return abs(current - previous) > Quota.resetAtJitterSeconds
        case (nil, nil):                return false
        default:                        return true
        }
    }

    /// A non-zero reading that dropped while the reset time stayed put is a
    /// lagging replica, not real usage going down.
    static func suspectUsageDrop(previous: QuotaWindow, current: QuotaWindow) -> Bool {
        guard let previousUsed = previous.usedPercent, let currentUsed = current.usedPercent else {
            return false
        }
        return currentUsed > 0
            && currentUsed < previousUsed
            && !resetAtMoved(previous.resetsAt, current.resetsAt)
    }

    /// Hold the higher reading and take only the new timestamp.
    ///
    /// There is deliberately no escape hatch that accepts a drop after N
    /// consecutive reads: a replica that lags for an hour would then be
    /// promoted to the truth, and the quota it hides is quota we would spend.
    static func reconcileSuspectRead(previous: QuotaWindow,
                                     current: QuotaWindow) -> (window: QuotaWindow, rejected: Bool) {
        guard suspectUsageDrop(previous: previous, current: current) else { return (current, false) }
        var held = previous
        held.observedAt = current.observedAt
        return (held, true)
    }

    /// Pair a window with its previous self by duration where that is
    /// unambiguous, and only fall back to the primary/secondary slot when it is
    /// not — the backend has been seen to move a window between the two slots.
    private static func matchingPreviousWindow(in bucket: RateLimitBucket,
                                               current: QuotaWindow,
                                               primary: Bool) -> QuotaWindow? {
        if let duration = current.windowDurationMins {
            let matches = [bucket.primary, bucket.secondary]
                .compactMap { $0 }
                .filter { $0.windowDurationMins == duration }
            // Zero matches means this window has no previous self at all —
            // the plan's window layout changed under us. Falling back to the
            // slot would pair it with a window of a different length and carry
            // that window's countdown verdict across.
            if matches.isEmpty { return nil }
            if matches.count == 1 { return matches[0] }
        }
        return primary ? bucket.primary : bucket.secondary
    }

    /// Merge an incoming read into what we already believed, rejecting lagging
    /// replicas and recomputing every `countdownActive` from scratch.
    static func reconcileSnapshot(previous: RateLimitsSnapshot,
                                  incoming: RateLimitsSnapshot) -> (snapshot: RateLimitsSnapshot,
                                                                    rejected: Int) {
        var current = incoming
        var rejected = 0

        for index in current.buckets.indices {
            let limitId = current.buckets[index].limitId
            guard let previousBucket = previous.buckets.first(where: { $0.limitId == limitId }) else {
                // Nothing to compare against: initialise, never trust the
                // incoming `countdownActive`.
                if var window = current.buckets[index].primary {
                    window.countdownActive = countdownWindowActive(previous: nil, current: window)
                    current.buckets[index].primary = window
                }
                if var window = current.buckets[index].secondary {
                    window.countdownActive = countdownWindowActive(previous: nil, current: window)
                    current.buckets[index].secondary = window
                }
                continue
            }

            for isPrimary in [true, false] {
                guard var window = isPrimary ? current.buckets[index].primary
                                             : current.buckets[index].secondary else { continue }
                if let previousWindow = matchingPreviousWindow(in: previousBucket,
                                                              current: window,
                                                              primary: isPrimary) {
                    let outcome = reconcileSuspectRead(previous: previousWindow, current: window)
                    var reconciled = outcome.window
                    if outcome.rejected { rejected += 1 }
                    // An unknown percentage carries no new evidence either way,
                    // so the previous verdict stands rather than being reset.
                    reconciled.countdownActive = reconciled.usedPercent == nil
                        ? previousWindow.countdownActive
                        : countdownWindowActive(previous: previousWindow, current: reconciled)
                    window = reconciled
                } else {
                    window.countdownActive = countdownWindowActive(previous: nil, current: window)
                }
                if isPrimary { current.buckets[index].primary = window }
                else { current.buckets[index].secondary = window }
            }
        }
        return (current, rejected)
    }

    /// Decide whether a weekly window has reset, and whether that reset is ours
    /// to act on.
    ///
    /// A scheduled reset time that has merely passed is never enough on its own
    /// — the backend has to agree, either by reporting zero usage or by showing
    /// a countdown that is genuinely running.
    static func detectReset(previous: QuotaWindow?,
                            current: QuotaWindow,
                            nowSeconds: Int64,
                            pendingScheduledResetAt: Int64?) -> ResetDecision {
        let currentUnused = current.usedPercent == 0
        let currentUsed = (current.usedPercent ?? 0) > 0
        let currentResetInFuture = (current.resetsAt ?? .min) > nowSeconds

        // A first observation can never justify spending quota.
        guard let previous else {
            return ResetDecision(resetObserved: false,
                                 countdownActive: currentUsed && currentResetInFuture,
                                 resetPending: false,
                                 scheduledResetAt: nil,
                                 shouldPoke: false,
                                 resetKey: nil,
                                 reason: .baseline)
        }

        // A remembered pending reset wins over the previous window's own time:
        // that is what carries a delayed reset across checks.
        let scheduledResetAt = pendingScheduledResetAt ?? previous.resetsAt
        let scheduledResetPassed = scheduledResetAt.map { nowSeconds >= $0 } ?? false

        let usedDropped: Bool = {
            guard let previousUsed = previous.usedPercent,
                  let currentUsedPercent = current.usedPercent else { return false }
            return previousUsed > 0 && currentUsedPercent < previousUsed
        }()
        let usageReset = usedDropped && resetAtMoved(previous.resetsAt, current.resetsAt)

        let scheduledResetReady = scheduledResetPassed && currentUnused
        let countdownActive = (currentUsed && currentResetInFuture)
            || countdownWindowActive(previous: previous, current: current)
        let scheduledCountdownReady = scheduledResetPassed && countdownActive

        let resetObserved = usageReset || scheduledResetReady || scheduledCountdownReady
        let resetPending = scheduledResetPassed && !scheduledResetReady && !scheduledCountdownReady

        let resetKey: String? = {
            if scheduledResetReady || scheduledCountdownReady || (usageReset && scheduledResetPassed) {
                return scheduledResetAt.map { "scheduled:\($0)" }
            }
            if usageReset {
                let before = previous.resetsAt.map(String.init) ?? "none"
                let after = current.resetsAt.map(String.init) ?? "none"
                return "early:\(before):\(after)"
            }
            return nil
        }()

        let reason: ResetReason = {
            if scheduledResetReady { return .scheduledResetAtZero }
            if scheduledCountdownReady { return .scheduledResetWithActiveCountdown }
            if usageReset { return .usageDroppedAndTimestampChanged }
            if resetPending { return .scheduledResetPending }
            return .noReset
        }()

        return ResetDecision(resetObserved: resetObserved,
                             countdownActive: countdownActive,
                             resetPending: resetPending,
                             scheduledResetAt: scheduledResetAt,
                             // Only a window that is still at zero is worth
                             // anchoring; anything else is already running.
                             shouldPoke: resetObserved && currentUnused,
                             resetKey: resetKey,
                             reason: reason)
    }

    static func pokeRetryAllowed(window: QuotaWindow, attempt: Int) -> Bool {
        attempt < Quota.pokeAttemptLimit
            && window.usedPercent == 0
            && !countdownWindowActive(previous: nil, current: window)
    }

    /// Whether a running countdown started close enough to our request to be
    /// ours.
    ///
    /// Never call this on its own. For a five-hour window that has not started,
    /// Codex reports `resetsAt = observedAt + 5h`, so the reasoned-back start
    /// equals the moment of the read — and a poke sent moments earlier lands
    /// inside the tolerance, reporting `verified` for a window nothing started.
    /// It is only meaningful once `verifyPoke` has established that a countdown
    /// is genuinely running.
    static func pokeMatchesWindow(pokeAt: Int64, window: QuotaWindow) -> Bool {
        guard let resetsAt = window.resetsAt, let duration = window.windowDurationMins else {
            return false
        }
        let windowStart = resetsAt - duration * 60
        return abs(windowStart - pokeAt) <= Quota.pokeWindowStartToleranceSeconds
    }

    /// Re-decide an existing attribution on a later read.
    ///
    /// Deliberately never promotes `unverified`: without a running countdown
    /// there is nothing to attribute, and saying otherwise would claim credit
    /// for a window that never opened.
    static func normalizeLastPoke(_ poke: LastPoke?,
                                  countdownActive: Bool,
                                  window: QuotaWindow?) -> LastPoke? {
        guard var poke else { return nil }
        if countdownActive {
            let matches = window.map { pokeMatchesWindow(pokeAt: poke.at, window: $0) } ?? false
            poke.status = matches ? .verified : .notAttributed
        }
        return poke
    }

    /// `not-attributed` is usually the correct answer rather than a bug: real
    /// use often starts the window before the keeper gets there.
    static func pokeWarning(_ poke: LastPoke?, provider: QuotaProvider) -> String? {
        switch poke?.status {
        case .unverified:
            switch provider {
            case .codex:        return "Codex backend 每週倒數未啟動。"
            case .claude:       return "Claude backend 每週倒數未啟動。"
            case .antigravity:  return nil
            }
        case .notAttributed:
            return "已偵測到每週重置，但倒數不是由這次自動請求啟動。"
        default:
            return nil
        }
    }
}

enum MonitorHealth: String, Codable, Equatable {
    case healthy
    case waiting
    case stale
}

extension QuotaDomain {
    static func monitorHealth(lastCheckAt: Int64?, nowSeconds: Int64) -> MonitorHealth {
        guard let lastCheckAt else { return .waiting }
        return nowSeconds - lastCheckAt <= Quota.defaultIntervalSeconds * 3 ? .healthy : .stale
    }
}

// MARK: - Burn rate

extension BurnRate {
    /// Below this the sample is too small to divide by — the ratio needs the
    /// equivalent of one whole five-hour window spent before it means anything.
    /// An account left idle never reaches it, and "not enough usage to
    /// estimate" is the correct answer there rather than a bug.
    static let minSamplePercent: Double = 100

    mutating func observe(previous: RateLimitsSnapshot,
                          current: RateLimitsSnapshot,
                          provider: QuotaProvider) {
        guard let previousFiveHour = previous.fiveHourWindow(for: provider),
              let currentFiveHour = current.fiveHourWindow(for: provider),
              let previousWeekly = previous.weeklyWindow(for: provider),
              let currentWeekly = current.weeklyWindow(for: provider) else { return }
        observeWindows(previousFiveHour: previousFiveHour, currentFiveHour: currentFiveHour,
                       previousWeekly: previousWeekly, currentWeekly: currentWeekly)
    }

    /// Only rising usage inside a single five-hour window says anything about
    /// the ratio. A window rollover, a lagging read, or a weekly reset tells us
    /// nothing and is skipped rather than averaged in.
    mutating func observeWindows(previousFiveHour: QuotaWindow,
                                 currentFiveHour: QuotaWindow,
                                 previousWeekly: QuotaWindow,
                                 currentWeekly: QuotaWindow) {
        if QuotaDomain.resetAtMoved(previousFiveHour.resetsAt, currentFiveHour.resetsAt) { return }
        guard let previousFiveHourUsed = previousFiveHour.usedPercent,
              let currentFiveHourUsed = currentFiveHour.usedPercent else { return }
        let fiveHourDelta = currentFiveHourUsed - previousFiveHourUsed
        if fiveHourDelta <= 0 { return }

        guard let previousWeeklyUsed = previousWeekly.usedPercent,
              let currentWeeklyUsed = currentWeekly.usedPercent else { return }
        // A negative delta means the weekly window reset between the reads,
        // which says nothing about the ratio.
        let weeklyDelta = currentWeeklyUsed - previousWeeklyUsed
        if weeklyDelta < 0 { return }

        fiveHourDeltaTotal += fiveHourDelta
        weeklyDeltaTotal += weeklyDelta
    }

    /// The measured ratio, or `nil` while the sample is still too small.
    func weeklyPercentPerFullFiveHour() -> Double? {
        guard fiveHourDeltaTotal >= Self.minSamplePercent else { return nil }
        let ratio = weeklyDeltaTotal / fiveHourDeltaTotal * 100
        return ratio > 0 ? ratio : nil
    }
}

/// What a weekly allowance can still physically absorb before it resets.
struct WeeklyDeadline: Equatable {
    var maxBurnablePercent: Double
    /// Quota that will expire unused no matter how hard the account is worked.
    var doomedWastePercent: Double
    /// When intense use has to begin; equal to `now` means "start immediately".
    /// Meaningless when `doomedWastePercent` is above zero.
    var latestStartAt: Int64
}

extension QuotaDomain {
    /// Weekly quota is spent through five-hour windows, so the number of windows
    /// still reachable before the weekly reset — not the remaining wall-clock
    /// time — is what bounds how much can still be spent.
    ///
    /// Every reachable window counts as fully spendable. A five-hour window is
    /// an allowance, not a schedule: it can be drained in well under an hour by
    /// running work in parallel. Claiming quota is *doomed* has to hold against
    /// the fastest possible use, so the bound deliberately errs high.
    static func weeklyDeadline(now: Int64,
                               fiveHour: QuotaWindow?,
                               weekly: QuotaWindow,
                               burnPerWindow: Double) -> WeeklyDeadline? {
        guard burnPerWindow > 0 else { return nil }
        guard let usedPercent = weekly.usedPercent, let resetsAt = weekly.resetsAt else { return nil }
        let remainingSeconds = resetsAt - now
        guard remainingSeconds > 0 else { return nil }

        let windowSeconds = Quota.fiveHourWindowMins * 60
        let remainingPercent = max(100 - usedPercent, 0)

        // A five-hour countdown already running only offers what is left of the
        // current window; one that has not started leaves a whole window ready
        // to spend, with the next rollover a full window after use begins.
        let running = (fiveHour?.countdownActive ?? false) ? fiveHour : nil
        let currentFraction: Double
        let lastStartSeconds: Int64
        let rolloverCount: Double

        if let window = running {
            currentFraction = window.usedPercent.map { min(max((100 - $0) / 100, 0), 1) } ?? 1
            let rolloverAt = max(window.resetsAt.map { $0 - now } ?? 0, 0)
            if remainingSeconds > rolloverAt {
                let whole = (remainingSeconds - rolloverAt) / windowSeconds
                lastStartSeconds = rolloverAt + whole * windowSeconds
                rolloverCount = Double(whole) + 1
            } else {
                lastStartSeconds = 0
                rolloverCount = 0
            }
        } else {
            let whole = remainingSeconds / windowSeconds
            currentFraction = 1
            lastStartSeconds = whole * windowSeconds
            rolloverCount = Double(whole)
        }

        // When the remaining time is an exact multiple of the window length this
        // admits one window that opens as the weekly quota resets and can
        // therefore absorb nothing. That is deliberate: it errs toward
        // "reachable", the only safe direction for a claim that quota is
        // doomed. Do not "fix" it.
        let maxBurnablePercent = burnPerWindow * (currentFraction + rolloverCount)
        let doomedWastePercent = max(remainingPercent - maxBurnablePercent, 0)

        // The deadline counts only whole windows, so it must never be what
        // decides `doomed`: the two use different window bases and mixing them
        // misreports reachable quota as doomed.
        let neededWindows = max((remainingPercent / burnPerWindow - 1e-9).rounded(.up), 0)
        let leadSeconds = Int64(max(neededWindows - 1, 0)) * windowSeconds
        let latestStartAt = max(now + lastStartSeconds - leadSeconds, now)

        return WeeklyDeadline(maxBurnablePercent: maxBurnablePercent,
                              doomedWastePercent: doomedWastePercent,
                              latestStartAt: latestStartAt)
    }
}

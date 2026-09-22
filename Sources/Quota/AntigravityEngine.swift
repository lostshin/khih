import Foundation

struct AntigravityCheckOutcome: Equatable {
    var group: AntigravityGroup
    var outcome: CheckOutcome
}

struct AntigravityFiveHourOutcome: Equatable {
    var group: AntigravityGroup
    var outcome: FiveHourOutcome
}

extension QuotaEngine {
    /// Called only while the account's check.lock is held.
    func checkAntigravity(account: QuotaAccountConfig, backend: QuotaBackend,
                          mode: CheckMode, cancelled: () -> Bool) throws -> [AntigravityCheckOutcome] {
        var state = storage.loadState(for: account)
        let previous = state.snapshot
        let incoming = try backend.readRateLimits(for: account, observedAt: now())
        var current = QuotaDomain.reconcileSnapshot(previous: previous ?? RateLimitsSnapshot(), incoming: incoming).snapshot
        var results: [AntigravityCheckOutcome] = []
        for group in AntigravityGroup.allCases {
            if cancelled() { throw CodexError.cancelled }
            // Written per group, and from the call site rather than inside the
            // branches: a group that decides to do nothing is the answer the
            // keeper gives almost every time, and without a line for it there is
            // no way to tell afterwards that it looked at all. Putting it here
            // also means a branch added later cannot forget to report itself.
            let reading = QuotaEngine.formatWindows(fiveHour: group.window(in: current, weekly: false),
                                                    weekly: group.window(in: current, weekly: true))
            try? activity("\(group.name) \(reading)", for: account)
            do {
                let outcome = try checkGroup(group, account: account, backend: backend, mode: mode,
                                             previous: previous, current: &current, state: &state,
                                             cancelled: cancelled)
                // `.observe` judges nothing, so it says nothing — the same
                // place the provider path stops in that mode.
                if mode != .observe, let line = Self.activityLine(for: outcome) {
                    try? activity("\(group.name)：\(line)", for: account)
                }
                results.append(.init(group: group, outcome: outcome))
            } catch {
                try? activity("\(group.name)：\(error.localizedDescription)", for: account)
                results.append(.init(group: group, outcome: .failed(error.localizedDescription)))
            }
        }
        if mode != .dryRun {
            state.snapshot = current
            try storage.saveState(state, for: account)
        }
        return results
    }

    /// The sentences the provider path already writes, so a log covering every
    /// provider reads as one story rather than two vocabularies.
    ///
    /// Nil where the branch has written something better of its own: a sent
    /// request reports its verification status, and a thrown error is reported
    /// by the caller that caught it.
    static func activityLine(for outcome: CheckOutcome) -> String? {
        switch outcome {
        case .baseline:               return "已建立 baseline；第一次觀測不會消耗額度。"
        case .alreadyHandled:         return "這次每週 reset 已處理，不重送自動請求。"
        case .countdownAlreadyActive: return "每週新倒數已由其他使用行為啟動，不送出自動請求。"
        case .resetPending:           return "每週預定 reset time 已過，但 backend 尚未回報 reset；繼續等待。"
        case .skippedInUse:           return "這個帳號正在使用中；本次不送出自動請求，等下次檢查。"
        case .dryRunWouldPoke:        return "Dry run：每週 reset 已確認，本可送出最小請求。"
        case .awaitingFiveHourConfirmation: return FiveHourRefusal.awaitingConfirmation.activityMessage
        case .noReset:                return "未偵測到每週 reset；未送出自動請求。"
        case .poked, .failed, .skippedBusy, .rateLimited, .noBackend, .groups: return nil
        }
    }

    private func observeGroup(_ group: AntigravityGroup, previous: RateLimitsSnapshot?,
                              current: RateLimitsSnapshot, state: inout AccountState,
                              observeFiveHour: Bool = true) {
        var saved = state.antigravityGroups[group.rawValue] ?? AntigravityGroupState()
        if let previous,
           let oldFive = group.window(in: previous, weekly: false),
           let oldWeek = group.window(in: previous, weekly: true),
           let five = group.window(in: current, weekly: false),
           let week = group.window(in: current, weekly: true) {
            saved.burnRate.observeWindows(previousFiveHour: oldFive, currentFiveHour: five,
                                          previousWeekly: oldWeek, currentWeekly: week)
        }
        if observeFiveHour { saved.fiveHourStarter.observe(group.window(in: current, weekly: false)) }
        let weekly = group.window(in: current, weekly: true)
        saved.weeklyKeeper.countdownActive = weekly?.countdownActive ?? false
        if let poke = saved.weeklyKeeper.lastPoke {
            saved.weeklyKeeper.lastPoke = QuotaDomain.normalizeLastPoke(
                poke, countdownActive: saved.weeklyKeeper.countdownActive, window: weekly)
        }
        state.antigravityGroups[group.rawValue] = saved
    }

    private func checkGroup(_ group: AntigravityGroup, account: QuotaAccountConfig,
                            backend: QuotaBackend, mode: CheckMode, previous: RateLimitsSnapshot?,
                            current: inout RateLimitsSnapshot, state: inout AccountState,
                            cancelled: () -> Bool) throws -> CheckOutcome {
        observeGroup(group, previous: previous, current: current, state: &state)
        guard let window = group.window(in: current, weekly: true) else { return .noReset }
        guard let previous, let old = group.window(in: previous, weekly: true) else { return .baseline }
        var keeper = state.antigravityGroups[group.rawValue]!.weeklyKeeper
        if mode == .observe { return .noReset }
        let decision = QuotaDomain.detectReset(previous: old, current: window, nowSeconds: now(),
                                               pendingScheduledResetAt: keeper.pendingScheduledResetAt)
        let manual = mode == .manual && keeper.lastPoke == nil
            && QuotaDomain.pokeRetryAllowed(window: window, attempt: 0)
        let outcome: CheckOutcome
        if decision.resetObserved && decision.resetKey == keeper.lastHandledResetKey && !manual {
            keeper.pendingScheduledResetAt = nil
            outcome = .alreadyHandled
        } else if decision.resetObserved && decision.countdownActive {
            keeper.lastHandledResetKey = decision.resetKey
            keeper.pendingScheduledResetAt = nil
            outcome = .countdownAlreadyActive
        } else if decision.shouldPoke || manual {
            if mode == .live && state.antigravityGroups[group.rawValue]?.fiveHourStarter.automaticAttemptAt != nil {
                return .awaitingFiveHourConfirmation
            }
            if mode == .live && isAccountInUse(account) { return .skippedInUse }
            if mode == .dryRun { return .dryRunWouldPoke }
            if cancelled() { throw CodexError.cancelled }
            let target = PokeTarget.antigravityGroup(group, weekly: true)
            let poke = try backend.poke(for: account, target: target, expectedFingerprint: nil)
            let at = now()
            keeper.lastHandledResetKey = decision.resetKey ?? "manual:\(group.rawValue):\(window.resetsAt ?? window.observedAt)"
            keeper.pendingScheduledResetAt = nil
            keeper.lastPoke = LastPoke(at: at, model: poke.model, response: poke.response,
                                       accountFingerprint: nil, status: .unverified, attempt: 1, verifiedAt: nil)
            state.antigravityGroups[group.rawValue]!.weeklyKeeper = keeper
            state.snapshot = current
            try storage.saveState(state, for: account)
            let verification = verifyPoke(account: account, backend: backend, target: target,
                                          previousSnapshot: current, previousWindow: window,
                                          pokeAt: at, cancelled: cancelled)
            current = verification.latest
            keeper.lastPoke?.status = verification.status
            if verification.status != .unverified {
                keeper.lastPoke?.verifiedAt = group.window(in: current, weekly: true)?.observedAt
            }
            try? activity("\(group.name) 每週請求：\(verification.status.rawValue)（1/1，不重試）。", for: account)
            outcome = .poked(verification.status)
        } else if decision.resetPending {
            keeper.pendingScheduledResetAt = decision.scheduledResetAt
            outcome = .resetPending
        } else {
            outcome = .noReset
        }
        keeper.countdownActive = group.window(in: current, weekly: true)?.countdownActive ?? false
        state.antigravityGroups[group.rawValue]!.weeklyKeeper = keeper
        // Commit each group before beginning the next one.
        if mode != .dryRun {
            state.snapshot = current
            try storage.saveState(state, for: account)
        }
        return outcome
    }

    func startAntigravity(account: QuotaAccountConfig, backend: QuotaBackend,
                          trigger: FiveHourTrigger = .manual, cancelled: () -> Bool) throws -> [AntigravityFiveHourOutcome] {
        var state = storage.loadState(for: account)
        let previous = state.snapshot
        let incoming = try backend.readRateLimits(for: account, observedAt: now())
        guard previous != nil else {
            if trigger == .automatic {
                state.snapshot = incoming
                try storage.saveState(state, for: account)
            }
            try? activity(FiveHourRefusal.noBaseline.activityMessage, for: account)
            return AntigravityGroup.allCases.map { .init(group: $0, outcome: .refused(.noBaseline)) }
        }
        var current = QuotaDomain.reconcileSnapshot(previous: previous ?? RateLimitsSnapshot(), incoming: incoming).snapshot
        var results: [AntigravityFiveHourOutcome] = []
        for group in AntigravityGroup.allCases {
            if cancelled() { throw CodexError.cancelled }
            do {
                observeGroup(group, previous: previous, current: current, state: &state)
                if trigger == .automatic,
                   let weeklyPoke = state.antigravityGroups[group.rawValue]!.weeklyKeeper.lastPoke,
                   weeklyPoke.at >= now() - Quota.fiveHourWindowMins * 60,
                   weeklyPoke.at >= (state.antigravityGroups[group.rawValue]!.fiveHourStarter.confirmedResetAt ?? 0),
                   group.window(in: current, weekly: false)?.countdownActive != true {
                    state.antigravityGroups[group.rawValue]!.fiveHourStarter.automaticAttemptAt =
                        state.antigravityGroups[group.rawValue]!.fiveHourStarter.automaticAttemptAt ?? weeklyPoke.at
                }
                let starter = state.antigravityGroups[group.rawValue]!.fiveHourStarter
                let outcome: FiveHourOutcome
                if previous.flatMap({ group.window(in: $0, weekly: false) }) == nil {
                    outcome = .refused(.noBaseline)
                } else if let window = group.window(in: current, weekly: false) {
                    if window.usedPercent == nil {
                        outcome = .refused(.unknownUsage)
                    } else if window.countdownActive {
                        outcome = .refused(.alreadyRunning)
                    } else if trigger == .automatic && starter.automaticAttemptAt != nil {
                        outcome = .refused(.awaitingConfirmation)
                    } else if trigger == .automatic && isAccountInUse(account) {
                        outcome = .refused(.inUse)
                    } else if trigger == .automatic && (starter.confirmedResetAt ?? 0) > now() {
                        outcome = .refused(.alreadyRunning)
                    } else {
                        if cancelled() { throw CodexError.cancelled }
                        state.antigravityGroups[group.rawValue]!.fiveHourStarter.automaticAttemptAt = now()
                        state.snapshot = current
                        try storage.saveState(state, for: account)
                        let target = PokeTarget.antigravityGroup(group, weekly: false)
                        let poke = try backend.poke(for: account, target: target, expectedFingerprint: nil)
                        let at = now()
                        state.antigravityGroups[group.rawValue]!.fiveHourStarter.lastPoke = LastPoke(
                            at: at, model: poke.model, response: poke.response, accountFingerprint: nil,
                            status: .unverified, attempt: 1, verifiedAt: nil)
                        state.snapshot = current
                        try storage.saveState(state, for: account)
                        let verification = verifyPoke(account: account, backend: backend, target: target,
                                                      previousSnapshot: current, previousWindow: window,
                                                      pokeAt: at, cancelled: cancelled)
                        current = verification.latest
                        state.antigravityGroups[group.rawValue]!.fiveHourStarter.lastPoke?.status = verification.status
                        if verification.status != .unverified {
                            state.antigravityGroups[group.rawValue]!.fiveHourStarter.lastPoke?.verifiedAt =
                                group.window(in: current, weekly: false)?.observedAt
                        }
                        if verification.status != .unverified {
                            state.antigravityGroups[group.rawValue]!.fiveHourStarter.observe(group.window(in: current, weekly: false))
                        }
                        if trigger == .automatic && state.antigravityGroups[group.rawValue]!.fiveHourStarter.automaticAttemptAt != nil {
                            try? activity("\(group.name)：" + FiveHourRefusal.awaitingConfirmation.activityMessage, for: account)
                        }
                        outcome = .started(verification.status)
                    }
                } else {
                    outcome = .refused(.noUniqueWindow)
                }
                // Normalize keeper without collecting the same burn-rate sample twice.
                observeGroup(group, previous: nil, current: current, state: &state, observeFiveHour: false)
                state.snapshot = current
                try storage.saveState(state, for: account)
                try? activity("\(group.name) 5h：\(outcome)", for: account)
                results.append(.init(group: group, outcome: outcome))
            } catch {
                try? activity("\(group.name) 5h：\(error.localizedDescription)", for: account)
                results.append(.init(group: group, outcome: .failed(error.localizedDescription)))
            }
        }
        return results
    }
}

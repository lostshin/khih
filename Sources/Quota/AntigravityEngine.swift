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
            do {
                let outcome = try checkGroup(group, account: account, backend: backend, mode: mode,
                                             previous: previous, current: &current, state: &state,
                                             cancelled: cancelled)
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

    private func observeGroup(_ group: AntigravityGroup, previous: RateLimitsSnapshot?,
                              current: RateLimitsSnapshot, state: inout AccountState) {
        var saved = state.antigravityGroups[group.rawValue] ?? AntigravityGroupState()
        if let previous,
           let oldFive = group.window(in: previous, weekly: false),
           let oldWeek = group.window(in: previous, weekly: true),
           let five = group.window(in: current, weekly: false),
           let week = group.window(in: current, weekly: true) {
            saved.burnRate.observeWindows(previousFiveHour: oldFive, currentFiveHour: five,
                                          previousWeekly: oldWeek, currentWeekly: week)
        }
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
                          cancelled: () -> Bool) throws -> [AntigravityFiveHourOutcome] {
        var state = storage.loadState(for: account)
        let previous = state.snapshot
        let incoming = try backend.readRateLimits(for: account, observedAt: now())
        guard previous != nil else {
            try? activity(FiveHourRefusal.noBaseline.activityMessage, for: account)
            return AntigravityGroup.allCases.map { .init(group: $0, outcome: .refused(.noBaseline)) }
        }
        var current = QuotaDomain.reconcileSnapshot(previous: previous ?? RateLimitsSnapshot(), incoming: incoming).snapshot
        var results: [AntigravityFiveHourOutcome] = []
        for group in AntigravityGroup.allCases {
            if cancelled() { throw CodexError.cancelled }
            do {
                observeGroup(group, previous: previous, current: current, state: &state)
                let outcome: FiveHourOutcome
                if previous.flatMap({ group.window(in: $0, weekly: false) }) == nil {
                    outcome = .refused(.noBaseline)
                } else if let window = group.window(in: current, weekly: false) {
                    if window.usedPercent == nil {
                        outcome = .refused(.unknownUsage)
                    } else if window.countdownActive {
                        outcome = .refused(.alreadyRunning)
                    } else {
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
                        outcome = .started(verification.status)
                    }
                } else {
                    outcome = .refused(.noUniqueWindow)
                }
                // Normalize keeper without collecting the same burn-rate sample twice.
                observeGroup(group, previous: nil, current: current, state: &state)
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

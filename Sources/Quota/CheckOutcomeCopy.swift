import Foundation

extension CheckOutcome {
    var message: String {
        switch self {
        case .skippedBusy: return L10n.t("Not sent — another quota operation is running.")
        case .skippedInUse: return L10n.t("Not sent — this account is in use.")
        case .rateLimited: return L10n.t("Not connected — waiting for the rate-limit cooldown.")
        case .baseline: return L10n.t("Baseline saved. No request was sent.")
        case .alreadyHandled: return L10n.t("This weekly reset was already handled.")
        case .countdownAlreadyActive: return L10n.t("The weekly countdown is already running.")
        case .resetPending: return L10n.t("Waiting for the backend to confirm the weekly reset.")
        case .noReset: return L10n.t("No weekly reset detected. No request was sent.")
        case .noBackend: return L10n.t("Not sent — the command this account is read through is not installed.")
        case .dryRunWouldPoke: return L10n.t("Dry run: the weekly window could be started.")
        case .failed(let detail): return L10n.t("The check failed: \(detail)")
        case .poked(.verified): return L10n.t("A minimal request opened the new weekly window.")
        case .poked(.unverified): return L10n.t("A request was sent, but the backend has not confirmed the countdown.")
        case .poked(.notAttributed): return L10n.t("A weekly countdown is running, but something else started it.")
        case .groups(let groups): return groups.map { $0.group.name + ": " + $0.outcome.message }.joined(separator: "\n")
        }
    }
}

extension CheckOutcome {
    /// Whether this is the answer a check usually gives.
    ///
    /// A baseline, or nothing to do, is what a healthy account reports every
    /// time. Saying so on a card the user is already looking at adds nothing;
    /// what is worth a line is a refusal, a failure, or a request actually sent.
    var isRoutine: Bool {
        switch self {
        case .baseline, .noReset, .alreadyHandled, .countdownAlreadyActive: return true
        case .groups(let groups): return groups.allSatisfy { $0.outcome.isRoutine }
        default: return false
        }
    }
}

/// One line for a card that has just checked everything behind it.
///
/// The merged Codex cell stands for several accounts, so a click on it produces
/// several outcomes and the card has room for one line. Decided here, and
/// tested, rather than improvised where the notch happens to need it.
enum CheckSummaryCopy {
    static func line(for outcomes: [CheckOutcome]) -> String? {
        guard let first = outcomes.first else { return nil }
        // One account speaks for itself, routine or not.
        guard outcomes.count > 1 else { return first.message }
        let notable = outcomes.filter { !$0.isRoutine }
        guard let lead = notable.first else {
            return L10n.t("Checked \(outcomes.count) accounts — nothing to do.")
        }
        guard notable.count > 1 else { return lead.message }
        return lead.message + " " + L10n.t("(\(notable.count - 1) more)")
    }
}

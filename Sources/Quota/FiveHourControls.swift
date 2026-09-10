import SwiftUI

/// Starts one account's five-hour countdown.
///
/// The only control in Codenotch that spends quota rather than reading it, so
/// it has no keyboard shortcut: it should be pressed on purpose or not at all.
///
/// A glyph rather than a labelled button, matching the mute bell beside it. A
/// labelled one is what this started as, and on a row that already carries a
/// name, a link and a switch it left the name three characters wide — an
/// account called after a long relay address wrapped to six lines.
struct FiveHourButton: View {
    @ObservedObject var quota: QuotaController
    let providerID: String

    var body: some View {
        Button {
            Task { await quota.startFiveHour(providerID) }
        } label: {
            if quota.isRunning(providerID) {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: "timer")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.borderless)
        .disabled(quota.isBusy)
        .help(L10n.t("Start 5-hour window") + " — "
              + L10n.t("Sends one minimal request to open this account's five-hour window. It refuses without sending anything if a countdown is already running, if the account cannot be confirmed, or if there is no reading to compare against."))
    }
}

/// What happened last, and the record of everything before that.
///
/// A refusal is reported as plainly as a success: the gates exist to *not*
/// send requests, so the common case is the button doing nothing, and saying so
/// is the difference between a working safeguard and an app that looks broken.
struct FiveHourReport: View {
    @ObservedObject var quota: QuotaController
    let providerID: String

    @State private var isShowingActivity = false
    @State private var activity: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let result = quota.result(for: providerID) {
                Text(Self.text(for: result))
                    .foregroundStyle(Self.tint(for: result))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let outcome = quota.checkResults[providerID] {
                Text(outcome.message)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            DisclosureGroup(isExpanded: $isShowingActivity) {
                if activity.isEmpty {
                    Text(L10n.t("Nothing recorded for this account yet."))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        // Index, because the same line can legitimately repeat.
                        ForEach(Array(activity.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.top, 2)
                }
            } label: {
                Text(L10n.t("Recent quota activity"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .onChange(of: isShowingActivity) { _, expanded in
                if expanded { activity = quota.recentActivity(providerID) }
            }
            // A press appends to the log, so what is on screen is stale the
            // moment a result arrives.
            .onChange(of: quota.result(for: providerID)) { _, _ in
                if isShowingActivity { activity = quota.recentActivity(providerID) }
            }
        }
    }

    nonisolated static func text(for result: FiveHourResult) -> String {
        switch result {
        case .started(.verified):
            return L10n.t("Started — the backend confirmed this request opened the window.")
        case .started(.unverified):
            return L10n.t("Sent, but the backend has not confirmed a countdown yet.")
        case .started(.notAttributed):
            return L10n.t("A countdown is running, but it was not started by this request.")
        case .refused(.noBaseline):
            return L10n.t("Not sent — there is no earlier reading to compare against yet.")
        case .refused(.accountUnconfirmed):
            return L10n.t("Not sent — the signed-in account could not be confirmed.")
        case .refused(.noUniqueWindow):
            return L10n.t("Not sent — the backend did not report a single five-hour window.")
        case .refused(.unknownUsage):
            return L10n.t("Not sent — the five-hour usage came back unreadable.")
        case .refused(.noBackend):
            return L10n.t("Not sent — the command this account is read through is not installed.")
        case .refused(.alreadyRunning):
            return L10n.t("Not sent — a five-hour countdown is already running.")
        case .skippedBusy:
            return L10n.t("Not sent — another check is running for this account.")
        case .groups(let results):
            return results.map { "\($0.group.name): " + text(for: FiveHourResult($0.outcome)) }.joined(separator: "\n")
        case .failed(let detail):
            return L10n.t("The request could not be made: \(detail)")
        }
    }

    private static func tint(for result: FiveHourResult) -> HierarchicalShapeStyle {
        switch result {
        // A refusal is the safeguard working, not a fault — it stays quiet.
        case .refused, .skippedBusy: return .secondary
        default:                     return .primary
        }
    }
}

struct ManualCheckButton: View {
    @ObservedObject var quota: QuotaController
    let providerID: String

    var body: some View {
        Button {
            Task { await quota.check(providerID, mode: .manual) }
        } label: {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .disabled(quota.isBusy)
        .help(L10n.t("Check now") + " — " + L10n.t("When safe, sends a minimal request to start the weekly countdown. Refresh only reads usage."))
    }
}

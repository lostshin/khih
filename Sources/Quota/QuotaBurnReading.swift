import Foundation

/// Measured from reconciled engine snapshots, never inferred from a UI bar.
struct QuotaBurnReading: Codable, Equatable {
    var group: String?
    var observedAt: Int64
    var rate: BurnRate
    var fiveHour: QuotaWindow?
    var weekly: QuotaWindow?

    func lines(now: Int64) -> [String] {
        guard now - observedAt <= 900, now >= observedAt else {
            return [L10n.t("Burn-rate unavailable"), L10n.t("The reading is out of date.")]
        }
        guard let weekly, weekly.usedPercent != nil, let fiveHour, fiveHour.usedPercent != nil else {
            return [L10n.t("Burn-rate unavailable"), L10n.t("The usage is unknown.")]
        }
        guard let ratio = rate.weeklyPercentPerFullFiveHour() else {
            return [L10n.t("Burn-rate unavailable"), L10n.t("Not enough usage to estimate yet.")]
        }
        let value = String(format: "%.1f", ratio)
        let estimate = L10n.t("Full 5h ≈ \(value)% weekly")
        guard let deadline = QuotaDomain.weeklyDeadline(now: now, fiveHour: fiveHour, weekly: weekly,
                                                       burnPerWindow: ratio) else {
            return [estimate, L10n.t("Weekly deadline unavailable")]
        }
        if deadline.doomedWastePercent > 0 {
            return [estimate, L10n.t("At least \(String(format: "%.1f", deadline.doomedWastePercent))% may expire unused")]
        }
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.timeZone = TimeZone(identifier: "Asia/Taipei")
        formatter.dateFormat = "MM/dd HH:mm"
        return [estimate, L10n.t("Start by \(formatter.string(from: Date(timeIntervalSince1970: Double(deadline.latestStartAt)))) (Taiwan)")]
    }

    static func readings(from state: AccountState, provider: QuotaProvider) -> [QuotaBurnReading] {
        guard let snapshot = state.snapshot else { return [] }
        if provider == .antigravity {
            return AntigravityGroup.allCases.map { group in
                QuotaBurnReading(group: group.rawValue, observedAt: snapshot.observedAt,
                                 rate: state.antigravityGroups[group.rawValue]?.burnRate ?? BurnRate(),
                                 fiveHour: group.window(in: snapshot, weekly: false), weekly: group.window(in: snapshot, weekly: true))
            }
        }
        return [QuotaBurnReading(observedAt: snapshot.observedAt, rate: state.burnRate,
                                 fiveHour: snapshot.fiveHourWindow(for: provider), weekly: snapshot.weeklyWindow(for: provider))]
    }
}

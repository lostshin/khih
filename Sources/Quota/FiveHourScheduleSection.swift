import SwiftUI

/// Formatting shared by the row and the section, so one appointment never
/// reads two ways on the same page.
enum FiveHourScheduleFormat {
    static let zone = TimeZone(identifier: "Asia/Taipei")!

    /// Taipei, explicitly, and without the year: the locale and the zone are
    /// stated on the style rather than left to the environment, because this
    /// is called from a plain function as well as from a view.
    static func time(_ at: Int64) -> String {
        let style = Date.FormatStyle(locale: L10n.locale,
                                     calendar: Calendar(identifier: .gregorian),
                                     timeZone: zone)
            .month().day().hour().minute()
        return Date(timeIntervalSince1970: Double(at)).formatted(style)
    }

    /// An appointment defaults to an hour out, and to the next whole hour
    /// rather than to this minute plus sixty: nobody means 14:37.
    static func suggestion(from now: Date = Date()) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let hour = calendar.date(byAdding: .hour, value: 1, to: now) ?? now
        return calendar.date(bySetting: .minute, value: 0, of: hour) ?? hour
    }
}

/// One account's appointment, under its row.
///
/// A line of text at rest, because that is all there is to say for an account
/// with nothing scheduled, and this row already carries a name, three buttons
/// and a switch. The picker lives in a popover: it is the rarest control on
/// the page and the widest, and nobody needs to see four of them at once.
struct FiveHourScheduleRow: View {
    @ObservedObject var schedule: QuotaSchedule
    let accountID: String

    @State private var isEditing = false
    @State private var date = FiveHourScheduleFormat.suggestion()
    /// This row's own refusal. Kept here rather than on the schedule: one
    /// shared message put the same orange line under every account at once.
    @State private var error: String?

    private var appointment: Int64? { schedule.appointment(for: accountID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: appointment == nil ? "alarm" : "alarm.waves.left.and.right.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(appointment == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.tint))
                if let at = appointment {
                    Text(L10n.t("Scheduled — starts \(FiveHourScheduleFormat.time(at))"))
                    Button(L10n.t("Change…")) { beginEditing(from: at) }
                        .buttonStyle(.link)
                    Button(L10n.t("Cancel")) { error = schedule.set(nil, for: [accountID]) }
                        .buttonStyle(.link)
                } else {
                    Text(L10n.t("5-hour start: not scheduled"))
                        .foregroundStyle(.secondary)
                    Button(L10n.t("Schedule…")) { beginEditing(from: nil) }
                        .buttonStyle(.link)
                }
            }
            .popover(isPresented: $isEditing, arrowEdge: .bottom) {
                FiveHourSchedulePicker(date: $date,
                                       title: L10n.t("Start this account's 5-hour window")) {
                    // Stays open on a refusal, with the reason under the row: a
                    // popover that closes on a press that saved nothing is the
                    // same silence this control was rebuilt to remove.
                    error = schedule.set(Int64(date.timeIntervalSince1970), for: [accountID])
                    if error == nil { isEditing = false }
                }
                .frame(width: 280)
            }

            // The refusal belongs where the press was, not only at the foot of
            // the page: the picker is a popover and the section is a scroll away.
            if let error {
                Text(L10n.t("Could not save the schedule: \(error)"))
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Opens on the time already set, so "change" starts from what is there
    /// rather than from a suggestion that throws it away.
    private func beginEditing(from at: Int64?) {
        error = nil
        let existing = at.map { Date(timeIntervalSince1970: Double($0)) }
        date = (existing.map { $0 > Date() ? $0 : nil } ?? nil) ?? FiveHourScheduleFormat.suggestion()
        isEditing = true
    }
}

/// The picker itself, shared by the popover and the section below, so the two
/// cannot disagree about what a time means.
struct FiveHourSchedulePicker: View {
    @Binding var date: Date
    let title: String
    let confirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            // No lower bound on the picker: the only one worth having is "now",
            // which moves on every body pass, and a minimum that keeps moving
            // restarts the field's editing session under the typing. The time
            // is checked when the button is pressed instead, where a refusal
            // can say so.
            DatePicker(L10n.t("Taiwan time"), selection: $date,
                       displayedComponents: [.date, .hourAndMinute])
                .environment(\.timeZone, FiveHourScheduleFormat.zone)
            HStack {
                Spacer()
                Button(L10n.t("Schedule"), action: confirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .controlSize(.small)
    }
}

/// Everything at once, and the standing list of what is set.
///
/// The per-row lines say what one account is doing; this says what the whole
/// set is doing, which is the question someone with four accounts actually
/// has — and it is the only place that can answer it without scrolling.
struct FiveHourScheduleSection: View {
    @ObservedObject var quota: QuotaController
    @ObservedObject var schedule: QuotaSchedule
    /// On-screen names, by provider id, as the rows above show them. Passed in
    /// rather than read off the account: an account's stored label is the name
    /// it was added under, which for Claude and Antigravity is an email
    /// address.
    let names: [String: String]

    @State private var date = FiveHourScheduleFormat.suggestion()
    @State private var error: String?

    private var targets: [QuotaAccountConfig] { quota.fiveHourTargets }

    /// Only appointments whose account is still here, newest last.
    private var scheduled: [(account: QuotaAccountConfig, at: Int64)] {
        targets.compactMap { account in
            schedule.appointment(for: account.id).map { (account, $0) }
        }
        .sorted { $0.at < $1.at }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.t("Start 5-hour windows once"))
                .font(.headline)

            HStack {
                DatePicker(L10n.t("Taiwan time"), selection: $date,
                           displayedComponents: [.date, .hourAndMinute])
                    .environment(\.timeZone, FiveHourScheduleFormat.zone)
                    .fixedSize()
                Button(L10n.t("Apply to all")) {
                    error = schedule.set(Int64(date.timeIntervalSince1970), for: targets.map(\.id))
                }
                .disabled(targets.isEmpty)
            }

            // The confirmation the whole section exists to give. A list, not a
            // count: "3 accounts scheduled" is the one answer that still needs
            // a follow-up question.
            if scheduled.isEmpty {
                Text(L10n.t("Nothing is scheduled."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(scheduled, id: \.account.id) { entry in
                        Text(L10n.t("\(name(for: entry.account)) — starts \(FiveHourScheduleFormat.time(entry.at))"))
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button(L10n.t("Cancel all")) {
                        error = schedule.set(nil, for: scheduled.map(\.account.id))
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }

            Text(L10n.t("Each account is started on its own time, once. Khih must stay open; it waits while asleep or busy and cancels if more than one hour late."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error {
                Text(L10n.t("Could not save the schedule: \(error)"))
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .controlSize(.small)
        // The window can stay open for hours, by which time a default worked
        // out when it opened is a time in the past. Only a stale default is
        // replaced — a time the user picked is left where they put it.
        .onAppear { if date <= Date() { date = FiveHourScheduleFormat.suggestion() } }
    }

    private func name(for account: QuotaAccountConfig) -> String {
        names[account.providerID] ?? account.displayLabel
    }
}

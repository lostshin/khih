import SwiftUI

struct FiveHourScheduleSection: View {
    @ObservedObject var quota: QuotaController
    @ObservedObject var schedule: QuotaSchedule
    @State private var date = Date().addingTimeInterval(3600)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.t("Start 5-hour windows once"))
                .font(.headline)
            DatePicker(L10n.t("Taiwan time"), selection: $date, in: Date()...,
                       displayedComponents: [.date, .hourAndMinute])
                .environment(\.timeZone, TimeZone(identifier: "Asia/Taipei")!)
            HStack {
                Button(L10n.t("Schedule")) { schedule.set(Int64(date.timeIntervalSince1970)) }
                    .disabled(quota.isBusy)
                if let at = schedule.settings.fiveHourStartAt {
                    Text(Date(timeIntervalSince1970: Double(at)), format: .dateTime
                        .month().day().hour().minute().timeZone(.specificName(.short)))
                        .environment(\.timeZone, TimeZone(identifier: "Asia/Taipei")!)
                        .font(.caption)
                    Button(L10n.t("Cancel schedule")) { schedule.set(nil) }
                }
            }
            Text(L10n.t("Runs once for all enabled accounts. Codenotch must stay open; it waits while asleep or busy and cancels if more than one hour late."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = schedule.error {
                Text(L10n.t("Could not save the schedule: \(error)"))
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .controlSize(.small)
    }
}

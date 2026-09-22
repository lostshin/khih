import Foundation
import Combine

/// One durable appointment per account. The timer consults memory only;
/// clearing the file is the commit that permits sending, so a restart cannot
/// replay one.
///
/// Per account rather than one appointment for everybody: the five-hour
/// windows they open are separate, and so are the hours someone wants them
/// opened at. "Every account at the same time" is then just the same
/// timestamp written to each of them, not a second mechanism to keep in step
/// with this one.
@MainActor
final class QuotaSchedule: ObservableObject {
    @Published private(set) var settings: QuotaSettings
    private let save: (QuotaSettings) throws -> Void
    static let grace: Int64 = 3600

    /// What a tick found: which accounts are to be started now, and which were
    /// too late to start and have been dropped. Both are empty on an ordinary
    /// tick, which is almost all of them.
    struct Due: Equatable {
        var fired: [String] = []
        var expired: [String] = []
        /// The file could not be written, so nothing was cleared and — since
        /// clearing is what stops a restart replaying an appointment — nothing
        /// may be sent either.
        var saveFailed = false

        var isEmpty: Bool { fired.isEmpty && expired.isEmpty && !saveFailed }
    }

    init(settings: QuotaSettings, save: @escaping (QuotaSettings) throws -> Void) {
        self.settings = settings
        self.save = save
    }

    func appointment(for accountID: String) -> Int64? { settings.fiveHourStartAt[accountID] }

    var appointments: [String: Int64] { settings.fiveHourStartAt }

    /// Saves, clears, or refuses an appointment for each of `accountIDs`.
    ///
    /// A time that has already passed is refused rather than stored: the
    /// one-second tick would take it on its very next pass, so the row would
    /// never get to show it and the press would read as a button that did
    /// nothing. Clearing skips the check — `takeDue` clears through here too.
    ///
    /// All of them or none: one write, so a press that covers four accounts
    /// cannot leave two of them scheduled and two not.
    ///
    /// Hands back the reason it did not happen, and nil when it did. Returned
    /// rather than published: one shared error property painted the same
    /// orange line under every account's row at once, and cleared itself the
    /// moment an unrelated appointment fired.
    @discardableResult
    func set(_ at: Int64?, for accountIDs: [String],
             now: Int64 = Int64(Date().timeIntervalSince1970)) -> String? {
        guard !accountIDs.isEmpty else { return L10n.t("there is no account to schedule") }
        if let at, at <= now { return L10n.t("that time has already passed") }
        var next = settings
        for id in accountIDs {
            if let at { next.fiveHourStartAt[id] = at } else { next.fiveHourStartAt[id] = nil }
        }
        return commit(next)
    }

    /// Everything due, in one pass.
    ///
    /// `targets` is the set of accounts a start could actually be sent for —
    /// enabled, and shown. An appointment for anything else simply waits; it
    /// still expires on time, which is what eventually clears the key for an
    /// account that has been removed.
    ///
    /// Expiry is decided before busyness on purpose: an appointment more than
    /// an hour late is cancelled whether or not the engine is free, because
    /// "not sent late" is the promise, and a busy engine must not turn it into
    /// "sent much later".
    func takeDue(now: Int64, busy: Bool, targets: Set<String>) -> Due {
        var due = Due()
        var next = settings
        for (id, at) in settings.fiveHourStartAt.sorted(by: { $0.key < $1.key }) where now >= at {
            if now - at > Self.grace {
                due.expired.append(id)
                next.fiveHourStartAt[id] = nil
            } else if !busy, targets.contains(id) {
                due.fired.append(id)
                next.fiveHourStartAt[id] = nil
            }
        }
        guard !due.isEmpty else { return due }
        guard commit(next) == nil else { return Due(saveFailed: true) }
        return due
    }

    private func commit(_ next: QuotaSettings) -> String? {
        do {
            try save(next)
            settings = next
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

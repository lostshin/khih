import Foundation
import Combine

/// A single durable appointment. The timer consults memory only; clearing the
/// file is the commit that permits sending, so a restart cannot replay it.
@MainActor
final class QuotaSchedule: ObservableObject {
    @Published private(set) var settings: QuotaSettings
    @Published private(set) var error: String?
    private let save: (QuotaSettings) throws -> Void
    static let grace: Int64 = 3600

    enum Due: Equatable { case waiting, expired, fire, failed }

    init(settings: QuotaSettings, save: @escaping (QuotaSettings) throws -> Void) {
        self.settings = settings
        self.save = save
    }

    @discardableResult
    func set(_ at: Int64?) -> Bool {
        let next = QuotaSettings(version: 1, fiveHourStartAt: at)
        do {
            try save(next)
            settings = next
            error = nil
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func takeDue(now: Int64, busy: Bool) -> Due {
        guard let at = settings.fiveHourStartAt, now >= at else { return .waiting }
        if now - at > Self.grace { return set(nil) ? .expired : .failed }
        guard !busy else { return .waiting }
        return set(nil) ? .fire : .failed
    }
}

import SwiftUI

private struct QuotaDetailsShowRemainingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var quotaDetailsShowRemaining: Bool {
        get { self[QuotaDetailsShowRemainingKey.self] }
        set { self[QuotaDetailsShowRemainingKey.self] = newValue }
    }
}

/// Presentation only: the provider evidence and usage-based warning colors stay intact.
enum QuotaDetailDisplay {
    static func fraction(_ window: LimitWindow, remaining: Bool) -> Double? {
        guard let used = window.usedFraction else { return nil }
        let fraction = min(max(used, 0), 1)
        return remaining ? 1 - fraction : fraction
    }

    static func summary(_ window: LimitWindow, remaining: Bool, locale: Locale = L10n.locale) -> String {
        guard let used = window.usedFraction else { return window.summary(locale: locale) }
        let halves = Percent.halves(for: used)
        return remaining ? L10n.t("\(halves.left)% remaining", locale: locale)
            : L10n.t("\(halves.used)% used", locale: locale)
    }
}

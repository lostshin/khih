import Foundation

/// A serialized, read-only observer of Google's official CLI.
actor AntigravityCLIProvider: UsageProvider {
    nonisolated let id = "gemini"
    nonisolated let displayName = "Antigravity"
    nonisolated let glyph = ProviderGlyph.antigravity
    nonisolated let minimumRefreshInterval: TimeInterval = 300
    nonisolated let fetchDeadline: TimeInterval = 140
    nonisolated var signInRoute: SignInRoute { .guidance(L10n.t("Sign in using the official agy CLI.")) }

    private let read: () throws -> RateLimitsSnapshot

    init(read: @escaping () throws -> RateLimitsSnapshot = {
        try AntigravityClient.shared.read(cancelled: { Task.isCancelled })
    }) {
        self.read = read
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        try Task.checkCancellation()
        let snapshot = try read()
        let windows = snapshot.buckets.flatMap { bucket in
            [("five-hour", bucket.primary), ("weekly", bucket.secondary)].compactMap { key, window -> LimitWindow? in
                guard let window else { return nil }
                return LimitWindow(id: "\(bucket.limitId):\(key)", group: bucket.limitId == "antigravity:gemini" ? L10n.t("Gemini Models") : L10n.t("Claude and GPT models"),
                                   label: key == "weekly" ? L10n.t("Weekly Limit") : L10n.t("5-hour Limit"),
                                   usedFraction: window.usedPercent.map { $0 / 100 },
                                   resetsAt: window.resetsAt.map { Date(timeIntervalSince1970: Double($0)) },
                                   duration: window.windowDurationMins.map { Double($0 * 60) })
            }
        }
        return ProviderSnapshot(id: id, displayName: displayName, glyph: glyph,
                                fidelity: .official, status: .ok, windows: windows,
                                headlineID: Self.headlineID(in: windows))
    }

    /// The Gemini five-hour window, which is the one being spent right now.
    ///
    /// Taking the most-used window instead put the weekly figure on the ring
    /// almost always: a seven-day window has had seven days to fill up, so it
    /// outranks a five-hour one that has just reset. The ring then answered a
    /// question nobody asked while the number that decides whether the next
    /// prompt goes through sat two rows down in the card.
    static func headlineID(in windows: [LimitWindow]) -> String? {
        if let gemini = windows.first(where: { $0.id == "antigravity:gemini:five-hour" }) {
            return gemini.id
        }
        // Only when the official CLI stopped reporting that window at all.
        return windows.filter { $0.usedFraction != nil }.max { $0.usedFraction! < $1.usedFraction! }?.id
    }
}

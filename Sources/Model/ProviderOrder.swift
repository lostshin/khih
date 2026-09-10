import Foundation

/// The rule that turns a remembered order into a real one.
///
/// The awkward part is not applying an order, it is that the set of providers is
/// not fixed: Claude Code contributes one per `~/.claude-<slug>` found at launch,
/// so an id can appear on a Mac that has never seen it and vanish from one that
/// has. A stored order is a preference to reconcile, never an authority.
enum ProviderOrder {
    /// A runtime's inventory can arrive alphabetically on every poll. Keep its
    /// existing cells in place and append newly loaded models.
    ///
    /// `activeCodexID` is the account the `codex` command is signed in to, and
    /// has no default: both the store and the notch merge, and a default would
    /// let one of them quietly compute a different headline from the other.
    static func cells(from snapshots: [ProviderSnapshot],
                      keeping previous: [ProviderSnapshot],
                      activeCodexID: String?) -> [ProviderSnapshot] {
        let expanded = snapshots.flatMap { snapshot in
            let cells = snapshot.notchSnapshots
            return snapshot.kind == .localRuntime
                ? arrange(cells, by: previous.map(\.id), id: \.id) : cells
        }
        let codex = expanded.filter { CodexProfile.isCodex(providerID: $0.id) }
        guard codex.count > 1 else { return expanded }
        let grouped = codexCell(codex, activeID: activeCodexID)
        var emitted = false
        return expanded.compactMap { snapshot in
            guard codex.contains(where: { $0.id == snapshot.id }) else { return snapshot }
            guard !emitted else { return nil }
            emitted = true
            return grouped
        }
    }

    private static let fiveHours: TimeInterval = 5 * 3600

    private static func codexCell(_ accounts: [ProviderSnapshot], activeID: String?) -> ProviderSnapshot {
        let windows = accounts.flatMap { account -> [LimitWindow] in
            // Says which group the ring is quoting. Without it the cell shows
            // one number over several accounts and no way to tell whose.
            let name = account.id == activeID
                ? account.displayName + " · " + L10n.t("In use") : account.displayName
            let title = account.status == .ok ? name
                : name + " · " + (account.statusMessage ?? L10n.t("No reading"))
            guard !account.windows.isEmpty else {
                var window = LimitWindow(id: "\(account.id):unavailable", group: title, label: L10n.t("No reading"))
                window.groupID = account.id
                window.sourceProviderID = account.providerID
                return [window]
            }
            return account.windows.map { window in
                var copied = LimitWindow(id: "\(account.id):\(window.id)", group: title, label: window.label,
                            usedFraction: window.usedFraction, remaining: window.remaining,
                            used: window.used, resetsAt: window.resetsAt, duration: window.duration)
                copied.groupID = account.id
                copied.sourceProviderID = account.providerID
                copied.burnReading = window.burnReading
                return copied
            }
        }
        let status: ProviderStatus
        if let oldest = accounts.compactMap({ $0.status.staleSince }).min() {
            status = .stale(since: oldest)
        } else if accounts.contains(where: { $0.status != .ok }) {
            status = .error(L10n.t("Some accounts have no current reading."))
        } else {
            status = .ok
        }
        return ProviderSnapshot(id: "codex:accounts", displayName: "Codex", glyph: accounts[0].glyph,
                                fidelity: .official, status: status, windows: windows,
                                headlineID: headlineID(accounts, activeID: activeID, windows: windows),
                                block: accounts.compactMap(\.block).first,
                                sourceProviderIDs: accounts.flatMap(\.refreshProviderIDs))
    }

    /// The five-hour window of the account being spent.
    ///
    /// The rule used to be "whichever window is closest to full", which is what
    /// `UsageModel`'s own note about headlines warns against: across four
    /// accounts and three window lengths it settled on whichever account had
    /// exhausted its session, so the ring read 0% while the account actually in
    /// use was untouched. A headline has to answer one question, and the
    /// question is whether the next prompt goes through.
    private static func headlineID(_ accounts: [ProviderSnapshot], activeID: String?,
                                   windows: [LimitWindow]) -> String? {
        func fiveHour(of account: ProviderSnapshot) -> String? {
            account.windows.first { $0.duration == fiveHours }.map { "\(account.id):\($0.id)" }
        }
        if let activeID, let active = accounts.first(where: { $0.id == activeID }),
           let id = fiveHour(of: active) { return id }
        // Signed in to an account this app does not manage, or that account
        // reports no session window — a plan billed by the month does not have
        // one. Naming an account is still better than naming none.
        if let id = accounts.lazy.compactMap(fiveHour).first { return id }
        return windows.filter { $0.usedFraction != nil }.max { $0.usedFraction! < $1.usedFraction! }?.id
    }

    /// `items` in the user's order, then everything the order has never seen, in
    /// the order it arrived in.
    ///
    /// Idempotent, which is what lets the store re-apply it to an already-sorted
    /// `snapshots` without the rings shuffling.
    static func arrange<T>(_ items: [T], by order: [String], id: (T) -> String) -> [T] {
        guard !order.isEmpty else { return items }

        var remaining = items
        var arranged: [T] = []
        for providerID in order {
            // A stored id no provider claims is the ordinary case, not
            // corruption: a `~/.claude-work` that is not on this Mac today.
            guard let index = remaining.firstIndex(where: { id($0) == providerID })
            else { continue }
            arranged.append(remaining.remove(at: index))
        }
        // Appended rather than dropped: a provider added by a new version has to
        // turn up somewhere, and the end is the one position that is never a lie
        // about what the user chose.
        return arranged + remaining
    }

    /// Where a provider goes when it is switched back on: after the ones already
    /// connected, rather than back to wherever it used to sit.
    ///
    /// Restoring its old place would make off/on a perfect round trip, which is
    /// tempting — but it lets a row that was not on screen outrank one the user
    /// deliberately dragged to the top while it was away. Landing at the end is
    /// never a surprise, and it is one drag to fix.
    static func joiningConnected(_ id: String, in order: [String],
                                 isConnected: (String) -> Bool) -> [String] {
        var rest = order.filter { $0 != id }
        // Nothing connected at all makes it the first, not the last.
        let insertAt = rest.lastIndex(where: isConnected).map { $0 + 1 } ?? 0
        rest.insert(id, at: insertAt)
        return rest
    }

    /// The order to remember, given the order now on screen.
    ///
    /// Ids that are remembered but not visible are kept, at the end: a Claude
    /// profile whose directory is not on this Mac today must not lose its place
    /// because an unrelated row moved.
    static func remember(_ visible: [String], keeping remembered: [String]) -> [String] {
        visible + remembered.filter { !visible.contains($0) }
    }
}

import Foundation

/// Shared by the read-only provider and quota engine. State is only read here;
/// the engine remains the sole writer of its transaction file.
final class ClaudeCooldown: @unchecked Sendable {
    private let lock = NSLock()
    private let archive: UsageArchive
    private let providerID: String
    private let persistedUntil: () -> Int64?
    /// Asked once, and the answer kept even when it is nil — doubly optional so
    /// "asked, and there was none" stays distinguishable from "not asked yet".
    /// Reading it means decoding `accounts.json` and a `state.json`, and it is
    /// only ever load-bearing at launch: the engine mirrors every later
    /// deadline into `archive` (`QuotaEngine.readRateLimits`/`poke`) before it
    /// writes `checkCooldownUntil`, so from then on the archive cannot lag.
    private var persisted: Int64??

    init(archive: UsageArchive, providerID: String = "claude",
         persistedUntil: @escaping () -> Int64? = { nil }) {
        self.archive = archive
        self.providerID = providerID
        self.persistedUntil = persistedUntil
    }

    /// The archived deadline, still in the future as of `now`, in the engine's
    /// own units — the one place `Date` crosses back into `Int64`.
    private func archived(now: Int64) -> Int64? {
        archive.loadBackoffUntil(providerID: providerID,
                                 now: Date(timeIntervalSince1970: Double(now)))
            .map { Int64($0.timeIntervalSince1970) }
    }

    func deadline(now: Int64) -> Int64? {
        lock.lock(); defer { lock.unlock() }
        if persisted == nil { persisted = .some(persistedUntil()) }
        return [archived(now: now), persisted ?? nil].compactMap { $0 }.filter { $0 > now }.max()
    }

    func record(until: Int64, now: Int64) {
        lock.lock(); defer { lock.unlock() }
        let previous = archived(now: now) ?? 0
        archive.saveBackoffUntil(Date(timeIntervalSince1970: Double(max(previous, until))),
                                 providerID: providerID)
    }

    /// Clears an expired deadline, and only an expired one: a response already
    /// in flight must not clear a newer 429's. Reads before writing because
    /// every successful read lands here and almost none of them have a key to
    /// clear — 429 is the rare case.
    func succeeded(now: Int64) {
        lock.lock(); defer { lock.unlock() }
        guard archive.hasBackoffUntil(providerID: providerID), archived(now: now) == nil else { return }
        archive.saveBackoffUntil(nil, providerID: providerID)
    }
}

import Foundation

/// Which account the `codex` command is signed in to right now.
///
/// Every managed account gets its own `CODEX_HOME`, which is the whole of the
/// isolation between them — and the reason none of them is "current" in its own
/// right. The account actually being spent is whichever one `~/.codex` holds,
/// and the only honest way to say which that is, is to compare the signed-in
/// account: a card's label is a display name the user can edit and proves
/// nothing.
///
/// Uses the digest the quota engine already computes for its own fingerprints,
/// so the two can never drift into disagreeing about what counts as the same
/// account. Only the account id is read; the token beside it in the same file
/// is never touched, logged, or stored.
final class CodexActiveAccount {
    private struct Cached {
        let stamp: Date?
        let ids: [String]
        let result: String?
    }

    private let systemHome: URL
    private let fileManager: FileManager
    private var cache: Cached?

    init(systemHome: URL = CodexActiveAccount.defaultSystemHome,
         fileManager: FileManager = .default) {
        self.systemHome = systemHome
        self.fileManager = fileManager
    }

    /// `CODEX_HOME` first, because a shell that sets it means it.
    static var defaultSystemHome: URL {
        let path = ProcessInfo.processInfo.environment["CODEX_HOME"]?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard !path.isEmpty else { return CodexProfile.default().configDirectory }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    /// The id of the profile signed in to the same account as `~/.codex`, or
    /// nil when that account is not one of these — a login the app does not
    /// manage, or no login at all.
    ///
    /// Cheap enough to call on every poll: the answer only changes when that
    /// file is rewritten, and account switchers replace it whole, so its
    /// modification date is a sufficient key. Watching the descriptor instead
    /// would follow the file that was replaced rather than the path.
    func providerID(among profiles: [CodexProfile]) -> String? {
        let stamp = modifiedAt()
        let ids = profiles.map(\.id)
        if let cache, cache.stamp == stamp, cache.ids == ids { return cache.result }
        let result = resolve(profiles)
        cache = Cached(stamp: stamp, ids: ids, result: result)
        return result
    }

    private func resolve(_ profiles: [CodexProfile]) -> String? {
        guard let active = CodexFingerprint.of(codexHome: systemHome) else { return nil }
        return profiles.first { CodexFingerprint.of(codexHome: $0.configDirectory) == active }?.id
    }

    private func modifiedAt() -> Date? {
        let path = systemHome.appendingPathComponent("auth.json").path
        return (try? fileManager.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }
}

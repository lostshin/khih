import Foundation
import os

/// One Claude account's limits, read from whichever source can answer without
/// interrupting anyone.
///
/// Two sources, in order. `claude "/usage"` is asked first where the binary is
/// installed: it reports the same figures off a credential Claude Code already
/// holds, and needs no keychain access from this app — which matters because
/// Claude Code files a new keychain item on every token rotation, so a grant
/// the user gives against the old item is good for about an hour. Where that
/// fails or Claude Code is not installed, the usage endpoint is called directly
/// with the OAuth token from the keychain, exactly as before.
///
/// One instance per `ClaudeProfile`: a work login kept under `~/.claude-work`
/// has its own token, its own limits and its own ring, and this reads exactly
/// one of them.
///
/// The numbers are Anthropic's, so this is `.official` — the tooltip shows them
/// unqualified. The endpoint is not a published API, though, so every failure
/// path degrades to a status the UI can render honestly rather than to a guess.
actor ClaudeOAuthProvider: UsageProvider {
    nonisolated let profile: ClaudeProfile
    nonisolated let id: String
    nonisolated let displayName: String
    nonisolated let glyph = ProviderGlyph.claude
    /// This profile's token, behind its own cache — see `ClaudeKeychain`.
    nonisolated private let keychain: ClaudeKeychain

    private let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private let session: URLSession
    /// When the token runs out, as of the last keychain read — expired or not.
    ///
    /// Read-only bookkeeping for `ClaudeTokenRefresher`, which has to know how
    /// long is left *before* deciding to do anything. Kept here because this is
    /// already the one place that reads the item, so exposing it costs no extra
    /// keychain traffic and no extra prompt.
    private(set) var tokenExpiry: Date?
    private let cooldown: ClaudeCooldown
    private let now: @Sendable () -> Int64
    /// How this profile's token is obtained. Injected for the same reason
    /// `session` is: the token path had no tests, which is how a back-off that
    /// never expired shipped. Production reads through this profile's own
    /// `ClaudeKeychain`; a test substitutes a fake credential source instead.
    private let loadCredentials: @Sendable () throws -> ClaudeCredentials

    /// How the CLI is asked, or nil where Claude Code is not installed. Nil is
    /// resolved once at init rather than per refresh: the answer only changes
    /// when someone installs or removes Claude Code, and the app is relaunched
    /// either way.
    nonisolated private let cli: ClaudeUsageCLI?
    /// A subprocess is far more expensive than an HTTP call, and `UsageStore`
    /// polls every 60s while a session is busy. The windows barely move in a
    /// minute, so the last answer is reused in between.
    private let cliRefreshInterval: TimeInterval
    private var lastCLIWindows: (windows: [LimitWindow], at: Date)?
    /// Stamped on every spawn, successful or not. Without it a Claude Code that
    /// is installed but signed out costs a process on every tick, forever.
    private var lastCLIAttempt: Date?

    /// How `claude-code/<version>` is obtained — see `ClaudeVersion`.
    private let readUserAgent: @Sendable () -> String?
    /// Resolved once, on the first request that needs it, and kept even when
    /// the answer is nil. Doubly optional so "asked, and there is none" is
    /// distinguishable from "not asked yet": a Mac without Claude Code
    /// installed must not pay for a spawn on every poll.
    private var resolvedUserAgent: String??

    init(profile: ClaudeProfile = .default(),
         session: URLSession = .shared,
         archive: UsageArchive = UsageArchive(),
         loadCredentials: (@Sendable () throws -> ClaudeCredentials)? = nil,
         cooldown: ClaudeCooldown? = nil,
         now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) },
         cli: ClaudeUsageCLI? = ClaudeUsageCLI.locate(),
         cliRefreshInterval: TimeInterval = 5 * 60,
         readUserAgent: @escaping @Sendable () -> String? = { ClaudeVersion.installed() }) {
        self.readUserAgent = readUserAgent
        self.cli = cli
        self.cliRefreshInterval = cliRefreshInterval
        self.profile = profile
        self.id = profile.id
        self.displayName = profile.displayName
        let keychain = ClaudeKeychain.shared(profile: profile)
        self.keychain = keychain
        self.loadCredentials = loadCredentials ?? { try keychain.load() }
        self.session = session
        self.cooldown = cooldown ?? ClaudeCooldown(archive: archive, providerID: profile.id)
        self.now = now
    }

    func fetchSnapshotAfterReconnect() async throws -> ProviderSnapshot {
        try checkCooldown()
        lastCLIWindows = nil
        lastCLIAttempt = nil
        return try await fetchSnapshot()
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        // Ahead of the CLI on purpose, which is the reverse of what this used
        // to do. Back then the app sent a Khih user agent and the CLI sent
        // `claude-code/<version>`, so the two sat in different buckets and a
        // 429 on one said nothing about the other. Both now present the same
        // agent, so a back-off almost certainly covers the CLI as well:
        // spawning it here could not fill the ring and could extend the very
        // deadline it is trying to outrun. The last good reading is not lost —
        // `UsageStore.degraded` re-shows it until `staleAfter`.
        try checkCooldown()
        if let windows = await cliWindows() {
            return ProviderSnapshot(
                id: id,
                displayName: displayName,
                glyph: glyph,
                fidelity: .official,
                status: .ok,
                windows: windows,
                headlineID: "session"
            )
        }
        do {
            let snapshot = try await fetch(retryingOnUnauthorized: true)
            cooldown.succeeded(now: now())
            return snapshot
        } catch UsageProviderError.needsAuth {
            // The held copy goes, so the next tick re-reads. Backing off is
            // `CredentialCache`'s job and it already does it correctly: it
            // waits on the item's modification date rather than on a clock, so
            // a token Claude Code has just rotated is picked up at once. A
            // second timer here could only ever be wrong — and was: it stamped
            // itself on every failed tick, so its own window never expired and
            // the keychain was never read again.
            throw UsageProviderError.needsAuth
        } catch UsageProviderError.credentialExpired {
            throw UsageProviderError.credentialExpired
        } catch let error as UsageProviderError {
            if case .rateLimited(let retryAfter) = error {
                let moment = now()
                cooldown.record(until: moment + Int64(retryAfter), now: moment)
            }
            throw error
        }
    }

    /// What `claude "/usage"` last said, or nil to mean "use the token path".
    ///
    /// Deliberately cannot throw. Every way the CLI can fail — not installed,
    /// signed out, wording changed, wedged and killed — is a reason to ask the
    /// endpoint instead, not a reason to fail the refresh. The endpoint's
    /// errors are also the ones `UsageStore` knows how to word, and a status
    /// invented here would be a second vocabulary saying the same things.
    /// Spawning `claude --version` off the actor, the way a `/usage` read
    /// goes: it is a subprocess either way.
    private func userAgent() async -> String? {
        if let resolvedUserAgent { return resolvedUserAgent }
        let read = readUserAgent
        let value = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { continuation.resume(returning: read()) }
        }
        resolvedUserAgent = value
        return value
    }

    private func cliWindows() async -> [LimitWindow]? {
        guard let cli else { return nil }
        let now = Date()

        // A cached answer is only reused inside the interval. Past it the
        // reading is stale, and handing it back as `.ok` would be claiming a
        // freshness it does not have.
        if let last = lastCLIWindows, now.timeIntervalSince(last.at) < cliRefreshInterval {
            return last.windows
        }
        if let lastCLIAttempt, now.timeIntervalSince(lastCLIAttempt) < cliRefreshInterval {
            return nil
        }
        lastCLIAttempt = now

        do {
            let windows = try await cli.read(profile: profile, now: now)
            lastCLIWindows = (windows, now)
            Log.usage.debug("\(self.id, privacy: .public): read \(windows.count) windows from claude /usage")
            return windows
        } catch {
            Log.usage.debug("\(self.id, privacy: .public): claude /usage did not answer, falling back to the token")
            return nil
        }
    }

    private func fetch(retryingOnUnauthorized: Bool) async throws -> ProviderSnapshot {
        try checkCooldown()
        let token = try currentToken()

        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        // Without this the request is rate-limited far harder than Claude
        // Code's own — see `ClaudeVersion`. Left off entirely when the version
        // cannot be read, rather than sent as a guess.
        if let agent = await userAgent() {
            request.setValue(agent, forHTTPHeaderField: "User-Agent")
        }
        request.timeoutInterval = 15

        try checkCooldown()
        Log.usage.debug("GET /api/oauth/usage")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        Log.usage.debug("usage endpoint answered \(status)")

        if status == 401 || status == 403 {
            // Rejected but unexpired: the held copy is wrong, which is what
            // signing into a different account looks like from here.
            keychain.forgetCached()
            // The cached token went stale mid-flight; re-read once in case
            // Claude Code has refreshed it since.
            if retryingOnUnauthorized {
                return try await fetch(retryingOnUnauthorized: false)
            }
            throw UsageProviderError.needsAuth
        }
        if status == 429 {
            let moment = now()
            throw UsageProviderError.rateLimited(retryAfter: Double(
                ClaudeBackend.cooldown(from: response as? HTTPURLResponse, now: moment) - moment))
        }
        guard (200..<300).contains(status) else {
            throw UsageProviderError.badResponse(status: status)
        }

        let payload = try Self.decoder.decode(UsageResponse.self, from: data)
        return ProviderSnapshot(
            id: id,
            displayName: displayName,
            glyph: glyph,
            fidelity: .official,
            status: .ok,
            windows: payload.limitWindows(),
            headlineID: "session"
        )
    }

    private func currentToken() throws -> String {
        // No local back-off lock here — `CredentialCache`, behind `keychain`,
        // already does this correctly: it waits on the item's modification
        // date rather than on a clock, so a token Claude Code has just
        // rotated is picked up at once. A second timer here could only ever
        // be wrong, and was — it stamped itself on every failed tick, so its
        // own window never expired and the keychain was never read again.
        let fresh = try loadCredentials()
        Log.usage.debug("\(self.id, privacy: .public): read keychain token, expires \(fresh.expiresAt, privacy: .public)")
        tokenExpiry = fresh.expiresAt
        // Expired is not signed out. Claude Code rotates this token whenever it
        // runs, and this app deliberately does not — minting one would mean
        // writing a credential it does not own, and racing the owner for it. So
        // after a machine restart the token is usually stale until Claude Code
        // is next used, and the honest thing is to keep showing the last reading
        // with its age rather than demand a sign-in that is not needed.
        guard !fresh.isExpired else { throw UsageProviderError.credentialExpired }
        return fresh.accessToken
    }

    nonisolated var signInRoute: SignInRoute {
        // Names the command for a profile, because that is the only way to
        // reach it: plain `claude` signs the default one in, not this.
        .guidance(L10n.t("Run `\(profile.signInCommand)` once — it signs in and is what these readings come from. Use /login there to change account."))
    }

    nonisolated func authorizeCredential() throws { try keychain.authorize() }

    nonisolated func forgetCachedCredential() { keychain.forgetCached() }

    /// Read the keychain again, ignoring anything held, and report the expiry.
    ///
    /// The after-check for `ClaudeTokenRefresher`, and the only caller that
    /// should want it: everything else is served from the cache precisely so
    /// that the keychain — and its prompt — is touched as rarely as possible.
    func reloadTokenExpiry() -> Date? {
        keychain.forgetCached()
        guard let fresh = try? loadCredentials() else { return nil }
        tokenExpiry = fresh.expiresAt
        return fresh.expiresAt
    }

    nonisolated func account() -> ProviderAccount? {
        let manageURL = URL(string: "https://claude.ai/settings/usage")

        // Settings must not be the thing that raises a keychain prompt. Where
        // the CLI can answer, the readings never touch the token, and opening
        // Settings to see whose account a ring is for would have been the one
        // thing that did — the exact interruption this provider now avoids.
        //
        // The trade is the plan name for the address, and the address is the
        // more useful half: it says *which* account, which is the only question
        // two Claude rings ever raise, and the token could never answer it.
        if cli != nil {
            guard let address = profile.signedInAddress() else { return nil }
            return ProviderAccount(
                label: address,
                plan: nil,   // Claude Code's own config does not name the plan
                source: profile.sourceName,
                manageURL: manageURL
            )
        }

        // Settings reads only metadata already held in memory.
        let credentials = keychain.held
        return ProviderAccount(
            label: profile.signedInAddress(),
            plan: credentials?.subscriptionType,
            source: profile.sourceName,
            manageURL: manageURL
        )
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        // Timestamps come back with fractional seconds and an offset, which
        // `.iso8601` alone will not parse.
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = withFraction.date(from: text) ?? plain.date(from: text) { return date }
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unparseable date \(text)")
            )
        }
        return decoder
    }()

    private func checkCooldown() throws {
        let moment = now()
        if let until = cooldown.deadline(now: moment) {
            throw UsageProviderError.rateLimited(retryAfter: Double(until - moment))
        }
    }

}

/// The shape of `GET /api/oauth/usage`.
struct UsageResponse: Decodable {
    struct Limit: Decodable {
        let kind: String
        let percent: Double
        let resetsAt: Date?
        /// What the window is scoped to, where it is scoped to anything.
        ///
        /// The model-specific weekly window comes back as `weekly_scoped` for
        /// *every* model, so the kind alone can only ever say "Scoped". The
        /// model it actually meters is named here and nowhere else — which is
        /// also why this is read rather than the model being hardcoded: the
        /// window follows whichever model the plan scopes, and has already been
        /// Opus once.
        let scope: Scope?

        /// The window's own name: the model where the response names one, the
        /// kind's own wording otherwise.
        var windowLabel: String {
            let named = scope?.model?.displayName?.trimmingCharacters(in: .whitespaces)
            if let named, !named.isEmpty { return named }
            return UsageResponse.label(forKind: kind)
        }

        private enum CodingKeys: String, CodingKey {
            case kind, percent, resetsAt, scope
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            kind = try container.decode(String.self, forKey: .kind)
            percent = try container.decode(Double.self, forKey: .percent)
            resetsAt = try container.decodeIfPresent(Date.self, forKey: .resetsAt)
            // Tolerated rather than required. Everything above is the reading
            // itself and must decode; the scope is only a nicer name for it, so
            // a shape change here falls back to the kind's wording instead of
            // costing the whole response.
            scope = try? container.decodeIfPresent(Scope.self, forKey: .scope)
        }
    }

    struct Scope: Decodable {
        struct Model: Decodable { let displayName: String? }
        let model: Model?
    }
    struct Window: Decodable {
        let utilization: Double
        let resetsAt: Date?
    }

    let limits: [Limit]?
    let fiveHour: Window?
    let sevenDay: Window?

    /// `limits` is the forward-compatible shape — it grows new kinds as
    /// Anthropic adds them — so it is preferred, with the two named windows as
    /// a fallback for older responses.
    func limitWindows() -> [LimitWindow] {
        var windows = (limits ?? []).compactMap { limit -> LimitWindow? in
            guard let resetsAt = limit.resetsAt else { return nil }
            return LimitWindow(
                id: limit.kind,
                label: limit.windowLabel,
                usedFraction: limit.percent / 100,
                resetsAt: resetsAt,
                duration: Self.duration(forKind: limit.kind)
            )
        }

        // The named windows are merged in rather than used only as a fallback.
        // Claude Code's own schema says an entry is "present only while the API
        // reports it and its resets_at has not passed", so a window that has
        // just rolled over disappears from `limits` while `five_hour` still
        // carries it. Relying on the array alone loses the session exactly when
        // it resets, which is when someone is most likely to be looking.
        func merge(_ window: UsageResponse.Window?, id: String, label: String) {
            guard let window, let resetsAt = window.resetsAt,
                  !windows.contains(where: { $0.id == id })
            else { return }
            windows.append(LimitWindow(id: id, label: label,
                                       usedFraction: window.utilization / 100,
                                       resetsAt: resetsAt, duration: Self.duration(forKind: id)))
        }
        merge(fiveHour, id: "session", label: Self.label(forKind: "session"))
        merge(sevenDay, id: "weekly_all", label: Self.label(forKind: "weekly_all"))

        return windows.sorted(by: UsageResponse.displayOrder)
    }

    static func duration(forKind kind: String) -> TimeInterval? {
        if kind == "session" { return 5 * 3600 }
        if kind.hasPrefix("weekly_") { return 7 * 86400 }
        return nil
    }

    /// The frame's wording, for the kinds it drew.
    ///
    /// The two windows every plan has are named after the length they measure,
    /// the same way Codex and Antigravity name theirs. They used to be called
    /// "Current session" and "All models", which described Claude's own
    /// vocabulary rather than the card's: three providers stacked in one notch
    /// read as three different measurements when only the wording differed,
    /// and "session" collided with the live-process list drawn below.
    static func label(forKind kind: String) -> String {
        switch kind {
        // Fixed at five hours by `duration(forKind:)`, so the length is not a
        // guess. Shares the interpolated key Codex already uses.
        case "session":       return L10n.t("\(5)h limit")
        case "weekly_all":    return L10n.t("Weekly limit")
        case "weekly_opus":   return L10n.t("Opus")
        case "weekly_sonnet": return L10n.t("Sonnet")
        // Only reached when the response names no model for the window, which
        // is the one case where there is nothing better to call it.
        case "weekly_scoped", "scoped": return L10n.t("Scoped")
        default:
            return kind
                .replacingOccurrences(of: "weekly_", with: "")
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
        }
    }

    /// Session first, then the weekly windows — the order the frame shows.
    /// Shared with `ClaudeUsageCLI`, which reads the same windows off the CLI
    /// and must hand them over in the same order.
    static func displayOrder(_ a: LimitWindow, _ b: LimitWindow) -> Bool {
        func rank(_ id: String) -> Int {
            if id == "session" { return 0 }
            if id == "weekly_all" { return 1 }
            return 2
        }
        let (ra, rb) = (rank(a.id), rank(b.id))
        return ra == rb ? a.id < b.id : ra < rb
    }
}

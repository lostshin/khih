import Foundation

/// The minimal request that opens a Claude window.
///
/// Every flag is here to make the request as small and as inert as it can be
/// while still counting: no tools, no MCP, no session on disk, and a budget
/// low enough that a misbehaving model cannot spend more than a rounding
/// error. Changing the model or the prompt changes what the request costs and
/// what it proves, so neither is configurable.
enum ClaudePoke {
    static let model = "claude-haiku-4-5-20251001"
    static let prompt = "Reply with exactly: OK"
    static let defaultTimeout: TimeInterval = 120

    static func arguments(model: String = model, prompt: String = prompt) -> [String] {
        ["-p", prompt,
         "--model", model,
         "--safe-mode",
         "--tools", "",
         "--setting-sources", "",
         "--strict-mcp-config",
         "--no-session-persistence",
         "--max-budget-usd", "0.05"]
    }

    /// The variables that would send the request somewhere else — and bill it
    /// somewhere else, against a quota this is not trying to measure.
    ///
    /// Removed rather than overwritten: an empty `ANTHROPIC_API_KEY` is not
    /// reliably the same as an absent one, and the point is for the CLI to fall
    /// back to the subscription login it already holds.
    static let clearedEnvironment = [
        "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL",
        "ANTHROPIC_MODEL", "ANTHROPIC_CUSTOM_HEADERS",
        "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX",
        "AWS_BEARER_TOKEN_BEDROCK", "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY",
        "AWS_SESSION_TOKEN", "AWS_PROFILE", "AWS_REGION",
        "GOOGLE_APPLICATION_CREDENTIALS", "CLOUD_ML_REGION", "ANTHROPIC_VERTEX_PROJECT_ID"
    ]

    static func environment(from base: [String: String]) -> [String: String] {
        var environment = base
        for key in clearedEnvironment { environment.removeValue(forKey: key) }
        return environment
    }
}

/// Reading and poking one Claude account.
///
/// This account is the system's single Claude Code login, so unlike Codex
/// there is no per-account home to isolate: what makes it *this* account is the
/// fingerprint, checked before the request and again inside it.
struct ClaudeBackend: QuotaBackend {
    /// Where the readings come from. Injected whole so tests never need a
    /// network, a keychain or a login.
    var readUsage: (Int64) throws -> RateLimitsSnapshot
    var readFingerprint: () -> String?
    var sendPoke: (String?) throws -> QuotaPokeResult
    /// Claude Code's own `/usage`. See `QuotaBackend.readObservation`: not the
    /// time-series, and never allowed to decide anything.
    var readUsageWithoutCredential: ((Int64) throws -> RateLimitsSnapshot)?

    func accountFingerprint(for account: QuotaAccountConfig) -> String? {
        readFingerprint()
    }

    func readRateLimits(for account: QuotaAccountConfig,
                        observedAt: Int64) throws -> RateLimitsSnapshot {
        try readUsage(observedAt)
    }

    func readObservation(for account: QuotaAccountConfig,
                         observedAt: Int64) throws -> RateLimitsSnapshot? {
        try readUsageWithoutCredential?(observedAt)
    }

    func poke(for account: QuotaAccountConfig, target: PokeTarget,
              expectedFingerprint: String?) throws -> QuotaPokeResult {
        try sendPoke(expectedFingerprint)
    }
}

// MARK: - The live wiring

extension ClaudeBackend {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    /// How long to stand off when a 429 arrives without usable guidance.
    /// A quarter of an hour: long enough to leave the bucket, short enough that
    /// a reading is never more than one window stale because of it.
    static let blindCooldown: Int64 = 15 * 60

    /// `Retry-After` as an absolute second, or nil where the header says
    /// nothing usable. `Retry-After: 0` has been seen from this endpoint and
    /// means "immediately", which is exactly what must not happen — a zero or
    /// negative delay is treated as no guidance at all.
    static func retryAt(from response: HTTPURLResponse?, now: Int64) -> Int64? {
        guard let raw = response?.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if let seconds = Int64(raw) { return seconds > 0 ? now + seconds : nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: raw) else { return nil }
        let at = Int64(date.timeIntervalSince1970)
        return at > now ? at : nil
    }

    /// The cooldown a 429 earns: the endpoint's own guidance where it gives
    /// any, and a fixed quarter of an hour where it does not.
    static func cooldown(from response: HTTPURLResponse?, now: Int64) -> Int64 {
        retryAt(from: response, now: now) ?? (now + blindCooldown)
    }

    /// Blocking on purpose. The engine runs one account at a time on a
    /// background queue and holds a lock for the whole transaction; an async
    /// hop in the middle of it would buy nothing and complicate the ordering
    /// the safety argument rests on.
    static func fetch(token: String, userAgent: String?, session: URLSession,
                      observedAt: Int64) throws -> RateLimitsSnapshot {
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        // The same header, and the same reason, as `ClaudeOAuthProvider` — see
        // `ClaudeVersion`. The engine polls less often than the ring does, but
        // it is the half that spends quota, and being throttled out of a
        // reading is what makes a weekly window quietly go unguarded.
        if let userAgent { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        request.timeoutInterval = 20

        var payload: Data?
        var httpResponse: HTTPURLResponse?
        var failure: Error?
        let done = DispatchSemaphore(value: 0)
        session.dataTask(with: request) { data, response, error in
            payload = data
            httpResponse = response as? HTTPURLResponse
            failure = error
            done.signal()
        }.resume()
        done.wait()

        if let failure { throw failure }
        let status = httpResponse?.statusCode ?? 0
        if status == 429 {
            throw QuotaBackendError.rateLimited(
                retryAt: cooldown(from: httpResponse, now: observedAt))
        }
        if status == 401 || status == 403 {
            throw ClaudeUsageError.needsAuth
        }
        guard (200..<300).contains(status) else {
            throw ClaudeUsageError.badResponse(status: status)
        }
        guard let payload else { throw ClaudeUsageError.unreadable }
        return try ClaudeUsage.snapshot(from: payload, observedAt: observedAt)
    }

    /// The account the CLI is signed in as. Nil whenever that cannot be
    /// established, which the engine treats as a refusal to poke rather than as
    /// a changed account.
    static func fingerprint(binary: URL, timeout: TimeInterval = 20, cancelled: () -> Bool = { false }) -> String? {
        guard let data = try? QuotaProcess.run(binary: binary,
                                               arguments: ["auth", "status", "--json"],
                                               environment: ProcessInfo.processInfo.environment,
                                               timeout: timeout, cancelled: cancelled)
        else { return nil }
        return ClaudeIdentity.fingerprint(fromStatus: data)
    }

    static func send(binary: URL, expectedFingerprint: String?,
                     timeout: TimeInterval = ClaudePoke.defaultTimeout, cancelled: () -> Bool = { false }) throws -> QuotaPokeResult {
        // Re-checked immediately before spending anything: the signed-in
        // account can change between the decision to poke and the poke.
        let observed = fingerprint(binary: binary, cancelled: cancelled)
        if let expectedFingerprint, observed != expectedFingerprint {
            throw CodexError.fingerprintChanged
        }
        let data = try QuotaProcess.run(
            binary: binary,
            arguments: ClaudePoke.arguments(),
            environment: ClaudePoke.environment(from: ProcessInfo.processInfo.environment),
            timeout: timeout, cancelled: cancelled)
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return QuotaPokeResult(model: ClaudePoke.model,
                               response: text,
                               accountFingerprint: observed)
    }
}

/// The token, from wherever this Mac keeps it.
///
/// The keychain is the real store; the file is what a Claude Code that could
/// not reach the keychain falls back to, so it is read only after the keychain
/// has failed. Neither path logs, returns or stores the token itself.
enum ClaudeToken {
    static func fileURL(home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> URL {
        home.appendingPathComponent(".claude/.credentials.json")
    }

    static func fromFile(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        // Both spellings have been seen; the nested one is what Claude Code
        // writes today.
        let nested = root["claudeAiOauth"] as? [String: Any] ?? root
        let token = (nested["accessToken"] ?? nested["access_token"]) as? String
        guard let token, !token.isEmpty else { return nil }
        return token
    }

    static func load(readCredential: () throws -> ClaudeCredentials = ClaudeCredentials.load,
                     readFile: () -> String? = { fromFile(at: fileURL()) }) throws -> String {
        do {
            let credential = try readCredential()
            guard !credential.accessToken.isEmpty else { throw ClaudeUsageError.needsAuth }
            guard !credential.isExpired else { throw ClaudeUsageError.credentialExpired }
            return credential.accessToken
        } catch UsageProviderError.accessDenied {
            throw ClaudeUsageError.accessDenied
        } catch UsageProviderError.credentialExpired {
            throw ClaudeUsageError.credentialExpired
        } catch UsageProviderError.needsAuth {
            // The file belongs to CLI installations without a keychain item.
            // A refused or expired keychain credential must not fall back to it.
            guard let token = readFile(), !token.isEmpty else { throw ClaudeUsageError.needsAuth }
            return token
        }
    }
}

/// A value worked out once, on whichever thread first needs it.
///
/// Used for the user agent, which costs a subprocess. Resolving it eagerly
/// would put that spawn on the main thread at launch, and resolving it per
/// request would pay for it every five minutes forever.
final class Lazily<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private let make: () -> Value
    private var value: Value?

    init(_ make: @escaping () -> Value) { self.make = make }

    func get() -> Value {
        lock.lock(); defer { lock.unlock() }
        if let value { return value }
        let made = make()
        value = made
        return made
    }
}

extension ClaudeBackend {
    /// The backend as the app runs it. Nil where Claude Code is not installed:
    /// the fingerprint and the request both go through the command, and
    /// without it there is no way to establish which account a reading belongs
    /// to — which is a gate, not an inconvenience.
    static func live(session: URLSession = .shared,
                     cancelled: @escaping () -> Bool = { false },
                     userAgent: Lazily<String?> = Lazily({ ClaudeVersion.installed() }),
                     usageCLI: Lazily<ClaudeUsageCLI?> = Lazily({ ClaudeUsageCLI.locate() }))
    -> ClaudeBackend? {
        guard let binary = ClaudeCLI.standalone() else { return nil }
        return ClaudeBackend(
            readUsage: { observedAt in
                let token = try ClaudeToken.load()
                do {
                    return try fetch(token: token, userAgent: userAgent.get(),
                                     session: session, observedAt: observedAt)
                } catch ClaudeUsageError.needsAuth {
                    ClaudeCredentials.forgetCached()
                    throw ClaudeUsageError.needsAuth
                }
            },
            readFingerprint: { fingerprint(binary: binary, cancelled: cancelled) },
            sendPoke: { expected in try send(binary: binary, expectedFingerprint: expected, cancelled: cancelled) },
            // Resolved lazily for the same reason the user agent is: locating
            // it touches the filesystem, and the common path never needs it.
            readUsageWithoutCredential: { observedAt in
                guard let cli = usageCLI.get() else { throw ClaudeUsageError.needsAuth }
                let text = try cli.output(ClaudeProfile.default())
                return try ClaudeUsage.observation(
                    rows: ClaudeUsageCLI.rows(text, now: Date(timeIntervalSince1970: Double(observedAt))),
                    observedAt: observedAt)
            })
    }
}

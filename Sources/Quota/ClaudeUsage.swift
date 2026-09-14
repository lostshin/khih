import Foundation

/// Turning `GET /api/oauth/usage` into the engine's own snapshot.
///
/// Deliberately not reused from `ClaudeOAuthProvider`: that path produces
/// `LimitWindow`, which carries a `Date` and a fraction. The safety logic
/// compares whole epoch seconds with a two-second tolerance and reasons a
/// window's start back from its reset, and a value that has been through a
/// `Double` fraction and a `Date` cannot be trusted to survive that intact.
enum ClaudeUsage {
    /// A timestamp as this endpoint has been seen to spell it: whole seconds,
    /// milliseconds, or RFC 3339 with or without fractional seconds.
    ///
    /// The two numeric forms are told apart by magnitude — seconds stopped
    /// being ten digits in 2001 and will not be eleven until 5138, so anything
    /// past that many digits is milliseconds.
    static func epochSeconds(from value: Any?) -> Int64? {
        switch value {
        case let number as NSNumber:
            let raw = number.doubleValue
            guard raw.isFinite, raw > 0 else { return nil }
            // Truncated, not rounded: half a second into a second is still
            // that second, and the safety comparisons work in whole ones.
            return Int64(raw > 1e11 ? raw / 1000 : raw)
        case let text as String:
            if let parsed = Double(text) {
                return epochSeconds(from: NSNumber(value: parsed))
            }
            let withFraction = ISO8601DateFormatter()
            withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            guard let date = withFraction.date(from: text) ?? plain.date(from: text) else { return nil }
            return Int64(date.timeIntervalSince1970)
        default:
            return nil
        }
    }

    /// A percentage the endpoint reports on a 0–100 scale. Out of range means
    /// the field is not what this parser thinks it is, and a wrong number here
    /// feeds a decision to spend quota — so it is refused rather than clamped.
    static func percent(from value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        let raw = number.doubleValue
        guard raw.isFinite, raw >= 0, raw <= 100 else { return nil }
        return raw
    }

    /// One `{utilization, resets_at}` object, under either of the two spellings
    /// the response uses for the reading itself.
    static func window(from object: [String: Any], observedAt: Int64,
                       durationMins: Int64) -> QuotaWindow? {
        let used = percent(from: object["utilization"]) ?? percent(from: object["percent"])
        guard let used else { return nil }
        return QuotaWindow(usedPercent: used,
                           windowDurationMins: durationMins,
                           resetsAt: epochSeconds(from: object["resets_at"] ?? object["resetsAt"]),
                           observedAt: observedAt)
    }

    /// Every window this account has, as buckets the engine's own selectors
    /// understand.
    ///
    /// A window a subscriber always has, absent from the response, is
    /// materialised at zero with no reset. That is not an invention: Claude
    /// Code's schema drops an entry the moment its reset passes, so absence is
    /// how a rolled-over window looks, and dropping the bucket instead would
    /// read as "this plan has no weekly limit". `checkAccount` is what decides
    /// whether an absent window has really reset — it takes two readings and a
    /// scheduled reset already past, never one.
    static func snapshot(from data: Data, observedAt: Int64) throws -> RateLimitsSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeUsageError.unreadable
        }

        let buckets = Quota.claudeWindows.compactMap { spec -> RateLimitBucket? in
            let object = root[spec.key] as? [String: Any]
            let read = object.flatMap {
                window(from: $0, observedAt: observedAt, durationMins: spec.durationMins)
            }
            guard let read else {
                guard spec.alwaysPresent else { return nil }
                return RateLimitBucket(
                    limitId: Quota.claudeLimitPrefix + spec.key,
                    limitName: spec.title,
                    primary: QuotaWindow(usedPercent: 0,
                                         windowDurationMins: spec.durationMins,
                                         resetsAt: nil,
                                         observedAt: observedAt))
            }
            return RateLimitBucket(limitId: Quota.claudeLimitPrefix + spec.key,
                                   limitName: spec.title,
                                   primary: read)
        }

        return RateLimitsSnapshot(observedAt: observedAt, buckets: buckets)
    }
}

enum ClaudeUsageError: LocalizedError, Equatable {
    /// The body was not the JSON object this parser expects.
    case unreadable
    /// The credential could not be read, or the endpoint rejected it.
    case needsAuth
    case badResponse(status: Int)
    case accessDenied
    case credentialExpired

    var errorDescription: String? {
        switch self {
        case .unreadable: return L10n.t("Claude returned an unreadable usage response. The previous reading is kept.")
        case .needsAuth: return L10n.t("Claude sign-in is unavailable or was rejected. Sign in using the official Claude Code CLI, then check again.")
        case .accessDenied: return L10n.t("Claude login access was denied. Choose Allow access to Claude sign-in in Settings, then check again.")
        case .credentialExpired: return L10n.t("Claude login has expired. Use the official Claude Code CLI to renew the login, then check again.")
        case .badResponse(let status): return L10n.t("Claude usage request failed (HTTP \(status)). Please try again later.")
        }
    }
}

/// The account the CLI is signed in as, as its own fingerprint.
///
/// `claude auth status --json` is the only place the identity is stated
/// without going near the token. Org and address together, because either
/// alone changes for reasons that are not a different account.
enum ClaudeIdentity {
    static func fingerprint(fromStatus data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        // The fields have been seen both at the root and under `account`.
        let account = root["account"] as? [String: Any] ?? root
        let org = (account["orgId"] ?? account["organizationId"]
                   ?? account["org_id"] ?? account["organization_id"]) as? String
        let email = (account["email"] ?? account["emailAddress"]
                     ?? account["email_address"]) as? String
        guard let org, let email, !org.isEmpty, !email.isEmpty else { return nil }
        // Hashed, and only the first twelve hex digits kept — the same shape
        // Codex's fingerprint takes, and for the same reason: enough to notice
        // the account changed, never enough to say who it is.
        return QuotaFingerprint.short(of: org + email)
    }
}

import Foundation

/// Constants copied verbatim from the Rust engine (`src/domain.rs`).
///
/// These are not tuning knobs. The jitter and tolerance values below are the
/// difference between correctly refusing to spend quota and silently burning
/// it, and every one of them was derived from observed backend behaviour —
/// see the comments on the functions in `QuotaDomain.swift` that use them.
enum Quota {
    static let defaultIntervalSeconds: Int64 = 300
    static let fiveHourWindowMins: Int64 = 300
    static let weeklyWindowMins: Int64 = 10_080
    static let pokeAttemptLimit = 3
    static let pokeVerificationAttempts = 3
    static let pokeWindowStartToleranceSeconds: Int64 = 60
    /// `resetsAt` jitters by about a second between reads, so timestamps are
    /// never compared for strict equality.
    static let resetAtJitterSeconds: Int64 = 2
    static let defaultModel = "gpt-5.6-luna"
    static let defaultPrompt =
        "Use the shell tool to run /usr/bin/true exactly once. Then reply only: OK"
    static let claudeLimitPrefix = "claude:"
    static let claudeFiveHourKey = "five_hour"
    static let claudeWeeklyKey = "seven_day"
}

/// Which upstream service an account is monitored against.
enum QuotaProvider: String, Codable, Equatable, CaseIterable {
    case codex
    case claude
    case antigravity = "google-antigravity"

    var displayName: String {
        switch self {
        case .codex:        return "Codex"
        case .claude:       return "Claude Code"
        case .antigravity:  return "Google Antigravity"
        }
    }
}

/// One window the Claude usage endpoint can report.
///
/// The API sends no duration, so `durationMins` is our definition; it is what
/// `pokeMatchesWindow` uses to reason backwards to a window start.
struct ClaudeWindowSpec {
    let key: String
    let durationMins: Int64
    let title: String
    /// A subscriber always has this window, so an absent field means the
    /// window has reset — not that the plan lacks it.
    let alwaysPresent: Bool
}

extension Quota {
    /// Every Claude window, in display order. Only `seven_day` may ever be poked.
    static let claudeWindows: [ClaudeWindowSpec] = [
        ClaudeWindowSpec(key: claudeFiveHourKey, durationMins: fiveHourWindowMins,
                         title: "5 小時限額", alwaysPresent: true),
        ClaudeWindowSpec(key: claudeWeeklyKey, durationMins: weeklyWindowMins,
                         title: "每週限額", alwaysPresent: true),
        ClaudeWindowSpec(key: "seven_day_opus", durationMins: weeklyWindowMins,
                         title: "每週 · Opus", alwaysPresent: false),
        ClaudeWindowSpec(key: "seven_day_sonnet", durationMins: weeklyWindowMins,
                         title: "每週 · Sonnet", alwaysPresent: false),
        ClaudeWindowSpec(key: "seven_day_oauth_apps", durationMins: weeklyWindowMins,
                         title: "每週 · OAuth 應用程式", alwaysPresent: false),
        ClaudeWindowSpec(key: "seven_day_overage_included", durationMins: weeklyWindowMins,
                         title: "每週 · 含超額", alwaysPresent: false),
    ]
}

// MARK: - Snapshot

/// One metered window as the backend reported it.
///
/// Times are `Int64` epoch seconds rather than `Date` on purpose: the safety
/// decisions compare them against tolerances of two and sixty seconds, and the
/// on-disk format has to stay byte-compatible with the Rust engine that wrote
/// the existing state files. `Date` is converted at the UI boundary only.
struct QuotaWindow: Codable, Equatable {
    var usedPercent: Double?
    var windowDurationMins: Int64?
    var resetsAt: Int64?
    var observedAt: Int64
    /// Whether a countdown is genuinely running. Never trust an incoming value
    /// for this — `reconcileSnapshot` recomputes it on every read.
    var countdownActive: Bool

    init(usedPercent: Double? = nil, windowDurationMins: Int64? = nil,
         resetsAt: Int64? = nil, observedAt: Int64 = 0, countdownActive: Bool = false) {
        self.usedPercent = usedPercent
        self.windowDurationMins = windowDurationMins
        self.resetsAt = resetsAt
        self.observedAt = observedAt
        self.countdownActive = countdownActive
    }

    private enum CodingKeys: String, CodingKey {
        case usedPercent, windowDurationMins, resetsAt, observedAt, countdownActive
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        usedPercent = try box.decodeIfPresent(Double.self, forKey: .usedPercent)
        windowDurationMins = try box.decodeIfPresent(Int64.self, forKey: .windowDurationMins)
        resetsAt = try box.decodeIfPresent(Int64.self, forKey: .resetsAt)
        observedAt = try box.decode(Int64.self, forKey: .observedAt)
        countdownActive = try box.decodeIfPresent(Bool.self, forKey: .countdownActive) ?? false
    }

    /// `countdownActive` is omitted when false, matching the Rust
    /// `skip_serializing_if = "is_false"` so a round trip leaves the file
    /// unchanged.
    func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        try box.encodeIfPresent(usedPercent, forKey: .usedPercent)
        try box.encodeIfPresent(windowDurationMins, forKey: .windowDurationMins)
        try box.encodeIfPresent(resetsAt, forKey: .resetsAt)
        try box.encode(observedAt, forKey: .observedAt)
        if countdownActive { try box.encode(true, forKey: .countdownActive) }
    }
}

struct CreditsSnapshot: Codable, Equatable {
    var hasCredits: Bool
    var unlimited: Bool
    var balance: String?
}

struct SpendControlLimitSnapshot: Codable, Equatable {
    var limit: String
    var used: String
    var remainingPercent: Int
    var resetsAt: Int64
}

struct RateLimitBucket: Codable, Equatable {
    var limitId: String
    var limitName: String?
    var primary: QuotaWindow?
    var secondary: QuotaWindow?
    var credits: CreditsSnapshot?
    var individualLimit: SpendControlLimitSnapshot?
    var spendControlReached: Bool?

    init(limitId: String, limitName: String? = nil, primary: QuotaWindow? = nil,
         secondary: QuotaWindow? = nil, credits: CreditsSnapshot? = nil,
         individualLimit: SpendControlLimitSnapshot? = nil, spendControlReached: Bool? = nil) {
        self.limitId = limitId
        self.limitName = limitName
        self.primary = primary
        self.secondary = secondary
        self.credits = credits
        self.individualLimit = individualLimit
        self.spendControlReached = spendControlReached
    }
}

struct RateLimitResetCreditDetail: Codable, Equatable {
    var grantedAt: Int64
    /// Absent when the backend did not publish an expiry. Never substitute
    /// `grantedAt` for it — a grant date is not a deadline.
    var expiresAt: Int64?
    var status: String
}

struct RateLimitResetCredits: Codable, Equatable {
    var availableCount: Int64
    /// `nil` means the backend only supplied the count. An empty list means
    /// detail lookup succeeded but returned no available credits.
    var credits: [RateLimitResetCreditDetail]?
}

struct RateLimitsSnapshot: Codable, Equatable {
    var observedAt: Int64
    var buckets: [RateLimitBucket]
    var rateLimitResetCredits: RateLimitResetCredits?

    init(observedAt: Int64 = 0, buckets: [RateLimitBucket] = [],
         rateLimitResetCredits: RateLimitResetCredits? = nil) {
        self.observedAt = observedAt
        self.buckets = buckets
        self.rateLimitResetCredits = rateLimitResetCredits
    }

    private enum CodingKeys: String, CodingKey {
        case observedAt, buckets, rateLimitResetCredits
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        observedAt = try box.decode(Int64.self, forKey: .observedAt)
        buckets = try box.decodeIfPresent([RateLimitBucket].self, forKey: .buckets) ?? []
        rateLimitResetCredits = try box.decodeIfPresent(RateLimitResetCredits.self,
                                                        forKey: .rateLimitResetCredits)
    }
}

// MARK: - Window selection
//
// Every lookup below demands that exactly one window match. A missing or
// duplicated window means the backend told us something we do not understand,
// and the only safe answer to that is to refuse to poke — never to guess which
// of two candidates was meant.

extension RateLimitsSnapshot {
    func uniqueBucket(_ limitId: String) -> RateLimitBucket? {
        let matches = buckets.filter { $0.limitId == limitId }
        return matches.count == 1 ? matches[0] : nil
    }

    func uniqueBucketWindow(_ limitId: String, durationMins: Int64) -> QuotaWindow? {
        guard let bucket = uniqueBucket(limitId) else { return nil }
        return Self.uniqueWindow(in: bucket, durationMins: durationMins)
    }

    private static func uniqueWindow(in bucket: RateLimitBucket,
                                     durationMins: Int64) -> QuotaWindow? {
        let matches = [bucket.primary, bucket.secondary]
            .compactMap { $0 }
            .filter { $0.windowDurationMins == durationMins }
        return matches.count == 1 ? matches[0] : nil
    }

    func codexBucket() -> RateLimitBucket? { uniqueBucket("codex") }

    func uniqueCodexWindow(durationMins: Int64) -> QuotaWindow? {
        guard let bucket = codexBucket() else { return nil }
        return Self.uniqueWindow(in: bucket, durationMins: durationMins)
    }

    func weeklyWindow() -> QuotaWindow? { uniqueCodexWindow(durationMins: Quota.weeklyWindowMins) }
    func fiveHourWindow() -> QuotaWindow? { uniqueCodexWindow(durationMins: Quota.fiveHourWindowMins) }

    func claudeWindow(_ key: String) -> QuotaWindow? {
        uniqueBucket(Quota.claudeLimitPrefix + key)?.primary
    }

    func weeklyWindow(for provider: QuotaProvider) -> QuotaWindow? {
        switch provider {
        case .codex:        return weeklyWindow()
        case .claude:       return claudeWindow(Quota.claudeWeeklyKey)
        case .antigravity:  return nil
        }
    }

    func fiveHourWindow(for provider: QuotaProvider) -> QuotaWindow? {
        switch provider {
        case .codex:        return fiveHourWindow()
        case .claude:       return claudeWindow(Quota.claudeFiveHourKey)
        case .antigravity:  return nil
        }
    }
}

// MARK: - Transaction state

enum PokeStatus: String, Codable, Equatable {
    case verified
    case unverified
    case notAttributed = "not-attributed"
}

struct LastPoke: Codable, Equatable {
    var at: Int64
    var model: String
    var response: String
    var accountFingerprint: String?
    var status: PokeStatus
    var attempt: Int?
    var verifiedAt: Int64?

    init(at: Int64, model: String, response: String = "", accountFingerprint: String? = nil,
         status: PokeStatus, attempt: Int? = nil, verifiedAt: Int64? = nil) {
        self.at = at
        self.model = model
        self.response = response
        self.accountFingerprint = accountFingerprint
        self.status = status
        self.attempt = attempt
        self.verifiedAt = verifiedAt
    }

    private enum CodingKeys: String, CodingKey {
        case at, model, response, accountFingerprint, status, attempt, verifiedAt
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        at = try box.decode(Int64.self, forKey: .at)
        model = try box.decode(String.self, forKey: .model)
        response = try box.decodeIfPresent(String.self, forKey: .response) ?? ""
        accountFingerprint = try box.decodeIfPresent(String.self, forKey: .accountFingerprint)
        status = try box.decode(PokeStatus.self, forKey: .status)
        attempt = try box.decodeIfPresent(Int.self, forKey: .attempt)
        verifiedAt = try box.decodeIfPresent(Int64.self, forKey: .verifiedAt)
    }
}

struct WeeklyKeeper: Codable, Equatable {
    var countdownActive: Bool
    var pendingScheduledResetAt: Int64?
    var lastHandledResetKey: String?
    var lastPoke: LastPoke?

    init(countdownActive: Bool = false, pendingScheduledResetAt: Int64? = nil,
         lastHandledResetKey: String? = nil, lastPoke: LastPoke? = nil) {
        self.countdownActive = countdownActive
        self.pendingScheduledResetAt = pendingScheduledResetAt
        self.lastHandledResetKey = lastHandledResetKey
        self.lastPoke = lastPoke
    }

    private enum CodingKeys: String, CodingKey {
        case countdownActive, pendingScheduledResetAt, lastHandledResetKey, lastPoke
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        countdownActive = try box.decodeIfPresent(Bool.self, forKey: .countdownActive) ?? false
        pendingScheduledResetAt = try box.decodeIfPresent(Int64.self, forKey: .pendingScheduledResetAt)
        lastHandledResetKey = try box.decodeIfPresent(String.self, forKey: .lastHandledResetKey)
        lastPoke = try box.decodeIfPresent(LastPoke.self, forKey: .lastPoke)
    }

    func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        if countdownActive { try box.encode(true, forKey: .countdownActive) }
        try box.encodeIfPresent(pendingScheduledResetAt, forKey: .pendingScheduledResetAt)
        try box.encodeIfPresent(lastHandledResetKey, forKey: .lastHandledResetKey)
        try box.encodeIfPresent(lastPoke, forKey: .lastPoke)
    }
}

/// A five-hour countdown the user asked to start.
///
/// Kept apart from `WeeklyKeeper` because no automatic path may ever write it:
/// reset detection owns the weekly window, and only an explicit button press or
/// a schedule the user set themselves may reach this one. That is also why it
/// has no reset key of its own — there is no automatic reset to deduplicate.
struct FiveHourStarter: Codable, Equatable {
    var lastPoke: LastPoke?

    init(lastPoke: LastPoke? = nil) { self.lastPoke = lastPoke }
}

/// How much weekly quota one full five-hour window costs, measured over time.
///
/// The weekly allowance can only be spent through five-hour windows, so this
/// ratio caps how fast weekly quota can possibly drain. Providers do not
/// publish it and it differs per plan, so it is measured rather than assumed.
struct BurnRate: Codable, Equatable {
    var fiveHourDeltaTotal: Double
    var weeklyDeltaTotal: Double

    init(fiveHourDeltaTotal: Double = 0, weeklyDeltaTotal: Double = 0) {
        self.fiveHourDeltaTotal = fiveHourDeltaTotal
        self.weeklyDeltaTotal = weeklyDeltaTotal
    }
}

/// Transaction and burn-rate state for one Antigravity quota group.
struct AntigravityGroupState: Codable, Equatable {
    var weeklyKeeper: WeeklyKeeper
    var fiveHourStarter: FiveHourStarter
    var burnRate: BurnRate

    init(weeklyKeeper: WeeklyKeeper = WeeklyKeeper(),
         fiveHourStarter: FiveHourStarter = FiveHourStarter(),
         burnRate: BurnRate = BurnRate()) {
        self.weeklyKeeper = weeklyKeeper
        self.fiveHourStarter = fiveHourStarter
        self.burnRate = burnRate
    }

    private enum CodingKeys: String, CodingKey {
        case weeklyKeeper, fiveHourStarter, burnRate
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        weeklyKeeper = try box.decodeIfPresent(WeeklyKeeper.self, forKey: .weeklyKeeper) ?? WeeklyKeeper()
        fiveHourStarter = try box.decodeIfPresent(FiveHourStarter.self, forKey: .fiveHourStarter) ?? FiveHourStarter()
        burnRate = try box.decodeIfPresent(BurnRate.self, forKey: .burnRate) ?? BurnRate()
    }
}

struct AccountState: Codable, Equatable {
    var version: Int
    var snapshot: RateLimitsSnapshot?
    var accountFingerprint: String?
    var weeklyKeeper: WeeklyKeeper
    var fiveHourStarter: FiveHourStarter
    var burnRate: BurnRate
    var antigravityGroups: [String: AntigravityGroupState]
    /// Provider-requested pause for live quota reads. Currently only Claude
    /// uses this after HTTP 429; the cached snapshot remains authoritative.
    var checkCooldownUntil: Int64?

    init(version: Int = 2, snapshot: RateLimitsSnapshot? = nil, accountFingerprint: String? = nil,
         weeklyKeeper: WeeklyKeeper = WeeklyKeeper(),
         fiveHourStarter: FiveHourStarter = FiveHourStarter(),
         burnRate: BurnRate = BurnRate(),
         antigravityGroups: [String: AntigravityGroupState] = [:],
         checkCooldownUntil: Int64? = nil) {
        self.version = version
        self.snapshot = snapshot
        self.accountFingerprint = accountFingerprint
        self.weeklyKeeper = weeklyKeeper
        self.fiveHourStarter = fiveHourStarter
        self.burnRate = burnRate
        self.antigravityGroups = antigravityGroups
        self.checkCooldownUntil = checkCooldownUntil
    }

    private enum CodingKeys: String, CodingKey {
        case version, snapshot, accountFingerprint, weeklyKeeper, fiveHourStarter
        case burnRate, antigravityGroups, checkCooldownUntil
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        version = try box.decode(Int.self, forKey: .version)
        snapshot = try box.decodeIfPresent(RateLimitsSnapshot.self, forKey: .snapshot)
        accountFingerprint = try box.decodeIfPresent(String.self, forKey: .accountFingerprint)
        weeklyKeeper = try box.decodeIfPresent(WeeklyKeeper.self, forKey: .weeklyKeeper) ?? WeeklyKeeper()
        fiveHourStarter = try box.decodeIfPresent(FiveHourStarter.self, forKey: .fiveHourStarter) ?? FiveHourStarter()
        burnRate = try box.decodeIfPresent(BurnRate.self, forKey: .burnRate) ?? BurnRate()
        antigravityGroups = try box.decodeIfPresent([String: AntigravityGroupState].self,
                                                    forKey: .antigravityGroups) ?? [:]
        checkCooldownUntil = try box.decodeIfPresent(Int64.self, forKey: .checkCooldownUntil)
    }

    func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        try box.encode(version, forKey: .version)
        try box.encodeIfPresent(snapshot, forKey: .snapshot)
        try box.encodeIfPresent(accountFingerprint, forKey: .accountFingerprint)
        try box.encode(weeklyKeeper, forKey: .weeklyKeeper)
        try box.encode(fiveHourStarter, forKey: .fiveHourStarter)
        try box.encode(burnRate, forKey: .burnRate)
        if !antigravityGroups.isEmpty {
            try box.encode(antigravityGroups, forKey: .antigravityGroups)
        }
        try box.encodeIfPresent(checkCooldownUntil, forKey: .checkCooldownUntil)
    }
}

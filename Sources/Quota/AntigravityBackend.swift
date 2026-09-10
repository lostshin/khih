import Foundation

enum AntigravityGroup: String, CaseIterable {
    case gemini
    case claudeGPT = "claude_gpt"

    var limitID: String { "antigravity:\(rawValue)" }
    var name: String {
        self == .gemini ? L10n.t("Gemini Models") : L10n.t("Claude and GPT models")
    }
    var model: String { self == .gemini ? "gemini-3.8-flash-low" : "claude-sonnet-4-6" }

    func window(in snapshot: RateLimitsSnapshot, weekly: Bool) -> QuotaWindow? {
        let buckets = snapshot.buckets.filter { $0.limitId == limitID }
        guard buckets.count == 1 else { return nil }
        let windows = [buckets[0].primary, buckets[0].secondary].compactMap { $0 }
            .filter { $0.windowDurationMins == (weekly ? Quota.weeklyWindowMins : Quota.fiveHourWindowMins) }
        return windows.count == 1 ? windows[0] : nil
    }
}

/// Shared by the observer and engine. No concurrent CLI process and no cached
/// verification: every read that gets this lock executes /usage again.
final class AntigravityClient: @unchecked Sendable {
    static let shared = AntigravityClient()
    private let lock = NSLock()
    private let shutdown = QuotaCancellation()
    func stop() { shutdown.cancel() }
    private let binary: Lazily<URL?>
    private let environment: [String: String]
    var timeout: TimeInterval = 130

    init(binary: Lazily<URL?> = Lazily { try? AntigravityUsage.resolve() },
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.binary = binary
        self.environment = environment
    }

    private func run(_ arguments: [String], cancelled: () -> Bool) throws -> Data {
        while !lock.try() {
            if cancelled() || shutdown.isCancelled { throw CodexError.cancelled }
            Thread.sleep(forTimeInterval: 0.01)
        }
        defer { lock.unlock() }
        guard let binary = binary.get() else { throw AntigravityUsage.Failure.binaryNotFound }
        return try QuotaProcess.run(binary: binary, arguments: arguments, environment: environment,
                                    timeout: timeout, currentDirectory: FileManager.default.temporaryDirectory,
                                    cancelled: { cancelled() || shutdown.isCancelled })
    }

    func read(observedAt: Int64? = nil, cancelled: () -> Bool = { false }) throws -> RateLimitsSnapshot {
        let data = try run(AntigravityUsage.arguments, cancelled: cancelled)
        return try AntigravityUsage.snapshot(from: data,
                                            observedAt: observedAt ?? Int64(Date().timeIntervalSince1970))
    }

    static func pokeArguments(_ group: AntigravityGroup) -> [String] {
        ["-p", "Reply with exactly: OK. Do not use tools.", "--model", group.model,
         "--effort", "low", "--mode", "plan", "--sandbox", "--disable-slash-commands",
         "--output-format", "json", "--print-timeout", "120s"]
    }

    func poke(_ group: AntigravityGroup, cancelled: () -> Bool) throws -> QuotaPokeResult {
        let data = try run(Self.pokeArguments(group), cancelled: cancelled)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["status"] as? String == "SUCCESS" else { throw AntigravityUsage.Failure.invalidUsage }
        return QuotaPokeResult(model: group.model,
                               response: String((root["response"] as? String ?? "").suffix(200)),
                               accountFingerprint: nil)
    }
}

struct AntigravityBackend: QuotaBackend {
    var client: AntigravityClient = .shared
    var cancelled: () -> Bool = { false }

    func accountFingerprint(for account: QuotaAccountConfig) -> String? { nil }
    func readRateLimits(for account: QuotaAccountConfig, observedAt: Int64) throws -> RateLimitsSnapshot {
        try client.read(observedAt: observedAt, cancelled: cancelled)
    }
    func poke(for account: QuotaAccountConfig, target: PokeTarget,
              expectedFingerprint: String?) throws -> QuotaPokeResult {
        guard case .antigravityGroup(let group, _) = target else { throw AntigravityUsage.Failure.invalidUsage }
        return try client.poke(group, cancelled: cancelled)
    }
}

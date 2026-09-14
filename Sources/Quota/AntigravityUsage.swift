import Foundation

/// The official CLI owns authentication. Only its usage envelope is read here.
enum AntigravityUsage {
    static let groups = [(key: "gemini", label: "Gemini Models"),
                         (key: "claude_gpt", label: "Claude and GPT models")]
    static let arguments = ["-p", "/usage", "--output-format", "json"]

    enum Failure: LocalizedError {
        case invalidUsage, binaryNotFound, backgroundReadFailed
        var errorDescription: String? {
            switch self {
            case .invalidUsage: return L10n.t("Antigravity returned an unreadable usage response. The previous reading is kept.")
            case .binaryNotFound: return L10n.t("The official agy command was not found on this Mac.")
            case .backgroundReadFailed: return L10n.t("Antigravity could not read usage silently. Open the official agy CLI to finish signing in, then check again. Browser sign-in is blocked during background checks.")
            }
        }
    }

    static func snapshot(from data: Data, observedAt: Int64) throws -> RateLimitsSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["status"] as? String == "SUCCESS",
              let response = root["response"] as? String else { throw Failure.invalidUsage }
        var windows: [String: QuotaWindow] = [:]
        for line in response.split(whereSeparator: \.isNewline) {
            let fields = line.components(separatedBy: "\t").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard let group = groups.first(where: { $0.label == fields.first }) else { continue }
            guard fields.count == 4 else { throw Failure.invalidUsage }
            let duration: Int64
            switch fields[1] {
            case "Five Hour Limit Remaining": duration = Quota.fiveHourWindowMins
            case "Weekly Limit Remaining": duration = Quota.weeklyWindowMins
            default: throw Failure.invalidUsage
            }
            let key = "\(group.key):\(duration)"
            guard windows[key] == nil, fields[2].hasSuffix("%"),
                  let remaining = Double(fields[2].dropLast()), remaining.isFinite,
                  (0...100).contains(remaining), fields[3].contains("T"),
                  let reset = ClaudeUsage.epochSeconds(from: fields[3]) else {
                throw Failure.invalidUsage
            }
            windows[key] = QuotaWindow(usedPercent: 100 - remaining,
                                       windowDurationMins: duration, resetsAt: reset,
                                       observedAt: observedAt,
                                       countdownActive: remaining < 100 && reset > observedAt)
        }
        let buckets = try groups.map { group -> RateLimitBucket in
            guard let five = windows["\(group.key):300"],
                  let weekly = windows["\(group.key):10080"] else { throw Failure.invalidUsage }
            return RateLimitBucket(limitId: "antigravity:\(group.key)", limitName: group.label,
                                   primary: five, secondary: weekly)
        }
        return RateLimitsSnapshot(observedAt: observedAt, buckets: buckets)
    }

    static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment,
                        home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> URL {
        let manager = FileManager.default
        if let override = environment["CODEX_QUOTA_KEEPER_ANTIGRAVITY_BIN"] {
            guard manager.isExecutableFile(atPath: override) else { throw Failure.binaryNotFound }
            return URL(fileURLWithPath: override)
        }
        let candidates = [home.appendingPathComponent(".local/bin/agy")]
            + (environment["PATH"] ?? "").split(separator: ":").map {
                URL(fileURLWithPath: String($0)).appendingPathComponent("agy")
            }
        guard let found = candidates.first(where: { manager.isExecutableFile(atPath: $0.path) })
        else { throw Failure.binaryNotFound }
        return found
    }
}

import CryptoKit
import Foundation

enum CodexError: LocalizedError {
    case binaryNotFound
    case startFailed(String)
    case timedOut(String)
    case cancelled
    case remote(method: String, message: String)
    case malformed(String)
    case pokeFailed(status: Int32, detail: String)
    case fingerprintChanged

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "找不到 Codex executable；請設定 CODEX_QUOTA_KEEPER_CODEX_BIN"
        case .startFailed(let detail):
            return "無法啟動 Codex app-server：\(detail)"
        case .timedOut(let method):
            return "Codex \(method) 逾時"
        case .cancelled:
            return "Codex 操作已取消"
        case .remote(let method, let message):
            return "Codex \(method) 失敗：\(message)"
        case .malformed(let detail):
            return "無法解析 Codex 回應：\(detail)"
        case .pokeFailed(let status, let detail):
            return "Codex poke 結束碼 \(status)：\(detail)"
        case .fingerprintChanged:
            return "Codex 帳號在自動請求前已改變；未送出請求"
        }
    }
}

enum CodexBinary {
    static let overrideVariable = "CODEX_QUOTA_KEEPER_CODEX_BIN"

    /// An explicit override first, then the two well-known install locations,
    /// then `PATH`. A developer's absolute path must never be baked in.
    static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment,
                        home: URL = FileManager.default.homeDirectoryForCurrentUser,
                        fileManager: FileManager = .default) throws -> URL {
        if let override = environment[overrideVariable], !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            if fileManager.isExecutableFile(atPath: url.path) { return url }
            throw CodexError.binaryNotFound
        }
        for candidate in [home.appendingPathComponent(".local/bin/codex"),
                          home.appendingPathComponent(".codex/bin/codex")] {
            if fileManager.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        if let found = which("codex", fileManager: fileManager) { return found }
        throw CodexError.binaryNotFound
    }

    private static func which(_ name: String, fileManager: FileManager) -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let path = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty,
              fileManager.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }
}

enum CodexFingerprint {
    /// A short digest of the signed-in account id, never the id itself.
    ///
    /// This is the only thing that says *which* account a state file belongs
    /// to. A card's label is a display name the user can edit and proves
    /// nothing; if this changes, the state is somebody else's and the safe
    /// answer is to rebuild a baseline rather than poke.
    static func of(codexHome: URL) -> String? {
        guard let data = try? Data(contentsOf: codexHome.appendingPathComponent("auth.json")),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let accountId = tokens["account_id"] as? String else { return nil }
        return QuotaFingerprint.short(of: accountId)
    }
}

/// How every provider's account fingerprint is made.
///
/// Twelve hex digits of a SHA-256: enough to notice the signed-in account
/// changed, and not enough to recover what it was. Shared so that Codex and
/// Claude cannot drift into two different spellings of the same idea — a
/// fingerprint that changes shape reads as a changed account, which blocks
/// poking until a baseline is rebuilt.
enum QuotaFingerprint {
    static func short(of value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }.joined().prefix(12).lowercased()
    }
}

// MARK: - Wire format

private struct RateLimitWindowWire: Decodable {
    var usedPercent: Double?
    var windowDurationMins: Int64?
    var resetsAt: Int64?
}

private struct RateLimitBucketWire: Decodable {
    var limitId: String?
    var limitName: String?
    var primary: RateLimitWindowWire?
    var secondary: RateLimitWindowWire?
    var credits: CreditsSnapshot?
    var individualLimit: SpendControlLimitSnapshot?
    var spendControlReached: Bool?

    func intoDomain(fallbackId: String, observedAt: Int64) -> RateLimitBucket {
        func window(_ wire: RateLimitWindowWire) -> QuotaWindow {
            // `countdownActive` is deliberately false here. Whether a countdown
            // is running is decided by `reconcileSnapshot` against the previous
            // observation, never by a single read.
            QuotaWindow(usedPercent: wire.usedPercent,
                        windowDurationMins: wire.windowDurationMins,
                        resetsAt: wire.resetsAt,
                        observedAt: observedAt,
                        countdownActive: false)
        }
        return RateLimitBucket(limitId: limitId ?? fallbackId,
                               limitName: limitName,
                               primary: primary.map(window),
                               secondary: secondary.map(window),
                               credits: credits,
                               individualLimit: individualLimit,
                               spendControlReached: spendControlReached)
    }
}

private struct RateLimitsResult: Decodable {
    var rateLimitsByLimitId: [String: RateLimitBucketWire]?
    var rateLimits: RateLimitBucketWire?
    var rateLimitResetCredits: RateLimitResetCredits?
}

struct CodexAccountInfo: Equatable {
    var email: String?
    var planType: String?
}

private struct AccountReadResult: Decodable {
    var email: String?
    var planType: String?

    private struct Payload: Decodable {
        var email: String?
        var planType: String?
    }

    private enum CodingKeys: String, CodingKey { case account, email, planType }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        // Seen both nested under `account` and flattened at the top level.
        let nested = try box.decodeIfPresent(Payload.self, forKey: .account)
        email = try nested?.email ?? box.decodeIfPresent(String.self, forKey: .email)
        planType = try nested?.planType ?? box.decodeIfPresent(String.self, forKey: .planType)
    }
}

private struct LoginStartResult: Decodable {
    var loginId: String?
    var userCode: String?
    var verificationUrl: String?
    /// Seen spelled both ways.
    var verificationUri: String?
}

private struct RpcHeader: Decodable {
    var id: Int?
    var method: String?
    var error: RpcError?
}

private struct RpcError: Decodable {
    var message: String?
}

private struct RpcResponse<T: Decodable>: Decodable {
    var result: T
}

// MARK: - Session

/// One `codex app-server` child process, speaking newline-delimited JSON-RPC
/// over stdin/stdout.
///
/// Note the wire format carries **no** `"jsonrpc": "2.0"` member — adding one
/// is not harmless politeness, it is a different protocol than the one the
/// server speaks.
///
/// This blocks the calling thread while waiting for a reply, exactly as the
/// Rust engine does. It must therefore never be driven from the main actor.
final class CodexAppServerSession {
    static let defaultTimeout: TimeInterval = 15

    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()

    private let condition = NSCondition()
    private var pending: [(id: Int?, method: String?, line: Data)] = []
    private var finished = false
    private var didShutdown = false
    private var nextId = 1
    private let timeout: TimeInterval
    private let cancelled: () -> Bool

    init(binary: URL,
         codexHome: URL,
         timeout: TimeInterval = defaultTimeout,
         cancelled: @escaping () -> Bool = { false }) throws {
        self.timeout = timeout
        self.cancelled = cancelled

        process.executableURL = binary
        process.arguments = ["app-server"]
        // The account's own home is the whole of the isolation between
        // accounts — without it every session speaks for whichever account
        // happens to be signed in globally.
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = codexHome.path
        process.environment = environment
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do { try process.run() } catch {
            throw CodexError.startFailed(error.localizedDescription)
        }

        startReading()
        // stderr is drained and discarded; left unread its pipe fills and the
        // child blocks writing to it.
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }

        try handshake()
    }

    deinit { shutdown() }

    func shutdown() {
        condition.lock()
        let alreadyDone = didShutdown
        didShutdown = true
        condition.unlock()
        guard !alreadyDone else { return }

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        // Closing stdin first gives a healthy server the chance to exit on its
        // own terms before it is killed.
        try? stdinPipe.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
            // Reap it. A wedged app-server — which is what a credential problem
            // looks like — would otherwise accumulate as a zombie on every
            // sixty-second poll, one per account.
            process.waitUntilExit()
        }
        condition.lock()
        finished = true
        condition.broadcast()
        condition.unlock()
    }

    private func startReading() {
        var buffer = Data()
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let chunk = handle.availableData
            if chunk.isEmpty {
                self.condition.lock()
                self.finished = true
                self.condition.broadcast()
                self.condition.unlock()
                return
            }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer = buffer[buffer.index(after: newline)...]
                guard !line.isEmpty else { continue }
                let data = Data(line)
                let header = try? JSONDecoder().decode(RpcHeader.self, from: data)
                self.condition.lock()
                self.pending.append((header?.id, header?.method, data))
                self.condition.broadcast()
                self.condition.unlock()
            }
        }
    }

    private func handshake() throws {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        _ = try request("initialize", params: [
            "clientInfo": ["name": "codenotch",
                           "title": "Codenotch",
                           "version": version ?? "0"]
        ], as: DiscardedResult.self)
        try notify("initialized", params: [:])
    }

    struct DiscardedResult: Decodable {
        init(from decoder: Decoder) throws {}
    }

    // MARK: Requests

    func rateLimits(observedAt: Int64) throws -> RateLimitsSnapshot {
        let result = try request("account/rateLimits/read", params: [:], as: RateLimitsResult.self)

        var buckets: [RateLimitBucket] = []
        if let byId = result.rateLimitsByLimitId, !byId.isEmpty {
            // The map key is the limit id whenever the bucket itself omits one.
            buckets = byId.sorted { $0.key < $1.key }.map {
                $0.value.intoDomain(fallbackId: $0.key, observedAt: observedAt)
            }
        } else if let single = result.rateLimits {
            buckets = [single.intoDomain(fallbackId: "codex", observedAt: observedAt)]
        }

        return RateLimitsSnapshot(observedAt: observedAt,
                                  buckets: buckets,
                                  rateLimitResetCredits: result.rateLimitResetCredits)
    }

    func accountInfo() throws -> CodexAccountInfo {
        let result = try request("account/read", params: [:], as: AccountReadResult.self)
        return CodexAccountInfo(email: result.email, planType: result.planType)
    }

    /// Begins a device-code sign-in and returns the code to show the user.
    func startDeviceLogin() throws -> CodexDeviceCode {
        let result = try request("account/login/start",
                                 params: ["type": "chatgptDeviceCode"],
                                 as: LoginStartResult.self)
        guard let loginId = result.loginId, !loginId.isEmpty,
              let userCode = result.userCode, !userCode.isEmpty,
              let url = result.verificationUrl ?? result.verificationUri, !url.isEmpty else {
            throw CodexError.malformed("Codex device auth 回應缺少必要欄位")
        }
        return CodexDeviceCode(loginId: loginId, userCode: userCode, verificationURL: url)
    }

    func cancelDeviceLogin(loginId: String) {
        _ = try? request("account/login/cancel", params: ["loginId": loginId],
                         as: DiscardedResult.self)
    }

    private func request<T: Decodable>(_ method: String,
                                       params: [String: Any],
                                       as type: T.Type) throws -> T {
        let id = nextId
        nextId += 1
        try send(["method": method, "id": id, "params": params])

        let deadline = Date().addingTimeInterval(timeout)
        while true {
            guard let line = try waitForLine(id: id, deadline: deadline) else {
                throw CodexError.timedOut(method)
            }
            let header = try? JSONDecoder().decode(RpcHeader.self, from: line)
            if let message = header?.error?.message {
                throw CodexError.remote(method: method, message: message)
            }
            do {
                return try JSONDecoder().decode(RpcResponse<T>.self, from: line).result
            } catch {
                throw CodexError.malformed("\(method): \(error)")
            }
        }
    }

    private func notify(_ method: String, params: [String: Any]) throws {
        try send(["method": method, "params": params])
    }

    private func send(_ value: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: value)
        data.append(0x0A)
        try stdinPipe.fileHandleForWriting.write(contentsOf: data)
    }

    /// Replies can arrive out of order, so anything that is not ours is left in
    /// the queue for whoever is waiting on it.
    private func waitForLine(id: Int, deadline: Date) throws -> Data? {
        try waitForMessage(deadline: deadline) { $0.id == id }
    }

    /// Waits for a notification the server sends on its own initiative — the
    /// device-login completion arrives this way, with no id to match on.
    func waitForNotification(method: String, deadline: Date) throws -> [String: Any]? {
        guard let line = try waitForMessage(deadline: deadline, where: {
            $0.id == nil && $0.method == method
        }) else { return nil }
        let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
        return (object?["params"] as? [String: Any]) ?? [:]
    }

    private func waitForMessage(deadline: Date,
                                where matches: ((id: Int?, method: String?, line: Data)) -> Bool)
        throws -> Data? {
        condition.lock()
        defer { condition.unlock() }
        while true {
            if cancelled() { throw CodexError.cancelled }
            if let index = pending.firstIndex(where: matches) {
                return pending.remove(at: index).line
            }
            // The child is gone and what we are waiting for is never coming.
            if finished, !process.isRunning { return nil }
            if Date() >= deadline { return nil }
            _ = condition.wait(until: min(deadline, Date().addingTimeInterval(0.25)))
        }
    }
}

// MARK: - The minimal request

/// What a minimal request came back with, whichever provider sent it. The
/// fingerprint is the account the request was actually billed to, as the
/// provider itself reports it — not the one the caller expected.
struct QuotaPokeResult: Equatable {
    var model: String
    var response: String
    var accountFingerprint: String?
}

enum CodexPoke {
    static let defaultTimeout: TimeInterval = 120

    /// The fixed minimal request that anchors a fresh quota window.
    ///
    /// Every flag here is part of the contract, not a preference: `--ephemeral`
    /// and `read-only` keep it from touching anything, the model and reasoning
    /// effort keep it as cheap as a request can be, and the prompt asks for one
    /// tool call so the request genuinely exercises the quota it is meant to
    /// anchor. Changing any of it needs the user's explicit agreement.
    static func arguments(model: String = Quota.defaultModel,
                          prompt: String = Quota.defaultPrompt,
                          isolatedHome: Bool = true,
                          workingDirectory: URL) -> [String] {
        var args = ["exec", "--ephemeral"]
        // An isolated home has no user config to ignore.
        if !isolatedHome { args.append("--ignore-user-config") }
        args += ["--ignore-rules", "--skip-git-repo-check",
                 "--sandbox", "read-only",
                 "--model", model,
                 "-c", "approval_policy=\"never\"",
                 "-c", "model_reasoning_effort=\"low\"",
                 "-C", workingDirectory.path,
                 prompt]
        return args
    }

    /// Runs the request. The fingerprint is re-checked here, immediately before
    /// spending anything: the account can change between the decision to poke
    /// and the poke itself.
    static func run(binary: URL,
                    codexHome: URL,
                    expectedFingerprint: String?,
                    timeout: TimeInterval = defaultTimeout,
                    workingDirectory: URL = FileManager.default.temporaryDirectory,
                    cancelled: () -> Bool = { false }) throws -> QuotaPokeResult {
        let fingerprint = CodexFingerprint.of(codexHome: codexHome)
        if let expectedFingerprint, fingerprint != expectedFingerprint {
            throw CodexError.fingerprintChanged
        }
        let model = Quota.defaultModel
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = codexHome.path

        let stdout: Data
        do {
            stdout = try QuotaProcess.run(
                binary: binary,
                arguments: arguments(model: model, workingDirectory: workingDirectory),
                environment: environment,
                timeout: timeout,
                cancelled: cancelled)
        } catch let failure as QuotaProcess.Failure {
            throw CodexError.pokeFailed(status: failure.status, detail: failure.detail)
        }

        // A completed request says the process finished, and nothing more.
        // Whether it anchored the window is decided by backend verification.
        let response = String(decoding: stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return QuotaPokeResult(model: model,
                               response: String(response.prefix(200)),
                               accountFingerprint: fingerprint)
    }
}

// MARK: - Device sign-in

struct CodexDeviceCode: Equatable {
    var loginId: String
    /// Shown to the user to type into the browser.
    var userCode: String
    var verificationURL: String
}

enum CodexLoginEvent: Equatable {
    /// Nothing has happened yet; ask again.
    case pending
    case completed
    case failed(String)
}

/// One device-code sign-in, alive for as long as the flow is on screen.
///
/// The app never sees the credential: the browser half happens at ChatGPT, and
/// the CLI writes the result into this account's own `CODEX_HOME`. All this
/// object does is start the attempt, hold the code to display, and wait for the
/// server to say it finished.
final class CodexDeviceLogin {
    let code: CodexDeviceCode
    private let session: CodexAppServerSession
    private var finished = false

    init(binary: URL, codexHome: URL, cancelled: @escaping () -> Bool = { false }) throws {
        let session = try CodexAppServerSession(binary: binary, codexHome: codexHome,
                                                cancelled: cancelled)
        do {
            self.code = try session.startDeviceLogin()
        } catch {
            session.shutdown()
            throw error
        }
        self.session = session
    }

    deinit { cancel() }

    /// Waits up to `timeout` for the browser half to finish.
    ///
    /// `pending` means "nothing yet" rather than "no": the user is off in a
    /// browser, and the caller decides how long to keep offering the code.
    func poll(timeout: TimeInterval) throws -> CodexLoginEvent {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            guard let params = try session.waitForNotification(
                method: "account/login/completed", deadline: deadline) else {
                return .pending
            }
            // A completion belonging to a different attempt is not ours.
            if let id = params["loginId"] as? String, id != code.loginId { continue }
            finished = true
            if let message = params["error"] as? String { return .failed(message) }
            if params["success"] as? Bool == false { return .failed("Codex 登入失敗") }
            return .completed
        }
    }

    /// Ends the attempt. Safe to call more than once, and called on the way out
    /// so an abandoned sign-in does not leave one open at the server.
    func cancel() {
        if !finished {
            finished = true
            session.cancelDeviceLogin(loginId: code.loginId)
        }
        session.shutdown()
    }
}

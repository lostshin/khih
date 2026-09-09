import Foundation

/// One monitored account, as `accounts.json` describes it.
///
/// `label` is a display name the user can edit — never evidence of which
/// account is actually signed in. Only the fingerprint derived from the
/// credential store answers that.
struct QuotaAccountConfig: Codable, Equatable, Identifiable {
    var id: String
    var label: String
    var provider: QuotaProvider
    /// Only meaningful for Codex accounts; read-only providers keep the
    /// directory unused so that `accounts.json` retains one stable shape.
    var codexHome: String
    var stateDir: String
    var enabled: Bool

    var codexHomeURL: URL { URL(fileURLWithPath: codexHome) }
    var stateDirURL: URL { URL(fileURLWithPath: stateDir) }

    private enum CodingKeys: String, CodingKey {
        case id, label, provider, codexHome, stateDir, enabled
    }

    init(id: String, label: String, provider: QuotaProvider = .codex,
         codexHome: String, stateDir: String, enabled: Bool = true) {
        self.id = id
        self.label = label
        self.provider = provider
        self.codexHome = codexHome
        self.stateDir = stateDir
        self.enabled = enabled
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        id = try box.decode(String.self, forKey: .id)
        label = try box.decode(String.self, forKey: .label)
        // Older files predate the field; those accounts are all Codex.
        provider = try box.decodeIfPresent(QuotaProvider.self, forKey: .provider) ?? .codex
        codexHome = try box.decode(String.self, forKey: .codexHome)
        stateDir = try box.decode(String.self, forKey: .stateDir)
        enabled = try box.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}

struct QuotaAccountsFile: Codable, Equatable {
    var version: Int
    var accounts: [QuotaAccountConfig]

    init(version: Int = 1, accounts: [QuotaAccountConfig] = []) {
        self.version = version
        self.accounts = accounts
    }

    private enum CodingKeys: String, CodingKey { case version, accounts }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        version = try box.decodeIfPresent(Int.self, forKey: .version) ?? 1
        accounts = try box.decodeIfPresent([QuotaAccountConfig].self, forKey: .accounts) ?? []
    }
}

/// App-wide settings, kept out of `accounts.json` so that its contract stays
/// untouched.
struct QuotaSettings: Codable, Equatable {
    var version: Int
    /// One-shot: when the user asked for every enabled account's five-hour
    /// countdown to be started. Cleared as soon as it fires or expires.
    var fiveHourStartAt: Int64?

    init(version: Int = 0, fiveHourStartAt: Int64? = nil) {
        self.version = version
        self.fiveHourStartAt = fiveHourStartAt
    }

    private enum CodingKeys: String, CodingKey { case version, fiveHourStartAt }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        version = try box.decodeIfPresent(Int.self, forKey: .version) ?? 0
        fiveHourStartAt = try box.decodeIfPresent(Int64.self, forKey: .fiveHourStartAt)
    }
}

/// Exclusive access to one account's check, held for as long as the object
/// lives.
///
/// The lock file is what stops a timer check, a manual check and a five-hour
/// start from running against the same account at once — three paths that
/// would otherwise each read, decide and write the same state file.
final class CheckLock {
    private let path: URL
    private let descriptor: Int32

    init(path: URL, descriptor: Int32) {
        self.path = path
        self.descriptor = descriptor
    }

    deinit {
        close(descriptor)
        try? FileManager.default.removeItem(at: path)
    }
}

enum QuotaStorageError: Error {
    case noParentDirectory
    case accountNotFound(String)
}

/// Reads and writes the on-disk state the Rust engine created.
///
/// The base directory is deliberately the one the Rust app already uses:
/// inheriting its files keeps every account's baseline, fingerprint and
/// `lastHandledResetKey` intact, and an account with no baseline is an account
/// that must not be poked until it has observed itself twice.
struct QuotaStorage {
    static let toolName = "codex-quota-keeper"
    /// A lock older than this belonged to a process that died holding it.
    static let checkLockStaleAfter: TimeInterval = 600

    let baseDir: URL

    init(baseDir: URL) { self.baseDir = baseDir }

    static func systemDefault() -> QuotaStorage {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return QuotaStorage(baseDir: home
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent(toolName))
    }

    var accountsPath: URL { baseDir.appendingPathComponent("accounts.json") }
    var settingsPath: URL { baseDir.appendingPathComponent("settings.json") }

    static func statePath(for account: QuotaAccountConfig) -> URL {
        account.stateDirURL.appendingPathComponent("state.json")
    }

    static func activityPath(for account: QuotaAccountConfig) -> URL {
        account.stateDirURL.appendingPathComponent("activity.log")
    }

    static func checkLockPath(for account: QuotaAccountConfig) -> URL {
        account.stateDirURL.appendingPathComponent("check.lock")
    }

    // MARK: - Accounts and settings

    func loadAccounts() -> QuotaAccountsFile {
        guard let data = try? Data(contentsOf: accountsPath),
              let file = try? JSONDecoder().decode(QuotaAccountsFile.self, from: data) else {
            return QuotaAccountsFile()
        }
        return file
    }

    func saveAccounts(_ file: QuotaAccountsFile) throws {
        try Self.atomicJSON(file, to: accountsPath)
    }

    func loadSettings() -> QuotaSettings {
        guard let data = try? Data(contentsOf: settingsPath),
              let settings = try? JSONDecoder().decode(QuotaSettings.self, from: data) else {
            return QuotaSettings()
        }
        return settings
    }

    func saveSettings(_ settings: QuotaSettings) throws {
        try Self.atomicJSON(settings, to: settingsPath)
    }

    // MARK: - Per-account state

    /// Anything unreadable, or written by an older schema, comes back as an
    /// empty baseline rather than a partially understood state.
    ///
    /// That is the safe direction: a state with no snapshot cannot pass the
    /// baseline gate, so the worst case is one skipped keeper cycle. Migrating
    /// a v1 file would instead carry forward a `lastHandledResetKey` whose
    /// meaning we no longer know.
    func loadState(for account: QuotaAccountConfig) -> AccountState {
        let path = Self.statePath(for: account)
        guard let data = try? Data(contentsOf: path) else { return AccountState() }
        guard let state = try? JSONDecoder().decode(AccountState.self, from: data),
              state.version == 2 else { return AccountState() }
        return state
    }

    func saveState(_ state: AccountState, for account: QuotaAccountConfig) throws {
        try Self.atomicJSON(state, to: Self.statePath(for: account))
    }

    // MARK: - Activity log

    func appendActivity(_ line: String, for account: QuotaAccountConfig) throws {
        try Self.privateDirectory(account.stateDirURL)
        let path = Self.activityPath(for: account)
        let entry = Data((line + "\n").utf8)

        if let handle = try? FileHandle(forWritingTo: path) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: entry)
        } else {
            FileManager.default.createFile(path: path, contents: entry)
        }
    }

    /// The tail of the log — the whole file is never needed, and an account
    /// that has run for months has a long one.
    func recentActivity(for account: QuotaAccountConfig, limit: Int) -> [String] {
        guard let text = try? String(contentsOf: Self.activityPath(for: account), encoding: .utf8) else {
            return []
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let trimmed = lines.last?.isEmpty == true ? lines.dropLast() : ArraySlice(lines)
        return Array(trimmed.suffix(limit))
    }

    /// Taipei time, matching what the Rust engine wrote — the log is read by a
    /// person, in one place, and mixing zones inside one file makes it useless
    /// for working out what happened when.
    static func activityTimestamp(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Taipei")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        return formatter.string(from: date)
    }

    // MARK: - Check lock

    /// `nil` means somebody else holds the lock; the caller must skip rather
    /// than wait.
    func acquireCheckLock(for account: QuotaAccountConfig,
                          staleAfter: TimeInterval = checkLockStaleAfter,
                          now: Date = Date()) throws -> CheckLock? {
        try Self.privateDirectory(account.stateDirURL)
        let path = Self.checkLockPath(for: account)

        if let lock = Self.exclusiveCreate(at: path) { return lock }

        // Somebody has it. Only a lock old enough to have outlived its process
        // may be broken.
        let modified = (try? FileManager.default.attributesOfItem(atPath: path.path)[.modificationDate] as? Date)
            ?? nil
        if let modified, now.timeIntervalSince(modified) <= staleAfter { return nil }
        if modified == nil { return nil }

        try? FileManager.default.removeItem(at: path)
        return Self.exclusiveCreate(at: path)
    }

    private static func exclusiveCreate(at path: URL) -> CheckLock? {
        let descriptor = open(path.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { return nil }
        return CheckLock(path: path, descriptor: descriptor)
    }

    // MARK: - Atomic writes

    /// Write to a sibling temporary file and rename over the target.
    ///
    /// A half-written state file is worse than a missing one: it would decode
    /// as an empty baseline and silently discard a `lastHandledResetKey`,
    /// which is what stops the same reset being poked twice.
    static func atomicJSON<T: Encodable>(_ value: T, to path: URL) throws {
        let parent = path.deletingLastPathComponent()
        guard !parent.path.isEmpty else { throw QuotaStorageError.noParentDirectory }
        try privateDirectory(parent)

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        var data = try encoder.encode(value)
        data.append(0x0A)

        let temporary = path.appendingPathExtension("tmp")
        guard FileManager.default.createFile(path: temporary, contents: data) else {
            throw CocoaError(.fileWriteUnknown)
        }
        // `replaceItemAt` requires the original to exist; the first write of
        // any of these files has no original to replace.
        if FileManager.default.fileExists(atPath: path.path) {
            _ = try FileManager.default.replaceItemAt(path, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: path)
        }
    }

    /// Owner-only, because these directories hold credentials and quota state.
    static func privateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}

private extension FileManager {
    /// Owner-only from the moment it exists, rather than created and then
    /// tightened.
    func createFile(path: URL, contents: Data) -> Bool {
        createFile(atPath: path.path, contents: contents,
                   attributes: [.posixPermissions: 0o600])
    }
}

import Combine
import Foundation

/// What the user sees after pressing the button, including the failures the
/// engine reports by throwing.
enum FiveHourResult: Equatable {
    case skippedBusy
    case refused(FiveHourRefusal)
    case started(PokeStatus)
    /// The request could not be made at all — no `codex` binary, a child that
    /// would not start, a timeout.
    case failed(String)

    init(_ outcome: FiveHourOutcome) {
        switch outcome {
        case .skippedBusy:          self = .skippedBusy
        case .refused(let reason):  self = .refused(reason)
        case .started(let status):  self = .started(status)
        }
    }
}

/// The boundary between the quota engine and the interface.
///
/// The engine blocks — it holds a file lock, sleeps between verification reads
/// and waits on child processes — so nothing here calls it on the main actor.
/// This object exists to keep that rule in one place, and to publish the little
/// state the UI needs while a request is in flight.
@MainActor
final class QuotaController: ObservableObject {
    /// Provider ids with a request in flight. The button spins on these rather
    /// than a global busy flag: one account's start says nothing about another.
    @Published private(set) var running: Set<String> = []
    /// The last result per provider id, shown under the row until something
    /// replaces it.
    @Published private(set) var results: [String: FiveHourResult] = [:]

    private let storage: QuotaStorage
    private var accounts: [QuotaAccountConfig]
    private let engine: QuotaEngine?

    /// Takes the engine as given, `nil` included — that is what "there is no
    /// way to make the request" looks like, and a test needs to be able to say
    /// it without depending on what is installed on the machine.
    init(storage: QuotaStorage, engine: QuotaEngine?) {
        self.storage = storage
        self.accounts = storage.loadAccounts().accounts
        self.engine = engine
    }

    /// Resolves an engine from this machine's own Codex install. Without a
    /// `codex` binary there is no way to make the request, so the button has
    /// nothing to offer and is not shown at all.
    convenience init(storage: QuotaStorage = QuotaStorage.systemDefault()) {
        let engine = (try? CodexBinary.resolve()).map {
            QuotaEngine(storage: storage, backend: CodexBackend(binary: $0))
        }
        self.init(storage: storage, engine: engine)
    }

    /// Re-read the account list. Cheap, and the file can change while the app
    /// is running.
    func reloadAccounts() {
        accounts = storage.loadAccounts().accounts
    }

    /// The managed account behind a provider id, if there is one.
    ///
    /// Only accounts in `accounts.json` can be started: the engine needs a
    /// state directory to hold the baseline and the lock, and a `~/.codex`
    /// profile the engine never adopted has neither.
    func account(forProviderID id: String) -> QuotaAccountConfig? {
        guard let accountID = CodexProfile.slug(fromProviderID: id) else { return nil }
        return accounts.first {
            $0.id == accountID && $0.provider == .codex && $0.enabled
        }
    }

    func canStartFiveHour(_ providerID: String) -> Bool {
        engine != nil && account(forProviderID: providerID) != nil
    }

    func isRunning(_ providerID: String) -> Bool { running.contains(providerID) }

    func result(for providerID: String) -> FiveHourResult? { results[providerID] }

    /// Starts one account's five-hour countdown.
    ///
    /// A second press while the first is in flight is ignored rather than
    /// queued — the engine would refuse it on the lock anyway, and a queued
    /// press is a press the user has forgotten about by the time it lands.
    func startFiveHour(_ providerID: String) async {
        guard !running.contains(providerID),
              let engine,
              let account = account(forProviderID: providerID) else { return }

        running.insert(providerID)
        defer { running.remove(providerID) }

        let result = await Self.offMainActor {
            do {
                return FiveHourResult(try engine.startFiveHour(account: account, trigger: .manual))
            } catch {
                return FiveHourResult.failed(error.localizedDescription)
            }
        }
        results[providerID] = result
    }

    /// The tail of an account's activity log — the record of what the engine
    /// did and why, including the attempts it refused.
    func recentActivity(_ providerID: String, limit: Int = 20) -> [String] {
        guard let account = account(forProviderID: providerID) else { return [] }
        return storage.recentActivity(for: account, limit: limit)
    }

    /// Runs blocking work off the main actor and comes back on it.
    private static func offMainActor<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: work())
            }
        }
    }
}

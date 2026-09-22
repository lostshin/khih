import XCTest
@testable import Khih

/// The token path of `ClaudeOAuthProvider`.
///
/// It had no tests at all — only the pure helpers (`backoff`, `retryAfter`) were
/// covered — which is how a back-off that re-stamped itself on every failed tick
/// shipped and locked the provider until the app was restarted.
///
/// Every assertion here is about one question: **after a failure, does the next
/// tick actually go and ask again?** Hence the counters. Asserting on the returned
/// error is not enough — the broken version returned exactly the right error while
/// never touching the keychain or the network.
final class ClaudeOAuthProviderTests: XCTestCase {

    override func tearDown() {
        StubEndpoint.reset([])
        super.tearDown()
    }

    /// A 401 must not stop the next tick from trying.
    ///
    /// The endpoint rejects the token and then starts answering again — a token
    /// rotated behind the app's back. This is the manual repro (a local server
    /// switched from 401 to 200) reduced to a test.
    func testA401DoesNotStopTheNextTickFromTrying() async throws {
        StubEndpoint.reset([
            .init(status: 401),                       // the tick's first attempt
            .init(status: 401),                       // its one retry on unauthorized
            .init(status: 200, body: Self.usagePayload)
        ])
        let source = CredentialSource(readable: true)
        let provider = makeProvider(source: source)

        await assertNeedsAuth(from: provider)
        XCTAssertEqual(StubEndpoint.requestCount, 2, "the retry on 401 did not happen")

        let snapshot = try await provider.fetchSnapshot()

        XCTAssertEqual(StubEndpoint.requestCount, 3,
                       "the next tick never reached the endpoint")
        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.windows.first?.id, "session")
    }

    /// A keychain read that failed must not stop the next tick from reading again.
    ///
    /// This is what happened in the field: the Mac was in dark wake, the keychain
    /// answered `-25320` ("no UI possible"), and that fell through to `needsAuth`.
    /// The credential was readable again seconds later; the provider never looked.
    func testAKeychainFailureDoesNotStopTheNextTickFromReading() async throws {
        StubEndpoint.reset([.init(status: 200, body: Self.usagePayload)])
        let source = CredentialSource(readable: false)
        let provider = makeProvider(source: source)

        await assertNeedsAuth(from: provider)
        XCTAssertEqual(source.reads, 1)
        XCTAssertEqual(StubEndpoint.requestCount, 0,
                       "it went to the network without a token")

        source.makeReadable()   // the machine woke up

        let snapshot = try await provider.fetchSnapshot()

        XCTAssertEqual(source.reads, 2, "the next tick never went back to the keychain")
        XCTAssertEqual(snapshot.status, .ok)
    }

    /// Failing repeatedly must not become failing silently.
    ///
    /// The bug's signature was a request count frozen at two while the poll kept
    /// firing every 60 seconds. Three ticks against a rejecting endpoint have to
    /// produce three attempts, not one.
    func testItKeepsAskingWhileTheEndpointKeepsRejecting() async {
        StubEndpoint.reset(Array(repeating: .init(status: 401), count: 6))
        let provider = makeProvider(source: CredentialSource(readable: true))

        for _ in 0..<3 { await assertNeedsAuth(from: provider) }

        XCTAssertEqual(StubEndpoint.requestCount, 6,
                       "the provider stopped asking after the first failure")
    }

    func testProvider429PublishesSharedCooldownAndSurvivesProviderRecreation() async throws {
        let clock: Int64 = 1_800_000_000
        let name = "SharedClaudeCooldown.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let archive = UsageArchive(defaults: defaults)
        let cooldown = ClaudeCooldown(archive: archive)
        StubEndpoint.reset([.init(status: 429, headers: ["Retry-After": "3600"])])
        let source = CredentialSource(readable: true)
        let provider = makeProvider(source: source, cooldown: cooldown, now: { clock })
        do { _ = try await provider.fetchSnapshot(); XCTFail("Expected 429") }
        catch UsageProviderError.rateLimited(let delay) { XCTAssertEqual(delay, 3600) }
        XCTAssertEqual(cooldown.deadline(now: clock), clock + 3600)
        let recreated = makeProvider(source: source, cooldown: ClaudeCooldown(archive: archive), now: { clock })
        do { _ = try await recreated.fetchSnapshot(); XCTFail("Expected cooldown") }
        catch UsageProviderError.rateLimited(let delay) { XCTAssertEqual(delay, 3600) }
        XCTAssertEqual(source.reads, 1)
        XCTAssertEqual(StubEndpoint.requestCount, 1)
        XCTAssertEqual(StubEndpoint.userAgents, ["claude-code/1.2.3"])
    }

    func testSharedCooldownBlocksCredentialsAndUserAgentBeforeFetching() async throws {
        let clock: Int64 = 1_800_000_000
        let name = "SharedClaudeCooldown.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let cooldown = ClaudeCooldown(archive: UsageArchive(defaults: defaults), persistedUntil: { clock + 900 })
        let source = CredentialSource(readable: true)
        StubEndpoint.reset([])
        let cliCalls = Counter()
        let provider = makeProvider(source: source, cooldown: cooldown, now: { clock },
                                    cli: Self.cli { cliCalls.increment(); return Self.cliUsage },
                                    readUserAgent: { XCTFail("Must not resolve CLI version"); return nil })
        do { _ = try await provider.fetchSnapshot(); XCTFail("Expected cooldown") }
        catch UsageProviderError.rateLimited(let delay) { XCTAssertEqual(delay, 900) }
        do { _ = try await provider.fetchSnapshotAfterReconnect(); XCTFail("Expected cooldown after reconnect") }
        catch UsageProviderError.rateLimited(let delay) { XCTAssertEqual(delay, 900) }
        XCTAssertEqual(source.reads, 0)
        XCTAssertEqual(cliCalls.value, 0)
        XCTAssertEqual(StubEndpoint.requestCount, 0)
    }

    // MARK: - Helpers

    private static let usagePayload = Data("""
    {"limits":[{"kind":"session","percent":42,"resets_at":"2099-01-01T00:00:00Z"}]}
    """.utf8)

    private func makeProvider(source: CredentialSource,
                              cooldown: ClaudeCooldown? = nil,
                              now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) },
                              cli: ClaudeUsageCLI? = nil,
                              cliRefreshInterval: TimeInterval = 5 * 60,
                              readUserAgent: @escaping @Sendable () -> String? = { "claude-code/1.2.3" },
                              onReadUserAgent: (@Sendable () -> Void)? = nil) -> ClaudeOAuthProvider {
        // A private defaults suite per test: the archive persists the 429 back-off
        // deadline, and a leaked one would silently skip fetches in the next test.
        let name = "ClaudeOAuthProviderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)

        // No CLI, because these are the token path's tests. Left to find one,
        // the provider would answer off `claude "/usage"` on a machine that has
        // Claude Code installed and off the endpoint on one that does not, and
        // every assertion below about retries and back-off would depend on the
        // developer's own setup rather than on the code.
        return ClaudeOAuthProvider(session: StubEndpoint.session(),
                                   archive: UsageArchive(defaults: defaults),
                                   loadCredentials: { try source.read() },
                                   cooldown: cooldown, now: now,
                                   cli: cli,
                                   cliRefreshInterval: cliRefreshInterval,
                                   readUserAgent: { onReadUserAgent?(); return readUserAgent() })
    }

    // MARK: - The user agent

    /// Not the first request — *every* request. The endpoint answers a
    /// Khih-shaped user agent from a far stricter bucket, and one call in
    /// ten missing the header is enough to sit in a 429 for hours.
    func testEveryRequestCarriesClaudeCodesUserAgent() async throws {
        StubEndpoint.reset([
            .init(status: 200, body: Self.usagePayload),
            .init(status: 200, body: Self.usagePayload),
            .init(status: 200, body: Self.usagePayload)
        ])
        let provider = makeProvider(source: CredentialSource(readable: true))

        for _ in 0..<3 { _ = try await provider.fetchSnapshot() }

        XCTAssertEqual(StubEndpoint.userAgents, Array(repeating: "claude-code/1.2.3", count: 3))
    }

    /// A retry is a request like any other.
    func testTheRetryAfterA401CarriesItToo() async throws {
        StubEndpoint.reset([.init(status: 401), .init(status: 401)])
        let provider = makeProvider(source: CredentialSource(readable: true))

        await assertNeedsAuth(from: provider)

        XCTAssertEqual(StubEndpoint.userAgents, ["claude-code/1.2.3", "claude-code/1.2.3"])
    }

    /// The version is read from a subprocess. Paying for it on every poll is
    /// what the cache exists to avoid.
    func testTheVersionIsReadOnceHoweverManyRequestsFollow() async throws {
        StubEndpoint.reset([
            .init(status: 200, body: Self.usagePayload),
            .init(status: 200, body: Self.usagePayload)
        ])
        let reads = Counter()
        let provider = makeProvider(source: CredentialSource(readable: true),
                                    onReadUserAgent: { reads.increment() })

        for _ in 0..<2 { _ = try await provider.fetchSnapshot() }

        XCTAssertEqual(reads.value, 1)
    }

    /// A Mac without Claude Code installed still asks — it just does not
    /// invent a version, and it does not spawn again hoping for a better answer.
    func testNoInstalledClaudeCodeMeansNoHeaderAndNoSecondSpawn() async throws {
        StubEndpoint.reset([
            .init(status: 200, body: Self.usagePayload),
            .init(status: 200, body: Self.usagePayload)
        ])
        let reads = Counter()
        let provider = makeProvider(source: CredentialSource(readable: true),
                                    readUserAgent: { nil },
                                    onReadUserAgent: { reads.increment() })

        for _ in 0..<2 { _ = try await provider.fetchSnapshot() }

        XCTAssertEqual(StubEndpoint.userAgents, [nil, nil])
        XCTAssertEqual(reads.value, 1)
    }

    // MARK: - The CLI path

    /// The point of the whole thing: when `claude "/usage"` answers, nothing
    /// asks macOS for a credential and nothing calls the endpoint.
    ///
    /// Counting is the only way to know. A provider that read the keychain and
    /// then threw the result away would return exactly the same snapshot, and
    /// the keychain prompt this exists to avoid would still have appeared.
    func testAWorkingCLIMeansNoKeychainReadAndNoRequest() async throws {
        StubEndpoint.reset([.init(status: 200, body: Self.usagePayload)])
        let source = CredentialSource(readable: true)
        let provider = makeProvider(source: source, cli: Self.cli(answering: Self.cliUsage))

        let snapshot = try await provider.fetchSnapshot()

        XCTAssertEqual(snapshot.windows.map(\.id), ["session", "weekly_all"])
        XCTAssertEqual(source.reads, 0, "the keychain was read even though the CLI answered")
        XCTAssertEqual(StubEndpoint.requestCount, 0, "the endpoint was called even though the CLI answered")
    }

    /// A CLI that cannot answer is a reason to ask the endpoint, never a reason
    /// to fail the refresh — otherwise installing Claude Code and signing out
    /// of it would take the ring down on a machine whose token is fine.
    func testAFailingCLIFallsBackToTheToken() async throws {
        StubEndpoint.reset([.init(status: 200, body: Self.usagePayload)])
        let source = CredentialSource(readable: true)
        let provider = makeProvider(source: source,
                                    cli: Self.cli(answering: "Please run /login first"))

        let snapshot = try await provider.fetchSnapshot()

        XCTAssertEqual(snapshot.windows.first?.id, "session")
        XCTAssertEqual(source.reads, 1, "the token path was not reached")
        XCTAssertEqual(StubEndpoint.requestCount, 1)
    }

    /// `UsageStore` polls every 60s while a session is busy, and each ask is a
    /// subprocess. The windows do not move enough in a minute to be worth one.
    func testTheCLIIsNotSpawnedOnEveryTick() async throws {
        let spawns = Counter()
        let provider = makeProvider(source: CredentialSource(readable: true),
                                    cli: Self.cli { spawns.increment(); return Self.cliUsage })

        _ = try await provider.fetchSnapshot()
        _ = try await provider.fetchSnapshot()
        _ = try await provider.fetchSnapshot()

        XCTAssertEqual(spawns.value, 1, "the CLI was spawned again inside its own interval")
    }

    func testReconnectDiscardsCLIReadingCache() async throws {
        let spawns = Counter()
        let provider = makeProvider(source: CredentialSource(readable: true),
                                    cli: Self.cli { spawns.increment(); return Self.cliUsage })
        _ = try await provider.fetchSnapshot()
        _ = try await provider.fetchSnapshotAfterReconnect()
        XCTAssertEqual(spawns.value, 2)
        XCTAssertEqual(StubEndpoint.requestCount, 0)
    }

    /// And it is asked again once the interval has passed, or the ring would
    /// show one reading for the rest of the session.
    func testTheCLIIsAskedAgainOnceTheIntervalPasses() async throws {
        let spawns = Counter()
        let provider = makeProvider(source: CredentialSource(readable: true),
                                    cli: Self.cli { spawns.increment(); return Self.cliUsage },
                                    cliRefreshInterval: 0)

        _ = try await provider.fetchSnapshot()
        _ = try await provider.fetchSnapshot()

        XCTAssertEqual(spawns.value, 2)
    }

    private static let cliUsage = """
    Current session: 38% used · resets Sep 7 at 2:59pm (Asia/Jakarta)
    Current week (all models): 4% used · resets Sep 14 at 5:59am (Asia/Jakarta)
    """

    private static func cli(answering text: String) -> ClaudeUsageCLI {
        cli { text }
    }

    private static func cli(_ answer: @escaping @Sendable () -> String) -> ClaudeUsageCLI {
        // The path is never run — `output` is what the provider reaches.
        ClaudeUsageCLI(binary: URL(fileURLWithPath: "/nonexistent/claude")) { _ in answer() }
    }

    private func assertNeedsAuth(from provider: ClaudeOAuthProvider,
                                 file: StaticString = #filePath,
                                 line: UInt = #line) async {
        do {
            _ = try await provider.fetchSnapshot()
            XCTFail("expected needsAuth, got a snapshot", file: file, line: line)
        } catch UsageProviderError.needsAuth {
            // expected
        } catch {
            XCTFail("expected needsAuth, got \(error)", file: file, line: line)
        }
    }
}

/// How many times the CLI was actually asked. "Did it spawn again?" is the
/// question the throttle exists to answer, and only a count answers it.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock(); count += 1; lock.unlock()
    }

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
}

/// Stands in for the keychain, and counts reads.
///
/// "Did it go back and ask?" is the whole question, and only a counter answers it.
private final class CredentialSource: @unchecked Sendable {
    private let lock = NSLock()
    private var readable: Bool
    private var readCount = 0

    init(readable: Bool) { self.readable = readable }

    var reads: Int {
        lock.lock(); defer { lock.unlock() }
        return readCount
    }

    func makeReadable() {
        lock.lock(); readable = true; lock.unlock()
    }

    func read() throws -> ClaudeCredentials {
        lock.lock()
        readCount += 1
        let allowed = readable
        lock.unlock()

        // The shape a dark-wake or not-found read takes by the time it leaves
        // `ClaudeCredentials.read()`.
        guard allowed else { throw UsageProviderError.needsAuth }
        return ClaudeCredentials(accessToken: "token",
                                 expiresAt: .distantFuture,
                                 subscriptionType: "max")
    }
}

/// Canned answers for the usage endpoint, and a count of how many requests
/// actually arrived. The repo had no URL stubbing, which is why nothing above
/// `retryAfter(from:)` was ever tested.
private final class StubEndpoint: URLProtocol {
    struct Answer {
        let status: Int
        var body: Data = Data()
        var headers: [String: String] = [:]
    }

    private static let lock = NSLock()
    private static var queued: [Answer] = []
    private static var served = 0
    /// One entry per request, in order, nil where the header was absent. Every
    /// request is checked, not just the first: the header is what keeps the
    /// endpoint out of its strict rate-limit bucket, and one call slipping
    /// through without it is the whole problem.
    private static var agents: [String?] = []

    static func reset(_ answers: [Answer]) {
        lock.lock(); queued = answers; served = 0; agents = []; lock.unlock()
    }

    static var userAgents: [String?] {
        lock.lock(); defer { lock.unlock() }
        return agents
    }

    static func record(userAgent: String?) {
        lock.lock(); agents.append(userAgent); lock.unlock()
    }

    static var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return served
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubEndpoint.self]
        return URLSession(configuration: configuration)
    }

    private static func next() -> Answer {
        lock.lock(); defer { lock.unlock() }
        served += 1
        // Running dry is a test bug, and a 500 says so more clearly than a crash
        // inside URLSession's callback would.
        return queued.isEmpty ? Answer(status: 500) : queued.removeFirst()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.record(userAgent: request.value(forHTTPHeaderField: "User-Agent"))
        let answer = Self.next()
        let response = HTTPURLResponse(url: request.url!,
                                       statusCode: answer.status,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: answer.headers.merging(["Content-Type": "application/json"]) { _, value in value })!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// `account()` must read through the injected credential source, like every
/// other read here.
///
/// It used to call the keychain directly, which made it impossible for a test
/// to build a real provider without touching the login keychain. On a test host
/// rebuilt with a fresh ad-hoc signature that means an authorization prompt,
/// and a prompt nobody answers hangs the whole suite — which is exactly what it
/// did, on `providerSummaries`.
final class ClaudeAccountSourceTests: XCTestCase {
    private func provider(_ load: @escaping @Sendable () throws -> ClaudeCredentials)
        -> ClaudeOAuthProvider {
        let name = "ClaudeAccountSourceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        // `cli: nil` as well as the injected source: `account()` answers from
        // Claude Code's own config where it can find it, so without this the
        // answer would come from whatever the developer has installed rather
        // than from the credential this test handed it.
        return ClaudeOAuthProvider(profile: .default(home: FileManager.default.temporaryDirectory.appendingPathComponent(name)),
                                   archive: UsageArchive(defaults: defaults),
                                   loadCredentials: load,
                                   cli: nil)
    }

    func testTheAccountSummaryNeverLoadsASecret() throws {
        var reads = 0
        let account = provider {
            reads += 1
            return ClaudeCredentials(accessToken: "t", expiresAt: .distantFuture,
                                     subscriptionType: "team")
        }.account()

        XCTAssertEqual(reads, 0, "settings must never load a secret")
        XCTAssertNil(account?.plan)
    }

    /// A source that has nothing is no account, and no crash.
    func testNoCredentialIsNoAccount() {
        XCTAssertNotNil(provider { throw UsageProviderError.needsAuth }.account())
    }
}

/// Parsing `claude --version`. The command's output format is not a contract,
/// so the parser takes the first thing shaped like a version and ignores the
/// rest rather than matching a whole line.
final class ClaudeVersionTests: XCTestCase {
    func testItTakesTheVersionOutOfTheUsualOutput() {
        XCTAssertEqual(ClaudeVersion.userAgent(output: "1.0.44 (Claude Code)\n"),
                       "claude-code/1.0.44")
    }

    func testAPrereleaseSuffixSurvives() {
        XCTAssertEqual(ClaudeVersion.parse("2.1.0-beta.3 (Claude Code)"), "2.1.0-beta.3")
    }

    /// Extra wording around it — a banner, a warning on stderr's way past — is
    /// not a reason to give up on a version that is right there.
    func testItFindsAVersionInAWordierAnswer() {
        XCTAssertEqual(ClaudeVersion.parse("Claude Code version 1.2.3, up to date"), "1.2.3")
    }

    /// Nothing recognisable means no header, never a guess.
    func testNothingVersionShapedMeansNoUserAgent() {
        XCTAssertNil(ClaudeVersion.userAgent(output: ""))
        XCTAssertNil(ClaudeVersion.userAgent(output: "command not found\n"))
        XCTAssertNil(ClaudeVersion.userAgent(output: "1.0"))
    }
}

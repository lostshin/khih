import XCTest
@testable import Codenotch

/// Which account `codex` is signed in to, decided by comparing the signed-in
/// account rather than a name. Everything here uses throwaway directories: the
/// real `~/.codex` is never read.
final class CodexActiveAccountTests: XCTestCase {
    private func directory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexActiveAccountTests.\(name).\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func writeAuth(_ home: URL, account: String, token: String = "fake") throws {
        let auth = ["tokens": ["access_token": token, "account_id": account]]
        try JSONSerialization.data(withJSONObject: auth)
            .write(to: home.appendingPathComponent("auth.json"))
    }

    private func profile(_ slug: String, at url: URL) -> CodexProfile {
        CodexProfile(slug: slug, configDirectory: url)
    }

    func testItNamesTheProfileSignedInToTheSameAccount() throws {
        let system = try directory("system")
        let mine = try directory("mine")
        let theirs = try directory("theirs")
        try writeAuth(system, account: "acct-one")
        try writeAuth(mine, account: "acct-one", token: "a-different-token")
        try writeAuth(theirs, account: "acct-two")

        let active = CodexActiveAccount(systemHome: system)
        XCTAssertEqual(active.providerID(among: [profile("theirs", at: theirs),
                                                 profile("mine", at: mine)]),
                       "codex-mine")
    }

    /// The token is refreshed constantly and differs between homes signed in to
    /// the same account, so only the account id may decide this.
    func testADifferentAccountIsNotAMatch() throws {
        let system = try directory("system")
        let other = try directory("other")
        try writeAuth(system, account: "acct-one")
        try writeAuth(other, account: "acct-two")

        XCTAssertNil(CodexActiveAccount(systemHome: system)
            .providerID(among: [profile("other", at: other)]))
    }

    func testNoSignInAtAllIsNotAMatch() throws {
        let system = try directory("system")
        let other = try directory("other")
        try writeAuth(other, account: "acct-two")

        // Nothing written to the system home at all.
        XCTAssertNil(CodexActiveAccount(systemHome: system)
            .providerID(among: [profile("other", at: other)]))
    }

    func testAnUnreadableSignInIsNotAMatch() throws {
        let system = try directory("system")
        let other = try directory("other")
        try Data("not json".utf8).write(to: system.appendingPathComponent("auth.json"))
        try writeAuth(other, account: "acct-two")

        XCTAssertNil(CodexActiveAccount(systemHome: system)
            .providerID(among: [profile("other", at: other)]))
    }

    /// Asked on every poll, so it must not re-read the file each time — but it
    /// must notice the file being replaced, which is how account switchers work.
    func testAnAnswerIsReusedUntilTheFileChanges() throws {
        let system = try directory("system")
        let one = try directory("one")
        let two = try directory("two")
        try writeAuth(system, account: "acct-one")
        try writeAuth(one, account: "acct-one")
        try writeAuth(two, account: "acct-two")
        let profiles = [profile("one", at: one), profile("two", at: two)]

        let active = CodexActiveAccount(systemHome: system)
        XCTAssertEqual(active.providerID(among: profiles), "codex-one")

        // Rewritten with a date the cache cannot mistake for the old one.
        try writeAuth(system, account: "acct-two")
        let path = system.appendingPathComponent("auth.json").path
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)],
                                              ofItemAtPath: path)
        XCTAssertEqual(active.providerID(among: profiles), "codex-two")
    }

    func testTheAnswerFollowsTheProfileListWithoutTheFileChanging() throws {
        let system = try directory("system")
        let one = try directory("one")
        try writeAuth(system, account: "acct-one")
        try writeAuth(one, account: "acct-one")

        let active = CodexActiveAccount(systemHome: system)
        XCTAssertNil(active.providerID(among: []))
        // An account added while the app is running must not be answered from
        // the cache taken before it existed.
        XCTAssertEqual(active.providerID(among: [profile("one", at: one)]), "codex-one")
    }
}

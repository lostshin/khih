import XCTest
@testable import Khih

final class BackgroundAuthenticationTests: XCTestCase {
    private func executable(_ body: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("fake-agy")
        try ("#!/bin/sh\n" + body).write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return file
    }

    func testBackgroundCLIAllowsOutputButBlocksBrowserLauncherAndAppleScript() throws {
        let binary = try executable("""
        test "$BROWSER" = /usr/bin/false || exit 2
        /usr/bin/open -h >/dev/null 2>&1 && exit 3
        /usr/bin/osascript -e 'return 1' >/dev/null 2>&1 && exit 4
        printf 'silent'
        """)
        let data = try BackgroundCLI.run(binary: binary, arguments: [], environment: [:], timeout: 3, cancelled: { false })
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "silent")
    }

    func testClientUsesBrowserProtectionAndDoesNotExposeOAuthOutput() throws {
        let binary = try executable("""
        test "$BROWSER" = /usr/bin/false || exit 2
        /usr/bin/open -h >/dev/null 2>&1 && exit 3
        echo 'https://example.test/oauth?state=private-fixture' >&2
        exit 1
        """)
        let client = AntigravityClient(binary: Lazily { binary }, environment: [:])
        XCTAssertThrowsError(try client.read(observedAt: 1_000_000)) { error in
            XCTAssertFalse(error.localizedDescription.contains("private-fixture"))
            XCTAssertFalse(String(describing: error).contains("https://"))
            XCTAssertTrue(error is AntigravityUsage.Failure)
        }
    }

    func testProtectedClientStillParsesOfficialUsage() throws {
        let rows = ["Gemini Models", "Claude and GPT models"].flatMap { group in
            ["Five Hour Limit Remaining", "Weekly Limit Remaining"].map {
                "\(group)\t\($0)\t75%\t2026-09-20T00:00:00Z"
            }
        }
        let data = try JSONSerialization.data(withJSONObject: ["status": "SUCCESS", "response": rows.joined(separator: "\n")])
        let json = String(decoding: data, as: UTF8.self)
        let binary = try executable("cat <<'FIXTURE'\n" + json + "\nFIXTURE\n")
        let client = AntigravityClient(binary: Lazily { binary }, environment: ["PATH": "/usr/bin:/bin"])
        let snapshot = try client.read(observedAt: 1_000_000)
        XCTAssertEqual(snapshot.buckets.count, 2)
        XCTAssertEqual(snapshot.buckets[0].primary?.usedPercent, 25)
        XCTAssertEqual(snapshot.buckets[1].secondary?.usedPercent, 25)
    }

    func testTraditionalChineseErrorsDoNotFallBackToSystemCodes() {
        let old = L10n.testLocale
        L10n.testLocale = Locale(identifier: "zh-Hant-TW")
        defer { L10n.testLocale = old }
        XCTAssertTrue(ClaudeUsageError.accessDenied.localizedDescription.contains("允許存取"))
        XCTAssertTrue(ClaudeUsageError.credentialExpired.localizedDescription.contains("過期"))
        XCTAssertEqual(ClaudeUsageError.badResponse(status: 503).localizedDescription, "Claude 額度請求失敗（HTTP 503），請稍後再試。")
        XCTAssertTrue(AntigravityUsage.Failure.backgroundReadFailed.localizedDescription.contains("禁止開啟瀏覽器"))
    }

    func testRefusedAndExpiredClaudeCredentialsNeverUseFallback() throws {
        var fileReads = 0
        for failure in [UsageProviderError.accessDenied, .credentialExpired] {
            XCTAssertThrowsError(try ClaudeToken.load(readCredential: { throw failure }, readFile: {
                fileReads += 1
                return "stale-fixture"
            })) { error in
                XCTAssertTrue(error is ClaudeUsageError)
            }
        }
        XCTAssertThrowsError(try ClaudeToken.load(readCredential: {
            ClaudeCredentials(accessToken: "expired-fixture", expiresAt: .distantPast, subscriptionType: nil)
        }, readFile: { fileReads += 1; return "stale-fixture" })) { error in
            XCTAssertEqual(error as? ClaudeUsageError, .credentialExpired)
        }
        XCTAssertEqual(fileReads, 0)
        XCTAssertEqual(try ClaudeToken.load(readCredential: { throw UsageProviderError.needsAuth }, readFile: { "file-fixture" }), "file-fixture")
        XCTAssertEqual(try ClaudeToken.load(readCredential: {
            ClaudeCredentials(accessToken: "valid-fixture", expiresAt: .distantFuture, subscriptionType: nil)
        }, readFile: { nil }), "valid-fixture")
    }

    func testClaudeErrorsExplainActionRatherThanNSErrorCode() {
        for error in [ClaudeUsageError.needsAuth, .accessDenied, .credentialExpired, .unreadable, .badResponse(status: 503)] {
            XCTAssertFalse(error.localizedDescription.contains("ClaudeUsageError"))
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
        XCTAssertTrue(ClaudeUsageError.badResponse(status: 503).localizedDescription.contains("503"))
    }
}

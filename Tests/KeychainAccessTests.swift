import XCTest
import Security
@testable import Codenotch

final class KeychainAccessTests: XCTestCase {
    func testSilentAndExplicitAccessRestoreInteractionAfterSuccessAndCancellation() throws {
        var allowed = true
        var transitions: [Bool] = []
        let gate = KeychainAccess(get: { pointer in
            pointer.pointee = DarwinBoolean(allowed)
            return errSecSuccess
        }, set: { value in
            allowed = value
            transitions.append(value)
            return errSecSuccess
        })
        try gate.perform { XCTAssertFalse(allowed) }
        XCTAssertTrue(allowed)
        allowed = false
        XCTAssertThrowsError(try gate.perform(interactive: true) {
            XCTAssertTrue(allowed)
            throw UsageProviderError.accessDenied
        })
        XCTAssertFalse(allowed)
        try gate.perform { XCTAssertFalse(allowed) }
        XCTAssertEqual(transitions, [false, true, true, false, false, false])
    }

    func testCredentialRotationAndDeniedAuthorizationStaySilentInBackground() throws {
        var stamp = Date(timeIntervalSince1970: 100)
        var denied = true
        var interactiveReads: [Bool] = []
        let reader = ClaudeKeychain(services: ["anonymous-test"], modifiedAt: { stamp }, read: { interactive in
            interactiveReads.append(interactive)
            if denied { throw UsageProviderError.accessDenied }
            return ClaudeCredentials(accessToken: "fixture", expiresAt: .distantFuture, subscriptionType: nil)
        })
        XCTAssertThrowsError(try reader.load())
        XCTAssertThrowsError(try reader.load())
        XCTAssertEqual(interactiveReads, [false])
        XCTAssertThrowsError(try reader.authorize())
        XCTAssertThrowsError(try reader.load())
        XCTAssertEqual(interactiveReads, [false, true])
        denied = false
        try reader.authorize()
        _ = try reader.load()
        XCTAssertEqual(interactiveReads, [false, true, true])
        stamp = Date(timeIntervalSince1970: 200)
        _ = try reader.load()
        XCTAssertEqual(interactiveReads, [false, true, true, false])
    }

    func testFailureToDisableInteractionNeverReadsSecret() {
        var read = false
        let gate = KeychainAccess(get: { _ in errSecSuccess }, set: { _ in errSecAuthFailed })
        XCTAssertThrowsError(try gate.perform { read = true })
        XCTAssertFalse(read)
    }
}

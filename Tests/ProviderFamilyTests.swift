import XCTest
@testable import Khih

final class ProviderFamilyTests: XCTestCase {
    func testEachProviderIsFiledUnderWhoseAccountItReads() {
        XCTAssertEqual(ProviderFamily.of(providerID: "codex"), .openAI)
        XCTAssertEqual(ProviderFamily.of(providerID: "codex-account-a"), .openAI)
        XCTAssertEqual(ProviderFamily.of(providerID: "claude"), .anthropic)
        XCTAssertEqual(ProviderFamily.of(providerID: "claude-work"), .anthropic)
        // Antigravity is read under the id `gemini`, for historical reasons the
        // preferences depend on.
        XCTAssertEqual(ProviderFamily.of(providerID: "gemini"), .google)
        XCTAssertEqual(ProviderFamily.of(providerID: "gemini-api"), .google)
        XCTAssertEqual(ProviderFamily.of(providerID: "cursor"), .other)
        XCTAssertEqual(ProviderFamily.of(providerID: "ollama"), .other)
    }

    func testAGroupSitsWhereItsFirstMemberSat() {
        let ids = ["claude", "codex-a", "gemini", "codex-b"]
        let groups = ProviderFamily.groups(ids, id: { $0 })
        XCTAssertEqual(groups.map(\.family), [.anthropic, .openAI, .google])
        XCTAssertEqual(groups[1].items, ["codex-a", "codex-b"])
    }

    func testTheLeftoversAlwaysComeLast() {
        let ids = ["cursor", "codex-a", "claude"]
        let groups = ProviderFamily.groups(ids, id: { $0 })
        XCTAssertEqual(groups.map(\.family), [.openAI, .anthropic, .other])
        XCTAssertEqual(groups.last?.items, ["cursor"])
    }

    func testNothingIsLost() {
        let ids = ["codex-a", "cursor", "claude", "gemini", "codex-b", "grok"]
        let groups = ProviderFamily.groups(ids, id: { $0 })
        XCTAssertEqual(Set(groups.flatMap(\.items)), Set(ids))
        XCTAssertEqual(groups.flatMap(\.items).count, ids.count)
    }

    func testAnEmptyListHasNoHeadings() {
        XCTAssertTrue(ProviderFamily.groups([String](), id: { $0 }).isEmpty)
    }
}

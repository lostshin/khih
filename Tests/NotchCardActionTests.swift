import XCTest
@testable import Khih

/// A click on an open card checks the accounts behind it. Both halves are pure:
/// which accounts a card stands for, and the one line that reports back.
@MainActor
final class NotchCardActionTests: XCTestCase {
    private func snapshot(_ id: String, sources: [String]? = nil) -> ProviderSnapshot {
        ProviderSnapshot(id: id, displayName: id, glyph: .openai, fidelity: .official,
                         status: .ok,
                         windows: [LimitWindow(id: "primary", label: "5h", usedFraction: 0.1,
                                               duration: 5 * 3600)],
                         sourceProviderIDs: sources)
    }

    func testTheMergedCellStandsForEveryAccountBehindIt() {
        let cell = snapshot("codex:accounts", sources: ["codex-a", "codex-b", "codex-c"])
        XCTAssertEqual(
            NotchWindowController.manualCheckTargets(for: cell, among: ["codex-a", "codex-b", "codex-c"]),
            ["codex-a", "codex-b", "codex-c"])
    }

    func testAnAccountWithNoEngineBehindItIsNotChecked() {
        let cell = snapshot("codex:accounts", sources: ["codex-a", "codex-unmanaged"])
        XCTAssertEqual(NotchWindowController.manualCheckTargets(for: cell, among: ["codex-a"]),
                       ["codex-a"])
    }

    /// A local runtime has no engine at all, and its card must go on doing what
    /// it always did when clicked.
    func testACardWithNothingToCheckOffersNothing() {
        XCTAssertTrue(NotchWindowController.manualCheckTargets(for: snapshot("ollama"),
                                                              among: ["codex-a"]).isEmpty)
    }

    func testASingleAccountCardStandsForItself() {
        XCTAssertEqual(NotchWindowController.manualCheckTargets(for: snapshot("claude"),
                                                               among: ["claude", "codex-a"]),
                       ["claude"])
    }

    // MARK: - The line the card shows

    func testOneAccountSpeaksForItselfEvenWhenThereWasNothingToDo() {
        XCTAssertEqual(CheckSummaryCopy.line(for: [.baseline]), CheckOutcome.baseline.message)
    }

    func testSeveralQuietAccountsCollapseIntoACount() {
        let line = CheckSummaryCopy.line(for: [.baseline, .noReset, .alreadyHandled, .countdownAlreadyActive])
        XCTAssertEqual(line, L10n.t("Checked \(4) accounts — nothing to do."))
    }

    func testTheOneAccountWithSomethingToSayIsWhatIsShown() {
        let line = CheckSummaryCopy.line(for: [.baseline, .failed("no binary"), .noReset])
        XCTAssertEqual(line, CheckOutcome.failed("no binary").message)
    }

    func testSeveralNotableOutcomesSayHowManyMoreThereAre() {
        let line = CheckSummaryCopy.line(for: [.failed("first"), .poked(.verified), .baseline])
        XCTAssertEqual(line, CheckOutcome.failed("first").message + " " + L10n.t("(\(1) more)"))
    }

    func testCheckingNothingSaysNothing() {
        XCTAssertNil(CheckSummaryCopy.line(for: []))
    }

    func testTheChineseWordingIsTranslated() {
        let locale = Locale(identifier: "zh-Hant-TW")
        XCTAssertEqual(L10n.t("Checked \(3) accounts — nothing to do.", locale: locale),
                       "已檢查 3 個帳號，沒有需要處理的項目。")
        XCTAssertEqual(L10n.t("(\(2) more)", locale: locale), "（另有 2 筆）")
        // Already in the catalogue, reused rather than respelled.
        XCTAssertEqual(L10n.t("Checking…", locale: locale), "正在檢查…")
        XCTAssertEqual(L10n.t("In use", locale: locale), "使用中")
        XCTAssertEqual(L10n.t("Other tools", locale: locale), "其他工具")
    }
}

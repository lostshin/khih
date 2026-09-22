import XCTest
import SwiftUI
@testable import Khih

@MainActor
final class GroupedProviderTests: XCTestCase {
    private func account(_ id: String, used: Double, weekly: Double) -> ProviderSnapshot {
        ProviderSnapshot(id: id, displayName: id, glyph: .openai, fidelity: .official,
                         status: .ok, windows: [
                            LimitWindow(id: "primary", label: "5h", usedFraction: used, duration: 5 * 3600),
                            LimitWindow(id: "secondary", label: "Weekly", usedFraction: weekly, duration: 7 * 86400)
                         ])
    }

    /// An account on a plan that bills by the month reports no session window.
    private func monthlyOnly(_ id: String, used: Double) -> ProviderSnapshot {
        ProviderSnapshot(id: id, displayName: id, glyph: .openai, fidelity: .official,
                         status: .ok, windows: [
                            LimitWindow(id: "primary", label: "Monthly", usedFraction: used, duration: 30 * 86400)
                         ])
    }

    func testSameNameGroupsKeepTheirSourceAndIgnoreGaps() {
        let accounts = ["codex-a", "codex-b", "codex-c"].map { id in
            ProviderSnapshot(id: id, displayName: "Same name", glyph: .openai,
                fidelity: .official, status: .ok, windows: [
                    LimitWindow(id: "primary", label: "5h", usedFraction: 0, duration: 18000),
                    LimitWindow(id: "secondary", label: "Weekly", usedFraction: 0.2, duration: 604800)])
        }
        let cell = ProviderOrder.cells(from: accounts, keeping: [], activeCodexID: nil)[0]
        let groups = TooltipWindowGroup.groups(cell.windows)
        XCTAssertEqual(groups.map(\.sourceProviderID), ["codex-a", "codex-b", "codex-c"])
        XCTAssertEqual(groups.map { $0.windows.count }, [2, 2, 2])
        XCTAssertEqual(cell.windowGroupCount, 3)
        let frames = ["codex-a": CGRect(x: 0, y: 0, width: 100, height: 80),
                      "codex-b": CGRect(x: 0, y: 100, width: 100, height: 80)]
        XCTAssertEqual(NotchWindowController.groupTarget(at: CGPoint(x: 50, y: 120), snapshot: cell, frames: frames), "codex-b")
        XCTAssertNil(NotchWindowController.groupTarget(at: CGPoint(x: 50, y: 90), snapshot: cell, frames: frames))
    }

    func testCheckingFeedbackIsVisibleWithoutAReading() {
        let cell = account("claude", used: 1, weekly: 1)
        let model = NotchViewModel()
        model.checkingCells.insert(cell.id)
        XCTAssertTrue(model.isRefreshing(cell))
        model.checkingCells.remove(cell.id)
        XCTAssertFalse(model.isRefreshing(cell))
    }

    func testThreeAccountsBecomeOneCellWithSixDistinctWindows() {
        let accounts = [account("codex-a", used: 0.1, weekly: 0.2),
                        account("codex-b", used: 0.3, weekly: 0.7),
                        account("codex-c", used: 0, weekly: 0.4)]
        let cells = ProviderOrder.cells(from: accounts, keeping: [], activeCodexID: nil)
        XCTAssertEqual(cells.count, 1)
        // The first account's session window, not the fullest window anywhere:
        // 10% of codex-a's five hours is spent, so 90% of it is left.
        XCTAssertEqual(cells[0].headlineText, "90%")
        XCTAssertEqual(cells[0].windows.count, 6)
        XCTAssertEqual(Set(cells[0].windows.map(\.id)).count, 6)
        XCTAssertEqual(cells[0].windowGroupCount, 3)
        XCTAssertEqual(cells[0].refreshProviderIDs, accounts.map(\.id))
        XCTAssertEqual(ProviderOrder.cells(from: cells, keeping: cells, activeCodexID: nil), cells, "must not group a display cell twice")
    }

    func testUnavailableAccountIsNotSilentlyDropped() {
        var absent = account("codex-b", used: 0, weekly: 0)
        absent.status = .needsAuth
        let cells = ProviderOrder.cells(from: [account("codex-a", used: 0.2, weekly: 0.5), absent],
                                            keeping: [], activeCodexID: nil)
        XCTAssertNotEqual(cells[0].status, .ok)
        XCTAssertEqual(cells[0].windowGroupCount, 2)
    }

    func testGroupingKeepsOtherProvidersAndPosition() {
        let other = account("claude", used: 0.1, weekly: 0.1)
        let cells = ProviderOrder.cells(from: [other, account("codex-b", used: 0.2, weekly: 0.2),
                                                account("codex-a", used: 0.3, weekly: 0.3)],
                                        keeping: [], activeCodexID: nil)
        XCTAssertEqual(cells.map(\.id), ["claude", "codex:accounts"])
        XCTAssertEqual(cells[1].refreshProviderIDs, ["codex-b", "codex-a"])
    }

    func testGroupedRefreshVisitsEveryAccountAndUsesTheirBusyState() async {
        let cell = ProviderOrder.cells(from: [account("codex-a", used: 0, weekly: 0),
                                               account("codex-b", used: 0, weekly: 0)],
                                       keeping: [], activeCodexID: nil)[0]
        let model = NotchViewModel()
        model.refreshing = ["codex-b"]
        XCTAssertTrue(model.isRefreshing(cell))
        var refreshed: [String] = []
        await model.refresh(cell) { refreshed.append($0) }
        XCTAssertEqual(refreshed, ["codex-a", "codex-b"])
    }

    func testTheRingQuotesTheAccountCodexIsSignedInTo() {
        let accounts = [account("codex-a", used: 0.9, weekly: 0.2),
                        account("codex-b", used: 0.1, weekly: 0.7)]
        let cell = ProviderOrder.cells(from: accounts, keeping: [], activeCodexID: "codex-b")[0]
        // codex-b has 90% of its session left, and is the one being spent.
        XCTAssertEqual(cell.headlineText, "90%")
        XCTAssertEqual(cell.headline?.id, "codex-b:primary")
    }

    /// Marked by the outline the card draws, not by a word in the title: every
    /// group already shows its account name, and the detail is mostly numbers.
    func testTheAccountInUseIsFlaggedWithoutChangingItsTitle() {
        let accounts = [account("codex-a", used: 0.2, weekly: 0.2),
                        account("codex-b", used: 0.2, weekly: 0.2)]
        let cell = ProviderOrder.cells(from: accounts, keeping: [], activeCodexID: "codex-b")[0]
        let titles = Set(cell.windows.compactMap(\.group))
        XCTAssertEqual(titles, ["codex-a", "codex-b"], "the title carries no in-use wording")

        let active = Set(cell.windows.filter(\.isActiveAccount).compactMap(\.group))
        XCTAssertEqual(active, ["codex-b"], "only the signed-in account is flagged")

        let groups = TooltipWindowGroup.groups(cell.windows)
        XCTAssertEqual(Set(groups.filter(\.isActiveAccount).map(\.id)), ["codex-b"],
                       "the flag survives into the group the card outlines")
    }

    func testNoAccountIsFlaggedWhenNoneIsSignedIn() {
        let accounts = [account("codex-a", used: 0.2, weekly: 0.2),
                        account("codex-b", used: 0.2, weekly: 0.2)]
        let cell = ProviderOrder.cells(from: accounts, keeping: [], activeCodexID: nil)[0]
        XCTAssertTrue(cell.windows.allSatisfy { !$0.isActiveAccount })
    }

    func testAnAccountWithNoSessionWindowFallsBackToOneThatHasOne() {
        let accounts = [monthlyOnly("codex-a", used: 0.5),
                        account("codex-b", used: 0.4, weekly: 0.9)]
        // Signed in to the account billed by the month, which has no session.
        let cell = ProviderOrder.cells(from: accounts, keeping: [], activeCodexID: "codex-a")[0]
        XCTAssertEqual(cell.headline?.id, "codex-b:primary")
    }

    func testAnUnknownSignInFallsBackRatherThanLosingTheHeadline() {
        let accounts = [account("codex-a", used: 0.4, weekly: 0.9),
                        account("codex-b", used: 0.2, weekly: 0.2)]
        // Signed in to an account this app does not manage.
        let cell = ProviderOrder.cells(from: accounts, keeping: [], activeCodexID: "codex-elsewhere")[0]
        XCTAssertEqual(cell.headline?.id, "codex-a:primary")
    }

    func testWithNoSessionWindowAnywhereTheFullestWindowStillNamesTheRing() {
        let accounts = [monthlyOnly("codex-a", used: 0.5), monthlyOnly("codex-b", used: 0.8)]
        let cell = ProviderOrder.cells(from: accounts, keeping: [], activeCodexID: nil)[0]
        XCTAssertEqual(cell.headline?.id, "codex-b:primary")
    }

    func testClaudeCardsDoNotListLiveSessions() {
        let model = NotchViewModel()
        let session = AgentSession(id: "s", name: "repo", detail: "idle",
                                   state: .idle, waitingFor: nil, since: Date())
        model.sessions = ["claude": [session], "codex-a": [session]]

        let claude = ProviderSnapshot(id: "claude", displayName: "Claude", glyph: .claude,
                                      fidelity: .official, status: .ok, windows: [])
        let codex = ProviderSnapshot(id: "codex-a", displayName: "Codex", glyph: .openai,
                                     fidelity: .official, status: .ok, windows: [])
        // Claude's monitor keeps a row for as long as the process lives, idle
        // included, so the list sat under the quota rows permanently.
        XCTAssertNil(model.activity(for: claude))
        XCTAssertEqual(model.activity(for: codex)?.sessions.count, 1)
    }

    func testDroppingTheSessionListShortensTheCard() {
        let windows = [LimitWindow(id: "session", label: "5h limit", usedFraction: 0.1, duration: 5 * 3600),
                       LimitWindow(id: "weekly_all", label: "Weekly limit", usedFraction: 0.25,
                                   duration: 7 * 86400)]
        let bare = NotchLayout.cardHeight(windowCount: windows.count, sessionCount: 0)
        let withSessions = NotchLayout.cardHeight(windowCount: windows.count, sessionCount: 2)
        XCTAssertLessThan(bare, withSessions, "the hover region must shrink with the card")
    }

    func testTaiwanTraditionalChineseGroupNames() {
        XCTAssertEqual(L10n.t("Gemini Models", locale: Locale(identifier: "zh-Hant-TW")), "Gemini 模型群組")
        XCTAssertEqual(L10n.t("Claude and GPT models", locale: Locale(identifier: "zh-Hant-TW")), "Claude／GPT 模型群組")
    }
}

@MainActor
final class GroupedTooltipRenderTests: XCTestCase {
    func testGroupedCodexAndAntigravityTooltipFitsWithoutLosingDetails() throws {
        let now: Int64 = 1_800_000_000
        let reading = QuotaBurnReading(observedAt: now,
            rate: BurnRate(fiveHourDeltaTotal: 200, weeklyDeltaTotal: 30),
            fiveHour: QuotaWindow(usedPercent: 0, windowDurationMins: 300, resetsAt: now + 18000, observedAt: now),
            weekly: QuotaWindow(usedPercent: 40, windowDurationMins: 10080, resetsAt: now + 604800, observedAt: now))
        let oldLocale = L10n.testLocale
        L10n.testLocale = Locale(identifier: "zh-Hant-TW")
        defer { L10n.testLocale = oldLocale }
        XCTAssertEqual(reading.lines(now: now)[0], "每滿 5h 約用 15.0% 週額度")
        let accounts = (1...3).map { index in
            var weekly = LimitWindow(id: "secondary", label: "每週額度", usedFraction: Double(index) / 10,
                                     resetsAt: Date(timeIntervalSince1970: Double(now + 604800)), duration: 604800)
            weekly.burnReading = reading
            return ProviderSnapshot(id: "codex-\(index)", displayName: "測試帳號 \(index)", glyph: .openai,
                                    fidelity: .official, status: .ok, windows: [
                                        LimitWindow(id: "primary", label: "5 小時額度", usedFraction: 0.2,
                                                    resetsAt: Date(timeIntervalSince1970: Double(now + 18000)),
                                                    duration: 18000), weekly])
        }
        let codex = ProviderOrder.cells(from: accounts, keeping: [], activeCodexID: nil)[0]
        // The same card with the ring following one account. Its group title is
        // longer than the others, and `cardHeight` allows a group title exactly
        // one line — so this has to be looked at, not just asserted on.
        let codexInUse = ProviderOrder.cells(from: accounts, keeping: [], activeCodexID: "codex-2")[0]
        XCTAssertEqual(codexInUse.headline?.id, "codex-2:primary")
        var agy = ProviderSnapshot(id: "gemini", displayName: "Antigravity", glyph: .antigravity,
                                  fidelity: .official, status: .ok, windows: [])
        for (index, title) in ["Gemini 模型群組", "Claude／GPT 模型群組"].enumerated() {
            agy.windows += accounts[index].windows.enumerated().map { offset, original in
                var window = LimitWindow(id: "\(index)-\(offset)", group: title, label: original.label,
                                         usedFraction: original.usedFraction, resetsAt: original.resetsAt,
                                         duration: original.duration)
                window.burnReading = original.burnReading
                return window
            }
        }
        // Claude's own card: two quota rows and the burn-rate line, and nothing
        // else — the same shape as the other two.
        var claudeWeekly = LimitWindow(id: "weekly_all", label: L10n.t("Weekly limit"), usedFraction: 0.25,
                                       resetsAt: Date(timeIntervalSince1970: Double(now + 604800)),
                                       duration: 604800)
        claudeWeekly.burnReading = reading
        let claude = ProviderSnapshot(id: "claude", displayName: "Claude", glyph: .claude,
                                      fidelity: .official, status: .ok, windows: [
                                        LimitWindow(id: "session", label: L10n.t("\(5)h limit"),
                                                    usedFraction: 0.1,
                                                    resetsAt: Date(timeIntervalSince1970: Double(now + 18000)),
                                                    duration: 18000),
                                        claudeWeekly], headlineID: "session")
        XCTAssertEqual(claude.windows.map(\.label), ["5 小時額度", "每週額度"])

        // Claude's card is legitimately the short one: two rows and a line,
        // against three accounts' worth of grouped rows.
        for (name, snapshot, floor) in [("codex", codex, 400.0), ("codex-in-use", codexInUse, 400.0),
                                        ("antigravity", agy, 400.0), ("claude", claude, 150.0)] {
            for scheme in [ColorScheme.light, .dark] {
                let view = TooltipCard(snapshot: snapshot, activity: nil,
                                       now: Date(timeIntervalSince1970: Double(now)),
                                       groupMessages: ["codex-2": L10n.t("Not sent — a five-hour countdown is already running.")])
                    .environment(\.colorScheme, scheme)
                    .padding(20).background(Color.gray.opacity(0.15))
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                let image = try XCTUnwrap(renderer.nsImage)
                XCTAssertLessThan(image.size.height, 900, "must fit a 900-point display")
                XCTAssertGreaterThan(image.size.height, floor)
                if let directory = ProcessInfo.processInfo.environment["GROUPED_RENDER_DIR"] {
                    let tiff = try XCTUnwrap(image.tiffRepresentation)
                    let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
                    try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name)-\(scheme).png"))
                }
            }
        }
    }
}

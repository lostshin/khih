import XCTest
@testable import Khih

@MainActor
final class StatusMenuTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_788_000_000)

    private func snapshot(
        id: String = "codex", name: String = "Codex",
        status: ProviderStatus = .ok,
        windows: [LimitWindow] = [],
        headlineID: String? = nil,
        block: UsageBlock? = nil
    ) -> ProviderSnapshot {
        ProviderSnapshot(id: id, displayName: name, glyph: .openai,
                         fidelity: .official, status: status,
                         windows: windows, headlineID: headlineID, block: block)
    }

    /// One window reads as one line with the same three facts the tooltip
    /// spreads over three lines: label, percentage, reset.
    func testAWindowReadsAsOneLineWithLabelSummaryAndReset() {
        let line = StatusItemController.windowLine(
            for: LimitWindow(id: "primary", label: "5h limit", usedFraction: 0.08,
                             resetsAt: now.addingTimeInterval(51 * 60)),
            now: now)
        XCTAssertTrue(line.contains("5h limit"), line)
        XCTAssertTrue(line.contains("8% Used · 92% left"), line)
        XCTAssertTrue(line.contains("Resets in 51 min"), line)
    }

    /// A window with no reset says so by saying nothing — never invented.
    func testAWindowWithoutAResetOmitsIt() {
        let line = StatusItemController.windowLine(
            for: LimitWindow(id: "primary", label: "5h limit", usedFraction: 0.08),
            now: now)
        XCTAssertTrue(line.contains("5h limit"), line)
        XCTAssertFalse(line.contains("Resets"), line)
    }

    /// The blocked line leads, because it changes what you can do next while
    /// the percentage beside it still reads comfortable.
    func testABlockLeadsTheDetails() {
        let details = StatusItemController.detailLines(for: snapshot(
            status: .ok,
            windows: [LimitWindow(id: "primary", label: "5h limit", usedFraction: 0.16)],
            block: UsageBlock(reason: "Paused", resetsAt: now.addingTimeInterval(90 * 60))
        ), now: now)
        XCTAssertEqual(details.count, 2)
        XCTAssertTrue(details[0].hasPrefix("Paused until "), details[0])
        XCTAssertTrue(details[1].contains("5h limit"), details[1])
    }

    /// Nothing metered reads as the tooltip's own status message, not blank.
    func testNoWindowsReadsAsTheStatusMessage() {
        let details = StatusItemController.detailLines(
            for: snapshot(status: .needsAuth), now: now)
        XCTAssertEqual(details, ["Sign in to Codex to read your usage"])
    }

    /// The header carries the headline figure and the reading's age — the same
    /// pair the tooltip header shows.
    func testTheMenuListsEveryProviderWithRefreshAndSettings() {
        let controller = StatusItemController(onOpenSettings: {})
        controller.snapshots = [snapshot(
            status: .stale(since: now.addingTimeInterval(-(20 * 3600 + 21 * 60))),
            windows: [LimitWindow(id: "secondary", label: "Weekly limit",
                                   usedFraction: 0.29,
                                   resetsAt: now.addingTimeInterval(3600))],
            headlineID: "secondary")]
        let menu = NSMenu()
        controller.rebuild(menu: menu, now: now)
        let titles = menu.items.map(\.title)
        // The menu's headline is the ring's: what is left.
        XCTAssertTrue(titles[0].contains("Codex — 71%"), titles[0])
        XCTAssertTrue(titles[0].contains("20 hr 21 min ago"), titles[0])
        XCTAssertTrue(titles[1].contains("Weekly limit"), titles[1])
        XCTAssertTrue(titles[1].contains("29% Used · 71% left"), titles[1])
        XCTAssertTrue(titles.contains("Refresh all"))
        XCTAssertTrue(titles.contains("Settings…"))
        XCTAssertTrue(titles.contains("Quit Khih"))
        // The header re-reads its own provider.
        XCTAssertEqual(menu.items[0].representedObject as? String, "codex")
    }

    /// With no readings yet the menu says so instead of showing an empty list.
    func testAnEmptyMenuSaysItIsWaiting() {
        let controller = StatusItemController(onOpenSettings: {})
        let menu = NSMenu()
        controller.rebuild(menu: menu, now: now)
        XCTAssertTrue(menu.items[0].title.contains("Waiting for the first reading"))
    }
}



/// Declining the keychain prompt is easy to do by reflex. Until now it was
/// reported as being signed out — sending someone who *is* signed in to fix
/// something that is not broken — and nothing on screen would ask again.

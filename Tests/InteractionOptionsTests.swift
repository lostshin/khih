import XCTest
import AppKit
import SwiftUI
@testable import Codenotch

@MainActor
final class InteractionOptionsTests: XCTestCase {
    func testDefaultsAndPersistence() {
        let name = "InteractionOptionsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = Preferences(defaults: defaults)
        XCTAssertTrue(preferences.detailsOnClick)
        XCTAssertFalse(preferences.detailsShowRemaining)
        preferences.detailsOnClick = false
        preferences.detailsShowRemaining = true
        let restored = Preferences(defaults: defaults)
        XCTAssertFalse(restored.detailsOnClick)
        XCTAssertTrue(restored.detailsShowRemaining)
    }

    func testHoverDoesNotOpenOrSwitchClickedDetailsAndToggleRestoresHover() {
        let controller = NotchWindowController()
        controller.model.snapshots = ["fixture-a", "fixture-b"].map {
            ProviderSnapshot(id: $0, displayName: "Fixture", glyph: .openai,
                fidelity: .official, status: .ok, windows: [])
        }
        controller.show()
        defer { controller.stop() }
        controller.model.isExpanded = true
        controller.updateHoveredDetail(0)
        XCTAssertNil(controller.model.hoveredIndex)
        controller.model.onCheckCell?(controller.model.snapshots[0])
        XCTAssertEqual(controller.model.hoveredIndex, 0)
        controller.updateHoveredDetail(1)
        XCTAssertEqual(controller.model.hoveredIndex, 0)
        controller.model.detailsOnClick = false
        controller.updateHoveredDetail(1)
        XCTAssertEqual(controller.model.hoveredIndex, 1)
    }

    func testQuotaDisplaySwitchesBothBarAndTextWithoutChangingEvidence() {
        let locale = Locale(identifier: "zh-Hant-TW")
        let window = LimitWindow(id: "five-hour", label: "5h", usedFraction: 0.25, duration: 18000)
        XCTAssertEqual(QuotaDetailDisplay.fraction(window, remaining: false), 0.25)
        XCTAssertEqual(QuotaDetailDisplay.fraction(window, remaining: true), 0.75)
        XCTAssertEqual(QuotaDetailDisplay.summary(window, remaining: false, locale: locale), "25% 已用")
        XCTAssertEqual(QuotaDetailDisplay.summary(window, remaining: true, locale: locale), "75% 剩餘")
        XCTAssertEqual(window.usedFraction, 0.25)
        let unknown = LimitWindow(id: "unknown", label: "5h")
        XCTAssertNil(QuotaDetailDisplay.fraction(unknown, remaining: true))
        XCTAssertEqual(QuotaDetailDisplay.summary(unknown, remaining: true, locale: locale), "尚無讀值")
        for (used, remaining) in [(0.0, 1.0), (1.0, 0.0)] {
            let edge = LimitWindow(id: "edge", label: "5h", usedFraction: used)
            XCTAssertEqual(QuotaDetailDisplay.fraction(edge, remaining: true), remaining)
        }
    }

    func testAppearanceOptionsAndQuotaModesRenderInTraditionalChinese() async throws {
        let name = "InteractionOptionsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let oldLocale = L10n.testLocale
        L10n.testLocale = Locale(identifier: "zh-Hant-TW")
        defer { defaults.removePersistentDomain(forName: name); L10n.testLocale = oldLocale }
        let preferences = Preferences(defaults: defaults)
        let settings = SettingsView(preferences: preferences, providers: { [] },
            signOut: { _ in }, signIn: { _ in false }, switchAccount: { _ in false },
            retry: { _ in }, resetPosition: {}, updater: Updater())
        let snapshot = ProviderSnapshot(id: "claude", displayName: "Claude", glyph: .claude,
            fidelity: .official, status: .ok, windows: [
                LimitWindow(id: "session", label: "5 小時額度", usedFraction: 0.25, duration: 18000),
                LimitWindow(id: "weekly_all", label: "每週額度", usedFraction: 0.6, duration: 604800)])
        for scheme in [ColorScheme.light, .dark] {
            for (name, content) in [
                ("appearance", AnyView(settings.appearancePane.frame(width: 520, height: 520))),
                ("used", AnyView(TooltipCard(snapshot: snapshot, now: Date(timeIntervalSince1970: 1_800_000_000))
                    .environment(\.quotaDetailsShowRemaining, false))),
                ("remaining", AnyView(TooltipCard(snapshot: snapshot, now: Date(timeIntervalSince1970: 1_800_000_000))
                    .environment(\.quotaDetailsShowRemaining, true)))
            ] {
                let host = NSHostingView(rootView: content
                    .background(scheme == .light ? Color.white : Color(white: 0.15))
                    .environment(\.colorScheme, scheme))
                host.frame = CGRect(origin: .zero, size: host.fittingSize)
                let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
                window.contentView = host
                window.orderFrontRegardless()
                try await Task.sleep(nanoseconds: 150_000_000)
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                window.close()
                if let directory = ProcessInfo.processInfo.environment["RING_RENDER_DIR"] {
                    let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name)-\(scheme).png"))
                }
            }
        }
    }

    private final class CloseDelegate: NSObject, NSWindowDelegate {
        var allowsClose = false
        var closes = 0
        func windowShouldClose(_ sender: NSWindow) -> Bool { allowsClose }
        func windowWillClose(_ notification: Notification) { closes += 1 }
    }

    func testMinimizeUsesCloseGuardAndNeverLeavesADockThumbnail() {
        let window = SettingsPanel(contentRect: CGRect(x: 100, y: 100, width: 200, height: 100),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let delegate = CloseDelegate()
        window.delegate = delegate
        window.orderFrontRegardless()
        window.miniaturize(nil)
        XCTAssertFalse(window.isMiniaturized)
        XCTAssertTrue(window.isVisible, "cleanup may veto closure until it has finished")
        delegate.allowsClose = true
        window.miniaturize(nil)
        XCTAssertFalse(window.isMiniaturized)
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(delegate.closes, 1)
    }

    func testClosingSettingsDropsDockPresenceEvenWhenDockWasSelected() {
        let name = "InteractionOptionsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = Preferences(defaults: defaults)
        preferences.appPresence = .dock
        let controller = SettingsWindowController(preferences: preferences, providers: { [] },
            updater: Updater(), signOut: { _ in }, signIn: { _ in false },
            switchAccount: { _ in false }, retry: { _ in }, resetPosition: {})
        let previous = NSApp.activationPolicy()
        defer { NSApp.setActivationPolicy(previous) }
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        XCTAssertEqual(NSApp.activationPolicy(), .accessory)
    }
}

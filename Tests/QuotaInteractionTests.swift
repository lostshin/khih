import XCTest
import SwiftUI
@testable import Codenotch

@MainActor
final class QuotaInteractionTests: XCTestCase {
    private var accounts: [ProviderSnapshot] {
        ["codex-a", "codex-b", "codex-c"].map { id in
            ProviderSnapshot(id: id, displayName: "Same name", glyph: .openai,
                fidelity: .official, status: .ok, windows: [
                    LimitWindow(id: "primary", label: "5h", usedFraction: 0, duration: 18000),
                    LimitWindow(id: "secondary", label: "Weekly", usedFraction: 0.2, duration: 604800)])
        }
    }

    func testRenderedSecondGroupRoutesOnlyItsFiveHourActionAtEveryEdgeAndScale() async throws {
        for edge in [NotchEdge.left, .right, .top, .bottom] {
            for scale in [CGFloat(0.8), 1.2] {
                let controller = NotchWindowController()
                controller.model.edge = edge
                controller.model.sizeScale = scale
                controller.model.snapshots = ProviderOrder.cells(from: accounts, keeping: [], activeCodexID: "codex-b")
                controller.manualCheckIDs = Set(accounts.map(\.id))
                var starts: [String] = []
                controller.onStartGroup = { starts.append($0); return "Done" }
                controller.show()
                controller.model.isExpanded = true
                controller.model.hoveredIndex = 0
                for _ in 0..<50 {
                    if controller.model.groupFrames.count == 3 { break }
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                let frames = controller.model.groupFrames
                XCTAssertEqual(frames.count, 3, "\(edge), \(scale)")
                let group = try XCTUnwrap(frames["codex-b"])
                let height = try XCTUnwrap(controller.panelFrameForTesting).height
                controller.handleClick(at: CGPoint(x: group.midX, y: height - group.midY))
                for _ in 0..<10 {
                    if !starts.isEmpty { break }
                    await Task.yield()
                }
                XCTAssertEqual(starts, ["codex-b"], "\(edge), \(scale)")
                controller.stop()
            }
        }
    }

    func testEveryManagedRingUsesManualCheckAndPanelConsumesOneClick() async throws {
        for id in ["codex:accounts", "claude", "gemini"] {
            let controller = NotchWindowController()
            let snapshot = id == "codex:accounts"
                ? ProviderOrder.cells(from: accounts, keeping: [], activeCodexID: nil)[0]
                : ProviderSnapshot(id: id, displayName: id, glyph: .claude, fidelity: .official,
                    status: .ok, windows: [LimitWindow(id: "primary", label: "5h", usedFraction: 1, duration: 18000)])
            controller.model.snapshots = [snapshot]
            controller.manualCheckIDs = Set(snapshot.refreshProviderIDs)
            var calls: [[String]] = []
            controller.onManualCheck = { calls.append($0); return "Checked" }
            controller.show()
            controller.model.isExpanded = true
            let panel = try XCTUnwrap(controller.panelContentViewForTesting?.window as? NotchPanel)
            let point = NotchPlacement(edge: .right, panelSize: panel.frame.size).point(
                along: controller.model.slack + controller.model.ringCenter(index: 0) * controller.model.sizeScale,
                across: controller.model.notchDepth * controller.model.sizeScale / 2)
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown,
                location: CGPoint(x: point.x, y: panel.frame.height - point.y), modifierFlags: [],
                timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: 1))
            panel.sendEvent(event)
            panel.sendEvent(event)
            for _ in 0..<10 { if !calls.isEmpty { break }; await Task.yield() }
            XCTAssertEqual(calls, [snapshot.refreshProviderIDs])
            XCTAssertTrue(controller.model.isRefreshing(snapshot))
            controller.stop()
        }
    }

    func testProgressAndSignInRenderWithReducedTransparency() async throws {
        let oldLocale = L10n.testLocale
        L10n.testLocale = Locale(identifier: "zh-Hant-TW")
        defer { L10n.testLocale = oldLocale }
        let storage = QuotaStorage(baseDir: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let quota = QuotaController(storage: storage, engine: nil)
        for scheme in [ColorScheme.light, .dark] {
            let progress = HStack {
                ForEach(0..<3) { index in
                    ProviderRing(usedFraction: [0.0, 1.0, nil][index], glyph: .openai, isRefreshing: true)
                }
            }.padding(24).background(Color.black)
                .environment(\.codenotchReduceTransparency, true)
            let sheet = CodexSignInSheet(quota: quota)
                .background(scheme == .light ? Color.white : Color(white: 0.15))
                .environment(\.colorScheme, scheme)
            for (name, content) in [("progress", AnyView(progress)), ("sign-in", AnyView(sheet))] {
                let host = NSHostingView(rootView: content)
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
                XCTAssertGreaterThan(bitmap.pixelsWide, 100)
                if let directory = ProcessInfo.processInfo.environment["GROUPED_RENDER_DIR"] {
                    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name)-\(scheme).png"))
                }
            }
        }
    }

    func testNewCopyUsesTaiwanTranslation() {
        let locale = Locale(identifier: "zh-Hant-TW")
        XCTAssertEqual(L10n.t("Allow access to Claude sign-in…", locale: locale), "允許存取 Claude 登入資料…")
        XCTAssertEqual(L10n.t("Copy code and open sign-in page", locale: locale), "複製代碼並開啟登入頁")
        XCTAssertEqual(L10n.t("Click to start this account’s 5-hour countdown", locale: locale), "點一下啟動此帳號的 5 小時倒數")
    }
}

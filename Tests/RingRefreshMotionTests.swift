import XCTest
import SwiftUI
@testable import Codenotch

@MainActor
final class RingRefreshMotionTests: XCTestCase {
    private final class Reading: ObservableObject {
        @Published var refreshing = false
        @Published var used: Double? = 1
    }

    private struct Harness: View {
        @ObservedObject var reading: Reading
        var body: some View {
            ProviderRing(usedFraction: reading.used, glyph: .openai, isRefreshing: reading.refreshing)
                .padding(20)
                .background(Color.black)
        }
    }

    func testRefreshSurvivesReadingUpdatesAndSettlesWithoutLeavingAnArc() async throws {
        let reading = Reading()
        let host = NSHostingView(rootView: Harness(reading: reading))
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.close() }
        try await Task.sleep(nanoseconds: 200_000_000)
        let before = try capture(host, name: "idle")
        reading.refreshing = true
        try await Task.sleep(nanoseconds: 200_000_000)
        let during = try capture(host, name: "refresh")
        // A missing reading and a new answer can both arrive during the turn.
        reading.used = nil
        try await Task.sleep(nanoseconds: 100_000_000)
        _ = try capture(host, name: "unknown")
        reading.used = 1
        try await Task.sleep(nanoseconds: 100_000_000)
        reading.refreshing = false
        try await Task.sleep(nanoseconds: 1_200_000_000)
        let after = try capture(host, name: "settled")
        XCTAssertGreaterThan(brightPixels(during), brightPixels(before), "an exhausted ring must still show progress")
        XCTAssertEqual(brightPixels(after), brightPixels(before), "the progress arc must disappear once the turn settles")
    }

    private func capture(_ host: NSView, name: String) throws -> NSBitmapImageRep {
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        if let directory = ProcessInfo.processInfo.environment["RING_RENDER_DIR"] {
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("ring-\(name).png"))
        }
        return bitmap
    }

    private func brightPixels(_ image: NSBitmapImageRep) -> Int {
        var count = 0
        for y in 0..<image.pixelsHigh {
            for x in 0..<image.pixelsWide {
                if let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                   min(color.redComponent, color.greenComponent, color.blueComponent) > 0.8 {
                    count += 1
                }
            }
        }
        return count
    }
}

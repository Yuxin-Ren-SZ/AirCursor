import AppKit
import SwiftUI
import XCTest
@testable import AirCursor

final class ClickableProbeTests: XCTestCase {
    @MainActor
    func testOwnSwiftUIWindowSkipsAXAndCompletesAsynchronouslyThroughOverlay() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.finishLaunching()
        guard let screen = NSScreen.screens.first else {
            throw XCTSkip("Requires a macOS WindowServer session")
        }
        let frame = NSRect(x: screen.frame.midX - 100, y: screen.frame.midY - 80,
                           width: 200, height: 160)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Welcome to AirCursor"
        window.contentView = NSHostingView(rootView: Button("Click me") {}.frame(width: 200, height: 160))
        window.setFrame(frame, display: true)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.level = .floating
        window.orderFrontRegardless()
        defer { window.close() }

        // The dwell ring must not mask the underlying tour window.
        let overlay = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        overlay.isReleasedWhenClosed = false
        overlay.ignoresMouseEvents = true
        overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        overlay.level = .screenSaver
        overlay.orderFrontRegardless()
        defer { overlay.close() }

        // Let WindowServer publish the newly ordered windows before hit-testing.
        try await Task.sleep(for: .milliseconds(100))

        let point = CGPoint(x: window.frame.midX, y: screen.frame.maxY - window.frame.midY)
        XCTAssertTrue(ClickableProbe.describe(point).contains("AX query skipped"),
                      "Expected window \(window.windowNumber) at \(window.frame), hit \(NSWindow.windowNumber(at: ScreenGeometry.cocoaPoint(from: point), belowWindowWithWindowNumber: 0)) at \(point)")
        let completed = expectation(description: "Own-window probe remains responsive")
        var returned = false
        ClickableProbe.check(point) { clickable in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertTrue(returned, "Keep the existing asynchronous completion contract")
            XCTAssertTrue(clickable)
            completed.fulfill()
        }
        returned = true
        await fulfillment(of: [completed], timeout: 2)
    }
}

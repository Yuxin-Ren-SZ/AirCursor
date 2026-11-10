import CoreGraphics
import AppKit
import XCTest
@testable import AirCursor

@MainActor
final class EventSynthesizerTests: XCTestCase {
    func testCalibrationOutputGuardBlocksEveryInputKind() {
        var events: [CGEvent] = []
        let synthesizer = EventSynthesizer(postEvent: { events.append($0) })
        synthesizer.inputEnabled = false
        synthesizer.move(to: CGPoint(x: 100, y: 100))
        synthesizer.click(.left, at: .zero)
        synthesizer.click(.right, at: .zero, count: 2)
        synthesizer.leftDown(at: .zero)
        synthesizer.scroll(vertical: 12, horizontal: 5)
        synthesizer.keyStroke(0, flags: .maskCommand)
        XCTAssertTrue(events.isEmpty)
        XCTAssertFalse(synthesizer.isLeftButtonDown)
    }

    func testDisablingInputReleasesADragAndNormalInputCanResume() throws {
        _ = NSApplication.shared
        guard !NSScreen.screens.isEmpty else { throw XCTSkip("Requires a macOS WindowServer session") }
        var events: [CGEvent] = []
        let synthesizer = EventSynthesizer(postEvent: { events.append($0) })
        synthesizer.leftDown(at: .zero)
        XCTAssertTrue(synthesizer.isLeftButtonDown)
        synthesizer.inputEnabled = false
        XCTAssertFalse(synthesizer.isLeftButtonDown)
        XCTAssertEqual(events.map(\.type), [.leftMouseDown, .leftMouseUp])
        synthesizer.click(.left, at: .zero)
        XCTAssertEqual(events.count, 2)
        synthesizer.inputEnabled = true
        synthesizer.click(.right, at: .zero)
        XCTAssertEqual(events.map(\.type), [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp])
    }
}

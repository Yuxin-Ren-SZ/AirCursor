import AppKit
import CoreGraphics

/// Posts synthetic mouse, scroll and keyboard events. Requires Accessibility permission.
final class EventSynthesizer {
    private let source = CGEventSource(stateID: .hidSystemState)
    private(set) var isLeftButtonDown = false

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system "allow Accessibility" prompt (once per app identity).
    static func requestTrust() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Current pointer position in global CG coordinates (top-left origin).
    func currentLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    func move(to point: CGPoint) {
        let type: CGEventType = isLeftButtonDown ? .leftMouseDragged : .mouseMoved
        CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    func click(_ button: CGMouseButton, at point: CGPoint, count: Int = 1) {
        let (downType, upType) = Self.types(for: button)
        for n in 1...max(1, count) {
            for type in [downType, upType] {
                guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button) else { continue }
                e.setIntegerValueField(.mouseEventClickState, value: Int64(n))
                e.post(tap: .cghidEventTap)
            }
        }
    }

    func leftDown(at point: CGPoint) {
        guard !isLeftButtonDown else { return }
        CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        isLeftButtonDown = true
    }

    func leftUp(at point: CGPoint) {
        guard isLeftButtonDown else { return }
        CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        isLeftButtonDown = false
    }

    /// Pixel-precise scroll. Positive `vertical` scrolls up, positive `horizontal` scrolls left.
    func scroll(vertical: Int32, horizontal: Int32) {
        CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: vertical, wheel2: horizontal, wheel3: 0)?
            .post(tap: .cghidEventTap)
    }

    func keyStroke(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { continue }
            e.flags = flags
            e.post(tap: .cghidEventTap)
        }
    }

    private static func types(for button: CGMouseButton) -> (CGEventType, CGEventType) {
        switch button {
        case .left: (.leftMouseDown, .leftMouseUp)
        case .right: (.rightMouseDown, .rightMouseUp)
        default: (.otherMouseDown, .otherMouseUp)
        }
    }
}

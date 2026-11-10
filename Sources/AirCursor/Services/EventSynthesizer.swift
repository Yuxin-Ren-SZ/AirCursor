import AppKit
import CoreGraphics

/// Posts synthetic mouse, scroll and keyboard events. Requires Accessibility permission.
final class EventSynthesizer {
    private lazy var source = CGEventSource(stateID: .hidSystemState)
    private let postEvent: (CGEvent) -> Void
    private(set) var isLeftButtonDown = false
    /// Final output guard for calibration. Releasing a held button is always allowed.
    var inputEnabled = true {
        didSet {
            if !inputEnabled, isLeftButtonDown { leftUp(at: currentLocation()) }
        }
    }

    init(postEvent: @escaping (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }) {
        self.postEvent = postEvent
    }

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
        guard inputEnabled else { return }
        let type: CGEventType = isLeftButtonDown ? .leftMouseDragged : .mouseMoved
        if let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left) { postEvent(event) }
    }

    func click(_ button: CGMouseButton, at point: CGPoint, count: Int = 1) {
        guard inputEnabled else { return }
        let (downType, upType) = Self.types(for: button)
        for n in 1...max(1, count) {
            for type in [downType, upType] {
                guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button) else { continue }
                e.setIntegerValueField(.mouseEventClickState, value: Int64(n))
                postEvent(e)
            }
        }
    }

    func leftDown(at point: CGPoint) {
        guard inputEnabled, !isLeftButtonDown else { return }
        if let event = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left) { postEvent(event) }
        isLeftButtonDown = true
    }

    func leftUp(at point: CGPoint) {
        guard isLeftButtonDown else { return }
        if let event = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) { postEvent(event) }
        isLeftButtonDown = false
    }

    /// Pixel-precise scroll. Positive `vertical` scrolls up, positive `horizontal` scrolls left.
    func scroll(vertical: Int32, horizontal: Int32) {
        guard inputEnabled else { return }
        if let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: vertical, wheel2: horizontal, wheel3: 0) { postEvent(event) }
    }

    func keyStroke(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        guard inputEnabled else { return }
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { continue }
            e.flags = flags
            postEvent(e)
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

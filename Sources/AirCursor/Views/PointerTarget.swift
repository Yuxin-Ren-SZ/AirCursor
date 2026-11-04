import AppKit
import SwiftUI

enum MouseButtonKind {
    case left, right, middle
}

/// Transparent AppKit view that reports hover, movement and clicks from the real
/// pointer — including the synthetic events AirCursor posts — even when the window
/// isn't key. Used by the guided tour to detect what the user actually did.
struct PointerTarget: NSViewRepresentable {
    var onHover: ((Bool) -> Void)? = nil
    var onMove: ((CGPoint) -> Void)? = nil
    var onClick: ((MouseButtonKind, Int) -> Void)? = nil

    func makeNSView(context: Context) -> TargetView {
        let view = TargetView()
        update(view)
        return view
    }

    func updateNSView(_ view: TargetView, context: Context) { update(view) }

    private func update(_ view: TargetView) {
        view.onHover = onHover
        view.onMove = onMove
        view.onClick = onClick
    }

    final class TargetView: NSView {
        var onHover: ((Bool) -> Void)?
        var onMove: ((CGPoint) -> Void)?
        var onClick: ((MouseButtonKind, Int) -> Void)?

        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                owner: self
            ))
        }

        override func mouseEntered(with event: NSEvent) { onHover?(true) }
        override func mouseExited(with event: NSEvent) { onHover?(false) }
        override func mouseMoved(with event: NSEvent) { onMove?(convert(event.locationInWindow, from: nil)) }
        override func mouseDragged(with event: NSEvent) { onMove?(convert(event.locationInWindow, from: nil)) }
        override func mouseDown(with event: NSEvent) { onClick?(.left, event.clickCount) }
        override func rightMouseDown(with event: NSEvent) { onClick?(.right, event.clickCount) }
        override func otherMouseDown(with event: NSEvent) { onClick?(.middle, event.clickCount) }
    }
}

import AppKit
import QuartzCore

private func makeOverlayPanel(size: NSSize) -> NSPanel {
    let panel = NSPanel(
        contentRect: NSRect(origin: .zero, size: size),
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: true
    )
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.ignoresMouseEvents = true
    panel.level = .screenSaver
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    panel.isReleasedWhenClosed = false
    panel.hidesOnDeactivate = false
    // Purely visual: keep it out of Accessibility so it never masks what's underneath.
    panel.setAccessibilityElement(false)
    panel.setAccessibilityHidden(true)
    return panel
}

/// Small toast at the bottom of the screen ("Scroll mode", "Tracking paused", …).
@MainActor
final class HUDController {
    private let panel = makeOverlayPanel(size: NSSize(width: 260, height: 44))
    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private var hideWork: DispatchWorkItem?

    init() {
        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.state = .active
        blur.blendingMode = .behindWindow
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 12
        blur.layer?.masksToBounds = true

        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        icon.symbolConfiguration = .init(pointSize: 15, weight: .semibold)
        icon.contentTintColor = .controlAccentColor

        let stack = NSStackView(views: [icon, label])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: blur.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: blur.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: blur.leadingAnchor),
        ])
        panel.contentView = blur
    }

    func show(_ text: String, symbol: String, near cgPoint: CGPoint?) {
        label.stringValue = text
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)

        let width = min(420, max(180, label.intrinsicContentSize.width + 70))
        let screen = screenFor(cgPoint) ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        panel.setFrame(NSRect(x: frame.midX - width / 2, y: frame.minY + 80, width: width, height: 44), display: true)

        hideWork?.cancel()
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                self.panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.panel.alphaValue == 0 else { return }
                    self.panel.orderOut(nil)
                }
            })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3, execute: work)
    }

    private func screenFor(_ cgPoint: CGPoint?) -> NSScreen? {
        guard let cgPoint else { return nil }
        let p = ScreenGeometry.cocoaPoint(from: cgPoint)
        return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) }
    }
}

/// Follows the cursor to draw the dwell-progress ring and click ripples.
@MainActor
final class CursorOverlayController {
    private static let size: CGFloat = 72
    private let panel = makeOverlayPanel(size: NSSize(width: size, height: size))
    private let track = CAShapeLayer()
    private let ring = CAShapeLayer()
    private let pulseLayer = CAShapeLayer()
    private var ringVisible = false
    private var pulseUntil: CFTimeInterval = 0

    init() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
        view.wantsLayer = true
        let bounds = view.bounds
        let ringPath = CGPath(ellipseIn: bounds.insetBy(dx: 18, dy: 18), transform: nil)

        for layer in [track, ring] {
            layer.frame = bounds
            layer.path = ringPath
            layer.fillColor = nil
            layer.lineWidth = 4
            layer.lineCap = .round
        }
        track.strokeColor = NSColor.black.withAlphaComponent(0.25).cgColor
        ring.strokeColor = NSColor.controlAccentColor.cgColor
        ring.strokeEnd = 0
        // Start the ring at 12 o'clock and fill clockwise.
        ring.transform = CATransform3DConcat(CATransform3DMakeRotation(.pi / 2, 0, 0, 1), CATransform3DMakeScale(-1, 1, 1))

        pulseLayer.frame = bounds
        pulseLayer.path = CGPath(ellipseIn: bounds.insetBy(dx: 22, dy: 22), transform: nil)
        pulseLayer.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor
        pulseLayer.strokeColor = NSColor.controlAccentColor.cgColor
        pulseLayer.lineWidth = 2
        pulseLayer.opacity = 0

        view.layer?.addSublayer(track)
        view.layer?.addSublayer(ring)
        view.layer?.addSublayer(pulseLayer)
        track.isHidden = true
        ring.isHidden = true
        panel.contentView = view
    }

    /// Call every frame while tracking. `progress` nil hides the dwell ring.
    func update(dwellProgress progress: Double?, at cgPoint: CGPoint) {
        let showRing = progress != nil
        let pulsing = CACurrentMediaTime() < pulseUntil

        if showRing != ringVisible {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            track.isHidden = !showRing
            ring.isHidden = !showRing
            CATransaction.commit()
            ringVisible = showRing
        }

        guard showRing || pulsing else {
            if panel.isVisible { panel.orderOut(nil) }
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.strokeEnd = CGFloat(progress ?? 0)
        CATransaction.commit()

        position(at: cgPoint)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func pulse(at cgPoint: CGPoint) {
        position(at: cgPoint)
        panel.orderFrontRegardless()
        pulseUntil = CACurrentMediaTime() + 0.45

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.4
        scale.toValue = 1.6
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.9
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 0.4
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        pulseLayer.add(group, forKey: "pulse")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.46) { [weak self] in
            guard let self, !self.ringVisible, CACurrentMediaTime() >= self.pulseUntil else { return }
            self.panel.orderOut(nil)
        }
    }

    func hide() {
        ringVisible = false
        panel.orderOut(nil)
    }

    private func position(at cgPoint: CGPoint) {
        let p = ScreenGeometry.cocoaPoint(from: cgPoint)
        panel.setFrameOrigin(NSPoint(x: p.x - Self.size / 2, y: p.y - Self.size / 2))
    }
}

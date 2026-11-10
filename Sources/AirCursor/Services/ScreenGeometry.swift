import AppKit
import CoreGraphics
import AirCursorCore

/// Display layout in global CG coordinates (origin top-left of the main display).
final class ScreenGeometry {
    private(set) var displays: [CGRect] = []
    private var displayIDs: [CGDirectDisplayID] = []

    init() { refresh() }

    func refresh() {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            displays = [CGDisplayBounds(CGMainDisplayID())]
            displayIDs = [CGMainDisplayID()]
            return
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        displayIDs = Array(ids.prefix(Int(count)))
        displays = displayIDs.map(CGDisplayBounds)
    }

    func calibrationDisplay(containing point: CGPoint) -> CalibrationDisplay {
        let bounds = display(containing: point)
        let index = displays.firstIndex(of: bounds) ?? 0
        let id = displayIDs.indices.contains(index) ? displayIDs[index] : CGMainDisplayID()
        let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }
        return CalibrationDisplay(id: String(id), name: screen?.localizedName ?? "Display",
            width: Double(screen?.frame.width ?? bounds.width), height: Double(screen?.frame.height ?? bounds.height),
            pixelWidth: CGDisplayPixelsWide(id), pixelHeight: CGDisplayPixelsHigh(id), scale: Double(screen?.backingScaleFactor ?? 1))
    }

    func display(containing p: CGPoint) -> CGRect {
        if let d = displays.first(where: { $0.contains(p) }) { return d }
        // Nearest display by center distance.
        return displays.min { a, b in
            hypot(a.midX - p.x, a.midY - p.y) < hypot(b.midX - p.x, b.midY - p.y)
        } ?? CGDisplayBounds(CGMainDisplayID())
    }

    /// Keeps the cursor on a real display. Moving across a shared edge works;
    /// moving into a gap between displays clamps to the display you came from.
    func clamp(_ p: CGPoint, from previous: CGPoint) -> CGPoint {
        if displays.contains(where: { $0.contains(p) }) { return p }
        let r = display(containing: previous)
        return CGPoint(x: min(max(p.x, r.minX), r.maxX - 1), y: min(max(p.y, r.minY), r.maxY - 1))
    }

    /// Converts a CG global point to Cocoa screen coordinates (bottom-left origin).
    static func cocoaPoint(from p: CGPoint) -> NSPoint {
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? CGDisplayBounds(CGMainDisplayID()).height
        return NSPoint(x: p.x, y: primaryHeight - p.y)
    }
}

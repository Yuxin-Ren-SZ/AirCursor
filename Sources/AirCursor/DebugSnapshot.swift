import AppKit
import SceneKit

extension Notification.Name {
    static let tourShowStep = Notification.Name("AirCursor.tourShowStep")
}

/// Developer tool: renders every guided-tour step to PNG for docs and visual review.
///
///     open build/AirCursor.app --env AIRCURSOR_SNAPSHOT_DIR=/tmp/shots
///
/// Off unless the environment variable is set.
@MainActor
enum DebugSnapshot {
    static var directory: URL? {
        ProcessInfo.processInfo.environment["AIRCURSOR_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
    }

    static func runIfRequested() {
        guard let dir = directory else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            for step in TourStep.allCases {
                NotificationCenter.default.post(name: .tourShowStep, object: step.rawValue)
                try? await Task.sleep(for: .seconds(1.6))
                if let window = NSApp.windows.first(where: { $0.title == "Welcome to AirCursor" && $0.isVisible }) {
                    capture(window, to: dir.appendingPathComponent(String(format: "tour-%02d-%@.png", step.rawValue, String(describing: step))))
                }
            }
            NSLog("AirCursor: snapshots written to \(dir.path)")
            NSApp.terminate(nil)
        }
    }

    private static func capture(_ window: NSWindow, to url: URL) {
        guard let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)

        // Metal-backed SceneKit views don't draw via cacheDisplay; composite their snapshot.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        for scn in sceneViews(in: view) {
            let frame = scn.convert(scn.bounds, to: view)
            let flipped = NSRect(x: frame.minX, y: view.isFlipped ? view.bounds.height - frame.maxY : frame.minY,
                                 width: frame.width, height: frame.height)
            scn.snapshot().draw(in: flipped)
        }
        NSGraphicsContext.restoreGraphicsState()

        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func sceneViews(in view: NSView) -> [SCNView] {
        view.subviews.flatMap { sub -> [SCNView] in
            (sub as? SCNView).map { [$0] } ?? sceneViews(in: sub)
        }
    }
}

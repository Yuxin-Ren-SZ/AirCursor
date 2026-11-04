import CoreMotion
import AirCursorCore

/// Streams head attitude from AirPods Pro / Max / 3rd gen+ / Beats Fit Pro via CoreMotion.
final class HeadphoneMotionService: NSObject, CMHeadphoneMotionManagerDelegate {
    private let manager = CMHeadphoneMotionManager()

    var onSample: ((MotionSample) -> Void)?
    var onConnectionChange: ((Bool) -> Void)?
    var onError: ((Error) -> Void)?

    static var authorizationStatus: CMAuthorizationStatus { CMHeadphoneMotionManager.authorizationStatus() }

    var isAvailable: Bool { manager.isDeviceMotionAvailable }
    var isActive: Bool { manager.isDeviceMotionActive }

    override init() {
        super.init()
        manager.delegate = self
    }

    /// Starts updates. The first call triggers the system motion-permission prompt.
    func start() {
        guard !manager.isDeviceMotionActive else { return }
        startUpdates()
    }

    private func startUpdates() {
        Diagnostics.log.notice("Starting headphone motion (available: \(self.manager.isDeviceMotionAvailable, privacy: .public), auth: \(Self.authorizationStatus.label, privacy: .public))")
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
            guard let self else { return }
            if let error {
                Diagnostics.log.error("Headphone motion error: \(String(describing: error), privacy: .public)")
                self.onError?(error)
                return
            }
            guard let motion else { return }
            let a = motion.attitude
            self.onSample?(MotionSample(timestamp: motion.timestamp, yaw: a.yaw, pitch: a.pitch, roll: a.roll))
        }
    }

    /// Stops and starts again — recovers a stream that stalled after a route change.
    func restart() {
        manager.stopDeviceMotionUpdates()
        // isDeviceMotionActive can lag the stop call, so start unconditionally after a beat.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.startUpdates()
        }
    }

    func stop() {
        guard manager.isDeviceMotionActive else { return }
        Diagnostics.log.notice("Stopping headphone motion")
        manager.stopDeviceMotionUpdates()
    }

    func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        Diagnostics.log.notice("Headphone motion: headphones connected")
        DispatchQueue.main.async { self.onConnectionChange?(true) }
    }

    func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        Diagnostics.log.notice("Headphone motion: headphones disconnected")
        DispatchQueue.main.async { self.onConnectionChange?(false) }
    }
}

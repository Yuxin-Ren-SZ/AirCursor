import Foundation

/// Shared by live control and calibration so learned thresholds use the same signal.
public struct RepositioningSignal: Sendable {
    private var rotationEnvelope = 0.0
    private var energy = 0.0
    public init() {}
    public mutating func update(magnitude: Double, angularSpeed: Double, dt: Double) -> (residual: Double, rms: Double) {
        rotationEnvelope = max(bounded(angularSpeed, 0, 0, 720), rotationEnvelope * exp(-max(dt, 0) / 0.12))
        let residual = max(0, magnitude - min(0.09, rotationEnvelope * 0.09 / 60))
        let alpha = 1 - exp(-min(max(dt, 0.001), 0.25) / 0.08)
        energy += (residual*residual - energy) * alpha
        return (residual, sqrt(max(0, energy)))
    }
}

public enum InputGateState: String, Sendable {
    case normal, cautious, frozen
    public var allowsClicks: Bool { self == .normal }
}

/// Heuristic intent gate, deliberately separate from Kalman covariance. Acceleration
/// is evidence of repositioning, not a position estimate. Missing acceleration leaves
/// attitude-only sources usable; malformed observations fail closed.
public struct RepositioningGate: Sendable {
    public private(set) var state: InputGateState = .normal
    public private(set) var accelerationAvailable = false
    private var lastTime: TimeInterval?
    private var lastAcceleration: Vec3?
    private var signal = RepositioningSignal()
    private var strongSince: TimeInterval?
    private var quietSince: TimeInterval?

    public init() {}
    public mutating func reset() { self = Self() }
    public mutating func freeze() {
        state = .frozen
        quietSince = nil
        strongSince = nil
    }

    public mutating func update(time: TimeInterval, acceleration: Vec3?, reliable: Bool,
                                angularSpeed: Double = 0,
                                settings: RepositioningSettings) -> InputGateState {
        guard time.isFinite else { freeze(); return state }
        let dt = time - (lastTime ?? time)
        guard lastTime == nil || dt > 0 else { freeze(); return state }
        defer { lastTime = time; lastAcceleration = acceleration }
        accelerationAvailable = acceleration != nil
        guard reliable, acceleration?.isFinite ?? true else { freeze(); return state }
        if dt > MotionDifferentiator.maxInterval { freeze() }

        let magnitude = settings.enabled ? (acceleration?.length ?? 0) : 0
        // An earbud accelerates during rotation about the neck. A bounded allowance
        // prevents brief ordinary turns/tilts from canceling their own click. It is
        // a heuristic, not translation compensation; strong raw acceleration still freezes.
        let features = signal.update(magnitude: magnitude, angularSpeed: angularSpeed, dt: dt)
        let residualMagnitude = features.residual, rms = features.rms
        let caution = bounded(settings.cautionAcceleration, 0.045, 0.01, 0.5)
        let strong = max(caution * 1.5, bounded(settings.freezeAcceleration, 0.18, 0.03, 1))
        let jerk: Double
        if let a = acceleration, let b = lastAcceleration, dt > 0, settings.enabled {
            jerk = Vec3(a.x-b.x, a.y-b.y, a.z-b.z).length / dt
        } else { jerk = 0 }

        if magnitude >= strong {
            strongSince = strongSince ?? time
            if magnitude >= max(0.65, strong * 3) || time - (strongSince ?? time) >= 0.12 - 1e-9 {
                freeze()
            }
        } else { strongSince = nil }

        if max(residualMagnitude, rms) >= caution || (jerk > 4 && residualMagnitude > caution * 0.8) {
            if state != .frozen { state = .cautious }
            quietSince = nil
        } else if state != .normal {
            if residualMagnitude < caution * 0.6, rms < caution * 0.8 {
                quietSince = quietSince ?? time
                if time - (quietSince ?? time) >= bounded(settings.settleTime, 0.25, 0.08, 1) {
                    state = .normal
                    quietSince = nil
                }
            } else { quietSince = nil }
        }
        return state
    }
}

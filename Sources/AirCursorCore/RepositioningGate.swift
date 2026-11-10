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

public enum InputGateReason: String, Sendable {
    case none, posture, invalidSignal, sampleGap, stale
    public var message: String {
        switch self {
        case .none: "Ready"
        case .posture: "Posture movement detected"
        case .invalidSignal: "Sensor reading rejected — settling"
        case .sampleGap: "Motion stream interrupted — settling"
        case .stale: "Waiting for fresh motion"
        }
    }
}

/// Heuristic intent gate, deliberately separate from Kalman covariance. Acceleration
/// is evidence of repositioning, not a position estimate. Missing acceleration leaves
/// attitude-only sources usable; malformed observations fail closed.
public struct RepositioningGate: Sendable {
    public private(set) var state: InputGateState = .normal
    public private(set) var reason: InputGateReason = .none
    public private(set) var accelerationAvailable = false
    private var lastTime: TimeInterval?
    private var signal = RepositioningSignal()
    private var strongSince: TimeInterval?
    private var cautionSince: TimeInterval?
    private var quietSince: TimeInterval?

    public init() {}
    public mutating func reset() { self = Self() }
    public mutating func freeze(reason: InputGateReason = .invalidSignal) {
        state = .frozen
        self.reason = reason
        quietSince = nil
        strongSince = nil
        cautionSince = nil
    }

    public mutating func update(time: TimeInterval, acceleration: Vec3?, reliable: Bool,
                                angularSpeed: Double = 0,
                                settings: RepositioningSettings) -> InputGateState {
        guard time.isFinite else { freeze(); return state }
        let dt = time - (lastTime ?? time)
        guard lastTime == nil || dt > 0 else { freeze(); return state }
        defer { lastTime = time }
        accelerationAvailable = acceleration != nil
        guard reliable, acceleration?.isFinite ?? true else {
            freeze(reason: dt > MotionDifferentiator.maxInterval ? .sampleGap : .invalidSignal)
            return state
        }
        if dt > MotionDifferentiator.maxInterval { freeze(reason: .sampleGap) }

        let magnitude = settings.enabled ? (acceleration?.length ?? 0) : 0
        // An earbud accelerates during rotation about the neck. A bounded allowance
        // prevents brief ordinary turns/tilts from canceling their own click. It is
        // a heuristic, not translation compensation; strong raw acceleration still freezes.
        let features = signal.update(magnitude: magnitude, angularSpeed: angularSpeed, dt: dt)
        let residualMagnitude = features.residual, rms = features.rms
        let caution = bounded(settings.cautionAcceleration, 0.06, 0.01, 0.5)
        let strong = max(caution * 2, bounded(settings.freezeAcceleration, 0.24, 0.03, 1))
        let postureEvidence = residualMagnitude >= caution * 0.8 && rms >= caution
        // Starts/braking and jerk alone are not intent evidence. Require both current
        // residual and sustained energy, then a dwell, before suppressing normal input.
        if magnitude >= max(0.65, strong * 3) { freeze(reason: .posture) }
        else if magnitude >= strong, postureEvidence {
            strongSince = strongSince ?? time
            if time - (strongSince ?? time) >= bounded(settings.freezeDuration, 0.2, 0.12, 0.6) - 1e-9 {
                freeze(reason: .posture)
            }
        } else { strongSince = nil }

        if postureEvidence {
            cautionSince = cautionSince ?? time
            if state == .normal, time - (cautionSince ?? time) >= bounded(settings.cautionDuration, 0.16, 0.08, 0.4) - 1e-9 {
                state = .cautious
                reason = .posture
            }
            quietSince = nil
        } else {
            cautionSince = nil
            if state == .normal { return state }
            // Posture recovery follows fresh quiet input. Waiting for the old energy
            // tail as well as a quiet dwell made recovery unnecessarily sluggish.
            let energyQuiet = reason == .posture || rms < caution * 0.8
            if residualMagnitude < caution * 0.6, energyQuiet {
                quietSince = quietSince ?? time
                let quietTime = reason == .posture ? bounded(settings.settleTime, 0.10, 0.06, 0.3)
                    : max(0.18, bounded(settings.settleTime, 0.10, 0.06, 0.3))
                if time - (quietSince ?? time) >= quietTime - 1e-9 {
                    state = .normal
                    reason = .none
                    quietSince = nil
                    signal = RepositioningSignal()
                }
            } else { quietSince = nil }
        }
        return state
    }
}

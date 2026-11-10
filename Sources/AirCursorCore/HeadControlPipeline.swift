import Foundation

public struct HeadControlUpdate: Sendable {
    public var rates: AngularRates?
    public var rawRates: AngularRates?
    public var targetVelocity: Vec2
    public var gate: InputGateState
    public var gateReason: InputGateReason
    public var gesture: GestureEvent?
    public var tiltStartTime: TimeInterval?
    public var tiltProgress: Double?
    public var holdingPointer: Bool
    public var awaitingTiltNeutral: Bool
    public var accepted: Bool
    public var allowsAutomaticClicks: Bool { accepted && gate.allowsClicks && !holdingPointer && !awaitingTiltNeutral }
}

/// Pure coordinator, replayable with recorded or synthetic observations. No events,
/// capture, wall clock or storage: output policy is testable independently of macOS.
public struct HeadControlPipeline: Sendable {
    public var pointerSettings: PointerSettings
    public var gestures: GestureDetector
    public private(set) var estimator = KalmanMotionEstimator()
    public private(set) var gate = RepositioningGate()
    private var differentiator = MotionDifferentiator()
    private var response = PointerResponse()
    private var lastSample: MotionSample?
    private var tiltWasHeld = false
    private var tiltSettledSince: TimeInterval?
    private var postureCanceledTilt = false

    public init(pointer: PointerSettings = PointerSettings(), gestures: GestureSettings = GestureSettings()) {
        pointerSettings = pointer
        self.gestures = GestureDetector(settings: gestures)
    }

    public mutating func reset(preservingGestures: Bool = false) {
        estimator.reset(); gate.reset(); differentiator.reset(); response.reset()
        if !preservingGestures { gestures.reset() }
        lastSample = nil; tiltWasHeld = false; tiltSettledSince = nil
        postureCanceledTilt = false
    }

    public mutating func cancelGestures() {
        gestures.cancelPendingGestures()
        response.reset()
        postureCanceledTilt = false
    }

    public mutating func suspend() {
        gate.freeze(reason: .stale); cancelGestures(); estimator.reset(); differentiator.reset()
        lastSample = nil
    }

    public mutating func process(_ sample: MotionSample, enabled: Set<HeadGesture>) -> HeadControlUpdate {
        var reliable = sample.isFinite
        if let previous = lastSample {
            let dt = sample.timestamp - previous.timestamp
            reliable = reliable && dt >= MotionDifferentiator.minInterval
                && dt <= MotionDifferentiator.maxInterval && previous.sourceID == sample.sourceID
            if previous.sourceID != sample.sourceID {
                gestures.resetTiltBaseline()
                tiltWasHeld = false
                tiltSettledSince = nil
            }
        }
        let raw = differentiator.push(sample)
        let estimate = estimator.push(sample, settings: pointerSettings.filter)
        reliable = reliable && estimate.accepted
        // Do not move the reference clock backwards on an out-of-order observation.
        if sample.isFinite, sample.timestamp > (lastSample?.timestamp ?? -.infinity) { lastSample = sample }
        let previousGate = gate.state
        let angularSpeed = max(sample.rotationRate.map { AngleMath.degrees($0.length) } ?? 0,
                               raw.map { hypot(hypot($0.yaw, $0.pitch), $0.roll) } ?? 0)
        let state = gate.update(time: sample.timestamp, acceleration: sample.userAcceleration,
                                reliable: reliable, angularSpeed: angularSpeed, settings: pointerSettings.repositioning)
        let rates = pointerSettings.filterMode == .kalman ? estimate.rates : raw
        var gesture: GestureEvent?
        if reliable {
            if state != .normal {
                gestures.cancelPendingGestures()
                if gate.reason == .posture {
                    postureCanceledTilt = true
                    tiltWasHeld = false
                    tiltSettledSince = nil
                }
            }
            gesture = gestures.process(sample, enabled: state == .normal ? enabled : [])
        } else { gestures.cancelPendingGestures() }

        let tiltEnabled = enabled.contains(.tiltLeft) || enabled.contains(.tiltRight)
        let tiltHeld = gestures.tiltStartTime != nil
            || (state == .normal && tiltEnabled && gestures.tiltWaitingForNeutral && !postureCanceledTilt)
        if !gestures.tiltWaitingForNeutral { postureCanceledTilt = false }
        if tiltHeld { tiltWasHeld = true; tiltSettledSince = nil }
        else if tiltWasHeld {
            // Swallow the return-to-neutral motion as well as the click itself.
            if let rates, hypot(rates.yaw, rates.pitch) < 15 {
                tiltSettledSince = tiltSettledSince ?? sample.timestamp
                if sample.timestamp - (tiltSettledSince ?? sample.timestamp) >= 0.12 {
                    tiltWasHeld = false; tiltSettledSince = nil
                }
            } else { tiltSettledSince = nil }
        }
        let holding = tiltHeld || tiltWasHeld || state == .frozen || !reliable || rates == nil
        var target = Vec2.zero
        if !holding, let rates {
            if previousGate == .frozen { response.reset() }
            target = pointerSettings.filterMode == .legacy
                ? PointerMapper.cursorVelocity(rates: rates, settings: pointerSettings)
                : response.velocity(rates: rates, settings: pointerSettings, mayLearnNoise: state == .normal)
            if state == .cautious { target = target * bounded(pointerSettings.repositioning.cautiousGain, 0.6, 0, 1) }
        } else { response.reset() }
        return HeadControlUpdate(rates: rates, rawRates: raw, targetVelocity: target,
            gate: state, gateReason: gate.reason, gesture: state == .normal && reliable ? gesture : nil,
            tiltStartTime: gestures.tiltStartTime, tiltProgress: gestures.tiltProgress,
            holdingPointer: holding, awaitingTiltNeutral: tiltEnabled && gestures.tiltWaitingForNeutral, accepted: reliable)
    }
}

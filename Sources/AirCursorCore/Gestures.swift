import Foundation

public enum HeadGesture: String, Sendable, CaseIterable {
    case nod, shake, tiltLeft, tiltRight
}

public struct GestureEvent: Equatable, Sendable {
    public let gesture: HeadGesture
    /// When the movement began (sample clock), used to undo the cursor drift it caused.
    public let startTime: TimeInterval
    public let time: TimeInterval
}

/// Detects deliberate head gestures from angular rates.
///
/// - Nod: a fast pitch swing followed by a fast swing back (either order) within `nodWindow`.
/// - Shake: three alternating fast yaw swings within `shakeWindow`.
/// - Tilt: roll held beyond `tiltAngle` from the neutral posture for `tiltHold`.
///   Fires once, then re-arms when the head returns toward neutral.
///
/// Direction-agnostic nod/shake detection means it works no matter which sign
/// convention a given AirPods model reports.
public struct GestureDetector: Sendable {
    public var settings: GestureSettings

    private var nodStart: (sign: Int, time: TimeInterval)?
    private var shakeSwings: [(sign: Int, time: TimeInterval)] = []
    private var cooldownUntil: TimeInterval = -.infinity
    private var rollBaseline: Double?
    private var tiltCandidate: (gesture: HeadGesture, since: TimeInterval)?
    private var tiltLatched = false
    private var offNeutralSince: TimeInterval?

    /// A head held off-neutral this long is a new posture (or a stale baseline taken
    /// while the AirPods were being put in), so it becomes the new neutral.
    static let reNeutralAfter: TimeInterval = 4

    /// Axis dominance: a gesture's axis must be this much faster than the other axis.
    static let dominance = 1.3
    /// The return swing of a nod may be a bit slower than the initial one.
    static let nodReturnFactor = 0.7

    public init(settings: GestureSettings = GestureSettings()) {
        self.settings = settings
    }

    /// Current roll relative to neutral, in degrees (for live display).
    public func relativeRoll(_ rollDegrees: Double) -> Double {
        guard let base = rollBaseline else { return 0 }
        return AngleMath.wrappedDeltaDegrees(rollDegrees, base)
    }

    public mutating func resetTiltBaseline(to rollDegrees: Double? = nil) {
        rollBaseline = rollDegrees
        offNeutralSince = nil
        tiltCandidate = nil
        tiltLatched = false
    }

    public mutating func reset() {
        nodStart = nil
        shakeSwings.removeAll()
        cooldownUntil = -.infinity
        resetTiltBaseline()
    }

    public mutating func process(
        rates: AngularRates,
        rollDegrees: Double,
        enabled: Set<HeadGesture>
    ) -> GestureEvent? {
        let t = rates.timestamp
        let tilt = updateTilt(rollDegrees: rollDegrees, time: t, enabled: enabled)

        guard t >= cooldownUntil else { return nil }

        if enabled.contains(.nod), let e = detectNod(rates) { return fire(e) }
        if enabled.contains(.shake), let e = detectShake(rates) { return fire(e) }
        if let e = tilt { return fire(e) }
        return nil
    }

    private mutating func fire(_ event: GestureEvent) -> GestureEvent {
        cooldownUntil = event.time + settings.cooldown
        nodStart = nil
        shakeSwings.removeAll()
        tiltCandidate = nil
        return event
    }

    private mutating func detectNod(_ r: AngularRates) -> GestureEvent? {
        let t = r.timestamp
        if let s = nodStart, t - s.time > settings.nodWindow { nodStart = nil }

        let needed = nodStart == nil ? settings.nodThreshold : settings.nodThreshold * Self.nodReturnFactor
        guard abs(r.pitch) >= needed, abs(r.pitch) > abs(r.yaw) * Self.dominance else { return nil }
        let sign = r.pitch > 0 ? 1 : -1

        if let s = nodStart {
            guard sign != s.sign else { return nil }
            nodStart = nil
            return GestureEvent(gesture: .nod, startTime: s.time, time: t)
        }
        nodStart = (sign, t)
        return nil
    }

    private mutating func detectShake(_ r: AngularRates) -> GestureEvent? {
        let t = r.timestamp
        shakeSwings.removeAll { t - $0.time > settings.shakeWindow }

        guard abs(r.yaw) >= settings.shakeThreshold, abs(r.yaw) > abs(r.pitch) * Self.dominance else { return nil }
        let sign = r.yaw > 0 ? 1 : -1
        if shakeSwings.last?.sign != sign { shakeSwings.append((sign, t)) }

        guard shakeSwings.count >= 3, let first = shakeSwings.first else { return nil }
        return GestureEvent(gesture: .shake, startTime: first.time, time: t)
    }

    private mutating func updateTilt(rollDegrees: Double, time t: TimeInterval, enabled: Set<HeadGesture>) -> GestureEvent? {
        guard let base = rollBaseline else {
            rollBaseline = rollDegrees
            return nil
        }
        let rel = AngleMath.wrappedDeltaDegrees(rollDegrees, base)

        if abs(rel) < settings.tiltAngle * 0.5 {
            // Near neutral: slowly follow posture changes and re-arm.
            rollBaseline = base + rel * 0.02
            tiltLatched = false
            tiltCandidate = nil
            offNeutralSince = nil
            return nil
        }

        if let since = offNeutralSince {
            if t - since > Self.reNeutralAfter {
                rollBaseline = rollDegrees
                offNeutralSince = nil
                tiltCandidate = nil
                tiltLatched = false
                return nil
            }
        } else {
            offNeutralSince = t
        }

        guard enabled.contains(.tiltLeft) || enabled.contains(.tiltRight), !tiltLatched else { return nil }

        guard abs(rel) >= settings.tiltAngle else {
            tiltCandidate = nil
            return nil
        }

        let gesture: HeadGesture = (rel > 0) != settings.swapTiltDirection ? .tiltRight : .tiltLeft
        guard let candidate = tiltCandidate, candidate.gesture == gesture else {
            tiltCandidate = (gesture, t)
            return nil
        }
        guard t - candidate.since >= settings.tiltHold else { return nil }

        tiltLatched = true
        tiltCandidate = nil
        guard enabled.contains(gesture), t >= cooldownUntil else { return nil }
        return GestureEvent(gesture: gesture, startTime: candidate.since, time: t)
    }
}

/// Clicks when the cursor rests in one spot. Requires movement between clicks so a
/// stationary cursor never machine-guns.
public struct DwellDetector: Sendable {
    public var settings: DwellSettings

    private var anchor: Vec2?
    private var anchorTime: TimeInterval = 0
    private var armed = false

    /// Fraction of the dwell before the progress ring appears (avoids flicker while moving).
    static let revealFraction = 0.2

    public init(settings: DwellSettings = DwellSettings()) {
        self.settings = settings
    }

    /// Disarm until the cursor moves again (call after any click).
    public mutating func reset() {
        armed = false
        anchor = nil
    }

    public struct Update: Equatable, Sendable {
        /// 0...1 while dwelling (nil = hide indicator).
        public var progress: Double?
        public var fired: Bool
    }

    public mutating func update(position: Vec2, time: TimeInterval) -> Update {
        guard let a = anchor else {
            anchor = position
            anchorTime = time
            return Update(progress: nil, fired: false)
        }
        if position.distance(to: a) > settings.radius {
            anchor = position
            anchorTime = time
            armed = true
            return Update(progress: nil, fired: false)
        }
        guard armed, settings.duration > 0 else { return Update(progress: nil, fired: false) }

        let fraction = (time - anchorTime) / settings.duration
        if fraction >= 1 {
            armed = false
            return Update(progress: 1, fired: true)
        }
        return Update(progress: fraction >= Self.revealFraction ? fraction : nil, fired: false)
    }
}

import Foundation

public enum HeadGesture: String, Sendable, CaseIterable {
    case nod, shake, tiltLeft, tiltRight
}

public struct GestureEvent: Equatable, Sendable {
    public let gesture: HeadGesture
    /// When the movement began (sample clock), used to undo the cursor drift it caused.
    public let startTime: TimeInterval
    public let time: TimeInterval
    /// Size of the movement in degrees (nod depth, shake swing, tilt angle).
    public let magnitude: Double

    public init(gesture: HeadGesture, startTime: TimeInterval, time: TimeInterval, magnitude: Double) {
        self.gesture = gesture
        self.startTime = startTime
        self.time = time
        self.magnitude = magnitude
    }
}

/// Detects deliberate head gestures from the head's *angle over time*.
///
/// Shape-based detection is far more reliable than speed thresholds: AirPods report
/// ~25 samples/s, so the peak speed of a natural nod is often missed, but its shape —
/// dip a few degrees, come back — always shows up.
///
/// - Nod: pitch leaves its starting angle by ≥ `nodAmplitude`, then returns most of
///   the way, within `nodWindow`, with little sideways motion. Either direction.
/// - Shake: yaw swings back and forth ≥ `shakeAmplitude` at least four times within
///   `shakeWindow`, with little vertical motion.
/// - Tilt: roll held beyond `tiltAngle` from the neutral posture for `tiltHold`.
///   Fires once, then re-arms when the head returns toward neutral.
public struct GestureDetector: Sendable {
    public var settings: GestureSettings

    private struct Pose {
        let t: TimeInterval
        let yaw: Double    // degrees, unwrapped (continuous)
        let pitch: Double  // degrees
    }

    private var history: [Pose] = []
    private var lastRawYaw: Double?
    private var cooldownUntil: TimeInterval = -.infinity
    /// After a gesture fires, nothing re-arms until the head settles, so one nod or
    /// shake (including its follow-through) can never fire twice.
    private var awaitingStill = false
    private var stillSince: TimeInterval?
    private var rollBaseline: Double?
    private var tiltCandidate: (gesture: HeadGesture, since: TimeInterval)?
    private var tiltLatched = false
    private var offNeutralSince: TimeInterval?
    private var tiltNeedsNeutral = false
    private var neutralSamples = 0
    private var tiltBaselineConfirmed = false
    private var tiltOffNeutral = false
    /// From the half-threshold crossing until return to neutral, including follow-through.
    public private(set) var tiltStartTime: TimeInterval?
    public private(set) var tiltProgress: Double?
    public var tiltWaitingForNeutral: Bool { tiltNeedsNeutral && tiltOffNeutral }

    /// A head held off-neutral this long is a new posture (or a stale baseline taken
    /// while the AirPods were being put in), so it becomes the new neutral.
    static let reNeutralAfter: TimeInterval = 4
    /// A nod must come back at least this fraction of the way to where it started.
    static let nodReturnFraction = 0.65
    /// Sideways motion allowed during a nod, relative to its depth (and vice versa for shakes).
    static let crossAxisAllowance = 0.6
    /// Movements slower than this (deg/s at their fastest) are deliberate pointing, not gestures.
    static let minNodSpeed = 30.0
    static let minShakeSpeed = 80.0
    /// Swings needed for a shake: left-right-left-right. Three can happen just by
    /// glancing left, then right, then back to the screen.
    static let shakeSwings = 4
    static let historySpan: TimeInterval = 1.5
    /// Head speed (deg/s) below which it counts as settled, and for how long.
    static let settledSpeed = 25.0
    static let settledFor: TimeInterval = 0.15

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
        tiltNeedsNeutral = false
        tiltStartTime = nil
        tiltProgress = nil
        neutralSamples = 0
        tiltBaselineConfirmed = false
        tiltOffNeutral = false
    }

    public mutating func reset() {
        history.removeAll()
        lastRawYaw = nil
        cooldownUntil = -.infinity
        awaitingStill = false
        stillSince = nil
        resetTiltBaseline()
    }

    /// Cancel clicks during bad signals, body movement or external mouse takeover.
    /// Keep the neutral reference: capturing the current tilted pose would re-arm it.
    public mutating func cancelPendingGestures() {
        history.removeAll()
        lastRawYaw = nil
        awaitingStill = true
        stillSince = nil
        tiltCandidate = nil
        tiltProgress = nil
        tiltStartTime = nil
        tiltLatched = true
        tiltNeedsNeutral = true
        offNeutralSince = nil
    }

    /// Feed every motion sample (angles in radians, as CoreMotion reports them).
    public mutating func process(_ sample: MotionSample, enabled: Set<HeadGesture>) -> GestureEvent? {
        guard sample.isFinite else { cancelPendingGestures(); return nil }
        let t = sample.timestamp
        let rawYaw = AngleMath.degrees(sample.yaw)
        let pitch = AngleMath.degrees(sample.pitch)
        let roll = AngleMath.degrees(sample.roll)

        // Unwrap yaw so a turn across ±180° stays continuous; drop history after gaps.
        if let last = history.last, t - last.t > MotionDifferentiator.maxInterval || t <= last.t {
            cancelPendingGestures()
        }
        let yaw: Double
        if let prev = lastRawYaw, let last = history.last {
            yaw = last.yaw + AngleMath.wrappedDeltaDegrees(rawYaw, prev)
        } else {
            yaw = rawYaw
        }
        lastRawYaw = rawYaw
        history.append(Pose(t: t, yaw: yaw, pitch: pitch))
        if let first = history.first, t - first.t > Self.historySpan {
            history.removeAll { t - $0.t > Self.historySpan }
        }

        let tilt = updateTilt(rollDegrees: roll, time: t, enabled: enabled)

        if awaitingStill {
            let speed = history.count >= 2 ? peakSpeedBetween(history[history.count - 2], history[history.count - 1]) : 0
            if speed < Self.settledSpeed {
                stillSince = stillSince ?? t
                if t - (stillSince ?? t) >= Self.settledFor {
                    awaitingStill = false
                    stillSince = nil
                    // Start fresh from the settled pose.
                    history = Array(history.suffix(1))
                }
            } else {
                stillSince = nil
            }
            return nil
        }

        guard t >= cooldownUntil else { return nil }
        if enabled.contains(.nod), let e = detectNod(now: t) { return fire(e) }
        if enabled.contains(.shake), let e = detectShake(now: t) { return fire(e) }
        if let e = tilt { return fire(e) }
        return nil
    }

    private mutating func fire(_ event: GestureEvent) -> GestureEvent {
        cooldownUntil = event.time + settings.cooldown
        awaitingStill = true
        stillSince = nil
        tiltCandidate = nil
        return event
    }

    private func peakSpeedBetween(_ a: Pose, _ b: Pose) -> Double {
        guard b.t > a.t else { return 0 }
        return max(abs(b.pitch - a.pitch), abs(b.yaw - a.yaw)) / (b.t - a.t)
    }

    // MARK: Nod

    private func detectNod(now: TimeInterval) -> GestureEvent? {
        guard history.count >= 3, let current = history.last else { return nil }
        let lastIndex = history.count - 1

        // Try every start point in the window, oldest first (earliest start = best
        // cursor-restore point).
        for j in 0..<(lastIndex - 1) where now - history[j].t <= settings.nodWindow {
            let start = history[j]
            var extreme = 0.0
            var extremeIndex = j
            for k in (j + 1)..<lastIndex {
                let d = history[k].pitch - start.pitch
                if abs(d) > abs(extreme) { extreme = d; extremeIndex = k }
            }
            let depth = abs(extreme)
            guard depth >= settings.nodAmplitude, extremeIndex > j else { continue }

            let remaining = abs(current.pitch - start.pitch)
            guard remaining <= depth * (1 - Self.nodReturnFraction) else { continue }

            let segment = history[j...lastIndex]
            let yawRange = (segment.map(\.yaw).max() ?? 0) - (segment.map(\.yaw).min() ?? 0)
            guard yawRange <= max(depth * Self.crossAxisAllowance, 3) else { continue }
            guard peakSpeed(segment, \.pitch) >= Self.minNodSpeed else { continue }

            return GestureEvent(gesture: .nod, startTime: start.t, time: now, magnitude: depth)
        }
        return nil
    }

    // MARK: Shake

    private func detectShake(now: TimeInterval) -> GestureEvent? {
        let window = history.filter { now - $0.t <= settings.shakeWindow }
        guard window.count >= 4, let first = window.first else { return nil }

        var anchor = first.yaw
        var direction = 0
        var swings = 0
        var largest = 0.0
        for pose in window.dropFirst() {
            let d = pose.yaw - anchor
            switch direction {
            case 0:
                if abs(d) >= settings.shakeAmplitude {
                    direction = d > 0 ? 1 : -1
                    swings = 1
                    largest = abs(d)
                    anchor = pose.yaw
                }
            case 1:
                if pose.yaw > anchor { anchor = pose.yaw }
                else if anchor - pose.yaw >= settings.shakeAmplitude {
                    swings += 1; largest = max(largest, anchor - pose.yaw)
                    direction = -1; anchor = pose.yaw
                }
            default:
                if pose.yaw < anchor { anchor = pose.yaw }
                else if pose.yaw - anchor >= settings.shakeAmplitude {
                    swings += 1; largest = max(largest, pose.yaw - anchor)
                    direction = 1; anchor = pose.yaw
                }
            }
        }
        guard swings >= Self.shakeSwings else { return nil }

        let pitchRange = (window.map(\.pitch).max() ?? 0) - (window.map(\.pitch).min() ?? 0)
        guard pitchRange <= largest * Self.crossAxisAllowance else { return nil }
        guard peakSpeed(window[...], \.yaw) >= Self.minShakeSpeed else { return nil }

        return GestureEvent(gesture: .shake, startTime: first.t, time: now, magnitude: largest)
    }

    private func peakSpeed(_ poses: ArraySlice<Pose>, _ axis: KeyPath<Pose, Double>) -> Double {
        var best = 0.0
        var previous: Pose?
        for p in poses {
            if let prev = previous, p.t > prev.t {
                best = max(best, abs(p[keyPath: axis] - prev[keyPath: axis]) / (p.t - prev.t))
            }
            previous = p
        }
        return best
    }

    // MARK: Tilt

    private mutating func updateTilt(rollDegrees: Double, time t: TimeInterval, enabled: Set<HeadGesture>) -> GestureEvent? {
        guard let base = rollBaseline else {
            rollBaseline = rollDegrees
            neutralSamples = 1
            return nil
        }
        let rel = AngleMath.wrappedDeltaDegrees(rollDegrees, base)
        tiltOffNeutral = abs(rel) >= settings.tiltAngle * 0.5

        if abs(rel) < settings.tiltAngle * 0.5 {
            neutralSamples += 1
            if neutralSamples >= 4 { tiltBaselineConfirmed = true }
            // Near neutral: slowly follow posture changes and re-arm.
            rollBaseline = base + rel * 0.02
            tiltLatched = false
            tiltNeedsNeutral = false
            tiltStartTime = nil
            tiltProgress = nil
            tiltCandidate = nil
            offNeutralSince = nil
            return nil
        }

        if let since = offNeutralSince {
            if t - since > Self.reNeutralAfter,
               (!tiltLatched && !tiltNeedsNeutral) || !tiltBaselineConfirmed {
                rollBaseline = rollDegrees
                offNeutralSince = nil
                tiltCandidate = nil
                tiltLatched = false
                tiltStartTime = nil
                tiltProgress = nil
                neutralSamples = 0
                tiltBaselineConfirmed = false
                return nil
            }
        } else {
            offNeutralSince = t
        }

        guard enabled.contains(.tiltLeft) || enabled.contains(.tiltRight) else {
            tiltStartTime = nil
            tiltProgress = nil
            return nil
        }
        // A canceled tilt may still hold pointing until neutral, but must not create
        // a new target anchor (especially after a physical mouse moved the cursor).
        guard !tiltNeedsNeutral else { return nil }
        tiltStartTime = tiltStartTime ?? t
        guard !tiltLatched else { return nil }

        guard abs(rel) >= settings.tiltAngle else {
            tiltCandidate = nil
            tiltProgress = nil
            return nil
        }

        let gesture: HeadGesture = (rel > 0) != settings.swapTiltDirection ? .tiltRight : .tiltLeft
        guard let candidate = tiltCandidate, candidate.gesture == gesture else {
            tiltCandidate = (gesture, t)
            tiltProgress = 0
            return nil
        }
        tiltProgress = min(1, (t - candidate.since) / max(settings.tiltHold, 0.01))
        guard t - candidate.since >= settings.tiltHold else { return nil }

        tiltLatched = true
        tiltCandidate = nil
        tiltProgress = nil
        guard enabled.contains(gesture), t >= cooldownUntil else { return nil }
        return GestureEvent(gesture: gesture, startTime: tiltStartTime ?? candidate.since, time: t, magnitude: abs(rel))
    }
}

/// Clicks when the cursor rests in one spot. Requires movement between clicks so a
/// stationary cursor never machine-guns.
public struct DwellDetector: Sendable {
    public var settings: DwellSettings

    private var anchor: Vec2?
    private var anchorTime: TimeInterval = 0
    private var armed = false

    /// Changes every time the pointer settles somewhere new, so the app can check
    /// (once per resting spot) whether what's under the pointer is clickable.
    public private(set) var anchorID = 0
    public private(set) var anchorPosition: Vec2?

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
            anchorID &+= 1
            anchorPosition = position
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

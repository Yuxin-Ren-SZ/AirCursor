import Foundation

/// Maps head angular velocity to cursor velocity.
///
/// Velocity ("relative") mapping is used rather than absolute angle mapping: it never
/// needs recalibration, survives sensor drift, and lets you "ratchet" across large or
/// multiple displays the way you'd lift and re-place a mouse.
public enum PointerMapper {
    /// Cursor pixels per degree of head rotation at sensitivity 1, no acceleration.
    public static let pixelsPerDegree: Double = 28

    /// Speed (px/s) for one axis given a rotation rate in deg/s. Sign is preserved.
    public static func axisSpeed(_ rate: Double, settings: PointerSettings) -> Double {
        let magnitude = abs(rate)
        guard magnitude > settings.deadzone else { return 0 }
        let effective = magnitude - settings.deadzone
        // Gentle, bounded acceleration: slow head = precise, fast head = travel.
        let boost = 1 + settings.acceleration * min(effective / 60, 3)
        let speed = effective * pixelsPerDegree * settings.sensitivity * boost
        return rate < 0 ? -speed : speed
    }

    /// Cursor velocity in screen points per second, in CoreGraphics global
    /// coordinates (origin top-left, +y is down).
    ///
    /// Turning the head left (+yaw) moves the cursor left; looking up (+pitch) moves it up.
    public static func cursorVelocity(rates: AngularRates, settings: PointerSettings) -> Vec2 {
        var dx = -axisSpeed(rates.yaw, settings: settings)
        var dy = -axisSpeed(rates.pitch, settings: settings)
        if settings.invertHorizontal { dx = -dx }
        if settings.invertVertical { dy = -dy }
        return Vec2(dx, dy)
    }
}

/// Headphone motion arrives at ~25 Hz; the screen refreshes at 60–120 Hz. The smoother
/// eases the cursor toward the latest target velocity every frame so motion is fluid,
/// and stops it promptly if samples go stale (AirPods removed or disconnected).
public struct PointerSmoother: Sendable {
    public static let staleAfter: TimeInterval = 0.12

    public private(set) var velocity: Vec2 = .zero
    private var target: Vec2 = .zero
    private var targetTime: TimeInterval = -.infinity

    public init() {}

    public mutating func setTarget(_ v: Vec2, at time: TimeInterval) {
        guard v.x.isFinite, v.y.isFinite, time.isFinite else { reset(); return }
        target = v
        targetTime = time
    }

    public mutating func reset() {
        velocity = .zero
        target = .zero
        targetTime = -.infinity
    }

    /// Advances by `dt` seconds and returns the cursor displacement for this frame.
    public mutating func step(now: TimeInterval, dt: Double, smoothing: Double) -> Vec2 {
        guard dt.isFinite, now.isFinite, dt > 0 else { return .zero }
        let goal = (now - targetTime) > Self.staleAfter ? .zero : target
        let s = bounded(smoothing, 0.18, 0, 0.97)
        // Frame-rate independent exponential smoothing (s is the per-1/60s retention).
        let alpha = 1 - pow(s, dt * 60)
        velocity += (goal - velocity) * alpha
        if goal == .zero, velocity.length < 2 { velocity = .zero }
        return velocity * dt
    }
}

/// Radial dead zone with hysteresis and a smooth, bounded precision-to-travel gain.
/// One gain for both axes preserves diagonal direction.
public struct PointerResponse: Sendable {
    private var active = false
    private var restNoise = 0.2
    public init() {}
    public mutating func reset() { active = false }

    public mutating func velocity(rates: AngularRates, settings: PointerSettings,
                                  mayLearnNoise: Bool = true) -> Vec2 {
        let magnitude = hypot(rates.yaw, rates.pitch)
        guard magnitude.isFinite else { reset(); return .zero }
        let base = bounded(settings.deadzone, 1.2, 0, 20)
        if mayLearnNoise, !active, magnitude < max(base, 0.5) {
            restNoise += (magnitude - restNoise) * 0.04
        }
        let deadzone = settings.adaptiveDeadzone && base > 0
            ? max(base, min(base * 2, restNoise * 2)) : base
        // Enter above the full threshold; leave below 65%. A continuous soft knee
        // keeps the change in gain at the threshold small.
        if active { active = magnitude > deadzone * 0.65 }
        else { active = magnitude > deadzone }
        guard active, magnitude > 0 else { return .zero }
        let effective = max(0, magnitude - deadzone * 0.65)
        let knee = deadzone > 0 ? min(1, effective / max(deadzone * 0.7, 0.01)) : 1
        let precision = bounded(settings.precisionGain, 18, 1, 100)
        let travel = max(precision, bounded(settings.travelGain, 48, 1, 200))
        let transition = bounded(settings.transitionSpeed, 35, 0.5, 120)
        let precisionSpeed = bounded(settings.precisionSpeed, 5, 0.5, 100)
        let t = min(1, max(0, (effective - precisionSpeed) / transition))
        let blend = t * t * (3 - 2 * t)
        let gain = precision + (travel - precision) * blend * bounded(settings.acceleration, 0.6, 0, 2) / 0.6
        let speed = effective * knee * gain * bounded(settings.sensitivity, 1, 0.05, 8)
        let x = -rates.yaw / magnitude * speed * (settings.invertHorizontal ? -1 : 1)
        let y = -rates.pitch / magnitude * speed * (settings.invertVertical ? -1 : 1)
        return Vec2(x, y)
    }
}

/// Recent cursor positions, so a head gesture can click where you were pointing
/// *before* the gesture itself nudged the cursor.
public struct CursorHistory: Sendable {
    private var buffer: [(time: TimeInterval, position: Vec2)] = []
    private var head = 0
    public let capacity: Int

    public init(capacity: Int = 360) {
        self.capacity = max(1, capacity)
        buffer.reserveCapacity(self.capacity)
    }

    public mutating func append(_ position: Vec2, at time: TimeInterval) {
        if buffer.count < capacity {
            buffer.append((time, position))
        } else {
            buffer[head] = (time, position)
            head = (head + 1) % capacity
        }
    }

    public mutating func removeAll() {
        buffer.removeAll(keepingCapacity: true)
        head = 0
    }

    /// Most recent position recorded at or before `time`; the oldest one if `time`
    /// predates the buffer; nil if empty.
    public func position(at time: TimeInterval) -> Vec2? {
        guard !buffer.isEmpty else { return nil }
        let ordered = buffer.count < capacity ? buffer : Array(buffer[head...] + buffer[..<head])
        var best = ordered[0].position
        for entry in ordered {
            if entry.time <= time { best = entry.position } else { break }
        }
        return best
    }
}

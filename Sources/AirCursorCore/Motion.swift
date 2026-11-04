import Foundation

/// One attitude reading from the headphones. Angles are in radians, timestamp in seconds.
public struct MotionSample: Equatable, Sendable {
    public var timestamp: TimeInterval
    public var yaw: Double
    public var pitch: Double
    public var roll: Double

    public init(timestamp: TimeInterval, yaw: Double, pitch: Double, roll: Double) {
        self.timestamp = timestamp
        self.yaw = yaw
        self.pitch = pitch
        self.roll = roll
    }
}

/// Angular velocities in degrees per second, derived from consecutive attitude samples.
public struct AngularRates: Equatable, Sendable {
    public var timestamp: TimeInterval
    public var yaw: Double
    public var pitch: Double
    public var roll: Double

    public init(timestamp: TimeInterval, yaw: Double, pitch: Double, roll: Double) {
        self.timestamp = timestamp
        self.yaw = yaw
        self.pitch = pitch
        self.roll = roll
    }
}

/// Turns a stream of attitude samples into angular rates, handling wrap-around and
/// rejecting gaps (e.g. after a Bluetooth hiccup) so they never produce a cursor jump.
public struct MotionDifferentiator: Sendable {
    public static let minInterval: TimeInterval = 0.002
    public static let maxInterval: TimeInterval = 0.25

    private var last: MotionSample?

    public init() {}

    public mutating func reset() { last = nil }

    public mutating func push(_ sample: MotionSample) -> AngularRates? {
        defer { last = sample }
        guard let previous = last else { return nil }
        let dt = sample.timestamp - previous.timestamp
        guard dt >= Self.minInterval, dt <= Self.maxInterval else { return nil }
        return AngularRates(
            timestamp: sample.timestamp,
            yaw: AngleMath.degrees(AngleMath.wrappedDelta(sample.yaw, previous.yaw)) / dt,
            pitch: AngleMath.degrees(AngleMath.wrappedDelta(sample.pitch, previous.pitch)) / dt,
            roll: AngleMath.degrees(AngleMath.wrappedDelta(sample.roll, previous.roll)) / dt
        )
    }
}

import Foundation

public struct Vec3: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double
    public init(_ x: Double, _ y: Double, _ z: Double) { self.x = x; self.y = y; self.z = z }
    public var length: Double { hypot(hypot(x, y), z) }
    public var isFinite: Bool { x.isFinite && y.isFinite && z.isFinite }
}

public struct OrientationQuaternion: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double
    public var w: Double
    public init(x: Double, y: Double, z: Double, w: Double) {
        self.x = x; self.y = y; self.z = z; self.w = w
    }
    public var isValid: Bool {
        [x, y, z, w].allSatisfy(\.isFinite) && abs(x*x + y*y + z*z + w*w - 1) < 0.1
    }
}

/// Acquisition boundary: providers normalize their sample timestamps to monotonic seconds.
/// Device-frame rotation rates must be transformed before use as yaw/pitch/roll rates.
public protocol HeadMotionSource: AnyObject {
    var onSample: ((MotionSample) -> Void)? { get set }
    func start()
    func stop()
}

/// Future gaze providers report absolute, calibrated screen observations separately from
/// relative head motion. This contract does not enable capture or fuse the two implicitly.
public struct GazeObservation: Equatable, Sendable {
    public var timestamp: TimeInterval
    public var screenID: String
    public var normalizedPosition: Vec2
    public var standardDeviation: Vec2
    public var sourceID: String
    public init(timestamp: TimeInterval, screenID: String, normalizedPosition: Vec2,
                standardDeviation: Vec2, sourceID: String) {
        self.timestamp = timestamp; self.screenID = screenID
        self.normalizedPosition = normalizedPosition; self.standardDeviation = standardDeviation
        self.sourceID = sourceID
    }
}

public protocol GazeSource: AnyObject {
    var onObservation: ((GazeObservation) -> Void)? { get set }
    func start()
    func stop()
}

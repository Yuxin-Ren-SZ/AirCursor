import Foundation

public enum MotionFilterMode: String, Codable, CaseIterable, Sendable {
    case kalman, legacy
}

/// Standard deviations have physical units; covariance matrices are derived using dt.
public struct KalmanSettings: Codable, Equatable, Sendable {
    public var measurementNoise: Double = 0.15 // degrees
    public var processAcceleration: Double = 100 // degrees/s²
    public var learnStationaryNoise: Bool = true
    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self), d = Self()
        measurementNoise = c.value(.measurementNoise, default: d.measurementNoise)
        processAcceleration = c.value(.processAcceleration, default: d.processAcceleration)
        learnStationaryNoise = c.value(.learnStationaryNoise, default: d.learnStationaryNoise)
    }
}

public struct RepositioningSettings: Codable, Equatable, Sendable {
    public var enabled = true
    public var cautionAcceleration: Double = 0.045 // g
    public var freezeAcceleration: Double = 0.18 // g, sustained for 120 ms
    public var cautiousGain: Double = 0.35
    public var settleTime: Double = 0.25
    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self), d = Self()
        enabled = c.value(.enabled, default: d.enabled)
        cautionAcceleration = c.value(.cautionAcceleration, default: d.cautionAcceleration)
        freezeAcceleration = c.value(.freezeAcceleration, default: d.freezeAcceleration)
        cautiousGain = c.value(.cautiousGain, default: d.cautiousGain)
        settleTime = c.value(.settleTime, default: d.settleTime)
    }
}

func bounded(_ value: Double, _ fallback: Double, _ lower: Double, _ upper: Double) -> Double {
    value.isFinite ? min(max(value, lower), upper) : fallback
}

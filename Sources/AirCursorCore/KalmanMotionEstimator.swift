import Foundation

public struct MotionEstimate: Sendable {
    public var rates: AngularRates?
    public var rateStandardDeviation: Vec3
    public var accepted: Bool
}

/// Constant-angular-velocity Kalman model, one [angle, rate] state per axis.
/// Observes attitude only: CoreMotion's device-frame gyro is retained for diagnostics
/// and stationary detection, not fused as an independent attitude measurement.
public struct KalmanMotionEstimator: Sendable {
    private struct Axis: Sendable {
        var angle: Double
        var rate = 0.0
        var p00: Double
        var p01 = 0.0
        var p11 = 400.0

        func innovation(_ observation: Double, dt: Double, q: Double, r: Double) -> (Double, Double) {
            let prediction = angle + rate * dt
            let residual = AngleMath.wrappedDeltaDegrees(observation, prediction)
            let variance = p00 + 2 * dt * p01 + dt * dt * p11 + q * pow(dt, 4) / 4 + r
            return (residual, variance)
        }

        mutating func update(_ observation: Double, dt: Double, q: Double, r: Double) {
            let a = p00 + 2 * dt * p01 + dt * dt * p11 + q * pow(dt, 4) / 4
            let b = p01 + dt * p11 + q * pow(dt, 3) / 2
            let c = p11 + q * dt * dt
            let residual = AngleMath.wrappedDeltaDegrees(observation, angle + rate * dt)
            let k0 = a / (a + r), k1 = b / (a + r)
            angle += rate * dt + k0 * residual
            rate += k1 * residual
            // Scalar-observation Joseph update keeps covariance symmetric/nonnegative.
            p00 = max(1e-12, (1-k0)*(1-k0)*a + k0*k0*r)
            p01 = (1-k0)*(b-k1*a) + k0*k1*r
            p11 = max(1e-12, c - 2*k1*b + k1*k1*(a+r))
        }
    }

    private var axes: [Axis] = []
    private var last: MotionSample?
    private var rejectedCount = 0
    private var learnedVariance: Double?
    private var quietSamples = 0
    public private(set) var measurementNoise = 0.15

    public init() {}
    public mutating func reset() { self = Self() }

    public mutating func push(_ sample: MotionSample, settings: KalmanSettings) -> MotionEstimate {
        let configuredNoise = bounded(settings.measurementNoise, 0.15, 0.01, 2)
        measurementNoise = settings.learnStationaryNoise ? sqrt(learnedVariance ?? configuredNoise*configuredNoise) : configuredNoise
        let r = measurementNoise * measurementNoise
        let values = [sample.yaw, sample.pitch, sample.roll].map(AngleMath.degrees)
        func result(_ rates: AngularRates? = nil, accepted: Bool = true) -> MotionEstimate {
            let deviations = axes.map { sqrt($0.p11) }
            return MotionEstimate(rates: rates,
                rateStandardDeviation: deviations.count == 3 ? Vec3(deviations[0], deviations[1], deviations[2]) : Vec3(20, 20, 20),
                accepted: accepted)
        }
        guard sample.isFinite else { reset(); return result(accepted: false) }
        guard let previous = last else {
            axes = values.map { Axis(angle: $0, p00: r) }
            last = sample
            return result()
        }
        let dt = sample.timestamp - previous.timestamp
        guard dt >= MotionDifferentiator.minInterval else { return result(accepted: false) }
        guard dt <= MotionDifferentiator.maxInterval, sample.sourceID == previous.sourceID else {
            reset()
            _ = push(sample, settings: settings)
            return result(accepted: false)
        }
        let previousValues = [previous.yaw, previous.pitch, previous.roll].map(AngleMath.degrees)
        let deltas = zip(values, previousValues).map { AngleMath.wrappedDeltaDegrees($0.0, $0.1) }
        // More model freedom during deliberate fast turns; quiet input keeps strong
        // noise rejection. A physical-rate check still rejects large sensor spikes.
        let observedSpeed = deltas.map { abs($0) / dt }.max() ?? 0
        let maneuver = min(6, max(0, observedSpeed - 10) / 30)
        let q = pow(bounded(settings.processAcceleration, 100, 1, 2000) * (1 + maneuver), 2)
        let inconsistent = zip(axes, values).contains { axis, value in
            let (residual, variance) = axis.innovation(value, dt: dt, q: q, r: r)
            return abs(residual) > max(12, 6 * sqrt(variance))
        }
        guard !inconsistent, deltas.allSatisfy({ abs($0) / dt <= 720 }) else {
            rejectedCount += 1
            // A sustained new pose may be a reference change. Re-seed without emitting
            // the rejected displacement; the output gate still requires a quiet period.
            if rejectedCount >= 3 {
                axes = values.map { Axis(angle: $0, p00: r) }
                last = sample
                rejectedCount = 0
            }
            return result(accepted: false)
        }
        rejectedCount = 0
        for i in axes.indices { axes[i].update(values[i], dt: dt, q: q, r: r) }

        let gyroQuiet = sample.rotationRate.map { AngleMath.degrees($0.length) < 5 } ?? true
        let quiet = gyroQuiet && (sample.userAcceleration?.length ?? 0) < 0.025
            && deltas.allSatisfy { abs($0) / dt < 5 }
        quietSamples = quiet ? quietSamples + 1 : 0
        if settings.learnStationaryNoise, quietSamples >= 50 {
            let observed = deltas.reduce(0) { $0 + $1*$1 } / 6
            let alpha = 1 - exp(-dt / 2)
            learnedVariance = bounded((learnedVariance ?? r) * (1-alpha) + observed*alpha, r, 0.0009, 0.25)
        }
        last = sample
        return result(AngularRates(timestamp: sample.timestamp, yaw: axes[0].rate, pitch: axes[1].rate, roll: axes[2].rate))
    }
}

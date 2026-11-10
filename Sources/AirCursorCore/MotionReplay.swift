import Foundation

/// Aggregate-only, in-memory replay. Rate RMS is a jitter metric only for a resting
/// trace; intentional motion also contributes. No sensor recording is written to disk.
public struct MotionReplayReport: Equatable, Sendable {
    public var sampleCount = 0
    public var rawRateRMS = 0.0
    public var filteredRateRMS = 0.0
    public var suppressedSamples = 0
    public var gestures: [HeadGesture] = []
}

public enum MotionReplay {
    public static func run(_ samples: [MotionSample], pointer: PointerSettings,
                           gestures: GestureSettings, enabled: Set<HeadGesture>) -> MotionReplayReport {
        var pipeline = HeadControlPipeline(pointer: pointer, gestures: gestures)
        var report = MotionReplayReport()
        var rawEnergy = 0.0, filteredEnergy = 0.0, count = 0
        for sample in samples {
            let update = pipeline.process(sample, enabled: enabled)
            report.sampleCount += 1
            if update.gate != .normal { report.suppressedSamples += 1 }
            if let gesture = update.gesture { report.gestures.append(gesture.gesture) }
            if let raw = update.rawRates, let filtered = update.rates, update.accepted {
                rawEnergy += raw.yaw*raw.yaw + raw.pitch*raw.pitch
                filteredEnergy += filtered.yaw*filtered.yaw + filtered.pitch*filtered.pitch
                count += 1
            }
        }
        if count > 0 {
            report.rawRateRMS = sqrt(rawEnergy / Double(count))
            report.filteredRateRMS = sqrt(filteredEnergy / Double(count))
        }
        return report
    }
}

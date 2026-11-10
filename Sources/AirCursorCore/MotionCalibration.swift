import Foundation

public enum CalibrationPhase: String, CaseIterable, Codable, Identifiable, Sendable {
    case neutral, slowPointing, fastPointing, leftTilt, rightTilt, repositioning
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .neutral: "Rest naturally"
        case .slowPointing: "Small, slow turns"
        case .fastPointing: "Comfortable fast turns"
        case .leftTilt: "Three small left tilts"
        case .rightTilt: "Three small right tilts"
        case .repositioning: "Adjust your posture"
        }
    }
    public var instruction: String {
        switch self {
        case .neutral: "Sit comfortably and look straight ahead. Let your head rest naturally."
        case .slowPointing: "Make small, slow turns left and right, then up and down, as if adjusting the pointer onto a small button."
        case .fastPointing: "Turn left and right, then up and down, at a comfortable pace for crossing a large screen. No sudden or exaggerated movements are needed."
        case .leftTilt: "Start upright. Tilt your left ear gently toward your shoulder, hold briefly, then return upright. Repeat three times using a small, comfortable movement."
        case .rightTilt: "Start upright. Tilt your right ear gently toward your shoulder, hold briefly, then return upright. Repeat three times using a small, comfortable movement."
        case .repositioning: "Start still, then shift left/right, lean forward/back, and sit slightly higher/lower as you normally would. Pause between adjustments and finish still."
        }
    }
    public var duration: Double {
        switch self {
        case .neutral: 4
        case .slowPointing, .leftTilt, .rightTilt: 10
        case .fastPointing, .repositioning: 8
        }
    }
}

public struct CalibrationRecording: Sendable {
    public var phase: CalibrationPhase
    public var samples: [MotionSample]
    public var elapsed: Double
    public var rejectedSamples: Int
    public var gaps: Int
    public init(phase: CalibrationPhase, samples: [MotionSample], elapsed: Double,
                rejectedSamples: Int = 0, gaps: Int = 0) {
        self.phase = phase; self.samples = samples; self.elapsed = elapsed
        self.rejectedSamples = rejectedSamples; self.gaps = gaps
    }
}

/// Counts valid sensor time, not wall time, so a disconnected device cannot complete
/// a step. Raw observations are bounded and remain in memory until apply/cancel.
public struct CalibrationCapture: Sendable {
    public private(set) var recording: CalibrationRecording
    public private(set) var sourceChanged = false
    private var previous: MotionSample?
    public var isComplete: Bool { recording.elapsed >= recording.phase.duration }
    public init(phase: CalibrationPhase) {
        recording = CalibrationRecording(phase: phase, samples: [], elapsed: 0)
    }
    public mutating func push(_ sample: MotionSample) {
        guard !isComplete, !sourceChanged, recording.samples.count < 6000 else { return }
        guard sample.isFinite else { recording.rejectedSamples += 1; return }
        if let last = previous {
            guard last.sourceID == sample.sourceID else { sourceChanged = true; return }
            let dt = sample.timestamp - last.timestamp
            guard dt >= MotionDifferentiator.minInterval else { recording.rejectedSamples += 1; return }
            if dt > MotionDifferentiator.maxInterval {
                recording.gaps += 1
                previous = sample
                recording.samples.append(sample)
                return
            }
            let changes = [AngleMath.wrappedDelta(sample.yaw, last.yaw),
                           AngleMath.wrappedDelta(sample.pitch, last.pitch),
                           AngleMath.wrappedDelta(sample.roll, last.roll)]
            guard changes.allSatisfy({ abs(AngleMath.degrees($0)) / dt <= 720 }) else {
                recording.rejectedSamples += 1; return
            }
            recording.elapsed += dt
        }
        previous = sample
        recording.samples.append(sample)
    }
}

/// Derived summaries only; no raw sensor trajectory is persisted.
public struct CalibrationProfile: Codable, Equatable, Sendable {
    public var date: Date
    public var sourceID: String
    public var sampleCount: Int
    public var slowSpeed: Double
    public var fastSpeed: Double
    public var precisionMaximumSpeed: Double
    public var travelMinimumSpeed: Double
    public var leftTiltPeak: Double
    public var rightTiltPeak: Double
    public var minimumTiltAngle: Double
    public var repositioningLearned: Bool
    public var postureAccelerationRMS: Vec3
    public var notes: [String]
}

public struct CalibrationBackup: Codable, Equatable, Sendable {
    public var pointer: PointerSettings
    public var gestures: GestureSettings
    public var profile: CalibrationProfile?
    public init(pointer: PointerSettings, gestures: GestureSettings, profile: CalibrationProfile?) {
        self.pointer = pointer; self.gestures = gestures; self.profile = profile
    }
}

public struct CalibrationIssue: Equatable, Sendable {
    public var phase: CalibrationPhase
    public var message: String
    public init(phase: CalibrationPhase, message: String) { self.phase = phase; self.message = message }
}

public struct CalibrationReport: Sendable {
    public var pointer: PointerSettings
    public var gestures: GestureSettings
    public var profile: CalibrationProfile
    /// Session reference only; not persisted across sensor reconnects.
    public var neutralRoll: Double
}

public struct CalibrationAnalysis: Sendable {
    public var report: CalibrationReport?
    public var issues: [CalibrationIssue]
}

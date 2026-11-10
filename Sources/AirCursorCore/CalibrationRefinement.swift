import Foundation

public struct CalibrationDisplay: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var width: Double
    public var height: Double
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var scale: Double
    public init(id: String = "", name: String = "Display", width: Double = 1440, height: Double = 900,
                pixelWidth: Int = 1440, pixelHeight: Int = 900, scale: Double = 1) {
        self.id = id; self.name = name; self.width = width; self.height = height
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight; self.scale = scale
    }
}

public enum MovementFeedback: String, CaseIterable, Codable, Sendable {
    case untested, tooLittle, comfortable, tooMuch
}
public enum PostureFeedback: String, CaseIterable, Codable, Sendable {
    case untested, falsePauses, comfortable, missed
}
public enum ClickFeedback: String, CaseIterable, Codable, Sendable {
    case untested, tooHard, comfortable, accidental
}
public struct CalibrationFeedback: Codable, Equatable, Sendable {
    public var slow: MovementFeedback = .untested
    public var fast: MovementFeedback = .untested
    public var posture: PostureFeedback = .untested
    public var leftClick: ClickFeedback = .untested
    public var rightClick: ClickFeedback = .untested
    public init() {}
    public var hasResponse: Bool { slow != .untested || fast != .untested || posture != .untested || leftClick != .untested || rightClick != .untested }
}

public struct CalibrationTrialMetrics: Codable, Equatable, Sendable {
    public var duration = 0.0
    public var posturePaused = 0.0
    public var signalPaused = 0.0
    public var nearTargets = 0
    public var farTargets = 0
    public var leftClicks = 0
    public var rightClicks = 0
    public init() {}
    public mutating func observe(dt: Double, gate: InputGateState, reason: InputGateReason) {
        guard dt.isFinite, dt > 0, dt <= 0.25 else { return }
        duration += dt
        if gate != .normal {
            if reason == .posture { posturePaused += dt } else { signalPaused += dt }
        }
    }
    public var postureFraction: Double { duration > 0 ? posturePaused / duration : 0 }
}

public struct CalibrationRefinement: Codable, Equatable, Sendable {
    public var number: Int
    public var feedback: CalibrationFeedback
    public var metrics: CalibrationTrialMetrics
    public var before: PointerSettings
    public var after: PointerSettings
    public var beforeGestures: GestureSettings?
    public var afterGestures: GestureSettings?
    public var changes: [String]
}

public enum CalibrationRefiner {
    public static func refine(_ original: CalibrationReport, feedback: CalibrationFeedback,
                              metrics: CalibrationTrialMetrics) -> CalibrationReport {
        guard feedback.hasResponse else { return original }
        var report = original, changes: [String] = []
        switch feedback.slow {
        case .tooLittle: report.pointer.precisionGain = min(60, report.pointer.precisionGain * 1.25)
        case .tooMuch: report.pointer.precisionGain = max(4, report.pointer.precisionGain * 0.8)
        default: break
        }
        switch feedback.fast {
        case .tooLittle: report.pointer.travelGain = min(120, report.pointer.travelGain * 1.2)
        case .tooMuch: report.pointer.travelGain = max(report.pointer.precisionGain, report.pointer.travelGain * 0.8)
        default: break
        }
        report.pointer.travelGain = max(report.pointer.precisionGain, report.pointer.travelGain)
        if feedback.slow == .tooLittle || feedback.slow == .tooMuch {
            changes.append(String(format: "Fine gain: %.1f → %.1f points/degree.", original.pointer.precisionGain, report.pointer.precisionGain))
        }
        if feedback.fast == .tooLittle || feedback.fast == .tooMuch || report.pointer.travelGain != original.pointer.travelGain {
            changes.append(String(format: "Travel gain: %.1f → %.1f points/degree.", original.pointer.travelGain, report.pointer.travelGain))
        }
        let minimumCaution = max(0.04, (report.profile.ordinaryResidualUpperBound ?? 0.02) * 1.35 + 0.01)
        switch feedback.posture {
        case .falsePauses:
            report.pointer.repositioning.cautionAcceleration = min(0.3, max(minimumCaution, report.pointer.repositioning.cautionAcceleration * 1.3))
            report.pointer.repositioning.freezeAcceleration = min(0.9, max(report.pointer.repositioning.cautionAcceleration * 2, report.pointer.repositioning.freezeAcceleration * 1.25))
            report.pointer.repositioning.cautionDuration = min(0.4, report.pointer.repositioning.cautionDuration + 0.04)
            report.pointer.repositioning.freezeDuration = min(0.6, report.pointer.repositioning.freezeDuration + 0.04)
            report.pointer.repositioning.cautiousGain = min(0.9, report.pointer.repositioning.cautiousGain + 0.1)
            report.pointer.repositioning.settleTime = max(0.06, report.pointer.repositioning.settleTime * 0.8)
            changes.append("Posture suppression is less sensitive and resumes sooner. Invalid-signal stops remain active.")
        case .missed:
            report.pointer.repositioning.cautionAcceleration = max(minimumCaution, report.pointer.repositioning.cautionAcceleration * 0.85)
            let floor = max(0.16, (report.profile.ordinaryRawUpperBound ?? 0.05) * 1.5, report.pointer.repositioning.cautionAcceleration * 2)
            report.pointer.repositioning.freezeAcceleration = max(floor, report.pointer.repositioning.freezeAcceleration * 0.85)
            report.pointer.repositioning.cautionDuration = max(0.08, report.pointer.repositioning.cautionDuration - 0.02)
            changes.append("Posture detection is more sensitive, within the measured normal-motion margin.")
        default: break
        }
        for side in [HeadGesture.tiltLeft, .tiltRight] {
            let rating = side == .tiltLeft ? feedback.leftClick : feedback.rightClick
            var angle = report.gestures.angle(for: side), hold = report.gestures.hold(for: side)
            if rating == .tooHard {
                angle = max(report.profile.minimumTiltAngle, angle * 0.9)
                hold = max(0.12, hold * 0.85)
            } else if rating == .accidental {
                angle = min(30, angle * 1.15); hold = min(0.6, hold * 1.15)
            }
            if rating == .tooHard || rating == .accidental {
                changes.append(String(format: "%@ click: %.1f° → %.1f°; hold %.0f → %.0f ms.",
                    side == .tiltLeft ? "Left" : "Right", report.gestures.angle(for: side), angle,
                    report.gestures.hold(for: side)*1000, hold*1000))
                if rating == .tooHard, angle <= report.profile.minimumTiltAngle + 0.001 {
                    changes.append("The \(side == .tiltLeft ? "left" : "right") angle has reached the measured pointing-noise margin. Re-record pointing and tilts to try a smaller angle.")
                }
            }
            if side == .tiltLeft { report.gestures.leftTiltAngle = angle; report.gestures.leftTiltHold = hold }
            else { report.gestures.rightTiltAngle = angle; report.gestures.rightTiltHold = hold }
        }
        report.gestures.tiltAngle = (report.gestures.angle(for: .tiltLeft) + report.gestures.angle(for: .tiltRight)) / 2
        report.gestures.tiltHold = (report.gestures.hold(for: .tiltLeft) + report.gestures.hold(for: .tiltRight)) / 2
        if changes.isEmpty { changes.append("These controls felt comfortable. Keep them and test another movement, or apply.") }
        report.profile.refinementCount += 1
        report.profile.refinements.append(CalibrationRefinement(number: report.profile.refinementCount, feedback: feedback,
            metrics: metrics, before: original.pointer, after: report.pointer,
            beforeGestures: original.gestures, afterGestures: report.gestures, changes: changes))
        report.profile.refinements = Array(report.profile.refinements.suffix(20))
        return report
    }
}

public enum CalibrationPreviewMode: String, CaseIterable, Sendable { case precision, travel }
public struct CalibrationPreviewGeometry: Sendable {
    public var scale: Double
    public var origin: Vec2
    public var size: Vec2
    public init(display: CalibrationDisplay, mode: CalibrationPreviewMode) {
        let width = bounded(display.width, 1440, 320, 12000), height = bounded(display.height, 900, 200, 8000)
        scale = mode == .precision ? 1 : min(520 / width, 220 / height)
        size = mode == .precision ? Vec2(520,220) : Vec2(min(520, width*scale), min(220, height*scale))
        origin = Vec2((520-size.x)/2, (220-size.y)/2)
    }
    public var targets: [Vec2] {
        [Vec2(0.08,0.5), Vec2(0.38,0.5), Vec2(0.62,0.5), Vec2(0.92,0.5), Vec2(0.5,0.18), Vec2(0.5,0.82)]
            .map { Vec2(origin.x + $0.x*size.x, origin.y + $0.y*size.y) }
    }
    public func clamp(_ point: Vec2) -> Vec2 {
        Vec2(min(origin.x + size.x - 6, max(origin.x+6, point.x)), min(origin.y+size.y-6, max(origin.y+6, point.y)))
    }
}

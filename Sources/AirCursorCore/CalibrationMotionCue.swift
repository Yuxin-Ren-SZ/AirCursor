import Foundation

public struct CalibrationCueFrame: Sendable {
    public var left: Vec2
    public var right: Vec2
    public var size: Double
    public var instruction: String
}

/// Normalized ear-dot positions, independent of animation timing and rendering.
public enum CalibrationMotionCue {
    public static func frame(phase: CalibrationPhase, elapsed: Double) -> CalibrationCueFrame {
        let t = max(0, elapsed.isFinite ? elapsed : 0).truncatingRemainder(dividingBy: phase.duration)
        var x = 0.0, y = 0.0, roll = 0.0, depth = 1.0
        var instruction = "Stay naturally upright"
        func pulse(_ time: Double, over duration: Double) -> Double {
            guard time < duration else { return 0 }
            return pow(sin(.pi * max(0, time) / duration), 2)
        }
        switch phase {
        case .neutral: break
        case .slowPointing, .fastPointing:
            let interval = phase.duration / 4
            let segment = min(3, Int(t / interval))
            let amount = pulse(t.truncatingRemainder(dividingBy: interval), over: phase == .slowPointing ? 2.3 : 0.8)
            let pace = phase == .slowPointing ? "slowly" : "at your comfortable travel pace"
            switch segment {
            case 0: x = -0.45 * amount; instruction = "Turn left \(pace), then return"
            case 1: x = 0.45 * amount; instruction = "Turn right \(pace), then return"
            case 2: y = -0.35 * amount; instruction = "Look up \(pace), then return"
            default: y = 0.35 * amount; instruction = "Look down \(pace), then return"
            }
        case .leftTilt, .rightTilt:
            let cycle = phase.duration / 3
            let local = t.truncatingRemainder(dividingBy: cycle)
            let amount: Double
            if local < 0.25 { amount = 0; instruction = "Start upright" }
            else if local < 0.75 { amount = (local-0.25)/0.5; instruction = "Tilt \(phase == .leftTilt ? "left" : "right") comfortably" }
            else if local < 1.45 { amount = 1; instruction = "Hold briefly" }
            else if local < 1.95 { amount = 1-(local-1.45)/0.5; instruction = "Return upright" }
            else { amount = 0; instruction = "Rest upright, then repeat" }
            roll = (phase == .leftTilt ? -1 : 1) * amount * 0.3
        case .repositioning:
            let segment = min(5, Int(t / 2))
            let amount = pulse(t.truncatingRemainder(dividingBy: 2), over: 1.6)
            switch segment {
            case 0: x = -0.45 * amount; instruction = "Shift your body left, then return"
            case 1: x = 0.45 * amount; instruction = "Shift your body right, then return"
            case 2: depth = 1 + 0.35 * amount; instruction = "Lean forward toward the screen, then return"
            case 3: depth = 1 - 0.25 * amount; instruction = "Lean back from the screen, then return"
            case 4: y = -0.35 * amount; instruction = "Sit slightly higher, then return"
            default: y = 0.35 * amount; instruction = "Sit slightly lower, then return"
            }
        }
        let span = 0.3 * depth
        return CalibrationCueFrame(left: Vec2(x - cos(roll)*span, y - sin(roll)*span),
                                   right: Vec2(x + cos(roll)*span, y + sin(roll)*span),
                                   size: depth, instruction: instruction)
    }
}

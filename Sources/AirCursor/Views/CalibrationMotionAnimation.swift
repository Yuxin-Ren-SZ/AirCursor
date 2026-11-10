import SwiftUI
import AirCursorCore

/// A front view of the user's ears. Capture time drives the cue so sensor gaps
/// pause both the recording and the demonstration at the same point.
struct CalibrationMotionAnimation: View {
    var phase: CalibrationPhase
    var recordingTime: Double?
    var countdown: Int
    @State private var started = Date()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            let elapsed = countdown > 0 ? 0 : recordingTime ?? timeline.date.timeIntervalSince(started)
            let cue = CalibrationMotionCue.frame(phase: phase, elapsed: elapsed)
            VStack(spacing: 8) {
                ZStack {
                    // Neutral position makes both translation and tilt easy to see.
                    Path { path in
                        path.move(to: CGPoint(x: 190, y: 75))
                        path.addLine(to: CGPoint(x: 330, y: 75))
                    }.stroke(Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 2, dash: [4, 5]))
                    ear("L", color: .blue, point: cue.left, depth: cue.size)
                    ear("R", color: .purple, point: cue.right, depth: cue.size)
                }
                .frame(width: 520, height: 150)
                .accessibilityHidden(true)
                Text(countdown > 0 ? "Start upright · recording soon" : cue.instruction)
                    .font(.headline).frame(maxWidth: .infinity)
                Text("Dots represent your left and right ear. Follow the pace with a comfortable range of motion.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.05)))
        .onChange(of: phase) { _, _ in started = Date() }
        .onChange(of: recordingTime != nil) { _, _ in started = Date() }
    }

    private func ear(_ label: String, color: Color, point: Vec2, depth: Double) -> some View {
        Text(label).font(.caption.bold()).foregroundStyle(.white)
            .frame(width: 28 * depth, height: 28 * depth)
            .background(Circle().fill(color))
            .position(x: 260 + point.x * 230, y: 75 + point.y * 130)
    }
}

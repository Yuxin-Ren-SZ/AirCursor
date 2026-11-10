import SwiftUI
import AirCursorCore

struct CalibrationFeedbackPanel: View {
    @EnvironmentObject private var calibration: MotionCalibrationController
    @State private var feedback = CalibrationFeedback()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("How did that feel?").font(.headline)
            Text("Try nearby targets in Fine control, outer targets in Whole-display travel, both click tilts, and a posture shift. Rate what you tried; leave the rest as Not tried.")
                .font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 16) {
                Text("Near targets: \(calibration.trial.nearTargets)")
                Text("Far targets: \(calibration.trial.farTargets)")
                Text(String(format: "Posture suppression: %.0f%%", calibration.trial.postureFraction * 100))
            }.font(.caption.monospacedDigit())
            if calibration.trial.signalPaused > 0 {
                Text(String(format: "Sensor interruptions: %.1f s — these are separate from posture detection.", calibration.trial.signalPaused))
                    .font(.caption).foregroundStyle(.orange)
            }
            movementRating("Slow / fine movement", selection: $feedback.slow)
            movementRating("Fast / long-distance travel", selection: $feedback.fast)
            Picker("Posture detection", selection: $feedback.posture) {
                Text("Not tried").tag(PostureFeedback.untested)
                Text("Pauses during pointing or clicks").tag(PostureFeedback.falsePauses)
                Text("Feels right").tag(PostureFeedback.comfortable)
                Text("Misses my posture shifts").tag(PostureFeedback.missed)
            }
            clickRating("Left tilt click", selection: $feedback.leftClick)
            clickRating("Right tilt click", selection: $feedback.rightClick)
            HStack {
                Button("Update and try again") {
                    calibration.applyFeedback(feedback)
                    feedback = CalibrationFeedback()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!feedback.hasResponse || !calibration.live.fresh)
                Button("Undo last adjustment") {
                    calibration.undoFeedback()
                    feedback = CalibrationFeedback()
                }.disabled(!calibration.canUndoFeedback)
            }
            if !calibration.feedbackChanges.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Changed for this round").font(.callout.bold())
                    ForEach(calibration.feedbackChanges, id: \.self) { Text($0).font(.callout) }
                }
            }
            if let refinements = calibration.report?.profile.refinements, !refinements.isEmpty {
                DisclosureGroup("Previous feedback rounds (\(refinements.count) retained)") {
                    ForEach(Array(refinements.reversed()), id: \.number) { refinement in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Round \(refinement.number)").font(.caption.bold())
                            ForEach(refinement.changes, id: \.self) { Text($0).font(.caption) }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                    }
                }
            }
            Text("Changes stay in this preview until Apply. You can repeat feedback rounds or undo an adjustment.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.06)))
        .onChange(of: calibration.roundNumber) { _, _ in feedback = CalibrationFeedback() }
    }

    private func movementRating(_ title: String, selection: Binding<MovementFeedback>) -> some View {
        Picker(title, selection: selection) {
            Text("Not tried").tag(MovementFeedback.untested)
            Text("Too little movement").tag(MovementFeedback.tooLittle)
            Text("Feels right").tag(MovementFeedback.comfortable)
            Text("Too much movement").tag(MovementFeedback.tooMuch)
        }
    }

    private func clickRating(_ title: String, selection: Binding<ClickFeedback>) -> some View {
        Picker(title, selection: selection) {
            Text("Not tried").tag(ClickFeedback.untested)
            Text("Too much effort").tag(ClickFeedback.tooHard)
            Text("Feels right").tag(ClickFeedback.comfortable)
            Text("Accidental clicks").tag(ClickFeedback.accidental)
        }
    }
}

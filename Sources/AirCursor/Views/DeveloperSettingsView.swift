import SwiftUI
import AirCursorCore

struct DeveloperSettingsView: View {
    @EnvironmentObject private var controller: AppController
    var body: some View {
        Form {
            Section("Personal motion calibration") {
                Text("Record resting noise, slow and fast pointing, comfortable click tilts, and normal posture adjustments. Review and preview the result before applying.")
                Button("Open guided calibration…") { controller.showCalibration() }
                    .buttonStyle(.borderedProminent)
                if let profile = controller.settings.calibrationProfile {
                    LabeledContent("Last calibrated", value: profile.date.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Source", value: profile.sourceID)
                    LabeledContent("Samples used", value: "\(profile.sampleCount)")
                    LabeledContent("Slow / fast speed", value: String(format: "%.1f / %.1f°/s", profile.slowSpeed, profile.fastSpeed))
                    LabeledContent("Natural left / right tilt", value: String(format: "%.1f / %.1f°", profile.leftTiltPeak, profile.rightTiltPeak))
                    LabeledContent("Posture learning", value: profile.repositioningLearned ? "Applied" : "Previous settings retained")
                    LabeledContent("Posture acceleration RMS", value: String(format: "x %.3f · y %.3f · z %.3f g",
                        profile.postureAccelerationRMS.x, profile.postureAccelerationRMS.y, profile.postureAccelerationRMS.z))
                    ForEach(profile.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                }
                Button("Undo last calibration") { controller.undoCalibration() }
                    .disabled(controller.settings.calibrationBackup == nil || controller.calibration.isActive)
                Text("Calibration is opt-in. Each applied session replaces the personal profile and keeps one undo snapshot. Raw motion is never saved.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Live signal inspection") {
                LabeledContent("Input state", value: controller.live.inputState)
                LabeledContent("Yaw: raw / filtered", value: String(format: "%.2f / %.2f°/s", controller.live.rawYawRate, controller.live.yawRate))
                LabeledContent("Pitch: raw / filtered", value: String(format: "%.2f / %.2f°/s", controller.live.rawPitchRate, controller.live.pitchRate))
                LabeledContent("Relative roll", value: String(format: "%.2f°", controller.live.relativeRoll))
                if let a = controller.live.accelerationVector {
                    LabeledContent("Acceleration", value: String(format: "x %.3f · y %.3f · z %.3f g", a.x, a.y, a.z))
                }
                Text("These observations describe rotation and acceleration, not translational position or speed. The calibration window plots live channels while recording.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

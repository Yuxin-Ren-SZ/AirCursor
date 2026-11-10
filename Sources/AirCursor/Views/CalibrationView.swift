import SwiftUI
import Combine
import AirCursorCore

struct CalibrationView: View {
    @EnvironmentObject private var controller: AppController
    @EnvironmentObject private var calibration: MotionCalibrationController
    @Environment(\.dismissWindow) private var dismissWindow
    private let frames = Timer.publish(every: 1.0/60, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Motion calibration").font(.title2.bold())
                    Text("Developer mode · comfortable movement, personal settings")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button(calibration.isActive ? "Cancel" : "Close") {
                    controller.finishCalibration()
                    dismissWindow(id: WindowID.calibration)
                }
            }
            .padding(20)
            Divider()
            if !calibration.isActive {
                welcome.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                HStack(alignment: .top, spacing: 0) {
                    phaseList.frame(width: 175).padding(.top, 16)
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            if let report = calibration.report { review(report) }
                            else if !calibration.issues.isEmpty { sampleIssues }
                            else { captureStep }
                        }
                        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .onReceive(frames) { _ in calibration.advance(now: ProcessInfo.processInfo.systemUptime) }
        .onAppear { controller.windowVisibilityChanged(); controller.updateCalibrationDisplay() }
        .onDisappear {
            controller.finishCalibration()
            controller.windowVisibilityChanged()
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Make head control fit you").font(.largeTitle.bold())
            Text("About a minute of natural movements helps find your precision range, fast-travel range, comfortable click tilts, and posture-adjustment settings.")
                .font(.title3).fixedSize(horizontal: false, vertical: true)
            Label("Head-controlled pointer, clicks, scrolling and stem actions pause during capture and preview. Use your mouse or keyboard for this guide.", systemImage: "pause.circle")
            Label("Raw motion stays in memory. Only the settings and a short calibration summary are saved when you choose Apply.", systemImage: "internaldrive")
            Label("Try the suggested settings in a virtual pointer preview before applying. You can undo the last calibration.", systemImage: "slider.horizontal.3")
            if let profile = controller.settings.calibrationProfile {
                Text("Last calibration: \(profile.date.formatted(date: .abbreviated, time: .shortened))")
                    .foregroundStyle(.secondary)
                Button("Fine-tune saved controls without re-recording") { controller.beginCalibration(tuneSaved: true) }
                    .disabled(!controller.settings.developerModeEnabled)
            }
            displayInfo
            if !controller.settings.developerModeEnabled {
                Text("Enable Developer mode in Settings → Shortcuts & General to begin.").foregroundStyle(.orange)
            }
            Button("Begin calibration") { controller.beginCalibration() }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(!controller.settings.developerModeEnabled)
                .keyboardShortcut(.defaultAction)
            Spacer()
        }
    }

    private var phaseList: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(CalibrationPhase.allCases.enumerated()), id: \.element) { index, phase in
                Button {
                    calibration.select(phase)
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: calibration.completed.contains(phase) ? "checkmark.circle.fill" : "\(index+1).circle")
                            .foregroundStyle(calibration.completed.contains(phase) ? Color.green : .secondary)
                        Text(phase.title).font(.callout).multilineTextAlignment(.leading)
                    }
                    .padding(9).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(calibration.phase == phase && calibration.report == nil ? Color.accentColor.opacity(0.12) : .clear))
                }
                .buttonStyle(.plain).disabled(calibration.isRecording || calibration.countdown > 0)
            }
            Divider().padding(.vertical, 8)
            Text("A smaller tilt is enough. Move comfortably; do not stretch to match the old click threshold.")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 9)
            Spacer()
        }
        .padding(.horizontal, 8)
    }

    private var captureStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(calibration.phase.title).font(.title.bold())
            Text(calibration.phase.instruction).font(.title3).fixedSize(horizontal: false, vertical: true)
            CalibrationMotionAnimation(phase: calibration.phase,
                                       recordingTime: calibration.isRecording ? calibration.progress * calibration.phase.duration : nil,
                                       countdown: calibration.countdown)
            Text(calibration.status).foregroundStyle(calibration.live.fresh ? Color.secondary : .orange)
            if calibration.countdown > 0 {
                Text("\(calibration.countdown)").font(.system(size: 54, weight: .semibold, design: .rounded))
                    .frame(maxWidth: .infinity)
            }
            ProgressView(value: calibration.progress)
            HStack {
                Text(calibration.isRecording ? "Recording valid motion" : calibration.completed.contains(calibration.phase) ? "Sample captured" : "\(Int(calibration.phase.duration)) seconds")
                Spacer()
                Text(String(format: "%.0f / %.0f s", calibration.progress * calibration.phase.duration, calibration.phase.duration)).monospacedDigit()
            }
            .font(.caption).foregroundStyle(.secondary)
            liveSignals
            if let feedback = calibration.stepFeedback {
                VStack(alignment: .leading, spacing: 6) {
                    Label(feedback.title, systemImage: feedback.needsRepeat ? "arrow.clockwise" : "checkmark.circle")
                        .font(.headline)
                    Text(feedback.detail).font(.callout)
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(feedback.needsRepeat ? Color.orange.opacity(0.1) : Color.green.opacity(0.08)))
            }
            HStack {
                Button(calibration.completed.contains(calibration.phase) ? "Repeat sample" : "Record sample") { calibration.startRecording() }
                    .disabled(calibration.isRecording || calibration.countdown > 0)
                Spacer()
                Button(calibration.completed.count == CalibrationPhase.allCases.count ? "Review settings" : "Continue") { nextStep() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!calibration.completed.contains(calibration.phase) || calibration.isRecording || calibration.countdown > 0 || calibration.stepFeedback?.needsRepeat == true)
                    .keyboardShortcut(.defaultAction)
            }
            Text("Start each recording upright. A two-second countdown gives you time to settle. Missing sensor data pauses recording time.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var liveSignals: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle().fill(calibration.live.fresh ? Color.green : .orange).frame(width: 7, height: 7)
                Text(calibration.live.fresh ? "Live motion" : "Waiting for AirPods motion").font(.callout.weight(.medium))
                Spacer()
                Text(String(format: "Roll %.1f°", calibration.live.roll)).monospacedDigit()
            }
            Text(String(format: "Yaw %.1f°/s · Pitch %.1f°/s", calibration.live.yawRate, calibration.live.pitchRate))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            CalibrationTrace(values: calibration.history.map { [$0.yawRate, $0.pitchRate] }, colors: [.blue, .purple], minimumScale: 20)
                .frame(height: 66)
            if let a = calibration.live.acceleration {
                Text(String(format: "Acceleration · x %.3f · y %.3f · z %.3f g", a.x, a.y, a.z))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                CalibrationTrace(values: calibration.history.map { [$0.acceleration?.x ?? 0, $0.acceleration?.y ?? 0, $0.acceleration?.z ?? 0] },
                                 colors: [.red, .green, .blue], minimumScale: 0.1).frame(height: 66)
            } else {
                Text("Acceleration is unavailable; posture tuning will retain the current settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14).background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.07)))
    }

    private var sampleIssues: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("A little more data").font(.title.bold())
            Text(calibration.status).foregroundStyle(.secondary)
            ForEach(Array(calibration.issues.enumerated()), id: \.offset) { _, issue in
                VStack(alignment: .leading, spacing: 8) {
                    Text(issue.phase.title).font(.headline)
                    Text(issue.message)
                    Button("Repeat this step") { calibration.select(issue.phase) }
                }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.08)))
            }
            Button("Restart calibration") { controller.finishCalibration(); controller.beginCalibration() }
        }
    }

    private func review(_ report: CalibrationReport) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Try, rate, and refine · round \(calibration.roundNumber)").font(.title.bold())
            Text("Use slow turns for the nearby targets, fast turns for the outer targets, and small left/right tilts to click. This preview only moves the dot below.")
                .foregroundStyle(.secondary)
            displayInfo
            Picker("Preview scale", selection: Binding(get: { calibration.previewMode }, set: { calibration.setPreviewMode($0) })) {
                Text("Fine control · 1:1").tag(CalibrationPreviewMode.precision)
                Text("Whole-display travel").tag(CalibrationPreviewMode.travel)
            }.pickerStyle(.segmented)
            preview
            HStack {
                Text("Left clicks: \(calibration.previewLeftClicks)")
                Text("Right clicks: \(calibration.previewRightClicks)")
                Spacer()
                Button("Center preview") { calibration.recenterPreview() }
            }.font(.caption)
            if calibration.previewGate != .normal {
                Text(calibration.previewReason.message)
                    .font(.caption).foregroundStyle(.orange)
            }
            if !calibration.readyToApply {
                Text("Return upright and hold still briefly to apply safely.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            CalibrationFeedbackPanel().environmentObject(calibration)
            DisclosureGroup("Measured parameters and proposed settings") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 9) {
                GridRow { Text("Setting"); Text("Current"); Text("Suggested") }.font(.caption.bold()).foregroundStyle(.secondary)
                change("Resting dead zone", controller.settings.pointer.deadzone, report.pointer.deadzone, suffix: "°/s")
                change("Attitude noise", controller.settings.pointer.filter.measurementNoise, report.pointer.filter.measurementNoise, suffix: "°")
                change("Precision gain", controller.settings.pointer.precisionGain, report.pointer.precisionGain, suffix: "pt/°")
                change("Travel gain", controller.settings.pointer.travelGain, report.pointer.travelGain, suffix: "pt/°")
                change("Left tilt", controller.settings.gestures.angle(for: .tiltLeft), report.gestures.angle(for: .tiltLeft), suffix: "°")
                change("Right tilt", controller.settings.gestures.angle(for: .tiltRight), report.gestures.angle(for: .tiltRight), suffix: "°")
                change("Left hold", controller.settings.gestures.hold(for: .tiltLeft), report.gestures.hold(for: .tiltLeft), suffix: "s")
                change("Right hold", controller.settings.gestures.hold(for: .tiltRight), report.gestures.hold(for: .tiltRight), suffix: "s")
                change("Posture slowdown threshold", controller.settings.pointer.repositioning.cautionAcceleration, report.pointer.repositioning.cautionAcceleration, suffix: "g")
                change("Posture pause threshold", controller.settings.pointer.repositioning.freezeAcceleration, report.pointer.repositioning.freezeAcceleration, suffix: "g")
                change("Posture movement gain", controller.settings.pointer.repositioning.cautiousGain, report.pointer.repositioning.cautiousGain, suffix: "×")
                change("Recovery time", controller.settings.pointer.repositioning.settleTime, report.pointer.repositioning.settleTime, suffix: "s")
            }
            Text(String(format: "Measured slow %.1f°/s · fast %.1f°/s. Precision buffer up to %.1f°/s; full travel gain from %.1f°/s.",
                        report.profile.slowSpeed, report.profile.fastSpeed, report.profile.precisionMaximumSpeed, report.profile.travelMinimumSpeed))
                .font(.caption).foregroundStyle(.secondary)
            ForEach(report.profile.notes, id: \.self) { Text($0).font(.callout).foregroundStyle(.orange) }
            }
            DisclosureGroup("Fine-tune the preview") {
                VStack(spacing: 12) {
                    LabeledSlider(title: "Precision gain", value: pointerBinding(\.precisionGain), range: 4...60, format: { String(format: "%.1f", $0) })
                    LabeledSlider(title: "Travel gain", value: pointerBinding(\.travelGain), range: 4...120, format: { String(format: "%.1f", $0) })
                    LabeledSlider(title: "Left tilt", value: tiltBinding(.tiltLeft), range: report.profile.minimumTiltAngle...max(20, report.profile.minimumTiltAngle+1), step: 0.1, format: { String(format: "%.1f°", $0) })
                    LabeledSlider(title: "Right tilt", value: tiltBinding(.tiltRight), range: report.profile.minimumTiltAngle...max(20, report.profile.minimumTiltAngle+1), step: 0.1, format: { String(format: "%.1f°", $0) })
                }.padding(.top, 10)
            }
            HStack {
                Button("Repeat posture sample") { calibration.select(.repositioning) }
                Spacer()
                Button("Apply personal settings") {
                    controller.finishCalibration(apply: true)
                    dismissWindow(id: WindowID.calibration)
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(!calibration.readyToApply)
            }
            Text("Applies the Kalman curve at 1× sensitivity and standard acceleration. Click bindings stay as configured. Only derived settings and this summary are saved.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var preview: some View {
        let geometry = calibration.previewGeometry
        return ZStack {
            RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.08))
            Rectangle().stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                .frame(width: geometry.size.x, height: geometry.size.y)
                .position(x: 260, y: 110)
            ForEach(Array(geometry.targets.enumerated()), id: \.offset) { _, point in
                Circle().strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 2)
                    .frame(width: 26, height: 26).position(x: point.x, y: point.y)
            }
            Circle().fill(Color.accentColor).frame(width: 12, height: 12)
                .position(x: calibration.previewPosition.x, y: calibration.previewPosition.y)
        }
        .frame(width: 520, height: 220)
        .accessibilityLabel("Virtual head-controlled pointer preview")
    }

    private var displayInfo: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(calibration.display.name).font(.callout.weight(.medium))
                Text(String(format: "%.0f × %.0f points · %d × %d pixels", calibration.display.width, calibration.display.height,
                            calibration.display.pixelWidth, calibration.display.pixelHeight))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Use display under cursor") { controller.updateCalibrationDisplay() }
                .controlSize(.small)
        }
    }

    private func change(_ title: String, _ old: Double, _ new: Double, suffix: String) -> some View {
        let format = suffix == "g" ? "%.3f %@" : "%.2f %@"
        return GridRow {
            Text(title)
            Text(String(format: format, old, suffix)).foregroundStyle(.secondary)
            Text(String(format: format, new, suffix)).fontWeight(.medium)
        }.font(.callout).monospacedDigit()
    }

    private func pointerBinding(_ key: WritableKeyPath<PointerSettings, Double>) -> Binding<Double> {
        Binding(get: { calibration.report?.pointer[keyPath: key] ?? 0 },
                set: { value in calibration.editPreview { $0.pointer[keyPath: key] = value } })
    }

    private func tiltBinding(_ side: HeadGesture) -> Binding<Double> {
        Binding(get: { calibration.report?.gestures.angle(for: side) ?? 6 }, set: { value in
            calibration.editPreview { report in
                if side == .tiltLeft { report.gestures.leftTiltAngle = value }
                else { report.gestures.rightTiltAngle = value }
            }
        })
    }

    private func nextStep() {
        if calibration.completed.count == CalibrationPhase.allCases.count { controller.reviewCalibration(); return }
        if let next = CalibrationPhase.allCases.first(where: { !calibration.completed.contains($0) }) { calibration.select(next) }
    }
}

private struct CalibrationTrace: View {
    var values: [[Double]]
    var colors: [Color]
    var minimumScale: Double
    var body: some View {
        Canvas { context, size in
            let scale = max(minimumScale, values.flatMap { $0 }.map(abs).max() ?? 0)
            var center = Path(); center.move(to: CGPoint(x: 0, y: size.height/2)); center.addLine(to: CGPoint(x: size.width, y: size.height/2))
            context.stroke(center, with: .color(.secondary.opacity(0.2)), lineWidth: 1)
            for channel in colors.indices {
                var path = Path()
                for (index, sample) in values.enumerated() where sample.indices.contains(channel) {
                    let point = CGPoint(x: size.width * Double(index) / Double(max(1, values.count-1)),
                                        y: size.height/2 - sample[channel] / scale * size.height * 0.45)
                    if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                context.stroke(path, with: .color(colors[channel]), lineWidth: 1.5)
            }
        }
    }
}

import SwiftUI
import AirCursorCore

struct MenuContentView: View {
    @EnvironmentObject private var controller: AppController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if !controller.accessibilityTrusted {
                warning("AirCursor needs Accessibility permission to move the pointer.", button: "Grant") {
                    controller.requestAccessibility()
                }
            }

            if controller.needsAudioHandoff {
                warning("Your AirPods are connected but playing for another device. Choose them under Control Center › Sound so they send head tracking to this Mac.", button: "Sound…") {
                    AppController.openSoundSettings()
                }
            }

            deviceRow

            Divider()

            Toggle(isOn: Binding(get: { controller.trackingEnabled }, set: { controller.setTracking($0) })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Head tracking").font(.body.weight(.medium))
                    Text("\(HotKey.toggleTracking.display) to toggle anywhere").font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            Picker("Mode", selection: Binding(get: { controller.mode }, set: { controller.setMode($0) })) {
                Text("Pointer").tag(TrackingMode.pointer)
                Text("Scroll").tag(TrackingMode.scroll)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(!controller.trackingEnabled)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Speed")
                    Spacer()
                    Text(String(format: "%.1f×", controller.settings.pointer.sensitivity))
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: $controller.settings.pointer.sensitivity, in: 0.2...4)
            }

            Toggle("Hover click (rest the pointer to click)", isOn: $controller.settings.dwell.enabled)
            if controller.settings.developerModeEnabled {
                Button("Motion calibration…") { controller.showCalibration() }
            }

            if let last = controller.lastTriggerDescription {
                Text("Last: \(last)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }

            Divider()

            HStack {
                Button("Settings…") { openMainWindow() }
                Button("Guided tour") {
                    openWindow(id: WindowID.tour)
                    NSApp.activate()
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 310)
        .task { controller.refreshDevices() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "cursorarrow.motionlines")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text("AirCursor").font(.headline)
                Text(controller.statusText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Circle()
                .fill(controller.trackingEnabled && controller.motionStreaming ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 9, height: 9)
        }
    }

    @ViewBuilder private var deviceRow: some View {
        if let device = controller.connectedHeadphones {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(device.name)
                    Text(controller.motionStreaming ? "Head tracking live" : "Connected — waiting for motion")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: device.symbol)
            }
        } else if let device = controller.pairedHeadphones.first {
            HStack {
                Label(device.name, systemImage: device.symbol)
                Spacer()
                Button(controller.busyDeviceID == device.id ? "Connecting…" : "Connect") { controller.connect(device) }
                    .disabled(controller.busyDeviceID != nil)
            }
        } else {
            HStack {
                Label("No AirPods paired", systemImage: "airpodspro")
                Spacer()
                Button("Pair…") { openMainWindow() }
            }
        }
    }

    private func warning(_ text: String, button: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(button, action: action).controlSize(.small)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(.orange.opacity(0.12)))
    }

    private func openMainWindow() {
        openWindow(id: WindowID.main)
        NSApp.activate()
    }
}

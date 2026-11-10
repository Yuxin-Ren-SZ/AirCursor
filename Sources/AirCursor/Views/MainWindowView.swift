import SwiftUI
import AirCursorCore

enum Pane: String, CaseIterable, Identifiable {
    case setup, devices, pointer, gestures, shortcuts, developer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .setup: "Setup"
        case .devices: "AirPods"
        case .pointer: "Pointer"
        case .gestures: "Clicks & Gestures"
        case .shortcuts: "Shortcuts & General"
        case .developer: "Developer"
        }
    }

    var symbol: String {
        switch self {
        case .setup: "checklist"
        case .devices: "airpodspro"
        case .pointer: "cursorarrow.motionlines"
        case .gestures: "hand.tap"
        case .shortcuts: "keyboard"
        case .developer: "waveform.path"
        }
    }
}

struct MainWindowView: View {
    @EnvironmentObject private var controller: AppController
    @State private var pane: Pane? = nil

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases.filter { $0 != .developer || controller.settings.developerModeEnabled }, selection: $pane) { p in
                Label(p.title, systemImage: p.symbol).tag(p)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            Group {
                switch pane ?? .setup {
                case .setup: SetupView(pane: $pane)
                case .devices: DevicesView()
                case .pointer: PointerSettingsView()
                case .gestures: GestureSettingsView()
                case .shortcuts: GeneralView()
                case .developer: DeveloperSettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear {
            if pane == nil { pane = controller.settings.hasCompletedOnboarding ? .pointer : .setup }
            controller.windowVisibilityChanged()
        }
        .onDisappear { controller.windowVisibilityChanged() }
        .onChange(of: controller.settings.developerModeEnabled) { _, enabled in
            if !enabled, pane == .developer { pane = .shortcuts }
        }
        .alert("AirCursor", isPresented: Binding(get: { controller.lastError != nil }, set: { if !$0 { controller.clearError() } })) {
            Button("OK") { controller.clearError() }
        } message: {
            Text(controller.lastError ?? "")
        }
    }
}

// MARK: - Setup

struct SetupView: View {
    @EnvironmentObject private var controller: AppController
    @Environment(\.openWindow) private var openWindow
    @Binding var pane: Pane?

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Use your AirPods as a mouse").font(.title2.bold())
                    Text("Turn your head to move the pointer. Tilt left to click, or tilt right to right-click. Three quick steps to get going.")
                        .foregroundStyle(.secondary)
                    Button("Take the guided tour") {
                        openWindow(id: WindowID.tour)
                        NSApp.activate()
                    }
                    .padding(.top, 4)
                }
                .padding(.vertical, 4)
            }

            Section("1 · Connect your AirPods") {
                HStack {
                    if let d = controller.connectedHeadphones {
                        Label(d.name, systemImage: d.symbol)
                        if !d.likelySupportsMotion {
                            Text("(may not support head tracking)").font(.caption).foregroundStyle(.orange)
                        }
                    } else {
                        Text("AirPods Pro, AirPods Max, AirPods (3rd gen or later) or Beats Fit Pro.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    StatusBadge(ok: controller.connectedHeadphones != nil, okText: "Connected", badText: "Not connected")
                    Button("Pair or connect…") { pane = .devices }
                }
            }

            if controller.needsAudioHandoff {
                Section {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Your AirPods aren’t playing for this Mac").font(.headline)
                            Text("They’re connected, but another device (probably your iPhone) is using them. AirPods only send head tracking to the device they play audio for. Put them in your ears, then click the Control Center icon in the menu bar › Sound and choose your AirPods.")
                                .font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Button("Open Sound Settings") { AppController.openSoundSettings() }
                    }
                }
            }

            Section("2 · Allow pointer control") {
                HStack {
                    Text("macOS asks you to allow AirCursor under Privacy & Security › Accessibility. This is what lets it move the pointer and click.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    StatusBadge(ok: controller.accessibilityTrusted, okText: "Allowed", badText: "Needed")
                    if !controller.accessibilityTrusted {
                        Button("Open Settings") { controller.requestAccessibility() }
                    }
                }
            }

            Section("3 · Allow head tracking") {
                HStack {
                    Text("Lets AirCursor read your AirPods’ motion sensors. Nothing leaves your Mac.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    StatusBadge(ok: controller.motionAuthorization == .authorized || controller.motionStreaming,
                                okText: "Allowed",
                                badText: controller.motionAuthorization == .denied ? "Denied" : "Needed")
                    if controller.motionAuthorization != .authorized {
                        Button(controller.motionAuthorization == .denied ? "Open Settings" : "Allow") {
                            if controller.motionAuthorization == .denied {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
                                    NSWorkspace.shared.open(url)
                                }
                            } else {
                                controller.requestMotionAccess()
                            }
                        }
                    }
                }
                if controller.motionStreaming || controller.live.hasData {
                    HeadVisualizer(live: controller.live, tiltThreshold: min(controller.settings.gestures.angle(for: .tiltLeft), controller.settings.gestures.angle(for: .tiltRight)))
                        .padding(.vertical, 6)
                }
            }

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("How to use it").font(.headline)
                        Text("Turn your head → move · Press stem → click · Press twice → right‑click · Press three times → scroll mode · Tilt left / right → click / right-click · Shake → pause/resume · \(HotKey.toggleTracking.display) → pause/resume")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button(controller.trackingEnabled ? "Tracking is on" : "Start tracking") {
                        controller.completeOnboarding()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!controller.accessibilityTrusted || controller.trackingEnabled)
                }
            }

            DiagnosticsSection()
        }
        .formStyle(.grouped)
        .task {
            while !Task.isCancelled {
                controller.refreshDevices(allowPrompt: true)
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
}

// MARK: - Devices

struct DevicesView: View {
    @EnvironmentObject private var controller: AppController
    @EnvironmentObject private var pairing: PairingService

    var body: some View {
        Form {
            Section("Your headphones") {
                if controller.pairedHeadphones.isEmpty {
                    Text("No headphones paired with this Mac yet. Pair them below.")
                        .foregroundStyle(.secondary)
                }
                ForEach(controller.pairedHeadphones) { device in
                    HStack {
                        Image(systemName: device.symbol).frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name)
                            Text(subtitle(for: device)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if controller.busyDeviceID == device.id {
                            ProgressView().controlSize(.small)
                        } else if device.isConnected {
                            Button("Disconnect") { controller.disconnect(device) }
                        } else {
                            Button("Connect") { controller.connect(device) }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Pair new AirPods").font(.headline)
                    Text("Put both AirPods in the case and open the lid. Press and hold the button on the back of the case (or the noise‑control button on AirPods Max) until the light flashes white. Then search.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Tip: if your AirPods are already set up with your iPhone and you use the same Apple Account here, they’re already paired — just tap Connect above.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Button(pairing.isSearching ? "Stop" : "Search for headphones") {
                        pairing.isSearching ? pairing.stopSearch() : pairing.startSearch()
                    }
                    if pairing.isSearching { ProgressView().controlSize(.small) }
                    pairingStatus
                    Spacer()
                    Button("Bluetooth Settings…") { BluetoothService.openSystemBluetoothSettings() }
                }

                ForEach(pairing.discovered.filter { !$0.isPaired }) { device in
                    HStack {
                        Image(systemName: device.symbol).frame(width: 24)
                        Text(device.name)
                        Spacer()
                        Button("Pair") { pairing.pair(device.id) }
                            .disabled(isPairing)
                    }
                }
            }

            Section("Supported for head tracking") {
                Text("AirPods Pro (all generations), AirPods Max, AirPods (3rd generation and later), Beats Fit Pro. Other headphones can connect but don’t have the motion sensors AirCursor needs.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .task {
            while !Task.isCancelled {
                controller.refreshDevices(allowPrompt: true)
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .onDisappear { pairing.stopSearch() }
    }

    private var isPairing: Bool {
        if case .pairing = pairing.state { return true }
        return false
    }

    @ViewBuilder private var pairingStatus: some View {
        switch pairing.state {
        case .idle, .searching: EmptyView()
        case .pairing(let name): Text("Pairing with \(name)…").foregroundStyle(.secondary)
        case .paired(let name): Label("Paired \(name)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let message): Text(message).foregroundStyle(.orange).lineLimit(2)
        }
    }

    private func subtitle(for device: HeadphoneDevice) -> String {
        var parts = [device.isConnected ? "Connected" : "Not connected"]
        if !device.likelySupportsMotion { parts.append("no head tracking") }
        if device.isConnected, controller.motionStreaming { parts.append("motion live") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Pointer

struct PointerSettingsView: View {
    @EnvironmentObject private var controller: AppController

    var body: some View {
        Form {
            Section("Live head tracking") {
                HeadVisualizer(live: controller.live, tiltThreshold: min(controller.settings.gestures.angle(for: .tiltLeft), controller.settings.gestures.angle(for: .tiltRight)))
                    .padding(.vertical, 6)
                if controller.motionStreaming {
                    Text(controller.live.inputState)
                        .foregroundStyle(controller.live.inputState == "Ready" ? Color.secondary : .orange)
                    Text(String(format: "Yaw speed: raw %.1f → filtered %.1f°/s · Pitch: raw %.1f → filtered %.1f°/s",
                                controller.live.rawYawRate, controller.live.yawRate,
                                controller.live.rawPitchRate, controller.live.pitchRate))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    if let acceleration = controller.live.acceleration {
                        Text(String(format: "Head acceleration: %.3f g", acceleration))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Button("Compare recent motion") { controller.compareRecentMotion() }
                    if let comparison = controller.motionComparison {
                        Text(comparison).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                if !controller.motionStreaming {
                    Text(controller.trackingEnabled ? "Waiting for motion data… make sure your AirPods are in your ears and connected to this Mac." : "Turn on head tracking to see live data.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Movement") {
                Picker("Motion filter", selection: $controller.settings.pointer.filterMode) {
                    Text("Kalman").tag(MotionFilterMode.kalman)
                    Text("Original").tag(MotionFilterMode.legacy)
                }
                LabeledSlider(title: "Speed", value: $controller.settings.pointer.sensitivity, range: 0.2...4,
                              format: { String(format: "%.1f×", $0) })
                LabeledSlider(title: "Acceleration", value: $controller.settings.pointer.acceleration, range: 0...2,
                              format: { String(format: "%.1f", $0) },
                              help: "Higher = quick head turns travel much farther; slow turns stay precise.")
                LabeledSlider(title: "Steadiness (dead zone)", value: $controller.settings.pointer.deadzone, range: 0...20, step: 0.1,
                              format: { String(format: "%.1f°/s", $0) },
                              help: "Ignores tiny movements so the pointer holds still while you read.")
                LabeledSlider(title: "Smoothing", value: $controller.settings.pointer.smoothing, range: 0...0.9,
                              format: { String(format: "%.0f%%", $0 * 100) },
                              help: "More smoothing looks silkier but adds a little lag.")
                Toggle("Invert left / right", isOn: $controller.settings.pointer.invertHorizontal)
                Toggle("Invert up / down", isOn: $controller.settings.pointer.invertVertical)
            }

            if controller.settings.pointer.filterMode == .kalman {
                Section("Precision and travel") {
                    LabeledSlider(title: "Precision gain", value: $controller.settings.pointer.precisionGain, range: 4...60,
                                  format: { String(format: "%.0f points/°", $0) })
                    LabeledSlider(title: "Travel gain", value: $controller.settings.pointer.travelGain, range: 4...120,
                                  format: { String(format: "%.0f points/°", $0) })
                    LabeledSlider(title: "Speed transition", value: $controller.settings.pointer.transitionSpeed, range: 0.5...80,
                                  format: { String(format: "%.0f°/s", $0) })
                    LabeledSlider(title: "Precision speed range", value: $controller.settings.pointer.precisionSpeed, range: 0.5...60,
                                  format: { String(format: "%.1f°/s", $0) })
                    Toggle("Adapt steadiness to resting noise", isOn: $controller.settings.pointer.adaptiveDeadzone)
                    Toggle("Learn sensor noise while still", isOn: $controller.settings.pointer.filter.learnStationaryNoise)
                    LabeledSlider(title: "Sensor noise", value: $controller.settings.pointer.filter.measurementNoise, range: 0.02...0.5,
                                  format: { String(format: "%.2f°", $0) },
                                  help: "Starting attitude noise estimate. Higher smooths more; resting calibration can update it.")
                    LabeledSlider(title: "Follow quick changes", value: $controller.settings.pointer.filter.processAcceleration, range: 20...400,
                                  format: { String(format: "%.0f°/s²", $0) },
                                  help: "Higher follows starts and stops faster, but also passes more sensor noise.")
                    Text("Slow turns make small adjustments; faster turns travel farther. Added smoothing increases lag. The Original filter retains the previous movement curve.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Posture adjustments") {
                Toggle("Reduce input while repositioning", isOn: $controller.settings.pointer.repositioning.enabled)
                LabeledSlider(title: "Slow down above", value: $controller.settings.pointer.repositioning.cautionAcceleration, range: 0.02...0.15,
                              format: { String(format: "%.3f g", $0) })
                LabeledSlider(title: "Pause above", value: $controller.settings.pointer.repositioning.freezeAcceleration, range: 0.1...0.6,
                              format: { String(format: "%.2f g", $0) })
                LabeledSlider(title: "Quiet recovery", value: $controller.settings.pointer.repositioning.settleTime, range: 0.06...0.3,
                              format: { String(format: "%.0f ms", $0 * 1000) })
                Text("Possible posture adjustments slow movement and pause head clicks. Strong, sustained movement pauses the pointer until you settle. Acceleration is a hint, not a measurement of your position.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Scroll mode") {
                LabeledSlider(title: "Scroll speed", value: $controller.settings.pointer.scrollSpeed, range: 0.2...4,
                              format: { String(format: "%.1f×", $0) })
                Toggle("Invert scroll direction", isOn: $controller.settings.pointer.invertScroll)
                Text("In scroll mode, look down/up to scroll and turn left/right to scroll sideways. Toggle it with a triple stem press or \(HotKey.scrollMode.display).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Gestures

struct GestureSettingsView: View {
    @EnvironmentObject private var controller: AppController

    var body: some View {
        Form {
            if let last = controller.lastTriggerDescription {
                Section {
                    Label("Last detected: \(last)", systemImage: "waveform.path.ecg")
                }
            }

            Section {
                Toggle("Use AirPods stem presses", isOn: $controller.settings.stemControlsEnabled)
                ForEach([Trigger.stemSingle, .stemDouble, .stemTriple]) { trigger in
                    ActionPicker(trigger: trigger, action: binding(trigger))
                        .disabled(!controller.settings.stemControlsEnabled)
                }
                Toggle("Keep AirPods routed to AirCursor (inaudible audio)", isOn: $controller.settings.keepAudioRouteActive)
                    .disabled(!controller.settings.stemControlsEnabled)
            } header: {
                Text("Stem presses")
            } footer: {
                Text("While tracking is on, AirCursor takes over play/pause/next/previous from your AirPods and keyboard media keys. Pause tracking to give them back to your music app.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Head gestures") {
                ForEach([Trigger.nod, .shake, .tiltLeft, .tiltRight]) { trigger in
                    ActionPicker(trigger: trigger, action: binding(trigger))
                }
                LabeledSlider(title: "Nod size needed", value: $controller.settings.gestures.nodAmplitude, range: 3...20, step: 0.5,
                              format: { String(format: "%.1f°", $0) },
                              help: controller.lastNodDepth.map { String(format: "Your last nod was %.1f°. Lower = easier nods, but more accidental clicks.", $0) }
                                ?? "Lower = easier nods, but more accidental clicks. Enable a nod action above to use nod clicks.")
                LabeledSlider(title: "Shake size needed", value: $controller.settings.gestures.shakeAmplitude, range: 4...25, step: 0.5,
                              format: { String(format: "%.1f°", $0) })
                Toggle("Separate left and right tilt settings", isOn: separateTilts)
                if separateTilts.wrappedValue {
                    LabeledSlider(title: "Left tilt angle", value: tiltAngle(.tiltLeft), range: 3...40, step: 0.1,
                                  format: { String(format: "%.1f°", $0) })
                    LabeledSlider(title: "Right tilt angle", value: tiltAngle(.tiltRight), range: 3...40, step: 0.1,
                                  format: { String(format: "%.1f°", $0) })
                    LabeledSlider(title: "Left hold", value: tiltHold(.tiltLeft), range: 0.1...1,
                                  format: { String(format: "%.2fs", $0) })
                    LabeledSlider(title: "Right hold", value: tiltHold(.tiltRight), range: 0.1...1,
                                  format: { String(format: "%.2fs", $0) })
                } else {
                    LabeledSlider(title: "Tilt angle", value: $controller.settings.gestures.tiltAngle, range: 3...40, step: 0.1,
                                  format: { String(format: "%.1f°", $0) })
                    LabeledSlider(title: "Tilt hold", value: $controller.settings.gestures.tiltHold, range: 0.1...1.0,
                                  format: { String(format: "%.2fs", $0) })
                }
                Toggle("Swap tilt left / right", isOn: $controller.settings.gestures.swapTiltDirection)
                Text("Tilt left for a left click and right for a right click. Hold until the ring fills, then return to neutral. The pointer stays on your target throughout the tilt.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Hover click") {
                Toggle("Click when the pointer rests", isOn: $controller.settings.dwell.enabled)
                Toggle("Only on buttons, links and other clickable things", isOn: $controller.settings.dwell.smart)
                    .disabled(!controller.settings.dwell.enabled)
                ActionPicker(trigger: .dwell, action: binding(.dwell))
                    .disabled(!controller.settings.dwell.enabled)
                LabeledSlider(title: "Rest time", value: $controller.settings.dwell.duration, range: 0.3...3,
                              format: { String(format: "%.1fs", $0) })
                    .disabled(!controller.settings.dwell.enabled)
                LabeledSlider(title: "Rest radius", value: $controller.settings.dwell.radius, range: 4...40,
                              format: { String(format: "%.0f pt", $0) })
                    .disabled(!controller.settings.dwell.enabled)
                Text("A ring fills around the pointer; it clicks when the ring closes. Move again to arm the next click. Paused while you type.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var separateTilts: Binding<Bool> {
        Binding(get: { controller.settings.gestures.leftTiltAngle != nil || controller.settings.gestures.rightTiltAngle != nil }, set: { enabled in
            var gestures = controller.settings.gestures
            gestures.leftTiltAngle = enabled ? gestures.tiltAngle : nil
            gestures.rightTiltAngle = enabled ? gestures.tiltAngle : nil
            gestures.leftTiltHold = enabled ? gestures.tiltHold : nil
            gestures.rightTiltHold = enabled ? gestures.tiltHold : nil
            controller.settings.gestures = gestures
        })
    }

    private func tiltAngle(_ side: HeadGesture) -> Binding<Double> {
        Binding(get: { controller.settings.gestures.angle(for: side) }, set: { value in
            if side == .tiltLeft { controller.settings.gestures.leftTiltAngle = value }
            else { controller.settings.gestures.rightTiltAngle = value }
        })
    }

    private func tiltHold(_ side: HeadGesture) -> Binding<Double> {
        Binding(get: { controller.settings.gestures.hold(for: side) }, set: { value in
            if side == .tiltLeft { controller.settings.gestures.leftTiltHold = value }
            else { controller.settings.gestures.rightTiltHold = value }
        })
    }

    private func binding(_ trigger: Trigger) -> Binding<PointerAction> {
        Binding(
            get: { controller.settings.actions[trigger] },
            set: { controller.settings.actions[trigger] = $0 }
        )
    }
}

// MARK: - General

struct GeneralView: View {
    @EnvironmentObject private var controller: AppController

    var body: some View {
        Form {
            Section("Keyboard shortcuts (work in any app)") {
                ForEach(HotKey.all, id: \.id) { key in
                    HStack {
                        Text(key.description)
                        Spacer()
                        Text(key.display)
                            .font(.body.monospaced())
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary))
                    }
                }
            }

            Section("General") {
                Toggle("Launch at login", isOn: Binding(get: { controller.launchAtLogin }, set: { controller.setLaunchAtLogin($0) }))
                Toggle("Switch Mac sound to AirPods when tracking starts", isOn: $controller.settings.routeAudioToHeadphones)
                Text("AirPods only send head-tracking data to the device they’re playing audio for. Leave this on unless you route audio yourself.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Show on‑screen status messages", isOn: $controller.settings.showHUD)
                Toggle("Show a ripple where clicks land", isOn: $controller.settings.showClickPulse)
                Toggle("Developer mode", isOn: $controller.settings.developerModeEnabled)
                if controller.settings.developerModeEnabled {
                    Button("Calibrate personal motion controls…") { controller.showCalibration() }
                    Text("Developer adds live signal inspection, guided calibration and a safe virtual pointer preview.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Tips") {
                VStack(alignment: .leading, spacing: 6) {
                    tip("Pointer drifting while you’re still? Raise Steadiness.")
                    tip("Hit the screen edge? Pause (shake or \(HotKey.toggleTracking.display)), turn back to center, resume — like lifting a mouse.")
                    tip("Removing an AirPod can send “pause”, which AirCursor treats as a press. Pause tracking first, or turn off Automatic Ear Detection.")
                    tip("Mission Control and Spaces actions use the standard macOS shortcuts (⌃↑, ⌃↓, ⌃←, ⌃→).")
                }
                .font(.callout)
            }

            DiagnosticsSection()

            Section {
                HStack {
                    Button("Reset all settings", role: .destructive) { controller.resetSettings() }
                    Spacer()
                    Text("AirCursor \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                        .foregroundStyle(.secondary)
                }
            }

            Section("About") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Made by Muhammad Afham")
                        .font(.callout.weight(.medium))
                    Text("Free and open source. If AirCursor helps you, a star on GitHub helps others find it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 14) {
                        Link("GitHub", destination: URL(string: "https://github.com/m-afham/AirCursor")!)
                        Link("Share feedback", destination: URL(string: "https://github.com/m-afham/AirCursor/discussions")!)
                        Link("mafham.dev", destination: URL(string: "https://mafham.dev")!)
                    }
                    .font(.callout)
                    .padding(.top, 2)
                }
                .padding(.vertical, 2)
            }
        }
        .formStyle(.grouped)
    }

    private func tip(_ text: String) -> some View {
        Label(text, systemImage: "lightbulb").labelStyle(.titleAndIcon)
    }
}

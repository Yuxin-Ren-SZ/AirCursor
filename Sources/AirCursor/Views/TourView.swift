import AppKit
import SwiftUI
import AirCursorCore

// MARK: - Steps

/// Deliberately short: set up, feel it once, see the cheat sheet. Everything else
/// is discoverable in Settings.
enum TourStep: Int, CaseIterable, Identifiable {
    case welcome, permissions, connect, tryIt, done

    var id: Int { rawValue }

    var eyebrow: String {
        switch self {
        case .welcome: "Welcome"
        case .permissions: "Step 1 of 3"
        case .connect: "Step 2 of 3"
        case .tryIt: "Step 3 of 3"
        case .done: "All set"
        }
    }
}

// MARK: - Tour

/// First-run guided tour. Progress lives in AppController (persisted), so leaving for
/// System Settings and coming back resumes on the same step.
struct TourView: View {
    @EnvironmentObject private var controller: AppController
    @EnvironmentObject private var pairing: PairingService
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var triedIt = false

    private var step: TourStep { TourStep(rawValue: controller.tourStep) ?? .welcome }

    var body: some View {
        HStack(spacing: 0) {
            TourStage(step: step)
                .frame(width: 340)

            VStack(alignment: .leading, spacing: 0) {
                ProgressDots(current: step)
                    .padding(.bottom, 22)

                Group {
                    content
                }
                .id(step)
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .opacity
                ))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                footer
            }
            .padding(.horizontal, 36)
            .padding(.top, 34)
            .padding(.bottom, 26)
        }
        .frame(width: 960, height: 640)
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
        .onAppear {
            NSApp.activate()
            controller.windowVisibilityChanged()
        }
        .onDisappear { controller.windowVisibilityChanged() }
        .onReceive(NotificationCenter.default.publisher(for: .tourShowStep)) { note in
            if let raw = note.object as? Int { controller.tourStep = raw }
        }
        // Both permissions granted → move on by itself.
        .onChange(of: permissionsGranted) { _, granted in
            guard granted, step == .permissions else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                if step == .permissions { go(1) }
            }
        }
    }

    private var permissionsGranted: Bool {
        controller.accessibilityTrusted && controller.motionAuthorization == .authorized
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome: WelcomeStep()
        case .permissions: PermissionsStep()
        case .connect: ConnectStep()
        case .tryIt: TryItStep(done: {
            guard !triedIt else { return }
            NSSound(named: "Glass")?.play()
            withAnimation(.spring(duration: 0.35)) { triedIt = true }
        })
        case .done: DoneStep()
        }
    }

    private var footer: some View {
        HStack {
            if step != .welcome {
                Button("Back") { go(-1) }
                    .buttonStyle(.borderless)
            }
            if step != .done {
                Button("Skip tour") { finish() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 12)
            }
            Spacer()
            if step == .tryIt, !triedIt {
                Button("Skip") { go(1) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 8)
            }
            Button(primaryTitle) {
                step == .done ? finish() : go(1)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(!canContinue)
        }
        .padding(.top, 16)
    }

    private var primaryTitle: String {
        switch step {
        case .welcome: "Get started"
        case .done: "Start using AirCursor"
        default: "Continue"
        }
    }

    private var canContinue: Bool {
        switch step {
        case .welcome, .done: true
        case .permissions: permissionsGranted
        case .connect: controller.motionStreaming
        case .tryIt: triedIt
        }
    }

    private func go(_ delta: Int) {
        guard let next = TourStep(rawValue: step.rawValue + delta) else { return }
        withAnimation(.smooth(duration: 0.35)) { controller.tourStep = next.rawValue }
    }

    private func finish() {
        controller.completeOnboarding()
        dismissWindow(id: WindowID.tour)
    }
}

// MARK: - Stage (left column)

private struct TourStage: View {
    @EnvironmentObject private var controller: AppController
    @EnvironmentObject private var pairing: PairingService
    let step: TourStep

    var body: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(
                colors: [Color(red: 0.07, green: 0.07, blue: 0.12), Color(red: 0.16, green: 0.13, blue: 0.30)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
            RadialGradient(colors: [Color.accentColor.opacity(0.28), .clear], center: .center, startRadius: 10, endRadius: 260)
                .ignoresSafeArea()

            Earbuds3DView(state: stageState, live: controller.live)
                .padding(.bottom, 60)

            VStack(spacing: 10) {
                statusPill
                Text("AirCursor")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .padding(.bottom, 26)
        }
        .environment(\.colorScheme, .dark)
    }

    private var stageState: EarbudsState {
        if controller.motionStreaming { return .live }
        if pairing.isSearching || step == .connect { return .searching }
        return .idle
    }

    private var statusPill: some View {
        let (text, color): (String, Color) = {
            if controller.motionStreaming {
                if !controller.trackingEnabled { return ("Paused", .orange) }
                return (controller.mode == .scroll ? "Scroll mode" : "Following your head", .green)
            }
            if pairing.isSearching { return ("Searching…", .blue) }
            if controller.connectedHeadphones != nil { return ("Connected · waiting for motion", .yellow) }
            return ("AirPods not connected", .gray)
        }()
        return HStack(spacing: 7) {
            Circle().fill(color).frame(width: 7, height: 7)
                .shadow(color: color, radius: 4)
            Text(text).font(.system(size: 12, weight: .medium))
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.white.opacity(0.08), in: Capsule())
        .foregroundStyle(.white.opacity(0.9))
        .animation(.default, value: text)
    }
}

private struct ProgressDots: View {
    let current: TourStep

    var body: some View {
        HStack(spacing: 10) {
            Text(current.eyebrow.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 5) {
                ForEach(TourStep.allCases) { s in
                    Capsule()
                        .fill(s.rawValue <= current.rawValue ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(width: s == current ? 18 : 6, height: 6)
                }
            }
            .animation(.smooth, value: current)
        }
    }
}

// MARK: - Shared pieces

private struct StepHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 28, weight: .bold))
            Text(subtitle)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 20)
    }
}

private struct PlayArea<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 18).fill(Color.secondary.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.secondary.opacity(0.15)))
            .clipShape(RoundedRectangle(cornerRadius: 18))
    }
}

private struct SuccessBadge: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.green)
            .transition(.scale.combined(with: .opacity))
    }
}

/// Warns when a practice step can't work because tracking is off.
private struct TrackingHint: View {
    @EnvironmentObject private var controller: AppController

    var body: some View {
        if !controller.trackingEnabled {
            hint("Head tracking is paused. Shake your head or press \(HotKey.toggleTracking.display) to resume.")
        } else if !controller.motionStreaming {
            hint("Waiting for your AirPods’ motion — make sure they’re in your ears.")
        }
    }

    private func hint(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.orange)
            .padding(.bottom, 10)
    }
}

extension AppController {
    /// Human phrase for how to trigger an action with the current bindings, e.g.
    /// "press the stem once or nod". Nil if nothing is bound to it.
    func howTo(_ action: PointerAction) -> String? {
        let triggers = settings.actions.triggers(for: action).filter { t in
            t != .dwell || settings.dwell.enabled
        }
        guard !triggers.isEmpty else { return nil }
        return triggers.map(\.phrase).joined(separator: " or ")
    }
}

extension Trigger {
    var phrase: String {
        switch self {
        case .stemSingle: "press the stem once"
        case .stemDouble: "press the stem twice"
        case .stemTriple: "press the stem three times"
        case .nod: "nod"
        case .shake: "shake your head"
        case .tiltLeft: "tilt your head left"
        case .tiltRight: "tilt your head right"
        case .dwell: "hold still"
        }
    }
}

// MARK: - Welcome

private struct WelcomeStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Your AirPods\nare now a mouse.")
                .font(.system(size: 40, weight: .bold))
                .padding(.bottom, 14)
            Text("Turn your head to point. Nod to click. Your hands stay free for everything else.")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 32)

            VStack(alignment: .leading, spacing: 20) {
                feature("cursorarrow.motionlines", "Point with your head", "Smooth and precise, across all your displays.")
                feature("hand.tap", "Click without touching", "A small nod clicks. So does a stem press.")
                feature("lock", "Private by design", "Motion data never leaves your Mac.")
            }

            Spacer()
            Text("Takes about a minute: two permissions, put your AirPods in, try it once.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
    }

    private func feature(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(detail).font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Permissions

private struct PermissionsStep: View {
    @EnvironmentObject private var controller: AppController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeader(
                title: "Two quick permissions",
                subtitle: "macOS asks you to approve these once. This page updates on its own when you come back."
            )
            VStack(spacing: 12) {
                row(
                    symbol: "cursorarrow.click.2",
                    title: "Accessibility",
                    detail: "Lets AirCursor move the pointer and click for you. Find AirCursor in the list and switch it on.",
                    granted: controller.accessibilityTrusted,
                    action: controller.requestAccessibility
                )
                row(
                    symbol: "gyroscope",
                    title: "Motion",
                    detail: "Reads head movement from your AirPods. It’s processed on this Mac and never stored or sent anywhere.",
                    granted: controller.motionAuthorization == .authorized,
                    denied: controller.motionAuthorization == .denied,
                    action: controller.requestMotionAccess
                )
            }
            Spacer()
        }
    }

    private func row(symbol: String, title: String, detail: String, granted: Bool, denied: Bool = false, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 20))
                .foregroundStyle(Color.accentColor)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(detail).font(.system(size: 13)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if denied {
                    Text("Turned off — enable AirCursor in System Settings › Privacy & Security › Motion & Fitness.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 16)
            if granted {
                SuccessBadge(text: "Allowed")
            } else {
                Button(denied ? "Open Settings" : "Allow…") {
                    if denied, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
                        NSWorkspace.shared.open(url)
                    } else {
                        action()
                    }
                }
                .controlSize(.large)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.secondary.opacity(0.07)))
        .animation(.spring(duration: 0.3), value: granted)
    }
}

// MARK: - Connect

private struct ConnectStep: View {
    @EnvironmentObject private var controller: AppController
    @EnvironmentObject private var pairing: PairingService
    @State private var showPairing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeader(
                title: "Put your AirPods in",
                subtitle: "When the earbuds on the left start turning with your head, you’re connected — and your pointer follows too."
            )

            if controller.motionStreaming {
                VStack(alignment: .leading, spacing: 8) {
                    SuccessBadge(text: "Head tracking is live")
                    Text("Try it: look around slowly and watch the earbuds — and your pointer — follow.")
                        .foregroundStyle(.secondary)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.green.opacity(0.08)))
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    if controller.needsAudioHandoff {
                        callout(
                            "Your AirPods are playing for another device",
                            "AirPods only send head tracking to the device they play for. Choose them in Control Center › Sound.",
                            button: "Open Sound Settings", action: AppController.openSoundSettings
                        )
                    }
                    ForEach(controller.pairedHeadphones) { device in
                        HStack {
                            Image(systemName: device.symbol).frame(width: 26)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(device.name).font(.system(size: 14, weight: .medium))
                                Text(device.isConnected ? "Connected" : "Not connected")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if controller.busyDeviceID == device.id {
                                ProgressView().controlSize(.small)
                            } else if !device.isConnected {
                                Button("Connect") { controller.connect(device) }
                            }
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.07)))
                    }
                    if controller.pairedHeadphones.isEmpty {
                        Text("No AirPods paired with this Mac yet.").foregroundStyle(.secondary)
                    }
                    DisclosureGroup("Pair new AirPods", isExpanded: $showPairing) {
                        pairingPanel.padding(.top, 8)
                    }
                    .padding(.top, 4)
                }
            }
            Spacer()
            Text("Works with AirPods Pro, AirPods Max, AirPods (3rd gen or later) and Beats Fit Pro.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .task {
            while !Task.isCancelled {
                controller.refreshDevices(allowPrompt: true)
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .onDisappear { pairing.stopSearch() }
    }

    private var pairingPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Open the case near your Mac, then hold the button on the back until the light flashes white.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(pairing.isSearching ? "Stop searching" : "Search") {
                    pairing.isSearching ? pairing.stopSearch() : pairing.startSearch()
                }
                if pairing.isSearching { ProgressView().controlSize(.small) }
                Spacer()
                Button("Bluetooth Settings…") { BluetoothService.openSystemBluetoothSettings() }
                    .buttonStyle(.borderless)
            }
            ForEach(pairing.discovered.filter { !$0.isPaired }) { device in
                HStack {
                    Image(systemName: device.symbol)
                    Text(device.name)
                    Spacer()
                    Button("Pair") { pairing.pair(device.id) }
                }
            }
            switch pairing.state {
            case .pairing(let name): Text("Pairing with \(name)…").font(.callout).foregroundStyle(.secondary)
            case .paired(let name): SuccessBadge(text: "Paired \(name)")
            case .failed(let message): Text(message).font(.callout).foregroundStyle(.orange)
            default: EmptyView()
            }
        }
    }

    private func callout(_ title: String, _ detail: String, button: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "airpodspro").font(.title2).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(button, action: action)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.1)))
    }
}

// MARK: - Try it

/// One short, real task: point at a button that hops around, click it three times —
/// by nodding or pressing the stem. Quietly learns the size of the user's nod.
private struct TryItStep: View {
    @EnvironmentObject private var controller: AppController
    let done: () -> Void

    @State private var hits = 0
    @State private var hovering = false
    @State private var usedNod = false
    @State private var usedStem = false

    private let spots: [CGPoint] = [CGPoint(x: 0.5, y: 0.45), CGPoint(x: 0.2, y: 0.22), CGPoint(x: 0.8, y: 0.72)]
    private let goal = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeader(title: "Point, then click — hands‑free", subtitle: subtitle)
            TrackingHint()
            PlayArea {
                GeometryReader { geo in
                    let finished = hits >= goal
                    let spot = spots[min(hits, spots.count - 1)]
                    Text(finished ? "Done!" : "Click me")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 150, height: 58)
                        .background(RoundedRectangle(cornerRadius: 16).fill(finished ? Color.green : Color.accentColor))
                        .scaleEffect(hovering && !finished ? 1.08 : 1)
                        .shadow(color: Color.accentColor.opacity(hovering ? 0.55 : 0), radius: 14)
                        .overlay(PointerTarget(
                            onHover: { h in withAnimation(.spring(duration: 0.2)) { hovering = h } },
                            onClick: { button, _ in
                                guard button == .left, hits < goal else { return }
                                withAnimation(.spring(duration: 0.4)) { hits += 1 }
                                if hits >= goal { done() }
                            }
                        ))
                        .position(x: geo.size.width * spot.x, y: geo.size.height * spot.y)
                }
            }
            HStack(spacing: 10) {
                chip("Nod", symbol: "arrow.down.and.line.horizontal.and.arrow.up", used: usedNod)
                chip("Stem press", symbol: "hand.tap", used: usedStem)
                Spacer()
                if hits >= goal {
                    SuccessBadge(text: "You’ve got it")
                } else {
                    Text("\(hits) of \(goal)").foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .padding(.top, 12)
            HStack {
                Toggle("Also click when I hold still (dwell)", isOn: $controller.settings.dwell.enabled)
                Spacer()
                Text("Speed").foregroundStyle(.secondary)
                Slider(value: $controller.settings.pointer.sensitivity, in: 0.2...4).frame(width: 150)
            }
            .font(.callout)
            .padding(.top, 10)
        }
        .onAppear { controller.beginNodCalibration() }
        .onDisappear { controller.endNodCalibration() }
        .onChange(of: controller.lastTriggerEvent) { _, event in
            guard let event else { return }
            if event.trigger == .nod { withAnimation { usedNod = true } }
            if event.trigger.isStem { withAnimation { usedStem = true } }
        }
    }

    private var subtitle: String {
        let nodClicks = controller.settings.actions[.nod].isClick
        let stem = controller.settings.actions[.stemSingle].isClick
        switch (nodClicks, stem) {
        case (true, true): return "Turn your head to put the pointer on the button, then give a small nod — or press the stem."
        case (true, false): return "Turn your head to put the pointer on the button, then give a small nod."
        default: return "Turn your head to put the pointer on the button, then \(controller.howTo(.leftClick) ?? "click")."
        }
    }

    private func chip(_ title: String, symbol: String, used: Bool) -> some View {
        Label(title, systemImage: used ? "checkmark.circle.fill" : symbol)
            .font(.callout.weight(.medium))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(used ? Color.green.opacity(0.18) : Color.secondary.opacity(0.12)))
            .foregroundStyle(used ? Color.green : Color.secondary)
    }
}

// MARK: - Done

private struct DoneStep: View {
    @EnvironmentObject private var controller: AppController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeader(
                title: "You’re ready.",
                subtitle: "AirCursor lives in your menu bar. Here’s everything you can do — remap any of it in Settings, and replay this tour from the menu bar."
            )
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(bindings, id: \.0) { trigger, action in
                    HStack(spacing: 12) {
                        Image(systemName: action.symbol)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 26)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(action.displayName).font(.system(size: 14, weight: .semibold))
                            Text(trigger.displayName).font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.07)))
                }
            }
            HStack(spacing: 18) {
                ForEach(HotKey.all, id: \.id) { key in
                    HStack(spacing: 6) {
                        Text(key.display)
                            .font(.system(size: 12, weight: .medium).monospaced())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.15)))
                        Text(key.description).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 18)
            Spacer()
        }
    }

    private var bindings: [(Trigger, PointerAction)] {
        Trigger.allCases.compactMap { t in
            let a = controller.settings.actions[t]
            if a == .none || (t == .dwell && !controller.settings.dwell.enabled) { return nil }
            return (t, a)
        }
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

import AppKit
import SwiftUI
import AirCursorCore

// MARK: - Steps

enum TourStep: Int, CaseIterable, Identifiable {
    case welcome, permissions, connect, move, click, rightClick, nod, scroll, pause, feel, done

    var id: Int { rawValue }

    var isPractice: Bool { rawValue >= TourStep.move.rawValue && self != .done }

    var eyebrow: String {
        switch self {
        case .welcome: "Welcome"
        case .permissions: "Setup · 1 of 2"
        case .connect: "Setup · 2 of 2"
        case .move, .click, .rightClick, .nod, .scroll, .pause, .feel:
            "Practice · \(rawValue - TourStep.move.rawValue + 1) of 7"
        case .done: "All set"
        }
    }
}

// MARK: - Tour

/// First-run guided tour: set up, then *experience* every interaction live.
struct TourView: View {
    @EnvironmentObject private var controller: AppController
    @EnvironmentObject private var pairing: PairingService
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var step: TourStep = .welcome
    @State private var completed: Set<TourStep> = []

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
            controller.refreshDevices()
        }
        .onReceive(NotificationCenter.default.publisher(for: .tourShowStep)) { note in
            if let raw = note.object as? Int, let s = TourStep(rawValue: raw) { step = s }
        }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome: WelcomeStep()
        case .permissions: PermissionsStep()
        case .connect: ConnectStep()
        case .move: MoveStep(done: done(.move))
        case .click: ClickStep(done: done(.click))
        case .rightClick: RightClickStep(done: done(.rightClick))
        case .nod: NodStep(done: done(.nod))
        case .scroll: ScrollStep(done: done(.scroll))
        case .pause: PauseStep(done: done(.pause))
        case .feel: FeelStep()
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
            if step.isPractice, !canContinue {
                Button("Skip this one") { go(1) }
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
        case .welcome, .feel, .done: true
        case .permissions: controller.accessibilityTrusted && controller.motionAuthorization == .authorized
        case .connect: controller.motionStreaming
        default: completed.contains(step)
        }
    }

    private func done(_ s: TourStep) -> () -> Void {
        {
            guard !completed.contains(s) else { return }
            NSSound(named: "Glass")?.play()
            withAnimation(.spring(duration: 0.35)) { _ = completed.insert(s) }
        }
    }

    private func go(_ delta: Int) {
        guard let next = TourStep(rawValue: step.rawValue + delta) else { return }
        withAnimation(.smooth(duration: 0.35)) { step = next }
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
            Text("Turn your head to point. Press the stem to click. Keep your hands free for everything else.")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 32)

            VStack(alignment: .leading, spacing: 20) {
                feature("cursorarrow.motionlines", "Point with your head", "Smooth, precise, works across all your displays.")
                feature("hand.tap", "Click with your AirPods", "Press the stem, nod, or just hold still.")
                feature("sparkles", "Gestures for everything", "Scroll, drag, pause, switch Spaces — your call.")
                feature("lock", "Private by design", "Motion data never leaves your Mac. No accounts, no network.")
            }

            Spacer()
            Text("The next couple of minutes walk you through setup and let you try every move.")
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

// MARK: - Practice: move

private struct MoveStep: View {
    @EnvironmentObject private var controller: AppController
    let done: () -> Void
    @State private var hit: Set<Int> = []

    private let spots: [CGPoint] = [
        CGPoint(x: 0.12, y: 0.18), CGPoint(x: 0.86, y: 0.16), CGPoint(x: 0.5, y: 0.5),
        CGPoint(x: 0.16, y: 0.84), CGPoint(x: 0.84, y: 0.82),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeader(
                title: "Point with your head",
                subtitle: "Turn your head to touch each dot. Slow turns are precise; quick turns travel far. Hit an edge? Pause, re‑center your head, resume — like lifting a mouse."
            )
            TrackingHint()
            PlayArea {
                GeometryReader { geo in
                    ForEach(spots.indices, id: \.self) { i in
                        let on = hit.contains(i)
                        ZStack {
                            Circle()
                                .fill(on ? Color.green : Color.accentColor.opacity(0.15))
                            Circle()
                                .strokeBorder(on ? Color.green : Color.accentColor, lineWidth: 2)
                            if on {
                                Image(systemName: "checkmark").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                            }
                        }
                        .frame(width: 46, height: 46)
                        .scaleEffect(on ? 1.15 : 1)
                        .overlay(PointerTarget(onHover: { inside in if inside { touch(i) } }))
                        .position(x: geo.size.width * spots[i].x, y: geo.size.height * spots[i].y)
                    }
                }
            }
            HStack {
                if hit.count == spots.count {
                    SuccessBadge(text: "All five — nicely done")
                } else {
                    Text("\(hit.count) of \(spots.count)").foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                Text("Speed").foregroundStyle(.secondary)
                Slider(value: $controller.settings.pointer.sensitivity, in: 0.2...4).frame(width: 160)
            }
            .padding(.top, 12)
        }
    }

    private func touch(_ i: Int) {
        guard !hit.contains(i) else { return }
        withAnimation(.spring(duration: 0.3)) { _ = hit.insert(i) }
        if hit.count == spots.count { done() }
    }
}

// MARK: - Practice: click

private struct ClickStep: View {
    @EnvironmentObject private var controller: AppController
    let done: () -> Void
    @State private var clicks = 0
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeader(
                title: "Click with your AirPods",
                subtitle: "Point at the button, then \(controller.howTo(.leftClick) ?? "click"). Click it twice to finish."
            )
            TrackingHint()
            PlayArea {
                VStack(spacing: 18) {
                    Text(clicks >= 2 ? "🎉" : "Click me")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 200, height: 76)
                        .background(RoundedRectangle(cornerRadius: 20).fill(clicks >= 2 ? Color.green : Color.accentColor))
                        .scaleEffect(hovering ? 1.06 : 1)
                        .shadow(color: Color.accentColor.opacity(hovering ? 0.5 : 0), radius: 16)
                        .overlay(PointerTarget(
                            onHover: { h in withAnimation(.spring(duration: 0.2)) { hovering = h } },
                            onClick: { button, _ in
                                guard button == .left else { return }
                                withAnimation(.spring(duration: 0.25)) { clicks += 1 }
                                if clicks >= 2 { done() }
                            }
                        ))
                    Text(clicks == 0 ? "The click lands exactly where the pointer is." : "\(clicks) click\(clicks == 1 ? "" : "s")")
                        .foregroundStyle(.secondary)
                }
            }
            if clicks >= 2 { SuccessBadge(text: "You’ve got it").padding(.top, 12) }
        }
    }
}

// MARK: - Practice: right click

private struct RightClickStep: View {
    @EnvironmentObject private var controller: AppController
    let done: () -> Void
    @State private var success = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let how = controller.howTo(.rightClick) {
                StepHeader(title: "Right‑click", subtitle: "Point at the card and \(how) to open its menu.")
                TrackingHint()
                PlayArea {
                    VStack(spacing: 14) {
                        Image(systemName: success ? "checkmark.seal.fill" : "doc.richtext")
                            .font(.system(size: 40))
                            .foregroundStyle(success ? Color.green : Color.accentColor)
                        Text(success ? "Context menu opened" : "Right‑click me")
                            .font(.system(size: 17, weight: .semibold))
                    }
                    .frame(width: 220, height: 160)
                    .background(RoundedRectangle(cornerRadius: 18).fill(.background))
                    .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                    .overlay(PointerTarget(onClick: { button, _ in
                        guard button == .right else { return }
                        withAnimation(.spring(duration: 0.3)) { success = true }
                        done()
                    }))
                }
                if success { SuccessBadge(text: "Right‑click works").padding(.top, 12) }
            } else {
                StepHeader(title: "Right‑click", subtitle: "Right‑click isn’t assigned to any gesture right now. You can assign it in Settings › Clicks & Gestures.")
                Spacer()
            }
        }
        .onAppear { if controller.howTo(.rightClick) == nil { done() } }
    }
}

// MARK: - Practice: nod

private struct NodStep: View {
    @EnvironmentObject private var controller: AppController
    let done: () -> Void
    @State private var success = false
    @State private var hovering = false
    @State private var misses = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if controller.settings.actions[.nod].isClick {
                StepHeader(
                    title: "Nod to click",
                    subtitle: "Point at the target and give a quick, firm nod — like a confident “yes”. The click lands where you pointed before the nod."
                )
                TrackingHint()
                PlayArea {
                    ZStack {
                        ForEach(0..<3) { ring in
                            Circle()
                                .strokeBorder((success ? Color.green : Color.accentColor).opacity(0.25 + Double(ring) * 0.25), lineWidth: 3)
                                .frame(width: CGFloat(150 - ring * 45), height: CGFloat(150 - ring * 45))
                        }
                        Image(systemName: success ? "checkmark" : "arrow.down.and.line.horizontal.and.arrow.up")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(success ? Color.green : Color.accentColor)
                    }
                    .scaleEffect(hovering ? 1.06 : 1)
                    .overlay(PointerTarget(onHover: { h in withAnimation(.spring(duration: 0.2)) { hovering = h } }))
                }
                HStack {
                    if success {
                        SuccessBadge(text: "Perfect nod")
                    } else if misses > 0 {
                        Text("Nod detected — point at the target first.").foregroundStyle(.secondary)
                    } else {
                        Text("Too sensitive or not sensitive enough? Adjust it in Settings › Clicks & Gestures.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.top, 12)
            } else {
                StepHeader(title: "Nod to click", subtitle: "Nodding isn’t set to click right now. You can change that in Settings › Clicks & Gestures.")
                Spacer()
            }
        }
        .onChange(of: controller.lastTriggerEvent) { _, event in
            guard let event, event.trigger == .nod, !success else { return }
            if hovering {
                withAnimation(.spring(duration: 0.3)) { success = true }
                done()
            } else {
                misses += 1
            }
        }
        .onAppear { if !controller.settings.actions[.nod].isClick { done() } }
    }
}

// MARK: - Practice: scroll

private struct ScrollStep: View {
    @EnvironmentObject private var controller: AppController
    let done: () -> Void
    @State private var entered = false
    @State private var reachedEnd = false

    private let lines = [
        "Scroll mode turns head movement into scrolling.",
        "Look down to move down the page.",
        "Look up to go back up.",
        "Turn left or right to scroll sideways.",
        "The farther and faster you look, the faster it scrolls.",
        "Hold your head still to stop.",
        "Tip: you can change scroll speed in Settings › Pointer.",
        "Tip: it works in any app — Safari, Mail, Notes, Finder.",
        "Keep going…",
        "Almost there…",
        "A little more…",
        "You made it to the end 🎉",
    ]

    var body: some View {
        let toggle = controller.howTo(.toggleScrollMode) ?? "press \(HotKey.scrollMode.display)"
        VStack(alignment: .leading, spacing: 0) {
            StepHeader(title: "Scroll hands‑free", subtitle: "Point at the list, then follow the three steps.")
            TrackingHint()
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 14) {
                    check(entered, "1. \(toggle.capitalizedFirst) to enter scroll mode")
                    check(reachedEnd, "2. Look down to reach the end")
                    check(entered && reachedEnd && controller.mode == .pointer, "3. \(toggle.capitalizedFirst) again to go back")
                    Spacer()
                    Text("Mode: \(controller.mode.title)")
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(controller.mode == .scroll ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12)))
                }
                .frame(width: 230, alignment: .leading)

                PlayArea {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            ForEach(lines.indices, id: \.self) { i in
                                Text(lines[i])
                                    .font(.system(size: 17, weight: i == lines.count - 1 ? .bold : .regular))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(22)
                    }
                    .onScrollGeometryChange(for: Bool.self) { geo in
                        geo.contentOffset.y + geo.containerSize.height >= geo.contentSize.height - 24
                    } action: { _, atEnd in
                        if atEnd, entered, !reachedEnd { withAnimation { reachedEnd = true } }
                    }
                }
            }
        }
        .onChange(of: controller.mode) { _, mode in
            if mode == .scroll { withAnimation { entered = true } }
            if mode == .pointer, entered, reachedEnd { done() }
        }
    }

    private func check(_ on: Bool, _ text: String) -> some View {
        Label {
            Text(text).font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(on ? Color.green : Color.secondary)
        }
    }
}

// MARK: - Practice: pause

private struct PauseStep: View {
    @EnvironmentObject private var controller: AppController
    let done: () -> Void
    @State private var paused = false
    @State private var resumed = false

    var body: some View {
        let how = controller.howTo(.toggleTracking) ?? "press \(HotKey.toggleTracking.display)"
        VStack(alignment: .leading, spacing: 0) {
            StepHeader(
                title: "Pause anytime",
                subtitle: "Pausing hands the pointer back to your trackpad and the stem back to your music. Do it before taking your AirPods out."
            )
            PlayArea {
                VStack(spacing: 22) {
                    Image(systemName: controller.trackingEnabled ? "cursorarrow.motionlines" : "pause.circle.fill")
                        .font(.system(size: 54))
                        .foregroundStyle(controller.trackingEnabled ? Color.accentColor : Color.orange)
                        .contentTransition(.symbolEffect(.replace))
                    VStack(alignment: .leading, spacing: 12) {
                        stepRow(paused, "\(how.capitalizedFirst) to pause")
                        stepRow(resumed, "\(how.capitalizedFirst) again to resume")
                    }
                    Text("Keyboard: \(HotKey.toggleTracking.display) works in any app.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            if resumed { SuccessBadge(text: "Paused and back — perfect").padding(.top, 12) }
        }
        .onChange(of: controller.trackingEnabled) { _, on in
            if !on { withAnimation { paused = true } }
            if on, paused, !resumed {
                withAnimation { resumed = true }
                done()
            }
        }
    }

    private func stepRow(_ on: Bool, _ text: String) -> some View {
        Label {
            Text(text).font(.system(size: 15))
        } icon: {
            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(on ? Color.green : Color.secondary)
        }
    }
}

// MARK: - Practice: feel

private struct FeelStep: View {
    @EnvironmentObject private var controller: AppController
    @State private var trail: [(point: CGPoint, time: Date)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeader(
                title: "Make it feel right",
                subtitle: "Draw a circle, then a figure eight. Tune it until the line feels like it’s coming from you."
            )
            HStack(alignment: .top, spacing: 18) {
                PlayArea {
                    TimelineView(.animation) { context in
                        Canvas { ctx, _ in
                            let now = context.date
                            let points = trail.filter { now.timeIntervalSince($0.time) < 1.6 }
                            guard points.count > 1 else { return }
                            for i in 1..<points.count {
                                let age = now.timeIntervalSince(points[i].time) / 1.6
                                var path = Path()
                                path.move(to: points[i - 1].point)
                                path.addLine(to: points[i].point)
                                ctx.stroke(path, with: .color(Color.accentColor.opacity(1 - age)),
                                           style: StrokeStyle(lineWidth: 5 * (1 - age) + 1, lineCap: .round))
                            }
                        }
                    }
                    .overlay(PointerTarget(onMove: { p in
                        trail.append((p, Date()))
                        if trail.count > 240 { trail.removeFirst(trail.count - 240) }
                    }))
                    .overlay(alignment: .topLeading) {
                        Text("Draw here").font(.caption).foregroundStyle(.tertiary).padding(12)
                    }
                }
                VStack(alignment: .leading, spacing: 16) {
                    LabeledSlider(title: "Speed", value: $controller.settings.pointer.sensitivity, range: 0.2...4,
                                  format: { String(format: "%.1f×", $0) })
                    LabeledSlider(title: "Smoothing", value: $controller.settings.pointer.smoothing, range: 0...0.9,
                                  format: { String(format: "%.0f%%", $0 * 100) })
                    LabeledSlider(title: "Steadiness", value: $controller.settings.pointer.deadzone, range: 0...20,
                                  format: { String(format: "%.0f°/s", $0) },
                                  help: "Raise if the pointer creeps while you hold still.")
                    Toggle("Dwell click (hold still to click)", isOn: $controller.settings.dwell.enabled)
                }
                .frame(width: 240)
            }
        }
    }
}

// MARK: - Done

private struct DoneStep: View {
    @EnvironmentObject private var controller: AppController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeader(
                title: "You’re ready.",
                subtitle: "AirCursor lives in your menu bar. Everything below can be remapped in Settings."
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

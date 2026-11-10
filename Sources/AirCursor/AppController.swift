import AppKit
import Carbon.HIToolbox
import CoreBluetooth
import CoreMotion
import ServiceManagement
import SwiftUI
import AirCursorCore

enum TrackingMode: String {
    case pointer, scroll

    var title: String { self == .pointer ? "Pointer" : "Scroll" }
}

/// Live sensor readout for the UI (published at ~10 Hz, not per frame).
struct LiveReadout: Equatable {
    var hasData = false
    var yaw = 0.0, pitch = 0.0, roll = 0.0          // degrees
    var yawRate = 0.0, pitchRate = 0.0              // deg/s
    var inputState = "Ready"
    var acceleration: Double?
    var accelerationVector: Vec3?
    var rawYawRate = 0.0, rawPitchRate = 0.0
    var relativeRoll = 0.0                          // degrees from neutral
}

/// Owns the whole pipeline: AirPods motion → pointer/gestures → synthetic input.
@MainActor
final class AppController: ObservableObject {
    static let shared = AppController()

    // MARK: Published state

    @Published var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            SettingsStore.save(settings)
            applySettings()
        }
    }

    @Published private(set) var trackingEnabled = false
    @Published private(set) var mode: TrackingMode = .pointer
    @Published private(set) var isDragging = false
    @Published private(set) var motionStreaming = false
    @Published private(set) var accessibilityTrusted = EventSynthesizer.isTrusted
    @Published private(set) var motionAuthorization: CMAuthorizationStatus = HeadphoneMotionService.authorizationStatus
    @Published private(set) var live = LiveReadout()
    @Published private(set) var motionComparison: String?
    @Published private(set) var lastTriggerDescription: String?
    /// Every handled trigger, for the guided tour to react to.
    @Published private(set) var lastTriggerEvent: TriggerEvent?
    /// Depth of the most recent nod, in degrees (shown next to the nod setting).
    @Published private(set) var lastNodDepth: Double?
    @Published private(set) var pairedHeadphones: [HeadphoneDevice] = []
    @Published private(set) var busyDeviceID: String?
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published private(set) var lastError: String?
    @Published private(set) var diagnostics = DiagnosticsSnapshot()
    /// Headphones are Bluetooth-connected but not playing for this Mac (e.g. still on the
    /// iPhone), so they won't stream head motion here until chosen as the Mac's output.
    @Published private(set) var needsAudioHandoff = false

    let pairing = PairingService()
    let calibration = MotionCalibrationController()
    private var resumeAfterCalibration = false
    private var preCalibrationGestures: GestureDetector?

    // MARK: Services

    private let motion = HeadphoneMotionService()
    private let synth = EventSynthesizer()
    private let stem = StemControlService()
    private let keepAlive = AudioKeepAlive()
    private let bluetooth = BluetoothService()
    private let hud = HUDController()
    private let cursorOverlay = CursorOverlayController()
    private let hotKeys = HotKeyManager()
    private let screens = ScreenGeometry()

    // MARK: Pipeline state

    private var control: HeadControlPipeline
    private var motionUpdate: HeadControlUpdate?
    private var tiltAnchor: CGPoint?
    private var motionTrace: [MotionSample] = []
    private var smoother = PointerSmoother()
    private var dwell: DwellDetector
    private var history = CursorHistory(capacity: 360)
    private var frameTimer: Timer?
    private var housekeepingTimer: Timer?
    private var lastFrame: TimeInterval?
    private var cursor: CGPoint?
    private var lastPosted: [CGPoint] = []
    private var lastFrameDelta: Double = 0
    private var scrollRemainder = Vec2.zero
    private var lastSampleHostTime: TimeInterval = 0
    private var lastLivePublish: TimeInterval = 0
    private var motionRequested = false
    private var didAutoStart = false
    /// Non-nil while the tour is learning how big the user's nods are.
    private var nodCalibration: [Double]?
    private var probedAnchor = -1
    private var anchorClickable: Bool?
    private static let calibrationNodAmplitude = 4.0
    private var sampleCount = 0
    private var housekeepingTicks = 0
    private var motionStartedAt: TimeInterval?
    private var lastMotionRestart: TimeInterval = 0
    private var lastMotionError: String?
    private var started = false

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private init() {
        let stored = SettingsStore.load()
        let loaded = stored.migrated()
        if loaded != stored { SettingsStore.save(loaded) }
        settings = loaded
        control = HeadControlPipeline(pointer: loaded.pointer, gestures: loaded.gestures)
        dwell = DwellDetector(settings: loaded.dwell)
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        Diagnostics.log.notice("AirCursor starting (accessibility: \(self.accessibilityTrusted, privacy: .public), motion: \(self.motionAuthorization.label, privacy: .public), onboarded: \(self.settings.hasCompletedOnboarding, privacy: .public))")

        motion.onSample = { [weak self] s in self?.handle(s) }
        motion.onConnectionChange = { [weak self] connected in self?.headphonesChanged(connected: connected) }
        motion.onError = { [weak self] error in self?.motionFailed(error) }
        stem.onPress = { [weak self] trigger in self?.handle(trigger: trigger, gestureStart: nil) }
        pairing.onPaired = { [weak self] _ in
            self?.refreshDevices()
            self?.toast("AirPods paired", symbol: "checkmark.circle.fill")
        }

        registerHotKeys()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screens.refresh() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.releaseButtons() }
        }

        housekeepingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.housekeeping() }
        }

        if motionAuthorization == .authorized { motionRequested = true }

        // Tracking is on by default: whenever Accessibility allows it.
        if accessibilityTrusted {
            didAutoStart = true
            setTracking(true, announce: false)
        } else {
            updateServices()
        }

        // Setup incomplete (first launch, reinstall, permissions reset) → guided tour,
        // resuming at the permissions step for people who've seen it before.
        if needsSetup {
            if settings.hasCompletedOnboarding, tourStep < 1 { tourStep = 1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self, self.needsSetup else { return }
                let visible = NSApp.windows.contains { $0.isVisible && $0.title == "Welcome to AirCursor" }
                if !visible { self.showTour() }
            }
        }
    }

    /// True until AirCursor can actually work: tour finished and both permissions granted.
    var needsSetup: Bool {
        !settings.hasCompletedOnboarding || !accessibilityTrusted || motionAuthorization != .authorized
    }

    /// Tracking is on by default, so the moment Accessibility is granted the pointer
    /// starts following your head (and asking for Motion, if not yet allowed).
    private func autoStartIfReady() {
        guard !calibration.isActive, !didAutoStart, !trackingEnabled, accessibilityTrusted else { return }
        didAutoStart = true
        Diagnostics.log.notice("Accessibility granted; tracking on")
        setTracking(true, announce: false)
    }

    func shutdown() {
        calibration.finish()
        releaseButtons()
        stem.stop()
        keepAlive.stop()
        motion.stop()
        hotKeys.unregisterAll()
    }

    // MARK: User intents

    func toggleTracking() { setTracking(!trackingEnabled) }

    func setTracking(_ on: Bool, announce: Bool = true) {
        if on, calibration.isActive {
            toast("Finish or cancel calibration to resume head control", symbol: "slider.horizontal.3")
            return
        }
        if on {
            accessibilityTrusted = EventSynthesizer.isTrusted
            guard accessibilityTrusted else {
                Diagnostics.log.notice("Tracking blocked: Accessibility not granted")
                EventSynthesizer.requestTrust()
                toast("Allow Accessibility to control the pointer", symbol: "lock.shield")
                return
            }
            motionRequested = true
        }
        guard on != trackingEnabled else { updateServices(); return }

        trackingEnabled = on
        Diagnostics.log.notice("Tracking \(on ? "on" : "off", privacy: .public)")
        if on { routeAudioToHeadphonesIfNeeded() }
        // Preserve a just-fired shake's cooldown and settling latch across pause/resume.
        control.reset(preservingGestures: true)
        motionUpdate = nil
        tiltAnchor = nil
        smoother.reset()
        cursor = nil
        lastFrame = nil
        history.removeAll()
        lastPosted.removeAll()
        lastFrameDelta = 0
        scrollRemainder = .zero
        if !on {
            releaseButtons()
            dwell.reset()
            cursorOverlay.hide()
        }
        updateServices()
        if announce {
            toast(on ? "Head tracking on" : "Head tracking paused",
                  symbol: on ? "cursorarrow.motionlines" : "pause.circle.fill")
        }
    }

    func setMode(_ newMode: TrackingMode) {
        guard newMode != mode else { return }
        if isDragging { endDrag(at: cursor ?? synth.currentLocation()) }
        mode = newMode
        control.cancelGestures()
        motionUpdate = nil
        tiltAnchor = nil
        scrollRemainder = .zero
        smoother.reset()
        dwell.reset()
        cursorOverlay.hide()
        toast(newMode == .scroll ? "Scroll mode — move your head to scroll" : "Pointer mode",
              symbol: newMode == .scroll ? "arrow.up.and.down.circle.fill" : "cursorarrow")
    }

    /// Asks for motion permission (system prompt) without starting cursor control.
    func requestMotionAccess() {
        motionRequested = true
        motion.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refreshPermissions() }
    }

    func requestAccessibility() {
        EventSynthesizer.requestTrust()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Current guided-tour step, persisted so the tour resumes after a relaunch or a
    /// trip to System Settings.
    @Published var tourStep: Int = UserDefaults.standard.integer(forKey: "AirCursor.tourStep") {
        didSet { UserDefaults.standard.set(tourStep, forKey: "AirCursor.tourStep") }
    }

    func completeOnboarding() {
        tourStep = 0
        settings.hasCompletedOnboarding = true
        if accessibilityTrusted { setTracking(true, announce: false) }
        toast("You’re all set — AirCursor lives in the menu bar", symbol: "cursorarrow.motionlines")
    }

    func resetSettings() {
        let onboarded = settings.hasCompletedOnboarding
        var fresh = AppSettings()
        fresh.hasCompletedOnboarding = onboarded
        settings = fresh
        control.gestures.reset()
        toast("Settings reset", symbol: "arrow.counterclockwise")
    }

    func recenterNow() { perform(.recenter, at: cursor ?? synth.currentLocation()) }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            lastError = nil
        } catch {
            lastError = "Launch at login: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: Devices

    /// Reads paired headphones. Touching IOBluetooth triggers the Bluetooth permission
    /// prompt (and blocks until answered), so background refreshes only run once access
    /// is granted; screens that are *about* connecting pass `allowPrompt: true`.
    func refreshDevices(allowPrompt: Bool = false) {
        let mayPrompt = allowPrompt && DebugSnapshot.directory == nil
        guard mayPrompt || CBManager.authorization == .allowedAlways else { return }
        let devices = bluetooth.pairedHeadphones()
        if devices != pairedHeadphones {
            pairedHeadphones = devices
            let summary = devices.map { "\($0.name)=\($0.isConnected ? "connected" : "not connected")" }.joined(separator: ", ")
            Diagnostics.log.notice("Headphones: \(summary.isEmpty ? "none" : summary, privacy: .public)")
        }
    }

    var connectedHeadphones: HeadphoneDevice? { pairedHeadphones.first(where: \.isConnected) }

    func connect(_ device: HeadphoneDevice) {
        busyDeviceID = device.id
        Task {
            let ok = await bluetooth.connect(address: device.id)
            busyDeviceID = nil
            refreshDevices()
            if ok {
                toast("Connected to \(device.name)", symbol: device.symbol)
                if trackingEnabled || motionRequested { motion.start() }
            } else {
                lastError = "Couldn't connect to \(device.name). Take them out of the case and try again."
            }
        }
    }

    func disconnect(_ device: HeadphoneDevice) {
        busyDeviceID = device.id
        Task {
            _ = await bluetooth.disconnect(address: device.id)
            busyDeviceID = nil
            refreshDevices()
        }
    }

    func clearError() { lastError = nil }

    // MARK: Personal motion calibration

    func showCalibration() {
        guard settings.developerModeEnabled else { return }
        windowOpener?(WindowID.calibration)
        NSApp.activate()
    }

    func beginCalibration() {
        guard settings.developerModeEnabled, !calibration.isActive else { return }
        resumeAfterCalibration = trackingEnabled
        preCalibrationGestures = control.gestures
        calibration.begin()
        setTracking(false, announce: false)
        releaseButtons()
        synth.inputEnabled = false
        cursorOverlay.hide()
        motionRequested = true
        routeAudioToHeadphonesIfNeeded()
        updateServices()
    }

    func reviewCalibration() {
        calibration.analyze(using: settings, screenWidth: screens.display(containing: synth.currentLocation()).width)
    }

    func finishCalibration(apply: Bool = false) {
        guard calibration.isActive else { return }
        let report = calibration.report
        if apply, report == nil || !calibration.readyToApply { return }
        let neutralRoll = calibration.recordedNeutralRoll
        let sourceChanged = calibration.sourceChanged
        calibration.finish() // discard raw samples before saving derived settings
        if apply, let report {
            var updated = settings
            updated.calibrationBackup = CalibrationBackup(pointer: settings.pointer, gestures: settings.gestures,
                                                          profile: settings.calibrationProfile)
            updated.pointer = report.pointer
            updated.gestures = report.gestures
            updated.calibrationProfile = report.profile
            settings = updated
        }
        control.reset(); motionUpdate = nil; smoother.reset(); tiltAnchor = nil
        if sourceChanged {
            resumeAfterCalibration = false
        } else if let neutralRoll {
            control.gestures.resetTiltBaseline(to: neutralRoll)
            control.cancelGestures()
        } else if let previous = preCalibrationGestures {
            control.gestures = previous
            control.cancelGestures()
        }
        preCalibrationGestures = nil
        synth.inputEnabled = true
        setTracking(resumeAfterCalibration, announce: false)
        updateServices()
        if !sourceChanged { autoStartIfReady() }
    }

    func undoCalibration() {
        guard !calibration.isActive, let backup = settings.calibrationBackup else { return }
        var updated = settings
        updated.pointer = backup.pointer; updated.gestures = backup.gestures
        updated.calibrationProfile = backup.profile; updated.calibrationBackup = nil
        settings = updated
    }

    // MARK: Nod calibration

    /// While active, smaller nods are accepted and their depths recorded.
    func beginNodCalibration() {
        guard nodCalibration == nil else { return }
        nodCalibration = []
        control.gestures.settings.nodAmplitude = min(settings.gestures.nodAmplitude, Self.calibrationNodAmplitude)
        Diagnostics.log.notice("Nod calibration started")
    }

    /// Sets the nod threshold to just over half the user's typical nod, so their
    /// natural nod always registers but small pointer corrections don't.
    func endNodCalibration() {
        guard let depths = nodCalibration else { return }
        nodCalibration = nil
        guard !depths.isEmpty else {
            control.gestures.settings = settings.gestures
            return
        }
        let median = depths.sorted()[depths.count / 2]
        let tuned = (min(max(median * 0.7, 5), 14) * 2).rounded() / 2
        Diagnostics.log.notice("Nod calibration: median \(String(format: "%.1f", median), privacy: .public)° → threshold \(String(format: "%.1f", tuned), privacy: .public)°")
        settings.gestures.nodAmplitude = tuned
        control.gestures.settings = settings.gestures
    }

    // MARK: Services orchestration

    private var motionNeeded: Bool {
        guard motionAuthorization != .denied, motionAuthorization != .restricted else { return false }
        if calibration.isActive { return true }
        if trackingEnabled { return true }
        return motionRequested && settings.hasCompletedOnboarding && settings.actions.headGestureCanToggleTracking
    }

    private var stemNeeded: Bool {
        if calibration.isActive { return false }
        guard settings.stemControlsEnabled else { return false }
        return trackingEnabled || (settings.hasCompletedOnboarding && settings.actions.stemCanToggleTracking)
    }

    private func updateServices() {
        let wantMotion = motionNeeded || (motionRequested && !settings.hasCompletedOnboarding)
        if wantMotion {
            if !motion.isActive { motionStartedAt = Self.now }
            motion.start()
        } else {
            motion.stop()
            motionStreaming = false
            motionStartedAt = nil
        }

        if stemNeeded {
            stem.start()
        } else {
            stem.stop()
        }

        // Keep the AirPods the active audio route while we need their sensors or presses.
        if settings.keepAudioRouteActive, wantMotion || stemNeeded {
            keepAlive.start()
        } else {
            keepAlive.stop()
        }
        publishDiagnostics()

        if trackingEnabled {
            if frameTimer == nil {
                let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.frame() }
                }
                RunLoop.main.add(timer, forMode: .common)
                frameTimer = timer
            }
        } else {
            frameTimer?.invalidate()
            frameTimer = nil
        }
    }

    private func applySettings() {
        if !settings.developerModeEnabled, calibration.isActive { finishCalibration() }
        control.pointerSettings = settings.pointer
        control.suspend()
        smoother.reset()
        motionUpdate = nil
        tiltAnchor = nil
        control.gestures.settings = settings.gestures
        if nodCalibration != nil {
            control.gestures.settings.nodAmplitude = min(settings.gestures.nodAmplitude, Self.calibrationNodAmplitude)
        }
        dwell.settings = settings.dwell
        if !settings.dwell.enabled { cursorOverlay.hide() }
        updateServices()
    }

    private func housekeeping() {
        refreshPermissions()
        let now = Self.now
        housekeepingTicks += 1
        if housekeepingTicks % 3 == 1 { refreshDevices() }
        if motionStreaming, now - lastSampleHostTime > 1.5 {
            motionStreaming = false
            smoother.reset()
            if isDragging { endDrag(at: cursor ?? synth.currentLocation()) }
            Diagnostics.log.notice("Motion samples stopped arriving")
        }
        // Watchdog: motion is on but silent → restart it (recovers after route changes).
        if motion.isActive, !motionStreaming, let started = motionStartedAt,
           now - started > 3, now - lastMotionRestart > 5,
           motionAuthorization != .denied, motionAuthorization != .restricted {
            lastMotionRestart = now
            Diagnostics.log.notice("No motion data yet; restarting headphone motion")
            routeAudioToHeadphonesIfNeeded()
            motion.restart()
        }
        publishDiagnostics()
    }

    /// AirPods only stream head motion to the device they're playing for, so make them
    /// the Mac's sound output (same as choosing them in Control Center › Sound).
    @discardableResult
    func routeAudioToHeadphonesIfNeeded(force: Bool = false) -> Bool {
        guard force || settings.routeAudioToHeadphones else { return false }
        let preferred = connectedHeadphones?.name ?? pairedHeadphones.first?.name
        guard let target = AudioRouter.headphoneOutput(preferredName: preferred) else {
            Diagnostics.log.notice("No AirPods audio output found to route to")
            return false
        }
        if AudioRouter.defaultOutput()?.id == target.id { return true }
        let ok = AudioRouter.setDefaultOutput(target)
        Diagnostics.log.notice("Route Mac sound to \(target.name, privacy: .public): \(ok ? "ok" : "failed", privacy: .public)")
        if ok {
            toast("Mac sound → \(target.name)", symbol: "airpodspro")
            // The stream reconnects on the new route; give it a moment, then restart if silent.
            motionStartedAt = Self.now
        }
        publishDiagnostics()
        return ok
    }

    static func openSoundSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private func publishDiagnostics() {
        let headphoneAudio = AudioRouter.headphoneOutput(preferredName: connectedHeadphones?.name)
        let handoff = connectedHeadphones != nil && headphoneAudio == nil && !motionStreaming
        if handoff != needsAudioHandoff {
            needsAudioHandoff = handoff
            if handoff { Diagnostics.log.notice("Headphones connected but not available as Mac audio output") }
            else if headphoneAudio != nil, trackingEnabled { routeAudioToHeadphonesIfNeeded() }
        }
        let snapshot = DiagnosticsSnapshot(
            accessibility: accessibilityTrusted,
            motionAuthorization: motionAuthorization.label,
            motionAvailable: motion.isAvailable,
            motionActive: motion.isActive,
            samplesReceived: sampleCount,
            secondsSinceLastSample: lastSampleHostTime > 0 ? Self.now - lastSampleHostTime : nil,
            audioKeepAlive: keepAlive.isRunning,
            stemControls: stem.isActive,
            trackingEnabled: trackingEnabled,
            connectedHeadphones: connectedHeadphones?.name,
            soundOutput: AudioRouter.defaultOutput().map { ($0.name, $0.isBluetooth) },
            headphonesAsAudio: headphoneAudio != nil,
            lastMotionError: lastMotionError,
            motionFilter: settings.pointer.filterMode.rawValue,
            inputGate: control.gate.state.rawValue,
            accelerationAvailable: control.gate.accelerationAvailable,
            measurementNoise: control.estimator.measurementNoise
        )
        if snapshot != diagnostics { diagnostics = snapshot }
    }

    private func refreshPermissions() {
        var granted = false
        let trusted = EventSynthesizer.isTrusted
        if trusted != accessibilityTrusted {
            accessibilityTrusted = trusted
            granted = granted || trusted
            if !trusted, trackingEnabled { setTracking(false) }
        }
        let auth = HeadphoneMotionService.authorizationStatus
        if auth != motionAuthorization {
            motionAuthorization = auth
            granted = granted || auth == .authorized
            updateServices()
        }
        autoStartIfReady()
        // Granting Accessibility happens in System Settings, which buries our window.
        // Bring the tour back so setup continues right where the user left it.
        if granted, !settings.hasCompletedOnboarding { showTour() }
    }

    // MARK: Windows

    /// Set by the menu bar label, which can call SwiftUI's openWindow.
    var windowOpener: ((String) -> Void)?

    func showTour() {
        windowOpener?(WindowID.tour)
        NSApp.activate()
        DispatchQueue.main.async {
            NSApp.windows.first { $0.title == "Welcome to AirCursor" }?.makeKeyAndOrderFront(nil)
        }
    }

    /// AirCursor is a menu bar app, but while one of its windows is open it shows in the
    /// Dock and ⌘-Tab so the window can't get lost behind other apps.
    func windowVisibilityChanged() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let titles: Set<String> = ["AirCursor", "Welcome to AirCursor", "Motion calibration"]
            let anyOpen = NSApp.windows.contains { $0.isVisible && titles.contains($0.title) }
            let policy: NSApplication.ActivationPolicy = anyOpen ? .regular : .accessory
            if NSApp.activationPolicy() != policy {
                NSApp.setActivationPolicy(policy)
                if anyOpen { NSApp.activate() }
            }
        }
    }

    private func headphonesChanged(connected: Bool) {
        refreshDevices()
        if connected {
            if trackingEnabled { routeAudioToHeadphonesIfNeeded() }
            control.reset()
            motionUpdate = nil
            tiltAnchor = nil
            control.gestures.resetTiltBaseline()
            toast("AirPods head tracking connected", symbol: "airpodspro")
        } else {
            motionStreaming = false
            calibration.connectionInterrupted()
            control.suspend()
            motionUpdate = nil
            tiltAnchor = nil
            smoother.reset()
            releaseButtons()
            if trackingEnabled { toast("AirPods disconnected", symbol: "exclamationmark.triangle.fill") }
        }
    }

    private func motionFailed(_ error: Error) {
        let ns = error as NSError
        lastMotionError = "\(ns.localizedDescription) (\(ns.domain) \(ns.code))"
        refreshPermissions()
        if motionAuthorization == .denied {
            lastError = "Motion access is off. Turn on AirCursor in System Settings › Privacy & Security."
        } else {
            NSLog("AirCursor: motion error \(error.localizedDescription)")
        }
    }

    // MARK: Motion → pointer

    func compareRecentMotion() {
        let report = MotionReplay.run(motionTrace, pointer: settings.pointer,
                                      gestures: settings.gestures, enabled: settings.actions.enabledHeadGestures)
        motionComparison = String(format: "%d recent samples · angular speed RMS: raw %.2f°/s → filtered %.2f°/s · %d suppressed samples. Compare while resting to assess jitter.",
                                  report.sampleCount, report.rawRateRMS, report.filteredRateRMS, report.suppressedSamples)
    }

    private func handle(_ sample: MotionSample) {
        let hostNow = Self.now
        lastSampleHostTime = hostNow
        sampleCount += 1
        if calibration.isActive {
            if !motionStreaming { motionStreaming = true }
            calibration.push(sample, hostTime: hostNow)
            return // calibration/preview must never synthesize desktop input
        }
        if sample.isFinite {
            motionTrace.append(sample)
            if motionTrace.count > 250 { motionTrace.removeFirst(motionTrace.count - 250) }
        }
        if !motionStreaming {
            motionStreaming = true
            Diagnostics.log.notice("Motion samples arriving")
            if motionAuthorization != .authorized { refreshPermissions() }
        }

        var enabled = settings.actions.enabledHeadGestures
        if nodCalibration != nil { enabled.insert(.nod) }
        let update = control.process(sample, enabled: enabled)
        motionUpdate = update

        if !update.allowsAutomaticClicks { dwell.reset() }
        if update.holdingPointer {
            smoother.reset()
            scrollRemainder = .zero
        }
        if update.gate == .frozen || !update.accepted { releaseButtons() }

        // Lock the target at the first likely tilt, before its hold-to-click interval.
        if trackingEnabled, mode == .pointer, let start = update.tiltStartTime, tiltAnchor == nil {
            let hostStart = start + (hostNow - sample.timestamp)
            let before = history.position(at: hostStart - 0.06)
            tiltAnchor = before.map { CGPoint(x: $0.x, y: $0.y) } ?? cursor ?? synth.currentLocation()
            if let anchor = tiltAnchor { cursor = anchor; post(anchor) }
        }
        if !update.holdingPointer { tiltAnchor = nil }

        if let event = update.gesture {
            if event.gesture == .nod {
                lastNodDepth = event.magnitude
                nodCalibration?.append(event.magnitude)
            }
            let start = event.startTime + (hostNow - sample.timestamp)
            handle(trigger: Trigger(event.gesture), gestureStart: start)
        }
        if trackingEnabled, motionUpdate != nil {
            smoother.setTarget(update.targetVelocity, at: hostNow)
        }

        if sample.isFinite, hostNow - lastLivePublish > 0.1 {
            lastLivePublish = hostNow
            let status: String
            if update.gate == .frozen { status = "Motion paused — settling" }
            else if update.gate == .cautious { status = "Repositioning — slower movement, clicks paused" }
            else if update.holdingPointer { status = "Tilt click — return to neutral to point" }
            else { status = "Ready" }
            live = LiveReadout(
                hasData: true,
                yaw: AngleMath.degrees(sample.yaw), pitch: AngleMath.degrees(sample.pitch),
                roll: AngleMath.degrees(sample.roll),
                yawRate: update.rates?.yaw ?? 0, pitchRate: update.rates?.pitch ?? 0,
                inputState: status, acceleration: sample.userAcceleration?.length, accelerationVector: sample.userAcceleration,
                rawYawRate: update.rawRates?.yaw ?? 0, rawPitchRate: update.rawRates?.pitch ?? 0,
                relativeRoll: control.gestures.relativeRoll(AngleMath.degrees(sample.roll))
            )
        }
    }

    /// Runs at 120 Hz while tracking: integrates smoothed velocity into cursor movement.
    private func frame() {
        guard trackingEnabled, !calibration.isActive else { return }
        let now = Self.now
        let dt = min(max(now - (lastFrame ?? now), 0), 0.05)
        lastFrame = now

        if motionUpdate != nil, now - lastSampleHostTime > PointerSmoother.staleAfter {
            control.suspend()
            motionUpdate = nil
            tiltAnchor = nil
            smoother.reset()
            dwell.reset()
            scrollRemainder = .zero
            releaseButtons()
            live.inputState = "Motion paused — waiting for samples"
        }
        var delta = smoother.step(now: now, dt: dt, smoothing: settings.pointer.smoothing)
        if syncCursorWithSystem() { delta = .zero }
        guard var position = cursor else { return }

        switch mode {
        case .pointer:
            if delta.length > 0.000001 {
                let next = screens.clamp(CGPoint(x: position.x + delta.x, y: position.y + delta.y), from: position)
                lastFrameDelta = hypot(next.x - position.x, next.y - position.y)
                position = next
                cursor = next
                post(next)
            } else {
                lastFrameDelta = 0
            }
        case .scroll:
            scrollRemainder += delta * (0.6 * settings.pointer.scrollSpeed)
            let sx = scrollRemainder.x.rounded(.towardZero)
            let sy = scrollRemainder.y.rounded(.towardZero)
            if sx != 0 || sy != 0 {
                scrollRemainder -= Vec2(sx, sy)
                let sign: Double = settings.pointer.invertScroll ? 1 : -1
                // Look down → reveal content below; turn right → reveal content to the right.
                synth.scroll(vertical: Int32(sy * sign), horizontal: Int32(sx * sign))
            }
        }

        history.append(Vec2(position.x, position.y), at: now)

        if mode == .pointer, settings.dwell.enabled, settings.actions[.dwell] != .none,
           motionStreaming, motionUpdate?.allowsAutomaticClicks == true, !isDragging, !userIsTyping {
            let update = dwell.update(position: Vec2(position.x, position.y), time: now)
            var progress = update.progress
            var fired = update.fired
            if settings.dwell.smart {
                // Once per resting spot, ask whether what's under the pointer is clickable.
                // Until we know (or if it isn't), show nothing and don't click.
                let anchor = dwell.anchorID
                if progress != nil || fired, probedAnchor != anchor {
                    probedAnchor = anchor
                    anchorClickable = nil
                    ClickableProbe.check(position) { [weak self] clickable in
                        guard let self, self.probedAnchor == anchor else { return }
                        self.anchorClickable = clickable
                    }
                }
                if anchorClickable != true {
                    progress = nil
                    fired = false
                }
            }
            cursorOverlay.update(dwellProgress: progress, at: position)
            if fired { handle(trigger: .dwell, gestureStart: nil) }
        } else {
            cursorOverlay.update(dwellProgress: motionUpdate?.tiltProgress, at: position)
        }
    }

    /// Hover click stays out of the way while you type.
    private var userIsTyping: Bool {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown) < 1.5
    }

    /// Adopts the real cursor position if something else (a mouse, trackpad) moved it.
    /// Our own recent posts are tolerated because the system position can lag a frame.
    private func syncCursorWithSystem() -> Bool {
        let actual = synth.currentLocation()
        guard let ours = cursor else {
            cursor = actual
            lastPosted = [actual]
            return true
        }
        let tolerance = max(6, lastFrameDelta * 2 + 6)
        let candidates = lastPosted.isEmpty ? [ours] : lastPosted
        let isOurs = candidates.contains { hypot($0.x - actual.x, $0.y - actual.y) <= tolerance }
        if !isOurs {
            cursor = actual
            lastPosted = [actual]
            smoother.reset()
            dwell.reset()
            control.cancelGestures()
            motionUpdate = nil
            tiltAnchor = nil
            return true
        }
        return false
    }

    private func post(_ point: CGPoint) {
        guard !calibration.isActive else { return }
        synth.move(to: point)
        lastPosted.append(point)
        if lastPosted.count > 3 { lastPosted.removeFirst(lastPosted.count - 3) }
    }

    // MARK: Triggers → actions

    private func handle(trigger: Trigger, gestureStart: TimeInterval?) {
        guard !calibration.isActive else { return }
        let action = settings.actions[trigger]
        guard action != .none else { return }
        if trigger.headGesture != nil || trigger == .dwell {
            guard motionUpdate?.accepted == true, motionUpdate?.gate == .normal else { return }
        }
        guard trackingEnabled || action == .toggleTracking else { return }
        // Head gestures can't pause tracking during setup: people look around a lot
        // while granting permissions and putting AirPods in.
        if action == .toggleTracking, trigger.headGesture != nil, !settings.hasCompletedOnboarding { return }
        guard accessibilityTrusted || !action.needsAccessibility else {
            toast("Allow Accessibility to click", symbol: "lock.shield")
            return
        }

        var point = cursor ?? synth.currentLocation()
        // A nod/shake nudges the cursor; put it back where it was when the gesture began.
        if (trigger == .tiltLeft || trigger == .tiltRight), let anchor = tiltAnchor {
            point = anchor
        } else if let start = gestureStart, trackingEnabled, mode == .pointer,
           let before = history.position(at: start - 0.06) {
            point = CGPoint(x: before.x, y: before.y)
            cursor = point
            post(point)
            smoother.reset()
        }

        lastTriggerDescription = "\(trigger.displayName) → \(action.displayName)"
        perform(action, at: point)
        lastTriggerEvent = TriggerEvent(trigger: trigger, action: action)
    }

    private func perform(_ action: PointerAction, at point: CGPoint) {
        guard !calibration.isActive else { return }
        switch action {
        case .none:
            return
        case .leftClick:
            if isDragging {
                endDrag(at: point)
            } else {
                synth.click(.left, at: point)
                clickFeedback(at: point)
            }
        case .rightClick:
            if isDragging { endDrag(at: point) }
            synth.click(.right, at: point)
            clickFeedback(at: point)
        case .doubleClick:
            if isDragging { endDrag(at: point) }
            synth.click(.left, at: point, count: 2)
            clickFeedback(at: point)
        case .middleClick:
            synth.click(.center, at: point)
            clickFeedback(at: point)
        case .toggleDrag:
            if isDragging { endDrag(at: point) } else { beginDrag(at: point) }
        case .toggleScrollMode:
            setMode(mode == .pointer ? .scroll : .pointer)
        case .toggleTracking:
            toggleTracking()
        case .recenter:
            let r = screens.display(containing: point)
            let center = CGPoint(x: r.midX, y: r.midY)
            cursor = center
            post(center)
            smoother.reset()
            control.reset()
            motionUpdate = nil
            tiltAnchor = nil
            history.removeAll()
            toast("Recentered", symbol: "scope")
        case .missionControl, .appWindows, .previousSpace, .nextSpace, .back, .forward, .screenshot:
            if let shortcut = action.keyShortcut {
                synth.keyStroke(shortcut.key, flags: shortcut.flags)
                toast(action.displayName, symbol: action.symbol)
            }
        }
        if action.isClick { dwell.reset() }
    }

    private func beginDrag(at point: CGPoint) {
        synth.leftDown(at: point)
        isDragging = true
        clickFeedback(at: point)
        toast("Dragging — click again to drop", symbol: "hand.draw.fill")
    }

    private func endDrag(at point: CGPoint) {
        synth.leftUp(at: point)
        isDragging = false
        clickFeedback(at: point)
    }

    /// Never leave a mouse button stuck down.
    private func releaseButtons() {
        if synth.isLeftButtonDown { synth.leftUp(at: cursor ?? synth.currentLocation()) }
        isDragging = false
    }

    private func clickFeedback(at point: CGPoint) {
        if settings.showClickPulse { cursorOverlay.pulse(at: point) }
    }

    private func toast(_ text: String, symbol: String) {
        guard settings.showHUD else { return }
        hud.show(text, symbol: symbol, near: cursor ?? synth.currentLocation())
    }

    private func registerHotKeys() {
        let mods = HotKey.modifiers
        hotKeys.register(id: HotKey.toggleTracking.id, keyCode: HotKey.toggleTracking.keyCode, modifiers: mods) { [weak self] in
            self?.toggleTracking()
        }
        hotKeys.register(id: HotKey.scrollMode.id, keyCode: HotKey.scrollMode.keyCode, modifiers: mods) { [weak self] in
            guard let self, self.trackingEnabled else { return }
            self.setMode(self.mode == .pointer ? .scroll : .pointer)
        }
        hotKeys.register(id: HotKey.recenter.id, keyCode: HotKey.recenter.keyCode, modifiers: mods) { [weak self] in
            self?.recenterNow()
        }
        hotKeys.register(id: HotKey.drag.id, keyCode: HotKey.drag.keyCode, modifiers: mods) { [weak self] in
            guard let self, self.trackingEnabled, self.accessibilityTrusted else { return }
            self.perform(.toggleDrag, at: self.cursor ?? self.synth.currentLocation())
        }
    }

    // MARK: Menu bar

    var menuBarSymbol: String {
        if !trackingEnabled { return "cursorarrow" }
        if !motionStreaming { return "airpodspro" }
        return mode == .scroll ? "arrow.up.and.down.circle" : "cursorarrow.motionlines"
    }

    var statusText: String {
        if calibration.isActive { return "Calibrating — head control paused" }
        if !accessibilityTrusted { return "Needs Accessibility permission" }
        if motionAuthorization == .denied { return "Motion access denied" }
        if !trackingEnabled { return "Paused" }
        if needsAudioHandoff { return "Choose AirPods as Mac sound output" }
        if !motionStreaming { return "Waiting for AirPods…" }
        if isDragging { return "Dragging" }
        return mode == .scroll ? "Scrolling" : "Tracking your head"
    }
}

// MARK: - Keyboard shortcuts for system actions

extension PointerAction {
    var needsAccessibility: Bool { self != .toggleTracking && self != .toggleScrollMode && self != .none }

    var keyShortcut: (key: CGKeyCode, flags: CGEventFlags)? {
        let arrow: CGEventFlags = [.maskSecondaryFn, .maskNumericPad]
        switch self {
        case .missionControl: return (CGKeyCode(kVK_UpArrow), arrow.union(.maskControl))
        case .appWindows: return (CGKeyCode(kVK_DownArrow), arrow.union(.maskControl))
        case .previousSpace: return (CGKeyCode(kVK_LeftArrow), arrow.union(.maskControl))
        case .nextSpace: return (CGKeyCode(kVK_RightArrow), arrow.union(.maskControl))
        case .back: return (CGKeyCode(kVK_ANSI_LeftBracket), .maskCommand)
        case .forward: return (CGKeyCode(kVK_ANSI_RightBracket), .maskCommand)
        case .screenshot: return (CGKeyCode(kVK_ANSI_5), [.maskCommand, .maskShift])
        default: return nil
        }
    }

    var symbol: String {
        switch self {
        case .none: "circle.slash"
        case .leftClick: "cursorarrow.click"
        case .rightClick: "contextualmenu.and.cursorarrow"
        case .doubleClick: "cursorarrow.click.2"
        case .middleClick: "computermouse"
        case .toggleDrag: "hand.draw"
        case .toggleScrollMode: "arrow.up.and.down"
        case .toggleTracking: "pause.circle"
        case .recenter: "scope"
        case .missionControl: "rectangle.3.group"
        case .appWindows: "macwindow.on.rectangle"
        case .previousSpace: "arrow.left.square"
        case .nextSpace: "arrow.right.square"
        case .back: "chevron.backward"
        case .forward: "chevron.forward"
        case .screenshot: "camera.viewfinder"
        }
    }
}

// MARK: - Persistence

enum SettingsStore {
    private static let key = "AirCursor.settings.v1"

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return settings
    }

    static func save(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

struct DiagnosticsSnapshot: Equatable {
    var accessibility = false
    var motionAuthorization = "—"
    var motionAvailable = false
    var motionActive = false
    var samplesReceived = 0
    var secondsSinceLastSample: Double?
    var audioKeepAlive = false
    var stemControls = false
    var trackingEnabled = false
    var connectedHeadphones: String?
    var soundOutput: (name: String, isBluetooth: Bool)?
    var headphonesAsAudio = false
    var lastMotionError: String?
    var motionFilter = "kalman"
    var inputGate = "normal"
    var accelerationAvailable = false
    var measurementNoise = 0.15

    static func == (a: Self, b: Self) -> Bool { a.text == b.text }

    var rows: [(label: String, value: String, ok: Bool)] {
        let fresh = samplesReceived > 0 && (secondsSinceLastSample ?? 99) < 2
        let last = secondsSinceLastSample.map { String(format: " (last %.1fs ago)", $0) } ?? ""
        var out: [(label: String, value: String, ok: Bool)] = [
            ("Accessibility (pointer control)", accessibility ? "allowed" : "NOT allowed", accessibility),
            ("Motion permission", motionAuthorization, motionAuthorization == "allowed"),
            ("Headphones connected", connectedHeadphones ?? "none", connectedHeadphones != nil),
            ("AirPods playing for this Mac", headphonesAsAudio ? "yes" : "no — choose them in Control Center › Sound", headphonesAsAudio),
            ("Mac sound output", soundOutput?.name ?? "unknown", soundOutput?.isBluetooth ?? false),
            ("Headphone motion available", motionAvailable ? "yes" : "no", motionAvailable),
            ("Motion updates running", motionActive ? "yes" : "no", motionActive),
            ("Motion samples received", "\(samplesReceived)\(last)", fresh),
            ("Audio keep-alive", audioKeepAlive ? "running" : "off", audioKeepAlive),
            ("Stem controls", stemControls ? "listening" : "off", stemControls),
            ("Head tracking", trackingEnabled ? "on" : "off", trackingEnabled),
            ("Motion filter", motionFilter, true),
            ("Input state", inputGate, inputGate == "normal"),
            ("Acceleration observations", accelerationAvailable ? "available" : "unavailable — attitude only", accelerationAvailable),
            ("Attitude noise estimate", String(format: "%.3f°", measurementNoise), true),
        ]
        if let lastMotionError { out.append(("Last motion error", lastMotionError, false)) }
        return out
    }

    var text: String { rows.map { "\($0.label): \($0.value)" }.joined(separator: "\n") }
}

struct TriggerEvent: Equatable {
    let id = UUID()
    let trigger: Trigger
    let action: PointerAction
    let time = Date()
}

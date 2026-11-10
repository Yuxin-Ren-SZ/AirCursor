import Foundation

extension KeyedDecodingContainer {
    /// Lenient decode: a missing or mistyped key falls back to the default, so settings
    /// saved by an older/newer build never wipe the user's whole configuration.
    func value<T: Decodable>(_ key: Key, default fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
}

public struct PointerSettings: Codable, Equatable, Sendable {
    /// Overall speed multiplier.
    public var sensitivity: Double = 1.0
    /// How much faster the cursor goes for quick head turns (0 = linear).
    public var acceleration: Double = 0.6
    /// Head rotation speed (deg/s) below which the cursor holds still. Filters tremor.
    public var deadzone: Double = 1.2
    /// 0 = raw, 0.95 = very smooth/laggy.
    public var smoothing: Double = 0.18
    public var filterMode: MotionFilterMode = .kalman
    public var filter = KalmanSettings()
    public var repositioning = RepositioningSettings()
    public var precisionGain: Double = 14
    public var travelGain: Double = 56
    public var transitionSpeed: Double = 35
    public var adaptiveDeadzone: Bool = true
    public var invertHorizontal: Bool = false
    public var invertVertical: Bool = false
    public var scrollSpeed: Double = 1.0
    public var invertScroll: Bool = false

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PointerSettings()
        sensitivity = c.value(.sensitivity, default: d.sensitivity)
        acceleration = c.value(.acceleration, default: d.acceleration)
        deadzone = c.value(.deadzone, default: d.deadzone)
        smoothing = c.value(.smoothing, default: d.smoothing)
        filterMode = c.value(.filterMode, default: d.filterMode)
        filter = c.value(.filter, default: d.filter)
        repositioning = c.value(.repositioning, default: d.repositioning)
        precisionGain = c.value(.precisionGain, default: d.precisionGain)
        travelGain = c.value(.travelGain, default: d.travelGain)
        transitionSpeed = c.value(.transitionSpeed, default: d.transitionSpeed)
        adaptiveDeadzone = c.value(.adaptiveDeadzone, default: d.adaptiveDeadzone)
        invertHorizontal = c.value(.invertHorizontal, default: d.invertHorizontal)
        invertVertical = c.value(.invertVertical, default: d.invertVertical)
        scrollSpeed = c.value(.scrollSpeed, default: d.scrollSpeed)
        invertScroll = c.value(.invertScroll, default: d.invertScroll)
    }
}

public struct GestureSettings: Codable, Equatable, Sendable {
    /// How far (degrees) the head must dip for a nod. Tuned per user by the guided tour.
    public var nodAmplitude: Double = 5.5
    /// Max time for a whole nod (down and back).
    public var nodWindow: Double = 0.8
    /// How far (degrees) each swing of a head shake must go.
    public var shakeAmplitude: Double = 12
    /// Time window for the four swings of a shake.
    public var shakeWindow: Double = 1.4
    /// Roll (degrees) away from your neutral posture that counts as a tilt.
    public var tiltAngle: Double = 18
    /// How long a tilt must be held before it fires.
    public var tiltHold: Double = 0.25
    /// Flip which side counts as "left" if your AirPods report roll the other way.
    public var swapTiltDirection: Bool = false
    /// Quiet period after any gesture so one movement can't fire twice.
    public var cooldown: Double = 0.5

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GestureSettings()
        nodAmplitude = c.value(.nodAmplitude, default: d.nodAmplitude)
        nodWindow = c.value(.nodWindow, default: d.nodWindow)
        shakeAmplitude = c.value(.shakeAmplitude, default: d.shakeAmplitude)
        shakeWindow = c.value(.shakeWindow, default: d.shakeWindow)
        tiltAngle = c.value(.tiltAngle, default: d.tiltAngle)
        tiltHold = c.value(.tiltHold, default: d.tiltHold)
        swapTiltDirection = c.value(.swapTiltDirection, default: d.swapTiltDirection)
        cooldown = c.value(.cooldown, default: d.cooldown)
    }
}

/// "Hover click": rest the pointer and it clicks.
public struct DwellSettings: Codable, Equatable, Sendable {
    public var enabled: Bool = false
    /// Only click things that are clickable (buttons, links, tabs, menus, fields…),
    /// so resting on text you're reading never clicks.
    public var smart: Bool = true
    /// Seconds the cursor must rest before it clicks.
    public var duration: Double = 0.8
    /// Pixels of drift still considered "resting".
    public var radius: Double = 16

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DwellSettings()
        enabled = c.value(.enabled, default: d.enabled)
        smart = c.value(.smart, default: d.smart)
        duration = c.value(.duration, default: d.duration)
        radius = c.value(.radius, default: d.radius)
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    /// Bumped when defaults change in a way existing users should receive.
    public static let currentVersion = 4
    public var version: Int = AppSettings.currentVersion

    public var pointer = PointerSettings()
    public var gestures = GestureSettings()
    public var dwell = DwellSettings()
    public var actions = ActionMap()
    /// Listen for AirPods stem presses (play/pause, next, previous).
    public var stemControlsEnabled: Bool = true
    /// Play an inaudible stream so macOS routes AirPods presses to AirCursor.
    public var keepAudioRouteActive: Bool = true
    /// Make the AirPods the Mac's sound output when tracking starts. AirPods only
    /// stream head motion to the device they're playing for, so this is on by default.
    public var routeAudioToHeadphones: Bool = true
    public var showHUD: Bool = true
    public var showClickPulse: Bool = true
    public var hasCompletedOnboarding: Bool = false

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        version = c.value(.version, default: 1)
        pointer = c.value(.pointer, default: d.pointer)
        gestures = c.value(.gestures, default: d.gestures)
        dwell = c.value(.dwell, default: d.dwell)
        actions = c.value(.actions, default: d.actions)
        if version < 4 {
            actions = .preTiltDefaults
            if let raw = try? c.decode([String: String].self, forKey: .actions) {
                for (key, value) in raw {
                    if let trigger = Trigger(rawValue: key), let action = PointerAction(rawValue: value) {
                        actions[trigger] = action
                    }
                }
            }
        }
        stemControlsEnabled = c.value(.stemControlsEnabled, default: d.stemControlsEnabled)
        keepAudioRouteActive = c.value(.keepAudioRouteActive, default: d.keepAudioRouteActive)
        routeAudioToHeadphones = c.value(.routeAudioToHeadphones, default: d.routeAudioToHeadphones)
        showHUD = c.value(.showHUD, default: d.showHUD)
        showClickPulse = c.value(.showClickPulse, default: d.showClickPulse)
        hasCompletedOnboarding = c.value(.hasCompletedOnboarding, default: d.hasCompletedOnboarding)
    }
}

extension AppSettings {
    /// Upgrades settings saved by older builds.
    public func migrated() -> AppSettings {
        var s = self
        if s.version < 2 {
            // v2: smart hover click becomes the default hands-free tap, and nods are
            // measured in degrees (smaller default).
            s.dwell = DwellSettings()
            s.dwell.enabled = true // historical v2 default
            s.gestures.nodAmplitude = GestureSettings().nodAmplitude
        }
        if s.version < 3 {
            // v3: shake needs bigger, repeated swings so glancing around never pauses.
            s.gestures.shakeAmplitude = GestureSettings().shakeAmplitude
            s.gestures.shakeWindow = GestureSettings().shakeWindow
        }
        if s.version < 4 {
            // Only replace the old stock bindings. Deliberate customizations survive.
            if s.actions == .preTiltDefaults {
                s.actions = ActionMap()
                s.dwell.enabled = false
            }
            if s.pointer.deadzone == 3 { s.pointer.deadzone = PointerSettings().deadzone }
            if s.pointer.smoothing == 0.55 { s.pointer.smoothing = PointerSettings().smoothing }
            if s.gestures.tiltAngle == 22 { s.gestures.tiltAngle = GestureSettings().tiltAngle }
            if s.gestures.tiltHold == 0.3 { s.gestures.tiltHold = GestureSettings().tiltHold }
        }
        s.version = AppSettings.currentVersion
        return s
    }
}

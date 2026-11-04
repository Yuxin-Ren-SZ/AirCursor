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
    public var deadzone: Double = 3.0
    /// 0 = raw, 0.95 = very smooth/laggy.
    public var smoothing: Double = 0.55
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
        invertHorizontal = c.value(.invertHorizontal, default: d.invertHorizontal)
        invertVertical = c.value(.invertVertical, default: d.invertVertical)
        scrollSpeed = c.value(.scrollSpeed, default: d.scrollSpeed)
        invertScroll = c.value(.invertScroll, default: d.invertScroll)
    }
}

public struct GestureSettings: Codable, Equatable, Sendable {
    /// Pitch speed (deg/s) a nod must reach.
    public var nodThreshold: Double = 110
    /// Max time between the down and up halves of a nod.
    public var nodWindow: Double = 0.55
    /// Yaw speed (deg/s) each swing of a head shake must reach.
    public var shakeThreshold: Double = 130
    /// Time window for the three swings of a shake.
    public var shakeWindow: Double = 0.9
    /// Roll (degrees) away from your neutral posture that counts as a tilt.
    public var tiltAngle: Double = 22
    /// How long a tilt must be held before it fires.
    public var tiltHold: Double = 0.3
    /// Flip which side counts as "left" if your AirPods report roll the other way.
    public var swapTiltDirection: Bool = false
    /// Quiet period after any gesture so one movement can't fire twice.
    public var cooldown: Double = 0.5

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GestureSettings()
        nodThreshold = c.value(.nodThreshold, default: d.nodThreshold)
        nodWindow = c.value(.nodWindow, default: d.nodWindow)
        shakeThreshold = c.value(.shakeThreshold, default: d.shakeThreshold)
        shakeWindow = c.value(.shakeWindow, default: d.shakeWindow)
        tiltAngle = c.value(.tiltAngle, default: d.tiltAngle)
        tiltHold = c.value(.tiltHold, default: d.tiltHold)
        swapTiltDirection = c.value(.swapTiltDirection, default: d.swapTiltDirection)
        cooldown = c.value(.cooldown, default: d.cooldown)
    }
}

public struct DwellSettings: Codable, Equatable, Sendable {
    public var enabled: Bool = false
    /// Seconds the cursor must rest before it clicks.
    public var duration: Double = 1.0
    /// Pixels of drift still considered "resting".
    public var radius: Double = 14

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DwellSettings()
        enabled = c.value(.enabled, default: d.enabled)
        duration = c.value(.duration, default: d.duration)
        radius = c.value(.radius, default: d.radius)
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
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
        pointer = c.value(.pointer, default: d.pointer)
        gestures = c.value(.gestures, default: d.gestures)
        dwell = c.value(.dwell, default: d.dwell)
        actions = c.value(.actions, default: d.actions)
        stemControlsEnabled = c.value(.stemControlsEnabled, default: d.stemControlsEnabled)
        keepAudioRouteActive = c.value(.keepAudioRouteActive, default: d.keepAudioRouteActive)
        routeAudioToHeadphones = c.value(.routeAudioToHeadphones, default: d.routeAudioToHeadphones)
        showHUD = c.value(.showHUD, default: d.showHUD)
        showClickPulse = c.value(.showClickPulse, default: d.showClickPulse)
        hasCompletedOnboarding = c.value(.hasCompletedOnboarding, default: d.hasCompletedOnboarding)
    }
}

import MediaPlayer
import AirCursorCore

/// Captures AirPods stem presses.
///
/// AirPods send stem presses to whichever app macOS considers "Now Playing":
/// one press → play/pause, two → next track, three → previous track. AirCursor
/// claims Now Playing while active and turns those commands into triggers.
/// (AudioKeepAlive makes macOS treat AirCursor as genuinely playing.)
final class StemControlService {
    var onPress: ((Trigger) -> Void)?

    private(set) var isActive = false
    private var targets: [(MPRemoteCommand, Any)] = []
    private var lastSinglePress: TimeInterval = 0

    /// Presses closer together than this are the same press (macOS can send pause+play).
    static let debounce: TimeInterval = 0.3

    func start() {
        guard !isActive else { return }
        isActive = true
        let center = MPRemoteCommandCenter.shared()
        register(center.togglePlayPauseCommand, as: .stemSingle)
        register(center.playCommand, as: .stemSingle)
        register(center.pauseCommand, as: .stemSingle)
        register(center.nextTrackCommand, as: .stemDouble)
        register(center.previousTrackCommand, as: .stemTriple)
        publishNowPlaying()
        Diagnostics.log.notice("Stem controls active")
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        for (command, target) in targets { command.removeTarget(target) }
        targets.removeAll()
        let info = MPNowPlayingInfoCenter.default()
        info.nowPlayingInfo = nil
        info.playbackState = .stopped
        Diagnostics.log.notice("Stem controls released")
    }

    private func register(_ command: MPRemoteCommand, as trigger: Trigger) {
        command.isEnabled = true
        let target = command.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.handle(trigger) }
            return .success
        }
        targets.append((command, target))
    }

    private func handle(_ trigger: Trigger) {
        Diagnostics.log.notice("Stem command → \(trigger.rawValue, privacy: .public)")
        if trigger == .stemSingle {
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastSinglePress > Self.debounce else { return }
            lastSinglePress = now
        }
        // Stay "playing" so the next press arrives as the same command family.
        publishNowPlaying()
        onPress?(trigger)
    }

    private func publishNowPlaying() {
        let info = MPNowPlayingInfoCenter.default()
        info.nowPlayingInfo = [
            MPMediaItemPropertyTitle: "AirCursor",
            MPMediaItemPropertyArtist: "Head pointer active",
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        info.playbackState = .playing
    }
}

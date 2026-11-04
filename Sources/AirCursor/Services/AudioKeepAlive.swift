import AVFoundation

/// Plays an inaudible stream to the current output device.
///
/// macOS streams AirPods head-tracking data most reliably while the AirPods are the
/// active audio route, and routes stem presses to the app that is actually playing.
/// This keeps both working without any audible sound.
final class AudioKeepAlive {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var configured = false
    private var wanted = false
    private var configObserver: NSObjectProtocol?

    private(set) var isRunning = false

    func start() {
        wanted = true
        configureIfNeeded()
        restart()
    }

    func stop() {
        wanted = false
        guard configured else { return }
        player.stop()
        engine.stop()
        isRunning = false
        Diagnostics.log.notice("Audio keep-alive stopped")
    }

    private func configureIfNeeded() {
        guard !configured else { return }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: Self.format)
        configured = true

        // Output device changed (e.g. AirPods connected) → restart on the new route.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self, self.wanted else { return }
            Diagnostics.log.notice("Audio route changed; restarting keep-alive")
            self.isRunning = false
            self.restart()
        }
    }

    private static let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!

    private static func silentBuffer() -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100) else { return nil }
        buffer.frameLength = buffer.frameCapacity
        if let channels = buffer.floatChannelData {
            for c in 0..<Int(format.channelCount) {
                channels[c].update(repeating: 0, count: Int(buffer.frameLength))
            }
        }
        return buffer
    }

    private func restart() {
        guard wanted, let buffer = Self.silentBuffer() else { return }
        do {
            if !engine.isRunning {
                engine.prepare()
                try engine.start()
            }
            if !player.isPlaying {
                player.scheduleBuffer(buffer, at: nil, options: .loops)
                player.play()
            }
            if !isRunning { Diagnostics.log.notice("Audio keep-alive running") }
            isRunning = true
        } catch {
            isRunning = false
            Diagnostics.log.error("Audio keep-alive failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

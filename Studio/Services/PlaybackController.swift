import AVFoundation
import Foundation

/// Plays one recording at a time (history and save sheet).
final class PlaybackController: ObservableObject {
    @Published private(set) var currentID: UUID?
    @Published private(set) var isPlaying = false
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    deinit {
        tearDown()
    }

    func isPlaying(_ id: UUID) -> Bool {
        currentID == id && isPlaying
    }

    /// Plays the recording, or pauses it when it is already playing.
    func toggle(id: UUID, url: URL, duration: TimeInterval) {
        if currentID == id, let player {
            if isPlaying {
                player.pause()
                isPlaying = false
            } else {
                if position >= self.duration - 0.05 {
                    player.seek(to: .zero)
                    position = 0
                }
                player.play()
                isPlaying = true
            }
            return
        }
        load(id: id, url: url, duration: duration)
        player?.play()
        isPlaying = true
    }

    private func load(id: UUID, url: URL, duration: TimeInterval) {
        tearDown()
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        self.player = player
        self.duration = duration
        currentID = id
        position = 0

        let interval = CMTime(seconds: 0.2, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self, time.seconds.isFinite else { return }
            self.position = time.seconds
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.isPlaying = false
            self.position = self.duration
        }
    }

    /// Jumps to a fraction (0…1) of the current recording.
    func seek(toFraction fraction: Double) {
        guard let player, duration > 0 else { return }
        let target = min(1, max(0, fraction)) * duration
        position = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    }

    func stop() {
        tearDown()
        currentID = nil
        isPlaying = false
        position = 0
        duration = 0
    }

    private func tearDown() {
        player?.pause()
        if let timeObserver {
            player?.removeTimeObserver(timeObserver)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        timeObserver = nil
        endObserver = nil
        player = nil
    }
}

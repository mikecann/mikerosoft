import AVFoundation
import Foundation

enum TranscriptTimeline {
    static func activeSegmentIndex(
        at time: TimeInterval,
        segments: [TranscriptSegment]
    ) -> Int? {
        segments.firstIndex { segment in
            time >= segment.start && time < segment.end
        }
    }
}

enum WaveformMath {
    static func normalizedPower(meanSquare: Double) -> Double {
        guard meanSquare > 0 else { return 0 }
        // A square root turns mean-square PCM energy into RMS amplitude. The
        // extra square root gives quiet speech enough visual presence without
        // making loud samples exceed the waveform bounds.
        return min(1, sqrt(sqrt(meanSquare)))
    }

    static func resample(_ samples: [Double], targetCount: Int) -> [Double] {
        guard !samples.isEmpty, targetCount > 0 else { return [] }
        guard samples.count > targetCount else {
            return samples.map { min(1, max(0, $0)) }
        }

        return (0..<targetCount).map { index in
            let start = index * samples.count / targetCount
            let end = max(start + 1, (index + 1) * samples.count / targetCount)
            return samples[start..<min(end, samples.count)]
                .map { min(1, max(0, $0)) }
                .max() ?? 0
        }
    }
}

@MainActor
final class MeetingPlaybackController: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0

    private var player: AVAudioPlayer?
    private var timer: Timer?

    func load(url: URL) throws {
        stop()
        let player = try AVAudioPlayer(contentsOf: url)
        player.delegate = self
        player.prepareToPlay()
        self.player = player
        duration = player.duration
        currentTime = 0
    }

    func togglePlayback() {
        guard let player else { return }
        if player.isPlaying {
            pause()
        } else {
            if player.currentTime >= player.duration {
                player.currentTime = 0
            }
            player.play()
            isPlaying = true
            startTimer()
        }
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        let bounded = min(max(0, time), player.duration)
        player.currentTime = bounded
        currentTime = bounded
    }

    func skip(by interval: TimeInterval) {
        seek(to: currentTime + interval)
    }

    func pause() {
        player?.pause()
        isPlaying = false
        timer?.invalidate()
        timer = nil
        syncTime()
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
        timer?.invalidate()
        timer = nil
        currentTime = 0
        duration = 0
    }

    nonisolated func audioPlayerDidFinishPlaying(
        _ player: AVAudioPlayer,
        successfully flag: Bool
    ) {
        Task { @MainActor [weak self] in
            self?.isPlaying = false
            self?.timer?.invalidate()
            self?.timer = nil
            self?.syncTime()
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.syncTime()
            }
        }
    }

    private func syncTime() {
        currentTime = player?.currentTime ?? currentTime
    }
}

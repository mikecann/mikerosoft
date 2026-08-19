import AppKit

/// Keeps sounding until the user explicitly acknowledges that the take failed.
/// A capture failure is expensive, so this deliberately interrupts everything.
@MainActor
final class CriticalRecordingAlarm {
    static let shared = CriticalRecordingAlarm()

    private var timer: Timer?
    private var attentionRequest: Int?
    private var alarmCount = 0

    func start() {
        stop()
        NSApplication.shared.activate(ignoringOtherApps: true)
        attentionRequest = NSApplication.shared.requestUserAttention(.criticalRequest)
        soundAlarm()

        let timer = Timer(timeInterval: 0.8, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.soundAlarm()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let attentionRequest {
            NSApplication.shared.cancelUserAttentionRequest(attentionRequest)
        }
        attentionRequest = nil
        alarmCount = 0
    }

    private func soundAlarm() {
        alarmCount += 1
        // Alternate two unmistakable system alarm sounds. NSSound.beep is the
        // fallback if a named system sound is unavailable on this macOS build.
        let name = alarmCount.isMultiple(of: 2) ? "Sosumi" : "Basso"
        if let sound = NSSound(named: NSSound.Name(name)) {
            sound.play()
        } else {
            NSSound.beep()
        }
    }
}

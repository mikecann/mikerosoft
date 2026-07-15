import Foundation

enum TaskbarPerformanceDiagnostics {
    @discardableResult
    static func measure<T>(_ name: String, threshold: TimeInterval, _ work: () -> T) -> T {
        let startedAt = DispatchTime.now()
        let result = work()
        logIfSlow(name, startedAt: startedAt, threshold: threshold)
        return result
    }

    static func logIfSlow(_ name: String, startedAt: DispatchTime, threshold: TimeInterval) {
        let elapsed = elapsedSeconds(since: startedAt)
        guard elapsed >= threshold else { return }
        log("performance slow \(name) \(formatMilliseconds(elapsed))")
    }

    static func formatMilliseconds(_ seconds: TimeInterval) -> String {
        "\(Int((seconds * 1000).rounded()))ms"
    }

    private static func elapsedSeconds(since startedAt: DispatchTime) -> TimeInterval {
        TimeInterval(DispatchTime.now().uptimeNanoseconds - startedAt.uptimeNanoseconds) / 1_000_000_000
    }
}

final class MainThreadWatchdog {
    private let queue = DispatchQueue(label: "mikerosoft.taskbar.main-thread-watchdog", qos: .userInitiated)
    private let interval: TimeInterval
    private let threshold: TimeInterval
    private var timer: DispatchSourceTimer?
    private var isWaitingForMainThread = false

    init(interval: TimeInterval = 0.1, threshold: TimeInterval = 0.25) {
        self.interval = interval
        self.threshold = threshold
    }

    func start() {
        queue.async {
            guard self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + self.interval, repeating: self.interval)
            timer.setEventHandler { [weak self] in
                self?.pingMainThread()
            }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.async {
            self.timer?.cancel()
            self.timer = nil
            self.isWaitingForMainThread = false
        }
    }

    private func pingMainThread() {
        guard !isWaitingForMainThread else { return }
        isWaitingForMainThread = true
        let sentAt = DispatchTime.now()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            TaskbarPerformanceDiagnostics.logIfSlow(
                "main-thread-stall",
                startedAt: sentAt,
                threshold: self.threshold
            )
            self.queue.async {
                self.isWaitingForMainThread = false
            }
        }
    }
}

import AppKit
import QuartzCore

/// Runs some drawing work at most once per frame of the screen a view is
/// on: at the end of the current run loop turn when the last run was a
/// frame or more ago, otherwise when the next frame is due. Requests made
/// together run once.
///
/// A mouse reports 125 times a second and the screen shows 60 frames. A
/// timeline that redrew for every report drew frames nobody saw, and each
/// one waited for the screen to let go of the frame before it.
@MainActor
final class FramePacer {
    private weak var view: NSView?
    private let work: () -> Void
    private var lastRun: CFTimeInterval = -.infinity
    private var scheduled = false

    init(view: NSView, work: @escaping () -> Void) {
        self.view = view
        self.work = work
    }

    /// Asks for the work to run: this turn if a frame has gone by since it
    /// last ran, otherwise when one has.
    func request() {
        guard !scheduled else { return }
        scheduled = true
        let wait = lastRun + frameInterval * 0.95 - CACurrentMediaTime()
        if wait <= 0 {
            // Later this turn, so everything asked for now runs together
            // before the frame is drawn.
            RunLoop.main.perform(inModes: [.common]) { MainActor.assumeIsolated { self.run() } }
        } else {
            let timer = Timer(timeInterval: wait, repeats: false) { _ in MainActor.assumeIsolated { self.run() } }
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func run() {
        guard scheduled else { return }
        scheduled = false
        lastRun = CACurrentMediaTime()
        work()
    }

    /// How often the view's screen shows a new frame.
    private var frameInterval: CFTimeInterval {
        let interval = view?.window?.screen?.minimumRefreshInterval ?? 0
        return interval > 0 ? interval : 1.0 / 60
    }
}

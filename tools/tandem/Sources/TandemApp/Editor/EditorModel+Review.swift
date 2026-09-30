import Foundation
import TandemCore

/// Reviewing what agents changed: stepping the playhead from one changed
/// stretch to the next, and marking them all reviewed.
extension EditorModel {
    /// Moves the playhead to the start of the next (or previous) change an
    /// agent made and scrolls it into view. False when there's none that
    /// way, which beeps.
    @discardableResult
    func goToAgentChange(forward: Bool) -> Bool {
        let now = playback.time
        guard let stop = forward ? review.stop(after: now) : review.stop(before: now) else {
            if review.stops.isEmpty {
                show(.info, "No agent changes to review.")
            } else {
                show(.info, forward ? "No more agent changes after the playhead." : "No agent changes before the playhead.")
            }
            return false
        }
        playback.pause()
        playback.seek(to: stop.time)
        timeline.bringIntoView(stop.time)
        if let latest = stop.edits.last {
            let others = stop.edits.count > 1 ? " and \(stop.edits.count - 1) more" : ""
            show(.info, "\(ActivityLog.displayName(latest.author)): \(latest.label)\(others)")
        }
        return true
    }

    /// Mike has seen what the agents changed: the log starts again empty
    /// and the highlights go.
    @discardableResult
    func markAgentChangesReviewed() -> Bool {
        guard !reviewLog.isEmpty else {
            show(.info, "No agent edits to review.")
            return false
        }
        let count = review.editCount
        session.review.markReviewed()
        reviewChanged(ReviewLog())
        show(.info, count == 1 ? "Marked 1 agent edit reviewed." : "Marked \(count) agent edits reviewed.")
        return true
    }
}

extension TimelineViewState {
    /// Scrolls `time` into view when it isn't showing, a quarter of the way
    /// in, so what follows it shows too.
    func bringIntoView(_ time: Time) {
        let x = scale.x(time)
        guard x < 0 || x > lanesWidth * 0.85 else { return }
        scale.scrollSeconds = max(0, time.seconds - Double(lanesWidth * 0.25) / scale.pixelsPerSecond)
    }
}

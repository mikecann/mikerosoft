import Foundation
import TandemCore

/// Times that drags and drops snap to: clip edges, the playhead, markers
/// and the in and out points.
struct SnapTargets: Equatable {
    /// Sorted, without duplicates.
    private(set) var times: [Time]

    init(_ times: [Time]) {
        self.times = Array(Set(times)).sorted()
    }

    /// Everything worth snapping to in `project`, leaving out the clips
    /// being dragged so a clip never snaps to itself.
    static func collect(
        in project: Project,
        excluding clipIDs: Set<String> = [],
        playhead: Time? = nil,
        inPoint: Time? = nil,
        outPoint: Time? = nil
    ) -> SnapTargets {
        var times: [Time] = [.zero]
        for track in project.allTracks {
            for clip in track.clips where !clipIDs.contains(clip.id) {
                times.append(clip.start)
                times.append(clip.end)
            }
        }
        times += project.markers.flatMap { [$0.time, $0.time + $0.duration] }
        times += [playhead, inPoint, outPoint].compactMap { $0 }
        return SnapTargets(times)
    }

    /// The nearest target within `tolerance` of `time`.
    func nearest(to time: Time, within tolerance: Time) -> Time? {
        guard !times.isEmpty else { return nil }
        // Binary search for the first target at or after `time`.
        var low = 0
        var high = times.count
        while low < high {
            let mid = (low + high) / 2
            if times[mid] < time { low = mid + 1 } else { high = mid }
        }
        var best: Time?
        for index in [low - 1, low] where times.indices.contains(index) {
            let candidate = times[index]
            let distance = abs(candidate.flicks - time.flicks)
            guard distance <= tolerance.flicks else { continue }
            if let current = best, abs(current.flicks - time.flicks) <= distance { continue }
            best = candidate
        }
        return best
    }

    /// For something moving by `delta` whose snappable edges are `edges`
    /// (for a clip, its start and end), the delta that lands the nearest
    /// edge on a target. Returns nil when nothing is in reach.
    func snappedDelta(_ delta: Time, edges: [Time], within tolerance: Time) -> (delta: Time, target: Time)? {
        var best: (delta: Time, target: Time, distance: Int64)?
        for edge in edges {
            let moved = edge + delta
            guard let target = nearest(to: moved, within: tolerance) else { continue }
            let distance = abs(target.flicks - moved.flicks)
            if best == nil || distance < best!.distance {
                best = (delta + (target - moved), target, distance)
            }
        }
        return best.map { ($0.delta, $0.target) }
    }
}

import Foundation
import TandemCore
import TandemMedia

/// Finds the long pauses in the take from its transcript and cuts them out
/// with ripple deletes, so the camera, screen and voice stay in sync and
/// B-roll and music follow.
enum PauseTightening {
    /// Timeline ranges to remove: gaps between words longer than `minimum`,
    /// less `keep` of breathing room on each side, only inside `within` if
    /// given. Sorted and merged.
    static func ranges(
        in project: Project,
        transcript: (MediaItem) -> Transcript?,
        minimum: Time,
        keep: Time,
        within: TimeRange? = nil
    ) -> [TimeRange] {
        var ranges: [TimeRange] = []
        for track in project.audioTracks where track.rippleMode == .cut && !track.locked {
            for clip in track.clips {
                guard let item = clip.mediaID.flatMap({ project.media($0) }), let words = transcript(item)?.words, words.count > 1 else { continue }
                let inside = words.filter { $0.end > clip.sourceStart && $0.start < clip.sourceEnd }.sorted { $0.start < $1.start }
                for (a, b) in zip(inside, inside.dropFirst()) {
                    guard b.start - a.end >= minimum else { continue }
                    let start = a.end + keep
                    let end = b.start - keep
                    guard end > start else { continue }
                    let timelineStart = clip.start + Time(seconds: (start - clip.sourceStart).seconds / clip.speed)
                    let timelineEnd = clip.start + Time(seconds: (end - clip.sourceStart).seconds / clip.speed)
                    var range = TimeRange(start: max(timelineStart, clip.start), end: min(timelineEnd, clip.end))
                    range.start = range.start.roundedToFrame(project.settings.frameRate)
                    range.duration = (range.end.roundedToFrame(project.settings.frameRate)) - range.start
                    if let within {
                        guard let clipped = range.intersection(within) else { continue }
                        range = clipped
                    }
                    if !range.isEmpty { ranges.append(range) }
                }
            }
        }
        return TimeRange.union(ranges)
    }

    /// One batch cutting every range, latest first so earlier ranges don't
    /// move under later cuts.
    static func batch(_ ranges: [TimeRange]) -> EditBatch? {
        guard !ranges.isEmpty else { return nil }
        let total = ranges.reduce(0) { $0 + $1.duration.seconds }
        return EditBatch(
            label: String(format: "Tighten %d %@ (%.1f s)", ranges.count, ranges.count == 1 ? "pause" : "pauses", total),
            commands: ranges.sorted { $0.start > $1.start }.map { .rippleDeleteRange(range: $0) }
        )
    }
}

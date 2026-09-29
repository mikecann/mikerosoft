import Foundation
import TandemAPI
import TandemCore
import TandemMedia

/// Finds the long pauses in the take from its transcript and cuts them out
/// with ripple deletes, so the camera, screen and voice stay in sync and
/// B-roll and music follow.
enum PauseTightening {
    /// Timeline ranges to remove: pauses between words longer than
    /// `minimum` (found the way `tandem pauses` finds them, from words
    /// trimmed to the voice and placed through the cuts), less `keep` of
    /// breathing room on each side, only inside `within` if given. Sorted
    /// and merged. Locked tracks aren't tightened, so their words don't
    /// count.
    static func ranges(
        in project: Project,
        transcript: (MediaItem) -> Transcript?,
        minimum: Time,
        keep: Time,
        within: TimeRange? = nil
    ) -> [TimeRange] {
        var unlocked = project
        for index in unlocked.audioTracks.indices where unlocked.audioTracks[index].locked {
            unlocked.audioTracks[index].clips = []
        }
        let map = TranscriptTools.speechMap(unlocked, transcripts: transcript)
        let frameRate = project.settings.frameRate
        var ranges: [TimeRange] = []
        for pause in TranscriptTools.pauses(in: map, minimum: minimum) {
            let start = (pause.start + keep).roundedToFrame(frameRate)
            let end = (pause.end - keep).roundedToFrame(frameRate)
            guard end > start else { continue }
            var range = TimeRange(start: start, end: end)
            if let within {
                guard let clipped = range.intersection(within) else { continue }
                range = clipped
            }
            if !range.isEmpty { ranges.append(range) }
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

import Foundation
import TandemCore

/// A transcript word where a clip plays it on the timeline.
public struct PlacedWord: Equatable, Sendable {
    /// The word's index in the transcript.
    public var index: Int
    public var clipID: String
    /// Timeline times, inside the clip.
    public var start: Time
    public var end: Time

    public init(index: Int, clipID: String, start: Time, end: Time) {
        self.index = index
        self.clipID = clipID
        self.start = start
        self.end = end
    }
}

extension Transcript {
    /// Where one track's clips play this transcript's words, in timeline
    /// order. The one rule for words and cuts, used by everything that shows
    /// words on the timeline (captions, pauses, tighten, search, the
    /// transcript lane):
    ///
    /// - A word plays once, on the clip that plays most of it (the earlier
    ///   one on a tie), clamped to that clip. A cut made in a pause next to
    ///   a word used to leave a sliver of it on the other side too, and it
    ///   showed twice.
    /// - A word with less than half of it left on the timeline was cut, so
    ///   it doesn't show at all.
    /// - A clip that plays most of a word again (the same stretch of the
    ///   file used twice) shows it again.
    ///
    /// Shares are measured in media time, so a clip's speed doesn't change
    /// how much of a word it keeps; it only squeezes where the word lands.
    ///
    /// - Parameter clips: the clips of one track that play this
    ///   transcript's file, in any order. Freeze frames and clips that don't
    ///   play forwards are skipped.
    public func placements(on clips: [Clip]) -> [PlacedWord] {
        let playing = clips.filter { !$0.freezeFrame && $0.speed > 0 && $0.duration > .zero }
        guard !playing.isEmpty, !words.isEmpty else { return [] }
        let order = playing.indices.sorted { (playing[$0].start, $0) < (playing[$1].start, $1) }
        var rank = [Int](repeating: 0, count: playing.count)
        for (position, clipIndex) in order.enumerated() { rank[clipIndex] = position }
        // The latest end of any word before each index, so a search can step
        // back past a long word that starts earlier (the engine's words can
        // overlap a little).
        var latestEnd = [Time](repeating: .zero, count: words.count + 1)
        latestEnd[0] = Time(flicks: .min)
        for (index, word) in words.enumerated() { latestEnd[index + 1] = max(latestEnd[index], word.end) }
        let sorted = zip(words, words.dropFirst()).allSatisfy { $0.start <= $1.start }

        var shares: [Int: [(clip: Int, from: Time, to: Time)]] = [:]
        for clipIndex in order {
            let clip = playing[clipIndex]
            let low = clip.sourceStart
            let high = clip.sourceEnd
            var index = 0
            if sorted {
                index = Self.firstIndex(of: words, startingAtOrAfter: low)
                while index > 0, latestEnd[index] > low { index -= 1 }
            }
            while index < words.count {
                let word = words[index]
                if sorted, word.start >= high { break }
                let end = Self.effectiveEnd(word)
                let from = max(word.start, low)
                let to = min(end, high)
                if to > from { shares[index, default: []].append((clipIndex, from, to)) }
                index += 1
            }
        }

        var placed: [PlacedWord] = []
        for index in shares.keys.sorted() {
            let parts = shares[index]!
            let word = words[index]
            let length = Self.effectiveEnd(word) - word.start
            // How much of the word plays anywhere on the track, counting a
            // stretch played twice once.
            let kept = TimeRange.union(parts.map { TimeRange(start: $0.from, end: $0.to) }).reduce(Time.zero) { $0 + $1.duration }
            guard kept.flicks * 2 >= length.flicks else { continue }
            let home = parts.max { a, b in
                let lengthA = a.to - a.from
                let lengthB = b.to - b.from
                if lengthA != lengthB { return lengthA < lengthB }
                // On a tie the earlier clip wins, so it must compare larger.
                return rank[a.clip] > rank[b.clip]
            }!
            for part in parts where part.clip == home.clip || (part.to - part.from).flicks * 2 > length.flicks {
                let clip = playing[part.clip]
                let start = Self.timelineTime(part.from, in: clip)
                let end = min(Self.timelineTime(part.to, in: clip), clip.end)
                placed.append(PlacedWord(index: index, clipID: clip.id, start: start, end: max(start, end)))
            }
        }
        placed.sort { ($0.start, $0.end, $0.index) < ($1.start, $1.end, $1.index) }
        return placed
    }

    /// Where media time `media` plays on the timeline in `clip`.
    static func timelineTime(_ media: Time, in clip: Clip) -> Time {
        clip.start + Time(seconds: (media - clip.sourceStart).seconds / clip.speed)
    }

    /// A word with no length still takes up a moment, so a clip can hold it.
    static func effectiveEnd(_ word: TranscriptWord) -> Time {
        max(word.end, word.start + Time(flicks: 1))
    }

    /// The first word whose start is at or after `time` (words sorted by start).
    static func firstIndex(of words: [TranscriptWord], startingAtOrAfter time: Time) -> Int {
        var low = 0
        var high = words.count
        while low < high {
            let middle = (low + high) / 2
            if words[middle].start < time { low = middle + 1 } else { high = middle }
        }
        return low
    }
}

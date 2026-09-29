import Foundation
import TandemCore
import TandemMedia

/// Transcript maths: mapping words from media time onto the timeline,
/// finding phrases, finding pauses and planning how to tighten them.
///
/// Transcripts are in media time (seconds into the file), with their word
/// edges pulled in to the voice when they're read (`TranscriptAlignment`).
/// A clip plays media from `sourceStart` at `speed`, so a word at media time
/// `m` plays at `clip.start + (m - sourceStart) / speed`, if the clip reaches
/// it. Which clip shows a word a cut runs through follows one rule,
/// `Transcript.placements(on:)`: the clip that plays most of it, and none
/// when less than half of it is left.
public enum TranscriptTools {
    public static let defaultMinimum = 0.6
    public static let defaultKeep = 0.15

    /// A word as it plays on the timeline.
    public struct SpokenWord: Equatable, Sendable {
        public var text: String
        public var start: Time
        public var end: Time
        public var clipID: String
        public var mediaID: String
        public var confidence: Double?
    }

    /// Everything said on the speech tracks, in timeline order.
    public struct SpeechMap: Sendable {
        public var words: [SpokenWord]
        /// Timeline ranges covered by speech clips with a transcript.
        public var covered: [TimeRange]
        /// Timeline ranges of speech clips whose transcript isn't ready, where
        /// nobody knows yet what's said.
        public var unknown: [TimeRange]
        /// Media IDs whose transcripts aren't ready.
        public var missing: [String]
        /// Speech clips with their track, for naming clips under a pause.
        public var clips: [Clip]
    }

    /// The tracks that carry dialogue: unmuted audio tracks that ripple as
    /// part of the take (Voice). Falls back to every unmuted audio track.
    public static func speechTracks(_ project: Project) -> [Track] {
        let audio = project.audioTracks.filter { !$0.muted }
        let take = audio.filter { $0.rippleMode == .cut }
        return take.isEmpty ? audio : take
    }

    public static func timelineTime(ofMediaTime media: Time, in clip: Clip) -> Time {
        clip.start + Time(seconds: (media - clip.sourceStart).seconds / clip.speed)
    }

    /// Whether a clip's sound is heard: enabled, not muted, not a freeze.
    static func isHeard(_ clip: Clip) -> Bool {
        clip.enabled && !(clip.audio?.muted ?? false) && !clip.freezeFrame
    }

    /// The words of `transcript` that `clips` play, in timeline order.
    /// `clips` are one track's clips of the transcript's file; a word shows
    /// once, on the clip that plays most of it, clamped to that clip, and not
    /// at all when less than half of it is left (`Transcript.placements(on:)`).
    public static func words(_ transcript: Transcript, playedBy clips: [Clip], mediaID: String) -> [SpokenWord] {
        transcript.placements(on: clips).map { placed in
            let word = transcript.words[placed.index]
            return SpokenWord(
                text: word.text, start: placed.start, end: placed.end,
                clipID: placed.clipID, mediaID: mediaID, confidence: word.confidence
            )
        }
    }

    /// The words one clip plays, placed among the clips of `track` that play
    /// the same file, so a word a cut runs through shows on one side only.
    public static func words(_ transcript: Transcript, playedBy clip: Clip, on track: Track) -> [SpokenWord] {
        guard let mediaID = clip.mediaID else { return [] }
        let siblings = track.clips.filter { $0.mediaID == mediaID && ($0.id == clip.id || isHeard($0)) }
        return words(transcript, playedBy: siblings, mediaID: mediaID).filter { $0.clipID == clip.id }
    }

    public static func speechMap(_ project: Project, analysis: AnalysisSource) -> SpeechMap {
        speechMap(project) { analysis.transcript(for: $0) }
    }

    public static func speechMap(_ project: Project, transcripts: (MediaItem) -> Transcript?) -> SpeechMap {
        var words: [SpokenWord] = []
        var covered: [TimeRange] = []
        var unknown: [TimeRange] = []
        var missing = Set<String>()
        var clips: [Clip] = []
        var cache: [String: Transcript?] = [:]
        for track in speechTracks(project) {
            // Each file's words are placed among all of its clips on the
            // track at once, so a cut between two of them shows a word once.
            var byMedia: [String: [Clip]] = [:]
            var order: [String] = []
            for clip in track.clips where isHeard(clip) {
                guard let mediaID = clip.mediaID, project.media(mediaID) != nil else { continue }
                clips.append(clip)
                if byMedia[mediaID] == nil { order.append(mediaID) }
                byMedia[mediaID, default: []].append(clip)
            }
            for mediaID in order {
                guard let item = project.media(mediaID), let group = byMedia[mediaID] else { continue }
                let transcript: Transcript?
                if let cached = cache[mediaID] {
                    transcript = cached
                } else {
                    transcript = transcripts(item)
                    cache[mediaID] = transcript
                }
                guard let transcript else {
                    missing.insert(mediaID)
                    unknown += group.map(\.range)
                    continue
                }
                covered += group.map(\.range)
                words += Self.words(transcript, playedBy: group, mediaID: mediaID)
            }
        }
        words.sort { ($0.start, $0.end) < ($1.start, $1.end) }
        return SpeechMap(
            words: words,
            covered: TimeRange.union(covered),
            unknown: TimeRange.union(unknown),
            missing: missing.sorted(),
            clips: clips
        )
    }

    // MARK: - Pauses

    /// Silences between words of at least `minimum`, in timeline time. A gap
    /// only counts when speech clips with transcripts cover all of it: a hole
    /// in the take, or a clip whose transcript isn't ready, isn't a pause.
    public static func pauses(in map: SpeechMap, minimum: Time, from: Time? = nil, to: Time? = nil) -> [Pause] {
        var result: [Pause] = []
        var lastEnd: Time?
        for (index, word) in map.words.enumerated() {
            defer { lastEnd = max(lastEnd ?? word.end, word.end) }
            guard let previousEnd = lastEnd, word.start - previousEnd >= minimum else { continue }
            let gap = TimeRange(start: previousEnd, end: word.start)
            if let from, gap.start < from { continue }
            if let to, gap.end > to { continue }
            guard isCovered(gap, map) else { continue }
            let under = map.clips.filter { $0.range.overlaps(gap) }.map(\.id)
            result.append(Pause(
                start: gap.start,
                end: gap.end,
                duration: gap.duration,
                before: context(map.words, upTo: index),
                after: context(map.words, from: index),
                clipIDs: under
            ))
        }
        return result
    }

    static func isCovered(_ gap: TimeRange, _ map: SpeechMap) -> Bool {
        guard map.covered.contains(where: { $0.start <= gap.start && gap.end <= $0.end }) else { return false }
        return !map.unknown.contains { $0.overlaps(gap) }
    }

    static func context(_ words: [SpokenWord], upTo index: Int, count: Int = 4) -> String {
        words[max(0, index - count)..<index].map(\.text).joined(separator: " ")
    }

    static func context(_ words: [SpokenWord], from index: Int, count: Int = 4) -> String {
        words[index..<min(words.count, index + count)].map(\.text).joined(separator: " ")
    }

    // MARK: - Tightening

    /// Shortens each pause to `keep`, cutting from the middle so half the
    /// kept silence stays after the last word and half before the next one.
    /// Cut edges are rounded inwards to frame boundaries, so the kept
    /// silence is never shorter than `keep`. Pauses that would lose less
    /// than a frame are left alone.
    public static func plan(_ pauses: [Pause], keep: Time, frameRate: FrameRate) -> [PlannedCut] {
        let half = Time(flicks: keep.flicks / 2)
        let rest = keep - half
        return pauses.compactMap { pause in
            let start = TimeText.ceilToFrame(pause.start + half, frameRate)
            let end = TimeText.floorToFrame(pause.end - rest, frameRate)
            guard end - start >= frameRate.frameDuration else { return nil }
            return PlannedCut(pause: pause, cut: TimeRange(start: start, end: end))
        }
    }

    /// `rippleDeleteRange` commands for a plan, latest first so every range
    /// is still in the current timeline's times when it runs.
    public static func commands(for cuts: [PlannedCut]) -> [EditCommand] {
        cuts.sorted { $0.cut.start > $1.cut.start }.map { .rippleDeleteRange(range: $0.cut, trackIDs: nil) }
    }

    // MARK: - Search

    /// Lower-case words with punctuation removed, so "Don't," matches "dont".
    public static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
            .split { !($0.isLetter || $0.isNumber) }
            .map(String.init)
    }

    /// Where `phrase` occurs in a transcript: ranges of word indices.
    public static func matches(of phrase: String, in transcript: Transcript) -> [ClosedRange<Int>] {
        let wanted = tokens(phrase)
        guard !wanted.isEmpty else { return [] }
        var stream: [(token: String, word: Int)] = []
        for (index, word) in transcript.words.enumerated() {
            for token in tokens(word.text) { stream.append((token, index)) }
        }
        guard stream.count >= wanted.count else { return [] }
        var result: [ClosedRange<Int>] = []
        var i = 0
        while i <= stream.count - wanted.count {
            if (0..<wanted.count).allSatisfy({ stream[i + $0].token == wanted[$0] }) {
                let range = stream[i].word...stream[i + wanted.count - 1].word
                if result.last != range { result.append(range) }
                i += wanted.count
            } else {
                i += 1
            }
        }
        return result
    }

    public static func search(
        _ phrase: String,
        in project: Project,
        analysis: AnalysisSource
    ) -> (hits: [SearchHit], unused: [UnusedHit], missing: [String]) {
        var hits: [SearchHit] = []
        var unused: [UnusedHit] = []
        var missing: [String] = []
        let speechMedia = Set(speechTracks(project).flatMap(\.clips).compactMap(\.mediaID))
        for item in project.media where item.hasAudio {
            guard let transcript = analysis.transcript(for: item) else {
                if speechMedia.contains(item.id) { missing.append(item.id) }
                continue
            }
            let found = matches(of: phrase, in: transcript)
            guard !found.isEmpty else { continue }
            // Where each word plays, track by track (the camera picture and
            // its sound both play it), by the same rule as everything else.
            var placed: [Int: [PlacedWord]] = [:]
            var rank: [String: Int] = [:]
            for track in project.allTracks {
                let clips = track.clips.filter { $0.mediaID == item.id }
                for clip in clips { rank[clip.id] = rank.count }
                for word in transcript.placements(on: clips) { placed[word.index, default: []].append(word) }
            }
            let words = transcript.words
            for match in found {
                let mediaStart = words[match.lowerBound].start
                let mediaEnd = words[match.upperBound].end
                let text = words[match].map(\.text).joined(separator: " ")
                let before = words[max(0, match.lowerBound - 4)..<match.lowerBound].map(\.text).joined(separator: " ")
                let after = words[(match.upperBound + 1)..<min(words.count, match.upperBound + 5)].map(\.text).joined(separator: " ")
                // The phrase's words on each clip: a cut through the phrase
                // leaves part of it on each side, each marked partial.
                var byClip: [String: (start: Time, end: Time, count: Int)] = [:]
                for index in match {
                    for word in placed[index] ?? [] {
                        if let entry = byClip[word.clipID] {
                            byClip[word.clipID] = (min(entry.start, word.start), max(entry.end, word.end), entry.count + 1)
                        } else {
                            byClip[word.clipID] = (word.start, word.end, 1)
                        }
                    }
                }
                if byClip.isEmpty {
                    unused.append(UnusedHit(
                        mediaID: item.id, path: item.path, text: text,
                        mediaStart: mediaStart, mediaEnd: mediaEnd, before: before, after: after
                    ))
                }
                var byRange: [TimeRange: (clipIDs: [String], partial: Bool)] = [:]
                for clipID in byClip.keys.sorted(by: { rank[$0, default: 0] < rank[$1, default: 0] }) {
                    let entry = byClip[clipID]!
                    let range = TimeRange(start: entry.start, end: entry.end)
                    var hit = byRange[range] ?? ([], false)
                    hit.clipIDs.append(clipID)
                    hit.partial = hit.partial || entry.count < match.count
                    byRange[range] = hit
                }
                for (range, entry) in byRange {
                    hits.append(SearchHit(
                        text: text, start: range.start, end: range.end, clipIDs: entry.clipIDs,
                        mediaID: item.id, mediaStart: mediaStart, mediaEnd: mediaEnd,
                        partial: entry.partial, before: before, after: after
                    ))
                }
            }
        }
        hits.sort { ($0.start, $0.end) < ($1.start, $1.end) }
        unused.sort { ($0.mediaID, $0.mediaStart) < ($1.mediaID, $1.mediaStart) }
        return (hits, unused, missing.sorted())
    }
}

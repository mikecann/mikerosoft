import Foundation
import TandemCore
import TandemMedia

/// Transcript maths: mapping words from media time onto the timeline,
/// finding phrases, finding pauses and planning how to tighten them.
///
/// Transcripts are in media time (seconds into the file). A clip plays media
/// from `sourceStart` at `speed`, so a word at media time `m` plays at
/// `clip.start + (m - sourceStart) / speed`, if the clip reaches it.
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

    /// The words of `transcript` that `clip` plays, clamped to the clip and
    /// mapped to timeline time.
    public static func words(_ transcript: Transcript, playedBy clip: Clip) -> [SpokenWord] {
        guard !clip.freezeFrame, clip.speed > 0, let mediaID = clip.mediaID else { return [] }
        let sourceStart = clip.sourceStart
        let sourceEnd = clip.sourceEnd
        return transcript.words.compactMap { word in
            guard word.end > sourceStart, word.start < sourceEnd else { return nil }
            let start = max(word.start, sourceStart)
            let end = min(word.end, sourceEnd)
            return SpokenWord(
                text: word.text,
                start: timelineTime(ofMediaTime: start, in: clip),
                end: timelineTime(ofMediaTime: end, in: clip),
                clipID: clip.id,
                mediaID: mediaID,
                confidence: word.confidence
            )
        }
    }

    public static func speechMap(_ project: Project, analysis: AnalysisSource) -> SpeechMap {
        var words: [SpokenWord] = []
        var covered: [TimeRange] = []
        var unknown: [TimeRange] = []
        var missing = Set<String>()
        var clips: [Clip] = []
        var cache: [String: Transcript?] = [:]
        for track in speechTracks(project) {
            for clip in track.clips where clip.enabled && !(clip.audio?.muted ?? false) {
                guard let mediaID = clip.mediaID, let item = project.media(mediaID), !clip.freezeFrame else { continue }
                clips.append(clip)
                let transcript: Transcript?
                if let cached = cache[mediaID] {
                    transcript = cached
                } else {
                    transcript = analysis.transcript(for: item)
                    cache[mediaID] = transcript
                }
                guard let transcript else {
                    missing.insert(mediaID)
                    unknown.append(clip.range)
                    continue
                }
                covered.append(clip.range)
                words += Self.words(transcript, playedBy: clip)
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
        let clips = project.allTracks.flatMap(\.clips).filter { $0.mediaID != nil && !$0.freezeFrame && $0.speed > 0 }
        let speechMedia = Set(speechTracks(project).flatMap(\.clips).compactMap(\.mediaID))
        for item in project.media where item.hasAudio {
            guard let transcript = analysis.transcript(for: item) else {
                if speechMedia.contains(item.id) { missing.append(item.id) }
                continue
            }
            for match in matches(of: phrase, in: transcript) {
                let words = transcript.words
                let mediaStart = words[match.lowerBound].start
                let mediaEnd = words[match.upperBound].end
                let text = words[match].map(\.text).joined(separator: " ")
                let before = words[max(0, match.lowerBound - 4)..<match.lowerBound].map(\.text).joined(separator: " ")
                let after = words[(match.upperBound + 1)..<min(words.count, match.upperBound + 5)].map(\.text).joined(separator: " ")
                var byRange: [TimeRange: (clipIDs: [String], partial: Bool)] = [:]
                for clip in clips where clip.mediaID == item.id && clip.sourceEnd > mediaStart && clip.sourceStart < mediaEnd {
                    let start = max(mediaStart, clip.sourceStart)
                    let end = min(mediaEnd, clip.sourceEnd)
                    let range = TimeRange(
                        start: timelineTime(ofMediaTime: start, in: clip),
                        end: timelineTime(ofMediaTime: end, in: clip)
                    )
                    let partial = start > mediaStart || end < mediaEnd
                    var entry = byRange[range] ?? ([], false)
                    entry.clipIDs.append(clip.id)
                    entry.partial = entry.partial || partial
                    byRange[range] = entry
                }
                if byRange.isEmpty {
                    unused.append(UnusedHit(
                        mediaID: item.id, path: item.path, text: text,
                        mediaStart: mediaStart, mediaEnd: mediaEnd, before: before, after: after
                    ))
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

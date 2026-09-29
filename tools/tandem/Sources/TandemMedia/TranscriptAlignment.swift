import Foundation
import TandemCore

/// Pulls transcript word times in to the voice, using the take's cached
/// waveform (the loudest sample in each 10 ms, over all channels).
///
/// SpeechAnalyzer times its words end to end, so each pause is swallowed by
/// the word before it or the word after it. On the workbench short's phone
/// take "of" ran from 28.14 to 29.22 s while the audio was silent from 28.26
/// to 29.05, so `pauses` saw 4 of the take's 16 pauses over 0.45 s, and a
/// cut made in a pause landed inside a word, which then showed on both
/// sides of it.
///
/// The pass:
///
/// 1. The take's noise floor (its quietest tenth) sets a threshold 10 dB
///    over it, never more than 30 dB under its loud tenth. That's where
///    ffmpeg's silencedetect at -32 dB sat on the phone take: the waveform
///    finds the same 45 silences of 0.2 s or more, to 10 ms.
/// 2. Silences are 100 ms or more under the threshold; voiced runs are
///    what's between them. Flicker around the threshold (gaps of 20 ms or
///    less) counts as voice, and a blip under 40 ms (a click) doesn't.
/// 3. Each word goes to one run, the one its own time range overlaps most.
///    After a word that ends a sentence or clause the pause belongs before
///    the next word, so that word leans to the run after a silence it
///    straddles (SpeechAnalyzer's punctuation comes from those pauses).
///    Words keep their order.
/// 4. Each run's words fill it from its first voiced moment to its last,
///    keeping the engine's boundaries between them where those fall inside.
///
/// Voiced runs no word lands in (breaths, clicks, the "um"s SpeechAnalyzer
/// leaves out) stay between the words, so they count as part of a pause.
///
/// It runs when a transcript is read (`MediaAnalysis.transcript(for:)`),
/// not when it's made, so transcripts already in a cache get it too and the
/// engine's own times stay on disk (`rawTranscript(for:)`).
public enum TranscriptAlignment {
    /// Bump when the pass changes what it makes (it keys the in-memory copy).
    public static let version = 1

    /// Silence this long or longer separates two voiced runs.
    static let minSilence = 0.1
    /// Quiet gaps this short inside voice are flicker around the threshold.
    static let flicker = 0.02
    /// Voice shorter than this, alone, is a click rather than speech.
    static let minVoice = 0.04
    /// A run a word only grazes by less than this isn't a place for it,
    /// unless the word has nowhere better.
    static let minOverlap = 0.06
    /// How much voice (in seconds) a word after a sentence end gives up to
    /// sit after the pause rather than before it.
    static let sentenceLean = 0.2
    /// The least time a word gets inside its run.
    static let minWord = 0.05
    /// A word with no voice under it moves to a run at most this far away;
    /// further than that it keeps its own times.
    static let reach = 1.0
    /// Coarser waveforms can't place a word edge.
    static let minRate = 50

    /// A stretch of voice, in seconds of media time.
    struct Run: Equatable {
        var start: Double
        var end: Double
    }

    /// `words` with their edges on the voice. `origin` is the media time of
    /// the waveform's first peak (0 for a whole file).
    public static func align(_ words: [TranscriptWord], waveform: Waveform, origin: Double = 0) -> [TranscriptWord] {
        guard !words.isEmpty, waveform.samplesPerSecond >= minRate, waveform.peaks.count >= 20 else { return words }
        let levels = waveform.peaks.map { $0 > 0 ? 20 * log10(Double($0)) : -120 }
        let runs = voicedRuns(levels, rate: Double(waveform.samplesPerSecond), threshold: threshold(levels), origin: origin)
        guard !runs.isEmpty else { return words }
        return place(words, in: runs, assignment: assign(words, to: runs))
    }

    /// 10 dB over the noise floor (the quietest tenth of the take), and
    /// never more than 30 dB under its loud tenth, so digital silence
    /// between takes doesn't drag it down to nothing.
    static func threshold(_ levels: [Double]) -> Double {
        let sorted = levels.sorted()
        guard !sorted.isEmpty else { return -120 }
        let floor = sorted[sorted.count / 10]
        let loud = sorted[min(sorted.count - 1, sorted.count * 9 / 10)]
        return max(floor + 10, loud - 30)
    }

    /// Stretches of the envelope over `threshold`, as media time.
    static func voicedRuns(_ levels: [Double], rate: Double, threshold: Double, origin: Double) -> [Run] {
        func buckets(_ seconds: Double) -> Int { max(1, Int((seconds * rate).rounded())) }
        var spans: [(start: Int, end: Int)] = []
        var index = 0
        while index < levels.count {
            guard levels[index] > threshold else {
                index += 1
                continue
            }
            var end = index
            while end < levels.count, levels[end] > threshold { end += 1 }
            if let last = spans.last, index - last.end <= buckets(flicker) {
                spans[spans.count - 1].end = end
            } else {
                spans.append((index, end))
            }
            index = end
        }
        var runs: [(start: Int, end: Int)] = []
        for span in spans where span.end - span.start >= buckets(minVoice) {
            if let last = runs.last, span.start - last.end < buckets(minSilence) {
                runs[runs.count - 1].end = span.end
            } else {
                runs.append(span)
            }
        }
        return runs.map { Run(start: origin + Double($0.start) / rate, end: origin + Double($0.end) / rate) }
    }

    /// Ends a sentence or clause, so a pause is likely after it.
    static func endsClause(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespaces).last else { return false }
        return ".?!,;:\u{2026}".contains(last)
    }

    /// The run each word goes to, or nil for a word with no run near it
    /// (it keeps its own times). A small dynamic programme over the few
    /// runs each word could go to, so the words stay in order.
    static func assign(_ words: [TranscriptWord], to runs: [Run]) -> [Int?] {
        let starts = runs.map(\.start)
        // The runs each word could go to, with a cost: less is better.
        let options: [[(run: Int, cost: Double)]] = words.map { word in
            let start = word.start.seconds
            // A word with no length still sits somewhere.
            let end = max(word.end.seconds, start + 0.01)
            var overlapping: [(run: Int, cost: Double)] = []
            var index = max(0, upperBound(starts, start) - 1)
            while index < runs.count, runs[index].start < end {
                let overlap = min(end, runs[index].end) - max(start, runs[index].start)
                if overlap > 0 { overlapping.append((index, -overlap)) }
                index += 1
            }
            if !overlapping.isEmpty {
                let real = overlapping.filter { -$0.cost >= minOverlap }
                return real.isEmpty ? [overlapping.min { $0.cost < $1.cost }!] : real
            }
            // No voice under it at all (SpeechAnalyzer often puts the first
            // word of a take in the silence before it): the nearest runs.
            var near: [(run: Int, cost: Double)] = []
            let after = upperBound(starts, start)
            if after < runs.count, runs[after].start - end <= reach { near.append((after, runs[after].start - end)) }
            if after > 0, start - runs[after - 1].end <= reach { near.append((after - 1, start - runs[after - 1].end)) }
            return near
        }

        // best[k][run] = (total cost, the previous aligned word's run).
        var best: [[Int: (cost: Double, previous: Int?)]] = []
        var aligned: [Int] = []
        for (index, choices) in options.enumerated() where !choices.isEmpty {
            var row: [Int: (cost: Double, previous: Int?)] = [:]
            if let before = best.last, let previousWord = aligned.last {
                let lean = previousWord == index - 1 && endsClause(words[previousWord].text) && choices.count > 1
                for choice in choices {
                    var pick: (cost: Double, previous: Int?)?
                    for (run, entry) in before where run <= choice.run {
                        let cost = entry.cost + choice.cost + (lean && run == choice.run ? sentenceLean : 0)
                        if pick == nil || cost < pick!.cost { pick = (cost, run) }
                    }
                    if let pick { row[choice.run] = pick }
                }
                if row.isEmpty {
                    // Every run it could go to is behind the word before
                    // (the engine's times overlap): it joins that word's run.
                    for (run, entry) in before { row[run] = (entry.cost + 1, run) }
                }
            } else {
                for choice in choices { row[choice.run] = (choice.cost, nil) }
            }
            best.append(row)
            aligned.append(index)
        }
        var result = [Int?](repeating: nil, count: words.count)
        guard var run = best.last?.min(by: { $0.value.cost < $1.value.cost || ($0.value.cost == $1.value.cost && $0.key < $1.key) })?.key else { return result }
        for k in stride(from: aligned.count - 1, through: 0, by: -1) {
            result[aligned[k]] = run
            if let previous = best[k][run]?.previous { run = previous }
        }
        return result
    }

    /// Words laid out in their runs. A run's first word starts where the
    /// voice starts and its last ends where the voice ends; between them the
    /// engine's boundaries stay where they fall inside the run, and every
    /// word keeps at least `minWord` (or a share by letters, when the run is
    /// too short for that).
    static func place(_ words: [TranscriptWord], in runs: [Run], assignment: [Int?]) -> [TranscriptWord] {
        var out = words
        var index = 0
        while index < words.count {
            guard let run = assignment[index] else {
                index += 1
                continue
            }
            var members = [index]
            var next = index + 1
            while next < words.count, assignment[next] == nil || assignment[next] == run {
                if assignment[next] == run { members.append(next) }
                next += 1
            }
            let span = runs[run]
            var bounds = [span.start]
            for (a, b) in zip(members, members.dropFirst()) {
                let between = (words[a].end.seconds + words[b].start.seconds) / 2
                bounds.append(min(max(between, bounds.last!), span.end))
            }
            bounds.append(span.end)
            let count = members.count
            if span.end - span.start < Double(count) * minWord {
                let letters = members.map { Double(max(1, words[$0].text.filter { $0.isLetter || $0.isNumber }.count)) }
                let total = letters.reduce(0, +)
                var at = span.start
                for (offset, share) in letters.enumerated() {
                    at += (span.end - span.start) * share / total
                    bounds[offset + 1] = offset + 1 == count ? span.end : at
                }
            } else {
                for k in 1..<count { bounds[k] = max(bounds[k], bounds[k - 1] + minWord) }
                for k in stride(from: count - 1, through: 1, by: -1) { bounds[k] = min(bounds[k], bounds[k + 1] - minWord) }
            }
            for (offset, member) in members.enumerated() {
                out[member].start = Time(seconds: bounds[offset])
                out[member].end = Time(seconds: bounds[offset + 1])
            }
            index = next
        }
        // Words that kept their own times mustn't overlap their neighbours.
        for k in out.indices.dropFirst() {
            if out[k].start < out[k - 1].end { out[k].start = out[k - 1].end }
            if out[k].end < out[k].start { out[k].end = out[k].start }
        }
        return out
    }

    /// The first index whose value is greater than `value`.
    static func upperBound(_ values: [Double], _ value: Double) -> Int {
        var low = 0
        var high = values.count
        while low < high {
            let middle = (low + high) / 2
            if values[middle] <= value { low = middle + 1 } else { high = middle }
        }
        return low
    }
}

extension Transcript {
    /// This transcript with its word edges on the voice (see
    /// `TranscriptAlignment`).
    public func aligned(to waveform: Waveform, origin: Double = 0) -> Transcript {
        var copy = self
        copy.words = TranscriptAlignment.align(words, waveform: waveform, origin: origin)
        return copy
    }
}

import Accelerate
import AVFoundation
import Foundation
import Speech
import TandemCore

/// Word-level transcript with SpeechAnalyzer (macOS 26), word times in media
/// time. The audio streams from the file a second at a time as the analyzer
/// asks for it, so a long take never sits in memory.
enum TranscriptJob {
    static let file = "transcript.json"

    static func run(source: URL, locale: String, into folder: URL, context: JobContext, timeRange: CMTimeRange? = nil) async throws {
        guard #available(macOS 26, *) else {
            throw MediaError.notApplicable("Transcripts need macOS 26 (SpeechAnalyzer)")
        }
        let transcript = try await SpeechTranscription.transcribe(source: source, localeID: locale, context: context, timeRange: timeRange)
        try CacheJSON.write(transcript, to: folder.appendingPathComponent(file))
    }

    static func read(from folder: URL) -> Transcript? {
        CacheJSON.read(Transcript.self, from: folder.appendingPathComponent(file))
    }
}

@available(macOS 26, *)
enum SpeechTranscription {
    static let engine = "SpeechAnalyzer"

    static func transcribe(source: URL, localeID: String, context: JobContext, timeRange: CMTimeRange?) async throws -> Transcript {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: localeID)) else {
            throw MediaError.notApplicable("SpeechAnalyzer doesn't support \(localeID)")
        }
        let status = await AssetInventory.status(forModules: [makeTranscriber(locale)])
        guard status != .unsupported else { throw MediaError.notApplicable("SpeechAnalyzer can't transcribe \(localeID) on this Mac") }
        do {
            return try await attempt(source: source, locale: locale, context: context, timeRange: timeRange)
        } catch let error where status < .installed && !context.isCancelled && !(error is CancellationError) {
            // The model usually works even when the inventory only says
            // "supported"; if it didn't, install it and try once more.
            let transcriber = makeTranscriber(locale)
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                context.progress(0, message: "Installing the \(locale.identifier) speech model")
                try await request.downloadAndInstall()
            }
            return try await attempt(source: source, locale: locale, context: context, timeRange: timeRange)
        }
    }

    static func makeTranscriber(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange, .transcriptionConfidence])
    }

    static func attempt(source: URL, locale: Locale, context: JobContext, timeRange: CMTimeRange?) async throws -> Transcript {
        let transcriber = makeTranscriber(locale)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw MediaError.failed("SpeechAnalyzer has no audio format for \(locale.identifier)")
        }
        let reader = try await AudioReader(url: source, sampleRate: format.sampleRate, channels: Int(format.channelCount), timeRange: timeRange)
        let start = timeRange?.start.seconds ?? 0
        let feed = try AnalyzerFeed(reader: reader, format: format, context: context, origin: start)
        let duration = reader.duration

        let analyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .utility, modelRetention: .lingering))
        let collector = Task { () -> [TranscriptWord] in
            var words: [TranscriptWord] = []
            for try await result in transcriber.results where result.isFinal {
                words += Self.words(in: result.text)
                let end = result.range.end.seconds
                if end.isFinite, duration > 0 { context.progress((end - start) / duration) }
            }
            return words
        }
        do {
            if let last = try await analyzer.analyzeSequence(AnalyzerInputs(feed: feed)) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            await analyzer.cancelAndFinishNow()
            collector.cancel()
            reader.cancel()
            throw error
        }
        let words = try await collector.value
        try context.checkCancellation()
        return Transcript(language: locale.identifier(.bcp47), engine: engine, words: feed.envelope.snap(words))
    }

    /// One word per run with a time range; runs carry their leading space.
    static func words(in text: AttributedString) -> [TranscriptWord] {
        var words: [TranscriptWord] = []
        for run in text.runs {
            guard let range = run.audioTimeRange else { continue }
            let word = String(text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty, range.start.isNumeric, range.end.isNumeric else { continue }
            words.append(TranscriptWord(
                text: word,
                start: Time(range.start),
                end: Time(range.end),
                confidence: run.transcriptionConfidence
            ))
        }
        return words
    }
}

/// Pulls audio from the reader a second at a time, converted to the
/// analyzer's format, each buffer stamped with its media time.
@available(macOS 26, *)
final class AnalyzerFeed: @unchecked Sendable {
    let reader: AudioReader
    let format: AVAudioFormat
    let context: JobContext
    private let chunkFrames: Int
    private var pending: [Float] = []
    private var pendingStart: CMTime?
    private var finished = false
    /// Loudness of the audio as it goes past, to tidy word edges afterwards.
    private(set) var envelope: SpeechEnvelope

    init(reader: AudioReader, format: AVAudioFormat, context: JobContext, origin: Double) throws {
        guard format.channelCount == AVAudioChannelCount(reader.channels) else {
            throw MediaError.failed("Speech audio format mismatch")
        }
        self.reader = reader
        self.format = format
        self.context = context
        chunkFrames = Int(format.sampleRate)
        envelope = SpeechEnvelope(origin: origin, sampleRate: reader.sampleRate)
    }

    func next() throws -> AnalyzerInput? {
        if context.isCancelled {
            reader.cancel()
            return nil
        }
        while !finished, pending.count < chunkFrames * reader.channels {
            let more = try reader.next { samples, _, start in
                if pendingStart == nil || pending.isEmpty { pendingStart = start }
                pending.append(contentsOf: samples)
                if reader.channels == 1 { envelope.add(samples, at: start.seconds) }
            }
            if !more { finished = true }
        }
        guard !pending.isEmpty, let start = pendingStart else { return nil }
        let take = min(pending.count, chunkFrames * reader.channels)
        let frames = take / reader.channels
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            throw MediaError.failed("Out of memory for speech audio")
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        try pending.withUnsafeBufferPointer { samples in
            try Self.convert(samples.baseAddress!, count: take, into: buffer)
        }
        pending.removeFirst(take)
        pendingStart = pending.isEmpty ? nil : start + CMTime(value: CMTimeValue(frames), timescale: CMTimeScale(format.sampleRate))
        return AnalyzerInput(buffer: buffer, bufferStartTime: start)
    }

    static func convert(_ samples: UnsafePointer<Float>, count: Int, into buffer: AVAudioPCMBuffer) throws {
        switch buffer.format.commonFormat {
        case .pcmFormatInt16:
            guard let destination = buffer.int16ChannelData?[0] else { throw MediaError.failed("Speech buffer has no data") }
            var clipped = [Float](repeating: 0, count: count)
            var low: Float = -1
            var high: Float = 32767 / 32768
            vDSP_vclip(samples, 1, &low, &high, &clipped, 1, vDSP_Length(count))
            var scale: Float = 32768
            vDSP_vsmul(clipped, 1, &scale, &clipped, 1, vDSP_Length(count))
            vDSP_vfixr16(clipped, 1, destination, 1, vDSP_Length(count))
        case .pcmFormatFloat32:
            guard let destination = buffer.floatChannelData?[0] else { throw MediaError.failed("Speech buffer has no data") }
            destination.update(from: samples, count: count)
        default:
            throw MediaError.failed("Unsupported speech audio format \(buffer.format)")
        }
    }
}

@available(macOS 26, *)
struct AnalyzerInputs: AsyncSequence, Sendable {
    typealias Element = AnalyzerInput
    let feed: AnalyzerFeed

    func makeAsyncIterator() -> Iterator { Iterator(feed: feed) }

    struct Iterator: AsyncIteratorProtocol {
        let feed: AnalyzerFeed

        mutating func next() async throws -> AnalyzerInput? {
            let feed = self.feed
            // Decoding blocks, so it runs off the cooperative threads.
            return try await Blocking.run(qos: feed.context.qos) { try feed.next() }
        }
    }
}


/// A 100 Hz loudness envelope of the speech audio, used to pull word edges
/// in to where the voice actually is.
///
/// SpeechAnalyzer's word ranges swallow the silence around them (in the
/// transcription spike they covered 8.7 of 11.7 s of pauses; Whisper 5.1),
/// which would hide the pauses Tandem tightens. A word that starts or ends
/// in 100 ms or more of quiet is trimmed to its loud part, with a little
/// padding so no consonant is clipped.
struct SpeechEnvelope {
    static let rate = 100.0
    let origin: Double
    let sampleRate: Double
    private(set) var energy: [Double] = []
    private(set) var counts: [Int] = []

    init(origin: Double, sampleRate: Double) {
        self.origin = origin
        self.sampleRate = sampleRate
    }

    mutating func add(_ samples: UnsafeBufferPointer<Float>, at start: Double) {
        var position = Int(((start - origin) * sampleRate).rounded())
        let perBucket = sampleRate / Self.rate
        var offset = 0
        while offset < samples.count {
            let bucket = Int(Double(max(0, position)) / perBucket)
            let bucketEnd = Int((Double(bucket + 1) * perBucket).rounded())
            let count = max(1, min(samples.count - offset, bucketEnd - max(0, position)))
            var sum: Float = 0
            vDSP_svesq(samples.baseAddress! + offset, 1, &sum, vDSP_Length(count))
            if bucket >= energy.count {
                energy.append(contentsOf: repeatElement(0, count: bucket - energy.count + 1))
                counts.append(contentsOf: repeatElement(0, count: bucket - counts.count + 1))
            }
            energy[bucket] += Double(sum)
            counts[bucket] += count
            offset += count
            position += count
        }
    }

    /// Level of each 10 ms in dBFS (RMS), -120 for digital silence.
    var levels: [Double] {
        zip(energy, counts).map { energy, count in
            count > 0 && energy > 0 ? 10 * log10(energy / Double(count)) : -120
        }
    }

    /// Between the room's noise and the voice: 10 dB over the quietest
    /// tenth, and never more than 30 dB under the loud tenth.
    static func threshold(for levels: [Double]) -> Double {
        let sorted = levels.sorted()
        guard !sorted.isEmpty else { return -120 }
        let floor = sorted[sorted.count / 10]
        let loud = sorted[min(sorted.count - 1, sorted.count * 9 / 10)]
        return max(floor + 10, loud - 30)
    }

    func snap(_ words: [TranscriptWord]) -> [TranscriptWord] {
        let levels = self.levels
        guard levels.count > 10 else { return words }
        let threshold = Self.threshold(for: levels)
        let quiet = 0.1
        let padBefore = 0.02
        let padAfter = 0.04
        return words.map { word in
            let first = max(0, Int(((word.start.seconds - origin) * Self.rate).rounded(.down)))
            let last = min(levels.count - 1, Int(((word.end.seconds - origin) * Self.rate).rounded(.up)) - 1)
            guard last >= first,
                  let loudFirst = (first...last).first(where: { levels[$0] > threshold }),
                  let loudLast = (first...last).last(where: { levels[$0] > threshold })
            else { return word }
            var snapped = word
            let voiceStart = origin + Double(loudFirst) / Self.rate - padBefore
            if voiceStart - word.start.seconds >= quiet { snapped.start = Time(seconds: voiceStart) }
            let voiceEnd = origin + Double(loudLast + 1) / Self.rate + padAfter
            if word.end.seconds - voiceEnd >= quiet { snapped.end = Time(seconds: voiceEnd) }
            return snapped
        }
    }
}

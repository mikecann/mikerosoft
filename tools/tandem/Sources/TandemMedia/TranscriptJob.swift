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
        let feed = try AnalyzerFeed(reader: reader, format: format, context: context)
        let duration = reader.duration
        let start = timeRange?.start.seconds ?? 0

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
        return Transcript(language: locale.identifier(.bcp47), engine: engine, words: words)
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

    init(reader: AudioReader, format: AVAudioFormat, context: JobContext) throws {
        guard format.channelCount == AVAudioChannelCount(reader.channels) else {
            throw MediaError.failed("Speech audio format mismatch")
        }
        self.reader = reader
        self.format = format
        self.context = context
        chunkFrames = Int(format.sampleRate)
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

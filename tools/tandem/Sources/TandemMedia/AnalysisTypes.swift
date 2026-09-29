import Foundation
import TandemCore

// Results of background analysis. All times are media time (seconds into the
// file), never timeline time. The render module and the API map them onto
// the timeline through each clip's sourceStart and speed.

public enum AnalysisKind: String, Codable, Sendable, CaseIterable {
    /// Filmstrip thumbnails for the timeline and browser.
    case thumbnails
    /// Peak envelope for drawing audio, and for pulling transcript words
    /// in to the voice (`TranscriptAlignment`).
    case waveform
    /// EBU R128 loudness of the whole file.
    case loudness
    /// 1080p HEVC copy for playing and scrubbing, a keyframe every 15 frames.
    case proxy
    /// Word-level transcript.
    case transcript
    /// Greyscale person matte (HEVC), for the portrait cutout.
    case matte
    /// Voice with the room removed (AUSoundIsolation), latency compensated.
    case isolatedVoice
    /// HEVC copy, alpha kept, of video macOS can't decode (QuickTime
    /// Animation, PNG in a MOV), made with ffmpeg. The picture plays, and
    /// thumbnails, proxies and mattes are made, from this copy.
    case converted
}

public struct TranscriptWord: Codable, Equatable, Sendable {
    public var text: String
    public var start: Time
    public var end: Time
    public var confidence: Double?

    public init(text: String, start: Time, end: Time, confidence: Double? = nil) {
        self.text = text
        self.start = start
        self.end = end
        self.confidence = confidence
    }
}

public struct Transcript: Codable, Equatable, Sendable {
    public var language: String
    /// For example "SpeechAnalyzer" or "whisper-medium.en".
    public var engine: String
    public var words: [TranscriptWord]

    public init(language: String, engine: String, words: [TranscriptWord]) {
        self.language = language
        self.engine = engine
        self.words = words
    }

    public var text: String { words.map(\.text).joined(separator: " ") }

    /// Gaps between words longer than `minimum`, for tightening pauses.
    public func pauses(longerThan minimum: Time) -> [TimeRange] {
        guard words.count > 1 else { return [] }
        return zip(words, words.dropFirst()).compactMap { a, b in
            b.start - a.end >= minimum ? TimeRange(start: a.end, end: b.start) : nil
        }
    }
}

public struct Waveform: Codable, Equatable, Sendable {
    /// Peak values per second of media.
    public var samplesPerSecond: Int
    /// Absolute peak per bucket, 0...1.
    public var peaks: [Float]

    public init(samplesPerSecond: Int, peaks: [Float]) {
        self.samplesPerSecond = samplesPerSecond
        self.peaks = peaks
    }
}

public struct Loudness: Codable, Equatable, Sendable {
    public var integratedLUFS: Double
    public var truePeakDBTP: Double
    public var loudnessRange: Double

    public init(integratedLUFS: Double, truePeakDBTP: Double, loudnessRange: Double) {
        self.integratedLUFS = integratedLUFS
        self.truePeakDBTP = truePeakDBTP
        self.loudnessRange = loudnessRange
    }
}

public struct ThumbnailStrip: Codable, Equatable, Sendable {
    /// Seconds of media between thumbnails.
    public var interval: Double
    /// JPEG files in time order, relative to the cache entry folder.
    public var files: [String]
    public var width: Int
    public var height: Int

    public init(interval: Double, files: [String], width: Int, height: Int) {
        self.interval = interval
        self.files = files
        self.width = width
        self.height = height
    }
}

public enum JobState: String, Codable, Sendable {
    case queued, running, done, failed, cancelled
}

public enum JobPriority: Int, Codable, Sendable, Comparable {
    /// Idle fill-in work.
    case background = 0
    /// Media the timeline uses.
    case timeline = 1
    /// Someone is waiting on it right now.
    case interactive = 2

    public static func < (a: JobPriority, b: JobPriority) -> Bool { a.rawValue < b.rawValue }
}

public struct JobStatus: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var kind: AnalysisKind
    public var mediaID: String
    public var state: JobState
    public var progress: Double
    public var message: String?

    public init(id: String, kind: AnalysisKind, mediaID: String, state: JobState, progress: Double = 0, message: String? = nil) {
        self.id = id
        self.kind = kind
        self.mediaID = mediaID
        self.state = state
        self.progress = progress
        self.message = message
    }
}

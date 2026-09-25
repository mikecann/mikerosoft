import Foundation
import TandemCore

/// How each analysis is made. Only the settings a kind uses go into its cache
/// key, so changing the transcript locale doesn't rebuild thumbnails.
public struct AnalysisSettings: Codable, Equatable, Sendable {
    /// Seconds of media between filmstrip thumbnails.
    public var thumbnailInterval: Double
    /// Thumbnail width in pixels; the height keeps the aspect.
    public var thumbnailWidth: Int
    /// Waveform peaks per second of media.
    public var waveformRate: Int
    /// Proxies fit inside this box (landscape; portrait sources swap it).
    public var proxyMaxWidth: Int
    public var proxyMaxHeight: Int
    /// VideoToolbox constant quality, 0...1. 0.45 is about 30 MB a minute
    /// for Mike's 4K camera, plenty for scrubbing (paused frames decode the
    /// original).
    public var proxyQuality: Double
    /// SpeechAnalyzer locale. en-US beat en-AU on Mike's voice (7.1% against
    /// 8.8% word error rate in the transcription spike).
    public var transcriptLocale: String
    public var matteQuality: MatteQuality
    /// `personAndProps` keeps a handheld mic; `person` is the plain person mask.
    public var matteMode: CutoutMode
    /// The matte fits inside this box, like proxies.
    public var matteMaxWidth: Int
    public var matteMaxHeight: Int
    public var voiceModel: VoiceIsolationModel

    public init(
        thumbnailInterval: Double = 2,
        thumbnailWidth: Int = 320,
        waveformRate: Int = 100,
        proxyMaxWidth: Int = 1920,
        proxyMaxHeight: Int = 1080,
        proxyQuality: Double = 0.45,
        transcriptLocale: String = "en-US",
        matteQuality: MatteQuality = .accurate,
        matteMode: CutoutMode = .personAndProps,
        matteMaxWidth: Int = 1920,
        matteMaxHeight: Int = 1080,
        voiceModel: VoiceIsolationModel = .voice
    ) {
        self.thumbnailInterval = thumbnailInterval
        self.thumbnailWidth = thumbnailWidth
        self.waveformRate = waveformRate
        self.proxyMaxWidth = proxyMaxWidth
        self.proxyMaxHeight = proxyMaxHeight
        self.proxyQuality = proxyQuality
        self.transcriptLocale = transcriptLocale
        self.matteQuality = matteQuality
        self.matteMode = matteMode
        self.matteMaxWidth = matteMaxWidth
        self.matteMaxHeight = matteMaxHeight
        self.voiceModel = voiceModel
    }

    public static let standard = AnalysisSettings()

    /// The settings `kind` depends on, as canonical JSON (sorted keys).
    public func canonical(for kind: AnalysisKind) -> String {
        let values: [String: String]
        switch kind {
        case .thumbnails: values = ["interval": "\(thumbnailInterval)", "width": "\(thumbnailWidth)"]
        case .waveform: values = ["rate": "\(waveformRate)"]
        case .loudness: values = [:]
        case .proxy: values = ["box": "\(proxyMaxWidth)x\(proxyMaxHeight)", "quality": "\(proxyQuality)"]
        case .transcript: values = ["locale": transcriptLocale]
        case .matte: values = ["box": "\(matteMaxWidth)x\(matteMaxHeight)", "mode": matteMode.rawValue, "quality": matteQuality.rawValue]
        case .isolatedVoice: values = ["model": voiceModel.rawValue]
        }
        let body = values.keys.sorted().map { "\"\($0)\":\"\(values[$0]!)\"" }.joined(separator: ",")
        return "{\(body)}"
    }
}

/// Vision person segmentation quality. Accurate is about 60 frames a second
/// on the M5 Pro (12 minutes for a 24 minute take), fast about 240.
public enum MatteQuality: String, Codable, Sendable, CaseIterable {
    case fast, balanced, accurate
}

/// Which AUSoundIsolation model to run. `voice` has 3,665 samples of
/// latency at 48 kHz, `highQualityVoice` 6,360 and sounds the same on
/// Mike's takes.
public enum VoiceIsolationModel: String, Codable, Sendable, CaseIterable {
    case voice, highQualityVoice
}

extension AnalysisKind {
    /// Bump when a kind's output changes, so old cache entries are rebuilt.
    public var algorithmVersion: Int {
        switch self {
        case .thumbnails, .waveform, .loudness, .proxy, .transcript, .matte, .isolatedVoice: return 1
        }
    }

    /// Whether this analysis makes sense for an item.
    public func applies(to item: MediaItem) -> Bool {
        switch self {
        case .thumbnails: return item.hasVideo || item.kind == .image
        case .waveform, .loudness, .transcript, .isolatedVoice: return item.hasAudio
        case .proxy, .matte: return item.kind == .video && item.hasVideo
        }
    }
}

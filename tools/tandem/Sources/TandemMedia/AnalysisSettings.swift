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
    /// VideoToolbox constant quality, 0...1. With a keyframe every 15
    /// frames, 0.78 is about 97 MB a minute of Mike's 4K camera (all-intra
    /// proxies at 0.6 were 105, the original is 104) and 11 of screen
    /// recording (was 57). VideoToolbox rounds quality in steps: 0.76 and
    /// 0.77 make the same file, as do 0.79 and 0.8, the next step up at
    /// 111 MB a minute.
    public var proxyQuality: Double
    /// Frames from one proxy keyframe to the next, P-frames between and no
    /// reordering; 1 is all-intra. All-intra proxies made their compression
    /// noise anew every frame, and it crawled over still walls and screen
    /// text while playing: 8x8 blocks of the camera's wall changed 0.45
    /// levels a frame at quality 0.6, the original 0.13. A P-frame leaves a
    /// still area as it was, so with a keyframe every 15 frames it's 0.07 a
    /// frame, with a tick of 0.31 at each keyframe (the camera's own
    /// keyframes tick 0.26, every 2 s). The viewer's exact seeks decode from
    /// the keyframe before: 16 ms at p95 against 9 all-intra, and drags
    /// still show every frame both ways. Every 30 frames saves little and
    /// drops frames dragging backwards. docs/RENDER.md has the numbers.
    public var proxyKeyFrameInterval: Int
    /// SpeechAnalyzer locale. en-US beat en-AU on Mike's voice (7.1% against
    /// 8.8% word error rate in the transcription spike).
    public var transcriptLocale: String
    /// What makes the cutout matte: RVM by default, with Vision (version 2)
    /// standing in when RVM's model can't be had.
    public var matteModel: MatteModel
    public var matteQuality: MatteQuality
    /// `personAndProps` keeps a handheld mic; `person` is the plain person mask.
    public var matteMode: CutoutMode
    /// Where `personAndProps` finds what the person holds.
    public var matteProps: MatteProps
    public var matteSmoothing: MatteSmoothing
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
        proxyQuality: Double = 0.78,
        proxyKeyFrameInterval: Int = 15,
        transcriptLocale: String = "en-US",
        matteModel: MatteModel = .robustVideoMatting,
        matteQuality: MatteQuality = .accurate,
        matteMode: CutoutMode = .personAndProps,
        matteProps: MatteProps = .subject,
        matteSmoothing: MatteSmoothing = .steady,
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
        self.proxyKeyFrameInterval = proxyKeyFrameInterval
        self.transcriptLocale = transcriptLocale
        self.matteModel = matteModel
        self.matteQuality = matteQuality
        self.matteMode = matteMode
        self.matteProps = matteProps
        self.matteSmoothing = matteSmoothing
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
        case .proxy: values = ["box": "\(proxyMaxWidth)x\(proxyMaxHeight)", "keyframes": "\(proxyKeyFrameInterval)", "quality": "\(proxyQuality)"]
        case .transcript: values = ["locale": transcriptLocale]
        case .matte where matteModel == .robustVideoMatting:
            // RVM keeps what the person holds either way, so both cutout
            // modes share one matte; its own version rebuilds only RVM mattes.
            values = ["box": "\(matteMaxWidth)x\(matteMaxHeight)", "model": matteModel.rawValue, "rvm": "\(RVMMatte.version)"]
        case .matte:
            var matte = ["box": "\(matteMaxWidth)x\(matteMaxHeight)", "mode": matteMode.rawValue, "quality": matteQuality.rawValue, "smoothing": matteSmoothing.rawValue]
            // A person-only matte has no props to find.
            if matteMode == .personAndProps { matte["props"] = matteProps.rawValue }
            values = matte
        case .isolatedVoice: values = ["model": voiceModel.rawValue]
        case .converted: values = [:]
        }
        let body = values.keys.sorted().map { "\"\($0)\":\"\(values[$0]!)\"" }.joined(separator: ",")
        return "{\(body)}"
    }
}

/// What makes the cutout matte.
public enum MatteModel: String, Codable, Sendable, CaseIterable {
    /// Apple Vision's person and subject masks, steadied by `MatteSmoother`
    /// (matte version 2). Also what an RVM matte falls back to, saying so,
    /// when RVM's model can't be downloaded or loaded.
    case vision
    /// Robust Video Matting (MobileNetV3), a video matting model that
    /// carries what it saw from frame to frame: steadier than Vision on
    /// Mike's takes, with soft edges (their light rim trimmed, see
    /// `RVMMatte.cleanEdge`). The default. GPL-3.0: the model is downloaded
    /// on first use and never bundled (see `RVMMatte`).
    case robustVideoMatting
}

/// Vision person segmentation quality. Accurate is about 60 frames a second
/// on the M5 Pro on its own, fast about 240. Fast and balanced shimmer less
/// where Mike sits still but lose hair and fingers and pop more when he
/// moves; see docs/MEDIA.md.
public enum MatteQuality: String, Codable, Sendable, CaseIterable {
    case fast, balanced, accurate
}

/// Where a `personAndProps` matte finds what the person holds.
public enum MatteProps: String, Codable, Sendable, CaseIterable {
    /// Vision's foreground subject mask ("lift subject"). It holds still
    /// from frame to frame and keeps the mic; it misses a hand held away
    /// from the body, which the person mask keeps. The default.
    case subject
    /// Vision's person instance mask, where the person mask has holes: the
    /// version 1 cutout. The mic pops in and out from frame to frame.
    case personInstances
}

/// How the matte is steadied over time.
public enum MatteSmoothing: String, Codable, Sendable, CaseIterable {
    /// Every frame as Vision made it.
    case off
    /// Medians and a gentle average over neighbouring frames, only where
    /// the picture is still, so edges stop shimmering and one-frame pops go
    /// while a moving hand leaves no trail. See `MatteSmoother`.
    case steady
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
        case .thumbnails, .waveform, .loudness, .transcript, .isolatedVoice, .converted: return 1
        // 2: the subject mask for props and smoothing over time.
        case .matte: return 2
        // 2: quality 0.6, so the 0.45 proxies that crawled rebuild.
        // 3: P-frames with a keyframe every 15 frames at quality 0.78. The
        // all-intra version 2 proxies made new compression noise every
        // frame, which still crawled over walls and screen text while
        // playing; these leave still areas still.
        case .proxy: return 3
        }
    }

    /// Whether this analysis makes sense for an item.
    public func applies(to item: MediaItem) -> Bool {
        switch self {
        case .thumbnails: return item.hasVideo || item.kind == .image
        case .waveform, .loudness, .transcript, .isolatedVoice: return item.hasAudio
        case .proxy, .matte: return item.kind == .video && item.hasVideo
        case .converted: return item.kind == .video && item.hasVideo && item.undecodableCodec != nil
        }
    }

    /// Kinds that decode the picture, so for a file macOS can't decode
    /// they're made from its `converted` copy.
    var readsPicture: Bool {
        switch self {
        case .thumbnails, .proxy, .matte: return true
        case .waveform, .loudness, .transcript, .isolatedVoice, .converted: return false
        }
    }
}

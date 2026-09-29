import Foundation
import TandemCore
import TandemMedia
import TandemRender

// Requests and results for every service operation. The same types travel
// over HTTP (as the JSON body and response), MCP (as tool arguments) and the
// CLI (built from flags), so all three stay in step. Times in requests may
// be seconds or `mm:ss.mmm` strings; times in results are seconds.

// MARK: - status

public struct StatusRequest: ServiceCall {
    public static let operation = ServiceOperation.status
    public init() {}

    public func run(on service: TandemService, context: CallContext) async throws -> StatusResult {
        service.status()
    }
}

/// Who has the project open, from its lock file.
public struct OwnerInfo: Codable, Equatable, Sendable {
    /// `app` or `cli`.
    public var owner: String
    public var pid: Int32
    public var started: Date
    /// The API port when the owner serves one.
    public var port: Int?

    public init(owner: String, pid: Int32, started: Date, port: Int?) {
        self.owner = owner
        self.pid = pid
        self.started = started
        self.port = port
    }
}

public struct StatusResult: Codable, Sendable {
    public var name: String
    public var path: String
    public var revision: Int
    public var savedRevision: Int
    /// True when edits haven't reached the file yet (autosave is a second behind).
    public var dirty: Bool
    public var duration: Time
    public var width: Int
    public var height: Int
    public var frameRate: Double
    public var tracks: Int
    public var clips: Int
    public var media: Int
    public var markers: Int
    /// Label of the edit `undo` would undo.
    public var undo: String?
    public var redo: String?
    public var openIn: OwnerInfo?
    /// True when nothing else had the project open and it was read straight
    /// from the file for this call.
    public var headless: Bool
    public var jobs: [JobStatus]
    public var exports: [ExportJob]
    /// True when the project was recovered from the journal after a crash.
    public var recoveredEdits: Bool
    public var apiVersion: String
}

// MARK: - media

public struct MediaRequest: ServiceCall {
    public static let operation = ServiceOperation.media
    /// Scan the folder for new files first.
    public var refresh: Bool?

    public init(refresh: Bool? = nil) {
        self.refresh = refresh
    }

    public func run(on service: TandemService, context: CallContext) async throws -> MediaResult {
        try await service.media(refresh: refresh ?? false)
    }
}

public struct AnalysisState: Codable, Equatable, Sendable {
    /// `ready`, `queued`, `running`, `failed`, `cancelled` or `none`.
    public var state: String
    public var progress: Double?
    /// Why it failed, when it did.
    public var message: String?

    public init(state: String, progress: Double? = nil, message: String? = nil) {
        self.state = state
        self.progress = progress
        self.message = message
    }
}

public struct MediaInfo: Codable, Sendable {
    public var id: String
    public var path: String
    public var kind: MediaKind
    public var role: MediaRole
    public var duration: Time?
    public var width: Int?
    public var height: Int?
    public var frameRate: Double?
    public var hasVideo: Bool
    public var hasAudio: Bool
    /// The video codec macOS can't decode ("rle " for QuickTime Animation,
    /// "png "), when it can't. The picture comes from a converted copy
    /// (`analysis.converted`).
    public var undecodableCodec: String?
    /// For a Live Photo's still, its motion clip (the short movie beside it).
    public var livePhotoVideo: String? = nil
    public var takeID: String?
    public var takeOffset: Time?
    /// How many timeline clips use this file.
    public var clips: Int
    /// False when the file is missing from disk.
    public var exists: Bool
    /// Analysis status by kind (`transcript`, `loudness`, `proxy`...).
    public var analysis: [String: AnalysisState]
}

public struct MediaResult: Codable, Sendable {
    public var revision: Int
    /// IDs of media a refresh added.
    public var added: [String]
    public var items: [MediaInfo]
}

// MARK: - timeline

public struct TimelineRequest: ServiceCall {
    public static let operation = ServiceOperation.timeline

    public enum Format: String, Codable, Sendable {
        /// The compact text view.
        case text
        /// The project JSON (filtered to the range).
        case json
    }

    public var from: Time?
    public var to: Time?
    public var format: Format?
    /// Add what's said in each speech clip (text form only).
    public var words: Bool?
    /// Just one line per track and the markers (text form only).
    public var summary: Bool?

    public init(from: Time? = nil, to: Time? = nil, format: Format? = nil, words: Bool? = nil, summary: Bool? = nil) {
        self.from = from
        self.to = to
        self.format = format
        self.words = words
        self.summary = summary
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        from = try c.decodeTime(.from)
        to = try c.decodeTime(.to)
        format = try c.decodeIfPresent(Format.self, forKey: .format)
        words = try c.decodeIfPresent(Bool.self, forKey: .words)
        summary = try c.decodeIfPresent(Bool.self, forKey: .summary)
    }

    public func run(on service: TandemService, context: CallContext) async throws -> TimelineResult {
        try service.timeline(from: from, to: to, format: format ?? .text, words: words ?? false, summary: summary ?? false)
    }
}

public struct TimelineResult: Codable, Sendable {
    public var revision: Int
    /// The text view, for `format: text`.
    public var text: String?
    /// The project, for `format: json`. Tracks keep only the clips that
    /// overlap the range.
    public var project: Project?
}

// MARK: - transcript, search, pauses, tighten

public struct TranscriptRequest: ServiceCall {
    public static let operation = ServiceOperation.transcript
    /// A media ID (media times), a clip ID (timeline times) or nothing for
    /// everything said on the timeline.
    public var id: String?
    public var from: Time?
    public var to: Time?

    public init(id: String? = nil, from: Time? = nil, to: Time? = nil) {
        self.id = id
        self.from = from
        self.to = to
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        from = try c.decodeTime(.from)
        to = try c.decodeTime(.to)
    }

    public func run(on service: TandemService, context: CallContext) async throws -> TranscriptResult {
        try service.transcript(id: id, from: from, to: to)
    }
}

public struct WordTiming: Codable, Equatable, Sendable {
    public var text: String
    public var start: Time
    public var end: Time
    /// The clip the word plays in, for timeline transcripts.
    public var clipID: String?
    public var confidence: Double?

    public init(text: String, start: Time, end: Time, clipID: String? = nil, confidence: Double? = nil) {
        self.text = text
        self.start = start
        self.end = end
        self.clipID = clipID
        self.confidence = confidence
    }
}

public struct TranscriptResult: Codable, Sendable {
    public var revision: Int
    /// `media`, `clip` or `timeline`.
    public var scope: String
    public var id: String?
    /// False when times are media times (a media transcript).
    public var timelineTimes: Bool
    public var words: [WordTiming]
    /// Media on the timeline whose transcript isn't ready yet.
    public var missing: [String]
}

public struct SearchRequest: ServiceCall {
    public static let operation = ServiceOperation.search
    public var phrase: String
    public var limit: Int?

    public init(phrase: String, limit: Int? = nil) {
        self.phrase = phrase
        self.limit = limit
    }

    public func run(on service: TandemService, context: CallContext) async throws -> SearchResult {
        try service.search(phrase: phrase, limit: limit)
    }
}

public struct SearchHit: Codable, Equatable, Sendable {
    /// The words as the transcript has them.
    public var text: String
    /// Timeline range of the match.
    public var start: Time
    public var end: Time
    /// Every clip playing the match: the voice clip and its linked picture.
    public var clipIDs: [String]
    public var mediaID: String
    public var mediaStart: Time
    public var mediaEnd: Time
    /// True when a cut runs through the phrase, so only part of it plays.
    public var partial: Bool
    /// A few words either side, for context.
    public var before: String
    public var after: String
}

/// A match in a file that the timeline doesn't use (cut out, or never placed).
public struct UnusedHit: Codable, Equatable, Sendable {
    public var mediaID: String
    public var path: String
    public var text: String
    public var mediaStart: Time
    public var mediaEnd: Time
    public var before: String
    public var after: String
}

public struct SearchResult: Codable, Sendable {
    public var revision: Int
    public var phrase: String
    public var hits: [SearchHit]
    public var unused: [UnusedHit]
    public var missing: [String]
}

public struct PausesRequest: ServiceCall {
    public static let operation = ServiceOperation.pauses
    /// Shortest gap to report, in seconds. Default 0.6.
    public var min: Double?
    public var from: Time?
    public var to: Time?

    public init(min: Double? = nil, from: Time? = nil, to: Time? = nil) {
        self.min = min
        self.from = from
        self.to = to
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        min = try c.decodeSeconds(.min)
        from = try c.decodeTime(.from)
        to = try c.decodeTime(.to)
    }

    public func run(on service: TandemService, context: CallContext) async throws -> PausesResult {
        try service.pauses(minimum: Time(seconds: min ?? TranscriptTools.defaultMinimum), from: from, to: to)
    }
}

/// A silence between two words, in timeline time.
public struct Pause: Codable, Equatable, Sendable {
    public var start: Time
    public var end: Time
    public var duration: Time
    /// The last words before the pause and the first ones after it.
    public var before: String
    public var after: String
    /// Speech clips under the pause.
    public var clipIDs: [String]
}

public struct PausesResult: Codable, Sendable {
    public var revision: Int
    public var minimum: Time
    public var pauses: [Pause]
    public var total: Time
    public var missing: [String]
}

public struct TightenRequest: ServiceCall {
    public static let operation = ServiceOperation.tighten
    /// Pauses at least this long get shortened. Default 0.6 s.
    public var min: Double?
    /// How much of each pause to keep. Default 0.15 s.
    public var keep: Double?
    /// Make the edit. Without it this is a dry run that returns the plan.
    public var apply: Bool?
    public var from: Time?
    public var to: Time?
    public var label: String?
    public var author: String?
    /// Refuse to apply if the project isn't at this revision.
    public var expectedRevision: Int?

    public init(
        min: Double? = nil, keep: Double? = nil, apply: Bool? = nil, from: Time? = nil, to: Time? = nil,
        label: String? = nil, author: String? = nil, expectedRevision: Int? = nil
    ) {
        self.min = min
        self.keep = keep
        self.apply = apply
        self.from = from
        self.to = to
        self.label = label
        self.author = author
        self.expectedRevision = expectedRevision
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        min = try c.decodeSeconds(.min)
        keep = try c.decodeSeconds(.keep)
        apply = try c.decodeIfPresent(Bool.self, forKey: .apply)
        from = try c.decodeTime(.from)
        to = try c.decodeTime(.to)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        author = try c.decodeIfPresent(String.self, forKey: .author)
        expectedRevision = try c.decodeIfPresent(Int.self, forKey: .expectedRevision)
    }

    public func run(on service: TandemService, context: CallContext) async throws -> TightenResult {
        try service.tighten(self, context: context)
    }
}

public struct PlannedCut: Codable, Equatable, Sendable {
    public var pause: Pause
    /// The time `rippleDeleteRange` removes, frame aligned.
    public var cut: TimeRange
}

public struct TightenResult: Codable, Sendable {
    /// The revision the plan was made against.
    public var revision: Int
    public var minimum: Time
    public var keep: Time
    public var cuts: [PlannedCut]
    public var removed: Time
    public var durationBefore: Time
    public var durationAfter: Time
    /// The batch that makes the cut, latest first so each range is still in
    /// the current timeline's times. Pass it to `apply` to run it yourself.
    public var commands: [EditCommand]
    /// Set when the plan was applied.
    public var applied: ApplyResult?
    public var warnings: [String]
    public var missing: [String]
}

// MARK: - apply, undo, redo, history, validate

public struct ApplyRequest: ServiceCall {
    public static let operation = ServiceOperation.apply
    public var label: String?
    public var author: String?
    public var commands: [EditCommand]
    public var expectedRevision: Int?
    public var idempotencyKey: String?
    /// Check the batch on a copy and report what it would do.
    public var dryRun: Bool?

    public init(
        label: String? = nil, author: String? = nil, commands: [EditCommand],
        expectedRevision: Int? = nil, idempotencyKey: String? = nil, dryRun: Bool? = nil
    ) {
        self.label = label
        self.author = author
        self.commands = commands
        self.expectedRevision = expectedRevision
        self.idempotencyKey = idempotencyKey
        self.dryRun = dryRun
    }

    public init(batch: EditBatch, dryRun: Bool? = nil) {
        self.init(
            label: batch.label, author: batch.author, commands: batch.commands,
            expectedRevision: batch.expectedRevision, idempotencyKey: batch.idempotencyKey, dryRun: dryRun
        )
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        author = try c.decodeIfPresent(String.self, forKey: .author)
        expectedRevision = try c.decodeIfPresent(Int.self, forKey: .expectedRevision)
        idempotencyKey = try c.decodeIfPresent(String.self, forKey: .idempotencyKey)
        dryRun = try c.decodeIfPresent(Bool.self, forKey: .dryRun)
        let raw = try c.decode([JSONValue].self, forKey: .commands)
        commands = try raw.enumerated().map { index, value in
            try CommandJSON.decode(value, path: "commands[\(index)]")
        }
    }

    public func run(on service: TandemService, context: CallContext) async throws -> ApplyResult {
        try service.apply(self, context: context)
    }
}

public struct ApplyResult: Codable, Equatable, Sendable {
    public var revision: Int
    public var label: String
    public var author: String
    /// IDs the batch created, in order (clips, tracks, transitions, markers).
    public var createdIDs: [String]
    public var warnings: [String]
    /// True when nothing was committed.
    public var dryRun: Bool
    /// True when an idempotency key matched an earlier batch, which wasn't
    /// applied again.
    public var repeated: Bool
    /// Clips that are new, gone, or different after the batch.
    public var added: [String]
    public var removed: [String]
    public var changed: [String]
    /// Timeline duration after the batch.
    public var duration: Time
}

public struct UndoRequest: ServiceCall {
    public static let operation = ServiceOperation.undo
    /// Refuse if the project has moved on, so an agent never undoes
    /// someone else's edit.
    public var expectedRevision: Int?

    public init(expectedRevision: Int? = nil) {
        self.expectedRevision = expectedRevision
    }

    public func run(on service: TandemService, context: CallContext) async throws -> UndoResult {
        try service.undo(expectedRevision: expectedRevision)
    }
}

public struct RedoRequest: ServiceCall {
    public static let operation = ServiceOperation.redo
    public var expectedRevision: Int?

    public init(expectedRevision: Int? = nil) {
        self.expectedRevision = expectedRevision
    }

    public func run(on service: TandemService, context: CallContext) async throws -> UndoResult {
        try service.redo(expectedRevision: expectedRevision)
    }
}

public struct UndoResult: Codable, Sendable {
    /// `undo` or `redo`.
    public var action: String
    public var revision: Int
    /// The label of the edit that was undone or redone.
    public var label: String
    public var author: String
}

public struct HistoryRequest: ServiceCall {
    public static let operation = ServiceOperation.history
    public var limit: Int?

    public init(limit: Int? = nil) {
        self.limit = limit
    }

    public func run(on service: TandemService, context: CallContext) async throws -> HistoryResult {
        service.history(limit: limit ?? 20)
    }
}

public struct HistoryEntry: Codable, Equatable, Sendable {
    public var label: String
    public var author: String
}

public struct HistoryResult: Codable, Sendable {
    public var revision: Int
    /// What `undo` would undo, newest first.
    public var undo: [HistoryEntry]
    public var redo: String?
    /// Recent changes seen by this server, oldest first.
    public var events: [ServiceEvent]
}

public struct ValidateRequest: ServiceCall {
    public static let operation = ServiceOperation.validate
    public init() {}

    public func run(on service: TandemService, context: CallContext) async throws -> ValidateResult {
        service.validate()
    }
}

public struct ValidateResult: Codable, Sendable {
    public var revision: Int
    /// True when there are no errors (warnings are fine).
    public var ok: Bool
    public var issues: [ValidationIssue]
}

// MARK: - frames and renders

public struct FrameRequest: ServiceCall {
    public static let operation = ServiceOperation.frame
    public var time: Time
    public var maxWidth: Int?
    public var maxHeight: Int?
    /// Write the PNG here (absolute, or relative to the project folder)
    /// instead of returning it as base64.
    public var output: String?
    /// An alternate output format ID, like `portrait`.
    public var format: String?

    public init(time: Time, maxWidth: Int? = nil, maxHeight: Int? = nil, output: String? = nil, format: String? = nil) {
        self.time = time
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.output = output
        self.format = format
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let time = try c.decodeTime(.time) else {
            throw DecodingError.keyNotFound(CodingKeys.time, .init(codingPath: c.codingPath, debugDescription: "time is required"))
        }
        self.time = time
        maxWidth = try c.decodeIfPresent(Int.self, forKey: .maxWidth)
        maxHeight = try c.decodeIfPresent(Int.self, forKey: .maxHeight)
        output = try c.decodeIfPresent(String.self, forKey: .output)
        format = try c.decodeIfPresent(String.self, forKey: .format)
    }

    public func run(on service: TandemService, context: CallContext) async throws -> ImageResult {
        try await service.prepareFrame(self)()
    }
}

public struct ScreenshotRequest: ServiceCall {
    public static let operation = ServiceOperation.screenshot
    public var output: String?

    public init(output: String? = nil) {
        self.output = output
    }

    public func run(on service: TandemService, context: CallContext) async throws -> ImageResult {
        try await service.screenshot(output: output)
    }
}

public struct ImageResult: Codable, Sendable {
    public var time: Time?
    /// Where the PNG was written, when an output path was given.
    public var path: String?
    /// The PNG as base64, when no output path was given.
    public var png: String?
    public var bytes: Int
    /// What the picture shows differently from the project, like a camera
    /// without its cutout because the matte isn't made yet.
    public var warnings: [String]

    public init(time: Time?, path: String?, png: String?, bytes: Int, warnings: [String] = []) {
        self.time = time
        self.path = path
        self.png = png
        self.bytes = bytes
        self.warnings = warnings
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        time = try c.decodeIfPresent(Time.self, forKey: .time)
        path = try c.decodeIfPresent(String.self, forKey: .path)
        png = try c.decodeIfPresent(String.self, forKey: .png)
        bytes = try c.decode(Int.self, forKey: .bytes)
        warnings = try c.decodeIfPresent([String].self, forKey: .warnings) ?? []
    }
}

public struct ClipRequest: ServiceCall {
    public static let operation = ServiceOperation.clip
    public var start: Time
    public var end: Time
    public var output: String?
    /// Defaults to the 720p review preset.
    public var preset: String?

    public init(start: Time, end: Time, output: String? = nil, preset: String? = nil) {
        self.start = start
        self.end = end
        self.output = output
        self.preset = preset
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let start = try c.decodeTime(.start) else {
            throw DecodingError.keyNotFound(CodingKeys.start, .init(codingPath: c.codingPath, debugDescription: "start is required"))
        }
        guard let end = try c.decodeTime(.end) else {
            throw DecodingError.keyNotFound(CodingKeys.end, .init(codingPath: c.codingPath, debugDescription: "end is required"))
        }
        self.start = start
        self.end = end
        output = try c.decodeIfPresent(String.self, forKey: .output)
        preset = try c.decodeIfPresent(String.self, forKey: .preset)
    }

    public func run(on service: TandemService, context: CallContext) async throws -> ExportOutcome {
        try await service.prepareClip(self)()
    }
}

public struct ExportRequest: ServiceCall {
    public static let operation = ServiceOperation.export
    /// A preset name (`youtube4k`, `youtube1080`, `review`, `short`). Nil
    /// picks the one that fits the canvas (`ExportPreset.standard(for:)`).
    public var preset: String?
    public var output: String?
    public var from: Time?
    public var to: Time?
    /// An alternate output format ID, like `portrait`.
    public var format: String?

    public init(preset: String? = nil, output: String? = nil, from: Time? = nil, to: Time? = nil, format: String? = nil) {
        self.preset = preset
        self.output = output
        self.from = from
        self.to = to
        self.format = format
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        preset = try c.decodeIfPresent(String.self, forKey: .preset)
        output = try c.decodeIfPresent(String.self, forKey: .output)
        from = try c.decodeTime(.from)
        to = try c.decodeTime(.to)
        format = try c.decodeIfPresent(String.self, forKey: .format)
    }

    public func run(on service: TandemService, context: CallContext) async throws -> ExportOutcome {
        try await service.prepareExport(self)()
    }
}

public struct ExportOutcome: Codable, Sendable {
    public var path: String
    public var preset: String
    /// The frame size, codec and bitrates it rendered with. An older app
    /// answering the CLI leaves them out.
    public var width: Int?
    public var height: Int?
    public var codec: ExportPreset.Codec?
    public var videoBitrate: Int?
    public var audioBitrate: Int?
    /// The alternate format rendered, like `portrait`; nil for the canvas.
    public var format: String?
    public var duration: Time
    /// Measured on the mix before AAC encoding.
    public var integratedLUFS: Double?
    public var truePeakDBTP: Double?
    /// Seconds the render took.
    public var elapsed: Double
    /// What the render shows or plays differently from the project, and
    /// anything about the preset worth knowing, like an upscale.
    public var warnings: [String]

    public init(path: String, preset: String, duration: Time, integratedLUFS: Double?, truePeakDBTP: Double?, elapsed: Double, warnings: [String] = []) {
        self.path = path
        self.preset = preset
        self.duration = duration
        self.integratedLUFS = integratedLUFS
        self.truePeakDBTP = truePeakDBTP
        self.elapsed = elapsed
        self.warnings = warnings
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        preset = try c.decode(String.self, forKey: .preset)
        width = try c.decodeIfPresent(Int.self, forKey: .width)
        height = try c.decodeIfPresent(Int.self, forKey: .height)
        codec = try c.decodeIfPresent(ExportPreset.Codec.self, forKey: .codec)
        videoBitrate = try c.decodeIfPresent(Int.self, forKey: .videoBitrate)
        audioBitrate = try c.decodeIfPresent(Int.self, forKey: .audioBitrate)
        format = try c.decodeIfPresent(String.self, forKey: .format)
        duration = try c.decode(Time.self, forKey: .duration)
        integratedLUFS = try c.decodeIfPresent(Double.self, forKey: .integratedLUFS)
        truePeakDBTP = try c.decodeIfPresent(Double.self, forKey: .truePeakDBTP)
        elapsed = try c.decode(Double.self, forKey: .elapsed)
        warnings = try c.decodeIfPresent([String].self, forKey: .warnings) ?? []
    }
}

// MARK: - loudness, watch, effects

public struct LoudnessRequest: ServiceCall {
    public static let operation = ServiceOperation.loudness
    public var mediaID: String?

    public init(mediaID: String? = nil) {
        self.mediaID = mediaID
    }

    public func run(on service: TandemService, context: CallContext) async throws -> LoudnessResult {
        try service.loudness(mediaID: mediaID)
    }
}

public struct MediaLoudness: Codable, Sendable {
    public var mediaID: String
    public var path: String
    public var integratedLUFS: Double?
    public var truePeakDBTP: Double?
    public var loudnessRange: Double?
    /// `ready`, or the analysis job's state.
    public var state: String
}

/// How loud a timeline clip plays relative to its file.
public struct ClipLevel: Codable, Sendable {
    public var clipID: String
    public var mediaID: String
    public var track: String
    /// Clip gain, added after normalisation.
    public var gainDB: Double
    public var normalizeTo: Double?
    /// The gain normalisation adds (target minus measured, within ±30 dB;
    /// 0 for a silent file), once the file's loudness is known.
    public var normalizeGainDB: Double?
    /// Speech (camera or voice sound, or on a take track): what
    /// `normalizeSpeech` levels.
    public var speech: Bool
}

public struct LoudnessResult: Codable, Sendable {
    /// The master's loudness target, in LUFS.
    public var target: Double
    public var truePeakCeiling: Double
    /// The level speech clips are normalised to, in LUFS.
    public var speechLoudness: Double
    public var media: [MediaLoudness]
    public var clips: [ClipLevel]
}

public struct WatchRequest: ServiceCall {
    public static let operation = ServiceOperation.watch
    /// Wait for the project to move past this revision. Defaults to the
    /// current revision, so the call waits for the next change.
    public var revision: Int?
    /// Seconds to wait before giving up. Default 30, at most 600.
    public var timeout: Double?

    public init(revision: Int? = nil, timeout: Double? = nil) {
        self.revision = revision
        self.timeout = timeout
    }

    public func run(on service: TandemService, context: CallContext) async throws -> WatchResult {
        await service.watch(after: revision, timeout: timeout ?? 30)
    }
}

public struct WatchResult: Codable, Sendable {
    public var revision: Int
    /// False when the wait timed out with no change.
    public var changed: Bool
    /// The changes this server saw after the requested revision.
    public var events: [ServiceEvent]
    public var jobs: [JobStatus]
}

public struct EffectsRequest: ServiceCall {
    public static let operation = ServiceOperation.effects
    /// One effect type, or all of them.
    public var type: String?

    public init(type: String? = nil) {
        self.type = type
    }

    public func run(on service: TandemService, context: CallContext) async throws -> EffectsResult {
        try EffectsResult.catalog(type: type)
    }
}

public struct TransitionInfo: Codable, Sendable {
    public var type: TransitionType
    public var defaultDuration: Time
}

public struct LayoutInfo: Codable, Sendable {
    public var preset: LayoutPreset
    public var name: String
}

public struct EffectsResult: Codable, Sendable {
    public var effects: [EffectDefinition]
    public var transitions: [TransitionInfo]
    public var layouts: [LayoutInfo]
    /// Parameter paths `setKeyframes` animates.
    public var animatable: [String]

    /// The built-in catalogue, which doesn't need a project.
    public static func catalog(type: String? = nil) throws -> EffectsResult {
        var effects = EffectRegistry.standard.sorted
        if let type {
            effects = effects.filter { $0.type.caseInsensitiveCompare(type) == .orderedSame }
            guard !effects.isEmpty else {
                let known = EffectRegistry.standard.sorted.map(\.type).joined(separator: ", ")
                throw ServiceError(.notFound, "No effect called \"\(type)\". Known effects: \(known).")
            }
        }
        return EffectsResult(
            effects: effects,
            transitions: TransitionType.allCases.map { TransitionInfo(type: $0, defaultDuration: $0.defaultDuration) },
            layouts: LayoutPreset.allCases.map { LayoutInfo(preset: $0, name: $0.name) },
            animatable: AnimatableParameter.fixed + ["video.effects.<effectID>.<param>", "audio.effects.<effectID>.<param>"]
        )
    }
}

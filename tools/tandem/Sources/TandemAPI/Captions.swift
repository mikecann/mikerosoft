import Foundation
import TandemCore
import TandemMedia

// Word-by-word captions from the transcripts, the way Mike's shorts have
// them: a few words at a time, the spoken word highlighted (the render
// module's `caption` title preset).

public struct CaptionsRequest: ServiceCall {
    public static let operation = ServiceOperation.captions
    public var from: Time?
    public var to: Time?
    /// Most words on screen at once. Default 3.
    public var words: Int?
    /// Where the captions sit, 0 top to 1 bottom. Default: the caption
    /// preset's place (0.42, between the screen and the camera in a short).
    public var y: Double?
    /// The video track to put them on, made if missing. Default "Captions".
    public var track: String?
    /// Make the edit. Without it this is a dry run that returns the plan.
    public var apply: Bool?
    public var label: String?
    public var author: String?
    public var expectedRevision: Int?

    public init(
        from: Time? = nil, to: Time? = nil, words: Int? = nil, y: Double? = nil, track: String? = nil,
        apply: Bool? = nil, label: String? = nil, author: String? = nil, expectedRevision: Int? = nil
    ) {
        self.from = from
        self.to = to
        self.words = words
        self.y = y
        self.track = track
        self.apply = apply
        self.label = label
        self.author = author
        self.expectedRevision = expectedRevision
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        from = try c.decodeTime(.from)
        to = try c.decodeTime(.to)
        words = try c.decodeIfPresent(Int.self, forKey: .words)
        y = try c.decodeIfPresent(Double.self, forKey: .y)
        track = try c.decodeIfPresent(String.self, forKey: .track)
        apply = try c.decodeIfPresent(Bool.self, forKey: .apply)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        author = try c.decodeIfPresent(String.self, forKey: .author)
        expectedRevision = try c.decodeIfPresent(Int.self, forKey: .expectedRevision)
    }

    public func run(on service: TandemService, context: CallContext) async throws -> CaptionsResult {
        try service.captions(self, context: context)
    }
}

public struct PlannedCaption: Codable, Equatable, Sendable {
    public var start: Time
    public var end: Time
    public var text: String
}

public struct CaptionsResult: Codable, Sendable {
    public var revision: Int
    public var track: String
    public var captions: [PlannedCaption]
    /// The batch that adds them. Pass it to `apply` to run it yourself.
    public var commands: [EditCommand]
    public var applied: ApplyResult?
    public var warnings: [String]
    public var missing: [String]
}

extension TranscriptTools {
    /// Splits the spoken words into captions of at most `maxWords`, breaking
    /// early at sentence ends, pauses over `maxGap` and after `maxDuration`.
    /// Each caption holds briefly after its last word but never overlaps the
    /// next one, and every edge sits on a frame.
    static func captions(
        _ words: [SpokenWord],
        maxWords: Int,
        maxGap: Time = Time(seconds: 0.35),
        maxDuration: Time = Time(seconds: 1.8),
        hold: Time = Time(seconds: 0.2),
        frameRate: FrameRate
    ) -> [(start: Time, end: Time, words: [SpokenWord])] {
        // Two voice tracks can play the same take; keep one copy of a word.
        var unique: [SpokenWord] = []
        for word in words {
            if let last = unique.last, word.start < last.end, word.text == last.text { continue }
            unique.append(word)
        }
        var groups: [[SpokenWord]] = []
        var current: [SpokenWord] = []
        for word in unique {
            if let first = current.first, let last = current.last {
                let sentenceEnded = last.text.last.map { ".?!".contains($0) } ?? false
                if current.count >= maxWords || word.start - last.end > maxGap || word.end - first.start > maxDuration || sentenceEnded {
                    groups.append(current)
                    current = []
                }
            }
            current.append(word)
        }
        if !current.isEmpty { groups.append(current) }

        let frame = frameRate.frameDuration
        var result: [(start: Time, end: Time, words: [SpokenWord])] = []
        for (index, group) in groups.enumerated() {
            let start = TimeText.floorToFrame(group[0].start, frameRate)
            var end = TimeText.ceilToFrame(group[group.count - 1].end + hold, frameRate)
            if index + 1 < groups.count {
                end = min(end, TimeText.floorToFrame(groups[index + 1][0].start, frameRate))
            }
            if let previous = result.last, start < previous.end {
                result[result.count - 1].end = start
            }
            guard end - start >= frame else { continue }
            result.append((start, end, group))
        }
        return result.filter { $0.end - $0.start >= frame }
    }
}

extension TandemService {
    public func captions(_ request: CaptionsRequest, context: CallContext) throws -> CaptionsResult {
        let maxWords = request.words ?? 3
        guard (1...12).contains(maxWords) else { throw ServiceError(.badRequest, "`words` must be between 1 and 12.") }
        if let y = request.y, !(0...1).contains(y) {
            throw ServiceError(.badRequest, "`y` is a fraction of the frame height, from 0 (top) to 1 (bottom).")
        }
        let trackName = request.track ?? "Captions"
        let (project, revision) = coordinator.snapshot()
        if let expected = request.expectedRevision, expected != revision {
            throw ServiceError.wrap(EditError.staleRevision(expected: expected, actual: revision))
        }
        let map = TranscriptTools.speechMap(project, analysis: analysis)
        let words = map.words.filter { word in
            (request.from.map { word.start >= $0 } ?? true) && (request.to.map { word.end <= $0 } ?? true)
        }
        let planned = TranscriptTools.captions(words, maxWords: maxWords, frameRate: project.settings.frameRate)

        var commands: [EditCommand] = []
        let trackID: String
        if let existing = project.track(named: trackName, kind: .video) {
            trackID = existing.id
            if existing.locked { throw ServiceError(.locked, "Track \"\(trackName)\" is locked.") }
        } else {
            trackID = IDs.make("trk")
            commands.append(.addTrack(kind: .video, name: trackName, index: nil, id: trackID))
            // Captions move with the speech when pauses are tightened later.
            commands.append(.updateTrack(trackID: trackID, patch: .object(["rippleMode": .string(RippleMode.follow.rawValue)])))
        }
        for caption in planned {
            let text = caption.words.map(\.text).joined(separator: " ")
            let timed = caption.words.map {
                TimedWord(text: $0.text, start: max(.zero, $0.start - caption.start), end: max(.zero, $0.end - caption.start))
            }
            var clip = Clip(
                name: text,
                content: .text(TextContent(text: text, preset: "caption", words: timed)),
                start: caption.start,
                duration: caption.end - caption.start,
                tags: ["captions"]
            )
            if let y = request.y {
                clip.video = VideoProperties(transform: Transform(position: Point(x: 0.5, y: y)))
            }
            commands.append(.insertClip(trackID: trackID, clip: clip, mode: .overwrite))
        }

        var warnings: [String] = []
        if !map.missing.isEmpty {
            let names = map.missing.compactMap { project.media($0)?.path }.joined(separator: ", ")
            warnings.append("No transcript yet for \(names), so nothing said there is captioned.")
        }
        let captions = planned.map { caption in
            PlannedCaption(start: caption.start, end: caption.end, text: caption.words.map(\.text).joined(separator: " "))
        }
        var result = CaptionsResult(
            revision: revision, track: trackName, captions: captions, commands: commands,
            applied: nil, warnings: warnings, missing: map.missing
        )
        guard !captions.isEmpty else { return result }
        let apply = ApplyRequest(
            label: request.label ?? "Caption \(captions.count) line\(captions.count == 1 ? "" : "s")",
            author: request.author, commands: commands,
            expectedRevision: revision, dryRun: request.apply != true
        )
        let applied = try self.apply(apply, context: context)
        result.warnings += applied.warnings
        if request.apply == true { result.applied = applied }
        return result
    }
}

extension CaptionsResult: ReadableResult {
    public var readableText: String {
        var lines: [String] = []
        let mode = applied == nil ? "dry run" : "applied"
        if captions.isEmpty {
            lines.append("Nothing to caption: no transcribed speech in that range.")
        } else {
            lines.append("\(captions.count) caption\(captions.count == 1 ? "" : "s") on \"\(track)\" (\(mode), revision \(revision)):")
            for caption in captions.prefix(40) {
                lines.append("  \(caption.start)-\(caption.end)  \(caption.text)")
            }
            if captions.count > 40 { lines.append("  ...and \(captions.count - 40) more.") }
        }
        for warning in warnings { lines.append("Warning: \(warning)") }
        if let applied {
            lines.append("Applied as revision \(applied.revision) (\"\(applied.label)\"). Undo with `tandem undo`.")
        } else if !captions.isEmpty {
            lines.append("Nothing changed yet. Run again with --apply (or apply: true) to add them.")
        }
        return lines.joined(separator: "\n")
    }
}

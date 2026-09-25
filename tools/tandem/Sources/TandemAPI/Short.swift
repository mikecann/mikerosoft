import Foundation
import TandemCore
import TandemMedia

// A 9:16 short from the landscape edit, the way Mike made his: the screen
// (and B-roll and graphics) in the top half, the camera in the bottom half
// with its background, and full-frame camera moments filling the frame.
// It's an alternate output format of the same project, so edits carry over
// and `tandem export --preset short` renders it.

public struct ShortRequest: ServiceCall {
    public static let operation = ServiceOperation.short
    /// Make the edit. Without it this is a dry run that returns the plan.
    public var apply: Bool?
    public var label: String?
    public var author: String?
    public var expectedRevision: Int?

    public init(apply: Bool? = nil, label: String? = nil, author: String? = nil, expectedRevision: Int? = nil) {
        self.apply = apply
        self.label = label
        self.author = author
        self.expectedRevision = expectedRevision
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        apply = try c.decodeIfPresent(Bool.self, forKey: .apply)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        author = try c.decodeIfPresent(String.self, forKey: .author)
        expectedRevision = try c.decodeIfPresent(Int.self, forKey: .expectedRevision)
    }

    public func run(on service: TandemService, context: CallContext) async throws -> ShortResult {
        try service.short(self, context: context)
    }
}

public struct ShortResult: Codable, Sendable {
    public var revision: Int
    public var format: OutputFormat
    /// Clips per slot: top, bottom, full.
    public var placed: [String: Int]
    public var commands: [EditCommand]
    public var applied: ApplyResult?
    public var warnings: [String]
}

extension TandemService {
    public func short(_ request: ShortRequest, context: CallContext) throws -> ShortResult {
        let (project, revision) = coordinator.snapshot()
        if let expected = request.expectedRevision, expected != revision {
            throw ServiceError.wrap(EditError.staleRevision(expected: expected, actual: revision))
        }
        let format = project.settings.alternateFormats.first { $0.id == OutputFormat.portrait.id } ?? .portrait
        var commands: [EditCommand] = []
        if !project.settings.alternateFormats.contains(where: { $0.id == format.id }) {
            let formats = project.settings.alternateFormats + [format]
            commands.append(.updateSettings(patch: .object(["alternateFormats": try JSONValue.from(formats)])))
        }
        var groups: [PortraitSlot: [String]] = [:]
        var skippedLocked = Set<String>()
        for track in project.videoTracks where !track.hidden {
            for clip in track.clips where clip.enabled {
                guard let mediaID = clip.mediaID, let item = project.media(mediaID) else { continue }
                if track.locked {
                    skippedLocked.insert(track.name)
                    continue
                }
                groups[Self.portraitSlot(for: clip, role: item.role), default: []].append(clip.id)
            }
        }
        for slot in PortraitSlot.allCases {
            guard let ids = groups[slot], !ids.isEmpty else { continue }
            // The camera keeps its background in a short.
            let cutout: Bool? = slot == .top ? nil : false
            commands.append(.setFormatLayout(clipIDs: ids, format: format.id, slot: slot, cutout: cutout))
        }
        var warnings: [String] = []
        if !skippedLocked.isEmpty {
            warnings.append("Left clips on locked tracks alone: \(skippedLocked.sorted().joined(separator: ", ")).")
        }
        var result = ShortResult(
            revision: revision, format: format,
            placed: Dictionary(uniqueKeysWithValues: groups.map { ($0.key.rawValue, $0.value.count) }),
            commands: commands, applied: nil, warnings: warnings
        )
        guard !commands.isEmpty else { return result }
        let apply = ApplyRequest(
            label: request.label ?? "Lay out the 9:16 short",
            author: request.author, commands: commands,
            expectedRevision: revision, dryRun: request.apply != true
        )
        let applied = try self.apply(apply, context: context)
        result.warnings += applied.warnings
        if request.apply == true { result.applied = applied }
        return result
    }

    /// Where a clip goes in the short: camera in the bottom half, or the
    /// whole frame when the landscape edit shows it full frame; everything
    /// else (screen, B-roll, graphics) in the top half.
    static func portraitSlot(for clip: Clip, role: MediaRole) -> PortraitSlot {
        guard role == .camera else { return .top }
        let video = clip.video ?? VideoProperties()
        let cutoutOn = video.cutout?.enabled ?? false
        if video.layoutPreset == LayoutPreset.full.rawValue || (video.transform.scale >= 0.99 && !cutoutOn) {
            return .full
        }
        return .bottom
    }
}

extension ShortResult: ReadableResult {
    public var readableText: String {
        var lines: [String] = []
        let mode = applied == nil ? "dry run" : "applied"
        let counts = ["top", "bottom", "full"].compactMap { slot in placed[slot].map { "\($0) in the \(slot == "full" ? "full frame" : "\(slot) half")" } }
        if counts.isEmpty {
            lines.append("Nothing to place: no video clips from media.")
        } else {
            lines.append("9:16 short \"\(format.name)\" (\(format.width)x\(format.height), \(mode), revision \(revision)): \(counts.joined(separator: ", ")).")
        }
        for warning in warnings { lines.append("Warning: \(warning)") }
        if let applied {
            lines.append("Applied as revision \(applied.revision). Render it with `tandem export --preset short` or look with `tandem frame <time> --format portrait`.")
        } else if !counts.isEmpty {
            lines.append("Nothing changed yet. Run again with --apply (or apply: true) to lay it out.")
        }
        return lines.joined(separator: "\n")
    }
}

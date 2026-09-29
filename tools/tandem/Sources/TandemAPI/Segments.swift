import Foundation
import TandemAssets
import TandemCore
import TandemMedia

// Segments: reusable bits of timeline (an intro, an outro, like and
// subscribe, comment below) saved into the shared library's Segments
// folder. A segment is a `Template` (the clips, their offsets and any
// fields) plus copies of the media it uses, so it keeps working whatever
// happens to the project it came from:
//
//     Tandem Library/Segments/Intro/
//       segment.json      the template and the media items, paths relative
//       intro-card.mov    the files its clips play
//       sting.wav
//
// Inserting one is one `insertTemplate` whose media clips carry their
// items with paths into the library, so the files are used where they are
// and archiving the project copies them in.

/// A saved segment, as `segment.json` has it.
public struct Segment: Codable, Equatable, Sendable {
    public static let fileName = "segment.json"
    public static let formatVersion = 1

    public var version: Int
    public var name: String
    /// The clips, as a template: offsets from the segment's start, and
    /// fields for words asked for when it goes in. Media clips name their
    /// file with `mediaPath`, relative to the segment's folder, and LUTs
    /// with a path relative to it too.
    public var template: Template
    /// The media items for those files, with paths relative to the folder.
    public var media: [MediaItem]
    public var savedAt: Date?
    /// The project it was saved from.
    public var savedFrom: String?
    /// What saving couldn't carry over, for people.
    public var notes: [String]

    public init(name: String, template: Template, media: [MediaItem], savedAt: Date? = Date(), savedFrom: String? = nil, notes: [String] = []) {
        self.version = Self.formatVersion
        self.name = name
        self.template = template
        self.media = media
        self.savedAt = savedAt
        self.savedFrom = savedFrom
        self.notes = notes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Self.formatVersion
        template = try c.decode(Template.self, forKey: .template)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? template.name
        media = try c.decodeIfPresent([MediaItem].self, forKey: .media) ?? []
        savedAt = try c.decodeIfPresent(Date.self, forKey: .savedAt)
        savedFrom = try c.decodeIfPresent(String.self, forKey: .savedFrom)
        notes = try c.decodeIfPresent([String].self, forKey: .notes) ?? []
    }
}

/// A segment in the library: its folder and what's in `segment.json`.
public struct StoredSegment: Equatable, Sendable {
    /// The folder's name, which is how the CLI and the app name it.
    public var id: String
    public var folder: URL
    public var segment: Segment

    public var name: String { segment.name }

    /// Files the segment's clips play that aren't in its folder.
    public var missingFiles: [String] {
        segment.media.map(\.path).filter { !FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
    }

    /// The template to insert: every file where it is in the library, each
    /// media clip carrying its item, so a project without the file gets it
    /// added (and one that has it already reuses it).
    public func insertableTemplate() -> Template {
        var template = segment.template
        template.id = "segment:\(id)"
        let items = Dictionary(segment.media.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        for index in template.clips.indices {
            var clip = template.clips[index]
            if let relative = clip.mediaPath {
                let path = absolute(relative)
                if var item = items[relative] ?? clip.media {
                    item.path = path
                    item.look = SegmentPaths.luts(in: item.look, resolve: absolute)
                    clip.media = item
                }
                clip.mediaPath = path
            }
            if var video = clip.clip.video {
                video.effects = SegmentPaths.luts(in: video.effects, resolve: absolute)
                clip.clip.video = video
            }
            template.clips[index] = clip
        }
        return template
    }

    /// The edit that puts it on the timeline at `at`.
    public func insertBatch(at: Time, values: [String: String] = [:], mode: InsertMode = .overwrite, label: String? = nil, author: String = "user") -> EditBatch {
        EditBatch(label: label ?? "Add segment \(name)", author: author, commands: [
            .insertTemplate(template: insertableTemplate(), at: at, values: values.isEmpty ? nil : values, mode: mode)
        ])
    }

    /// A path in `segment.json` as a path on this Mac: relative ones are
    /// in the segment's folder.
    func absolute(_ path: String) -> String {
        path.hasPrefix("/") ? path : folder.appendingPathComponent(path).standardizedFileURL.path
    }

    /// For lists: what it is at a glance.
    public var summary: SegmentSummary {
        let template = segment.template
        var tracks: [String] = []
        for clip in template.clips where !tracks.contains(clip.track) { tracks.append(clip.track) }
        return SegmentSummary(
            id: id, name: name, folder: folder.path, duration: template.duration, clips: template.clips.count,
            tracks: tracks, fields: template.fields, files: segment.media.map(\.path), missing: missingFiles,
            savedAt: segment.savedAt, savedFrom: segment.savedFrom
        )
    }
}

/// A segment for lists and agents.
public struct SegmentSummary: Codable, Equatable, Sendable {
    /// The folder's name in `Segments/`.
    public var id: String
    public var name: String
    public var folder: String
    public var duration: Time
    public var clips: Int
    /// The tracks it goes on, by name.
    public var tracks: [String]
    /// Words asked for when it goes in (`values` in `insert`).
    public var fields: [TemplateField]
    /// The files it carries, relative to its folder.
    public var files: [String]
    /// Files it carries that aren't there any more.
    public var missing: [String]
    public var savedAt: Date?
    public var savedFrom: String?
}

/// The segments in a shared library's `Segments/` folder.
public struct SegmentStore: Sendable {
    public let library: SharedLibrary
    /// What happens to a segment another one replaces: the Trash, so it
    /// can come back. Tests swap in their own.
    public var discard: @Sendable (URL) throws -> Void = { url in
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    public init(library: SharedLibrary) {
        self.library = library
    }

    public var folder: URL { library.segmentsFolder }

    /// Every segment, by name, and the folders that couldn't be read.
    public func list() -> (segments: [StoredSegment], problems: [String]) {
        let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        var segments: [StoredSegment] = []
        var problems: [String] = []
        for entry in entries {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let file = entry.appendingPathComponent(Segment.fileName)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            do {
                segments.append(try read(entry))
            } catch {
                problems.append("\(entry.lastPathComponent)/\(Segment.fileName) couldn't be read: \(ServiceError.wrap(error).message)")
            }
        }
        segments.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return (segments, problems)
    }

    /// A segment by its folder's name or its own name, ignoring case.
    public func load(_ name: String) throws -> StoredSegment {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // The folder as it's spelled on disk, which a case-insensitive
        // volume would otherwise answer to however it's typed.
        let all = list().segments
        if let found = all.first(where: { $0.id == wanted })
            ?? all.first(where: { $0.id.caseInsensitiveCompare(wanted) == .orderedSame || $0.name.caseInsensitiveCompare(wanted) == .orderedSame }) {
            return found
        }
        let names = all.map(\.name)
        let known = names.isEmpty ? "There are no segments yet." : "Segments: \(names.joined(separator: ", "))."
        throw ServiceError(.notFound, "No segment called \"\(wanted)\" in \(folder.path). \(known)")
    }

    private func read(_ folder: URL) throws -> StoredSegment {
        let data = try Data(contentsOf: folder.appendingPathComponent(Segment.fileName))
        let segment = try ServiceJSON.decoder().decode(Segment.self, from: data)
        return StoredSegment(id: folder.lastPathComponent, folder: folder.standardizedFileURL, segment: segment)
    }

    /// The folder name for a segment called `name`: the name, less what a
    /// folder name can't have.
    public static func folderName(for name: String) -> String {
        var safe = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        while safe.hasPrefix(".") { safe.removeFirst() }
        return String(safe.prefix(80)).trimmingCharacters(in: .whitespaces)
    }

    /// Writes a drafted segment into `Segments/<name>/` with copies of its
    /// files (APFS clones where they can be, dates kept), making the
    /// library's folders if they aren't there. A segment already called
    /// that is refused unless `replace`, which moves the old one to the
    /// Trash. The segment appears whole or not at all: it's put together
    /// in a hidden folder and moved into place.
    @discardableResult
    public func save(_ draft: SegmentMaker.Draft, replace: Bool = false) throws -> StoredSegment {
        let name = Self.folderName(for: draft.segment.name)
        guard !name.isEmpty else { throw ServiceError(.badRequest, "A segment needs a name.") }
        try library.create()
        let target = folder.appendingPathComponent(name, isDirectory: true)
        let exists = FileCopier.anythingAt(target)
        if exists && !replace {
            throw ServiceError(.invalid, "There's already a segment called \"\(name)\" in \(folder.path). Save it under another name, or replace it (the old one goes to the Trash).")
        }
        let staging = folder.appendingPathComponent(".\(name).tandem-saving-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            for file in draft.files {
                let destination = staging.appendingPathComponent(file.name)
                guard let info = FileCopier.fileInfo(file.source) else {
                    throw ServiceError(.notFound, "\(file.source.path) isn't there any more, so the segment wasn't saved.")
                }
                _ = try FileCopier.copy(file.source, to: destination, control: nil) { _ in }
                guard FileCopier.fileInfo(destination)?.size == info.size else {
                    throw ServiceError(.internalError, "The copy of \(file.source.lastPathComponent) came out a different size, so the segment wasn't saved.")
                }
                FileCopier.keepDate(info.modified, on: destination)
            }
            let data = try ServiceJSON.encoder(pretty: true).encode(draft.segment)
            try data.write(to: staging.appendingPathComponent(Segment.fileName), options: .atomic)
            if exists {
                do {
                    try discard(target)
                } catch {
                    throw ServiceError(.unavailable, "The old \"\(name)\" couldn't go to the Trash, so it's still there: \(error.localizedDescription)")
                }
            }
            guard try FileCopier.moveIntoPlace(staging, target) else {
                throw ServiceError(.invalid, "Something else is at \(target.path) now; nothing was saved.")
            }
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
        return try read(target)
    }
}

/// Turns clips on a timeline into a segment.
public enum SegmentMaker {
    /// A title whose words are asked for when the segment goes in.
    public struct Field: Codable, Equatable, Sendable {
        public var clipID: String
        /// The placeholder's name (`{{title}}`); made from the label when
        /// left out.
        public var key: String?
        /// What the field is called when it's asked for; the clip's name
        /// when left out.
        public var label: String?

        public init(clipID: String, key: String? = nil, label: String? = nil) {
            self.clipID = clipID
            self.key = key
            self.label = label
        }
    }

    /// A file to copy into the segment's folder, and its name there.
    public struct FileCopy: Equatable, Sendable {
        public var source: URL
        public var name: String
    }

    /// A segment ready to save, and the files it needs copied.
    public struct Draft: Sendable {
        public var segment: Segment
        public var files: [FileCopy]
    }

    /// Makes a segment called `name` of the clips `clipIDs` (exactly those:
    /// the app's selection brings linked clips along), starting where the
    /// first of them starts. Each clip goes on a track of the same name and
    /// kind. Every file the clips play is copied, once, beside the segment
    /// (a converted shared sticker named after its original), and LUTs
    /// with them. `fields` turn titles into words asked for on insert; any
    /// `{{key}}` already in a title is a field too.
    public static func draft(name: String, clipIDs: [String], in project: Project, folder: ProjectFolder, fields: [Field] = [], assetsRoot: URL? = AssetLibrary.root()) throws -> Draft {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !SegmentStore.folderName(for: name).isEmpty else { throw ServiceError(.badRequest, "A segment needs a name.") }
        var seen = Set<String>()
        let ids = clipIDs.filter { seen.insert($0).inserted }
        guard !ids.isEmpty else { throw ServiceError(.badRequest, "Choose the clips to save: select them on the timeline (or pass clip IDs, or a time range).") }

        // Clips track by track as the app shows them (video tracks top
        // down, then audio), each track's in time order.
        var picked: [(track: Track, clip: Clip)] = []
        for id in ids {
            guard let location = project.location(ofClip: id) else { throw ServiceError(.notFound, "There's no clip \(id) in the project.") }
            picked.append((project[location.track], project[location.track].clips[location.index]))
        }
        var trackOrder: [String: Int] = [:]
        for (index, track) in project.videoTracks.reversed().enumerated() { trackOrder[track.id] = index }
        for (index, track) in project.audioTracks.enumerated() { trackOrder[track.id] = project.videoTracks.count + index }
        picked.sort { (trackOrder[$0.track.id] ?? 0, $0.clip.start) < (trackOrder[$1.track.id] ?? 0, $1.clip.start) }
        let start = picked.map(\.clip.start).min() ?? .zero
        let end = picked.map(\.clip.end).max() ?? .zero

        // Tracks keep their names; two with the same name and kind become
        // "Text" and "Text 2", so their clips can't land on top of each other.
        var trackNames: [String: String] = [:]
        var usedNames = Set<String>()
        for track in project.allTracks where picked.contains(where: { $0.track.id == track.id }) {
            var candidate = track.name
            var n = 2
            while usedNames.contains("\(track.kind.rawValue)|\(candidate.lowercased())") {
                candidate = "\(track.name) \(n)"
                n += 1
            }
            usedNames.insert("\(track.kind.rawValue)|\(candidate.lowercased())")
            trackNames[track.id] = candidate
        }

        var files = Files(assetsRoot: assetsRoot)
        var notes: [String] = []
        var media: [String: MediaItem] = [:]
        var mediaOrder: [String] = []
        var clips: [TemplateClip] = []
        for (track, original) in picked {
            var clip = original
            clip.start = .zero
            clip.linkGroup = nil
            clip.tags.removeAll { $0.hasPrefix("template:") }
            var mediaPath: String?
            if let mediaID = original.mediaID {
                guard let item = project.media(mediaID) else { throw ServiceError(.notFound, "Clip \(original.id) plays media \(mediaID), which isn't in the project.") }
                if media[mediaID] == nil {
                    let url = folder.url(for: item)
                    guard FileCopier.fileInfo(url) != nil else {
                        throw ServiceError(.notFound, "\(item.path) is missing, so the segment can't carry it. Relink it first (tandem relink).")
                    }
                    var copy = item
                    copy.path = try files.add(url)
                    copy.takeID = nil
                    copy.takeOffset = nil
                    copy.look = try files.luts(in: item.look, folder: folder, notes: &notes)
                    media[mediaID] = copy
                    mediaOrder.append(mediaID)
                }
                mediaPath = media[mediaID]?.path
                clip.content = .media(mediaID: "")
            }
            if var video = clip.video {
                video.effects = try files.luts(in: video.effects, folder: folder, notes: &notes)
                clip.video = video
            }
            clips.append(TemplateClip(track: trackNames[track.id] ?? track.name, trackKind: track.kind, offset: original.start - start, clip: clip, mediaPath: mediaPath))
        }

        // Words asked for on insert.
        var templateFields: [TemplateField] = []
        var keys = Set<String>()
        for (number, choice) in fields.enumerated() {
            guard let index = picked.firstIndex(where: { $0.clip.id == choice.clipID }) else {
                throw ServiceError(.notFound, "Clip \(choice.clipID) isn't one of the clips being saved, so it can't be a field.")
            }
            guard case .text(var text) = clips[index].clip.content else {
                throw ServiceError(.invalid, "Clip \(choice.clipID) isn't a title, so it can't be a field.")
            }
            let label = choice.label ?? picked[index].clip.name ?? "Text \(number + 1)"
            let key = uniqueKey(choice.key ?? label, taken: &keys)
            templateFields.append(TemplateField(key: key, label: label, defaultValue: text.text))
            text.text = "{{\(key)}}"
            clips[index].clip.content = .text(text)
        }
        for clip in clips {
            guard case .text(let text) = clip.clip.content else { continue }
            for key in placeholders(in: text.text) where !keys.contains(key) {
                keys.insert(key)
                templateFields.append(TemplateField(key: key, label: key, defaultValue: ""))
            }
        }

        // Transitions come along when every clip they join is saved: a
        // dissolve between two of them, a fade at one's head or tail.
        let places = Dictionary(uniqueKeysWithValues: picked.enumerated().map { ($0.element.clip.id, $0.offset) })
        var transitions: [TemplateTransition] = []
        var halfSaved = 0
        var seenTracks = Set<String>()
        for track in picked.map(\.track) where seenTracks.insert(track.id).inserted {
            for transition in track.transitions {
                let from = transition.fromClipID.flatMap { places[$0] }
                let to = transition.toClipID.flatMap { places[$0] }
                guard from != nil || to != nil else { continue }
                guard (transition.fromClipID == nil) == (from == nil), (transition.toClipID == nil) == (to == nil) else {
                    halfSaved += 1
                    continue
                }
                transitions.append(TemplateTransition(from: from, to: to, type: transition.type, direction: transition.direction, duration: transition.duration))
            }
        }
        if halfSaved > 0 {
            notes.append("\(halfSaved == 1 ? "A transition" : "\(halfSaved) transitions") to a clip that isn't in the segment \(halfSaved == 1 ? "is" : "are") left out.")
        }

        let folderName = SegmentStore.folderName(for: name)
        let template = Template(id: "segment:\(folderName)", name: name, duration: end - start, fields: templateFields, clips: clips, transitions: transitions)
        let segment = Segment(name: name, template: template, media: mediaOrder.compactMap { media[$0] }, savedFrom: project.name, notes: notes)
        return Draft(segment: segment, files: files.copies)
    }

    /// `{{key}}` placeholders in a title, in order.
    static func placeholders(in text: String) -> [String] {
        var found: [String] = []
        var rest = Substring(text)
        while let open = rest.range(of: "{{"), let close = rest.range(of: "}}", range: open.upperBound..<rest.endIndex) {
            let key = rest[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty, !found.contains(key) { found.append(key) }
            rest = rest[close.upperBound...]
        }
        return found
    }

    /// A placeholder name from a label: "Section title" is `sectionTitle`.
    static func uniqueKey(_ label: String, taken: inout Set<String>) -> String {
        let words = label.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        var key = words.enumerated().map { $0.offset == 0 ? $0.element.lowercased() : $0.element.prefix(1).uppercased() + $0.element.dropFirst().lowercased() }.joined()
        if key.isEmpty { key = "text" }
        var candidate = key
        var n = 2
        while taken.contains(candidate) {
            candidate = "\(key)\(n)"
            n += 1
        }
        taken.insert(candidate)
        return candidate
    }

    /// The files a segment copies, each once, with names that don't clash.
    struct Files {
        let assetsRoot: URL?
        var copies: [FileCopy] = []
        private var bySource: [String: String] = [:]
        private var taken = Set<String>([Segment.fileName.lowercased()])

        init(assetsRoot: URL?) {
            self.assetsRoot = assetsRoot
        }

        /// The name `url` gets in the segment's folder.
        mutating func add(_ url: URL) throws -> String {
            let real = ProjectArchiver.realPath(url) ?? url.standardizedFileURL.path
            if let known = bySource[real] { return known }
            var name = url.lastPathComponent
            // The library's converted copy of a shared sticker is named
            // after the sticker, not "normalised.mov".
            if let assetsRoot, let original = AssetLibrary.sharedOriginal(of: URL(fileURLWithPath: real), assetsRoot: assetsRoot) {
                name = "\(((original as NSString).lastPathComponent as NSString).deletingPathExtension).\(url.pathExtension)"
            }
            var n = 1
            while taken.contains(FileCopier.alongside(name, n).lowercased()) { n += 1 }
            name = FileCopier.alongside(name, n)
            taken.insert(name.lowercased())
            bySource[real] = name
            copies.append(FileCopy(source: URL(fileURLWithPath: real), name: name))
            return name
        }

        /// `effects` with each LUT copied and pointed at its copy. A LUT
        /// that isn't there is left pointing where it was, with a note.
        mutating func luts(in effects: [Effect], folder: ProjectFolder, notes: inout [String]) throws -> [Effect] {
            var result = effects
            for index in result.indices {
                guard let path = ProjectArchiver.lutPath(result[index]) else { continue }
                let url = folder.url(forPath: path)
                guard FileCopier.fileInfo(url) != nil else {
                    let note = "The look \(path) is missing, so the segment points where it was."
                    if !notes.contains(note) { notes.append(note) }
                    result[index].params["path"] = .string(url.path)
                    continue
                }
                result[index].params["path"] = .string(try add(url))
            }
            return result
        }
    }
}

/// LUT paths in a segment's effects.
enum SegmentPaths {
    /// `effects` with every LUT's path passed through `resolve`.
    static func luts(in effects: [Effect], resolve: (String) -> String) -> [Effect] {
        var result = effects
        for index in result.indices {
            guard let path = ProjectArchiver.lutPath(result[index]) else { continue }
            result[index].params["path"] = .string(resolve(path))
        }
        return result
    }
}

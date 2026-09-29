import CryptoKit
import Foundation
import TandemCore
import TandemMedia

/// An asset copied into a project, ready to add: submit
/// `.addMedia(item: mediaItem)` (skip it if the project already has that
/// media ID) and place it on `trackName` with `audio` as the clip's sound.
public struct AssetPlacement: Codable, Sendable {
    public var asset: Asset
    /// Nil for fonts and LUTs, which are installed rather than placed.
    /// Its ID is the same every time this asset is used, so using an asset
    /// twice in one project doesn't add it twice.
    public var mediaItem: MediaItem?
    /// The files the project uses, as it refers to them: copies relative to
    /// the project folder, or (`referencedInPlace`) the shared library's
    /// files where they are.
    public var files: [String]
    public var role: MediaRole
    /// The track it belongs on in Mike's standard layout.
    public var trackName: String?
    /// Suggested clip audio: music at -31 dB with a 2 s fade out, sound
    /// effects at -15 dB (from the Filmora audit of 51 projects).
    public var audio: AudioProperties?
    /// True for a shared library asset: nothing was copied, and the project
    /// refers to the library's file, so changing it there changes it in
    /// every project. Archiving copies it in.
    public var referencedInPlace = false

    /// The suggested clip gain, in dB.
    public var gainDB: Double? { audio?.gainDB }
}

/// Credits for the video description, built from what a project uses.
public struct ProjectCredits: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var line: String
        /// True when the licence asks for the credit; false for courtesy
        /// credits (Pexels creators).
        public var required: Bool
        public var licenceClass: LicenceClass
        public var assetIDs: [String]
        public var assetNames: [String]
    }

    /// One asset the project uses, for a review panel.
    public struct UsedAsset: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var provider: String
        public var licenceClass: LicenceClass
        public var licence: String?
    }

    public var entries: [Entry]
    /// Things to sort out before publishing: unknown licences, credits
    /// without a line, subscriptions to keep in good standing.
    public var warnings: [String]
    public var assets: [UsedAsset]

    /// The block to paste into the YouTube description. Empty when nothing
    /// needs a credit.
    public func text(includeOptional: Bool = false) -> String {
        let required = entries.filter(\.required).map(\.line)
        let optional = includeOptional ? entries.filter { !$0.required }.map(\.line) : []
        guard !required.isEmpty || !optional.isEmpty else { return "" }
        var lines = ["Credits"] + required
        if !optional.isEmpty {
            if !required.isEmpty { lines.append("") }
            lines.append("Thanks to")
            lines += optional
        }
        return lines.joined(separator: "\n")
    }
}

extension AssetLibrary {
    // MARK: - Using an asset in a project

    /// Where assets go inside a project: `assets/<kind>/`.
    public static func projectFolder(for kind: AssetKind, in project: ProjectFolder) -> URL {
        project.assetsFolder.appendingPathComponent(kind.rawValue, isDirectory: true)
    }

    /// A short, stable code for an asset ID, used for its media ID and file
    /// name in a project.
    static func shortCode(_ assetID: String) -> String {
        let alphabet = Array("abcdefghijkmnpqrstuvwxyz23456789")
        let digest = Array(SHA256.hash(data: Data(assetID.utf8)))
        return String((0..<8).map { alphabet[Int(digest[$0]) % alphabet.count] })
    }

    /// The media ID an asset gets in any project.
    public static func mediaID(for assetID: String) -> String {
        "med_\(shortCode(assetID))"
    }

    /// The track, role and audio defaults for an asset kind.
    public static func suggestions(for kind: AssetKind) -> (role: MediaRole, track: String?, audio: AudioProperties?) {
        switch kind {
        case .music: return (.music, "Music", AudioProperties(gainDB: -31, fadeOut: Time(seconds: 2)))
        case .sfx: return (.sfx, "SFX", AudioProperties(gainDB: -15))
        case .sticker: return (.sticker, "Graphics", nil)
        case .overlay, .icon, .logo: return (.graphic, "Graphics", nil)
        case .video, .image: return (.broll, "B-roll", nil)
        case .title: return (.graphic, "Text", nil)
        case .font, .lut, .transition: return (.other, nil, nil)
        }
    }

    /// Fetches the asset if needed, copies it into
    /// `<project>/assets/<kind>/`, records the use and returns a media item
    /// with suggested role, track and gain. Fonts are copied and registered
    /// but get no media item.
    ///
    /// A shared library asset isn't copied: the project refers to the file
    /// where it is (`referencedInPlace`), the library's own file, or for
    /// one a project can't play as it is (WebM, Lottie, SVG) the library's
    /// converted copy, which is made again when the file changes.
    public func use(_ id: String, in project: ProjectFolder, projectID: String, projectFile: URL? = nil) async throws -> AssetPlacement {
        let asset = try await fetch(id)
        guard let source = playableURL(for: asset), FileManager.default.fileExists(atPath: source.path) else {
            throw AssetError.notFound("the file for \(asset.name)")
        }
        if asset.provider == SharedLibraryProvider.providerID {
            return try await reference(asset, file: source, in: project, projectID: projectID, projectFile: projectFile)
        }
        let destinationFolder = Self.projectFolder(for: asset.kind, in: project)
        try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
        let code = Self.shortCode(asset.id)
        let slug = LocalMatcher.tokens(asset.name).joined(separator: "-").prefix(40)
        let base = slug.isEmpty ? code : "\(slug)-\(code)"

        var copied: [URL] = []
        func copy(_ file: URL, as name: String) throws -> URL {
            let fileManager = FileManager.default
            func size(_ url: URL) -> Int64? {
                (try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? Int64
            }
            let sourceSize = size(file)
            // A file already there that isn't this one (Mike reworked the
            // copy, or the library's file changed since the timeline started
            // using it) is never replaced: the copy goes beside it.
            let stem = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            var destination = destinationFolder.appendingPathComponent(name)
            var counter = 2
            while fileManager.fileExists(atPath: destination.path) || (try? fileManager.destinationOfSymbolicLink(atPath: destination.path)) != nil {
                if let sourceSize, size(destination) == sourceSize { break }
                destination = destinationFolder.appendingPathComponent(ext.isEmpty ? "\(stem) \(counter)" : "\(stem) \(counter).\(ext)")
                counter += 1
            }
            if !fileManager.fileExists(atPath: destination.path) {
                // copyItem clones on APFS, so this costs no extra space
                // when the project is on the same volume as the library.
                try fileManager.copyItem(at: file, to: destination)
            }
            copied.append(destination)
            return destination
        }
        let main = try copy(source, as: "\(base).\(source.pathExtension.lowercased())")
        if asset.kind == .font {
            let folder = self.folder(for: asset)
            for extra in (asset.remote["extraFiles"] ?? "").split(separator: "\n") {
                let file = folder.appendingPathComponent(String(extra))
                if FileManager.default.fileExists(atPath: file.path) { _ = try copy(file, as: String(extra)) }
            }
            await FontInstaller.register(copied)
        }

        let (role, track, audio) = Self.suggestions(for: asset.kind)
        let mediaPath = project.path(for: main)
        let item = mediaItem(for: asset, path: mediaPath, role: role)
        try catalog.recordUsage(AssetUsage(
            assetID: asset.id,
            projectID: projectID,
            projectPath: (projectFile ?? project.root).path,
            mediaID: item?.id,
            mediaPath: mediaPath
        ))
        return AssetPlacement(asset: asset, mediaItem: item, files: copied.map(project.path(for:)), role: role, trackName: track, audio: audio)
    }

    /// Uses a shared library asset where it is: no copy, the path to the
    /// file as the project stores it (absolute, unless the library is in
    /// the project's folder), and the use recorded for the credits.
    private func reference(_ asset: Asset, file: URL, in project: ProjectFolder, projectID: String, projectFile: URL?) async throws -> AssetPlacement {
        var files = [file]
        if asset.kind == .font {
            let folder = self.folder(for: asset)
            files += (asset.remote["extraFiles"] ?? "").split(separator: "\n").map { folder.appendingPathComponent(String($0)) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            await FontInstaller.register(files)
        }
        let (role, track, audio) = Self.suggestions(for: asset.kind)
        let mediaPath = project.path(for: file)
        let item = mediaItem(for: asset, path: mediaPath, role: role)
        try catalog.recordUsage(AssetUsage(
            assetID: asset.id,
            projectID: projectID,
            projectPath: (projectFile ?? project.root).path,
            mediaID: item?.id,
            mediaPath: mediaPath
        ))
        return AssetPlacement(asset: asset, mediaItem: item, files: files.map(project.path(for:)), role: role, trackName: track, audio: audio, referencedInPlace: true)
    }

    /// The media item for an asset's copy in a project.
    func mediaItem(for asset: Asset, path: String, role: MediaRole) -> MediaItem? {
        let kind: MediaKind
        switch asset.remote["mediaKind"].flatMap(MediaKind.init(rawValue:)) {
        case .some(let known): kind = known
        case .none:
            switch asset.kind {
            case .music, .sfx: kind = .audio
            case .image, .icon, .logo: kind = .image
            case .sticker, .overlay, .video: kind = .video
            case .font, .lut, .title, .transition: return nil
            }
        }
        if asset.kind == .font || asset.kind == .lut { return nil }
        let hasAudio = asset.remote["hasAudio"].map { $0 == "1" } ?? (kind == .audio)
        let hasVideo = asset.remote["hasVideo"].map { $0 == "1" } ?? (kind != .audio)
        return MediaItem(
            id: Self.mediaID(for: asset.id),
            path: path,
            kind: kind,
            role: role,
            duration: kind == .image ? nil : asset.duration.map { Time(seconds: $0) },
            frameRate: asset.remote["frameRate"].flatMap(Double.init).map(Self.frameRate),
            width: asset.width,
            height: asset.height,
            hasVideo: kind == .image ? true : hasVideo,
            hasAudio: hasAudio,
            hasAlpha: asset.hasAlpha
        )
    }

    /// An exact frame rate for a measured one: whole numbers stay whole,
    /// NTSC rates become their 1001 fractions, anything else is kept to
    /// the millisecond.
    static func frameRate(_ fps: Double) -> FrameRate {
        let whole = fps.rounded()
        if abs(fps - whole) < 0.01 { return FrameRate(Int64(whole)) }
        for base in [24.0, 30.0, 60.0] where abs(fps - base * 1000 / 1001) < 0.01 {
            return FrameRate(Int64(base * 1000), 1001)
        }
        return FrameRate(Int64((fps * 1000).rounded()), 1000)
    }

    // MARK: - Credits

    /// The tag a clip carries for the catalogue asset its file or look came
    /// from when it arrived some other way than being used from the
    /// library (in a saved segment): `asset:<id>`.
    public static let assetTagPrefix = "asset:"

    /// Credits for every asset the project uses now: assets recorded as
    /// used in this project whose media is still in it, and assets a clip
    /// still on the timeline names in an `asset:` tag (a segment's sticker
    /// or sound). Fonts and LUTs have no media item, so they count while
    /// their copy is still in the project folder (or always, when no folder
    /// is given).
    public func credits(for project: Project, in folder: ProjectFolder? = nil) throws -> ProjectCredits {
        let mediaIDs = Set(project.media.map(\.id))
        let mediaPaths = Set(project.media.map(\.path))
        var ids: [String] = []
        for use in try catalog.usage(forProject: project.id) {
            let current: Bool
            if let mediaID = use.mediaID {
                current = mediaIDs.contains(mediaID) || use.mediaPath.map(mediaPaths.contains) ?? false
            } else if let path = use.mediaPath, let folder {
                current = FileManager.default.fileExists(atPath: folder.url(forPath: path).path)
            } else {
                current = true
            }
            if current, !ids.contains(use.assetID) { ids.append(use.assetID) }
        }
        for tag in project.allTracks.flatMap(\.clips).flatMap(\.tags) where tag.hasPrefix(Self.assetTagPrefix) {
            let id = String(tag.dropFirst(Self.assetTagPrefix.count))
            if !id.isEmpty, !ids.contains(id) { ids.append(id) }
        }
        return try credits(assetIDs: ids)
    }

    /// Credits for a list of assets, in the order given.
    public func credits(assetIDs: [String]) throws -> ProjectCredits {
        var entries: [ProjectCredits.Entry] = []
        var used: [ProjectCredits.UsedAsset] = []
        var unknown: [String] = []
        var missingLines: [String] = []
        var subscriptions: [String: (count: Int, notes: String?)] = [:]
        var subscriptionOrder: [String] = []

        for id in assetIDs {
            let asset = try catalog.asset(id: id)
            let licence = try catalog.licence(for: id)
            let name = asset?.name ?? id
            let licenceClass = licence?.licenceClass ?? asset?.licenceClass ?? .unknown
            used.append(ProjectCredits.UsedAsset(id: id, name: name, provider: asset?.provider ?? Asset.parseID(id)?.provider ?? "", licenceClass: licenceClass, licence: licence?.name))
            let line = licence?.creditLine ?? asset?.creditLine
            switch licenceClass {
            case .unknown:
                unknown.append(name)
            case .creditNeeded where line == nil:
                missingLines.append(name)
            case .subscription:
                let source = licence?.holder ?? licence?.name ?? asset?.provider ?? "a subscription"
                if subscriptions[source] == nil { subscriptionOrder.append(source) }
                subscriptions[source, default: (0, licence?.notes)].count += 1
            default:
                break
            }
            guard let line else { continue }
            let required = licenceClass == .creditNeeded || licenceClass == .unknown
            if let index = entries.firstIndex(where: { $0.line == line }) {
                entries[index].assetIDs.append(id)
                entries[index].assetNames.append(name)
                entries[index].required = entries[index].required || required
            } else {
                entries.append(ProjectCredits.Entry(line: line, required: required, licenceClass: licenceClass, assetIDs: [id], assetNames: [name]))
            }
        }

        var warnings: [String] = []
        if !unknown.isEmpty {
            warnings.append("No licence on record for \(Self.list(unknown)). Add a \(FolderLicence.fileName) to their import folder, or replace them.")
        }
        if !missingLines.isEmpty {
            let one = missingLines.count == 1
            warnings.append("\(Self.list(missingLines)) \(one ? "needs" : "need") a credit but \(one ? "has" : "have") no credit line. Check the licence and write one.")
        }
        for source in subscriptionOrder {
            guard let entry = subscriptions[source] else { continue }
            let count = entry.count == 1 ? "1 asset" : "\(entry.count) assets"
            let advice = entry.notes ?? "Covered only while the subscription is active on a plan that allows this channel."
            warnings.append("\(count) from \(source). \(advice)")
        }
        return ProjectCredits(entries: entries, warnings: warnings, assets: used)
    }

    /// "a", "a and b", "a, b and c".
    static func list(_ names: [String]) -> String {
        let quoted = names.map { "\"\($0)\"" }
        guard quoted.count > 1 else { return quoted.first ?? "" }
        return quoted.dropLast().joined(separator: ", ") + " and " + quoted.last!
    }
}

extension AssetPlacement {
    /// The edits that put this asset on the timeline at `time`: `addMedia`
    /// unless the project already has the media, then `placeMedia`, which
    /// routes it to the track for its role and applies the music and SFX
    /// levels. Images last 5 s unless `duration` says otherwise. Fonts and
    /// LUTs need no edits.
    public func editCommands(at time: Time, in project: Project, duration: Time? = nil, mode: InsertMode? = nil) -> [EditCommand] {
        guard let item = mediaItem else { return [] }
        var commands: [EditCommand] = []
        if project.media(item.id) == nil { commands.append(.addMedia(item: item)) }
        commands.append(.placeMedia(mediaIDs: [item.id], at: time, duration: duration, mode: mode))
        return commands
    }
}

import Foundation
import TandemCore

/// The media browser's groups, built from the project's media list.
enum MediaGroupKind: String, CaseIterable, Identifiable {
    case recordings, graphics, broll, images, music, sfx, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recordings: return "Recordings"
        case .graphics: return "Graphics"
        case .broll: return "B-roll"
        case .images: return "Images"
        case .music: return "Music"
        case .sfx: return "SFX"
        case .other: return "Other"
        }
    }

    /// The filter chip label.
    var chip: String {
        switch self {
        case .recordings: return "takes"
        case .graphics: return "graphics"
        case .broll: return "broll"
        case .images: return "images"
        case .music: return "music"
        case .sfx: return "sfx"
        case .other: return "other"
        }
    }

    /// Grids of thumbnails, or rows.
    var isGrid: Bool { self == .graphics || self == .broll || self == .images }
}

/// One thing in the browser: a paired take, or a single file.
struct MediaEntry: Identifiable, Equatable {
    /// The take ID, or the media ID for single files.
    var id: String
    var title: String
    var subtitle: String
    /// What gets placed when it's dragged to the timeline, in sync.
    var mediaIDs: [String]
    /// The file whose picture represents the entry (the camera for a take).
    var primaryMediaID: String
    /// The screen recording behind the camera thumbnail, for takes.
    var secondaryMediaID: String?
    var duration: Time?
    var group: MediaGroupKind
    /// File names, for search.
    var searchText: String
}

struct MediaGroup: Identifiable, Equatable {
    var kind: MediaGroupKind
    /// Where the files came from, like "motion-graphics/out".
    var detail: String?
    var entries: [MediaEntry]

    var id: String { kind.rawValue }
}

enum MediaCatalog {
    static func group(for item: MediaItem) -> MediaGroupKind {
        switch item.role {
        case .camera, .screen: return .recordings
        case .graphic, .sticker: return .graphics
        case .broll: return .broll
        case .image: return .images
        case .music: return .music
        case .sfx: return .sfx
        case .other: return item.kind == .audio ? .sfx : (item.kind == .image ? .images : .other)
        }
    }

    static func fileName(_ item: MediaItem) -> String {
        URL(fileURLWithPath: item.path).lastPathComponent
    }

    static func baseName(_ item: MediaItem) -> String {
        displayName(forPath: item.path)
    }

    /// A file's name without its extension. Copies the asset library made
    /// (`assets/<kind>/rocket-x3iqg3mw.mov`) lose their eight letter code.
    static func displayName(forPath path: String) -> String {
        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let folders = path.split(separator: "/").dropLast()
        guard folders.count >= 2, folders[folders.count - 2] == "assets",
              let dash = name.lastIndex(of: "-"), name.index(after: dash) < name.endIndex else { return name }
        let code = name[name.index(after: dash)...]
        let alphabet = Set("abcdefghijkmnpqrstuvwxyz23456789")
        guard code.count == 8, code.allSatisfy(alphabet.contains) else { return name }
        return String(name[..<dash])
    }

    /// A short name for status lines: record-it files read "camera 10:54",
    /// anything else its file name without the extension.
    static func shortName(_ item: MediaItem) -> String {
        if item.role == .camera || item.role == .screen, let time = timeOfDay(fromFileName: fileName(item)) {
            return "\(item.role == .camera ? "camera" : "screen") \(time)"
        }
        return baseName(item)
    }

    /// The time of day a record-it file was made, from its name
    /// (`2026-09-24_102826-camera.mov` is 10:28).
    static func timeOfDay(fromFileName name: String) -> String? {
        guard let match = name.range(of: #"_(\d{2})(\d{2})\d{2}"#, options: .regularExpression) else { return nil }
        let digits = name[match].dropFirst()
        let hours = digits.prefix(2)
        let minutes = digits.dropFirst(2).prefix(2)
        return "\(hours):\(minutes)"
    }

    /// Groups the media, pairing takes, in a stable order. `search` matches
    /// titles and file names, case-insensitively.
    static func groups(for project: Project, search: String = "", only filter: MediaGroupKind? = nil) -> [MediaGroup] {
        var entries: [MediaEntry] = []
        var takes: [String: [MediaItem]] = [:]
        for item in project.media {
            if let take = item.takeID, item.role == .camera || item.role == .screen {
                takes[take, default: []].append(item)
            } else {
                entries.append(single(item))
            }
        }
        // Takes in time order: by the earliest file name, which record-it
        // stamps with the date and time.
        let ordered = takes.sorted { a, b in
            (a.value.map(\.path).min() ?? a.key) < (b.value.map(\.path).min() ?? b.key)
        }
        for (index, (takeID, items)) in ordered.enumerated() {
            let camera = items.first { $0.role == .camera }
            let screen = items.first { $0.role == .screen }
            let primary = camera ?? items[0]
            let duration = items.compactMap(\.duration).max()
            var title = "Take \(index + 1)"
            if let time = items.compactMap({ timeOfDay(fromFileName: fileName($0)) }).first {
                title += " · \(time)"
            }
            let subtitle = [duration.map { Timecode.duration($0.seconds) }, "\(items.count) \(items.count == 1 ? "file" : "files")"].compactMap { $0 }.joined(separator: " · ")
            entries.append(MediaEntry(
                id: takeID,
                title: title,
                subtitle: subtitle,
                mediaIDs: items.sorted { $0.role == .camera && $1.role != .camera }.map(\.id),
                primaryMediaID: primary.id,
                secondaryMediaID: screen?.id == primary.id ? nil : screen?.id,
                duration: duration,
                group: .recordings,
                searchText: ([title] + items.map(fileName)).joined(separator: " ").lowercased()
            ))
        }
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            // The whole phrase first ("take 2"), then every word in any order.
            let phrase = entries.filter { $0.searchText.contains(query) }
            if !phrase.isEmpty {
                entries = phrase
            } else {
                let words = query.split(separator: " ").map(String.init)
                entries = entries.filter { entry in words.allSatisfy { entry.searchText.contains($0) } }
            }
        }
        var groups: [MediaGroup] = []
        for kind in MediaGroupKind.allCases where filter == nil || filter == kind {
            var members = entries.filter { $0.group == kind }
            guard !members.isEmpty else { continue }
            if kind != .recordings { members.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending } }
            let folders = Set(members.flatMap(\.mediaIDs).compactMap { project.media($0) }.map { ($0.path as NSString).deletingLastPathComponent })
            let detail: String? = kind == .recordings ? "camera + screen" : (folders.count == 1 ? folders.first.flatMap { $0.isEmpty || $0.hasPrefix("/") ? nil : $0 } : nil)
            groups.append(MediaGroup(kind: kind, detail: detail, entries: members))
        }
        return groups
    }

    private static func single(_ item: MediaItem) -> MediaEntry {
        var name = baseName(item)
        // An unpaired record-it file reads as "Camera · 10:54".
        if item.role == .camera || item.role == .screen, let time = timeOfDay(fromFileName: fileName(item)) {
            name = "\(item.role == .camera ? "Camera" : "Screen") · \(time)"
        }
        let subtitle: String
        if let duration = item.duration, item.kind != .image {
            subtitle = Timecode.duration(duration.seconds)
        } else if let w = item.width, let h = item.height {
            subtitle = "\(w)×\(h)"
        } else {
            subtitle = item.kind.rawValue
        }
        return MediaEntry(
            id: item.id, title: name, subtitle: subtitle, mediaIDs: [item.id], primaryMediaID: item.id,
            secondaryMediaID: nil, duration: item.duration, group: group(for: item),
            searchText: (name + " " + baseName(item) + " " + item.path).lowercased()
        )
    }
}

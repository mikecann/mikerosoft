import CoreGraphics
import Foundation
import TandemAssets
import TandemCore

/// The sections of the Audio and Graphics tabs, each a part of the asset
/// library's left rail (`BrowserSection`).
enum AssetSection: String, CaseIterable, Identifiable {
    case music, sfx, stickers, icons, broll

    var id: String { rawValue }

    /// The Audio tab's sections, then the Graphics tab's.
    static let audio: [AssetSection] = [.music, .sfx]
    static let graphics: [AssetSection] = [.stickers, .icons, .broll]

    var title: String {
        switch self {
        case .music: return "Music"
        case .sfx: return "SFX"
        case .stickers: return "Stickers"
        case .icons: return "Icons"
        case .broll: return "B-roll"
        }
    }

    var browserSection: BrowserSection {
        switch self {
        case .music: return .music
        case .sfx: return .sfx
        case .stickers: return .stickers
        case .icons: return .iconsAndLogos
        case .broll: return .overlaysAndBroll
        }
    }

    var kinds: Set<AssetKind> { browserSection.kinds }
    var isAudio: Bool { self == .music || self == .sfx }

    var searchPrompt: String {
        switch self {
        case .music: return "Search music"
        case .sfx: return "Search sound effects"
        case .stickers: return "Search stickers"
        case .icons: return "Search icons and logos"
        case .broll: return "Search B-roll and overlays"
        }
    }

    /// Width over height of a tile; audio lists rows instead.
    var tileAspect: CGFloat {
        switch self {
        case .broll: return 82.0 / 48.0
        default: return 1
        }
    }
}

/// Which part of the library a section shows.
enum AssetScope: String, CaseIterable, Identifiable {
    case all, favourites, recent, downloaded, inProject

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .favourites: return "Favourites"
        case .recent: return "Recent"
        case .downloaded: return "Downloaded"
        case .inProject: return "In project"
        }
    }
}

/// The browser's filters: licence, length, tempo and transparency. Each
/// only applies where it means something (no tempo for stickers).
struct AssetFilters: Equatable {
    enum Length: String, CaseIterable, Identifiable {
        case any, underTwo, twoToTen, tenToSixty, overMinute

        var id: String { rawValue }

        var title: String {
            switch self {
            case .any: return "Any length"
            case .underTwo: return "Under 2 s"
            case .twoToTen: return "2 to 10 s"
            case .tenToSixty: return "10 s to a minute"
            case .overMinute: return "Over a minute"
            }
        }

        var range: (min: Double?, max: Double?) {
            switch self {
            case .any: return (nil, nil)
            case .underTwo: return (nil, 2)
            case .twoToTen: return (2, 10)
            case .tenToSixty: return (10, 60)
            case .overMinute: return (60, nil)
            }
        }
    }

    enum Tempo: String, CaseIterable, Identifiable {
        case any, slow, medium, fast

        var id: String { rawValue }

        var title: String {
            switch self {
            case .any: return "Any tempo"
            case .slow: return "Slow, under 90 BPM"
            case .medium: return "Medium, 90 to 120 BPM"
            case .fast: return "Fast, over 120 BPM"
            }
        }

        var range: (min: Double?, max: Double?) {
            switch self {
            case .any: return (nil, nil)
            case .slow: return (nil, 90)
            case .medium: return (90, 120)
            case .fast: return (120, nil)
            }
        }
    }

    var licences: Set<LicenceClass> = []
    var duration: Length = .any
    var tempo: Tempo = .any
    var transparentOnly = false

    var isActive: Bool { !licences.isEmpty || duration != .any || tempo != .any || transparentOnly }
}

/// How the browser turns what's on screen into library calls, and the
/// words it shows on tiles.
enum AssetBrowsing {
    /// The catalogue query for a section, scope, search text, source chip
    /// and filters.
    static func query(section: AssetSection, scope: AssetScope, text: String, provider: String?, filters: AssetFilters, projectID: String?, limit: Int = 240) -> AssetQuery {
        var query: AssetQuery
        switch scope {
        case .all: query = AssetQuery()
        case .favourites: query = .favourites()
        case .recent: query = .recentlyUsed()
        case .downloaded: query = .downloaded()
        case .inProject: query = .inProject(projectID ?? "")
        }
        query.kinds = section.kinds
        query.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        query.limit = limit
        if let provider { query.providers = [provider] }
        query.licenceClasses = filters.licences
        if section.isAudio || section == .broll {
            query.minDuration = filters.duration.range.min
            query.maxDuration = filters.duration.range.max
        }
        if section == .music {
            query.minBPM = filters.tempo.range.min
            query.maxBPM = filters.tempo.range.max
        }
        if !section.isAudio, filters.transparentOnly { query.hasAlpha = true }
        return query
    }

    /// The same search sent to the providers.
    static func providerQuery(section: AssetSection, text: String, filters: AssetFilters, perPage: Int = 30) -> ProviderQuery {
        var query = ProviderQuery(text: text.trimmingCharacters(in: .whitespacesAndNewlines), kinds: section.kinds, perPage: perPage)
        if section.isAudio || section == .broll {
            query.minDuration = filters.duration.range.min
            query.maxDuration = filters.duration.range.max
        }
        return query
    }

    /// The providers that offer a section's kinds, in the library's order.
    static func sources(for section: AssetSection, in providers: [ProviderInfo]) -> [ProviderInfo] {
        providers.filter { !Set($0.kinds).isDisjoint(with: section.kinds.map(\.rawValue)) }
    }

    /// A source's name for a chip: "Noto animated emoji" is just "Noto".
    static func sourceName(_ displayName: String) -> String {
        let short = [
            "Noto animated emoji": "Noto", "SVGL logos": "SVGL", "Google Fonts (Fontsource)": "Google Fonts",
            "Import folders": "Your folders", "Epidemic Sound": "Epidemic"
        ]
        return short[displayName] ?? displayName
    }

    /// What the providers found that isn't listed already, a group per
    /// provider, keeping the ones that failed so the reason shows.
    static func onlineGroups(_ results: [AssetLibrary.ProviderResults], excluding local: [Asset]) -> [(provider: String, assets: [Asset], error: String?)] {
        let listed = Set(local.map(\.id))
        return results.compactMap { result in
            let fresh = result.assets.filter { !listed.contains($0.id) }
            guard !fresh.isEmpty || result.error != nil else { return nil }
            return (result.provider, fresh, result.error)
        }
    }

    /// "0:03", "1:24", "1:00:01"; under a second shows tenths.
    static func durationText(_ seconds: Double?) -> String? {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return nil }
        if seconds < 1 { return String(format: "0:00.%d", Int((seconds * 10).rounded(.down))) }
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }

    /// The licence class on a tile: short enough for 82 points, and never
    /// "No licence", which could read as "needs none".
    static func licenceLabel(_ licence: LicenceClass) -> String {
        licence.label
    }

    /// Length and tempo for a row: "1:33 · 118 BPM".
    static func details(_ asset: Asset) -> String {
        var parts: [String] = []
        if asset.kind.isAudio || asset.kind == .video, let duration = durationText(asset.duration) { parts.append(duration) }
        if let bpm = asset.bpm { parts.append("\(Int(bpm.rounded())) BPM") }
        return parts.joined(separator: " · ")
    }
}

/// Turns a used asset into the edit that puts it on the timeline.
enum AssetPlacing {
    /// `placement.editCommands(at:in:)`, except that a media item already
    /// pointing at the copied file is reused: the project's folder watcher
    /// can add the file under its own ID before the edit lands. Like a
    /// media drop, it overwrites what's there (Cmd inserts).
    static func commands(for placement: AssetPlacement, at time: Time, in project: Project, mode: InsertMode = .overwrite) -> [EditCommand] {
        var placement = placement
        if var item = placement.mediaItem, project.media(item.id) == nil,
           let existing = project.media.first(where: { $0.path == item.path }) {
            item.id = existing.id
            placement.mediaItem = item
        }
        return placement.editCommands(at: max(.zero, time), in: project, mode: mode)
    }
}

/// What a library item carries when it's dragged to the timeline.
enum LibraryDrag: Equatable {
    case media([String])
    case asset(String)
    case transition(TransitionType)
    case effect(String)
    case title(String)
    case template(String)

    private static let prefixes = (
        asset: "tandem-asset:", transition: "tandem-transition:", effect: "tandem-effect:",
        title: "tandem-title:", template: "tandem-template:"
    )

    var payload: String {
        switch self {
        case .media(let ids): return MediaDrag.payload(ids)
        case .asset(let id): return Self.prefixes.asset + id
        case .transition(let type): return Self.prefixes.transition + type.rawValue
        case .effect(let type): return Self.prefixes.effect + type
        case .title(let id): return Self.prefixes.title + id
        case .template(let id): return Self.prefixes.template + id
        }
    }

    static func parse(_ text: String) -> LibraryDrag? {
        func rest(_ prefix: String) -> String? {
            guard text.hasPrefix(prefix) else { return nil }
            let value = String(text.dropFirst(prefix.count))
            return value.isEmpty ? nil : value
        }
        if text.hasPrefix(MediaDrag.prefix) {
            let ids = MediaDrag.ids(from: text)
            return ids.isEmpty ? nil : .media(ids)
        }
        if let id = rest(prefixes.asset) { return .asset(id) }
        if let name = rest(prefixes.transition) { return TransitionType(rawValue: name).map(LibraryDrag.transition) }
        if let type = rest(prefixes.effect) { return .effect(type) }
        if let id = rest(prefixes.title) { return .title(id) }
        if let id = rest(prefixes.template) { return .template(id) }
        return nil
    }
}

/// The waveform strip on an audio row, and where hovering it plays from.
enum WaveformStrip {
    /// `count` column heights, each the loudest peak in its span, 0 to 1.
    static func columns(_ peaks: [Float], count: Int) -> [Float] {
        guard count > 0 else { return [] }
        guard !peaks.isEmpty else { return Array(repeating: 0, count: count) }
        return (0..<count).map { column in
            let lower = column * peaks.count / count
            let upper = max(lower + 1, (column + 1) * peaks.count / count)
            let loudest = peaks[lower..<min(upper, peaks.count)].map { abs($0) }.max() ?? 0
            return min(1, loudest)
        }
    }

    /// Where to play from when the pointer is `fraction` of the way along,
    /// kept a tenth of a second inside the file.
    static func time(atFraction fraction: Double, duration: Double) -> Double {
        guard duration > 0 else { return 0 }
        return min(max(fraction, 0) * duration, max(0, duration - 0.1))
    }
}

/// The transitions a project leans on, for "Transitions you use most".
enum TransitionUse {
    static func mostUsed(in project: Project, limit: Int) -> [TransitionType] {
        var counts: [TransitionType: Int] = [:]
        for track in project.allTracks {
            for transition in track.transitions { counts[transition.type, default: 0] += 1 }
        }
        let order = TransitionType.allCases
        return counts.keys.sorted { a, b in
            counts[a]! != counts[b]! ? counts[a]! > counts[b]! : order.firstIndex(of: a)! < order.firstIndex(of: b)!
        }.prefix(limit).map { $0 }
    }
}

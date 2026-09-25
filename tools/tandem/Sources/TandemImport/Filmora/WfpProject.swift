import Foundation
import TandemCore

// A Filmora project as the importer reads it.
//
// A `.wfp` is a zip of JSON:
//
//     ProjectFolder/project_info.json            name, canvas, frame rate, which media holds the timeline
//     ProjectFolder/Medias/<id>/timeline.wesproj the timelines, their tracks and clips, and the media resources
//     ProjectFolder/Medias/<id>/extra.json       markers and clip bookkeeping
//
// Times are ticks of 100 ns. Clip and transition ends are inclusive (the
// last tick), so a clip that ends where the next begins has
// `tlEnd == next.tlBegin - 1`. Video tracks are listed bottom to top, like
// Tandem's. Audio "lanes" that hold a video track's sound name that track
// in userData key 20.

struct WfpProject {
    var name: String
    var width: Int
    var height: Int
    var frameRate: FrameRate
    /// Seconds, as Filmora recorded it.
    var duration: Double
    var editorVersion: String?
    var guid: String?
    var timelines: [Int: WfpTimeline]
    var mainTimelineID: Int
    /// The media Filmora knows about, by `sourceUuid`.
    var resources: [String: WfpResource]
    /// `allMarkersInfo` from extra.json: marker lists keyed by the map ID of
    /// the timeline (or clip) they belong to.
    var markers: JSONNode

    var mainTimeline: WfpTimeline? { timelines[mainTimelineID] }

    func timeline(_ id: Int) -> WfpTimeline? { timelines[id] }

    static let ticksPerSecond = 10_000_000.0

    /// Reads a zipped `.wfp`, or an unzipped one: a folder holding
    /// `ProjectFolder`, the `ProjectFolder` itself, or a `<name>.wfp.dir`.
    static func load(from url: URL) throws -> WfpProject {
        let files = try WfpFiles(url: url)
        let info = JSONNode(data: try files.read("project_info.json"))
        guard let mediaID = info["timeline_mediaId"].string else {
            throw ImportError.invalid("\(url.lastPathComponent) has no timeline_mediaId in project_info.json")
        }
        let document = JSONNode(data: try files.read("Medias/\(mediaID)/timeline.wesproj"))
        guard document["timelineInfos"].exists else {
            throw ImportError.invalid("\(url.lastPathComponent) has no timelines")
        }
        let extra = (try? files.read("Medias/\(mediaID)/extra.json")).map { JSONNode(data: $0) } ?? .missing

        var timelines: [Int: WfpTimeline] = [:]
        for node in document["timelineInfos"].array {
            let timeline = WfpTimeline(node)
            timelines[timeline.id] = timeline
        }
        var resources: [String: WfpResource] = [:]
        for node in document["resources"].array {
            if let uuid = node["sourceUuid"].string { resources[uuid] = WfpResource(node) }
        }
        let resolution = info["project_timeline_resolution"]
        let rate = info["project_timeline_framerate"]
        let fps = FrameRate(Int64(rate[0].int ?? 30), Int64(max(1, rate[1].int ?? 1)))
        let fallbackName = url.deletingPathExtension().lastPathComponent
        return WfpProject(
            name: info["project_file_name"].string.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackName,
            width: resolution[0].int ?? 1920,
            height: resolution[1].int ?? 1080,
            frameRate: fps.numerator > 0 ? fps : .fps30,
            duration: Double(info["project_timeline_duration"].int64 ?? 0) / ticksPerSecond,
            editorVersion: info["project_editor_modify_version"].string,
            guid: info["project_guid"].string,
            timelines: timelines,
            mainTimelineID: document["currentTimelineId"].int ?? document["timelineInfos"][0]["timelineId"].int ?? 0,
            resources: resources,
            markers: extra["allMarkersInfo"]
        )
    }
}

/// Reads project files from a zip or a folder.
private struct WfpFiles {
    let zip: ZipReader?
    let prefix: String
    let folder: URL?

    init(url: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw ImportError.unreadable("\(url.path) (no such file)")
        }
        if isDirectory.boolValue {
            zip = nil
            prefix = ""
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("ProjectFolder/project_info.json").path) {
                folder = url.appendingPathComponent("ProjectFolder")
            } else if FileManager.default.fileExists(atPath: url.appendingPathComponent("project_info.json").path) {
                folder = url
            } else {
                throw ImportError.invalid("\(url.lastPathComponent) doesn't look like a Filmora project folder")
            }
        } else {
            let reader = try ZipReader(url: url)
            guard let info = reader.names.first(where: { $0.hasSuffix("ProjectFolder/project_info.json") }) else {
                throw ImportError.invalid("\(url.lastPathComponent) isn't a Filmora project (no ProjectFolder/project_info.json)")
            }
            zip = reader
            prefix = String(info.dropLast("project_info.json".count))
            folder = nil
        }
    }

    /// A file by its path inside `ProjectFolder`.
    func read(_ path: String) throws -> Data {
        if let zip { return try zip.read(prefix + path) }
        let url = folder!.appendingPathComponent(path)
        do {
            return try Data(contentsOf: url)
        } catch {
            throw ImportError.unreadable(url.path)
        }
    }
}

struct WfpTimeline {
    var id: Int
    var width: Int?
    var height: Int?
    /// userData key 3: the map ID markers are filed under.
    var mapID: String?
    var tracks: [WfpTrack]

    init(_ node: JSONNode) {
        id = node["timelineId"].int ?? 0
        width = node["resolutionWidth"].int
        height = node["resolutionHeight"].int
        mapID = Wfp.userDataString(node, key: 3)
        tracks = node["trackInfos"].array.enumerated().map { WfpTrack($1, index: $0) }
    }
}

struct WfpTrack {
    var index: Int
    var kind: TrackKind
    var tag: Int?
    /// For an audio lane, the index of the video track whose sound it holds.
    var linkedVideoIndex: Int?
    var muted: Bool
    var locked: Bool
    var clips: [WfpClip]

    init(_ node: JSONNode, index: Int) {
        self.index = index
        kind = node["trackType"].int == 1 ? .video : .audio
        tag = node["trackTag"].int
        linkedVideoIndex = Wfp.userDataInt(node, key: 20)
        muted = node["mute"].bool ?? false
        locked = node["locked"].bool ?? false
        clips = node["clipList"].array.map(WfpClip.init).sorted { $0.begin < $1.begin }
    }
}

struct WfpResource {
    var path: String?
    var mediaLength: Int64?
    var streamType: Int?
    var hasVideo: Bool
    var hasAudio: Bool
    var width: Int?
    var height: Int?
    var frameRate: FrameRate?

    init(_ node: JSONNode) {
        path = node["filename"].string.flatMap(Wfp.path(fromFilename:))
        mediaLength = node["mediaLength"].int64
        streamType = node["streamType"].int
        let video = node["vidStreamInfo"].array
        let audio = node["audStreamInfo"].array
        hasVideo = (node["videoStreamCount"].int ?? video.count) > 0 || streamType == 5 || streamType == 7
        hasAudio = (node["audioStreamCount"].int ?? audio.count) > 0 || (streamType == 3)
        width = video.first?["width"].int
        height = video.first?["height"].int
        if let num = video.first?["frameRate"]["num"].int, let den = video.first?["frameRate"]["den"].int, num > 0, den > 0 {
            frameRate = AVFoundationProbe.frameRate(Double(num) / Double(den))
        }
    }

    var isImage: Bool { streamType == 5 || streamType == 7 }

    /// What Filmora recorded about the file, for when it's missing.
    var probed: ProbedMedia? {
        if isImage { return .image(width: width ?? 1920, height: height ?? 1080) }
        guard let mediaLength, mediaLength > 0, hasVideo || hasAudio else { return nil }
        return ProbedMedia(
            kind: hasVideo ? .video : .audio,
            duration: Time(seconds: Double(mediaLength) / WfpProject.ticksPerSecond),
            hasVideo: hasVideo,
            hasAudio: hasAudio,
            width: width,
            height: height,
            frameRate: frameRate
        )
    }
}

struct WfpClip {
    var node: JSONNode
    var type: Int
    var begin: Int64
    /// Exclusive: the tick after the last one.
    var end: Int64
    var inPoint: Int64
    var outPoint: Int64
    var uid: String
    var filename: String?
    var sourceUuid: String?
    /// userData key 3: shared by a clip's picture and sound.
    var mapID: String?
    /// userData key 50: the name Filmora shows.
    var displayName: String?
    /// userData key 12: the library resource the clip came from.
    var resource: JSONNode
    var nestedTimelineID: Int?
    var effects: [WfpEffect]
    var pip: JSONNode
    var preTransition: WfpTransition?
    var postTransition: WfpTransition?

    init(_ node: JSONNode) {
        self.node = node
        type = node["type"].int ?? 0
        begin = node["tlBegin"].int64 ?? 0
        end = (node["tlEnd"].int64 ?? begin) + 1
        inPoint = node["inPoint"].int64 ?? 0
        outPoint = (node["outPoint"].int64 ?? inPoint) + 1
        uid = node["thisUId"].string ?? "\(type)@\(begin)"
        filename = node["filename"].string
        sourceUuid = node["sourceUuid"].string
        mapID = Wfp.userDataString(node, key: 3)
        displayName = Wfp.userDataString(node, key: 50)
        resource = Wfp.userData(node, key: 12).map { JSONNode(jsonString: String(decoding: $0, as: UTF8.self)) } ?? .missing
        nestedTimelineID = node["timelineId"].int
        effects = node["effectChainList"].array.flatMap { chain in
            chain["effectList"].array.map { WfpEffect($0, chain: chain["name"].string) }
        }
        pip = node["pipBuf"].embedded
        preTransition = WfpTransition(node["preTransition"])
        postTransition = WfpTransition(node["postTransition"])
    }

    var isVideo: Bool { [1, 14].contains(type) }
    var isAudio: Bool { [2, 15].contains(type) }

    func effect(_ id: String) -> WfpEffect? {
        effects.first { $0.id == id }
    }
}

struct WfpEffect {
    var chain: String?
    var id: String
    var display: String
    /// Nil when Filmora didn't say, which means on.
    var enabled: Bool?
    var params: [String: JSONNode]
    /// Keyframes by parameter name, from `paramMapList`.
    var keyframes: [String: JSONNode]

    init(_ node: JSONNode, chain: String?) {
        self.chain = chain
        id = node["id"].string ?? ""
        display = node["display"].string ?? id
        enabled = node["enable"].bool
        var params: [String: JSONNode] = [:]
        for param in node["paramList"].array {
            if let name = param["name"].string { params[name] = param["fxParam"]["unValue"] }
        }
        self.params = params
        var keyframes: [String: JSONNode] = [:]
        for map in node["paramMapList"].array {
            if let name = map["name"].string, map["keyFrame"]["parameter"].exists {
                keyframes[name] = map["keyFrame"]["parameter"].embedded
            }
        }
        self.keyframes = keyframes
    }

    var isOn: Bool { enabled ?? true }

    func number(_ name: String) -> Double? { params[name]?.double }
}

struct WfpTransition {
    var name: String
    var id: String
    var begin: Int64
    /// Exclusive.
    var end: Int64

    init?(_ node: JSONNode) {
        guard node.exists, let begin = node["tlBegin"].int64, let last = node["tlEnd"].int64 else { return nil }
        name = node["display"].string ?? node["id"].string ?? "transition"
        id = node["id"].string ?? ""
        self.begin = begin
        end = last + 1
    }
}

/// Small helpers for Filmora's encodings.
enum Wfp {
    static func userData(_ node: JSONNode, key: Int) -> Data? {
        for entry in node["userData"].array where entry["key"].int == key {
            return entry["data"].string.flatMap { Data(base64Encoded: $0) }
        }
        return nil
    }

    /// A userData string, without the NUL padding Filmora adds.
    static func userDataString(_ node: JSONNode, key: Int) -> String? {
        guard let data = userData(node, key: key) else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\u{0}"))
        return text.isEmpty ? nil : text
    }

    /// A little-endian integer stored in userData.
    static func userDataInt(_ node: JSONNode, key: Int) -> Int? {
        guard let data = userData(node, key: key), !data.isEmpty, data.count <= 8 else { return nil }
        var value = 0
        for (shift, byte) in data.enumerated() { value |= Int(byte) << (8 * shift) }
        return value
    }

    /// Filmora writes `file:/` plus an absolute path, so most paths come out
    /// as `file://Users/...`. Library clips sometimes carry only a relative
    /// path; those return nil and the resource's full path is used instead.
    static func path(fromFilename filename: String) -> String? {
        var path = filename
        if path.hasPrefix("file:") {
            path = String(path.dropFirst(5))
            while path.hasPrefix("//") { path.removeFirst() }
            if !path.hasPrefix("/") { path = "/" + path }
        }
        return path.hasPrefix("/") ? path : nil
    }

    static func time(_ ticks: Int64) -> Time {
        Time(seconds: Double(ticks) / WfpProject.ticksPerSecond)
    }
}

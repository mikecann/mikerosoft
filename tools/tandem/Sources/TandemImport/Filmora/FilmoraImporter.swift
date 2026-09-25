import Foundation
import TandemCore
import TandemMedia

/// Imports Filmora `.wfp` projects, best effort.
///
/// Tracks keep Filmora's layering (its video tracks are listed bottom to
/// top, like Tandem's) and clips keep their times, source ranges and speed.
/// The settings Mike used map onto Tandem's: transform and its keyframes,
/// the AI cutout, opacity, crop, drop shadow, border, the colour grade
/// (moved onto the media when every clip of a file shares it), volume,
/// loudness gain and fades, transitions, titles as text clips, and markers.
/// Title templates become text clips and other templates are flattened into
/// their media and sounds. A picture and its sound stay linked, and so do
/// the camera and screen clips of one record-it take.
///
/// Anything else is listed in the report. Clips whose media Tandem can't
/// play (WebM stickers) are left out with a to-do marker where they were;
/// missing media stays on the timeline offline, with the length Filmora
/// recorded, so it can be relinked.
public struct FilmoraImporter: Sendable {
    public var locating: MediaLocating

    /// By default, paths from TinkerDesk (the other Mac) are also tried
    /// under this Mac's home folder.
    public init(locating: MediaLocating = MediaLocating(pathRewrites: [MediaLocating.tinkerDeskHome])) {
        self.locating = locating
    }

    /// Imports a `.wfp` file or an unzipped project folder. `name` defaults
    /// to the name Filmora saved.
    public func importProject(at url: URL, name: String? = nil) async throws -> ImportResult {
        let wfp = try WfpProject.load(from: url)
        guard wfp.mainTimeline != nil else { throw ImportError.invalid("\(url.lastPathComponent) has no main timeline") }
        let run = FilmoraRun(wfp: wfp, source: url.path, name: name ?? wfp.name, locating: locating)
        return await run.build()
    }
}

private final class FilmoraRun {
    enum Category: CaseIterable {
        case camera, screen, voice, screenAudio, music, sfx, text, graphic, broll, image, sticker, other

        var isTake: Bool { [.camera, .screen, .voice, .screenAudio].contains(self) }
    }

    struct Edge {
        var name: String
        var duration: Time
        /// The Filmora transition spans the cut, so it joins two clips.
        var spansCut: Bool
        /// Filmora placed it off-centre; Tandem centres it on the cut.
        var offCentre: Bool
    }

    struct PlannedClip {
        var clip: Clip
        var category: Category
        var mapID: String?
        var takeBase: String?
        var colour: [Effect]
        var head: Edge?
        var tail: Edge?
        var flattened: Bool
    }

    final class PlannedTrack {
        let key: String
        let kind: TrackKind
        var filmoraIndex: Int?
        var linkedVideoIndex: Int?
        var muted = false
        var locked = false
        var clips: [PlannedClip] = []
        var lanes: [[PlannedClip]] = []
        var names: [String] = []
        var ids: [String] = []
        var rippleMode: RippleMode = .follow

        init(key: String, kind: TrackKind) {
            self.key = key
            self.kind = kind
        }
    }

    let wfp: WfpProject
    let source: String
    let name: String
    let catalog: MediaCatalog
    var report: ImportReport
    var ids = ImportIDs.Allocator()
    let settings: ProjectSettings
    let frame: Time
    var tracks: [PlannedTrack] = []
    var templateSounds: PlannedTrack?
    var markers: [Marker] = []
    var flattenedSounds = Set<String>()
    var titleSizeNoted = false

    init(wfp: WfpProject, source: String, name: String, locating: MediaLocating) {
        self.wfp = wfp
        self.source = source
        self.name = name
        self.catalog = MediaCatalog(locating: locating)
        self.report = ImportReport(source: source, importer: "filmora", projectName: name)
        var settings = ProjectSettings(width: wfp.width, height: wfp.height, frameRate: wfp.frameRate)
        if settings.width <= 0 || settings.height <= 0 {
            settings.width = 1920
            settings.height = 1080
        }
        self.settings = settings
        self.frame = settings.frameRate.frameDuration
    }

    func build() async -> ImportResult {
        let main = wfp.mainTimeline!
        await resolveMedia(in: main)
        for track in main.tracks {
            plan(track)
        }
        for track in tracks + [templateSounds].compactMap({ $0 }) {
            arrangeLanes(track)
        }
        nameTracks()
        let looks = assignLooks()
        addMarkers(main)
        let project = assemble(looks: looks)
        return ImportResult(project: project, report: report)
    }

    // MARK: - Media

    private func mediaPath(_ clip: WfpClip) -> String? {
        if let uuid = clip.sourceUuid, let path = wfp.resources[uuid]?.path { return path }
        return clip.filename.flatMap(Wfp.path(fromFilename:))
    }

    private func roleHint(_ clip: WfpClip, path: String) -> MediaRole? {
        if clip.type == 14 || clip.type == 15 { return .screen }
        switch clip.resource["res_type"].int {
        case 46: return .music
        case 47: return .sfx
        case 7: return .sticker
        case 55: return .broll
        default: break
        }
        if clip.node["humanseg_hair"]["status"].int == 1 { return .camera }
        let lower = path.lowercased()
        if lower.contains("/filmora/resnewaudio/") { return .music }
        if lower.contains("/filmora/resaudiosound/") { return .sfx }
        if lower.contains("/filmora/element/") { return .sticker }
        let resource = clip.sourceUuid.flatMap { wfp.resources[$0] }
        let seconds = Double(resource?.mediaLength ?? 0) / WfpProject.ticksPerSecond
        if lower.contains("/filmora/audio/") { return seconds >= 30 ? .music : .sfx }
        // A short sound file outside the music folders is a sound effect.
        if resource?.streamType == 3, seconds > 0, seconds < 30, !lower.contains("music"), !lower.contains("voice") {
            return .sfx
        }
        return nil
    }

    /// What the clips say about one file, for when it can't be found and
    /// Filmora kept no resource record for it.
    struct Usage {
        var firstClip: WfpClip
        var at: Time
        var video = false
        var audio = false
        /// The furthest media time any clip reaches.
        var reach = 0.0
    }

    /// Probes every file the timeline (and the templates on it) uses.
    private func resolveMedia(in main: WfpTimeline) async {
        var usage: [String: Usage] = [:]
        var order: [String] = []
        func collect(_ timeline: WfpTimeline, shift: Int64, depth: Int) {
            guard depth < 4 else { return }
            for track in timeline.tracks {
                for clip in track.clips {
                    if clip.isVideo || clip.isAudio, let path = mediaPath(clip) {
                        if usage[path] == nil {
                            usage[path] = Usage(firstClip: clip, at: Wfp.time(clip.begin + shift))
                            order.append(path)
                        }
                        usage[path]!.video = usage[path]!.video || clip.isVideo
                        usage[path]!.audio = usage[path]!.audio || clip.isAudio
                        usage[path]!.reach = max(usage[path]!.reach, FilmoraSpeed(clip).sourceEnd)
                    } else if let nested = clip.nestedTimelineID.flatMap(wfp.timeline) {
                        collect(nested, shift: shift + clip.begin - clip.inPoint, depth: depth + 1)
                    }
                }
            }
        }
        collect(main, shift: 0, depth: 0)
        for path in order {
            let use = usage[path]!
            var fallback = use.firstClip.sourceUuid.flatMap { wfp.resources[$0]?.probed }
            if fallback == nil, use.reach > 0 {
                // No record of the file, so make one from how the clips use it.
                fallback = ProbedMedia(kind: use.video ? .video : .audio, duration: Time(seconds: use.reach), hasVideo: use.video, hasAudio: use.audio)
            } else if var known = fallback, known.kind != .image {
                known.hasVideo = known.hasVideo || use.video
                known.hasAudio = known.hasAudio || use.audio
                if let duration = known.duration, duration.seconds < use.reach { known.duration = Time(seconds: use.reach) }
                fallback = known
            }
            _ = await catalog.resolve(path, role: roleHint(use.firstClip, path: path), fallback: fallback, report: &report, at: use.at)
        }
    }

    // MARK: - Planning clips

    private func plan(_ track: WfpTrack) {
        let planned = PlannedTrack(key: "filmora-\(track.index)", kind: track.kind)
        planned.filmoraIndex = track.index
        planned.linkedVideoIndex = track.kind == .audio ? track.linkedVideoIndex : nil
        planned.muted = track.muted
        planned.locked = track.locked
        tracks.append(planned)
        for clip in track.clips {
            place(clip, on: planned, shift: 0, window: nil, template: nil, depth: 0)
        }
    }

    /// Plans one Filmora clip. Clips inside templates carry the `shift`
    /// from their timeline to the main one and the `window` of it that
    /// shows.
    private func place(_ clip: WfpClip, on track: PlannedTrack, shift: Int64, window: Range<Int64>?, template: String?, depth: Int) {
        let at = Wfp.time(clip.begin + shift)
        switch clip.type {
        case 1, 14, 2, 15:
            if let planned = mediaClip(clip, on: track, shift: shift, window: window) { track.clips.append(planned) }
        case 4:
            if let planned = titleClip(clip, shift: shift, window: window, template: template) { track.clips.append(planned) }
        case 6, 7:
            flatten(clip, onto: track, shift: shift, window: window, depth: depth)
        case 16:
            flattenSounds(clip, shift: shift, window: window, depth: depth)
        case 8:
            report.add(.unsupported, "clip", "Effect layers (adjustment clips) aren't imported.", at: at)
        case 26:
            report.add(.unsupported, "clip", "Pen drawings aren't imported.", at: at)
        default:
            report.add(.unsupported, "clip", "Filmora clip type \(clip.type) isn't imported.", at: at)
        }
    }

    /// The part of a clip inside `window`, in its own timeline's ticks.
    private func clamp(_ clip: WfpClip, to window: Range<Int64>?) -> (begin: Int64, end: Int64)? {
        guard let window else { return clip.end > clip.begin ? (clip.begin, clip.end) : nil }
        let begin = max(clip.begin, window.lowerBound)
        let end = min(clip.end, window.upperBound)
        return end > begin ? (begin, end) : nil
    }

    private func mediaClip(_ clip: WfpClip, on track: PlannedTrack, shift: Int64, window: Range<Int64>?) -> PlannedClip? {
        guard let (begin, end) = clamp(clip, to: window) else { return nil }
        let start = Wfp.time(begin + shift)
        let label = clip.displayName ?? mediaPath(clip).map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? "clip"
        guard let path = mediaPath(clip), let item = catalog.item(forPath: path) else {
            if track.kind == .video {
                let sticker = clip.resource["res_type"].int == 7 || (mediaPath(clip) ?? "").lowercased().hasSuffix(".webm")
                markers.append(Marker(
                    id: ids.make("mk", key: "left-out:\(clip.uid):\(shift)"),
                    time: start,
                    duration: Wfp.time(end + shift) - start,
                    name: sticker ? "Sticker: \(label)" : "Left out: \(label)",
                    kind: .todo,
                    note: "Imported from Filmora without this clip; see the import report."
                ))
            }
            return nil
        }
        let speedInfo = FilmoraSpeed(clip)
        let filmoraSeconds = Double(clip.end - clip.begin) / WfpProject.ticksPerSecond
        guard filmoraSeconds > 0 else { return nil }
        var speed = (speedInfo.sourceEnd - speedInfo.sourceStart) / filmoraSeconds
        var sourceStart = speedInfo.sourceStart + Double(begin - clip.begin) / WfpProject.ticksPerSecond * speed
        var duration = Wfp.time(end + shift) - start
        guard duration > .zero else { return nil }
        var freeze = false
        if item.kind == .image {
            speed = 1
            sourceStart = 0
        } else {
            if speedInfo.freeze {
                if speedInfo.sourceEnd - speedInfo.sourceStart < frame.seconds {
                    freeze = true
                    speed = 1
                } else {
                    report.add(.approximated, "speed", "A freeze frame inside a clip plays as normal motion.", at: start)
                }
            }
            if speedInfo.ramp {
                report.add(.approximated, "speed", "A speed ramp plays at its average speed.", at: start)
            }
            if speedInfo.reverse {
                report.add(.unsupported, "speed", "Reversed clips play forwards; Tandem has no reverse.", at: start)
            }
        }
        guard speed.isFinite, speed > 0 else {
            report.add(.failed, "clip", "\(label) has no usable speed.", at: start)
            return nil
        }
        if speed > 100 {
            report.add(.approximated, "speed", "Speeds above 100x were capped at 100x.", at: start)
            speed = 100
        }
        if track.kind == .video && !(item.hasVideo || item.kind == .image) {
            report.add(.unsupported, "clip", "\(label) has no picture Tandem can read, so its video clip was left out.", at: start)
            return nil
        }
        if track.kind == .audio && !item.hasAudio {
            report.add(.note, "clip", "\(label) has no sound track Tandem can read, so its audio clip was left out.", at: start)
            return nil
        }
        if sourceStart < 0 {
            sourceStart = 0
        }
        if item.kind != .image, !freeze, let length = item.duration {
            let available = (length + frame).seconds - sourceStart
            if available <= 0 {
                report.add(.failed, "clip", "\(label) starts after the end of its media.", at: start)
                return nil
            }
            if duration.seconds * speed > available {
                duration = Time(seconds: (length.seconds - sourceStart) / speed)
                report.add(.approximated, "clip", "A clip ran past the end of its media and was shortened to fit.", at: start)
                guard duration > .zero else { return nil }
            }
        }
        var planned = PlannedClip(
            clip: Clip(
                id: ids.make("clip", key: "\(clip.uid)@\(shift)"),
                name: label,
                content: .media(mediaID: item.id),
                start: start,
                duration: duration,
                sourceStart: Time(seconds: sourceStart),
                speed: speed,
                freezeFrame: freeze
            ),
            category: category(for: item, on: track.kind),
            mapID: shift == 0 ? clip.mapID : nil,
            takeBase: takeBase(item),
            colour: [],
            head: edge(clip.preTransition, at: begin, window: window),
            tail: edge(clip.postTransition, at: end, window: window),
            flattened: shift != 0 || window != nil
        )
        if track.kind == .video {
            let (video, keyframes, colour) = videoProperties(clip, clipSeconds: duration.seconds, sourceStart: speedInfo.sourceStart, speed: speed, at: start)
            planned.clip.video = video
            planned.clip.keyframes = keyframes
            planned.colour = colour
        } else {
            planned.clip.audio = audioProperties(clip, duration: duration, at: start)
        }
        return planned
    }

    private func category(for item: MediaItem, on kind: TrackKind) -> Category {
        switch (item.role, kind) {
        case (.camera, .video): return .camera
        case (.screen, .video): return .screen
        case (.camera, .audio): return .voice
        case (.screen, .audio): return .screenAudio
        case (.music, _): return .music
        case (.sfx, _): return .sfx
        case (.graphic, _): return .graphic
        case (.broll, _): return .broll
        case (.image, _): return .image
        case (.sticker, _): return .sticker
        default: return kind == .audio ? .other : .broll
        }
    }

    /// record-it names a take's files `<base>-camera.mov` and `<base>-screen.mov`.
    private func takeBase(_ item: MediaItem) -> String? {
        let name = URL(fileURLWithPath: item.path).deletingPathExtension().lastPathComponent
        for suffix in ["-camera", "-screen"] where name.hasSuffix(suffix) {
            return URL(fileURLWithPath: item.path).deletingLastPathComponent().appendingPathComponent(String(name.dropLast(suffix.count))).path
        }
        return nil
    }

    /// A transition at one end of a clip, if it survives the window.
    private func edge(_ transition: WfpTransition?, at cut: Int64, window: Range<Int64>?) -> Edge? {
        guard let transition else { return nil }
        if let window, !window.contains(cut) && cut != window.upperBound { return nil }
        let duration = Wfp.time(transition.end) - Wfp.time(transition.begin)
        guard duration > .zero else { return nil }
        let spans = transition.begin < cut && transition.end > cut
        let before = Double(cut - transition.begin) / WfpProject.ticksPerSecond
        let after = Double(transition.end - cut) / WfpProject.ticksPerSecond
        return Edge(name: transition.name, duration: duration, spansCut: spans, offCentre: spans && abs(before - after) > frame.seconds)
    }

    // MARK: - Picture

    private func videoProperties(_ clip: WfpClip, clipSeconds: Double, sourceStart: Double, speed: Double, at time: Time) -> (VideoProperties, [String: [Keyframe]], [Effect]) {
        var video = VideoProperties()
        var keyframes: [String: [Keyframe]] = [:]
        var colour: [Effect] = []
        var effects: [Effect] = []
        let key = clip.uid

        if let transform = clip.effect("video/effect/transform"), transform.isOn {
            let scaleX = transform.number("Scale_x") ?? 100
            let scaleY = transform.number("Scale_y") ?? scaleX
            if abs(scaleX - scaleY) > 0.5 {
                report.add(.approximated, "transform", "A stretched clip (different width and height scale) keeps only its width scale.", at: time)
            }
            video.transform = Transform(
                position: Point(x: transform.number("Position_x") ?? 0.5, y: transform.number("Position_y") ?? 0.5),
                scale: scaleX / 100,
                rotation: transform.number("Rotation") ?? 0
            )
            let x = transform.keyframes["Position_x"].map { FilmoraKeyframes.points($0, sourceStart: sourceStart, speed: speed) } ?? []
            let y = transform.keyframes["Position_y"].map { FilmoraKeyframes.points($0, sourceStart: sourceStart, speed: speed) } ?? []
            if !x.isEmpty || !y.isEmpty {
                let base = video.transform.position
                let frames = FilmoraKeyframes.keyframes(times: (x + y).map(\.time), duration: clipSeconds) { t in
                    .point(Point(x: FilmoraKeyframes.value(x, at: t) ?? base.x, y: FilmoraKeyframes.value(y, at: t) ?? base.y))
                }
                if let frames { keyframes["video.transform.position"] = frames }
            }
            if let list = transform.keyframes["Scale_x"] ?? transform.keyframes["Scale_y"] {
                let points = FilmoraKeyframes.points(list, sourceStart: sourceStart, speed: speed)
                if let frames = FilmoraKeyframes.keyframes(times: points.map(\.time), duration: clipSeconds, value: { .number((FilmoraKeyframes.value(points, at: $0) ?? 100) / 100) }) {
                    keyframes["video.transform.scale"] = frames
                }
            }
            if let list = transform.keyframes["Rotation"] {
                let points = FilmoraKeyframes.points(list, sourceStart: sourceStart, speed: speed)
                if let frames = FilmoraKeyframes.keyframes(times: points.map(\.time), duration: clipSeconds, value: { .number(FilmoraKeyframes.value(points, at: $0) ?? 0) }) {
                    keyframes["video.transform.rotation"] = frames
                }
            }
            if (transform.number("EnableShadow") ?? 0) != 0 {
                var params: [String: ParamValue] = [
                    "distance": .number(transform.number("nDistance") ?? 4),
                    "blur": .number(transform.number("nBlur") ?? 5),
                    "opacity": .number(transform.number("nAlpha") ?? 60)
                ]
                if let angle = transform.number("uDirectAngle") { params["angle"] = .number(angle) }
                effects.append(Effect(id: ImportIDs.make("fx", key: "\(key):shadow"), type: "dropShadow", params: params))
            }
            if ["LeftTop", "RightTop", "LeftBottom", "RightBottom"].contains(where: { transform.params[$0] != nil }) {
                report.add(.unsupported, "transform", "Corner settings on the transform aren't imported.", at: time)
            }
        }

        if let crop = clip.effect("video/effect/crop-pan-zoom"), crop.isOn {
            applyCrop(crop, to: &video, keyframes: &keyframes, clipSeconds: clipSeconds, at: time)
        }

        if let opacity = clip.pip["Opacity"].double, opacity < 99.95 {
            video.opacity = max(0, opacity / 100)
        }
        let opacityFrames = clip.pip["OpacityKeyFrame"].embedded
        if opacityFrames["keyframeSets"].array.count >= 2 {
            let points = FilmoraKeyframes.points(opacityFrames, sourceStart: sourceStart, speed: speed)
            if let frames = FilmoraKeyframes.keyframes(times: points.map(\.time), duration: clipSeconds, value: { .number((FilmoraKeyframes.value(points, at: $0) ?? 100) / 100) }) {
                keyframes["video.opacity"] = frames
            }
        }
        let blend = clip.pip["BlendMode"]
        if let mode = blend.string, !["normal", "0", ""].contains(mode.lowercased()) {
            report.add(.unsupported, "compositing", "Blend mode \(mode) isn't supported; the clip draws normally.", at: time)
        } else if let mode = blend.int, mode != 0 {
            report.add(.unsupported, "compositing", "Blend mode \(mode) isn't supported; the clip draws normally.", at: time)
        }

        let legacyCutout = clip.effects.contains { $0.display == "Human Segmentation" && $0.isOn }
        if clip.node["humanseg_hair"]["status"].int == 1 || legacyCutout {
            video.cutout = Cutout()
        }

        for effect in clip.effects {
            switch effect.id {
            case "video/effect/transform", "video/effect/crop-pan-zoom",
                 "B4CF1D0F-D10A-1613-6EF4-A4F0D0364978", "87289B96-239D-4740-BF86-023F54349902":
                continue
            case FilmoraColour.adjustColorID:
                guard effect.isOn else { continue }
                let mapped = FilmoraColour.map(effect.params, idKey: key)
                colour = mapped.effects
                for setting in mapped.approximated {
                    report.add(.approximated, "colour", "Colour setting \(setting) was converted roughly.", at: time)
                }
                for setting in mapped.unmapped {
                    report.add(.unsupported, "colour", "Colour setting \(setting) has no Tandem equivalent.", at: time)
                }
                continue
            case "video/effect/horizontal_filp", "video/effect/vertical_filp":
                if effect.enabled == true {
                    report.add(.unsupported, "effect", "Flipped clips aren't supported; the clip isn't flipped.", at: time)
                }
                continue
            default:
                break
            }
            guard effect.isOn else { continue }
            switch effect.display {
            case "Sharpen":
                if let amount = effect.number("amount"), amount > 0 {
                    effects.append(Effect(id: ImportIDs.make("fx", key: "\(key):sharpen"), type: "sharpen", params: ["amount": .number(amount)]))
                }
            case "PipBorder":
                if let size = effect.number("Size"), size > 0 {
                    var params: [String: ParamValue] = ["width": .number(size)]
                    if let color = FilmoraText.color(effect.params["Color"]?.int) { params["color"] = .color(color) }
                    effects.append(Effect(id: ImportIDs.make("fx", key: "\(key):border"), type: "border", params: params))
                }
            case "ColorWheel", "rgbcurve", "CurveColor", "HDRColor", "InnerShadow", "HumanSegmentationHairEffect", "Human Segmentation":
                // Filmora writes these into every clip at their neutral settings.
                if effect.enabled == true, effect.display != "Human Segmentation", effect.params.values.contains(where: { ($0.double ?? 0) != 0 }) {
                    report.add(.unsupported, "effect", "\(effect.display) isn't supported.", at: time)
                }
            default:
                if !effect.params.isEmpty || effect.enabled == true {
                    report.add(.unsupported, "effect", "Effect \"\(effect.display)\" isn't supported.", at: time)
                }
            }
        }
        video.effects = effects
        return (video, keyframes, colour)
    }

    private func applyCrop(_ crop: WfpEffect, to video: inout VideoProperties, keyframes: inout [String: [Keyframe]], clipSeconds: Double, at time: Time) {
        if let x = crop.number("crop_x"), let y = crop.number("crop_y"), let w = crop.number("crop_width"), let h = crop.number("crop_height"),
           w > 0, h > 0, (x, y, w, h) != (0, 0, 1, 1) {
            video.crop = Crop(left: x, top: y, right: max(0, 1 - x - w), bottom: max(0, 1 - y - h))
        }
        guard let script = crop.params["SettingScript"]?.embedded else { return }
        let rects = script.array.compactMap { node -> (time: Double, x: Double, y: Double, w: Double, h: Double)? in
            guard let w = node["Width"].double, let h = node["Height"].double, w > 0, h > 0 else { return nil }
            return (node["Time"].double ?? 0, node["X"].double ?? 0, node["Y"].double ?? 0, w, h)
        }
        let zooms = rects.filter { !($0.x == 0 && $0.y == 0 && $0.w == 1 && $0.h == 1) }
        guard !zooms.isEmpty else { return }
        // Crop and zoom shows a region of the source filling the frame:
        // scale up by 1/size and move the region's centre to the middle.
        let base = video.transform
        func zoomed(_ rect: (time: Double, x: Double, y: Double, w: Double, h: Double)) -> (Double, Point) {
            let zoom = min(1 / rect.w, 1 / rect.h)
            let u = rect.x + rect.w / 2 - 0.5
            let v = rect.y + rect.h / 2 - 0.5
            return (base.scale * zoom, Point(x: base.position.x - u * base.scale * zoom, y: base.position.y - v * base.scale * zoom))
        }
        if rects.count == 1 {
            let (scale, position) = zoomed(rects[0])
            video.transform.scale = scale
            video.transform.position = position
            report.add(.approximated, "crop", "A crop and zoom region became a zoom on the clip's transform.", at: time)
        } else {
            let sorted = rects.sorted { $0.time < $1.time }
            keyframes["video.transform.scale"] = sorted.map { Keyframe(time: Time(seconds: $0.time * clipSeconds), value: .number(zoomed($0).0), interpolation: .linear) }
            keyframes["video.transform.position"] = sorted.map { Keyframe(time: Time(seconds: $0.time * clipSeconds), value: .point(zoomed($0).1), interpolation: .linear) }
            report.add(.approximated, "crop", "An animated pan and zoom became transform keyframes.", at: time)
        }
    }

    // MARK: - Sound

    private func audioProperties(_ clip: WfpClip, duration: Time, at time: Time) -> AudioProperties {
        var audio = AudioProperties()
        if let volume = clip.effect("audio/effect/volume"), volume.isOn {
            var gain = volume.number("VolumeGain") ?? 0
            if volume.params["LoudnessGainEnable"]?.bool == true {
                gain += volume.number("LoudnessGain") ?? 0
            }
            audio.gainDB = gain
            if let balance = volume.number("Balance"), balance != 0, abs(balance - 0.5) > 0.01 {
                report.add(.unsupported, "audio", "Pan (balance) isn't supported; the clip plays centred.", at: time)
            }
        }
        if let fade = clip.effect("audio/effect/fade"), fade.isOn {
            let fadeIn = Time(seconds: fade.number("FadeInTime") ?? 0)
            let fadeOut = Time(seconds: fade.number("FadeOutTime") ?? 0)
            audio.fadeIn = min(fadeIn, duration)
            audio.fadeOut = min(fadeOut, duration)
            if fadeIn > duration || fadeOut > duration {
                report.add(.note, "audio", "Fades longer than their clip were shortened to the clip.", at: time)
            }
        }
        if clip.node["enableV3Denoise"].bool == true {
            audio.voiceIsolation = min(1, max(0, (clip.node["denoiseV3Strength"].double ?? 50) / 100))
            report.add(.approximated, "audio", "Filmora's AI denoise became Tandem's voice isolation.", at: time)
        }
        for effect in clip.effects where effect.id.hasPrefix("audio/") {
            let active = effect.isOn && effect.params.values.contains { ($0.double ?? 0) != 0 || $0.bool == true }
            switch effect.id {
            case "audio/effect/volume", "audio/effect/fade", "audio/effect/clip_volume", "audio/effect/change_channel":
                continue
            case "audio/effect/audio_enhancer", "audio/effect/speech_enhance", "audio/effect/reverb_denoise":
                if active {
                    audio.voiceIsolation = 1
                    report.add(.approximated, "audio", "Filmora's voice enhancer became Tandem's voice isolation.", at: time)
                }
            case "audio/effect/ducking":
                if effect.enabled == true {
                    report.add(.unsupported, "audio", "Auto ducking isn't supported.", at: time)
                }
            case "audio/effect/equalizer":
                if effect.enabled == true, active {
                    report.add(.unsupported, "audio", "Equalizer settings aren't supported.", at: time)
                }
            default:
                if active {
                    report.add(.unsupported, "audio", "Audio effect \"\(effect.display)\" isn't supported.", at: time)
                }
            }
        }
        if clip.node["volumeKeyframe"]["parameter"].embedded["keyframeSets"].array.count >= 2 {
            report.add(.unsupported, "audio", "Volume keyframes aren't imported; the clip keeps its overall level.", at: time)
        }
        return audio
    }

    // MARK: - Titles and templates

    private func titleClip(_ clip: WfpClip, shift: Int64, window: Range<Int64>?, template: String?, transform: Transform? = nil) -> PlannedClip? {
        guard let (begin, end) = clamp(clip, to: window) else { return nil }
        let start = Wfp.time(begin + shift)
        guard Wfp.time(end + shift) > start else { return nil }
        guard let mapped = FilmoraText.map(clip) else {
            report.add(.failed, "title", "A title had no text data.", at: start)
            return nil
        }
        for note in mapped.notes {
            report.add(.approximated, "title", note, at: start)
        }
        if !titleSizeNoted {
            titleSizeNoted = true
            report.add(.note, "title", "Title sizes are estimated from the size of Filmora's text box; fonts and colours carry over.")
        }
        var position = mapped.position
        if let transform {
            // The template's own transform maps its canvas onto the main one.
            position = Point(
                x: transform.position.x + (position.x - 0.5) * transform.scale,
                y: transform.position.y + (position.y - 0.5) * transform.scale
            )
        }
        var content = mapped.content
        if let transform, transform.scale != 1 {
            content.style.size = (content.style.size * transform.scale).rounded()
        }
        let text = content.text.replacingOccurrences(of: "\n", with: " ")
        var clipValue = Clip(
            id: ids.make("clip", key: "\(clip.uid)@\(shift)"),
            name: String(text.prefix(40)),
            content: .text(content),
            start: start,
            duration: Wfp.time(end + shift) - start,
            video: VideoProperties(transform: Transform(position: position, rotation: mapped.rotation))
        )
        if let template { clipValue.tags = ["filmora-template:\(template)"] }
        return PlannedClip(
            clip: clipValue, category: .text, mapID: nil, takeBase: nil, colour: [],
            head: edge(clip.preTransition, at: begin, window: window),
            tail: edge(clip.postTransition, at: end, window: window),
            flattened: template != nil
        )
    }

    private func templateName(_ clip: WfpClip) -> String {
        if let name = clip.displayName { return name }
        if let name = clip.resource["name"].string {
            // Custom templates end in a creation timestamp.
            let trimmed = name.replacingOccurrences(of: #"_\d{10,}$"#, with: "", options: .regularExpression)
            return trimmed.replacingOccurrences(of: "_", with: " ")
        }
        return "template"
    }

    /// Replaces a template or compound clip with what's inside it: text
    /// layers and media on its track (extra layers go on lanes above), and
    /// its sounds on a sounds track.
    private func flatten(_ clip: WfpClip, onto track: PlannedTrack, shift: Int64, window: Range<Int64>?, depth: Int) {
        let at = Wfp.time(clip.begin + shift)
        guard depth < 4, let id = clip.nestedTimelineID, let nested = wfp.timeline(id), let (begin, end) = clamp(clip, to: window) else {
            report.add(.unsupported, "template", "A template or compound clip with nothing readable inside was left out.", at: at)
            return
        }
        let name = templateName(clip)
        let isTitle = clip.type == 7 || clip.resource["res_type"].int == 1
        if !isTitle {
            report.add(.approximated, "template", "Template \"\(name)\" was flattened into its layers and sounds.", at: at)
        }
        let childShift = shift + clip.begin - clip.inPoint
        let childWindow = (begin - clip.begin + clip.inPoint)..<(end - clip.begin + clip.inPoint)
        var transform: Transform?
        if let t = clip.effect("video/effect/transform") {
            let candidate = Transform(
                position: Point(x: t.number("Position_x") ?? 0.5, y: t.number("Position_y") ?? 0.5),
                scale: (t.number("Scale_x") ?? 100) / 100
            )
            if candidate != Transform() { transform = candidate }
        }
        let soundsKey = "\(id)@\(clip.begin + shift)"
        let takeSounds = flattenedSounds.insert(soundsKey).inserted
        let firstChild = track.clips.count
        for nestedTrack in nested.tracks {
            for child in nestedTrack.clips {
                switch child.type {
                case 4:
                    if let planned = titleClip(child, shift: childShift, window: childWindow, template: name, transform: transform) {
                        track.clips.append(planned)
                    }
                case 1, 14:
                    if var planned = mediaClip(child, on: track, shift: childShift, window: childWindow) {
                        if let transform, var video = planned.clip.video {
                            video.transform.position = Point(
                                x: transform.position.x + (video.transform.position.x - 0.5) * transform.scale,
                                y: transform.position.y + (video.transform.position.y - 0.5) * transform.scale
                            )
                            video.transform.scale *= transform.scale
                            planned.clip.video = video
                        }
                        planned.clip.tags.append("filmora-template:\(name)")
                        track.clips.append(planned)
                    }
                case 2, 15:
                    if takeSounds {
                        let sounds = soundsTrack()
                        if var planned = mediaClip(child, on: sounds, shift: childShift, window: childWindow) {
                            planned.clip.tags.append("filmora-template:\(name)")
                            sounds.clips.append(planned)
                        }
                    }
                case 6, 7:
                    flatten(child, onto: track, shift: childShift, window: childWindow, depth: depth + 1)
                case 16:
                    flattenSounds(child, shift: childShift, window: childWindow, depth: depth + 1)
                default:
                    place(child, on: track, shift: childShift, window: childWindow, template: name, depth: depth + 1)
                }
            }
        }
        // The template's own transitions belong to the layers at its edges.
        let head = edge(clip.preTransition, at: begin, window: window)
        let tail = edge(clip.postTransition, at: end, window: window)
        let start = Wfp.time(begin + shift)
        let finish = Wfp.time(end + shift)
        for i in track.clips.indices.dropFirst(firstChild) {
            if track.clips[i].head == nil, track.clips[i].clip.start == start { track.clips[i].head = head }
            if track.clips[i].tail == nil, track.clips[i].clip.end == finish { track.clips[i].tail = tail }
        }
    }

    /// A template's sound (Filmora's type 16 clip, the audio half of a
    /// template) becomes the sounds inside it, once per template.
    private func flattenSounds(_ clip: WfpClip, shift: Int64, window: Range<Int64>?, depth: Int) {
        guard depth < 4, let id = clip.nestedTimelineID, let nested = wfp.timeline(id), let (begin, end) = clamp(clip, to: window) else { return }
        guard flattenedSounds.insert("\(id)@\(clip.begin + shift)").inserted else { return }
        let childShift = shift + clip.begin - clip.inPoint
        let childWindow = (begin - clip.begin + clip.inPoint)..<(end - clip.begin + clip.inPoint)
        let sounds = soundsTrack()
        for nestedTrack in nested.tracks {
            for child in nestedTrack.clips {
                if child.isAudio, var planned = mediaClip(child, on: sounds, shift: childShift, window: childWindow) {
                    planned.clip.tags.append("filmora-template-sound")
                    sounds.clips.append(planned)
                } else if child.type == 16 || ((child.type == 6 || child.type == 7) && child.nestedTimelineID != nil) {
                    flattenSounds(child, shift: childShift, window: childWindow, depth: depth + 1)
                }
            }
        }
    }

    private func soundsTrack() -> PlannedTrack {
        if let templateSounds { return templateSounds }
        let track = PlannedTrack(key: "template-sounds", kind: .audio)
        templateSounds = track
        return track
    }

    // MARK: - Lanes, names and looks

    /// Sorts a track's clips into lanes that don't overlap. Filmora's own
    /// rounding leaves sub-millisecond gaps and overlaps between clips that
    /// meet; those are closed so the clips (and their transitions) join.
    private func arrangeLanes(_ track: PlannedTrack) {
        let tolerance = Time(seconds: 0.001)
        var lanes: [[PlannedClip]] = []
        for clip in track.clips.sorted(by: { $0.clip.start < $1.clip.start }) {
            var placed = false
            for i in lanes.indices {
                guard let last = lanes[i].last else { continue }
                let gap = clip.clip.start - last.clip.end
                if gap >= .zero && gap > tolerance {
                    lanes[i].append(clip)
                    placed = true
                } else if abs(gap.seconds) <= tolerance.seconds {
                    if gap != .zero {
                        let trimmed = clip.clip.start - last.clip.start
                        if trimmed > .zero {
                            lanes[i][lanes[i].count - 1].clip.duration = trimmed
                        }
                    }
                    lanes[i].append(clip)
                    placed = true
                }
                if placed { break }
            }
            if !placed {
                if !lanes.isEmpty {
                    report.add(.note, "clip", "Overlapping clips on one Filmora track were spread over extra Tandem tracks.", at: clip.clip.start)
                }
                lanes.append([clip])
            }
        }
        track.lanes = lanes
    }

    private func nameTracks() {
        var used = Set<String>()
        func unique(_ base: String) -> String {
            var name = base
            var counter = 2
            while used.contains(name.lowercased()) {
                name = "\(base) \(counter)"
                counter += 1
            }
            used.insert(name.lowercased())
            return name
        }
        for track in orderedTracks() {
            let clips = track.lanes.flatMap { $0 }
            var counts: [Category: Int] = [:]
            for clip in clips { counts[clip.category, default: 0] += 1 }
            let base: String
            if track.key == "template-sounds" {
                base = "Template sounds"
            } else if track.kind == .video {
                let camera = counts[.camera] ?? 0
                let screen = counts[.screen] ?? 0
                let media = clips.filter { $0.clip.mediaID != nil }.count
                if camera > 0, screen > 0, Double(min(camera, screen)) >= 0.2 * Double(media) {
                    base = "Main"
                } else {
                    let order: [Category] = [.camera, .screen, .text, .graphic, .broll, .image, .sticker, .other]
                    let top = order.max { (counts[$0] ?? 0, -order.firstIndex(of: $0)!) < (counts[$1] ?? 0, -order.firstIndex(of: $1)!) } ?? .other
                    base = [.camera: "Camera", .screen: "Screen", .text: "Text", .graphic: "Graphics", .broll: "B-roll",
                            .image: "Images", .sticker: "Stickers"][top] ?? "Video"
                }
            } else if (counts[.voice] ?? 0) > 0 {
                base = "Voice"
            } else {
                let order: [Category] = [.screenAudio, .music, .sfx, .other]
                let top = order.max { (counts[$0] ?? 0, -order.firstIndex(of: $0)!) < (counts[$1] ?? 0, -order.firstIndex(of: $1)!) } ?? .other
                if let name = [.screenAudio: "Screen audio", .music: "Music", .sfx: "SFX"][top] {
                    base = name
                } else if let video = track.linkedVideoIndex.flatMap({ index in tracks.first { $0.filmoraIndex == index } }), let name = video.names.first {
                    // The sound of a video track named for what it shows.
                    base = "\(name) audio"
                } else {
                    base = "Audio"
                }
            }
            track.names = track.lanes.indices.map { unique($0 == 0 ? base : "\(base) extra") }
            let take = clips.filter { $0.category.isTake }.count
            track.rippleMode = !clips.isEmpty && Double(take) >= 0.5 * Double(clips.count) ? .cut : .follow
            track.ids = track.lanes.indices.map { ImportIDs.make("trk", key: "\(track.key):\($0)") }
        }
    }

    /// Video tracks bottom to top, with each track's extra lanes just above
    /// it; then audio: the sound of each video track in the same order, then
    /// standalone tracks, then template sounds.
    private func orderedTracks() -> [PlannedTrack] {
        let withClips = tracks.filter { !$0.lanes.isEmpty }
        let video = withClips.filter { $0.kind == .video }
        let lanes = withClips.filter { $0.kind == .audio && $0.linkedVideoIndex != nil }
            .sorted { ($0.linkedVideoIndex ?? 0, $0.filmoraIndex ?? 0) < ($1.linkedVideoIndex ?? 0, $1.filmoraIndex ?? 0) }
        let standalone = withClips.filter { $0.kind == .audio && $0.linkedVideoIndex == nil }
        let sounds = [templateSounds].compactMap { $0 }.filter { !$0.lanes.isEmpty }
        return video + lanes + standalone + sounds
    }

    /// A colour grade shared by every clip of a file moves onto the file's
    /// look, as Tandem keeps camera grades. Otherwise each clip keeps its own.
    private func assignLooks() -> [String: [Effect]] {
        func signature(_ effects: [Effect]) -> String {
            effects.map { "\($0.type):\($0.params.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" })" }.joined(separator: "|")
        }
        var grades: [String: [String]] = [:]
        var sample: [String: [Effect]] = [:]
        for track in tracks where track.kind == .video {
            for clip in track.lanes.flatMap({ $0 }) {
                guard let media = clip.clip.mediaID else { continue }
                grades[media, default: []].append(signature(clip.colour))
                if sample[media] == nil, !clip.colour.isEmpty { sample[media] = clip.colour }
            }
        }
        var looks: [String: [Effect]] = [:]
        for (media, signatures) in grades where Set(signatures).count == 1 {
            if let effects = sample[media] {
                looks[media] = effects.map { effect in
                    var effect = effect
                    effect.id = ImportIDs.make("fx", key: "look:\(media):\(effect.type)")
                    return effect
                }
            }
        }
        for track in tracks where track.kind == .video {
            for lane in track.lanes.indices {
                for i in track.lanes[lane].indices {
                    let clip = track.lanes[lane][i]
                    guard !clip.colour.isEmpty, let media = clip.clip.mediaID, looks[media] == nil else { continue }
                    var video = clip.clip.video ?? VideoProperties()
                    video.effects = clip.colour + video.effects
                    track.lanes[lane][i].clip.video = video
                }
            }
        }
        if !looks.isEmpty {
            report.add(.note, "colour", "A colour grade shared by every clip of a file was moved onto that file's look (\(looks.count) file(s)).")
        }
        return looks
    }

    // MARK: - Markers

    private func addMarkers(_ main: WfpTimeline) {
        let lists = wfp.markers.object ?? [:]
        var elsewhere = 0
        for (key, list) in lists where key != "beatDetectInfo" {
            let entries = list.array
            guard key == main.mapID else {
                elsewhere += entries.count
                continue
            }
            for (index, entry) in entries.enumerated() {
                guard let position = entry["position"].int64 else { continue }
                let name = entry["name"].string ?? ""
                let comment = entry["comments"].string ?? ""
                markers.append(Marker(
                    id: ids.make("mk", key: "marker:\(index):\(position)"),
                    time: Wfp.time(position),
                    name: name.isEmpty ? "Marker" : name,
                    kind: .marker,
                    note: comment.isEmpty ? nil : comment
                ))
            }
        }
        if elsewhere > 0 {
            report.add(.unsupported, "marker", "\(elsewhere) marker(s) on clips or other timelines weren't imported.")
        }
    }

    // MARK: - Building the project

    private func assemble(looks: [String: [Effect]]) -> Project {
        var project = Project(id: ImportIDs.make("prj", key: "filmora:\(wfp.guid ?? name)"), name: name, settings: settings)
        project.metadata = ["importedFrom": source, "importer": "filmora", "filmoraName": wfp.name]
        if let version = wfp.editorVersion { project.metadata["filmoraVersion"] = version }
        let builder = ProjectBuilder(project: project, report: report)

        let ordered = orderedTracks()
        let clips = ordered.flatMap { $0.lanes.flatMap { $0 } }
        let usedMedia = Set(clips.compactMap(\.clip.mediaID))
        let media = catalog.items.filter { usedMedia.contains($0.id) }.map { item -> MediaItem in
            var item = item
            item.look = looks[item.id] ?? []
            return item
        }
        builder.apply("Add media", media.map { ProjectBuilder.Step(.addMedia(item: $0), "media \($0.path)") })

        var trackSteps: [ProjectBuilder.Step] = []
        var videoIndex = 0
        var audioIndex = 0
        for track in ordered {
            for lane in track.lanes.indices {
                let index = track.kind == .video ? videoIndex : audioIndex
                trackSteps.append(ProjectBuilder.Step(.addTrack(kind: track.kind, name: track.names[lane], index: index, id: track.ids[lane]), "track \(track.names[lane])"))
                trackSteps.append(ProjectBuilder.Step(.updateTrack(trackID: track.ids[lane], patch: .object(["rippleMode": .string(track.rippleMode.rawValue)])), "ripple mode of \(track.names[lane])"))
                if track.kind == .video { videoIndex += 1 } else { audioIndex += 1 }
            }
        }
        builder.apply("Add tracks", trackSteps)

        for track in ordered {
            for (lane, planned) in track.lanes.enumerated() {
                builder.apply("Place clips on \(track.names[lane])", planned.map {
                    ProjectBuilder.Step(.insertClip(trackID: track.ids[lane], clip: $0.clip), "clip \($0.clip.name ?? $0.clip.id) at \($0.clip.start)", at: $0.clip.start)
                })
            }
        }

        builder.apply("Link pictures with their sound", linkSteps(ordered, placed: builder.project))
        // Working out transitions adds to the report, so hand it over and back.
        report = builder.report
        let transitions = transitionSteps(ordered, project: builder.project)
        builder.report = report
        builder.apply("Add transitions", transitions)
        builder.apply("Add markers", markers.sorted { $0.time < $1.time }.map {
            ProjectBuilder.Step(.addMarker(marker: $0), "marker \($0.name)", at: $0.time)
        })

        var settingsSteps: [ProjectBuilder.Step] = []
        for track in ordered {
            for lane in track.lanes.indices {
                var patch: [String: JSONValue] = [:]
                if track.muted {
                    patch[track.kind == .video ? "hidden" : "muted"] = .bool(true)
                }
                if track.locked { patch["locked"] = .bool(true) }
                if !patch.isEmpty {
                    settingsSteps.append(ProjectBuilder.Step(.updateTrack(trackID: track.ids[lane], patch: .object(patch)), "settings of \(track.names[lane])"))
                }
            }
        }
        builder.apply("Mute, hide and lock tracks", settingsSteps)

        let result = builder.project
        var stats: [String: Double] = [:]
        stats["duration"] = (result.duration.seconds * 1000).rounded() / 1000
        stats["clips"] = Double(result.allTracks.reduce(0) { $0 + $1.clips.count })
        stats["tracks"] = Double(result.allTracks.count)
        stats["transitions"] = Double(result.allTracks.reduce(0) { $0 + $1.transitions.count })
        stats["markers"] = Double(result.markers.count)
        stats["media"] = Double(result.media.count)
        stats["filmora.duration"] = (wfp.duration * 1000).rounded() / 1000
        let main = wfp.mainTimeline!
        stats["filmora.clips"] = Double(main.tracks.reduce(0) { $0 + $1.clips.count })
        stats["filmora.transitions"] = Double(main.tracks.reduce(0) { total, track in
            total + track.clips.reduce(0) { $0 + ($1.preTransition == nil ? 0 : 1) + ($1.postTransition == nil ? 0 : 1) }
        })
        builder.report.stats = stats
        report = builder.report
        return result
    }

    /// Links each picture with its sound (Filmora gives the pair one map
    /// ID), and the clips of one record-it take that share a time range.
    private func linkSteps(_ ordered: [PlannedTrack], placed project: Project) -> [ProjectBuilder.Step] {
        let clips = ordered.flatMap { $0.lanes.flatMap { $0 } }.filter { project.clip($0.clip.id) != nil && !$0.flattened }
        var parent: [String: String] = [:]
        func find(_ id: String) -> String {
            var root = id
            while let next = parent[root], next != root { root = next }
            parent[id] = root
            return root
        }
        func union(_ a: String, _ b: String) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[rb] = ra }
        }
        var byKey: [String: String] = [:]
        for clip in clips {
            parent[clip.clip.id] = clip.clip.id
            let range = "\(clip.clip.start.flicks):\(clip.clip.duration.flicks)"
            var keys: [String] = []
            if let map = clip.mapID { keys.append("map:\(map):\(range)") }
            if let take = clip.takeBase { keys.append("take:\(take):\(range)") }
            for key in keys {
                if let other = byKey[key] { union(other, clip.clip.id) } else { byKey[key] = clip.clip.id }
            }
        }
        var groups: [String: [String]] = [:]
        for clip in clips { groups[find(clip.clip.id), default: []].append(clip.clip.id) }
        return groups.values.filter { $0.count > 1 }.sorted { $0[0] < $1[0] }.map {
            ProjectBuilder.Step(.link(clipIDs: $0), "link \($0.count) clips")
        }
    }

    private func transitionSteps(_ ordered: [PlannedTrack], project: Project) -> [ProjectBuilder.Step] {
        var steps: [ProjectBuilder.Step] = []
        for track in ordered {
            for (lane, planned) in track.lanes.enumerated() {
                let trackID = track.ids[lane]
                let clips = planned.filter { project.clip($0.clip.id) != nil }
                var heads = Set<String>()
                var tails = Set<String>()
                for (i, current) in clips.enumerated() {
                    let next = i + 1 < clips.count && clips[i + 1].clip.start == current.clip.end ? clips[i + 1] : nil
                    let previous = i > 0 && clips[i - 1].clip.end == current.clip.start ? clips[i - 1] : nil
                    if let tail = current.tail, !tails.contains(current.clip.id) {
                        if tail.spansCut, let next, !heads.contains(next.clip.id) {
                            if let step = between(current.clip, next.clip, tail, track: track, trackID: trackID, project: project) {
                                steps.append(step)
                                tails.insert(current.clip.id)
                                heads.insert(next.clip.id)
                            }
                        } else if let step = end(current.clip, tail, head: false, track: track, trackID: trackID) {
                            steps.append(step)
                            tails.insert(current.clip.id)
                        }
                    }
                    if let head = current.head, !heads.contains(current.clip.id) {
                        if head.spansCut, let previous, !tails.contains(previous.clip.id) {
                            if let step = between(previous.clip, current.clip, head, track: track, trackID: trackID, project: project) {
                                steps.append(step)
                                tails.insert(previous.clip.id)
                                heads.insert(current.clip.id)
                            }
                        } else if let step = end(current.clip, head, head: true, track: track, trackID: trackID) {
                            steps.append(step)
                            heads.insert(current.clip.id)
                        }
                    }
                }
            }
        }
        return steps
    }

    private func mapped(_ edge: Edge, track: PlannedTrack, placement: FilmoraTransitions.Placement, at time: Time) -> FilmoraTransitions.Mapped {
        let mapped = FilmoraTransitions.map(edge.name, onAudio: track.kind == .audio, placement: placement)
        if !mapped.exact {
            let what = track.kind == .audio ? "a crossfade" : "a \(mapped.type.rawValue)"
            report.add(.approximated, "transition", "\"\(edge.name)\" plays as \(what).", at: time)
        }
        return mapped
    }

    /// A transition at a clip's head or tail, no longer than the clip.
    private func end(_ clip: Clip, _ edge: Edge, head: Bool, track: PlannedTrack, trackID: String) -> ProjectBuilder.Step? {
        let at = head ? clip.start : clip.end
        let type = mapped(edge, track: track, placement: head ? .head : .tail, at: at)
        let duration = min(edge.duration, clip.duration)
        let transition = Transition(
            id: ids.make("tr", key: "\(head ? "head" : "tail"):\(clip.id)"),
            type: type.type,
            direction: type.direction,
            duration: duration,
            fromClipID: head ? nil : clip.id,
            toClipID: head ? clip.id : nil
        )
        return ProjectBuilder.Step(.addTransition(trackID: trackID, transition: transition), "\(edge.name) at the \(head ? "head" : "tail") of \(clip.name ?? clip.id)", at: at)
    }

    /// A transition across a cut, shortened when either clip lacks the
    /// media it needs beyond the cut (Filmora freezes frames there; Tandem
    /// won't).
    private func between(_ from: Clip, _ to: Clip, _ edge: Edge, track: PlannedTrack, trackID: String, project: Project) -> ProjectBuilder.Step? {
        let type = mapped(edge, track: track, placement: .between, at: to.start)
        if edge.offCentre {
            report.add(.approximated, "transition", "An off-centre transition was centred on its cut.", at: to.start)
        }
        var duration = edge.duration
        let half = Time(flicks: duration.flicks / 2)
        func room(after clip: Clip) -> Time {
            guard let limit = project.sourceLimit(for: clip), !clip.freezeFrame else { return clip.duration }
            return Time(seconds: max(0, (limit - clip.sourceEnd).seconds / clip.speed))
        }
        func room(before clip: Clip) -> Time {
            guard clip.mediaID != nil, !clip.freezeFrame else { return clip.duration }
            return Time(seconds: max(0, clip.sourceStart.seconds / clip.speed))
        }
        if let media = to.mediaID, project.media(media)?.kind == .image {
            // TandemCore asks the incoming clip for media before its start,
            // which a still never has.
            report.add(.unsupported, "transition", "Transitions into a still image aren't supported yet; it cuts in.", at: to.start)
            return nil
        }
        let available = min(room(after: from), room(before: to), from.duration, to.duration)
        if half > available {
            let frames = available.flicks / frame.flicks
            guard frames >= 1 else {
                report.add(.unsupported, "transition", "A transition was left out: its clips have no media beyond the cut.", at: to.start)
                return nil
            }
            duration = Time(flicks: frames * frame.flicks * 2)
            report.add(.approximated, "transition", "A transition was shortened to fit the media either side of its cut.", at: to.start)
        }
        let transition = Transition(
            id: ids.make("tr", key: "cut:\(from.id):\(to.id)"),
            type: type.type,
            direction: type.direction,
            duration: duration,
            fromClipID: from.id,
            toClipID: to.id
        )
        return ProjectBuilder.Step(.addTransition(trackID: trackID, transition: transition), "\(edge.name) at \(to.start)", at: to.start)
    }
}

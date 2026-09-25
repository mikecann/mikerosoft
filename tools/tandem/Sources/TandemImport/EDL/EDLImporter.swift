import Foundation
import TandemCore
import TandemMedia

/// Rebuilds a video in Tandem from a segment EDL and its recipe.
///
/// The take is placed segment by segment with `placeMedia`, so each
/// segment's camera, voice and screen clips are linked and in sync. A
/// `screen` segment moves the camera into the corner with the cutout on; a
/// `cam` segment leaves it full frame over the screen. Then come the
/// recipe's layers: the intro, B-roll, graphics, transitions, one music cue
/// per section on alternating tracks, sound effects and section markers.
///
/// Everything the recipe places by take time lands on the same words
/// however the cut changed, and anything that can't be placed goes in the
/// report.
public struct EDLImporter: Sendable {
    public var recipe: EDLRecipe
    public var locating: MediaLocating

    public init(recipe: EDLRecipe, locating: MediaLocating = MediaLocating()) {
        self.recipe = recipe
        self.locating = locating
    }

    /// Imports the EDL at `url`, or the recipe's own EDL when nil.
    public func importEDL(at url: URL? = nil) async throws -> ImportResult {
        let edlURL: URL
        if let url {
            edlURL = url
        } else if let path = recipe.edl {
            edlURL = URL(fileURLWithPath: recipe.resolve(path))
        } else {
            throw ImportError.invalid("no EDL given and the recipe doesn't name one")
        }
        return try await importEDL(SegmentEDL.load(from: edlURL), source: edlURL.path)
    }

    public func importEDL(_ edl: SegmentEDL, source: String) async throws -> ImportResult {
        guard !recipe.takes.isEmpty else { throw ImportError.invalid("the recipe lists no takes") }
        guard !edl.segments.isEmpty else { throw ImportError.invalid("the EDL has no segments") }
        let run = EDLRun(recipe: recipe, locating: locating, edl: edl, source: source)
        return await run.build()
    }
}

/// One EDL import in progress.
private final class EDLRun {
    let recipe: EDLRecipe
    let edl: SegmentEDL
    let catalog: MediaCatalog
    let builder: ProjectBuilder
    var ids = ImportIDs.Allocator()

    /// A segment as it will be placed.
    struct Planned {
        var index: Int
        /// Take times after cut adjustments.
        var start: Double
        var end: Double
        var layout: SegmentEDL.Layout
        var take: Int
        var screenOffset: Double
        var broll: [(at: Double, duration: Double)]
        var timelineStart: Time = .zero
        var duration: Time = .zero
        var hasScreen = false
        var cameraClip: String?
        var voiceClip: String?
        var screenClip: String?

        var timelineEnd: Time { timelineStart + duration }
    }

    /// A placed transition, remembered for its sound.
    struct Placed {
        var role: EDLRecipe.TransitionRole
        /// Its middle, where a sound's loudest point should land.
        var middle: Time
    }

    var segments: [Planned] = []
    var placed: [Placed] = []
    var takeMedia: [(camera: MediaItem?, screen: MediaItem?)] = []
    var timelineEnd: Time = .zero

    init(recipe: EDLRecipe, locating: MediaLocating, edl: SegmentEDL, source: String) {
        self.recipe = recipe
        self.edl = edl
        self.catalog = MediaCatalog(locating: locating)
        var settings = ProjectSettings()
        if let width = recipe.width, let height = recipe.height {
            settings.width = width
            settings.height = height
        }
        if let fps = recipe.frameRate, let rate = AVFoundationProbe.frameRate(fps) {
            settings.frameRate = rate
        }
        var project = Project.standard(name: recipe.name)
        project.id = ImportIDs.make("prj", key: "edl:\(recipe.name)")
        project.settings = settings
        for i in project.videoTracks.indices {
            project.videoTracks[i].id = ImportIDs.make("trk", key: "edl:video:\(project.videoTracks[i].name)")
        }
        for i in project.audioTracks.indices {
            project.audioTracks[i].id = ImportIDs.make("trk", key: "edl:audio:\(project.audioTracks[i].name)")
        }
        project.metadata = ["importedFrom": source, "importer": "edl", "recipe": recipe.name]
        let report = ImportReport(source: source, importer: "edl", projectName: recipe.name)
        builder = ProjectBuilder(project: project, report: report)
    }

    func build() async -> ImportResult {
        for note in recipe.notes ?? [] {
            builder.report.add(.note, "recipe", note)
        }
        await addTakeMedia()
        if let intro = recipe.intro {
            _ = await media(intro.path, role: .broll)
        }
        planSegments()
        placeIntro()
        placeTakes()
        placeBroll()
        await placeInserts()
        addCutTransitions()
        await addMusic()
        await addSoundEffects()
        addSectionMarkers()
        finish()
        return ImportResult(project: builder.project, report: builder.report)
    }

    var report: ImportReport {
        get { builder.report }
        set { builder.report = newValue }
    }

    func trackID(_ name: String) -> String? {
        builder.project.track(named: name)?.id
    }

    // MARK: - Media

    private var mediaByPath: [String: MediaItem] = [:]

    /// Resolves a recipe path and returns its item once it's in the project.
    func media(_ path: String, role: MediaRole? = nil, at time: Time? = nil) async -> MediaItem? {
        let resolved = recipe.resolve(path)
        if let known = mediaByPath[resolved] { return known }
        var report = self.report
        let outcome = await catalog.resolve(resolved, role: role, report: &report, at: time)
        self.report = report
        switch outcome {
        case .found(let item), .offline(let item):
            let failed = builder.apply("Add \(URL(fileURLWithPath: resolved).lastPathComponent)", [
                ProjectBuilder.Step(.addMedia(item: item), "media \(resolved)")
            ])
            guard failed.isEmpty else { return nil }
            mediaByPath[resolved] = item
            return item
        case .unusable:
            return nil
        }
    }

    /// The take files, with the camera grade and a shared take ID.
    func addTakeMedia() async {
        let look = recipe.cameraLook ?? []
        var steps: [ProjectBuilder.Step] = []
        for (index, take) in recipe.takes.enumerated() {
            let cameraPath = recipe.resolve(take.camera)
            let takeID = "take_" + URL(fileURLWithPath: cameraPath).deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "-camera", with: "")
            var camera: MediaItem?
            var screen: MediaItem?
            var report = self.report
            switch await catalog.resolve(cameraPath, role: .camera, report: &report) {
            case .found(var item), .offline(var item):
                item.look = look
                item.takeID = takeID
                item.takeOffset = .zero
                camera = item
            case .unusable:
                report.add(.failed, "take", "Take \(index + 1) has no usable camera file, so its segments are left out.")
            }
            if let path = take.screen {
                switch await catalog.resolve(recipe.resolve(path), role: .screen, report: &report) {
                case .found(var item), .offline(var item):
                    item.takeID = camera == nil ? nil : takeID
                    item.takeOffset = .zero
                    screen = item
                case .unusable:
                    break
                }
            }
            self.report = report
            takeMedia.append((camera, screen))
            if let camera {
                steps.append(ProjectBuilder.Step(.addMedia(item: camera), "media \(camera.path)"))
                mediaByPath[cameraPath] = camera
            }
            if let screen, let path = take.screen {
                steps.append(ProjectBuilder.Step(.addMedia(item: screen), "media \(screen.path)"))
                mediaByPath[recipe.resolve(path)] = screen
            }
        }
        let failed = builder.apply("Add the take", steps)
        if !failed.isEmpty {
            // A take file that couldn't be added can't be placed either.
            let added = Set(builder.project.media.map(\.id))
            takeMedia = takeMedia.map { pair in
                (pair.camera.flatMap { added.contains($0.id) ? $0 : nil }, pair.screen.flatMap { added.contains($0.id) ? $0 : nil })
            }
        }
    }

    // MARK: - Segments

    func planSegments() {
        let adjustments = recipe.cutAdjustments ?? []
        let replacesBefore = recipe.intro?.replacesBefore
        var matched = Set<Int>()
        for (index, segment) in edl.segments.enumerated() {
            if let replacesBefore, segment.start < replacesBefore - 0.000_5 { continue }
            var start = segment.start
            var end = segment.end
            if let a = adjustments.firstIndex(where: { abs($0.start - start) < 0.002 && abs($0.end - end) < 0.002 }) {
                start = adjustments[a].newStart
                end = adjustments[a].newEnd
                matched.insert(a)
            }
            var layout = segment.layout
            if let override = recipe.layoutOverrides?.first(where: { start >= $0.from - 0.000_5 && start <= $0.to + 0.000_5 }) {
                layout = override.layout
            }
            let take = recipe.takes.lastIndex { $0.start <= start + 0.000_5 } ?? 0
            if take + 1 < recipe.takes.count, end > recipe.takes[take + 1].start {
                report.add(.approximated, "segment", "A segment ran past the end of its recording session and was cut at the session's end.")
                end = recipe.takes[take + 1].start
            }
            guard end - start > 0.001 else {
                report.add(.failed, "segment", "EDL segment \(index + 1) has no length.")
                continue
            }
            let broll = (segment.broll ?? []).compactMap { pair -> (Double, Double)? in
                pair.count >= 2 ? (pair[0], pair[1]) : nil
            }
            segments.append(Planned(
                index: index, start: start, end: end, layout: layout, take: take,
                screenOffset: segment.screenOffset ?? 0, broll: broll
            ))
        }
        let unmatched = adjustments.count - matched.count
        if unmatched > 0 {
            report.add(.note, "segment", "\(unmatched) cut adjustment(s) matched no segment in this EDL.")
        }

        // Lay the segments end to end after the intro.
        var cursor = Time.zero
        if let intro = recipe.intro, let item = mediaByPathOrCatalog(intro.path), let length = item.duration {
            cursor = length
        }
        for i in segments.indices {
            let take = recipe.takes[segments[i].take]
            let localStart = segments[i].start - take.start
            let localEnd = segments[i].end - take.start
            if let camera = takeMedia[segments[i].take].camera, let length = camera.duration, localEnd > length.seconds + 0.02 {
                report.add(.approximated, "segment", "A segment ran past the end of its camera file and was shortened.", at: cursor)
                segments[i].end = take.start + length.seconds
            }
            segments[i].timelineStart = cursor
            segments[i].duration = Time(seconds: segments[i].end - segments[i].start)
            cursor += segments[i].duration
            if let screen = takeMedia[segments[i].take].screen, let length = screen.duration {
                let screenStart = localStart + segments[i].screenOffset
                segments[i].hasScreen = screenStart >= 0 && screenStart + segments[i].duration.seconds <= length.seconds + 0.001
            }
            if segments[i].layout == .screen && !segments[i].hasScreen {
                segments[i].layout = .cam
                report.add(.approximated, "layout", "The screen recording ends before this segment, so it shows the camera full frame.", at: segments[i].timelineStart)
            }
        }
        timelineEnd = cursor
    }

    private func mediaByPathOrCatalog(_ path: String) -> MediaItem? {
        mediaByPath[recipe.resolve(path)] ?? catalog.item(forPath: recipe.resolve(path))
    }

    /// Where a take time plays on the new timeline.
    func timeline(forTake time: Double) -> Time? {
        for segment in segments where segment.start - 0.000_5 <= time && time < segment.end + 0.000_5 {
            return segment.timelineStart + Time(seconds: max(0, time - segment.start))
        }
        return nil
    }

    /// The start of the segment a section begins at: the one starting
    /// nearest `time`, or failing that the one playing it.
    func cut(nearTake time: Double, tolerance: Double = 0.6) -> Time? {
        if let segment = segments.min(by: { abs($0.start - time) < abs($1.start - time) }), abs(segment.start - time) <= tolerance {
            return segment.timelineStart
        }
        return timeline(forTake: time)
    }

    // MARK: - Intro and take clips

    func placeIntro() {
        guard let intro = recipe.intro, let item = mediaByPathOrCatalog(intro.path),
              let camera = trackID("Camera"), let voice = trackID("Voice") else { return }
        builder.apply("Place the intro", [
            ProjectBuilder.Step(.placeMedia(
                mediaIDs: [item.id], at: .zero, videoTrackID: camera, audioTrackID: voice, includeAudio: item.hasAudio
            ), "intro \(intro.path)")
        ])
        guard let audio = builder.project.track(named: "Voice")?.clip(at: .zero) else { return }
        var patch: [String: JSONValue] = [:]
        if let normalize = intro.normalizeTo { patch["normalizeTo"] = .number(normalize) }
        if let gain = intro.gainDB { patch["gainDB"] = .number(gain) }
        if !patch.isEmpty {
            builder.apply("Level the intro", [
                ProjectBuilder.Step(.updateClip(clipID: audio.id, patch: .object(["audio": .object(patch)])), "intro level")
            ])
        }
    }

    func placeTakes() {
        var steps: [ProjectBuilder.Step] = []
        for segment in segments {
            guard let camera = takeMedia[segment.take].camera else { continue }
            let local = segment.start - recipe.takes[segment.take].start
            var ids = [camera.id]
            if segment.hasScreen, let screen = takeMedia[segment.take].screen { ids.append(screen.id) }
            steps.append(ProjectBuilder.Step(
                .placeMedia(mediaIDs: ids, at: segment.timelineStart, sourceStart: Time(seconds: local), duration: segment.duration),
                "segment \(segment.index + 1) (\(segment.start)-\(segment.end))",
                at: segment.timelineStart
            ))
        }
        builder.apply("Place the take", steps)

        let project = builder.project
        let cameraTrack = project.track(named: "Camera")
        let voiceTrack = project.track(named: "Voice")
        let screenTrack = project.track(named: "Screen")
        for i in segments.indices {
            let start = segments[i].timelineStart
            segments[i].cameraClip = cameraTrack?.clips.first { $0.start == start }?.id
            segments[i].voiceClip = voiceTrack?.clips.first { $0.start == start }?.id
            segments[i].screenClip = segments[i].hasScreen ? screenTrack?.clips.first { $0.start == start }?.id : nil
        }

        var updates: [ProjectBuilder.Step] = []
        for segment in segments {
            if let clip = segment.cameraClip {
                updates.append(ProjectBuilder.Step(.updateClip(clipID: clip, patch: layoutPatch(segment.layout)), "layout", at: segment.timelineStart))
            }
            if let clip = segment.voiceClip, let voice = recipe.voice {
                var patch: [String: JSONValue] = [:]
                if let normalize = voice.normalizeTo { patch["normalizeTo"] = .number(normalize) }
                if let gain = voice.gainDB { patch["gainDB"] = .number(gain) }
                if !patch.isEmpty {
                    updates.append(ProjectBuilder.Step(.updateClip(clipID: clip, patch: .object(["audio": .object(patch)])), "voice level", at: segment.timelineStart))
                }
            }
            if let clip = segment.screenClip, segment.screenOffset != 0 {
                updates.append(ProjectBuilder.Step(
                    .slip(clipID: clip, delta: Time(seconds: segment.screenOffset), includeLinked: false),
                    "screen offset", at: segment.timelineStart
                ))
            }
        }
        builder.apply("Set layouts and voice levels", updates)
    }

    func layoutPatch(_ layout: SegmentEDL.Layout) -> JSONValue {
        switch layout {
        case .cam:
            return .object(["video": .object(["layoutPreset": .string("full")])])
        case .screen:
            let pip = recipe.pip ?? EDLRecipe.PiP(x: 0.87, y: 0.77, scale: 0.5)
            var video: [String: JSONValue] = [
                "transform": .object([
                    "position": .object(["x": .number(pip.x), "y": .number(pip.y)]),
                    "scale": .number(pip.scale),
                    "rotation": .number(0)
                ]),
                // The name TandemCore's LayoutPreset gives this layout.
                "layoutPreset": .string("pipRight")
            ]
            if pip.cutout ?? true {
                video["cutout"] = .object(["enabled": .bool(true)])
            }
            return .object(["video": .object(video)])
        }
    }

    // MARK: - B-roll and inserts

    /// The EDL's own B-roll: the screen shown full frame over a camera
    /// segment while the voice carries on.
    func placeBroll() {
        var wanted: [(start: Time, duration: Time, take: Int, local: Double)] = []
        for segment in segments {
            for (at, length) in segment.broll {
                let start = segment.timelineStart + Time(seconds: max(0, at - segment.start))
                wanted.append((start, Time(seconds: length), segment.take, at - recipe.takes[segment.take].start + segment.screenOffset))
            }
        }
        // Top-level overlays sit on the EDL's own timeline: the original
        // segments end to end, before the intro and any adjustments.
        if let overlays = edl.overlays, !overlays.isEmpty {
            var original: [(start: Double, segment: SegmentEDL.Segment)] = []
            var cursor = 0.0
            for segment in edl.segments {
                original.append((cursor, segment))
                cursor += segment.end - segment.start
            }
            for overlay in overlays {
                guard let host = original.last(where: { $0.start <= overlay.timeline + 0.000_5 }),
                      let start = timeline(forTake: host.segment.start + (overlay.timeline - host.start)) else {
                    report.add(.unsupported, "broll", "An EDL overlay falls in a part of the EDL this import dropped.")
                    continue
                }
                let take = recipe.takes.lastIndex { $0.start <= overlay.screenAt + 0.000_5 } ?? 0
                wanted.append((start, Time(seconds: overlay.duration), take, overlay.screenAt - recipe.takes[take].start))
            }
        }
        for item in wanted {
            guard let screen = takeMedia[item.take].screen else {
                report.add(.unsupported, "broll", "B-roll from a take with no screen recording was left out.", at: item.start)
                continue
            }
            var duration = item.duration
            if let length = screen.duration, Time(seconds: item.local) + duration > length {
                duration = length - Time(seconds: item.local)
            }
            guard item.local >= 0, duration > .zero else {
                report.add(.unsupported, "broll", "B-roll outside its screen recording was left out.", at: item.start)
                continue
            }
            let clip = Clip(
                id: ids.make("clip", key: "broll:\(item.start.flicks)"),
                name: "Screen B-roll",
                content: .media(mediaID: screen.id),
                start: item.start,
                duration: duration,
                sourceStart: Time(seconds: item.local)
            )
            placeOverlay(clip, family: "B-roll", slideIn: true, slideOut: true, what: "screen B-roll")
        }
    }

    func placeInserts() async {
        var previousEnd: Time?
        for (index, insert) in (recipe.inserts ?? []).enumerated() {
            let start: Time?
            if insert.afterPrevious == true {
                start = previousEnd
            } else if let at = insert.at {
                start = timeline(forTake: at)
            } else {
                start = nil
            }
            guard let start else {
                report.add(.unsupported, "insert", "\(insert.path) has no place on this cut (its take time isn't in any segment).")
                previousEnd = nil
                continue
            }
            let guessed = MediaScanner.role(forPath: insert.path)
            let role: MediaRole = [.graphic, .broll, .image, .sticker].contains(guessed) ? guessed : .broll
            guard let item = await media(insert.path, role: role, at: start) else {
                previousEnd = nil
                continue
            }
            let sourceStart = Time(seconds: insert.sourceStart ?? 0)
            var duration = Time(seconds: insert.duration)
            if item.kind != .image, let length = item.duration, sourceStart + duration > length {
                duration = length - sourceStart
                report.add(.approximated, "insert", "\(insert.path) is shorter than its slot, so it ends early.", at: start)
            }
            guard duration > .zero else { continue }
            let clip = Clip(
                id: ids.make("clip", key: "insert:\(index):\(insert.path)"),
                name: insert.note ?? URL(fileURLWithPath: insert.path).deletingPathExtension().lastPathComponent,
                content: .media(mediaID: item.id),
                start: start,
                duration: duration,
                sourceStart: item.kind == .image ? .zero : sourceStart
            )
            let family = role == .graphic ? "Graphics" : "B-roll"
            if placeOverlay(clip, family: family, slideIn: insert.slideIn ?? false, slideOut: insert.slideOut ?? false, what: insert.path) {
                previousEnd = clip.end
            } else {
                previousEnd = nil
            }
        }
    }

    /// Puts a clip on the first free track of a family and adds its
    /// slide in and out.
    @discardableResult
    func placeOverlay(_ clip: Clip, family: String, slideIn: Bool, slideOut: Bool, what: String) -> Bool {
        guard let track = builder.freeTrack(.video, family: family, range: clip.range) else { return false }
        let failed = builder.apply("Place \(what)", [ProjectBuilder.Step(.insertClip(trackID: track, clip: clip), what, at: clip.start)])
        guard failed.isEmpty else { return false }
        var steps: [ProjectBuilder.Step] = []
        if slideIn, let spec = recipe.transitions?.overlayIn {
            let duration = min(Time(seconds: spec.duration), clip.duration)
            steps.append(ProjectBuilder.Step(.addTransition(trackID: track, transition: Transition(
                id: ids.make("tr", key: "in:\(clip.id)"), type: spec.type, direction: spec.direction,
                duration: duration, fromClipID: nil, toClipID: clip.id
            )), "\(what) slide in", at: clip.start))
            placed.append(Placed(role: .overlayIn, middle: clip.start + Time(flicks: duration.flicks / 2)))
        }
        if slideOut, let spec = recipe.transitions?.overlayOut {
            let duration = min(Time(seconds: spec.duration), clip.duration)
            steps.append(ProjectBuilder.Step(.addTransition(trackID: track, transition: Transition(
                id: ids.make("tr", key: "out:\(clip.id)"), type: spec.type, direction: spec.direction,
                duration: duration, fromClipID: clip.id, toClipID: nil
            )), "\(what) slide out", at: clip.end))
            placed.append(Placed(role: .overlayOut, middle: clip.end - Time(flicks: duration.flicks / 2)))
        }
        builder.apply("Slide \(what)", steps)
        return true
    }

    // MARK: - Transitions between segments

    func addCutTransitions() {
        guard let transitions = recipe.transitions else { return }
        var steps: [ProjectBuilder.Step] = []
        let pushTolerance = transitions.topicPush?.tolerance ?? 0.6
        for i in segments.indices.dropFirst() {
            let previous = segments[i - 1]
            let segment = segments[i]
            guard previous.timelineEnd == segment.timelineStart else { continue }
            if previous.layout != segment.layout, let spec = transitions.layoutSwitch {
                if let step = cutTransition(spec, track: "Camera", from: previous.cameraClip, to: segment.cameraClip, at: segment.timelineStart, role: .layoutSwitch) {
                    steps.append(step)
                }
            } else if previous.layout == .screen, segment.layout == .screen, let push = transitions.topicPush,
                      push.at.contains(where: { abs($0 - segment.start) < pushTolerance }) {
                if let step = cutTransition(push.spec, track: "Screen", from: previous.screenClip, to: segment.screenClip, at: segment.timelineStart, role: .topicPush) {
                    steps.append(step)
                }
            }
        }
        if let spec = transitions.end, let last = segments.last {
            var duration = Time(seconds: spec.duration)
            if duration > last.duration {
                report.add(.approximated, "transition", "The closing \(spec.type.rawValue) is longer than the last clip, so it was shortened to fit.", at: last.timelineEnd)
                duration = last.duration
            }
            for (name, clip) in [("Camera", last.cameraClip), ("Screen", last.screenClip)] {
                guard let clip, let track = trackID(name) else { continue }
                steps.append(ProjectBuilder.Step(.addTransition(trackID: track, transition: Transition(
                    id: ids.make("tr", key: "end:\(clip)"), type: spec.type, direction: spec.direction,
                    duration: duration, fromClipID: clip, toClipID: nil
                )), "closing \(spec.type.rawValue) on \(name)", at: last.timelineEnd))
            }
            placed.append(Placed(role: .end, middle: last.timelineEnd - Time(flicks: duration.flicks / 2)))
            if let voice = last.voiceClip {
                steps.append(ProjectBuilder.Step(.updateClip(clipID: voice, patch: .object([
                    "audio": .object(["fadeOut": .number(duration.seconds)])
                ])), "voice fade at the end", at: last.timelineEnd))
            }
        }
        builder.apply("Add transitions", steps)
    }

    /// A transition centred on a cut, shortened when the clips don't have
    /// enough media either side of the cut.
    func cutTransition(_ spec: EDLRecipe.TransitionSpec, track name: String, from: String?, to: String?, at time: Time, role: EDLRecipe.TransitionRole) -> ProjectBuilder.Step? {
        guard let from, let to, let track = trackID(name),
              let fromClip = builder.project.clip(from), let toClip = builder.project.clip(to) else {
            report.add(.unsupported, "transition", "A \(spec.type.rawValue) had no clip on one side of its cut.", at: time)
            return nil
        }
        var duration = Time(seconds: spec.duration)
        let frame = builder.project.settings.frameRate.frameDuration
        let after = builder.project.sourceLimit(for: fromClip).map { $0 - fromClip.sourceEnd } ?? duration
        let before = toClip.sourceStart
        let room = min(after, before, fromClip.duration, toClip.duration)
        if Time(flicks: duration.flicks / 2) > room {
            let fitted = Time(flicks: (room.flicks / frame.flicks) * frame.flicks * 2)
            guard fitted >= frame + frame else {
                report.add(.unsupported, "transition", "A \(spec.type.rawValue) was left out: the clips have no media beyond the cut.", at: time)
                return nil
            }
            report.add(.approximated, "transition", "A \(spec.type.rawValue) was shortened to fit the media either side of the cut.", at: time)
            duration = fitted
        }
        placed.append(Placed(role: role, middle: time))
        return ProjectBuilder.Step(.addTransition(trackID: track, transition: Transition(
            id: ids.make("tr", key: "cut:\(from):\(to)"), type: spec.type, direction: spec.direction,
            duration: duration, fromClipID: from, toClipID: to
        )), "\(spec.type.rawValue) at the cut", at: time)
    }

    // MARK: - Music

    struct SectionTime {
        var section: EDLRecipe.Section
        var time: Time
    }

    var sectionTimes: [SectionTime] = []

    func resolveSections() async {
        guard sectionTimes.isEmpty else { return }
        var result: [SectionTime] = []
        for (index, section) in (recipe.sections ?? []).enumerated() {
            if section.outro == true {
                // Placed so its cue ends with the video; worked out with the music.
                let cueLength = await cueDuration(section.music)
                let trim = recipe.music?.outroTrim ?? 0
                let start = cueLength.map { max(.zero, timelineEnd - $0 + Time(seconds: trim)) } ?? timelineEnd
                result.append(SectionTime(section: section, time: start))
            } else if let at = section.at {
                guard let time = cut(nearTake: at) else {
                    report.add(.unsupported, "section", "Section \"\(section.name)\" starts at a take time this cut doesn't include.")
                    continue
                }
                result.append(SectionTime(section: section, time: time))
            } else if index == 0 {
                result.append(SectionTime(section: section, time: .zero))
            } else {
                report.add(.unsupported, "section", "Section \"\(section.name)\" has no take time.")
            }
        }
        sectionTimes = result.sorted { $0.time < $1.time }
    }

    func cueDuration(_ path: String?) async -> Time? {
        guard let path, let item = await media(path, role: .music) else { return nil }
        return item.duration
    }

    func addMusic() async {
        await resolveSections()
        guard let music = recipe.music else { return }
        let crossfade = Time(seconds: music.crossfade)
        let half = Time(flicks: crossfade.flicks / 2)
        let cues = sectionTimes.filter { $0.section.music != nil }
        // Each cue starts half a crossfade before its section's cut (the
        // first one at the very start, the outro where it was placed) and
        // runs a full crossfade into the next one.
        var starts: [Time] = []
        for (i, cue) in cues.enumerated() {
            if cue.section.outro == true || (i == 0 && cue.time == .zero) {
                starts.append(cue.time)
            } else {
                starts.append(max(.zero, cue.time - half))
            }
        }
        for (i, cue) in cues.enumerated() {
            guard let path = cue.section.music, let item = await media(path, role: .music, at: starts[i]) else { continue }
            let start = starts[i]
            let isLast = i == cues.count - 1
            var end = isLast ? timelineEnd : starts[i + 1] + crossfade
            if let length = item.duration, end - start > length {
                end = start + length
                report.add(.approximated, "music", "\(URL(fileURLWithPath: path).lastPathComponent) is shorter than its section, so it ends early.", at: end)
            }
            guard end > start else { continue }
            let duration = end - start
            let audio = AudioProperties(
                gainDB: music.gainDB ?? 0,
                fadeIn: start == .zero ? .zero : min(crossfade, duration),
                fadeOut: isLast ? min(Time(seconds: music.endFadeOut ?? 0), duration) : min(crossfade, duration),
                normalizeTo: music.normalizeTo
            )
            let clip = Clip(
                id: ids.make("clip", key: "music:\(i):\(path)"),
                name: cue.section.name,
                content: .media(mediaID: item.id),
                start: start,
                duration: duration,
                audio: audio,
                tags: ["music-cue"]
            )
            // Cues alternate between two tracks so each crossfade has room.
            let preferred = i % 2 == 0 ? "Music" : "Music 2"
            let track: String?
            if let existing = builder.project.track(named: preferred, kind: .audio) {
                track = existing.isFree(clip.range) ? existing.id : builder.freeTrack(.audio, family: "Music", range: clip.range)
            } else {
                let after = builder.project.location(ofTrack: trackID("Music") ?? "").map { $0.index + 1 }
                track = builder.addTrack(.audio, name: preferred, rippleMode: .follow, index: after)
            }
            guard let track else { continue }
            builder.apply("Add music", [ProjectBuilder.Step(.insertClip(trackID: track, clip: clip), "music cue \(cue.section.name)", at: start)])
        }
    }

    // MARK: - Sound effects

    func addSoundEffects() async {
        guard let sfx = recipe.sfx else { return }
        struct Candidate {
            var at: Time
            var sound: EDLRecipe.TransitionSound
        }
        var candidates: [Candidate] = []
        for transition in placed {
            for sound in sfx.onTransitions ?? [] where sound.on == transition.role {
                candidates.append(Candidate(at: transition.middle, sound: sound))
            }
        }
        // Higher priority first, then earlier; a sound too close to one
        // already kept is dropped.
        candidates.sort { a, b in
            let pa = a.sound.priority ?? 0
            let pb = b.sound.priority ?? 0
            return pa != pb ? pa > pb : a.at < b.at
        }
        let gap = Time(seconds: sfx.minGap ?? 0)
        var kept: [Candidate] = []
        for candidate in candidates where kept.allSatisfy({ abs(($0.at - candidate.at).seconds) >= gap.seconds - 0.000_001 }) {
            kept.append(candidate)
        }
        var sounds: [(path: String, start: Time, gain: Double?, name: String?)] = kept.map { candidate in
            (candidate.sound.path, max(.zero, candidate.at - Time(seconds: candidate.sound.peak)), candidate.sound.gainDB, nil)
        }
        for event in sfx.events ?? [] {
            guard let start = timeline(forTake: event.at) else {
                report.add(.unsupported, "sfx", "\(event.path) at take time \(event.at) has no place on this cut.")
                continue
            }
            sounds.append((event.path, start, event.gainDB, event.note))
        }
        sounds.sort { $0.start < $1.start }
        for (index, sound) in sounds.enumerated() {
            guard let item = await media(sound.path, role: .sfx, at: sound.start), let length = item.duration else { continue }
            let clip = Clip(
                id: ids.make("clip", key: "sfx:\(index):\(sound.path):\(sound.start.flicks)"),
                name: sound.name ?? URL(fileURLWithPath: sound.path).deletingPathExtension().lastPathComponent,
                content: .media(mediaID: item.id),
                start: sound.start,
                duration: length,
                audio: AudioProperties(gainDB: sound.gain ?? 0)
            )
            guard let track = builder.freeTrack(.audio, family: "SFX", range: clip.range) else { continue }
            builder.apply("Add a sound effect", [ProjectBuilder.Step(.insertClip(trackID: track, clip: clip), "sound \(sound.path)", at: sound.start)])
        }
    }

    // MARK: - Markers and stats

    func addSectionMarkers() {
        let steps = sectionTimes.enumerated().map { index, entry in
            ProjectBuilder.Step(.addMarker(marker: Marker(
                id: ids.make("mk", key: "section:\(index):\(entry.section.name)"),
                time: entry.time,
                name: entry.section.name,
                kind: .section
            )), "section \(entry.section.name)", at: entry.time)
        }
        builder.apply("Mark sections", steps)
    }

    func finish() {
        let project = builder.project
        var stats: [String: Double] = [:]
        stats["segments"] = Double(segments.count)
        stats["duration"] = (project.duration.seconds * 1000).rounded() / 1000
        stats["clips"] = Double(project.allTracks.reduce(0) { $0 + $1.clips.count })
        stats["tracks"] = Double(project.allTracks.count)
        stats["transitions"] = Double(project.allTracks.reduce(0) { $0 + $1.transitions.count })
        stats["markers"] = Double(project.markers.count)
        stats["media"] = Double(project.media.count)
        builder.report.stats = stats
    }
}

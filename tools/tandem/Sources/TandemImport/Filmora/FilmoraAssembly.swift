import Foundation
import TandemCore

// The second half of a Filmora import: laying planned clips on tracks and
// building the project through the coordinator.

extension FilmoraRun {
    // MARK: - Lanes, names and looks

    /// Sorts a track's clips into lanes that don't overlap. Filmora's own
    /// rounding leaves sub-millisecond gaps and overlaps between clips that
    /// meet; those are closed so the clips (and their transitions) join.
    func arrangeLanes(_ track: PlannedTrack) {
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
                            var previous = lanes[i][lanes[i].count - 1].clip
                            previous.duration = trimmed
                            if var audio = previous.audio {
                                audio.fadeIn = min(audio.fadeIn, trimmed)
                                audio.fadeOut = min(audio.fadeOut, trimmed)
                                previous.audio = audio
                            }
                            lanes[i][lanes[i].count - 1].clip = previous
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

    func nameTracks() {
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
    func orderedTracks() -> [PlannedTrack] {
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
    func assignLooks() -> [String: [Effect]] {
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

    func addMarkers(_ main: WfpTimeline) {
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

    func assemble(looks: [String: [Effect]]) -> Project {
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
        // Before tracks are locked, which normalizeSpeech leaves alone.
        levelSpeech(builder)

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

    /// Speech is normalised to the project's speech level, as clips placed
    /// in Tandem are, unless the import keeps Filmora's levels. Either way
    /// the report says what happened to Filmora's gains.
    func levelSpeech(_ builder: ProjectBuilder) {
        let speech = AudioLevels.speechClips(in: builder.project)
        if speechLevels == .normalize, !speech.isEmpty {
            let gains = speech.map { $0.clip.audio?.gainDB ?? 0 }
            let low = gains.min() ?? 0, high = gains.max() ?? 0
            let filmora = low == high ? String(format: "%+.1f dB", low) : String(format: "%+.1f to %+.1f dB", low, high)
            let level = AudioLevels.number(builder.project.settings.speechLoudness)
            builder.apply("Level speech", [ProjectBuilder.Step(.normalizeSpeech, "speech clips")])
            builder.report.add(.note, "audio", "\(speech.count) speech clips were normalised to \(level) LUFS, the project's speech level, with no gain instead of Filmora's \(filmora). Import with --keep-levels to keep Filmora's.")
        }
        let autoNormalized = builder.project.audioTracks.flatMap(\.clips).filter { $0.audio?.normalizeTo == Self.autoNormalizationLUFS }
        if !autoNormalized.isEmpty {
            builder.report.add(.note, "audio", "Filmora's Auto Normalization became normalise to -24 LUFS (where Filmora levels, on Tandem's meter) with the clip's loudness gain on top, on \(autoNormalized.count) clip(s).")
        }
    }

    /// Links each picture with its sound (Filmora gives the pair one map
    /// ID), and the clips of one record-it take that share a time range.
    func linkSteps(_ ordered: [PlannedTrack], placed project: Project) -> [ProjectBuilder.Step] {
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

    func transitionSteps(_ ordered: [PlannedTrack], project: Project) -> [ProjectBuilder.Step] {
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

    func mapped(_ edge: Edge, track: PlannedTrack, placement: FilmoraTransitions.Placement, at time: Time) -> FilmoraTransitions.Mapped {
        let mapped = FilmoraTransitions.map(edge.name, onAudio: track.kind == .audio, placement: placement)
        if !mapped.exact {
            let what = track.kind == .audio ? "a crossfade" : "a \(mapped.type.rawValue)"
            report.add(.approximated, "transition", "\"\(edge.name)\" plays as \(what).", at: time)
        }
        return mapped
    }

    /// A transition at a clip's head or tail, no longer than the clip.
    func end(_ clip: Clip, _ edge: Edge, head: Bool, track: PlannedTrack, trackID: String) -> ProjectBuilder.Step? {
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
    func between(_ from: Clip, _ to: Clip, _ edge: Edge, track: PlannedTrack, trackID: String, project: Project) -> ProjectBuilder.Step? {
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

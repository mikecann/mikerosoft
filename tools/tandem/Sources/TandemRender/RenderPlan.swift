import Foundation
import TandemCore
import TandemMedia

// The render plan is a pure description of how a project maps onto
// AVFoundation: which media plays on which composition track and when, what
// the compositor draws in each stretch of time, and the volume of every
// piece of sound. Keeping it free of AVFoundation makes the timeline rules
// testable without media, and the builder a thin translation.

/// A stretch of one file on one composition track.
struct PlannedSegment: Equatable {
    enum Role: Equatable {
        /// A video clip's picture.
        case picture
        /// The cutout matte for a video clip, mirroring its time mapping.
        case matte
        /// An audio clip's sound.
        case sound
        /// The cached isolated voice for an audio clip.
        case isolatedVoice
    }

    var clipID: String
    var mediaID: String
    var role: Role
    /// Where the segment plays on the timeline, including transition handles.
    var timeline: TimeRange
    /// Media time at `timeline.start`.
    var sourceStart: Time
    var speed: Double
    var freeze: Bool
    /// Index of the composition track within its pool (video or audio).
    var track: Int = 0
    /// Sound only: volume breakpoints on the timeline, linear gain.
    var envelope: [GainPoint] = []
}

struct GainPoint: Equatable {
    var time: Time
    var gain: Double
}

/// One clip drawn by the compositor.
struct LayerRef: Equatable {
    var clipID: String
    /// Index into `project.videoTracks`.
    var trackIndex: Int
    /// Composition track (video pool index) with the clip's picture, for
    /// video media.
    var pictureTrack: Int?
    /// Composition track with the clip's matte, when it has a cutout and the
    /// matte exists.
    var matteTrack: Int?
}

struct TransitionRef: Equatable {
    var transition: Transition
    /// When the transition plays on the timeline.
    var window: TimeRange
    var trackIndex: Int
}

/// What one video track contributes to a frame: a clip, or a transition
/// between two (either side may be missing at a clip's head or tail).
indirect enum StackNode: Equatable {
    case layer(LayerRef)
    case transition(TransitionRef, from: StackNode?, to: StackNode?)

    /// Every clip drawn by this node.
    var layers: [LayerRef] {
        switch self {
        case .layer(let ref): return [ref]
        case .transition(_, let from, let to): return (from?.layers ?? []) + (to?.layers ?? [])
        }
    }
}

/// A stretch of the timeline with one layer stack, bottom track first.
struct PlannedInstruction: Equatable {
    var range: TimeRange
    var stack: [StackNode]
}

struct RenderPlan {
    var duration: Time
    var videoSegments: [PlannedSegment]
    var audioSegments: [PlannedSegment]
    var videoTrackCount: Int
    var audioTrackCount: Int
    var instructions: [PlannedInstruction]
    var warnings: [String]
}

enum RenderPlanner {
    /// Hard cuts on audio get a fade this long each side so nothing clicks.
    static let microFade = Time(seconds: 0.003)

    static func plan(_ project: Project, format: String?, assets: RenderAssets?) -> RenderPlan {
        var warnings = Warnings()
        let duration = project.duration
        let mediaByID = Dictionary(project.media.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // MARK: Video

        var planned: [[PlannedClip]] = Array(repeating: [], count: project.videoTracks.count)
        var windows: [[TransitionRef]] = Array(repeating: [], count: project.videoTracks.count)
        var videoSegments: [PlannedSegment] = []

        for (trackIndex, track) in project.videoTracks.enumerated() where !track.hidden {
            let trackWindows = transitionWindows(track, trackIndex: trackIndex)
            windows[trackIndex] = trackWindows
            let (heads, tails) = extensions(track, trackWindows)

            for clip in track.clips where clip.enabled && !clip.isHidden(inFormat: format) {
                var item: MediaItem?
                switch clip.content {
                case .graphic(let graphic):
                    warnings.add("Graphic clips aren't rendered yet (\(graphic.template)).")
                    continue
                case .media(let mediaID):
                    guard let found = mediaByID[mediaID] else {
                        warnings.add("Clip \(clip.id) uses missing media \(mediaID).")
                        continue
                    }
                    guard found.kind == .image || found.hasVideo else { continue }
                    item = found
                case .text, .solid, .adjustment:
                    break
                }

                var head = heads[clip.id] ?? .zero
                let tail = tails[clip.id] ?? .zero
                let isMovingVideo = item.map { $0.kind == .video } ?? false
                if isMovingVideo && !clip.freezeFrame {
                    // There's no picture before the start of the file.
                    let available = Time(seconds: max(0, clip.sourceStart.seconds) / clip.speed)
                    head = min(head, available)
                }
                let visible = TimeRange(start: clip.start - head, end: clip.end + tail)
                planned[trackIndex].append(PlannedClip(clip: clip, trackIndex: trackIndex, visible: visible))

                guard let item, isMovingVideo else { continue }
                if let codec = item.undecodableCodecName, assets?.convertedURL(for: item) == nil {
                    warnings.add("\(item.path) is \(codec), which macOS can't decode, and it isn't converted yet, so it's left out.")
                    continue
                }
                let sourceStart = clip.freezeFrame ? clip.sourceStart : clip.sourceStart - head.scaled(by: clip.speed)
                let picture = PlannedSegment(
                    clipID: clip.id, mediaID: item.id, role: .picture, timeline: visible,
                    sourceStart: sourceStart, speed: clip.speed, freeze: clip.freezeFrame
                )
                videoSegments.append(picture)
                if let cutout = clip.video?.cutout, cutout.enabled {
                    if assets?.matteURL(for: item, cutout: cutout) != nil {
                        var matte = picture
                        matte.role = .matte
                        videoSegments.append(matte)
                    } else {
                        warnings.add("No cutout matte for \(item.path) yet, showing the full frame.")
                    }
                }
            }
        }
        let videoTrackCount = assignTracks(&videoSegments)

        // MARK: Instructions

        var tracksOfClip: [String: (picture: Int?, matte: Int?)] = [:]
        for segment in videoSegments {
            var entry = tracksOfClip[segment.clipID] ?? (nil, nil)
            if segment.role == .picture { entry.picture = segment.track } else { entry.matte = segment.track }
            tracksOfClip[segment.clipID] = entry
        }

        var bounds = Set<Time>([.zero, duration])
        for clips in planned {
            for p in clips {
                bounds.insert(p.visible.start)
                bounds.insert(p.visible.end)
            }
        }
        for list in windows {
            for w in list {
                bounds.insert(w.window.start)
                bounds.insert(w.window.end)
            }
        }
        let times = bounds.filter { $0 >= .zero && $0 <= duration }.sorted()
        var instructions: [PlannedInstruction] = []
        for (a, b) in zip(times, times.dropFirst()) where a < b {
            let middle = Time(flicks: a.flicks + (b.flicks - a.flicks) / 2)
            var stack: [StackNode] = []
            for trackIndex in planned.indices {
                stack += nodes(
                    at: middle, clips: planned[trackIndex], windows: windows[trackIndex],
                    tracksOfClip: tracksOfClip
                )
            }
            if var last = instructions.last, last.stack == stack, last.range.end == a {
                last.range = TimeRange(start: last.range.start, end: b)
                instructions[instructions.count - 1] = last
            } else {
                instructions.append(PlannedInstruction(range: TimeRange(start: a, end: b), stack: stack))
            }
        }

        // MARK: Audio

        var audioSegments: [PlannedSegment] = []
        let soloing = project.audioTracks.contains { $0.solo && !$0.muted }
        for track in project.audioTracks where !track.muted && (!soloing || track.solo) {
            let trackWindows = transitionWindows(track, trackIndex: 0)
            let (heads, tails) = extensions(track, trackWindows)
            // Muted clips are left out entirely, so they never count as the
            // neighbour of a seamless join.
            let enabled = track.clips.filter { $0.enabled && !($0.audio?.muted ?? false) }
            for (index, clip) in enabled.enumerated() {
                guard case .media(let mediaID) = clip.content, let item = mediaByID[mediaID], item.hasAudio else { continue }
                let audio = clip.audio ?? AudioProperties()

                var head = heads[clip.id] ?? .zero
                let tail = tails[clip.id] ?? .zero
                if !clip.freezeFrame {
                    head = min(head, Time(seconds: max(0, clip.sourceStart.seconds) / clip.speed))
                }
                let timeline = TimeRange(start: clip.start - head, end: clip.end + tail)
                let headWindow = trackWindows.first { $0.transition.toClipID == clip.id }?.window
                let tailWindow = trackWindows.first { $0.transition.fromClipID == clip.id }?.window
                let previous = index > 0 ? enabled[index - 1] : nil
                let next = index + 1 < enabled.count ? enabled[index + 1] : nil
                let seamlessIn = previous.map { isSeamless($0, clip) } ?? false
                let seamlessOut = next.map { isSeamless(clip, $0) } ?? false

                // Normalising is a constant gain from the file's measured
                // loudness; the clip gain (and its keyframes) go on top in
                // the envelope. The viewer, review clips and export all take
                // their sound from this plan, so they level the same.
                var constant = 1.0
                if let target = audio.normalizeTo {
                    let measured = assets?.loudness(for: item)?.integratedLUFS
                    if let gain = AudioLevels.normalizeGainDB(target: target, measuredLUFS: measured) {
                        constant *= AudioEnvelope.gain(dB: gain)
                    } else {
                        warnings.add("No loudness measurement for \(item.path) yet, so it isn't normalised.")
                    }
                }
                let isolation = min(max(audio.voiceIsolation, 0), 1)
                let isolated = isolation > 0 && assets?.isolatedVoiceURL(for: item) != nil
                if isolation > 0 && !isolated {
                    warnings.add("No isolated voice for \(item.path) yet, playing the original.")
                }

                let shape = AudioEnvelope.Shape(
                    clip: clip, segment: timeline, headWindow: headWindow, tailWindow: tailWindow,
                    microFadeIn: headWindow == nil && !seamlessIn && audio.fadeIn < microFade,
                    microFadeOut: tailWindow == nil && !seamlessOut && audio.fadeOut < microFade
                )
                let sourceStart = clip.freezeFrame ? clip.sourceStart : clip.sourceStart - head.scaled(by: clip.speed)
                let original = PlannedSegment(
                    clipID: clip.id, mediaID: item.id, role: .sound, timeline: timeline,
                    sourceStart: sourceStart, speed: clip.speed, freeze: clip.freezeFrame,
                    envelope: AudioEnvelope.points(shape, constantGain: constant * (isolated ? 1 - isolation : 1))
                )
                if !isolated || isolation < 1 {
                    audioSegments.append(original)
                }
                if isolated {
                    var voice = original
                    voice.role = .isolatedVoice
                    voice.envelope = AudioEnvelope.points(shape, constantGain: constant * isolation)
                    audioSegments.append(voice)
                }
            }
        }
        let audioTrackCount = assignTracks(&audioSegments)

        return RenderPlan(
            duration: duration,
            videoSegments: videoSegments,
            audioSegments: audioSegments,
            videoTrackCount: videoTrackCount,
            audioTrackCount: audioTrackCount,
            instructions: instructions,
            warnings: warnings.list
        )
    }

    // MARK: - Helpers

    struct PlannedClip {
        var clip: Clip
        var trackIndex: Int
        /// The clip's range plus any transition handles it plays through.
        var visible: TimeRange
    }

    /// When each transition on a track plays. A transition between two clips
    /// is centred on the cut; one at a clip's head or tail sits inside it.
    static func transitionWindows(_ track: Track, trackIndex: Int) -> [TransitionRef] {
        let clips = Dictionary(track.clips.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return track.transitions.compactMap { t in
            guard t.duration > .zero else { return nil }
            let from = t.fromClipID.flatMap { clips[$0] }
            let to = t.toClipID.flatMap { clips[$0] }
            let window: TimeRange
            switch (from, to) {
            case let (a?, b?):
                guard a.end == b.start else { return nil }
                let half = Time(flicks: t.duration.flicks / 2)
                window = TimeRange(start: a.end - half, duration: t.duration)
            case let (a?, nil):
                let length = min(t.duration, a.duration)
                window = TimeRange(start: a.end - length, duration: length)
            case let (nil, b?):
                window = TimeRange(start: b.start, duration: min(t.duration, b.duration))
            case (nil, nil):
                return nil
            }
            return TransitionRef(transition: t, window: window, trackIndex: trackIndex)
        }
        .sorted { $0.window.start < $1.window.start }
    }

    /// How far each clip plays past its edges to cover centred transitions.
    static func extensions(_ track: Track, _ windows: [TransitionRef]) -> (heads: [String: Time], tails: [String: Time]) {
        var heads: [String: Time] = [:]
        var tails: [String: Time] = [:]
        let clips = Dictionary(track.clips.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for w in windows {
            guard let fromID = w.transition.fromClipID, let toID = w.transition.toClipID,
                  let from = clips[fromID], let to = clips[toID] else { continue }
            tails[fromID] = w.window.end - from.end
            heads[toID] = to.start - w.window.start
        }
        return (heads, tails)
    }

    /// Two clips that continue the same media without a jump, so the cut
    /// between them is inaudible and needs no micro-fade.
    static func isSeamless(_ a: Clip, _ b: Clip) -> Bool {
        guard a.end == b.start, let media = a.mediaID, media == b.mediaID,
              a.speed == b.speed, !a.freezeFrame, !b.freezeFrame,
              abs((a.sourceEnd - b.sourceStart).flicks) <= Time.flicksPerSample48k else { return false }
        let x = a.audio ?? AudioProperties()
        let y = b.audio ?? AudioProperties()
        return x.gainDB == y.gainDB && x.normalizeTo == y.normalizeTo && x.voiceIsolation == y.voiceIsolation
            && x.fadeOut == .zero && y.fadeIn == .zero
            && a.keyframes["audio.gainDB"] == nil && b.keyframes["audio.gainDB"] == nil
    }

    /// Interval partitioning: each segment goes on the first composition
    /// track that's free when it starts. Clips joined by a transition
    /// overlap, so they land on different tracks (the classic A/B roll).
    /// Returns the number of tracks used.
    static func assignTracks(_ segments: inout [PlannedSegment]) -> Int {
        let order = segments.indices.sorted {
            segments[$0].timeline.start == segments[$1].timeline.start ? $0 < $1 : segments[$0].timeline.start < segments[$1].timeline.start
        }
        var ends: [Time] = []
        for i in order {
            let range = segments[i].timeline
            if let free = ends.firstIndex(where: { $0 <= range.start }) {
                segments[i].track = free
                ends[free] = range.end
            } else {
                segments[i].track = ends.count
                ends.append(range.end)
            }
        }
        return ends.count
    }

    /// The stack nodes one track contributes at `time`: its visible clips,
    /// folded into transition nodes for every transition playing then.
    static func nodes(
        at time: Time,
        clips: [PlannedClip],
        windows: [TransitionRef],
        tracksOfClip: [String: (picture: Int?, matte: Int?)]
    ) -> [StackNode] {
        var groups: [(node: StackNode, clips: Set<String>)] = clips
            .filter { $0.visible.contains(time) }
            .map { planned in
                let tracks = tracksOfClip[planned.clip.id]
                let ref = LayerRef(
                    clipID: planned.clip.id, trackIndex: planned.trackIndex,
                    pictureTrack: tracks?.picture ?? nil, matteTrack: tracks?.matte ?? nil
                )
                return (StackNode.layer(ref), [planned.clip.id])
            }
        for w in windows where w.window.contains(time) {
            let fromIndex = w.transition.fromClipID.flatMap { id in groups.firstIndex { $0.clips.contains(id) } }
            let toIndex = w.transition.toClipID.flatMap { id in groups.firstIndex { $0.clips.contains(id) } }
            if fromIndex == nil && toIndex == nil { continue }
            if let fromIndex, let toIndex, fromIndex == toIndex { continue }
            let node = StackNode.transition(w, from: fromIndex.map { groups[$0].node }, to: toIndex.map { groups[$0].node })
            let indices = [fromIndex, toIndex].compactMap { $0 }
            let members = indices.reduce(into: Set<String>()) { $0.formUnion(groups[$1].clips) }
            let insertAt = indices.min() ?? 0
            for i in indices.sorted(by: >) { groups.remove(at: i) }
            groups.insert((node, members), at: insertAt)
        }
        return groups.map(\.node)
    }

    /// Collects warnings without repeating any.
    struct Warnings {
        private(set) var list: [String] = []
        private var seen = Set<String>()

        mutating func add(_ message: String) {
            if seen.insert(message).inserted { list.append(message) }
        }
    }
}

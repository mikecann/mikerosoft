import Foundation
import TandemCore

/// Everything about a video besides its segment list: which files make up
/// the take, how the layouts look, and the pipeline steps that ran after
/// the EDL (an intro, loosened cuts, transitions, graphics, music and sound
/// effects).
///
/// Times in a recipe are take times, like the EDL's, so they stay attached
/// to the same words when the cut changes. `EDLImporter` turns them into
/// timeline times for the cut it builds.
///
/// `EDLRecipe.decisionModels` is the recipe for the September 2026 video,
/// read out of the Python scripts that built its Filmora projects.
public struct EDLRecipe: Codable, Equatable, Sendable {
    public var name: String
    /// Folder that relative paths resolve against. `~` is expanded.
    public var root: String?
    /// The EDL to use when none is given, relative to `root`.
    public var edl: String?
    public var width: Int?
    public var height: Int?
    /// Frames per second, for example 30.
    public var frameRate: Double?
    /// The recording sessions, in order. A take covers EDL time from its
    /// `start` until the next take's.
    public var takes: [Take]
    public var voice: Voice?
    /// Where the camera goes in the `screen` layout.
    public var pip: PiP?
    /// The camera grade, stored on the camera media so every clip gets it.
    public var cameraLook: [Effect]?
    public var intro: Intro?
    /// Segment edges moved after the EDL was made, for example by the pass
    /// that stopped cuts clipping words. Matched on the segment's EDL times.
    public var cutAdjustments: [CutAdjustment]?
    /// Layouts changed after the EDL was made, by take time of the segment
    /// start.
    public var layoutOverrides: [LayoutOverride]?
    public var transitions: Transitions?
    /// Graphics and B-roll laid over the cut.
    public var inserts: [Insert]?
    /// Named sections: section markers, and one music cue each.
    public var sections: [Section]?
    public var music: Music?
    public var sfx: SoundEffects?
    /// Where the numbers came from, for people reading the recipe.
    public var notes: [String]?

    public struct Take: Codable, Equatable, Sendable {
        /// EDL time the take starts at.
        public var start: Double
        public var camera: String
        /// The screen recording of the same session. It starts with the
        /// camera, so the two share take time.
        public var screen: String?

        public init(start: Double, camera: String, screen: String? = nil) {
            self.start = start
            self.camera = camera
            self.screen = screen
        }
    }

    public struct Voice: Codable, Equatable, Sendable {
        /// Loudness the camera sound is levelled to, in LUFS.
        public var normalizeTo: Double?
        public var gainDB: Double?

        public init(normalizeTo: Double? = nil, gainDB: Double? = nil) {
            self.normalizeTo = normalizeTo
            self.gainDB = gainDB
        }
    }

    public struct PiP: Codable, Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var scale: Double
        /// Cut Mike out of his background, the 2026 look.
        public var cutout: Bool?

        public init(x: Double, y: Double, scale: Double, cutout: Bool? = true) {
            self.x = x
            self.y = y
            self.scale = scale
            self.cutout = cutout
        }
    }

    /// A pre-rendered opening that replaces the start of the EDL.
    public struct Intro: Codable, Equatable, Sendable {
        public var path: String
        /// EDL segments that start before this take time are dropped.
        public var replacesBefore: Double
        public var normalizeTo: Double?
        public var gainDB: Double?

        public init(path: String, replacesBefore: Double, normalizeTo: Double? = nil, gainDB: Double? = nil) {
            self.path = path
            self.replacesBefore = replacesBefore
            self.normalizeTo = normalizeTo
            self.gainDB = gainDB
        }
    }

    public struct CutAdjustment: Codable, Equatable, Sendable {
        /// The segment as the EDL has it.
        public var start: Double
        public var end: Double
        /// Where its edges ended up.
        public var newStart: Double
        public var newEnd: Double

        public init(start: Double, end: Double, newStart: Double, newEnd: Double) {
            self.start = start
            self.end = end
            self.newStart = newStart
            self.newEnd = newEnd
        }
    }

    public struct LayoutOverride: Codable, Equatable, Sendable {
        public var from: Double
        public var to: Double
        public var layout: SegmentEDL.Layout

        public init(from: Double, to: Double, layout: SegmentEDL.Layout) {
            self.from = from
            self.to = to
            self.layout = layout
        }
    }

    public struct TransitionSpec: Codable, Equatable, Sendable {
        public var type: TransitionType
        public var direction: Direction?
        public var duration: Double

        public init(type: TransitionType, direction: Direction? = nil, duration: Double) {
            self.type = type
            self.direction = direction
            self.duration = duration
        }
    }

    /// A push at the start of a new topic while the screen stays up.
    public struct TopicPush: Codable, Equatable, Sendable {
        public var type: TransitionType
        public var direction: Direction?
        public var duration: Double
        /// Take times of the voice where each new topic starts.
        public var at: [Double]
        /// How close the cut has to be to one of `at`, in seconds.
        public var tolerance: Double?

        public init(type: TransitionType, direction: Direction? = nil, duration: Double, at: [Double], tolerance: Double? = nil) {
            self.type = type
            self.direction = direction
            self.duration = duration
            self.at = at
            self.tolerance = tolerance
        }

        var spec: TransitionSpec { TransitionSpec(type: type, direction: direction, duration: duration) }
    }

    public struct Transitions: Codable, Equatable, Sendable {
        /// Between a camera segment and a screen segment.
        public var layoutSwitch: TransitionSpec?
        public var topicPush: TopicPush?
        /// At the end of the video.
        public var end: TransitionSpec?
        /// Graphics and B-roll coming in and going out.
        public var overlayIn: TransitionSpec?
        public var overlayOut: TransitionSpec?

        public init(
            layoutSwitch: TransitionSpec? = nil,
            topicPush: TopicPush? = nil,
            end: TransitionSpec? = nil,
            overlayIn: TransitionSpec? = nil,
            overlayOut: TransitionSpec? = nil
        ) {
            self.layoutSwitch = layoutSwitch
            self.topicPush = topicPush
            self.end = end
            self.overlayIn = overlayIn
            self.overlayOut = overlayOut
        }
    }

    public struct Insert: Codable, Equatable, Sendable {
        public var path: String
        /// Take time it starts at. Leave it out and set `afterPrevious` to
        /// butt it against the insert before.
        public var at: Double?
        public var afterPrevious: Bool?
        /// Timeline seconds, capped at what the file has.
        public var duration: Double
        public var sourceStart: Double?
        public var slideIn: Bool?
        public var slideOut: Bool?
        public var note: String?

        public init(
            path: String,
            at: Double? = nil,
            afterPrevious: Bool? = nil,
            duration: Double,
            sourceStart: Double? = nil,
            slideIn: Bool? = nil,
            slideOut: Bool? = nil,
            note: String? = nil
        ) {
            self.path = path
            self.at = at
            self.afterPrevious = afterPrevious
            self.duration = duration
            self.sourceStart = sourceStart
            self.slideIn = slideIn
            self.slideOut = slideOut
            self.note = note
        }
    }

    public struct Section: Codable, Equatable, Sendable {
        public var name: String
        /// Take time of the cut the section starts at. Nil for the first
        /// section (the start of the timeline) and for the outro.
        public var at: Double?
        /// The music cue for the section.
        public var music: String?
        /// The closing section: its cue is placed to end with the video.
        public var outro: Bool?

        public init(name: String, at: Double? = nil, music: String? = nil, outro: Bool? = nil) {
            self.name = name
            self.at = at
            self.music = music
            self.outro = outro
        }
    }

    public struct Music: Codable, Equatable, Sendable {
        /// Seconds each cue overlaps the next, centred on the section cut.
        public var crossfade: Double
        /// Loudness each cue is levelled to before `gainDB`, in LUFS.
        public var normalizeTo: Double?
        public var gainDB: Double?
        /// Fade on the last cue.
        public var endFadeOut: Double?
        /// Seconds of the outro cue's tail that run past the video's end.
        public var outroTrim: Double?

        public init(crossfade: Double, normalizeTo: Double? = nil, gainDB: Double? = nil, endFadeOut: Double? = nil, outroTrim: Double? = nil) {
            self.crossfade = crossfade
            self.normalizeTo = normalizeTo
            self.gainDB = gainDB
            self.endFadeOut = endFadeOut
            self.outroTrim = outroTrim
        }
    }

    public struct SoundEffects: Codable, Equatable, Sendable {
        /// Transition sounds closer than this keep only the higher
        /// priority, then the earlier, one.
        public var minGap: Double?
        public var onTransitions: [TransitionSound]?
        public var events: [SoundEvent]?

        public init(minGap: Double? = nil, onTransitions: [TransitionSound]? = nil, events: [SoundEvent]? = nil) {
            self.minGap = minGap
            self.onTransitions = onTransitions
            self.events = events
        }
    }

    public enum TransitionRole: String, Codable, Sendable {
        case layoutSwitch, topicPush, overlayIn, overlayOut, end
    }

    /// A sound placed so its loudest point lands mid-transition.
    public struct TransitionSound: Codable, Equatable, Sendable {
        public var on: TransitionRole
        public var path: String
        /// Seconds from the start of the file to its loudest point.
        public var peak: Double
        public var gainDB: Double
        public var priority: Int?

        public init(on: TransitionRole, path: String, peak: Double, gainDB: Double, priority: Int? = nil) {
            self.on = on
            self.path = path
            self.peak = peak
            self.gainDB = gainDB
            self.priority = priority
        }
    }

    /// A sound that starts at a take time.
    public struct SoundEvent: Codable, Equatable, Sendable {
        public var path: String
        public var at: Double
        public var gainDB: Double?
        public var note: String?

        public init(path: String, at: Double, gainDB: Double? = nil, note: String? = nil) {
            self.path = path
            self.at = at
            self.gainDB = gainDB
            self.note = note
        }
    }

    public init(name: String, root: String? = nil, edl: String? = nil, takes: [Take]) {
        self.name = name
        self.root = root
        self.edl = edl
        self.takes = takes
    }

    public static func load(from url: URL) throws -> EDLRecipe {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ImportError.unreadable(url.path)
        }
        return try decode(data, name: url.lastPathComponent)
    }

    static func decode(_ data: Data, name: String) throws -> EDLRecipe {
        var recipe: EDLRecipe
        do {
            recipe = try JSONDecoder().decode(EDLRecipe.self, from: data)
        } catch {
            throw ImportError.invalid("\(name) isn't an EDL recipe: \(error)")
        }
        // Recipes leave effect IDs out; give them stable ones so the same
        // recipe always builds the same project.
        if let look = recipe.cameraLook {
            recipe.cameraLook = look.enumerated().map { index, effect in
                var effect = effect
                effect.id = ImportIDs.make("fx", key: "look:\(index):\(effect.type)")
                return effect
            }
        }
        return recipe
    }

    /// The folder relative paths resolve against.
    public var rootURL: URL? {
        root.map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath, isDirectory: true) }
    }

    /// A recipe path made absolute.
    public func resolve(_ path: String) -> String {
        let expanded = NSString(string: path).expandingTildeInPath
        if expanded.hasPrefix("/") { return expanded }
        guard let rootURL else { return expanded }
        return rootURL.appendingPathComponent(expanded).path
    }
}

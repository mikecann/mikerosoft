import Foundation
import TandemCore
import TandemMedia

/// The timeline as text an agent (or a person) can read in one go: tracks
/// top to bottom as the app shows them, one line per clip with its ID, time
/// range, what it plays and anything set away from the defaults.
///
///     V2 Camera  trk_2kd8  cut
///       clip_k3f9x2mq  00:00.000-00:10.000  10.000s  take1-camera.mov [00:00.000-00:10.000]  linked #1  scale 0.5 at 0.87,0.77  cutout  fx dropShadow
///         ~ dissolve 0.500s into clip_p8d2m4xa  tr_9ffq2xa3
///
/// Times are `mm:ss.mmm` on the timeline; square brackets hold the range of
/// the file the clip plays. `linked #n` groups clips that move and cut
/// together.
public enum TimelineDump {
    public struct Options {
        /// Only show clips overlapping `from..<to` (and markers inside it).
        public var from: Time?
        public var to: Time?
        /// When set, speech clips get the words they play underneath.
        public var transcripts: ((MediaItem) -> Transcript?)?
        /// Wrap width for words.
        public var width: Int

        public init(from: Time? = nil, to: Time? = nil, transcripts: ((MediaItem) -> Transcript?)? = nil, width: Int = 100) {
            self.from = from
            self.to = to
            self.transcripts = transcripts
            self.width = width
        }
    }

    /// One line per track (clips, the span they cover, gaps in the take)
    /// and the markers: enough to find your way round a long edit before
    /// reading part of it in full.
    public static func summary(_ project: Project, revision: Int? = nil) -> String {
        var out: [String] = []
        let settings = project.settings
        var header = "\(project.name): \(project.duration) long, \(settings.width)x\(settings.height) at \(CommandText.number(settings.frameRate.framesPerSecond)) fps"
        if let revision { header += ", revision \(revision)" }
        out.append(header)
        let clipCount = project.allTracks.reduce(0) { $0 + $1.clips.count }
        out.append("\(project.allTracks.count) tracks, \(clipCount) clips, \(project.media.count) media files. Read part of it in full with from and to.")
        if !project.markers.isEmpty {
            out.append("")
            out.append("Markers")
            for marker in project.markers {
                out.append("  \(marker.time)  \(marker.kind.rawValue)  \"\(marker.name)\"  \(marker.id)")
            }
        }
        out.append("")
        out.append("Tracks, top to bottom")
        var rows: [(String, Track)] = []
        for (index, track) in project.videoTracks.enumerated().reversed() { rows.append(("V\(index + 1)", track)) }
        for (index, track) in project.audioTracks.enumerated() { rows.append(("A\(index + 1)", track)) }
        // A small table: the fixed columns are padded so the rest lines up.
        var table: [[String]] = []
        for (label, track) in rows {
            var row = ["\(label) \(track.name)", track.id, track.rippleMode.rawValue]
            if track.clips.isEmpty {
                row += ["empty", "", ""]
            } else {
                let covered = TimeRange.union(track.clips.map(\.range))
                let total = covered.reduce(Time.zero) { $0 + $1.duration }
                row.append(track.clips.count == 1 ? "1 clip" : "\(track.clips.count) clips")
                row.append("\(track.clips[0].start)-\(track.end)")
                row.append("\(TimeText.duration(total)) of content")
                if track.rippleMode == .cut && covered.count > 1 {
                    row.append(covered.count == 2 ? "1 gap" : "\(covered.count - 1) gaps")
                }
                if !track.transitions.isEmpty { row.append(track.transitions.count == 1 ? "1 transition" : "\(track.transitions.count) transitions") }
            }
            if track.locked { row.append("locked") }
            if track.hidden { row.append("hidden") }
            if track.muted { row.append("muted") }
            table.append(row)
        }
        let padded = 6
        let widths = (0..<padded).map { column in table.map { $0.count > column ? $0[column].count : 0 }.max() ?? 0 }
        for row in table {
            var cells: [String] = []
            for (column, cell) in row.enumerated() {
                cells.append(column < padded - 1 ? cell.padding(toLength: widths[column], withPad: " ", startingAt: 0) : cell)
            }
            out.append(("  " + cells.joined(separator: "  ")).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression))
        }
        return out.joined(separator: "\n") + "\n"
    }

    public static func render(_ project: Project, revision: Int? = nil, options: Options = Options()) -> String {
        var out: [String] = []
        let settings = project.settings
        var header = "\(project.name): \(project.duration) long, \(settings.width)x\(settings.height) at \(CommandText.number(settings.frameRate.framesPerSecond)) fps"
        if let revision { header += ", revision \(revision)" }
        out.append(header)
        let range = options.from != nil || options.to != nil
        if range {
            let from = options.from ?? .zero
            let to = options.to.map(\.description) ?? "the end"
            out.append("Showing \(from) to \(to): clips that overlap it, at their full length.")
        }
        out.append("Tracks top to bottom as the app shows them. cut tracks hold the take and ripple edits cut them together; follow tracks move with them; off tracks stay put.")
        out.append("Clips: ID, start-end on the timeline, length, content [source in-out of the file], then settings that aren't the defaults.")

        func overlaps(_ start: Time, _ end: Time) -> Bool {
            if let from = options.from, end <= from { return false }
            if let to = options.to, start >= to { return false }
            return true
        }

        // Markers
        let markers = project.markers.filter { overlaps($0.time, $0.time + max($0.duration, Time(flicks: 1))) }
        if !markers.isEmpty {
            out.append("")
            out.append("Markers")
            for marker in markers {
                var line = "  \(marker.time)"
                if marker.duration > .zero { line += "-\(marker.time + marker.duration)" }
                line += "  \(marker.kind.rawValue)  \"\(marker.name)\""
                if let note = marker.note, !note.isEmpty { line += " (\(note))" }
                line += "  \(marker.id)"
                out.append(line)
            }
        }

        // Tracks in the order the app shows them: video top to bottom (the
        // highest track first), then audio.
        var shown: [(label: String, track: Track, clips: [Clip])] = []
        for (index, track) in project.videoTracks.enumerated().reversed() {
            shown.append(("V\(index + 1)", track, track.clips.filter { overlaps($0.start, $0.end) }))
        }
        for (index, track) in project.audioTracks.enumerated() {
            shown.append(("A\(index + 1)", track, track.clips.filter { overlaps($0.start, $0.end) }))
        }

        // Number link groups in timeline order so "linked #1" is the first take.
        var linkNumbers: [String: Int] = [:]
        let ordered = shown.enumerated().flatMap { order, entry in entry.clips.map { (clip: $0, order: order) } }
            .sorted { ($0.clip.start, $0.order) < ($1.clip.start, $1.order) }
        for entry in ordered {
            if let group = entry.clip.linkGroup, linkNumbers[group] == nil { linkNumbers[group] = linkNumbers.count + 1 }
        }

        let idWidth = shown.flatMap(\.clips).map(\.id.count).max() ?? 13
        let lengthWidth = shown.flatMap(\.clips).map { TimeText.duration($0.duration).count }.max() ?? 7
        let names = mediaNames(project)
        let speechTrackIDs = Set(TranscriptTools.speechTracks(project).map(\.id))
        var usedMedia: [String] = []
        var untranscribed: [String] = []

        for (label, track, clips) in shown {
            out.append("")
            var flags = [track.rippleMode.rawValue]
            if track.locked { flags.append("locked") }
            if track.hidden { flags.append("hidden") }
            if track.muted { flags.append("muted") }
            if track.solo { flags.append("solo") }
            if !track.targeted { flags.append("untargeted") }
            // Settings most of the track's clips share are said once, in
            // the header, and each clip lists only what's different.
            let settings = clips.map { clipSettings($0, links: linkNumbers, names: names) }
            let usual = usualSettings(settings)
            var header = "\(label) \(track.name)  \(track.id)  \(flags.joined(separator: " "))"
            if !usual.isEmpty { header += "  (most clips: \(usual.joined(separator: ", ")))" }
            out.append(header)
            if clips.isEmpty {
                out.append(range ? "  (nothing here in this range)" : "  (empty)")
                continue
            }
            let heads = Dictionary(track.transitions.filter { $0.fromClipID == nil }.compactMap { t in t.toClipID.map { ($0, t) } }, uniquingKeysWith: { a, _ in a })
            let tails = Dictionary(track.transitions.compactMap { t in t.fromClipID.map { ($0, t) } }, uniquingKeysWith: { a, _ in a })
            var previousEnd: Time? = range ? nil : .zero
            // The words each clip plays, placed among all of the track's
            // clips at once, so a word a cut runs through shows on one side.
            var spoken: [String: [TranscriptTools.SpokenWord]] = [:]
            var transcribed = Set<String>()
            if let transcripts = options.transcripts, speechTrackIDs.contains(track.id) {
                var byMedia: [String: [Clip]] = [:]
                for clip in track.clips where TranscriptTools.isHeard(clip) || clips.contains(where: { $0.id == clip.id }) {
                    if let mediaID = clip.mediaID { byMedia[mediaID, default: []].append(clip) }
                }
                for (mediaID, group) in byMedia {
                    guard let item = project.media(mediaID), item.hasAudio, let transcript = transcripts(item) else { continue }
                    transcribed.insert(mediaID)
                    for word in TranscriptTools.words(transcript, playedBy: group, mediaID: mediaID) {
                        spoken[word.clipID, default: []].append(word)
                    }
                }
            }
            for (clip, own) in zip(clips, settings) {
                if track.rippleMode == .cut, let previousEnd, clip.start > previousEnd {
                    out.append("    gap \(previousEnd)-\(clip.start) (\(TimeText.duration(clip.start - previousEnd)))")
                }
                if let transition = heads[clip.id] {
                    out.append("    ~ \(transition.type.rawValue)\(direction(transition)) \(TimeText.duration(transition.duration)) in  \(transition.id)")
                }
                let id = clip.id.padding(toLength: idWidth, withPad: " ", startingAt: 0)
                let length = String(repeating: " ", count: max(0, lengthWidth - TimeText.duration(clip.duration).count)) + TimeText.duration(clip.duration)
                var parts = ["  \(id)", "\(clip.start)-\(clip.end)", length, content(clip, project: project, names: names)]
                parts += own.filter { !usual.contains($0) }
                // A usual setting the clip doesn't have is only worth saying
                // when nothing of its kind replaces it ("gain 3.9 dB" already
                // says it isn't the usual gain).
                let kinds = Set(own.map(settingKind))
                let missing = usual.filter { !own.contains($0) && !kinds.contains(settingKind($0)) }
                if !missing.isEmpty { parts.append("not: " + missing.joined(separator: ", ")) }
                out.append(parts.joined(separator: "  "))
                if let mediaID = clip.mediaID, !usedMedia.contains(mediaID) { usedMedia.append(mediaID) }
                if let transition = tails[clip.id] {
                    let target = transition.toClipID.map { " into \($0)" } ?? " out"
                    out.append("    ~ \(transition.type.rawValue)\(direction(transition)) \(TimeText.duration(transition.duration))\(target)  \(transition.id)")
                }
                if options.transcripts != nil, speechTrackIDs.contains(track.id),
                   let mediaID = clip.mediaID, let item = project.media(mediaID), item.hasAudio {
                    if transcribed.contains(mediaID) {
                        // With a range, only the words inside it, marked where they're cut short.
                        let all = spoken[clip.id] ?? []
                        let shown = all.filter { overlaps($0.start, $0.end) }
                        var words = shown.map(\.text).joined(separator: " ")
                        if !words.isEmpty {
                            if shown.first != all.first { words = "..." + words }
                            if shown.last != all.last { words += "..." }
                        }
                        out += wrap(words.isEmpty ? "(no words)" : "\"\(words)\"", width: options.width, indent: "      ")
                    } else if !untranscribed.contains(item.id) {
                        untranscribed.append(item.id)
                    }
                }
                previousEnd = clip.end
            }
        }

        if !untranscribed.isEmpty {
            // Said once, after the header, rather than under every clip.
            let note = "No transcript yet for \(untranscribed.joined(separator: ", ")), so its clips show no words."
            out.insert(note, at: range ? 4 : 3)
        }

        if !usedMedia.isEmpty {
            out.append("")
            out.append("Media")
            let mediaWidth = usedMedia.map(\.count).max() ?? 0
            for id in usedMedia {
                guard let item = project.media(id) else {
                    out.append("  \(id)  (missing from the project)")
                    continue
                }
                var parts = ["  \(id.padding(toLength: mediaWidth, withPad: " ", startingAt: 0))", item.path, item.role.rawValue]
                if let duration = item.duration { parts.append(duration.description) }
                if let w = item.width, let h = item.height {
                    var picture = "\(w)x\(h)"
                    if let rate = item.frameRate { picture += " \(CommandText.number((rate.framesPerSecond * 100).rounded() / 100))fps" }
                    parts.append(picture)
                }
                if let take = item.takeID { parts.append("take \(take) +\(TimeText.duration(item.takeOffset ?? .zero))") }
                out.append(parts.joined(separator: "  "))
            }
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// Settings shared by at least 60% of a track's clips (four or more),
    /// in the order they first appear. Link groups and names belong to one
    /// clip, so they never count.
    static func usualSettings(_ settings: [[String]]) -> [String] {
        guard settings.count >= 4 else { return [] }
        var counts: [String: Int] = [:]
        var order: [String] = []
        for list in settings {
            for setting in Set(list) where !setting.hasPrefix("linked #") && !setting.hasPrefix("named ") {
                if counts[setting] == nil { order.append(setting) }
                counts[setting, default: 0] += 1
            }
        }
        let needed = Int((Double(settings.count) * 0.6).rounded(.up))
        let usual = Set(order.filter { counts[$0, default: 0] >= needed })
        // Keep the order settings have on a clip line.
        var ordered: [String] = []
        for list in settings {
            for setting in list where usual.contains(setting) && !ordered.contains(setting) { ordered.append(setting) }
        }
        return ordered
    }

    /// What a setting is about: its first word ("gain", "scale", "layout").
    static func settingKind(_ setting: String) -> String {
        String(setting.prefix { $0 != " " })
    }

    /// Short names for media: the file name, or the path when two files
    /// share a name.
    static func mediaNames(_ project: Project) -> [String: String] {
        let base = Dictionary(project.media.map { ($0.id, ($0.path as NSString).lastPathComponent) }, uniquingKeysWith: { a, _ in a })
        var counts: [String: Int] = [:]
        for name in base.values { counts[name, default: 0] += 1 }
        var names: [String: String] = [:]
        for item in project.media {
            let name = base[item.id] ?? item.path
            names[item.id] = (counts[name] ?? 0) > 1 ? item.path : name
        }
        return names
    }

    static func content(_ clip: Clip, project: Project, names: [String: String]) -> String {
        switch clip.content {
        case .media(let mediaID):
            let name = names[mediaID] ?? "\(mediaID) (missing)"
            if project.media(mediaID)?.kind == .image { return name }
            if clip.freezeFrame { return "\(name) frozen at \(clip.sourceStart)" }
            return "\(name) [\(clip.sourceStart)-\(clip.sourceEnd)]"
        case .text(let text):
            var result = "text \"\(shorten(text.text.replacingOccurrences(of: "\n", with: " / "), 48))\""
            if let preset = text.preset { result += " \(preset)" }
            return result
        case .graphic(let graphic):
            guard graphic.template == SectionCard.template else { return "graphic \(graphic.template)" }
            // Like: section card 01 "Methodology" / "Let's keep it fair" 1 of 3
            let card = SectionCard.Props(graphic.props)
            var result = "section card"
            if !card.number.isEmpty { result += " \(card.number)" }
            result += " \"\(shorten(card.title.replacingOccurrences(of: "\n", with: " "), 40))\""
            if !card.subtitle.isEmpty { result += " / \"\(shorten(card.subtitle, 32))\"" }
            if let index = card.index, card.total > 0 { result += " \(index) of \(card.total)" }
            if !card.kicker.isEmpty { result += " kicker \(card.kicker)" }
            return result
        case .solid(let color):
            return "solid \(hex(color))"
        case .adjustment:
            return "adjustment"
        }
    }

    static func clipSettings(_ clip: Clip, links: [String: Int], names: [String: String] = [:]) -> [String] {
        var parts: [String] = []
        if let name = clip.name, !name.isEmpty {
            // Clips placed from a file are named after it; only show names someone chose.
            let fileName = clip.mediaID.flatMap { names[$0] }.map { ($0 as NSString).deletingPathExtension }
            if name != fileName { parts.append("named \"\(name)\"") }
        }
        if let group = clip.linkGroup, let number = links[group] { parts.append("linked #\(number)") }
        if !clip.enabled { parts.append("disabled") }
        if clip.speed != 1 { parts.append("speed \(CommandText.number(clip.speed))x") }
        if let video = clip.video {
            if let preset = video.layoutPreset { parts.append("layout \(preset)") }
            let t = video.transform
            let defaultPosition = t.position == Point(x: 0.5, y: 0.5)
            if t.scale != 1 || !defaultPosition {
                var place = "scale \(num(t.scale))"
                if !defaultPosition { place += " at \(num(t.position.x)),\(num(t.position.y))" }
                parts.append(place)
            }
            if t.rotation != 0 { parts.append("rotated \(num(t.rotation))") }
            if !video.crop.isIdentity {
                let c = video.crop
                let edges = [("l", c.left), ("t", c.top), ("r", c.right), ("b", c.bottom)].filter { $0.1 != 0 }
                parts.append("crop " + edges.map { "\($0.0)\(num($0.1))" }.joined(separator: " "))
            }
            if video.opacity != 1 { parts.append("opacity \(num(video.opacity))") }
            if let cutout = video.cutout, cutout.enabled { parts.append(cutout.mode == .person ? "cutout person" : "cutout") }
            if !video.effects.isEmpty { parts.append("fx " + video.effects.map(effectName).joined(separator: ",")) }
            if !video.formatOverrides.isEmpty { parts.append("formats " + video.formatOverrides.keys.sorted().joined(separator: ",")) }
        }
        if let audio = clip.audio {
            if audio.muted { parts.append("muted") }
            if audio.gainDB != 0 { parts.append("gain \(decibels(audio.gainDB)) dB") }
            if let target = audio.normalizeTo { parts.append("level \(decibels(target)) LUFS") }
            if audio.fadeIn > .zero { parts.append("fade in \(TimeText.duration(audio.fadeIn))") }
            if audio.fadeOut > .zero { parts.append("fade out \(TimeText.duration(audio.fadeOut))") }
            if audio.voiceIsolation > 0 { parts.append("isolate voice \(num(audio.voiceIsolation))") }
            if !audio.effects.isEmpty { parts.append("fx " + audio.effects.map(effectName).joined(separator: ",")) }
        }
        if case .text(let text) = clip.content {
            if let animation = text.animationIn { parts.append("in \(animation)") }
            if let animation = text.animationOut { parts.append("out \(animation)") }
            // What the clip sets over its preset, as the JSON names it, so
            // an agent can see (and patch) exactly what wins.
            if !text.style.isEmpty { parts.append("style " + styleFields(text.style)) }
        }
        if !clip.keyframes.isEmpty {
            let names = clip.keyframes.keys.sorted().map { key -> String in
                key.replacingOccurrences(of: "video.transform.", with: "")
                    .replacingOccurrences(of: "video.", with: "")
                    .replacingOccurrences(of: "audio.", with: "")
            }
            parts.append("animates " + names.joined(separator: ","))
        }
        if !clip.tags.isEmpty { parts.append(clip.tags.map { "#\($0)" }.joined(separator: " ")) }
        return parts
    }

    static func effectName(_ effect: Effect) -> String {
        effect.enabled ? effect.type : "\(effect.type)(off)"
    }

    static func direction(_ transition: Transition) -> String {
        transition.direction.map { " \($0.rawValue)" } ?? ""
    }

    /// Levels to a tenth of a dB, which is all anyone hears.
    static func decibels(_ value: Double) -> String {
        CommandText.number((value * 10).rounded() / 10)
    }

    static func num(_ value: Double) -> String {
        let rounded = (value * 1000).rounded() / 1000
        return CommandText.number(rounded)
    }

    /// `font=TiltWarp-Regular size=84 shadow=false`: only the fields set.
    static func styleFields(_ style: TextStyle) -> String {
        var fields: [String] = []
        if let font = style.font { fields.append("font=\(font)") }
        if let size = style.size { fields.append("size=\(num(size))") }
        if let weight = style.weight { fields.append("weight=\(num(weight))") }
        if let color = style.color { fields.append("color=\(hex(color))") }
        if let color = style.strokeColor { fields.append("strokeColor=\(hex(color))") }
        if let width = style.strokeWidth { fields.append("strokeWidth=\(num(width))") }
        if let color = style.backgroundColor { fields.append("backgroundColor=\(color.a <= 0 ? "none" : hex(color))") }
        if let alignment = style.alignment { fields.append("alignment=\(alignment)") }
        if let uppercase = style.uppercase { fields.append("uppercase=\(uppercase)") }
        if let shadow = style.shadow { fields.append("shadow=\(shadow)") }
        if let spacing = style.lineSpacing { fields.append("lineSpacing=\(num(spacing))") }
        return fields.joined(separator: " ")
    }

    static func hex(_ color: RGBA) -> String {
        func byte(_ v: Double) -> String { String(format: "%02X", Int((min(max(v, 0), 1) * 255).rounded())) }
        var text = "#" + byte(color.r) + byte(color.g) + byte(color.b)
        if color.a < 1 { text += " at \(num(color.a))" }
        return text
    }

    static func shorten(_ text: String, _ limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 3)) + "..."
    }

    static func wrap(_ text: String, width: Int, indent: String) -> [String] {
        var lines: [String] = []
        var line = ""
        for word in text.split(separator: " ", omittingEmptySubsequences: true) {
            if !line.isEmpty && indent.count + line.count + 1 + word.count > width {
                lines.append(indent + line)
                line = ""
            }
            line += line.isEmpty ? String(word) : " " + word
        }
        if !line.isEmpty { lines.append(indent + line) }
        return lines
    }

    /// The project with each track holding only the clips that overlap
    /// `from..<to`, with their transitions, and the markers inside it.
    public static func filtered(_ project: Project, from: Time?, to: Time?) -> Project {
        guard from != nil || to != nil else { return project }
        func overlaps(_ start: Time, _ end: Time) -> Bool {
            if let from, end <= from { return false }
            if let to, start >= to { return false }
            return true
        }
        var result = project
        for location in result.trackLocations {
            var track = result[location]
            track.clips = track.clips.filter { overlaps($0.start, $0.end) }
            let kept = Set(track.clips.map(\.id))
            track.transitions = track.transitions.filter { t in
                [t.fromClipID, t.toClipID].compactMap { $0 }.allSatisfy(kept.contains)
            }
            result[location] = track
        }
        result.markers = result.markers.filter { overlaps($0.time, $0.time + max($0.duration, Time(flicks: 1))) }
        return result
    }
}

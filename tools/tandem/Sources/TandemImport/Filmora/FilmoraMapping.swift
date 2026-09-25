import Foundation
import TandemCore

// How Filmora's settings map onto Tandem's. Each mapping says when it's
// exact and when it's a stand-in, so the importer can report the difference.

// MARK: - Transitions

enum FilmoraTransitions {
    struct Mapped: Equatable {
        var type: TransitionType
        var direction: Direction?
        /// False when Tandem has no real equivalent and plays something close.
        var exact: Bool
    }

    enum Placement { case head, tail, between }

    /// Maps a Filmora transition by its display name. Mike's six (Cut Slide
    /// Transition 03, Push Down/Up/Left, Dissolve and fade_black) map
    /// exactly; anything else becomes the nearest Tandem type.
    static func map(_ name: String, onAudio: Bool, placement: Placement) -> Mapped {
        let lower = name.lowercased()
        if onAudio {
            return Mapped(type: .dissolve, exact: lower.contains("audio fade") || lower.contains("constant gain") || lower.contains("crossfade"))
        }
        let direction = self.direction(in: lower)
        if lower.contains("cut slide") { return Mapped(type: .cutSlide, direction: direction, exact: true) }
        if lower.contains("fade_black") || lower.contains("fade to black") || lower.contains("dip to black") || lower == "fade black" {
            return Mapped(type: placement == .head ? .fadeFromBlack : .fadeToBlack, exact: true)
        }
        if lower.contains("push") {
            return Mapped(type: .push, direction: direction ?? .left, exact: direction != nil || lower == "push")
        }
        if lower.contains("dissolve") || lower == "fade" || lower.contains("cross fade") || lower.contains("crossfade") {
            return Mapped(type: .dissolve, exact: true)
        }
        if lower.contains("wipe") { return Mapped(type: .wipe, direction: direction ?? .left, exact: direction != nil) }
        if lower.contains("slid") { return Mapped(type: .slide, direction: direction ?? .left, exact: direction != nil) }
        if lower.contains("zoom") { return Mapped(type: .zoom, exact: false) }
        return Mapped(type: .dissolve, exact: false)
    }

    private static func direction(in name: String) -> Direction? {
        let words = name.replacingOccurrences(of: "_", with: " ").split(separator: " ").map(String.init)
        if words.contains("left") { return .left }
        if words.contains("right") { return .right }
        if words.contains("up") { return .up }
        if words.contains("down") { return .down }
        return nil
    }
}

// MARK: - Colour

enum FilmoraColour {
    static let adjustColorID = "662E16ED-4524-4D13-AAE9-11DBA0C63E17"

    private static let colours = ["Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple", "Magenta"]
    private static let basic: [String: String] = [
        "u_contrast": "contrast", "u_blackLevel": "blackLevel", "u_highlight": "highlights", "u_highlights": "highlights",
        "u_shadow": "shadows", "u_shadows": "shadows", "u_saturation": "saturation", "u_vibrance": "vibrance",
        "u_temperature": "temperature", "u_tint": "tint"
    ]

    struct Mapped {
        var effects: [Effect]
        /// Settings that were carried over only roughly.
        var approximated: [String]
        /// Settings with no Tandem equivalent.
        var unmapped: [String]
    }

    /// Tandem colour effects for Filmora's AdjustColor node. Zero values are
    /// Filmora's defaults and are left out, as are its internal switches.
    static func map(_ params: [String: JSONNode], idKey: String) -> Mapped {
        var colorAdjust: [String: ParamValue] = [:]
        var hsl: [String: ParamValue] = [:]
        var vignette: [String: ParamValue] = [:]
        var lut: [String: ParamValue] = [:]
        var approximated: [String] = []
        var unmapped: [String] = []
        for (key, node) in params.sorted(by: { $0.key < $1.key }) {
            if key.hasPrefix("bEnable") || key.hasSuffix("degreeMinVal") || key.hasSuffix("degreeMaxVal") || key.hasPrefix("autoColor") { continue }
            if key == "lut3dPath" {
                if let path = node.string, !path.isEmpty { lut["path"] = .string(path) }
                continue
            }
            guard let value = node.double, value != 0 else { continue }
            if let name = basic[key] {
                colorAdjust[name] = .number(value)
            } else if key == "u_exposure" || key == "u_brightness" {
                // Filmora's -100...100 against Tandem's stops.
                colorAdjust["exposure"] = .number((colorAdjust["exposure"]?.number ?? 0) + value / 50)
                approximated.append(key)
            } else if key == "amount" {
                vignette["amount"] = .number(value)
            } else if key == "size" || key == "feather" {
                vignette[key] = .number(value)
            } else if key == "alpha" {
                lut["intensity"] = .number(value > 1 ? value / 100 : value)
            } else if let (colour, property) = hslKey(key) {
                hsl["\(colour.lowercased())\(property)"] = .number(value)
            } else {
                unmapped.append(key)
            }
        }
        var effects: [Effect] = []
        if !colorAdjust.isEmpty { effects.append(Effect(id: ImportIDs.make("fx", key: "\(idKey):colorAdjust"), type: "colorAdjust", params: colorAdjust)) }
        if !hsl.isEmpty { effects.append(Effect(id: ImportIDs.make("fx", key: "\(idKey):hsl"), type: "hsl", params: hsl)) }
        if !vignette.isEmpty && vignette["amount"] != nil {
            effects.append(Effect(id: ImportIDs.make("fx", key: "\(idKey):vignette"), type: "vignette", params: vignette))
        }
        if lut["path"] != nil { effects.append(Effect(id: ImportIDs.make("fx", key: "\(idKey):lut"), type: "lut", params: lut)) }
        return Mapped(effects: effects, approximated: approximated, unmapped: unmapped)
    }

    private static func hslKey(_ key: String) -> (String, String)? {
        let parts = key.split(separator: "_", maxSplits: 1).map(String.init)
        guard parts.count == 2, colours.contains(parts[0]) else { return nil }
        switch parts[1] {
        case "satVal": return (parts[0], "Saturation")
        case "hueVal": return (parts[0], "Hue")
        case "brightnessVal", "lumVal", "lightVal", "luminanceVal": return (parts[0], "Luminance")
        default: return nil
        }
    }
}

// MARK: - Text

enum FilmoraText {
    struct Mapped {
        var content: TextContent
        var position: Point
        var rotation: Double
        var notes: [String]
    }

    /// A Tandem text layer from a Filmora title clip.
    static func map(_ clip: WfpClip) -> Mapped? {
        let script = clip.node["scriptBuf"].embedded
        guard script.exists else { return nil }
        let data = script["TextData"][0]
        var text = script["Text"].string ?? data["CharData"].string ?? ""
        text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var notes: [String] = []
        let basic = data["Basic"]
        var style = TextStyle()
        let font = basic["FontName"].string ?? style.font
        style.font = font
        style.weight = weight(font: font, bold: basic["FontBold"].bool ?? false)
        let alpha = (basic["TextAlpha"].double ?? 255) / 255
        style.color = color(basic["TextColor"][0]["Color"].int, alpha: alpha) ?? .white
        let border = data["Border"]
        if border["Enable"].bool == true, let width = border["Size"].double, width > 0 {
            style.strokeColor = color(border["Color"].int, alpha: (border["Alpha"].double ?? 255) / 255) ?? .black
            style.strokeWidth = width
        }
        style.shadow = data["Shadow"]["Enable"].bool ?? false
        let background = script["Background"]
        if background["Enable"].bool == true {
            style.backgroundColor = color(background["Color"].int, alpha: (background["Alpha"].double ?? 255) / 255)
        }
        let layout = script["Layout"]
        if let align = layout["TextAlign"].string?.lowercased(), ["left", "center", "right"].contains(align) {
            style.alignment = align
        }
        style.uppercase = data["CharCase"].int == 1
        // Filmora sizes text to fit its box, so the box height says more
        // about how big the words look than FontSize does.
        let lines = Double(max(1, text.split(separator: "\n", omittingEmptySubsequences: false).count))
        if let boxHeight = script["ScaleY"].double, boxHeight > 0 {
            style.size = (boxHeight * 1080 / lines / 1.2 * 0.85).rounded()
        } else if let size = basic["FontSize"].double {
            style.size = size
        }
        var content = TextContent(text: text, style: style)
        if let (name, duration) = animation(clip.node["inAnimation"]) {
            content.animationIn = animationName(name, entering: true)
            if content.animationIn == nil { notes.append("Title animation \"\(name)\" has no Tandem equivalent.") }
            if let duration { content.animationDuration = duration }
        }
        if let (name, duration) = animation(clip.node["outAnimation"]) {
            content.animationOut = animationName(name, entering: false)
            if content.animationOut == nil { notes.append("Title animation \"\(name)\" has no Tandem equivalent.") }
            if let duration, content.animationIn == nil { content.animationDuration = duration }
        }
        if script["Stt"].exists || clip.node["isSubtitleText"].bool == true {
            notes.append("Caption word timings weren't carried over; the caption text was.")
        }
        let position = Point(x: script["PosX"].double ?? 0.5, y: script["PosY"].double ?? 0.5)
        return Mapped(content: content, position: position, rotation: layout["Angle"].double ?? 0, notes: notes)
    }

    /// Filmora's default text for a new title. A title still saying this
    /// was probably left in by mistake.
    static func isPlaceholder(_ text: String) -> Bool {
        let placeholders = ["text here", "title here", "enter text here", "your text here", "enter title here", "subtitle here"]
        return placeholders.contains(text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// Filmora stores colours as 0xRRGGBB integers, -1 for "not set".
    static func color(_ value: Int?, alpha: Double = 1) -> RGBA? {
        guard let value, value >= 0 else { return nil }
        return RGBA(
            r: Double((value >> 16) & 0xFF) / 255,
            g: Double((value >> 8) & 0xFF) / 255,
            b: Double(value & 0xFF) / 255,
            a: min(1, max(0, alpha))
        )
    }

    static func weight(font: String, bold: Bool) -> Double {
        let lower = font.lowercased()
        if lower.contains("black") || lower.contains("heavy") { return 900 }
        if lower.contains("extrabold") || lower.contains("extra bold") { return 800 }
        if lower.contains("semibold") || lower.contains("semi bold") { return 600 }
        if lower.contains("bold") || bold { return 700 }
        if lower.contains("medium") { return 500 }
        if lower.contains("light") { return 300 }
        if lower.contains("thin") { return 100 }
        return 400
    }

    private static func animation(_ node: JSONNode) -> (String, Time?)? {
        guard let name = node["name"].string, !name.isEmpty else { return nil }
        let duration = node["duration"].int64.map { Wfp.time($0) }
        return (name, duration)
    }

    /// Tandem's title animations by what Filmora's look like.
    static func animationName(_ name: String, entering: Bool) -> String? {
        let lower = name.lowercased()
        if lower.contains("typewriter") || lower.contains("verbatim") { return entering ? "typewriter" : nil }
        if lower.contains("fade") || lower.contains("gradually") { return entering ? "fadeIn" : "fadeOut" }
        if lower.contains("pop") || lower.contains("bounce") || lower.contains("flash") { return entering ? "popIn" : "popOut" }
        if lower.contains("up") { return entering ? "slideUp" : "slideDown" }
        if lower.contains("down") { return entering ? "slideDown" : "slideUp" }
        if lower.contains("slide") || lower.contains("insert") { return entering ? "slideUp" : "slideDown" }
        return nil
    }
}

// MARK: - Keyframes and speed

enum FilmoraKeyframes {
    /// One Filmora keyframe list as (clip-relative seconds, value) pairs.
    ///
    /// Filmora keys animation to media time, mostly in seconds but in ticks
    /// in some lists (opacity), whatever their version says. No media runs
    /// for 100,000 seconds, so a list with a time past that is in ticks.
    /// Tandem keys animation to the clip's start, so times shift by the
    /// clip's source start and speed.
    static func points(_ parameter: JSONNode, sourceStart: Double, speed: Double) -> [(time: Double, value: Double)] {
        let raw = parameter["keyframeSets"].array.compactMap { frame -> (Double, Double)? in
            guard let time = frame["_time"].double, let value = frame["_value"].double else { return nil }
            return (time, value)
        }
        let inTicks = raw.contains { $0.0 > 100_000 }
        return raw.map { time, value in
            let seconds = inTicks ? time / WfpProject.ticksPerSecond : time
            return ((seconds - sourceStart) / max(speed, 0.000_001), value)
        }.sorted { $0.0 < $1.0 }
    }

    /// The value of a keyframe list at a time, held flat outside it.
    static func value(_ points: [(time: Double, value: Double)], at time: Double) -> Double? {
        guard let first = points.first, let last = points.last else { return nil }
        if time <= first.time { return first.value }
        if time >= last.time { return last.value }
        for (a, b) in zip(points, points.dropFirst()) where time >= a.time && time <= b.time {
            let span = b.time - a.time
            return span > 0 ? a.value + (b.value - a.value) * (time - a.time) / span : b.value
        }
        return last.value
    }

    /// Tandem keyframes for a clip of `duration` seconds, keeping only the
    /// nearest keyframe outside each end, or nil when nothing changes.
    static func keyframes(times: [Double], duration: Double, value: (Double) -> ParamValue) -> [Keyframe]? {
        var unique = Array(Set(times.map { ($0 * 1_000_000).rounded() / 1_000_000 })).sorted()
        if let before = unique.last(where: { $0 < 0 }) { unique.removeAll { $0 < before } }
        if let after = unique.first(where: { $0 > duration }) { unique.removeAll { $0 > after } }
        guard unique.count >= 2 else { return nil }
        let frames = unique.map { Keyframe(time: Time(seconds: $0), value: value($0), interpolation: .linear) }
        guard Set(frames.map { "\($0.value)" }).count > 1 else { return nil }
        return frames
    }
}

struct FilmoraSpeed {
    /// Media seconds the clip starts and ends at.
    var sourceStart: Double
    var sourceEnd: Double
    /// The speed curve changes inside the clip.
    var ramp: Bool
    /// The speed Filmora plays the clip at, when it's one speed throughout.
    var uniform: Double?
    var freeze: Bool
    var reverse: Bool

    /// Reads a clip's source range. Filmora's in and out points are divided
    /// by the speed, so the media range comes from `speed.offset` and
    /// `speed.offsetEnd` when they're there.
    init(_ clip: WfpClip) {
        let speed = clip.node["speed"]
        let inSeconds = Double(clip.inPoint) / WfpProject.ticksPerSecond
        let outSeconds = Double(clip.outPoint) / WfpProject.ticksPerSecond
        if let offset = speed["offset"].double, let offsetEnd = speed["offsetEnd"].double, offsetEnd > offset {
            sourceStart = offset
            sourceEnd = offsetEnd
        } else {
            sourceStart = inSeconds
            sourceEnd = outSeconds
        }
        let parameter = speed["speedParam"].embedded
        var values = parameter["keyframeSets"].array.compactMap { $0["_value"].double }
        // A trailing 1.0 at the end of the media is Filmora's end marker.
        if values.count > 1, abs(values.last! - 1) < 0.001 { values.removeLast() }
        ramp = Set(values.map { ($0 * 1000).rounded() }).count > 1
        uniform = !ramp ? values.first.flatMap { $0 > 0 ? $0 : nil } : nil
        let freezes = parameter["_freeze"].array
        freeze = !freezes.isEmpty
        reverse = speed["reverse"].bool ?? false
    }
}

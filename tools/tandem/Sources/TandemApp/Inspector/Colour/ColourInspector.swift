import AppKit
import SwiftUI
import TandemCore
import UniformTypeIdentifiers

/// What the Colour tab grades: every clip from the file (its look, how
/// Mike grades a camera take) or just this clip, on top of that.
enum ColourTarget: String, CaseIterable, Hashable {
    case take, clip
}

/// The Colour tab: a switch between the whole take and this clip, then
/// fixed sections in grading order (Light, Colour, Colour wheels, Colour
/// mixer, Vignette, Sharpen, LUT), each with an on/off switch, a reset and
/// a chevron. The sections are views onto the look's or the clip's
/// effects (`ColourGrade`); anything they don't cover is listed at the end
/// as it is.
struct ColourInspector: View {
    let model: EditorModel
    let clip: Clip
    /// Where the tab opens, instead of the default for the clip's media.
    var initialTarget: ColourTarget? = nil
    /// The target picked for a clip; a new clip starts on its default.
    @State private var picked: (clipID: String, target: ColourTarget)?
    @State private var mixerColour: String?
    @AppStorage("colourCollapsedSections", store: AppDefaults.store) private var collapsedList = "lut"

    var body: some View {
        if model.project.location(ofClip: clip.id)?.track.kind != .video {
            Text("Colour applies to picture. Select a video clip.")
                .font(.ui(12))
                .foregroundStyle(Theme.textMuted.color)
                .padding(16)
        } else {
            let item = model.media(for: clip)
            let target = target(for: item)
            let editor = ColourEditor(model: model, clip: clip, item: item, target: target)
            VStack(alignment: .leading, spacing: 0) {
                if let item {
                    targetSwitch(item, target: target)
                } else if case .adjustment = clip.content {
                    caption("Grades everything under this adjustment layer.")
                }
                ForEach(ColourSection.allCases) { section in
                    sectionBlock(section, editor)
                }
                OtherColourEffects(editor: editor)
            }
        }
    }

    /// The tab opens where the grade is: the whole take when only the file
    /// has one, this clip when only the clip has one. Otherwise camera
    /// takes open on the whole take, since that's how Mike grades, and
    /// anything else on the clip.
    private func target(for item: MediaItem?) -> ColourTarget {
        guard let item else { return .clip }
        if let picked, picked.clipID == clip.id { return picked.target }
        if let initialTarget { return initialTarget }
        return Self.defaultTarget(for: clip, item: item)
    }

    static func defaultTarget(for clip: Clip, item: MediaItem) -> ColourTarget {
        let lookHasGrade = !item.look.isEmpty
        let clipHasGrade = (clip.video?.effects ?? []).contains { EffectRegistry.standard.definition($0.type)?.category == "Colour" }
        if lookHasGrade != clipHasGrade { return lookHasGrade ? .take : .clip }
        return item.role == .camera ? .take : .clip
    }

    // MARK: - Whole take or this clip

    private func targetSwitch(_ item: MediaItem, target: ColourTarget) -> some View {
        let uses = model.project.videoTracks.reduce(0) { sum, track in sum + track.clips.lazy.filter { $0.mediaID == item.id }.count }
        // Non-breaking hyphens, so a wrap doesn't split the file name.
        let file = MediaCatalog.fileName(item).replacingOccurrences(of: "-", with: "\u{2011}")
        let whole = item.takeID == nil ? "Whole file" : "Whole take"
        let ownColour = (clip.video?.effects ?? []).contains { EffectRegistry.standard.definition($0.type)?.category == "Colour" }
        return VStack(alignment: .leading, spacing: 8) {
            GraphiteSegmented(
                options: ColourTarget.allCases,
                selected: target,
                title: { option in
                    switch option {
                    case .take: return "\(whole) · \(uses == 1 ? "1 clip" : "\(uses) clips")"
                    case .clip: return "This clip"
                    }
                },
                icon: { $0 == .take ? Icons.wholeTake : Icons.thisClip },
                help: { option in
                    switch option {
                    case .take: return "Grade every clip from \(file): the grade you set up once per take"
                    case .clip: return "Grade only this clip, on top of the \(whole.lowercased())'s grade"
                    }
                },
                marked: { option in option == .take ? !item.look.isEmpty : ownColour },
                action: { picked = (clip.id, $0) }
            )
            Text(verbatim: target == .take
                ? "Changes here grade every clip from \(file)."
                : (item.look.isEmpty ? "Changes here grade only this clip." : "Changes here grade only this clip, on top of the \(whole.lowercased())'s grade."))
                .font(.ui(11.5))
                .foregroundStyle(Theme.textMuted.color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border.color).frame(height: 1) }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.ui(11.5))
            .foregroundStyle(Theme.textMuted.color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border.color).frame(height: 1) }
    }

    // MARK: - Sections

    private var collapsed: Set<String> {
        Set(collapsedList.split(separator: ",").map(String.init))
    }

    private func toggleCollapsed(_ section: ColourSection) {
        var set = collapsed
        if set.contains(section.rawValue) { set.remove(section.rawValue) } else { set.insert(section.rawValue) }
        collapsedList = ColourSection.allCases.map(\.rawValue).filter(set.contains).joined(separator: ",")
    }

    private func sectionBlock(_ section: ColourSection, _ editor: ColourEditor) -> some View {
        let grade = editor.grade
        let values = grade.values(section, shown: editor.shown)
        let changed = grade.isChanged(section, shown: editor.shown)
        let expanded = !collapsed.contains(section.rawValue)
        return ColourSectionBlock(
            section: section,
            hasEffect: grade.effect(section) != nil,
            isOn: grade.isOn(section),
            isChanged: changed,
            canToggle: changed || !grade.isOn(section),
            summary: expanded || !changed ? "" : ColourSummary.text(section, values),
            expanded: expanded,
            toggleExpanded: { toggleCollapsed(section) },
            toggle: { editor.toggle(section) },
            reset: { editor.reset(section) }
        ) {
            switch section {
            case .wheels:
                ColourWheelsPanel(
                    values: values,
                    diamond: { wheel in editor.diamond(section, keys: wheel.keys, name: "\(wheel.name) wheel") },
                    commit: { changes, label in editor.set(section, changes, label: label) }
                )
            case .mixer:
                ColourMixerPanel(
                    values: values,
                    selected: mixerColour ?? ColourSection.mixerColours.first { ColourSummary.mixerChanged($0, values) } ?? "red",
                    select: { mixerColour = $0 },
                    accessory: { key in editor.accessory(section, key) },
                    commit: { key, value, label in editor.set(section, [key: .number(value)], label: label) }
                )
            case .lut:
                LUTPanel(model: model, values: values, accessory: editor.accessory(section, "intensity")) { key, value, label in
                    editor.set(section, [key: value], label: label)
                }
            default:
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(ColourSliderSpec.specs(section), id: \.key) { spec in
                        spec.row(section: section, value: values[spec.key]?.number ?? 0, accessory: editor.accessory(section, spec.key)) { value in
                            editor.set(section, [spec.key: .number(value)], label: spec.undo)
                        }
                    }
                }
            }
        }
    }
}

/// Edits the tab's target: the file's look, or the clip's own effects,
/// where values that are animated become keyframes at the playhead.
@MainActor
struct ColourEditor {
    let model: EditorModel
    let clip: Clip
    let item: MediaItem?
    let target: ColourTarget
    let grade: ColourGrade
    /// The clip's effects at the playhead, when some are animated.
    let shown: [Effect]?

    init(model: EditorModel, clip: Clip, item: MediaItem?, target: ColourTarget) {
        self.model = model
        self.clip = clip
        self.item = item
        self.target = target
        if target == .take, let item {
            grade = ColourGrade(item.look)
            shown = nil
        } else {
            let grade = ColourGrade(clip: clip)
            self.grade = grade
            // Reading the playhead makes the tab follow it, so only when
            // something here is animated.
            shown = grade.animated.isEmpty ? nil : clip.resolvedVideo(at: model.clipTime(of: clip)).effects
        }
    }

    var isLook: Bool { target == .take && item != nil }

    func apply(_ change: ColourChange?) {
        guard let change else { return }
        if isLook, let item {
            model.apply(InspectorEdits.look(item.id, change.effects, label: "\(change.label) (whole take)"))
            return
        }
        let commands = ColourEdits.clipCommands(clip, change, at: model.clipTime(of: clip), tolerance: model.keyframeTolerance)
        guard !commands.isEmpty else { return }
        model.apply(EditBatch(label: change.label, commands: commands))
    }

    func set(_ section: ColourSection, _ values: [String: ParamValue], label: String) {
        apply(grade.setting(section, values, label: label))
    }

    func toggle(_ section: ColourSection) {
        apply(grade.toggling(section))
    }

    func reset(_ section: ColourSection) {
        apply(grade.resetting(section))
    }

    /// The keyframe diamond after a control, for a clip's own effects (a
    /// look isn't animated). Until the section has an effect there's
    /// nothing to animate, so it's a gap that keeps the rows lined up.
    func accessory(_ section: ColourSection, _ key: String) -> AnyView? {
        guard !isLook else { return nil }
        guard let effect = grade.effect(section) else { return AnyView(Color.clear.frame(width: 16, height: 18)) }
        return AnyView(KeyframeButton(model: model, clip: clip, parameter: ColourEdits.path(effect.id, key)))
    }

    /// One diamond for several parameters, like a wheel's hue, amount and
    /// brightness.
    func diamond(_ section: ColourSection, keys: [String], name: String) -> AnyView? {
        guard !isLook else { return nil }
        guard let effect = grade.effect(section) else { return AnyView(Color.clear.frame(width: 16, height: 18)) }
        return AnyView(KeyframeGroupButton(model: model, clip: clip, parameters: keys.map { ColourEdits.path(effect.id, $0) }, name: name))
    }
}

/// A section: icon, title, reset, on/off switch and chevron, then its
/// controls, dimmed while it's off. Until something in the section changes
/// there's nothing to reset or turn off, so those stay hidden.
struct ColourSectionBlock<Content: View>: View {
    let section: ColourSection
    let hasEffect: Bool
    let isOn: Bool
    let isChanged: Bool
    let canToggle: Bool
    /// What a collapsed section changes, in a few words.
    let summary: String
    let expanded: Bool
    let toggleExpanded: () -> Void
    let toggle: () -> Void
    let reset: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Button(action: toggleExpanded) {
                    HStack(spacing: 6) {
                        PanelIcon(name: Icons.colourSection(section), color: isChanged && isOn ? Theme.amber.color : Theme.textMuted.color)
                        Text(section.title)
                            .font(.ui(12, .bold))
                            .foregroundStyle(isOn ? Theme.text.color : Theme.textMuted.color)
                            .fixedSize()
                        Spacer(minLength: 4)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(ColourSliderSpec.sectionHelp(section) + (expanded ? " Click to hide." : " Click to show."))
                if hasEffect {
                    IconButton(symbol: Icons.reset, help: "Reset \(section.title.lowercased()): back to no change", action: reset)
                    GraphiteSwitch(isOn: isOn, action: toggle)
                        .disabled(!canToggle)
                        .opacity(canToggle ? 1 : 0.35)
                        .help(canToggle
                            ? (isOn ? "Turn \(section.title.lowercased()) off to compare" : "Turn \(section.title.lowercased()) back on")
                            : "Nothing to turn off yet")
                }
                Button(action: toggleExpanded) {
                    Image(systemName: expanded ? Icons.expanded : Icons.collapsed)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.textFaint.color)
                        .frame(width: 14, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(expanded ? "Hide \(section.title.lowercased())" : "Show \(section.title.lowercased())")
            }
            .frame(height: 18)
            if !expanded, !summary.isEmpty {
                Text(summary)
                    .font(.ui(11))
                    .foregroundStyle(Theme.textFaint.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 22)
                    .padding(.top, -5)
            }
            if expanded {
                content()
                    .opacity(isOn ? 1 : 0.5)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border.color).frame(height: 1) }
    }
}

/// How a colour slider reads: its label, what it does, units and track.
struct ColourSliderSpec {
    let key: String
    let label: String
    /// The undo menu's name for a change.
    let undo: String
    let help: String
    /// Shown after the number: " EV", "%", "°".
    var unit = ""
    /// The number shown is the stored value times this.
    var scale = 1.0
    var decimals = 0
    /// A "+" on values above 0, for controls that go both ways.
    var signed = true
    var gradient: [Color]? = nil

    /// Room for the widest value, "+0.35 EV", so every slider in the tab
    /// is the same length.
    static let valueWidth: CGFloat = 58

    func format(_ value: Double) -> String {
        let shown = value * scale
        var number = String(format: "%.\(decimals)f", abs(shown))
        if decimals > 0, number.hasSuffix(".0") { number.removeLast(2) }
        let rounded = Double(number) ?? 0
        let sign = rounded == 0 ? "" : (shown < 0 ? "−" : (signed ? "+" : ""))
        return sign + number + unit
    }

    func parse(_ text: String) -> Double? {
        SliderRow.plainNumber(text).map { $0 / scale }
    }

    @MainActor
    func row(section: ColourSection, value: Double, accessory: AnyView?, commit: @escaping (Double) -> Void) -> SliderRow {
        let param = EffectRegistry.standard.definition(section.effectType)?.param(key)
        let lower = param?.min ?? -100
        let upper = param?.max ?? 100
        return SliderRow(
            label: label, value: value, range: lower...upper, bipolar: lower < 0 && upper > 0,
            valueWidth: Self.valueWidth, format: format, parse: parse,
            defaultValue: section.neutral(key).number, gradient: gradient, help: help, step: param?.step,
            accessory: accessory, onCommit: commit
        )
    }

    static func specs(_ section: ColourSection) -> [ColourSliderSpec] {
        switch section {
        case .light:
            return [
                ColourSliderSpec(key: "exposure", label: "Exposure", undo: "Exposure", help: "Brightens or darkens the whole picture, in stops: +1 is twice the light.", unit: " EV", decimals: 2),
                ColourSliderSpec(key: "contrast", label: "Contrast", undo: "Contrast", help: "Spreads the tones apart around mid grey; below 0 flattens them."),
                ColourSliderSpec(key: "highlights", label: "Highlights", undo: "Highlights", help: "Brightens or pulls back the brightest parts."),
                ColourSliderSpec(key: "shadows", label: "Shadows", undo: "Shadows", help: "Lifts or deepens the darkest parts."),
                ColourSliderSpec(key: "blackLevel", label: "Black level", undo: "Black level", help: "Moves the black point: below 0 crushes the blacks, above 0 lifts them towards grey.")
            ]
        case .colour:
            return [
                ColourSliderSpec(key: "temperature", label: "Temperature", undo: "Temperature", help: "White balance: cooler and bluer to the left, warmer and more amber to the right.", gradient: ColourTracks.temperature),
                ColourSliderSpec(key: "tint", label: "Tint", undo: "Tint", help: "Takes out a green cast (to the right) or a magenta one (to the left).", gradient: ColourTracks.tint),
                ColourSliderSpec(key: "saturation", label: "Saturation", undo: "Saturation", help: "How colourful the whole picture is. −100% is black and white.", unit: "%", gradient: ColourTracks.saturation),
                ColourSliderSpec(key: "vibrance", label: "Vibrance", undo: "Vibrance", help: "Boosts the muted colours more than the strong ones, so skin stays natural.", gradient: ColourTracks.vibrance)
            ]
        case .vignette:
            return [
                ColourSliderSpec(key: "amount", label: "Amount", undo: "Vignette amount", help: "Darkens the edges (below 0) or lightens them (above 0). Mike's camera grade uses −22 to −37.", gradient: ColourTracks.vignette),
                ColourSliderSpec(key: "size", label: "Size", undo: "Vignette size", help: "How much of the middle stays clear.", unit: "%", signed: false),
                ColourSliderSpec(key: "feather", label: "Feather", undo: "Vignette feather", help: "How gradually the edges fall off.", unit: "%", signed: false)
            ]
        case .sharpen:
            return [
                ColourSliderSpec(key: "amount", label: "Amount", undo: "Sharpen", help: "Sharpens fine detail. 3 or 4 suits the camera.", decimals: 1, signed: false)
            ]
        case .lut:
            return [
                ColourSliderSpec(key: "intensity", label: "Intensity", undo: "LUT intensity", help: "How much of the LUT to mix in.", unit: "%", scale: 100, signed: false)
            ]
        case .wheels, .mixer:
            return []
        }
    }

    /// The mixer's three sliders for one colour.
    static func mixer(_ colour: String) -> [ColourSliderSpec] {
        let hue = ColourSection.mixerHues[colour] ?? 0
        let plural = colour == "aqua" ? "aquas" : colour + "s"
        let index = ColourSection.mixerColours.firstIndex(of: colour) ?? 0
        let before = ColourSection.mixerColours[(index + 7) % 8]
        let after = ColourSection.mixerColours[(index + 1) % 8]
        let name = colour.capitalized
        return [
            ColourSliderSpec(key: colour + "Hue", label: "Hue", undo: "\(name) hue", help: "Shifts the \(plural) towards \(before) (left) or \(after) (right), by up to 30°.", unit: "°", scale: 0.3, decimals: 1, gradient: ColourTracks.hueAround(hue)),
            ColourSliderSpec(key: colour + "Saturation", label: "Saturation", undo: "\(name) saturation", help: "Makes the \(plural) greyer (left) or richer (right). Mike's camera grade takes reds down 7 or 8 to calm skin.", unit: "%", gradient: ColourTracks.saturation(of: hue)),
            ColourSliderSpec(key: colour + "Luminance", label: "Luminance", undo: "\(name) luminance", help: "Makes the \(plural) darker (left) or lighter (right).", gradient: ColourTracks.luminance(of: hue))
        ]
    }

    static func sectionHelp(_ section: ColourSection) -> String {
        switch section {
        case .light: return "Light: exposure, contrast, highlights, shadows and black level. Click to show or hide."
        case .colour: return "Colour: white balance, saturation and vibrance. Click to show or hide."
        case .wheels: return "Colour wheels: tint the shadows, midtones and highlights, with a brightness for each. Click to show or hide."
        case .mixer: return "Colour mixer: the hue, saturation and luminance of one colour at a time. Click to show or hide."
        case .vignette: return "Vignette: darker or lighter edges. Click to show or hide."
        case .sharpen: return "Sharpen: crisper detail. Click to show or hide."
        case .lut: return "LUT: a .cube lookup table. Click to show or hide."
        }
    }
}

/// The colours along the colour sliders' tracks.
enum ColourTracks {
    static func hsb(_ hue: Double, _ saturation: Double, _ brightness: Double) -> Color {
        Color(hue: ColourWheels.normalised(hue) / 360, saturation: saturation, brightness: brightness)
    }

    static let neutral = Color(white: 0.62)
    static let temperature = [Color(red: 0.30, green: 0.52, blue: 0.95), neutral, Color(red: 0.98, green: 0.68, blue: 0.22)]
    static let tint = [Color(red: 0.38, green: 0.78, blue: 0.40), neutral, Color(red: 0.86, green: 0.36, blue: 0.84)]
    static let saturation = [Color(white: 0.5), hsb(20, 0.35, 0.72), hsb(350, 0.95, 0.92)]
    static let vibrance = [Color(white: 0.55), hsb(200, 0.3, 0.7), hsb(30, 0.85, 0.95)]
    static let vignette = [Color(white: 0.1), Color(white: 0.45), Color(white: 0.85)]
    static let brightness = [Color(white: 0.12), Color(white: 0.85)]

    /// Hue ±30 degrees around a colour.
    static func hueAround(_ hue: Double) -> [Color] {
        [hsb(hue - 30, 0.8, 0.9), hsb(hue, 0.8, 0.9), hsb(hue + 30, 0.8, 0.9)]
    }

    static func saturation(of hue: Double) -> [Color] {
        [Color(white: 0.55), hsb(hue, 0.45, 0.8), hsb(hue, 1, 0.95)]
    }

    static func luminance(of hue: Double) -> [Color] {
        [hsb(hue, 0.85, 0.25), hsb(hue, 0.8, 0.8), hsb(hue, 0.3, 1)]
    }
}

/// A collapsed section's changes in a few words.
enum ColourSummary {
    static func text(_ section: ColourSection, _ values: [String: ParamValue]) -> String {
        switch section {
        case .wheels:
            let wheels = ColourWheels.Wheel.allCases.filter { wheel in
                (values[wheel.amountKey]?.number ?? 0) != 0 || (values[wheel.brightnessKey]?.number ?? 0) != 0
            }
            return list(wheels.map { $0.name.lowercased() })
        case .mixer:
            let colours = ColourSection.mixerColours.filter { mixerChanged($0, values) }
            return list(colours.map { $0 == "aqua" ? "aquas" : $0 + "s" })
        case .lut:
            guard case .string(let path)? = values["path"], !path.isEmpty else { return "no file" }
            return (path as NSString).lastPathComponent
        default:
            let specs = ColourSliderSpec.specs(section)
            let parts = specs.compactMap { spec -> String? in
                let value = values[spec.key]?.number ?? 0
                guard .number(value) != section.neutral(spec.key) else { return nil }
                return "\(spec.label.lowercased()) \(spec.format(value))"
            }
            let text = parts.prefix(3).joined(separator: ", ")
            return text.prefix(1).uppercased() + text.dropFirst()
        }
    }

    static func mixerChanged(_ colour: String, _ values: [String: ParamValue]) -> Bool {
        ColourSection.mixerAspects.contains { (values[colour + $0]?.number ?? 0) != 0 }
    }

    private static func list(_ names: [String]) -> String {
        guard let first = names.first else { return "" }
        let capitalised = first.prefix(1).uppercased() + first.dropFirst()
        switch names.count {
        case 1: return capitalised
        case 2: return "\(capitalised) and \(names[1])"
        default: return ([capitalised] + names[1..<(names.count - 1)]).joined(separator: ", ") + " and " + names.last!
        }
    }
}

/// The LUT section: the .cube file, and how much of it to mix in.
struct LUTPanel: View {
    let model: EditorModel
    let values: [String: ParamValue]
    let accessory: AnyView?
    let commit: (String, ParamValue, String) -> Void

    private var path: String {
        if case .string(let path)? = values["path"] { return path }
        return ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Text("File")
                    .font(.ui(12))
                    .foregroundStyle(Theme.textMuted.color)
                    .frame(width: SliderRow.labelWidth, alignment: .leading)
                HStack(spacing: 5) {
                    PanelIcon(name: Icons.lutFile, color: path.isEmpty ? Theme.textFaint.color : Theme.textMuted.color)
                    Text(path.isEmpty ? "None" : (path as NSString).lastPathComponent)
                        .font(.ui(12))
                        .foregroundStyle(path.isEmpty ? Theme.textFaint.color : Theme.text.color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .help(path.isEmpty ? "No LUT chosen" : path)
                Spacer(minLength: 4)
                if !path.isEmpty {
                    IconButton(symbol: Icons.clearFile, help: "Stop using this LUT", size: 11) {
                        commit("path", .string(""), "LUT file")
                    }
                }
                OutlineButton(title: "Choose…") { choose() }
                    .help("Choose a .cube LUT file")
            }
            ColourSliderSpec.specs(.lut)[0].row(section: .lut, value: values["intensity"]?.number ?? 1, accessory: accessory) { value in
                commit("intensity", .number(value), "LUT intensity")
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "cube")].compactMap { $0 }
        panel.allowsOtherFileTypes = true
        panel.message = "Choose a .cube LUT"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        commit("path", .string(model.folder.path(for: url)), "LUT file")
    }
}

/// Colour effects no section shows (a second HSL, a pack's effect), as
/// the generic effect rows, so nothing in the grade is hidden.
struct OtherColourEffects: View {
    let editor: ColourEditor
    @State private var expanded: Set<String> = []

    private var others: [Effect] {
        let all = editor.grade.others
        guard !editor.isLook else { return all }
        return all.filter { EffectRegistry.standard.definition($0.type)?.category == "Colour" }
    }

    var body: some View {
        let others = others
        if !others.isEmpty {
            InspectorSection(title: editor.isLook ? "More in this grade" : "More colour effects", icon: Icons.otherColourEffects) {
                ForEach(others) { effect in
                    let shown = editor.shown?.first { $0.id == effect.id } ?? effect
                    EffectRow(
                        effect: shown,
                        expanded: expanded.contains(effect.id),
                        toggleExpanded: {
                            if expanded.contains(effect.id) { expanded.remove(effect.id) } else { expanded.insert(effect.id) }
                        },
                        setEnabled: { enabled in setEnabled(effect, enabled) },
                        remove: { remove(effect) },
                        keyframe: editor.isLook ? nil : { param in
                            AnyView(KeyframeButton(model: editor.model, clip: editor.clip, parameter: ColourEdits.path(effect.id, param.key)))
                        },
                        commit: { key, value, name in commit(effect, key, value, name) }
                    )
                }
            }
        }
    }

    private func name(_ effect: Effect) -> String {
        EffectRegistry.standard.definition(effect.type)?.name ?? effect.type
    }

    private func setEnabled(_ effect: Effect, _ enabled: Bool) {
        if editor.isLook, let item = editor.item {
            var look = item.look
            if let index = look.firstIndex(where: { $0.id == effect.id }) { look[index].enabled = enabled }
            editor.model.apply(InspectorEdits.look(item.id, look, label: "Turn \(enabled ? "on" : "off") \(name(effect).lowercased()) (whole take)"))
        } else {
            editor.model.apply(InspectorEdits.effectEnabled(editor.clip.id, effectID: effect.id, enabled: enabled, name: name(effect)))
        }
    }

    private func remove(_ effect: Effect) {
        if editor.isLook, let item = editor.item {
            editor.model.apply(InspectorEdits.look(item.id, item.look.filter { $0.id != effect.id }, label: "Remove \(name(effect).lowercased()) (whole take)"))
        } else {
            editor.model.apply(EditBatch(label: "Remove \(name(effect).lowercased())", commands: [.removeEffect(clipID: editor.clip.id, effectID: effect.id)]))
        }
    }

    private func commit(_ effect: Effect, _ key: String, _ value: ParamValue, _ name: String) {
        if editor.isLook, let item = editor.item {
            editor.model.apply(InspectorEdits.lookParam(item, effectID: effect.id, key: key, value: value, label: "\(name) (whole take)"))
        } else {
            editor.model.setParameter(ColourEdits.path(effect.id, key), to: value, in: editor.clip, label: name) {
                InspectorEdits.effectParam(editor.clip.id, effectID: effect.id, key: key, value: value, label: name)
            }
        }
    }
}

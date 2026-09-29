import AppKit
import SwiftUI
import TandemCore
import UniformTypeIdentifiers

/// One slider of a section: plain values and the editor, so it's only
/// redrawn when its own value (or the target) changes. Dragging previews
/// in the viewer where the target can (`ColourEditor.preview`).
struct ColourSliderRow: View, Equatable {
    let spec: ColourSliderSpec
    let section: ColourSection
    let value: Double
    let diamond: ColourDiamond
    let editor: ColourEditor

    nonisolated static func == (a: ColourSliderRow, b: ColourSliderRow) -> Bool {
        a.spec == b.spec && a.section == b.section && a.value == b.value && a.diamond == b.diamond && a.editor == b.editor
    }

    var body: some View {
        spec.row(
            section: section, value: value,
            accessory: editor.diamond(diamond, keys: [spec.key], name: "\(section.title) \(spec.label.lowercased())"),
            preview: { value in editor.preview(section, value.map { [spec.key: .number($0)] }) }
        ) { value in
            editor.set(section, [spec.key: .number(value)], label: spec.undo)
        }
    }
}

/// A keyframe diamond that finds its clip when it draws, so it's right
/// even when the row around it wasn't redrawn. One diamond can key several
/// parameters together, like a wheel's hue, amount and brightness.
struct ColourKeyframeDiamond: View {
    let model: EditorModel
    let clipID: String
    let parameters: [String]
    /// "Shadows wheel", for a group's tooltip.
    let name: String

    var body: some View {
        if let clip = model.project.clip(clipID) {
            if parameters.count == 1 {
                KeyframeButton(model: model, clip: clip, parameter: parameters[0])
            } else {
                KeyframeGroupButton(model: model, clip: clip, parameters: parameters, name: name)
            }
        } else {
            Color.clear.frame(width: 16, height: 18)
        }
    }
}

/// How a colour slider reads: its label, what it does, units and track.
struct ColourSliderSpec: Equatable {
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
    func row(section: ColourSection, value: Double, accessory: AnyView?, preview: @escaping (Double?) -> Void = { _ in }, commit: @escaping (Double) -> Void) -> SliderRow {
        let param = EffectRegistry.standard.definition(section.effectType)?.param(key)
        let lower = param?.min ?? -100
        let upper = param?.max ?? 100
        return SliderRow(
            label: label, value: value, range: lower...upper, bipolar: lower < 0 && upper > 0,
            valueWidth: Self.valueWidth, format: format, parse: parse,
            defaultValue: section.neutral(key).number, gradient: gradient, help: help, step: param?.step,
            dimsDefault: true, onPreview: preview, accessory: accessory, onCommit: commit
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
struct LUTPanel: View, Equatable {
    let values: [String: ParamValue]
    let diamond: ColourDiamond
    let editor: ColourEditor

    nonisolated static func == (a: LUTPanel, b: LUTPanel) -> Bool {
        a.values == b.values && a.diamond == b.diamond && a.editor == b.editor
    }

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
                        editor.set(.lut, ["path": .string("")], label: "LUT file")
                    }
                }
                OutlineButton(title: "Choose…") { choose() }
                    .help("Choose a .cube LUT file")
            }
            ColourSliderRow(spec: ColourSliderSpec.specs(.lut)[0], section: .lut, value: values["intensity"]?.number ?? 1, diamond: diamond, editor: editor)
                .equatable()
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "cube")].compactMap { $0 }
        panel.allowsOtherFileTypes = true
        panel.message = "Choose a .cube LUT"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        editor.set(.lut, ["path": .string(editor.model.folder.path(for: url))], label: "LUT file")
    }
}

/// Colour effects no section shows (a second HSL, a pack's effect), as
/// the generic effect rows, so nothing in the grade is hidden.
struct OtherColourEffects: View {
    let editor: ColourEditor
    let effects: [Effect]
    /// The clip's effects at the playhead, when some are animated.
    let atPlayhead: [Effect]?
    @State private var expanded: Set<String> = []

    var body: some View {
        if !effects.isEmpty {
            InspectorSection(title: editor.isLook ? "More in this grade" : "More colour effects", icon: Icons.otherColourEffects) {
                ForEach(effects) { effect in
                    EffectRow(
                        effect: atPlayhead?.first { $0.id == effect.id } ?? effect,
                        expanded: expanded.contains(effect.id),
                        toggleExpanded: {
                            if expanded.contains(effect.id) { expanded.remove(effect.id) } else { expanded.insert(effect.id) }
                        },
                        setEnabled: { enabled in setEnabled(effect.id, enabled) },
                        remove: { remove(effect.id) },
                        keyframe: editor.isLook ? nil : { param in
                            editor.diamond(.effect(effect.id), keys: [param.key], name: param.name) ?? AnyView(EmptyView())
                        },
                        commit: { key, value, name in commit(effect.id, key, value, name) }
                    )
                }
            }
        }
    }

    private func name(_ effect: Effect) -> String {
        EffectRegistry.standard.definition(effect.type)?.name ?? effect.type
    }

    // Each action starts from the project as it is now.

    private func setEnabled(_ effectID: String, _ enabled: Bool) {
        guard let (clip, item, _) = editor.current() else { return }
        if editor.isLook, let item {
            var look = item.look
            guard let index = look.firstIndex(where: { $0.id == effectID }) else { return }
            look[index].enabled = enabled
            editor.model.apply(InspectorEdits.look(item.id, look, label: "Turn \(enabled ? "on" : "off") \(name(look[index]).lowercased()) (whole take)"))
        } else if let effect = clip.video?.effects.first(where: { $0.id == effectID }) {
            editor.model.apply(InspectorEdits.effectEnabled(clip.id, effectID: effectID, enabled: enabled, name: name(effect)))
        }
    }

    private func remove(_ effectID: String) {
        guard let (clip, item, _) = editor.current() else { return }
        if editor.isLook, let item, let effect = item.look.first(where: { $0.id == effectID }) {
            editor.model.apply(InspectorEdits.look(item.id, item.look.filter { $0.id != effectID }, label: "Remove \(name(effect).lowercased()) (whole take)"))
        } else if let effect = clip.video?.effects.first(where: { $0.id == effectID }) {
            editor.model.apply(EditBatch(label: "Remove \(name(effect).lowercased())", commands: [.removeEffect(clipID: clip.id, effectID: effectID)]))
        }
    }

    private func commit(_ effectID: String, _ key: String, _ value: ParamValue, _ name: String) {
        guard let (clip, item, _) = editor.current() else { return }
        if editor.isLook, let item {
            editor.model.apply(InspectorEdits.lookParam(item, effectID: effectID, key: key, value: value, label: "\(name) (whole take)"))
        } else {
            editor.model.setParameter(ColourEdits.path(effectID, key), to: value, in: clip, label: name) {
                InspectorEdits.effectParam(clip.id, effectID: effectID, key: key, value: value, label: name)
            }
        }
    }
}

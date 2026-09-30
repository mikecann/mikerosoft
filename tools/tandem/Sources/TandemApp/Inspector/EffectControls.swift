import AppKit
import SwiftUI
import TandemCore

/// A clip's effects with controls built from each effect's parameter
/// definitions, so an effect from a pack gets its UI for free.
struct EffectStack: View {
    let model: EditorModel
    let clip: Clip
    let domain: EffectDefinition.Domain
    var title = "Effects"
    /// Registry categories this stack leaves to another tab.
    var excludeCategories: Set<String> = []
    /// When set, only these categories.
    var onlyCategories: Set<String>? = nil
    @State private var expanded: Set<String> = []

    private func belongs(_ type: String) -> Bool {
        guard let definition = EffectRegistry.standard.definition(type) else { return onlyCategories == nil }
        if let only = onlyCategories { return only.contains(definition.category) }
        return !excludeCategories.contains(definition.category)
    }

    var body: some View {
        // Animated parameters show their value at the playhead.
        let effects = clip.keyframes.isEmpty
            ? ((domain == .video ? clip.video?.effects : clip.audio?.effects) ?? [])
            : (domain == .video ? clip.resolvedVideo(at: model.clipTime(of: clip)).effects : clip.resolvedAudio(at: model.clipTime(of: clip)).effects)
        let shown = effects.filter { belongs($0.type) }
        let prefix = domain == .video ? "video.effects." : "audio.effects."
        let available = EffectRegistry.standard.sorted.filter { $0.domain == domain && belongs($0.type) }
        InspectorSection(title: title, icon: title == "Effects" ? Icons.effects : Icons.clipOnly, accessory: {
            Menu {
                ForEach(available, id: \.type) { definition in
                    Button(definition.name, systemImage: Icons.effect(definition.type)) {
                        let effect = Effect(type: definition.type)
                        if model.apply(EditBatch(label: "Add \(definition.name.lowercased())", commands: [.addEffect(clipID: clip.id, effect: effect)])) != nil {
                            expanded.insert(effect.id)
                        }
                    }
                }
            } label: {
                Text("+ Add")
                    .font(.ui(11.5))
                    .foregroundStyle(Theme.amber.color)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(available.isEmpty)
        }) {
            ForEach(shown) { effect in
                EffectRow(
                    effect: effect,
                    expanded: expanded.contains(effect.id),
                    toggleExpanded: {
                        if expanded.contains(effect.id) { expanded.remove(effect.id) } else { expanded.insert(effect.id) }
                    },
                    setEnabled: { enabled in
                        model.apply(InspectorEdits.effectEnabled(clip.id, effectID: effect.id, enabled: enabled, name: EffectRegistry.standard.definition(effect.type)?.name ?? effect.type))
                    },
                    remove: {
                        model.apply(EditBatch(label: "Remove \((EffectRegistry.standard.definition(effect.type)?.name ?? effect.type).lowercased())", commands: [.removeEffect(clipID: clip.id, effectID: effect.id)]))
                    },
                    keyframe: { param in
                        AnyView(KeyframeButton(model: model, clip: clip, parameter: prefix + effect.id + "." + param.key))
                    },
                    commit: { key, value, name in
                        model.setParameter(prefix + effect.id + "." + key, to: value, in: clip, label: name) {
                            InspectorEdits.effectParam(clip.id, effectID: effect.id, key: key, value: value, label: name)
                        }
                    }
                )
            }
        }
    }
}

/// One effect: a compact row that opens to show its parameters.
struct EffectRow: View {
    let effect: Effect
    let expanded: Bool
    let toggleExpanded: () -> Void
    let setEnabled: (Bool) -> Void
    var remove: (() -> Void)?
    /// The keyframe diamond for an animatable parameter, where keyframes apply.
    var keyframe: ((ParamDefinition) -> AnyView)? = nil
    let commit: (String, ParamValue, String) -> Void

    private var definition: EffectDefinition? { EffectRegistry.standard.definition(effect.type) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    setEnabled(!effect.enabled)
                } label: {
                    Circle()
                        .strokeBorder(Theme.textSecondary.color, lineWidth: 1.5)
                        .background(Circle().fill(effect.enabled ? Theme.amber.color : .clear))
                        .frame(width: 10, height: 10)
                }
                .buttonStyle(.plain)
                .tip(effect.enabled ? "Turn off" : "Turn on")
                PanelIcon(name: Icons.effect(effect.type), color: effect.enabled ? Theme.textSecondary.color : Theme.textFaint.color)
                Text(definition?.name ?? "\(effect.type) (unknown)")
                    .font(.ui(12))
                    .foregroundStyle(effect.enabled ? Theme.text.color : Theme.textMuted.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(summary)
                    .font(.ui(11))
                    .foregroundStyle(Theme.textMuted.color)
                    .lineLimit(1)
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textFaint.color)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.field.color))
            .contentShape(Rectangle())
            .onTapGesture(perform: toggleExpanded)
            .contextMenu {
                Button(effect.enabled ? "Turn off" : "Turn on", systemImage: effect.enabled ? "eye.slash" : "eye") { setEnabled(!effect.enabled) }
                if let remove { Button("Remove", systemImage: "trash", action: remove) }
            }
            if expanded, let definition {
                ParamControls(definition: definition, values: definition.resolvedParams(effect), keyframe: keyframe, commit: commit)
                    .padding(.leading, 4)
                if let remove {
                    Button(action: remove) {
                        Text("Remove \(definition.name.lowercased())")
                            .font(.ui(11))
                            .foregroundStyle(Theme.textMuted.color)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 4)
                }
            }
        }
    }

    /// The first parameter's value, like the design's "0 px".
    private var summary: String {
        guard let definition, let first = definition.params.first(where: { $0.kind == .number }) else { return "" }
        let value = definition.resolvedParams(effect)[first.key]?.number ?? 0
        return ParamFormatting.format(value, first)
    }
}

enum ParamFormatting {
    static func format(_ value: Double, _ param: ParamDefinition) -> String {
        let step = param.step ?? 1
        let digits = step >= 1 ? 0 : (step >= 0.1 ? 1 : 2)
        let number = String(format: "%.\(digits)f", value).replacingOccurrences(of: "-", with: "−")
        switch param.unit {
        case "%": return number + "%"
        case "degrees": return number + "°"
        case "stops": return (value > 0 ? "+" : "") + number
        case "px@1080": return number + " px"
        case let unit?: return "\(number) \(unit)"
        case nil: return (param.min ?? 0) < 0 && value > 0 ? "+" + number : number
        }
    }
}

/// Controls generated from parameter definitions.
struct ParamControls: View {
    let definition: EffectDefinition
    let values: [String: ParamValue]
    var keyframe: ((ParamDefinition) -> AnyView)? = nil
    let commit: (String, ParamValue, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(definition.params, id: \.key) { param in
                control(for: param)
            }
        }
    }

    @ViewBuilder
    private func control(for param: ParamDefinition) -> some View {
        let value = values[param.key] ?? param.defaultValue
        switch param.kind {
        case .number:
            let lower = param.min ?? 0
            let upper = param.max ?? max(1, (value.number ?? 0) * 2)
            SliderRow(
                label: param.name, value: value.number ?? 0, range: lower...upper, bipolar: lower < 0 && upper > 0,
                format: { ParamFormatting.format($0, param) },
                parse: SliderRow.plainNumber,
                defaultValue: param.defaultValue.number,
                help: ParamHelp.text(definition, param),
                step: param.step,
                accessory: param.animatable ? keyframe?(param) : nil
            ) { newValue in
                commit(param.key, .number(newValue), param.name)
            }
        case .bool:
            HStack {
                Text(param.name).font(.ui(12)).foregroundStyle(Theme.textMuted.color)
                Spacer()
                let on = { if case .bool(let b) = value { return b } else { return false } }()
                GraphiteSwitch(isOn: on) { commit(param.key, .bool(!on), param.name) }
            }
        case .color:
            ColourRow(label: param.name, value: { if case .color(let c) = value { return c } else { return .white } }()) { colour in
                commit(param.key, .color(colour), param.name)
            }
        case .choice:
            HStack(spacing: 10) {
                Text(param.name).font(.ui(12)).foregroundStyle(Theme.textMuted.color).frame(width: 86, alignment: .leading)
                let current = { if case .string(let s) = value { return s } else { return "" } }()
                Menu(current.isEmpty ? "Choose" : current) {
                    ForEach(param.choices ?? [], id: \.self) { choice in
                        Button(choice) { commit(param.key, .string(choice), param.name) }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer()
            }
        case .string:
            StringParamRow(param: param, value: { if case .string(let s) = value { return s } else { return "" } }()) { text in
                commit(param.key, .string(text), param.name)
            }
        case .point:
            let point = { if case .point(let p) = value { return p } else { return Point(x: 0.5, y: 0.5) } }()
            HStack(spacing: 10) {
                Text(param.name).font(.ui(12)).foregroundStyle(Theme.textMuted.color).frame(width: 86, alignment: .leading)
                NumberField(prefix: "x", value: point.x * 100) { commit(param.key, .point(Point(x: $0 / 100, y: point.y)), param.name) }
                NumberField(prefix: "y", value: point.y * 100) { commit(param.key, .point(Point(x: point.x, y: $0 / 100)), param.name) }
                Spacer()
            }
        }
    }
}

/// A colour well that commits once the picking settles, so dragging in the
/// colour panel doesn't make dozens of undo steps.
private struct ColourRow: View {
    let label: String
    let value: RGBA
    let commit: (RGBA) -> Void
    @State private var pending: DispatchWorkItem?

    var body: some View {
        HStack(spacing: 10) {
            Text(label).font(.ui(12)).foregroundStyle(Theme.textMuted.color).frame(width: 86, alignment: .leading)
            ColorPicker("", selection: Binding(
                get: { Color(.sRGB, red: value.r, green: value.g, blue: value.b, opacity: value.a) },
                set: { colour in
                    guard let converted = NSColor(colour).usingColorSpace(.sRGB) else { return }
                    let rgba = RGBA(r: Double(converted.redComponent), g: Double(converted.greenComponent), b: Double(converted.blueComponent), a: Double(converted.alphaComponent))
                    pending?.cancel()
                    let work = DispatchWorkItem { commit(rgba) }
                    pending = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
                }
            ), supportsOpacity: true)
            .labelsHidden()
            Spacer()
        }
    }
}

private struct StringParamRow: View {
    let param: ParamDefinition
    let value: String
    let commit: (String) -> Void
    @State private var text = ""

    var body: some View {
        HStack(spacing: 8) {
            Text(param.name).font(.ui(12)).foregroundStyle(Theme.textMuted.color).frame(width: 86, alignment: .leading)
            TextField("", text: $text, prompt: Text("none").foregroundStyle(Theme.textFaint.color))
                .textFieldStyle(.plain)
                .font(.ui(12))
                .foregroundStyle(Theme.text.color)
                .onSubmit { if text != value { commit(text) } }
            if param.key == "path" {
                OutlineButton(title: "Choose…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = []
                    panel.allowsOtherFileTypes = true
                    panel.message = "Choose a .cube LUT"
                    if panel.runModal() == .OK, let url = panel.url {
                        text = url.path
                        commit(url.path)
                    }
                }
            }
        }
        .onAppear { text = value }
        .onChange(of: value) { _, new in text = new }
    }
}

/// What an effect's parameter does, for its control's tooltip. Effects
/// without a line here (a pack's) get their summary.
enum ParamHelp {
    static func text(_ definition: EffectDefinition, _ param: ParamDefinition) -> String {
        if let line = lines["\(definition.type).\(param.key)"] { return line }
        return "\(definition.name) \(param.name.lowercased()). \(definition.summary)"
    }

    static let lines: [String: String] = [
        "dropShadow.distance": "How far the shadow falls from the picture, in pixels at 1080p.",
        "dropShadow.angle": "Where the light comes from, degrees anticlockwise from the right: 135 casts the shadow down and right.",
        "dropShadow.blur": "How soft the shadow's edge is, in pixels at 1080p.",
        "dropShadow.opacity": "How dark the shadow is.",
        "dropShadow.color": "The shadow's colour.",
        "border.width": "How thick the outline is, in pixels at 1080p.",
        "border.color": "The outline's colour.",
        "roundedCorners.radius": "How round the corners are, in pixels at 1080p.",
        "blur.radius": "How blurred the picture is, in pixels at 1080p.",
        "pixelate.scale": "How big the blocks are, in pixels at 1080p. Big enough to hide keys and emails.",
        "pitchShift.semitones": "Moves the pitch up or down without changing the speed. 12 is an octave."
    ]
}

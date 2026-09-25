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
        let effects = (domain == .video ? clip.video?.effects : clip.audio?.effects) ?? []
        let shown = effects.filter { belongs($0.type) }
        let available = EffectRegistry.standard.sorted.filter { $0.domain == domain && belongs($0.type) }
        InspectorSection(title: title, accessory: {
            Menu {
                ForEach(available, id: \.type) { definition in
                    Button(definition.name) {
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
            if shown.isEmpty {
                Text(domain == .video ? "No effects on this clip." : "No sound effects on this clip.")
                    .font(.ui(11.5))
                    .foregroundStyle(Theme.textFaint.color)
            }
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
                    commit: { key, value, name in
                        model.apply(InspectorEdits.effectParam(clip.id, effectID: effect.id, key: key, value: value, label: name))
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
                .help(effect.enabled ? "Turn off" : "Turn on")
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
                Button(effect.enabled ? "Turn off" : "Turn on") { setEnabled(!effect.enabled) }
                if let remove { Button("Remove", action: remove) }
            }
            if expanded, let definition {
                ParamControls(definition: definition, values: definition.resolvedParams(effect), commit: commit)
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
                parse: { Double($0.replacingOccurrences(of: "−", with: "-").filter { "-0123456789.".contains($0) }) }
            ) { newValue in
                let step = param.step ?? 0
                let snapped = step > 0 ? (newValue / step).rounded() * step : newValue
                commit(param.key, .number(snapped), param.name)
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

// MARK: - Colour tab

/// The file's look (the grade every clip of the file gets) and the clip's
/// own colour effects.
struct ColourInspector: View {
    let model: EditorModel
    let clip: Clip
    @State private var expanded: Set<String> = []

    var body: some View {
        let isVideo = model.project.location(ofClip: clip.id)?.track.kind == .video
        if !isVideo {
            Text("Colour applies to picture. Select a video clip.")
                .font(.ui(12))
                .foregroundStyle(Theme.textMuted.color)
                .padding(16)
        } else {
            if let item = model.media(for: clip) {
                lookSection(item)
            }
            EffectStack(model: model, clip: clip, domain: .video, title: "This clip only", onlyCategories: ["Colour"])
        }
    }

    private func lookSection(_ item: MediaItem) -> some View {
        let colourTypes = EffectRegistry.standard.sorted.filter { $0.domain == .video && $0.category == "Colour" }
        let users = model.project.allTracks.flatMap(\.clips).filter { $0.mediaID == item.id }.count
        return InspectorSection(title: "Look", accessory: {
            Menu {
                ForEach(colourTypes, id: \.type) { definition in
                    Button(definition.name) {
                        let effect = Effect(type: definition.type)
                        if model.apply(InspectorEdits.look(item.id, item.look + [effect], label: "Add \(definition.name.lowercased()) to the look")) != nil {
                            expanded.insert(effect.id)
                        }
                    }
                }
            } label: {
                Text("+ Add").font(.ui(11.5)).foregroundStyle(Theme.amber.color)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }) {
            Text("Applies to every clip from \(MediaCatalog.fileName(item)) (\(users) on the timeline).")
                .font(.ui(11.5))
                .foregroundStyle(Theme.textMuted.color)
                .fixedSize(horizontal: false, vertical: true)
            if item.look.isEmpty {
                Text("No grade yet. Add Colour to start one.")
                    .font(.ui(11.5))
                    .foregroundStyle(Theme.textFaint.color)
            }
            ForEach(item.look) { effect in
                EffectRow(
                    effect: effect,
                    expanded: expanded.contains(effect.id),
                    toggleExpanded: {
                        if expanded.contains(effect.id) { expanded.remove(effect.id) } else { expanded.insert(effect.id) }
                    },
                    setEnabled: { enabled in
                        var look = item.look
                        if let index = look.firstIndex(where: { $0.id == effect.id }) { look[index].enabled = enabled }
                        model.apply(InspectorEdits.look(item.id, look, label: enabled ? "Turn on look effect" : "Turn off look effect"))
                    },
                    remove: {
                        model.apply(InspectorEdits.look(item.id, item.look.filter { $0.id != effect.id }, label: "Remove from the look"))
                    },
                    commit: { key, value, name in
                        model.apply(InspectorEdits.lookParam(item, effectID: effect.id, key: key, value: value, label: "Look: \(name.lowercased())"))
                    }
                )
            }
        }
    }
}

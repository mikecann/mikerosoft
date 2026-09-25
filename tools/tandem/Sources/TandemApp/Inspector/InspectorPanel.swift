import AppKit
import SwiftUI
import TandemCore

/// The right panel: the selected clip's Video, Colour, Audio and Info, and
/// the activity feed.
struct InspectorPanel: View {
    let model: EditorModel
    let actions: EditorActions

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                ForEach(InspectorTab.allCases) { tab in
                    InspectorTabButton(tab: tab, selected: model.inspectorTab == tab) { model.inspectorTab = tab }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(height: 40)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border.color).frame(height: 1) }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.panel.color)
    }

    @ViewBuilder private var content: some View {
        if model.inspectorTab == .activity {
            ActivityFeed(model: model)
        } else if let transitionID = model.selectedTransitionID, model.selection.isEmpty,
                  let location = model.project.location(ofTransition: transitionID) {
            TransitionInspector(model: model, transition: model.project[location.track].transitions[location.index], track: model.project[location.track])
        } else if let clipID = model.primaryClipID, let clip = model.project.clip(clipID) {
            ClipHeader(model: model, clip: clip)
            switch model.inspectorTab {
            case .video: VideoInspector(model: model, clip: clip)
            case .colour: ColourInspector(model: model, clip: clip)
            case .audio: AudioInspector(model: model, clip: clip)
            case .info: ClipInfo(model: model, clip: clip)
            case .activity: EmptyView()
            }
        } else {
            NothingSelected(model: model)
        }
    }
}

private struct InspectorTabButton: View {
    let tab: InspectorTab
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(tab.title)
                .font(.ui(12, selected ? .semibold : .regular))
                .foregroundStyle(selected ? Theme.text.color : Theme.textFaint.color)
                .padding(.bottom, 2)
                .overlay(alignment: .bottom) {
                    if selected { Rectangle().fill(Theme.amber.color).frame(height: 2).offset(y: 2) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// "Camera · Take 2" and "V2 · 05:21 to 05:44 · linked to screen".
struct ClipHeader: View {
    let model: EditorModel
    let clip: Clip

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.ui(13, .bold))
                .foregroundStyle(Theme.text.color)
                .lineLimit(1)
            Text(subtitle)
                .font(.ui(11.5))
                .foregroundStyle(Theme.textMuted.color)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border.color).frame(height: 1) }
    }

    private var trackName: String { model.project.track(containingClip: clip.id)?.name ?? "" }

    private var title: String {
        let name = ClipRenderer(project: model.project, scale: model.timeline.scale, artwork: nil, visible: 0...0).name(of: clip)
        let count = model.selection.count
        let suffix = count > 1 ? " and \(count - 1) more" : ""
        return "\(trackName) · \(name)\(suffix)"
    }

    private var subtitle: String {
        var parts: [String] = []
        if let location = model.project.location(ofClip: clip.id) {
            parts.append("\(location.track.kind == .video ? "V" : "A")\(location.track.index + 1)")
        }
        parts.append("\(Timecode.string(clip.start, rate: model.frameRate)) to \(Timecode.string(clip.end, rate: model.frameRate))")
        let partners = model.project.linkedClipIDs(of: clip.id).filter { $0 != clip.id }
        if !partners.isEmpty {
            let names = Set(partners.compactMap { model.project.track(containingClip: $0)?.name.lowercased() })
            parts.append("linked to " + names.sorted().joined(separator: " and "))
        }
        return parts.joined(separator: " · ")
    }
}

private struct NothingSelected: View {
    let model: EditorModel

    var body: some View {
        let settings = model.project.settings
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.project.name)
                    .font(.ui(13, .bold))
                    .foregroundStyle(Theme.text.color)
                Text("Select a clip to see its settings.")
                    .font(.ui(11.5))
                    .foregroundStyle(Theme.textMuted.color)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border.color).frame(height: 1) }
            InspectorSection(title: "Project") {
                InfoRow(label: "Canvas", value: "\(settings.width) × \(settings.height)")
                InfoRow(label: "Frame rate", value: String(format: "%g fps", settings.frameRate.framesPerSecond))
                InfoRow(label: "Loudness", value: String(format: "%.0f LUFS, peaks under %.0f dBTP", settings.loudnessTarget, settings.truePeakCeiling).replacingOccurrences(of: "-", with: "−"))
                InfoRow(label: "Length", value: Timecode.string(model.project.duration, rate: model.frameRate))
                InfoRow(label: "Media", value: "\(model.project.media.count) files")
            }
            InspectorSection(title: "Keys") {
                ForEach(Self.hints, id: \.0) { hint in
                    InfoRow(label: hint.0, value: hint.1)
                }
            }
        }
    }

    static let hints: [(String, String)] = [
        ("J K L", "Play backwards, stop, play forwards"),
        ("I and O", "Mark in and out; ; lifts and ' extracts"),
        ("⌘B", "Blade at the playhead"),
        ("Q and W", "Ripple trim to the playhead"),
        ("1 to 4", "Full, PiP right, PiP left, split"),
        ("Z drag", "Zoom the screen in the viewer")
    ]
}

// MARK: - Video

struct VideoInspector: View {
    let model: EditorModel
    let clip: Clip

    private var video: VideoProperties { model.videoPreview[clip.id] ?? clip.video ?? VideoProperties() }
    private var isVideo: Bool { model.project.location(ofClip: clip.id)?.track.kind == .video }
    private var canvas: CGSize { CGSize(width: model.project.settings.width, height: model.project.settings.height) }

    var body: some View {
        if !isVideo {
            Text("This clip is sound only. Its settings are on the Audio tab.")
                .font(.ui(12))
                .foregroundStyle(Theme.textMuted.color)
                .padding(16)
        } else {
            layoutSection
            cutoutSection
            cropSection
            EffectStack(model: model, clip: clip, domain: .video, excludeCategories: ["Colour"])
        }
    }

    private var layoutSection: some View {
        InspectorSection(title: "Layout") {
            GraphiteSegmented(
                options: LayoutPreset.allCases,
                selected: video.layoutPreset.flatMap(LayoutPreset.init(rawValue:)),
                title: { preset in
                    switch preset {
                    case .full: return "Full"
                    case .pipRight: return "PiP ↘"
                    case .pipLeft: return "PiP ↙"
                    case .split: return "Split"
                    }
                },
                action: { preset in
                    model.apply(TimelineEdits.applyLayout(model.project, preset: preset, playhead: model.playback.time, selection: model.selection.isEmpty ? [clip.id] : model.selection))
                }
            )
            SliderRow(label: "Scale", value: video.transform.scale * 100, range: 0...400, format: { "\(Int($0.rounded()))%" },
                      onPreview: preview { properties, value in properties.transform.scale = (value ?? 0) / 100 },
                      onCommit: commitTransform { transform, value in transform.scale = value / 100 })
            PositionRow(model: model, clip: clip, transform: video.transform, canvas: canvas)
            SliderRow(label: "Rotation", value: video.transform.rotation, range: -180...180, bipolar: true, format: { "\(Int($0.rounded()))°" },
                      onPreview: preview { properties, value in properties.transform.rotation = value ?? 0 },
                      onCommit: commitTransform { transform, value in transform.rotation = value })
            SliderRow(label: "Opacity", value: video.opacity * 100, range: 0...100, format: { "\(Int($0.rounded()))%" },
                      onPreview: preview { properties, value in properties.opacity = (value ?? 0) / 100 },
                      onCommit: { value in model.apply(InspectorEdits.video(clip.id, ["opacity": .number(value / 100)], label: "Opacity")) })
        }
    }

    private var cutoutSection: some View {
        let cutout = video.cutout
        let enabled = cutout?.enabled == true
        let shadow = video.effects.first { $0.type == "dropShadow" }
        return InspectorSection(title: "Portrait cutout", accessory: {
            GraphiteSwitch(isOn: enabled) {
                model.apply(InspectorEdits.video(clip.id, ["cutout": .object(["enabled": .bool(!enabled)])], label: enabled ? "Cutout off" : "Cutout on"))
            }
        }) {
            SliderRow(label: "Edge", value: cutout?.edgeFeather ?? 2, range: 0...20, format: { String(format: "%.0f px", $0) },
                      onCommit: { value in model.apply(InspectorEdits.video(clip.id, ["cutout": .object(["edgeFeather": .number(value)])], label: "Cutout edge")) })
            HStack(spacing: 10) {
                Text("Keep mic")
                    .font(.ui(12))
                    .foregroundStyle(Theme.textMuted.color)
                    .frame(width: 86, alignment: .leading)
                let keeps = (cutout?.mode ?? .personAndProps) == .personAndProps
                Text(keeps ? "On" : "Off")
                    .font(.ui(12))
                    .foregroundStyle(Theme.text.color)
                Spacer()
                GraphiteSwitch(isOn: keeps) {
                    model.apply(InspectorEdits.video(clip.id, ["cutout": .object(["mode": .string(keeps ? CutoutMode.person.rawValue : CutoutMode.personAndProps.rawValue)])], label: keeps ? "Cutout without props" : "Cutout keeps the mic"))
                }
            }
            SliderRow(label: "Shadow", value: shadow?.params["opacity"]?.number ?? (shadow == nil ? 0 : 60), range: 0...100, format: { "\(Int($0.rounded()))%" },
                      onCommit: { value in model.apply(InspectorEdits.shadowOpacity(clip, percent: value)) })
        }
        .opacity(enabled ? 1 : 0.75)
    }

    private var cropSection: some View {
        InspectorSection(title: "Crop") {
            ForEach(["left", "top", "right", "bottom"], id: \.self) { edge in
                SliderRow(label: edge.capitalized, value: value(of: edge) * 100, range: 0...50, format: { "\(Int($0.rounded()))%" },
                          onPreview: { value in
                              var preview = video
                              if let value { set(edge, value / 100, in: &preview.crop) }
                              model.videoPreview[clip.id] = value == nil ? nil : preview
                          },
                          onCommit: { value in
                              var crop = video.crop
                              set(edge, value / 100, in: &crop)
                              model.apply(InspectorEdits.crop(clip.id, crop))
                          })
            }
        }
    }

    private func value(of edge: String) -> Double {
        switch edge {
        case "left": return video.crop.left
        case "top": return video.crop.top
        case "right": return video.crop.right
        default: return video.crop.bottom
        }
    }

    private func set(_ edge: String, _ value: Double, in crop: inout Crop) {
        switch edge {
        case "left": crop.left = value
        case "top": crop.top = value
        case "right": crop.right = value
        default: crop.bottom = value
        }
    }

    /// Live viewer preview while a slider moves; nil clears it.
    private func preview(_ change: @escaping (inout VideoProperties, Double?) -> Void) -> (Double?) -> Void {
        { value in
            guard let value else {
                model.videoPreview[clip.id] = nil
                return
            }
            var properties = clip.video ?? VideoProperties()
            change(&properties, value)
            model.videoPreview[clip.id] = properties
        }
    }

    private func commitTransform(_ change: @escaping (inout Transform, Double) -> Void) -> (Double) -> Void {
        { value in
            var transform = (clip.video ?? VideoProperties()).transform
            change(&transform, value)
            model.apply(InspectorEdits.transform(clip.id, transform, label: "Transform"))
        }
    }
}

/// Position in canvas pixels, typed like the design's "x 1580 · y 870".
private struct PositionRow: View {
    let model: EditorModel
    let clip: Clip
    let transform: Transform
    let canvas: CGSize

    var body: some View {
        HStack(spacing: 10) {
            Text("Position")
                .font(.ui(12))
                .foregroundStyle(Theme.textMuted.color)
                .frame(width: 86, alignment: .leading)
            NumberField(prefix: "x", value: transform.position.x * canvas.width) { x in
                var next = transform
                next.position.x = x / canvas.width
                model.apply(InspectorEdits.transform(clip.id, next, label: "Position"))
            }
            Text("·").foregroundStyle(Theme.textFaint.color)
            NumberField(prefix: "y", value: transform.position.y * canvas.height) { y in
                var next = transform
                next.position.y = y / canvas.height
                model.apply(InspectorEdits.transform(clip.id, next, label: "Position"))
            }
            Spacer(minLength: 0)
        }
    }
}

/// A number that turns into a text field on click.
struct NumberField: View {
    let prefix: String
    let value: Double
    let commit: (Double) -> Void
    @State private var text = ""
    @State private var editing = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(prefix).font(.ui(12)).foregroundStyle(Theme.textMuted.color)
            if editing {
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .font(.ui(12).monospacedDigit())
                    .foregroundStyle(Theme.text.color)
                    .frame(width: 46)
                    .focused($focused)
                    .onSubmit(finish)
                    .onChange(of: focused) { _, now in if !now { finish() } }
            } else {
                Text(verbatim: String(Int(value.rounded())))
                    .font(.ui(12).monospacedDigit())
                    .foregroundStyle(Theme.text.color)
                    .onTapGesture {
                        text = "\(Int(value.rounded()))"
                        editing = true
                        focused = true
                    }
            }
        }
    }

    private func finish() {
        guard editing else { return }
        editing = false
        if let number = Double(text.trimmingCharacters(in: .whitespaces)), abs(number - value) > 0.01 { commit(number) }
    }
}

// MARK: - Audio

struct AudioInspector: View {
    let model: EditorModel
    let clip: Clip

    /// The sound this tab edits: the clip itself on an audio track, or the
    /// audio clips linked to a video clip.
    private var targets: [Clip] {
        if model.project.location(ofClip: clip.id)?.track.kind == .audio {
            let selectedAudio = TimelineEdits.ordered(model.selection, in: model.project).filter { model.project.location(ofClip: $0)?.track.kind == .audio }
            return (selectedAudio.isEmpty ? [clip.id] : selectedAudio).compactMap { model.project.clip($0) }
        }
        return model.project.linkedClipIDs(of: clip.id).filter { model.project.location(ofClip: $0)?.track.kind == .audio }.compactMap { model.project.clip($0) }
    }

    var body: some View {
        let targets = targets
        if let first = targets.first {
            let audio = first.audio ?? AudioProperties()
            let ids = targets.map(\.id)
            let noun = targets.count == 1 ? "clip" : "\(targets.count) clips"
            InspectorSection(title: "Level") {
                SliderRow(label: "Gain", value: audio.gainDB, range: -60...12, bipolar: true, valueWidth: 62,
                          format: { String(format: "%+.1f dB", $0).replacingOccurrences(of: "-", with: "−") },
                          parse: { Double($0.replacingOccurrences(of: "−", with: "-").filter { "-+0123456789.".contains($0) }) },
                          onCommit: { value in model.apply(InspectorEdits.audio(ids, ["gainDB": .number((value * 10).rounded() / 10)], label: "Gain")) })
                HStack(spacing: 10) {
                    Text("Muted")
                        .font(.ui(12))
                        .foregroundStyle(Theme.textMuted.color)
                        .frame(width: 86, alignment: .leading)
                    Text(audio.muted ? "Yes" : "No")
                        .font(.ui(12))
                        .foregroundStyle(Theme.text.color)
                    Spacer()
                    GraphiteSwitch(isOn: audio.muted) {
                        model.apply(InspectorEdits.audio(ids, ["muted": .bool(!audio.muted)], label: audio.muted ? "Unmute \(noun)" : "Mute \(noun)"))
                    }
                }
                HStack(spacing: 10) {
                    Text("Normalise")
                        .font(.ui(12))
                        .foregroundStyle(Theme.textMuted.color)
                        .frame(width: 86, alignment: .leading)
                    Text(audio.normalizeTo.map { String(format: "to %.0f LUFS", $0).replacingOccurrences(of: "-", with: "−") } ?? "Off")
                        .font(.ui(12))
                        .foregroundStyle(Theme.text.color)
                    Spacer()
                    GraphiteSwitch(isOn: audio.normalizeTo != nil) {
                        let value: JSONValue = audio.normalizeTo == nil ? .number(model.project.settings.loudnessTarget) : .null
                        model.apply(InspectorEdits.audio(ids, ["normalizeTo": value], label: audio.normalizeTo == nil ? "Normalise" : "Stop normalising"))
                    }
                }
                if let item = model.media(for: first), let loudness = model.session.analysis.loudness(for: item) {
                    InfoRow(label: "Measured", value: String(format: "%.1f LUFS · peak %.1f dBTP", loudness.integratedLUFS, loudness.truePeakDBTP).replacingOccurrences(of: "-", with: "−"))
                }
            }
            InspectorSection(title: "Fades") {
                SliderRow(label: "Fade in", value: audio.fadeIn.seconds, range: 0...min(5, first.duration.seconds), format: { String(format: "%.1f s", $0) },
                          onCommit: { value in model.apply(InspectorEdits.audio(ids, ["fadeIn": .number(value)], label: "Fade in")) })
                SliderRow(label: "Fade out", value: audio.fadeOut.seconds, range: 0...min(5, first.duration.seconds), format: { String(format: "%.1f s", $0) },
                          onCommit: { value in model.apply(InspectorEdits.audio(ids, ["fadeOut": .number(value)], label: "Fade out")) })
            }
            InspectorSection(title: "Voice isolation") {
                SliderRow(label: "Amount", value: audio.voiceIsolation * 100, range: 0...100, format: { "\(Int($0.rounded()))%" },
                          onCommit: { value in model.apply(InspectorEdits.audio(ids, ["voiceIsolation": .number(value / 100)], label: "Voice isolation")) })
                Text("Mixes in the isolated voice once the media module has made it.")
                    .font(.ui(11))
                    .foregroundStyle(Theme.textFaint.color)
            }
            EffectStack(model: model, clip: first, domain: .audio, excludeCategories: [])
        } else {
            Text("This clip has no sound on the timeline.")
                .font(.ui(12))
                .foregroundStyle(Theme.textMuted.color)
                .padding(16)
        }
    }
}

// MARK: - Info

struct ClipInfo: View {
    let model: EditorModel
    let clip: Clip

    var body: some View {
        let rate = model.frameRate
        let item = model.media(for: clip)
        InspectorSection(title: "Clip") {
            InfoRow(label: "ID", value: clip.id)
            InfoRow(label: "Starts", value: Timecode.string(clip.start, rate: rate))
            InfoRow(label: "Length", value: Timecode.string(clip.duration, rate: rate))
            if clip.mediaID != nil {
                InfoRow(label: "Media in", value: Timecode.string(clip.sourceStart, rate: rate))
                InfoRow(label: "Media out", value: Timecode.string(clip.sourceEnd, rate: rate))
            }
            HStack(spacing: 10) {
                Text("Speed")
                    .font(.ui(12))
                    .foregroundStyle(Theme.textMuted.color)
                    .frame(width: 86, alignment: .leading)
                Menu("\(Int((clip.speed * 100).rounded()))%") {
                    ForEach([0.5, 0.75, 1, 1.25, 1.5, 2], id: \.self) { speed in
                        Button("\(Int(speed * 100))%") {
                            model.apply(EditBatch(label: "Speed \(Int(speed * 100))%", commands: [.setSpeed(clipID: clip.id, speed: speed, ripple: true)]))
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer()
            }
            if let group = clip.linkGroup {
                InfoRow(label: "Linked", value: "\(model.project.linkedClipIDs(of: clip.id).count) clips (\(group))")
            }
            if !clip.tags.isEmpty {
                InfoRow(label: "Tags", value: clip.tags.joined(separator: ", "))
            }
        }
        if let item {
            InspectorSection(title: "Media", accessory: {
                OutlineButton(title: "Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([model.folder.url(for: item)])
                }
            }) {
                InfoRow(label: "File", value: item.path)
                InfoRow(label: "Role", value: item.role.rawValue)
                if let w = item.width, let h = item.height { InfoRow(label: "Size", value: "\(w) × \(h)") }
                if let fps = item.frameRate { InfoRow(label: "Frame rate", value: String(format: "%g fps%@", fps.framesPerSecond, item.variableFrameRate ? ", variable" : "")) }
                if let duration = item.duration { InfoRow(label: "Length", value: Timecode.string(duration, rate: rate)) }
                InfoRow(label: "Streams", value: [item.hasVideo ? "picture" : nil, item.hasAudio ? "sound" : nil, item.hasAlpha ? "alpha" : nil].compactMap { $0 }.joined(separator: ", "))
                if let take = item.takeID { InfoRow(label: "Take", value: take + (item.takeOffset.map { " · starts \(String(format: "%.3f", $0.seconds)) s in" } ?? "")) }
            }
        }
    }
}

// MARK: - Transitions

struct TransitionInspector: View {
    let model: EditorModel
    let transition: TandemCore.Transition
    let track: Track

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(transition.type.displayName) · \(track.name)")
                .font(.ui(13, .bold))
                .foregroundStyle(Theme.text.color)
            Text(transition.fromClipID != nil && transition.toClipID != nil ? "Between two clips" : "At a clip's \(transition.fromClipID == nil ? "start" : "end")")
                .font(.ui(11.5))
                .foregroundStyle(Theme.textMuted.color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border.color).frame(height: 1) }
        InspectorSection(title: "Transition") {
            HStack(spacing: 10) {
                Text("Type")
                    .font(.ui(12))
                    .foregroundStyle(Theme.textMuted.color)
                    .frame(width: 86, alignment: .leading)
                Menu(transition.type.displayName) {
                    ForEach(TransitionType.allCases, id: \.self) { type in
                        Button(type.displayName) { update(["type": .string(type.rawValue)], "Change transition") }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer()
            }
            if [.push, .slide, .wipe, .cutSlide].contains(transition.type) {
                HStack(spacing: 10) {
                    Text("Direction")
                        .font(.ui(12))
                        .foregroundStyle(Theme.textMuted.color)
                        .frame(width: 86, alignment: .leading)
                    GraphiteSegmented(options: [Direction.left, .right, .up, .down], selected: transition.direction ?? .left, title: { $0.rawValue.capitalized }) { direction in
                        update(["direction": .string(direction.rawValue)], "Transition direction")
                    }
                }
            }
            SliderRow(label: "Duration", value: transition.duration.seconds, range: 0.1...3, format: { String(format: "%.2f s", $0) }) { value in
                update(["duration": .number((value * 100).rounded() / 100)], "Transition length")
            }
            Button {
                model.apply(EditBatch(label: "Remove transition", commands: [.removeTransition(transitionID: transition.id)]))
            } label: {
                Text("Remove transition")
                    .font(.ui(11.5))
                    .foregroundStyle(Theme.red.color)
            }
            .buttonStyle(.plain)
        }
    }

    private func update(_ fields: [String: JSONValue], _ label: String) {
        model.apply(EditBatch(label: label, commands: [.updateTransition(transitionID: transition.id, patch: .object(fields))]))
    }
}

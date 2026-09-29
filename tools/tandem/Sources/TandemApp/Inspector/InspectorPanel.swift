import AppKit
import SwiftUI
import TandemCore
import TandemMedia
import TandemRender

/// The right panel: the selected clip's Video, Colour, Audio and Info, and
/// the activity feed.
struct InspectorPanel: View {
    let model: EditorModel
    let actions: EditorActions

    /// Whether the clip tabs have a clip to show. Without one (nothing
    /// selected, or a transition) they're dimmed and don't switch, since
    /// the panel shows the project or the transition whichever is chosen.
    private var hasClip: Bool {
        model.primaryClipID.flatMap { model.project.clip($0) } != nil
    }

    var body: some View {
        let hasClip = hasClip
        VStack(spacing: 0) {
            // Icons and titles when they fit, icons alone (and the chosen
            // tab's title) in a narrow inspector.
            ViewThatFits(in: .horizontal) {
                tabRow(hasClip: hasClip, compact: false)
                tabRow(hasClip: hasClip, compact: true)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
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

    private func tabRow(hasClip: Bool, compact: Bool) -> some View {
        HStack(spacing: compact ? 14 : 16) {
            ForEach(InspectorTab.allCases) { tab in
                let available = tab == .activity || hasClip
                InspectorTabButton(
                    tab: tab, selected: available && model.inspectorTab == tab, available: available,
                    showsTitle: !compact || (available && model.inspectorTab == tab)
                ) { model.inspectorTab = tab }
            }
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: true, vertical: false)
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
    /// False for the clip tabs while there's no clip to show.
    let available: Bool
    let showsTitle: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: Icons.tab(tab))
                    .font(.system(size: 11, weight: selected ? .semibold : .regular))
                if showsTitle {
                    Text(tab.title)
                        .font(.ui(12, selected ? .semibold : .regular))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(selected ? Theme.text.color : Theme.textFaint.color)
            .opacity(available ? 1 : 0.4)
            .padding(.bottom, 2)
            .overlay(alignment: .bottom) {
                if selected { Rectangle().fill(Theme.amber.color).frame(height: 2).offset(y: 2) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .help(help)
    }

    private var help: String {
        guard available else { return "Select a clip on the timeline to see its \(tab.title.lowercased()) settings" }
        switch tab {
        case .video: return "Video: layout, position, cutout, crop and effects"
        case .colour: return "Colour: the take's look and this clip's colour"
        case .audio: return "Audio: level, fades, voice isolation and effects"
        case .info: return "Info: the clip's times and its media file"
        case .activity: return "Activity: every edit, yours and agents'"
        }
    }
}

/// The clip's name, "Take 2" or "Take 2 and 3 more". Where it is and
/// what it's linked to are in the Info tab.
struct ClipHeader: View {
    let model: EditorModel
    let clip: Clip

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.ui(13, .bold))
                .foregroundStyle(Theme.text.color)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border.color).frame(height: 1) }
    }

    private var title: String {
        let name = ClipRenderer.name(of: clip, in: model.project)
        let count = model.selection.count
        return count > 1 ? "\(name) and \(count - 1) more" : name
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
                HStack(spacing: 6) {
                    PanelIcon(name: Icons.selectAClip, color: Theme.amber.color)
                    Text("Select a clip to edit it.")
                        .font(.ui(11.5))
                        .foregroundStyle(Theme.textMuted.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border.color).frame(height: 1) }
            InspectorSection(title: "Project", icon: Icons.project) {
                InfoRow(label: "Canvas", value: "\(settings.width) × \(settings.height)")
                InfoRow(label: "Frame rate", value: String(format: "%g fps", settings.frameRate.framesPerSecond))
                InfoRow(label: "Loudness", value: String(format: "%.0f LUFS, peaks under %.0f dBTP", settings.loudnessTarget, settings.truePeakCeiling).replacingOccurrences(of: "-", with: "−"))
                InfoRow(label: "Length", value: Timecode.string(model.project.duration, rate: model.frameRate))
                InfoRow(label: "Media", value: "\(model.project.media.count) files")
            }
            InspectorSection(title: "Keys", icon: Icons.keys) {
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

    /// What the clip looks like at the playhead: animated values follow it.
    private var video: VideoProperties {
        if let preview = model.videoPreview[clip.id] { return preview }
        guard !clip.keyframes.isEmpty else { return clip.video ?? VideoProperties() }
        return clip.resolvedVideo(at: model.clipTime(of: clip))
    }
    private var isVideo: Bool { model.project.location(ofClip: clip.id)?.track.kind == .video }
    private var canvas: CGSize { CGSize(width: model.project.settings.width, height: model.project.settings.height) }

    var body: some View {
        if !isVideo {
            Text("This clip is sound only. Its settings are on the Audio tab.")
                .font(.ui(12))
                .foregroundStyle(Theme.textMuted.color)
                .padding(16)
        } else {
            if case .text(let text) = clip.content {
                TextSection(model: model, clip: clip, text: text)
            }
            if let card = SectionCard.props(of: clip) {
                SectionCardSection(model: model, clip: clip, props: card)
            }
            AnimationSection(model: model, clip: clip, domain: "video.")
            layoutSection
            if clip.mediaID != nil { cutoutSection }
            cropSection
            EffectStack(model: model, clip: clip, domain: .video, excludeCategories: ["Colour"])
        }
    }

    private var layoutSection: some View {
        InspectorSection(title: "Layout", icon: Icons.layoutSection) {
            GraphiteSegmented(
                options: LayoutPreset.allCases,
                selected: video.layoutPreset.flatMap(LayoutPreset.init(rawValue:)),
                title: { preset in
                    switch preset {
                    case .full: return "Full"
                    case .pipRight: return "PiP right"
                    case .pipLeft: return "PiP left"
                    case .split: return "Split"
                    case .fill: return "Fill"
                    }
                },
                icon: Icons.layout,
                help: { preset in
                    switch preset {
                    case .full: return "Full: the picture fills the frame (1)"
                    case .pipRight: return "Picture in picture, bottom right, with the cutout (2)"
                    case .pipLeft: return "Picture in picture, bottom left, with the cutout (3)"
                    case .split: return "Split: side by side (4)"
                    case .fill: return "Fill: scaled up to fill the frame, edges cropped"
                    }
                },
                action: { preset in
                    model.apply(TimelineEdits.applyLayout(model.project, preset: preset, playhead: model.playback.time, selection: model.selection.isEmpty ? [clip.id] : model.selection))
                }
            )
            SliderRow(label: "Scale", value: video.transform.scale * 100, range: 0...400, format: { "\(Int($0.rounded()))%" },
                      defaultValue: 100, help: "How big the picture is. 100% fits it inside the frame; 50% is the PiP size.",
                      onPreview: preview { properties, value in properties.transform.scale = (value ?? 0) / 100 },
                      accessory: key("video.transform.scale"),
                      onCommit: { value in
                          commit("video.transform.scale", .number(value / 100), label: "Scale", plain: commitTransform { transform in transform.scale = value / 100 })
                      })
            PositionRow(model: model, clip: clip, transform: video.transform, canvas: canvas) { position in
                commit("video.transform.position", .point(position), label: "Position", plain: commitTransform { transform in transform.position = position })
            }
            SliderRow(label: "Rotation", value: video.transform.rotation, range: -180...180, bipolar: true, format: { "\(Int($0.rounded()))°" },
                      help: "Turns the picture about its centre, clockwise.",
                      onPreview: preview { properties, value in properties.transform.rotation = value ?? 0 },
                      accessory: key("video.transform.rotation"),
                      onCommit: { value in
                          commit("video.transform.rotation", .number(value), label: "Rotation", plain: commitTransform { transform in transform.rotation = value })
                      })
            SliderRow(label: "Opacity", value: video.opacity * 100, range: 0...100, format: { "\(Int($0.rounded()))%" },
                      defaultValue: 100, help: "How solid the clip is. 0% lets everything underneath show through.",
                      onPreview: preview { properties, value in properties.opacity = (value ?? 0) / 100 },
                      accessory: key("video.opacity"),
                      onCommit: { value in
                          commit("video.opacity", .number(value / 100), label: "Opacity") { InspectorEdits.video(clip.id, ["opacity": .number(value / 100)], label: "Opacity") }
                      })
        }
    }

    /// The keyframe diamond for a parameter.
    private func key(_ parameter: String) -> AnyView {
        AnyView(KeyframeButton(model: model, clip: clip, parameter: parameter))
    }

    /// Sets a parameter at the playhead when it's animated, or its plain
    /// value when it isn't.
    private func commit(_ parameter: String, _ value: ParamValue, label: String, plain: () -> EditBatch?) {
        model.setParameter(parameter, to: value, in: clip, label: label, plain: plain)
    }

    private var cutoutSection: some View {
        let cutout = video.cutout
        let enabled = cutout?.enabled == true
        let shadow = video.effects.first { $0.type == "dropShadow" }
        return InspectorSection(title: "Portrait cutout", icon: Icons.cutout, accessory: {
            GraphiteSwitch(isOn: enabled) {
                model.apply(InspectorEdits.video(clip.id, ["cutout": .object(["enabled": .bool(!enabled)])], label: enabled ? "Cutout off" : "Cutout on"))
            }
        }) {
            SliderRow(label: "Edge", value: cutout?.edgeFeather ?? 2, range: 0...20, format: { String(format: "%.0f px", $0) },
                      defaultValue: 2, help: "Softens the cutout's edge, in pixels, so hair and shoulders don't look cut with scissors.",
                      onCommit: { value in model.apply(InspectorEdits.video(clip.id, ["cutout": .object(["edgeFeather": .number(value)])], label: "Cutout edge")) })
            HStack(spacing: 10) {
                Text("Keep mic")
                    .font(.ui(12))
                    .foregroundStyle(Theme.textMuted.color)
                    .frame(width: 86, alignment: .leading)
                let keeps = (cutout?.mode ?? .personAndProps) == .personAndProps
                Spacer()
                GraphiteSwitch(isOn: keeps) {
                    model.apply(InspectorEdits.video(clip.id, ["cutout": .object(["mode": .string(keeps ? CutoutMode.person.rawValue : CutoutMode.personAndProps.rawValue)])], label: keeps ? "Cutout without props" : "Cutout keeps the mic"))
                }
            }
            SliderRow(label: "Shadow", value: shadow?.params["opacity"]?.number ?? (shadow == nil ? 0 : 60), range: 0...100, format: { "\(Int($0.rounded()))%" },
                      help: "How dark the drop shadow behind the cutout is. 0% is no shadow.",
                      onCommit: { value in model.apply(InspectorEdits.shadowOpacity(clip, percent: value)) })
        }
        .opacity(enabled ? 1 : 0.75)
    }

    private var cropSection: some View {
        InspectorSection(title: "Crop", icon: Icons.crop) {
            ForEach(["left", "top", "right", "bottom"], id: \.self) { edge in
                SliderRow(label: edge.capitalized, value: value(of: edge) * 100, range: 0...50, format: { "\(Int($0.rounded()))%" },
                          defaultValue: 0, help: "Trims the \(edge) edge off the picture, as a share of its size.",
                          onPreview: { value in
                              var preview = video
                              if let value { set(edge, value / 100, in: &preview.crop) }
                              model.videoPreview[clip.id] = value == nil ? nil : preview
                          },
                          accessory: key("video.crop.\(edge)"),
                          onCommit: { value in
                              var crop = (clip.video ?? VideoProperties()).crop
                              set(edge, value / 100, in: &crop)
                              commit("video.crop.\(edge)", .number(value / 100), label: "Crop") { InspectorEdits.crop(clip.id, crop) }
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

    /// Live viewer preview while a slider moves; nil clears it. It starts
    /// from the clip as it is at the playhead, so animated values hold.
    private func preview(_ change: @escaping (inout VideoProperties, Double?) -> Void) -> (Double?) -> Void {
        { value in
            guard let value else {
                model.videoPreview[clip.id] = nil
                return
            }
            var properties = clip.keyframes.isEmpty ? (clip.video ?? VideoProperties()) : clip.resolvedVideo(at: model.clipTime(of: clip))
            change(&properties, value)
            model.videoPreview[clip.id] = properties
        }
    }

    /// The plain transform patch, for parameters that aren't animated.
    private func commitTransform(_ change: @escaping (inout Transform) -> Void) -> () -> EditBatch? {
        {
            var transform = (clip.video ?? VideoProperties()).transform
            change(&transform)
            return InspectorEdits.transform(clip.id, transform, label: "Transform")
        }
    }
}

/// Position in canvas pixels, typed like the design's "x 1580 · y 870".
private struct PositionRow: View {
    let model: EditorModel
    let clip: Clip
    let transform: Transform
    let canvas: CGSize
    let commit: (Point) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text("Position")
                .font(.ui(12))
                .foregroundStyle(Theme.textMuted.color)
                .frame(width: 86, alignment: .leading)
            NumberField(prefix: "x", value: transform.position.x * canvas.width) { x in
                commit(Point(x: x / canvas.width, y: transform.position.y))
            }
            Text("·").foregroundStyle(Theme.textFaint.color)
            NumberField(prefix: "y", value: transform.position.y * canvas.height) { y in
                commit(Point(x: transform.position.x, y: y / canvas.height))
            }
            Spacer(minLength: 0)
            KeyframeButton(model: model, clip: clip, parameter: "video.transform.position")
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
            AnimationSection(model: model, clip: first, domain: "audio.")
            LevelSection(model: model, targets: targets)
            SpeechLevelSection(model: model)
            InspectorSection(title: "Fades", icon: Icons.fades) {
                SliderRow(label: "Fade in", value: audio.fadeIn.seconds, range: 0...min(5, first.duration.seconds), format: { String(format: "%.1f s", $0) },
                          defaultValue: 0, help: "How long the sound takes to come up from silence at the clip's start (an equal-power curve).",
                          onCommit: { value in model.apply(InspectorEdits.audio(ids, ["fadeIn": .number(value)], label: "Fade in")) })
                SliderRow(label: "Fade out", value: audio.fadeOut.seconds, range: 0...min(5, first.duration.seconds), format: { String(format: "%.1f s", $0) },
                          defaultValue: 0, help: "How long the sound takes to go down to silence at the clip's end (an equal-power curve).",
                          onCommit: { value in model.apply(InspectorEdits.audio(ids, ["fadeOut": .number(value)], label: "Fade out")) })
            }
            InspectorSection(title: "Voice isolation", icon: Icons.voiceIsolation) {
                SliderRow(label: "Amount", value: audio.voiceIsolation * 100, range: 0...100, format: { "\(Int($0.rounded()))%" },
                          defaultValue: 0, help: "How much of the isolated voice (room noise and music taken out) replaces the original sound. 0% is the original.",
                          onCommit: { value in model.apply(InspectorEdits.audio(ids, ["voiceIsolation": .number(value / 100)], label: "Voice isolation")) })
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
        InspectorSection(title: "Clip", icon: Icons.clip) {
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
            InspectorSection(title: "Media", icon: Icons.media, accessory: {
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
                if let codec = item.undecodableCodecName { InfoRow(label: "Codec", value: conversionText(codec, item)) }
                if let take = item.takeID { InfoRow(label: "Take", value: take + (item.takeOffset.map { " · starts \(String(format: "%.3f", $0.seconds)) s in" } ?? "")) }
            }
        }
    }

    /// macOS can't decode QuickTime Animation or PNG video, so Tandem plays
    /// a converted copy; says how that's going.
    private func conversionText(_ codec: String, _ item: MediaItem) -> String {
        if model.session.analysis.convertedURL(for: item) != nil { return "\(codec) · plays from an HEVC copy" }
        let job = model.jobs.last { $0.mediaID == item.id && $0.kind == .converted }
        if job?.state == .failed { return "\(codec) · can't convert: \(job?.message ?? "unknown error")" }
        return "\(codec) · converting to HEVC"
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
        InspectorSection(title: "Transition", icon: Icons.transition) {
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
            SliderRow(label: "Duration", value: transition.duration.seconds, range: 0.1...3, format: { String(format: "%.2f s", $0) },
                      defaultValue: transition.type.defaultDuration.seconds, help: "How long the transition takes.") { value in
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

/// A text clip's words and look. Edits patch `content.text`. The style
/// rows show what the title is drawn with. A row the clip sets itself,
/// rather than taking from its preset, has an amber label and a button
/// that goes back to the preset's value.
private struct TextSection: View {
    let model: EditorModel
    let clip: Clip
    let text: TextContent
    @State private var draft = ""
    @FocusState private var editing: Bool

    /// What the title is drawn with.
    private var style: TextStyle.Resolved { TitlePresets.style(for: text) }
    /// What it would be drawn with if the clip set nothing itself.
    private var base: TextStyle.Resolved { TitlePresets.presetStyle(text.preset) }
    private var own: TextStyle { text.style }
    private var presetName: String? { TitlePresets.preset(text.preset)?.name }

    var body: some View {
        InspectorSection(title: "Text", icon: Icons.text) {
            TextEditor(text: $draft)
                .font(.ui(12.5))
                .foregroundStyle(Theme.text.color)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.never)
                .frame(height: 64)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.field.color))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.fieldBorder.color, lineWidth: 1))
                .focused($editing)
                .onAppear { draft = text.text }
                .onChange(of: text.text) { _, new in if !editing { draft = new } }
                .onChange(of: editing) { _, now in if !now { commitText() } }
            Text(presetName.map { "Changes apply when you click away. The \($0) preset styles this title; amber settings are this clip's own." }
                 ?? "Changes apply when you click away.")
                .font(.ui(11))
                .foregroundStyle(Theme.textFaint.color)
                .fixedSize(horizontal: false, vertical: true)
            fontRow
            SliderRow(
                label: "Size", value: style.size, range: 12...240, format: { String(format: "%.0f pt", $0) },
                accessory: resetAccessory(["size"], own.size != nil, String(format: "%.0f pt", base.size)), marked: own.size != nil
            ) { value in
                set(["size": .number(value.rounded())], "Text size")
            }
            SliderRow(
                label: "Weight", value: style.weight, range: 100...900, format: { String(format: "%.0f", $0) },
                accessory: resetAccessory(["weight"], own.weight != nil, String(format: "%.0f", base.weight)), marked: own.weight != nil
            ) { value in
                set(["weight": .number((value / 100).rounded() * 100)], "Text weight")
            }
            colourRow("Colour", field: "color", value: style.color, preset: base.color, opacity: false)
            SliderRow(
                label: "Outline", value: style.hasOutline ? style.strokeWidth : 0, range: 0...20,
                format: { $0 == 0 ? "None" : String(format: "%.0f pt", $0) }, step: 1,
                accessory: resetAccessory(["strokeWidth", "strokeColor"], own.strokeWidth != nil || own.strokeColor != nil, base.hasOutline ? String(format: "%.0f pt", base.strokeWidth) : "none"),
                marked: own.strokeWidth != nil || own.strokeColor != nil
            ) { value in
                set(TextStyleEdits.outline(width: value, current: style), value == 0 ? "No text outline" : "Text outline")
            }
            if style.hasOutline, let outline = style.strokeColor {
                colourRow("Outline colour", field: "strokeColor", value: outline, preset: base.strokeColor ?? .black, opacity: false)
            }
            HStack(spacing: 10) {
                label("Background", marked: own.backgroundColor != nil)
                ColorPicker("", selection: colourBinding(style.backgroundColor ?? RGBA(r: 0, g: 0, b: 0, a: 0)) {
                    set(["backgroundColor": ParamValue.color($0).json], "Text background")
                }, supportsOpacity: true)
                    .labelsHidden()
                if style.backgroundColor != nil {
                    OutlineButton(title: "None") { set(TextStyleEdits.noBackground(preset: base), "No text background") }
                }
                Spacer()
                resetButton(["backgroundColor"], own.backgroundColor != nil, base.backgroundColor == nil ? "no box" : "its box")
            }
            switchRow("Capitals", field: "uppercase", isOn: style.uppercase, preset: base.uppercase)
            switchRow("Shadow", field: "shadow", isOn: style.shadow, preset: base.shadow)
        }
    }

    /// The font's name, with a warning when this Mac can't draw it.
    private var fontRow: some View {
        HStack(spacing: 10) {
            label("Font", marked: own.font != nil)
            Text(style.font)
                .font(.ui(12))
                .foregroundStyle(Theme.text.color)
                .lineLimit(1)
                .truncationMode(.tail)
            if let missing = ProjectFonts.missing(for: text, clipID: clip.id) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.amber.color)
                    .help("Not installed, so it's drawn in SF Pro. Pick a font in the Fonts tab, or run: tandem assets use \(missing.assetID)")
            }
            Spacer()
            resetButton(["font"], own.font != nil, base.font)
        }
    }

    private func colourRow(_ title: String, field: String, value: RGBA, preset: RGBA, opacity: Bool) -> some View {
        let marked = field == "color" ? own.color != nil : own.strokeColor != nil
        return HStack(spacing: 10) {
            label(title, marked: marked)
            ColorPicker("", selection: colourBinding(value) { set([field: ParamValue.color($0).json], title == "Colour" ? "Text colour" : "Text outline colour") }, supportsOpacity: opacity)
                .labelsHidden()
            Spacer()
            resetButton([field], marked, Self.describe(preset))
        }
    }

    private func switchRow(_ title: String, field: String, isOn: Bool, preset: Bool) -> some View {
        let marked = field == "uppercase" ? own.uppercase != nil : own.shadow != nil
        return HStack(spacing: 10) {
            label(title, marked: marked)
            Spacer()
            GraphiteSwitch(isOn: isOn) { set([field: .bool(!isOn)], "\(isOn ? "No" : "Text") \(title.lowercased())") }
            resetButton([field], marked, preset ? "on" : "off")
        }
    }

    private func label(_ title: String, marked: Bool) -> some View {
        Text(title)
            .font(.ui(12))
            .foregroundStyle(marked ? Theme.amber.color : Theme.textMuted.color)
            .frame(width: SliderRow.labelWidth, alignment: .leading)
    }

    /// The button back to the preset's value, or the room it takes so the
    /// rows line up.
    private func resetButton(_ fields: [String], _ shown: Bool, _ presetValue: String) -> some View {
        Group {
            if shown {
                IconButton(symbol: Icons.reset, help: TextStyleEdits.resetHelp(preset: presetName, value: presetValue)) {
                    set(TextStyleEdits.reset(fields), "\(fields[0] == "strokeWidth" ? "Outline" : fields[0].capitalized) from the preset")
                }
            } else {
                Color.clear.frame(width: 18, height: 18)
            }
        }
    }

    private func resetAccessory(_ fields: [String], _ shown: Bool, _ presetValue: String) -> AnyView {
        AnyView(resetButton(fields, shown, presetValue))
    }

    private static func describe(_ colour: RGBA) -> String {
        String(format: "#%02X%02X%02X", Int((colour.r * 255).rounded()), Int((colour.g * 255).rounded()), Int((colour.b * 255).rounded()))
    }

    private func set(_ fields: [String: JSONValue], _ label: String) {
        patch(["style": .object(fields)], label)
    }

    private func commitText() {
        guard draft != text.text else { return }
        patch(["text": .string(draft)], "Edit text")
    }

    private func patch(_ fields: [String: JSONValue], _ label: String) {
        model.apply(EditBatch(label: label, commands: [
            .updateClip(clipID: clip.id, patch: .object(["content": .object(["text": .object(fields)])]))
        ]))
    }

    /// A colour binding that commits after the picker settles.
    private func colourBinding(_ value: RGBA, commit: @escaping (RGBA) -> Void) -> Binding<Color> {
        Binding(
            get: { Color(.sRGB, red: value.r, green: value.g, blue: value.b, opacity: value.a) },
            set: { colour in
                guard let converted = NSColor(colour).usingColorSpace(.sRGB) else { return }
                let rgba = RGBA(r: Double(converted.redComponent), g: Double(converted.greenComponent), b: Double(converted.blueComponent), a: Double(converted.alphaComponent))
                ColourCommitter.shared.schedule { commit(rgba) }
            }
        )
    }
}

/// Coalesces colour picker changes into one edit once the dragging stops.
@MainActor
final class ColourCommitter {
    static let shared = ColourCommitter()
    private var pending: DispatchWorkItem?

    func schedule(_ action: @escaping () -> Void) {
        pending?.cancel()
        let work = DispatchWorkItem(block: action)
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
}

import AppKit
import SwiftUI
import TandemCore

/// What the Colour tab grades: every clip from the file (its look, how
/// Mike grades a camera take) or just this clip, on top of that.
enum ColourTarget: String, CaseIterable, Hashable, Sendable {
    case take, clip
}

/// The Colour tab: a switch between the whole take and this clip, then
/// fixed sections in grading order (Light, Colour, Colour wheels, Colour
/// mixer, Vignette, Sharpen, LUT), each with an on/off switch, a reset and
/// a chevron. The sections are views onto the look's or the clip's
/// effects (`ColourGrade`); anything they don't cover is listed at the end
/// as it is.
///
/// Sections and controls are handed plain values and a `ColourEditor`,
/// not closures over a copy of the project, so SwiftUI can compare them
/// and redraw only what an edit changed: moving one slider redraws that
/// slider, not the thirty other controls.
struct ColourInspector: View {
    let model: EditorModel
    let clip: Clip
    /// Where the tab opens, instead of the default for the clip's media.
    var initialTarget: ColourTarget? = nil
    /// The target picked for a clip; a new clip starts on its default.
    @State private var picked: (clipID: String, target: ColourTarget)?

    var body: some View {
        if model.project.location(ofClip: clip.id)?.track.kind != .video {
            Text("Colour applies to picture. Select a video clip.")
                .font(.ui(12))
                .foregroundStyle(Theme.textMuted.color)
                .padding(16)
        } else {
            let item = model.media(for: clip)
            let target = target(for: item)
            let editor = ColourEditor(model: model, clipID: clip.id, target: target)
            let shown = ColourShown(model: model, clip: clip, item: item, target: target)
            VStack(alignment: .leading, spacing: 0) {
                if let item {
                    targetSwitch(item, target: target)
                } else if case .adjustment = clip.content {
                    caption("Grades everything under this adjustment layer.")
                }
                ForEach(ColourSection.allCases) { section in
                    ColourSectionView(section: section, state: shown.state(section), editor: editor)
                        .equatable()
                }
                OtherColourEffects(editor: editor, effects: shown.others, atPlayhead: shown.atPlayhead)
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
            if target == .take, !item.look.isEmpty {
                let others = ColourCopy.candidates(for: item, in: model.project)
                if !others.isEmpty { copyMenu(item, others: others) }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border.color).frame(height: 1) }
    }

    /// Copies this take's grade to the other files like it, one or all at
    /// once; files that have it already are ticked. When they all have it,
    /// a quiet line says so instead.
    @ViewBuilder
    private func copyMenu(_ item: MediaItem, others: [MediaItem]) -> some View {
        let missing = others.filter { !ColourCopy.hasSameLook($0, as: item) }
        let one = item.role == .camera ? "camera file" : "file like this"
        let many = item.role == .camera ? "camera files" : "files like this"
        if missing.isEmpty {
            Text(verbatim: others.count == 1 ? "The other \(one) has this grade too." : "The other \(others.count) \(many) have this grade too.")
                .font(.ui(11.5))
                .foregroundStyle(Theme.textFaint.color)
        } else {
            Menu {
                if others.count > 1 {
                    Button("All \(others.count) other \(many)", systemImage: Icons.wholeTake) {
                        copy(item, to: others)
                    }
                    Divider()
                }
                ForEach(others) { other in
                    let has = ColourCopy.hasSameLook(other, as: item)
                    Button(MediaCatalog.fileName(other), systemImage: has ? "checkmark" : Icons.thisClip) {
                        copy(item, to: [other])
                    }
                    .disabled(has)
                }
            } label: {
                Text("Copy grade to…")
                    .font(.ui(11.5))
                    .foregroundStyle(Theme.amber.color)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Give the other \(many) the same grade, replacing theirs")
        }
    }

    private func copy(_ item: MediaItem, to targets: [MediaItem]) {
        guard let source = model.project.media(item.id) else { return }
        let current = targets.compactMap { model.project.media($0.id) }
        guard let batch = ColourCopy.copy(from: source, to: current) else { return }
        model.apply(batch)
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
}

/// What the tab shows for its target, worked out once per redraw: the
/// grade, and for a clip with animated values, its effects at the
/// playhead.
@MainActor
struct ColourShown {
    let grade: ColourGrade
    /// The clip's effects at the playhead, when some are animated.
    let atPlayhead: [Effect]?
    let isLook: Bool

    init(model: EditorModel, clip: Clip, item: MediaItem?, target: ColourTarget) {
        if target == .take, let item {
            grade = ColourGrade(item.look)
            atPlayhead = nil
            isLook = true
        } else {
            let grade = ColourGrade(clip: clip)
            self.grade = grade
            // Reading the playhead makes the tab follow it, so only when
            // something here is animated.
            atPlayhead = grade.animated.isEmpty ? nil : clip.resolvedVideo(at: model.clipTime(of: clip)).effects
            isLook = false
        }
    }

    func state(_ section: ColourSection) -> ColourSectionState {
        let effect = grade.effect(section)
        return ColourSectionState(
            values: grade.values(section, shown: atPlayhead),
            hasEffect: effect != nil,
            isOn: grade.isOn(section),
            isChanged: grade.isChanged(section, shown: atPlayhead),
            diamond: isLook ? .none : (effect.map { .effect($0.id) } ?? .gap)
        )
    }

    /// Effects the sections don't show. A clip's other effects (a drop
    /// shadow, a blur) belong to the Video tab.
    var others: [Effect] {
        let all = grade.others
        guard !isLook else { return all }
        return all.filter { EffectRegistry.standard.definition($0.type)?.category == "Colour" }
    }
}

/// A section's part of the grade, as plain values.
struct ColourSectionState: Equatable, Sendable {
    var values: [String: ParamValue]
    var hasEffect: Bool
    var isOn: Bool
    var isChanged: Bool
    var diamond: ColourDiamond

    /// Something to turn off, or an effect that's off to turn back on.
    var canToggle: Bool { isChanged || !isOn }
}

/// What goes after a control for its keyframes.
enum ColourDiamond: Equatable, Sendable {
    /// Nothing: a look doesn't animate.
    case none
    /// A gap: a clip's section with no effect yet has nothing to animate,
    /// but its rows stay lined up with the others.
    case gap
    /// The diamond for a parameter of this effect.
    case effect(String)
}

/// Edits the tab's target: the file's look, or the clip's own effects,
/// where values that are animated become keyframes at the playhead.
///
/// It keeps no copy of the project. Each change starts from the clip and
/// the look as they are when it's made, so a control that hasn't redrawn
/// since the last edit can't write back an older grade.
struct ColourEditor: Equatable, Sendable {
    let model: EditorModel
    let clipID: String
    /// `.take` only for a clip with media.
    let target: ColourTarget

    nonisolated static func == (a: ColourEditor, b: ColourEditor) -> Bool {
        a.model === b.model && a.clipID == b.clipID && a.target == b.target
    }

    var isLook: Bool { target == .take }

    /// The clip, its media and the grade being edited, as they are now.
    @MainActor
    func current() -> (clip: Clip, item: MediaItem?, grade: ColourGrade)? {
        guard let clip = model.project.clip(clipID) else { return nil }
        let item = model.media(for: clip)
        if isLook, let item { return (clip, item, ColourGrade(item.look)) }
        return (clip, item, ColourGrade(clip: clip))
    }

    @MainActor
    func apply(_ make: (ColourGrade) -> ColourChange?) {
        guard let (clip, item, grade) = current(), let change = make(grade) else { return }
        if isLook, let item {
            model.apply(InspectorEdits.look(item.id, change.effects, label: "\(change.label) (whole take)"))
            return
        }
        let commands = ColourEdits.clipCommands(clip, change, at: model.clipTime(of: clip), tolerance: model.keyframeTolerance)
        guard !commands.isEmpty else { return }
        model.apply(EditBatch(label: change.label, commands: commands))
    }

    @MainActor
    func set(_ section: ColourSection, _ values: [String: ParamValue], label: String) {
        apply { $0.setting(section, values, label: label) }
    }

    @MainActor
    func toggle(_ section: ColourSection) {
        apply { $0.toggling(section) }
    }

    @MainActor
    func reset(_ section: ColourSection) {
        apply { $0.resetting(section) }
    }

    /// Shows values in the viewer while they're dragged, before they're
    /// committed; nil ends it. It goes through the viewer's drag preview
    /// (`model.videoPreview`), which the player draws from on every frame:
    /// a clip's own grade as part of the clip's properties, a look as a
    /// stand-in for the file's (`LiveVideoOverrides.setLooks`) that the
    /// clip's properties, unchanged, carry to the viewer. Either stays
    /// until the committed edit is on screen, so the picture doesn't flick
    /// back in between.
    @MainActor
    func preview(_ section: ColourSection, _ values: [String: ParamValue]?) {
        guard let values else {
            if model.videoPreview[clipID] != nil { model.videoPreview[clipID] = nil }
            return
        }
        guard let clip = model.project.clip(clipID) else { return }
        // From the clip as it is at the playhead, so animated values hold.
        // A drag back to where it started changes nothing, and shows that.
        var video = clip.resolvedVideo(at: model.clipTime(of: clip))
        if isLook, let item = model.media(for: clip) {
            let change = ColourGrade(item.look).setting(section, values, label: "", newID: { "fx_preview" })
            model.playback.liveOverrides.setLooks([item.id: change?.effects ?? item.look])
        } else if let change = ColourGrade(video.effects).setting(section, values, label: "", newID: { "fx_preview" }) {
            video.effects = change.effects
        }
        model.videoPreview[clipID] = video
    }

    /// The keyframe diamond after a control, its gap, or nothing for a
    /// look. One diamond can key several parameters (a wheel's three).
    @MainActor
    func diamond(_ diamond: ColourDiamond, keys: [String], name: String) -> AnyView? {
        switch diamond {
        case .none:
            return nil
        case .gap:
            return AnyView(Color.clear.frame(width: 16, height: 18))
        case .effect(let effectID):
            return AnyView(ColourKeyframeDiamond(model: model, clipID: clipID, parameters: keys.map { ColourEdits.path(effectID, $0) }, name: name))
        }
    }
}

/// One section, header and controls, redrawn only when its own values,
/// its on/off state or the target change.
struct ColourSectionView: View, Equatable {
    let section: ColourSection
    let state: ColourSectionState
    let editor: ColourEditor
    @AppStorage("colourCollapsedSections", store: AppDefaults.store) private var collapsedList = "lut"

    nonisolated static func == (a: ColourSectionView, b: ColourSectionView) -> Bool {
        a.section == b.section && a.state == b.state && a.editor == b.editor
    }

    private var expanded: Bool {
        !collapsedList.split(separator: ",").contains { $0 == section.rawValue }
    }

    private func toggleCollapsed() {
        var collapsed = Set(collapsedList.split(separator: ",").map(String.init))
        if collapsed.contains(section.rawValue) { collapsed.remove(section.rawValue) } else { collapsed.insert(section.rawValue) }
        collapsedList = ColourSection.allCases.map(\.rawValue).filter(collapsed.contains).joined(separator: ",")
    }

    var body: some View {
        let expanded = expanded
        ColourSectionBlock(
            section: section,
            hasEffect: state.hasEffect,
            isOn: state.isOn,
            isChanged: state.isChanged,
            canToggle: state.canToggle,
            summary: expanded || !state.isChanged ? "" : ColourSummary.text(section, state.values),
            expanded: expanded,
            toggleExpanded: toggleCollapsed,
            toggle: { editor.toggle(section) },
            reset: { editor.reset(section) }
        ) {
            switch section {
            case .wheels:
                ColourWheelsPanel(values: state.values, diamond: state.diamond, editor: editor)
            case .mixer:
                ColourMixerPanel(values: state.values, diamond: state.diamond, editor: editor)
            case .lut:
                LUTPanel(values: state.values, diamond: state.diamond, editor: editor)
                    .equatable()
            default:
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(ColourSliderSpec.specs(section), id: \.key) { spec in
                        ColourSliderRow(spec: spec, section: section, value: state.values[spec.key]?.number ?? 0, diamond: state.diamond, editor: editor)
                            .equatable()
                    }
                }
            }
        }
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

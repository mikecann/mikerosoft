import Foundation
import TandemCore

/// Keyframe editing shared by the timeline, the inspector and the viewer.
extension EditorModel {
    /// Keyframes within half a frame count as at the same time.
    var keyframeTolerance: Time { KeyframeEdits.tolerance(frameRate) }

    /// The playhead as a time inside a clip, kept inside it.
    func clipTime(of clip: Clip) -> Time {
        min(max(playback.time - clip.start, .zero), clip.duration)
    }

    /// Sets a parameter at the playhead: the keyframe there when it's
    /// animated (added if there isn't one), else the plain value through
    /// `plain`.
    @discardableResult
    func setParameter(_ parameter: String, to value: ParamValue, in clip: Clip, label: String, plain: () -> EditBatch?) -> Bool {
        if let command = KeyframeEdits.setValue(value, for: parameter, in: clip, at: clipTime(of: clip), tolerance: keyframeTolerance) {
            return apply(EditBatch(label: label, commands: [command])) != nil
        }
        return apply(plain()) != nil
    }

    /// The diamond next to a control: removes the parameter's keyframe at
    /// the playhead, or adds one holding its current value.
    func toggleKeyframe(_ parameter: String, in clip: Clip) {
        let time = clipTime(of: clip)
        let name = KeyframeEdits.name(of: parameter, in: clip).lowercased()
        if !KeyframeEdits.parameters(in: clip, keyedAt: time, tolerance: keyframeTolerance, among: [parameter]).isEmpty {
            apply(EditBatch(label: "Remove \(name) keyframe", commands: KeyframeEdits.removeKeyframes(in: clip, at: time, parameters: [parameter], tolerance: keyframeTolerance)))
        } else if let command = KeyframeEdits.addKeyframe(parameter, in: clip, at: time, tolerance: keyframeTolerance) {
            let label = KeyframeEdits.isAnimated(parameter, in: clip) ? "Add \(name) keyframe" : "Animate \(name)"
            apply(EditBatch(label: label, commands: [command] + KeyframeEdits.layoutCleared(for: [parameter], in: clip)))
        }
    }

    /// Option-K on the clip the inspector shows.
    @discardableResult
    func toggleKeyframes() -> Bool {
        guard let id = primaryClipID, let clip = project.clip(id), let kind = project.location(ofClip: id)?.track.kind else {
            show(.info, "Select a clip, or put the playhead over one, to add a keyframe.")
            return false
        }
        guard let batch = KeyframeEdits.toggle(in: clip, at: clipTime(of: clip), trackKind: kind, tolerance: keyframeTolerance) else { return false }
        guard apply(batch) != nil else { return false }
        if let updated = project.clip(id) {
            let parameters = KeyframeEdits.parameters(in: updated, keyedAt: clipTime(of: updated), tolerance: keyframeTolerance)
            selectedKeyframe = parameters.isEmpty ? nil : KeyframeRef(clipID: id, time: clipTime(of: updated), parameters: parameters)
            show(.info, parameters.isEmpty ? "Removed the keyframe." : "Keyframe on \(KeyframeEdits.summary(of: parameters, in: updated).lowercased()).")
        }
        return true
    }

    /// Moves the playhead to the primary clip's next or previous keyframe.
    @discardableResult
    func seekKeyframe(forward: Bool) -> Bool {
        guard let id = primaryClipID, let clip = project.clip(id) else { return false }
        let time = forward
            ? KeyframeEdits.next(after: playback.time, in: clip, tolerance: keyframeTolerance)
            : KeyframeEdits.previous(before: playback.time, in: clip, tolerance: keyframeTolerance)
        guard let time else { return false }
        playback.pause()
        playback.seek(to: time)
        return true
    }

    /// Delete with a keyframe chosen on the timeline.
    @discardableResult
    func deleteSelectedKeyframe() -> Bool {
        guard let keyframe = selectedKeyframe, let clip = project.clip(keyframe.clipID) else { return false }
        let commands = KeyframeEdits.removeKeyframes(in: clip, at: keyframe.time, parameters: keyframe.parameters, tolerance: keyframeTolerance)
        guard !commands.isEmpty else { return false }
        selectedKeyframe = nil
        return apply(EditBatch(label: "Remove keyframe", commands: commands)) != nil
    }

    /// Changes the easing of the keyframes at a time on a clip.
    func setEasing(_ interpolation: Interpolation, in clip: Clip, at time: Time, parameters: [String]) {
        let commands = KeyframeEdits.setEasing(interpolation, in: clip, at: time, parameters: parameters, tolerance: keyframeTolerance)
        guard !commands.isEmpty else { return }
        apply(EditBatch(label: "Keyframe easing", commands: commands))
    }
}

extension Interpolation {
    /// Sentence-case names for menus.
    var displayName: String {
        switch self {
        case .linear: return "Linear"
        case .easeIn: return "Ease in"
        case .easeOut: return "Ease out"
        case .easeInOut: return "Ease in and out"
        case .hold: return "Hold"
        }
    }

    static let menuOrder: [Interpolation] = [.easeInOut, .easeIn, .easeOut, .linear, .hold]
}

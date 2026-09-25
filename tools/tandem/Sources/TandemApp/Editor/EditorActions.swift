import AppKit
import TandemCore

/// Carries out editor commands from keys, menus, buttons and the
/// `tandem://` URL scheme. Edits are built by `TimelineEdits` and applied
/// through the model; this class decides what each command acts on (the
/// selection, the playhead, the in and out points).
@MainActor
final class EditorActions {
    unowned let model: EditorModel
    weak var controller: ProjectWindowController?

    init(model: EditorModel) {
        self.model = model
    }

    private var project: Project { model.project }
    private var playback: PlaybackController { model.playback }
    private var playhead: Time { model.playback.time }

    func tool(for command: EditorCommand) -> TimelineTool? {
        switch command {
        case .toolSelect: return .select
        case .toolBlade: return .blade
        case .toolRippleTrim: return .rippleTrim
        case .toolRoll: return .roll
        case .toolSlip: return .slip
        case .toolSlide: return .slide
        default: return nil
        }
    }

    /// Whether a menu item for `command` should be enabled.
    func canPerform(_ command: EditorCommand) -> Bool {
        switch command {
        case .undo: return model.undoLabel != nil
        case .redo: return model.redoLabel != nil
        case .lift, .rippleDelete: return !model.selection.isEmpty || model.selectedTransitionID != nil || model.selectedKeyframe != nil
        case .nudgeLeft, .nudgeRight, .nudgeLeftFive, .nudgeRightFive, .link, .deselectAll: return !model.selection.isEmpty
        case .liftInOut, .extractInOut: return model.inOutRange != nil
        default: return true
        }
    }

    /// Runs `command`. Returns false when there was nothing to act on.
    @discardableResult
    func perform(_ command: EditorCommand) -> Bool {
        switch command {
        // Transport
        case .playPause: playback.togglePlay()
        case .shuttleReverse: playback.shuttleReverse()
        case .shuttleStop: playback.pause()
        case .shuttleForward: playback.shuttleForward()
        case .stepBack: playback.step(frames: -1)
        case .stepForward: playback.step(frames: 1)
        case .stepBackFive: playback.step(frames: -5)
        case .stepForwardFive: playback.step(frames: 5)
        case .goToStart: seek(.zero)
        case .goToEnd: seek(project.duration)
        case .previousEdit: return seek(EditPoints.previous(before: playhead, in: project))
        case .nextEdit: return seek(EditPoints.next(after: playhead, in: project))
        case .previousMarker: return seek(EditPoints.previousMarker(before: playhead, in: project))
        case .nextMarker: return seek(EditPoints.nextMarker(after: playhead, in: project))

        // In and out
        case .markIn:
            model.inPoint = playhead
            if let out = model.outPoint, out <= playhead { model.outPoint = nil }
        case .markOut:
            model.outPoint = playhead
            if let inPoint = model.inPoint, inPoint >= playhead { model.inPoint = nil }
        case .clearIn: model.inPoint = nil
        case .clearOut: model.outPoint = nil
        case .clearInOut:
            model.inPoint = nil
            model.outPoint = nil
        case .markClip:
            let tracks = project.videoTracks.reversed() + project.audioTracks
            guard let clip = tracks.filter(\.targeted).compactMap({ $0.clip(at: playhead) }).first else { return false }
            model.inPoint = clip.start
            model.outPoint = clip.end
        case .liftInOut, .extractInOut:
            guard let range = model.inOutRange else {
                model.show(.info, "Set an in and out point first (I and O).")
                return false
            }
            if command == .liftInOut {
                return apply(TimelineEdits.liftRange(project, range: range), otherwise: "Nothing between in and out to lift.")
            }
            guard apply(TimelineEdits.extractRange(project, range: range), otherwise: "Nothing to extract.") else { return false }
            model.inPoint = nil
            model.outPoint = nil
            seek(range.start)

        // Editing
        case .bladeAtPlayhead:
            return apply(TimelineEdits.bladeAtPlayhead(project, playhead: playhead, selection: model.selection), otherwise: "Nothing under the playhead to cut.")
        case .rippleTrimStart, .rippleTrimEnd:
            let edge: ClipEdge = command == .rippleTrimStart ? .start : .end
            guard let result = TimelineEdits.rippleTrimToPlayhead(project, playhead: playhead, edge: edge, selection: model.selection) else {
                model.show(.info, "Put the playhead inside a clip to trim it.")
                return false
            }
            guard model.apply(result.batch) != nil else { return false }
            seek(result.playhead)
        case .lift, .rippleDelete:
            // A keyframe chosen on the timeline goes before its clip does.
            if command == .lift, model.selectedKeyframe != nil { return model.deleteSelectedKeyframe() }
            if model.selection.isEmpty, let id = model.selectedTransitionID {
                model.selectedTransitionID = nil
                return model.apply(EditBatch(label: "Remove transition", commands: [.removeTransition(transitionID: id)])) != nil
            }
            return apply(TimelineEdits.remove(project, clipIDs: model.selection, ripple: command == .rippleDelete), otherwise: "Select clips to delete.")
        case .nudgeLeft: return nudge(-1)
        case .nudgeRight: return nudge(1)
        case .nudgeLeftFive: return nudge(-5)
        case .nudgeRightFive: return nudge(5)
        case .link:
            return apply(TimelineEdits.toggleLink(project, selection: model.selection), otherwise: "Select two or more clips to link.")
        case .addMarker:
            return apply(TimelineEdits.addMarker(project, at: playhead), otherwise: "")
        case .addTransition:
            return apply(TimelineEdits.addDefaultTransition(project, playhead: playhead, selection: model.selection), otherwise: "Put the playhead on a cut between two clips.")
        case .toggleKeyframe: return model.toggleKeyframes()
        case .previousKeyframe: return model.seekKeyframe(forward: false)
        case .nextKeyframe: return model.seekKeyframe(forward: true)
        case .layoutFull: return layout(.full)
        case .layoutPipRight: return layout(.pipRight)
        case .layoutPipLeft: return layout(.pipLeft)
        case .layoutSplit: return layout(.split)

        // Selection
        case .selectAll: model.selection = Set(project.allTracks.flatMap(\.clips).map(\.id))
        case .deselectAll:
            model.selection = []
            model.selectedTransitionID = nil
        case .selectForward: model.selection = SelectionRules.forward(from: playhead, in: project)

        // Timeline view
        case .zoomIn: model.timeline.zoom(by: 1.5, anchorX: nil)
        case .zoomOut: model.timeline.zoom(by: 1 / 1.5, anchorX: nil)
        case .zoomToFit: model.timeline.fit(project.duration)
        case .toggleSnapping:
            model.snapping.toggle()
            model.show(.info, model.snapping ? "Snapping on." : "Snapping off.")
        case .toggleLinkedSelection:
            model.linkedSelection.toggle()
            model.show(.info, model.linkedSelection ? "Linked selection on." : "Linked selection off.")
        case .toggleRipple:
            model.rippleTrims.toggle()
            model.show(.info, model.rippleTrims ? "Edge drags ripple." : "Edge drags trim without rippling.")
        case .toggleTranscriptLane: model.showTranscript.toggle()

        // Tools
        case .toolSelect, .toolBlade, .toolRippleTrim, .toolRoll, .toolSlip, .toolSlide:
            if let tool = tool(for: command) { model.tool = tool }

        // Viewer
        case .toggleSafeMargins: model.showSafeMargins.toggle()
        case .toggleProxy: playback.useProxies.toggle()

        // Project
        case .undo: model.undo()
        case .redo: model.redo()
        case .save: model.save()
        case .saveVersion: ProjectDocuments.shared.saveVersion(of: model)
        case .export: model.showExportSheet = true
        case .newProject: ProjectDocuments.shared.newProject()
        case .openProject: ProjectDocuments.shared.openPanel()
        }
        return true
    }

    // MARK: - Helpers

    @discardableResult
    private func seek(_ time: Time?) -> Bool {
        guard let time else { return false }
        playback.pause()
        playback.seek(to: time)
        return true
    }

    private func apply(_ batch: EditBatch?, otherwise message: String) -> Bool {
        guard let batch else {
            if !message.isEmpty { model.show(.info, message) }
            return false
        }
        return model.apply(batch) != nil
    }

    private func nudge(_ frames: Int64) -> Bool {
        if model.selection.isEmpty {
            playback.step(frames: frames)
            return true
        }
        return apply(TimelineEdits.nudge(project, clipIDs: model.selection, frames: frames), otherwise: "")
    }

    private func layout(_ preset: LayoutPreset) -> Bool {
        apply(
            TimelineEdits.applyLayout(project, preset: preset, playhead: playhead, selection: model.selection),
            otherwise: "Select a video clip, or put the playhead over one."
        )
    }
}

import Foundation
import TandemCore

/// Clip selection rules, Premiere style.
///
/// With linked selection on, clicking a clip selects its whole link group
/// (camera picture, camera sound and screen). Option inverts that for one
/// click, so Option-click picks just one side of a linked group. Shift or
/// Cmd adds to or removes from the selection.
enum SelectionRules {
    struct Modifiers: Equatable {
        var shift = false
        var command = false
        var option = false

        init(shift: Bool = false, command: Bool = false, option: Bool = false) {
            self.shift = shift
            self.command = command
            self.option = option
        }
    }

    /// The clips a click on `clipID` refers to.
    static func members(of clipID: String, in project: Project, linkedSelection: Bool, option: Bool) -> Set<String> {
        let linked = linkedSelection != option
        return Set(linked ? project.linkedClipIDs(of: clipID) : [clipID])
    }

    /// The selection after a click on `clipID`.
    static func click(
        _ clipID: String,
        in project: Project,
        current: Set<String>,
        modifiers: Modifiers,
        linkedSelection: Bool
    ) -> Set<String> {
        let members = members(of: clipID, in: project, linkedSelection: linkedSelection, option: modifiers.option)
        if modifiers.shift || modifiers.command {
            if current.contains(clipID) { return current.subtracting(members) }
            return current.union(members)
        }
        // Pressing an already selected clip keeps the selection, so a group
        // can be dragged together.
        if current.contains(clipID) && current.isSuperset(of: members) && !modifiers.option { return current }
        return members
    }

    /// The selection after a marquee drag over `clipIDs`.
    static func marquee(
        _ clipIDs: [String],
        in project: Project,
        current: Set<String>,
        modifiers: Modifiers,
        linkedSelection: Bool
    ) -> Set<String> {
        var picked = Set<String>()
        if linkedSelection != modifiers.option {
            // Whole link groups, found in two passes over the timeline
            // rather than one per clip: this runs on every mouse move.
            let boxed = Set(clipIDs)
            var groups = Set<String>()
            for track in project.allTracks {
                for clip in track.clips where boxed.contains(clip.id) {
                    if let group = clip.linkGroup { groups.insert(group) } else { picked.insert(clip.id) }
                }
            }
            if !groups.isEmpty {
                for track in project.allTracks {
                    for clip in track.clips where clip.linkGroup.map(groups.contains) == true { picked.insert(clip.id) }
                }
            }
        } else {
            picked = Set(clipIDs)
        }
        if modifiers.shift || modifiers.command { return current.union(picked) }
        return picked
    }

    /// `A`: every clip that starts at or after the playhead.
    static func forward(from time: Time, in project: Project) -> Set<String> {
        Set(project.allTracks.flatMap(\.clips).filter { $0.start >= time }.map(\.id))
    }

    /// Drops IDs that no longer exist after an edit.
    static func pruned(_ selection: Set<String>, in project: Project) -> Set<String> {
        let all = Set(project.allTracks.flatMap(\.clips).map(\.id))
        return selection.intersection(all)
    }
}

/// Edit points and marker stops for the Up and Down keys.
enum EditPoints {
    /// Clip starts and ends on targeted tracks (every track when none is
    /// targeted), sorted.
    static func all(in project: Project) -> [Time] {
        let targeted = project.allTracks.filter(\.targeted)
        let tracks = targeted.isEmpty ? project.allTracks : targeted
        return Array(Set(tracks.flatMap(\.clips).flatMap { [$0.start, $0.end] })).sorted()
    }

    static func previous(before time: Time, in project: Project) -> Time? {
        all(in: project).last { $0 < time }
    }

    static func next(after time: Time, in project: Project) -> Time? {
        all(in: project).first { $0 > time }
    }

    static func previousMarker(before time: Time, in project: Project) -> Time? {
        project.markers.map(\.time).filter { $0 < time }.max()
    }

    static func nextMarker(after time: Time, in project: Project) -> Time? {
        project.markers.map(\.time).filter { $0 > time }.min()
    }
}

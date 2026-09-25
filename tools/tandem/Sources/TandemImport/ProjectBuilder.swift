import Foundation
import TandemCore

/// Builds an imported project through `ProjectCoordinator`, so every step
/// is an ordinary edit command and the result always validates.
///
/// Each step of an import is one labelled batch. If the coordinator rejects
/// a batch, its commands are retried one at a time and the ones that still
/// fail go in the report, so one bad clip can't sink a whole import.
final class ProjectBuilder {
    struct Step {
        var command: EditCommand
        /// What the command is for, shown in the report if it fails, for
        /// example "clip from camera.mov at 01:02.000".
        var what: String
        var at: Time?

        init(_ command: EditCommand, _ what: String, at: Time? = nil) {
            self.command = command
            self.what = what
            self.at = at
        }
    }

    let coordinator: ProjectCoordinator
    var report: ImportReport
    let author: String

    init(project: Project, report: ImportReport, author: String = "importer") {
        self.coordinator = ProjectCoordinator(project: project)
        self.report = report
        self.author = author
    }

    var project: Project { coordinator.project }

    /// Applies the steps as one batch, falling back to one command at a
    /// time. Returns the indices of the steps that failed.
    @discardableResult
    func apply(_ label: String, _ steps: [Step]) -> Set<Int> {
        guard !steps.isEmpty else { return [] }
        do {
            let result = try coordinator.apply(EditBatch(label: label, author: author, commands: steps.map(\.command)))
            note(result.warnings)
            return []
        } catch {
            var failed = Set<Int>()
            for (index, step) in steps.enumerated() {
                do {
                    let result = try coordinator.apply(EditBatch(label: "\(label): \(step.what)", author: author, commands: [step.command]))
                    note(result.warnings)
                } catch {
                    failed.insert(index)
                    report.add(.failed, "edit", "\(label), \(step.what): \(error)", at: step.at)
                }
            }
            return failed
        }
    }

    /// Adds a track and sets how it ripples. Returns its ID.
    @discardableResult
    func addTrack(_ kind: TrackKind, name: String, rippleMode: RippleMode, index: Int? = nil, id: String? = nil) -> String? {
        let trackID = id ?? ImportIDs.make("trk", key: "\(kind.rawValue):\(name):\(project.allTracks.count)")
        let failed = apply("Add track \(name)", [
            Step(.addTrack(kind: kind, name: name, index: index, id: trackID), "track \(name)"),
            Step(.updateTrack(trackID: trackID, patch: .object(["rippleMode": .string(rippleMode.rawValue)])), "ripple mode of \(name)")
        ])
        return failed.contains(0) ? nil : trackID
    }

    func track(named name: String, kind: TrackKind? = nil) -> Track? {
        project.track(named: name, kind: kind)
    }

    /// The first track in the family `name`, `name 2`, `name 3`... that is
    /// free over `range`, adding the next one (just above the last) when
    /// they're all busy. Used for overlays that may overlap each other.
    func freeTrack(_ kind: TrackKind, family name: String, range: TimeRange, rippleMode: RippleMode = .follow) -> String? {
        var index = 1
        var lastLocation: TrackLocation?
        while true {
            let candidate = index == 1 ? name : "\(name) \(index)"
            guard let track = project.track(named: candidate, kind: kind) else { break }
            lastLocation = project.location(ofTrack: track.id)
            if track.isFree(range) { return track.id }
            index += 1
        }
        let newName = index == 1 ? name : "\(name) \(index)"
        let position = lastLocation.map { $0.index + 1 }
        return addTrack(kind, name: newName, rippleMode: rippleMode, index: position)
    }

    private func note(_ warnings: [String]) {
        for warning in warnings {
            report.add(.note, "tandem", warning)
        }
    }
}

/// Deterministic IDs for imported objects, so importing the same project
/// twice gives the same IDs and the two files diff cleanly.
enum ImportIDs {
    static func make(_ prefix: String, key: String) -> String {
        var generator = SplitMix64(seed: fnv1a(key))
        return IDs.make(prefix, using: &generator)
    }

    /// Hands out IDs that are unique within one import, even if two keys
    /// happen to hash alike.
    struct Allocator {
        private var used = Set<String>()

        mutating func make(_ prefix: String, key: String) -> String {
            var attempt = 0
            while true {
                let id = ImportIDs.make(prefix, key: attempt == 0 ? key : "\(key)#\(attempt)")
                if !used.contains(id) {
                    used.insert(id)
                    return id
                }
                attempt += 1
            }
        }

        mutating func reserve(_ id: String) {
            used.insert(id)
        }
    }

    static func fnv1a(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01B3
        }
        return hash
    }
}

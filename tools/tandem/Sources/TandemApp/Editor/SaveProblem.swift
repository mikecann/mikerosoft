import Foundation

/// What the app says when a project won't save: in the status bar while
/// autosave keeps trying, and before a window closes or Tandem quits with
/// edits that didn't make it to disk.
enum SaveProblem {
    /// The status bar's lasting note.
    static let short = "Not saved"

    /// The status bar message when saving starts failing.
    static func message(file: String, reason: String) -> String {
        "Couldn't save \(file). \(sentence(reason)) Tandem keeps trying."
    }

    /// The alert before closing (or quitting) loses edits.
    static func closeAlert(files: [String], reason: String, quitting: Bool) -> (title: String, detail: String) {
        let names = files.count == 1 ? files[0] : "\(files.count) projects"
        let title = "Tandem couldn't save \(names)"
        let action = quitting ? "Quitting" : "Closing"
        let detail = "\(sentence(reason))\n\n\(action) now loses the edits since the last save, unless the journal in .tandem next to the project kept them (Tandem replays it when the project next opens). Keep it open to fix the problem and save with ⌘S."
        return (title, detail)
    }

    /// The reason as a sentence, ending in one full stop.
    static func sentence(_ reason: String) -> String {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "The file couldn't be written." }
        return trimmed.hasSuffix(".") ? trimmed : trimmed + "."
    }
}

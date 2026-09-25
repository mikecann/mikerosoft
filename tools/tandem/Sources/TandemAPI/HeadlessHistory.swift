import Foundation
import TandemCore

/// Undo, redo and idempotency for edits made with the app closed.
///
/// When no app has the project open, each CLI command (and each MCP tool
/// call) opens the file, edits it and closes it again, so the coordinator's
/// in-memory undo stack only ever lives for one call. This keeps the undo
/// history in `.tandem/<name>.undo.json` instead: a snapshot of the project
/// before each headless edit, plus the results of recent idempotent batches
/// so a retried batch isn't applied twice.
///
/// The history is only valid while the project is still at `revision`. Any
/// edit made elsewhere (the app, `tandem serve`) moves the revision on, and
/// the stale history is dropped the next time it's touched.
final class HeadlessHistory: @unchecked Sendable {
    struct Entry: Codable {
        var label: String
        var author: String
        var date: Date
        /// The project to go back to.
        var project: Project
    }

    struct Idempotent: Codable {
        var key: String
        var result: ApplyResult
    }

    struct State: Codable {
        var revision: Int
        var undo: [Entry]
        var redo: [Entry]
        var idempotent: [Idempotent]

        init(revision: Int) {
            self.revision = revision
            undo = []
            redo = []
            idempotent = []
        }
    }

    let url: URL
    private let maxEntries = 20
    private let maxKeys = 100

    init(projectURL: URL) {
        let name = projectURL.deletingPathExtension().lastPathComponent
        url = ProjectFile.supportFolder(for: projectURL).appendingPathComponent("\(name).undo.json")
    }

    private func load() -> State? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? ServiceJSON.decoder().decode(State.self, from: data)
    }

    private func save(_ state: State) {
        guard let data = try? ServiceJSON.encoder().encode(state) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// The history as it stands at `revision`, or an empty one if it's stale.
    private func current(at revision: Int) -> State {
        guard let state = load(), state.revision == revision else {
            var fresh = State(revision: revision)
            // Idempotency keys stay useful even when the undo stack goes stale.
            fresh.idempotent = load()?.idempotent ?? []
            return fresh
        }
        return state
    }

    /// Records a committed headless edit.
    func recordEdit(label: String, author: String, before: Project, beforeRevision: Int, afterRevision: Int) {
        var state = current(at: beforeRevision)
        state.undo.append(Entry(label: label, author: author, date: Date(), project: before))
        if state.undo.count > maxEntries { state.undo.removeFirst(state.undo.count - maxEntries) }
        state.redo.removeAll()
        state.revision = afterRevision
        save(state)
    }

    /// The top of the undo stack, if the history is current.
    func peekUndo(at revision: Int) -> Entry? {
        current(at: revision).undo.last
    }

    func peekRedo(at revision: Int) -> Entry? {
        current(at: revision).redo.last
    }

    /// Undo labels, newest first.
    func undoEntries(at revision: Int) -> [Entry] {
        current(at: revision).undo.reversed()
    }

    /// Pops the undo entry after it has been restored, moving the replaced
    /// project onto the redo stack.
    func didUndo(at revision: Int, replaced: Project, newRevision: Int) {
        var state = current(at: revision)
        guard let entry = state.undo.popLast() else { return }
        state.redo.append(Entry(label: entry.label, author: entry.author, date: Date(), project: replaced))
        state.revision = newRevision
        save(state)
    }

    func didRedo(at revision: Int, replaced: Project, newRevision: Int) {
        var state = current(at: revision)
        guard let entry = state.redo.popLast() else { return }
        state.undo.append(Entry(label: entry.label, author: entry.author, date: Date(), project: replaced))
        state.revision = newRevision
        save(state)
    }

    func result(forKey key: String) -> ApplyResult? {
        load()?.idempotent.last { $0.key == key }?.result
    }

    func remember(key: String, result: ApplyResult) {
        var state = load() ?? State(revision: result.revision)
        state.idempotent.removeAll { $0.key == key }
        state.idempotent.append(Idempotent(key: key, result: result))
        if state.idempotent.count > maxKeys { state.idempotent.removeFirst(state.idempotent.count - maxKeys) }
        save(state)
    }
}

import Foundation

/// The one place a project changes. Every client (the app UI, the CLI in
/// headless mode, the local API that agents use) submits `EditBatch`es here.
///
/// A batch is applied to a copy of the project, validated as a whole, and
/// only then committed, so a failing command leaves nothing half done. Each
/// commit bumps the revision, becomes one undo step, is appended to the
/// crash-recovery journal and is announced to observers.
///
/// All state is guarded by a serial queue, so it is safe to call from any
/// thread. Observers are called on that queue; hop to the main thread in UI
/// code.
public final class ProjectCoordinator: @unchecked Sendable {
    public struct CommitResult: Codable, Equatable, Sendable {
        public var revision: Int
        public var label: String
        public var author: String
        /// IDs of things the batch created (clips, tracks, transitions,
        /// markers), in creation order, so callers can refer to them without
        /// re-reading the whole project.
        public var createdIDs: [String]
        /// Things worth telling the user that didn't block the edit.
        public var warnings: [String]
    }

    public struct ChangeEvent: Sendable {
        public enum Kind: String, Sendable { case edit, undo, redo, reload }
        public var kind: Kind
        public var revision: Int
        public var label: String
        public var author: String
        /// The project either side of the change. Observers run inside the
        /// coordinator and can't read it back, so the review log works out
        /// what an agent's batch did from these.
        public var before: Project?
        public var after: Project?
    }

    private struct UndoEntry {
        var label: String
        var author: String
        var before: Project
        var after: Project
    }

    private let queue = DispatchQueue(label: "com.mikerosoft.tandem.coordinator")
    private var _project: Project
    private var _revision: Int
    private var undoStack: [UndoEntry] = []
    private var redoStack: [UndoEntry] = []
    private var idempotencyResults: [String: CommitResult] = [:]
    private var observers: [UUID: (ChangeEvent) -> Void] = [:]
    private let journal: ProjectJournal?
    private let maxUndo = 500

    public init(project: Project, revision: Int = 0, journal: ProjectJournal? = nil) {
        self._project = project
        self._revision = revision
        self.journal = journal
    }

    public var project: Project { queue.sync { _project } }
    public var revision: Int { queue.sync { _revision } }

    /// The project and its revision read together, for callers that want to
    /// send `expectedRevision` with their next batch.
    public func snapshot() -> (project: Project, revision: Int) {
        queue.sync { (_project, _revision) }
    }

    public var undoLabel: String? { queue.sync { undoStack.last?.label } }
    public var redoLabel: String? { queue.sync { redoStack.last?.label } }

    @discardableResult
    public func apply(_ batch: EditBatch) throws -> CommitResult {
        try queue.sync {
            if let key = batch.idempotencyKey, let previous = idempotencyResults[key] {
                return previous
            }
            if let expected = batch.expectedRevision, expected != _revision {
                throw EditError.staleRevision(expected: expected, actual: _revision)
            }
            var working = _project
            var context = EditContext()
            for (index, command) in batch.commands.enumerated() {
                do {
                    try Editing.apply(command, to: &working, context: &context)
                } catch let error as EditError where batch.commands.count > 1 {
                    throw EditError.invalid("command \(index + 1) of \(batch.commands.count): \(error.description)")
                }
            }
            let issues = ProjectValidator.validate(working)
            if let first = issues.first(where: { $0.severity == .error }) {
                throw EditError.invalid(first.message)
            }
            let before = _project
            _project = working
            _revision += 1
            undoStack.append(UndoEntry(label: batch.label, author: batch.author, before: before, after: working))
            if undoStack.count > maxUndo { undoStack.removeFirst(undoStack.count - maxUndo) }
            redoStack.removeAll()
            let result = CommitResult(
                revision: _revision,
                label: batch.label,
                author: batch.author,
                createdIDs: context.createdIDs,
                warnings: context.warnings + issues.filter { $0.severity == .warning }.map(\.message)
            )
            if let key = batch.idempotencyKey { idempotencyResults[key] = result }
            journal?.append(batch: batch, revision: _revision, seed: context.seed)
            notify(ChangeEvent(kind: .edit, revision: _revision, label: batch.label, author: batch.author, before: before, after: working))
            return result
        }
    }

    /// Undoes the last batch. Returns nil if there is nothing to undo.
    @discardableResult
    public func undo() -> CommitResult? {
        queue.sync {
            guard let entry = undoStack.popLast() else { return nil }
            let replaced = _project
            _project = entry.before
            _revision += 1
            redoStack.append(entry)
            journal?.appendSnapshot(project: _project, revision: _revision, reason: "undo \(entry.label)")
            notify(ChangeEvent(kind: .undo, revision: _revision, label: entry.label, author: entry.author, before: replaced, after: _project))
            return CommitResult(revision: _revision, label: "Undo \(entry.label)", author: entry.author, createdIDs: [], warnings: [])
        }
    }

    @discardableResult
    public func redo() -> CommitResult? {
        queue.sync {
            guard let entry = redoStack.popLast() else { return nil }
            let replaced = _project
            _project = entry.after
            _revision += 1
            undoStack.append(entry)
            journal?.appendSnapshot(project: _project, revision: _revision, reason: "redo \(entry.label)")
            notify(ChangeEvent(kind: .redo, revision: _revision, label: entry.label, author: entry.author, before: replaced, after: _project))
            return CommitResult(revision: _revision, label: "Redo \(entry.label)", author: entry.author, createdIDs: [], warnings: [])
        }
    }

    /// Replaces the whole project, for example after the file changed on
    /// disk while the app was closed. Clears undo history.
    public func reload(_ project: Project) {
        queue.sync {
            let replaced = _project
            _project = project
            _revision += 1
            undoStack.removeAll()
            redoStack.removeAll()
            // Journaled like an undo: edits after this are relative to the
            // new project, so a replay after a crash has to start from it.
            journal?.appendSnapshot(project: project, revision: _revision, reason: "reload")
            notify(ChangeEvent(kind: .reload, revision: _revision, label: "Reload", author: "system", before: replaced, after: project))
        }
    }

    /// Recent undo labels, newest first, for the activity feed.
    public func history(limit: Int = 50) -> [(label: String, author: String)] {
        queue.sync { undoStack.suffix(limit).reversed().map { ($0.label, $0.author) } }
    }

    @discardableResult
    public func observe(_ handler: @escaping (ChangeEvent) -> Void) -> UUID {
        let token = UUID()
        queue.sync { observers[token] = handler }
        return token
    }

    public func removeObserver(_ token: UUID) {
        queue.sync { _ = observers.removeValue(forKey: token) }
    }

    private func notify(_ event: ChangeEvent) {
        for handler in observers.values { handler(event) }
    }
}

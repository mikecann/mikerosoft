import Foundation

/// Keeps a project's review log as its coordinator commits: an agent's
/// batch is recorded, every edit carries the highlights along, an undo
/// drops what it put back, and the log is saved beside the journal after
/// each change. Every session has one (the app, `tandem serve` and each
/// headless CLI command), so agent edits are logged wherever they're made
/// and the app finds them when it opens the project.
///
/// Work happens on the recorder's own queue, off the coordinator's, and
/// observers hear the new log there. Reading `log` waits for the edits
/// already heard, so a status read straight after an edit sees it.
public final class ReviewRecorder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.mikerosoft.tandem.review")
    private let coordinator: ProjectCoordinator
    private let folder: FolderAnchor?
    private let fileName: String
    private var _log: ReviewLog
    private var observers: [UUID: (ReviewLog) -> Void] = [:]
    private var token: UUID?
    private var closed = false

    /// `url` is `ProjectFile.reviewURL(for:)`; nil keeps the log in memory.
    public init(coordinator: ProjectCoordinator, url: URL?) {
        self.coordinator = coordinator
        if let url {
            folder = FolderAnchor(url.deletingLastPathComponent())
            fileName = url.lastPathComponent
            _log = ReviewLog.load(from: url)
        } else {
            folder = nil
            fileName = ""
            _log = ReviewLog()
        }
        token = coordinator.observe { [weak self] event in self?.heard(event) }
        // Clips taken off the timeline since the log was saved (by an older
        // Tandem, or by hand) have nothing left to show.
        queue.async { [weak self] in
            guard let self, !self.closed else { return }
            var log = self._log
            if log.prune(in: coordinator.project, reverts: false) { self.commit(log) }
        }
    }

    /// Where the log is saved now. It follows the folder if the video
    /// folder is renamed or moved while the project is open.
    public var url: URL? {
        folder.map { $0.url.appendingPathComponent(fileName) }
    }

    public var log: ReviewLog {
        queue.sync { _log }
    }

    /// Hears the log each time it changes, on the recorder's queue.
    @discardableResult
    public func observe(_ handler: @escaping (ReviewLog) -> Void) -> UUID {
        let token = UUID()
        queue.sync { observers[token] = handler }
        return token
    }

    public func removeObserver(_ token: UUID) {
        queue.sync { _ = observers.removeValue(forKey: token) }
    }

    /// Mike has looked at everything: the log starts again empty.
    public func markReviewed() {
        queue.sync {
            guard !_log.isEmpty else { return }
            commit(ReviewLog())
        }
    }

    /// What the journal replayed when the project opened after a crash,
    /// which no recorder heard committing: the agents' batches are
    /// recorded (unless the log already has them) and undos prune.
    public func catchUp(_ replayed: [(entry: ProjectJournal.Entry, before: Project, after: Project)]) {
        guard !replayed.isEmpty else { return }
        queue.sync {
            var log = _log
            var changed = false
            for (entry, before, after) in replayed {
                changed = log.follow(from: before, to: after) || changed
                if let batch = entry.batch {
                    changed = log.record(label: batch.label, author: batch.author, revision: entry.revision, date: entry.date, before: before, after: after) || changed
                } else {
                    changed = log.prune(in: after, reverts: true) || changed
                }
            }
            if let last = replayed.last {
                changed = log.prune(in: last.after, reverts: false) || changed
            }
            if changed { commit(log) }
        }
    }

    /// A redo the coordinator saw only as a reload: the headless undo
    /// history puts back a whole project. The batch is back, so if an
    /// agent made it, it waits for review again.
    public func redid(label: String, author: String, revision: Int, before: Project, after: Project) {
        queue.async { [weak self] in
            guard let self, !self.closed else { return }
            var log = self._log
            if log.record(label: label, author: author, revision: revision, before: before, after: after) { self.commit(log) }
        }
    }

    /// Finishes what it has heard and stops listening. The log is saved.
    public func close() {
        if let token { coordinator.removeObserver(token) }
        token = nil
        queue.sync { closed = true }
    }

    // MARK: - Edits

    /// Runs inside the coordinator's queue, so it only queues the work.
    private func heard(_ event: ProjectCoordinator.ChangeEvent) {
        queue.async { [weak self] in self?.handle(event) }
    }

    private func handle(_ event: ProjectCoordinator.ChangeEvent) {
        guard !closed, let before = event.before, let after = event.after else { return }
        var log = _log
        var changed = log.follow(from: before, to: after)
        switch event.kind {
        case .edit, .redo:
            changed = log.record(label: event.label, author: event.author, revision: event.revision, before: before, after: after) || changed
            changed = log.prune(in: after, reverts: false) || changed
        case .undo, .reload:
            changed = log.prune(in: after, reverts: true) || changed
        }
        if changed { commit(log) }
    }

    /// On the queue: keeps, saves and announces a new log.
    private func commit(_ log: ReviewLog) {
        _log = log
        if let url { try? log.save(to: url) }
        for handler in observers.values { handler(log) }
    }
}

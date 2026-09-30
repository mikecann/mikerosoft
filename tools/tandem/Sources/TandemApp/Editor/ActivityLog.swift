import Foundation
import TandemCore

/// One committed batch in the activity feed.
struct ActivityEntry: Identifiable, Equatable {
    /// The revision the batch created, unique within a session.
    let id: Int
    let label: String
    let author: String
    let date: Date

    var isAgent: Bool { EditAuthor.isAgent(author) }
}

/// The edits made in this session, mirrored from the coordinator's change
/// events so the feed can show who did what and when. It follows the undo
/// and redo stacks exactly: an undone edit moves to `undone` and comes back
/// on redo, a new edit clears the redo side.
struct ActivityLog: Equatable {
    static let systemAuthor = EditAuthor.system

    /// Oldest first, in undo stack order.
    private(set) var done: [ActivityEntry] = []
    /// The redo stack; the last one redoes next.
    private(set) var undone: [ActivityEntry] = []

    static func isPerson(_ author: String) -> Bool {
        EditAuthor.isPerson(author)
    }

    /// Who a batch came from, as the feed shows it.
    static func displayName(_ author: String) -> String {
        if isPerson(author) { return "You" }
        if author == systemAuthor { return "Tandem" }
        // The command line tools are acronyms.
        if ["cli", "mcp", "api"].contains(author.lowercased()) { return author.uppercased() }
        return author.prefix(1).uppercased() + author.dropFirst()
    }

    mutating func record(_ kind: ProjectCoordinator.ChangeEvent.Kind, revision: Int, label: String, author: String, date: Date = Date()) {
        switch kind {
        case .edit:
            done.append(ActivityEntry(id: revision, label: label, author: author, date: date))
            undone.removeAll()
        case .undo:
            if let last = done.popLast() { undone.append(last) }
        case .redo:
            if let last = undone.popLast() { done.append(last) }
        case .reload:
            done.removeAll()
            undone.removeAll()
        }
    }

    /// Newest first, for the feed.
    var recent: [ActivityEntry] { done.reversed() }

    /// How many undos it takes to undo `entryID` and everything after it.
    func undoSteps(through entryID: Int) -> Int? {
        guard let index = done.lastIndex(where: { $0.id == entryID }) else { return nil }
        return done.count - index
    }

    /// The last edit an agent made, for the top bar chip.
    var lastAgentEntry: ActivityEntry? {
        done.last { $0.isAgent }
    }
}

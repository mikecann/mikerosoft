import CoreGraphics
import Foundation
import TandemCore

/// One drag in progress. Each pointer move plans a batch and previews it on
/// a copy of the project; a move the edit can't make keeps the last good
/// preview, so the clips stop at the limit instead of flickering back.
/// Nothing reaches the coordinator until `finish()` hands the batch over.
struct DragSession {
    let kind: DragKind
    let context: DragContext
    private(set) var plan: DragPlan
    /// The project as it would be after the drag, or nil when unchanged.
    private(set) var preview: Project?
    /// Pixels moved, for telling a click from a drag.
    private(set) var distance: CGFloat = 0

    init(kind: DragKind, context: DragContext) {
        self.kind = kind
        self.context = context
        self.plan = DragPlan(batch: nil, snappedTo: nil, delta: .zero)
    }

    mutating func update(_ pointer: DragPointer, travelled: CGFloat) {
        distance = max(distance, travelled)
        let candidate = DragPlanner.plan(kind, pointer: pointer, context: context)
        guard let batch = candidate.batch else {
            plan = candidate
            preview = nil
            return
        }
        if let applied = EditPreview.apply(batch, to: context.project) {
            plan = candidate
            preview = applied
        }
    }

    /// The batch to commit, or nil for a click or a no-op drag.
    func finish(minimumDistance: CGFloat = 2) -> EditBatch? {
        guard distance >= minimumDistance, preview != nil else { return nil }
        return plan.batch
    }
}

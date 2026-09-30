import SwiftUI
import TandemCore

/// The timeline toolbar's chip while agent edits wait for review: how many,
/// buttons that step the playhead through the stretches they changed, and
/// Mark reviewed. Hidden when there's nothing to review.
struct ReviewChip: View {
    let model: EditorModel
    let actions: EditorActions

    var body: some View {
        let review = model.review
        if !review.isEmpty {
            HStack(spacing: 0) {
                StepButton(icon: "chevron.left", help: Shortcuts.help("Previous agent change", .previousAgentChange)) {
                    actions.perform(.previousAgentChange)
                }
                Text(review.chipTitle)
                    .font(.ui(11.5, .medium))
                    .foregroundStyle(Theme.agent.color)
                    .padding(.horizontal, 2)
                    .tip(summary)
                StepButton(icon: "chevron.right", help: Shortcuts.help("Next agent change", .nextAgentChange)) {
                    actions.perform(.nextAgentChange)
                }
                Rectangle()
                    .fill(Theme.agent.opacity(0.35).color)
                    .frame(width: 1, height: 14)
                    .padding(.horizontal, 4)
                Button {
                    actions.perform(.markAgentChangesReviewed)
                } label: {
                    Text("Mark reviewed")
                        .font(.ui(11.5))
                        .foregroundStyle(Theme.text.color)
                        .padding(.trailing, 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .tip(Shortcuts.help("Mark reviewed: clear the agent edits highlighted on the timeline", .markAgentChangesReviewed))
            }
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.agent.opacity(0.12).color))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.agent.opacity(0.35).color, lineWidth: 1))
        }
    }

    /// The latest edits waiting, for hovering the count.
    private var summary: String {
        let entries = model.reviewLog.entries
        var lines = ["Agent edits since you last marked them reviewed:"]
        lines += entries.suffix(8).map { "\(ActivityLog.displayName($0.author)) · \($0.label) · \(TimelineReview.when($0.date))" }
        if entries.count > 8 { lines.append("and \(entries.count - 8) earlier") }
        return lines.joined(separator: "\n")
    }
}

/// A chevron that steps through the changes.
private struct StepButton: View {
    let icon: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.agent.color)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .tip(help)
    }
}

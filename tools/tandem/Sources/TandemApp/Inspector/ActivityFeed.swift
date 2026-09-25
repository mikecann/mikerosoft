import AppKit
import SwiftUI
import TandemCore

/// Every committed batch this session, newest first, with who made it.
/// Agent edits land here the moment they commit, and each one is a single
/// undo step.
struct ActivityFeed: View {
    let model: EditorModel

    var body: some View {
        let entries = model.activity.recent
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Activity")
                    .font(.ui(13, .bold))
                    .foregroundStyle(Theme.text.color)
                Text("Edits by you and your agents. Each one is a single undo step.")
                    .font(.ui(11.5))
                    .foregroundStyle(Theme.textMuted.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border.color).frame(height: 1) }

            VStack(alignment: .leading, spacing: 2) {
                if let redo = model.redoLabel {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(redo)
                                .font(.ui(12.5))
                                .foregroundStyle(Theme.textMuted.color)
                                .strikethrough()
                            Text("Undone")
                                .font(.ui(11.5))
                                .foregroundStyle(Theme.textFaint.color)
                        }
                        Spacer()
                        OutlineButton(title: "Redo") { model.redo() }
                    }
                    .padding(8)
                }
                if entries.isEmpty && model.redoLabel == nil {
                    Text("Edits show here as they happen, including ones agents make through the tandem CLI and MCP.")
                        .font(.ui(12))
                        .foregroundStyle(Theme.textFaint.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(8)
                }
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    ActivityRow(entry: entry, latest: index == 0) {
                        model.undo(through: entry.id)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)

            HStack(spacing: 8) {
                Text("Any agent can connect")
                    .font(.ui(11.5))
                    .foregroundStyle(Theme.textMuted.color)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Self.mcpConfig(for: model.fileURL), forType: .string)
                    model.show(.info, "Copied the MCP config for this project.")
                } label: {
                    Text("Copy MCP config")
                        .font(.ui(11.5))
                        .foregroundStyle(Theme.text.color)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.field.color))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .overlay(alignment: .top) { Rectangle().fill(Theme.border.color).frame(height: 1) }
        }
    }

    /// An MCP server entry that runs the bundled `tandem` CLI on this project.
    static func mcpConfig(for projectURL: URL) -> String {
        let cli = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("tandem").path ?? "tandem"
        let object: [String: Any] = ["mcpServers": ["tandem": ["command": cli, "args": ["mcp", "--project", projectURL.path]]]]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }
}

private struct ActivityRow: View {
    let entry: ActivityEntry
    let latest: Bool
    let undo: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(entry.isAgent ? Theme.amber.color : (entry.author == ActivityLog.systemAuthor ? Theme.textFainter.color : Theme.textMuted.color))
                .frame(width: 6, height: 6)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.label)
                    .font(.ui(12.5))
                    .foregroundStyle(Theme.text.color)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(ActivityLog.displayName(entry.author)) · \(entry.date.formatted(date: .omitted, time: .shortened))")
                    .font(.ui(11.5))
                    .foregroundStyle(Theme.textMuted.color)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if latest || hovering {
                OutlineButton(title: latest ? "Undo" : "Undo to here", action: undo)
                    .help(latest ? "Undo this edit" : "Undo this edit and everything after it. Redo brings them back.")
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(entry.isAgent && latest ? Theme.field.color : .clear))
        .onHover { hovering = $0 }
    }
}

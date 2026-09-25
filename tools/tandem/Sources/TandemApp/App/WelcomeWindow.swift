import AppKit
import SwiftUI

/// Shown when no project is open: new, open and recent projects.
@MainActor
final class WelcomeWindowController: NSWindowController {
    private let state = WelcomeState()

    init(documents: ProjectDocuments) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 400),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Tandem"
        window.backgroundColor = Theme.panel.ns
        window.appearance = NSAppearance(named: .darkAqua)
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        state.documents = documents
        window.contentView = NSHostingView(rootView: WelcomeView(state: state).ignoresSafeArea())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func refresh() {
        state.recent = ProjectDocuments.shared.recent.existing()
    }
}

@MainActor
@Observable
final class WelcomeState {
    var recent: [URL] = []
    @ObservationIgnored weak var documents: ProjectDocuments?
}

struct WelcomeView: View {
    let state: WelcomeState

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Spacer().frame(height: 56)
                Text("Tandem")
                    .font(.ui(28, .bold))
                    .foregroundStyle(Theme.text.color)
                Text("Edit Convex videos with your agents.")
                    .font(.ui(12.5))
                    .foregroundStyle(Theme.textMuted.color)
                    .padding(.top, 4)
                Spacer()
                VStack(alignment: .leading, spacing: 8) {
                    WelcomeButton(title: "New project…", detail: "Pick the video's folder", primary: true) {
                        state.documents?.newProject()
                    }
                    WelcomeButton(title: "Open…", detail: "A .tandem file", primary: false) {
                        state.documents?.openPanel()
                    }
                }
                .padding(.bottom, 28)
            }
            .padding(.horizontal, 28)
            .frame(width: 250, alignment: .leading)
            .frame(maxHeight: .infinity)

            Rectangle().fill(Theme.border.color).frame(width: 1)

            VStack(alignment: .leading, spacing: 2) {
                Text("Recent")
                    .font(.ui(11.5, .semibold))
                    .foregroundStyle(Theme.textMuted.color)
                    .padding(.horizontal, 10)
                    .padding(.top, 48)
                    .padding(.bottom, 6)
                if state.recent.isEmpty {
                    Text("Projects you open show up here.")
                        .font(.ui(12))
                        .foregroundStyle(Theme.textFaint.color)
                        .padding(.horizontal, 10)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(state.recent, id: \.self) { url in
                            RecentRow(url: url) { state.documents?.open(url) }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.window.color)
        }
        .frame(minWidth: 560, maxWidth: .infinity, minHeight: 400, maxHeight: .infinity)
        .background(Theme.panel.color)
    }
}

private struct WelcomeButton: View {
    let title: String
    let detail: String
    let primary: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.ui(13, .semibold))
                Text(detail).font(.ui(11)).opacity(0.7)
            }
            .foregroundStyle(primary ? Theme.onAmber.color : Theme.text.color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(primary ? Theme.amber.color : Theme.field.color))
        }
        .buttonStyle(.plain)
    }
}

private struct RecentRow: View {
    let url: URL
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(url.deletingPathExtension().lastPathComponent)
                    .font(.ui(12.5, .semibold))
                    .foregroundStyle(Theme.text.color)
                Text(url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.ui(11))
                    .foregroundStyle(Theme.textFaint.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7).fill(hovering ? Theme.rowSelected.color : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

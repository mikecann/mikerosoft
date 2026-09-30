import AppKit
import SwiftUI

/// Shown when no project is open: new, open and recent projects. It can be
/// resized, and opens at the size it was left at.
@MainActor
final class WelcomeWindowController: NSWindowController, NSWindowDelegate {
    private let state = WelcomeState()

    init(documents: ProjectDocuments) {
        let visible = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1_440, height: 900)
        let size = WelcomeSize.restore(AppDefaults.store.string(forKey: WelcomeSize.defaultsKey), fitting: visible)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
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
        window.contentMinSize = WelcomeSize.minimum
        window.center()
        super.init(window: window)
        window.delegate = self
        state.documents = documents
        let hosting = NSHostingView(rootView: WelcomeView(state: state).ignoresSafeArea())
        // The window sets the size; the view fills it.
        hosting.sizingOptions = []
        window.contentView = hosting
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func windowDidEndLiveResize(_ notification: Notification) {
        rememberSize()
    }

    func windowWillClose(_ notification: Notification) {
        rememberSize()
    }

    private func rememberSize() {
        guard let window else { return }
        AppDefaults.store.set(NSStringFromSize(window.contentRect(forFrameRect: window.frame).size), forKey: WelcomeSize.defaultsKey)
    }

    func refresh() {
        state.recent = ProjectDocuments.shared.recent.existing()
    }
}

/// The project list's size: what it was left at, kept on screen and no
/// smaller than its layout needs.
enum WelcomeSize {
    static let minimum = CGSize(width: 560, height: 400)
    static let defaultsKey = "welcomeWindowSize"

    static func restore(_ saved: String?, fitting visible: CGSize) -> CGSize {
        let size = saved.map { NSSizeFromString($0) } ?? .zero
        guard size.width > 0, size.height > 0 else { return minimum }
        return CGSize(
            width: max(minimum.width, min(size.width, visible.width)),
            height: max(minimum.height, min(size.height, visible.height))
        )
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
                GeometryReader { geometry in
                    // Bigger frames when the window is made bigger.
                    let iconWidth: CGFloat = geometry.size.width > 520 ? 112 : 64
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(state.recent, id: \.self) { url in
                                RecentRow(url: url, iconWidth: iconWidth) { state.documents?.open(url) }
                            }
                        }
                    }
                    .scrollIndicators(.automatic)
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
    var iconWidth: CGFloat = 64
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ProjectIconView(url: url, width: iconWidth)
                VStack(alignment: .leading, spacing: 2) {
                    Text(url.deletingPathExtension().lastPathComponent)
                        .font(.ui(12.5, .semibold))
                        .foregroundStyle(Theme.text.color)
                        .lineLimit(1)
                    Text(url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.ui(11))
                        .foregroundStyle(Theme.textFaint.color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7).fill(hovering ? Theme.rowSelected.color : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerHover { hovering = $0 }
    }
}

/// A project's icon in the list: a frame from it, or a quiet placeholder
/// until there is one. Reading it never waits on the disk.
struct ProjectIconView: View {
    let url: URL
    var width: CGFloat = 64

    var body: some View {
        let icons = ProjectIcons.shared
        _ = icons.revision
        let height = (width * 9 / 16).rounded()
        return ZStack {
            RoundedRectangle(cornerRadius: 5).fill(Theme.field.color)
            if let image = icons.image(for: url) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "film")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textFainter.color)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.border.color, lineWidth: 1))
    }
}

import AppKit
import SwiftUI

/// SwiftUI content that takes files dropped from Finder. The drop lands on
/// an AppKit view around the content, the way AppKit delivers drags, so it
/// works whatever the content is (and `tandem://simulate` can drive it).
struct FileDropZone<Content: View>: View {
    let onFiles: ([URL]) -> Void
    @ViewBuilder var content: () -> Content
    @State private var targeted = false

    var body: some View {
        FileDropArea(content: content(), targeted: $targeted, onFiles: onFiles)
            .overlay {
                if targeted {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Theme.amber.color, lineWidth: 1.5)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.dropTarget.color))
                        .padding(6)
                        .allowsHitTesting(false)
                }
            }
    }
}

private struct FileDropArea<Content: View>: NSViewRepresentable {
    let content: Content
    @Binding var targeted: Bool
    let onFiles: ([URL]) -> Void

    func makeNSView(context: Context) -> FileDropHostingView<Content> {
        let view = FileDropHostingView(rootView: content)
        view.sizingOptions = []
        update(view)
        return view
    }

    func updateNSView(_ view: FileDropHostingView<Content>, context: Context) {
        view.rootView = content
        update(view)
    }

    private func update(_ view: FileDropHostingView<Content>) {
        view.onFiles = onFiles
        view.onTargeted = { on in
            if targeted != on { targeted = on }
        }
    }
}

/// A hosting view registered for file URLs.
final class FileDropHostingView<Content: View>: NSHostingView<Content> {
    var onFiles: (([URL]) -> Void)?
    var onTargeted: ((Bool) -> Void)?

    required init(rootView: Content) {
        super.init(rootView: rootView)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func files(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !files(sender).isEmpty else { return [] }
        onTargeted?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        files(sender).isEmpty ? [] : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onTargeted?(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onTargeted?(false)
        let urls = files(sender)
        guard !urls.isEmpty else { return false }
        onFiles?(urls)
        return true
    }
}

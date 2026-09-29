import CoreGraphics
import Foundation

/// How big the editor's panels are: the media library on the left, the
/// inspector on the right, and the workspace over the timeline. Dragging
/// the dividers between them changes these, and they're kept in the app's
/// preferences so a restart keeps the layout.
struct PanelSizes: Equatable {
    var libraryWidth: CGFloat
    var inspectorWidth: CGFloat
    /// Nil until the split is dragged: until then it follows the window.
    var workspaceHeight: CGFloat?

    static let standard = PanelSizes(libraryWidth: Theme.Metrics.mediaPanelWidth, inspectorWidth: Theme.Metrics.inspectorWidth, workspaceHeight: nil)
    static let libraryRange: ClosedRange<CGFloat> = 240...560
    static let inspectorRange: ClosedRange<CGFloat> = 300...600
    /// The viewer keeps at least this much between the side panels.
    static let minimumViewerWidth: CGFloat = 420
    /// The two 1 pt divider lines.
    static let dividers: CGFloat = 2

    /// The side panels' widths in a window `windowWidth` wide. When the
    /// window is too narrow for both and the viewer, they give up room in
    /// proportion to how far each is over its minimum. The saved widths
    /// stay as they are, so widening the window brings them back.
    func fitted(windowWidth: CGFloat) -> (library: CGFloat, inspector: CGFloat) {
        var library = Self.libraryRange.clamp(libraryWidth)
        var inspector = Self.inspectorRange.clamp(inspectorWidth)
        let over = library + inspector + Self.minimumViewerWidth + Self.dividers - windowWidth
        let spareLibrary = library - Self.libraryRange.lowerBound
        let spareInspector = inspector - Self.inspectorRange.lowerBound
        let spare = spareLibrary + spareInspector
        if over > 0, spare > 0 {
            let take = min(over, spare)
            library -= take * spareLibrary / spare
            inspector -= take * spareInspector / spare
        }
        return (library, inspector)
    }

    /// A library width from a drag: within its range, leaving the viewer
    /// its minimum next to the inspector as it's shown.
    func library(dragged width: CGFloat, windowWidth: CGFloat) -> CGFloat {
        let inspector = fitted(windowWidth: windowWidth).inspector
        let room = windowWidth - inspector - Self.minimumViewerWidth - Self.dividers
        return Self.libraryRange.clamp(min(width, room))
    }

    /// An inspector width from a drag, the same way.
    func inspector(dragged width: CGFloat, windowWidth: CGFloat) -> CGFloat {
        let library = fitted(windowWidth: windowWidth).library
        let room = windowWidth - library - Self.minimumViewerWidth - Self.dividers
        return Self.inspectorRange.clamp(min(width, room))
    }

    // MARK: - Preferences

    private static let libraryKey = "panelLibraryWidth"
    private static let inspectorKey = "panelInspectorWidth"
    private static let workspaceKey = "panelWorkspaceHeight"

    static func load(from store: UserDefaults = AppDefaults.store) -> PanelSizes {
        func number(_ key: String) -> CGFloat? {
            (store.object(forKey: key) as? NSNumber).map { CGFloat($0.doubleValue) }
        }
        return PanelSizes(
            libraryWidth: number(libraryKey).map(libraryRange.clamp) ?? standard.libraryWidth,
            inspectorWidth: number(inspectorKey).map(inspectorRange.clamp) ?? standard.inspectorWidth,
            workspaceHeight: number(workspaceKey)
        )
    }

    func save(to store: UserDefaults = AppDefaults.store) {
        store.set(Double(libraryWidth), forKey: Self.libraryKey)
        store.set(Double(inspectorWidth), forKey: Self.inspectorKey)
        if let workspaceHeight {
            store.set(Double(workspaceHeight), forKey: Self.workspaceKey)
        } else {
            store.removeObject(forKey: Self.workspaceKey)
        }
    }
}

extension ClosedRange where Bound == CGFloat {
    func clamp(_ value: CGFloat) -> CGFloat {
        Swift.min(Swift.max(value, lowerBound), upperBound)
    }
}

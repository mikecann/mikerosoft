import AppKit
import TandemCore

/// Every cursor Tandem shows, named for what a press there would do. Views
/// work out the kind with the functions here, which are tested, and only
/// set its `nsCursor`.
///
/// macOS 26 draws `resizeLeftRight` as `columnResize` (a bar with arrows)
/// and `resizeUpDown` as `rowResize`, so a trim uses the window-edge double
/// arrow instead, keeping the bar for a roll: the cut it moves is the line
/// between two clips.
enum CursorKind: Equatable {
    case arrow
    /// Something a drag moves as it is: the selected layer in the viewer, a
    /// marker, a clip under the slip or slide tool.
    case grab
    /// While that drag runs.
    case grabbing
    /// A corner handle of the viewer's selection box: drag to scale.
    case scaleCorner(ViewerCorner)
    /// A clip's edge: drag to trim it.
    case trim
    /// The cut between two clips, with the roll tool: drag to move it.
    case roll
    /// The blade tool over a clip it can cut.
    case blade
    /// The line under a track: drag to set its height.
    case rowResize
    /// A keyframe: click to go to it, drag to move it.
    case pointer
    /// The viewer with Z held: drag a box to zoom into it.
    case zoomIn

    var nsCursor: NSCursor {
        switch self {
        case .arrow: return .arrow
        case .grab: return .openHand
        case .grabbing: return .closedHand
        case .scaleCorner(let corner): return .frameResize(position: corner.position, directions: .all)
        case .trim: return .frameResize(position: .left, directions: .all)
        case .roll: return .columnResize
        case .blade: return Self.bladeCursor
        case .rowResize: return .rowResize
        case .pointer: return .pointingHand
        case .zoomIn: return .zoomIn
        }
    }

    func set() { nsCursor.set() }

    static let all: [CursorKind] = [.arrow, .grab, .grabbing, .trim, .roll, .blade, .rowResize, .pointer, .zoomIn]
        + ViewerCorner.allCases.map { .scaleCorner($0) }

    /// The kind `cursor` shows, or "other" (a text field's I-beam, say),
    /// for the `tandem://debug` dump.
    static func describe(_ cursor: NSCursor) -> String {
        if let kind = all.first(where: { $0.nsCursor === cursor }) { return "\(kind)" }
        // The arrow and the I-beam have no image to compare (macOS draws
        // them), so only a cursor with one is matched by its picture.
        guard cursor.image.size != .zero, let image = cursor.image.tiffRepresentation else { return "other" }
        return all.first { $0.nsCursor.image.tiffRepresentation == image }.map { "\($0)" } ?? "other"
    }

    /// A cut line with scissors pointing at it; the hot spot is on the line.
    private static let bladeCursor: NSCursor = {
        let image = NSImage(size: NSSize(width: 28, height: 24), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            // White round black, like the system cursors, so it shows on
            // any clip colour.
            let line = CGRect(x: 5, y: 2, width: 2, height: 20)
            context.setFillColor(NSColor.white.cgColor)
            context.fill(line.insetBy(dx: -1, dy: -1))
            context.setFillColor(NSColor.black.cgColor)
            context.fill(line)
            let base = NSImage.SymbolConfiguration(pointSize: 11, weight: .bold)
            guard let symbol = NSImage(systemSymbolName: "scissors", accessibilityDescription: nil)?.withSymbolConfiguration(base),
                  let outline = symbol.withSymbolConfiguration(base.applying(.init(paletteColors: [.white]))),
                  let fill = symbol.withSymbolConfiguration(base.applying(.init(paletteColors: [.black]))) else { return true }
            let rect = CGRect(x: 10, y: 12 - symbol.size.height / 2, width: symbol.size.width, height: symbol.size.height)
            for dx in [-1.0, 0, 1] {
                for dy in [-1.0, 0, 1] where dx != 0 || dy != 0 {
                    outline.draw(in: rect.offsetBy(dx: dx, dy: dy), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                }
            }
            fill.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 6, y: 12))
    }()
}

/// A corner of the viewer's selection box.
enum ViewerCorner: CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight

    var position: NSCursor.FrameResizePosition {
        switch self {
        case .topLeft: return .topLeft
        case .topRight: return .topRight
        case .bottomLeft: return .bottomLeft
        case .bottomRight: return .bottomRight
        }
    }
}

/// The corner handles of the selected layer's box in the viewer, drawn,
/// pressed and hovered alike. Points are in the overlay's coordinates, y
/// down.
enum ViewerHandles {
    /// The side of a handle's square.
    static let size: CGFloat = 7
    /// How far outside its square a press still takes a handle.
    static let reach: CGFloat = 4

    static func rects(for box: CGRect) -> [(corner: ViewerCorner, rect: CGRect)] {
        [
            (.topLeft, CGPoint(x: box.minX, y: box.minY)), (.topRight, CGPoint(x: box.maxX, y: box.minY)),
            (.bottomLeft, CGPoint(x: box.minX, y: box.maxY)), (.bottomRight, CGPoint(x: box.maxX, y: box.maxY))
        ].map { corner, centre in
            (corner, CGRect(x: centre.x - size / 2, y: centre.y - size / 2, width: size, height: size))
        }
    }

    /// The corner whose handle is under `point`.
    static func corner(at point: CGPoint, box: CGRect) -> ViewerCorner? {
        rects(for: box).first { $0.rect.insetBy(dx: -reach, dy: -reach).contains(point) }?.corner
    }

    /// Over the viewer: zoom while Z is held, scale on a handle, move inside
    /// the selected layer's box, and the arrow elsewhere (a click there
    /// selects).
    static func cursor(at point: CGPoint, box: CGRect?, zoomKeyHeld: Bool) -> CursorKind {
        if zoomKeyHeld { return .zoomIn }
        guard let box else { return .arrow }
        if let corner = corner(at: point, box: box) { return .scaleCorner(corner) }
        return box.contains(point) ? .grab : .arrow
    }
}

extension CursorKind {
    /// Over the timeline's lanes: what a press would start there. `press`
    /// is that drag (`DragKind.forPress`), nil when a press starts none, as
    /// on a locked track.
    static func timeline(hit: TimelineHit, tool: TimelineTool, overKeyframe: Bool, press: DragKind?, project: Project) -> CursorKind {
        if tool == .blade {
            guard case .clip(_, let trackID, _) = hit, project.track(trackID)?.locked == false else { return .arrow }
            return .blade
        }
        if overKeyframe { return .pointer }
        switch press {
        case .trim?: return .trim
        case .roll?: return .roll
        case .slip?, .slide?: return .grab
        // Clips move with the arrow, as in other editors.
        case .move?, nil: return .arrow
        }
    }

    /// While a timeline drag runs.
    static func dragging(_ kind: DragKind) -> CursorKind {
        switch kind {
        case .trim: return .trim
        case .roll: return .roll
        case .slip, .slide: return .grabbing
        case .move: return .arrow
        }
    }
}

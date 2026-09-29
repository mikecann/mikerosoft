import AppKit
import QuartzCore

/// The dashed amber line at the time a drag snaps to. It's a layer that
/// moves, so the line doesn't repaint the lanes under it.
@MainActor
final class SnapLineView: NSView {
    private let shape = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        shape.fillColor = nil
        shape.strokeColor = Theme.amber.opacity(0.9).cg
        shape.lineWidth = 1
        shape.lineDashPattern = [4, 3]
        shape.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(shape)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Shows the line down the whole point at `x`, `height` tall.
    func show(atX x: CGFloat, height: CGFloat) {
        let frame = CGRect(x: x, y: 0, width: 1, height: height)
        if self.frame != frame {
            self.frame = frame
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            shape.frame = bounds
            // Dashes start at the top, whichever way the layer runs.
            let path = CGMutablePath()
            let top: CGFloat = shape.contentsAreFlipped() ? 0 : height
            path.move(to: CGPoint(x: 0.5, y: top))
            path.addLine(to: CGPoint(x: 0.5, y: height - top))
            shape.path = path
            CATransaction.commit()
        }
        isHidden = false
    }
}

/// The small label beside the pointer while dragging ("+00:01:12",
/// "Add label at 01:40:00"). Its own view, so it moves without repainting
/// the lanes.
@MainActor
final class DragLabelView: NSView {
    private var text = ""
    private static let font = Theme.Fonts.digits(10.5, .semibold)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Shows `text` up and to the right of `point` (the lanes' view
    /// coordinates), kept inside `area`.
    func show(_ text: String, near point: CGPoint, in area: CGRect) {
        let width = TextMetrics.width(of: text, font: Self.font)
        let frame = CGRect(x: min(point.x + 12, area.width - width - 14), y: max(2, point.y - 22), width: width + 10, height: 16).integral
        if self.frame != frame { self.frame = frame }
        if text != self.text {
            self.text = text
            needsDisplay = true
        }
        isHidden = false
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.addPath(CGPath(roundedRect: bounds, cornerWidth: 4, cornerHeight: 4, transform: nil))
        context.setFillColor(Theme.raised.cg)
        context.fillPath()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(
            with: CGRect(x: 5, y: 1.5, width: bounds.width - 5, height: Self.font.pointSize + 5), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: [.font: Self.font, .foregroundColor: Theme.text.ns, .paragraphStyle: paragraph]
        )
    }
}

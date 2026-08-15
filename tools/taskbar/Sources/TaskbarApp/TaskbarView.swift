import AppKit

final class TaskbarView: NSView {
    var items: [TaskbarItem] = []
    var settings: TaskbarSettingValues = .defaults
    var onActivate: ((TaskbarItem) -> Void)?
    var onMenu: (() -> NSMenu)?
    var onItemMenu: ((TaskbarItem) -> NSMenu?)?
    var onWidgetMenu: ((TaskbarWidgetID) -> NSMenu?)?
    var onWidgetActivate: ((TaskbarWidgetID, StatsWidgetMetric?, NSRect, NSView) -> Void)?
    var onMovePinnedItem: ((TaskbarItem, TaskbarItem?) -> Void)?
    var onMeasurePreferredTileWidth: (() -> Void)?

    private var tileRects: [(NSRect, TaskbarItem)] = []
    private var widgetRects: [(NSRect, TaskbarWidgetID)] = []
    private var mouseDownItem: TaskbarItem?
    private var mouseDownPoint: NSPoint?
    private var mouseDownWidget: (rect: NSRect, id: TaskbarWidgetID, statsMetric: StatsWidgetMetric?)?
    private var didDragPinnedItem = false
    private var hoverTrackingArea: NSTrackingArea?
    private(set) var hoveredItemKey: String?
    var pointerLocationProvider: (() -> NSPoint?)?
    private var tileHeight: CGFloat {
        max(18, bounds.height - 8)
    }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    func update(items: [TaskbarItem], settings: TaskbarSettingValues) {
        self.items = items
        self.settings = settings
        refreshLayout()
        updateHover(at: currentPointerLocation())
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        refreshLayout()
        updateHover(at: currentPointerLocation())
    }

    override func draw(_ dirtyRect: NSRect) {
        for (rect, item) in tileRects {
            drawTile(
                item: item,
                rect: rect,
                isHovered: taskbarItemInteractionKey(item) == hoveredItemKey
            )
        }

        drawWidgets()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: taskbarPointerCursor())
    }

    override func mouseEntered(with event: NSEvent) {
        // A neighbouring window can leave its resize cursor active as the
        // pointer crosses directly onto this borderless panel.
        taskbarPointerCursor().set()
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        taskbarPointerCursor().set()
        let point = convert(event.locationInWindow, from: nil)
        updateHover(at: point)
    }

    override func mouseExited(with event: NSEvent) {
        updateHover(at: nil)
    }

    private func updateHover(at point: NSPoint?) {
        let item = point.flatMap { point in
            taskbarHoverTarget(
                at: point,
                tileRects: tileRects.map { (rect: $0.0, item: $0.1) },
                bounds: bounds
            )
        }
        let key = item.map(taskbarItemInteractionKey)
        guard key != hoveredItemKey else { return }
        hoveredItemKey = key
        needsDisplay = true
    }

    private func currentPointerLocation() -> NSPoint? {
        if let pointerLocationProvider {
            return pointerLocationProvider()
        }
        guard let window else { return nil }
        return convert(window.mouseLocationOutsideOfEventStream, from: nil)
    }

    func frontmostTileLayout() -> (rect: NSRect, item: TaskbarItem)? {
        tileRects
            .first { _, item in item.isFrontmost }
            .map { (rect: $0.0, item: $0.1) }
    }

    private func refreshLayout() {
        let layout = makeLayout()
        tileRects = layout.tiles
        widgetRects = layout.widgets
    }

    private func makeLayout() -> TaskbarLayout {
        taskbarLayout(
            bounds: bounds,
            items: items,
            settings: settings,
            tileHeight: tileHeight,
            preferredTileWidths: items.map { preferredTileWidth(for: $0) }
        )
    }

    override func mouseDown(with event: NSEvent) {
        resetMousePressState()
        let point = convert(event.locationInWindow, from: nil)
        if let widget = widgetHit(at: point) {
            mouseDownWidget = widget
            return
        }

        guard let item = tileRects.first(where: { taskbarInteractionRect(for: $0.0, in: bounds).contains(point) })?.1 else { return }
        mouseDownItem = item
        mouseDownPoint = point
    }

    override func mouseDragged(with event: NSEvent) {
        guard mouseDownItem?.isPinned == true, let mouseDownPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        didDragPinnedItem = updatedTaskbarPinnedDragState(
            wasDragging: didDragPinnedItem,
            mouseDownPoint: mouseDownPoint,
            currentPoint: point
        )
    }

    override func mouseUp(with event: NSEvent) {
        defer { resetMousePressState() }

        let point = convert(event.locationInWindow, from: nil)
        if let widget = mouseDownWidget, taskbarInteractionRect(for: widget.rect, in: bounds).contains(point) {
            onWidgetActivate?(widget.id, widget.statsMetric, widget.rect, self)
            return
        }

        guard let item = mouseDownItem, let mouseDownPoint else { return }

        switch resolveTaskbarMouseUpAction(
            pressedItem: item,
            mouseDownPoint: mouseDownPoint,
            mouseUpPoint: point,
            didDragPinnedItem: didDragPinnedItem,
            tileRects: tileRects.map { (rect: $0.0, item: $0.1) },
            bounds: bounds
        ) {
        case .activate:
            onActivate?(item)
        case .movePinnedItem(let target):
            onMovePinnedItem?(item, target)
        case .none:
            break
        }
    }

    private func resetMousePressState() {
        mouseDownItem = nil
        mouseDownPoint = nil
        mouseDownWidget = nil
        didDragPinnedItem = false
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let item = tileRects.first(where: { taskbarInteractionRect(for: $0.0, in: bounds).contains(point) })?.1,
           let itemMenu = onItemMenu?(item) {
            NSMenu.popUpContextMenu(itemMenu, with: event, for: self)
            return
        }

        if let widgetID = widgetRects.first(where: { taskbarInteractionRect(for: $0.0, in: bounds).contains(point) })?.1,
           let widgetMenu = onWidgetMenu?(widgetID) {
            NSMenu.popUpContextMenu(widgetMenu, with: event, for: self)
            return
        }

        guard let menu = onMenu?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private func widgetHit(at point: NSPoint) -> (rect: NSRect, id: TaskbarWidgetID, statsMetric: StatsWidgetMetric?)? {
        guard let widget = widgetRects.first(where: { taskbarInteractionRect(for: $0.0, in: bounds).contains(point) }) else {
            return nil
        }

        guard widget.1 == .stats,
              let metric = statsWidgetMetric(at: point, in: widget.0, settings: settings.statsWidget),
              let metricRect = statsWidgetMetricRect(metric, in: widget.0, settings: settings.statsWidget)
        else {
            return (rect: widget.0, id: widget.1, statsMetric: nil)
        }

        return (rect: metricRect, id: widget.1, statsMetric: metric)
    }

    private func preferredTileWidth(for item: TaskbarItem) -> CGFloat {
        onMeasurePreferredTileWidth?()
        let label = taskbarItemLabel(item)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 12)
        ]
        let textWidth = ceil((label as NSString).size(withAttributes: attributes).width)
        let iconSize = TaskbarItemMetrics.iconSize(for: tileHeight)
        return preferredTaskbarItemWidth(
            for: item,
            textWidth: textWidth,
            iconSize: iconSize,
            minimumWidth: CGFloat(settings.minimumItemWidth),
            maximumWidth: CGFloat(settings.maximumItemWidth)
        )
    }

    private func drawTile(item: TaskbarItem, rect: NSRect, isHovered: Bool) {
        if isHovered {
            let hoverRect = rect.insetBy(dx: 0.5, dy: 0.5)
            let hoverPath = NSBezierPath(roundedRect: hoverRect, xRadius: 6, yRadius: 6)
            NSColor.white.withAlphaComponent(0.07).setFill()
            hoverPath.fill()
            NSColor.white.withAlphaComponent(0.10).setStroke()
            hoverPath.lineWidth = 1
            hoverPath.stroke()
        }

        let preferredIconSize = TaskbarItemMetrics.iconSize(for: rect.height)
        let iconSize = min(preferredIconSize, max(0, rect.width - 2))
        guard iconSize > 0 else { return }

        let wantsLabel = taskbarItemShowsLabel(item)
            && rect.width >= TaskbarItemMetrics.leadingInset
            + iconSize
            + TaskbarItemMetrics.iconTextGap
            + 4
            + TaskbarItemMetrics.trailingInset
        let iconX: CGFloat
        if wantsLabel {
            iconX = rect.minX + TaskbarItemMetrics.leadingInset
        } else {
            iconX = rect.minX + max(0, (rect.width - iconSize) / 2)
        }
        let iconRect = NSRect(
            x: iconX,
            y: rect.midY - iconSize / 2,
            width: iconSize,
            height: iconSize
        )
        if item.isMinimized, let context = NSGraphicsContext.current {
            context.saveGraphicsState()
            context.cgContext.setAlpha(0.45)
            drawTaskbarIcon(
                item: item,
                rect: iconRect
            )
            context.restoreGraphicsState()
        } else {
            drawTaskbarIcon(
                item: item,
                rect: iconRect
            )
        }

        guard wantsLabel else { return }
        let label = taskbarItemLabel(item)
        let labelX = iconRect.maxX + TaskbarItemMetrics.iconTextGap
        let labelWidth = max(0, rect.maxX - labelX - TaskbarItemMetrics.trailingInset)
        guard labelWidth > 1 else { return }

        drawTaskbarText(
            label,
            in: NSRect(
                x: labelX,
                y: rect.midY - 7.5,
                width: labelWidth,
                height: 15
            ),
            size: min(12, max(10, rect.height - 5)),
            bold: true,
            active: item.isFrontmost,
            textColor: item.isMinimized ? NSColor(calibratedWhite: 0.58, alpha: 1.0) : nil
        )
    }

    private func drawWidgets() {
        let widgetsByID = Dictionary(uniqueKeysWithValues: activeTaskbarWidgets(for: settings).map { ($0.id, $0) })
        let date = Date()
        for (rect, widgetID) in widgetRects {
            widgetsByID[widgetID]?.draw(in: rect, values: settings, date: date)
        }
    }
}

struct TaskbarLayout {
    let tiles: [(rect: NSRect, item: TaskbarItem)]
    let widgets: [(rect: NSRect, id: TaskbarWidgetID)]
}

func taskbarLayout(
    bounds: NSRect,
    items: [TaskbarItem],
    settings: TaskbarSettingValues,
    tileHeight: CGFloat,
    preferredTileWidths: [CGFloat]
) -> TaskbarLayout {
    precondition(items.count == preferredTileWidths.count)

    let leftPadding: CGFloat = 6
    let widgets = activeTaskbarWidgets(for: settings)
    let widgetSpacing = taskbarWidgetSpacing(widgetSpacing: CGFloat(settings.widgetSpacing))
    let trailingWidth: CGFloat
    if widgets.isEmpty {
        trailingWidth = 8
    } else {
        let minimumWidgetWidths = widgets.reduce(CGFloat(0)) { total, widget in
            total + widget.minimumWidth(in: settings, height: tileHeight)
        }
        trailingWidth = minimumWidgetWidths
            + widgetSpacing * CGFloat(max(0, widgets.count - 1))
            + 12
    }

    var tiles: [(rect: NSRect, item: TaskbarItem)] = []
    if !items.isEmpty {
        var x = leftPadding
        let y: CGFloat = max(2, (bounds.height - tileHeight) / 2)
        let maxTileX = bounds.width - trailingWidth - 8
        let availableWidth = max(0, maxTileX - leftPadding)
        let itemCount = CGFloat(items.count)
        let gapCount = max(0, itemCount - 1)
        let minimumTileWidth: CGFloat = 1
        let gapBudget = max(0, availableWidth - minimumTileWidth * itemCount)
        let effectiveItemSpacing: CGFloat
        if gapCount > 0 {
            effectiveItemSpacing = min(CGFloat(settings.itemSpacing), gapBudget / gapCount)
        } else {
            effectiveItemSpacing = 0
        }
        let availableTileWidth = max(0, availableWidth - effectiveItemSpacing * gapCount)
        let softMinimumWidth = TaskbarItemMetrics.iconOnlyWidth(
            iconSize: TaskbarItemMetrics.iconSize(for: tileHeight)
        )
        let fittedWidths = fittedTaskbarItemWidths(
            preferredWidths: preferredTileWidths,
            softMinimumWidth: softMinimumWidth,
            availableWidth: availableTileWidth
        )

        for (item, tileWidth) in zip(items, fittedWidths) {
            let rect = NSRect(x: x, y: y, width: tileWidth, height: tileHeight)
            tiles.append((rect, item))
            x += tileWidth + effectiveItemSpacing
        }
    }

    guard !widgets.isEmpty else {
        return TaskbarLayout(tiles: tiles, widgets: [])
    }

    let lastTileMaxX = tiles.map { $0.rect.maxX }.max() ?? leftPadding
    let leftLimit = min(bounds.width - 8, max(lastTileMaxX + 8, leftPadding))
    var rightX = bounds.width - 8
    let availableTrailingWidth = max(0, rightX - leftLimit)
    let y: CGFloat = max(2, (bounds.height - tileHeight) / 2)
    let widgetMinimumWidths = widgets.map { widget in
        widget.minimumWidth(in: settings, height: tileHeight)
    }
    let requiredWidth = widgetMinimumWidths.reduce(0, +)
        + widgetSpacing * CGFloat(max(0, widgets.count - 1))
    var extraWidth = max(0, availableTrailingWidth - requiredWidth)
    var widgetRects: [(rect: NSRect, id: TaskbarWidgetID)] = []
    for (widget, minimumWidth) in zip(widgets, widgetMinimumWidths).reversed() {
        let availableWidth = minimumWidth + extraWidth
        let preferredWidth = widget.preferredWidth(
            in: settings,
            height: tileHeight,
            availableWidth: availableWidth
        )
        let width = min(max(minimumWidth, preferredWidth), availableWidth)
        let rect = NSRect(
            x: rightX - width,
            y: y,
            width: width,
            height: tileHeight
        )
        widgetRects.append((rect, widget.id))
        extraWidth = max(0, extraWidth - (width - minimumWidth))
        rightX = rect.minX - widgetSpacing
    }

    return TaskbarLayout(tiles: tiles, widgets: Array(widgetRects.reversed()))
}

func taskbarInteractionRect(for visualRect: NSRect, in bounds: NSRect) -> NSRect {
    NSRect(
        x: visualRect.minX,
        y: bounds.minY,
        width: visualRect.width,
        height: bounds.height
    )
}

func taskbarPointerCursor() -> NSCursor {
    .arrow
}

func taskbarHoverTarget(
    at point: NSPoint,
    tileRects: [(rect: NSRect, item: TaskbarItem)],
    bounds: NSRect
) -> TaskbarItem? {
    tileRects.first {
        taskbarInteractionRect(for: $0.rect, in: bounds).contains(point)
    }?.item
}

private func taskbarItemInteractionKey(_ item: TaskbarItem) -> String {
    "\(item.identity)#\(item.windowIDs.first.map(String.init) ?? "pinned")"
}

func taskbarWidgetSpacing(widgetSpacing: CGFloat) -> CGFloat {
    max(0, widgetSpacing)
}

enum TaskbarMouseUpAction: Equatable {
    case activate
    case movePinnedItem(before: TaskbarItem)
    case none
}

let taskbarPinnedDragThreshold: CGFloat = 4

func updatedTaskbarPinnedDragState(
    wasDragging: Bool,
    mouseDownPoint: NSPoint,
    currentPoint: NSPoint,
    threshold: CGFloat = taskbarPinnedDragThreshold
) -> Bool {
    guard !wasDragging else { return true }
    let deltaX = currentPoint.x - mouseDownPoint.x
    let deltaY = currentPoint.y - mouseDownPoint.y
    return deltaX * deltaX + deltaY * deltaY >= threshold * threshold
}

func resolveTaskbarMouseUpAction(
    pressedItem: TaskbarItem,
    mouseDownPoint: NSPoint,
    mouseUpPoint: NSPoint,
    didDragPinnedItem: Bool,
    tileRects: [(rect: NSRect, item: TaskbarItem)],
    bounds: NSRect,
    dragThreshold: CGFloat = taskbarPinnedDragThreshold
) -> TaskbarMouseUpAction {
    let isPinnedDrag = pressedItem.isPinned
        && updatedTaskbarPinnedDragState(
            wasDragging: didDragPinnedItem,
            mouseDownPoint: mouseDownPoint,
            currentPoint: mouseUpPoint,
            threshold: dragThreshold
        )

    if isPinnedDrag {
        guard let target = tileRects.first(where: { rect, item in
            item.isPinned
                && item.identity != pressedItem.identity
                && taskbarInteractionRect(for: rect, in: bounds).contains(mouseUpPoint)
        })?.item else {
            return .none
        }

        return .movePinnedItem(before: target)
    }

    guard let pressedTileRect = tileRects.first(where: { rect, item in
        item.identity == pressedItem.identity
            && taskbarInteractionRect(for: rect, in: bounds).contains(mouseDownPoint)
    })?.rect,
    taskbarInteractionRect(for: pressedTileRect, in: bounds).contains(mouseUpPoint) else {
        return .none
    }

    return .activate
}

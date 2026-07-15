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

    private var tileRects: [(NSRect, TaskbarItem)] = []
    private var widgetRects: [(NSRect, TaskbarWidgetID)] = []
    private var mouseDownItem: TaskbarItem?
    private var mouseDownWidget: (rect: NSRect, id: TaskbarWidgetID, statsMetric: StatsWidgetMetric?)?
    private var didDragPinnedItem = false
    private let leftPadding: CGFloat = 6
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
        tileRects = tileLayout()
        widgetRects = widgetLayout(after: tileRects)
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        tileRects = tileLayout()
        widgetRects = widgetLayout(after: tileRects)
    }

    override func draw(_ dirtyRect: NSRect) {
        for (rect, item) in tileRects {
            drawTile(item: item, rect: rect)
        }

        drawWidgets()
    }

    func frontmostTileLayout() -> (rect: NSRect, item: TaskbarItem)? {
        tileLayout()
            .first { _, item in item.isFrontmost }
            .map { (rect: $0.0, item: $0.1) }
    }

    private func tileLayout() -> [(NSRect, TaskbarItem)] {
        var layout: [(NSRect, TaskbarItem)] = []
        guard !items.isEmpty else { return layout }

        var x = leftPadding
        let y: CGFloat = max(2, (bounds.height - tileHeight) / 2)
        let maxTileX = bounds.width - trailingWidth() - 8
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
        let preferredWidths = items.map { preferredTileWidth(for: $0) }
        let softMinimumWidth = TaskbarItemMetrics.iconOnlyWidth(iconSize: TaskbarItemMetrics.iconSize(for: tileHeight))
        let fittedWidths = fittedTaskbarItemWidths(
            preferredWidths: preferredWidths,
            softMinimumWidth: softMinimumWidth,
            availableWidth: availableTileWidth
        )

        for (item, tileWidth) in zip(items, fittedWidths) {
            let rect = NSRect(x: x, y: y, width: tileWidth, height: tileHeight)
            layout.append((rect, item))
            x += tileWidth + effectiveItemSpacing
        }

        return layout
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let widget = widgetHit(at: point) {
            mouseDownWidget = widget
            mouseDownItem = nil
            return
        }

        guard let item = tileRects.first(where: { taskbarInteractionRect(for: $0.0, in: bounds).contains(point) })?.1 else { return }
        mouseDownItem = item
        mouseDownWidget = nil
        didDragPinnedItem = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard mouseDownItem?.isPinned == true else { return }
        didDragPinnedItem = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownItem = nil
            mouseDownWidget = nil
            didDragPinnedItem = false
        }

        let point = convert(event.locationInWindow, from: nil)
        if let widget = mouseDownWidget, taskbarInteractionRect(for: widget.rect, in: bounds).contains(point) {
            onWidgetActivate?(widget.id, widget.statsMetric, widget.rect, self)
            return
        }

        guard let item = mouseDownItem else { return }

        if didDragPinnedItem, item.isPinned {
            let target = tileRects
                .first(where: { rect, targetItem in
                    taskbarInteractionRect(for: rect, in: bounds).contains(point)
                        && targetItem.isPinned
                        && targetItem.identity != item.identity
                })?
                .1
            onMovePinnedItem?(item, target)
            return
        }

        onActivate?(item)
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
        let label = taskbarItemLabel(item)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 12)
        ]
        let textWidth = ceil((label as NSString).size(withAttributes: attributes).width)
        let iconSize = TaskbarItemMetrics.iconSize(for: tileHeight)
        return taskbarItemWidth(
            textWidth: textWidth,
            iconSize: iconSize,
            minimumWidth: CGFloat(settings.minimumItemWidth),
            maximumWidth: CGFloat(settings.maximumItemWidth)
        )
    }

    private func trailingWidth() -> CGFloat {
        let widgets = activeTaskbarWidgets(for: settings)
        guard !widgets.isEmpty else { return 8 }

        let spacing = taskbarWidgetSpacing(itemSpacing: CGFloat(settings.itemSpacing))
        let widgetWidths = widgets.reduce(CGFloat(0)) { total, widget in
            total + widget.minimumWidth(in: settings, height: tileHeight)
        }
        return widgetWidths + spacing * CGFloat(max(0, widgets.count - 1)) + 12
    }

    private func widgetLayout(after tileLayout: [(NSRect, TaskbarItem)]) -> [(NSRect, TaskbarWidgetID)] {
        let widgets = activeTaskbarWidgets(for: settings)
        guard !widgets.isEmpty else { return [] }

        let lastTileMaxX = tileLayout.map { $0.0.maxX }.max() ?? leftPadding
        let leftLimit = min(bounds.width - 8, max(lastTileMaxX + 8, leftPadding))
        var rightX = bounds.width - 8
        let availableTrailingWidth = max(0, rightX - leftLimit)
        let y: CGFloat = max(2, (bounds.height - tileHeight) / 2)
        let spacing = taskbarWidgetSpacing(itemSpacing: CGFloat(settings.itemSpacing))

        var remainingWidth = availableTrailingWidth
        var layout: [(NSRect, TaskbarWidgetID)] = []
        for widget in widgets.reversed() {
            let minimumWidth = widget.minimumWidth(in: settings, height: tileHeight)
            let preferredWidth = widget.preferredWidth(
                in: settings,
                height: tileHeight,
                availableWidth: remainingWidth
            )
            let width = min(max(minimumWidth, preferredWidth), max(minimumWidth, remainingWidth))
            let rect = NSRect(
                x: rightX - width,
                y: y,
                width: width,
                height: tileHeight
            )
            layout.append((rect, widget.id))
            rightX = rect.minX - spacing
            remainingWidth = max(0, rightX - leftLimit)
        }

        return layout.reversed()
    }

    private func drawTile(item: TaskbarItem, rect: NSRect) {
        let preferredIconSize = TaskbarItemMetrics.iconSize(for: rect.height)
        let iconSize = min(preferredIconSize, max(0, rect.width - 2))
        guard iconSize > 0 else { return }

        let wantsLabel = rect.width >= TaskbarItemMetrics.leadingInset
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

func taskbarInteractionRect(for visualRect: NSRect, in bounds: NSRect) -> NSRect {
    NSRect(
        x: visualRect.minX,
        y: bounds.minY,
        width: visualRect.width,
        height: bounds.height
    )
}

func taskbarWidgetSpacing(itemSpacing: CGFloat) -> CGFloat {
    min(max(0, itemSpacing), 2)
}

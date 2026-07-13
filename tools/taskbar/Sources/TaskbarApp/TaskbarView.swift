import AppKit

final class TaskbarView: NSView {
    var items: [TaskbarItem] = []
    var settings: TaskbarSettingValues = .defaults
    var onActivate: ((TaskbarItem) -> Void)?
    var onMenu: (() -> NSMenu)?
    var onItemMenu: ((TaskbarItem) -> NSMenu?)?
    var onMovePinnedItem: ((TaskbarItem, TaskbarItem?) -> Void)?

    private var tileRects: [(NSRect, TaskbarItem)] = []
    private var mouseDownItem: TaskbarItem?
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
        let layout = tileLayout()
        tileRects = layout
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        tileRects = tileLayout()

        for (rect, item) in tileRects {
            drawTile(item: item, rect: rect)
        }

        drawTrailingChrome(clockMode: settings.clockMode)
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
        guard let item = tileRects.first(where: { $0.0.contains(point) })?.1 else {
            return
        }
        mouseDownItem = item
        didDragPinnedItem = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard mouseDownItem?.isPinned == true else { return }
        didDragPinnedItem = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownItem = nil
            didDragPinnedItem = false
        }

        let point = convert(event.locationInWindow, from: nil)
        guard let item = mouseDownItem else { return }

        if didDragPinnedItem, item.isPinned {
            let target = tileRects
                .first(where: { rect, targetItem in
                    rect.contains(point) && targetItem.isPinned && targetItem.identity != item.identity
                })?
                .1
            onMovePinnedItem?(item, target)
            return
        }

        onActivate?(item)
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let item = tileRects.first(where: { $0.0.contains(point) })?.1,
           let itemMenu = onItemMenu?(item) {
            NSMenu.popUpContextMenu(itemMenu, with: event, for: self)
            return
        }

        guard let menu = onMenu?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
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
        switch settings.clockMode {
        case .hidden:
            return 8
        case .time:
            return 54
        case .dateAndTime:
            return 122
        }
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
        drawTaskbarIcon(
            item: item,
            rect: iconRect
        )

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
            active: item.isFrontmost
        )
    }

    private func drawTrailingChrome(clockMode: ClockMode) {
        guard clockMode != .hidden else { return }

        let textY = max(9, bounds.midY - 9)
        let formatter = DateFormatter()
        switch clockMode {
        case .hidden:
            return
        case .time:
            formatter.dateFormat = "HH:mm"
            drawTaskbarText(formatter.string(from: Date()), in: NSRect(x: bounds.width - 48, y: textY, width: 40, height: 18), size: 12, bold: false, active: false)
        case .dateAndTime:
            formatter.dateFormat = "EEE HH:mm"
            drawTaskbarText(formatter.string(from: Date()), in: NSRect(x: bounds.width - 116, y: textY, width: 108, height: 18), size: 12, bold: false, active: false)
        }
    }
}

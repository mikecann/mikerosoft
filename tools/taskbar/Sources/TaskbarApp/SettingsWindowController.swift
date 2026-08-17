import AppKit

enum SettingsSidebarItem: Equatable {
    case general
    case widgets
    case widget(TaskbarWidgetID)
    case divider(String)
    case monitor(ScreenInfo)
    case monitorWidget(ScreenInfo, TaskbarWidgetID)

    var title: String {
        switch self {
        case .general:
            return "General"
        case .widgets:
            return "Widgets"
        case .widget(let widgetID), .monitorWidget(_, let widgetID):
            return taskbarWidgetPlugin(id: widgetID)?.title ?? widgetID.rawValue
        case .divider(let title):
            return title
        case .monitor(let screen):
            return screen.name
        }
    }

    var symbolName: String {
        switch self {
        case .general:
            return "gearshape"
        case .widgets:
            return "puzzlepiece.extension"
        case .widget(let widgetID), .monitorWidget(_, let widgetID):
            return taskbarWidgetPlugin(id: widgetID)?.symbolName ?? "puzzlepiece.extension"
        case .divider:
            return ""
        case .monitor:
            return "display"
        }
    }

    var indentLevel: Int {
        switch self {
        case .general, .widgets, .monitor:
            return 0
        case .divider:
            return 0
        case .widget, .monitorWidget:
            return 1
        }
    }

    var isSelectable: Bool {
        switch self {
        case .divider:
            return false
        case .general, .widgets, .widget, .monitor, .monitorWidget:
            return true
        }
    }

    fileprivate var selectionIdentity: SettingsSidebarSelectionIdentity {
        switch self {
        case .general:
            return .general
        case .widgets:
            return .widgets
        case .widget(let widgetID):
            return .widget(widgetID)
        case .divider(let title):
            return .divider(title)
        case .monitor(let screen):
            return .monitor(screen.id)
        case .monitorWidget(let screen, let widgetID):
            return .monitorWidget(screen.id, widgetID)
        }
    }
}

private enum SettingsSidebarSelectionIdentity: Equatable {
    case general
    case widgets
    case widget(TaskbarWidgetID)
    case divider(String)
    case monitor(UInt32)
    case monitorWidget(UInt32, TaskbarWidgetID)
}

func reconciledSettingsSidebarSelection(
    _ selection: SettingsSidebarItem,
    in items: [SettingsSidebarItem]
) -> SettingsSidebarItem {
    items.first { $0.isSelectable && $0.selectionIdentity == selection.selectionIdentity } ?? .general
}

func taskbarSettingsSidebarItems(
    screens: [ScreenInfo],
    widgets: [TaskbarWidgetID] = installedTaskbarWidgetIDs()
) -> [SettingsSidebarItem] {
    var items: [SettingsSidebarItem] = [
        .general,
        .widgets
    ]
    items.append(contentsOf: widgets.map { .widget($0) })

    if !screens.isEmpty {
        items.append(.divider("Per Monitor"))
    }

    for screen in screens {
        items.append(.monitor(screen))
        items.append(contentsOf: widgets.map { .monitorWidget(screen, $0) })
    }
    return items
}

private final class SettingsSidebarCell: NSTableCellView {
    var imageLeadingConstraint: NSLayoutConstraint?
}

private final class SettingsSidebarDividerCell: NSTableCellView {
    let line = NSBox()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }

    private func build() {
        guard textField == nil else { return }

        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor

        line.translatesAutoresizingMaskIntoConstraints = false
        line.boxType = .separator

        addSubview(label)
        addSubview(line)
        textField = label

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            line.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            line.centerYAnchor.constraint(equalTo: label.centerYAnchor)
        ])
    }
}

private final class PinnedAppButton: NSButton {
    var pinnedApp: PinnedApp?
}

private final class ValueSlider: NSSlider {
    weak var valueLabel: NSTextField?
    var valueFormatter: ((Double) -> String)?

    func refreshValueLabel() {
        valueLabel?.stringValue = valueFormatter?(doubleValue) ?? "\(Int(round(doubleValue)))"
    }
}

private enum StatsCPUCoreColorKind: Int, CaseIterable {
    case superCore
    case performance
    case efficiency

    var title: String {
        switch self {
        case .superCore: return "Super"
        case .performance: return "Performance"
        case .efficiency: return "Efficiency"
        }
    }

    var identifier: String {
        switch self {
        case .superCore: return "stats-super-core-color"
        case .performance: return "stats-performance-core-color"
        case .efficiency: return "stats-efficiency-core-color"
        }
    }

    var colorRole: CPUPerformanceColorRole {
        switch self {
        case .superCore: return .superCore
        case .performance: return .performance
        case .efficiency: return .efficiency
        }
    }
}

protocol TaskbarSettingsWindow: AnyObject {
    var onClose: (() -> Void)? { get set }
    func updateScreens(_ screens: [ScreenInfo])
    func selectMonitor(screenID: UInt32)
    func selectWidget(_ widgetID: TaskbarWidgetID, screenID: UInt32?)
    func showWindow(_ sender: Any?)
}

final class SettingsWindowController: NSWindowController, TaskbarSettingsWindow, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let settings: TaskbarSettings
    private var settingsChangeObservation: TaskbarSettingsChangeObservation?
    private var screens: [ScreenInfo]
    private var sidebarItems: [SettingsSidebarItem] = []
    private let tableView = NSTableView()
    private let detailView = NSView()

    private var selectedItem: SettingsSidebarItem = .general
    private weak var pinCandidatePopup: NSPopUpButton?
    var onClose: (() -> Void)?

    init(settings: TaskbarSettings, screens: [ScreenInfo]) {
        self.settings = settings
        self.screens = screens

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Taskbar Settings"
        window.titlebarAppearsTransparent = false
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
        window.delegate = self

        rebuildSidebarItems()
        buildWindowContent()
        settingsChangeObservation = settings.observeChanges { [weak self] in
            self?.renderDetail()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateScreens(_ screens: [ScreenInfo]) {
        let previousSelection = selectedItem
        self.screens = screens
        rebuildSidebarItems()
        tableView.reloadData()

        selectedItem = reconciledSettingsSidebarSelection(previousSelection, in: sidebarItems)
        let selectedRow = sidebarItems.firstIndex(of: selectedItem) ?? 0
        tableView.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)
        renderDetail()
    }

    func selectMonitor(screenID: UInt32) {
        guard let row = sidebarItems.firstIndex(where: { item in
            if case .monitor(let screen) = item {
                return screen.id == screenID
            }
            return false
        }) else {
            return
        }

        selectedItem = sidebarItems[row]
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        renderDetail()
    }

    func selectWidget(_ widgetID: TaskbarWidgetID, screenID: UInt32? = nil) {
        guard let row = sidebarItems.firstIndex(where: { item in
            switch (item, screenID) {
            case (.widget(let candidateID), nil):
                return candidateID == widgetID
            case (.monitorWidget(let screen, let candidateID), .some(let screenID)):
                return screen.id == screenID && candidateID == widgetID
            default:
                return false
            }
        }) else {
            return
        }

        selectedItem = sidebarItems[row]
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        renderDetail()
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        renderDetail()
    }

    func windowWillClose(_ notification: Notification) {
        settingsChangeObservation?.cancel()
        settingsChangeObservation = nil
        onClose?()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        sidebarItems.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = sidebarItems[row]
        if case .divider = item {
            let identifier = NSUserInterfaceItemIdentifier("SettingsSidebarDividerCell")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? SettingsSidebarDividerCell
                ?? SettingsSidebarDividerCell(frame: .zero)
            cell.identifier = identifier
            cell.textField?.stringValue = item.title
            return cell
        }

        let identifier = NSUserInterfaceItemIdentifier("SettingsSidebarCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? SettingsSidebarCell
            ?? SettingsSidebarCell(frame: .zero)

        if cell.textField == nil || cell.imageView == nil {
            cell.subviews.forEach { $0.removeFromSuperview() }

            let imageView = NSImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
            imageView.contentTintColor = .secondaryLabelColor

            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.lineBreakMode = .byTruncatingTail

            cell.addSubview(imageView)
            cell.addSubview(textField)
            cell.imageView = imageView
            cell.textField = textField

            let imageLeadingConstraint = imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12)
            cell.imageLeadingConstraint = imageLeadingConstraint

            NSLayoutConstraint.activate([
                imageLeadingConstraint,
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 18),
                imageView.heightAnchor.constraint(equalToConstant: 18),

                textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 8),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }

        cell.identifier = identifier
        cell.imageLeadingConstraint?.constant = 12 + CGFloat(item.indentLevel * 18)
        cell.imageView?.image = symbol(item.symbolName)
        cell.textField?.stringValue = item.title
        cell.textField?.font = item.indentLevel == 0 ? .systemFont(ofSize: 13, weight: .regular) : .systemFont(ofSize: 12, weight: .regular)
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        sidebarItems[row].isSelectable ? 34 : 24
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        sidebarItems[row].isSelectable
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard sidebarItems.indices.contains(row) else { return }
        guard sidebarItems[row].isSelectable else { return }
        selectedItem = sidebarItems[row]
        renderDetail()
    }

    private func rebuildSidebarItems() {
        sidebarItems = taskbarSettingsSidebarItems(screens: screens)
    }

    private func buildWindowContent() {
        guard let contentView = window?.contentView else { return }

        let splitView = NSSplitView()
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        contentView.addSubview(splitView)

        NSLayoutConstraint.activate([
            splitView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            splitView.topAnchor.constraint(equalTo: contentView.topAnchor),
            splitView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        let sidebarScroll = NSScrollView()
        sidebarScroll.translatesAutoresizingMaskIntoConstraints = false
        sidebarScroll.hasVerticalScroller = false
        sidebarScroll.drawsBackground = true
        sidebarScroll.backgroundColor = NSColor.windowBackgroundColor

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("SettingsSidebarColumn"))
        column.width = 210
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 34
        tableView.selectionHighlightStyle = .regular
        tableView.dataSource = self
        tableView.delegate = self
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        sidebarScroll.documentView = tableView

        let detailScroll = NSScrollView()
        detailScroll.translatesAutoresizingMaskIntoConstraints = false
        detailScroll.hasVerticalScroller = true
        detailScroll.drawsBackground = false
        detailView.translatesAutoresizingMaskIntoConstraints = false
        detailScroll.documentView = detailView

        splitView.addArrangedSubview(sidebarScroll)
        splitView.addArrangedSubview(detailScroll)

        sidebarScroll.widthAnchor.constraint(equalToConstant: 210).isActive = true
        detailView.widthAnchor.constraint(equalTo: detailScroll.contentView.widthAnchor).isActive = true
        renderDetail()
    }

    private func renderDetail() {
        detailView.subviews.forEach { $0.removeFromSuperview() }
        pinCandidatePopup = nil

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        detailView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: detailView.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: detailView.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: detailView.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: detailView.bottomAnchor, constant: -28)
        ])

        switch selectedItem {
        case .general:
            renderGeneral(in: stack)
        case .widgets:
            renderWidgets(in: stack)
        case .widget(let widgetID):
            renderWidget(widgetID, screen: nil, in: stack)
        case .divider:
            renderGeneral(in: stack)
        case .monitor(let screen):
            renderMonitor(screen, in: stack)
        case .monitorWidget(let screen, let widgetID):
            renderWidget(widgetID, screen: screen, in: stack)
        }
    }

    private func renderGeneral(in stack: NSStackView) {
        addHeader("General", subtitle: "Defaults used by every monitor unless that monitor has an override.", to: stack)

        let values = settings.preferences.general
        stack.addArrangedSubview(settingRow(
            icon: "power",
            title: "Start at login",
            description: "Launch the taskbar automatically when you sign in.",
            control: checkbox(state: settings.preferences.startAtLogin, action: #selector(setStartAtLogin(_:)))
        ))
        stack.addArrangedSubview(settingRow(
            icon: "eye",
            title: "Show taskbar",
            description: "Draw the bar on monitors using these defaults.",
            control: checkbox(state: values.isVisible, action: #selector(setGeneralVisible(_:)))
        ))
        stack.addArrangedSubview(settingRow(
            icon: "arrow.up.and.down",
            title: "Taskbar size",
            description: "Set the height of the bar.",
            control: heightControl(value: values.taskbarHeight, enabled: true, action: #selector(setGeneralHeight(_:)))
        ))
        stack.addArrangedSubview(settingRow(
            icon: "arrow.left.and.right",
            title: "Minimum item width",
            description: "Keep taskbar items easy to hit.",
            control: itemWidthControl(value: values.minimumItemWidth, enabled: true, action: #selector(setGeneralMinimumItemWidth(_:)))
        ))
        stack.addArrangedSubview(settingRow(
            icon: "arrow.left.and.right.square",
            title: "Maximum item width",
            description: "Long titles ellipsis after this width.",
            control: itemWidthControl(value: values.maximumItemWidth, enabled: true, action: #selector(setGeneralMaximumItemWidth(_:)))
        ))
        stack.addArrangedSubview(settingRow(
            icon: "rectangle.split.3x1",
            title: "Item spacing",
            description: "Set the horizontal gap between taskbar items.",
            control: itemSpacingControl(value: values.itemSpacing, enabled: true, action: #selector(setGeneralItemSpacing(_:)))
        ))
        stack.addArrangedSubview(settingRow(
            icon: "square.split.2x1",
            title: "Widget spacing",
            description: "Set the horizontal gap between taskbar widgets.",
            control: widgetSpacingControl(value: values.widgetSpacing, enabled: true, action: #selector(setGeneralWidgetSpacing(_:)))
        ))
        stack.addArrangedSubview(settingRow(
            icon: "circle.lefthalf.filled",
            title: "Background opacity",
            description: "Control how much desktop shows through the bar.",
            control: opacityControl(value: values.backgroundOpacity, enabled: true, action: #selector(setGeneralBackgroundOpacity(_:)))
        ))
        stack.addArrangedSubview(settingRow(
            icon: "rectangle.bottomthird.inset.filled",
            title: "Keep windows above bar",
            description: "Resize normal app windows so they stop above the taskbar.",
            control: checkbox(state: values.avoidOverlappingWindows, action: #selector(setGeneralAvoidOverlappingWindows(_:)))
        ))
        stack.addArrangedSubview(settingRow(
            icon: "minus.square",
            title: "Show minimised windows",
            description: "Keep minimised windows on the bar with a muted appearance.",
            control: checkbox(state: values.showMinimizedWindows, action: #selector(setGeneralShowMinimizedWindows(_:)))
        ))
        stack.addArrangedSubview(settingRow(
            icon: "dock.rectangle",
            title: "Auto-hide",
            description: "Hide the bar until the pointer reaches the screen edge.",
            control: checkbox(state: values.autoHide, action: #selector(setGeneralAutoHide(_:)))
        ))
        stack.addArrangedSubview(settingRow(
            icon: "scribble.variable",
            title: "Reveal animation",
            description: "Choose how the bar moves in and out.",
            control: revealAnimationPopup(animation: values.revealAnimation, enabled: true, action: #selector(setGeneralRevealAnimation(_:)))
        ))
        stack.addArrangedSubview(settingRow(
            icon: "speedometer",
            title: "Reveal speed",
            description: "Set the animation duration.",
            control: durationControl(value: values.revealAnimationDuration, enabled: true, action: #selector(setGeneralRevealDuration(_:)))
        ))
        stack.addArrangedSubview(pinnedAppsSection(
            title: "Pinned apps",
            subtitle: "Pinned apps stay at the left and remain visible when closed.",
            apps: values.pinnedApps,
            enabled: true
        ))
    }

    private func renderMonitor(_ screen: ScreenInfo, in stack: NSStackView) {
        let override = settings.overrides(for: screen.persistentID)
        let resolved = settings.values(for: screen.persistentID)
        addHeader(screen.name, subtitle: "Enable an override to use a monitor-specific value.", to: stack)

        stack.addArrangedSubview(overrideBoolRow(
            icon: "eye",
            title: "Show taskbar",
            description: "Hide or show the bar on this monitor.",
            isOverridden: override.isVisible != nil,
            value: resolved.isVisible,
            overrideAction: #selector(toggleMonitorVisibleOverride(_:)),
            valueAction: #selector(setMonitorVisible(_:))
        ))
        stack.addArrangedSubview(overrideHeightRow(
            isOverridden: override.taskbarHeight != nil,
            value: resolved.taskbarHeight
        ))
        stack.addArrangedSubview(overrideSliderRow(
            icon: "arrow.left.and.right",
            title: "Minimum item width",
            description: "Keep taskbar items easy to hit.",
            isOverridden: override.minimumItemWidth != nil,
            control: itemWidthControl(value: resolved.minimumItemWidth, enabled: override.minimumItemWidth != nil, action: #selector(setMonitorMinimumItemWidth(_:))),
            overrideAction: #selector(toggleMonitorMinimumItemWidthOverride(_:))
        ))
        stack.addArrangedSubview(overrideSliderRow(
            icon: "arrow.left.and.right.square",
            title: "Maximum item width",
            description: "Long titles ellipsis after this width.",
            isOverridden: override.maximumItemWidth != nil,
            control: itemWidthControl(value: resolved.maximumItemWidth, enabled: override.maximumItemWidth != nil, action: #selector(setMonitorMaximumItemWidth(_:))),
            overrideAction: #selector(toggleMonitorMaximumItemWidthOverride(_:))
        ))
        stack.addArrangedSubview(overrideSliderRow(
            icon: "rectangle.split.3x1",
            title: "Item spacing",
            description: "Set the horizontal gap between items on this bar.",
            isOverridden: override.itemSpacing != nil,
            control: itemSpacingControl(value: resolved.itemSpacing, enabled: override.itemSpacing != nil, action: #selector(setMonitorItemSpacing(_:))),
            overrideAction: #selector(toggleMonitorItemSpacingOverride(_:))
        ))
        stack.addArrangedSubview(overrideSliderRow(
            icon: "square.split.2x1",
            title: "Widget spacing",
            description: "Set the gap between widgets on this bar.",
            isOverridden: override.widgetSpacing != nil,
            control: widgetSpacingControl(value: resolved.widgetSpacing, enabled: override.widgetSpacing != nil, action: #selector(setMonitorWidgetSpacing(_:))),
            overrideAction: #selector(toggleMonitorWidgetSpacingOverride(_:))
        ))
        stack.addArrangedSubview(overrideSliderRow(
            icon: "circle.lefthalf.filled",
            title: "Background opacity",
            description: "Control how much desktop shows through this bar.",
            isOverridden: override.backgroundOpacity != nil,
            control: opacityControl(value: resolved.backgroundOpacity, enabled: override.backgroundOpacity != nil, action: #selector(setMonitorBackgroundOpacity(_:))),
            overrideAction: #selector(toggleMonitorBackgroundOpacityOverride(_:))
        ))
        stack.addArrangedSubview(overrideBoolRow(
            icon: "rectangle.bottomthird.inset.filled",
            title: "Keep windows above bar",
            description: "Resize normal app windows so they stop above this taskbar.",
            isOverridden: override.avoidOverlappingWindows != nil,
            value: resolved.avoidOverlappingWindows,
            overrideAction: #selector(toggleMonitorAvoidOverlappingWindowsOverride(_:)),
            valueAction: #selector(setMonitorAvoidOverlappingWindows(_:))
        ))
        stack.addArrangedSubview(overrideBoolRow(
            icon: "minus.square",
            title: "Show minimised windows",
            description: "Keep minimised windows on this bar with a muted appearance.",
            isOverridden: override.showMinimizedWindows != nil,
            value: resolved.showMinimizedWindows,
            overrideAction: #selector(toggleMonitorShowMinimizedWindowsOverride(_:)),
            valueAction: #selector(setMonitorShowMinimizedWindows(_:))
        ))
        stack.addArrangedSubview(overrideBoolRow(
            icon: "dock.rectangle",
            title: "Auto-hide",
            description: "Hide this bar until the pointer reaches the screen edge.",
            isOverridden: override.autoHide != nil,
            value: resolved.autoHide,
            overrideAction: #selector(toggleMonitorAutoHideOverride(_:)),
            valueAction: #selector(setMonitorAutoHide(_:))
        ))
        stack.addArrangedSubview(overrideRevealAnimationRow(
            isOverridden: override.revealAnimation != nil,
            value: resolved.revealAnimation
        ))
        stack.addArrangedSubview(overrideSliderRow(
            icon: "speedometer",
            title: "Reveal speed",
            description: "Set the animation duration for this monitor.",
            isOverridden: override.revealAnimationDuration != nil,
            control: durationControl(value: resolved.revealAnimationDuration, enabled: override.revealAnimationDuration != nil, action: #selector(setMonitorRevealDuration(_:))),
            overrideAction: #selector(toggleMonitorRevealDurationOverride(_:))
        ))
        stack.addArrangedSubview(overridePinnedAppsSection(
            apps: resolved.pinnedApps,
            isOverridden: override.pinnedApps != nil
        ))
    }

    private func renderWidgets(in stack: NSStackView) {
        addHeader("Widgets", subtitle: "Installed taskbar widgets. Choose a widget in the sidebar to configure its defaults or monitor overrides.", to: stack)

        for widget in installedTaskbarWidgetPlugins() {
            let isEnabled = widget.isEnabled(in: settings.preferences.general)
            let status = NSTextField(labelWithString: isEnabled ? "Enabled by default" : "Off by default")
            status.textColor = .secondaryLabelColor
            status.widthAnchor.constraint(equalToConstant: 130).isActive = true
            stack.addArrangedSubview(settingRow(
                icon: widget.symbolName,
                title: widget.title,
                description: "Widget settings live on their own page.",
                control: status
            ))
        }
    }

    private func renderWidget(_ widgetID: TaskbarWidgetID, screen: ScreenInfo?, in stack: NSStackView) {
        switch widgetID {
        case .stats:
            renderStatsWidget(screen: screen, in: stack)
        case .battery:
            renderBatteryWidget(screen: screen, in: stack)
        case .controlCenterLights:
            renderControlCenterLightsWidget(screen: screen, in: stack)
        case .dateTime:
            renderDateTimeWidget(screen: screen, in: stack)
        }
    }

    private func renderControlCenterLightsWidget(screen: ScreenInfo?, in stack: NSStackView) {
        let snapshot = ControlCenterLightsController.shared.snapshot()
        if let screen {
            let override = settings.overrides(for: screen.persistentID)
            let resolved = settings.values(for: screen.persistentID)
            addHeader("Control Center Lights", subtitle: "\(screen.name) override for the Control Center Lights widget.", to: stack)
            stack.addArrangedSubview(overrideControlCenterLightsWidgetRow(
                isOverridden: override.controlCenterLightsWidget != nil,
                value: resolved.controlCenterLightsWidget,
                discoveredCount: snapshot.discoveredCount
            ))
            return
        }

        let values = settings.preferences.general
        addHeader(
            "Control Center Lights",
            subtitle: "Default lights button setting used by every monitor unless that monitor has an override.",
            to: stack
        )
        stack.addArrangedSubview(settingRow(
            icon: "lightbulb",
            title: "Lights button",
            description: snapshot.discoveredCount == 0
                ? "Looking for Elgato lights on your local network."
                : "Found \(snapshot.discoveredCount) Elgato light(s).",
            control: checkbox(
                state: values.controlCenterLightsWidget.isEnabled,
                action: #selector(setGeneralControlCenterLightsEnabled(_:))
            )
        ))
    }

    private func renderBatteryWidget(screen: ScreenInfo?, in stack: NSStackView) {
        if let screen {
            let override = settings.overrides(for: screen.persistentID)
            let resolved = settings.values(for: screen.persistentID)
            addHeader("Battery", subtitle: "\(screen.name) override for the Battery widget.", to: stack)
            stack.addArrangedSubview(overrideBatteryWidgetRow(
                isOverridden: override.batteryWidget != nil,
                value: resolved.batteryWidget
            ))
            return
        }

        let values = settings.preferences.general
        addHeader("Battery", subtitle: "Default Battery widget settings used by every monitor unless that monitor has an override.", to: stack)
        stack.addArrangedSubview(settingRow(
            icon: "battery.100",
            title: "Battery",
            description: "Show the Mac's current battery level in the taskbar.",
            control: batteryWidgetControls(
                value: values.batteryWidget,
                enabled: true,
                enabledAction: #selector(setGeneralBatteryEnabled(_:))
            )
        ))
    }

    private func renderStatsWidget(screen: ScreenInfo?, in stack: NSStackView) {
        if let screen {
            let override = settings.overrides(for: screen.persistentID)
            let resolved = settings.values(for: screen.persistentID)
            addHeader("Stats", subtitle: "\(screen.name) override for the Stats widget.", to: stack)
            stack.addArrangedSubview(overrideStatsWidgetRow(
                isOverridden: override.statsWidget != nil,
                value: resolved.statsWidget
            ))
            return
        }

        let values = settings.preferences.general
        addHeader("Stats", subtitle: "Default Stats widget settings used by every monitor unless that monitor has an override.", to: stack)
        stack.addArrangedSubview(settingRow(
            icon: "chart.bar",
            title: "Stats",
            description: "Show CPU, memory, and network activity in the taskbar.",
            control: statsWidgetControls(
                value: values.statsWidget,
                enabled: true,
                enabledAction: #selector(setGeneralStatsEnabled(_:)),
                cpuAction: #selector(setGeneralStatsCPU(_:)),
                gpuAction: #selector(setGeneralStatsGPU(_:)),
                memoryAction: #selector(setGeneralStatsMemory(_:)),
                networkAction: #selector(setGeneralStatsNetwork(_:)),
                cpuDisplayAction: #selector(setGeneralStatsCPUDisplay(_:)),
                memoryDisplayAction: #selector(setGeneralStatsMemoryDisplay(_:)),
                cpuCoreColorAction: #selector(setGeneralStatsCPUCoreColor(_:))
            )
        ))
    }

    private func renderDateTimeWidget(screen: ScreenInfo?, in stack: NSStackView) {
        if let screen {
            let override = settings.overrides(for: screen.persistentID)
            let resolved = settings.values(for: screen.persistentID)
            addHeader("Date & Time", subtitle: "\(screen.name) override for the Date & Time widget.", to: stack)
            stack.addArrangedSubview(overrideDateTimeWidgetRow(
                isOverridden: override.dateTimeWidget != nil || override.clockMode != nil,
                value: resolved.dateTimeWidget
            ))
            return
        }

        let values = settings.preferences.general
        addHeader("Date & Time", subtitle: "Default Date & Time widget settings used by every monitor unless that monitor has an override.", to: stack)
        stack.addArrangedSubview(settingRow(
            icon: "clock",
            title: "Date & Time",
            description: "Configure the widget at the right edge of the bar.",
            control: dateTimeWidgetControls(
                value: values.dateTimeWidget,
                enabled: true,
                enabledAction: #selector(setGeneralDateTimeEnabled(_:)),
                dateDisplayAction: #selector(setGeneralDateTimeDateDisplay(_:)),
                dayOfWeekAction: #selector(setGeneralDateTimeDayOfWeek(_:)),
                secondsAction: #selector(setGeneralDateTimeSeconds(_:)),
                twentyFourHourAction: #selector(setGeneralDateTime24Hour(_:))
            )
        ))
    }

    private func addHeader(_ title: String, subtitle: String, to stack: NSStackView) {
        let titleField = NSTextField(labelWithString: title)
        titleField.font = .systemFont(ofSize: 22, weight: .semibold)
        titleField.textColor = .labelColor
        stack.addArrangedSubview(titleField)

        let subtitleField = NSTextField(labelWithString: subtitle)
        subtitleField.font = .systemFont(ofSize: 13)
        subtitleField.textColor = .secondaryLabelColor
        subtitleField.maximumNumberOfLines = 2
        stack.addArrangedSubview(subtitleField)
    }

    private func settingRow(icon: String, title: String, description: String, control: NSView) -> NSView {
        let row = horizontalRow()
        row.alignment = .top

        let iconView = NSImageView(image: symbol(icon) ?? NSImage())
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 17, weight: .regular)
        iconView.contentTintColor = .controlAccentColor
        iconView.widthAnchor.constraint(equalToConstant: 24).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 24).isActive = true

        let labelStack = NSStackView()
        labelStack.orientation = .vertical
        labelStack.alignment = .leading
        labelStack.spacing = 2

        let titleField = NSTextField(labelWithString: title)
        titleField.font = .systemFont(ofSize: 13, weight: .semibold)

        let descriptionField = NSTextField(labelWithString: description)
        descriptionField.font = .systemFont(ofSize: 12)
        descriptionField.textColor = .secondaryLabelColor
        descriptionField.maximumNumberOfLines = 2
        descriptionField.lineBreakMode = .byWordWrapping

        labelStack.addArrangedSubview(titleField)
        labelStack.addArrangedSubview(descriptionField)
        labelStack.widthAnchor.constraint(equalToConstant: 200).isActive = true

        control.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        row.addArrangedSubview(iconView)
        row.addArrangedSubview(labelStack)
        row.addArrangedSubview(control)
        return row
    }

    private func checkbox(state: Bool, action: Selector) -> NSButton {
        let button = NSButton(checkboxWithTitle: "", target: self, action: action)
        button.state = state ? .on : .off
        return button
    }

    private func titledCheckbox(_ title: String, state: Bool, enabled: Bool, action: Selector) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: self, action: action)
        button.state = state ? .on : .off
        button.isEnabled = enabled
        return button
    }

    private func dateTimeWidgetControls(
        value: DateTimeWidgetSettings,
        enabled: Bool,
        enabledAction: Selector,
        dateDisplayAction: Selector,
        dayOfWeekAction: Selector,
        secondsAction: Selector,
        twentyFourHourAction: Selector
    ) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6

        let topRow = horizontalRow()
        topRow.addArrangedSubview(titledCheckbox("Show", state: value.isEnabled, enabled: enabled, action: enabledAction))
        topRow.addArrangedSubview(dateDisplayPopup(display: value.dateDisplay, enabled: enabled, action: dateDisplayAction))

        let optionsRow = horizontalRow()
        optionsRow.spacing = 10
        optionsRow.addArrangedSubview(titledCheckbox("Day", state: value.showDayOfWeek, enabled: enabled, action: dayOfWeekAction))
        optionsRow.addArrangedSubview(titledCheckbox("Seconds", state: value.showSeconds, enabled: enabled, action: secondsAction))
        optionsRow.addArrangedSubview(titledCheckbox("24-hour", state: value.use24HourClock, enabled: enabled, action: twentyFourHourAction))

        stack.addArrangedSubview(topRow)
        stack.addArrangedSubview(optionsRow)
        return stack
    }

    private func batteryWidgetControls(
        value: BatteryWidgetSettings,
        enabled: Bool,
        enabledAction: Selector
    ) -> NSView {
        let row = horizontalRow()
        row.addArrangedSubview(titledCheckbox("Show", state: value.isEnabled, enabled: enabled, action: enabledAction))
        return row
    }

    private func statsWidgetControls(
        value: StatsWidgetSettings,
        enabled: Bool,
        enabledAction: Selector,
        cpuAction: Selector,
        gpuAction: Selector,
        memoryAction: Selector,
        networkAction: Selector,
        cpuDisplayAction: Selector,
        memoryDisplayAction: Selector,
        cpuCoreColorAction: Selector
    ) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8

        let topRow = horizontalRow()
        topRow.addArrangedSubview(titledCheckbox("Show", state: value.isEnabled, enabled: enabled, action: enabledAction))

        stack.addArrangedSubview(topRow)

        let cpuRow = horizontalRow()
        cpuRow.addArrangedSubview(titledCheckbox("CPU", state: value.showCPU, enabled: enabled, action: cpuAction))
        cpuRow.addArrangedSubview(statsCPUDisplayPopup(display: value.cpuDisplay, enabled: enabled, action: cpuDisplayAction))
        stack.addArrangedSubview(statsOptionGroup(label: "CPU", control: cpuRow))

        stack.addArrangedSubview(statsOptionGroup(
            label: "CPU core colours",
            control: statsCPUCoreColorControls(
                colors: value.cpuCoreColors,
                enabled: enabled,
                action: cpuCoreColorAction
            )
        ))

        let gpuRow = horizontalRow()
        gpuRow.addArrangedSubview(titledCheckbox("GPU", state: value.showGPU, enabled: enabled, action: gpuAction))
        stack.addArrangedSubview(statsOptionGroup(label: "GPU", control: gpuRow))

        let memoryRow = horizontalRow()
        memoryRow.addArrangedSubview(titledCheckbox("RAM", state: value.showMemory, enabled: enabled, action: memoryAction))
        memoryRow.addArrangedSubview(statsMemoryDisplayPopup(display: value.memoryDisplay, enabled: enabled, action: memoryDisplayAction))
        stack.addArrangedSubview(statsOptionGroup(label: "RAM", control: memoryRow))

        let networkRow = horizontalRow()
        networkRow.addArrangedSubview(titledCheckbox("Network", state: value.showNetwork, enabled: enabled, action: networkAction))
        stack.addArrangedSubview(statsOptionGroup(label: "Network", control: networkRow))

        return stack
    }

    private func statsCPUCoreColorControls(
        colors: StatsCPUCoreColors,
        enabled: Bool,
        action: Selector
    ) -> NSView {
        let row = horizontalRow()
        row.spacing = 14

        for kind in StatsCPUCoreColorKind.allCases {
            let control = NSStackView()
            control.orientation = .vertical
            control.alignment = .leading
            control.spacing = 3

            let label = NSTextField(labelWithString: kind.title)
            label.font = .systemFont(ofSize: 10)
            label.textColor = .secondaryLabelColor

            let colorWell = NSColorWell(frame: NSRect(x: 0, y: 0, width: 54, height: 24))
            colorWell.identifier = NSUserInterfaceItemIdentifier(kind.identifier)
            colorWell.tag = kind.rawValue
            colorWell.color = statsColorFromHex(
                statsCPUCoreColorHex(for: kind.colorRole, colors: colors)
            ) ?? .systemBlue
            colorWell.target = self
            colorWell.action = action
            colorWell.isEnabled = enabled
            colorWell.setAccessibilityLabel("\(kind.title) core colour")
            colorWell.widthAnchor.constraint(equalToConstant: 54).isActive = true
            colorWell.heightAnchor.constraint(equalToConstant: 24).isActive = true

            control.addArrangedSubview(label)
            control.addArrangedSubview(colorWell)
            row.addArrangedSubview(control)
        }
        return row
    }

    private func statsOptionGroup(label: String, control: NSView) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4

        let title = NSTextField(labelWithString: label)
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = .secondaryLabelColor

        stack.addArrangedSubview(title)
        stack.addArrangedSubview(control)
        return stack
    }

    private func dateDisplayPopup(display: DateTimeDateDisplay, enabled: Bool, action: Selector) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        for display in DateTimeDateDisplay.allCases {
            popup.addItem(withTitle: display.label)
        }
        if let index = DateTimeDateDisplay.allCases.firstIndex(of: display) {
            popup.selectItem(at: index)
        }
        popup.target = self
        popup.action = action
        popup.isEnabled = enabled
        popup.widthAnchor.constraint(equalToConstant: 170).isActive = true
        return popup
    }

    private func revealAnimationPopup(animation: RevealAnimation, enabled: Bool, action: Selector) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        for animation in RevealAnimation.allCases {
            popup.addItem(withTitle: animation.label)
        }
        if let index = RevealAnimation.allCases.firstIndex(of: animation) {
            popup.selectItem(at: index)
        }
        popup.target = self
        popup.action = action
        popup.isEnabled = enabled
        popup.widthAnchor.constraint(equalToConstant: 150).isActive = true
        return popup
    }

    private func statsMemoryDisplayPopup(display: StatsMemoryDisplay, enabled: Bool, action: Selector) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        for display in StatsMemoryDisplay.allCases {
            popup.addItem(withTitle: display.label)
        }
        if let index = StatsMemoryDisplay.allCases.firstIndex(of: display) {
            popup.selectItem(at: index)
        }
        popup.target = self
        popup.action = action
        popup.isEnabled = enabled
        popup.widthAnchor.constraint(equalToConstant: 140).isActive = true
        return popup
    }

    private func statsCPUDisplayPopup(display: StatsCPUDisplay, enabled: Bool, action: Selector) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        for display in StatsCPUDisplay.allCases {
            popup.addItem(withTitle: display.label)
        }
        if let index = StatsCPUDisplay.allCases.firstIndex(of: display) {
            popup.selectItem(at: index)
        }
        popup.target = self
        popup.action = action
        popup.isEnabled = enabled
        popup.widthAnchor.constraint(equalToConstant: 140).isActive = true
        return popup
    }

    private func heightControl(value: Double, enabled: Bool, action: Selector) -> NSView {
        sliderControl(
            value: value,
            minValue: TaskbarSettingValues.minimumTaskbarHeight,
            maxValue: TaskbarSettingValues.maximumTaskbarHeight,
            enabled: enabled,
            action: action,
            formatter: { "\(Int(round($0))) px" }
        )
    }

    private func itemWidthControl(value: Double, enabled: Bool, action: Selector) -> NSView {
        sliderControl(
            value: value,
            minValue: TaskbarSettingValues.smallestItemWidth,
            maxValue: TaskbarSettingValues.largestItemWidth,
            enabled: enabled,
            action: action,
            formatter: { "\(Int(round($0))) px" }
        )
    }

    private func itemSpacingControl(value: Double, enabled: Bool, action: Selector) -> NSView {
        sliderControl(
            value: value,
            minValue: TaskbarSettingValues.minimumItemSpacing,
            maxValue: TaskbarSettingValues.maximumItemSpacing,
            enabled: enabled,
            action: action,
            formatter: { "\(Int(round($0))) px" }
        )
    }

    private func widgetSpacingControl(value: Double, enabled: Bool, action: Selector) -> NSView {
        sliderControl(
            value: value,
            minValue: TaskbarSettingValues.minimumWidgetSpacing,
            maxValue: TaskbarSettingValues.maximumWidgetSpacing,
            enabled: enabled,
            action: action,
            formatter: { "\(Int(round($0))) px" }
        )
    }

    private func opacityControl(value: Double, enabled: Bool, action: Selector) -> NSView {
        sliderControl(
            value: value,
            minValue: TaskbarSettingValues.minimumBackgroundOpacity,
            maxValue: TaskbarSettingValues.maximumBackgroundOpacity,
            enabled: enabled,
            action: action,
            formatter: { "\(Int(round($0 * 100)))%" }
        )
    }

    private func durationControl(value: Double, enabled: Bool, action: Selector) -> NSView {
        sliderControl(
            value: value,
            minValue: TaskbarSettingValues.minimumRevealAnimationDuration,
            maxValue: TaskbarSettingValues.maximumRevealAnimationDuration,
            enabled: enabled,
            action: action,
            formatter: { String(format: "%.2fs", $0) }
        )
    }

    private func sliderControl(
        value: Double,
        minValue: Double,
        maxValue: Double,
        enabled: Bool,
        action: Selector,
        formatter: @escaping (Double) -> String
    ) -> NSView {
        let row = horizontalRow()

        let slider = ValueSlider(
            value: value,
            minValue: minValue,
            maxValue: maxValue,
            target: self,
            action: action
        )
        slider.isEnabled = enabled
        slider.valueFormatter = formatter
        slider.widthAnchor.constraint(equalToConstant: 110).isActive = true

        let valueLabel = NSTextField(labelWithString: formatter(value))
        valueLabel.textColor = enabled ? .labelColor : .secondaryLabelColor
        valueLabel.widthAnchor.constraint(equalToConstant: 48).isActive = true
        slider.valueLabel = valueLabel

        row.addArrangedSubview(slider)
        row.addArrangedSubview(valueLabel)
        return row
    }

    private func overrideBoolRow(
        icon: String,
        title: String,
        description: String,
        isOverridden: Bool,
        value: Bool,
        overrideAction: Selector,
        valueAction: Selector
    ) -> NSView {
        let controls = horizontalRow()

        let override = NSButton(checkboxWithTitle: "Override", target: self, action: overrideAction)
        override.state = isOverridden ? .on : .off
        override.widthAnchor.constraint(equalToConstant: 92).isActive = true

        let valueButton = checkbox(state: value, action: valueAction)
        valueButton.isEnabled = isOverridden

        controls.addArrangedSubview(override)
        controls.addArrangedSubview(valueButton)
        return settingRow(icon: icon, title: title, description: description, control: controls)
    }

    private func overrideDateTimeWidgetRow(isOverridden: Bool, value: DateTimeWidgetSettings) -> NSView {
        let controls = NSStackView()
        controls.orientation = .vertical
        controls.alignment = .leading
        controls.spacing = 6

        let override = NSButton(checkboxWithTitle: "Override", target: self, action: #selector(toggleMonitorDateTimeOverride(_:)))
        override.state = isOverridden ? .on : .off
        override.widthAnchor.constraint(equalToConstant: 92).isActive = true

        controls.addArrangedSubview(override)
        controls.addArrangedSubview(dateTimeWidgetControls(
            value: value,
            enabled: isOverridden,
            enabledAction: #selector(setMonitorDateTimeEnabled(_:)),
            dateDisplayAction: #selector(setMonitorDateTimeDateDisplay(_:)),
            dayOfWeekAction: #selector(setMonitorDateTimeDayOfWeek(_:)),
            secondsAction: #selector(setMonitorDateTimeSeconds(_:)),
            twentyFourHourAction: #selector(setMonitorDateTime24Hour(_:))
        ))
        return settingRow(
            icon: "clock",
            title: "Date & Time",
            description: "Configure this monitor's Date & Time widget.",
            control: controls
        )
    }

    private func overrideStatsWidgetRow(isOverridden: Bool, value: StatsWidgetSettings) -> NSView {
        let controls = NSStackView()
        controls.orientation = .vertical
        controls.alignment = .leading
        controls.spacing = 6

        let override = NSButton(checkboxWithTitle: "Override", target: self, action: #selector(toggleMonitorStatsOverride(_:)))
        override.state = isOverridden ? .on : .off
        override.widthAnchor.constraint(equalToConstant: 92).isActive = true

        controls.addArrangedSubview(override)
        controls.addArrangedSubview(statsWidgetControls(
            value: value,
            enabled: isOverridden,
            enabledAction: #selector(setMonitorStatsEnabled(_:)),
            cpuAction: #selector(setMonitorStatsCPU(_:)),
            gpuAction: #selector(setMonitorStatsGPU(_:)),
            memoryAction: #selector(setMonitorStatsMemory(_:)),
            networkAction: #selector(setMonitorStatsNetwork(_:)),
            cpuDisplayAction: #selector(setMonitorStatsCPUDisplay(_:)),
            memoryDisplayAction: #selector(setMonitorStatsMemoryDisplay(_:)),
            cpuCoreColorAction: #selector(setMonitorStatsCPUCoreColor(_:))
        ))
        return settingRow(
            icon: "chart.bar",
            title: "Stats",
            description: "Configure this monitor's Stats widget.",
            control: controls
        )
    }

    private func overrideBatteryWidgetRow(isOverridden: Bool, value: BatteryWidgetSettings) -> NSView {
        let controls = NSStackView()
        controls.orientation = .vertical
        controls.alignment = .leading
        controls.spacing = 6

        let override = NSButton(checkboxWithTitle: "Override", target: self, action: #selector(toggleMonitorBatteryOverride(_:)))
        override.state = isOverridden ? .on : .off
        override.widthAnchor.constraint(equalToConstant: 92).isActive = true

        controls.addArrangedSubview(override)
        controls.addArrangedSubview(batteryWidgetControls(
            value: value,
            enabled: isOverridden,
            enabledAction: #selector(setMonitorBatteryEnabled(_:))
        ))
        return settingRow(
            icon: "battery.100",
            title: "Battery",
            description: "Configure this monitor's Battery widget.",
            control: controls
        )
    }

    private func overrideControlCenterLightsWidgetRow(
        isOverridden: Bool,
        value: ControlCenterLightsWidgetSettings,
        discoveredCount: Int
    ) -> NSView {
        let controls = NSStackView()
        controls.orientation = .vertical
        controls.alignment = .leading
        controls.spacing = 6

        let override = NSButton(
            checkboxWithTitle: "Override",
            target: self,
            action: #selector(toggleMonitorControlCenterLightsOverride(_:))
        )
        override.state = isOverridden ? .on : .off
        override.widthAnchor.constraint(equalToConstant: 92).isActive = true

        controls.addArrangedSubview(override)
        controls.addArrangedSubview(titledCheckbox(
            "Show",
            state: value.isEnabled,
            enabled: isOverridden,
            action: #selector(setMonitorControlCenterLightsEnabled(_:))
        ))
        return settingRow(
            icon: "lightbulb",
            title: "Lights button",
            description: discoveredCount == 0
                ? "Looking for Elgato lights on your local network."
                : "Found \(discoveredCount) Elgato light(s).",
            control: controls
        )
    }

    private func overrideHeightRow(isOverridden: Bool, value: Double) -> NSView {
        let controls = horizontalRow()

        let override = NSButton(checkboxWithTitle: "Override", target: self, action: #selector(toggleMonitorHeightOverride(_:)))
        override.state = isOverridden ? .on : .off
        override.widthAnchor.constraint(equalToConstant: 92).isActive = true

        controls.addArrangedSubview(override)
        controls.addArrangedSubview(heightControl(value: value, enabled: isOverridden, action: #selector(setMonitorHeight(_:))))
        return settingRow(
            icon: "arrow.up.and.down",
            title: "Taskbar size",
            description: "Set a monitor-specific bar height.",
            control: controls
        )
    }

    private func overrideSliderRow(
        icon: String,
        title: String,
        description: String,
        isOverridden: Bool,
        control: NSView,
        overrideAction: Selector
    ) -> NSView {
        let controls = horizontalRow()

        let override = NSButton(checkboxWithTitle: "Override", target: self, action: overrideAction)
        override.state = isOverridden ? .on : .off
        override.widthAnchor.constraint(equalToConstant: 92).isActive = true

        controls.addArrangedSubview(override)
        controls.addArrangedSubview(control)
        return settingRow(icon: icon, title: title, description: description, control: controls)
    }

    private func overrideRevealAnimationRow(isOverridden: Bool, value: RevealAnimation) -> NSView {
        let controls = horizontalRow()

        let override = NSButton(checkboxWithTitle: "Override", target: self, action: #selector(toggleMonitorRevealAnimationOverride(_:)))
        override.state = isOverridden ? .on : .off
        override.widthAnchor.constraint(equalToConstant: 92).isActive = true

        controls.addArrangedSubview(override)
        controls.addArrangedSubview(revealAnimationPopup(animation: value, enabled: isOverridden, action: #selector(setMonitorRevealAnimation(_:))))
        return settingRow(
            icon: "scribble.variable",
            title: "Reveal animation",
            description: "Choose how this bar moves in and out.",
            control: controls
        )
    }

    private func pinnedAppsSection(title: String, subtitle: String, apps: [PinnedApp], enabled: Bool) -> NSView {
        let section = NSStackView()
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 8

        let headerControl = NSView()
        section.addArrangedSubview(settingRow(icon: "pin", title: title, description: subtitle, control: headerControl))

        let editor = NSStackView()
        editor.orientation = .vertical
        editor.alignment = .leading
        editor.spacing = 8
        editor.edgeInsets = NSEdgeInsets(top: 0, left: 36, bottom: 0, right: 0)

        let addRow = horizontalRow()
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        let candidates = runningAppCandidates(excluding: apps)
        if candidates.isEmpty {
            popup.addItem(withTitle: "No running apps to add")
            popup.isEnabled = false
        } else {
            for app in candidates {
                popup.addItem(withTitle: app.displayName)
                popup.lastItem?.representedObject = app
                popup.lastItem?.image = appIcon(app)
            }
            popup.isEnabled = enabled
        }
        popup.widthAnchor.constraint(equalToConstant: 240).isActive = true
        pinCandidatePopup = popup

        let addButton = NSButton(title: "Pin", target: self, action: #selector(addPinnedApp(_:)))
        addButton.isEnabled = enabled && !candidates.isEmpty
        addRow.addArrangedSubview(popup)
        addRow.addArrangedSubview(addButton)
        editor.addArrangedSubview(addRow)

        if apps.isEmpty {
            let empty = NSTextField(labelWithString: "No pinned apps yet.")
            empty.textColor = .secondaryLabelColor
            empty.font = .systemFont(ofSize: 12)
            editor.addArrangedSubview(empty)
        } else {
            for app in apps {
                editor.addArrangedSubview(pinnedAppRow(app: app, enabled: enabled))
            }
        }

        section.addArrangedSubview(editor)
        return section
    }

    private func overridePinnedAppsSection(apps: [PinnedApp], isOverridden: Bool) -> NSView {
        let section = NSStackView()
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 8

        let controls = horizontalRow()
        let override = NSButton(checkboxWithTitle: "Override", target: self, action: #selector(toggleMonitorPinnedAppsOverride(_:)))
        override.state = isOverridden ? .on : .off
        override.widthAnchor.constraint(equalToConstant: 92).isActive = true
        controls.addArrangedSubview(override)

        section.addArrangedSubview(settingRow(
            icon: "pin",
            title: "Pinned apps",
            description: "Set monitor-specific pinned apps.",
            control: controls
        ))

        let editor = pinnedAppsEditor(apps: apps, enabled: isOverridden)
        editor.edgeInsets = NSEdgeInsets(top: 0, left: 36, bottom: 0, right: 0)
        section.addArrangedSubview(editor)
        return section
    }

    private func pinnedAppsEditor(apps: [PinnedApp], enabled: Bool) -> NSStackView {
        let editor = NSStackView()
        editor.orientation = .vertical
        editor.alignment = .leading
        editor.spacing = 8

        let addRow = horizontalRow()
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        let candidates = runningAppCandidates(excluding: apps)
        if candidates.isEmpty {
            popup.addItem(withTitle: "No running apps to add")
            popup.isEnabled = false
        } else {
            for app in candidates {
                popup.addItem(withTitle: app.displayName)
                popup.lastItem?.representedObject = app
                popup.lastItem?.image = appIcon(app)
            }
            popup.isEnabled = enabled
        }
        popup.widthAnchor.constraint(equalToConstant: 240).isActive = true
        pinCandidatePopup = popup

        let addButton = NSButton(title: "Pin", target: self, action: #selector(addPinnedApp(_:)))
        addButton.isEnabled = enabled && !candidates.isEmpty
        addRow.addArrangedSubview(popup)
        addRow.addArrangedSubview(addButton)
        editor.addArrangedSubview(addRow)

        if apps.isEmpty {
            let empty = NSTextField(labelWithString: enabled ? "No pinned apps yet." : "Using general pinned apps.")
            empty.textColor = .secondaryLabelColor
            empty.font = .systemFont(ofSize: 12)
            editor.addArrangedSubview(empty)
        } else {
            for app in apps {
                editor.addArrangedSubview(pinnedAppRow(app: app, enabled: enabled))
            }
        }
        return editor
    }

    private func pinnedAppRow(app: PinnedApp, enabled: Bool) -> NSView {
        let row = horizontalRow()

        let iconView = NSImageView(image: appIcon(app))
        iconView.widthAnchor.constraint(equalToConstant: 20).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 20).isActive = true

        let label = NSTextField(labelWithString: app.displayName)
        label.widthAnchor.constraint(equalToConstant: 230).isActive = true

        let remove = PinnedAppButton(title: "Unpin", target: self, action: #selector(unpinPinnedApp(_:)))
        remove.pinnedApp = app
        remove.isEnabled = enabled

        row.addArrangedSubview(iconView)
        row.addArrangedSubview(label)
        row.addArrangedSubview(remove)
        return row
    }

    private func runningAppCandidates(excluding pinnedApps: [PinnedApp]) -> [PinnedApp] {
        let excluded = Set(pinnedApps.map(\.identity))
        var seen = Set<String>()

        return NSWorkspace.shared.runningApplications
            .compactMap { app -> PinnedApp? in
                guard app.activationPolicy == .regular else { return nil }
                let displayName = app.localizedName
                    ?? app.bundleURL?.deletingPathExtension().lastPathComponent
                    ?? app.bundleIdentifier
                    ?? "Unknown"
                let pinnedApp = PinnedApp(
                    displayName: displayName,
                    bundleID: app.bundleIdentifier ?? "",
                    appPath: app.bundleURL?.path ?? ""
                )
                guard !pinnedApp.bundleID.isEmpty || !pinnedApp.appPath.isEmpty else { return nil }
                guard !excluded.contains(pinnedApp.identity), !seen.contains(pinnedApp.identity) else { return nil }
                seen.insert(pinnedApp.identity)
                return pinnedApp
            }
            .sorted { left, right in
                left.displayName.localizedCaseInsensitiveCompare(right.displayName) == .orderedAscending
            }
    }

    private func appIcon(_ app: PinnedApp) -> NSImage {
        if !app.appPath.isEmpty {
            return NSWorkspace.shared.icon(forFile: app.appPath)
        }
        return symbol("app.dashed") ?? NSImage()
    }

    private func horizontalRow() -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        return row
    }

    private func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    private var selectedMonitorID: UInt32? {
        switch selectedItem {
        case .monitor(let screen), .monitorWidget(let screen, _):
            return screen.id
        case .general, .widgets, .widget, .divider:
            return nil
        }
    }

    private func selectedDateDisplay(from popup: NSPopUpButton) -> DateTimeDateDisplay? {
        let index = popup.indexOfSelectedItem
        guard DateTimeDateDisplay.allCases.indices.contains(index) else { return nil }
        return DateTimeDateDisplay.allCases[index]
    }

    private func selectedRevealAnimation(from popup: NSPopUpButton) -> RevealAnimation? {
        let index = popup.indexOfSelectedItem
        guard RevealAnimation.allCases.indices.contains(index) else { return nil }
        return RevealAnimation.allCases[index]
    }

    private func selectedStatsMemoryDisplay(from popup: NSPopUpButton) -> StatsMemoryDisplay? {
        let index = popup.indexOfSelectedItem
        guard StatsMemoryDisplay.allCases.indices.contains(index) else { return nil }
        return StatsMemoryDisplay.allCases[index]
    }

    private func selectedStatsCPUDisplay(from popup: NSPopUpButton) -> StatsCPUDisplay? {
        let index = popup.indexOfSelectedItem
        guard StatsCPUDisplay.allCases.indices.contains(index) else { return nil }
        return StatsCPUDisplay.allCases[index]
    }

    private func selectedStatsCPUCoreColor(
        from colorWell: NSColorWell
    ) -> (kind: StatsCPUCoreColorKind, hex: String)? {
        guard let kind = StatsCPUCoreColorKind(rawValue: colorWell.tag),
              let hex = statsColorHex(colorWell.color)
        else {
            return nil
        }
        return (kind, hex)
    }

    private func setStatsCPUCoreColor(
        _ hex: String,
        kind: StatsCPUCoreColorKind,
        colors: inout StatsCPUCoreColors
    ) {
        switch kind {
        case .superCore:
            colors.superCore = hex
        case .performance:
            colors.performance = hex
        case .efficiency:
            colors.efficiency = hex
        }
    }

    private func refreshSliderLabel(_ sender: NSSlider) {
        (sender as? ValueSlider)?.refreshValueLabel()
    }

    private func mutateSettings(_ mutation: () -> Void) {
        guard let settingsChangeObservation else {
            mutation()
            return
        }
        settings.performChanges(suppressing: settingsChangeObservation, mutation)
    }

    private func updateGeneral(_ transform: (inout TaskbarSettingValues) -> Void) {
        mutateSettings {
            settings.updateGeneral(transform)
        }
    }

    private func monitorID(for screenID: UInt32) -> String {
        screens.first(where: { $0.id == screenID })?.persistentID
            ?? persistentDisplayID(runtimeID: screenID, displayUUID: nil)
    }

    private func values(for screenID: UInt32) -> TaskbarSettingValues {
        settings.values(for: monitorID(for: screenID))
    }

    private func overrides(for screenID: UInt32) -> TaskbarMonitorOverrides {
        settings.overrides(for: monitorID(for: screenID))
    }

    private func updateOverrides(
        for screenID: UInt32,
        _ transform: (inout TaskbarMonitorOverrides) -> Void
    ) {
        mutateSettings {
            settings.updateOverrides(for: monitorID(for: screenID), transform)
        }
    }

    private func pin(_ app: PinnedApp, for screenID: UInt32?) {
        mutateSettings {
            settings.pin(app, forMonitor: screenID.map(monitorID(for:)))
        }
    }

    private func unpin(_ app: PinnedApp, for screenID: UInt32?) {
        mutateSettings {
            settings.unpin(app, forMonitor: screenID.map(monitorID(for:)))
        }
    }

    @objc private func setStartAtLogin(_ sender: NSButton) {
        mutateSettings {
            settings.setStartAtLogin(sender.state == .on)
        }
    }

    @objc private func setGeneralVisible(_ sender: NSButton) {
        updateGeneral { $0.isVisible = sender.state == .on }
    }

    @objc private func setGeneralDateTimeEnabled(_ sender: NSButton) {
        updateGeneral { $0.dateTimeWidget.isEnabled = sender.state == .on }
    }

    @objc private func setGeneralDateTimeDateDisplay(_ sender: NSPopUpButton) {
        guard let display = selectedDateDisplay(from: sender) else { return }
        updateGeneral { $0.dateTimeWidget.dateDisplay = display }
    }

    @objc private func setGeneralDateTimeDayOfWeek(_ sender: NSButton) {
        updateGeneral { $0.dateTimeWidget.showDayOfWeek = sender.state == .on }
    }

    @objc private func setGeneralDateTimeSeconds(_ sender: NSButton) {
        updateGeneral { $0.dateTimeWidget.showSeconds = sender.state == .on }
    }

    @objc private func setGeneralDateTime24Hour(_ sender: NSButton) {
        updateGeneral { $0.dateTimeWidget.use24HourClock = sender.state == .on }
    }

    @objc private func setGeneralStatsEnabled(_ sender: NSButton) {
        updateGeneral { $0.statsWidget.isEnabled = sender.state == .on }
    }

    @objc private func setGeneralBatteryEnabled(_ sender: NSButton) {
        updateGeneral { $0.batteryWidget.isEnabled = sender.state == .on }
    }

    @objc private func setGeneralStatsCPU(_ sender: NSButton) {
        updateGeneral { $0.statsWidget.showCPU = sender.state == .on }
    }

    @objc private func setGeneralStatsGPU(_ sender: NSButton) {
        updateGeneral { $0.statsWidget.showGPU = sender.state == .on }
    }

    @objc private func setGeneralStatsMemory(_ sender: NSButton) {
        updateGeneral { $0.statsWidget.showMemory = sender.state == .on }
    }

    @objc private func setGeneralStatsNetwork(_ sender: NSButton) {
        updateGeneral { $0.statsWidget.showNetwork = sender.state == .on }
    }

    @objc private func setGeneralStatsCPUDisplay(_ sender: NSPopUpButton) {
        guard let display = selectedStatsCPUDisplay(from: sender) else { return }
        updateGeneral { $0.statsWidget.cpuDisplay = display }
    }

    @objc private func setGeneralStatsMemoryDisplay(_ sender: NSPopUpButton) {
        guard let display = selectedStatsMemoryDisplay(from: sender) else { return }
        updateGeneral { $0.statsWidget.memoryDisplay = display }
    }

    @objc private func setGeneralStatsCPUCoreColor(_ sender: NSColorWell) {
        guard let selection = selectedStatsCPUCoreColor(from: sender) else { return }
        updateGeneral {
            setStatsCPUCoreColor(
                selection.hex,
                kind: selection.kind,
                colors: &$0.statsWidget.cpuCoreColors
            )
        }
    }

    @objc private func setGeneralHeight(_ sender: NSSlider) {
        refreshSliderLabel(sender)
        updateGeneral { $0.taskbarHeight = sender.doubleValue }
    }

    @objc private func setGeneralMinimumItemWidth(_ sender: NSSlider) {
        refreshSliderLabel(sender)
        updateGeneral { $0.minimumItemWidth = sender.doubleValue }
    }

    @objc private func setGeneralMaximumItemWidth(_ sender: NSSlider) {
        refreshSliderLabel(sender)
        updateGeneral { $0.maximumItemWidth = sender.doubleValue }
    }

    @objc private func setGeneralItemSpacing(_ sender: NSSlider) {
        refreshSliderLabel(sender)
        updateGeneral { $0.itemSpacing = sender.doubleValue }
    }

    @objc private func setGeneralWidgetSpacing(_ sender: NSSlider) {
        refreshSliderLabel(sender)
        updateGeneral { $0.widgetSpacing = sender.doubleValue }
    }

    @objc private func setGeneralControlCenterLightsEnabled(_ sender: NSButton) {
        updateGeneral { $0.controlCenterLightsWidget.isEnabled = sender.state == .on }
    }

    @objc private func setGeneralBackgroundOpacity(_ sender: NSSlider) {
        refreshSliderLabel(sender)
        updateGeneral { $0.backgroundOpacity = sender.doubleValue }
    }

    @objc private func setGeneralAvoidOverlappingWindows(_ sender: NSButton) {
        updateGeneral { $0.avoidOverlappingWindows = sender.state == .on }
    }

    @objc private func setGeneralShowMinimizedWindows(_ sender: NSButton) {
        updateGeneral { $0.showMinimizedWindows = sender.state == .on }
    }

    @objc private func setGeneralAutoHide(_ sender: NSButton) {
        updateGeneral { $0.autoHide = sender.state == .on }
    }

    @objc private func setGeneralRevealAnimation(_ sender: NSPopUpButton) {
        guard let animation = selectedRevealAnimation(from: sender) else { return }
        updateGeneral { $0.revealAnimation = animation }
    }

    @objc private func setGeneralRevealDuration(_ sender: NSSlider) {
        refreshSliderLabel(sender)
        updateGeneral { $0.revealAnimationDuration = sender.doubleValue }
    }

    @objc private func toggleMonitorVisibleOverride(_ sender: NSButton) {
        guard let id = selectedMonitorID else { return }
        let value = values(for: id).isVisible
        updateOverrides(for: id) { $0.isVisible = sender.state == .on ? value : nil }
        renderDetail()
    }

    @objc private func toggleMonitorDateTimeOverride(_ sender: NSButton) {
        guard let id = selectedMonitorID else { return }
        let value = values(for: id).dateTimeWidget
        updateOverrides(for: id) {
            $0.dateTimeWidget = sender.state == .on ? value : nil
            $0.clockMode = nil
        }
        renderDetail()
    }

    @objc private func toggleMonitorStatsOverride(_ sender: NSButton) {
        guard let id = selectedMonitorID else { return }
        let value = values(for: id).statsWidget
        updateOverrides(for: id) { $0.statsWidget = sender.state == .on ? value : nil }
        renderDetail()
    }

    @objc private func toggleMonitorBatteryOverride(_ sender: NSButton) {
        guard let id = selectedMonitorID else { return }
        let value = values(for: id).batteryWidget
        updateOverrides(for: id) { $0.batteryWidget = sender.state == .on ? value : nil }
        renderDetail()
    }

    @objc private func toggleMonitorControlCenterLightsOverride(_ sender: NSButton) {
        guard let id = selectedMonitorID else { return }
        let value = values(for: id).controlCenterLightsWidget
        updateOverrides(for: id) {
            $0.controlCenterLightsWidget = sender.state == .on ? value : nil
        }
        renderDetail()
    }

    @objc private func toggleMonitorHeightOverride(_ sender: NSButton) {
        guard let id = selectedMonitorID else { return }
        let value = values(for: id).taskbarHeight
        updateOverrides(for: id) { $0.taskbarHeight = sender.state == .on ? value : nil }
        renderDetail()
    }

    @objc private func toggleMonitorMinimumItemWidthOverride(_ sender: NSButton) {
        guard let id = selectedMonitorID else { return }
        let value = values(for: id).minimumItemWidth
        updateOverrides(for: id) { $0.minimumItemWidth = sender.state == .on ? value : nil }
        renderDetail()
    }

    @objc private func toggleMonitorMaximumItemWidthOverride(_ sender: NSButton) {
        guard let id = selectedMonitorID else { return }
        let value = values(for: id).maximumItemWidth
        updateOverrides(for: id) { $0.maximumItemWidth = sender.state == .on ? value : nil }
        renderDetail()
    }

    @objc private func toggleMonitorItemSpacingOverride(_ sender: NSButton) {
        guard let id = selectedMonitorID else { return }
        let value = values(for: id).itemSpacing
        updateOverrides(for: id) { $0.itemSpacing = sender.state == .on ? value : nil }
        renderDetail()
    }

    @objc private func toggleMonitorWidgetSpacingOverride(_ sender: NSButton) {
        guard let id = selectedMonitorID else { return }
        let value = values(for: id).widgetSpacing
        updateOverrides(for: id) { $0.widgetSpacing = sender.state == .on ? value : nil }
        renderDetail()
    }

    @objc private func toggleMonitorBackgroundOpacityOverride(_ sender: NSButton) {
        guard let id = selectedMonitorID else { return }
        let value = values(for: id).backgroundOpacity
        updateOverrides(for: id) { $0.backgroundOpacity = sender.state == .on ? value : nil }
        renderDetail()
    }

    @objc private func toggleMonitorAvoidOverlappingWindowsOverride(_ sender: NSButton) {
        guard let id = selectedMonitorID else { return }
        let value = values(for: id).avoidOverlappingWindows
        updateOverrides(for: id) { $0.avoidOverlappingWindows = sender.state == .on ? value : nil }
        renderDetail()
    }

    @objc private func toggleMonitorShowMinimizedWindowsOverride(_ sender: NSButton) {
        guard let id = selectedMonitorID else { return }
        let value = values(for: id).showMinimizedWindows
        updateOverrides(for: id) { $0.showMinimizedWindows = sender.state == .on ? value : nil }
        renderDetail()
    }

    @objc private func toggleMonitorAutoHideOverride(_ sender: NSButton) {
        guard let id = selectedMonitorID else { return }
        let value = values(for: id).autoHide
        updateOverrides(for: id) { $0.autoHide = sender.state == .on ? value : nil }
        renderDetail()
    }

    @objc private func toggleMonitorRevealAnimationOverride(_ sender: NSButton) {
        guard let id = selectedMonitorID else { return }
        let value = values(for: id).revealAnimation
        updateOverrides(for: id) { $0.revealAnimation = sender.state == .on ? value : nil }
        renderDetail()
    }

    @objc private func toggleMonitorRevealDurationOverride(_ sender: NSButton) {
        guard let id = selectedMonitorID else { return }
        let value = values(for: id).revealAnimationDuration
        updateOverrides(for: id) { $0.revealAnimationDuration = sender.state == .on ? value : nil }
        renderDetail()
    }

    @objc private func toggleMonitorPinnedAppsOverride(_ sender: NSButton) {
        guard let id = selectedMonitorID else { return }
        let value = values(for: id).pinnedApps
        updateOverrides(for: id) { $0.pinnedApps = sender.state == .on ? value : nil }
        renderDetail()
    }

    @objc private func setMonitorVisible(_ sender: NSButton) {
        guard let id = selectedMonitorID else { return }
        updateOverrides(for: id) { $0.isVisible = sender.state == .on }
    }

    private func updateMonitorDateTimeWidget(_ transform: (inout DateTimeWidgetSettings) -> Void) {
        guard let id = selectedMonitorID else { return }
        let current = overrides(for: id).dateTimeWidget ?? values(for: id).dateTimeWidget
        updateOverrides(for: id) { override in
            var value = current
            transform(&value)
            override.dateTimeWidget = value
            override.clockMode = nil
        }
    }

    @objc private func setMonitorDateTimeEnabled(_ sender: NSButton) {
        updateMonitorDateTimeWidget { $0.isEnabled = sender.state == .on }
    }

    @objc private func setMonitorDateTimeDateDisplay(_ sender: NSPopUpButton) {
        guard let display = selectedDateDisplay(from: sender) else { return }
        updateMonitorDateTimeWidget { $0.dateDisplay = display }
    }

    @objc private func setMonitorDateTimeDayOfWeek(_ sender: NSButton) {
        updateMonitorDateTimeWidget { $0.showDayOfWeek = sender.state == .on }
    }

    @objc private func setMonitorDateTimeSeconds(_ sender: NSButton) {
        updateMonitorDateTimeWidget { $0.showSeconds = sender.state == .on }
    }

    @objc private func setMonitorDateTime24Hour(_ sender: NSButton) {
        updateMonitorDateTimeWidget { $0.use24HourClock = sender.state == .on }
    }

    private func updateMonitorStatsWidget(_ transform: (inout StatsWidgetSettings) -> Void) {
        guard let id = selectedMonitorID else { return }
        let current = overrides(for: id).statsWidget ?? values(for: id).statsWidget
        updateOverrides(for: id) { override in
            var value = current
            transform(&value)
            override.statsWidget = value
        }
    }

    @objc private func setMonitorStatsEnabled(_ sender: NSButton) {
        updateMonitorStatsWidget { $0.isEnabled = sender.state == .on }
    }

    @objc private func setMonitorStatsCPU(_ sender: NSButton) {
        updateMonitorStatsWidget { $0.showCPU = sender.state == .on }
    }

    @objc private func setMonitorStatsGPU(_ sender: NSButton) {
        updateMonitorStatsWidget { $0.showGPU = sender.state == .on }
    }

    @objc private func setMonitorStatsMemory(_ sender: NSButton) {
        updateMonitorStatsWidget { $0.showMemory = sender.state == .on }
    }

    @objc private func setMonitorStatsNetwork(_ sender: NSButton) {
        updateMonitorStatsWidget { $0.showNetwork = sender.state == .on }
    }

    private func updateMonitorBatteryWidget(_ transform: (inout BatteryWidgetSettings) -> Void) {
        guard let id = selectedMonitorID else { return }
        let current = overrides(for: id).batteryWidget ?? values(for: id).batteryWidget
        updateOverrides(for: id) { override in
            var value = current
            transform(&value)
            override.batteryWidget = value
        }
    }

    @objc private func setMonitorBatteryEnabled(_ sender: NSButton) {
        updateMonitorBatteryWidget { $0.isEnabled = sender.state == .on }
    }

    private func updateMonitorControlCenterLightsWidget(
        _ transform: (inout ControlCenterLightsWidgetSettings) -> Void
    ) {
        guard let id = selectedMonitorID else { return }
        let current = overrides(for: id).controlCenterLightsWidget
            ?? values(for: id).controlCenterLightsWidget
        updateOverrides(for: id) { override in
            var value = current
            transform(&value)
            override.controlCenterLightsWidget = value
        }
    }

    @objc private func setMonitorControlCenterLightsEnabled(_ sender: NSButton) {
        updateMonitorControlCenterLightsWidget { $0.isEnabled = sender.state == .on }
    }

    @objc private func setMonitorStatsCPUDisplay(_ sender: NSPopUpButton) {
        guard let display = selectedStatsCPUDisplay(from: sender) else { return }
        updateMonitorStatsWidget { $0.cpuDisplay = display }
    }

    @objc private func setMonitorStatsMemoryDisplay(_ sender: NSPopUpButton) {
        guard let display = selectedStatsMemoryDisplay(from: sender) else { return }
        updateMonitorStatsWidget { $0.memoryDisplay = display }
    }

    @objc private func setMonitorStatsCPUCoreColor(_ sender: NSColorWell) {
        guard let selection = selectedStatsCPUCoreColor(from: sender) else { return }
        updateMonitorStatsWidget {
            setStatsCPUCoreColor(
                selection.hex,
                kind: selection.kind,
                colors: &$0.cpuCoreColors
            )
        }
    }

    @objc private func setMonitorHeight(_ sender: NSSlider) {
        guard let id = selectedMonitorID else { return }
        refreshSliderLabel(sender)
        updateOverrides(for: id) { $0.taskbarHeight = sender.doubleValue }
    }

    @objc private func setMonitorMinimumItemWidth(_ sender: NSSlider) {
        guard let id = selectedMonitorID else { return }
        refreshSliderLabel(sender)
        updateOverrides(for: id) { $0.minimumItemWidth = sender.doubleValue }
    }

    @objc private func setMonitorMaximumItemWidth(_ sender: NSSlider) {
        guard let id = selectedMonitorID else { return }
        refreshSliderLabel(sender)
        updateOverrides(for: id) { $0.maximumItemWidth = sender.doubleValue }
    }

    @objc private func setMonitorItemSpacing(_ sender: NSSlider) {
        guard let id = selectedMonitorID else { return }
        refreshSliderLabel(sender)
        updateOverrides(for: id) { $0.itemSpacing = sender.doubleValue }
    }

    @objc private func setMonitorWidgetSpacing(_ sender: NSSlider) {
        guard let id = selectedMonitorID else { return }
        refreshSliderLabel(sender)
        updateOverrides(for: id) { $0.widgetSpacing = sender.doubleValue }
    }

    @objc private func setMonitorBackgroundOpacity(_ sender: NSSlider) {
        guard let id = selectedMonitorID else { return }
        refreshSliderLabel(sender)
        updateOverrides(for: id) { $0.backgroundOpacity = sender.doubleValue }
    }

    @objc private func setMonitorAvoidOverlappingWindows(_ sender: NSButton) {
        guard let id = selectedMonitorID else { return }
        updateOverrides(for: id) { $0.avoidOverlappingWindows = sender.state == .on }
    }

    @objc private func setMonitorShowMinimizedWindows(_ sender: NSButton) {
        guard let id = selectedMonitorID else { return }
        updateOverrides(for: id) { $0.showMinimizedWindows = sender.state == .on }
    }

    @objc private func setMonitorAutoHide(_ sender: NSButton) {
        guard let id = selectedMonitorID else { return }
        updateOverrides(for: id) { $0.autoHide = sender.state == .on }
    }

    @objc private func setMonitorRevealAnimation(_ sender: NSPopUpButton) {
        guard let id = selectedMonitorID, let animation = selectedRevealAnimation(from: sender) else { return }
        updateOverrides(for: id) { $0.revealAnimation = animation }
    }

    @objc private func setMonitorRevealDuration(_ sender: NSSlider) {
        guard let id = selectedMonitorID else { return }
        refreshSliderLabel(sender)
        updateOverrides(for: id) { $0.revealAnimationDuration = sender.doubleValue }
    }

    @objc private func addPinnedApp(_ sender: NSButton) {
        guard let app = pinCandidatePopup?.selectedItem?.representedObject as? PinnedApp else { return }
        pin(app, for: selectedMonitorID)
        renderDetail()
    }

    @objc private func unpinPinnedApp(_ sender: PinnedAppButton) {
        guard let app = sender.pinnedApp else { return }
        unpin(app, for: selectedMonitorID)
        renderDetail()
    }
}

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

final class SettingsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let settings: TaskbarSettings
    private var screens: [ScreenInfo]
    private var sidebarItems: [SettingsSidebarItem] = []
    private let tableView = NSTableView()
    private let detailView = NSView()

    private var selectedItem: SettingsSidebarItem = .general
    private weak var pinCandidatePopup: NSPopUpButton?

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

        rebuildSidebarItems()
        buildWindowContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateScreens(_ screens: [ScreenInfo]) {
        self.screens = screens
        rebuildSidebarItems()
        tableView.reloadData()

        if !sidebarItems.contains(selectedItem) {
            selectedItem = .general
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
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
        let override = settings.overrides(for: screen.id)
        let resolved = settings.values(for: screen.id)
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
        case .dateTime:
            renderDateTimeWidget(screen: screen, in: stack)
        }
    }

    private func renderDateTimeWidget(screen: ScreenInfo?, in stack: NSStackView) {
        if let screen {
            let override = settings.overrides(for: screen.id)
            let resolved = settings.values(for: screen.id)
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

    private func refreshSliderLabel(_ sender: NSSlider) {
        (sender as? ValueSlider)?.refreshValueLabel()
    }

    @objc private func setStartAtLogin(_ sender: NSButton) {
        settings.setStartAtLogin(sender.state == .on)
    }

    @objc private func setGeneralVisible(_ sender: NSButton) {
        settings.updateGeneral { $0.isVisible = sender.state == .on }
    }

    @objc private func setGeneralGroupByApp(_ sender: NSButton) {
        settings.updateGeneral { $0.groupByApp = sender.state == .on }
    }

    @objc private func setGeneralWindowCounts(_ sender: NSButton) {
        settings.updateGeneral { $0.showWindowCounts = sender.state == .on }
    }

    @objc private func setGeneralDateTimeEnabled(_ sender: NSButton) {
        settings.updateGeneral { $0.dateTimeWidget.isEnabled = sender.state == .on }
    }

    @objc private func setGeneralDateTimeDateDisplay(_ sender: NSPopUpButton) {
        guard let display = selectedDateDisplay(from: sender) else { return }
        settings.updateGeneral { $0.dateTimeWidget.dateDisplay = display }
    }

    @objc private func setGeneralDateTimeDayOfWeek(_ sender: NSButton) {
        settings.updateGeneral { $0.dateTimeWidget.showDayOfWeek = sender.state == .on }
    }

    @objc private func setGeneralDateTimeSeconds(_ sender: NSButton) {
        settings.updateGeneral { $0.dateTimeWidget.showSeconds = sender.state == .on }
    }

    @objc private func setGeneralDateTime24Hour(_ sender: NSButton) {
        settings.updateGeneral { $0.dateTimeWidget.use24HourClock = sender.state == .on }
    }

    @objc private func setGeneralHeight(_ sender: NSSlider) {
        refreshSliderLabel(sender)
        settings.updateGeneral { $0.taskbarHeight = sender.doubleValue }
    }

    @objc private func setGeneralMinimumItemWidth(_ sender: NSSlider) {
        refreshSliderLabel(sender)
        settings.updateGeneral { $0.minimumItemWidth = sender.doubleValue }
    }

    @objc private func setGeneralMaximumItemWidth(_ sender: NSSlider) {
        refreshSliderLabel(sender)
        settings.updateGeneral { $0.maximumItemWidth = sender.doubleValue }
    }

    @objc private func setGeneralItemSpacing(_ sender: NSSlider) {
        refreshSliderLabel(sender)
        settings.updateGeneral { $0.itemSpacing = sender.doubleValue }
    }

    @objc private func setGeneralBackgroundOpacity(_ sender: NSSlider) {
        refreshSliderLabel(sender)
        settings.updateGeneral { $0.backgroundOpacity = sender.doubleValue }
    }

    @objc private func setGeneralAvoidOverlappingWindows(_ sender: NSButton) {
        settings.updateGeneral { $0.avoidOverlappingWindows = sender.state == .on }
    }

    @objc private func setGeneralAutoHide(_ sender: NSButton) {
        settings.updateGeneral { $0.autoHide = sender.state == .on }
    }

    @objc private func setGeneralRevealAnimation(_ sender: NSPopUpButton) {
        guard let animation = selectedRevealAnimation(from: sender) else { return }
        settings.updateGeneral { $0.revealAnimation = animation }
    }

    @objc private func setGeneralRevealDuration(_ sender: NSSlider) {
        refreshSliderLabel(sender)
        settings.updateGeneral { $0.revealAnimationDuration = sender.doubleValue }
    }

    @objc private func toggleMonitorVisibleOverride(_ sender: NSButton) {
        guard let id = selectedMonitorID else { return }
        let value = settings.values(for: id).isVisible
        settings.updateOverrides(for: id) { $0.isVisible = sender.state == .on ? value : nil }
        renderDetail()
    }

    @objc private func toggleMonitorGroupByAppOverride(_ sender: NSButton) {
        guard let id = selectedMonitorID else { return }
        let value = settings.values(for: id).groupByApp
        settings.updateOverrides(for: id) { $0.groupByApp = sender.state == .on ? value : nil }
        renderDetail()
    }

    @objc private func toggleMonitorWindowCountsOverride(_ sender: NSButton) {
        guard let id = selectedMonitorID else { return }
        let value = settings.values(for: id).showWindowCounts
        settings.updateOverrides(for: id) { $0.showWindowCounts = sender.state == .on ? value : nil }
        renderDetail()
    }

    @objc private func toggleMonitorDateTimeOverride(_ sender: NSButton) {
        guard let id = selectedMonitorID else { return }
        let value = settings.values(for: id).dateTimeWidget
        settings.updateOverrides(for: id) {
            $0.dateTimeWidget = sender.state == .on ? value : nil
            $0.clockMode = nil
        }
        renderDetail()
    }

    @objc private func toggleMonitorHeightOverride(_ sender: NSButton) {
        guard let id = selectedMonitorID else { return }
        let value = settings.values(for: id).taskbarHeight
        settings.updateOverrides(for: id) { $0.taskbarHeight = sender.state == .on ? value : nil }
        renderDetail()
    }

    @objc private func toggleMonitorMinimumItemWidthOverride(_ sender: NSButton) {
        guard let id = selectedMonitorID else { return }
        let value = settings.values(for: id).minimumItemWidth
        settings.updateOverrides(for: id) { $0.minimumItemWidth = sender.state == .on ? value : nil }
        renderDetail()
    }

    @objc private func toggleMonitorMaximumItemWidthOverride(_ sender: NSButton) {
        guard let id = selectedMonitorID else { return }
        let value = settings.values(for: id).maximumItemWidth
        settings.updateOverrides(for: id) { $0.maximumItemWidth = sender.state == .on ? value : nil }
        renderDetail()
    }

    @objc private func toggleMonitorItemSpacingOverride(_ sender: NSButton) {
        guard let id = selectedMonitorID else { return }
        let value = settings.values(for: id).itemSpacing
        settings.updateOverrides(for: id) { $0.itemSpacing = sender.state == .on ? value : nil }
        renderDetail()
    }

    @objc private func toggleMonitorBackgroundOpacityOverride(_ sender: NSButton) {
        guard let id = selectedMonitorID else { return }
        let value = settings.values(for: id).backgroundOpacity
        settings.updateOverrides(for: id) { $0.backgroundOpacity = sender.state == .on ? value : nil }
        renderDetail()
    }

    @objc private func toggleMonitorAvoidOverlappingWindowsOverride(_ sender: NSButton) {
        guard let id = selectedMonitorID else { return }
        let value = settings.values(for: id).avoidOverlappingWindows
        settings.updateOverrides(for: id) { $0.avoidOverlappingWindows = sender.state == .on ? value : nil }
        renderDetail()
    }

    @objc private func toggleMonitorAutoHideOverride(_ sender: NSButton) {
        guard let id = selectedMonitorID else { return }
        let value = settings.values(for: id).autoHide
        settings.updateOverrides(for: id) { $0.autoHide = sender.state == .on ? value : nil }
        renderDetail()
    }

    @objc private func toggleMonitorRevealAnimationOverride(_ sender: NSButton) {
        guard let id = selectedMonitorID else { return }
        let value = settings.values(for: id).revealAnimation
        settings.updateOverrides(for: id) { $0.revealAnimation = sender.state == .on ? value : nil }
        renderDetail()
    }

    @objc private func toggleMonitorRevealDurationOverride(_ sender: NSButton) {
        guard let id = selectedMonitorID else { return }
        let value = settings.values(for: id).revealAnimationDuration
        settings.updateOverrides(for: id) { $0.revealAnimationDuration = sender.state == .on ? value : nil }
        renderDetail()
    }

    @objc private func toggleMonitorPinnedAppsOverride(_ sender: NSButton) {
        guard let id = selectedMonitorID else { return }
        let value = settings.values(for: id).pinnedApps
        settings.updateOverrides(for: id) { $0.pinnedApps = sender.state == .on ? value : nil }
        renderDetail()
    }

    @objc private func setMonitorVisible(_ sender: NSButton) {
        guard let id = selectedMonitorID else { return }
        settings.updateOverrides(for: id) { $0.isVisible = sender.state == .on }
    }

    @objc private func setMonitorGroupByApp(_ sender: NSButton) {
        guard let id = selectedMonitorID else { return }
        settings.updateOverrides(for: id) { $0.groupByApp = sender.state == .on }
    }

    @objc private func setMonitorWindowCounts(_ sender: NSButton) {
        guard let id = selectedMonitorID else { return }
        settings.updateOverrides(for: id) { $0.showWindowCounts = sender.state == .on }
    }

    private func updateMonitorDateTimeWidget(_ transform: (inout DateTimeWidgetSettings) -> Void) {
        guard let id = selectedMonitorID else { return }
        let current = settings.overrides(for: id).dateTimeWidget ?? settings.values(for: id).dateTimeWidget
        settings.updateOverrides(for: id) { override in
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

    @objc private func setMonitorHeight(_ sender: NSSlider) {
        guard let id = selectedMonitorID else { return }
        refreshSliderLabel(sender)
        settings.updateOverrides(for: id) { $0.taskbarHeight = sender.doubleValue }
    }

    @objc private func setMonitorMinimumItemWidth(_ sender: NSSlider) {
        guard let id = selectedMonitorID else { return }
        refreshSliderLabel(sender)
        settings.updateOverrides(for: id) { $0.minimumItemWidth = sender.doubleValue }
    }

    @objc private func setMonitorMaximumItemWidth(_ sender: NSSlider) {
        guard let id = selectedMonitorID else { return }
        refreshSliderLabel(sender)
        settings.updateOverrides(for: id) { $0.maximumItemWidth = sender.doubleValue }
    }

    @objc private func setMonitorItemSpacing(_ sender: NSSlider) {
        guard let id = selectedMonitorID else { return }
        refreshSliderLabel(sender)
        settings.updateOverrides(for: id) { $0.itemSpacing = sender.doubleValue }
    }

    @objc private func setMonitorBackgroundOpacity(_ sender: NSSlider) {
        guard let id = selectedMonitorID else { return }
        refreshSliderLabel(sender)
        settings.updateOverrides(for: id) { $0.backgroundOpacity = sender.doubleValue }
    }

    @objc private func setMonitorAvoidOverlappingWindows(_ sender: NSButton) {
        guard let id = selectedMonitorID else { return }
        settings.updateOverrides(for: id) { $0.avoidOverlappingWindows = sender.state == .on }
    }

    @objc private func setMonitorAutoHide(_ sender: NSButton) {
        guard let id = selectedMonitorID else { return }
        settings.updateOverrides(for: id) { $0.autoHide = sender.state == .on }
    }

    @objc private func setMonitorRevealAnimation(_ sender: NSPopUpButton) {
        guard let id = selectedMonitorID, let animation = selectedRevealAnimation(from: sender) else { return }
        settings.updateOverrides(for: id) { $0.revealAnimation = animation }
    }

    @objc private func setMonitorRevealDuration(_ sender: NSSlider) {
        guard let id = selectedMonitorID else { return }
        refreshSliderLabel(sender)
        settings.updateOverrides(for: id) { $0.revealAnimationDuration = sender.doubleValue }
    }

    @objc private func addPinnedApp(_ sender: NSButton) {
        guard let app = pinCandidatePopup?.selectedItem?.representedObject as? PinnedApp else { return }
        if let id = selectedMonitorID {
            settings.pin(app, for: id)
        } else {
            settings.pin(app)
        }
        renderDetail()
    }

    @objc private func unpinPinnedApp(_ sender: PinnedAppButton) {
        guard let app = sender.pinnedApp else { return }
        if let id = selectedMonitorID {
            settings.unpin(app, for: id)
        } else {
            settings.unpin(app)
        }
        renderDetail()
    }
}

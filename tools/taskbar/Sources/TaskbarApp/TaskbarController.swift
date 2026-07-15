import AppKit
import QuartzCore

final class TaskbarPanel {
    let screenID: UInt32
    let panel: NSPanel
    let containerView: TaskbarContainerView
    let view: TaskbarView
    private var screen: ScreenInfo
    private var values: TaskbarSettingValues
    private var currentItems: [TaskbarItem] = []
    private var isShown = true

    init(screen: ScreenInfo, values: TaskbarSettingValues, controller: TaskbarController) {
        screenID = screen.id
        self.screen = screen
        self.values = values
        let height = CGFloat(values.taskbarHeight)

        let frame = NSRect(
            x: screen.appKitFrame.minX,
            y: screen.appKitFrame.minY,
            width: screen.appKitFrame.width,
            height: height
        )

        panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "mikerosoft taskbar"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        view = TaskbarView(frame: NSRect(x: 0, y: 0, width: frame.width, height: frame.height))
        containerView = TaskbarContainerView(frame: view.frame, taskbarView: view)
        view.settings = values
        view.onActivate = { [weak controller] item in
            controller?.activate(item: item)
        }
        view.onMenu = { [weak controller, screenID] in
            controller?.makeSettingsMenu(screenID: screenID) ?? NSMenu()
        }
        view.onItemMenu = { [weak controller, screenID] item in
            controller?.makeItemMenu(for: item, screenID: screenID)
        }
        view.onWidgetMenu = { [weak controller, screenID] widgetID in
            controller?.makeWidgetMenu(for: widgetID, screenID: screenID)
        }
        view.onWidgetActivate = { [weak controller, screenID] widgetID, statsMetric, rect, view in
            controller?.activateWidget(widgetID, statsMetric: statsMetric, screenID: screenID, relativeTo: rect, of: view)
        }
        view.onMovePinnedItem = { [weak controller, screenID] item, target in
            controller?.movePinnedItem(item, before: target, screenID: screenID)
        }
        panel.contentView = containerView
    }

    func update(screen: ScreenInfo, items: [TaskbarItem], values: TaskbarSettingValues) {
        let valuesChanged = self.values != values
        self.screen = screen
        self.values = values

        let height = CGFloat(values.taskbarHeight)
        let frame = NSRect(
            x: screen.appKitFrame.minX,
            y: screen.appKitFrame.minY,
            width: screen.appKitFrame.width,
            height: height
        )
        let contentFrame = NSRect(x: 0, y: 0, width: frame.width, height: frame.height)
        let contentChanged = currentItems != items
            || valuesChanged
            || containerView.frame != contentFrame

        if contentChanged {
            containerView.frame = contentFrame
            containerView.update(items: items, settings: values)
            currentItems = items
        }
        guard values.isVisible else {
            panel.orderOut(nil)
            return
        }
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }

        if values.autoHide {
            updateAutoHide(mouseLocation: NSEvent.mouseLocation, animated: false)
        } else {
            setShown(true, animated: false)
        }
    }

    func updateAutoHide(mouseLocation: NSPoint, animated: Bool) {
        guard values.isVisible, values.autoHide else { return }
        setShown(shouldReveal(mouseLocation: mouseLocation), animated: animated)
    }

    func close() {
        panel.orderOut(nil)
        panel.contentView = nil
    }

    private func shouldReveal(mouseLocation: NSPoint) -> Bool {
        guard screen.appKitFrame.contains(mouseLocation) else { return false }
        let revealHeight = isShown ? CGFloat(values.taskbarHeight) + 8 : 6
        return mouseLocation.y <= screen.appKitFrame.minY + revealHeight
    }

    private func setShown(_ shown: Bool, animated: Bool) {
        let targetFrame = frame(shown: shown)
        guard panel.frame != targetFrame else { return }

        isShown = shown
        if !animated || values.revealAnimation == .instant || values.revealAnimationDuration <= 0 {
            panel.setFrame(targetFrame, display: true)
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = values.revealAnimationDuration
            context.timingFunction = timingFunction(for: values.revealAnimation)
            panel.animator().setFrame(targetFrame, display: true)
        }
    }

    private func frame(shown: Bool) -> NSRect {
        let height = CGFloat(values.taskbarHeight)
        let visibleStrip: CGFloat = 3
        return NSRect(
            x: screen.appKitFrame.minX,
            y: shown ? screen.appKitFrame.minY : screen.appKitFrame.minY - height + visibleStrip,
            width: screen.appKitFrame.width,
            height: height
        )
    }

    private func timingFunction(for animation: RevealAnimation) -> CAMediaTimingFunction? {
        switch animation {
        case .instant:
            return nil
        case .linear:
            return CAMediaTimingFunction(name: .linear)
        case .ease:
            return CAMediaTimingFunction(name: .easeInEaseOut)
        }
    }
}

final class TaskbarController: NSObject {
    private let settings = TaskbarSettings()
    private let windowAvoider = WindowAvoider()
    private let performanceWatchdog = MainThreadWatchdog()
    private var panels: [UInt32: TaskbarPanel] = [:]
    private var timer: Timer?
    private var autoHideTimer: Timer?
    private var pendingRefreshWorkItem: DispatchWorkItem?
    private var settingsWindowController: SettingsWindowController?
    private var statsPopoverPanel: NSPanel?
    private var statsPopoverMetric: StatsWidgetMetric?
    private var statsPopoverEventMonitors: [Any] = []
    private var menuItemContext: (screenID: UInt32, item: TaskbarItem)?
    private var menuWidgetContext: (screenID: UInt32, widgetID: TaskbarWidgetID)?
    private var menuScreenContext: UInt32?
    private let commandFileURL = URL(fileURLWithPath: "/tmp/mikerosoft-taskbar-command")

    func start() {
        configureTaskbarAccessibilityMessagingTimeout()
        performanceWatchdog.start()
        settings.onChange = { [weak self] in
            self?.syncStartAtLogin()
            self?.refresh()
        }
        syncStartAtLogin()
        log("screens=\(collectScreens().map { "\($0.name):\($0.appKitFrame)" }.joined(separator: " | "))")
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        timer?.tolerance = 0.2
        autoHideTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            self?.updateAutoHide()
        }
        autoHideTimer?.tolerance = 0.02
        log("taskbar ready")
    }

    @objc func refresh() {
        TaskbarPerformanceDiagnostics.measure("refresh", threshold: 0.25) {
            refreshNow()
        }
    }

    private func refreshNow() {
        processCommandFile()

        let screens = collectScreens()
        let screenIDs = Set(screens.map(\.id))
        let valuesByScreen = screens.reduce(into: [UInt32: TaskbarSettingValues]()) { result, screen in
            result[screen.id] = settings.values(for: screen.id)
        }

        for staleID in panels.keys where !screenIDs.contains(staleID) {
            panels[staleID]?.close()
            panels.removeValue(forKey: staleID)
        }

        for screen in screens where panels[screen.id] == nil {
            panels[screen.id] = TaskbarPanel(screen: screen, values: settings.values(for: screen.id), controller: self)
        }

        let currentProcessID = currentPID()
        let shouldIncludeMinimized = screens.contains { screen in
            valuesByScreen[screen.id]?.showMinimizedWindows ?? TaskbarSettingValues.defaults.showMinimizedWindows
        }
        let records = TaskbarPerformanceDiagnostics.measure("collectWindowRecords", threshold: 0.12) {
            collectWindowRecords(screens: screens, includeMinimized: shouldIncludeMinimized)
        }
        let visibleForWindowAvoidance = visibleWindows(records, currentPID: currentProcessID)
        let currentFrontmostPID = frontmostPID()
        let currentFrontmostWindowID = frontmostWindowID(in: visibleForWindowAvoidance, frontmostPID: currentFrontmostPID)

        for screen in screens {
            let values = valuesByScreen[screen.id] ?? settings.values(for: screen.id)
            let taskbarWindows = visibleWindows(
                records,
                currentPID: currentProcessID,
                includeMinimized: values.showMinimizedWindows
            )
            let screenWindows = taskbarWindows.filter { $0.screenID == screen.id }
            let items = buildTaskbarItems(
                windows: screenWindows,
                frontmostPID: currentFrontmostPID,
                frontmostWindowID: currentFrontmostWindowID,
                groupByApp: false,
                pinnedApps: values.pinnedApps
            )
            panels[screen.id]?.update(screen: screen, items: items, values: values)
        }

        let avoidanceRequests = windowAdjustmentRequests(
            records: visibleForWindowAvoidance,
            screens: screens,
            valuesByScreen: valuesByScreen,
            currentPID: currentProcessID
        )
        windowAvoider.keepWindowsAboveTaskbars(adjustments: avoidanceRequests)
    }

    func activate(item: TaskbarItem) {
        let pidText = item.pid.map(String.init) ?? "not-running"
        log("activating \(item.owner) pid=\(pidText) windows=\(item.windowIDs)")
        if let pid = item.pid {
            if item.isMinimized {
                unminimizeApplicationWindowAsync(pid: pid, title: item.title)
            }
            activateApplicationWindowAsync(item: item)
        } else {
            _ = launchApplication(appPath: item.appPath, bundleID: item.bundleID)
        }
        scheduleRefreshSoon()
    }

    private func scheduleRefreshSoon(after delay: TimeInterval = 0.08) {
        pendingRefreshWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.pendingRefreshWorkItem = nil
            self?.refresh()
        }
        pendingRefreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func processCommandFile() {
        guard let command = try? String(contentsOf: commandFileURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !command.isEmpty
        else {
            return
        }

        try? FileManager.default.removeItem(at: commandFileURL)

        switch command {
        case "show-settings":
            log("command show-settings")
            showSettings()
        default:
            log("unknown command \(command)")
        }
    }

    private func updateAutoHide() {
        let mouseLocation = NSEvent.mouseLocation
        panels.values.forEach { $0.updateAutoHide(mouseLocation: mouseLocation, animated: true) }
    }

    func makeSettingsMenu(screenID: UInt32? = nil) -> NSMenu {
        menuScreenContext = screenID
        let menu = NSMenu(title: "Taskbar")

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(showSettingsFromMenu), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refreshFromMenu), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let quitItem = NSMenuItem(title: "Quit Taskbar", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    func makeItemMenu(for item: TaskbarItem, screenID: UInt32) -> NSMenu {
        menuItemContext = (screenID, item)
        menuScreenContext = screenID

        let menu = NSMenu(title: item.owner)
        let pinTitle = item.isPinned ? "Unpin \(item.owner)" : "Pin \(item.owner)"
        let pinItem = NSMenuItem(title: pinTitle, action: #selector(togglePinnedMenuItem), keyEquivalent: "")
        pinItem.target = self
        menu.addItem(pinItem)

        if item.pid != nil {
            let forceQuitItem = NSMenuItem(title: "Force Quit \(item.owner)", action: #selector(forceQuitMenuItem), keyEquivalent: "")
            forceQuitItem.target = self
            menu.addItem(forceQuitItem)
        }

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(showSettingsFromMenu), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        return menu
    }

    func makeWidgetMenu(for widgetID: TaskbarWidgetID, screenID: UInt32) -> NSMenu? {
        menuWidgetContext = (screenID, widgetID)
        menuScreenContext = screenID

        switch widgetID {
        case .stats:
            return makeStatsWidgetMenu(screenID: screenID)
        case .dateTime:
            return makeDateTimeWidgetMenu(screenID: screenID)
        }
    }

    func activateWidget(_ widgetID: TaskbarWidgetID, statsMetric: StatsWidgetMetric?, screenID: UInt32, relativeTo rect: NSRect, of view: NSView) {
        switch widgetID {
        case .stats:
            showStatsPopover(metric: statsMetric ?? .cpu, screenID: screenID, relativeTo: rect, of: view)
        case .dateTime:
            break
        }
    }

    private func showStatsPopover(metric: StatsWidgetMetric, screenID _: UInt32, relativeTo rect: NSRect, of view: NSView) {
        if statsPopoverPanel?.isVisible == true, statsPopoverMetric == metric {
            closeStatsPopover()
            return
        }

        guard let window = view.window else { return }
        closeStatsPopover()

        let windowRect = view.convert(rect, to: nil)
        let screenRect = window.convertToScreen(windowRect)
        let screenFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? screenRect
        let preferredSize = StatsPopoverLayout.size(for: metric)
        let size = NSSize(
            width: preferredSize.width,
            height: min(preferredSize.height, max(320, screenFrame.height - 16))
        )
        let x = min(
            max(screenRect.midX - size.width / 2, screenFrame.minX + 8),
            screenFrame.maxX - size.width - 8
        )
        let y = min(screenRect.maxY + 8, screenFrame.maxY - size.height - 8)

        let panel = NSPanel(
            contentRect: NSRect(origin: NSPoint(x: x, y: y), size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentViewController = StatsPopoverViewController(metric: metric, size: size)
        statsPopoverMetric = metric
        statsPopoverPanel = panel
        installStatsPopoverEventMonitors(for: panel)
        panel.orderFrontRegardless()
    }

    private func closeStatsPopover() {
        statsPopoverPanel?.close()
        statsPopoverPanel = nil
        statsPopoverMetric = nil
        removeStatsPopoverEventMonitors()
    }

    private func installStatsPopoverEventMonitors(for panel: NSPanel) {
        removeStatsPopoverEventMonitors()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

        if let localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self, weak panel] event in
            guard let panel else { return event }
            if let eventWindow = event.window {
                let point = eventWindow.convertToScreen(NSRect(origin: event.locationInWindow, size: .zero)).origin
                if panel.frame.contains(point) {
                    return event
                }
            }
            self?.closeStatsPopover()
            return event
        }) {
            statsPopoverEventMonitors.append(localMonitor)
        }

        if let globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self, weak panel] _ in
            guard let panel else { return }
            if !panel.frame.contains(NSEvent.mouseLocation) {
                self?.closeStatsPopover()
            }
        }) {
            statsPopoverEventMonitors.append(globalMonitor)
        }
    }

    private func removeStatsPopoverEventMonitors() {
        for monitor in statsPopoverEventMonitors {
            NSEvent.removeMonitor(monitor)
        }
        statsPopoverEventMonitors.removeAll()
    }

    private func makeStatsWidgetMenu(screenID: UInt32) -> NSMenu {
        let value = settings.values(for: screenID).statsWidget
        let snapshot = TaskbarStatsSampler.shared.snapshot()
        let menu = NSMenu(title: "Stats")

        let summary = NSMenuItem(
            title: "CPU \(formattedStatsPercent(snapshot.cpuPercent))  GPU \(formattedStatsPercent(snapshot.gpuPercent))  RAM \(formattedStatsPercent(snapshot.memoryPercent))",
            action: nil,
            keyEquivalent: ""
        )
        summary.isEnabled = false
        menu.addItem(summary)

        let network = NSMenuItem(
            title: "Net ↑ \(formattedStatsBytesPerSecond(snapshot.networkUploadBytesPerSecond))  ↓ \(formattedStatsBytesPerSecond(snapshot.networkDownloadBytesPerSecond))",
            action: nil,
            keyEquivalent: ""
        )
        network.isEnabled = false
        menu.addItem(network)
        menu.addItem(.separator())

        addWidgetToggle(
            title: "Show Stats",
            state: value.isEnabled,
            action: #selector(toggleStatsWidgetFromMenu),
            to: menu
        )
        addWidgetToggle(
            title: "CPU",
            state: value.showCPU,
            action: #selector(toggleStatsCPUFromMenu),
            to: menu
        )
        addWidgetToggle(
            title: "GPU",
            state: value.showGPU,
            action: #selector(toggleStatsGPUFromMenu),
            to: menu
        )
        addWidgetToggle(
            title: "RAM",
            state: value.showMemory,
            action: #selector(toggleStatsMemoryFromMenu),
            to: menu
        )
        addWidgetToggle(
            title: "Network",
            state: value.showNetwork,
            action: #selector(toggleStatsNetworkFromMenu),
            to: menu
        )
        addWidgetToggle(
            title: "CPU Graph",
            state: value.showMiniGraph,
            action: #selector(toggleStatsMiniGraphFromMenu),
            to: menu
        )

        let memoryDisplayItem = NSMenuItem(title: "RAM Display", action: nil, keyEquivalent: "")
        let memoryDisplayMenu = NSMenu(title: "RAM Display")
        for display in StatsMemoryDisplay.allCases {
            let item = NSMenuItem(title: display.label, action: #selector(setStatsMemoryDisplayFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = display.rawValue
            item.state = value.memoryDisplay == display ? .on : .off
            memoryDisplayMenu.addItem(item)
        }
        menu.addItem(memoryDisplayItem)
        menu.setSubmenu(memoryDisplayMenu, for: memoryDisplayItem)

        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Stats Settings...", action: #selector(showWidgetSettingsFromMenu), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        return menu
    }

    private func makeDateTimeWidgetMenu(screenID: UInt32) -> NSMenu {
        let value = settings.values(for: screenID).dateTimeWidget
        let menu = NSMenu(title: "Date & Time")

        let showItem = NSMenuItem(title: "Show Date & Time", action: #selector(toggleDateTimeWidgetFromMenu), keyEquivalent: "")
        showItem.target = self
        showItem.state = value.isEnabled ? .on : .off
        menu.addItem(showItem)

        let dateItem = NSMenuItem(title: "Date", action: nil, keyEquivalent: "")
        let dateMenu = NSMenu(title: "Date")
        for display in DateTimeDateDisplay.allCases {
            let item = NSMenuItem(title: display.label, action: #selector(setDateTimeDateDisplayFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = display.rawValue
            item.state = value.dateDisplay == display ? .on : .off
            dateMenu.addItem(item)
        }
        menu.addItem(dateItem)
        menu.setSubmenu(dateMenu, for: dateItem)

        addWidgetToggle(
            title: "Show Day of Week",
            state: value.showDayOfWeek,
            action: #selector(toggleDateTimeDayOfWeekFromMenu),
            to: menu
        )
        addWidgetToggle(
            title: "Show Seconds",
            state: value.showSeconds,
            action: #selector(toggleDateTimeSecondsFromMenu),
            to: menu
        )
        addWidgetToggle(
            title: "24-Hour Time",
            state: value.use24HourClock,
            action: #selector(toggleDateTime24HourFromMenu),
            to: menu
        )

        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Date & Time Settings...", action: #selector(showWidgetSettingsFromMenu), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        return menu
    }

    private func addWidgetToggle(title: String, state: Bool, action: Selector, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = state ? .on : .off
        menu.addItem(item)
    }

    @objc func showSettings() {
        showSettings(screenID: nil)
    }

    @objc private func showSettingsFromMenu() {
        showSettings(screenID: menuScreenContext)
    }

    @objc private func showWidgetSettingsFromMenu() {
        guard let context = menuWidgetContext else {
            showSettings(screenID: menuScreenContext)
            return
        }
        showSettings(widgetID: context.widgetID, screenID: context.screenID)
    }

    func showSettings(screenID: UInt32?) {
        let screens = collectScreens()
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(settings: settings, screens: screens)
        } else {
            settingsWindowController?.updateScreens(screens)
        }
        if let screenID {
            settingsWindowController?.selectMonitor(screenID: screenID)
        }
        settingsWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showSettings(widgetID: TaskbarWidgetID, screenID: UInt32?) {
        let screens = collectScreens()
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(settings: settings, screens: screens)
        } else {
            settingsWindowController?.updateScreens(screens)
        }
        settingsWindowController?.selectWidget(widgetID, screenID: screenID)
        settingsWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func refreshFromMenu() {
        refresh()
    }

    @objc private func togglePinnedMenuItem() {
        guard let context = menuItemContext else { return }
        let app = PinnedApp(
            displayName: context.item.owner,
            bundleID: context.item.bundleID,
            appPath: context.item.appPath
        )

        if context.item.isPinned {
            settings.unpin(app, for: context.screenID)
        } else {
            settings.pin(app, for: context.screenID)
        }
        refresh()
    }

    func movePinnedItem(_ item: TaskbarItem, before target: TaskbarItem?, screenID: UInt32) {
        settings.movePinnedApp(
            movingIdentity: item.identity,
            beforeIdentity: target?.identity,
            for: screenID
        )
        refresh()
    }

    @objc private func forceQuitMenuItem() {
        guard let pid = menuItemContext?.item.pid else { return }
        _ = forceQuitApplication(pid: pid)
        refresh()
    }

    @objc private func toggleDateTimeWidgetFromMenu() {
        updateDateTimeWidgetFromMenu { $0.isEnabled.toggle() }
    }

    @objc private func setDateTimeDateDisplayFromMenu(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let display = DateTimeDateDisplay(rawValue: rawValue)
        else {
            return
        }
        updateDateTimeWidgetFromMenu { $0.dateDisplay = display }
    }

    @objc private func toggleDateTimeDayOfWeekFromMenu() {
        updateDateTimeWidgetFromMenu { $0.showDayOfWeek.toggle() }
    }

    @objc private func toggleDateTimeSecondsFromMenu() {
        updateDateTimeWidgetFromMenu { $0.showSeconds.toggle() }
    }

    @objc private func toggleDateTime24HourFromMenu() {
        updateDateTimeWidgetFromMenu { $0.use24HourClock.toggle() }
    }

    @objc private func toggleStatsWidgetFromMenu() {
        updateStatsWidgetFromMenu { $0.isEnabled.toggle() }
    }

    @objc private func toggleStatsCPUFromMenu() {
        updateStatsWidgetFromMenu { $0.showCPU.toggle() }
    }

    @objc private func toggleStatsGPUFromMenu() {
        updateStatsWidgetFromMenu { $0.showGPU.toggle() }
    }

    @objc private func toggleStatsMemoryFromMenu() {
        updateStatsWidgetFromMenu { $0.showMemory.toggle() }
    }

    @objc private func toggleStatsNetworkFromMenu() {
        updateStatsWidgetFromMenu { $0.showNetwork.toggle() }
    }

    @objc private func toggleStatsMiniGraphFromMenu() {
        updateStatsWidgetFromMenu { $0.showMiniGraph.toggle() }
    }

    @objc private func setStatsMemoryDisplayFromMenu(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let display = StatsMemoryDisplay(rawValue: rawValue)
        else {
            return
        }
        updateStatsWidgetFromMenu { $0.memoryDisplay = display }
    }

    private func updateDateTimeWidgetFromMenu(_ transform: (inout DateTimeWidgetSettings) -> Void) {
        guard let context = menuWidgetContext, context.widgetID == .dateTime else { return }
        let current = settings.overrides(for: context.screenID).dateTimeWidget
            ?? settings.values(for: context.screenID).dateTimeWidget
        settings.updateOverrides(for: context.screenID) { override in
            var value = current
            transform(&value)
            override.dateTimeWidget = value
            override.clockMode = nil
        }
        refresh()
    }

    private func updateStatsWidgetFromMenu(_ transform: (inout StatsWidgetSettings) -> Void) {
        guard let context = menuWidgetContext, context.widgetID == .stats else { return }
        let current = settings.overrides(for: context.screenID).statsWidget
            ?? settings.values(for: context.screenID).statsWidget
        settings.updateOverrides(for: context.screenID) { override in
            var value = current
            transform(&value)
            override.statsWidget = value
        }
        refresh()
    }

    private func syncStartAtLogin() {
        StartupManager.setEnabled(settings.preferences.startAtLogin)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

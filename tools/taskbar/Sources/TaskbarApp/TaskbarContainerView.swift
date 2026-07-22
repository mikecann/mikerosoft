import AppKit
import QuartzCore

func shouldRunTaskbarWidgetRepaintTimer(
    values: TaskbarSettingValues,
    isAttachedToWindow: Bool,
    isPanelVisible: Bool
) -> Bool {
    isAttachedToWindow
        && isPanelVisible
        && (values.dateTimeWidget.isEnabled || values.statsWidget.isEnabled || values.batteryWidget.isEnabled)
}

final class TaskbarContainerView: NSView {
    let taskbarView: TaskbarView

    private let requestWidgetRepaint: (TaskbarView) -> Void
    private let selectedHighlightLayer = CALayer()
    private var selectedHighlightKey: String?
    private var selectedHighlightTargetFrame: CGRect?
    private var isPanelVisible = false
    private var widgetRepaintTimer: Timer?

    init(
        frame: NSRect,
        taskbarView: TaskbarView,
        requestWidgetRepaint: @escaping (TaskbarView) -> Void = { $0.needsDisplay = true }
    ) {
        self.taskbarView = taskbarView
        self.requestWidgetRepaint = requestWidgetRepaint
        super.init(frame: frame)

        wantsLayer = true
        layer?.masksToBounds = true

        selectedHighlightLayer.backgroundColor = NSColor(calibratedWhite: 0.96, alpha: 0.88).cgColor
        selectedHighlightLayer.borderColor = NSColor(calibratedWhite: 1.0, alpha: 0.50).cgColor
        selectedHighlightLayer.borderWidth = 1
        selectedHighlightLayer.zPosition = 1
        selectedHighlightLayer.isHidden = true
        layer?.addSublayer(selectedHighlightLayer)

        taskbarView.wantsLayer = true
        taskbarView.layer?.backgroundColor = NSColor.clear.cgColor
        taskbarView.layer?.zPosition = 2
        addSubview(taskbarView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        widgetRepaintTimer?.invalidate()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateWidgetRepaintTimer()
    }

    override func layout() {
        super.layout()
        taskbarView.frame = bounds
        updateBackground(values: taskbarView.settings)
        updateSelectedHighlight(animated: false)
    }

    func update(items: [TaskbarItem], settings: TaskbarSettingValues) {
        updateBackground(values: settings)
        taskbarView.update(items: items, settings: settings)
        updateSelectedHighlight(animated: true)
        updateWidgetRepaintTimer()
    }

    func setWidgetRepaintVisibility(_ isVisible: Bool) {
        guard isPanelVisible != isVisible else { return }
        isPanelVisible = isVisible
        updateWidgetRepaintTimer()
    }

    private func updateWidgetRepaintTimer() {
        let shouldRun = shouldRunTaskbarWidgetRepaintTimer(
            values: taskbarView.settings,
            isAttachedToWindow: window != nil,
            isPanelVisible: isPanelVisible
        )
        guard shouldRun else {
            stopWidgetRepaintTimer()
            return
        }
        guard widgetRepaintTimer == nil else { return }

        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.requestWidgetRepaint(self.taskbarView)
        }
        timer.tolerance = 0.1
        widgetRepaintTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopWidgetRepaintTimer() {
        widgetRepaintTimer?.invalidate()
        widgetRepaintTimer = nil
    }

    private func updateBackground(values: TaskbarSettingValues) {
        layer?.backgroundColor = NSColor(calibratedWhite: 0.06, alpha: CGFloat(values.backgroundOpacity)).cgColor
    }

    private func updateSelectedHighlight(animated: Bool) {
        guard let selected = taskbarView.frontmostTileLayout() else {
            clearSelectedHighlight()
            return
        }

        let targetFrame = selected.rect
        let targetKey = selectedHighlightIdentity(for: selected.item)
        let targetChanged = selectedHighlightTargetFrame?.isMeaningfullyDifferent(from: targetFrame) ?? true
        guard selectedHighlightKey != targetKey || targetChanged else { return }

        let wasVisible = !selectedHighlightLayer.isHidden && selectedHighlightTargetFrame != nil
        selectedHighlightKey = targetKey
        selectedHighlightTargetFrame = targetFrame

        selectedHighlightLayer.isHidden = false
        moveSelectedHighlight(to: targetFrame, animated: animated && wasVisible)
    }

    private func moveSelectedHighlight(to targetFrame: CGRect, animated: Bool) {
        let cornerRadius = min(10, targetFrame.height / 2)

        guard animated else {
            CATransaction.withDisabledActions {
                selectedHighlightLayer.frame = targetFrame
                selectedHighlightLayer.cornerRadius = cornerRadius
            }
            return
        }

        let startFrame = selectedHighlightLayer.presentation()?.frame ?? selectedHighlightLayer.frame
        let startCornerRadius = selectedHighlightLayer.presentation()?.cornerRadius ?? selectedHighlightLayer.cornerRadius
        selectedHighlightLayer.removeAllAnimations()

        CATransaction.withDisabledActions {
            selectedHighlightLayer.frame = startFrame
            selectedHighlightLayer.cornerRadius = startCornerRadius
        }

        CATransaction.begin()
        CATransaction.setAnimationDuration(TaskbarSelectionAnimation.duration)
        CATransaction.setAnimationTimingFunction(TaskbarSelectionAnimation.timingFunction)
        selectedHighlightLayer.frame = targetFrame
        selectedHighlightLayer.cornerRadius = cornerRadius
        CATransaction.commit()
    }

    private func clearSelectedHighlight() {
        selectedHighlightKey = nil
        selectedHighlightTargetFrame = nil
        selectedHighlightLayer.removeAllAnimations()
        selectedHighlightLayer.isHidden = true
    }

    private func selectedHighlightIdentity(for item: TaskbarItem) -> String {
        "\(item.identity)#\(item.windowIDs.map(String.init).joined(separator: ","))"
    }
}

private extension CATransaction {
    static func withDisabledActions(_ work: () -> Void) {
        begin()
        setDisableActions(true)
        work()
        commit()
    }
}

private extension CGRect {
    func isMeaningfullyDifferent(from other: CGRect) -> Bool {
        abs(minX - other.minX) > 0.5
            || abs(minY - other.minY) > 0.5
            || abs(width - other.width) > 0.5
            || abs(height - other.height) > 0.5
    }
}

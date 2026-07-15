import ApplicationServices
import CoreGraphics
import Foundation

private let minimumClampedWindowHeight: CGFloat = 120
private let slowAccessibilityClampThreshold: TimeInterval = 0.15

struct WindowAdjustmentRequest: Equatable {
    let windowID: Int
    let pid: pid_t
    let originalFrame: CGRect
    let clampedFrame: CGRect
}

struct AccessibilityTrustState {
    private var hasPrompted = false

    mutating func isTrusted(
        isCurrentlyTrusted: () -> Bool = AXIsProcessTrusted,
        promptForTrust: () -> Bool = promptForAccessibilityTrust
    ) -> Bool {
        if isCurrentlyTrusted() {
            return true
        }

        guard !hasPrompted else {
            return false
        }

        hasPrompted = true
        return promptForTrust()
    }
}

private func promptForAccessibilityTrust() -> Bool {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
}

func clampedWindowFrame(_ frame: CGRect, screen: ScreenInfo, reservedBottomHeight: CGFloat) -> CGRect? {
    guard reservedBottomHeight > 0 else { return nil }

    let availableMaxY = screen.quartzFrame.maxY - reservedBottomHeight
    guard frame.maxY > availableMaxY + 1 else { return nil }

    var y = frame.minY
    var height = availableMaxY - y
    if height < minimumClampedWindowHeight {
        height = min(minimumClampedWindowHeight, screen.quartzFrame.height - reservedBottomHeight)
        y = max(screen.quartzFrame.minY, availableMaxY - height)
    }

    guard height > 0 else { return nil }
    return CGRect(x: frame.minX, y: y, width: frame.width, height: height)
}

func windowAdjustmentRequests(
    records: [WindowRecord],
    screens: [ScreenInfo],
    valuesByScreen: [UInt32: TaskbarSettingValues],
    currentPID: pid_t
) -> [WindowAdjustmentRequest] {
    let screensByID = screens.reduce(into: [UInt32: ScreenInfo]()) { result, screen in
        result[screen.id] = screen
    }
    var adjustedWindowIDs = Set<Int>()
    var requests: [WindowAdjustmentRequest] = []

    for record in records {
        guard record.pid != currentPID else { continue }
        guard record.layer == 0, record.isOnScreen else { continue }
        guard let screenID = record.screenID,
              let screen = screensByID[screenID],
              let values = valuesByScreen[screenID]
        else {
            continue
        }

        guard values.isVisible, values.avoidOverlappingWindows, !values.autoHide else { continue }
        guard let clamped = clampedWindowFrame(record.bounds, screen: screen, reservedBottomHeight: values.taskbarHeight) else { continue }
        guard !adjustedWindowIDs.contains(record.windowID) else { continue }

        requests.append(
            WindowAdjustmentRequest(
                windowID: record.windowID,
                pid: record.pid,
                originalFrame: record.bounds,
                clampedFrame: clamped
            )
        )
        adjustedWindowIDs.insert(record.windowID)
    }

    return requests
}

final class WindowAvoider {
    private let queue = DispatchQueue(label: "mikerosoft.taskbar.window-avoidance", qos: .userInitiated)
    private let stateLock = NSLock()
    private var hasLoggedMissingPermission = false
    private var accessibilityTrustState = AccessibilityTrustState()
    private var pendingRequests: [WindowAdjustmentRequest]?
    private var isPassRunning = false

    func keepWindowsAboveTaskbars(adjustments requests: [WindowAdjustmentRequest]) {
        stateLock.lock()
        pendingRequests = requests
        let shouldStartPass = !isPassRunning
        if shouldStartPass {
            isPassRunning = true
        }
        stateLock.unlock()

        guard shouldStartPass else { return }

        queue.async { [weak self] in
            self?.runPendingPasses()
        }
    }

    private func runPendingPasses() {
        while true {
            stateLock.lock()
            let requests = pendingRequests
            pendingRequests = nil
            if requests == nil {
                isPassRunning = false
            }
            stateLock.unlock()

            guard let requests else { return }
            guard !requests.isEmpty else { continue }
            runAdjustmentPass(requests)
        }
    }

    private func runAdjustmentPass(_ requests: [WindowAdjustmentRequest]) {
        guard accessibilityTrustState.isTrusted() else {
            if !hasLoggedMissingPermission {
                hasLoggedMissingPermission = true
                log("window avoidance needs Accessibility permission before it can resize other apps")
            }
            return
        }

        for request in requests {
            let startedAt = DispatchTime.now()
            _ = clampAccessibilityWindow(pid: request.pid, matching: request.originalFrame, to: request.clampedFrame)
            TaskbarPerformanceDiagnostics.logIfSlow(
                "window-avoidance AX pid=\(request.pid) window=\(request.windowID)",
                startedAt: startedAt,
                threshold: slowAccessibilityClampThreshold
            )
        }
    }

    private func clampAccessibilityWindow(pid: pid_t, matching originalFrame: CGRect, to newFrame: CGRect) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        setTaskbarAccessibilityMessagingTimeout(app)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement]
        else {
            return false
        }

        for window in windows {
            setTaskbarAccessibilityMessagingTimeout(window)
            guard let frame = accessibilityFrame(for: window), approximatelyEqual(frame, originalFrame) else {
                continue
            }

            setAccessibilityFrame(newFrame, for: window)
            return true
        }

        return false
    }

    private func accessibilityFrame(for window: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue,
              let sizeValue
        else {
            return nil
        }

        let positionAXValue = positionValue as! AXValue
        let sizeAXValue = sizeValue as! AXValue
        var point = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionAXValue, .cgPoint, &point)
        AXValueGetValue(sizeAXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }

    private func setAccessibilityFrame(_ frame: CGRect, for window: AXUIElement) {
        var point = frame.origin
        var size = frame.size
        if let position = AXValueCreate(.cgPoint, &point) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
        }
        if let axSize = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, axSize)
        }
    }

    private func approximatelyEqual(_ left: CGRect, _ right: CGRect) -> Bool {
        abs(left.minX - right.minX) < 4
            && abs(left.minY - right.minY) < 4
            && abs(left.width - right.width) < 4
            && abs(left.height - right.height) < 4
    }
}

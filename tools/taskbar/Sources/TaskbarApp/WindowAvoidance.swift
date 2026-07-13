import ApplicationServices
import CoreGraphics
import Foundation

private let minimumClampedWindowHeight: CGFloat = 120

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

final class WindowAvoider {
    private var hasLoggedMissingPermission = false
    private var accessibilityTrustState = AccessibilityTrustState()

    func keepWindowsAboveTaskbars(
        records: [WindowRecord],
        screens: [ScreenInfo],
        settings: TaskbarSettings,
        currentPID: pid_t
    ) {
        guard accessibilityTrustState.isTrusted() else {
            if !hasLoggedMissingPermission {
                hasLoggedMissingPermission = true
                log("window avoidance needs Accessibility permission before it can resize other apps")
            }
            return
        }

        let screensByID = Dictionary(uniqueKeysWithValues: screens.map { ($0.id, $0) })
        var adjustedWindowIDs = Set<Int>()

        for record in records {
            guard record.pid != currentPID else { continue }
            guard record.layer == 0, record.isOnScreen else { continue }
            guard let screenID = record.screenID, let screen = screensByID[screenID] else { continue }

            let values = settings.values(for: screenID)
            guard values.isVisible, values.avoidOverlappingWindows, !values.autoHide else { continue }
            guard let clamped = clampedWindowFrame(record.bounds, screen: screen, reservedBottomHeight: values.taskbarHeight) else { continue }
            guard !adjustedWindowIDs.contains(record.windowID) else { continue }

            if clampAccessibilityWindow(pid: record.pid, matching: record.bounds, to: clamped) {
                adjustedWindowIDs.insert(record.windowID)
            }
        }
    }

    private func clampAccessibilityWindow(pid: pid_t, matching originalFrame: CGRect, to newFrame: CGRect) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement]
        else {
            return false
        }

        for window in windows {
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

import AppKit
import CoreGraphics
import Foundation

func currentPID() -> pid_t {
    ProcessInfo.processInfo.processIdentifier
}

func frontmostPID() -> pid_t? {
    NSWorkspace.shared.frontmostApplication?.processIdentifier
}

func activateApplication(pid: pid_t) -> Bool {
    guard let app = NSRunningApplication(processIdentifier: pid) else {
        return false
    }

    let options: NSApplication.ActivationOptions = [
        .activateIgnoringOtherApps,
        .activateAllWindows
    ]
    return app.activate(options: options)
}

func forceQuitApplication(pid: pid_t) -> Bool {
    guard let app = NSRunningApplication(processIdentifier: pid) else {
        return false
    }
    return app.forceTerminate()
}

func launchApplication(appPath: String, bundleID: String) -> Bool {
    let workspace = NSWorkspace.shared

    if !appPath.isEmpty {
        let url = URL(fileURLWithPath: appPath)
        workspace.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        return true
    }

    guard !bundleID.isEmpty,
          let url = workspace.urlForApplication(withBundleIdentifier: bundleID)
    else {
        return false
    }

    workspace.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    return true
}

func collectWindowRecords(screens: [ScreenInfo]) -> [WindowRecord] {
    let options: CGWindowListOption = [
        .optionOnScreenOnly,
        .excludeDesktopElements
    ]
    guard let rawWindows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
        return []
    }

    let windowPIDs = Set(rawWindows.map {
        pid_t(($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0)
    })
    let accessibilitySignatures = collectAccessibilitySignatures(for: windowPIDs)

    return rawWindows.map { window in
        let pid = pid_t((window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0)
        let app = NSRunningApplication(processIdentifier: pid)
        let bounds = rect(from: window[kCGWindowBounds as String] as? [String: Any])
        let title = window[kCGWindowName as String] as? String ?? ""

        return WindowRecord(
            owner: window[kCGWindowOwnerName as String] as? String ?? "",
            title: title,
            pid: pid,
            windowID: (window[kCGWindowNumber as String] as? NSNumber)?.intValue ?? 0,
            layer: (window[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
            isOnScreen: (window[kCGWindowIsOnscreen as String] as? Bool) ?? true,
            bounds: bounds,
            screenID: screenIDForWindow(bounds: bounds, screens: screens),
            bundleID: app?.bundleIdentifier ?? "",
            appPath: app?.bundleURL?.path ?? "",
            accessibilitySignature: accessibilitySignatures[AccessibilityWindowKey(pid: pid, title: title, bounds: bounds)] ?? ""
        )
    }
}

private struct AccessibilityWindowKey: Hashable {
    let pid: pid_t
    let title: String
    let x: Int
    let y: Int
    let width: Int
    let height: Int

    init(pid: pid_t, title: String, bounds: CGRect) {
        self.pid = pid
        self.title = title
        self.x = Int(bounds.origin.x.rounded())
        self.y = Int(bounds.origin.y.rounded())
        self.width = Int(bounds.width.rounded())
        self.height = Int(bounds.height.rounded())
    }
}

private func collectAccessibilitySignatures(for pids: Set<pid_t>) -> [AccessibilityWindowKey: String] {
    guard AXIsProcessTrusted() else { return [:] }

    var signatures: [AccessibilityWindowKey: String] = [:]
    for app in NSWorkspace.shared.runningApplications where pids.contains(app.processIdentifier) {
        let pid = app.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement]
        else {
            continue
        }

        for window in windows {
            let title = accessibilityString(window, kAXTitleAttribute)
            guard let bounds = accessibilityBounds(window) else { continue }
            let signature = accessibilityChildSignature(window)
            guard !signature.isEmpty else { continue }
            signatures[AccessibilityWindowKey(pid: pid, title: title, bounds: bounds)] = signature
        }
    }

    return signatures
}

private func accessibilityBounds(_ element: AXUIElement) -> CGRect? {
    var positionRef: CFTypeRef?
    var sizeRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
          AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
          let positionRef,
          let sizeRef,
          CFGetTypeID(positionRef) == AXValueGetTypeID(),
          CFGetTypeID(sizeRef) == AXValueGetTypeID()
    else {
        return nil
    }

    var point = CGPoint.zero
    var size = CGSize.zero
    AXValueGetValue(positionRef as! AXValue, .cgPoint, &point)
    AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
    return CGRect(origin: point, size: size)
}

private func accessibilityChildSignature(_ element: AXUIElement) -> String {
    var childrenRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
          let children = childrenRef as? [AXUIElement],
          !children.isEmpty
    else {
        return ""
    }

    return children
        .map { String(describing: $0) }
        .sorted()
        .joined(separator: "|")
}

private func accessibilityString(_ element: AXUIElement, _ attribute: String) -> String {
    var valueRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &valueRef) == .success else {
        return ""
    }
    return valueRef as? String ?? ""
}

private func rect(from dictionary: [String: Any]?) -> CGRect {
    guard let dictionary else { return .zero }

    return CGRect(
        x: number(dictionary["X"]),
        y: number(dictionary["Y"]),
        width: number(dictionary["Width"]),
        height: number(dictionary["Height"])
    )
}

private func number(_ value: Any?) -> CGFloat {
    if let number = value as? NSNumber {
        return CGFloat(truncating: number)
    }
    return 0
}

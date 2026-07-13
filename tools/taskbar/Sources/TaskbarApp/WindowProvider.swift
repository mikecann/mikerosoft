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

    return rawWindows.map { window in
        let pid = pid_t((window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0)
        let app = NSRunningApplication(processIdentifier: pid)
        let bounds = rect(from: window[kCGWindowBounds as String] as? [String: Any])

        return WindowRecord(
            owner: window[kCGWindowOwnerName as String] as? String ?? "",
            title: window[kCGWindowName as String] as? String ?? "",
            pid: pid,
            windowID: (window[kCGWindowNumber as String] as? NSNumber)?.intValue ?? 0,
            layer: (window[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
            isOnScreen: (window[kCGWindowIsOnscreen as String] as? Bool) ?? true,
            bounds: bounds,
            screenID: screenIDForWindow(bounds: bounds, screens: screens),
            bundleID: app?.bundleIdentifier ?? "",
            appPath: app?.bundleURL?.path ?? ""
        )
    }
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

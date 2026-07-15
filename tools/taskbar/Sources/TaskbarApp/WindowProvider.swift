import AppKit
import CoreGraphics
import Foundation

func currentPID() -> pid_t {
    ProcessInfo.processInfo.processIdentifier
}

func frontmostPID() -> pid_t? {
    NSWorkspace.shared.frontmostApplication?.processIdentifier
}

func activateApplication(pid: pid_t, activateAllWindows: Bool = false) -> Bool {
    guard let app = NSRunningApplication(processIdentifier: pid) else {
        return false
    }

    var options: NSApplication.ActivationOptions = [.activateIgnoringOtherApps]
    if activateAllWindows {
        options.insert(.activateAllWindows)
    }
    return app.activate(options: options)
}

func activateApplicationWindow(item: TaskbarItem) -> Bool {
    guard let pid = item.pid else { return false }
    let appActivated = activateApplication(pid: pid)
    guard AXIsProcessTrusted() else { return appActivated }

    let axApp = AXUIElementCreateApplication(pid)
    setTaskbarAccessibilityMessagingTimeout(axApp)
    guard let target = matchingApplicationWindow(
        axApp: axApp,
        title: item.title,
        bounds: item.windowBounds,
        accessibilitySignature: item.accessibilitySignature
    ) else {
        return appActivated
    }

    let raised = AXUIElementPerformAction(target, kAXRaiseAction as CFString) == .success
    let madeMain = AXUIElementSetAttributeValue(axApp, kAXMainWindowAttribute as CFString, target) == .success
    let focusedWindow = AXUIElementSetAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, target) == .success
    let focused = AXUIElementSetAttributeValue(target, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
    return appActivated || raised || madeMain || focusedWindow || focused
}

func activateApplicationWindowAsync(item: TaskbarItem) {
    performAccessibilityWindowAction("activate window pid=\(item.pid.map(String.init) ?? "not-running")") {
        _ = activateApplicationWindow(item: item)
    }
}

func unminimizeApplicationWindow(pid: pid_t, title: String) -> Bool {
    guard AXIsProcessTrusted() else { return false }

    let axApp = AXUIElementCreateApplication(pid)
    setTaskbarAccessibilityMessagingTimeout(axApp)
    var windowsRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
          let windows = windowsRef as? [AXUIElement]
    else {
        return false
    }

    let minimizedWindows = windows.filter { window in
        setTaskbarAccessibilityMessagingTimeout(window)
        return accessibilityBool(window, "AXMinimized")
    }
    guard let target = minimizedWindows.first(where: { accessibilityString($0, kAXTitleAttribute) == title })
        ?? minimizedWindows.first
    else {
        return false
    }

    return AXUIElementSetAttributeValue(target, "AXMinimized" as CFString, kCFBooleanFalse) == .success
}

func unminimizeApplicationWindowAsync(pid: pid_t, title: String) {
    performAccessibilityWindowAction("unminimize AX pid=\(pid)") {
        _ = unminimizeApplicationWindow(pid: pid, title: title)
    }
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

func collectWindowRecords(screens: [ScreenInfo], includeMinimized: Bool = false) -> [WindowRecord] {
    let options: CGWindowListOption = [
        .optionOnScreenOnly,
        .excludeDesktopElements
    ]
    guard let rawWindows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
        return []
    }

    let rawWindowPIDs = Set(rawWindows.map { window in
        pid_t((window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0)
    })
    let appMetadata = RunningApplicationMetadataSampler.shared.metadata(for: rawWindowPIDs)
    let accessibilitySurfaces = AccessibilitySurfaceSampler.shared.surfaces(for: rawWindowPIDs)

    let matchRequests = rawWindows.map { window in
        AccessibilityWindowMatchRequest(
            pid: pid_t((window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0),
            cgTitle: window[kCGWindowName as String] as? String ?? "",
            bounds: rect(from: window[kCGWindowBounds as String] as? [String: Any])
        )
    }
    let matchedAccessibilitySurfaces = matchingAccessibilitySurfaces(
        requests: matchRequests,
        in: accessibilitySurfaces
    )

    let cgRecords = zip(rawWindows, matchedAccessibilitySurfaces).map { window, accessibilitySurface in
        let pid = pid_t((window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0)
        let bounds = rect(from: window[kCGWindowBounds as String] as? [String: Any])
        let owner = window[kCGWindowOwnerName as String] as? String ?? ""
        let cgTitle = window[kCGWindowName as String] as? String ?? ""
        let title = resolvedWindowTitle(
            cgTitle: cgTitle,
            owner: owner,
            accessibilityTitle: accessibilitySurface?.title ?? ""
        )
        let metadata = appMetadata[pid]

        return WindowRecord(
            owner: owner,
            title: title,
            pid: pid,
            windowID: (window[kCGWindowNumber as String] as? NSNumber)?.intValue ?? 0,
            layer: (window[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
            isOnScreen: (window[kCGWindowIsOnscreen as String] as? Bool) ?? true,
            isMinimized: false,
            bounds: bounds,
            screenID: screenIDForWindow(bounds: bounds, screens: screens),
            bundleID: metadata?.bundleID ?? "",
            appPath: metadata?.appPath ?? "",
            accessibilityTitle: accessibilitySurface?.title ?? "",
            accessibilitySignature: accessibilitySurface?.signature ?? ""
        )
    }

    guard includeMinimized else {
        return cgRecords
    }

    let cgKeys = Set(cgRecords.map { AccessibilityWindowKey(pid: $0.pid, title: $0.title, bounds: $0.bounds) })
    return cgRecords + MinimizedWindowSampler.shared.records(screens: screens, excluding: cgKeys)
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

struct AccessibilityWindowSurface: Equatable {
    let pid: pid_t
    let title: String
    let bounds: CGRect
    let signature: String
}

struct AccessibilityWindowMatchRequest: Equatable {
    let pid: pid_t
    let cgTitle: String
    let bounds: CGRect
}

func resolvedWindowTitle(cgTitle: String, owner: String, accessibilityTitle: String) -> String {
    let title = cgTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    let owner = owner.trimmingCharacters(in: .whitespacesAndNewlines)
    let accessibilityTitle = accessibilityTitle.trimmingCharacters(in: .whitespacesAndNewlines)

    if !accessibilityTitle.isEmpty, title.isEmpty || title.caseInsensitiveCompare(owner) == .orderedSame {
        return accessibilityTitle
    }
    if !title.isEmpty {
        return title
    }
    return accessibilityTitle.isEmpty ? owner : accessibilityTitle
}

func matchingAccessibilitySurface(
    pid: pid_t,
    cgTitle: String,
    bounds: CGRect,
    in surfaces: [AccessibilityWindowSurface]
) -> AccessibilityWindowSurface? {
    matchingAccessibilitySurfaces(
        requests: [AccessibilityWindowMatchRequest(pid: pid, cgTitle: cgTitle, bounds: bounds)],
        in: surfaces
    ).first ?? nil
}

func matchingAccessibilitySurfaces(
    requests: [AccessibilityWindowMatchRequest],
    in surfaces: [AccessibilityWindowSurface]
) -> [AccessibilityWindowSurface?] {
    var consumedSurfaceIndexes = Set<Int>()

    return requests.map { request in
        guard let matchIndex = matchingAccessibilitySurfaceIndex(
            request: request,
            in: surfaces,
            consumedSurfaceIndexes: consumedSurfaceIndexes
        ) else {
            return nil
        }

        consumedSurfaceIndexes.insert(matchIndex)
        return surfaces[matchIndex]
    }
}

private func matchingAccessibilitySurfaceIndex(
    request: AccessibilityWindowMatchRequest,
    in surfaces: [AccessibilityWindowSurface],
    consumedSurfaceIndexes: Set<Int>
) -> Int? {
    let candidates = surfaces.indices.filter { index in
        guard !consumedSurfaceIndexes.contains(index) else { return false }
        let surface = surfaces[index]
        let requestKey = AccessibilityWindowKey(pid: request.pid, title: "", bounds: request.bounds)
        let surfaceKey = AccessibilityWindowKey(pid: surface.pid, title: "", bounds: surface.bounds)
        return requestKey == surfaceKey
    }
    guard !candidates.isEmpty else { return nil }

    let title = request.cgTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else {
        return candidates.first
    }

    let scoredCandidates = candidates.map { index -> (index: Int, score: Int) in
        (
            index: index,
            score: accessibilityTitleMatchScore(cgTitle: title, accessibilityTitle: surfaces[index].title)
        )
    }
        .filter { $0.score > 0 }

    if let match = scoredCandidates.max(by: { left, right in
        if left.score != right.score { return left.score < right.score }
        let leftTitleCount = surfaces[left.index].title.count
        let rightTitleCount = surfaces[right.index].title.count
        if leftTitleCount != rightTitleCount { return leftTitleCount > rightTitleCount }
        return left.index > right.index
    }) {
        return match.index
    }

    return candidates.count == 1 ? candidates.first : nil
}

private func accessibilityTitleMatchScore(cgTitle: String, accessibilityTitle: String) -> Int {
    let cgTitle = normalizedWindowTitle(cgTitle)
    let accessibilityTitle = normalizedWindowTitle(accessibilityTitle)
    guard !cgTitle.isEmpty, !accessibilityTitle.isEmpty else { return 0 }

    if accessibilityTitle == cgTitle {
        return 3
    }

    guard accessibilityTitle.hasPrefix(cgTitle) else {
        return 0
    }

    let suffix = accessibilityTitle.dropFirst(cgTitle.count).trimmingCharacters(in: .whitespacesAndNewlines)
    guard let first = suffix.first else {
        return 3
    }

    return ["-", "–", "|", ":"].contains(first) ? 2 : 0
}

private func normalizedWindowTitle(_ value: String) -> String {
    value
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .lowercased()
}

private func matchingApplicationWindow(
    axApp: AXUIElement,
    title: String,
    bounds: CGRect?,
    accessibilitySignature: String
) -> AXUIElement? {
    var windowsRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
          let windows = windowsRef as? [AXUIElement]
    else {
        return nil
    }

    let candidates = windows.compactMap { window -> (window: AXUIElement, score: Int)? in
        setTaskbarAccessibilityMessagingTimeout(window)
        let role = accessibilityString(window, kAXRoleAttribute)
        guard role.isEmpty || role == "AXWindow" else { return nil }

        let candidateTitle = accessibilityString(window, kAXTitleAttribute)
        let candidateBounds = accessibilityBounds(window)
        let candidateSignature = accessibilityChildSignature(window)
        let score = applicationWindowMatchScore(
            itemTitle: title,
            itemBounds: bounds,
            itemAccessibilitySignature: accessibilitySignature,
            candidateTitle: candidateTitle,
            candidateBounds: candidateBounds,
            candidateAccessibilitySignature: candidateSignature
        )
        guard score > 0 else { return nil }
        return (window, score)
    }

    return candidates.max { left, right in
        left.score < right.score
    }?.window
}

func applicationWindowMatchScore(
    itemTitle: String,
    itemBounds: CGRect?,
    itemAccessibilitySignature: String,
    candidateTitle: String,
    candidateBounds: CGRect?,
    candidateAccessibilitySignature: String
) -> Int {
    var score = accessibilityTitleMatchScore(cgTitle: itemTitle, accessibilityTitle: candidateTitle)
    if score == 0 {
        score = accessibilityTitleMatchScore(cgTitle: candidateTitle, accessibilityTitle: itemTitle)
    }

    let itemSignature = itemAccessibilitySignature.trimmingCharacters(in: .whitespacesAndNewlines)
    let candidateSignature = candidateAccessibilitySignature.trimmingCharacters(in: .whitespacesAndNewlines)
    if !itemSignature.isEmpty, itemSignature == candidateSignature {
        score += 10
    }

    if let itemBounds,
       let candidateBounds,
       AccessibilityWindowKey(pid: 0, title: "", bounds: itemBounds)
        == AccessibilityWindowKey(pid: 0, title: "", bounds: candidateBounds) {
        score += 4
    }

    return score
}

private struct RunningApplicationMetadata {
    let bundleID: String
    let appPath: String
}

private final class RunningApplicationMetadataSampler {
    static let shared = RunningApplicationMetadataSampler()

    private let lock = NSLock()
    private var cachedMetadata: [pid_t: RunningApplicationMetadata] = [:]
    private var lastRefresh = Date.distantPast
    private var isRefreshing = false

    func metadata(for pids: Set<pid_t>, now: Date = Date()) -> [pid_t: RunningApplicationMetadata] {
        lock.lock()
        let cached = cachedMetadata.filter { pids.contains($0.key) }
        let shouldRefresh = now.timeIntervalSince(lastRefresh) >= 2.0 && !isRefreshing
        if shouldRefresh {
            isRefreshing = true
            lastRefresh = now
        }
        lock.unlock()

        if shouldRefresh {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else { return }
                let metadata = collectRunningApplicationMetadata(for: pids)
                self.lock.lock()
                self.cachedMetadata = metadata
                self.isRefreshing = false
                self.lock.unlock()
            }
        }

        return cached
    }
}

private func collectRunningApplicationMetadata(for pids: Set<pid_t>) -> [pid_t: RunningApplicationMetadata] {
    NSWorkspace.shared.runningApplications
        .filter { pids.contains($0.processIdentifier) }
        .reduce(into: [pid_t: RunningApplicationMetadata]()) { result, app in
            result[app.processIdentifier] = RunningApplicationMetadata(
                bundleID: app.bundleIdentifier ?? "",
                appPath: app.bundleURL?.path ?? ""
            )
        }
}

private final class AccessibilitySurfaceSampler {
    static let shared = AccessibilitySurfaceSampler()

    private let lock = NSLock()
    private var cachedSurfaces: [AccessibilityWindowSurface] = []
    private var lastRefresh = Date.distantPast
    private var isRefreshing = false

    func surfaces(for pids: Set<pid_t>, now: Date = Date()) -> [AccessibilityWindowSurface] {
        lock.lock()
        let cached = cachedSurfaces.filter { pids.contains($0.pid) }
        let shouldRefresh = now.timeIntervalSince(lastRefresh) >= 2.0 && !isRefreshing
        if shouldRefresh {
            isRefreshing = true
            lastRefresh = now
        }
        lock.unlock()

        if shouldRefresh {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else { return }
                let surfaces = collectAccessibilitySurfaces(for: pids)
                self.lock.lock()
                self.cachedSurfaces = surfaces
                self.isRefreshing = false
                self.lock.unlock()
            }
        }

        return cached
    }
}

private func collectAccessibilitySurfaces(for pids: Set<pid_t>) -> [AccessibilityWindowSurface] {
    guard AXIsProcessTrusted() else { return [] }

    var surfaces: [AccessibilityWindowSurface] = []
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
            let role = accessibilityString(window, kAXRoleAttribute)
            guard role.isEmpty || role == "AXWindow" else { continue }
            let signature = accessibilityChildSignature(window)
            surfaces.append(
                AccessibilityWindowSurface(
                    pid: pid,
                    title: title,
                    bounds: bounds,
                    signature: signature
                )
            )
        }
    }

    return surfaces
}

private final class MinimizedWindowSampler {
    static let shared = MinimizedWindowSampler()

    private let lock = NSLock()
    private var cachedRecords: [WindowRecord] = []
    private var lastRefresh = Date.distantPast
    private var isRefreshing = false

    func records(screens: [ScreenInfo], excluding visibleKeys: Set<AccessibilityWindowKey>, now: Date = Date()) -> [WindowRecord] {
        lock.lock()
        let cached = cachedRecords.filter { record in
            !visibleKeys.contains(AccessibilityWindowKey(pid: record.pid, title: record.title, bounds: record.bounds))
        }
        let shouldRefresh = now.timeIntervalSince(lastRefresh) >= 2.0 && !isRefreshing
        if shouldRefresh {
            isRefreshing = true
            lastRefresh = now
        }
        lock.unlock()

        if shouldRefresh {
            let screens = screens
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else { return }
                let records = collectMinimizedWindowRecords(screens: screens)
                self.lock.lock()
                self.cachedRecords = records
                self.isRefreshing = false
                self.lock.unlock()
            }
        }

        return cached
    }
}

private func collectMinimizedWindowRecords(screens: [ScreenInfo]) -> [WindowRecord] {
    guard AXIsProcessTrusted() else { return [] }

    let runningApps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
    let fallbackScreenID = screens.first?.id
    var records: [WindowRecord] = []

    for app in runningApps {
        let pid = app.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement]
        else {
            continue
        }

        for window in windows {
            guard accessibilityBool(window, "AXMinimized") else { continue }
            let role = accessibilityString(window, kAXRoleAttribute)
            guard role.isEmpty || role == "AXWindow" else { continue }

            let title = accessibilityString(window, kAXTitleAttribute)
            guard let bounds = accessibilityBounds(window) else { continue }
            records.append(
                WindowRecord(
                    owner: app.localizedName ?? app.bundleURL?.deletingPathExtension().lastPathComponent ?? "",
                    title: title,
                    pid: pid,
                    windowID: syntheticWindowID(pid: pid, title: title, bounds: bounds),
                    layer: 0,
                    isOnScreen: false,
                    isMinimized: true,
                    bounds: bounds,
                    screenID: screenIDForWindow(bounds: bounds, screens: screens) ?? fallbackScreenID,
                    bundleID: app.bundleIdentifier ?? "",
                    appPath: app.bundleURL?.path ?? "",
                    accessibilityTitle: title,
                    accessibilitySignature: ""
                )
            )
        }
    }

    return records
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

private func accessibilityBool(_ element: AXUIElement, _ attribute: String) -> Bool {
    var valueRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &valueRef) == .success else {
        return false
    }
    return valueRef as? Bool ?? false
}

private func syntheticWindowID(pid: pid_t, title: String, bounds: CGRect) -> Int {
    var hash = Int(pid)
    for scalar in title.unicodeScalars {
        hash = hash &* 31 &+ Int(scalar.value)
    }
    hash = hash &* 31 &+ Int(bounds.origin.x.rounded())
    hash = hash &* 31 &+ Int(bounds.origin.y.rounded())
    hash = hash &* 31 &+ Int(bounds.width.rounded())
    hash = hash &* 31 &+ Int(bounds.height.rounded())
    return -abs(hash == Int.min ? Int.max : hash)
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

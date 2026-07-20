import AppKit
import CoreGraphics
import Darwin
import Foundation

private typealias AXGetWindowFunction = @convention(c) (
    AXUIElement,
    UnsafeMutablePointer<CGWindowID>
) -> AXError

private let axGetWindow: AXGetWindowFunction? = {
    guard let handle = dlopen(nil, RTLD_NOW),
          let symbol = dlsym(handle, "_AXUIElementGetWindow")
    else {
        return nil
    }

    return unsafeBitCast(symbol, to: AXGetWindowFunction.self)
}()

private func accessibilityWindowID(_ element: AXUIElement) -> Int {
    guard let axGetWindow else { return 0 }

    var windowID = CGWindowID(0)
    guard axGetWindow(element, &windowID) == .success else { return 0 }
    return Int(windowID)
}

func resolvedAccessibilitySignature(
    windowIDBridgeAvailable: Bool,
    fallback: () -> String
) -> String {
    guard !windowIDBridgeAvailable else { return "" }
    return fallback()
}

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
        windowIDs: item.windowIDs,
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

func minimizeApplicationWindow(item: TaskbarItem) -> Bool {
    guard let pid = item.pid, AXIsProcessTrusted() else { return false }

    let axApp = AXUIElementCreateApplication(pid)
    setTaskbarAccessibilityMessagingTimeout(axApp)
    guard let target = matchingApplicationWindow(
        axApp: axApp,
        windowIDs: item.windowIDs,
        title: item.title,
        bounds: item.windowBounds,
        accessibilitySignature: item.accessibilitySignature
    ) else {
        return false
    }

    return AXUIElementSetAttributeValue(
        target,
        kAXMinimizedAttribute as CFString,
        kCFBooleanTrue
    ) == .success
}

func minimizeApplicationWindowAsync(item: TaskbarItem) {
    let pidText = item.pid.map(String.init) ?? "not-running"
    performAccessibilityWindowAction("minimize window pid=\(pidText)") {
        guard minimizeApplicationWindow(item: item), let pid = item.pid else { return }
        for windowID in item.windowIDs {
            MinimizedWindowSampler.shared.invalidate(pid: pid, windowID: windowID)
        }
    }
}

func unminimizeApplicationWindowAndReturnID(pid: pid_t, title: String) -> Int? {
    guard AXIsProcessTrusted() else { return nil }

    let axApp = AXUIElementCreateApplication(pid)
    setTaskbarAccessibilityMessagingTimeout(axApp)
    var windowsRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
          let windows = windowsRef as? [AXUIElement]
    else {
        return nil
    }

    let minimizedWindows = windows.filter { window in
        setTaskbarAccessibilityMessagingTimeout(window)
        return accessibilityBool(window, "AXMinimized")
    }
    guard let target = minimizedWindows.first(where: { accessibilityString($0, kAXTitleAttribute) == title })
        ?? minimizedWindows.first
    else {
        return nil
    }

    let targetTitle = accessibilityString(target, kAXTitleAttribute)
    let targetBounds = accessibilityBounds(target)
    let windowID = resolvedMinimizedWindowID(accessibilityWindowID(target)) {
        guard let targetBounds else { return 0 }
        return syntheticWindowID(pid: pid, title: targetTitle, bounds: targetBounds)
    }
    guard AXUIElementSetAttributeValue(target, "AXMinimized" as CFString, kCFBooleanFalse) == .success else {
        return nil
    }
    return windowID
}

func unminimizeApplicationWindowAsync(pid: pid_t, title: String) {
    performAccessibilityWindowAction("unminimize AX pid=\(pid)") {
        guard let windowID = unminimizeApplicationWindowAndReturnID(pid: pid, title: title) else { return }
        MinimizedWindowSampler.shared.invalidate(pid: pid, windowID: windowID)
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
            windowID: (window[kCGWindowNumber as String] as? NSNumber)?.intValue ?? 0,
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
        let windowID = (window[kCGWindowNumber as String] as? NSNumber)?.intValue ?? 0
        let matchedAccessibilityWindowID = accessibilitySurface?.windowID ?? 0
        let accessibilityWindowID = windowID > 0 && matchedAccessibilityWindowID == windowID
            ? matchedAccessibilityWindowID
            : 0
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
            windowID: windowID,
            accessibilityWindowID: accessibilityWindowID,
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
    let cgWindowIDs = Set(cgRecords.lazy.map(\.windowID).filter { $0 > 0 })
    return cgRecords + MinimizedWindowSampler.shared.records(
        screens: screens,
        excluding: cgKeys,
        visibleWindowIDs: cgWindowIDs
    )
}

struct AccessibilityWindowKey: Hashable {
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
    let windowID: Int
    let title: String
    let bounds: CGRect
    let signature: String

    init(pid: pid_t, windowID: Int = 0, title: String, bounds: CGRect, signature: String) {
        self.pid = pid
        self.windowID = windowID
        self.title = title
        self.bounds = bounds
        self.signature = signature
    }
}

struct AccessibilityWindowMatchRequest: Equatable {
    let pid: pid_t
    let windowID: Int
    let cgTitle: String
    let bounds: CGRect

    init(pid: pid_t, windowID: Int = 0, cgTitle: String, bounds: CGRect) {
        self.pid = pid
        self.windowID = windowID
        self.cgTitle = cgTitle
        self.bounds = bounds
    }
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
    windowID: Int = 0,
    cgTitle: String,
    bounds: CGRect,
    in surfaces: [AccessibilityWindowSurface]
) -> AccessibilityWindowSurface? {
    matchingAccessibilitySurfaces(
        requests: [AccessibilityWindowMatchRequest(pid: pid, windowID: windowID, cgTitle: cgTitle, bounds: bounds)],
        in: surfaces
    ).first ?? nil
}

func matchingAccessibilitySurfaces(
    requests: [AccessibilityWindowMatchRequest],
    in surfaces: [AccessibilityWindowSurface]
) -> [AccessibilityWindowSurface?] {
    var consumedSurfaceIndexes = Set<Int>()
    var matches = Array<AccessibilityWindowSurface?>(repeating: nil, count: requests.count)

    for requestIndex in requests.indices {
        let request = requests[requestIndex]
        guard request.windowID > 0,
              let matchIndex = surfaces.indices.first(where: { index in
                  !consumedSurfaceIndexes.contains(index)
                      && surfaces[index].windowID == request.windowID
              })
        else {
            continue
        }

        consumedSurfaceIndexes.insert(matchIndex)
        matches[requestIndex] = surfaces[matchIndex]
    }

    for requestIndex in requests.indices where matches[requestIndex] == nil {
        let request = requests[requestIndex]
        guard let matchIndex = matchingAccessibilitySurfaceIndex(
            request: request,
            in: surfaces,
            consumedSurfaceIndexes: consumedSurfaceIndexes
        ) else {
            continue
        }

        consumedSurfaceIndexes.insert(matchIndex)
        matches[requestIndex] = surfaces[matchIndex]
    }

    return matches
}

private func matchingAccessibilitySurfaceIndex(
    request: AccessibilityWindowMatchRequest,
    in surfaces: [AccessibilityWindowSurface],
    consumedSurfaceIndexes: Set<Int>
) -> Int? {
    let candidates = surfaces.indices.filter { index in
        guard !consumedSurfaceIndexes.contains(index) else { return false }
        let surface = surfaces[index]
        guard !(request.windowID > 0 && surface.windowID > 0 && request.windowID != surface.windowID) else {
            return false
        }
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
    windowIDs: [Int],
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

    let eligibleWindows = windows.filter { window in
        setTaskbarAccessibilityMessagingTimeout(window)
        let role = accessibilityString(window, kAXRoleAttribute)
        return role.isEmpty || role == "AXWindow"
    }
    let candidateWindowIDs = eligibleWindows.map(accessibilityWindowID)

    if let matchIndex = exactApplicationWindowMatchIndex(
        itemWindowIDs: windowIDs,
        candidateWindowIDs: candidateWindowIDs
    ) {
        return eligibleWindows[matchIndex]
    }

    let scoredCandidates = zip(eligibleWindows, candidateWindowIDs).compactMap {
        window, candidateWindowID -> (window: AXUIElement, score: Int)? in
        guard canHeuristicallyMatchApplicationWindow(
            itemWindowIDs: windowIDs,
            candidateWindowID: candidateWindowID
        ) else {
            return nil
        }
        let candidateTitle = accessibilityString(window, kAXTitleAttribute)
        let candidateBounds = accessibilityBounds(window)
        let candidateSignature = resolvedAccessibilitySignature(windowIDBridgeAvailable: axGetWindow != nil) {
            accessibilityChildSignature(window)
        }
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

    return scoredCandidates.max { left, right in
        left.score < right.score
    }?.window
}

func exactApplicationWindowMatchIndex(itemWindowIDs: [Int], candidateWindowIDs: [Int]) -> Int? {
    let knownItemWindowIDs = Set(itemWindowIDs.filter { $0 > 0 })
    guard !knownItemWindowIDs.isEmpty else { return nil }
    return candidateWindowIDs.firstIndex(where: knownItemWindowIDs.contains)
}

func canHeuristicallyMatchApplicationWindow(itemWindowIDs: [Int], candidateWindowID: Int) -> Bool {
    let knownItemWindowIDs = Set(itemWindowIDs.filter { $0 > 0 })
    guard !knownItemWindowIDs.isEmpty, candidateWindowID > 0 else { return true }
    return knownItemWindowIDs.contains(candidateWindowID)
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

struct RunningApplicationMetadata {
    let bundleID: String
    let appPath: String
}

final class RunningApplicationMetadataSampler {
    static let shared = RunningApplicationMetadataSampler()

    private let collect: (Set<pid_t>) -> [pid_t: RunningApplicationMetadata]
    private let schedule: (@escaping () -> Void) -> Void
    private let lock = NSLock()
    private var cachedMetadata: [pid_t: RunningApplicationMetadata] = [:]
    private var attemptedPIDs = Set<pid_t>()
    private var lastRefresh = Date.distantPast
    private var isRefreshing = false
    private var hasLoadedInitialSnapshot = false
    private var pendingRefreshPIDs = Set<pid_t>()

    init(
        collect: @escaping (Set<pid_t>) -> [pid_t: RunningApplicationMetadata] = collectRunningApplicationMetadata,
        schedule: @escaping (@escaping () -> Void) -> Void = { work in
            DispatchQueue.global(qos: .utility).async(execute: work)
        }
    ) {
        self.collect = collect
        self.schedule = schedule
    }

    func metadata(for pids: Set<pid_t>, now: Date = Date()) -> [pid_t: RunningApplicationMetadata] {
        lock.lock()
        let cached = cachedMetadata.filter { pids.contains($0.key) }
        let containsUnknownPID = !pids.isSubset(of: attemptedPIDs)
        if containsUnknownPID, isRefreshing {
            pendingRefreshPIDs.formUnion(pids)
        }
        let shouldLoadSynchronously = (!hasLoadedInitialSnapshot || containsUnknownPID) && !isRefreshing
        let shouldRefresh = !shouldLoadSynchronously
            && hasLoadedInitialSnapshot
            && now.timeIntervalSince(lastRefresh) >= 2.0
            && !isRefreshing
        if shouldLoadSynchronously || shouldRefresh {
            isRefreshing = true
            lastRefresh = now
        }
        lock.unlock()

        if shouldLoadSynchronously {
            let metadata = collect(pids)
            lock.lock()
            cachedMetadata = metadata
            attemptedPIDs = pids
            hasLoadedInitialSnapshot = true
            let pendingPIDs = pendingRefreshPIDs
            pendingRefreshPIDs.removeAll()
            attemptedPIDs.formUnion(pendingPIDs)
            isRefreshing = !pendingPIDs.isEmpty
            lock.unlock()
            if !pendingPIDs.isEmpty {
                refreshInBackground(for: pendingPIDs)
            }
            return metadata.filter { pids.contains($0.key) }
        }

        if shouldRefresh {
            refreshInBackground(for: pids)
        }

        return cached
    }

    private func refreshInBackground(for pids: Set<pid_t>) {
        schedule { [weak self] in
            guard let self else { return }
            let metadata = self.collect(pids)
            self.lock.lock()
            self.cachedMetadata = metadata
            self.attemptedPIDs = pids
            let pendingPIDs = self.pendingRefreshPIDs
            self.pendingRefreshPIDs.removeAll()
            self.attemptedPIDs.formUnion(pendingPIDs)
            self.isRefreshing = !pendingPIDs.isEmpty
            self.lock.unlock()
            if !pendingPIDs.isEmpty {
                self.refreshInBackground(for: pendingPIDs)
            }
        }
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

final class AccessibilitySurfaceSampler {
    static let shared = AccessibilitySurfaceSampler()

    private let collect: (Set<pid_t>) -> [AccessibilityWindowSurface]
    private let lock = NSLock()
    private var cachedSurfaces: [AccessibilityWindowSurface] = []
    private var lastRefresh = Date.distantPast
    private var isRefreshing = false
    private var hasLoadedInitialSnapshot = false

    init(
        collect: @escaping (Set<pid_t>) -> [AccessibilityWindowSurface] = collectAccessibilitySurfaces
    ) {
        self.collect = collect
    }

    func surfaces(for pids: Set<pid_t>, now: Date = Date()) -> [AccessibilityWindowSurface] {
        lock.lock()
        let cached = cachedSurfaces.filter { pids.contains($0.pid) }
        let shouldLoadSynchronously = !hasLoadedInitialSnapshot && !isRefreshing
        let shouldRefresh = hasLoadedInitialSnapshot
            && now.timeIntervalSince(lastRefresh) >= 2.0
            && !isRefreshing
        if shouldLoadSynchronously || shouldRefresh {
            isRefreshing = true
            lastRefresh = now
        }
        lock.unlock()

        if shouldLoadSynchronously {
            let surfaces = collect(pids)
            lock.lock()
            cachedSurfaces = surfaces
            hasLoadedInitialSnapshot = true
            isRefreshing = false
            lock.unlock()
            return surfaces.filter { pids.contains($0.pid) }
        }

        if shouldRefresh {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else { return }
                let surfaces = self.collect(pids)
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
            let windowID = accessibilityWindowID(window)
            let signature = resolvedAccessibilitySignature(windowIDBridgeAvailable: axGetWindow != nil) {
                accessibilityChildSignature(window)
            }
            surfaces.append(
                AccessibilityWindowSurface(
                    pid: pid,
                    windowID: windowID,
                    title: title,
                    bounds: bounds,
                    signature: signature
                )
            )
        }
    }

    return surfaces
}

final class MinimizedWindowSampler {
    static let shared = MinimizedWindowSampler()

    private let collect: ([ScreenInfo]) -> [WindowRecord]
    private let schedule: (@escaping () -> Void) -> Void
    private let lock = NSLock()
    private var cachedRecords: [WindowRecord] = []
    private var lastRefresh = Date.distantPast
    private var isRefreshing = false
    private var hasLoadedInitialSnapshot = false
    private var cacheGeneration = 0

    init(
        collect: @escaping ([ScreenInfo]) -> [WindowRecord] = collectMinimizedWindowRecords,
        schedule: @escaping (@escaping () -> Void) -> Void = { work in
            DispatchQueue.global(qos: .utility).async(execute: work)
        }
    ) {
        self.collect = collect
        self.schedule = schedule
    }

    func invalidate(pid: pid_t, windowID: Int) {
        lock.lock()
        cacheGeneration += 1
        if windowID != 0 {
            cachedRecords.removeAll { record in
                record.pid == pid && record.windowID == windowID
            }
        }
        lock.unlock()
    }

    func records(
        screens: [ScreenInfo],
        excluding visibleKeys: Set<AccessibilityWindowKey>,
        visibleWindowIDs: Set<Int>,
        now: Date = Date()
    ) -> [WindowRecord] {
        lock.lock()
        let cached = filteredMinimizedRecords(
            cachedRecords,
            excluding: visibleKeys,
            visibleWindowIDs: visibleWindowIDs
        )
        let shouldLoadSynchronously = !hasLoadedInitialSnapshot && !isRefreshing
        let shouldRefresh = hasLoadedInitialSnapshot
            && now.timeIntervalSince(lastRefresh) >= 2.0
            && !isRefreshing
        if shouldLoadSynchronously || shouldRefresh {
            isRefreshing = true
            lastRefresh = now
        }
        let refreshGeneration = cacheGeneration
        lock.unlock()

        if shouldLoadSynchronously {
            let records = collect(screens)
            lock.lock()
            let currentRecords: [WindowRecord]
            if cacheGeneration == refreshGeneration {
                cachedRecords = records
                currentRecords = records
            } else {
                currentRecords = cachedRecords
            }
            hasLoadedInitialSnapshot = true
            isRefreshing = false
            lock.unlock()
            return filteredMinimizedRecords(
                currentRecords,
                excluding: visibleKeys,
                visibleWindowIDs: visibleWindowIDs
            )
        }

        if shouldRefresh {
            let screens = screens
            schedule { [weak self] in
                guard let self else { return }
                let records = self.collect(screens)
                self.lock.lock()
                if self.cacheGeneration == refreshGeneration {
                    self.cachedRecords = records
                }
                self.isRefreshing = false
                self.lock.unlock()
            }
        }

        return cached
    }
}

private func filteredMinimizedRecords(
    _ records: [WindowRecord],
    excluding visibleKeys: Set<AccessibilityWindowKey>,
    visibleWindowIDs: Set<Int>
) -> [WindowRecord] {
    records.filter { record in
        !isStaleCachedMinimizedWindow(windowID: record.windowID, visibleWindowIDs: visibleWindowIDs)
            && !visibleKeys.contains(AccessibilityWindowKey(pid: record.pid, title: record.title, bounds: record.bounds))
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
            let resolvedAccessibilityWindowID = accessibilityWindowID(window)
            let windowID = resolvedMinimizedWindowID(resolvedAccessibilityWindowID) {
                syntheticWindowID(pid: pid, title: title, bounds: bounds)
            }
            records.append(
                WindowRecord(
                    owner: app.localizedName ?? app.bundleURL?.deletingPathExtension().lastPathComponent ?? "",
                    title: title,
                    pid: pid,
                    windowID: windowID,
                    accessibilityWindowID: resolvedAccessibilityWindowID,
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

func resolvedMinimizedWindowID(_ windowID: Int, fallback: () -> Int) -> Int {
    guard windowID > 0 else { return fallback() }
    return windowID
}

func isStaleCachedMinimizedWindow(windowID: Int, visibleWindowIDs: Set<Int>) -> Bool {
    windowID > 0 && visibleWindowIDs.contains(windowID)
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

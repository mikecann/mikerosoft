import CoreGraphics
import Foundation

let minimumWindowWidth: CGFloat = 64
let minimumWindowHeight: CGFloat = 40
private let maximumUntitledInternalSurfaceArea: CGFloat = 60_000
private let internalSurfaceSiblingAreaMultiplier: CGFloat = 8

let ignoredOwners: Set<String> = [
    "Control Center",
    "Dock",
    "Notification Center",
    "Spotlight",
    "SystemUIServer",
    "Window Server",
    "loginwindow"
]

struct WindowRecord: Equatable {
    let owner: String
    let title: String
    let pid: pid_t
    let windowID: Int
    let accessibilityWindowID: Int
    let layer: Int
    let isOnScreen: Bool
    let isMinimized: Bool
    let bounds: CGRect
    let screenID: UInt32?
    let bundleID: String
    let appPath: String
    let accessibilityTitle: String
    let accessibilitySignature: String
    // nil means Accessibility did not expose a fullscreen state for this window.
    let isFullscreen: Bool?

    init(
        owner: String,
        title: String,
        pid: pid_t,
        windowID: Int,
        accessibilityWindowID: Int,
        layer: Int,
        isOnScreen: Bool,
        isMinimized: Bool,
        bounds: CGRect,
        screenID: UInt32?,
        bundleID: String,
        appPath: String,
        accessibilityTitle: String,
        accessibilitySignature: String,
        isFullscreen: Bool? = nil
    ) {
        self.owner = owner
        self.title = title
        self.pid = pid
        self.windowID = windowID
        self.accessibilityWindowID = accessibilityWindowID
        self.layer = layer
        self.isOnScreen = isOnScreen
        self.isMinimized = isMinimized
        self.bounds = bounds
        self.screenID = screenID
        self.bundleID = bundleID
        self.appPath = appPath
        self.accessibilityTitle = accessibilityTitle
        self.accessibilitySignature = accessibilitySignature
        self.isFullscreen = isFullscreen
    }
}

struct TaskbarItem: Equatable {
    let owner: String
    let pid: pid_t?
    let title: String
    let windowCount: Int
    let windowIDs: [Int]
    let windowBounds: CGRect?
    let accessibilitySignature: String
    let isFrontmost: Bool
    let isMinimized: Bool
    let bundleID: String
    let appPath: String
    let isPinned: Bool
    let pinOrder: Int?

    var identity: String {
        identityForTaskbar(bundleID: bundleID, appPath: appPath)
    }
}

struct FrontmostWindowExpectation: Equatable {
    let pid: pid_t
    let windowID: Int
    let expiresAt: TimeInterval
}

struct FrontmostWindowResolution: Equatable {
    let effectiveWindowID: Int?
    let remainingExpectation: FrontmostWindowExpectation?
}

enum TaskbarItemClickAction: Equatable {
    case minimize
    case restore
    case activate
    case launch
}

func taskbarItemClickAction(for item: TaskbarItem) -> TaskbarItemClickAction {
    guard item.pid != nil else { return .launch }
    if item.isMinimized { return .restore }
    if item.isFrontmost { return .minimize }
    return .activate
}

func taskbarItemSpringLoadAction(for item: TaskbarItem) -> TaskbarItemClickAction {
    guard item.pid != nil else { return .launch }
    if item.isMinimized { return .restore }
    // A drag hover must never inherit the click-to-minimise behaviour. The
    // dragged files need the target app to stay visible when it is already active.
    return .activate
}

func frontmostWindowExpectation(
    afterActivating item: TaskbarItem,
    now: TimeInterval,
    timeToLive: TimeInterval = 2
) -> FrontmostWindowExpectation? {
    guard let pid = item.pid, let windowID = item.windowIDs.first else {
        return nil
    }

    return FrontmostWindowExpectation(
        pid: pid,
        windowID: windowID,
        expiresAt: now + timeToLive
    )
}

func resolveFrontmostWindow(
    measuredPID: pid_t?,
    measuredWindowID: Int?,
    expectation: FrontmostWindowExpectation?,
    now: TimeInterval
) -> FrontmostWindowResolution {
    guard let expectation, now < expectation.expiresAt else {
        return FrontmostWindowResolution(
            effectiveWindowID: measuredWindowID,
            remainingExpectation: nil
        )
    }

    guard measuredPID == expectation.pid else {
        return FrontmostWindowResolution(
            effectiveWindowID: measuredWindowID,
            remainingExpectation: expectation
        )
    }

    if measuredWindowID == expectation.windowID {
        return FrontmostWindowResolution(
            effectiveWindowID: measuredWindowID,
            remainingExpectation: nil
        )
    }

    return FrontmostWindowResolution(
        effectiveWindowID: expectation.windowID,
        remainingExpectation: expectation
    )
}

func visibleWindows(_ records: [WindowRecord], currentPID: pid_t, includeMinimized: Bool = false) -> [WindowRecord] {
    deduplicatedAccessibilitySurfaces(records.filter { record in
        let owner = record.owner.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !owner.isEmpty, !ignoredOwners.contains(owner) else { return false }
        guard !(record.pid == currentPID && record.title == "mikerosoft taskbar") else { return false }
        guard record.layer == 0 else { return false }
        if record.isMinimized {
            return includeMinimized
        }
        guard record.isOnScreen else { return false }
        guard record.bounds.width >= minimumWindowWidth else { return false }
        guard record.bounds.height >= minimumWindowHeight else { return false }
        return true
    })
}

private func deduplicatedAccessibilitySurfaces(_ records: [WindowRecord]) -> [WindowRecord] {
    var result: [WindowRecord] = []

    for record in records {
        guard let existingIndex = result.firstIndex(where: { isDuplicateSurface($0, record) }) else {
            result.append(record)
            continue
        }

        if shouldReplaceDuplicate(existing: result[existingIndex], with: record) {
            result[existingIndex] = record
        }
    }

    return result
}

private func isDuplicateSurface(_ left: WindowRecord, _ right: WindowRecord) -> Bool {
    if left.windowID > 0, left.windowID == right.windowID {
        return true
    }

    if hasProvenAccessibilityWindowID(left), hasProvenAccessibilityWindowID(right) {
        return false
    }

    let leftSignature = accessibilityDuplicateSignature(left)
    let rightSignature = accessibilityDuplicateSignature(right)

    if let leftSignature,
       let rightSignature,
       leftSignature == rightSignature {
        return accessibilityTitlesCanRepresentSameSurface(left, right)
    }

    guard fallbackDuplicateBaseKey(left) == fallbackDuplicateBaseKey(right),
          titlesCanRepresentSameSurface(left, right)
    else {
        return false
    }

    if leftSignature != nil || rightSignature != nil {
        return isUntitledInternalSiblingSurface(left, comparedTo: right)
            || isUntitledInternalSiblingSurface(right, comparedTo: left)
    }

    return left.bounds.overlapRatio(with: right.bounds) >= 0.5
}

private func hasProvenAccessibilityWindowID(_ record: WindowRecord) -> Bool {
    record.windowID > 0 && record.accessibilityWindowID == record.windowID
}

private func isUntitledInternalSiblingSurface(_ record: WindowRecord, comparedTo sibling: WindowRecord) -> Bool {
    guard record.accessibilitySignature.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return false
    }

    let title = normalizedDuplicateTitle(record.title)
    guard title.isEmpty || title == normalizedDuplicateTitle(record.owner) else {
        return false
    }

    guard record.bounds.area <= maximumUntitledInternalSurfaceArea else {
        return false
    }

    guard sibling.bounds.area >= record.bounds.area * internalSurfaceSiblingAreaMultiplier else {
        return false
    }

    return record.bounds.overlapRatio(with: sibling.bounds) >= 0.5
}

private func shouldReplaceDuplicate(existing: WindowRecord, with candidate: WindowRecord) -> Bool {
    let existingTitleScore = duplicateTitleScore(existing)
    let candidateTitleScore = duplicateTitleScore(candidate)
    if candidateTitleScore != existingTitleScore {
        return candidateTitleScore > existingTitleScore
    }
    return candidate.bounds.area > existing.bounds.area
}

private func accessibilityTitlesCanRepresentSameSurface(_ left: WindowRecord, _ right: WindowRecord) -> Bool {
    let leftTitle = normalizedDuplicateTitle(left.accessibilityTitle)
    let rightTitle = normalizedDuplicateTitle(right.accessibilityTitle)
    let ownerTitle = normalizedDuplicateTitle(left.owner)

    if leftTitle.isEmpty, rightTitle.isEmpty {
        return titlesCanRepresentSameSurface(left, right)
    }

    if leftTitle == rightTitle {
        return true
    }

    return leftTitle.isEmpty
        || rightTitle.isEmpty
        || leftTitle == ownerTitle
        || rightTitle == ownerTitle
}

private func accessibilityDuplicateSignature(_ record: WindowRecord) -> String? {
    let axSignature = record.accessibilitySignature.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !axSignature.isEmpty else { return nil }
    return [
        String(record.pid),
        record.bundleID,
        record.appPath,
        record.owner,
        axSignature
    ].joined(separator: "\u{1f}")
}

private func fallbackDuplicateBaseKey(_ record: WindowRecord) -> String {
    [
        String(record.pid),
        record.bundleID,
        record.appPath,
        record.owner
    ].joined(separator: "\u{1f}")
}

private func titlesCanRepresentSameSurface(_ left: WindowRecord, _ right: WindowRecord) -> Bool {
    let leftTitle = normalizedDuplicateTitle(left.title)
    let rightTitle = normalizedDuplicateTitle(right.title)
    guard !leftTitle.isEmpty, !rightTitle.isEmpty else {
        return leftTitle.isEmpty && rightTitle.isEmpty
    }
    if leftTitle == rightTitle { return true }
    return leftTitle == normalizedDuplicateTitle(left.owner)
        || rightTitle == normalizedDuplicateTitle(right.owner)
}

private func duplicateTitleScore(_ record: WindowRecord) -> Int {
    let title = normalizedDuplicateTitle(record.title)
    guard !title.isEmpty else { return 0 }
    return title == normalizedDuplicateTitle(record.owner) ? 1 : 2
}

private func normalizedDuplicateTitle(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}

func taskbarItemWidth(textWidth: CGFloat, iconSize: CGFloat, minimumWidth: CGFloat, maximumWidth: CGFloat) -> CGFloat {
    let naturalWidth = TaskbarItemMetrics.naturalWidth(textWidth: textWidth, iconSize: iconSize)
    return max(minimumWidth, min(maximumWidth, naturalWidth))
}

func fittedTaskbarItemWidths(preferredWidths: [CGFloat], softMinimumWidth: CGFloat, availableWidth: CGFloat) -> [CGFloat] {
    guard !preferredWidths.isEmpty else { return [] }

    let availableWidth = max(0, availableWidth)
    let preferredWidths = preferredWidths.map { max(0, $0) }
    let totalPreferredWidth = preferredWidths.reduce(0, +)

    guard totalPreferredWidth > availableWidth else {
        return preferredWidths
    }

    let softMinimumWidth = max(0, softMinimumWidth)
    let softMinimumTotalWidth = softMinimumWidth * CGFloat(preferredWidths.count)

    guard availableWidth > softMinimumTotalWidth else {
        let forcedWidth = availableWidth / CGFloat(preferredWidths.count)
        return Array(repeating: forcedWidth, count: preferredWidths.count)
    }

    var fittedWidths = preferredWidths
    var remainingOverflow = totalPreferredWidth - availableWidth
    var shrinkableIndexes = Set(fittedWidths.indices.filter { fittedWidths[$0] > softMinimumWidth })

    while remainingOverflow > 0.001, !shrinkableIndexes.isEmpty {
        let shrinkPerItem = remainingOverflow / CGFloat(shrinkableIndexes.count)
        var indexesAtMinimum = Set<Int>()

        for index in shrinkableIndexes {
            let availableShrink = fittedWidths[index] - softMinimumWidth
            let shrink = min(shrinkPerItem, availableShrink)
            fittedWidths[index] -= shrink
            remainingOverflow -= shrink

            if fittedWidths[index] <= softMinimumWidth + 0.001 {
                fittedWidths[index] = softMinimumWidth
                indexesAtMinimum.insert(index)
            }
        }

        shrinkableIndexes.subtract(indexesAtMinimum)
    }

    return fittedWidths
}

func fittedTaskbarItemWidths(
    preferredWidths: [CGFloat],
    minimumWidths: [CGFloat],
    availableWidth: CGFloat
) -> [CGFloat] {
    precondition(preferredWidths.count == minimumWidths.count)
    guard !preferredWidths.isEmpty else { return [] }

    let availableWidth = max(0, availableWidth)
    let minimumWidths = minimumWidths.map { max(0, $0) }
    let preferredWidths = zip(preferredWidths, minimumWidths).map { preferredWidth, minimumWidth in
        max(minimumWidth, preferredWidth)
    }
    let totalPreferredWidth = preferredWidths.reduce(0, +)

    guard totalPreferredWidth > availableWidth else {
        return preferredWidths
    }

    let totalMinimumWidth = minimumWidths.reduce(0, +)
    guard availableWidth > totalMinimumWidth else {
        guard totalMinimumWidth > 0 else {
            return Array(repeating: 0, count: preferredWidths.count)
        }

        var fittedWidths = minimumWidths.map { $0 * availableWidth / totalMinimumWidth }
        fittedWidths[fittedWidths.index(before: fittedWidths.endIndex)] += availableWidth - fittedWidths.reduce(0, +)
        return fittedWidths
    }

    var fittedWidths = preferredWidths
    var remainingOverflow = totalPreferredWidth - availableWidth
    var shrinkableIndexes = fittedWidths.indices.filter {
        fittedWidths[$0] > minimumWidths[$0]
    }

    while remainingOverflow > 0.000_001, !shrinkableIndexes.isEmpty {
        let shrinkPerItem = remainingOverflow / CGFloat(shrinkableIndexes.count)
        var stillShrinkable: [Int] = []

        for index in shrinkableIndexes {
            let availableShrink = fittedWidths[index] - minimumWidths[index]
            let shrink = min(shrinkPerItem, availableShrink)
            fittedWidths[index] -= shrink
            remainingOverflow -= shrink

            if fittedWidths[index] > minimumWidths[index] + 0.000_001 {
                stillShrinkable.append(index)
            } else {
                fittedWidths[index] = minimumWidths[index]
            }
        }

        shrinkableIndexes = stillShrinkable
    }

    if remainingOverflow > 0, let index = fittedWidths.indices.last(where: {
        fittedWidths[$0] > minimumWidths[$0]
    }) {
        fittedWidths[index] -= min(remainingOverflow, fittedWidths[index] - minimumWidths[index])
    }

    return fittedWidths
}

func buildTaskbarItems(
    windows: [WindowRecord],
    frontmostPID: pid_t?,
    frontmostWindowID: Int? = nil,
    pinnedApps: [PinnedApp] = []
) -> [TaskbarItem] {
    let pinnedByIdentity = Dictionary(uniqueKeysWithValues: pinnedApps.enumerated().map { index, app in
        (app.identity, index)
    })

    let runningItems = windows.map { window in
            let pinOrder = pinnedByIdentity[identity(bundleID: window.bundleID, appPath: window.appPath)]
            return TaskbarItem(
                owner: window.owner,
                pid: window.pid,
                title: window.title.isEmpty ? window.owner : window.title,
                windowCount: 1,
                windowIDs: [window.windowID],
                windowBounds: window.bounds,
                accessibilitySignature: window.accessibilitySignature,
                isFrontmost: isFrontmostWindow(window, frontmostPID: frontmostPID, frontmostWindowID: frontmostWindowID),
                isMinimized: window.isMinimized,
                bundleID: window.bundleID,
                appPath: window.appPath,
                isPinned: pinOrder != nil,
                pinOrder: pinOrder
            )
        }

    return runningItems
        .includingClosedPinnedApps(
            pinnedApps: pinnedApps,
            existingIdentities: Set(runningItems.map { identity(bundleID: $0.bundleID, appPath: $0.appPath) })
        )
        .sorted(by: taskbarItemSort)
}

private func taskbarItemSort(_ left: TaskbarItem, _ right: TaskbarItem) -> Bool {
    switch (left.pinOrder, right.pinOrder) {
    case let (leftOrder?, rightOrder?):
        if leftOrder != rightOrder { return leftOrder < rightOrder }
    case (_?, nil):
        return true
    case (nil, _?):
        return false
    case (nil, nil):
        break
    }

    let ownerCompare = left.owner.localizedCaseInsensitiveCompare(right.owner)
    if ownerCompare != .orderedSame {
        return ownerCompare == .orderedAscending
    }

    let titleCompare = left.title.localizedCaseInsensitiveCompare(right.title)
    if titleCompare != .orderedSame {
        return titleCompare == .orderedAscending
    }

    if left.pid != right.pid {
        return (left.pid ?? 0) < (right.pid ?? 0)
    }

    return (left.windowIDs.first ?? 0) < (right.windowIDs.first ?? 0)
}

private func identity(bundleID: String, appPath: String) -> String {
    identityForTaskbar(bundleID: bundleID, appPath: appPath)
}

private func identityForTaskbar(bundleID: String, appPath: String) -> String {
    if !bundleID.isEmpty {
        return "bundle:\(bundleID)"
    }
    return "path:\(appPath)"
}

private extension CGRect {
    var area: CGFloat {
        guard !isNull, !isEmpty else { return 0 }
        return width * height
    }

    func overlapRatio(with other: CGRect) -> CGFloat {
        let smallerArea = min(area, other.area)
        guard smallerArea > 0 else { return 0 }
        return intersection(other).area / smallerArea
    }
}

private extension Array where Element == TaskbarItem {
    func includingClosedPinnedApps(pinnedApps: [PinnedApp], existingIdentities: Set<String>) -> [TaskbarItem] {
        var items = self
        for (index, app) in pinnedApps.enumerated() where !existingIdentities.contains(app.identity) {
            items.append(
                TaskbarItem(
                    owner: app.displayName,
                    pid: nil,
                    title: app.displayName,
                    windowCount: 0,
                    windowIDs: [],
                    windowBounds: nil,
                    accessibilitySignature: "",
                    isFrontmost: false,
                    isMinimized: false,
                    bundleID: app.bundleID,
                    appPath: app.appPath,
                    isPinned: true,
                    pinOrder: index
                )
            )
        }
        return items
    }
}

func frontmostWindowID(in windows: [WindowRecord], frontmostPID: pid_t?) -> Int? {
    guard let frontmostPID else { return nil }
    return windows.first { window in
        window.pid == frontmostPID
            && !window.isMinimized
            && window.layer == 0
            && window.isOnScreen
    }?.windowID
}

private func isFrontmostWindow(_ window: WindowRecord, frontmostPID: pid_t?, frontmostWindowID: Int?) -> Bool {
    guard !window.isMinimized, frontmostPID == window.pid else {
        return false
    }

    if let frontmostWindowID {
        return window.windowID == frontmostWindowID
    }

    return true
}

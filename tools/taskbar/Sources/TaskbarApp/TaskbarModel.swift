import CoreGraphics
import Foundation

let minimumWindowWidth: CGFloat = 64
let minimumWindowHeight: CGFloat = 40

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
    let layer: Int
    let isOnScreen: Bool
    let bounds: CGRect
    let screenID: UInt32?
    let bundleID: String
    let appPath: String
}

struct TaskbarItem: Equatable {
    let owner: String
    let pid: pid_t?
    let title: String
    let windowCount: Int
    let windowIDs: [Int]
    let isFrontmost: Bool
    let bundleID: String
    let appPath: String
    let isPinned: Bool
    let pinOrder: Int?

    var identity: String {
        identityForTaskbar(bundleID: bundleID, appPath: appPath)
    }
}

func visibleWindows(_ records: [WindowRecord], currentPID: pid_t) -> [WindowRecord] {
    records.filter { record in
        let owner = record.owner.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !owner.isEmpty, !ignoredOwners.contains(owner) else { return false }
        guard !(record.pid == currentPID && record.title == "mikerosoft taskbar") else { return false }
        guard record.layer == 0 else { return false }
        guard record.isOnScreen else { return false }
        guard record.bounds.width >= minimumWindowWidth else { return false }
        guard record.bounds.height >= minimumWindowHeight else { return false }
        return true
    }
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

func buildTaskbarItems(
    windows: [WindowRecord],
    frontmostPID: pid_t?,
    groupByApp: Bool,
    pinnedApps: [PinnedApp] = []
) -> [TaskbarItem] {
    _ = groupByApp
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
                isFrontmost: frontmostPID == window.pid,
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
                    isFrontmost: false,
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

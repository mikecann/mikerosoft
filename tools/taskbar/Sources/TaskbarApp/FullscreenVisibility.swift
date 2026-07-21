import CoreGraphics
import Darwin

private let fullscreenEdgeTolerance: CGFloat = 2

private func isSteamGame(_ record: WindowRecord) -> Bool {
    record.appPath
        .replacingOccurrences(of: "\\", with: "/")
        .lowercased()
        .contains("/steamapps/common/")
}

func windowShouldObscureTaskbar(_ record: WindowRecord) -> Bool {
    // A normal macOS window can fill the exact screen after a title-bar double
    // click. Only native fullscreen windows, or borderless Steam games which do
    // not reliably expose AXFullScreen, should make the taskbar disappear.
    record.isFullscreen == true || isSteamGame(record)
}

func windowCoversScreen(_ windowBounds: CGRect, screenBounds: CGRect) -> Bool {
    windowBounds.minX <= screenBounds.minX + fullscreenEdgeTolerance
        && windowBounds.minY <= screenBounds.minY + fullscreenEdgeTolerance
        && windowBounds.maxX >= screenBounds.maxX - fullscreenEdgeTolerance
        && windowBounds.maxY >= screenBounds.maxY - fullscreenEdgeTolerance
}

func fullscreenCoveredScreenIDs(
    records: [WindowRecord],
    screens: [ScreenInfo],
    frontmostPID: pid_t?,
    currentPID: pid_t
) -> Set<UInt32> {
    guard let frontmostPID, frontmostPID != currentPID else { return [] }

    let foregroundWindows = records.filter {
        $0.pid == frontmostPID
            && $0.layer == 0
            && $0.isOnScreen
            && !$0.isMinimized
    }

    return foregroundWindows.reduce(into: Set<UInt32>()) { coveredScreenIDs, window in
        guard windowShouldObscureTaskbar(window) else { return }
        for screen in screens where windowCoversScreen(window.bounds, screenBounds: screen.quartzFrame) {
            coveredScreenIDs.insert(screen.id)
        }
    }
}

import CoreGraphics
import Darwin

private let fullscreenEdgeTolerance: CGFloat = 2

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
        for screen in screens where windowCoversScreen(window.bounds, screenBounds: screen.quartzFrame) {
            coveredScreenIDs.insert(screen.id)
        }
    }
}

import AppKit
import CoreGraphics

struct ScreenInfo: Equatable {
    let id: UInt32
    let name: String
    let appKitFrame: CGRect
    let quartzFrame: CGRect
}

struct ScreenSnapshot: Equatable {
    let id: UInt32
    let name: String
    let appKitFrame: CGRect
    let displayBounds: CGRect?
}

func screenInfos(from snapshots: [ScreenSnapshot]) -> [ScreenInfo] {
    let primaryMaxY = snapshots.first?.appKitFrame.maxY ?? 0

    return snapshots.map { snapshot in
        let frame = snapshot.appKitFrame
        let fallbackQuartzFrame = CGRect(
            x: frame.minX,
            y: primaryMaxY - frame.maxY,
            width: frame.width,
            height: frame.height
        )

        return ScreenInfo(
            id: snapshot.id,
            name: snapshot.name,
            appKitFrame: frame,
            quartzFrame: snapshot.displayBounds ?? fallbackQuartzFrame
        )
    }
}

func collectScreens() -> [ScreenInfo] {
    let snapshots = NSScreen.screens.enumerated().map { index, screen in
        let displayID = screenID(screen)
        return ScreenSnapshot(
            id: displayID ?? UInt32(index + 1),
            name: screen.localizedName,
            appKitFrame: screen.frame,
            displayBounds: displayID.map(CGDisplayBounds)
        )
    }

    return screenInfos(from: snapshots)
}

private func screenID(_ screen: NSScreen) -> UInt32? {
    let key = NSDeviceDescriptionKey("NSScreenNumber")
    if let number = screen.deviceDescription[key] as? NSNumber {
        return number.uint32Value
    }
    return nil
}

func screenIDForWindow(bounds: CGRect, screens: [ScreenInfo]) -> UInt32? {
    screens
        .map { screen in
            (screen.id, bounds.intersection(screen.quartzFrame).area)
        }
        .filter { $0.1 > 0 }
        .max(by: { $0.1 < $1.1 })?
        .0
}

private extension CGRect {
    var area: CGFloat {
        guard !isNull, !isEmpty else { return 0 }
        return width * height
    }
}

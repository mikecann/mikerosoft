import AppKit
import CoreGraphics

struct ScreenInfo: Equatable {
    let id: UInt32
    let name: String
    let appKitFrame: CGRect
    let quartzFrame: CGRect
}

func collectScreens() -> [ScreenInfo] {
    let screens = NSScreen.screens
    let desktopMaxY = screens.map { $0.frame.maxY }.max() ?? 0

    return screens.enumerated().map { index, screen in
        let id = screenID(screen, fallback: UInt32(index + 1))
        let frame = screen.frame
        let quartzFrame = CGRect(
            x: frame.minX,
            y: desktopMaxY - frame.maxY,
            width: frame.width,
            height: frame.height
        )

        return ScreenInfo(
            id: id,
            name: screen.localizedName,
            appKitFrame: frame,
            quartzFrame: quartzFrame
        )
    }
}

private func screenID(_ screen: NSScreen, fallback: UInt32) -> UInt32 {
    let key = NSDeviceDescriptionKey("NSScreenNumber")
    if let number = screen.deviceDescription[key] as? NSNumber {
        return number.uint32Value
    }
    return fallback
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

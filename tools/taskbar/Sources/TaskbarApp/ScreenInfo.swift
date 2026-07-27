import AppKit
import ColorSync
import CoreGraphics

struct ScreenInfo: Equatable {
    /// CoreGraphics' connection-local ID. Use this for live window and display APIs only.
    let id: UInt32
    let name: String
    let appKitFrame: CGRect
    let quartzFrame: CGRect
    /// Stable display identity used for persisted per-monitor settings.
    let persistentID: String

    init(
        id: UInt32,
        name: String,
        appKitFrame: CGRect,
        quartzFrame: CGRect,
        persistentID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.appKitFrame = appKitFrame
        self.quartzFrame = quartzFrame
        self.persistentID = persistentID ?? persistentDisplayID(runtimeID: id, displayUUID: nil)
    }
}

struct ScreenSnapshot: Equatable {
    let id: UInt32
    let name: String
    let appKitFrame: CGRect
    let displayBounds: CGRect?
    let persistentID: String

    init(
        id: UInt32,
        name: String,
        appKitFrame: CGRect,
        displayBounds: CGRect?,
        persistentID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.appKitFrame = appKitFrame
        self.displayBounds = displayBounds
        self.persistentID = persistentID ?? persistentDisplayID(runtimeID: id, displayUUID: nil)
    }
}

func persistentDisplayID(runtimeID: UInt32, displayUUID: String?) -> String {
    guard let displayUUID else {
        // This fallback is intentionally labelled as runtime-only. It avoids
        // pretending that vendor/model/zero-serial tuples uniquely identify
        // identical displays.
        return "runtime:\(runtimeID)"
    }

    let normalizedUUID = displayUUID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !normalizedUUID.isEmpty else {
        return "runtime:\(runtimeID)"
    }
    return "display:\(normalizedUUID)"
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
            quartzFrame: snapshot.displayBounds ?? fallbackQuartzFrame,
            persistentID: snapshot.persistentID
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
            displayBounds: displayID.map(CGDisplayBounds),
            persistentID: displayID.map {
                persistentDisplayID(runtimeID: $0, displayUUID: displayUUID(for: $0))
            }
        )
    }

    return screenInfos(from: snapshots)
}

private func displayUUID(for displayID: UInt32) -> String? {
    guard let unmanagedUUID = CGDisplayCreateUUIDFromDisplayID(displayID) else {
        return nil
    }
    let uuid = unmanagedUUID.takeRetainedValue()
    return CFUUIDCreateString(nil, uuid) as String
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

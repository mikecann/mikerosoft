import AppKit
import CoreGraphics

enum NavigationDirection: Equatable {
    case back
    case forward
}

enum BackForwardRouter {
    static let backButton: Int64 = 3
    static let forwardButton: Int64 = 4

    /// Apps that ignore mouse buttons 4 and 5 but understand the trackpad
    /// swipe. Everything else, such as Chrome and VS Code, already handles the
    /// side buttons, so it keeps receiving them unchanged. This list matches
    /// LinearMouse's universal back and forward feature.
    static let swipeApps = [
        "com.apple.*",
        "com.binarynights.ForkLift*",
        "org.mozilla.firefox",
        "com.operasoftware.Opera"
    ]

    static func direction(
        forButton button: Int64,
        targetBundleID: String?,
        enabled: Bool
    ) -> NavigationDirection? {
        guard enabled, let targetBundleID, wantsSwipe(targetBundleID) else {
            return nil
        }

        switch button {
        case backButton:
            return .back
        case forwardButton:
            return .forward
        default:
            return nil
        }
    }

    static func wantsSwipe(_ bundleID: String) -> Bool {
        swipeApps.contains { pattern in
            if pattern.hasSuffix("*") {
                return bundleID.hasPrefix(pattern.dropLast())
            }
            return bundleID == pattern
        }
    }
}

enum SideButtonAction: Equatable {
    case passThrough
    case swipe(NavigationDirection)
}

/// Remembers which presses became swipes so their drags and releases are
/// swallowed too, even if the pointer has moved over another app since.
struct SideButtonState {
    private var converted: Set<Int64> = []

    mutating func mouseDown(button: Int64, direction: NavigationDirection?) -> SideButtonAction {
        guard let direction else {
            converted.remove(button)
            return .passThrough
        }

        converted.insert(button)
        return .swipe(direction)
    }

    func swallowsDrag(button: Int64) -> Bool {
        converted.contains(button)
    }

    /// Returns true when the release belongs to a press that became a swipe.
    mutating func mouseUp(button: Int64) -> Bool {
        converted.remove(button) != nil
    }
}

/// Builds the trackpad "swipe between pages" gesture that Finder and Safari
/// use for back and forward. The field numbers are private CoreGraphics values
/// listed in WebKit's CoreGraphicsTestSPI.h, and LinearMouse posts the same
/// two events.
enum NavigationSwipe {
    static let gestureEventType = CGEventType(rawValue: 29)!
    static let hidTypeField = CGEventField(rawValue: 110)!
    static let directionField = CGEventField(rawValue: 115)!
    static let phaseField = CGEventField(rawValue: 132)!

    private static let navigationSwipeHIDType: Int64 = 16
    private static let phaseBegan: Int64 = 1
    private static let phaseEnded: Int64 = 4
    private static let swipeLeft: Int64 = 0x04
    private static let swipeRight: Int64 = 0x08

    static func events(for direction: NavigationDirection) -> [CGEvent] {
        guard let began = CGEvent(source: nil), let ended = CGEvent(source: nil) else {
            return []
        }

        for event in [began, ended] {
            event.type = gestureEventType
            event.setIntegerValueField(hidTypeField, value: navigationSwipeHIDType)
        }
        began.setIntegerValueField(phaseField, value: phaseBegan)
        began.setIntegerValueField(directionField, value: direction == .back ? swipeLeft : swipeRight)
        ended.setIntegerValueField(phaseField, value: phaseEnded)

        return [began, ended]
    }

    static func post(_ direction: NavigationDirection) {
        for event in events(for: direction) {
            event.post(tap: .cgSessionEventTap)
        }
    }
}

enum TargetApp {
    /// Bundle identifier of the app that a mouse event is headed for.
    static func bundleIdentifier(for event: CGEvent) -> String? {
        let targetPID = pid_t(truncatingIfNeeded: event.getIntegerValueField(.eventTargetUnixProcessID))
        if targetPID > 0, let bundleID = bundleIdentifier(of: targetPID) {
            return bundleID
        }

        // Events at the HID tap are not always routed yet. Fall back to the
        // owner of the frontmost normal window under the pointer.
        guard let ownerPID = windowOwner(at: event.location) else {
            return nil
        }
        return bundleIdentifier(of: ownerPID)
    }

    private static func bundleIdentifier(of pid: pid_t) -> String? {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

    private static func windowOwner(at point: CGPoint) -> pid_t? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        for window in windows {
            guard let layer = window[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let boundsValue = window[kCGWindowBounds as String],
                  let bounds = CGRect(dictionaryRepresentation: boundsValue as! CFDictionary),
                  bounds.contains(point),
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t
            else {
                continue
            }
            return pid
        }

        return nil
    }
}

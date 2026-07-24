import AppKit
import ApplicationServices

struct AccessibilityWindowCounter {
    func countWindows(for application: NSRunningApplication) -> Int? {
        let element = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.2)

        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element,
            kAXWindowsAttribute as CFString,
            &value
        )

        guard result == .success, let value else {
            return nil
        }

        // AXWindows includes minimized windows, which is important here. Minimizing
        // the final window must not be treated as closing it.
        guard CFGetTypeID(value) == CFArrayGetTypeID() else {
            return nil
        }

        return CFArrayGetCount((value as! CFArray))
    }
}

enum AccessibilityPermission {
    static var isGranted: Bool {
        AXIsProcessTrusted()
    }

    static func requestIfNeeded() {
        guard !isGranted else {
            return
        }

        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}

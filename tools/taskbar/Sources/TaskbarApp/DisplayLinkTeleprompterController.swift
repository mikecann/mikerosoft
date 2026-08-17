import AppKit
import ApplicationServices
import Foundation

struct DisplayLinkAccessibilityNode: Equatable {
    var role: String
    var text: String = ""
    var boolValue: Bool?
    var children: [DisplayLinkAccessibilityNode] = []
}

enum DisplayLinkPrompterSwitchAction: Equatable {
    case none
    case press
}

func displayLinkPrompterSwitchAction(current: Bool?, target: Bool) -> DisplayLinkPrompterSwitchAction {
    current == target ? .none : .press
}

private func isDisplayLinkSwitch(_ node: DisplayLinkAccessibilityNode) -> Bool {
    node.role == kAXCheckBoxRole as String || node.role == "AXSwitch"
}

private func namesElgatoPrompter(_ text: String) -> Bool {
    let normalized = text.lowercased()
    // macOS and DisplayLink sometimes shorten the display name to
    // "Elgato Prom.". Match the stable product-name stem used by Video HQ.
    return normalized.contains("elgato") && normalized.contains("prom")
}

private func subtreeNamesElgatoPrompter(_ node: DisplayLinkAccessibilityNode) -> Bool {
    namesElgatoPrompter(node.text) || node.children.contains(where: subtreeNamesElgatoPrompter)
}

private func firstSwitchPath(
    in node: DisplayLinkAccessibilityNode,
    path: [Int]
) -> [Int]? {
    if isDisplayLinkSwitch(node) {
        return path
    }
    for (index, child) in node.children.enumerated() {
        if let match = firstSwitchPath(in: child, path: path + [index]) {
            return match
        }
    }
    return nil
}

func displayLinkTeleprompterSwitchPath(in root: DisplayLinkAccessibilityNode) -> [Int]? {
    func search(_ node: DisplayLinkAccessibilityNode, path: [Int]) -> [Int]? {
        if isDisplayLinkSwitch(node), namesElgatoPrompter(node.text) {
            return path
        }

        // Search smaller subtrees first. That keeps a neighbouring display's
        // switch from being selected merely because the whole window also
        // contains the words "Elgato Prompter" somewhere else.
        for (index, child) in node.children.enumerated() {
            if let match = search(child, path: path + [index]) {
                return match
            }
        }

        guard subtreeNamesElgatoPrompter(node) else { return nil }
        return firstSwitchPath(in: node, path: path)
    }

    return search(root, path: [])
}

enum DisplayLinkTeleprompterError: LocalizedError {
    case accessibilityPermissionMissing
    case managerUnavailable
    case menuUnavailable
    case switchUnavailable
    case switchDidNotChange

    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionMissing:
            return "Taskbar does not have Accessibility permission"
        case .managerUnavailable:
            return "DisplayLink Manager is not available"
        case .menuUnavailable:
            return "DisplayLink Manager's menu bar control is unavailable"
        case .switchUnavailable:
            return "DisplayLink Manager did not expose an Elgato Prompter switch"
        case .switchDidNotChange:
            return "DisplayLink Manager's Elgato Prompter switch did not change"
        }
    }
}

private enum DisplayLinkSwitchUpdate {
    case unavailable
    case alreadySet
    case changed
}

final class DisplayLinkTeleprompterController {
    static let shared = DisplayLinkTeleprompterController()

    private let bundleID = "com.displaylink.DisplayLinkUserAgent"
    private let appURL = URL(fileURLWithPath: "/Applications/DisplayLink Manager.app")
    private let queue = DispatchQueue(label: "com.mikerosoft.taskbar.displaylink-prompter", qos: .userInitiated)

    func setEnabled(_ enabled: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            let result = Result { try self.setEnabledSynchronously(enabled) }
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    private func setEnabledSynchronously(_ enabled: Bool) throws {
        guard AXIsProcessTrusted() else {
            throw DisplayLinkTeleprompterError.accessibilityPermissionMissing
        }
        guard let app = runningManager() ?? launchManagerAndWait() else {
            throw DisplayLinkTeleprompterError.managerUnavailable
        }

        let application = AXUIElementCreateApplication(app.processIdentifier)
        setTaskbarAccessibilityMessagingTimeout(application)

        switch try updateVisiblePrompterSwitch(enabled, in: application) {
        case .alreadySet:
            log("DisplayLink Elgato Prompter is already \(enabled ? "enabled" : "disabled")")
            return
        case .changed:
            log("DisplayLink Elgato Prompter set \(enabled ? "on" : "off")")
            return
        case .unavailable:
            break
        }

        guard let statusItem = displayLinkStatusItem(in: application),
              AXUIElementPerformAction(statusItem, kAXPressAction as CFString) == .success
        else {
            throw DisplayLinkTeleprompterError.menuUnavailable
        }

        defer {
            // Close the panel if it is still open. A failed close is harmless,
            // while leaving DisplayLink's UI on screen after every light toggle
            // would be distracting.
            if visiblePrompterSwitch(in: application) != nil {
                _ = AXUIElementPerformAction(statusItem, kAXPressAction as CFString)
            }
        }

        for _ in 0..<20 {
            switch try updateVisiblePrompterSwitch(enabled, in: application) {
            case .alreadySet, .changed:
                log("DisplayLink Elgato Prompter set \(enabled ? "on" : "off")")
                return
            case .unavailable:
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw DisplayLinkTeleprompterError.switchUnavailable
    }

    private func runningManager() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    private func launchManagerAndWait() -> NSRunningApplication? {
        guard FileManager.default.fileExists(atPath: appURL.path) else { return nil }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
            if let error {
                log("Could not launch DisplayLink Manager: \(error.localizedDescription)")
            }
        }

        for _ in 0..<30 {
            if let app = runningManager() {
                return app
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return nil
    }

    private func visiblePrompterSwitch(in application: AXUIElement) -> AXUIElement? {
        let root = accessibilitySnapshot(of: application)
        guard let path = displayLinkTeleprompterSwitchPath(in: root) else { return nil }
        return accessibilityElement(at: path, from: application)
    }

    private func updateVisiblePrompterSwitch(
        _ enabled: Bool,
        in application: AXUIElement
    ) throws -> DisplayLinkSwitchUpdate {
        guard let toggle = visiblePrompterSwitch(in: application) else {
            return .unavailable
        }

        let currentValue = accessibilityBoolValue(of: toggle)
        if displayLinkPrompterSwitchAction(current: currentValue, target: enabled) == .none {
            return .alreadySet
        }

        // SwiftUI exposes this as a writable AXValue, but DisplayLink ignores
        // AXUIElementSetAttributeValue even though it returns success. Invoke
        // the switch's actual action just as a user click would.
        let pressResult = AXUIElementPerformAction(toggle, kAXPressAction as CFString)
        log("DisplayLink Elgato Prompter AXPress result=\(pressResult.rawValue) current=\(String(describing: currentValue)) target=\(enabled)")
        guard pressResult == .success else {
            throw DisplayLinkTeleprompterError.switchDidNotChange
        }

        for _ in 0..<20 {
            // Re-read the tree because SwiftUI often replaces the switch
            // element during its state animation. The screen list is the
            // stronger fallback when disabling the display closes the panel.
            if visiblePrompterSwitch(in: application).flatMap(accessibilityBoolValue) == enabled
                || prompterScreenIsEnabled() == enabled {
                return .changed
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw DisplayLinkTeleprompterError.switchDidNotChange
    }

    private func prompterScreenIsEnabled() -> Bool {
        let readScreens = {
            NSScreen.screens.contains { namesElgatoPrompter($0.localizedName) }
        }
        if Thread.isMainThread {
            return readScreens()
        }
        return DispatchQueue.main.sync(execute: readScreens)
    }

    private func displayLinkStatusItem(in application: AXUIElement) -> AXUIElement? {
        for attribute in ["AXExtrasMenuBar", kAXMenuBarAttribute as String] {
            guard let menuBar = accessibilityElementAttribute(application, attribute) else { continue }
            let descendants = accessibilityDescendants(of: menuBar, maximumCount: 40)
            if let named = descendants.first(where: {
                accessibilityStringValue(of: $0).lowercased().contains("displaylink")
                    && accessibilityRole(of: $0) == kAXMenuBarItemRole as String
            }) {
                return named
            }
            if attribute == "AXExtrasMenuBar",
               let onlyStatusItem = descendants.first(where: {
                   accessibilityRole(of: $0) == kAXMenuBarItemRole as String
               }) {
                return onlyStatusItem
            }
        }
        return nil
    }
}

private func accessibilitySnapshot(
    of element: AXUIElement,
    depth: Int = 0,
    remaining: inout Int
) -> DisplayLinkAccessibilityNode {
    remaining -= 1
    let children = depth < 12 && remaining > 0
        ? accessibilityChildren(of: element).map {
            accessibilitySnapshot(of: $0, depth: depth + 1, remaining: &remaining)
        }
        : []
    return DisplayLinkAccessibilityNode(
        role: accessibilityRole(of: element),
        text: accessibilityStringValue(of: element),
        boolValue: accessibilityBoolValue(of: element),
        children: children
    )
}

private func accessibilitySnapshot(of element: AXUIElement) -> DisplayLinkAccessibilityNode {
    var remaining = 500
    return accessibilitySnapshot(of: element, remaining: &remaining)
}

private func accessibilityElement(at path: [Int], from root: AXUIElement) -> AXUIElement? {
    var current = root
    for index in path {
        let children = accessibilityChildren(of: current)
        guard children.indices.contains(index) else { return nil }
        current = children[index]
    }
    return current
}

private func accessibilityDescendants(of root: AXUIElement, maximumCount: Int) -> [AXUIElement] {
    var result: [AXUIElement] = []
    var pending = [root]
    while let element = pending.popLast(), result.count < maximumCount {
        result.append(element)
        pending.append(contentsOf: accessibilityChildren(of: element).reversed())
    }
    return result
}

private func accessibilityChildren(of element: AXUIElement) -> [AXUIElement] {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
          let children = value as? [AXUIElement]
    else {
        return []
    }
    return children
}

private func accessibilityElementAttribute(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
          let value,
          CFGetTypeID(value) == AXUIElementGetTypeID()
    else {
        return nil
    }
    return (value as! AXUIElement)
}

private func accessibilityRole(of element: AXUIElement) -> String {
    accessibilityStringAttribute(element, kAXRoleAttribute as String)
}

private func accessibilityStringValue(of element: AXUIElement) -> String {
    [
        kAXTitleAttribute as String,
        kAXDescriptionAttribute as String,
        kAXHelpAttribute as String,
        kAXRoleDescriptionAttribute as String,
        kAXIdentifierAttribute as String,
        kAXValueAttribute as String
    ]
    .map { accessibilityStringAttribute(element, $0) }
    .filter { !$0.isEmpty }
    .joined(separator: " ")
}

private func accessibilityStringAttribute(_ element: AXUIElement, _ attribute: String) -> String {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
        return ""
    }
    return value as? String ?? ""
}

private func accessibilityBoolValue(of element: AXUIElement) -> Bool? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
          let number = value as? NSNumber
    else {
        return nil
    }
    return number.boolValue
}

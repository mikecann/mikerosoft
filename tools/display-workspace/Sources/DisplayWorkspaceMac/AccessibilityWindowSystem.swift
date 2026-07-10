import AppKit
import ApplicationServices
import Darwin
import Foundation
import DisplayWorkspaceCore

public enum AccessibilityWindowError: Error, LocalizedError {
    case permissionRequired
    case windowNoLongerAvailable(Int)
    case operationFailed(attribute: String, error: AXError)

    public var errorDescription: String? {
        switch self {
        case .permissionRequired:
            return "Display Workspace needs Accessibility permission to save and restore windows."
        case let .windowNoLongerAvailable(runtimeID):
            return "Window \(runtimeID) is no longer available."
        case let .operationFailed(attribute, error):
            return "Could not set window \(attribute) (Accessibility error \(error.rawValue))."
        }
    }
}

public final class AccessibilityWindowSystem: WindowSystem {
    private var windowElements: [Int: AXUIElement] = [:]
    private let spaceLocator: (any WindowSpaceLocating)?
    private let windowIDResolver: AccessibilityWindowIDResolver?

    public init(spaceLocator: (any WindowSpaceLocating)? = nil) {
        self.spaceLocator = spaceLocator
        windowIDResolver = try? AccessibilityWindowIDResolver()
    }

    public static func isTrusted(prompt: Bool) -> Bool {
        let options = [
            "AXTrustedCheckOptionPrompt": prompt,
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    public func currentWindows() throws -> [ManagedWindow] {
        guard Self.isTrusted(prompt: false) else {
            throw AccessibilityWindowError.permissionRequired
        }

        windowElements.removeAll(keepingCapacity: true)
        var result: [ManagedWindow] = []
        var runtimeID = 1

        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  let bundleIdentifier = app.bundleIdentifier else { continue }

            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(appElement, 0.75)
            guard let windows: [AXUIElement] = attribute(kAXWindowsAttribute, from: appElement) else {
                continue
            }

            for window in windows {
                let isFullScreen: Bool = attribute("AXFullScreen", from: window) ?? false
                guard let role: String = attribute(kAXRoleAttribute, from: window),
                      role == kAXWindowRole as String,
                      !isFullScreen,
                      let position = pointAttribute(kAXPositionAttribute, from: window),
                      let size = sizeAttribute(kAXSizeAttribute, from: window),
                      size.width > 1,
                      size.height > 1 else { continue }

                let title: String? = attribute(kAXTitleAttribute, from: window)
                let documentURL: String? = attribute(kAXDocumentAttribute, from: window)
                let isMinimized: Bool = attribute(kAXMinimizedAttribute, from: window) ?? false
                let windowServerID = windowIDResolver?.windowServerID(for: window)
                let spaceID: UInt64?
                if let windowServerID, let spaceLocator {
                    spaceID = try? spaceLocator.spaceID(forWindowServerID: windowServerID)
                } else {
                    spaceID = nil
                }
                let managedWindow = ManagedWindow(
                    runtimeID: runtimeID,
                    windowServerID: windowServerID,
                    spaceID: spaceID,
                    bundleIdentifier: bundleIdentifier,
                    appName: app.localizedName ?? bundleIdentifier,
                    title: title,
                    documentURL: documentURL,
                    frame: WorkspaceFrame(
                        origin: WorkspacePoint(x: position.x, y: position.y),
                        size: WorkspaceSize(width: size.width, height: size.height)
                    ),
                    isMinimized: isMinimized
                )
                windowElements[runtimeID] = window
                result.append(managedWindow)
                runtimeID += 1
            }
        }

        return result
    }

    public func restoreWindow(
        runtimeID: Int,
        frame: WorkspaceFrame,
        isMinimized: Bool
    ) throws {
        guard let window = windowElements[runtimeID] else {
            throw AccessibilityWindowError.windowNoLongerAvailable(runtimeID)
        }

        try setBool(false, attribute: kAXMinimizedAttribute, on: window, required: false)
        try setPoint(frame.origin, on: window)
        try setSize(frame.size, on: window)
        // Some apps constrain the frame while resizing. Reapply the position afterwards.
        try setPoint(frame.origin, on: window)
        try setBool(isMinimized, attribute: kAXMinimizedAttribute, on: window, required: false)
    }

    private func attribute<T>(_ name: String, from element: AXUIElement) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value as? T
    }

    private func pointAttribute(_ name: String, from element: AXUIElement) -> CGPoint? {
        guard let value: AXValue = attribute(name, from: element),
              AXValueGetType(value) == .cgPoint else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value, .cgPoint, &point) ? point : nil
    }

    private func sizeAttribute(_ name: String, from element: AXUIElement) -> CGSize? {
        guard let value: AXValue = attribute(name, from: element),
              AXValueGetType(value) == .cgSize else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value, .cgSize, &size) ? size : nil
    }

    private func setPoint(_ point: WorkspacePoint, on element: AXUIElement) throws {
        var value = CGPoint(x: point.x, y: point.y)
        guard let axValue = AXValueCreate(.cgPoint, &value) else { return }
        try set(axValue, attribute: kAXPositionAttribute, on: element, required: true)
    }

    private func setSize(_ size: WorkspaceSize, on element: AXUIElement) throws {
        var value = CGSize(width: size.width, height: size.height)
        guard let axValue = AXValueCreate(.cgSize, &value) else { return }
        try set(axValue, attribute: kAXSizeAttribute, on: element, required: true)
    }

    private func setBool(
        _ value: Bool,
        attribute: String,
        on element: AXUIElement,
        required: Bool
    ) throws {
        try set(value as CFBoolean, attribute: attribute, on: element, required: required)
    }

    private func set(
        _ value: CFTypeRef,
        attribute: String,
        on element: AXUIElement,
        required: Bool
    ) throws {
        let error = AXUIElementSetAttributeValue(element, attribute as CFString, value)
        if error != .success && required {
            throw AccessibilityWindowError.operationFailed(
                attribute: attribute,
                error: error
            )
        }
    }
}

private final class AccessibilityWindowIDResolver {
    private typealias GetWindowID = @convention(c) (
        AXUIElement,
        UnsafeMutablePointer<UInt32>
    ) -> AXError

    private let handle: UnsafeMutableRawPointer
    private let getWindowID: GetWindowID

    init() throws {
        let path = "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/Versions/A/HIServices"
        guard let handle = dlopen(path, RTLD_NOW) else {
            throw SkyLightSpaceError.frameworkUnavailable(path)
        }
        self.handle = handle
        guard let symbol = dlsym(handle, "_AXUIElementGetWindow") else {
            throw SkyLightSpaceError.symbolUnavailable("_AXUIElementGetWindow")
        }
        getWindowID = unsafeBitCast(symbol, to: GetWindowID.self)
    }

    func windowServerID(for element: AXUIElement) -> UInt32? {
        var windowID: UInt32 = 0
        return getWindowID(element, &windowID) == .success ? windowID : nil
    }
}

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import MeetingArchiveCore

enum MeetingSignalStatus: Equatable, Sendable {
    case ready
    case noSupportedMeeting
    case accessibilityPermissionRequired
    case ambiguous(String)
}

struct MeetingSignalSnapshot: Equatable, Sendable {
    let session: MeetingSessionDescriptor?
    let windowID: CGWindowID?
    /// `nil` means the application UI did not prove either on or off. Callers
    /// must never turn an unknown or missing control into a camera-off edge.
    let cameraActive: Bool?
    let videoSafe: Bool
    let status: MeetingSignalStatus
}

struct SignalWindowFrame: Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    func approximatelyMatches(_ other: SignalWindowFrame, tolerance: Double = 3) -> Bool {
        abs(x - other.x) <= tolerance
            && abs(y - other.y) <= tolerance
            && abs(width - other.width) <= tolerance
            && abs(height - other.height) <= tolerance
    }
}

struct AccessibilityControlSnapshot: Equatable, Sendable {
    let role: String
    let title: String
    let controlDescription: String?
    let help: String?
    let value: String?
    let identifier: String?
    let url: String?
    let isEnabled: Bool

    init(
        role: String,
        title: String,
        controlDescription: String?,
        help: String? = nil,
        value: String?,
        identifier: String?,
        url: String?,
        isEnabled: Bool
    ) {
        self.role = role
        self.title = title
        self.controlDescription = controlDescription
        self.help = help
        self.value = value
        self.identifier = identifier
        self.url = url
        self.isEnabled = isEnabled
    }

    fileprivate var searchableText: String {
        [title, controlDescription, value, identifier]
            .compactMap { $0 }
            .joined(separator: " ")
            .foldedForMeetingSignal
    }
}

struct AccessibilityWindowSnapshot: Equatable, Sendable {
    let processID: pid_t
    let bundleIdentifier: String
    let applicationName: String
    let title: String
    let axWindowNumber: CGWindowID?
    let frame: SignalWindowFrame?
    let isMinimized: Bool
    let controls: [AccessibilityControlSnapshot]
}

/// Application-menu metadata has a different scope from window controls. The
/// resolver must explicitly bind it to one exact window before it can affect a
/// meeting signal.
struct AccessibilityMenuItemSnapshot: Equatable, Sendable {
    let title: String
    let isEnabled: Bool
}

struct AccessibilityMenuSnapshot: Equatable, Sendable {
    let title: String
    let items: [AccessibilityMenuItemSnapshot]
}

struct AccessibilityApplicationMenuSnapshot: Equatable, Sendable {
    let processID: pid_t
    let bundleIdentifier: String
    let menus: [AccessibilityMenuSnapshot]
}

struct CGWindowSnapshot: Equatable, Sendable {
    let windowID: CGWindowID
    let ownerPID: pid_t
    let ownerBundleIdentifier: String
    let title: String
    let frame: SignalWindowFrame?
    let isOnScreen: Bool
    let layer: Int
}

struct MeetingAccessibilityObservation: Equatable, Sendable {
    let accessibilityTrusted: Bool
    let accessibilityWindows: [AccessibilityWindowSnapshot]
    let cgWindows: [CGWindowSnapshot]
    let applicationMenus: [AccessibilityApplicationMenuSnapshot]
    let inaccessibleBundleIdentifiers: Set<String>
    let cgWindowListAvailable: Bool

    init(
        accessibilityTrusted: Bool,
        accessibilityWindows: [AccessibilityWindowSnapshot],
        cgWindows: [CGWindowSnapshot],
        applicationMenus: [AccessibilityApplicationMenuSnapshot] = [],
        inaccessibleBundleIdentifiers: Set<String> = [],
        cgWindowListAvailable: Bool = true
    ) {
        self.accessibilityTrusted = accessibilityTrusted
        self.accessibilityWindows = accessibilityWindows
        self.cgWindows = cgWindows
        self.applicationMenus = applicationMenus
        self.inaccessibleBundleIdentifiers = inaccessibleBundleIdentifiers
        self.cgWindowListAvailable = cgWindowListAvailable
    }
}

/// Converts bounded AX and CoreGraphics metadata into conservative meeting
/// signals. It owns only the camera-session epoch. Capture state remains in
/// `CaptureStateMachine`.
struct MeetingSignalResolver: Sendable {
    private struct ActiveEpoch: Sendable {
        let descriptor: MeetingSessionDescriptor
        let windowID: CGWindowID
    }

    private var activeEpoch: ActiveEpoch?

    init(restoring session: MeetingSessionDescriptor? = nil) {
        guard let session, let windowID = Self.windowID(from: session.surface.id) else {
            activeEpoch = nil
            return
        }
        activeEpoch = ActiveEpoch(descriptor: session, windowID: windowID)
    }

    mutating func restore(_ session: MeetingSessionDescriptor?) {
        self = MeetingSignalResolver(restoring: session)
    }

    mutating func resolve(_ observation: MeetingAccessibilityObservation) -> MeetingSignalSnapshot {
        guard observation.accessibilityTrusted else {
            return retainedUnknown(status: .accessibilityPermissionRequired)
        }

        let zoomMenuEligiblePIDs = Set(Dictionary(
            grouping: observation.accessibilityWindows.filter {
                $0.bundleIdentifier == "us.zoom.xos"
                    && $0.title.foldedForMeetingSignal == "zoom meeting"
            },
            by: \.processID
        ).compactMap { processID, windows in
            windows.count == 1 ? processID : nil
        })

        let candidates = observation.accessibilityWindows.compactMap { window in
            let applicationMenu = zoomMenuEligiblePIDs.contains(window.processID)
                && window.title.foldedForMeetingSignal == "zoom meeting"
                ? observation.applicationMenus.first {
                    $0.processID == window.processID
                        && $0.bundleIdentifier == window.bundleIdentifier
                }
                : nil
            return MeetingWindowClassifier.classify(
                window,
                mapping: MeetingWindowMapper.map(window, to: observation.cgWindows),
                applicationMenu: applicationMenu
            )
        }

        if let activeEpoch {
            return resolveActive(
                activeEpoch,
                candidates: candidates,
                observation: observation
            )
        }

        let joined = candidates.filter { $0.surfaceState == .joined }
        let mappedCameraOn = joined.filter { $0.mapping.windowID != nil && $0.cameraActive == true }

        if mappedCameraOn.count == 1, let candidate = mappedCameraOn.first, let windowID = candidate.mapping.windowID {
            let descriptor = MeetingSessionDescriptor(
                id: UUID().uuidString.lowercased(),
                sourceApplication: SourceApplicationDescriptor(
                    bundleIdentifier: candidate.window.bundleIdentifier,
                    displayName: candidate.window.applicationName,
                    kind: candidate.applicationKind
                ),
                surface: MeetingSurfaceDescriptor(
                    id: Self.surfaceID(windowID: windowID),
                    title: candidate.window.title.nilIfEmpty,
                    kind: .meeting
                ),
                attribution: .positive
            )
            self.activeEpoch = ActiveEpoch(descriptor: descriptor, windowID: windowID)
            return snapshot(descriptor: descriptor, candidate: candidate, windowID: windowID)
        }

        if mappedCameraOn.count > 1 {
            return MeetingSignalSnapshot(
                session: nil,
                windowID: nil,
                cameraActive: nil,
                videoSafe: false,
                status: .ambiguous("More than one camera-on meeting was found.")
            )
        }

        if joined.contains(where: { $0.mapping == .ambiguous }) {
            return MeetingSignalSnapshot(
                session: nil,
                windowID: nil,
                cameraActive: nil,
                videoSafe: false,
                status: .ambiguous("A meeting window was found, but it could not be mapped to one exact capture window.")
            )
        }

        if joined.contains(where: { $0.cameraActive == nil }) {
            return MeetingSignalSnapshot(
                session: nil,
                windowID: nil,
                cameraActive: nil,
                videoSafe: false,
                status: .ambiguous("A meeting was found, but its camera control state is unknown.")
            )
        }

        return MeetingSignalSnapshot(
            session: nil,
            windowID: nil,
            cameraActive: nil,
            videoSafe: false,
            status: .noSupportedMeeting
        )
    }

    private mutating func resolveActive(
        _ epoch: ActiveEpoch,
        candidates: [ClassifiedMeetingWindow],
        observation: MeetingAccessibilityObservation
    ) -> MeetingSignalSnapshot {
        let matching = candidates.first { candidate in
            candidate.window.bundleIdentifier == epoch.descriptor.sourceApplication.bundleIdentifier
                && candidate.mapping.windowID == epoch.windowID
        }

        if let matching {
            if matching.surfaceState == .ended || (matching.surfaceState == .joined && matching.cameraActive == false) {
                activeEpoch = nil
                return MeetingSignalSnapshot(
                    session: epoch.descriptor,
                    windowID: epoch.windowID,
                    cameraActive: false,
                    videoSafe: false,
                    status: .ready
                )
            }

            guard matching.surfaceState == .joined else {
                return retainedUnknown(status: .ambiguous("The active meeting surface is temporarily unproven."))
            }
            return snapshot(descriptor: epoch.descriptor, candidate: matching, windowID: epoch.windowID)
        }

        let cgWindowStillExists = observation.cgWindows.contains {
            $0.windowID == epoch.windowID
                && $0.ownerBundleIdentifier == epoch.descriptor.sourceApplication.bundleIdentifier
        }
        let axWindowStillExists = observation.accessibilityWindows.contains {
            $0.bundleIdentifier == epoch.descriptor.sourceApplication.bundleIdentifier
                && $0.axWindowNumber == epoch.windowID
        }
        if !observation.cgWindowListAvailable
            || observation.inaccessibleBundleIdentifiers.contains(epoch.descriptor.sourceApplication.bundleIdentifier)
            || axWindowStillExists {
            return retainedUnknown(status: .ambiguous("The active meeting surface is temporarily unproven."))
        }
        if !cgWindowStillExists {
            activeEpoch = nil
            return MeetingSignalSnapshot(
                session: epoch.descriptor,
                windowID: epoch.windowID,
                cameraActive: false,
                videoSafe: false,
                status: .ready
            )
        }

        return retainedUnknown(status: .ambiguous("The active meeting surface is temporarily unproven."))
    }

    private func snapshot(
        descriptor: MeetingSessionDescriptor,
        candidate: ClassifiedMeetingWindow,
        windowID: CGWindowID
    ) -> MeetingSignalSnapshot {
        if case .googleMeet = candidate.applicationKind {
            return MeetingSignalSnapshot(
                session: descriptor,
                windowID: windowID,
                cameraActive: candidate.cameraActive,
                videoSafe: false,
                status: .ambiguous("Chrome tab visibility is not guarded per frame.")
            )
        }

        if candidate.window.isMinimized {
            return MeetingSignalSnapshot(
                session: descriptor,
                windowID: windowID,
                cameraActive: candidate.cameraActive,
                videoSafe: false,
                status: .ambiguous("The meeting window is minimized, so video frames are unavailable.")
            )
        }

        return MeetingSignalSnapshot(
            session: descriptor,
            windowID: windowID,
            cameraActive: candidate.cameraActive,
            videoSafe: candidate.videoSafe,
            status: candidate.cameraActive == nil
                ? .ambiguous("A meeting was found, but its camera control state is unknown.")
                : .ready
        )
    }

    private func retainedUnknown(status: MeetingSignalStatus) -> MeetingSignalSnapshot {
        MeetingSignalSnapshot(
            session: activeEpoch?.descriptor,
            windowID: activeEpoch?.windowID,
            cameraActive: nil,
            videoSafe: false,
            status: status
        )
    }

    private static func surfaceID(windowID: CGWindowID) -> String {
        "cg-window:\(windowID)"
    }

    private static func windowID(from surfaceID: String) -> CGWindowID? {
        guard surfaceID.hasPrefix("cg-window:") else { return nil }
        return CGWindowID(surfaceID.dropFirst("cg-window:".count))
    }
}

/// The app owns polling cadence. `poll()` performs one bounded snapshot and
/// optionally emits the same value to a callback for a future event-driven host.
@MainActor
final class MeetingSignalProvider {
    typealias Handler = @Sendable (MeetingSignalSnapshot) -> Void

    private var resolver: MeetingSignalResolver
    private let onSnapshot: Handler?

    init(
        restoring session: MeetingSessionDescriptor? = nil,
        onSnapshot: Handler? = nil
    ) {
        resolver = MeetingSignalResolver(restoring: session)
        self.onSnapshot = onSnapshot
    }

    func restore(_ session: MeetingSessionDescriptor?) {
        resolver.restore(session)
    }

    @discardableResult
    func poll() -> MeetingSignalSnapshot {
        let snapshot = resolver.resolve(MeetingAccessibilityCollector.collect())
        onSnapshot?(snapshot)
        return snapshot
    }
}

private enum SurfaceState: Equatable, Sendable {
    case joined
    case prejoin
    case ended
    case ambiguous
}

private enum WindowMapping: Equatable, Sendable {
    case matched(CGWindowID)
    case missing
    case ambiguous

    var windowID: CGWindowID? {
        if case .matched(let windowID) = self { return windowID }
        return nil
    }
}

private struct ClassifiedMeetingWindow: Sendable {
    let window: AccessibilityWindowSnapshot
    let applicationKind: MeetingApplicationKind
    let surfaceState: SurfaceState
    let cameraActive: Bool?
    let mapping: WindowMapping
    let videoSafe: Bool
}

private struct ZoomMenuCameraEvidence: Sendable {
    let cameraActive: Bool?
}

private struct ZoomToolbarCameraEvidence: Sendable {
    let cameraActive: Bool?
    let isContradictory: Bool
}

private enum MeetingWindowClassifier {
    private static let bundleKinds: [String: MeetingApplicationKind] = [
        "com.google.Chrome": .googleMeet,
        "com.google.Chrome.beta": .googleMeet,
        "com.google.Chrome.canary": .googleMeet,
        "com.google.Chrome.dev": .googleMeet,
        "us.zoom.xos": .zoom,
        "com.microsoft.teams": .teams,
        "com.microsoft.teams2": .teams,
        "com.tinyspeck.slackmacgap": .slack,
    ]

    static func classify(
        _ window: AccessibilityWindowSnapshot,
        mapping: WindowMapping,
        applicationMenu: AccessibilityApplicationMenuSnapshot? = nil
    ) -> ClassifiedMeetingWindow? {
        guard let kind = bundleKinds[window.bundleIdentifier] else { return nil }

        let interactive = window.controls.filter {
            $0.isEnabled && ["axbutton", "axcheckbox", "axmenubutton", "axmenuitem", "axlink"]
                .contains($0.role.foldedForMeetingSignal)
        }
        let labels = interactive.map(\.searchableText)
        let helpLabels = interactive.compactMap { $0.help?.foldedForMeetingSignal }
        let allText = ([window.title] + window.controls.map(\.searchableText))
            .joined(separator: " ")
            .foldedForMeetingSignal

        let classification: (SurfaceState, Bool?)
        switch kind {
        case .googleMeet:
            classification = classifyMeet(window: window, labels: labels, allText: allText)
        case .zoom:
            classification = classifyZoom(
                window: window,
                labels: labels,
                helpLabels: helpLabels,
                allText: allText,
                menuEvidence: zoomMenuEvidence(applicationMenu)
            )
        case .teams:
            classification = classifyTeams(window: window, labels: labels, allText: allText)
        case .slack:
            classification = classifySlack(window: window, labels: labels, allText: allText)
        case .recordIt, .cameraPreview, .other:
            return nil
        }

        let isGoogleMeet: Bool
        switch kind {
        case .googleMeet: isGoogleMeet = true
        case .zoom, .teams, .slack, .recordIt, .cameraPreview, .other: isGoogleMeet = false
        }
        let videoSafe = classification.0 == .joined
            && mapping.windowID != nil
            && !window.isMinimized
            && !isGoogleMeet

        return ClassifiedMeetingWindow(
            window: window,
            applicationKind: kind,
            surfaceState: classification.0,
            cameraActive: classification.1,
            mapping: mapping,
            videoSafe: videoSafe
        )
    }

    private static func classifyMeet(
        window: AccessibilityWindowSnapshot,
        labels: [String],
        allText: String
    ) -> (SurfaceState, Bool?) {
        let hasMeetURL = window.controls.contains { control in
            guard let url = control.url, let components = URLComponents(string: url) else { return false }
            return components.scheme == "https"
                && components.host?.lowercased() == "meet.google.com"
                && components.path.split(separator: "/").first?.isEmpty == false
        }
        guard hasMeetURL else { return (.ambiguous, nil) }
        if containsAny(allText, ["you left the meeting", "return to home screen", "rejoin the meeting"]) {
            return (.ended, false)
        }
        let hasLeave = labels.containsAny(["leave call", "leave meeting"])
        let hasJoin = labels.containsAny(["join now", "ask to join", "join meeting"])
        if hasJoin && !hasLeave { return (.prejoin, nil) }
        guard hasLeave else { return (.ambiguous, nil) }
        return (.joined, cameraState(labels: labels, on: ["turn off camera"], off: ["turn on camera"]))
    }

    private static func classifyZoom(
        window: AccessibilityWindowSnapshot,
        labels: [String],
        helpLabels: [String],
        allText: String,
        menuEvidence: ZoomMenuCameraEvidence?
    ) -> (SurfaceState, Bool?) {
        if containsAny(allText, ["meeting ended", "you have left the meeting"]) { return (.ended, false) }
        let title = window.title.foldedForMeetingSignal
        let knownPreview = containsAny(title, ["video preview", "settings", "preferences", "join meeting"])
        let hasLeave = labels.containsAny(["leave", "leave meeting", "end", "end meeting"])
        let hasJoin = labels.containsAny(["join", "join meeting"])
        if knownPreview || (hasJoin && !hasLeave) { return (.prejoin, nil) }
        let toolbarCamera = zoomToolbarCameraEvidence(labels: labels, helpLabels: helpLabels)
        if hasLeave, containsAny(title, ["zoom meeting", "zoom webinar"]) {
            guard let menuEvidence else {
                return (.joined, toolbarCamera.isContradictory ? nil : toolbarCamera.cameraActive)
            }
            return (.joined, reconciledZoomCamera(toolbar: toolbarCamera, menu: menuEvidence))
        }
        guard title == "zoom meeting", let menuEvidence else { return (.ambiguous, nil) }
        return (.joined, reconciledZoomCamera(toolbar: toolbarCamera, menu: menuEvidence))
    }

    private static func zoomToolbarCameraEvidence(
        labels: [String],
        helpLabels: [String]
    ) -> ZoomToolbarCameraEvidence {
        let helpHasStop = helpLabels.containsAny(["stop video"])
        let helpHasStart = helpLabels.containsAny(["start video"])
        let preferredLabels = helpHasStop || helpHasStart ? helpLabels : labels
        let hasStop = preferredLabels.containsAny(["stop video"])
        let hasStart = preferredLabels.containsAny(["start video"])
        return ZoomToolbarCameraEvidence(
            cameraActive: hasStop == hasStart ? nil : hasStop,
            isContradictory: hasStop && hasStart
        )
    }

    private static func reconciledZoomCamera(
        toolbar: ZoomToolbarCameraEvidence,
        menu: ZoomMenuCameraEvidence
    ) -> Bool? {
        guard !toolbar.isContradictory, let menuCamera = menu.cameraActive else { return nil }
        guard toolbar.cameraActive == nil || toolbar.cameraActive == menuCamera else { return nil }
        return toolbar.cameraActive ?? menuCamera
    }

    private static func zoomMenuEvidence(
        _ applicationMenu: AccessibilityApplicationMenuSnapshot?
    ) -> ZoomMenuCameraEvidence? {
        guard let meetingMenu = applicationMenu?.menus.first(where: {
            $0.title.foldedForMeetingSignal == "meeting"
        }) else { return nil }
        let items = meetingMenu.items
            .filter(\.isEnabled)
            .map { $0.title.foldedForMeetingSignal }
        let hasStopVideo = items.contains("stop video")
        let hasStartVideo = items.contains("start video")
        guard hasStopVideo || hasStartVideo else { return nil }
        return ZoomMenuCameraEvidence(
            cameraActive: hasStopVideo == hasStartVideo ? nil : hasStopVideo
        )
    }

    private static func classifyTeams(
        window: AccessibilityWindowSnapshot,
        labels: [String],
        allText: String
    ) -> (SurfaceState, Bool?) {
        if containsAny(allText, ["meeting ended", "return to chat"]) { return (.ended, false) }
        let title = window.title.foldedForMeetingSignal
        let knownPreview = containsAny(title, ["pre-join", "prejoin", "device settings", "test call"])
        let hasLeave = labels.containsAny(["leave", "leave call", "leave meeting"])
        let hasJoin = labels.containsAny(["join now", "join meeting"])
        if knownPreview || (hasJoin && !hasLeave) { return (.prejoin, nil) }
        guard hasLeave else { return (.ambiguous, nil) }
        return (.joined, cameraState(
            labels: labels,
            on: ["turn camera off", "turn off camera"],
            off: ["turn camera on", "turn on camera"]
        ))
    }

    private static func classifySlack(
        window: AccessibilityWindowSnapshot,
        labels: [String],
        allText: String
    ) -> (SurfaceState, Bool?) {
        if containsAny(allText, ["huddle ended", "you left the huddle"]) { return (.ended, false) }
        let title = window.title.foldedForMeetingSignal
        if containsAny(title, ["preferences", "settings", "audio & video"]) { return (.prejoin, nil) }
        guard labels.containsAny(["leave huddle"]), containsAny(title, ["huddle", "call"]) else {
            return (.ambiguous, nil)
        }
        return (.joined, cameraState(
            labels: labels,
            on: ["turn off video", "stop video"],
            off: ["turn on video", "start video"]
        ))
    }

    private static func cameraState(labels: [String], on: [String], off: [String]) -> Bool? {
        let hasOn = labels.containsAny(on)
        let hasOff = labels.containsAny(off)
        guard hasOn != hasOff else { return nil }
        return hasOn
    }

    private static func containsAny(_ value: String, _ needles: [String]) -> Bool {
        needles.contains { value.contains($0) }
    }
}

private enum MeetingWindowMapper {
    static func map(
        _ window: AccessibilityWindowSnapshot,
        to cgWindows: [CGWindowSnapshot]
    ) -> WindowMapping {
        let sameProcess = cgWindows.filter {
            $0.ownerPID == window.processID
                && $0.ownerBundleIdentifier == window.bundleIdentifier
                && $0.layer == 0
        }

        if let number = window.axWindowNumber {
            return sameProcess.contains(where: { $0.windowID == number }) ? .matched(number) : .missing
        }

        let title = window.title.foldedForMeetingSignal
        let matches = sameProcess.filter { cgWindow in
            let titleMatches = !title.isEmpty && cgWindow.title.foldedForMeetingSignal == title
            let frameMatches = window.frame.flatMap { axFrame in
                cgWindow.frame.map { axFrame.approximatelyMatches($0) }
            } ?? false
            return titleMatches && frameMatches
        }

        if matches.count == 1, let match = matches.first { return .matched(match.windowID) }
        if matches.count > 1 { return .ambiguous }
        return .missing
    }
}

@MainActor
private enum MeetingAccessibilityCollector {
    private static let supportedBundleIDs: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.google.Chrome.canary",
        "com.google.Chrome.dev",
        "us.zoom.xos",
        "com.microsoft.teams",
        "com.microsoft.teams2",
        "com.tinyspeck.slackmacgap",
    ]

    private static let maxElementsPerWindow = 800
    private static let maxTreeDepth = 12
    private static let maxMenuElementsPerApplication = 80
    private static let maxMenuTreeDepth = 4
    private static let messagingTimeout: Float = 0.2

    static func collect() -> MeetingAccessibilityObservation {
        guard AXIsProcessTrusted() else {
            return MeetingAccessibilityObservation(
                accessibilityTrusted: false,
                accessibilityWindows: [],
                cgWindows: [],
                cgWindowListAvailable: false
            )
        }

        let applications = NSWorkspace.shared.runningApplications.filter {
            guard let bundleIdentifier = $0.bundleIdentifier else { return false }
            return supportedBundleIDs.contains(bundleIdentifier)
        }
        let bundleByPID = Dictionary(uniqueKeysWithValues: applications.compactMap { application in
            application.bundleIdentifier.map { (application.processIdentifier, $0) }
        })
        let cgWindowResult = collectCGWindows(bundleByPID: bundleByPID)
        var axWindows: [AccessibilityWindowSnapshot] = []
        var applicationMenus: [AccessibilityApplicationMenuSnapshot] = []
        var inaccessibleBundleIdentifiers: Set<String> = []
        for application in applications {
            guard let bundleIdentifier = application.bundleIdentifier else { continue }
            let appElement = AXUIElementCreateApplication(application.processIdentifier)
            AXUIElementSetMessagingTimeout(appElement, messagingTimeout)
            if let windows = collectAXWindows(application: application, appElement: appElement) {
                axWindows.append(contentsOf: windows)
            } else {
                inaccessibleBundleIdentifiers.insert(bundleIdentifier)
            }
            if bundleIdentifier == "us.zoom.xos",
               let menu = collectApplicationMenu(
                    processID: application.processIdentifier,
                    bundleIdentifier: bundleIdentifier,
                    appElement: appElement
               ) {
                applicationMenus.append(menu)
            }
        }

        return MeetingAccessibilityObservation(
            accessibilityTrusted: true,
            accessibilityWindows: axWindows,
            cgWindows: cgWindowResult ?? [],
            applicationMenus: applicationMenus,
            inaccessibleBundleIdentifiers: inaccessibleBundleIdentifiers,
            cgWindowListAvailable: cgWindowResult != nil
        )
    }

    private static func collectCGWindows(bundleByPID: [pid_t: String]) -> [CGWindowSnapshot]? {
        guard let raw = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[CFString: Any]] else { return nil }

        return raw.compactMap { info in
            guard let ownerPID = (info[kCGWindowOwnerPID] as? NSNumber)?.int32Value,
                  let bundleIdentifier = bundleByPID[ownerPID],
                  let windowID = (info[kCGWindowNumber] as? NSNumber)?.uint32Value else {
                return nil
            }

            let bounds = (info[kCGWindowBounds] as? [String: Any]).flatMap { dictionary -> SignalWindowFrame? in
                var rect = CGRect.zero
                guard CGRectMakeWithDictionaryRepresentation(dictionary as CFDictionary, &rect) else { return nil }
                return SignalWindowFrame(
                    x: rect.origin.x,
                    y: rect.origin.y,
                    width: rect.size.width,
                    height: rect.size.height
                )
            }

            return CGWindowSnapshot(
                windowID: windowID,
                ownerPID: ownerPID,
                ownerBundleIdentifier: bundleIdentifier,
                title: info[kCGWindowName] as? String ?? "",
                frame: bounds,
                isOnScreen: (info[kCGWindowIsOnscreen] as? NSNumber)?.boolValue ?? false,
                layer: (info[kCGWindowLayer] as? NSNumber)?.intValue ?? 0
            )
        }
    }

    private static func collectAXWindows(
        application: NSRunningApplication,
        appElement: AXUIElement
    ) -> [AccessibilityWindowSnapshot]? {
        guard let bundleIdentifier = application.bundleIdentifier else { return nil }
        guard let windows = elements(attribute: kAXWindowsAttribute as CFString, from: appElement) else { return nil }

        return windows.map { window in
            AccessibilityWindowSnapshot(
                processID: application.processIdentifier,
                bundleIdentifier: bundleIdentifier,
                applicationName: application.localizedName ?? bundleIdentifier,
                title: string(attribute: kAXTitleAttribute as CFString, from: window) ?? "",
                axWindowNumber: number(attribute: "AXWindowNumber" as CFString, from: window).map { CGWindowID($0.uint32Value) },
                frame: frame(from: window),
                isMinimized: boolean(attribute: kAXMinimizedAttribute as CFString, from: window) ?? false,
                controls: collectControls(from: window)
            )
        }
    }

    private static func collectApplicationMenu(
        processID: pid_t,
        bundleIdentifier: String,
        appElement: AXUIElement
    ) -> AccessibilityApplicationMenuSnapshot? {
        guard let menuBarValue = attribute(kAXMenuBarAttribute as CFString, from: appElement),
              CFGetTypeID(menuBarValue) == AXUIElementGetTypeID() else { return nil }
        let menuBar = menuBarValue as! AXUIElement
        guard
              let menuBarItems = elements(attribute: kAXChildrenAttribute as CFString, from: menuBar)
        else { return nil }

        var remaining = maxMenuElementsPerApplication
        let menus = menuBarItems.compactMap { menuBarItem -> AccessibilityMenuSnapshot? in
            guard remaining > 0 else { return nil }
            remaining -= 1
            guard let values = menuValues(from: menuBarItem) else { return nil }
            let title = string(from: values[1]) ?? ""
            guard title.foldedForMeetingSignal == "meeting" else { return nil }

            var stack = (elements(from: values[3]) ?? [])
                .reversed()
                .map { ($0, 0) }
            var items: [AccessibilityMenuItemSnapshot] = []
            while let (element, depth) = stack.popLast(), remaining > 0 {
                remaining -= 1
                guard let values = menuValues(from: element) else { continue }
                let role = string(from: values[0])?.foldedForMeetingSignal
                if role == (kAXMenuItemRole as String).foldedForMeetingSignal {
                    let itemTitle = string(from: values[1]) ?? ""
                    if !itemTitle.isEmpty {
                        items.append(AccessibilityMenuItemSnapshot(
                            title: itemTitle,
                            isEnabled: bool(from: values[2]) ?? true
                        ))
                    }
                }
                if depth < maxMenuTreeDepth,
                   let children = elements(from: values[3]) {
                    stack.append(contentsOf: children.reversed().map { ($0, depth + 1) })
                }
            }
            return AccessibilityMenuSnapshot(title: title, items: items)
        }
        guard !menus.isEmpty else { return nil }
        return AccessibilityApplicationMenuSnapshot(
            processID: processID,
            bundleIdentifier: bundleIdentifier,
            menus: menus
        )
    }

    private static func menuValues(from element: AXUIElement) -> [Any]? {
        let names: [CFString] = [
            kAXRoleAttribute as CFString,
            kAXTitleAttribute as CFString,
            kAXEnabledAttribute as CFString,
            kAXChildrenAttribute as CFString,
        ]
        var rawValues: CFArray?
        let status = AXUIElementCopyMultipleAttributeValues(
            element,
            names as CFArray,
            AXCopyMultipleAttributeOptions(rawValue: 0),
            &rawValues
        )
        guard status == .success,
              let values = rawValues as? [Any],
              values.count == names.count else { return nil }
        return values
    }

    private static func collectControls(from window: AXUIElement) -> [AccessibilityControlSnapshot] {
        var stack: [(AXUIElement, Int)] = [(window, 0)]
        var controls: [AccessibilityControlSnapshot] = []
        var visited = 0

        while let (element, depth) = stack.popLast(), visited < maxElementsPerWindow {
            visited += 1
            guard let values = controlValues(from: element) else { continue }
            if bool(from: values[0]) == true {
                continue
            }
            let role = string(from: values[1]) ?? ""
            let title = string(from: values[2]) ?? ""
            let description = string(from: values[3])
            let help = string(from: values[4])
            let value = string(from: values[5])
            let identifier = string(from: values[6])
            let url = string(from: values[7])
            let enabled = bool(from: values[8]) ?? true

            if !role.isEmpty || !title.isEmpty || description != nil || help != nil || value != nil || identifier != nil || url != nil {
                controls.append(AccessibilityControlSnapshot(
                    role: role,
                    title: title,
                    controlDescription: description,
                    help: help,
                    value: value,
                    identifier: identifier,
                    url: url,
                    isEnabled: enabled
                ))
            }

            if depth < maxTreeDepth,
               let children = elements(from: values[9]) ?? elements(from: values[10]) {
                stack.append(contentsOf: children.reversed().map { ($0, depth + 1) })
            }
        }

        return controls
    }

    /// One cross-process AX call per element is materially safer than fetching
    /// each attribute separately when an app is slow or hung.
    private static func controlValues(from element: AXUIElement) -> [Any]? {
        let names: [CFString] = [
            kAXHiddenAttribute as CFString,
            kAXRoleAttribute as CFString,
            kAXTitleAttribute as CFString,
            kAXDescriptionAttribute as CFString,
            kAXHelpAttribute as CFString,
            kAXValueAttribute as CFString,
            kAXIdentifierAttribute as CFString,
            kAXURLAttribute as CFString,
            kAXEnabledAttribute as CFString,
            kAXVisibleChildrenAttribute as CFString,
            kAXChildrenAttribute as CFString,
        ]
        var rawValues: CFArray?
        let status = AXUIElementCopyMultipleAttributeValues(
            element,
            names as CFArray,
            AXCopyMultipleAttributeOptions(rawValue: 0),
            &rawValues
        )
        guard status == .success,
              let values = rawValues as? [Any],
              values.count == names.count else { return nil }
        return values
    }

    private static func frame(from element: AXUIElement) -> SignalWindowFrame? {
        guard let positionValue = attribute(kAXPositionAttribute as CFString, from: element),
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              let sizeValue = attribute(kAXSizeAttribute as CFString, from: element),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }

        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return SignalWindowFrame(x: point.x, y: point.y, width: size.width, height: size.height)
    }

    private static func elements(attribute name: CFString, from element: AXUIElement) -> [AXUIElement]? {
        attribute(name, from: element) as? [AXUIElement]
    }

    private static func elements(from value: Any) -> [AXUIElement]? {
        value as? [AXUIElement]
    }

    private static func string(attribute name: CFString, from element: AXUIElement) -> String? {
        guard let value = attribute(name, from: element) else { return nil }
        return string(from: value)
    }

    private static func string(from value: Any) -> String? {
        if let string = value as? String { return string.truncatedForMeetingSignal }
        if let url = value as? URL { return url.absoluteString.truncatedForMeetingSignal }
        if let url = value as? NSURL { return url.absoluteString?.truncatedForMeetingSignal }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func number(attribute name: CFString, from element: AXUIElement) -> NSNumber? {
        attribute(name, from: element) as? NSNumber
    }

    private static func boolean(attribute name: CFString, from element: AXUIElement) -> Bool? {
        (attribute(name, from: element) as? NSNumber)?.boolValue
    }

    private static func bool(from value: Any) -> Bool? {
        (value as? NSNumber)?.boolValue
    }

    private static func attribute(_ name: CFString, from element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
        return value
    }
}

private extension Array where Element == String {
    func containsAny(_ needles: [String]) -> Bool {
        contains { value in needles.contains { value.contains($0) } }
    }
}

private extension String {
    var foldedForMeetingSignal: String {
        folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    var truncatedForMeetingSignal: String {
        count <= 256 ? self : String(prefix(256))
    }

    var nilIfEmpty: String? { isEmpty ? nil : self }
}

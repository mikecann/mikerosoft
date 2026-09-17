import CoreGraphics
import XCTest
@testable import MeetingArchiveApp

final class MeetingSignalProviderTests: XCTestCase {
    func testMeetJoinedCameraOnIsAttributedButVideoFailsClosed() throws {
        var resolver = MeetingSignalResolver()
        let result = resolver.resolve(observation(
            ax: [window(
                app: .chrome,
                title: "Daily sync - Google Meet - Google Chrome",
                number: 101,
                controls: [
                    control(role: "AXWebArea", title: "Meet", url: "https://meet.google.com/abc-defg-hij"),
                    control(title: "Leave call"),
                    control(title: "Turn off camera"),
                ]
            )],
            cg: [cgWindow(id: 101, app: .chrome, title: "Daily sync - Google Meet - Google Chrome")]
        ))

        XCTAssertEqual(result.session?.sourceApplication.kind, .googleMeet)
        XCTAssertEqual(result.windowID, 101)
        XCTAssertEqual(result.cameraActive, true)
        XCTAssertFalse(result.videoSafe, "polling cannot stop unrelated Chrome-tab frames before they leak")
        XCTAssertEqual(result.status, .ambiguous("Chrome tab visibility is not guarded per frame."))
    }

    func testMeetPrejoinCameraPreviewIsExcluded() {
        var resolver = MeetingSignalResolver()
        let result = resolver.resolve(observation(
            ax: [window(
                app: .chrome,
                title: "Ready to join? - Google Meet - Google Chrome",
                number: 102,
                controls: [
                    control(role: "AXWebArea", title: "Meet", url: "https://meet.google.com/abc-defg-hij"),
                    control(title: "Join now"),
                    control(title: "Turn off camera"),
                ]
            )],
            cg: [cgWindow(id: 102, app: .chrome, title: "Ready to join? - Google Meet - Google Chrome")]
        ))

        XCTAssertNil(result.session)
        XCTAssertNil(result.cameraActive)
        XCTAssertFalse(result.videoSafe)
        XCTAssertEqual(result.status, .noSupportedMeeting)
    }

    func testMeetTabSwitchBecomesUnknownRatherThanCameraOff() throws {
        var resolver = MeetingSignalResolver()
        let joined = resolver.resolve(observation(
            ax: [window(
                app: .chrome,
                title: "Daily sync - Google Meet - Google Chrome",
                number: 103,
                controls: [
                    control(role: "AXWebArea", title: "Meet", url: "https://meet.google.com/abc-defg-hij"),
                    control(title: "Leave call"),
                    control(title: "Turn off camera"),
                ]
            )],
            cg: [cgWindow(id: 103, app: .chrome, title: "Daily sync - Google Meet - Google Chrome")]
        ))

        let switched = resolver.resolve(observation(
            ax: [window(
                app: .chrome,
                title: "Inbox - Google Chrome",
                number: 103,
                controls: [control(role: "AXWebArea", title: "Inbox", url: "https://mail.google.com/")]
            )],
            cg: [cgWindow(id: 103, app: .chrome, title: "Inbox - Google Chrome")]
        ))

        XCTAssertEqual(switched.session?.id, joined.session?.id)
        XCTAssertNil(switched.cameraActive)
        XCTAssertFalse(switched.videoSafe)
        XCTAssertEqual(switched.status, .ambiguous("The active meeting surface is temporarily unproven."))
    }

    func testExplicitCameraOffEndsEpochAndLaterOnUsesNewID() throws {
        var resolver = MeetingSignalResolver()
        let on = resolver.resolve(zoomObservation(cameraControl: "Stop Video"))
        let off = resolver.resolve(zoomObservation(cameraControl: "Start Video"))
        let stillOff = resolver.resolve(zoomObservation(cameraControl: "Start Video"))
        let onAgain = resolver.resolve(zoomObservation(cameraControl: "Stop Video"))

        XCTAssertEqual(off.session?.id, on.session?.id)
        XCTAssertEqual(off.cameraActive, false)
        XCTAssertNil(stillOff.session, "an off edge should be emitted once")
        XCTAssertNotEqual(onAgain.session?.id, on.session?.id)
        XCTAssertEqual(onAgain.cameraActive, true)
    }

    func testClosedNativeMeetingWindowEmitsOffButPermissionLossDoesNot() throws {
        var closedResolver = MeetingSignalResolver()
        let active = closedResolver.resolve(zoomObservation(cameraControl: "Stop Video"))
        let closed = closedResolver.resolve(observation(
            ax: [window(app: .zoom, title: "Zoom Workplace", number: 205, controls: [])],
            cg: [cgWindow(id: 205, app: .zoom, title: "Zoom Workplace")]
        ))

        XCTAssertEqual(closed.session?.id, active.session?.id)
        XCTAssertEqual(closed.cameraActive, false)

        var deniedResolver = MeetingSignalResolver()
        let deniedActive = deniedResolver.resolve(zoomObservation(cameraControl: "Stop Video"))
        let denied = deniedResolver.resolve(MeetingAccessibilityObservation(
            accessibilityTrusted: false,
            accessibilityWindows: [],
            cgWindows: []
        ))

        XCTAssertEqual(denied.session?.id, deniedActive.session?.id)
        XCTAssertNil(denied.cameraActive)
        XCTAssertEqual(denied.status, .accessibilityPermissionRequired)

        var stalledResolver = MeetingSignalResolver()
        let stalledActive = stalledResolver.resolve(zoomObservation(cameraControl: "Stop Video"))
        let stalled = stalledResolver.resolve(MeetingAccessibilityObservation(
            accessibilityTrusted: true,
            accessibilityWindows: [],
            cgWindows: [],
            inaccessibleBundleIdentifiers: ["us.zoom.xos"]
        ))

        XCTAssertEqual(stalled.session?.id, stalledActive.session?.id)
        XCTAssertNil(stalled.cameraActive)
        XCTAssertEqual(stalled.status, .ambiguous("The active meeting surface is temporarily unproven."))
    }

    func testZoomPreviewAndJoinWindowAreExcluded() {
        var resolver = MeetingSignalResolver()
        let result = resolver.resolve(observation(
            ax: [window(
                app: .zoom,
                title: "Video Preview",
                number: 202,
                controls: [control(title: "Join Meeting"), control(title: "Stop Video")]
            )],
            cg: [cgWindow(id: 202, app: .zoom, title: "Video Preview")]
        ))

        XCTAssertNil(result.session)
        XCTAssertNil(result.cameraActive)
        XCTAssertEqual(result.status, .noSupportedMeeting)
    }

    func testZoomMeetingMenuKeepsCameraOnWhenToolbarIsHidden() {
        var resolver = MeetingSignalResolver()
        let result = resolver.resolve(zoomMenuObservation(
            item: "Stop video",
            windows: [window(
                app: .zoom,
                title: "Zoom Meeting",
                number: 201,
                controls: [control(role: "AXStaticText", title: "Video render Mike Cann, Computer audio unmuted")]
            )]
        ))

        XCTAssertEqual(result.windowID, 201)
        XCTAssertEqual(result.cameraActive, true)
        XCTAssertEqual(result.session?.sourceApplication.kind, .zoom)
        XCTAssertTrue(result.videoSafe)
    }

    func testZoomMeetingMenuEmitsCameraOffAfterToolbarHides() throws {
        var resolver = MeetingSignalResolver()
        let active = resolver.resolve(zoomMenuObservation(
            item: "Stop video",
            windows: [window(
                app: .zoom,
                title: "Zoom Meeting",
                number: 201,
                controls: [control(role: "AXStaticText", title: "Video render Mike Cann, Computer audio unmuted")]
            )]
        ))
        let stopped = resolver.resolve(zoomMenuObservation(
            item: "Start video",
            windows: [window(
                app: .zoom,
                title: "Zoom Meeting",
                number: 201,
                controls: [control(role: "AXStaticText", title: "Video render Mike Cann, Computer audio unmuted")]
            )]
        ))

        XCTAssertNotNil(active.session)
        XCTAssertEqual(stopped.session?.id, active.session?.id)
        XCTAssertEqual(stopped.cameraActive, false)
    }

    func testZoomMenuNeverQualifiesPreviewHomeOrAmbiguousWindows() {
        for windows in [
            [window(
                app: .zoom,
                title: "Mike Cann's Zoom Meeting",
                number: 202,
                controls: [control(title: "Start"), control(title: "Video turn off currently on")]
            )],
            [window(app: .zoom, title: "Zoom Workplace", number: 203, controls: [])],
            [
                window(app: .zoom, title: "Zoom Meeting", number: 204, controls: []),
                window(app: .zoom, title: "Zoom Meeting", number: 205, controls: []),
            ],
        ] {
            var resolver = MeetingSignalResolver()
            let result = resolver.resolve(zoomMenuObservation(item: "Stop video", windows: windows))

            XCTAssertNil(result.session, "Global menu evidence leaked onto a non-unique joined surface")
            XCTAssertNil(result.cameraActive)
        }
    }

    func testConflictingZoomToolbarAndMenuCameraActionsFailClosed() {
        var resolver = MeetingSignalResolver()
        let result = resolver.resolve(zoomMenuObservation(
            item: "Start video",
            windows: [window(
                app: .zoom,
                title: "Zoom Meeting",
                number: 201,
                controls: [control(title: "Leave"), control(title: "Stop Video")]
            )]
        ))

        XCTAssertNil(result.session)
        XCTAssertNil(result.cameraActive)
        XCTAssertEqual(result.status, .ambiguous("A meeting was found, but its camera control state is unknown."))
    }

    func testZoomHelpStopVideoOverridesStaleStartVideoDescription() {
        var resolver = MeetingSignalResolver()
        let result = resolver.resolve(zoomMenuObservation(
            item: "Stop video",
            windows: [window(
                app: .zoom,
                title: "Zoom Meeting",
                number: 201,
                controls: [
                    control(title: "Leave"),
                    control(
                        title: "",
                        description: "Start video",
                        help: "Stop video (⇧⌘V)",
                        identifier: "video"
                    ),
                ]
            )]
        ))

        XCTAssertEqual(result.cameraActive, true)
        XCTAssertTrue(result.videoSafe)
    }

    func testZoomHelpStartVideoOverridesStaleStopVideoDescription() {
        var resolver = MeetingSignalResolver()
        let active = resolver.resolve(zoomMenuObservation(
            item: "Stop video",
            windows: [window(
                app: .zoom,
                title: "Zoom Meeting",
                number: 201,
                controls: [control(title: "Leave"), control(title: "", help: "Stop video (⇧⌘V)")]
            )]
        ))
        let stopped = resolver.resolve(zoomMenuObservation(
            item: "Start video",
            windows: [window(
                app: .zoom,
                title: "Zoom Meeting",
                number: 201,
                controls: [
                    control(title: "Leave"),
                    control(
                        title: "",
                        description: "Stop video",
                        help: "Start video (⇧⌘V)",
                        identifier: "video"
                    ),
                ]
            )]
        ))

        XCTAssertEqual(stopped.session?.id, active.session?.id)
        XCTAssertEqual(stopped.cameraActive, false)
    }

    func testZoomMissingHelpFallsBackToVisibleControlAction() {
        var resolver = MeetingSignalResolver()
        let result = resolver.resolve(zoomMenuObservation(
            item: "Stop video",
            windows: [window(
                app: .zoom,
                title: "Zoom Meeting",
                number: 201,
                controls: [control(title: "Leave"), control(title: "", description: "Stop video")]
            )]
        ))

        XCTAssertEqual(result.cameraActive, true)
        XCTAssertTrue(result.videoSafe)
    }

    func testZoomHelpCameraActionCannotQualifyPreview() {
        var resolver = MeetingSignalResolver()
        let result = resolver.resolve(zoomMenuObservation(
            item: "Stop video",
            windows: [window(
                app: .zoom,
                title: "Video Preview",
                number: 202,
                controls: [
                    control(title: "Join Meeting"),
                    control(title: "", description: "Start video", help: "Stop video (⇧⌘V)"),
                ]
            )]
        ))

        XCTAssertNil(result.session)
        XCTAssertNil(result.cameraActive)
        XCTAssertFalse(result.videoSafe)
    }

    func testTeamsJoinedCameraOffIsExplicit() {
        var resolver = MeetingSignalResolver()
        let result = resolver.resolve(observation(
            ax: [window(
                app: .teams,
                title: "Weekly planning | Microsoft Teams",
                number: 301,
                controls: [control(title: "Leave"), control(title: "Turn camera on")]
            )],
            cg: [cgWindow(id: 301, app: .teams, title: "Weekly planning | Microsoft Teams")]
        ))

        XCTAssertNil(result.session, "an initially camera-off call is not a camera session")
        XCTAssertNil(result.cameraActive, "without an active epoch there is no off edge to emit")
        XCTAssertEqual(result.status, .noSupportedMeeting)
    }

    func testSlackUnknownCameraLabelFailsClosed() {
        var resolver = MeetingSignalResolver()
        let result = resolver.resolve(observation(
            ax: [window(
                app: .slack,
                title: "Engineering huddle",
                number: 401,
                controls: [control(title: "Leave huddle"), control(title: "Camera")]
            )],
            cg: [cgWindow(id: 401, app: .slack, title: "Engineering huddle")]
        ))

        XCTAssertNil(result.session)
        XCTAssertNil(result.cameraActive)
        XCTAssertFalse(result.videoSafe)
        XCTAssertEqual(result.status, .ambiguous("A meeting was found, but its camera control state is unknown."))
    }

    func testAmbiguousAXToCGMappingFailsClosed() {
        var resolver = MeetingSignalResolver()
        let axWindow = window(
            app: .zoom,
            title: "Zoom Meeting",
            number: nil,
            controls: [control(title: "Leave"), control(title: "Stop Video")]
        )
        let duplicate = cgWindow(id: 501, app: .zoom, title: "Zoom Meeting")
        let result = resolver.resolve(observation(
            ax: [axWindow],
            cg: [duplicate, CGWindowSnapshot(
                windowID: 502,
                ownerPID: duplicate.ownerPID,
                ownerBundleIdentifier: duplicate.ownerBundleIdentifier,
                title: duplicate.title,
                frame: duplicate.frame,
                isOnScreen: duplicate.isOnScreen,
                layer: duplicate.layer
            )]
        ))

        XCTAssertNil(result.session)
        XCTAssertNil(result.windowID)
        XCTAssertEqual(result.status, .ambiguous("A meeting window was found, but it could not be mapped to one exact capture window."))
    }

    func testRestoredDescriptorKeepsEpochIDForSameWindow() throws {
        var first = MeetingSignalResolver()
        let initial = first.resolve(zoomObservation(cameraControl: "Stop Video"))
        let descriptor = try XCTUnwrap(initial.session)
        var restored = MeetingSignalResolver(restoring: descriptor)
        let afterRestart = restored.resolve(zoomObservation(cameraControl: "Stop Video"))

        XCTAssertEqual(afterRestart.session?.id, descriptor.id)
        XCTAssertEqual(afterRestart.windowID, 201)
        XCTAssertEqual(afterRestart.cameraActive, true)
    }

    func testMinimizedNativeWindowRetainsCameraStateButBlocksVideo() {
        var resolver = MeetingSignalResolver()
        let result = resolver.resolve(observation(
            ax: [window(
                app: .zoom,
                title: "Zoom Meeting",
                number: 201,
                minimized: true,
                controls: [control(title: "Leave"), control(title: "Stop Video")]
            )],
            cg: [cgWindow(id: 201, app: .zoom, title: "Zoom Meeting", isOnScreen: false)]
        ))

        XCTAssertEqual(result.cameraActive, true)
        XCTAssertFalse(result.videoSafe)
        XCTAssertEqual(result.status, .ambiguous("The meeting window is minimized, so video frames are unavailable."))
    }
}

private extension MeetingSignalProviderTests {
    enum AppFixture {
        case chrome, zoom, teams, slack

        var pid: pid_t {
            switch self {
            case .chrome: 1_001
            case .zoom: 1_002
            case .teams: 1_003
            case .slack: 1_004
            }
        }

        var bundleID: String {
            switch self {
            case .chrome: "com.google.Chrome"
            case .zoom: "us.zoom.xos"
            case .teams: "com.microsoft.teams2"
            case .slack: "com.tinyspeck.slackmacgap"
            }
        }

        var name: String {
            switch self {
            case .chrome: "Google Chrome"
            case .zoom: "zoom.us"
            case .teams: "Microsoft Teams"
            case .slack: "Slack"
            }
        }
    }

    func control(
        role: String = "AXButton",
        title: String,
        description: String? = nil,
        help: String? = nil,
        value: String? = nil,
        identifier: String? = nil,
        url: String? = nil
    ) -> AccessibilityControlSnapshot {
        AccessibilityControlSnapshot(
            role: role,
            title: title,
            controlDescription: description,
            help: help,
            value: value,
            identifier: identifier,
            url: url,
            isEnabled: true
        )
    }

    func window(
        app: AppFixture,
        title: String,
        number: CGWindowID?,
        minimized: Bool = false,
        controls: [AccessibilityControlSnapshot]
    ) -> AccessibilityWindowSnapshot {
        AccessibilityWindowSnapshot(
            processID: app.pid,
            bundleIdentifier: app.bundleID,
            applicationName: app.name,
            title: title,
            axWindowNumber: number,
            frame: SignalWindowFrame(x: 100, y: 100, width: 1200, height: 800),
            isMinimized: minimized,
            controls: controls
        )
    }

    func cgWindow(
        id: CGWindowID,
        app: AppFixture,
        title: String,
        isOnScreen: Bool = true
    ) -> CGWindowSnapshot {
        CGWindowSnapshot(
            windowID: id,
            ownerPID: app.pid,
            ownerBundleIdentifier: app.bundleID,
            title: title,
            frame: SignalWindowFrame(x: 100, y: 100, width: 1200, height: 800),
            isOnScreen: isOnScreen,
            layer: 0
        )
    }

    func observation(
        ax: [AccessibilityWindowSnapshot],
        cg: [CGWindowSnapshot],
        menus: [AccessibilityApplicationMenuSnapshot] = []
    ) -> MeetingAccessibilityObservation {
        MeetingAccessibilityObservation(
            accessibilityTrusted: true,
            accessibilityWindows: ax,
            cgWindows: cg,
            applicationMenus: menus
        )
    }

    func zoomMenuObservation(
        item: String,
        windows: [AccessibilityWindowSnapshot]
    ) -> MeetingAccessibilityObservation {
        observation(
            ax: windows,
            cg: windows.enumerated().map { offset, window in
                cgWindow(
                    id: window.axWindowNumber ?? CGWindowID(900 + offset),
                    app: .zoom,
                    title: window.title
                )
            },
            menus: [AccessibilityApplicationMenuSnapshot(
                processID: AppFixture.zoom.pid,
                bundleIdentifier: AppFixture.zoom.bundleID,
                menus: [AccessibilityMenuSnapshot(
                    title: "Meeting",
                    items: [AccessibilityMenuItemSnapshot(title: item, isEnabled: true)]
                )]
            )]
        )
    }

    func zoomObservation(cameraControl: String) -> MeetingAccessibilityObservation {
        observation(
            ax: [window(
                app: .zoom,
                title: "Zoom Meeting",
                number: 201,
                controls: [control(title: "Leave"), control(title: cameraControl)]
            )],
            cg: [cgWindow(id: 201, app: .zoom, title: "Zoom Meeting")]
        )
    }
}

import Foundation

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: String,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    guard condition() else {
        throw TestFailure(description: "\(file):\(line): \(message)")
    }
}

private func observation(
    bundleID: String,
    appName: String,
    title: String?,
    isOnScreen: Bool = true
) -> WindowObservation {
    WindowObservation(
        windowID: 42,
        bundleIdentifier: bundleID,
        applicationName: appName,
        title: title,
        layer: 0,
        isOnScreen: isOnScreen,
        x: 10,
        y: 20,
        width: 1280,
        height: 720
    )
}

@main
struct CandidateRulesTests {
    static func main() throws {
        try meetWindowIsOnlyAHeuristicCandidate()
        try chromeCameraPreviewIsNotMistakenForMeet()
        try zoomMeetingAndPreviewAreSeparated()
        try teamsRulesKeepGenericWindowAmbiguous()
        try slackHuddleAndSettingsAreSeparated()
        try unrelatedAppsAreIgnored()
        try offscreenCandidateCarriesCaptureWarning()
        print("CandidateRulesTests: 7 passed")
    }

    private static func meetWindowIsOnlyAHeuristicCandidate() throws {
        let result = MeetingSurfaceRules.assess(observation(
            bundleID: "com.google.Chrome",
            appName: "Google Chrome",
            title: "Daily sync - Google Meet - Google Chrome"
        ))

        try expect(result.supportedApp == .googleMeetChrome, "expected Chrome Meet adapter")
        try expect(result.disposition == .candidate, "expected a candidate surface")
        try expect(result.evidence == .applicationIdentityAndTitleHeuristic, "title must stay labelled heuristic")
        try expect(result.safeForAutomaticTrigger == false, "a Meet-looking title cannot prove joined-call state")
        try expect(result.limitations.contains(where: { $0.contains("pre-join") }), "must disclose pre-join ambiguity")
    }

    private static func chromeCameraPreviewIsNotMistakenForMeet() throws {
        let result = MeetingSurfaceRules.assess(observation(
            bundleID: "com.google.Chrome",
            appName: "Google Chrome",
            title: "Webcam test - Google Chrome"
        ))

        try expect(result.supportedApp == .googleMeetChrome, "Chrome is a supported host app")
        try expect(result.disposition == .ambiguous, "an arbitrary Chrome camera page is not a Meet surface")
        try expect(result.safeForAutomaticTrigger == false, "Chrome identity cannot establish camera ownership")
    }

    private static func zoomMeetingAndPreviewAreSeparated() throws {
        let meeting = MeetingSurfaceRules.assess(observation(
            bundleID: "us.zoom.xos",
            appName: "zoom.us",
            title: "Zoom Meeting"
        ))
        let preview = MeetingSurfaceRules.assess(observation(
            bundleID: "us.zoom.xos",
            appName: "zoom.us",
            title: "Video Preview"
        ))

        try expect(meeting.disposition == .candidate, "Zoom Meeting should be a candidate")
        try expect(meeting.safeForAutomaticTrigger == false, "window title still does not prove camera ownership")
        try expect(preview.disposition == .excluded, "Zoom Video Preview must be excluded")
    }

    private static func teamsRulesKeepGenericWindowAmbiguous() throws {
        let meeting = MeetingSurfaceRules.assess(observation(
            bundleID: "com.microsoft.teams2",
            appName: "Microsoft Teams",
            title: "Weekly planning | Meeting | Microsoft Teams"
        ))
        let generic = MeetingSurfaceRules.assess(observation(
            bundleID: "com.microsoft.teams2",
            appName: "Microsoft Teams",
            title: "Microsoft Teams"
        ))

        try expect(meeting.disposition == .candidate, "meeting-labelled Teams window should be a candidate")
        try expect(generic.disposition == .ambiguous, "generic Teams window must stay ambiguous")
    }

    private static func slackHuddleAndSettingsAreSeparated() throws {
        let huddle = MeetingSurfaceRules.assess(observation(
            bundleID: "com.tinyspeck.slackmacgap",
            appName: "Slack",
            title: "Huddle | #engineering | Slack"
        ))
        let settings = MeetingSurfaceRules.assess(observation(
            bundleID: "com.tinyspeck.slackmacgap",
            appName: "Slack",
            title: "Preferences"
        ))

        try expect(huddle.disposition == .candidate, "Slack Huddle should be a candidate")
        try expect(settings.disposition == .excluded, "Slack preferences must be excluded")
    }

    private static func unrelatedAppsAreIgnored() throws {
        let result = MeetingSurfaceRules.assess(observation(
            bundleID: "com.apple.TextEdit",
            appName: "TextEdit",
            title: "Notes"
        ))

        try expect(result.supportedApp == nil, "unrelated app must not get a supported-app identity")
        try expect(result.disposition == .unrelated, "unrelated app should be ignored")
        try expect(result.evidence == .none, "unrelated app should have no meeting evidence")
    }

    private static func offscreenCandidateCarriesCaptureWarning() throws {
        let result = MeetingSurfaceRules.assess(observation(
            bundleID: "us.zoom.xos",
            appName: "zoom.us",
            title: "Zoom Meeting",
            isOnScreen: false
        ))

        try expect(result.disposition == .candidate, "visibility should not erase surface identity")
        try expect(result.limitations.contains(where: { $0.contains("offscreen") }), "offscreen surface needs an explicit capture warning")
    }
}

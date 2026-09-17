import Foundation

struct WindowObservation: Codable, Equatable {
    let windowID: UInt32
    let bundleIdentifier: String
    let applicationName: String
    let title: String?
    let layer: Int
    let isOnScreen: Bool
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

enum SupportedMeetingApp: String, Codable, CaseIterable {
    case googleMeetChrome = "google-meet-chrome"
    case zoom
    case teams
    case slack
}

enum CandidateDisposition: String, Codable {
    case candidate
    case ambiguous
    case excluded
    case unrelated
}

enum EvidenceLevel: String, Codable {
    case applicationIdentityAndTitleHeuristic = "application-identity-plus-title-heuristic"
    case applicationIdentityOnly = "application-identity-only"
    case none
}

struct CandidateAssessment: Codable, Equatable {
    let supportedApp: SupportedMeetingApp?
    let disposition: CandidateDisposition
    let evidence: EvidenceLevel
    let safeForAutomaticTrigger: Bool
    let matchedRules: [String]
    let limitations: [String]
}

enum MeetingSurfaceRules {
    private static let chromeBundleIDs: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.google.Chrome.canary",
        "com.google.Chrome.dev",
    ]

    private static let zoomBundleIDs: Set<String> = [
        "us.zoom.xos",
    ]

    private static let teamsBundleIDs: Set<String> = [
        "com.microsoft.teams",
        "com.microsoft.teams2",
    ]

    private static let slackBundleIDs: Set<String> = [
        "com.tinyspeck.slackmacgap",
    ]

    static func assess(_ window: WindowObservation) -> CandidateAssessment {
        guard let app = supportedApp(bundleIdentifier: window.bundleIdentifier) else {
            return CandidateAssessment(
                supportedApp: nil,
                disposition: .unrelated,
                evidence: .none,
                safeForAutomaticTrigger: false,
                matchedRules: [],
                limitations: []
            )
        }

        let title = normalized(window.title)
        var assessment: CandidateAssessment

        switch app {
        case .googleMeetChrome:
            assessment = assessChrome(title: title)
        case .zoom:
            assessment = assessZoom(title: title)
        case .teams:
            assessment = assessTeams(title: title)
        case .slack:
            assessment = assessSlack(title: title)
        }

        guard !window.isOnScreen, assessment.disposition != .unrelated else {
            return assessment
        }

        return CandidateAssessment(
            supportedApp: assessment.supportedApp,
            disposition: assessment.disposition,
            evidence: assessment.evidence,
            safeForAutomaticTrigger: assessment.safeForAutomaticTrigger,
            matchedRules: assessment.matchedRules,
            limitations: assessment.limitations + [
                "ScreenCaptureKit reports this window as offscreen. That can mean minimized, on another Space, or otherwise unavailable; inventory alone cannot distinguish those states or prove usable frames."
            ]
        )
    }

    static func supportedApp(bundleIdentifier: String) -> SupportedMeetingApp? {
        if chromeBundleIDs.contains(bundleIdentifier) { return .googleMeetChrome }
        if zoomBundleIDs.contains(bundleIdentifier) { return .zoom }
        if teamsBundleIDs.contains(bundleIdentifier) { return .teams }
        if slackBundleIDs.contains(bundleIdentifier) { return .slack }
        return nil
    }

    private static func assessChrome(title: String) -> CandidateAssessment {
        if containsAny(title, ["google meet", "meet.google.com"]) {
            return assessment(
                app: .googleMeetChrome,
                disposition: .candidate,
                evidence: .applicationIdentityAndTitleHeuristic,
                rules: ["exact Chrome bundle identifier", "title contains 'Google Meet' or 'meet.google.com'"],
                limitations: [
                    "The title is a heuristic. It does not distinguish a Meet pre-join screen from a joined call.",
                    "ScreenCaptureKit identifies the Chrome window, not its active tab or URL. Switching tabs can expose unrelated content unless a separate browser adapter suppresses frames.",
                ]
            )
        }

        return assessment(
            app: .googleMeetChrome,
            disposition: .ambiguous,
            evidence: .applicationIdentityOnly,
            rules: ["exact Chrome bundle identifier"],
            limitations: [
                "A Chrome process can host Meet, a camera-test page, and unrelated tabs at the same time. Its identity is not meeting evidence.",
            ]
        )
    }

    private static func assessZoom(title: String) -> CandidateAssessment {
        if containsAny(title, ["video preview", "settings", "preferences", "join meeting"]) {
            return assessment(
                app: .zoom,
                disposition: .excluded,
                evidence: .applicationIdentityAndTitleHeuristic,
                rules: ["exact Zoom bundle identifier", "known preview/settings/pre-join title"],
                limitations: [
                    "This exclusion is title-based and must be rechecked when Zoom changes its UI or localization.",
                ]
            )
        }

        if containsAny(title, ["zoom meeting", "zoom webinar"]) {
            return assessment(
                app: .zoom,
                disposition: .candidate,
                evidence: .applicationIdentityAndTitleHeuristic,
                rules: ["exact Zoom bundle identifier", "title contains 'Zoom Meeting' or 'Zoom Webinar'"],
                limitations: [
                    "The window title does not prove joined-call state, outgoing-camera state, or camera ownership.",
                ]
            )
        }

        return assessment(
            app: .zoom,
            disposition: .ambiguous,
            evidence: .applicationIdentityOnly,
            rules: ["exact Zoom bundle identifier"],
            limitations: [
                "A generic Zoom window may be the launcher, chat, a preview, or a call surface.",
            ]
        )
    }

    private static func assessTeams(title: String) -> CandidateAssessment {
        if containsAny(title, ["device settings", "settings", "test call", "pre-join", "prejoin"]) {
            return assessment(
                app: .teams,
                disposition: .excluded,
                evidence: .applicationIdentityAndTitleHeuristic,
                rules: ["exact Teams bundle identifier", "known settings/test/pre-join title"],
                limitations: [
                    "This exclusion is title-based and must be rechecked across Teams versions and localizations.",
                ]
            )
        }

        if containsAny(title, ["meeting", "call"]) && title != "microsoft teams" {
            return assessment(
                app: .teams,
                disposition: .candidate,
                evidence: .applicationIdentityAndTitleHeuristic,
                rules: ["exact Teams bundle identifier", "title contains 'meeting' or 'call'"],
                limitations: [
                    "Teams window titles are UI heuristics and do not prove joined-call or outgoing-camera state.",
                ]
            )
        }

        return assessment(
            app: .teams,
            disposition: .ambiguous,
            evidence: .applicationIdentityOnly,
            rules: ["exact Teams bundle identifier"],
            limitations: [
                "The generic Teams shell cannot be separated from a call using application identity alone.",
            ]
        )
    }

    private static func assessSlack(title: String) -> CandidateAssessment {
        if containsAny(title, ["preferences", "settings", "audio & video"]) {
            return assessment(
                app: .slack,
                disposition: .excluded,
                evidence: .applicationIdentityAndTitleHeuristic,
                rules: ["exact Slack bundle identifier", "known settings title"],
                limitations: [
                    "This exclusion is title-based and must be rechecked when Slack changes its UI or localization.",
                ]
            )
        }

        if containsAny(title, ["huddle", "call"]) {
            return assessment(
                app: .slack,
                disposition: .candidate,
                evidence: .applicationIdentityAndTitleHeuristic,
                rules: ["exact Slack bundle identifier", "title contains 'huddle' or 'call'"],
                limitations: [
                    "A Huddle-looking window does not establish joined state, camera-on state, or camera ownership.",
                ]
            )
        }

        return assessment(
            app: .slack,
            disposition: .ambiguous,
            evidence: .applicationIdentityOnly,
            rules: ["exact Slack bundle identifier"],
            limitations: [
                "The generic Slack shell does not reveal whether a Huddle is active.",
            ]
        )
    }

    private static func assessment(
        app: SupportedMeetingApp,
        disposition: CandidateDisposition,
        evidence: EvidenceLevel,
        rules: [String],
        limitations: [String]
    ) -> CandidateAssessment {
        CandidateAssessment(
            supportedApp: app,
            disposition: disposition,
            evidence: evidence,
            // None of these passive rules attributes camera use to a process. A future
            // app adapter must confirm joined-call and local-camera state first.
            safeForAutomaticTrigger: false,
            matchedRules: rules,
            limitations: limitations + [
                "Camera activity is a separate device-level signal. Temporal overlap must not be treated as camera ownership."
            ]
        )
    }

    private static func normalized(_ title: String?) -> String {
        (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func containsAny(_ value: String, _ needles: [String]) -> Bool {
        needles.contains { value.contains($0) }
    }
}

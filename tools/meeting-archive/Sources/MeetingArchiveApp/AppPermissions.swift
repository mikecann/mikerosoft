import AppKit
import AVFoundation
import ApplicationServices
import Combine
import CoreGraphics
import EventKit
import Foundation
import UserNotifications

enum AppPermissionKind: String, CaseIterable, Identifiable, Sendable {
    case accessibility
    case screenRecording
    case microphone
    case notifications
    case calendar

    var id: String { rawValue }

    var title: String {
        switch self {
        case .accessibility: "Meeting detection"
        case .screenRecording: "Screen and meeting audio"
        case .microphone: "Microphone"
        case .notifications: "Notifications"
        case .calendar: "Calendar suggestions"
        }
    }

    fileprivate var requestAttemptedKey: String {
        "permissionRequestAttempted.\(rawValue)"
    }

    fileprivate var settingsURL: URL? {
        let value = switch self {
        case .accessibility:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .screenRecording:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        case .microphone:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case .notifications:
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        case .calendar:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
        }
        return URL(string: value)
    }
}

enum AppPermissionStatus: String, Equatable, Sendable {
    case notRequested
    case needsAccess
    case granted
    case denied
    case restricted
    case unknown

    var label: String {
        switch self {
        case .notRequested: "Not requested"
        case .needsAccess: "Needs access"
        case .granted: "Granted"
        case .denied: "Denied"
        case .restricted: "Restricted"
        case .unknown: "Unknown"
        }
    }
}

enum AppSystemAuthorizationStatus: Equatable, Sendable {
    case notDetermined
    case granted
    case denied
    case restricted
    case unknown
}

enum AppPermissionStatusMapper {
    static func binary(granted: Bool, requestAttempted: Bool) -> AppPermissionStatus {
        if granted { return .granted }
        // AX and screen-capture preflight expose only yes/no. Request history
        // tells us the app has tried setup, not that macOS recorded a denial.
        return requestAttempted ? .needsAccess : .notRequested
    }

    static func system(_ status: AppSystemAuthorizationStatus) -> AppPermissionStatus {
        switch status {
        case .notDetermined: .notRequested
        case .granted: .granted
        case .denied: .denied
        case .restricted: .restricted
        case .unknown: .unknown
        }
    }
}

@MainActor
final class AppPermissions: ObservableObject {
    @Published private(set) var statuses = Dictionary(
        uniqueKeysWithValues: AppPermissionKind.allCases.map { ($0, AppPermissionStatus.notRequested) }
    )
    @Published private(set) var failure: String?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func status(for permission: AppPermissionKind) -> AppPermissionStatus {
        statuses[permission] ?? .unknown
    }

    func refresh() async {
        let notificationSettings = await UNUserNotificationCenter.current().notificationSettings()
        statuses = [
            .accessibility: AppPermissionStatusMapper.binary(
                granted: AXIsProcessTrusted(),
                requestAttempted: defaults.bool(forKey: AppPermissionKind.accessibility.requestAttemptedKey)
            ),
            .screenRecording: AppPermissionStatusMapper.binary(
                granted: CGPreflightScreenCaptureAccess(),
                requestAttempted: defaults.bool(forKey: AppPermissionKind.screenRecording.requestAttemptedKey)
            ),
            .microphone: AppPermissionStatusMapper.system(Self.microphoneStatus()),
            .notifications: AppPermissionStatusMapper.system(Self.notificationStatus(notificationSettings.authorizationStatus)),
            .calendar: AppPermissionStatusMapper.system(Self.calendarStatus()),
        ]
    }

    func performAction(
        for permission: AppPermissionKind,
        calendar: CalendarService
    ) async {
        failure = nil
        switch status(for: permission) {
        case .needsAccess, .denied, .restricted, .unknown:
            openSystemSettings(for: permission)
            return
        case .granted:
            await refresh()
            return
        case .notRequested:
            break
        }

        defaults.set(true, forKey: permission.requestAttemptedKey)
        do {
            switch permission {
            case .accessibility:
                let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            case .screenRecording:
                _ = CGRequestScreenCaptureAccess()
            case .microphone:
                _ = await AVCaptureDevice.requestAccess(for: .audio)
            case .notifications:
                _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            case .calendar:
                _ = try await calendar.requestAccess()
            }
        } catch {
            failure = error.localizedDescription
        }
        await refresh()
    }

    private func openSystemSettings(for permission: AppPermissionKind) {
        guard let url = permission.settingsURL, NSWorkspace.shared.open(url) else {
            failure = "Could not open System Settings for \(permission.title.lowercased())."
            return
        }
    }

    private static func microphoneStatus() -> AppSystemAuthorizationStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined: .notDetermined
        case .authorized: .granted
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .unknown
        }
    }

    private static func notificationStatus(
        _ status: UNAuthorizationStatus
    ) -> AppSystemAuthorizationStatus {
        switch status {
        case .notDetermined: .notDetermined
        case .authorized, .provisional: .granted
        case .denied: .denied
        @unknown default: .unknown
        }
    }

    private static func calendarStatus() -> AppSystemAuthorizationStatus {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined: .notDetermined
        case .fullAccess: .granted
        case .writeOnly: .restricted
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .unknown
        }
    }
}

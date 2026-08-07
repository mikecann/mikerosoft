import AppKit
import AVFoundation
import CoreMedia
import ScreenCaptureKit

enum CaptureDeviceCatalog {
    static func displays() -> [CaptureDisplay] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            let displayID = CGDirectDisplayID(number.uint32Value)
            let currentMode = CGDisplayCopyDisplayMode(displayID)
            let sourceWidth = currentMode?.pixelWidth ?? Int(screen.frame.width * screen.backingScaleFactor)
            let sourceHeight = currentMode?.pixelHeight ?? Int(screen.frame.height * screen.backingScaleFactor)
            let outputSize = preferredRecordingSize(
                displayName: screen.localizedName,
                sourceWidth: sourceWidth,
                sourceHeight: sourceHeight
            )
            return CaptureDisplay(
                id: displayID,
                name: screen.localizedName,
                width: outputSize.width,
                height: outputSize.height,
                sourceWidth: sourceWidth,
                sourceHeight: sourceHeight
            )
        }
    }

    static func windows() async throws -> [CaptureWindow] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            true,
            onScreenWindowsOnly: true
        )
        let ownProcessID = ProcessInfo.processInfo.processIdentifier
        let windows = content.windows.compactMap { window -> CaptureWindow? in
            guard
                let application = window.owningApplication,
                application.processID != ownProcessID,
                let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                !title.isEmpty,
                window.frame.width >= 160,
                window.frame.height >= 100
            else { return nil }

            return CaptureWindow(
                id: window.windowID,
                applicationName: application.applicationName,
                title: title,
                width: Int(window.frame.width.rounded()),
                height: Int(window.frame.height.rounded())
            )
        }
        return sortedCaptureWindows(windows)
    }

    static func cameras() -> [CaptureCamera] {
        cameraDiscoverySession().devices.compactMap { device in
            guard let format = preferredDeviceFormat(for: device) else { return nil }
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return CaptureCamera(
                id: device.uniqueID,
                name: device.localizedName,
                width: Int(dimensions.width),
                height: Int(dimensions.height)
            )
        }
    }

    static func camera(withID id: String) -> AVCaptureDevice? {
        cameraDiscoverySession().devices.first { $0.uniqueID == id }
    }

    static func microphones() -> [CaptureAudioDevice] {
        let defaultDeviceID = AVCaptureDevice.default(for: .audio)?.uniqueID
        return audioDiscoverySession().devices
            .sorted { left, right in
                if left.uniqueID == defaultDeviceID { return true }
                if right.uniqueID == defaultDeviceID { return false }
                return left.localizedName.localizedCaseInsensitiveCompare(right.localizedName) == .orderedAscending
            }
            .map { CaptureAudioDevice(id: $0.uniqueID, name: $0.localizedName) }
    }

    static func audioDevice(withID id: String) -> AVCaptureDevice? {
        audioDiscoverySession().devices.first { $0.uniqueID == id }
    }

    static func preferredDeviceFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let options = device.formats.map(cameraFormatOption)
        guard let preferred = preferredCameraFormat(in: options) else { return nil }
        return device.formats.first { cameraFormatOption($0) == preferred }
    }

    private static func cameraDiscoverySession() -> AVCaptureDevice.DiscoverySession {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external, .builtInWideAngleCamera, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        )
    }

    private static func audioDiscoverySession() -> AVCaptureDevice.DiscoverySession {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        )
    }

    private static func cameraFormatOption(_ format: AVCaptureDevice.Format) -> CameraFormatOption {
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let ranges = format.videoSupportedFrameRateRanges
        return CameraFormatOption(
            width: Int(dimensions.width),
            height: Int(dimensions.height),
            minimumFrameRate: ranges.map(\.minFrameRate).min() ?? 0,
            maximumFrameRate: ranges.map(\.maxFrameRate).max() ?? 0
        )
    }
}

func preferredRecordingSize(
    displayName _: String,
    sourceWidth: Int,
    sourceHeight: Int
) -> (width: Int, height: Int) {
    // Preserve the framebuffer exactly. A larger encoded canvas cannot restore
    // detail that macOS did not render, and it makes later crops look softer.
    return (sourceWidth, sourceHeight)
}

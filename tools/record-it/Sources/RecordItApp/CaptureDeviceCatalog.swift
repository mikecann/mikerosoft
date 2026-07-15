import AppKit
import AVFoundation
import CoreMedia

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

private func preferredRecordingSize(
    displayName: String,
    sourceWidth: Int,
    sourceHeight: Int
) -> (width: Int, height: Int) {
    if displayName.caseInsensitiveCompare("HG584T05") == .orderedSame {
        return (3840, 2160)
    }
    return (sourceWidth, sourceHeight)
}

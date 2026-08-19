import CoreGraphics
import Foundation

enum ScreenCaptureTargetKind: String, CaseIterable, Identifiable {
    case display
    case window

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .display: "Display"
        case .window: "Window"
        }
    }
}

struct CaptureDisplay: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let name: String
    let width: Int
    let height: Int
    let sourceWidth: Int
    let sourceHeight: Int

    init(
        id: CGDirectDisplayID,
        name: String,
        width: Int,
        height: Int,
        sourceWidth: Int? = nil,
        sourceHeight: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.width = width
        self.height = height
        self.sourceWidth = sourceWidth ?? width
        self.sourceHeight = sourceHeight ?? height
    }

    var resolutionLabel: String { "\(width) × \(height)" }
    var sourceResolutionLabel: String { "\(sourceWidth) × \(sourceHeight)" }
    var isOutputScaled: Bool { width != sourceWidth || height != sourceHeight }

    var upscalingWarning: String? {
        guard isOutputScaled else { return nil }
        return "Source \(sourceResolutionLabel) → output \(resolutionLabel). This recording will be upscaled and may look soft."
    }
}

struct CaptureWindow: Identifiable, Hashable {
    let id: CGWindowID
    let applicationName: String
    let title: String
    let width: Int
    let height: Int

    var displayName: String { "\(applicationName) · \(title)" }
    var sizeLabel: String { "\(width) × \(height) pt" }
}

enum ScreenCaptureTarget {
    case display(CaptureDisplay)
    case window(CaptureWindow)
}

struct CapturePixelSize: Equatable {
    let width: Int
    let height: Int
}

func sortedCaptureWindows(_ windows: [CaptureWindow]) -> [CaptureWindow] {
    windows.sorted { left, right in
        let applicationOrder = left.applicationName.localizedCaseInsensitiveCompare(right.applicationName)
        if applicationOrder != .orderedSame { return applicationOrder == .orderedAscending }
        return left.title.localizedCaseInsensitiveCompare(right.title) == .orderedAscending
    }
}

func windowCapturePixelSize(
    widthInPoints: CGFloat,
    heightInPoints: CGFloat,
    pointPixelScale: Float
) -> CapturePixelSize {
    func evenDimension(_ points: CGFloat) -> Int {
        let pixels = max(2, Int((points * CGFloat(pointPixelScale)).rounded()))
        // The recorder uses a 4:2:0 pixel format, which requires even dimensions.
        return pixels - (pixels % 2)
    }

    return CapturePixelSize(
        width: evenDimension(widthInPoints),
        height: evenDimension(heightInPoints)
    )
}

func preferredDisplay(
    in displays: [CaptureDisplay],
    preferredName: String = "PA27JCV"
) -> CaptureDisplay? {
    displays.first {
        $0.name.compare(preferredName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    } ?? displays.first
}

struct CameraFormatOption: Hashable {
    let width: Int
    let height: Int
    let minimumFrameRate: Double
    let maximumFrameRate: Double

    var supports30FPS: Bool {
        minimumFrameRate <= 30 && maximumFrameRate >= 30
    }
}

func preferredCameraFormat(in formats: [CameraFormatOption]) -> CameraFormatOption? {
    let candidates = formats.filter(\.supports30FPS)
    if let native4K = candidates.first(where: { $0.width == 3840 && $0.height == 2160 }) {
        return native4K
    }

    let fourKPixelCount = 3840 * 2160
    return candidates
        .filter { $0.width * $0.height <= fourKPixelCount }
        .max { $0.width * $0.height < $1.width * $1.height }
        ?? candidates.max { $0.width * $0.height < $1.width * $1.height }
}

struct CameraFrameRateRangeOption {
    let minimumFrameRate: Double
    let maximumFrameRate: Double
}

func preferredCameraFrameRateRangeIndex(
    in ranges: [CameraFrameRateRangeOption],
    targetFrameRate: Double = 30
) -> Int? {
    ranges.indices.min {
        abs(ranges[$0].maximumFrameRate - targetFrameRate)
            < abs(ranges[$1].maximumFrameRate - targetFrameRate)
    }
}

struct CaptureCamera: Identifiable, Hashable {
    let id: String
    let name: String
    let width: Int
    let height: Int

    var resolutionLabel: String { "\(width) × \(height) @ 30 fps" }
    var recordsNative4K: Bool { width == 3840 && height == 2160 }
}

func preferredCamera(in cameras: [CaptureCamera]) -> CaptureCamera? {
    cameras.first(where: \.recordsNative4K) ?? cameras.first
}

struct CaptureAudioDevice: Identifiable, Hashable {
    let id: String
    let name: String
}

func preferredAudioDevice(
    in devices: [CaptureAudioDevice],
    preferredName: String = "Yeti"
) -> CaptureAudioDevice? {
    devices.first {
        $0.name.range(of: preferredName, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    } ?? devices.first
}

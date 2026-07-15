import CoreGraphics
import Foundation

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
    var isOutputScaled: Bool { width != sourceWidth || height != sourceHeight }
}

func preferredDisplay(
    in displays: [CaptureDisplay],
    preferredName: String = "HG584T05"
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

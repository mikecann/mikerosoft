import AVFoundation
import Foundation
import VideoToolbox

enum VideoCodec: String, Hashable {
    case h264
    case hevc

    init?(codecType: CMVideoCodecType) {
        switch codecType {
        case kCMVideoCodecType_H264:
            self = .h264
        case kCMVideoCodecType_HEVC:
            self = .hevc
        default:
            return nil
        }
    }

    var avVideoCodecType: AVVideoCodecType {
        switch self {
        case .h264: .h264
        case .hevc: .hevc
        }
    }

    var codecType: CMVideoCodecType {
        switch self {
        case .h264: kCMVideoCodecType_H264
        case .hevc: kCMVideoCodecType_HEVC
        }
    }

    var displayName: String {
        switch self {
        case .h264: "H.264"
        case .hevc: "HEVC"
        }
    }
}

enum RateControlMode: String, CaseIterable, Identifiable, Hashable {
    case cbr
    case cqp
    case vbr

    var id: String { rawValue }

    var displayName: String { rawValue.uppercased() }

    var explanation: String {
        switch self {
        case .cbr:
            "Keeps the stream close to one bitrate. Useful when a fixed data rate matters."
        case .cqp:
            "Keeps a constant quantization level. Lower QP means higher quality and larger files."
        case .vbr:
            "Targets an average bitrate but can spend more bits on complex scenes, up to the maximum."
        }
    }
}

struct HardwareVideoEncoder: Identifiable, Hashable {
    let id: String
    let displayName: String
    let codec: VideoCodec
    let supportedRateControls: Set<RateControlMode>
    var supportsConstantQuality = false
}

/// Screen-only quality preset. Screen content is mostly static UI with smooth
/// gradients and fine text, which a fixed QP or bitrate either starves (blocky
/// gradients when zoomed in the edit) or pads. Constant quality spends bits
/// only where the picture changes.
enum ScreenQuality: String, CaseIterable, Identifiable, Hashable {
    case standard
    case high
    case editMaster

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standard: "Standard"
        case .high: "High"
        case .editMaster: "Edit Master"
        }
    }

    var explanation: String {
        switch self {
        case .standard:
            "Uses the same encoder settings as the camera."
        case .high:
            "Constant quality 90%. Sharp text, but subtle dark gradients can band when zoomed."
        case .editMaster:
            "Constant quality 95%. Holds up to 3× punch-ins in the edit. Largest files."
        }
    }

    var constantQuality: Double? {
        switch self {
        case .standard: nil
        case .high: 0.9
        case .editMaster: 0.95
        }
    }
}

struct EncoderConfiguration: Equatable {
    let encoder: HardwareVideoEncoder
    let rateControl: RateControlMode
    let bitRateMbps: Int
    let maximumBitRateMbps: Int
    let qualityParameter: Int
    /// VideoToolbox quality from 0 to 1. When set, it replaces `rateControl`.
    var constantQuality: Double?

    var summary: String {
        if let constantQuality {
            return "\(encoder.displayName) · Quality \(Int((constantQuality * 100).rounded()))%"
        }
        return switch rateControl {
        case .cbr:
            "\(encoder.displayName) · CBR \(bitRateMbps) Mbps"
        case .cqp:
            "\(encoder.displayName) · CQP \(qualityParameter)"
        case .vbr:
            "\(encoder.displayName) · VBR \(bitRateMbps)-\(maximumBitRateMbps) Mbps"
        }
    }
}

/// The screen recording configuration: the shared encoder settings, with the
/// screen quality preset applied when the encoder supports constant quality.
func screenEncoderConfiguration(
    base: EncoderConfiguration,
    quality: ScreenQuality
) -> EncoderConfiguration {
    guard let constantQuality = quality.constantQuality, base.encoder.supportsConstantQuality else {
        return base
    }
    var configuration = base
    configuration.constantQuality = constantQuality
    return configuration
}

enum HardwareVideoEncoderCatalog {
    static func availableEncoders() -> [HardwareVideoEncoder] {
        var rawEncoderList: CFArray?
        guard
            VTCopyVideoEncoderList(nil, &rawEncoderList) == noErr,
            let entries = rawEncoderList as? [[CFString: Any]]
        else { return [] }

        return hardwareVideoEncoders(
            from: entries,
            supportedRateControls: { encoderID, codecType in
                supportedRateControls(in: supportedProperties(encoderID: encoderID, codecType: codecType))
            },
            supportsConstantQuality: { encoderID, codecType in
                supportedProperties(encoderID: encoderID, codecType: codecType)[
                    kVTCompressionPropertyKey_Quality as String
                ] != nil
            }
        )
    }
}

func hardwareVideoEncoders(
    from entries: [[CFString: Any]],
    supportedRateControls: (String, CMVideoCodecType) -> Set<RateControlMode>,
    supportsConstantQuality: (String, CMVideoCodecType) -> Bool = { _, _ in false }
) -> [HardwareVideoEncoder] {
    entries.compactMap { entry in
        guard
            entry[kVTVideoEncoderList_IsHardwareAccelerated] as? Bool == true,
            let encoderID = entry[kVTVideoEncoderList_EncoderID] as? String,
            let displayName = entry[kVTVideoEncoderList_DisplayName] as? String,
            let codecNumber = entry[kVTVideoEncoderList_CodecType] as? NSNumber
        else { return nil }

        let codecType = CMVideoCodecType(codecNumber.uint32Value)
        guard let codec = VideoCodec(codecType: codecType) else { return nil }
        let rateControls = supportedRateControls(encoderID, codecType)
        guard !rateControls.isEmpty else { return nil }

        return HardwareVideoEncoder(
            id: encoderID,
            displayName: displayName,
            codec: codec,
            supportedRateControls: rateControls,
            supportsConstantQuality: supportsConstantQuality(encoderID, codecType)
        )
    }
}

func preferredHardwareVideoEncoder(
    in encoders: [HardwareVideoEncoder],
    savedID: String
) -> HardwareVideoEncoder? {
    encoders.first { $0.id == savedID }
        ?? encoders.first { $0.codec == .hevc }
        ?? encoders.first
}

func preferredRateControl(
    savedMode: RateControlMode,
    supportedModes: Set<RateControlMode>
) -> RateControlMode? {
    if supportedModes.contains(savedMode) {
        return savedMode
    }
    if supportedModes.contains(.vbr) {
        return .vbr
    }
    return RateControlMode.allCases.first { supportedModes.contains($0) }
}

private func supportedProperties(
    encoderID: String,
    codecType: CMVideoCodecType
) -> [String: Any] {
    var session: VTCompressionSession?
    let status = VTCompressionSessionCreate(
        allocator: nil,
        width: 1280,
        height: 720,
        codecType: codecType,
        encoderSpecification: [
            kVTVideoEncoderSpecification_EncoderID: encoderID
        ] as CFDictionary,
        imageBufferAttributes: nil,
        compressedDataAllocator: nil,
        outputCallback: nil,
        refcon: nil,
        compressionSessionOut: &session
    )
    guard status == noErr, let session else { return [:] }
    defer { VTCompressionSessionInvalidate(session) }

    var rawProperties: CFDictionary?
    guard
        VTSessionCopySupportedPropertyDictionary(
            session,
            supportedPropertyDictionaryOut: &rawProperties
        ) == noErr,
        let properties = rawProperties as? [String: Any]
    else { return [:] }
    return properties
}

private func supportedRateControls(in properties: [String: Any]) -> Set<RateControlMode> {
    var modes: Set<RateControlMode> = []
    if properties[kVTCompressionPropertyKey_ConstantBitRate as String] != nil {
        modes.insert(.cbr)
    }
    if
        properties[kVTCompressionPropertyKey_MinAllowedFrameQP as String] != nil,
        properties[kVTCompressionPropertyKey_MaxAllowedFrameQP as String] != nil
    {
        modes.insert(.cqp)
    }
    if #available(macOS 26.0, *) {
        if properties[kVTCompressionPropertyKey_VariableBitRate as String] != nil {
            modes.insert(.vbr)
        }
    } else if
        properties[kVTCompressionPropertyKey_AverageBitRate as String] != nil,
        properties[kVTCompressionPropertyKey_DataRateLimits as String] != nil
    {
        modes.insert(.vbr)
    }
    return modes
}

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
}

struct EncoderConfiguration: Equatable {
    let encoder: HardwareVideoEncoder
    let rateControl: RateControlMode
    let bitRateMbps: Int
    let maximumBitRateMbps: Int
    let qualityParameter: Int

    var summary: String {
        switch rateControl {
        case .cbr:
            "\(encoder.displayName) · CBR \(bitRateMbps) Mbps"
        case .cqp:
            "\(encoder.displayName) · CQP \(qualityParameter)"
        case .vbr:
            "\(encoder.displayName) · VBR \(bitRateMbps)-\(maximumBitRateMbps) Mbps"
        }
    }
}

enum HardwareVideoEncoderCatalog {
    static func availableEncoders() -> [HardwareVideoEncoder] {
        var rawEncoderList: CFArray?
        guard
            VTCopyVideoEncoderList(nil, &rawEncoderList) == noErr,
            let entries = rawEncoderList as? [[CFString: Any]]
        else { return [] }

        return hardwareVideoEncoders(from: entries) { encoderID, codecType in
            supportedRateControls(encoderID: encoderID, codecType: codecType)
        }
    }
}

func hardwareVideoEncoders(
    from entries: [[CFString: Any]],
    supportedRateControls: (String, CMVideoCodecType) -> Set<RateControlMode>
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
            supportedRateControls: rateControls
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

private func supportedRateControls(
    encoderID: String,
    codecType: CMVideoCodecType
) -> Set<RateControlMode> {
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
    guard status == noErr, let session else { return [] }
    defer { VTCompressionSessionInvalidate(session) }

    var rawProperties: CFDictionary?
    guard
        VTSessionCopySupportedPropertyDictionary(
            session,
            supportedPropertyDictionaryOut: &rawProperties
        ) == noErr,
        let properties = rawProperties as? [String: Any]
    else { return [] }

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

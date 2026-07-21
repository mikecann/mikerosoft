import AVFoundation
import VideoToolbox
import XCTest
@testable import RecordItApp

final class EncoderSettingsTests: XCTestCase {
    func testCatalogKeepsOnlyUsableH264AndHEVCHardwareEncoders() {
        let entries: [[CFString: Any]] = [
            encoderEntry(id: "hardware-h264", name: "Apple H.264 (HW)", codec: kCMVideoCodecType_H264, hardware: true),
            encoderEntry(id: "hardware-hevc", name: "Apple HEVC (HW)", codec: kCMVideoCodecType_HEVC, hardware: true),
            encoderEntry(id: "software-h264", name: "Apple H.264", codec: kCMVideoCodecType_H264, hardware: false),
            encoderEntry(id: "hardware-prores", name: "Apple ProRes 422 (HW)", codec: kCMVideoCodecType_AppleProRes422, hardware: true)
        ]

        let encoders = hardwareVideoEncoders(from: entries) { _, _ in
            Set(RateControlMode.allCases)
        }

        XCTAssertEqual(encoders.map(\.id), ["hardware-h264", "hardware-hevc"])
        XCTAssertEqual(encoders.map(\.codec), [.h264, .hevc])
    }

    func testCatalogOmitsAnEncoderThatCannotCreateARateControlledSession() {
        let entries = [
            encoderEntry(id: "unavailable", name: "Unavailable HEVC", codec: kCMVideoCodecType_HEVC, hardware: true)
        ]

        let encoders = hardwareVideoEncoders(from: entries) { _, _ in [] }

        XCTAssertTrue(encoders.isEmpty)
    }

    func testPreferredEncoderRestoresTheSavedHardwareEncoderThenFallsBackToHEVC() {
        let encoders = [
            HardwareVideoEncoder(
                id: "h264",
                displayName: "Apple H.264 (HW)",
                codec: .h264,
                supportedRateControls: Set(RateControlMode.allCases)
            ),
            HardwareVideoEncoder(
                id: "hevc",
                displayName: "Apple HEVC (HW)",
                codec: .hevc,
                supportedRateControls: Set(RateControlMode.allCases)
            )
        ]

        XCTAssertEqual(preferredHardwareVideoEncoder(in: encoders, savedID: "h264")?.id, "h264")
        XCTAssertEqual(preferredHardwareVideoEncoder(in: encoders, savedID: "missing")?.id, "hevc")
    }

    private func encoderEntry(
        id: String,
        name: String,
        codec: CMVideoCodecType,
        hardware: Bool
    ) -> [CFString: Any] {
        [
            kVTVideoEncoderList_EncoderID: id,
            kVTVideoEncoderList_DisplayName: name,
            kVTVideoEncoderList_CodecType: NSNumber(value: codec),
            kVTVideoEncoderList_IsHardwareAccelerated: hardware
        ]
    }
}

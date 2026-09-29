import XCTest
@testable import PhoneMirrorApp

final class PhoneScreenFilterTests: XCTestCase {
    func testAcceptsAPluggedInPhoneScreen() {
        XCTAssertTrue(PhoneScreenFilter.isPhoneScreen(modelID: "iOS Device", hasMuxedMedia: true))
    }

    func testRejectsContinuityCameraForTheSamePhone() {
        // Continuity Camera shows up as "<name> Camera" with the hardware model and plain video.
        XCTAssertFalse(PhoneScreenFilter.isPhoneScreen(modelID: "iPhone11,6", hasMuxedMedia: false))
    }

    func testRejectsWebcams() {
        XCTAssertFalse(PhoneScreenFilter.isPhoneScreen(modelID: "UVC Camera VendorID_5426 ProductID_3592", hasMuxedMedia: false))
    }

    func testRejectsAnIOSDeviceWithoutMuxedMedia() {
        XCTAssertFalse(PhoneScreenFilter.isPhoneScreen(modelID: "iOS Device", hasMuxedMedia: false))
    }
}

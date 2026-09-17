import XCTest
@testable import MeetingArchiveApp

final class AppPermissionStatusTests: XCTestCase {
    func testBinaryPermissionUsesRequestHistoryOnlyWhenPreflightIsFalse() {
        XCTAssertEqual(
            AppPermissionStatusMapper.binary(granted: false, requestAttempted: false),
            .notRequested
        )
        XCTAssertEqual(
            AppPermissionStatusMapper.binary(granted: false, requestAttempted: true),
            .needsAccess
        )
        XCTAssertEqual(
            AppPermissionStatusMapper.binary(granted: true, requestAttempted: true),
            .granted
        )
    }

    func testSystemAuthorizationStatesMapWithoutCollapsingRestrictedAccess() {
        XCTAssertEqual(AppPermissionStatusMapper.system(.notDetermined), .notRequested)
        XCTAssertEqual(AppPermissionStatusMapper.system(.denied), .denied)
        XCTAssertEqual(AppPermissionStatusMapper.system(.restricted), .restricted)
        XCTAssertEqual(AppPermissionStatusMapper.system(.granted), .granted)
        XCTAssertEqual(AppPermissionStatusMapper.system(.unknown), .unknown)
    }
}

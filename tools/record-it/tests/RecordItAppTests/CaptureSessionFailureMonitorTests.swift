import AVFoundation
import XCTest
@testable import RecordItApp

final class CaptureSessionFailureMonitorTests: XCTestCase {
    func testSessionInterruptionIsReportedAsAHardCaptureFailure() {
        let session = AVCaptureSession()
        let failure = expectation(description: "capture failure")
        let message = LockedString()
        let monitor = CaptureSessionFailureMonitor(
            session: session,
            deviceIDs: [],
            notificationCenter: .default
        ) { error in
            message.set(error.localizedDescription)
            failure.fulfill()
        }
        monitor.start()
        defer { monitor.stop() }

        NotificationCenter.default.post(
            name: AVCaptureSession.wasInterruptedNotification,
            object: session
        )

        wait(for: [failure], timeout: 1)
        XCTAssertTrue(message.value.contains("interrupted"))
    }

    func testStoppedMonitorDoesNotReportNotifications() {
        let session = AVCaptureSession()
        let failure = expectation(description: "no capture failure")
        failure.isInverted = true
        let monitor = CaptureSessionFailureMonitor(
            session: session,
            deviceIDs: [],
            notificationCenter: .default
        ) { _ in failure.fulfill() }
        monitor.start()
        monitor.stop()

        NotificationCenter.default.post(
            name: AVCaptureSession.wasInterruptedNotification,
            object: session
        )

        wait(for: [failure], timeout: 0.1)
    }
}

private final class LockedString: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = ""

    var value: String { lock.withLock { storedValue } }

    func set(_ value: String) {
        lock.withLock { storedValue = value }
    }
}

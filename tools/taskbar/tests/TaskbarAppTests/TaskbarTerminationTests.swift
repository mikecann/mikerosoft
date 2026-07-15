import XCTest
@testable import TaskbarApp

final class TaskbarTerminationTests: XCTestCase {
    func testNormalApplicationTerminationFlushesOnce() {
        var flushCount = 0
        var terminationRequestCount = 0
        let lifecycle = AppTerminationLifecycle(
            prepareForTermination: { flushCount += 1 },
            requestApplicationTermination: { terminationRequestCount += 1 }
        )

        lifecycle.applicationWillTerminate()
        lifecycle.applicationWillTerminate()

        XCTAssertEqual(flushCount, 1)
        XCTAssertEqual(terminationRequestCount, 0)
    }

    func testSIGTERMRequestsAppTerminationAndLifecycleFlushesOnce() {
        var flushCount = 0
        var terminationRequestCount = 0
        var installedHandler: (() -> Void)?
        var cancellationCount = 0
        let lifecycle = AppTerminationLifecycle(
            prepareForTermination: { flushCount += 1 },
            requestApplicationTermination: { terminationRequestCount += 1 }
        )
        var bridge: TerminationSignalBridge? = TerminationSignalBridge(
            onSignal: { lifecycle.requestTerminationFromSignal() },
            registerSignalHandler: { handler in
                installedHandler = handler
                return { cancellationCount += 1 }
            }
        )

        bridge?.start()
        bridge?.start()
        installedHandler?()

        XCTAssertEqual(terminationRequestCount, 1)
        lifecycle.applicationWillTerminate()
        lifecycle.applicationWillTerminate()
        XCTAssertEqual(flushCount, 1)

        bridge = nil
        XCTAssertEqual(cancellationCount, 1)
    }
}

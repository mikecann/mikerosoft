import Foundation
import XCTest
@testable import RecordItApp

final class ErrorDescriptionTests: XCTestCase {
    func testDetailedDescriptionIncludesFailureReasonAndUnderlyingWriterError() {
        let underlying = NSError(
            domain: NSOSStatusErrorDomain,
            code: -50,
            userInfo: [NSLocalizedDescriptionKey: "Invalid audio format"]
        )
        let error = NSError(
            domain: "AVFoundationErrorDomain",
            code: -11_800,
            userInfo: [
                NSLocalizedDescriptionKey: "The operation could not be completed",
                NSLocalizedFailureReasonErrorKey: "The AAC encoder rejected the input",
                NSUnderlyingErrorKey: underlying
            ]
        )

        let message = detailedErrorDescription(error)

        XCTAssertTrue(message.contains("The AAC encoder rejected the input"))
        XCTAssertTrue(message.contains("Invalid audio format"))
        XCTAssertTrue(message.contains("AVFoundationErrorDomain -11800"))
        XCTAssertTrue(message.contains("NSOSStatusErrorDomain -50"))
    }
}

import XCTest
@testable import VideoHQApp

final class NotionPageReferenceTests: XCTestCase {
    func testPageIDParsesFromNotionLinkAndRawUUID() {
        XCTAssertEqual(
            NotionPageReference.pageID(
                from: "https://www.notion.so/My-Video-Script-b55c9c91384d452b81dbd1ef79372b75?pvs=4"
            ),
            "b55c9c91-384d-452b-81db-d1ef79372b75"
        )
        XCTAssertEqual(
            NotionPageReference.pageID(from: "b55c9c91-384d-452b-81db-d1ef79372b75"),
            "b55c9c91-384d-452b-81db-d1ef79372b75"
        )
        XCTAssertNil(NotionPageReference.pageID(from: "not a notion page"))
    }
}

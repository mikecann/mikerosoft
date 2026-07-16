import Foundation
import XCTest
@testable import VideoHQApp

private final class NotionRecordingTransport: HTTPTransport {
    private(set) var request: URLRequest?
    let responseBody: String

    init(responseBody: String) {
        self.responseBody = responseBody
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        self.request = request
        let response = HTTPURLResponse(
            url: try XCTUnwrap(request.url),
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (Data(responseBody.utf8), response)
    }
}

final class NotionClientTests: XCTestCase {
    func testSearchReturnsPagesAndSendsCurrentNotionRequest() async throws {
        let transport = NotionRecordingTransport(responseBody: #"""
        {
          "object": "list",
          "results": [{
            "object": "page",
            "id": "b55c9c91-384d-452b-81db-d1ef79372b75",
            "url": "https://www.notion.so/b55c9c91384d452b81dbd1ef79372b75",
            "last_edited_time": "2026-07-15T04:00:00.000Z",
            "properties": {
              "Name": {
                "id": "title",
                "type": "title",
                "title": [{"plain_text": "AI Tips Video Script"}]
              }
            }
          }],
          "next_cursor": null,
          "has_more": false
        }
        """#)
        let client = NotionClient(apiKey: "notion-test", transport: transport)

        let pages = try await client.searchPages(query: "AI Tips")

        XCTAssertEqual(pages.map(\.title), ["AI Tips Video Script"])
        XCTAssertEqual(pages.first?.id, "b55c9c91-384d-452b-81db-d1ef79372b75")
        let request = try XCTUnwrap(transport.request)
        XCTAssertEqual(request.url?.absoluteString, "https://api.notion.com/v1/search")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer notion-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Notion-Version"), "2026-03-11")

        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["query"] as? String, "AI Tips")
        XCTAssertEqual((json["filter"] as? [String: String])?["value"], "page")
    }

    func testRetrieveMarkdownDownloadsPageContent() async throws {
        let transport = NotionRecordingTransport(responseBody: #"""
        {
          "object": "page_markdown",
          "id": "b55c9c91-384d-452b-81db-d1ef79372b75",
          "markdown": "# AI Tips\n\nThe full script.",
          "truncated": false,
          "unknown_block_ids": []
        }
        """#)
        let client = NotionClient(apiKey: "notion-test", transport: transport)

        let page = try await client.retrieveMarkdown(
            pageID: "b55c9c91-384d-452b-81db-d1ef79372b75"
        )

        XCTAssertEqual(page.markdown, "# AI Tips\n\nThe full script.")
        XCTAssertFalse(page.truncated)
        let request = try XCTUnwrap(transport.request)
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://api.notion.com/v1/pages/b55c9c91-384d-452b-81db-d1ef79372b75/markdown"
        )
        XCTAssertEqual(request.httpMethod, "GET")
    }
}

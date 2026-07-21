import Foundation
import XCTest
@testable import VideoHQApp

private final class NotionRecordingTransport: HTTPTransport {
    private(set) var request: URLRequest?
    let responseBody: String
    let statusCode: Int

    init(responseBody: String, statusCode: Int = 200) {
        self.responseBody = responseBody
        self.statusCode = statusCode
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        self.request = request
        let response = HTTPURLResponse(
            url: try XCTUnwrap(request.url),
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (Data(responseBody.utf8), response)
    }
}

final class NotionClientTests: XCTestCase {
    func testNotionErrorUsesReadableAPIDetail() async {
        let transport = NotionRecordingTransport(
            responseBody: #"{"object":"error","message":"Share Projects DB with your integration."}"#,
            statusCode: 404
        )
        let client = NotionClient(apiKey: "notion-test", transport: transport)

        do {
            _ = try await client.listVideoProjects()
            XCTFail("Expected the Notion request to fail")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "Notion request failed with HTTP 404:\nShare Projects DB with your integration."
            )
        }
    }

    func testListVideoProjectsQueriesWritingAndReadyToShootStatuses() async throws {
        let transport = NotionRecordingTransport(responseBody: #"""
        {
          "object": "list",
          "results": [{
            "object": "page",
            "id": "373fd70e-cfa0-80e5-a9d5-e64d804c1ccf",
            "url": "https://www.notion.so/373fd70ecfa080e5a9d5e64d804c1ccf",
            "last_edited_time": "2026-07-16T03:18:00.000Z",
            "properties": {
              "Name": {
                "id": "title",
                "type": "title",
                "title": [{"plain_text": "Convex + AI Quick Tips"}]
              },
              "Status": {
                "id": "status",
                "type": "status",
                "status": {"name": "Ready to Shoot"}
              }
            }
          }],
          "next_cursor": null,
          "has_more": false
        }
        """#)
        let client = NotionClient(apiKey: "notion-test", transport: transport)

        let projects = try await client.listVideoProjects()

        XCTAssertEqual(
            projects,
            [NotionVideoProject(
                id: "373fd70e-cfa0-80e5-a9d5-e64d804c1ccf",
                name: "Convex + AI Quick Tips",
                status: "Ready to Shoot",
                url: URL(string: "https://www.notion.so/373fd70ecfa080e5a9d5e64d804c1ccf")
            )]
        )
        let request = try XCTUnwrap(transport.request)
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://api.notion.com/v1/data_sources/1a8fd70e-cfa0-8076-8e19-000bbdf1cc35/query"
        )
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let filter = try XCTUnwrap(json["filter"] as? [String: Any])
        let alternatives = try XCTUnwrap(filter["or"] as? [[String: Any]])
        let statuses = alternatives.compactMap { item in
            (item["status"] as? [String: String])?["equals"]
        }
        XCTAssertEqual(statuses, ["Writing", "Ready to Shoot"])
    }

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

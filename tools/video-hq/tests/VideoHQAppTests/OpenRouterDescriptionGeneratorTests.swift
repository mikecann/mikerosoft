import Foundation
import XCTest
@testable import VideoHQApp

private final class RecordingHTTPTransport: HTTPTransport {
    private(set) var request: URLRequest?

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        self.request = request
        let body = #"{"choices":[{"message":{"content":"A polished description"}}]}"#
        let response = HTTPURLResponse(
            url: try XCTUnwrap(request.url),
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (Data(body.utf8), response)
    }
}

final class OpenRouterDescriptionGeneratorTests: XCTestCase {
    func testGenerateSendsCompatibleOpenRouterRequestAndReturnsReply() async throws {
        let transport = RecordingHTTPTransport()
        let generator = OpenRouterDescriptionGenerator(
            apiKey: "test-key",
            transport: transport
        )

        let reply = try await generator.generate(transcript: "[00:00:01] Intro")

        XCTAssertEqual(reply, "A polished description")
        let request = try XCTUnwrap(transport.request)
        XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")

        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "google/gemini-3.1-pro-preview")
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
        XCTAssertEqual(messages.last?["content"], "Here is the transcript with timestamps:\n\n[00:00:01] Intro\n\nPlease generate a YouTube description for this video.")
        XCTAssertTrue(messages.first?["content"]?.contains("Description, Timestamps, Resources, Hashtags, Titles") == true)
    }
}

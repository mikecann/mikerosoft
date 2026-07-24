import Foundation
import Testing
@testable import RecordMeetingApp

@Suite("Notion payloads")
struct NotionPayloadTests {
    @Test
    func parsesPageURLsAndCompactIDs() {
        #expect(
            NotionPageReference.pageID(
                from: "https://www.notion.so/Recorded-Meetings-123456781234123412341234567890ab"
            ) == "12345678-1234-1234-1234-1234567890ab"
        )
        #expect(
            NotionPageReference.pageID(from: "123456781234123412341234567890ab")
                == "12345678-1234-1234-1234-1234567890ab"
        )
        #expect(NotionPageReference.pageID(from: "not a notion page") == nil)
    }

    @Test
    func databaseSchemaContainsMeetingMetadata() throws {
        let data = try NotionPayloadFactory.createDatabase(parentPageID: "parent-id")
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let source = try #require(object["initial_data_source"] as? [String: Any])
        let properties = try #require(source["properties"] as? [String: Any])

        #expect(properties["Name"] != nil)
        #expect(properties["Started"] != nil)
        #expect(properties["Duration"] != nil)
        #expect(properties["Speakers"] != nil)
        #expect(properties["Audio file"] != nil)
    }

    @Test
    func meetingPageUsesDataSourceParentAndNamedSpeakers() throws {
        let meeting = MeetingMetadata(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            title: "Planning",
            description: "Roadmap",
            startedAt: Date(timeIntervalSince1970: 0),
            endedAt: Date(timeIntervalSince1970: 125),
            audioFile: "/tmp/planning.mp3",
            transcriptFile: "/tmp/planning.md",
            speakers: ["Michael", "Alex"]
        )

        let data = try NotionPayloadFactory.createMeetingPage(meeting: meeting, dataSourceID: "source-id")
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let parent = try #require(object["parent"] as? [String: Any])
        let properties = try #require(object["properties"] as? [String: Any])

        #expect(parent["data_source_id"] as? String == "source-id")
        #expect(properties["Speakers"] != nil)
        #expect(properties["Description"] != nil)
    }

    @Test
    func transcriptBlocksAreChunkedBelowNotionLimit() throws {
        let segments = (0..<205).map {
            TranscriptSegment(start: Double($0), end: Double($0 + 1), text: "Line \($0)", speaker: "SPEAKER_00")
        }
        let document = TranscriptDocument(
            segments: segments,
            speakers: [.init(id: "SPEAKER_00", samplePath: "/tmp/one.mp3")]
        )

        let batches = NotionPayloadFactory.transcriptBlockBatches(
            document: document,
            speakerNames: ["SPEAKER_00": "Michael"]
        )

        #expect(batches.map(\.count) == [100, 100, 7])
    }

    @Test
    func createsDatabaseThenRetrievesItsDataSource() async throws {
        let transport = NotionMockTransport()
        let client = NotionClient(token: "secret", transport: transport)

        let sourceID = try await client.createRecordedMeetingsDatabase(
            parentPageReference: "123456781234123412341234567890ab"
        )
        let requests = await transport.requests

        #expect(sourceID == "source-id")
        #expect(requests.map { $0.url?.path } == ["/v1/databases", "/v1/databases/database-id"])
        #expect(requests.first?.value(forHTTPHeaderField: "Notion-Version") == "2026-03-11")
        #expect(requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
    }
}

private actor NotionMockTransport: NotionHTTPTransport {
    private(set) var requests: [URLRequest] = []

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let body: String
        if request.httpMethod == "POST" {
            body = #"{"id":"database-id"}"#
        } else {
            body = #"{"id":"database-id","data_sources":[{"id":"source-id"}]}"#
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (Data(body.utf8), response)
    }
}

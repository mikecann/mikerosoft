import Foundation

enum NotionPageReference {
    static func pageID(from reference: String) -> String? {
        let pattern = #"(?i)([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|[0-9a-f]{32})"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: reference,
                range: NSRange(reference.startIndex..., in: reference)
              ),
              let range = Range(match.range(at: 1), in: reference) else {
            return nil
        }

        let compact = reference[range].replacingOccurrences(of: "-", with: "").lowercased()
        guard compact.count == 32 else { return nil }
        let lengths = [8, 4, 4, 4, 12]
        var index = compact.startIndex
        return lengths.map { length in
            let end = compact.index(index, offsetBy: length)
            defer { index = end }
            return String(compact[index..<end])
        }.joined(separator: "-")
    }
}

enum NotionPayloadFactory {
    static func createDatabase(parentPageID: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "parent": ["type": "page_id", "page_id": parentPageID],
            "title": [richText("Recorded Meetings")],
            "description": [richText("Audio recordings, metadata, and speaker-labelled transcripts created by Record Meeting.")],
            "icon": ["type": "emoji", "emoji": "🎙️"],
            "initial_data_source": [
                "properties": [
                    "Name": ["title": [:]],
                    "Started": ["date": [:]],
                    "Duration": ["number": ["format": "number"]],
                    "Speakers": ["rich_text": [:]],
                    "Description": ["rich_text": [:]],
                    "Audio file": ["rich_text": [:]],
                    "Transcript file": ["rich_text": [:]],
                ],
            ],
        ])
    }

    static func createMeetingPage(meeting: MeetingMetadata, dataSourceID: String) throws -> Data {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return try JSONSerialization.data(withJSONObject: [
            "parent": ["type": "data_source_id", "data_source_id": dataSourceID],
            "icon": ["type": "emoji", "emoji": "🎧"],
            "properties": [
                "Name": ["type": "title", "title": [richText(meeting.title)]],
                "Started": [
                    "type": "date",
                    "date": [
                        "start": iso.string(from: meeting.startedAt),
                        "end": iso.string(from: meeting.endedAt),
                    ],
                ],
                "Duration": ["type": "number", "number": Int(meeting.duration.rounded())],
                "Speakers": ["type": "rich_text", "rich_text": [richText(meeting.speakers.joined(separator: ", "))]],
                "Description": ["type": "rich_text", "rich_text": richTextArray(meeting.description)],
                "Audio file": ["type": "rich_text", "rich_text": [richText(meeting.audioFile)]],
                "Transcript file": ["type": "rich_text", "rich_text": [richText(meeting.transcriptFile)]],
            ],
        ])
    }

    static func transcriptBlockBatches(
        document: TranscriptDocument,
        speakerNames: [String: String]
    ) -> [[[String: Any]]] {
        var blocks: [[String: Any]] = [
            heading("Transcript", level: 1),
            paragraph("Speaker names have been reviewed in Record Meeting. Timestamps refer to the local MP3 file."),
        ]
        blocks.append(contentsOf: document.segments.map { segment in
            let speaker = TranscriptDocument.displayName(for: segment.speaker, names: speakerNames)
            let text = "\(speaker) [\(TranscriptDocument.timestamp(segment.start))]\n\(segment.text)"
            return paragraph(String(text.prefix(1_900)))
        })
        return stride(from: 0, to: blocks.count, by: 100).map {
            Array(blocks[$0..<min($0 + 100, blocks.count)])
        }
    }

    static func appendBlocks(_ blocks: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["children": blocks])
    }

    private static func richText(_ content: String) -> [String: Any] {
        ["type": "text", "text": ["content": String(content.prefix(1_900))]]
    }

    private static func richTextArray(_ content: String) -> [[String: Any]] {
        content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [richText(content)]
    }

    private static func paragraph(_ content: String) -> [String: Any] {
        [
            "object": "block",
            "type": "paragraph",
            "paragraph": ["rich_text": [richText(content)]],
        ]
    }

    private static func heading(_ content: String, level: Int) -> [String: Any] {
        let type = "heading_\(level)"
        return [
            "object": "block",
            "type": type,
            type: ["rich_text": [richText(content)]],
        ]
    }
}

protocol NotionHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

struct URLSessionNotionTransport: NotionHTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await URLSession.shared.data(for: request)
    }
}

struct NotionClient: Sendable {
    static let endpoint = URL(string: "https://api.notion.com/v1")!
    static let apiVersion = "2026-03-11"

    let token: String
    let transport: any NotionHTTPTransport

    init(token: String, transport: any NotionHTTPTransport = URLSessionNotionTransport()) {
        self.token = token
        self.transport = transport
    }

    func createRecordedMeetingsDatabase(parentPageReference: String) async throws -> String {
        guard let parentID = NotionPageReference.pageID(from: parentPageReference) else {
            throw RecordMeetingError.message("Paste a valid Notion parent page link or page ID.")
        }
        let payload = try NotionPayloadFactory.createDatabase(parentPageID: parentID)
        let response: DatabaseResponse = try await send(path: "databases", method: "POST", body: payload)

        let retrieved: DatabaseResponse = try await send(
            path: "databases/\(response.id)",
            method: "GET",
            body: nil
        )
        guard let sourceID = retrieved.dataSources?.first?.id ?? response.dataSources?.first?.id else {
            throw RecordMeetingError.message("Notion created the database but did not return its data source ID.")
        }
        return sourceID
    }

    func publish(
        meeting: MeetingMetadata,
        transcript: TranscriptDocument,
        speakerNames: [String: String],
        dataSourceID: String
    ) async throws -> URL? {
        let body = try NotionPayloadFactory.createMeetingPage(
            meeting: meeting,
            dataSourceID: dataSourceID
        )
        let page: PageResponse = try await send(path: "pages", method: "POST", body: body)

        for batch in NotionPayloadFactory.transcriptBlockBatches(
            document: transcript,
            speakerNames: speakerNames
        ) {
            let blockBody = try NotionPayloadFactory.appendBlocks(batch)
            let _: BlockListResponse = try await send(
                path: "blocks/\(page.id)/children",
                method: "PATCH",
                body: blockBody
            )
        }
        return page.url.flatMap(URL.init(string:))
    }

    private func send<Response: Decodable>(
        path: String,
        method: String,
        body: Data?
    ) async throws -> Response {
        var request = URLRequest(url: Self.endpoint.appendingPathComponent(path))
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await transport.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RecordMeetingError.message("Notion returned an invalid response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(APIError.self, from: data).message)
                ?? String(decoding: data, as: UTF8.self)
            throw RecordMeetingError.message("Notion request failed (HTTP \(http.statusCode)): \(message)")
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw RecordMeetingError.message("Could not read Notion's response: \(error.localizedDescription)")
        }
    }

    private struct APIError: Decodable {
        let message: String
    }

    private struct DataSourceSummary: Decodable {
        let id: String
    }

    private struct DatabaseResponse: Decodable {
        let id: String
        let dataSources: [DataSourceSummary]?

        enum CodingKeys: String, CodingKey {
            case id
            case dataSources = "data_sources"
        }
    }

    private struct PageResponse: Decodable {
        let id: String
        let url: String?
    }

    private struct BlockListResponse: Decodable {}
}

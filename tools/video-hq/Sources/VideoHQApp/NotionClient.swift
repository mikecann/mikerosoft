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
        let chunks = [8, 4, 4, 4, 12]
        var index = compact.startIndex
        var parts: [Substring] = []
        for length in chunks {
            let end = compact.index(index, offsetBy: length)
            parts.append(compact[index..<end])
            index = end
        }
        return parts.map(String.init).joined(separator: "-")
    }
}

struct NotionPageSearchResult: Identifiable, Equatable {
    let id: String
    let title: String
    let url: URL?
    let lastEditedTime: String
}

struct NotionVideoProject: Identifiable, Equatable {
    let id: String
    let name: String
    let status: String
    let url: URL?
}

struct NotionPageMarkdown: Decodable, Equatable {
    let markdown: String
    let truncated: Bool
    let unknownBlockIDs: [String]

    enum CodingKeys: String, CodingKey {
        case markdown
        case truncated
        case unknownBlockIDs = "unknown_block_ids"
    }
}

enum NotionClientError: LocalizedError {
    case invalidResponse
    case requestFailed(Int, String)
    case invalidPageReference
    case missingAPIKey(URL)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Notion returned an unexpected response."
        case .requestFailed(let status, let body):
            let detail = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty
                ? "Notion request failed with HTTP \(status)."
                : "Notion request failed with HTTP \(status):\n\(detail)"
        case .invalidPageReference:
            return "Paste a valid Notion page link or page ID."
        case .missingAPIKey(let dotenvURL):
            return "NOTION_API_KEY is not set. Add it to \(dotenvURL.path), then reopen Video HQ."
        }
    }
}

struct NotionClient {
    static let endpoint = URL(string: "https://api.notion.com/v1")!
    static let apiVersion = "2026-03-11"
    static let videoProjectsDataSourceID = "1a8fd70e-cfa0-8076-8e19-000bbdf1cc35"

    let apiKey: String
    let transport: any HTTPTransport

    init(apiKey: String, transport: any HTTPTransport = URLSessionHTTPTransport()) {
        self.apiKey = apiKey
        self.transport = transport
    }

    func searchPages(query: String) async throws -> [NotionPageSearchResult] {
        let payload = SearchRequest(
            query: query.trimmingCharacters(in: .whitespacesAndNewlines),
            pageSize: 50,
            filter: SearchFilter(property: "object", value: "page"),
            sort: SearchSort(direction: "descending", timestamp: "last_edited_time")
        )
        var request = request(url: Self.endpoint.appendingPathComponent("search"), method: "POST")
        request.httpBody = try JSONEncoder().encode(payload)

        let data = try await send(request)
        let response = try JSONDecoder().decode(SearchResponse.self, from: data)
        return response.results.map { page in
            let title = page.properties.values
                .first(where: { $0.type == "title" })?
                .title?
                .map(\.plainText)
                .joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return NotionPageSearchResult(
                id: page.id,
                title: title.flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled",
                url: page.url.flatMap(URL.init(string:)),
                lastEditedTime: page.lastEditedTime
            )
        }
    }

    func retrieveMarkdown(pageID: String) async throws -> NotionPageMarkdown {
        let url = Self.endpoint
            .appendingPathComponent("pages")
            .appendingPathComponent(pageID)
            .appendingPathComponent("markdown")
        let data = try await send(request(url: url, method: "GET"))
        return try JSONDecoder().decode(NotionPageMarkdown.self, from: data)
    }

    func listVideoProjects() async throws -> [NotionVideoProject] {
        var projects: [NotionVideoProject] = []
        var cursor: String?

        repeat {
            let payload = DataSourceQueryRequest(
                filter: CompoundFilter(or: [
                    StatusFilter(property: "Status", status: EqualsFilter(equals: "Writing")),
                    StatusFilter(property: "Status", status: EqualsFilter(equals: "Ready to Shoot"))
                ]),
                sorts: [SearchSort(direction: "descending", timestamp: "last_edited_time")],
                pageSize: 100,
                startCursor: cursor
            )
            let url = Self.endpoint
                .appendingPathComponent("data_sources")
                .appendingPathComponent(Self.videoProjectsDataSourceID)
                .appendingPathComponent("query")
            var queryRequest = request(url: url, method: "POST")
            queryRequest.httpBody = try JSONEncoder().encode(payload)

            let data = try await send(queryRequest)
            let response = try JSONDecoder().decode(DataSourceQueryResponse.self, from: data)
            projects.append(contentsOf: response.results.compactMap { page in
                guard let name = page.title, let status = page.properties["Status"]?.status?.name else {
                    return nil
                }
                return NotionVideoProject(
                    id: page.id,
                    name: name,
                    status: status,
                    url: page.url.flatMap(URL.init(string:))
                )
            })
            cursor = response.hasMore ? response.nextCursor : nil
        } while cursor != nil

        return projects
    }

    private func request(url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await transport.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NotionClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let apiMessage = try? JSONDecoder().decode(APIErrorResponse.self, from: data).message
            throw NotionClientError.requestFailed(
                httpResponse.statusCode,
                apiMessage ?? String(decoding: data, as: UTF8.self)
            )
        }
        return data
    }
}

private extension NotionClient {
    struct APIErrorResponse: Decodable {
        let message: String
    }

    struct DataSourceQueryRequest: Encodable {
        let filter: CompoundFilter
        let sorts: [SearchSort]
        let pageSize: Int
        let startCursor: String?

        enum CodingKeys: String, CodingKey {
            case filter
            case sorts
            case pageSize = "page_size"
            case startCursor = "start_cursor"
        }
    }

    struct CompoundFilter: Encodable {
        let or: [StatusFilter]
    }

    struct StatusFilter: Encodable {
        let property: String
        let status: EqualsFilter
    }

    struct EqualsFilter: Encodable {
        let equals: String
    }

    struct SearchRequest: Encodable {
        let query: String
        let pageSize: Int
        let filter: SearchFilter
        let sort: SearchSort

        enum CodingKeys: String, CodingKey {
            case query
            case pageSize = "page_size"
            case filter
            case sort
        }
    }

    struct SearchFilter: Encodable {
        let property: String
        let value: String
    }

    struct SearchSort: Encodable {
        let direction: String
        let timestamp: String
    }

    struct SearchResponse: Decodable {
        let results: [SearchPage]
    }

    struct DataSourceQueryResponse: Decodable {
        let results: [SearchPage]
        let nextCursor: String?
        let hasMore: Bool

        enum CodingKeys: String, CodingKey {
            case results
            case nextCursor = "next_cursor"
            case hasMore = "has_more"
        }
    }

    struct SearchPage: Decodable {
        let id: String
        let url: String?
        let lastEditedTime: String
        let properties: [String: PageProperty]

        var title: String? {
            properties.values
                .first(where: { $0.type == "title" })?
                .title?
                .map(\.plainText)
                .joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        enum CodingKeys: String, CodingKey {
            case id
            case url
            case lastEditedTime = "last_edited_time"
            case properties
        }
    }

    struct PageProperty: Decodable {
        let type: String
        let title: [RichText]?
        let status: StatusValue?
    }

    struct StatusValue: Decodable {
        let name: String
    }

    struct RichText: Decodable {
        let plainText: String

        enum CodingKeys: String, CodingKey {
            case plainText = "plain_text"
        }
    }
}

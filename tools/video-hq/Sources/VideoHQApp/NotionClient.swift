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
            throw NotionClientError.requestFailed(
                httpResponse.statusCode,
                String(decoding: data, as: UTF8.self)
            )
        }
        return data
    }
}

private extension NotionClient {
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

    struct SearchPage: Decodable {
        let id: String
        let url: String?
        let lastEditedTime: String
        let properties: [String: PageProperty]

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
    }

    struct RichText: Decodable {
        let plainText: String

        enum CodingKeys: String, CodingKey {
            case plainText = "plain_text"
        }
    }
}

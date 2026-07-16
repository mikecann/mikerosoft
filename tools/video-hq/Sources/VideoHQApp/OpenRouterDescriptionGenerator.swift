import Foundation

protocol HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

struct URLSessionHTTPTransport: HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await URLSession.shared.data(for: request)
    }
}

struct OpenRouterDescriptionGenerator: VideoDescriptionGenerating {
    static let model = "google/gemini-3.1-pro-preview"
    static let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

    private static let systemPrompt = """
    You help creators turn a video transcript with timestamps into a polished, third-person YouTube description optimized for SEO from a software developer's perspective.

    Output exactly these five sections in this order: Description, Timestamps, Resources, Hashtags, Titles.

    1) Description: Write a short, keyword-rich third-person summary for developers. Cover the tech stack, problems solved, notable patterns, practical outcomes, and intended audience. Keep paragraphs short and avoid hype.
    2) Timestamps: Use the transcript timecodes with concise inferred section titles. Keep one line per timestamp, formatted as "[HH:MM:SS] Title" or "[MM:SS] Title".
    3) Resources: Include links supplied by the user. Do not invent links. If none were supplied, write "No links provided - add relevant repo, doc, and blog URLs here."
    4) Hashtags: Write one horizontal list of 8-15 relevant technical hashtags.
    5) Titles: Write three distinct, informative titles for developers, each under about 70 characters and avoiding clickbait.

    Preserve technical accuracy. Reflect uncertainty honestly. Use American English unless asked otherwise. Do not use emojis. Output plain text only, with no markdown, preamble, sign-off, or meta-commentary.
    """

    let apiKey: String
    let transport: any HTTPTransport

    init(apiKey: String, transport: any HTTPTransport = URLSessionHTTPTransport()) {
        self.apiKey = apiKey
        self.transport = transport
    }

    func generate(transcript: String) async throws -> String {
        let messages = [
            Message(role: "system", content: Self.systemPrompt),
            Message(
                role: "user",
                content: "Here is the transcript with timestamps:\n\n\(transcript)\n\nPlease generate a YouTube description for this video."
            ),
        ]
        let payload = RequestPayload(
            model: Self.model,
            messages: messages,
            temperature: 0.7,
            maxTokens: 8_000
        )

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://github.com/mikecann/mikerosoft", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("mikerosoft/video-hq", forHTTPHeaderField: "X-Title")
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await transport.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw VideoHQError.invalidDescriptionResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw VideoHQError.descriptionRequestFailed(
                httpResponse.statusCode,
                String(decoding: data, as: UTF8.self)
            )
        }

        let decoded = try JSONDecoder().decode(ResponsePayload.self, from: data)
        guard let reply = decoded.choices.first?.message.content,
              !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VideoHQError.invalidDescriptionResponse
        }
        return reply
    }
}

private extension OpenRouterDescriptionGenerator {
    struct Message: Codable {
        let role: String
        let content: String
    }

    struct RequestPayload: Encodable {
        let model: String
        let messages: [Message]
        let temperature: Double
        let maxTokens: Int

        enum CodingKeys: String, CodingKey {
            case model
            case messages
            case temperature
            case maxTokens = "max_tokens"
        }
    }

    struct ResponsePayload: Decodable {
        let choices: [Choice]
    }

    struct Choice: Decodable {
        let message: ResponseMessage
    }

    struct ResponseMessage: Decodable {
        let content: String
    }
}

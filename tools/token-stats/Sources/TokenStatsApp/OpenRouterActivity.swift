import Foundation
import Security

enum OpenRouterActivityError: LocalizedError {
    case invalidResponse
    case invalidManagementKey
    case rejected(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "OpenRouter returned an invalid response."
        case .invalidManagementKey:
            return "That is not a complete OpenRouter management key. Copy the full key beginning with sk-or-v1-."
        case let .rejected(statusCode, message):
            return "OpenRouter activity request failed (\(statusCode)): \(message)"
        }
    }
}

enum OpenRouterManagementKey {
    static func isValid(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("sk-or-v1-"), trimmed.count == 73 else {
            return false
        }
        return trimmed.dropFirst("sk-or-v1-".count).allSatisfy(\.isHexDigit)
    }
}

enum OpenRouterActivityParser {
    private struct Response: Decodable {
        let data: [Row]
    }

    private struct Row: Decodable {
        let date: String
        let model: String
        let promptTokens: Int?
        let completionTokens: Int?
        let usage: Double?

        enum CodingKeys: String, CodingKey {
            case date
            case model
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case usage
        }
    }

    private struct GroupKey: Hashable {
        let date: Date
        let model: String
    }

    private struct Totals {
        var inputTokens = 0
        var outputTokens = 0
        var costUSD = 0.0
    }

    static func parse(data: Data) throws -> [UsageRecord] {
        let response = try JSONDecoder().decode(Response.self, from: data)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"

        var grouped: [GroupKey: Totals] = [:]
        for row in response.data {
            // The live Activity API currently returns `yyyy-MM-dd HH:mm:ss`,
            // while older fixtures and exports use a bare calendar date.
            // Billing is daily, so normalize both shapes to the UTC date.
            guard let date = formatter.date(from: String(row.date.prefix(10))) else { continue }
            let key = GroupKey(date: date, model: row.model)
            var totals = grouped[key, default: Totals()]
            totals.inputTokens += row.promptTokens ?? 0
            totals.outputTokens += row.completionTokens ?? 0
            // `usage` is the amount billed by OpenRouter. The separate
            // byok_usage_inference field estimates spend paid elsewhere.
            totals.costUSD += row.usage ?? 0
            grouped[key] = totals
        }

        return grouped.map { key, totals in
            UsageRecord(
                id: "openrouter-api|\(Int(key.date.timeIntervalSince1970))|\(key.model)",
                date: key.date,
                provider: .openRouter,
                model: key.model,
                inputTokens: totals.inputTokens,
                cachedInputTokens: 0,
                cacheWriteTokens: 0,
                outputTokens: totals.outputTokens,
                exactCostUSD: totals.costUSD
            )
        }
    }
}

enum OpenRouterActivityClient {
    static func activityRequest(managementKey: String) throws -> URLRequest {
        guard let url = URL(string: "https://openrouter.ai/api/v1/activity") else {
            throw OpenRouterActivityError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(managementKey)", forHTTPHeaderField: "Authorization")
        request.setValue("Token Stats", forHTTPHeaderField: "X-Title")
        request.timeoutInterval = 30
        return request
    }

    static func fetch(managementKey: String) async throws -> [UsageRecord] {
        let request = try activityRequest(managementKey: managementKey)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenRouterActivityError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data))
                .flatMap { $0 as? [String: Any] }
                .flatMap { $0["error"] as? [String: Any] }
                .flatMap { $0["message"] as? String }
                ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw OpenRouterActivityError.rejected(
                statusCode: http.statusCode,
                message: message
            )
        }
        return try OpenRouterActivityParser.parse(data: data)
    }
}

enum OpenRouterKeychain {
    static let service = "app.mikerosoft.token-stats.openrouter"
    static let account = "management-key"

    static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else {
            return nil
        }
        return key
    }

    static func save(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard OpenRouterManagementKey.isValid(trimmed) else {
            throw OpenRouterActivityError.invalidManagementKey
        }
        let identifyingQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(identifyingQuery as CFDictionary)

        var item = identifyingQuery
        item[kSecValueData as String] = Data(trimmed.utf8)
        item[kSecAttrLabel as String] = "Token Stats OpenRouter management key"
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: SecCopyErrorMessageString(status, nil) ?? "Could not save the OpenRouter key."]
            )
        }
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

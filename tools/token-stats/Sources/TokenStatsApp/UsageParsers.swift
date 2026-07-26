import Foundation

private enum JSONValue {
    static func dictionary(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func int(_ dictionary: [String: Any], _ key: String) -> Int {
        if let value = dictionary[key] as? Int { return value }
        if let value = dictionary[key] as? NSNumber { return value.intValue }
        return 0
    }

    static func date(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}

enum CodexUsageParser {
    static func parse(lines: [String], sourceID: String) -> [UsageRecord] {
        var records: [UsageRecord] = []
        var currentModel = "unknown-codex-model"
        var previous: [String: Int] = [:]

        for (index, line) in lines.enumerated() {
            let root = JSONValue.dictionary(line)
            if line.contains(#""type":"turn_context""#) {
                if let payload = root?["payload"] as? [String: Any],
                   let model = payload["model"] as? String {
                    currentModel = model
                } else if let model = capture(#""model":"([^"]+)""#, in: line) {
                    // The streaming reader intentionally caps turn_context
                    // lines. The model lives near the start, while the rest can
                    // contain megabytes of instructions that are irrelevant.
                    currentModel = model
                }
                continue
            }
            guard let root else { continue }
            guard root["type"] as? String == "event_msg",
                  let payload = root["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let total = info["total_token_usage"] as? [String: Any],
                  let date = JSONValue.date(root["timestamp"]) else {
                continue
            }

            let totalInput = JSONValue.int(total, "input_tokens")
            let cached = JSONValue.int(total, "cached_input_tokens")
            let write = JSONValue.int(total, "cache_write_input_tokens")
            let output = JSONValue.int(total, "output_tokens")
            let deltaInput = max(0, totalInput - (previous["input"] ?? 0))
            let deltaCached = max(0, cached - (previous["cached"] ?? 0))
            let deltaWrite = max(0, write - (previous["write"] ?? 0))
            let deltaOutput = max(0, output - (previous["output"] ?? 0))
            previous = ["input": totalInput, "cached": cached, "write": write, "output": output]

            // Codex input_tokens includes cached input. Split it so cost math
            // cannot accidentally charge cached tokens at the full rate.
            records.append(UsageRecord(
                id: "\(sourceID):\(index)",
                date: date,
                provider: .codex,
                model: currentModel,
                inputTokens: max(0, deltaInput - deltaCached),
                cachedInputTokens: deltaCached,
                cacheWriteTokens: deltaWrite,
                outputTokens: deltaOutput
            ))
        }
        return records
    }

    private static func capture(_ pattern: String, in value: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: value,
                range: NSRange(value.startIndex..., in: value)
              ),
              let range = Range(match.range(at: 1), in: value) else {
            return nil
        }
        return String(value[range])
    }
}

enum ClaudeUsageParser {
    static func parse(lines: [String], sourceID: String) -> [UsageRecord] {
        var bestByMessageID: [String: UsageRecord] = [:]
        var scoreByMessageID: [String: Int] = [:]

        for (index, line) in lines.enumerated() {
            guard let root = JSONValue.dictionary(line),
                  root["type"] as? String == "assistant",
                  let message = root["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any],
                  let date = JSONValue.date(root["timestamp"]) else {
                continue
            }
            let messageID = (message["id"] as? String) ?? "\(sourceID):\(index)"
            let model = (message["model"] as? String) ?? "unknown-claude-model"
            let record = UsageRecord(
                id: "\(sourceID):\(messageID)",
                date: date,
                provider: .claude,
                model: model,
                inputTokens: JSONValue.int(usage, "input_tokens"),
                cachedInputTokens: JSONValue.int(usage, "cache_read_input_tokens"),
                cacheWriteTokens: JSONValue.int(usage, "cache_creation_input_tokens"),
                outputTokens: JSONValue.int(usage, "output_tokens")
            )
            let score = record.totalTokens
            if score >= (scoreByMessageID[messageID] ?? -1) {
                bestByMessageID[messageID] = record
                scoreByMessageID[messageID] = score
            }
        }
        return bestByMessageID.values.sorted { $0.date < $1.date }
    }
}

enum OpenRouterCSVError: LocalizedError {
    case missingHeaders

    var errorDescription: String? {
        "That CSV does not look like an OpenRouter Activity export."
    }
}

enum OpenRouterCSVParser {
    static func parse(csv: String, sourceID: String) throws -> [UsageRecord] {
        let rows = CSV.rows(csv)
        guard let rawHeaders = rows.first else { throw OpenRouterCSVError.missingHeaders }
        let headers = rawHeaders.map(normalize)
        guard let dateIndex = index(in: headers, matching: ["date", "time", "timestamp", "period"]),
              let modelIndex = index(in: headers, matching: ["model"]) else {
            throw OpenRouterCSVError.missingHeaders
        }
        let promptIndex = index(in: headers, matching: ["prompttokens", "inputtokens", "tokensprompt"])
        let completionIndex = index(in: headers, matching: ["completiontokens", "outputtokens", "tokenscompletion"])
        let totalTokensIndex = index(in: headers, matching: ["totaltokens", "tokens"])
        let costIndex = index(in: headers, matching: ["totalcost", "cost", "spend", "usage"])

        return rows.dropFirst().enumerated().compactMap { offset, row in
            guard row.indices.contains(dateIndex), row.indices.contains(modelIndex),
                  let date = parseDate(row[dateIndex]) else { return nil }
            let input = promptIndex.flatMap { row.indices.contains($0) ? parseInteger(row[$0]) : nil } ?? 0
            let output = completionIndex.flatMap { row.indices.contains($0) ? parseInteger(row[$0]) : nil } ?? 0
            let total = totalTokensIndex.flatMap { row.indices.contains($0) ? parseInteger(row[$0]) : nil } ?? 0
            let adjustedInput = input == 0 && output == 0 ? total : input
            let cost = costIndex.flatMap { row.indices.contains($0) ? parseDouble(row[$0]) : nil }
            return UsageRecord(
                id: "\(sourceID):\(offset)",
                date: date,
                provider: .openRouter,
                model: row[modelIndex],
                inputTokens: adjustedInput,
                cachedInputTokens: 0,
                cacheWriteTokens: 0,
                outputTokens: output,
                exactCostUSD: cost
            )
        }
    }

    private static func normalize(_ value: String) -> String {
        value.lowercased().filter(\.isLetter)
    }

    private static func index(in headers: [String], matching candidates: [String]) -> Int? {
        candidates.compactMap { headers.firstIndex(of: $0) }.first
    }

    private static func parseInteger(_ value: String) -> Int? {
        Int(value.filter { $0.isNumber || $0 == "-" })
    }

    private static func parseDouble(_ value: String) -> Double? {
        Double(value.filter { $0.isNumber || $0 == "." || $0 == "-" })
    }

    private static func parseDate(_ value: String) -> Date? {
        if let date = JSONValue.date(value) { return date }
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd", "MMM d, yyyy", "d MMM yyyy"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
}

private enum CSV {
    static func rows(_ text: String) -> [[String]] {
        var result: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        let characters = Array(text)
        var index = 0

        while index < characters.count {
            let character = characters[index]
            if character == "\"" {
                if quoted, index + 1 < characters.count, characters[index + 1] == "\"" {
                    field.append("\"")
                    index += 1
                } else {
                    quoted.toggle()
                }
            } else if character == ",", !quoted {
                row.append(field.trimmingCharacters(in: .whitespacesAndNewlines))
                field = ""
            } else if character == "\n", !quoted {
                row.append(field.trimmingCharacters(in: .whitespacesAndNewlines))
                if row.contains(where: { !$0.isEmpty }) { result.append(row) }
                row = []
                field = ""
            } else if character != "\r" {
                field.append(character)
            }
            index += 1
        }
        row.append(field.trimmingCharacters(in: .whitespacesAndNewlines))
        if row.contains(where: { !$0.isEmpty }) { result.append(row) }
        return result
    }
}

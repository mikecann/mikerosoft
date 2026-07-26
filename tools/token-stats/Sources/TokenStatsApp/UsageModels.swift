import Foundation
import SwiftUI

enum UsageProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case codex = "Codex"
    case claude = "Claude"
    case openRouter = "OpenRouter"

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .codex: return Color(red: 0.20, green: 0.78, blue: 0.67)
        case .claude: return Color(red: 0.91, green: 0.51, blue: 0.28)
        case .openRouter: return Color(red: 0.54, green: 0.47, blue: 0.96)
        }
    }

    var symbol: String {
        switch self {
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .claude: return "sparkles"
        case .openRouter: return "point.3.connected.trianglepath.dotted"
        }
    }
}

struct UsageRecord: Identifiable, Equatable, Codable, Sendable {
    let id: String
    let date: Date
    let provider: UsageProvider
    let model: String
    /// Input that was not served from cache.
    let inputTokens: Int
    let cachedInputTokens: Int
    let cacheWriteTokens: Int
    let outputTokens: Int
    let exactCostUSD: Double?

    init(
        id: String,
        date: Date,
        provider: UsageProvider,
        model: String,
        inputTokens: Int,
        cachedInputTokens: Int,
        cacheWriteTokens: Int,
        outputTokens: Int,
        exactCostUSD: Double? = nil
    ) {
        self.id = id
        self.date = date
        self.provider = provider
        self.model = model
        self.inputTokens = max(0, inputTokens)
        self.cachedInputTokens = max(0, cachedInputTokens)
        self.cacheWriteTokens = max(0, cacheWriteTokens)
        self.outputTokens = max(0, outputTokens)
        self.exactCostUSD = exactCostUSD
    }

    var totalTokens: Int {
        inputTokens + cachedInputTokens + cacheWriteTokens + outputTokens
    }
}

struct DailyUsagePoint: Identifiable, Sendable {
    let date: Date
    let provider: UsageProvider
    let tokens: Int
    let costUSD: Double

    var id: String { "\(date.timeIntervalSince1970)-\(provider.rawValue)" }
}

struct ProviderSummary: Identifiable, Sendable {
    let provider: UsageProvider
    let tokens: Int
    let costUSD: Double
    let records: Int

    var id: UsageProvider { provider }
}

enum DashboardMetric: String, CaseIterable, Identifiable {
    case tokens = "Tokens"
    case cost = "Estimated cost"

    var id: String { rawValue }
}

enum DashboardRange: String, CaseIterable, Identifiable, Sendable {
    case sevenDays = "7 days"
    case thirtyDays = "30 days"
    case ninetyDays = "90 days"
    case all = "All time"

    var id: String { rawValue }

    func startDate(relativeTo now: Date, records: [UsageRecord], calendar: Calendar = .current) -> Date {
        switch self {
        case .sevenDays:
            return calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)) ?? now
        case .thirtyDays:
            return calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: now)) ?? now
        case .ninetyDays:
            return calendar.date(byAdding: .day, value: -89, to: calendar.startOfDay(for: now)) ?? now
        case .all:
            return records.map(\.date).min().map { calendar.startOfDay(for: $0) }
                ?? calendar.startOfDay(for: now)
        }
    }
}

enum TokenFormat {
    static func compact(_ value: Int) -> String {
        if value >= 1_000_000_000 {
            return String(format: "%.2fB", Double(value) / 1_000_000_000)
        }
        if value >= 1_000_000 {
            return String(format: "%.2fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fK", Double(value) / 1_000)
        }
        return value.formatted()
    }

    static func currency(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(value < 10 ? 2 : 0)))
    }
}

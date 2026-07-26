import XCTest
@testable import TokenStatsApp

final class AggregationAndPricingTests: XCTestCase {
    func testPricingSeparatesUncachedAndCachedInput() {
        let record = UsageRecord(
            id: "one",
            date: Date(timeIntervalSince1970: 0),
            provider: .codex,
            model: "gpt-5.6-sol",
            inputTokens: 900,
            cachedInputTokens: 100,
            cacheWriteTokens: 40,
            outputTokens: 50
        )

        let cost = PricingCatalog.current.estimatedCost(for: record)

        // 900 * $5/M + 100 * $0.50/M + 40 * $6.25/M + 50 * $30/M
        XCTAssertEqual(cost, 0.0063, accuracy: 0.000_000_1)
    }

    func testExactOpenRouterCostWinsOverEstimate() {
        let record = UsageRecord(
            id: "router",
            date: Date(timeIntervalSince1970: 0),
            provider: .openRouter,
            model: "unknown/model",
            inputTokens: 10,
            cachedInputTokens: 0,
            cacheWriteTokens: 0,
            outputTokens: 20,
            exactCostUSD: 0.42
        )

        XCTAssertEqual(PricingCatalog.current.cost(for: record), 0.42)
    }

    func testLongContextMultiplierUsesWholeRequestInputVolume() {
        let record = UsageRecord(
            id: "long",
            date: Date(timeIntervalSince1970: 0),
            provider: .codex,
            model: "gpt-5.6-sol",
            inputTokens: 30_000,
            cachedInputTokens: 250_000,
            cacheWriteTokens: 0,
            outputTokens: 10_000
        )

        let cost = PricingCatalog.current.estimatedCost(for: record)

        // Long context doubles all input rates and multiplies output by 1.5.
        XCTAssertEqual(cost, 1.0, accuracy: 0.000_001)
    }

    func testDailyAggregationFillsMissingDaysAndSplitsProviders() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = ISO8601DateFormatter().date(from: "2026-07-23T00:00:00Z")!
        let end = ISO8601DateFormatter().date(from: "2026-07-25T23:59:59Z")!
        let records = [
            UsageRecord(id: "c", date: start, provider: .codex, model: "gpt-5.6-sol", inputTokens: 10, cachedInputTokens: 0, cacheWriteTokens: 0, outputTokens: 2),
            UsageRecord(id: "a", date: end, provider: .claude, model: "claude-opus-4-8", inputTokens: 20, cachedInputTokens: 0, cacheWriteTokens: 0, outputTokens: 3)
        ]

        let points = UsageAggregator.daily(records: records, from: start, through: end, calendar: calendar)

        XCTAssertEqual(points.count, 3 * UsageProvider.allCases.count)
        XCTAssertEqual(points.filter { $0.date == calendar.startOfDay(for: start) && $0.provider == .codex }.first?.tokens, 12)
        XCTAssertEqual(points.filter { $0.date == calendar.date(byAdding: .day, value: 1, to: start)! }.map(\.tokens).reduce(0, +), 0)
    }

    func testAllTimeSnapshotReducesLargeHistoryToDailyChartPoints() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = ISO8601DateFormatter().date(from: "2026-04-21T00:00:00Z")!
        let records = (0..<90_000).map { index in
            UsageRecord(
                id: "\(index)",
                date: calendar.date(byAdding: .day, value: index % 96, to: start)!,
                provider: .codex,
                model: "gpt-5.6-sol",
                inputTokens: 100,
                cachedInputTokens: 900,
                cacheWriteTokens: 0,
                outputTokens: 10
            )
        }
        let end = calendar.date(byAdding: .hour, value: 1, to:
            calendar.date(byAdding: .day, value: 95, to: start)!
        )!

        let snapshot = DashboardSnapshot.build(
            allRecords: records,
            range: .all,
            providers: Set(UsageProvider.allCases),
            now: end,
            calendar: calendar
        )

        XCTAssertEqual(snapshot.records.count, 90_000)
        XCTAssertEqual(snapshot.points.count, 96 * UsageProvider.allCases.count)
        XCTAssertEqual(snapshot.modelSummaries.count, 1)
        XCTAssertEqual(snapshot.activeDays, 96)
    }
}

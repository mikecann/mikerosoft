import Foundation

struct DashboardModelSummary: Identifiable, Sendable {
    let model: String
    let tokens: Int
    let costUSD: Double

    var id: String { model }
}

struct DashboardSnapshot: Sendable {
    let records: [UsageRecord]
    let points: [DailyUsagePoint]
    let providerSummaries: [ProviderSummary]
    let modelSummaries: [DashboardModelSummary]
    let sourceRecordCounts: [UsageProvider: Int]
    let totalTokens: Int
    let totalCostUSD: Double
    let cachedTokens: Int
    let activeDays: Int
    let rangeStart: Date
    let rangeEnd: Date
    let unpricedTokens: Int
    let unpricedLabelCount: Int

    static let empty = DashboardSnapshot(
        records: [],
        points: [],
        providerSummaries: UsageProvider.allCases.map {
            ProviderSummary(provider: $0, tokens: 0, costUSD: 0, records: 0)
        },
        modelSummaries: [],
        sourceRecordCounts: [:],
        totalTokens: 0,
        totalCostUSD: 0,
        cachedTokens: 0,
        activeDays: 0,
        rangeStart: Date(),
        rangeEnd: Date(),
        unpricedTokens: 0,
        unpricedLabelCount: 0
    )

    static func build(
        allRecords: [UsageRecord],
        range: DashboardRange,
        providers: Set<UsageProvider>,
        now: Date,
        calendar: Calendar = .current,
        pricing: PricingCatalog = .current
    ) -> DashboardSnapshot {
        let start = range.startDate(relativeTo: now, records: allRecords, calendar: calendar)
        let records = allRecords.filter {
            $0.date >= start && $0.date <= now && providers.contains($0.provider)
        }
        let points = UsageAggregator.daily(
            records: records,
            from: start,
            through: now,
            calendar: calendar,
            pricing: pricing
        ).filter { providers.contains($0.provider) }

        var totalTokens = 0
        var totalCost = 0.0
        var cachedTokens = 0
        var days = Set<Date>()
        var unpricedTokens = 0
        var unpricedLabels = Set<String>()
        var byModel: [String: (tokens: Int, cost: Double)] = [:]

        for record in records {
            let cost = pricing.cost(for: record)
            totalTokens += record.totalTokens
            totalCost += cost
            cachedTokens += record.cachedInputTokens
            days.insert(calendar.startOfDay(for: record.date))
            var model = byModel[record.model] ?? (0, 0)
            model.tokens += record.totalTokens
            model.cost += cost
            byModel[record.model] = model
            if record.exactCostUSD == nil, pricing.pricing(for: record.model) == nil {
                unpricedTokens += record.totalTokens
                unpricedLabels.insert(record.model)
            }
        }

        let models = byModel.map {
            DashboardModelSummary(model: $0.key, tokens: $0.value.tokens, costUSD: $0.value.cost)
        }.sorted { $0.tokens > $1.tokens }

        return DashboardSnapshot(
            records: records,
            points: points,
            providerSummaries: UsageAggregator.providerSummaries(records: records, pricing: pricing),
            modelSummaries: models,
            sourceRecordCounts: Dictionary(grouping: allRecords, by: \.provider).mapValues(\.count),
            totalTokens: totalTokens,
            totalCostUSD: totalCost,
            cachedTokens: cachedTokens,
            activeDays: days.count,
            rangeStart: start,
            rangeEnd: now,
            unpricedTokens: unpricedTokens,
            unpricedLabelCount: unpricedLabels.count
        )
    }
}

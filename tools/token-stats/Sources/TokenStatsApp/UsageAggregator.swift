import Foundation

enum UsageAggregator {
    static func daily(
        records: [UsageRecord],
        from start: Date,
        through end: Date,
        calendar: Calendar = .current,
        pricing: PricingCatalog = .current
    ) -> [DailyUsagePoint] {
        let firstDay = calendar.startOfDay(for: start)
        let lastDay = calendar.startOfDay(for: end)
        var totals: [String: (tokens: Int, cost: Double)] = [:]

        for record in records where record.date >= firstDay && record.date < (calendar.date(byAdding: .day, value: 1, to: lastDay) ?? end) {
            let day = calendar.startOfDay(for: record.date)
            let key = "\(day.timeIntervalSince1970):\(record.provider.rawValue)"
            var value = totals[key] ?? (0, 0)
            value.tokens += record.totalTokens
            value.cost += pricing.cost(for: record)
            totals[key] = value
        }

        var points: [DailyUsagePoint] = []
        var day = firstDay
        while day <= lastDay {
            for provider in UsageProvider.allCases {
                let key = "\(day.timeIntervalSince1970):\(provider.rawValue)"
                let value = totals[key] ?? (0, 0)
                points.append(DailyUsagePoint(date: day, provider: provider, tokens: value.tokens, costUSD: value.cost))
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return points
    }

    static func providerSummaries(records: [UsageRecord], pricing: PricingCatalog = .current) -> [ProviderSummary] {
        UsageProvider.allCases.map { provider in
            let matching = records.filter { $0.provider == provider }
            return ProviderSummary(
                provider: provider,
                tokens: matching.reduce(0) { $0 + $1.totalTokens },
                costUSD: matching.reduce(0) { $0 + pricing.cost(for: $1) },
                records: matching.count
            )
        }
    }
}

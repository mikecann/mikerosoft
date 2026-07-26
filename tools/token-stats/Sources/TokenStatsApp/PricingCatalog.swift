import Foundation

struct ModelPricing {
    let inputPerMillion: Double
    let cachedInputPerMillion: Double
    let cacheWritePerMillion: Double
    let outputPerMillion: Double
    var longContextThreshold: Int? = nil
    var longContextInputMultiplier: Double = 1
    var longContextOutputMultiplier: Double = 1
}

struct PricingCatalog {
    static let current = PricingCatalog()

    // Public API list prices checked on 25 July 2026. These are deliberately
    // local and explicit so a screenshot always has a reproducible estimate.
    private let exact: [String: ModelPricing] = [
        "gpt-5.6-sol": .init(inputPerMillion: 5, cachedInputPerMillion: 0.5, cacheWritePerMillion: 6.25, outputPerMillion: 30, longContextThreshold: 272_000, longContextInputMultiplier: 2, longContextOutputMultiplier: 1.5),
        "gpt-5.6": .init(inputPerMillion: 5, cachedInputPerMillion: 0.5, cacheWritePerMillion: 6.25, outputPerMillion: 30, longContextThreshold: 272_000, longContextInputMultiplier: 2, longContextOutputMultiplier: 1.5),
        "gpt-5.6-terra": .init(inputPerMillion: 2.5, cachedInputPerMillion: 0.25, cacheWritePerMillion: 3.125, outputPerMillion: 15, longContextThreshold: 272_000, longContextInputMultiplier: 2, longContextOutputMultiplier: 1.5),
        "gpt-5.6-luna": .init(inputPerMillion: 1, cachedInputPerMillion: 0.1, cacheWritePerMillion: 1.25, outputPerMillion: 6, longContextThreshold: 272_000, longContextInputMultiplier: 2, longContextOutputMultiplier: 1.5),
        "gpt-5.5": .init(inputPerMillion: 5, cachedInputPerMillion: 0.5, cacheWritePerMillion: 0, outputPerMillion: 30, longContextThreshold: 272_000, longContextInputMultiplier: 2, longContextOutputMultiplier: 1.5),
        "gpt-5.4": .init(inputPerMillion: 2.5, cachedInputPerMillion: 0.25, cacheWritePerMillion: 0, outputPerMillion: 15, longContextThreshold: 272_000, longContextInputMultiplier: 2, longContextOutputMultiplier: 1.5),
        "gpt-5.4-mini": .init(inputPerMillion: 0.75, cachedInputPerMillion: 0.075, cacheWritePerMillion: 0, outputPerMillion: 4.5),
        "gpt-5.3-codex": .init(inputPerMillion: 1.75, cachedInputPerMillion: 0.175, cacheWritePerMillion: 0, outputPerMillion: 14),
        "gpt-5.2": .init(inputPerMillion: 1.75, cachedInputPerMillion: 0.175, cacheWritePerMillion: 0, outputPerMillion: 14),
        "gpt-5.2-codex": .init(inputPerMillion: 1.75, cachedInputPerMillion: 0.175, cacheWritePerMillion: 0, outputPerMillion: 14),
        "gpt-5-codex": .init(inputPerMillion: 1.25, cachedInputPerMillion: 0.125, cacheWritePerMillion: 0, outputPerMillion: 10),
        "gpt-5": .init(inputPerMillion: 1.25, cachedInputPerMillion: 0.125, cacheWritePerMillion: 0, outputPerMillion: 10),
        "claude-fable-5": .init(inputPerMillion: 10, cachedInputPerMillion: 1, cacheWritePerMillion: 12.5, outputPerMillion: 50),
        "claude-mythos-5": .init(inputPerMillion: 10, cachedInputPerMillion: 1, cacheWritePerMillion: 12.5, outputPerMillion: 50),
        "claude-opus-5": .init(inputPerMillion: 5, cachedInputPerMillion: 0.5, cacheWritePerMillion: 6.25, outputPerMillion: 25),
        // Introductory price through 31 August 2026.
        "claude-sonnet-5": .init(inputPerMillion: 2, cachedInputPerMillion: 0.2, cacheWritePerMillion: 2.5, outputPerMillion: 10),
        "claude-opus-4-8": .init(inputPerMillion: 5, cachedInputPerMillion: 0.5, cacheWritePerMillion: 6.25, outputPerMillion: 25),
        "claude-opus-4-7": .init(inputPerMillion: 5, cachedInputPerMillion: 0.5, cacheWritePerMillion: 6.25, outputPerMillion: 25),
        "claude-opus-4-6": .init(inputPerMillion: 3, cachedInputPerMillion: 0.3, cacheWritePerMillion: 3.75, outputPerMillion: 15),
        "claude-sonnet-4-6": .init(inputPerMillion: 3, cachedInputPerMillion: 0.3, cacheWritePerMillion: 3.75, outputPerMillion: 15),
        "claude-sonnet-4-5": .init(inputPerMillion: 3, cachedInputPerMillion: 0.3, cacheWritePerMillion: 3.75, outputPerMillion: 15),
        "claude-haiku-4-5": .init(inputPerMillion: 1, cachedInputPerMillion: 0.1, cacheWritePerMillion: 1.25, outputPerMillion: 5)
    ]

    func pricing(for rawModel: String) -> ModelPricing? {
        let model = rawModel.lowercased()
        if let match = exact[model] { return match }

        // Snapshot suffixes keep the canonical model prefix.
        return exact
            .filter { model.hasPrefix($0.key + "-") }
            .max(by: { $0.key.count < $1.key.count })?
            .value
    }

    func estimatedCost(for record: UsageRecord) -> Double {
        guard let price = pricing(for: record.model) else { return 0 }
        let inputVolume = record.inputTokens + record.cachedInputTokens + record.cacheWriteTokens
        let isLongContext = price.longContextThreshold.map { inputVolume > $0 } ?? false
        let inputMultiplier = isLongContext ? price.longContextInputMultiplier : 1
        let outputMultiplier = isLongContext ? price.longContextOutputMultiplier : 1
        return (
            Double(record.inputTokens) * price.inputPerMillion * inputMultiplier
            + Double(record.cachedInputTokens) * price.cachedInputPerMillion * inputMultiplier
            + Double(record.cacheWriteTokens) * price.cacheWritePerMillion * inputMultiplier
            + Double(record.outputTokens) * price.outputPerMillion * outputMultiplier
        ) / 1_000_000
    }

    func cost(for record: UsageRecord) -> Double {
        record.exactCostUSD ?? estimatedCost(for: record)
    }
}

import Foundation

enum UsageAggregator {
    static func today(overview: UsageOverview, records: [UsageRecord]) -> (UsageOverview, [ModelUsage]) {
        var result = overview
        let successful = records.filter { $0.status == "成功" }
        result.inputTokens = successful.reduce(0) { $0 + $1.inputTokens }
        result.outputTokens = successful.reduce(0) { $0 + $1.outputTokens }
        result.cacheReadTokens = successful.reduce(0) { $0 + $1.cacheReadTokens }
        result.cacheWriteTokens = successful.contains { $0.cacheWriteTokens != nil }
            ? successful.reduce(0) { $0 + ($1.cacheWriteTokens ?? 0) }
            : nil
        result.reasoningTokens = successful.reduce(0) { $0 + $1.reasoningTokens }
        result.todayCost = overview.todayCost ?? successful.reduce(Decimal.zero) { $0 + ($1.cost ?? .zero) }

        let models = Dictionary(grouping: successful, by: \.modelName).map { model, values in
            ModelUsage(
                id: model,
                modelName: model,
                requestCount: values.count,
                totalTokens: values.reduce(0) { $0 + $1.totalTokens },
                cacheReadTokens: values.reduce(0) { $0 + $1.cacheReadTokens },
                cost: values.reduce(Decimal.zero) { $0 + ($1.cost ?? .zero) }
            )
        }.sorted { $0.totalTokens > $1.totalTokens }
        return (result, models)
    }
}

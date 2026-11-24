import Foundation

/// One calendar-day projection for settings and both menu styles. Account quota is deliberately absent.
struct ClaudeHistorySummary {
    struct Total {
        let tokens: Int?
        let costUSD: Double?
        var incompleteRequests: Int = 0
        let hasUnpricedUsage: Bool
    }

    let entries: [CostUsageDailyReport.Entry]
    let chartDays: [CodexTokenActivityDay]
    let today: Total
    let month: Total

    init(days: [CostUsageDailyReport.Entry], updatedAt: Date?, now: Date = Date(), calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: now)
        let dates = (-29...0).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
        let keys = Set(dates.map { CostUsageLocalDay.key(from: $0, calendar: calendar) })
        entries = days.filter { keys.contains($0.date) }.sorted { $0.date < $1.date }
        let grouped = Dictionary(grouping: entries, by: \.date)
        chartDays = dates.map { date in
            let rows = grouped[CostUsageLocalDay.key(from: date, calendar: calendar)] ?? []
            let total = Self.total(rows, available: updatedAt != nil)
            let models = rows.flatMap { $0.modelBreakdowns ?? [] }
            return CodexTokenActivityDay(day: date, totalTokens: total.tokens ?? 0,
                estimatedCostUSD: total.costUSD,
                modelTokenTotals: Dictionary(models.map { ($0.modelName, $0.totalTokens ?? 0) }, uniquingKeysWith: +))
        }
        self.today = Self.total(grouped[CostUsageLocalDay.key(from: now, calendar: calendar)] ?? [], available: updatedAt != nil)
        month = Self.total(entries, available: updatedAt != nil)
    }

    static func hasUnpricedUsage(_ entry: CostUsageDailyReport.Entry) -> Bool {
        (entry.incompleteRequestCount ?? 0) > 0
            || (entry.totalTokens ?? 0) > 0 && entry.costUSD == nil
            || (entry.modelBreakdowns ?? []).contains { $0.hasUnpricedUsage }
    }

    private static func total(_ entries: [CostUsageDailyReport.Entry], available: Bool) -> Total {
        guard available else { return Total(tokens: nil, costUSD: nil, hasUnpricedUsage: false) }
        let tokens = entries.compactMap(\.totalTokens)
        let costs = entries.compactMap(\.costUSD)
        return Total(tokens: entries.isEmpty ? 0 : (tokens.isEmpty ? nil : tokens.reduce(0, +)),
                     costUSD: entries.isEmpty ? 0 : (costs.isEmpty ? nil : costs.reduce(0, +)),
                     incompleteRequests: entries.reduce(0) { $0 + ($1.incompleteRequestCount ?? 0) },
                     hasUnpricedUsage: entries.contains(where: hasUnpricedUsage) || entries.contains { ($0.incompleteRequestCount ?? 0) > 0 })
    }
}

import SwiftUI

/// Compact history shared by both menu styles; reads the existing scan results.
struct MenuTokenHistoryChart: View {
    @ObservedObject var model: MenuBarStatusModel
    let days: [CodexTokenActivityDay]
    let isClaude: Bool
    @State private var hoveredDay: Date?

    private var chartDays: [CodexTokenActivityDay] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let grouped = Dictionary(grouping: days) { calendar.startOfDay(for: $0.day) }
        return (-29...0).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: today) else { return nil }
            let entries = grouped[date] ?? []
            let costs = entries.compactMap(\.estimatedCostUSD)
            return CodexTokenActivityDay(day: date,
                totalTokens: entries.reduce(0) { $0 + max(0, $1.totalTokens) },
                estimatedCostUSD: costs.isEmpty ? nil : costs.reduce(0, +))
        }
    }

    var body: some View {
        let history = chartDays
        let peak = history.map { Double($0.totalTokens) }.max() ?? 0
        let selected = history.first { $0.day == hoveredDay }
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(model.text("近 30 天 Token", "30-day tokens"))
                Spacer(minLength: 4)
            }.foregroundStyle(.secondary)

            HStack(alignment: .bottom, spacing: 3) {
                ForEach(history) { day in
                    let amount = Double(day.totalTokens)
                    let fraction = peak > 0 ? amount / peak : 0
                    RoundedRectangle(cornerRadius: 2)
                        .fill(amount > 0
                              ? (isClaude ? Color.orange : Color.accentColor).opacity(hoveredDay == day.day ? 1 : 0.72)
                              : Color.secondary.opacity(0.18))
                        .frame(maxWidth: .infinity)
                        .frame(height: amount > 0 ? max(5, 48 * fraction) : 3)
                        .frame(height: 50, alignment: .bottom)
                        .contentShape(Rectangle())
                        .onHover { inside in
                            if inside { hoveredDay = day.day }
                            else if hoveredDay == day.day { hoveredDay = nil }
                        }
                        .help(detail(day))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(detail(day))
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(model.text("近 30 天 Token 柱状图", "30-day token bar chart"))
            HStack {
                if let first = history.first { Text(dateLabel(first.day)) }
                Spacer()
                if let last = history.last { Text(dateLabel(last.day)) }
            }.foregroundStyle(.secondary)
            // Reserve the detail row so hovering cannot resize the native menu.
            Text(selected.map(detail) ?? model.text("悬停查看每日 Token 与费用", "Hover for daily tokens and cost"))
                .font(.caption2).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity, minHeight: 16, maxHeight: 16, alignment: .leading)
                .allowsHitTesting(false)
        }
    }

    private func dateLabel(_ day: Date) -> String {
        day.formatted(.dateTime.month().day().locale(Locale(identifier: model.appLanguage.localeIdentifier)))
    }

    private func detail(_ day: CodexTokenActivityDay) -> String {
        let cost = model.estimatedCostText(day.estimatedCostUSD)
        return "\(dateLabel(day.day)) · \(model.compactTokenCountText(day.totalTokens)) Token · \(cost)"
    }
}

import SwiftUI

/// Compact history shared by both menu styles; reads the existing scan results.
struct MenuTokenHistoryChart: View {
    @ObservedObject var model: MenuBarStatusModel
    let days: [CodexTokenActivityDay]
    let isClaude: Bool
    var settingsStyle = false
    var unpricedDays: Set<String> = []
    var incompleteDays: Set<String> = []
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
                estimatedCostUSD: costs.isEmpty ? nil : costs.reduce(0, +),
                modelTokenTotals: Dictionary(entries.flatMap { $0.modelTokenTotals.map { ($0.key, $0.value) } },
                                             uniquingKeysWith: +),
                hasUnpricedUsage: entries.contains { $0.costIsPartial })
        }
    }

    var body: some View {
        let history = chartDays
        let peak = history.map { Double($0.totalTokens) }.max() ?? 0
        let selected = history.first { $0.day == hoveredDay }
        VStack(alignment: .leading, spacing: 5) {
            if !settingsStyle { HStack {
                Text(model.text("近 30 天 Token", "30-day tokens"))
                Spacer(minLength: 4)
            }.foregroundStyle(.secondary) }

            HStack(alignment: .bottom, spacing: 3) {
                ForEach(history) { day in
                    let amount = Double(day.totalTokens)
                    let fraction = peak > 0 ? amount / peak : 0
                    bar(day, peak: peak)
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
            if settingsStyle {
                Text(selected.map { day in
                    day.modelTokenTotals.sorted { $0.key < $1.key }
                        .map { "\($0.key) · \(model.compactTokenCountText($0.value)) token" }.joined(separator: "\n")
                } ?? "")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)
                .allowsHitTesting(false)
            }
        }
    }

    private func dateLabel(_ day: Date) -> String {
        day.formatted(.dateTime.month().day().locale(Locale(identifier: model.appLanguage.localeIdentifier)))
    }

    private func detail(_ day: CodexTokenActivityDay) -> String {
        let incomplete = incompleteDays.contains(CostUsageLocalDay.key(from: day.day))
        if incomplete && day.totalTokens == 0 { return dateLabel(day.day) + model.text(" · 用量不完整", " · Incomplete usage") }
        let cost = model.estimatedCostText(day.estimatedCostUSD,
                                           partial: incomplete || day.costIsPartial || unpricedDays.contains(CostUsageLocalDay.key(from: day.day)))
        return "\(dateLabel(day.day)) · \(incomplete ? "≥" : "")\(model.compactTokenCountText(day.totalTokens)) Token · \(cost)"
    }

    @ViewBuilder private func bar(_ day: CodexTokenActivityDay, peak: Double) -> some View {
        let totals = day.modelTokenTotals.filter { $0.value > 0 }.sorted { $0.key < $1.key }
        if settingsStyle, !totals.isEmpty {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    ForEach(totals, id: \.key) { name, tokens in
                        Rectangle().fill(modelColor(name).opacity(hoveredDay == day.day ? 1 : 0.8))
                            .frame(height: geometry.size.height * Double(tokens) / Double(max(1, day.totalTokens)))
                    }
                }.frame(maxHeight: .infinity, alignment: .bottom)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
            }
        } else {
            RoundedRectangle(cornerRadius: 2).fill(day.totalTokens > 0
                ? Color.accentColor.opacity(hoveredDay == day.day ? 1 : 0.72)
                : (incompleteDays.contains(CostUsageLocalDay.key(from: day.day)) ? ASBTone.caution.lamp : Color.secondary).opacity(0.35))
        }
    }

    private func modelColor(_ name: String) -> Color {
        let key = name.lowercased()
        // Model hues avoid red, yellow and green, which are reserved for the light.
        if key.contains("opus") { return .purple }
        if key.contains("sonnet") { return .indigo }
        if key.contains("haiku") { return .teal }
        return .secondary
    }
}

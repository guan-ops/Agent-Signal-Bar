import SwiftUI

/// The original Codex settings chart, shared with Claude using provider-scoped display data.
struct UsageTokenHistoryChart: View {
    @ObservedObject var model: MenuBarStatusModel
    let days: [CodexTokenActivityDay]
    var peakTokens: Int? = nil
    var prominent = false
    var isClaude = false
    var unpricedDays: Set<String> = []
    var incompleteDays: Set<String> = []
    @State private var hoveredTokenActivityDayID: TimeInterval?
    @Environment(\.colorScheme) private var colorScheme
    private var settingsBodyStrongFont: Font { UsageSettingsTypography(language: model.appLanguage).strong }
    private var settingsDetailFont: Font { UsageSettingsTypography(language: model.appLanguage).detail }
    private var settingsDetailStrongFont: Font { settingsDetailFont.weight(.semibold) }
    var body: some View {
        tokenUsageBarChart(days: days, peakTokens: peakTokens ?? days.map(\.totalTokens).max() ?? 0, prominent: prominent)
    }
    private func isIncomplete(_ day: CodexTokenActivityDay) -> Bool { incompleteDays.contains(CostUsageLocalDay.key(from: day.day)) }
    private func tokenUsageBarChart(
        days: [CodexTokenActivityDay],
        peakTokens: Int,
        prominent: Bool = false
    ) -> some View {
        let hoveredDay = hoveredTokenActivityDay(in: days)

        return VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geometry in
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(days) { day in
                        tokenUsageBar(
                            day: day,
                            peakTokens: peakTokens,
                            prominent: prominent,
                            isSelected: hoveredTokenActivityDayID == day.id
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case let .active(location):
                        guard !days.isEmpty, geometry.size.width > 0 else { return }
                        let stride = (geometry.size.width + 3) / CGFloat(days.count)
                        let index = min(max(Int(location.x / stride), 0), days.count - 1)
                        hoveredTokenActivityDayID = days[index].id
                    case .ended:
                        hoveredTokenActivityDayID = nil
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 48, maxHeight: 48, alignment: .bottom)
            .padding(.top, 2)

            HStack(alignment: .firstTextBaseline) {
                if let firstDay = days.first {
                    Text(tokenActivityShortDateText(firstDay.day))
                        .font(settingsDetailFont)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                if let lastDay = days.last {
                    Text(tokenActivityShortDateText(lastDay.day))
                        .font(settingsDetailFont)
                        .foregroundStyle(.tertiary)
                }
            }

            TokenUsageInlineDetail {
                if let hoveredDay {
                    tokenUsageDayDetail(for: hoveredDay)
                } else {
                    tokenUsageHoverHint()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private struct TokenUsageBarSegment: Identifiable {
        let model: String
        let tokens: Int

        var id: String { model }
    }

    private struct TokenUsageBarSlice: Identifiable {
        let segment: TokenUsageBarSegment
        let height: CGFloat

        var id: String { segment.id }
    }

    private func tokenUsageBar(
        day: CodexTokenActivityDay,
        peakTokens: Int,
        prominent: Bool = false,
        isSelected: Bool = false
    ) -> some View {
        let normalized = peakTokens > 0 ? CGFloat(day.totalTokens) / CGFloat(peakTokens) : 0
        let barHeight = day.totalTokens > 0 ? max(5, normalized * 44) : 4
        let opacity = day.totalTokens > 0 ? 0.35 + (normalized * 0.55) : 0.12
        let segments = tokenUsageBarSegments(for: day)
        let slices = tokenUsageBarSlices(segments: segments, barHeight: barHeight)

        return ZStack(alignment: .bottom) {
            if isSelected {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(Color.secondary.opacity(colorScheme == .dark ? 0.18 : 0.14))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            VStack(spacing: 0) {
                Spacer(minLength: 0)

                ZStack(alignment: .top) {
                    if day.totalTokens > 0 {
                        VStack(spacing: 0) {
                            ForEach(slices) { slice in
                                Rectangle()
                                    .fill(tokenUsageModelColor(
                                        slice.segment.model,
                                        normalized: normalized,
                                        prominent: prominent,
                                        isSelected: isSelected
                                    ))
                                    .frame(height: slice.height)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                    } else {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill((isIncomplete(day) ? ASBTone.caution.lamp : Color.secondary).opacity(opacity))
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: barHeight)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 48, maxHeight: 48, alignment: .bottom)
        .contentShape(Rectangle())
        .accessibilityLabel(tokenUsageHelpText(for: day))
    }

    private func tokenUsageBarSlices(
        segments: [TokenUsageBarSegment],
        barHeight: CGFloat
    ) -> [TokenUsageBarSlice] {
        guard segments.isEmpty == false else { return [] }

        let segmentTotal = max(segments.map(\.tokens).reduce(0, +), 1)
        var slices = segments
            .reversed()
            .map { segment in
                let rawHeight = barHeight * CGFloat(segment.tokens) / CGFloat(segmentTotal)
                return TokenUsageBarSlice(
                    segment: segment,
                    height: max(rawHeight, tokenUsageMinimumVisibleSegmentHeight(
                        rawHeight: rawHeight,
                        barHeight: barHeight,
                        segmentCount: segments.count
                    ))
                )
            }

        let totalHeight = slices.map(\.height).reduce(0, +)
        guard totalHeight > barHeight,
              let tallestIndex = slices.indices.max(by: { slices[$0].height < slices[$1].height })
        else {
            return slices
        }

        let overflow = totalHeight - barHeight
        let tallest = slices[tallestIndex]
        slices[tallestIndex] = TokenUsageBarSlice(
            segment: tallest.segment,
            height: max(1, tallest.height - overflow)
        )
        return slices
    }

    private func tokenUsageMinimumVisibleSegmentHeight(
        rawHeight: CGFloat,
        barHeight: CGFloat,
        segmentCount: Int
    ) -> CGFloat {
        guard segmentCount > 1,
              rawHeight > 0,
              barHeight >= 12
        else {
            return rawHeight
        }
        return min(3, max(1.5, barHeight * 0.055))
    }

    private func tokenUsageBarSegments(for day: CodexTokenActivityDay) -> [TokenUsageBarSegment] {
        guard day.totalTokens > 0 else {
            return []
        }

        var totals = day.modelTokenTotals.filter { _, tokens in tokens > 0 }
        let knownTotal = totals.values.reduce(0, +)
        if day.totalTokens > knownTotal {
            totals["__other__"] = day.totalTokens - knownTotal
        }
        if totals.isEmpty {
            totals["__other__"] = day.totalTokens
        }

        return totals
            .sorted { lhs, rhs in
                let leftRank = tokenUsageModelSortRank(lhs.key)
                let rightRank = tokenUsageModelSortRank(rhs.key)
                if leftRank != rightRank {
                    return leftRank < rightRank
                }
                return lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending
            }
            .map { TokenUsageBarSegment(model: $0.key, tokens: $0.value) }
    }

    private func tokenUsageModelSortRank(_ modelName: String) -> Int {
        if isClaude {
            let name = modelName.lowercased()
            return name.contains("opus") ? 0 : name.contains("sonnet") ? 1 : name.contains("haiku") ? 2 : 99
        }
        return CodexModelPresentation.forModel(modelName).sortRank
    }

    private func tokenUsageModelColor(
        _ modelName: String,
        normalized: CGFloat,
        prominent: Bool,
        isSelected: Bool
    ) -> Color {
        let name = modelName.lowercased()
        let baseColor: Color = isClaude
            ? (name.contains("opus") ? .purple : name.contains("sonnet") ? .indigo : name.contains("haiku") ? .teal : .secondary)
            : CodexModelPresentation.forModel(modelName).color

        let baseOpacity = prominent
            ? 0.48 + (normalized * 0.42)
            : 0.42 + (normalized * 0.48)
        return baseColor.opacity(isSelected ? min(baseOpacity + 0.18, 1) : baseOpacity)
    }

    private func tokenUsageHelpText(for day: CodexTokenActivityDay) -> String {
        if isIncomplete(day) { return tokenUsageDaySummaryText(for: day) + model.text(" · 用量不完整", " · Incomplete usage") }
        let summary = model.text(
            "\(tokenActivityDateText(day.day))：\(model.compactTokenCountText(day.totalTokens)) 个 Token",
            "\(tokenActivityDateText(day.day)): \(model.compactTokenCountText(day.totalTokens)) tokens"
        )
        let breakdown = tokenUsageBarSegments(for: day)
            .filter { $0.model != "__other__" }
            .map { "\(tokenUsageModelDisplayName($0.model)): \(model.compactTokenCountText($0.tokens))" }
            .joined(separator: " / ")

        return breakdown.isEmpty ? summary : "\(summary)\n\(breakdown)"
    }

    private func tokenUsageModelDisplayName(_ modelName: String) -> String {
        if modelName == "__other__" { return model.text("其他", "Other") }
        return isClaude ? modelName : CodexModelPresentation.forModel(modelName).displayName
    }

    private func tokenUsageDaySummaryText(for day: CodexTokenActivityDay) -> String {
        let cost = model.estimatedCostText(day.estimatedCostUSD, partial: isIncomplete(day) || day.costIsPartial || unpricedDays.contains(CostUsageLocalDay.key(from: day.day)))
        if isIncomplete(day), day.totalTokens == 0 { return tokenActivityShortDateText(day.day) + model.text("：用量不完整", ": Incomplete usage") }
        return model.text(
            "\(tokenActivityShortDateText(day.day))：\(cost) · \(model.compactTokenCountText(day.totalTokens)) token",
            "\(tokenActivityShortDateText(day.day)): \(cost) · \(model.compactTokenCountText(day.totalTokens)) tokens"
        )
    }

    private func tokenUsageSegmentCostText(
        _ segment: TokenUsageBarSegment,
        day: CodexTokenActivityDay
    ) -> String? {
        if let cost = day.modelEstimatedCostTotals[segment.model] {
            return tokenActivityCurrencyText(cost, partial: (day.modelUnpricedTokenTotals?[segment.model] ?? 0) > 0)
        }
        return nil
    }

    private func tokenUsageDayDetail(for day: CodexTokenActivityDay) -> some View {
        let segments = tokenUsageBarSegments(for: day)
        let visibleSegments = segments.filter { $0.tokens > 0 }

        return VStack(alignment: .leading, spacing: 7) {
            Text(tokenUsageDaySummaryText(for: day))
                .font(settingsBodyStrongFont)
                .foregroundStyle(.primary.opacity(0.9))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.78)

            if isIncomplete(day) {
                Text(model.text("用量不完整；仅显示已确认小计", "Incomplete usage; confirmed subtotal only")).font(settingsDetailFont).foregroundStyle(ASBTone.caution.foreground)
            }
            if visibleSegments.isEmpty {
                Text(model.text("暂无模型明细", "No model details"))
                    .font(settingsDetailFont)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(visibleSegments) { segment in
                        tokenUsageModelDetailRow(segment, day: day)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .topLeading)
    }

    private func tokenUsageHoverHint() -> some View {
        Text(model.text("悬停在柱形图上查看详情", "Hover over a bar to view details"))
            .font(settingsDetailFont)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .allowsHitTesting(false)
    }

    private func tokenUsageModelDetailRow(
        _ segment: TokenUsageBarSegment,
        day: CodexTokenActivityDay
    ) -> some View {
        let percent = day.totalTokens > 0
            ? Int((Double(segment.tokens) / Double(day.totalTokens) * 100).rounded())
            : 0
        let cost = tokenUsageSegmentCostText(segment, day: day)
        let detailText = [
            cost,
            "\(model.compactTokenCountText(segment.tokens)) token",
            "\(percent)%"
        ]
            .compactMap { $0 }
            .joined(separator: " · ")
        let modeDetailText = tokenUsageModelModeDetailText(segment.model, day: day)

        return HStack(alignment: .top, spacing: 7) {
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(tokenUsageModelColor(
                    segment.model,
                    normalized: 1,
                    prominent: false,
                    isSelected: true
                ))
                .frame(width: 3, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(tokenUsageModelDisplayName(segment.model))
                    .font(settingsDetailStrongFont)
                    .lineLimit(1)

                Text(detailText)
                    .font(settingsDetailFont)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)

                if let modeDetailText {
                    Text(modeDetailText)
                        .font(settingsDetailFont)
                        .foregroundStyle(.secondary.opacity(0.92))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
            }
        }
    }

    private func tokenUsageModelModeDetailText(
        _ modelName: String,
        day: CodexTokenActivityDay
    ) -> String? {
        guard modelName != "__other__" else { return nil }
        let standardTokens = day.modelStandardTokenTotals[modelName] ?? 0
        let priorityTokens = day.modelPriorityTokenTotals[modelName] ?? 0
        guard standardTokens > 0 || priorityTokens > 0 else { return nil }

        let standard = tokenUsageModePiece(
            label: model.text("标准", "Std"),
            tokens: standardTokens,
            cost: day.modelStandardEstimatedCostTotals[modelName],
            partial: (day.modelStandardUnpricedTokenTotals?[modelName] ?? 0) > 0
        )
        let priority = tokenUsageModePiece(
            label: model.text("快速", "Fast"),
            tokens: priorityTokens,
            cost: day.modelPriorityEstimatedCostTotals[modelName],
            partial: (day.modelPriorityUnpricedTokenTotals?[modelName] ?? 0) > 0
        )
        return [standard, priority]
            .compactMap { $0 }
            .joined(separator: " / ")
    }

    private func tokenUsageModePiece(
        label: String,
        tokens: Int,
        cost: Double?,
        partial: Bool
    ) -> String? {
        guard tokens > 0 else { return nil }
        var parts: [String] = [label]
        if let cost {
            parts.append(tokenActivityCurrencyText(cost, partial: partial))
        }
        parts.append("\(model.compactTokenCountText(tokens)) token")
        return parts.joined(separator: " ")
    }

    private func hoveredTokenActivityDay(in days: [CodexTokenActivityDay]) -> CodexTokenActivityDay? {
        guard let hoveredTokenActivityDayID else { return nil }
        return days.first { $0.id == hoveredTokenActivityDayID }
    }

    private func tokenActivityCurrencyText(_ value: Double?, partial: Bool = false) -> String {
        model.estimatedCostText(value, partial: partial)
    }

    private func tokenActivityShortDateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: model.appLanguage.localeIdentifier)
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter.string(from: date)
    }

    private func tokenActivityDateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: model.appLanguage.localeIdentifier)
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

}

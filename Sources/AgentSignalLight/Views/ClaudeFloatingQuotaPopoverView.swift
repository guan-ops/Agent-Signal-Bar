import SwiftUI

/// Claude values/actions in the same quota-panel surface used by Codex.
struct ClaudeFloatingQuotaPopoverView: View {
    @ObservedObject var model: MenuBarStatusModel
    @ObservedObject private var support: ClaudeSupportModel
    init(model: MenuBarStatusModel) { self.model = model; self.support = model.claudeSupport }
    private var scrollHeight: CGFloat? {
        let snapshot = support.snapshot
        let rows = snapshot?.windows.count ?? 0
        let extras = [snapshot?.extraUsed != nil, snapshot?.prepaidBalance != nil, snapshot?.cloudCredits != nil,
                      snapshot?.resetInventory != nil, snapshot?.subscription != nil].filter { $0 }.count
        // Extra provider windows use the same rows, bounded to the screen instead of a different layout.
        return rows > 2 || extras > 1 ? min(550, CGFloat(176 + rows * 47 + extras * 56)) : nil
    }
    private var context: String {
        guard let snapshot = support.snapshot else { return model.text("账户未验证", "Account unverified") }
        return [support.hidePersonalInfo ? nil : snapshot.email, snapshot.plan, snapshot.source].compactMap { $0 }.joined(separator: " · ")
    }
    var body: some View {
        FloatingUsagePanel(scrollHeight: scrollHeight) {
            FloatingUsageIdentity(title: model.text("Claude 配额", "Claude quota"), context: context,
                detail: support.snapshot.map { model.quotaUpdatedText(for: $0.updatedAt) },
                refreshLabel: model.text("刷新额度", "Refresh quota"), isRefreshing: support.isRefreshing,
                refresh: { support.refresh(force: true) })
            if model.claudeFloatingBadgeText == "—" {
                Text(model.claudeFloatingQuotaMessage).font(.system(size: 11, weight: .medium)).foregroundStyle(ASBTone.caution.foreground)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array((support.snapshot?.windows ?? []).enumerated()), id: \.element.id) { index, window in
                if index > 0 { divider }
                FloatingUsageChoiceRow(title: model.claudeQuotaTitleLine(window),
                    subtitle: model.claudeQuotaResetText(window),
                    isSelected: model.claudeFloatingQuotaWindowID == window.id,
                    remainingPercent: 100 - window.usedPercent,
                    action: { model.selectClaudeFloatingQuotaWindow(window.id) })
            }
            divider
            choice("automatic", title: model.text("自动选择额度窗口", "Automatic quota window"), subtitle: model.text("优先显示最紧张的有效窗口", "Show the most constrained available window"))
            if support.snapshot?.hasExtraBudget == true {
                divider
                choice("extra_usage", title: model.text("角标显示额外用量预算", "Show extra usage budget"), subtitle: model.text("显示预算剩余比例", "Show remaining monthly budget percent"))
            }
            if support.snapshot?.prepaidBalance != nil {
                divider
                choice("prepaid", title: model.text("角标显示预充值余额", "Show prepaid balance"), subtitle: model.text("显示来源返回的实际余额", "Show the reported balance"))
            }
            divider
            ClaudeCompactBalancesView(model: model, support: support)
        }
    }
    private var divider: some View { Divider() }
    private func choice(_ id: String, title: String, subtitle: String) -> some View {
        FloatingUsageChoiceRow(title: title, subtitle: subtitle, isSelected: model.claudeFloatingQuotaWindowID == id,
                              action: { model.selectClaudeFloatingQuotaWindow(id) })
    }
}

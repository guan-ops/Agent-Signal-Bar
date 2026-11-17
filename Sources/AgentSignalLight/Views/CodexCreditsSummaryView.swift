import SwiftUI

/// Shared by settings, both menu presentations and the floating quota panel.
struct CodexCreditsSummaryView: View {
    @ObservedObject var model: MenuBarStatusModel

    var body: some View {
        UsageBalanceSection(title: model.codexCreditsTitle,
                            value: model.latestCodexCredits.map { model.codexCreditNumber($0.remaining) + " credits" } ?? "—") {
            if let credits = model.latestCodexCredits {
                if let used = credits.used, let limit = credits.limit {
                    Text(model.text("已用 ", "Used ") + model.codexCreditNumber(used) + " / " + model.codexCreditNumber(limit) + " credits")
                }
                if credits.limit != nil, let balance = credits.balance {
                    Text(model.text("另有余额 ", "Separate balance ") + model.codexCreditNumber(balance) + " credits")
                }
                if let reset = credits.resetsAt {
                    Text(model.text("重置 ", "Resets ") + model.localizedDateTimeString(for: reset))
                }
                Text(model.text("更新 ", "Updated ") + model.localizedDateTimeString(for: credits.updatedAt))
                    .font(.caption2).foregroundStyle(.secondary)
                if model.codexCreditsAreStale {
                    Text(model.text("上次读取结果；刷新后才能自动切换角标。", "Previous balance; refresh before automatic badge switching."))
                        .foregroundStyle(.orange)
                } else if !model.isClaudeFloatingUsage, model.latestAgentQuota != nil, model.codexFloatingCredits != nil {
                    Text(model.text("订阅额度已用完，角标显示 Credits 余额。", "Plan limit reached; the badge shows credits."))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(model.text("当前来源尚未提供余额。", "The current source has not provided a balance."))
                    .foregroundStyle(.secondary)
            }
        }.font(.caption).fixedSize(horizontal: false, vertical: true)
    }
}

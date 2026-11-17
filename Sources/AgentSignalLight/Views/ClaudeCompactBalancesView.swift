import SwiftUI

/// Compact balances in menus and floating panels. Full account controls stay in Usage settings.
struct ClaudeCompactBalancesView: View {
    @ObservedObject var model: MenuBarStatusModel
    @ObservedObject var support: ClaudeSupportModel
    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            if let snapshot = support.snapshot {
                VStack(alignment: .leading, spacing: 7) {
                    if snapshot.extraUsed != nil || snapshot.extraLimit != nil {
                        UsageBalanceSection(title: model.text("月预算剩余", "Monthly budget left"), value: snapshot.extraRemaining.map { money($0, snapshot.extraCurrency) } ?? "—") {
                            Text(model.claudeFloatingExtraUsageText ?? "—").foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    if let balance = snapshot.prepaidBalance {
                        UsageBalanceSection(title: model.text("预充值余额", "Prepaid balance"), value: money(balance, snapshot.prepaidCurrency)) { EmptyView() }
                    }
                    if let cloud = snapshot.cloudCredits {
                        UsageBalanceSection(title: model.text("云任务赠送额度", "Cloud credits"), value: cloud.isAvailable(at: context.date) ? money(cloud.remaining, "USD") : model.text("不可用", "Unavailable")) {
                            if let expiry = cloud.expiresAt { Text(model.text("到期 ", "Expires ") + model.localizedDateTimeString(for: expiry)).font(.caption2).foregroundStyle(.secondary) }
                        }
                    }
                    if support.quotaIssue == nil, snapshot.isFresh(at: context.date), let inventory = snapshot.resetInventory {
                        let available = inventory.available(at: context.date)
                        UsageBalanceSection(title: model.text("限额重置次数", "Limit resets"), value: model.text("\(available.count) 次可用", "\(available.count) available")) {
                            if let expiry = available.compactMap({ $0 }).min() { Text(model.text("最近到期 ", "Next expiry ") + model.localizedDateTimeString(for: expiry)).font(.caption2).foregroundStyle(.secondary) }
                        }
                    }
                    if let subscription = snapshot.subscription, let date = subscription.expiresAt ?? subscription.renewsAt {
                        UsageBalanceSection(title: subscription.expiresAt == nil ? model.text("续费日期", "Renews") : model.text("订阅到期", "Subscription ends"), value: billingDate(date, dateOnly: subscription.isDateOnly)) { EmptyView() }
                    }
                    if support.quotaIssue != nil || !snapshot.isFresh(at: context.date) {
                        Text(model.text("上次读取结果；等待刷新。", "Previous capture; awaiting refresh.")).font(.caption2).foregroundStyle(.orange)
                    }
                }
            }
        }
    }
    private func money(_ amount: Double, _ currency: String) -> String {
        amount.formatted(.currency(code: currency).presentation(.isoCode).locale(Locale(identifier: model.appLanguage.localeIdentifier)))
    }
    private func billingDate(_ date: Date, dateOnly: Bool) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: model.appLanguage.localeIdentifier)
        f.dateStyle = .medium; f.timeStyle = dateOnly ? .none : .short
        f.timeZone = dateOnly ? TimeZone(secondsFromGMT: 0) : .current
        return f.string(from: date)
    }
}

import SwiftUI
import Charts

struct ClaudeEntitlementsView: View {
    @ObservedObject var model: MenuBarStatusModel
    @ObservedObject var support: ClaudeSupportModel
    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            if let snapshot = support.snapshot {
                VStack(alignment: .leading, spacing: 8) {
                    if snapshot.extraUsed != nil || snapshot.extraLimit != nil {
                        Text(model.text("额外用量月预算", "Monthly extra usage budget")).fontWeight(.semibold)
                        Text(model.claudeFloatingExtraUsageText ?? "—")
                        if let percent = snapshot.extraRemainingPercent, let remaining = snapshot.extraRemaining {
                            ProgressView(value: 100 - percent, total: 100)
                            Text(model.text("预算剩余 ", "Budget remaining ") + money(remaining, snapshot.extraCurrency))
                            Text(model.text("月初重置时间为推算，以 Claude 用量页为准。", "Calendar-month rollover is inferred; check Claude's Usage page."))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    if let balance = snapshot.prepaidBalance {
                        row(model.text("预充值余额", "Prepaid usage balance"), money(balance, snapshot.prepaidCurrency))
                    }
                    if let cloud = snapshot.cloudCredits {
                        let available = cloud.isAvailable(at: context.date)
                        row(model.text("云任务赠送额度", "Cloud credits"), available ? money(cloud.remaining, "USD") : model.text("已过期或不可用", "Expired or unavailable"))
                        if let expiry = cloud.expiresAt {
                            Text(model.text("到期 ", "Expires ") + model.localizedDateTimeString(for: expiry)).foregroundStyle(.secondary)
                        }
                    }
                    if support.quotaIssue == nil, snapshot.isFresh(at: context.date), let inventory = snapshot.resetInventory {
                        let available = inventory.available(at: context.date)
                        row(model.text("限额重置次数", "Limit resets"), model.text("\(available.count) 次可用", "\(available.count) available"))
                        if let expiry = available.compactMap({ $0 }).min() {
                            Text(model.text("最近到期 ", "Next expiry ") + model.localizedDateTimeString(for: expiry)).foregroundStyle(.secondary)
                        }
                        Link(model.text("前往 Claude 使用重置", "Use a reset in Claude"), destination: URL(string: "https://claude.ai/settings/usage")!)
                    }
                    if let subscription = snapshot.subscription, let date = subscription.expiresAt ?? subscription.renewsAt {
                        row(subscription.expiresAt == nil ? model.text("续费日期", "Renews") : model.text("订阅到期", "Subscription ends"), billingDate(date, dateOnly: subscription.isDateOnly))
                    }
                    if support.quotaIssue != nil || !snapshot.isFresh(at: context.date) {
                        Text(model.text("以上为上次读取结果。", "Values above are from the previous capture.")).foregroundStyle(.orange)
                    }
                }.font(.caption).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private func money(_ amount: Double, _ currency: String) -> String {
        amount.formatted(.currency(code: currency).presentation(.isoCode).locale(Locale(identifier: model.appLanguage.localeIdentifier)))
    }
    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) { Text(title).fontWeight(.semibold); Spacer(minLength: 4); Text(value).monospacedDigit() }
    }
    private func billingDate(_ date: Date, dateOnly: Bool) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: model.appLanguage.localeIdentifier)
        formatter.dateStyle = .medium; formatter.timeStyle = dateOnly ? .none : .short
        formatter.timeZone = dateOnly ? TimeZone(secondsFromGMT: 0) : .current
        return formatter.string(from: date)
    }
}

struct ClaudeQuotaHistoryView: View {
    @ObservedObject var model: MenuBarStatusModel
    @ObservedObject var support: ClaudeSupportModel
    @State private var selected = "five_hour"
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.text("额度历史与预测", "Quota history & forecast")).fontWeight(.semibold)
            if let snapshot = support.snapshot, snapshot.credentialID.hasPrefix("cli-unverified-") {
                Text(model.text("CLI 未提供可验证的账号，暂不保存额度历史。", "CLI account ownership is unverified; quota history is not recorded."))
                    .foregroundStyle(.secondary)
            } else if support.quotaHistoryEnabled, let snapshot = support.snapshot {
                let windows = snapshot.historyWindows
                let selection = windows.contains { $0.id == selected } ? selected : windows.first?.id ?? selected
                if !windows.isEmpty {
                    Picker(model.text("额度窗口", "Quota window"), selection: Binding(get: { selection }, set: { selected = $0 })) {
                        ForEach(windows) { window in Text(model.localizedClaudeText(window.title)).tag(window.id) }
                    }
                }
                let rows = support.quotaSamples(windowID: selection)
                if rows.count >= 2 {
                    Chart(rows) { row in
                        LineMark(x: .value("Time", row.date), y: .value("Used %", row.usedPercent))
                        PointMark(x: .value("Time", row.date), y: .value("Used %", row.usedPercent)).symbolSize(10)
                    }.chartYScale(domain: 0...100).frame(height: 110)
                    .accessibilityLabel(model.text("当前账号额度已用百分比历史", "Observed quota usage for this account"))
                } else {
                    Text(model.text("开始记录当前账号的真实额度读数。", "Recording observed quota for the current account."))
                        .foregroundStyle(.secondary)
                }
                if let forecast = support.quotaForecast(windowID: selection) {
                    Text(forecast.willLastToReset ? model.text("按最近消耗速度，预计可撑到重置。", "At the recent pace, quota is expected to last until reset.")
                         : model.text("按最近消耗速度，预计用尽：", "Estimated exhaustion at the recent pace: ") + model.localizedDateTimeString(for: forecast.exhaustionAt))
                        .foregroundStyle(forecast.willLastToReset ? Color.secondary : Color.orange)
                } else {
                    Text(model.text("至少 3 次有效采样、跨度 5 分钟且有消耗变化后显示估算。", "Estimates need at least 3 valid samples spanning 5 minutes with a change in usage."))
                        .foregroundStyle(.secondary)
                }
            }
            DisclosureGroup(model.text("提醒与历史设置", "Notifications & history")) {
                VStack(alignment: .leading, spacing: 7) {
                    Toggle(model.text("保存本机额度历史", "Keep local quota history"), isOn: $support.quotaHistoryEnabled)
                    Toggle(model.text("额度不足时提醒", "Warn when quota runs low"), isOn: noticeBinding(\.quotaWarningsEnabled))
                    Picker(model.text("提醒阈值", "Warning threshold"), selection: $support.warningThreshold) {
                        ForEach([10, 20, 30, 50], id: \.self) { Text("\($0)%").tag($0) }
                    }
                    Toggle(model.text("确认额度恢复时提醒", "Notify when quota recovers"), isOn: noticeBinding(\.resetNotificationsEnabled))
                    Toggle(model.text("预计重置前用尽时提醒", "Warn if quota may run out before reset"), isOn: noticeBinding(\.predictionWarningsEnabled))
                    Toggle(model.text("隐藏个人信息", "Hide personal information"), isOn: $support.hidePersonalInfo)
                    Text(model.text("按账号与来源分开记录；预测仅为估算。10% 的低额度提醒始终跟随已启用的不足提醒。", "History stays separate by account and source. Forecasts are estimates. Enabled low-quota alerts also include 10%."))
                        .font(.caption2).foregroundStyle(.secondary)
                    Button(model.text("清除本机额度历史", "Clear local quota history")) { support.clearQuotaHistory() }
                }.padding(.top, 5)
            }
        }.font(.caption).controlSize(.small)
    }
    private func noticeBinding(_ key: ReferenceWritableKeyPath<ClaudeSupportModel, Bool>) -> Binding<Bool> {
        Binding(get: { support[keyPath: key] }, set: { value in support[keyPath: key] = value; if value { support.requestNotificationPermission() } })
    }
}

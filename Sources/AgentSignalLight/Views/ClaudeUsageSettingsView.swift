import SwiftUI
import AppKit

/// Claude data/actions adapted to the same settings components used by Codex.
struct ClaudeUsageSettingsView: View {
    @ObservedObject var model: MenuBarStatusModel
    @ObservedObject var support: ClaudeSupportModel
    enum Section { case account, quota, balances, history }
    var section: Section? = nil
    var accountDetailsExpanded: Binding<Bool>? = nil
    let onConnections: () -> Void
    @State private var showSettings = false
    @State private var showDays = false

    private var detailsBinding: Binding<Bool> { accountDetailsExpanded ?? $showSettings }
    private var busy: Bool { support.accountActionInProgress }
    private var typography: UsageSettingsTypography { .init(language: model.appLanguage) }
    private var titleFont: Font { typography.title }
    private var bodyFont: Font { typography.body }
    private var detailFont: Font { typography.detail }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let section {
                switch section {
                case .account: accountCard
                case .quota: quotaCard
                case .balances: balancesCard
                case .history: historyCard
                }
            } else {
                accountCard
                quotaCard
                balancesCard
                historyCard
                CodexUsageDetailsView(details: support.historyDetails, isLoading: support.isHistoryScanning,
                                  text: model.text, tokens: model.compactTokenCountText,
                                  formatCost: { model.estimatedCostText($0, partial: $1) }, provider: .claude)
            }
        }
        .font(bodyFont)
        .controlSize(.small)
        .disclosureGroupStyle(UsageDetailsDisclosureStyle(
            expandedText: model.text("已展开", "Expanded"), collapsedText: model.text("已收起", "Collapsed")))
        .task {
            guard section == nil else { return }
            support.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                if !Task.isCancelled { support.refresh() }
            }
        }
    }

    var accountCard: some View {
        UsageAccountCard(model: model,
            title: (support.hidePersonalInfo ? model.text("Claude 账号", "Claude account") : support.snapshot?.email) ?? model.text("未找到 Claude 登录", "No Claude login found"),
            detail: support.snapshot?.plan?.capitalized, isActive: support.snapshot != nil,
            badge: support.snapshot == nil ? nil : model.text("默认", "Default"),
            isRefreshing: support.isRefreshing, isBusy: busy,
            refreshHelp: model.text("刷新 Claude 账户、会话和 Token 使用", "Refresh Claude account, session, and token usage"),
            refresh: { support.refresh(force: true) }, detailsExpanded: detailsBinding) {
                UsageActionButton(model: model,
                    title: support.usageSource == .web ? model.text("登录账号", "Sign in") : support.hasClaudeCLI ? model.text("登录账号", "Sign in") : model.text("安装并登录", "Install & sign in"),
                    systemImage: "person.crop.circle.badge.plus", disabled: busy, action: signIn)
                Menu {
                    if support.accounts.isEmpty { Text(model.text("暂无保存账户", "No saved accounts")) }
                    ForEach(support.accounts, id: \.number) { account in
                        Button { support.switchAccount(account.number) } label: {
                            Label(support.accountLabel(account), systemImage: account.isActive ? "checkmark.circle.fill" : "person")
                        }.disabled(!support.canSwitchAccount(account))
                    }
                } label: { UsageControlSurface(model: model, title: model.text("切换", "Switch"), width: 65) }
                .menuStyle(.borderlessButton).disabled(support.accounts.isEmpty || busy)
                .help(model.text("切换保存的 Claude 账户", "Switch saved Claude account"))
                Menu {
                    Button(model.text("重新认证", "Reauthenticate")) { signIn() }
                    Button(model.text("重新读取现有登录", "Read existing login again")) { support.allowCredentialRead() }
                    if support.credentialConsent {
                        Button(model.text("停止读取 Claude Code 登录", "Stop reading Claude Code credentials")) { support.stopCredentialRead() }
                    }
                    Divider()
                    Button(model.text("多账号设置…", "Account settings…")) { detailsBinding.wrappedValue = true }
                    Button(model.text("连接设置…", "Connections…"), action: onConnections)
                } label: { UsageControlSurface(model: model, systemImage: "ellipsis") }
                .menuStyle(.borderlessButton).disabled(busy).help(model.text("更多账户操作", "More account actions"))
                if support.isLoggingIn {
                    Button(model.text("取消登录", "Cancel sign-in")) { support.cancelLogin() }
                }
            } details: {
                connectionDetails
                if support.swapEnabled {
                    if support.accounts.isEmpty {
                        Text(model.text("暂无保存账号，请在 cswap 中添加后刷新。", "No saved accounts. Add one in cswap, then refresh."))
                            .font(detailFont).foregroundStyle(.secondary)
                    } else {
                        Divider().opacity(0.35)
                        ClaudeAccountsOverviewView(model: model, support: support)
                    }
                }
            } messages: {
                if let message = support.loginMessage { issue(localized(message), color: .secondary) }
                if let message = support.switchIssue ?? support.swapIssue { issue(localized(message)) }
                if support.credentialReadBlocked {
                    ClaudeCredentialChoiceButtons(model: model, support: support)
                }
            }
    }

    @ViewBuilder var balancesCard: some View {
        if let snapshot = support.snapshot,
           snapshot.extraUsed != nil || snapshot.extraLimit != nil || snapshot.prepaidBalance != nil || snapshot.cloudCredits != nil || snapshot.resetInventory != nil || snapshot.subscription != nil {
            card { ClaudeEntitlementsView(model: model, support: support) }
        }
    }

    private var connectionDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            ClaudeSourceSettingsView(model: model, support: support)
            detailRow(model.text("CLI", "CLI"), support.hasClaudeCLI ? model.text("已检测到", "Detected") : model.text("尚未安装", "Not installed"))
            if !support.hidePersonalInfo, let organization = support.snapshot?.organization { detailRow(model.text("组织", "Organization"), organization) }
            Text(model.text("通过 Claude Code 在浏览器中授权，完成后自动读取账号与配额。个人订阅需要 Pro 或 Max。",
                            "Authorize Claude Code in your browser; account and quota refresh after sign-in. Personal subscriptions require Pro or Max."))
                .font(detailFont).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !support.hasClaudeCLI {
                Text(model.text("未找到 Claude Code。请先自行安装，或在下方选择已安装的可执行文件：", "Claude Code was not found. Install it yourself, or choose the installed executable below:"))
                    .font(detailFont).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(ClaudeSupportModel.installCommand).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
            // Without a snapshot the Session card already offers this as its empty-state action.
            if support.snapshot != nil {
                Button(model.text("重新读取现有登录", "Read existing login again")) { support.allowCredentialRead() }
            }
            executableRow("Claude CLI", path: support.claudePath) { support.claudePath = $0 }
            Divider().opacity(0.35)
            Toggle(model.text("读取 claude-swap 多账号", "Read accounts from claude-swap"), isOn: $support.swapEnabled)
            if support.swapEnabled {
                executableRow("claude-swap", path: support.swapPath) { support.swapPath = $0 }
                Text(model.text("在 cswap 中保存或移除账号；此处点击“切换”后才更改登录账号。", "Save or remove accounts in cswap; the signed-in account changes only when you click Switch here."))
                    .font(detailFont).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Divider().opacity(0.35)
            Toggle(model.text("状态灯显示 Claude Code", "Include Claude Code in signal lights"), isOn: Binding(
                get: { model.signalLightAgentScopes.contains(.claudeCode) },
                set: { enabled in
                    var scopes = model.signalLightAgentScopes
                    if enabled { scopes.insert(.claudeCode) } else { scopes.remove(.claudeCode) }
                    if !scopes.isEmpty { model.setSignalLightAgentScopes(scopes) }
                }))
            Toggle(model.text("监控 Claude Desktop", "Monitor Claude Desktop"), isOn: Binding(
                get: { model.isClaudeDesktopMonitoringEnabled }, set: { model.setClaudeDesktopMonitoringEnabled($0) }))
            Button(model.text("连接与 Hook 设置…", "Connections & hook settings…"), action: onConnections)
            Text(model.text("Claude Code Hook 提供工作、等待授权、完成和阻塞状态；普通桌面聊天只显示应用活动。",
                            "Claude Code hooks report working, permission, done, and blocked states; ordinary desktop chat reports app activity."))
                .font(detailFont).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.disabled(busy)
    }

    var quotaCard: some View {
        card {
            HStack {
                Text(model.text("会话", "Session")).font(titleFont)
                Spacer()
                if let date = support.snapshot?.updatedAt {
                    Text(model.text("更新 ", "Updated ") + date.formatted(date: .omitted, time: .shortened))
                        .font(detailFont).foregroundStyle(.tertiary)
                }
            }
            if let message = support.quotaIssue { issue(localized(message)) }
            if let snapshot = support.snapshot {
                Text(model.text("Claude 配额", "Claude quota")).fontWeight(.semibold)
                Text([support.hidePersonalInfo ? nil : snapshot.email, snapshot.source].compactMap { $0 }.joined(separator: " · "))
                    .font(detailFont).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if support.quotaIssue != nil {
                    issue(model.text("上次读取结果，尚未刷新。", "Previous snapshot; not refreshed yet."))
                }
                // Only show returned windows; an absent window is never zero usage.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), alignment: .leading)], spacing: 8) {
                    ForEach(snapshot.windows) { window in
                        UsageQuotaWindowTile(language: model.appLanguage,
                            title: localized(window.title) + model.text(" · 剩余 ", " · Left ")
                                + (100 - window.usedPercent).formatted(.number.precision(.fractionLength(0...1))) + "%",
                            reset: window.resetsAt.map { model.text("重置 ", "Resets ") + model.localizedDateTimeString(for: $0) }
                                ?? window.resetDescription ?? model.text("重置时间未提供", "Reset time unavailable"),
                            remainingPercent: 100 - window.usedPercent)
                    }
                }
            } else {
                Text(model.text("暂无已验证配额", "No verified quota")).fontWeight(.semibold)
                Text(model.text("登录或重新读取现有 Claude Code 登录后显示。", "Sign in or read your existing Claude Code login to show quota."))
                    .font(detailFont).foregroundStyle(.secondary)
                Button(model.text("重新读取现有登录", "Read existing login again")) { support.allowCredentialRead() }
                    .disabled(busy || support.isRefreshing)
            }
            DisclosureGroup(model.text("额度历史与提醒", "Quota history & notifications")) {
                ClaudeQuotaHistoryView(model: model, support: support).padding(.top, 8)
            }.font(detailFont)
        }
    }

    var historyCard: some View {
        let summary = support.historySummary()
        return card {
            HStack(spacing: 8) {
                Text(model.text("本机 Token 使用", "Local Token Usage")).font(titleFont)
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                    .help(model.text("汇总本机 Claude Code 会话日志，包含缓存 Token；切换账号不影响统计范围。费用为估算，并非订阅账单。",
                                     "Local Claude Code session logs including cached tokens, across accounts. Costs are estimates, not subscription charges."))
                Spacer()
            }
            if support.isHistoryScanning {
                Text(model.text("正在扫描本机会话并估算 Token…", "Scanning local sessions and estimating tokens…"))
                    .font(detailFont).foregroundStyle(.secondary)
                ProgressView().progressViewStyle(.linear)
                    .accessibilityLabel(model.text("本地 Token 估算进度", "Local token estimation progress"))
            }
            if let message = support.historyIssue { issue(localized(message)) }
            if summary.month.incompleteRequests > 0 {
                issue(model.text("有 \(summary.month.incompleteRequests) 个请求用量不完整；仅汇总已确认部分。", "\(summary.month.incompleteRequests) requests have incomplete usage; totals include confirmed records only."))
            }
            if summary.month.hasUnpricedUsage && summary.entries.contains(where: ClaudeHistorySummary.hasUnpricedUsage) {
                issue(model.text("部分用量或费用未知；≥ 表示已确认的费用小计。", "Some usage or costs are unknown; ≥ marks the confirmed cost subtotal."))
            }
            UsageTokenDashboard(language: model.appLanguage,
                todayCost: model.estimatedCostText(summary.today.costUSD, partial: summary.today.hasUnpricedUsage),
                monthCost: model.estimatedCostText(summary.month.costUSD, partial: summary.month.hasUnpricedUsage),
                todayTokens: tokenText(summary.today.tokens), monthTokens: tokenText(summary.month.tokens)) {
                UsageTokenHistoryChart(model: model, days: summary.chartDays, isClaude: true,
                    unpricedDays: Set(summary.entries.filter(ClaudeHistorySummary.hasUnpricedUsage).map(\.date)),
                    incompleteDays: Set(summary.entries.filter { ($0.incompleteRequestCount ?? 0) > 0 }.map(\.date)))
            }
            if support.historyUpdatedAt != nil && summary.entries.isEmpty {
                Text(model.text("近 30 天未发现本地 Claude Code 用量记录。", "No local Claude Code usage records in the last 30 days."))
                    .font(detailFont).foregroundStyle(.secondary)
            }
            DisclosureGroup(model.text("每日与模型明细", "Daily & model details"), isExpanded: $showDays) {
                ForEach(summary.entries.reversed(), id: \.date) { day in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(day.date).fontWeight(.semibold)
                            Spacer()
                            Text(tokenText(day.totalTokens))
                            Text(model.estimatedCostText(day.costUSD, partial: ClaudeHistorySummary.hasUnpricedUsage(day)))
                        }
                        if let count = day.incompleteRequestCount, count > 0 { Text(model.text("用量不完整：\(count) 个请求", "Incomplete usage: \(count) requests")).foregroundStyle(.orange).font(detailFont) }
                        ForEach(day.modelBreakdowns ?? [], id: \.modelName) { breakdown in
                            HStack {
                                Text(breakdown.modelName).lineLimit(1).truncationMode(.middle)
                                if (breakdown.incompleteRequestCount ?? 0) > 0 { Image(systemName: "exclamationmark.circle").help(model.text("包含用量不完整的请求", "Contains incomplete requests")) }
                                Spacer()
                                Text(tokenText(breakdown.totalTokens))
                                Text(model.estimatedCostText(breakdown.costUSD, partial: breakdown.hasUnpricedUsage || (breakdown.incompleteRequestCount ?? 0) > 0))
                            }.font(detailFont).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 5)
                }
            }
        }
    }

    private func card<Content: View>(@ViewBuilder content: @escaping () -> Content) -> some View {
        UsageSettingsCard(content: content)
    }
    private func signIn() { if support.usageSource == .web { detailsBinding.wrappedValue = true } else { support.login() } }
    private func localized(_ value: String) -> String {
        let parts = value.components(separatedBy: " / ")
        return parts.count == 2 ? model.text(parts[0], parts[1]) : value
    }
    private func tokenText(_ total: Int?) -> String {
        total.map { model.compactTokenCountText($0) + " token" } ?? model.text("暂无数据", "Unavailable")
    }
    private func issue(_ value: String, color: Color = .orange) -> some View {
        Text(value).font(detailFont).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
    }
    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).textSelection(.enabled).multilineTextAlignment(.trailing)
        }.font(detailFont)
    }
    private func executableRow(_ title: String, path: String, selected: @escaping (String) -> Void) -> some View {
        HStack {
            Text(title)
            Text(path.isEmpty ? model.text("自动检测", "Auto detect") : URL(fileURLWithPath: path).lastPathComponent)
                .foregroundStyle(.secondary).lineLimit(1).help(path)
            Spacer()
            Button(model.text("选择…", "Choose…")) {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = false
                panel.allowsMultipleSelection = false
                if panel.runModal() == .OK, let url = panel.url { selected(url.path) }
            }
            if !path.isEmpty { Button(model.text("自动", "Auto")) { selected("") } }
        }
    }
}

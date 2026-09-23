import SwiftUI
import Charts
import AppKit

struct ClaudeUsageSettingsView: View {
    @ObservedObject var model: MenuBarStatusModel
    @ObservedObject var support: ClaudeSupportModel
    let onConnections: () -> Void
    @State private var showSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(model.text("Claude 账号", "Claude account")).font(.headline)
                        Spacer()
                        if support.isRefreshing { ProgressView().controlSize(.small) }
                        Button(model.text("刷新", "Refresh")) { support.refresh(force: true) }
                            .disabled(support.isRefreshing || support.isSwitching)
                    }
                    Text(support.snapshot?.email ?? model.text("尚未读取登录账号", "Account not read yet"))
                        .fontWeight(.medium).textSelection(.enabled)
                    if let snapshot = support.snapshot {
                        Text([snapshot.plan, snapshot.organization].compactMap { $0 }.joined(separator: " · "))
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Button(model.text("登录 Claude Code", "Sign in to Claude Code")) { support.login() }.disabled(support.isLoggingIn || support.isInstallingCLI)
                        if support.isInstallingCLI {
                            ProgressView().controlSize(.small)
                            Text(model.text("正在安装…", "Installing…"))
                        } else if support.isLoggingIn {
                            ProgressView().controlSize(.small)
                            Button(model.text("取消登录", "Cancel sign-in")) { support.cancelLogin() }
                        } else if !support.hasClaudeCLI {
                            Button(model.text("一键安装并登录", "Install and sign in")) { support.installAndLogin() }
                        }
                    }.disabled(support.isSwitching)
                    Text(model.text("通过 Claude Code 自动跳转浏览器登录，完成后自动读取账号与配额。一键安装将运行 Anthropic 官方安装器，安装到当前用户目录，无需管理员密码。", "Claude Code opens browser sign-in, then account and usage refresh automatically. One-click installation runs Anthropic’s official installer in your user directory without an administrator password.")).foregroundStyle(.secondary)
                    Text(model.text("个人订阅登录需要 Claude Pro 或 Max；Free 账号无法完成此授权。", "Personal subscription sign-in requires Claude Pro or Max; Free accounts cannot complete this authorization.")).foregroundStyle(.secondary)
                    if !support.credentialConsent {
                        Text(model.text("首次登录完成后，macOS 可能请求允许读取 Claude Code 登录信息。", "After first sign-in, macOS may ask for permission to read Claude Code credentials."))
                            .foregroundStyle(.secondary)
                    }
                    DisclosureGroup(model.text("接入设置", "Connection settings"), isExpanded: $showSettings) {
                        VStack(alignment: .leading, spacing: 8) {
                            Button(model.text("重新读取现有登录", "Read existing login again")) { support.allowCredentialRead() }
                            if support.credentialConsent {
                                Button(model.text("停止读取登录信息", "Stop reading credentials")) { support.stopCredentialRead() }
                            }
                            executableRow("Claude CLI", path: support.claudePath) { support.claudePath = $0 }
                            Toggle(model.text("读取 claude-swap 多账号", "Read accounts from claude-swap"), isOn: $support.swapEnabled)
                            if support.swapEnabled {
                                executableRow("claude-swap", path: support.swapPath) { support.swapPath = $0 }
                                Text(model.text("在 cswap 中保存或移除账号；此处读取账号列表，点击切换后才会更改登录账号。", "Save or remove accounts in cswap. This list changes the signed-in account only when you click Switch."))
                                    .foregroundStyle(.secondary)
                            }
                        }.padding(.top, 6).disabled(support.isSwitching || support.isLoggingIn || support.isInstallingCLI)
                    }
                    .disclosureGroupStyle(UsageDetailsDisclosureStyle(
                        expandedText: model.text("已展开", "Expanded"),
                        collapsedText: model.text("已收起", "Collapsed")))
                    if let message = support.loginMessage { Text(localized(message)).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
            }
            if support.swapEnabled { accounts }
            quota
            history
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(model.text("Claude 状态灯", "Claude signal light")).font(.headline)
                        Spacer()
                        Button(model.text("连接设置", "Connections"), action: onConnections)
                    }
                    Toggle(model.text("状态灯显示 Claude Code", "Include Claude Code in signal lights"), isOn: Binding(
                        get: { model.signalLightAgentScopes.contains(.claudeCode) },
                        set: { enabled in
                            var scopes = model.signalLightAgentScopes
                            if enabled { scopes.insert(.claudeCode) } else { scopes.remove(.claudeCode) }
                            if !scopes.isEmpty { model.setSignalLightAgentScopes(scopes) }
                        }))
                    Toggle(model.text("监控 Claude Desktop", "Monitor Claude Desktop"), isOn: Binding(
                        get: { model.isClaudeDesktopMonitoringEnabled }, set: { model.setClaudeDesktopMonitoringEnabled($0) }))
                    Text(model.text("Claude Code Hook 提供工作、等待授权、完成和阻塞状态。桌面进程监控只表示应用活动。", "Claude Code hooks report working, permission, done, and blocked states. Desktop process monitoring reports app activity only."))
                        .foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
            }
        }
        .font(.caption)
        .controlSize(.small)
        .task {
            support.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                if !Task.isCancelled { support.refresh() }
            }
        }
    }

    private func localized(_ text: String) -> String {
        let parts = text.components(separatedBy: " / ")
        return parts.count == 2 ? model.text(parts[0], parts[1]) : text
    }

    private var quota: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(model.text("订阅配额", "Subscription usage")).font(.headline)
                    Spacer()
                    if let date = support.snapshot?.updatedAt { Text(date, style: .time).foregroundStyle(.secondary) }
                }
                if let issue = support.quotaIssue {
                    Text(localized(issue)).foregroundStyle(.orange)
                    if support.snapshot != nil { Text(model.text("以下为上次读取的账号结果，尚未刷新。", "Below is the previously read account snapshot; it has not refreshed.")).foregroundStyle(.secondary) }
                }
                if let snapshot = support.snapshot {
                    Text(snapshot.source).foregroundStyle(.secondary)
                    ForEach(snapshot.windows) { window in windowRow(window) }
                    if let used = snapshot.extraUsed {
                        HStack {
                            Text(model.text("额外用量", "Extra usage"))
                            Spacer()
                            Text(used, format: .currency(code: snapshot.extraCurrency))
                            if let limit = snapshot.extraLimit { Text("/ " + limit.formatted(.currency(code: snapshot.extraCurrency))) }
                        }
                    }
                } else {
                    Text(model.text("暂无已验证配额。登录并读取账号后刷新。", "No verified quota. Sign in and read the account, then refresh."))
                        .foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
        }
    }

    private func windowRow(_ window: ClaudeQuotaWindow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(localized(window.title))
                Spacer()
                Text(model.text("已用", "Used") + " " + window.usedPercent.formatted(.number.precision(.fractionLength(0...1))) + "%")
            }
            ProgressView(value: window.usedPercent, total: 100)
                .tint(window.usedPercent >= 90 ? .orange : .accentColor)
            if let reset = window.resetsAt {
                Text(model.text("重置时间：", "Resets: ") + reset.formatted(date: .abbreviated, time: .shortened))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var accounts: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.text("已保存账号", "Saved accounts")).font(.headline)
                if support.isSwitching { Label(model.text("正在切换账号…", "Switching account…"), systemImage: "arrow.triangle.2.circlepath") }
                if let issue = support.switchIssue { Text(localized(issue)).foregroundStyle(.orange) }
                if let issue = support.swapIssue { Text(localized(issue)).foregroundStyle(.orange) }
                if support.accounts.isEmpty && !support.isSwitching {
                    Text(model.text("请配置已安装的 claude-swap 并刷新。", "Configure installed claude-swap and refresh.")).foregroundStyle(.secondary)
                }
                ForEach(support.accounts, id: \.number) { account in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(account.alias ?? "\(account.email) · \(account.organizationName.isEmpty ? "Account \(account.number)" : account.organizationName)")
                                .lineLimit(2)
                            Spacer()
                            if account.isActive { Text(model.text("当前", "Active")).foregroundStyle(.secondary) }
                            else {
                                Button(model.text("切换", "Switch")) { support.switchAccount(account.number) }
                                    .disabled(account.usageStatus != .ok || support.isSwitching || support.swapIssue != nil)
                            }
                        }
                        if let window = account.fiveHour { Text("5h · " + window.usedPercent.formatted() + "%") }
                        if let window = account.sevenDay { Text("7d · " + window.usedPercent.formatted() + "%") }
                        ForEach(Array(account.scoped.enumerated()), id: \.offset) { _, scoped in
                            Text(scoped.name + " · " + scoped.usedPercent.formatted() + "%")
                        }
                        if account.usageStatus != .ok { Text(model.text("需要检查该账号登录状态", "Check this account's sign-in status")).foregroundStyle(.orange) }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
        }
    }

    private var history: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.text("本机 Claude Code · 30 天", "Local Claude Code · 30 days")).font(.headline)
                Text(model.text("本机会话汇总，不归属于当前所选账号；费用为估算值。", "Local session totals, not attributed to the selected account. Costs are estimates."))
                    .foregroundStyle(.secondary)
                if support.isHistoryScanning {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(model.text("正在扫描本机会话并估算 Token…", "Scanning local sessions and estimating tokens…"))
                            .foregroundStyle(.secondary)
                        ProgressView()
                            .progressViewStyle(.linear)
                            .tint(.orange)
                            .accessibilityLabel(model.text("本地 Token 估算进度", "Local token estimation progress"))
                        if support.historyUpdatedAt != nil {
                            Text(model.text("正在更新，以下为上次扫描结果。", "Updating; previous scan results are shown below."))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if let issue = support.historyIssue { Text(localized(issue)).foregroundStyle(.orange) }
                if support.historyUpdatedAt == nil {
                    if !support.isHistoryScanning {
                        Text(model.text("尚未读取历史", "History not read yet")).foregroundStyle(.secondary)
                    }
                } else if support.days.isEmpty {
                    Text(model.text("未发现本地 Claude Code 用量记录", "No local Claude Code usage records found")).foregroundStyle(.secondary)
                } else {
                    HStack {
                        Text("Token · " + support.days.compactMap(\.totalTokens).reduce(0, +).formatted())
                        Spacer()
                        let costs = support.days.compactMap(\.costUSD)
                        if !costs.isEmpty { Text(model.estimatedCostText(costs.reduce(0, +))) }
                    }
                    Chart(support.days, id: \.date) { day in
                        BarMark(x: .value("Day", day.date), y: .value("Tokens", day.totalTokens ?? 0))
                            .foregroundStyle(Color.orange.gradient)
                    }.frame(height: 100).chartXAxis(.hidden)
                    ForEach(support.days.suffix(7).reversed(), id: \.date) { day in
                        HStack {
                            Text(day.date)
                            Spacer()
                            Text((day.totalTokens ?? 0).formatted() + " Token")
                            if let cost = day.costUSD { Text(model.estimatedCostText(cost)) }
                        }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
        }
    }

    private func executableRow(_ title: String, path: String, selected: @escaping (String) -> Void) -> some View {
        HStack {
            Text(title)
            Text(path.isEmpty ? model.text("自动检测", "Auto detect") : URL(fileURLWithPath: path).lastPathComponent)
                .foregroundStyle(.secondary).lineLimit(1)
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

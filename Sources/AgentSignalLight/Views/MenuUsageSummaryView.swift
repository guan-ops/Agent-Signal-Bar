import SwiftUI
import AppKit
import Combine
import AgentSignalLightCore

@MainActor
final class UsageMenuNavigation: ObservableObject {
    enum Provider: String, CaseIterable { case codex = "Codex", claude = "Claude" }
    struct Request { let provider: Provider; let id = UUID() }
    @Published var provider: Provider = .codex
    @Published private(set) var request: Request?
    func openSettings(for provider: Provider) {
        self.provider = provider
        request = Request(provider: provider)
    }
}

/// Shared by the native menu and detailed popover. All values keep their original source scope.
struct MenuUsageSummaryView: View {
    @ObservedObject var model: MenuBarStatusModel
    @ObservedObject var claude: ClaudeSupportModel
    @ObservedObject var navigation: UsageMenuNavigation
    var nativeMenu = false
    var onOpenSettings: (UsageMenuNavigation.Provider) -> Void

    @MainActor
    static func nativeMenuItem(model: MenuBarStatusModel, claude: ClaudeSupportModel,
                               navigation: UsageMenuNavigation,
                               onOpenSettings: @escaping (UsageMenuNavigation.Provider) -> Void) -> NSMenuItem {
        let item = NSMenuItem()
        let host = MenuUsageHostingView(rootView:
            MenuUsageSummaryView(model: model, claude: claude, navigation: navigation, nativeMenu: true,
                                 onOpenSettings: onOpenSettings)
                .padding(10).frame(width: 360)
                .fixedSize(horizontal: false, vertical: true)
                .preferredColorScheme(model.appTheme.colorScheme))
        host.setFrameSize(host.fittingSize)
        item.view = host
        return item
    }

    @MainActor
    static func nativeAccountMenuItem(model: MenuBarStatusModel, claude: ClaudeSupportModel,
                                      onOpenSettings: @escaping (UsageMenuNavigation.Provider) -> Void) -> NSMenuItem {
        let parent = NSMenuItem(title: model.text("切换账号", "Switch account"), action: nil, keyEquivalent: "")
        let menu = NSMenu()
        menu.autoenablesItems = false
        for provider in UsageMenuNavigation.Provider.allCases {
            let group = NSMenuItem(title: provider.rawValue, action: nil, keyEquivalent: "")
            let accounts = NSMenu(); accounts.autoenablesItems = false
            if provider == .codex {
                for account in model.codexSavedAccounts {
                    let item = UsageActionMenuItem(title: String(account.displayName.prefix(30))) { model.switchCodexAccount(account) }
                    item.state = model.isActiveCodexAccount(account) ? .on : .off
                    item.isEnabled = !model.isActiveCodexAccount(account) && !model.isCodexAccountActionRunning
                    accounts.addItem(item)
                }
            } else {
                for account in claude.accounts {
                    let item = UsageActionMenuItem(title: String((account.alias ?? account.email).prefix(30))) { claude.switchAccount(account.number) }
                    item.state = account.isActive ? .on : .off
                    item.isEnabled = !account.isActive && account.usageStatus == .ok && !claude.isSwitching && claude.swapIssue == nil
                    accounts.addItem(item)
                }
            }
            accounts.addItem(UsageActionMenuItem(title: model.text("管理账号…", "Manage accounts…")) { onOpenSettings(provider) })
            group.submenu = accounts; menu.addItem(group)
        }
        parent.submenu = menu
        return parent
    }

    private var isClaude: Bool { navigation.provider == .claude }
    private var isRefreshing: Bool {
        isClaude ? claude.isRefreshing || claude.isSwitching
            : model.isTokenActivityLoading || model.isCodexAccountActionRunning || model.isCodexRateLimitFetchInFlight
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Picker(model.text("用量平台", "Usage provider"), selection: $navigation.provider) {
                    ForEach(UsageMenuNavigation.Provider.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden()
                Button { refresh(force: true) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).disabled(isRefreshing)
                    .help(model.text("刷新用量", "Refresh usage"))
                    .accessibilityLabel(model.text("刷新用量", "Refresh usage"))
            }
            VStack(alignment: .leading, spacing: 10) {
                if nativeMenu {
                    Button { onOpenSettings(navigation.provider) } label: { account }
                        .buttonStyle(.plain)
                } else { account }
                Divider()
                quota
                Divider()
                tokens
                CostCurrencyRateNote(store: model.costCurrency, text: model.text, compact: true)
            }
            .padding(12)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
            Button(model.text("用量与账号设置…", "Usage & account settings…")) { onOpenSettings(navigation.provider) }
                .buttonStyle(.borderless)
        }
        .font(.caption)
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: navigation.provider) {
            refresh(force: false)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                if !Task.isCancelled { refresh(force: false) }
            }
        }
    }

    private var account: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(navigation.provider.rawValue).font(.headline)
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 3) {
                Text(isClaude ? claude.snapshot?.email ?? model.text("尚未读取账号", "Account not read")
                    : model.codexCurrentAccount?.displayName ?? model.codexProviderAccountEmail ?? model.text("尚未登录", "Not signed in"))
                    .fontWeight(.semibold).lineLimit(1).truncationMode(.middle)
                if let plan = isClaude ? claude.snapshot?.plan : model.codexCurrentAccount?.planName ?? model.codexProviderPlanName {
                    Text(plan).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if nativeMenu { Image(systemName: "chevron.right").foregroundStyle(.secondary) }
            if !nativeMenu {
            Menu {
                if isClaude {
                    ForEach(claude.accounts, id: \.number) { account in
                        Button(shortTitle(account.alias ?? account.email)) { claude.switchAccount(account.number) }
                            .disabled(account.isActive || account.usageStatus != .ok || claude.isSwitching || claude.swapIssue != nil)
                    }
                } else {
                    ForEach(model.codexSavedAccounts) { account in
                        Button(shortTitle(account.displayName)) { model.switchCodexAccount(account) }
                            .disabled(model.isActiveCodexAccount(account) || model.isCodexAccountActionRunning)
                    }
                }
                Button(model.text("管理账号…", "Manage accounts…")) { onOpenSettings(navigation.provider) }
            } label: { Image(systemName: "person.crop.circle") }
            .menuStyle(.borderlessButton).fixedSize()
            .help(model.text("切换或管理账号", "Switch or manage accounts"))
            .accessibilityLabel(model.text("切换或管理账号", "Switch or manage accounts"))
            }
        }
    }

    @ViewBuilder private var quota: some View {
        if isClaude {
            if let issue = claude.quotaIssue ?? claude.switchIssue ?? claude.swapIssue { issueText(localized(issue)) }
            if let snapshot = claude.snapshot {
                Text(snapshot.source).foregroundStyle(.secondary).font(.caption2)
                Text(model.text("更新 ", "Updated ") + snapshot.updatedAt.formatted(date: .omitted, time: .shortened))
                    .foregroundStyle(.secondary)
                if claude.quotaIssue != nil { issueText(model.text("上次读取结果", "Previous snapshot")) }
                ForEach(snapshot.windows.prefix(2)) { window in
                    quotaRow(title: localized(window.title), remaining: 100 - window.usedPercent,
                             reset: window.resetsAt.map { model.text("重置 ", "Resets ") + $0.formatted(date: .abbreviated, time: .shortened) })
                }
                if let used = snapshot.extraUsed {
                    Text(model.text("额外用量 ", "Extra usage ") + used.formatted(.currency(code: snapshot.extraCurrency)))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(model.text("在用量设置中登录 Claude Code 以显示配额。", "Sign in to Claude Code in Usage settings to show quota."))
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        } else {
            if let error = model.codexUsageFetchState?.errorMessage { issueText(error) }
            if model.codexUsageFetchState?.isStale == true { issueText(model.text("上次读取结果", "Previous snapshot")) }
            if let quota = model.latestAgentQuota {
                let identity = model.codexQuotaIdentityPresentation(for: quota)
                HStack {
                    Text(identity.context).lineLimit(1).truncationMode(.middle)
                        .help([identity.title, identity.context, identity.limitID].compactMap { $0 }.joined(separator: " · "))
                    Spacer(minLength: 4)
                    Text(model.quotaUpdatedText(for: quota)).fixedSize()
                }.font(.caption2).foregroundStyle(.secondary)
                ForEach(model.quotaBadgeWindows(for: quota), id: \.self) { slot in
                    let window = model.quotaWindow(for: slot, quota: quota)
                    quotaRow(title: model.quotaTitleLine(for: slot, quota: quota), remaining: window?.remainingPercent,
                             reset: model.quotaResetText(for: window, badgeWindow: slot), includesPercent: true)
                }
            } else { Text(model.text("暂无已验证配额", "No verified quota")).foregroundStyle(.secondary) }
            if model.recentLocalQuotaObservation() != nil {
                Text(model.text("另有本地会话观察，详见设置。", "Separate local observation in settings."))
                    .foregroundStyle(.secondary)
            }
            if model.isCodexAccountMessageError, let issue = model.codexAccountMessage { issueText(issue) }
            if let credits = model.codexResetCreditsPresentation() {
                HStack {
                    Text(credits.title + " · " + credits.availableText)
                    Spacer(minLength: 4)
                    Label(credits.expirySummaryText, systemImage: "clock")
                        .lineLimit(1).minimumScaleFactor(0.7)
                }.font(.caption2).foregroundStyle(.secondary).help(credits.helpText)
            }
        }
    }

    private func quotaRow(title: String, remaining: Double?, reset: String?, includesPercent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).lineLimit(1)
                Spacer(minLength: 2)
                if !includesPercent, let remaining {
                    Text(model.text("剩余 ", "Left ") + remaining.formatted(.number.precision(.fractionLength(0))) + "%")
                }
            }
            if let remaining, remaining.isFinite {
                ProgressView(value: min(max(remaining, 0), 100), total: 100)
                    .tint(remaining <= 10 ? .orange : .accentColor)
            }
            if let reset { Text(reset).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
        }
    }

    private var tokens: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 16) {
                metricColumn(title: model.text("今日", "Today"), tokens: todayTokens, cost: todayCost)
                metricColumn(title: model.text("近 30 天", "30 days"), tokens: monthTokens, cost: monthCost)
            }
            MenuTokenHistoryChart(model: model, days: historyDays, isClaude: isClaude)
                .id(navigation.provider)
                .padding(.vertical, 5)
            if let popularModel {
                Text(model.text("最常用模型：", "Top model: ") + popularModel)
                    .font(.caption2).lineLimit(1).truncationMode(.middle)
            }
            Text(model.text("本机汇总 · 费用为估算，并非订阅账单", "This Mac · Estimated cost, not a subscription bill"))
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            if !isClaude { CodexTokenScanProgressView(model: model) }
            if isClaude && claude.isHistoryScanning {
                Text(model.text("正在扫描；保留已有结果。", "Scanning; previous results retained.")).foregroundStyle(.secondary)
                ProgressView().progressViewStyle(.linear)
                    .accessibilityLabel(model.text("本地 Token 估算进度", "Local token estimation progress"))
            }
            if isClaude {
                if let issue = claude.historyIssue { issueText(localized(issue)) }
            } else if let status = model.tokenActivityStatusText, !model.isTokenActivityLoading {
                Text(status).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    private func metricColumn(title: String, tokens: Int?, cost: Double?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).foregroundStyle(.secondary)
            Text(model.estimatedCostText(cost))
                .font(.system(size: 17, weight: .semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(tokens.map { model.compactTokenCountText($0) + " Token" } ?? "—")
                .fontWeight(.medium).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var monthTokens: Int? {
        if !isClaude { return model.tokenActivityDisplayTotal(for: .last30Days) }
        guard claude.historyUpdatedAt != nil else { return nil }
        return historyDays.reduce(0) { $0 + $1.totalTokens }
    }
    private var monthCost: Double? {
        if !isClaude { return model.tokenActivityEstimatedCost(for: .last30Days) }
        let costs = historyDays.compactMap(\.estimatedCostUSD)
        return costs.isEmpty ? nil : costs.reduce(0, +)
    }
    private var popularModel: String? {
        var totals: [String: Int] = [:]
        for day in historyDays {
            for (name, tokens) in day.modelTokenTotals { totals[name, default: 0] += tokens }
        }
        return totals.filter { $0.value > 0 }.sorted {
            $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
        }.first?.key
    }

    private var historyDays: [CodexTokenActivityDay] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let start = calendar.date(byAdding: .day, value: -29, to: today) ?? today
        let end = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        let records: [CodexTokenActivityDay] = isClaude ? claude.days.compactMap { entry in
            guard let day = CostUsageDateParser.parse(entry.date) else { return nil }
            return CodexTokenActivityDay(day: day, totalTokens: entry.totalTokens ?? 0,
                                         estimatedCostUSD: entry.costUSD,
                                         modelTokenTotals: Dictionary((entry.modelBreakdowns ?? []).map {
                                             ($0.modelName, $0.totalTokens ?? 0)
                                         }, uniquingKeysWith: +))
        } : model.tokenActivityDays
        return records.filter { $0.day >= start && $0.day < end }
    }

    private var todayTokens: Int? {
        if !isClaude { return model.tokenActivityDisplayTotal(for: .today) }
        guard claude.historyUpdatedAt != nil else { return nil }
        return todayClaudeEntry?.totalTokens ?? (claude.days.isEmpty ? nil : 0)
    }
    private var todayCost: Double? {
        if !isClaude { return model.tokenActivityEstimatedCost(for: .today) }
        return todayClaudeEntry?.costUSD
    }
    private var todayClaudeEntry: CostUsageDailyReport.Entry? {
        let formatter = DateFormatter(); formatter.calendar = Calendar.current
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        return claude.days.first { $0.date == formatter.string(from: Date()) }
    }
    private func refresh(force: Bool) {
        if isClaude { claude.refresh(force: force) }
        else {
            model.refreshCodexAccounts()
            model.pollCodexRateLimitsIfNeeded(force: force)
            model.refreshTokenActivityIfNeeded(force: force)
        }
    }
    private func issueText(_ value: String) -> some View {
        Text(value).foregroundStyle(.orange).lineLimit(2).help(value)
    }
    private func localized(_ value: String) -> String {
        let parts = value.components(separatedBy: " / ")
        return parts.count == 2 ? model.text(parts[0], parts[1]) : value
    }
    private func shortTitle(_ value: String) -> String { value.count > 30 ? String(value.prefix(27)) + "…" : value }
}

@MainActor
private final class UsageActionMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("Programmatic menu item") }
    @objc private func invoke() { handler() }
}

/// NSMenu uses the custom view's frame; keep it equal to SwiftUI's full content height.
@MainActor
private final class MenuUsageHostingView<Content: View>: NSHostingView<Content> {
    override func layout() {
        super.layout()
        let height = fittingSize.height
        if abs(frame.height - height) > 0.5 {
            setFrameSize(NSSize(width: frame.width, height: height))
        }
    }
}

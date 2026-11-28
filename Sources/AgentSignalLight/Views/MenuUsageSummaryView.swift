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
                    let item = UsageActionMenuItem(title: ClaudeAccountPresentation.menuLabel(claude.accountLabel(account))) { claude.switchAccount(account.number) }
                    item.state = account.isActive ? .on : .off
                    item.isEnabled = claude.canSwitchAccount(account)
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
        isClaude ? claude.isRefreshing || claude.accountActionInProgress
            : model.isTokenActivityLoading || model.isCodexAccountActionRunning || model.isCodexRateLimitFetchInFlight
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ASB.Space.m) {
            HStack(spacing: ASB.Space.s) {
                Picker(model.text("用量平台", "Usage provider"), selection: $navigation.provider) {
                    ForEach(UsageMenuNavigation.Provider.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden()
                Button { refresh(force: true) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).disabled(isRefreshing)
                    .help(model.text("刷新用量", "Refresh usage"))
                    .accessibilityLabel(model.text("刷新用量", "Refresh usage"))
            }
            // UI 2.0: account and quota in one group, device usage in another.
            VStack(alignment: .leading, spacing: 10) {
                if nativeMenu {
                    Button { onOpenSettings(navigation.provider) } label: { account }
                        .buttonStyle(.plain)
                } else { account }
                quota
            }
            // Both hosts (the native menu and the menu bar panel) are glass, so the groups are too.
            .padding(ASB.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .asbGlassGroupBackground()
            VStack(alignment: .leading, spacing: 10) {
                tokens
                CostCurrencyRateNote(store: model.costCurrency, text: model.text, compact: true)
            }
            .padding(ASB.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .asbGlassGroupBackground()
            Button(model.text("用量与账号设置…", "Usage & account settings…")) { onOpenSettings(navigation.provider) }
                .buttonStyle(.borderless)
        }
        .font(ASB.Typeface.caption)
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
            Text(navigation.provider.rawValue).font(ASB.Typeface.bodyStrong)
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 3) {
                Text(isClaude ? (claude.hidePersonalInfo ? model.text("Claude 账号", "Claude account") : claude.snapshot?.email) ?? model.text("尚未读取账号", "Account not read")
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
                        Button(ClaudeAccountPresentation.menuLabel(claude.accountLabel(account))) { claude.switchAccount(account.number) }
                            .disabled(!claude.canSwitchAccount(account))
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
                captureCaption(context: snapshot.source, updated: model.quotaUpdatedText(for: snapshot.updatedAt))
                if claude.quotaIssue != nil || !snapshot.isFresh(at: Date()) { issueText(model.text("上次读取结果", "Previous snapshot")) }
                ForEach(snapshot.windows.prefix(2)) { window in
                    ASBQuotaLine(title: model.claudeQuotaWindowTitle(window),
                                 valueText: model.quotaRemainingText(100 - window.usedPercent),
                                 remainingPercent: 100 - window.usedPercent,
                                 detail: model.claudeQuotaResetText(window), compact: true)
                }
                if snapshot.windows.count > 2 {
                    Text(model.text("另有 \(snapshot.windows.count - 2) 个额度窗口，详见用量设置。", "\(snapshot.windows.count - 2) more quota windows in Usage settings."))
                        .font(ASB.Typeface.caption).foregroundStyle(.secondary)
                }
                ClaudeCompactBalancesView(model: model, support: claude)

            } else {
                Text(model.text("暂无已验证配额", "No verified quota"))
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        } else {
            if let error = model.codexUsageFetchState?.errorMessage { issueText(error) }
            if model.codexUsageFetchState?.isStale == true { issueText(model.text("上次读取结果", "Previous snapshot")) }
            if let quota = model.latestAgentQuota {
                let identity = model.codexQuotaIdentityPresentation(for: quota)
                captureCaption(context: identity.context, updated: model.quotaUpdatedText(for: quota))
                    .help([identity.title, identity.context, identity.limitID].compactMap { $0 }.joined(separator: " · "))
                ForEach(model.quotaBadgeWindows(for: quota), id: \.self) { slot in
                    let window = model.quotaWindow(for: slot, quota: quota)
                    ASBQuotaLine(title: model.quotaWindowTitle(for: slot, quota: quota),
                                 valueText: model.quotaRemainingText(window?.remainingPercent),
                                 remainingPercent: window?.remainingPercent,
                                 detail: model.quotaResetText(for: window, badgeWindow: slot), compact: true)
                }
            } else { Text(model.text("暂无已验证配额", "No verified quota")).foregroundStyle(.secondary) }
            if model.recentLocalQuotaObservation() != nil {
                Text(model.text("另有本地会话观察，详见设置。", "Separate local observation in settings."))
                    .foregroundStyle(.secondary)
            }
            if model.isCodexAccountMessageError, let issue = model.codexAccountMessage { issueText(issue) }
            CodexCreditsSummaryView(model: model)
            if let credits = model.codexResetCreditsPresentation() {
                HStack {
                    Text(credits.title + " · " + credits.availableText)
                    Spacer(minLength: 4)
                    Label(credits.expirySummaryText, systemImage: "clock")
                        .lineLimit(1).minimumScaleFactor(0.7)
                }.font(ASB.Typeface.caption).foregroundStyle(.secondary).help(credits.helpText)
            }
        }
    }

    private func captureCaption(context: String, updated: String) -> some View {
        HStack {
            Text(context).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            Text(updated).fixedSize()
        }.font(ASB.Typeface.caption).foregroundStyle(.secondary)
    }

    private var tokens: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 16) {
                metricColumn(title: model.text("今日", "Today"), tokens: todayTokens, cost: todayCost,
                             partial: isClaude ? claude.historySummary().today.hasUnpricedUsage : model.tokenActivityCostIsPartial(for: .today))
                metricColumn(title: model.text("近 30 天", "30 days"), tokens: monthTokens, cost: monthCost,
                             partial: isClaude ? claude.historySummary().month.hasUnpricedUsage : model.tokenActivityCostIsPartial(for: .last30Days))
            }
            MenuTokenHistoryChart(model: model, days: historyDays, isClaude: isClaude,
                                  unpricedDays: isClaude ? Set(claude.historySummary().entries.filter(ClaudeHistorySummary.hasUnpricedUsage).map(\.date)) : [],
                                  incompleteDays: isClaude ? Set(claude.historySummary().entries.filter { ($0.incompleteRequestCount ?? 0) > 0 }.map(\.date)) : [])
                .id(navigation.provider)
                .padding(.vertical, 5)
            if let popularModel {
                Text(model.text("最常用模型：", "Top model: ") + popularModel)
                    .font(ASB.Typeface.caption).lineLimit(1).truncationMode(.middle)
            }
            Text(model.text("本机汇总 · 费用为估算，并非订阅账单", "This Mac · Estimated cost, not a subscription bill"))
                .font(ASB.Typeface.caption).foregroundStyle(.secondary).lineLimit(1)
            if isClaude, claude.historySummary().month.incompleteRequests > 0 {
                Text(model.text("包含用量不完整的请求；仅显示已确认小计", "Incomplete requests; confirmed subtotals only")).font(ASB.Typeface.caption).foregroundStyle(ASBTone.caution.foreground)
            }
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

    private func metricColumn(title: String, tokens: Int?, cost: Double?, partial: Bool = false) -> some View {
        ASBStat(label: title, value: model.estimatedCostText(cost, partial: partial),
                detail: tokens.map { model.compactTokenCountText($0) + " Token" } ?? "—")
    }

    private var monthTokens: Int? {
        if !isClaude { return model.tokenActivityDisplayTotal(for: .last30Days) }
        return claude.historySummary().month.tokens
    }
    private var monthCost: Double? {
        if !isClaude { return model.tokenActivityEstimatedCost(for: .last30Days) }
        return claude.historySummary().month.costUSD
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
        let records = isClaude ? claude.historySummary().chartDays : model.tokenActivityDays
        return records.filter { $0.day >= start && $0.day < end }
    }

    static func activityDay(for entry: CostUsageDailyReport.Entry) -> CodexTokenActivityDay? {
        guard let day = CostUsageDateParser.parse(entry.date) else { return nil }
        return CodexTokenActivityDay(day: day, totalTokens: entry.totalTokens ?? 0,
            estimatedCostUSD: entry.costUSD,
            modelTokenTotals: Dictionary((entry.modelBreakdowns ?? []).map {
                ($0.modelName, $0.totalTokens ?? 0)
            }, uniquingKeysWith: +), hasUnpricedUsage: entry.hasUnpricedUsage)
    }

    private var todayTokens: Int? {
        if !isClaude { return model.tokenActivityDisplayTotal(for: .today) }
        return claude.historySummary().today.tokens
    }
    private var todayCost: Double? {
        if !isClaude { return model.tokenActivityEstimatedCost(for: .today) }
        return claude.historySummary().today.costUSD
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
        Text(value).foregroundStyle(ASBTone.caution.foreground).lineLimit(2).help(value)
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

/// NSMenu uses the custom view's frame. Resize between layout passes, including while tracking.
@MainActor
final class MenuUsageHostingView<Content: View>: NSHostingView<Content> {
    private var resizeScheduled = false

    override func layout() {
        super.layout()
        guard abs(frame.height - fittingSize.height) > 0.5, !resizeScheduled else { return }
        resizeScheduled = true
        // Resizing here re-enters NSMenu's window layout and can apply the height delta
        // twice to its glass background. The main queue alone stalls while tracking.
        let resize: @MainActor @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            self.resizeScheduled = false
            let height = self.fittingSize.height
            guard height.isFinite, height > 0, abs(self.frame.height - height) > 0.5 else { return }
            self.setFrameSize(NSSize(width: self.frame.width, height: height))
        }
        RunLoop.main.perform(inModes: [.default, .eventTracking]) {
            MainActor.assumeIsolated { resize() }
        }
    }
}

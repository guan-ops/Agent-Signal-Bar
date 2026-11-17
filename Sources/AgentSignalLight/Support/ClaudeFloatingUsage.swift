import Foundation
import AgentSignalLightCore

/// The tag keeps Claude data out of Codex's account-quota store and presentation helpers.
enum FloatingQuotaContent: Equatable {
    case codex(AgentQuotaStatus)
    case codexCredits
    case claude
}

extension MenuBarStatusModel {
    var isClaudeFloatingUsage: Bool { selectedSignalLightProvider == .claude }
    var floatingUsageProviderName: String { isClaudeFloatingUsage ? "Claude" : "Codex" }

    var floatingQuotaContent: FloatingQuotaContent? {
        guard isFloatingSignalQuotaBadgeEnabled, !isMonitoringPaused else { return nil }
        if isClaudeFloatingUsage { return .claude }
        return latestAgentQuota.map(FloatingQuotaContent.codex) ?? (latestCodexCredits == nil ? nil : .codexCredits)
    }

    func claudeQuotaWindowTitle(_ window: ClaudeQuotaWindow) -> String {
        window.id == "five_hour" ? displayName(for: FloatingSignalQuotaBadgeWindow.fiveHours)
            : window.id == "seven_day" ? displayName(for: FloatingSignalQuotaBadgeWindow.weekly) : localizedClaudeText(window.title)
    }

    func claudeQuotaTitleLine(_ window: ClaudeQuotaWindow) -> String {
        let title = window.id == "five_hour" ? displayName(for: FloatingSignalQuotaBadgeWindow.fiveHours)
            : window.id == "seven_day" ? displayName(for: FloatingSignalQuotaBadgeWindow.weekly) : localizedClaudeText(window.title)
        return quotaTitleLine(title: title, percentText: "\(Int((100 - window.usedPercent).rounded()))%")
    }

    func claudeQuotaResetText(_ window: ClaudeQuotaWindow) -> String {
        if window.resetsAt == nil, let description = window.resetDescription { return description }
        return quotaResetText(resetsAt: window.resetsAt, showsDate: window.id != "five_hour")
    }

    var claudeSelectedFloatingQuota: ClaudeQuotaWindow? {
        guard let snapshot = claudeSupport.snapshot else { return nil }
        if claudeFloatingQuotaWindowID == "automatic" {
            return snapshot.windows.filter { $0.resetsAt.map { $0 > Date() } ?? true }.max { $0.usedPercent < $1.usedPercent }
        }
        return snapshot.windows.first { $0.id == claudeFloatingQuotaWindowID }
    }

    var claudeUsesExtraBudget: Bool {
        guard let snapshot = claudeSupport.snapshot, snapshot.hasExtraBudget else { return false }
        return claudeFloatingQuotaWindowID == "extra_usage" || (snapshot.windows.isEmpty && claudeFloatingQuotaWindowID != "prepaid")
    }

    var claudeUsesPrepaidBalance: Bool {
        guard let snapshot = claudeSupport.snapshot, snapshot.prepaidBalance != nil else { return false }
        return claudeFloatingQuotaWindowID == "prepaid" || (snapshot.windows.isEmpty && !snapshot.hasExtraBudget)
    }

    var claudeFloatingBadgeText: String {
        if claudeUsesPrepaidBalance {
            guard let snapshot = claudeSupport.snapshot, snapshot.isFresh(at: Date()), claudeSupport.quotaIssue == nil,
                  !claudeSupport.isSwitching, let balance = snapshot.prepaidBalance else { return "—" }
            let formatter = NumberFormatter(); formatter.numberStyle = .currency
            formatter.currencyCode = snapshot.prepaidCurrency
            formatter.locale = Locale(identifier: appLanguage.localeIdentifier); formatter.maximumFractionDigits = 0
            return (balance > 0 && balance < 1 ? "<" : "") + (formatter.string(from: NSNumber(value: balance > 0 && balance < 1 ? 1 : floor(balance))) ?? "—")
        }
        return claudeFloatingRemainingPercent().map { "\(Int($0.rounded()))%" } ?? "—"
    }

    /// A retained snapshot is useful in the detail panel, but not as an unqualified live percentage.
    func claudeFloatingRemainingPercent(now: Date = Date()) -> Double? {
        guard !claudeSupport.isSwitching, !claudeSupport.isLoggingIn,
              claudeSupport.quotaIssue == nil,
              let snapshot = claudeSupport.snapshot,
              snapshot.isFresh(at: now) else { return nil }
        if claudeUsesExtraBudget {
            guard snapshot.extraBudgetResetAt.map({ $0 > now }) ?? false else { return nil }
            return snapshot.extraRemainingPercent
        }
        guard !claudeUsesPrepaidBalance,
              let window = claudeSelectedFloatingQuota,
              window.resetsAt.map({ $0 > now }) ?? true else { return nil }
        return 100 - window.usedPercent
    }

    var claudeFloatingQuotaMessage: String {
        if claudeSupport.isSwitching { return text("正在切换账号…", "Switching account…") }
        if claudeSupport.isLoggingIn { return text("等待登录完成…", "Waiting for sign-in…") }
        if let issue = claudeSupport.quotaIssue {
            let prefix = claudeSupport.snapshot == nil ? "" : text("上次读取结果 · ", "Previous snapshot · ")
            return prefix + localizedClaudeText(issue)
        }
        guard claudeSupport.snapshot != nil else { return text("尚无已验证额度，请在用量设置中选择来源并登录。", "No verified quota. Choose a source and sign in in Usage settings.") }
        if claudeUsesPrepaidBalance { return text("预充值余额；与月预算和赠送额度分开。", "Prepaid balance; separate from monthly budget and cloud credits.") }
        if claudeUsesExtraBudget { return text("额外用量月预算剩余比例；不是订阅配额。", "Remaining monthly extra usage budget, separate from subscription quota.") }
        if claudeSelectedFloatingQuota == nil { return text("所选窗口暂无数据，可选择下方其他窗口。", "Selected window unavailable. Choose another window below.") }
        if claudeFloatingRemainingPercent() == nil { return text("上次读取结果，等待刷新。", "Previous snapshot; awaiting refresh.") }
        return text("当前账号订阅额度", "Current account subscription quota")
    }

    func localizedClaudeText(_ text: String) -> String {
        let parts = text.components(separatedBy: " / ")
        guard parts.count == 2 else { return text }
        return appLanguage.usesCompactLatinLayout ? parts[1] : parts[0]
    }

    var claudeFloatingExtraUsageText: String? {
        guard let snapshot = claudeSupport.snapshot,
              snapshot.extraUsed != nil || snapshot.extraLimit != nil else { return nil }
        func amount(_ value: Double?) -> String {
            value.map { $0.formatted(.currency(code: snapshot.extraCurrency).presentation(.isoCode)
                .locale(Locale(identifier: appLanguage.localeIdentifier))) } ?? "—"
        }
        return text("已用 ", "Used ") + amount(snapshot.extraUsed)
            + text(" · 月上限 ", " · Monthly limit ") + amount(snapshot.extraLimit)
    }

    func floatingUsageTokens(for window: FloatingSignalTokenBadgeWindow) -> Int? {
        if isClaudeFloatingUsage {
            let summary = claudeSupport.historySummary()
            return window == .today ? summary.today.tokens : summary.month.tokens
        }
        return tokenActivityDisplayTotal(for: window)
    }

    func floatingUsageCost(for window: FloatingSignalTokenBadgeWindow) -> Double? {
        if isClaudeFloatingUsage {
            let summary = claudeSupport.historySummary()
            return window == .today ? summary.today.costUSD : summary.month.costUSD
        }
        return tokenActivityEstimatedCost(for: window)
    }

    func floatingUsageHasUnpricedCost(for window: FloatingSignalTokenBadgeWindow) -> Bool {
        guard isClaudeFloatingUsage else { return tokenActivityCostIsPartial(for: window) }
        let summary = claudeSupport.historySummary()
        return window == .today ? summary.today.hasUnpricedUsage : summary.month.hasUnpricedUsage
    }

    func floatingUsageCostText(for window: FloatingSignalTokenBadgeWindow) -> String {
        guard let cost = floatingUsageCost(for: window) else {
            return tokenUsageCostText(nil, isLoading: isFloatingUsageLoading)
        }
        return text("费用 ", "cost ") + estimatedCostText(cost, partial: floatingUsageHasUnpricedCost(for: window))
    }

    var isFloatingUsageLoading: Bool { isClaudeFloatingUsage ? claudeSupport.isHistoryScanning : isTokenActivityLoading }
}

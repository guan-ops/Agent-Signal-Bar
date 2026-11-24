import Foundation
import AgentSignalLightCore

/// Mirrors CodexBar's CodexConsumerProjection fallback: a binding exhausted lane,
/// or no rate windows, plus a positive verified balance. Reset credits are unrelated.
enum CodexCreditsDisplay {
    static func isFresh(_ credits: CodexCreditStatus, fetchState: CodexUsageFetchState?, now: Date) -> Bool {
        credits.remaining.isFinite && credits.remaining >= 0
            && fetchState?.isStale == false && fetchState?.errorMessage == nil
            && (-60..<300).contains(now.timeIntervalSince(credits.updatedAt))
            && (credits.resetsAt.map { $0 > now } ?? true)
    }

    static func usesCredits(quota: AgentQuotaStatus?, credits: CodexCreditStatus?,
                            fetchState: CodexUsageFetchState?, now: Date = Date()) -> Bool {
        guard let credits, credits.remaining > 0, isFresh(credits, fetchState: fetchState, now: now) else { return false }
        guard let quota else { return true }
        guard (-60..<300).contains(now.timeIntervalSince(quota.updatedAt)) else { return false }
        return [quota.primaryWindow, quota.secondaryWindow].compactMap { $0 }.contains {
            $0.remainingPercent <= 0 && ($0.resetsAt.map { $0 > now } ?? true)
        }
    }

    static func badgeText(_ remaining: Double) -> String {
        guard remaining.isFinite, remaining >= 0 else { return "—" }
        if remaining >= 1_000_000 { return String(format: "%.1fM", remaining / 1_000_000) + "c" }
        if remaining >= 1_000 { return String(format: "%.1fK", remaining / 1_000) + "c" }
        if remaining > 0, remaining < 1 { return "<1c" }
        return "\(Int(remaining.rounded(.down)))c"
    }
}

extension MenuBarStatusModel {
    var codexFloatingCredits: CodexCreditStatus? {
        guard let credits = latestCodexCredits,
              CodexCreditsDisplay.isFresh(credits, fetchState: codexUsageFetchState, now: Date()) else { return nil }
        if latestAgentQuota == nil { return credits }
        return CodexCreditsDisplay.usesCredits(quota: latestAgentQuota, credits: credits,
            fetchState: codexUsageFetchState) ? credits : nil
    }

    func codexCreditNumber(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)).locale(Locale(identifier: appLanguage.localeIdentifier)))
    }

    var codexCreditsTitle: String {
        latestCodexCredits?.limit == nil ? text("Credits 余额", "Credit balance") : text("月度 Credits 剩余", "Monthly credits remaining")
    }

    var codexCreditsAreStale: Bool {
        latestCodexCredits.map { !CodexCreditsDisplay.isFresh($0, fetchState: codexUsageFetchState, now: Date()) } ?? false
    }

    var codexCreditsBadgeHelp: String {
        guard let credits = codexFloatingCredits else { return text("Credits 余额暂不可用", "Credit balance unavailable") }
        return "Codex · \(codexCreditsTitle) · \(codexCreditNumber(credits.remaining)) credits · "
            + text("c 表示 credits，点击查看余额与订阅额度。", "c means credits. Click for balance and plan limits.")
    }
}

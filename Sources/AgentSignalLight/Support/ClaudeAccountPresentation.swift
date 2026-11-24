import Foundation

// Policy and label rules informed by guan-ops/CodexBar's ClaudeSwapAccountProjection.swift
// (Git blob 980ca83036956b99dbcd842b39c935e5c8d4ab68). MIT attribution in ClaudeSupport-LICENSE.txt.
enum ClaudeAccountPresentation {
    static func label(_ row: ClaudeSwapAccountRow, among rows: [ClaudeSwapAccountRow]) -> String {
        if let alias = row.alias, !alias.isEmpty { return alias }
        if row.email.isEmpty { return "Account \(row.number)" }
        let duplicates = rows.filter { $0.email.lowercased() == row.email.lowercased() }
        guard duplicates.count > 1 else { return row.email }
        let organization = row.organizationName.isEmpty ? "" : " · \(row.organizationName)"
        return "\(row.email)\(organization) · #\(row.number)"
    }

    static func menuLabel(_ label: String) -> String {
        guard label.count > 30 else { return label }
        // Preserve the organization/slot suffix that distinguishes equal-email accounts.
        return String(label.prefix(17)) + "…" + String(label.suffix(12))
    }

    static func canActivate(_ row: ClaudeSwapAccountRow) -> Bool {
        if row.isActive { return row.usageStatus == .foreignCredential }
        switch row.usageStatus {
        case .ok, .apiKey, .unavailable, .foreignCredential: return true
        case .tokenExpired, .reloginRequired, .keychainUnavailable, .noCredentials, .unknown: return false
        }
    }

    static func status(_ row: ClaudeSwapAccountRow) -> (zh: String, en: String) {
        switch row.usageStatus {
        case .ok: return row.isActive ? ("当前账号", "Current account") : ("可切换", "Available")
        case .apiKey: return ("API Key 账号，无订阅额度", "API key account; no subscription quota")
        case .unavailable: return ("额度暂不可用，仍可切换", "Quota unavailable; switching available")
        case .foreignCredential: return ("当前凭据归属不匹配，可重新切换", "Credential owner mismatch; switch again")
        case .tokenExpired: return ("登录已过期，请在 cswap 中恢复登录", "Login expired; restore it in cswap")
        case .reloginRequired: return ("需要在 cswap 中重新登录", "Sign in again in cswap")
        case .keychainUnavailable: return ("钥匙串不可读取", "Keychain unavailable")
        case .noCredentials: return ("此账号没有保存的登录", "No saved login for this account")
        case .unknown: return ("未知账号状态，暂不可切换", "Unknown account status; switching unavailable")
        }
    }
}

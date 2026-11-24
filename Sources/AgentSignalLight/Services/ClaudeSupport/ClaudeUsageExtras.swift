import Foundation
import CoreFoundation
import CryptoKit

enum ClaudeUsageSource: String, CaseIterable, Sendable {
    case oauth, automatic, cli, web
    var title: String {
        switch self { case .oauth: "Claude Code OAuth"; case .automatic: "自动 / Automatic"; case .cli: "Claude CLI"; case .web: "Claude 网页 / Claude Web" }
    }
}

enum ClaudeValue {
    static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite,
              n.doubleValue >= 0 else { return nil }
        return n.doubleValue
    }
    static func bool(_ value: Any?) -> Bool? {
        guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }
    static func key(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func text(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let result = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : String(result.prefix(200))
    }
}

// CodexBar ClaudeCloudCreditsSnapshot: these are USD, independent of prepaid usage credits.
struct ClaudeCloudCredits: Equatable, Sendable {
    let remaining: Double
    let limit: Double?
    let used: Double?
    let expiresAt: Date?
    let isLocked: Bool
    func isAvailable(at now: Date) -> Bool { !isLocked && (expiresAt.map { $0 > now } ?? true) }
    static func parse(_ value: Any?) -> Self? {
        guard let row = value as? [String: Any] else { return nil }
        for key in ["limit_dollars", "used_dollars", "remaining_dollars"] {
            if let value = row[key], !(value is NSNull), ClaudeValue.number(value) == nil { return nil }
        }
        if let locked = row["locked_reason"], !(locked is NSNull), !(locked is String) { return nil }
        let limit = ClaudeValue.number(row["limit_dollars"]), used = ClaudeValue.number(row["used_dollars"])
        let remaining = ClaudeValue.number(row["remaining_dollars"]) ?? limit.flatMap { limit in used.map { max(0, limit - $0) } }
        guard let remaining else { return nil }
        let expiry = ClaudeUsageSnapshot.date(row["resets_at"])
        guard row["resets_at"] == nil || row["resets_at"] is NSNull || expiry != nil else { return nil }
        return .init(remaining: remaining, limit: limit, used: used, expiresAt: expiry,
                     isLocked: ClaudeValue.text(row["locked_reason"]) != nil)
    }
}

// CodexBar ClaudeRateLimitResetCredits: only active eligible grants, never persisted or redeemed here.
struct ClaudeResetInventory: Equatable, Sendable {
    let expirations: [Date?]
    func available(at now: Date) -> [Date?] {
        expirations.filter { $0.map { $0 > now } ?? true }.sorted { ($0 ?? .distantFuture) < ($1 ?? .distantFuture) }
    }
    static func parse(_ value: Any?, now: Date) -> Self? {
        guard let row = value as? [String: Any], ClaudeValue.bool(row["eligible"]) == true,
              let grants = row["grants"] as? [Any], grants.count <= 200 else { return nil }
        var result: [Date?] = []
        for value in grants {
            guard let grant = value as? [String: Any], ClaudeValue.bool(grant["paused"]) == false,
                  let left = ClaudeValue.number(grant["resets_left"]), left.rounded() == left, left <= 50 else { continue }
            if let total = grant["resets_total"], !(total is NSNull) {
                guard let total = ClaudeValue.number(total), total.rounded() == total, total >= left else { continue }
            }
            let start = ClaudeUsageSnapshot.date(grant["starts_at"]), end = ClaudeUsageSnapshot.date(grant["ends_at"])
            guard grant["starts_at"] == nil || grant["starts_at"] is NSNull || start != nil,
                  grant["ends_at"] == nil || grant["ends_at"] is NSNull || end != nil,
                  start.map({ $0 <= now }) ?? true, end.map({ $0 > now }) ?? true else { continue }
            guard result.count + Int(left) <= 50 else { return nil }
            result.append(contentsOf: Array(repeating: end, count: Int(left)))
        }
        return .init(expirations: result)
    }
}

struct ClaudeSubscriptionDates: Equatable, Sendable {
    let renewsAt: Date?
    let expiresAt: Date?
    let isDateOnly: Bool
    static func parse(_ value: Any?) -> Self? {
        guard let root = value as? [String: Any] else { return nil }
        let fields = root["subscription"] as? [String: Any] ?? root
        guard let status = fields["status"] as? String, ["active", "trialing", "canceled"].contains(status) else { return nil }
        let dateKeys = ["next_charge_at", "next_charge_date", "plan_ending_at", "plan_ending_before"]
        guard dateKeys.allSatisfy({ fields.keys.contains($0) }) else { return nil }
        func date(_ names: [String]) -> (Date, Bool)? {
            for key in names {
                guard let raw = fields[key] as? String else { continue }
                if raw.count == 10 {
                    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
                    f.timeZone = TimeZone(secondsFromGMT: 0); f.dateFormat = "yyyy-MM-dd"; f.isLenient = false
                    if let d = f.date(from: raw), f.string(from: d) == raw { return (d, true) }
                } else if let d = ClaudeUsageSnapshot.date(raw) { return (d, false) }
            }
            return nil
        }
        for key in dateKeys where !(fields[key] is NSNull) {
            guard date([key]) != nil else { return nil }
        }
        let end = date(["plan_ending_at", "plan_ending_before"])
        let renewal = end == nil && status != "canceled" ? date(["next_charge_at", "next_charge_date"]) : nil
        guard end != nil || renewal != nil else { return nil }
        return .init(renewsAt: renewal?.0, expiresAt: end?.0, isDateOnly: (end ?? renewal)?.1 ?? false)
    }
}

extension ClaudeUsageSnapshot {
    var extraBudgetResetAt: Date? {
        guard hasExtraBudget else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let month = calendar.dateInterval(of: .month, for: updatedAt) else { return nil }
        return month.end
    }
    var historyWindows: [ClaudeQuotaWindow] {
        guard let remaining = extraRemainingPercent else { return windows }
        return windows + [.init(id: "extra_usage", title: "额外用量月预算 / Monthly extra usage budget", usedPercent: 100 - remaining, resetsAt: extraBudgetResetAt)]
    }
    var hasExtraBudget: Bool { extraLimit.map { $0 > 0 } == true && extraUsed != nil }
    var extraRemainingPercent: Double? {
        guard let limit = extraLimit, limit > 0, let used = extraUsed else { return nil }
        return max(0, min(100, 100 - used / limit * 100))
    }
    var extraRemaining: Double? { extraLimit.flatMap { limit in extraUsed.map { max(0, limit - $0) } } }
    func isFresh(at now: Date) -> Bool { (-60..<freshnessInterval).contains(now.timeIntervalSince(updatedAt)) }
    var historyOwner: String { accountKey ?? ClaudeValue.key(source + "|" + credentialID) }

    static func parseUsage(_ data: Data, credentialID: String, plan: String?, now: Date, source: String = "Claude Code OAuth", allowsUnavailable: Bool = false) throws -> Self {
        guard data.count <= 1_048_576, let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ClaudeSupportError.invalidResponse }
        let amounts = extraAmounts(root["extra_usage"] as? [String: Any])
        let windows = try windows(from: data, allowsEmpty: true)
        let cloud = ClaudeCloudCredits.parse(root["iguana_necktie"])
        let resets = ClaudeResetInventory.parse(root["cedar_ember"], now: now)
        guard root["error"] == nil, allowsUnavailable || !windows.isEmpty || amounts.used != nil || amounts.limit != nil || cloud != nil || resets != nil else { throw ClaudeSupportError.invalidResponse }
        return .init(credentialID: credentialID, email: nil, organization: nil, plan: plan, windows: windows,
                     extraUsed: amounts.used, extraLimit: amounts.limit, extraCurrency: amounts.currency, updatedAt: now,
                     source: source, cloudCredits: cloud, resetInventory: resets)
    }
}

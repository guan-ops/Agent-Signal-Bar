import Foundation
import Security
import LocalAuthentication
import CoreFoundation
import CryptoKit

struct ClaudeCredential: Sendable {
    let accessToken: String
    let expiresAt: Date?
    let plan: String?
    var identity: String { SHA256.hash(data: Data(accessToken.utf8)).map { String(format: "%02x", $0) }.joined() }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 1_048_576,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { throw ClaudeSupportError.loginRequired }
        return Self(accessToken: token,
                    expiresAt: (oauth["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) },
                    plan: oauth["subscriptionType"] as? String)
    }
}

enum ClaudeSupportError: Error, Equatable {
    case loginRequired, keychainDenied, invalidResponse, missingCLI, commandFailed, timedOut, outputTooLarge
    case webLoginRequired, webChallenge, organizationRequired, manualCLIRequired, sourceDisabled, accountChanged
    case rateLimited(Date), server(Int)
    var message: String {
        switch self {
        case .loginRequired: "请登录 Claude Code 后重试。 / Sign in to Claude Code, then retry."
        case .keychainDenied: "受保护的 Claude 登录信息无法静默读取；可改用 CLI。 / Protected Claude credentials cannot be read silently; choose CLI instead."
        case .invalidResponse: "Claude 返回的数据不完整。 / Claude returned incomplete data."
        case .missingCLI: "未找到命令行工具，请选择已安装的可执行文件。 / Select the installed executable."
        case .commandFailed: "命令未成功，请在终端检查登录状态。 / Check sign-in status in Terminal."
        case .timedOut: "操作超时，已保留上次结果。 / Timed out; previous results retained."
        case .outputTooLarge: "命令输出超过限制。 / Command output exceeded the limit."
        case .rateLimited: "Claude 暂时限流，将稍后重试。 / Claude is rate limited; retrying later."
        case .server(let status): "Claude HTTP \(status)，请稍后重试。 / Please retry later."
        case .webLoginRequired: "请登录 Claude 网页并重新读取会话。 / Sign in to Claude on the web and read the session again."
        case .webChallenge: "网页访问需要网络验证；可改用 Claude Code 来源。 / Web access requires a network challenge; use the Claude Code source."
        case .organizationRequired: "请选择网页账号所属的组织。 / Select the organization for this web account."
        case .manualCLIRequired: "请点击刷新读取 CLI；后台运行尚未开启。 / Click Refresh to read the CLI; background probes are off."
        case .accountChanged: "账号已变化，请刷新。 / Account changed; refresh again."
        case .sourceDisabled: "请先启用所选来源的读取权限。 / Enable access for the selected source first."
        }
    }
}

struct ClaudeQuotaWindow: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let usedPercent: Double
    let resetsAt: Date?
    var resetDescription: String? = nil
}

struct ClaudeUsageSnapshot: Sendable {
    let credentialID: String
    var email: String?
    var organization: String?
    let plan: String?
    let windows: [ClaudeQuotaWindow]
    var extraUsed: Double?
    var extraLimit: Double?
    var extraCurrency: String
    let updatedAt: Date
    var source: String = "Claude Code OAuth"
    var accountKey: String? = nil
    var cloudCredits: ClaudeCloudCredits? = nil
    var resetInventory: ClaudeResetInventory? = nil
    var prepaidBalance: Double? = nil
    var prepaidCurrency: String = "USD"
    var subscription: ClaudeSubscriptionDates? = nil
    var freshnessInterval: TimeInterval = 300

    static func extraAmounts(_ extra: [String: Any]?) -> (used: Double?, limit: Double?, currency: String) {
        func amount(_ key: String) -> Double? {
            guard ClaudeValue.bool(extra?["is_enabled"]) == true,
                  let number = extra?[key] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue >= 0 else { return nil }
            return number.doubleValue / 100
        }
        let currency = (extra?["currency"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return (amount("used_credits"), amount("monthly_limit"), currency?.isEmpty == false ? currency! : "USD")
    }

    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    static func windows(from data: Data, allowsEmpty: Bool = false) throws -> [ClaudeQuotaWindow] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ClaudeSupportError.invalidResponse }
        var windows: [ClaudeQuotaWindow] = []
        let keys = [("five_hour", "5 小时 / 5 hours"), ("seven_day", "7 天 / 7 days"),
                    ("seven_day_opus", "Opus · 7 天 / Opus · 7 days"), ("seven_day_sonnet", "Sonnet · 7 天 / Sonnet · 7 days"),
                    ("seven_day_oauth_apps", "OAuth Apps · 7 天 / OAuth Apps · 7 days")]
        for (key, title) in keys {
            guard let row = root[key] as? [String: Any], let number = row["utilization"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  case let used = number.doubleValue,
                  used.isFinite, used >= 0, used <= 100 else { continue }
            windows.append(.init(id: key, title: title, usedPercent: used, resetsAt: date(row["resets_at"])))
        }
        if let limits = root["limits"] as? [Any] {
            // CodexBar ClaudeScopedWeeklyLimitMapper: stable model identity, weekly-only,
            // no all-model duplicate, no fabricated percentage for an absent measurement.
            var seen = Set<String>()
            for entry in limits {
                guard let limit = entry as? [String: Any] else { continue }
                guard limit["is_active"] as? Bool != false,
                      limit["kind"] as? String == "weekly_scoped", limit["group"] as? String == "weekly",
                      let scope = limit["scope"] as? [String: Any], let model = scope["model"] as? [String: Any],
                      let rawTitle = model["display_name"] as? String else { continue }
                let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                let rawID = (model["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let identity = rawID?.isEmpty == false ? rawID! : title
                let id = identity.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: "-")
                let name = title.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: "-")
                guard !title.isEmpty, !id.isEmpty, name != "all-models", !id.hasSuffix("all-models"),
                      let value = limit["percent"] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                      value.doubleValue.isFinite, (0...100).contains(value.doubleValue), seen.insert(id).inserted else { continue }
                windows.append(.init(id: "scoped-\(id)", title: title + " · 7 天 / " + title + " · 7 days",
                    usedPercent: value.doubleValue, resetsAt: date(limit["resets_at"])))
            }
        }
        // CodexBar maps these evolving Web keys to one stable Daily Routines window.
        let routineKeys = ["seven_day_routines", "seven_day_claude_routines", "claude_routines", "routines", "routine", "seven_day_cowork", "cowork"]
        if let row = routineKeys.compactMap({ root[$0] as? [String: Any] }).first,
           let used = ClaudeValue.number(row["utilization"]), used <= 100 {
            windows.append(.init(id: "claude-routines", title: "日常任务 / Daily Routines", usedPercent: used, resetsAt: date(row["resets_at"])))
        }
        guard allowsEmpty || !windows.isEmpty else { throw ClaudeSupportError.invalidResponse }
        return windows
    }
}

/// Read-only access to Claude Code's credential owner. Refresh tokens are never copied or rotated here.
enum ClaudeCredentialReader {
    private static func credentialData(at url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 1_048_577) ?? Data()
        guard data.count <= 1_048_576 else { throw ClaudeSupportError.invalidResponse }
        return data
    }

    private static func readKeychain(_ query: [String: Any]) -> (OSStatus, Data?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }

    static func read(allowPrompt: Bool, environment: [String: String] = ProcessInfo.processInfo.environment,
                     home: URL = FileManager.default.homeDirectoryForCurrentUser,
                     keychainRead: ([String: Any]) -> (OSStatus, Data?) = readKeychain) throws -> ClaudeCredential {
        if let custom = environment["CLAUDE_CONFIG_DIR"], !custom.isEmpty {
            // Do not fall through from a custom profile into the ambient Keychain account.
            let url = URL(fileURLWithPath: custom).appendingPathComponent(".credentials.json")
            guard let data = try? credentialData(at: url) else { throw ClaudeSupportError.loginRequired }
            return try ClaudeCredential.decode(data)
        }
        let context = LAContext()
        context.interactionNotAllowed = !allowPrompt
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials", kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context]
        var data: Data?
        let status = KeychainInteractionPolicy.perform(allowInteraction: allowPrompt) {
            let result = keychainRead(query)
            data = result.1
            return result.0
        }
        if status == errSecInteractionNotAllowed || status == errSecInteractionRequired || status == errSecAuthFailed || status == errSecUserCanceled {
            throw ClaudeSupportError.keychainDenied
        }
        if status == errSecSuccess, let data { return try ClaudeCredential.decode(data) }
        guard status == errSecItemNotFound else { throw ClaudeSupportError.keychainDenied }
        let url = home.appendingPathComponent(".claude/.credentials.json")
        guard let data = try? credentialData(at: url) else { throw ClaudeSupportError.loginRequired }
        return try ClaudeCredential.decode(data)
    }
}

private final class ClaudeNoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

actor ClaudeUsageService {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let transport: Transport
    private var blockedUntil: [String: Date] = [:]
    private var profiles: [String: (Date, Data?)] = [:]
    init(transport: @escaping Transport = ClaudeHTTPTransport.send) { self.transport = transport }

    func fetch(_ credential: ClaudeCredential, now: Date = Date(), includeProfile: Bool = true,
               claudeVersion: String? = nil) async throws -> ClaudeUsageSnapshot {
        if let expiry = credential.expiresAt, expiry <= now { throw ClaudeSupportError.loginRequired }
        if let until = blockedUntil[credential.identity], until > now { throw ClaudeSupportError.rateLimited(until) }
        let data = try await request("usage", credential: credential, now: now, claudeVersion: claudeVersion)
        let result = try ClaudeUsageSnapshot.parseUsage(data, credentialID: credential.identity, plan: credential.plan, now: now)
        return includeProfile ? await enrichProfile(result, credential: credential, now: now, claudeVersion: claudeVersion) : result
    }

    func enrichProfile(_ snapshot: ClaudeUsageSnapshot, credential: ClaudeCredential, now: Date = Date(),
                       claudeVersion: String? = nil) async -> ClaudeUsageSnapshot {
        let profile: Data?
        if let cached = profiles[credential.identity], now.timeIntervalSince(cached.0) < 900 { profile = cached.1 }
        else {
            profile = try? await request("profile", credential: credential, now: now, timeout: 2, claudeVersion: claudeVersion)
            if profiles.count >= 32 { profiles.removeAll() }
            profiles[credential.identity] = (now, profile)
        }
        let identity = profile.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let account = identity?["account"] as? [String: Any]
        let organization = identity?["organization"] as? [String: Any]
        var result = snapshot
        result.email = account?["email"] as? String ?? account?["email_address"] as? String ?? account?["emailAddress"] as? String
        result.organization = organization?["name"] as? String ?? organization?["uuid"] as? String
        if let accountID = ClaudeValue.text(account?["uuid"]), let orgID = ClaudeValue.text(organization?["uuid"]) {
            result.accountKey = ClaudeValue.key("oauth|" + accountID + "|" + orgID)
        }
        return result
    }

    private func request(_ endpoint: String, credential: ClaudeCredential, now: Date, timeout: TimeInterval = 30,
                         claudeVersion: String? = nil) async throws -> Data {
        let agents = ClaudeCodeVersion.userAgents(version: claudeVersion)
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/\(endpoint)" + (endpoint == "usage" ? "?cedar_ember=1" : ""))!)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = timeout
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(endpoint == "usage" ? agents.primary : agents.legacy, forHTTPHeaderField: "User-Agent")
        var (data, response) = try await transport(request)
        // Retry only the rejection of the optional inventory query, with the same credential and version.
        // A 403 naming the missing user:profile scope is a real authorization answer and is not retried.
        if endpoint == "usage", [400, 404, 422].contains(response.statusCode) || (response.statusCode == 403
            && !String(decoding: data.prefix(4096), as: UTF8.self).contains("user:profile")) {
            request.url = URL(string: "https://api.anthropic.com/api/oauth/usage")!
            request.setValue(agents.legacy, forHTTPHeaderField: "User-Agent")
            (data, response) = try await transport(request)
        }
        guard data.count <= 1_048_576 else { throw ClaudeSupportError.invalidResponse }
        switch response.statusCode {
        case 200: return data
        case 401: throw ClaudeSupportError.loginRequired
        case 429:
            let until = ClaudeHTTPTransport.retryDate(response: response, now: now)
            if endpoint == "usage" { blockedUntil[credential.identity] = until }
            throw ClaudeSupportError.rateLimited(until)
        default: throw ClaudeSupportError.server(response.statusCode)
        }
    }
}

// Shared ephemeral transport: never forwards credentials through redirects or stores cookies.
enum ClaudeHTTPTransport {
    static func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration, delegate: ClaudeNoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ClaudeSupportError.invalidResponse }
        return (data, response)
    }

    static func retryDate(response: HTTPURLResponse, now: Date) -> Date {
        let header = response.value(forHTTPHeaderField: "Retry-After")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let raw = header.flatMap(Double.init) ?? header.flatMap { formatter.date(from: $0)?.timeIntervalSince(now) } ?? 300
        return now.addingTimeInterval(max(60, min(raw.isFinite ? raw : 300, 86400)))
    }
}

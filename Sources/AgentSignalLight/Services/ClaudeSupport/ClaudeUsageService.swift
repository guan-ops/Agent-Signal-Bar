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
    case rateLimited(Date), server(Int)
    var message: String {
        switch self {
        case .loginRequired: "请登录 Claude Code 后重试。 / Sign in to Claude Code, then retry."
        case .keychainDenied: "需要授权读取 Claude 登录信息。 / Allow access to Claude credentials."
        case .invalidResponse: "Claude 返回的数据不完整。 / Claude returned incomplete data."
        case .missingCLI: "未找到命令行工具，请选择已安装的可执行文件。 / Select the installed executable."
        case .commandFailed: "命令未成功，请在终端检查登录状态。 / Check sign-in status in Terminal."
        case .timedOut: "操作超时，已保留上次结果。 / Timed out; previous results retained."
        case .outputTooLarge: "命令输出超过限制。 / Command output exceeded the limit."
        case .rateLimited: "Claude 暂时限流，将稍后重试。 / Claude is rate limited; retrying later."
        case .server(let status): "Claude HTTP \(status)，请稍后重试。 / Please retry later."
        }
    }
}

struct ClaudeQuotaWindow: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let usedPercent: Double
    let resetsAt: Date?
}

struct ClaudeUsageSnapshot: Sendable {
    let credentialID: String
    let email: String?
    let organization: String?
    let plan: String?
    let windows: [ClaudeQuotaWindow]
    let extraUsed: Double?
    let extraLimit: Double?
    let extraCurrency: String
    let updatedAt: Date
    var source: String = "Claude Code OAuth"

    static func extraAmounts(_ extra: [String: Any]?) -> (used: Double?, limit: Double?, currency: String) {
        func amount(_ key: String) -> Double? {
            guard extra?["is_enabled"] as? Bool == true,
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

    static func windows(from data: Data) throws -> [ClaudeQuotaWindow] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ClaudeSupportError.invalidResponse }
        var windows: [ClaudeQuotaWindow] = []
        let keys = [("five_hour", "5 小时 / 5 hours"), ("seven_day", "7 天 / 7 days"),
                    ("seven_day_opus", "Opus · 7 天"), ("seven_day_sonnet", "Sonnet · 7 天"),
                    ("seven_day_oauth_apps", "OAuth Apps · 7 天")]
        for (key, title) in keys {
            guard let row = root[key] as? [String: Any], let number = row["utilization"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  case let used = number.doubleValue,
                  used.isFinite, used >= 0, used <= 100 else { continue }
            windows.append(.init(id: key, title: title, usedPercent: used, resetsAt: date(row["resets_at"])))
        }
        if let limits = root["limits"] as? [[String: Any]] {
            for (index, limit) in limits.enumerated() {
                guard limit["is_active"] as? Bool != false,
                      let scope = limit["scope"] as? [String: Any], let model = scope["model"] as? [String: Any],
                      let title = model["display_name"] as? String, !title.isEmpty,
                      let value = limit["percent"] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                      value.doubleValue.isFinite, (0...100).contains(value.doubleValue) else { continue }
                windows.append(.init(id: "scoped-\(index)", title: title, usedPercent: value.doubleValue, resetsAt: date(limit["resets_at"])))
            }
        }
        guard !windows.isEmpty else { throw ClaudeSupportError.invalidResponse }
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

    static func read(allowPrompt: Bool, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> ClaudeCredential {
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
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecInteractionNotAllowed || status == errSecAuthFailed || status == errSecUserCanceled {
            throw ClaudeSupportError.keychainDenied
        }
        if status == errSecSuccess, let data = result as? Data { return try ClaudeCredential.decode(data) }
        guard status == errSecItemNotFound else { throw ClaudeSupportError.keychainDenied }
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
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
    init(transport: @escaping Transport = ClaudeHTTPTransport.send) { self.transport = transport }

    func fetch(_ credential: ClaudeCredential, now: Date = Date()) async throws -> ClaudeUsageSnapshot {
        if let expiry = credential.expiresAt, expiry <= now { throw ClaudeSupportError.loginRequired }
        if let until = blockedUntil[credential.identity], until > now { throw ClaudeSupportError.rateLimited(until) }
        let data = try await request("usage", credential: credential, now: now)
        let windows = try ClaudeUsageSnapshot.windows(from: data)
        let profile = try? await request("profile", credential: credential, now: now)
        let identity = profile.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let account = identity?["account"] as? [String: Any]
        let organization = identity?["organization"] as? [String: Any]
        let usage = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let extra = usage?["extra_usage"] as? [String: Any]
        let amounts = ClaudeUsageSnapshot.extraAmounts(extra)
        return .init(credentialID: credential.identity,
            email: account?["email"] as? String ?? account?["email_address"] as? String ?? account?["emailAddress"] as? String,
            organization: organization?["name"] as? String ?? organization?["uuid"] as? String,
            plan: credential.plan, windows: windows,
            extraUsed: amounts.used,
            extraLimit: amounts.limit,
            extraCurrency: amounts.currency,
            updatedAt: now)
    }

    private func request(_ endpoint: String, credential: ClaudeCredential, now: Date) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/\(endpoint)")!)
        request.timeoutInterval = 30
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("claude-code/2.1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await transport(request)
        guard data.count <= 1_048_576 else { throw ClaudeSupportError.invalidResponse }
        switch response.statusCode {
        case 200: return data
        case 401: throw ClaudeSupportError.loginRequired
        case 429:
            let until = ClaudeHTTPTransport.retryDate(response: response, now: now)
            blockedUntil[credential.identity] = until
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

import AgentSignalLightCore
import Foundation

final class CodexRateLimitFetcher: @unchecked Sendable {
    private let environment: [String: String]
    private let fileManager: FileManager
    private let session: URLSession
    private let browserCookieImporter: any OpenAIBrowserCookieImporting

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        session: URLSession = .shared,
        browserCookieImporter: any OpenAIBrowserCookieImporting = OpenAIBrowserCookieImporter()
    ) {
        self.environment = environment
        self.fileManager = fileManager
        self.session = session
        self.browserCookieImporter = browserCookieImporter
    }

    func fetchQuota(now: Date = Date()) async throws -> AgentQuotaStatus {
        try await fetchUsageStatus(now: now).quota
    }

    func fetchUsageStatus(now: Date = Date()) async throws -> CodexUsageStatus {
        try await fetchUsageStatus(now: now, route: .oauthAPI)
    }

    func fetchUsageStatus(now: Date = Date(), route: CodexRateLimitFetchRoute) async throws -> CodexUsageStatus {
        switch route {
        case .automatic(let cookieHeader, let importsBrowserCookies):
            if let cookieHeader = Self.normalizedCookieHeader(cookieHeader) {
                do {
                    let response = try await fetchUsage(cookieHeader: cookieHeader, accountID: try? loadCredentials().accountID)
                    return try Self.usageStatus(from: response, updatedAt: now)
                } catch {
                    return try await fetchOAuthUsageStatus(now: now)
                }
            }
            if importsBrowserCookies,
               let imported = await browserCookieImporter.importCookieHeader()
            {
                do {
                    let response = try await fetchUsage(
                        cookieHeader: imported.cookieHeader,
                        accountID: try? loadCredentials().accountID
                    )
                    return try Self.usageStatus(from: response, updatedAt: now)
                } catch {
                    return try await fetchOAuthUsageStatus(now: now)
                }
            }
            return try await fetchOAuthUsageStatus(now: now)
        case .oauthAPI:
            return try await fetchOAuthUsageStatus(now: now)
        case .manualCookie(let cookieHeader):
            guard let cookieHeader = Self.normalizedCookieHeader(cookieHeader) else {
                throw CodexRateLimitFetchError.invalidCookieHeader
            }
            let response = try await fetchUsage(cookieHeader: cookieHeader, accountID: try? loadCredentials().accountID)
            return try Self.usageStatus(from: response, updatedAt: now)
        }
    }

    private func fetchOAuthUsageStatus(now: Date) async throws -> CodexUsageStatus {
        var credentials = try loadCredentials()
        if credentials.needsRefresh {
            credentials = try await refresh(credentials)
            try saveIfNeeded(credentials)
        }

        do {
            let response = try await fetchUsage(credentials: credentials)
            return try Self.usageStatus(from: response, updatedAt: now)
        } catch CodexRateLimitFetchError.unauthorized where !credentials.refreshToken.isEmpty {
            credentials = try await refresh(credentials)
            try saveIfNeeded(credentials)
            let response = try await fetchUsage(credentials: credentials)
            return try Self.usageStatus(from: response, updatedAt: now)
        }
    }

    private func fetchUsage(cookieHeader: String, accountID: String?) async throws -> CodexUsageResponse {
        var request = URLRequest(url: usageURL())
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("AgentSignalLight", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CodexRateLimitFetchError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200...299:
            return try JSONDecoder().decode(CodexUsageResponse.self, from: data)
        case 401, 403:
            throw CodexRateLimitFetchError.unauthorized
        default:
            throw CodexRateLimitFetchError.serverError(httpResponse.statusCode)
        }
    }

    private func fetchUsage(credentials: CodexCredentials) async throws -> CodexUsageResponse {
        var request = URLRequest(url: usageURL())
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("AgentSignalLight", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accountID = credentials.accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CodexRateLimitFetchError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200...299:
            return try JSONDecoder().decode(CodexUsageResponse.self, from: data)
        case 401, 403:
            throw CodexRateLimitFetchError.unauthorized
        default:
            throw CodexRateLimitFetchError.serverError(httpResponse.statusCode)
        }
    }

    private func refresh(_ credentials: CodexCredentials) async throws -> CodexCredentials {
        guard !credentials.refreshToken.isEmpty else {
            return credentials
        }

        var request = URLRequest(url: URL(string: "https://auth.openai.com/oauth/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_id": "app_EMoamEEZ73f0CkXaXp7hrann",
            "grant_type": "refresh_token",
            "refresh_token": credentials.refreshToken,
            "scope": "openid profile email"
        ])

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw CodexRateLimitFetchError.refreshFailed
        }

        return CodexCredentials(
            accessToken: json["access_token"] as? String ?? credentials.accessToken,
            refreshToken: json["refresh_token"] as? String ?? credentials.refreshToken,
            idToken: json["id_token"] as? String ?? credentials.idToken,
            accountID: json["account_id"] as? String ?? credentials.accountID,
            lastRefresh: Date(),
            source: credentials.source
        )
    }

    private func loadCredentials() throws -> CodexCredentials {
        let url = authFileURL()
        guard fileManager.fileExists(atPath: url.path) else {
            throw CodexRateLimitFetchError.missingCredentials
        }

        let data = try Data(contentsOf: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexRateLimitFetchError.invalidCredentials
        }

        if let apiKey = json["OPENAI_API_KEY"] as? String,
           !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return CodexCredentials(
                accessToken: apiKey,
                refreshToken: "",
                idToken: nil,
                accountID: nil,
                lastRefresh: nil,
                source: .apiKey
            )
        }

        guard let tokens = json["tokens"] as? [String: Any],
              let accessToken = Self.stringValue(in: tokens, snakeCaseKey: "access_token", camelCaseKey: "accessToken"),
              !accessToken.isEmpty
        else {
            throw CodexRateLimitFetchError.invalidCredentials
        }

        let refreshToken = Self.stringValue(
            in: tokens,
            snakeCaseKey: "refresh_token",
            camelCaseKey: "refreshToken"
        ) ?? ""

        return CodexCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: Self.stringValue(in: tokens, snakeCaseKey: "id_token", camelCaseKey: "idToken"),
            accountID: Self.stringValue(in: tokens, snakeCaseKey: "account_id", camelCaseKey: "accountId"),
            lastRefresh: Self.parseLastRefresh(from: json["last_refresh"]),
            source: .oauth
        )
    }

    private func saveIfNeeded(_ credentials: CodexCredentials) throws {
        guard credentials.canPersist else { return }
        try save(credentials)
    }

    private func save(_ credentials: CodexCredentials) throws {
        let url = authFileURL()
        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = existing
        }

        var tokens = (json["tokens"] as? [String: Any]) ?? [:]
        tokens["access_token"] = credentials.accessToken
        tokens["refresh_token"] = credentials.refreshToken
        if let idToken = credentials.idToken {
            tokens["id_token"] = idToken
        }
        if let accountID = credentials.accountID {
            tokens["account_id"] = accountID
        }
        json["tokens"] = tokens
        json["last_refresh"] = ISO8601DateFormatter().string(from: Date())

        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private func authFileURL() -> URL {
        if let codexHome = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !codexHome.isEmpty {
            return URL(fileURLWithPath: (codexHome as NSString).expandingTildeInPath)
                .appendingPathComponent("auth.json")
        }

        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("auth.json")
    }

    private func usageURL() -> URL {
        let normalizedBaseURL = normalizedChatGPTBaseURL()
        let path = normalizedBaseURL.contains("/backend-api") ? "/wham/usage" : "/api/codex/usage"
        return URL(string: normalizedBaseURL + path)
            ?? URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    }

    private func normalizedChatGPTBaseURL() -> String {
        var value = configuredChatGPTBaseURL() ?? "https://chatgpt.com/backend-api"
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") {
            value.removeLast()
        }
        if (value.hasPrefix("https://chatgpt.com") || value.hasPrefix("https://chat.openai.com")),
           !value.contains("/backend-api") {
            value += "/backend-api"
        }
        return value.isEmpty ? "https://chatgpt.com/backend-api" : value
    }

    private func configuredChatGPTBaseURL() -> String? {
        let configURL = authFileURL()
            .deletingLastPathComponent()
            .appendingPathComponent("config.toml")
        guard let contents = try? String(contentsOf: configURL, encoding: .utf8) else {
            return nil
        }

        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = rawLine.split(separator: "#", maxSplits: 1).first ?? ""
            let parts = line.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard parts.count == 2, parts[0] == "chatgpt_base_url" else {
                continue
            }

            return parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }

        return nil
    }

    static func quotaStatus(from response: CodexUsageResponse, updatedAt: Date) throws -> AgentQuotaStatus {
        try usageStatus(from: response, updatedAt: updatedAt).quota
    }

    static func usageStatus(from response: CodexUsageResponse, updatedAt: Date) throws -> CodexUsageStatus {
        guard let primaryWindow = response.rateLimit?.primaryWindow,
              let primary = windowStatus(from: primaryWindow)
        else {
            throw CodexRateLimitFetchError.noRateLimits
        }

        let secondary = response.rateLimit?.secondaryWindow.flatMap(windowStatus(from:))
        let quota = AgentQuotaStatus(
            remainingPercent: primary.remainingPercent,
            usedPercent: primary.usedPercent,
            limitName: nil,
            windowMinutes: primary.windowMinutes,
            resetsAt: primary.resetsAt,
            updatedAt: updatedAt,
            primary: primary,
            secondary: secondary
        )
        return CodexUsageStatus(
            quota: quota,
            credits: creditStatus(from: response, updatedAt: updatedAt),
            planName: response.planType?.rawValue
        )
    }

    private static func windowStatus(from window: CodexUsageResponse.WindowSnapshot) -> AgentQuotaWindowStatus? {
        let usedPercent = min(max(window.usedPercent, 0), 100)
        return AgentQuotaWindowStatus(
            remainingPercent: 100 - usedPercent,
            usedPercent: usedPercent,
            windowMinutes: window.limitWindowSeconds / 60,
            resetsAt: Date(timeIntervalSince1970: TimeInterval(window.resetAt))
        )
    }

    private static func creditStatus(from response: CodexUsageResponse, updatedAt: Date) -> CodexCreditStatus? {
        let limit = response.individualLimit
            ?? response.rateLimit?.individualLimit
            ?? response.spendControl?.individualLimit
        if let limitStatus = limit?.creditStatus(updatedAt: updatedAt) {
            return limitStatus
        }
        guard let balance = response.credits?.balance else { return nil }
        return CodexCreditStatus(
            title: "Credits",
            used: nil,
            limit: nil,
            remaining: max(0, balance),
            remainingPercent: nil,
            resetsAt: nil,
            updatedAt: updatedAt
        )
    }

    private static func parseLastRefresh(from raw: Any?) -> Date? {
        guard let value = raw as? String, !value.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func stringValue(
        in dictionary: [String: Any],
        snakeCaseKey: String,
        camelCaseKey: String
    ) -> String? {
        if let value = dictionary[snakeCaseKey] as? String,
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return value
        }
        if let value = dictionary[camelCaseKey] as? String,
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return value
        }
        return nil
    }

    static func normalizedCookieHeader(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }

        if let extracted = extractCookieHeader(from: value) {
            value = extracted
        }

        value = stripCookiePrefix(value)
        value = stripWrappingQuotes(value)
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.contains("=") else { return nil }
        return value.isEmpty ? nil : value
    }

    private static func extractCookieHeader(from raw: String) -> String? {
        let patterns = [
            #"(?i)-H\s*'Cookie:\s*([^']+)'"#,
            #"(?i)-H\s*\"Cookie:\s*([^\"]+)\""#,
            #"(?i)\bcookie:\s*'([^']+)'"#,
            #"(?i)\bcookie:\s*\"([^\"]+)\""#,
            #"(?i)\bcookie:\s*([^\r\n]+)"#,
            #"(?i)(?:^|\s)(?:--cookie|-b)\s*'([^']+)'"#,
            #"(?i)(?:^|\s)(?:--cookie|-b)\s*\"([^\"]+)\""#,
            #"(?i)(?:^|\s)-b([^\s=]+=[^\s]+)"#,
            #"(?i)(?:^|\s)(?:--cookie|-b)\s+([^\s]+)"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
            guard let match = regex.firstMatch(in: raw, range: range),
                  match.numberOfRanges >= 2,
                  let captureRange = Range(match.range(at: 1), in: raw)
            else {
                continue
            }
            let captured = raw[captureRange].trimmingCharacters(in: .whitespacesAndNewlines)
            if !captured.isEmpty {
                return String(captured)
            }
        }
        return nil
    }

    private static func stripCookiePrefix(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("cookie:") else { return trimmed }
        let index = trimmed.index(trimmed.startIndex, offsetBy: "cookie:".count)
        return String(trimmed[index...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripWrappingQuotes(_ raw: String) -> String {
        guard raw.count >= 2 else { return raw }
        if (raw.hasPrefix("\"") && raw.hasSuffix("\"")) ||
            (raw.hasPrefix("'") && raw.hasSuffix("'"))
        {
            return String(raw.dropFirst().dropLast())
        }
        return raw
    }
}

enum CodexRateLimitFetchRoute: Equatable, Sendable {
    case automatic(cookieHeader: String?, importsBrowserCookies: Bool)
    case oauthAPI
    case manualCookie(String)
}

struct CodexUsageStatus: Equatable, Sendable {
    let quota: AgentQuotaStatus
    let credits: CodexCreditStatus?
    let planName: String?
}

struct CodexCreditStatus: Codable, Equatable, Sendable {
    let title: String
    let used: Double?
    let limit: Double?
    let remaining: Double
    let remainingPercent: Double?
    let resetsAt: Date?
    let updatedAt: Date

    var usedPercent: Double? {
        remainingPercent.map { min(100, max(0, 100 - $0)) }
    }
}

struct CodexUsageResponse: Decodable, Sendable {
    let planType: PlanType?
    let rateLimit: RateLimitDetails?
    let credits: CreditDetails?
    let individualLimit: SpendControlLimitSnapshot?
    let spendControl: SpendControlDetails?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case credits
        case individualLimit = "individual_limit"
        case individualLimitCamel = "individualLimit"
        case spendControl = "spend_control"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        planType = try? container.decodeIfPresent(PlanType.self, forKey: .planType)
        rateLimit = try? container.decodeIfPresent(RateLimitDetails.self, forKey: .rateLimit)
        credits = try? container.decodeIfPresent(CreditDetails.self, forKey: .credits)
        individualLimit = (try? container.decodeIfPresent(SpendControlLimitSnapshot.self, forKey: .individualLimit))
            ?? (try? container.decodeIfPresent(SpendControlLimitSnapshot.self, forKey: .individualLimitCamel))
        spendControl = try? container.decodeIfPresent(SpendControlDetails.self, forKey: .spendControl)
    }

    enum PlanType: Decodable, Equatable, Sendable {
        case known(String)

        var rawValue: String {
            switch self {
            case let .known(value):
                return value
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            self = .known(try container.decode(String.self))
        }
    }

    struct RateLimitDetails: Decodable, Sendable {
        let primaryWindow: WindowSnapshot?
        let secondaryWindow: WindowSnapshot?
        let individualLimit: SpendControlLimitSnapshot?

        enum CodingKeys: String, CodingKey {
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
            case individualLimit = "individual_limit"
            case individualLimitCamel = "individualLimit"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            primaryWindow = try? container.decodeIfPresent(WindowSnapshot.self, forKey: .primaryWindow)
            secondaryWindow = try? container.decodeIfPresent(WindowSnapshot.self, forKey: .secondaryWindow)
            individualLimit = (try? container.decodeIfPresent(SpendControlLimitSnapshot.self, forKey: .individualLimit))
                ?? (try? container.decodeIfPresent(SpendControlLimitSnapshot.self, forKey: .individualLimitCamel))
        }
    }

    struct WindowSnapshot: Decodable, Sendable {
        let usedPercent: Double
        let resetAt: Int
        let limitWindowSeconds: Int

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case resetAt = "reset_at"
            case limitWindowSeconds = "limit_window_seconds"
        }
    }

    struct CreditDetails: Decodable, Sendable {
        let balance: Double?

        enum CodingKeys: String, CodingKey {
            case balance
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            balance = CodexUsageResponse.decodeFlexibleDouble(container, forKey: .balance)
        }
    }

    struct SpendControlDetails: Decodable, Sendable {
        let individualLimit: SpendControlLimitSnapshot?

        enum CodingKeys: String, CodingKey {
            case individualLimit = "individual_limit"
            case individualLimitCamel = "individualLimit"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            individualLimit = (try? container.decodeIfPresent(SpendControlLimitSnapshot.self, forKey: .individualLimit))
                ?? (try? container.decodeIfPresent(SpendControlLimitSnapshot.self, forKey: .individualLimitCamel))
        }
    }

    struct SpendControlLimitSnapshot: Decodable, Sendable {
        let limit: Double?
        let used: Double?
        let remainingPercent: Double?
        let resetsAt: Int?

        enum CodingKeys: String, CodingKey {
            case limit
            case used
            case remainingPercent
            case remainingPercentSnake = "remaining_percent"
            case resetsAt
            case resetsAtSnake = "resets_at"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            limit = CodexUsageResponse.decodeFlexibleDouble(container, forKey: .limit)
            used = CodexUsageResponse.decodeFlexibleDouble(container, forKey: .used)
            remainingPercent = CodexUsageResponse.decodeFlexibleDouble(container, forKey: .remainingPercent)
                ?? CodexUsageResponse.decodeFlexibleDouble(container, forKey: .remainingPercentSnake)
            resetsAt = CodexUsageResponse.decodeFlexibleInt(container, forKey: .resetsAt)
                ?? CodexUsageResponse.decodeFlexibleInt(container, forKey: .resetsAtSnake)
        }

        func creditStatus(updatedAt: Date) -> CodexCreditStatus? {
            guard let limit, limit > 0 else { return nil }
            let used: Double = if let used {
                max(0, used)
            } else if let remainingPercent {
                limit * max(0, min(100, 100 - remainingPercent)) / 100
            } else {
                0
            }
            let remainingPercent = remainingPercent ?? max(0, min(100, 100 - (used / limit * 100)))
            return CodexCreditStatus(
                title: "Monthly credit limit",
                used: used,
                limit: limit,
                remaining: max(0, limit - used),
                remainingPercent: remainingPercent,
                resetsAt: resetsAt.flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil },
                updatedAt: updatedAt
            )
        }
    }

    private static func decodeFlexibleDouble<K: CodingKey>(
        _ container: KeyedDecodingContainer<K>,
        forKey key: K
    ) -> Double? {
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return Double(value)
        }
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            return Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private static func decodeFlexibleInt<K: CodingKey>(
        _ container: KeyedDecodingContainer<K>,
        forKey key: K
    ) -> Int? {
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return Int(value)
        }
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }
}

private struct CodexCredentials {
    let accessToken: String
    let refreshToken: String
    let idToken: String?
    let accountID: String?
    let lastRefresh: Date?
    let source: CodexCredentialSource

    var needsRefresh: Bool {
        guard source == .oauth, !refreshToken.isEmpty else { return false }
        guard let lastRefresh else { return true }
        return Date().timeIntervalSince(lastRefresh) > 8 * 24 * 60 * 60
    }

    var canPersist: Bool {
        source == .oauth
    }
}

private enum CodexCredentialSource {
    case apiKey
    case oauth
}

private enum CodexRateLimitFetchError: Error {
    case missingCredentials
    case invalidCredentials
    case invalidCookieHeader
    case invalidResponse
    case unauthorized
    case refreshFailed
    case serverError(Int)
    case noRateLimits
}

import AgentSignalLightCore
import Foundation

final class CodexRateLimitFetcher: @unchecked Sendable {
    private let environment: [String: String]
    private let fileManager: FileManager
    private let session: URLSession

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        session: URLSession = .shared
    ) {
        self.environment = environment
        self.fileManager = fileManager
        self.session = session
    }

    func fetchQuota(now: Date = Date()) async throws -> AgentQuotaStatus {
        var credentials = try loadCredentials()
        if credentials.needsRefresh {
            credentials = try await refresh(credentials)
            try saveIfNeeded(credentials)
        }

        do {
            let response = try await fetchUsage(credentials: credentials)
            return try Self.quotaStatus(from: response, updatedAt: now)
        } catch CodexRateLimitFetchError.unauthorized where !credentials.refreshToken.isEmpty {
            credentials = try await refresh(credentials)
            try saveIfNeeded(credentials)
            let response = try await fetchUsage(credentials: credentials)
            return try Self.quotaStatus(from: response, updatedAt: now)
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
        guard let primaryWindow = response.rateLimit?.primaryWindow,
              let primary = windowStatus(from: primaryWindow)
        else {
            throw CodexRateLimitFetchError.noRateLimits
        }

        let secondary = response.rateLimit?.secondaryWindow.flatMap(windowStatus(from:))
        return AgentQuotaStatus(
            remainingPercent: primary.remainingPercent,
            usedPercent: primary.usedPercent,
            limitName: nil,
            windowMinutes: primary.windowMinutes,
            resetsAt: primary.resetsAt,
            updatedAt: updatedAt,
            primary: primary,
            secondary: secondary
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
}

struct CodexUsageResponse: Decodable, Sendable {
    let rateLimit: RateLimitDetails?

    enum CodingKeys: String, CodingKey {
        case rateLimit = "rate_limit"
    }

    struct RateLimitDetails: Decodable, Sendable {
        let primaryWindow: WindowSnapshot?
        let secondaryWindow: WindowSnapshot?

        enum CodingKeys: String, CodingKey {
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
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
    case invalidResponse
    case unauthorized
    case refreshFailed
    case serverError(Int)
    case noRateLimits
}

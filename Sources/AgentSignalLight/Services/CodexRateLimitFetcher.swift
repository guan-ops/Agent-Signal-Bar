import AgentSignalLightCore
import CryptoKit
import Foundation

final class CodexRateLimitFetcher: @unchecked Sendable {
    private static let officialCookieUsageURL = URL(
        string: "https://chatgpt.com/backend-api/wham/usage"
    )!

    private let environment: [String: String]
    private let fileManager: FileManager
    private let session: URLSession
    private let browserCookieImporter: any OpenAIBrowserCookieImporting
    private let credentialPersistence: (any CodexRefreshedCredentialPersisting)?
    private let clock: @Sendable () -> Date

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        session: URLSession = .shared,
        browserCookieImporter: any OpenAIBrowserCookieImporting = OpenAIBrowserCookieImporter(),
        credentialPersistence: (any CodexRefreshedCredentialPersisting)? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.environment = environment
        self.fileManager = fileManager
        self.session = session
        self.browserCookieImporter = browserCookieImporter
        self.credentialPersistence = credentialPersistence
        self.clock = clock
    }

    func fetchQuota(now: Date? = nil) async throws -> AgentQuotaStatus {
        let now = now ?? clock()
        return try await fetchUsageStatus(now: now).quota
    }

    func fetchUsageStatus(now: Date? = nil) async throws -> CodexUsageStatus {
        let now = now ?? clock()
        return try await fetchUsageStatus(now: now, route: .oauthAPI)
    }

    func fetchUsageStatus(
        now: Date? = nil,
        route: CodexRateLimitFetchRoute,
        expectedAuthFingerprint: String? = nil
    ) async throws -> CodexUsageStatus {
        let now = now ?? clock()
        try Task.checkCancellation()
        switch route {
        case .automatic(let cookieHeader, let importsBrowserCookies):
            let credentials = try loadCredentialsForCookieRouting(
                expectedAuthFingerprint: expectedAuthFingerprint
            )
            let targetEmail = credentials?.email
            let canSafelyUseCookie = credentials == nil || targetEmail != nil

            if canSafelyUseCookie,
               let cookieHeader = Self.normalizedCookieHeader(cookieHeader) {
                do {
                    try await validateCookieHeader(cookieHeader, targetEmail: targetEmail)
                    let response = try await fetchUsage(
                        cookieHeader: cookieHeader,
                        accountID: credentials?.accountID
                    )
                    try validateActiveAuthFingerprint(credentials?.authFileFingerprint)
                    return try Self.usageStatus(
                        from: response,
                        updatedAt: now,
                        source: .manualCookie,
                        authFingerprint: credentials?.authFileFingerprint
                    )
                } catch {
                    try Task.checkCancellation()
                    let cookieError = error
                    do {
                        return try await fetchOAuthUsageStatus(
                            now: now,
                            expectedAuthFingerprint: expectedAuthFingerprint
                        )
                    } catch CodexRateLimitFetchError.missingCredentials {
                        throw cookieError
                    }
                }
            }
            if canSafelyUseCookie, importsBrowserCookies {
                if let imported = await browserCookieImporter.importCookieHeader(targetEmail: targetEmail) {
                    do {
                        let response = try await fetchUsage(
                            cookieHeader: imported.cookieHeader,
                            accountID: credentials?.accountID
                        )
                        try validateActiveAuthFingerprint(credentials?.authFileFingerprint)
                        return try Self.usageStatus(
                            from: response,
                            updatedAt: now,
                            source: .browserCookie,
                            authFingerprint: credentials?.authFileFingerprint
                        )
                    } catch {
                        try Task.checkCancellation()
                        let cookieError = error
                        do {
                            return try await fetchOAuthUsageStatus(
                                now: now,
                                expectedAuthFingerprint: expectedAuthFingerprint
                            )
                        } catch CodexRateLimitFetchError.missingCredentials {
                            throw cookieError
                        }
                    }
                } else {
                    try Task.checkCancellation()
                    if credentials == nil {
                        throw CodexRateLimitFetchError.cookieUnavailable
                    }
                }
            }
            try Task.checkCancellation()
            return try await fetchOAuthUsageStatus(
                now: now,
                expectedAuthFingerprint: expectedAuthFingerprint
            )
        case .oauthAPI:
            return try await fetchOAuthUsageStatus(
                now: now,
                expectedAuthFingerprint: expectedAuthFingerprint
            )
        case .manualCookie(let cookieHeader):
            guard let cookieHeader = Self.normalizedCookieHeader(cookieHeader) else {
                throw CodexRateLimitFetchError.invalidCookieHeader
            }
            let credentials = try loadCredentialsForCookieRouting(
                expectedAuthFingerprint: expectedAuthFingerprint
            )
            guard credentials == nil || credentials?.email != nil else {
                throw CodexRateLimitFetchError.cookieAccountMismatch
            }
            try await validateCookieHeader(cookieHeader, targetEmail: credentials?.email)
            let response = try await fetchUsage(cookieHeader: cookieHeader, accountID: credentials?.accountID)
            try validateActiveAuthFingerprint(credentials?.authFileFingerprint)
            return try Self.usageStatus(
                from: response,
                updatedAt: now,
                source: .manualCookie,
                authFingerprint: credentials?.authFileFingerprint
            )
        }
    }

    func fetchRateLimitResetCredits(
        now: Date? = nil,
        timeout: TimeInterval = 4,
        expectedAuthFingerprint: String? = nil
    ) async throws -> CodexRateLimitResetCreditsSnapshot {
        let now = now ?? clock()
        try Task.checkCancellation()
        var credentials = try loadCredentials(expectedAuthFingerprint: expectedAuthFingerprint)
        guard credentials.source == .oauth else {
            throw CodexRateLimitFetchError.oauthCredentialsRequired
        }
        if credentials.needsRefresh(at: now) {
            credentials = try await refresh(credentials)
            credentials = try saveIfNeeded(credentials)
            try Task.checkCancellation()
        }

        var request = URLRequest(
            url: rateLimitResetCreditsURL(),
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: timeout
        )
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("AgentSignalLight", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("codex-1", forHTTPHeaderField: "OpenAI-Beta")
        request.setValue("Codex Desktop", forHTTPHeaderField: "originator")
        if let accountID = credentials.accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-ID")
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CodexRateLimitFetchError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200...299:
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom(Self.decodeISO8601Date)
            guard let payload = try? decoder.decode(CodexRateLimitResetCreditsResponse.self, from: data),
                  payload.availableCount >= 0
            else {
                throw CodexRateLimitFetchError.invalidResponse
            }
            try validateActiveAuthFingerprint(credentials.authFileFingerprint)
            return CodexRateLimitResetCreditsSnapshot(
                credits: payload.credits.map(\.model),
                availableCount: payload.availableCount,
                updatedAt: now
            )
        case 401, 403:
            throw CodexRateLimitFetchError.unauthorized
        default:
            throw CodexRateLimitFetchError.serverError(httpResponse.statusCode)
        }
    }

    private func fetchOAuthUsageStatus(
        now: Date,
        expectedAuthFingerprint: String?
    ) async throws -> CodexUsageStatus {
        var credentials = try loadCredentials(expectedAuthFingerprint: expectedAuthFingerprint)
        if credentials.needsRefresh(at: now) {
            credentials = try await refresh(credentials)
            credentials = try saveIfNeeded(credentials)
            try Task.checkCancellation()
        }

        do {
            let response = try await fetchUsage(credentials: credentials)
            try validateActiveAuthFingerprint(credentials.authFileFingerprint)
            return try Self.usageStatus(
                from: response,
                updatedAt: now,
                source: credentials.usageFetchSource,
                authFingerprint: credentials.authFileFingerprint
            )
        } catch CodexRateLimitFetchError.unauthorized where !credentials.refreshToken.isEmpty {
            credentials = try await refresh(credentials)
            credentials = try saveIfNeeded(credentials)
            try Task.checkCancellation()
            let response = try await fetchUsage(credentials: credentials)
            try validateActiveAuthFingerprint(credentials.authFileFingerprint)
            return try Self.usageStatus(
                from: response,
                updatedAt: now,
                source: credentials.usageFetchSource,
                authFingerprint: credentials.authFileFingerprint
            )
        }
    }

    private func fetchUsage(cookieHeader: String, accountID: String?) async throws -> CodexUsageResponse {
        // Browser cookies must never follow a user-configured proxy/base URL.
        // They are scoped to the first-party ChatGPT host only.
        var request = URLRequest(url: Self.officialCookieUsageURL)
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

    private func validateCookieHeader(_ cookieHeader: String, targetEmail: String?) async throws {
        guard let targetEmail = OpenAICookieIdentityVerifier.normalizedEmail(targetEmail) else {
            return
        }
        let signedInEmail = await OpenAICookieIdentityVerifier.signedInEmail(
            cookieHeader: cookieHeader,
            session: session
        )
        try Task.checkCancellation()
        guard OpenAICookieIdentityVerifier.normalizedEmail(signedInEmail) == targetEmail else {
            throw CodexRateLimitFetchError.cookieAccountMismatch
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

        // OAuth providers may rotate the refresh token as soon as they process
        // this request. Finish it even if the UI switches accounts and cancels
        // the surrounding usage task, so the rotated token can still be saved
        // back to the original account slot.
        let session = session
        let refreshTask = Task.detached(priority: .utility) {
            try await session.data(for: request)
        }
        let (data, response) = try await refreshTask.value
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CodexRateLimitFetchError.refreshFailed
        }

        switch httpResponse.statusCode {
        case 200...299:
            break
        case 400, 401, 403:
            throw CodexRateLimitFetchError.refreshRejected
        default:
            throw CodexRateLimitFetchError.serverError(httpResponse.statusCode)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexRateLimitFetchError.refreshFailed
        }

        let refreshedIDToken = json["id_token"] as? String ?? credentials.idToken
        return CodexCredentials(
            accessToken: json["access_token"] as? String ?? credentials.accessToken,
            refreshToken: json["refresh_token"] as? String ?? credentials.refreshToken,
            idToken: refreshedIDToken,
            email: Self.email(fromIDToken: refreshedIDToken) ?? credentials.email,
            accountID: json["account_id"] as? String ?? credentials.accountID,
            lastRefresh: Date(),
            source: credentials.source,
            authFileFingerprint: credentials.authFileFingerprint,
            authFileData: credentials.authFileData
        )
    }

    private func loadCredentials(expectedAuthFingerprint: String? = nil) throws -> CodexCredentials {
        let url = authFileURL()
        guard fileManager.fileExists(atPath: url.path) else {
            throw CodexRateLimitFetchError.missingCredentials
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw CodexRateLimitFetchError.invalidCredentials
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexRateLimitFetchError.invalidCredentials
        }
        let authFileFingerprint = Self.fingerprint(data)
        if let expectedAuthFingerprint,
           authFileFingerprint != expectedAuthFingerprint {
            throw CodexRateLimitFetchError.credentialsChanged
        }

        if let apiKey = json["OPENAI_API_KEY"] as? String,
           !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return CodexCredentials(
                accessToken: apiKey,
                refreshToken: "",
                idToken: nil,
                email: nil,
                accountID: nil,
                lastRefresh: nil,
                source: .apiKey,
                authFileFingerprint: authFileFingerprint,
                authFileData: data
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

        let idToken = Self.stringValue(in: tokens, snakeCaseKey: "id_token", camelCaseKey: "idToken")
        return CodexCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: idToken,
            email: Self.email(fromIDToken: idToken),
            accountID: Self.stringValue(in: tokens, snakeCaseKey: "account_id", camelCaseKey: "accountId"),
            lastRefresh: Self.parseLastRefresh(from: json["last_refresh"]),
            source: .oauth,
            authFileFingerprint: authFileFingerprint,
            authFileData: data
        )
    }

    private func loadCredentialsForCookieRouting(
        expectedAuthFingerprint: String?
    ) throws -> CodexCredentials? {
        do {
            return try loadCredentials(expectedAuthFingerprint: expectedAuthFingerprint)
        } catch CodexRateLimitFetchError.missingCredentials {
            if expectedAuthFingerprint != nil {
                throw CodexRateLimitFetchError.credentialsChanged
            }
            return nil
        }
    }

    func validateActiveAuthFingerprint(_ expectedAuthFingerprint: String?) throws {
        guard let expectedAuthFingerprint else { return }
        let url = authFileURL()
        guard let data = try? Data(contentsOf: url),
              Self.fingerprint(data) == expectedAuthFingerprint
        else {
            throw CodexRateLimitFetchError.credentialsChanged
        }
    }

    private func saveIfNeeded(_ credentials: CodexCredentials) throws -> CodexCredentials {
        guard credentials.canPersist else { return credentials }
        let data = try refreshedAuthData(from: credentials)
        let fingerprint = Self.fingerprint(data)
        return try CodexActiveAuthFileCoordinator.withLock {
            let url = authFileURL()
            let currentData = try? Data(contentsOf: url)
            let activeCredentialsStillMatch = currentData.map(Self.fingerprint)
                == credentials.authFileFingerprint
            var wroteActiveCredentials = false

            CodexActiveAuthFileCoordinator.rememberRefreshedAuthData(
                data,
                replacingAuthFingerprint: credentials.authFileFingerprint
            )

            if activeCredentialsStillMatch {
                if let latestData = try? Data(contentsOf: url),
                   Self.fingerprint(latestData) == credentials.authFileFingerprint {
                    try fileManager.createDirectory(
                        at: url.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try data.write(to: url, options: .atomic)
                    try? fileManager.setAttributes(
                        [.posixPermissions: NSNumber(value: Int16(0o600))],
                        ofItemAtPath: url.path
                    )
                    wroteActiveCredentials = true
                }
            }

            if let credentialPersistence {
                do {
                    try credentialPersistence.persistRefreshedAuthData(
                        data,
                        replacingAuthFingerprint: credentials.authFileFingerprint
                    )
                } catch {
                    // Keep the pending copy so a later account switch can use
                    // it without falling back to the invalid old token.
                    if !wroteActiveCredentials {
                        throw CodexRateLimitFetchError.credentialsChanged
                    }
                }
            } else if wroteActiveCredentials {
                CodexActiveAuthFileCoordinator.clearRefreshedAuthData(
                    replacingAuthFingerprint: credentials.authFileFingerprint
                )
            }

            guard wroteActiveCredentials else {
                throw CodexRateLimitFetchError.credentialsChanged
            }
            return credentials.replacingAuthFile(
                fingerprint: fingerprint,
                data: data
            )
        }
    }

    private func refreshedAuthData(from credentials: CodexCredentials) throws -> Data {
        var json = (try JSONSerialization.jsonObject(with: credentials.authFileData) as? [String: Any])
            ?? [:]

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

        return try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
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

    private func rateLimitResetCreditsURL() -> URL {
        URL(string: normalizedChatGPTBaseURL() + "/wham/rate-limit-reset-credits")
            ?? URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!
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
        try usageStatus(from: response, updatedAt: updatedAt, source: .unknown).quota
    }

    static func usageStatus(
        from response: CodexUsageResponse,
        updatedAt: Date,
        source: CodexUsageFetchSource,
        authFingerprint: String? = nil
    ) throws -> CodexUsageStatus {
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
            planName: response.planType?.rawValue,
            source: source,
            authFingerprint: authFingerprint
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

    private static func email(fromIDToken token: String?) -> String? {
        guard let token else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = payload.count % 4
        if padding > 0 {
            payload += String(repeating: "=", count: 4 - padding)
        }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        let auth = json["https://api.openai.com/auth"] as? [String: Any]
        for value in [json["email"], json["preferred_username"], auth?["email"]] {
            guard let email = value as? String,
                  let normalized = OpenAICookieIdentityVerifier.normalizedEmail(email)
            else {
                continue
            }
            return normalized
        }
        return nil
    }

    private static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
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

    private static func decodeISO8601Date(from decoder: Decoder) throws -> Date {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: raw) {
            return date
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Invalid ISO-8601 date: \(raw)"
        )
    }
}

enum CodexRateLimitFetchRoute: Equatable, Sendable {
    case automatic(cookieHeader: String?, importsBrowserCookies: Bool)
    case oauthAPI
    case manualCookie(String)
}

enum CodexUsageFetchSource: String, Codable, Equatable, Sendable {
    case manualCookie = "manual-cookie"
    case browserCookie = "browser-cookie"
    case oauth
    case apiKey = "api-key"
    case unknown
}

struct CodexUsageStatus: Equatable, Sendable {
    let quota: AgentQuotaStatus
    let credits: CodexCreditStatus?
    let planName: String?
    let source: CodexUsageFetchSource
    let authFingerprint: String?
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

struct CodexRateLimitResetCreditsSnapshot: Codable, Equatable, Sendable {
    let credits: [CodexRateLimitResetCredit]
    let availableCount: Int
    let updatedAt: Date

    func availableCredits(at date: Date) -> [CodexRateLimitResetCredit] {
        credits
            .filter { credit in
                credit.status == .available && (credit.expiresAt.map { $0 > date } ?? true)
            }
            .sorted { lhs, rhs in
                switch (lhs.expiresAt, rhs.expiresAt) {
                case let (lhsDate?, rhsDate?):
                    if lhsDate != rhsDate { return lhsDate < rhsDate }
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    break
                }
                return lhs.grantedAt < rhs.grantedAt
            }
    }
}

struct CodexRateLimitResetCredit: Codable, Equatable, Sendable {
    let status: CodexRateLimitResetCreditStatus
    let grantedAt: Date
    let expiresAt: Date?
}

enum CodexRateLimitResetCreditStatus: Codable, Equatable, Sendable {
    case available
    case redeeming
    case redeemed
    case expired
    case unknown(String)

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "available": self = .available
        case "redeeming": self = .redeeming
        case "redeemed": self = .redeemed
        case "expired": self = .expired
        default: self = .unknown(value)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        let value: String = switch self {
        case .available: "available"
        case .redeeming: "redeeming"
        case .redeemed: "redeemed"
        case .expired: "expired"
        case let .unknown(value): value
        }
        try container.encode(value)
    }
}

private struct CodexRateLimitResetCreditsResponse: Decodable {
    let credits: [CodexRateLimitResetCreditResponse]
    let availableCount: Int

    private enum CodingKeys: String, CodingKey {
        case credits
        case availableCount = "available_count"
    }
}

private struct CodexRateLimitResetCreditResponse: Decodable {
    let status: CodexRateLimitResetCreditStatus
    let grantedAt: Date
    let expiresAt: Date?

    private enum CodingKeys: String, CodingKey {
        case status
        case grantedAt = "granted_at"
        case expiresAt = "expires_at"
    }

    var model: CodexRateLimitResetCredit {
        CodexRateLimitResetCredit(status: status, grantedAt: grantedAt, expiresAt: expiresAt)
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
    let email: String?
    let accountID: String?
    let lastRefresh: Date?
    let source: CodexCredentialSource
    let authFileFingerprint: String
    let authFileData: Data

    func needsRefresh(at now: Date) -> Bool {
        guard source == .oauth, !refreshToken.isEmpty else { return false }
        guard let lastRefresh else { return true }
        return now.timeIntervalSince(lastRefresh) > 8 * 24 * 60 * 60
    }

    var canPersist: Bool {
        source == .oauth
    }

    var usageFetchSource: CodexUsageFetchSource {
        switch source {
        case .apiKey:
            return .apiKey
        case .oauth:
            return .oauth
        }
    }

    func replacingAuthFile(fingerprint: String, data: Data) -> CodexCredentials {
        CodexCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: idToken,
            email: email,
            accountID: accountID,
            lastRefresh: lastRefresh,
            source: source,
            authFileFingerprint: fingerprint,
            authFileData: data
        )
    }
}

private enum CodexCredentialSource {
    case apiKey
    case oauth
}

enum CodexRateLimitFetchError: Error, LocalizedError {
    case missingCredentials
    case invalidCredentials
    case invalidCookieHeader
    case cookieUnavailable
    case cookieAccountMismatch
    case invalidResponse
    case unauthorized
    case oauthCredentialsRequired
    case refreshFailed
    case refreshRejected
    case credentialsChanged
    case serverError(Int)
    case noRateLimits

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "Codex credentials are unavailable. Sign in to Codex and try again."
        case .invalidCredentials:
            return "The saved Codex credentials are invalid. Sign in again and retry."
        case .invalidCookieHeader:
            return "The OpenAI Cookie header is empty or invalid."
        case .cookieUnavailable:
            return "No usable browser Cookie was found for the selected Codex account."
        case .cookieAccountMismatch:
            return "The OpenAI Cookie does not match the selected Codex account."
        case .invalidResponse:
            return "Codex returned an invalid usage response."
        case .unauthorized:
            return "Codex rejected the saved credentials. Sign in again and retry."
        case .oauthCredentialsRequired:
            return "Limit reset credits require Codex OAuth credentials."
        case .refreshFailed:
            return "Codex OAuth credentials could not be refreshed right now."
        case .refreshRejected:
            return "Codex rejected the OAuth refresh token. Sign in again and retry."
        case .credentialsChanged:
            return "The active Codex account changed while usage was refreshing."
        case let .serverError(statusCode):
            return "Codex usage request failed with HTTP status \(statusCode)."
        case .noRateLimits:
            return "Codex did not return rate-limit data for this account."
        }
    }
}

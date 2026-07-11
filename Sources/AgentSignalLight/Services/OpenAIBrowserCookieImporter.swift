import Foundation
#if os(macOS)
import SweetCookieKit
#endif

struct OpenAIBrowserCookieImportResult: Equatable, Sendable {
    let cookieHeader: String
    let sourceLabel: String
    let debugLog: String
    let signedInEmail: String?

    init(
        cookieHeader: String,
        sourceLabel: String,
        debugLog: String,
        signedInEmail: String? = nil
    ) {
        self.cookieHeader = cookieHeader
        self.sourceLabel = sourceLabel
        self.debugLog = debugLog
        self.signedInEmail = signedInEmail
    }
}

protocol OpenAIBrowserCookieImporting: Sendable {
    func importCookieHeader(targetEmail: String?) async -> OpenAIBrowserCookieImportResult?
}

extension OpenAIBrowserCookieImporting {
    func importCookieHeader() async -> OpenAIBrowserCookieImportResult? {
        await importCookieHeader(targetEmail: nil)
    }
}

struct OpenAIBrowserCookieImporter: OpenAIBrowserCookieImporting {
    // The imported header is reused for identity and usage endpoints, so only
    // cookies valid for the shared first-party root scope may be included.
    static let officialCookieScopeURL = URL(string: "https://chatgpt.com/")!

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func importCookieHeader(targetEmail: String?) async -> OpenAIBrowserCookieImportResult? {
        #if os(macOS)
        let session = session
        let importTask = Task.detached(priority: .utility) { () -> OpenAIBrowserCookieImportResult? in
            let client = BrowserCookieClient()
            let query = BrowserCookieQuery(
                domains: ["chatgpt.com"],
                domainMatch: .suffix,
                origin: .fixed(Self.officialCookieScopeURL)
            )
            var logLines: [String] = []
            let identityDeadline = Date().addingTimeInterval(8)

            for browser in Browser.defaultImportOrder {
                guard !Task.isCancelled else { return nil }
                do {
                    let sources = try client.records(matching: query, in: browser) { message in
                        logLines.append("[\(browser.displayName)] \(message)")
                    }
                    for source in sources {
                        guard !Task.isCancelled else { return nil }
                        let cookies = source.cookies(origin: query.origin)
                        guard let header = Self.cookieHeader(
                            from: cookies,
                            for: Self.officialCookieScopeURL
                        ) else {
                            continue
                        }
                        let signedInEmail: String?
                        if let targetEmail = OpenAICookieIdentityVerifier.normalizedEmail(targetEmail) {
                            let remaining = identityDeadline.timeIntervalSinceNow
                            guard remaining > 0 else {
                                logLines.append("Stopped Cookie account matching after the 8-second deadline.")
                                return nil
                            }
                            signedInEmail = await OpenAICookieIdentityVerifier.signedInEmail(
                                cookieHeader: header,
                                session: session,
                                timeout: min(3, remaining)
                            )
                            guard OpenAICookieIdentityVerifier.normalizedEmail(signedInEmail) == targetEmail else {
                                let resolvedEmail = signedInEmail ?? "unknown"
                                logLines.append(
                                    "Skipped \(source.label): signed in as \(resolvedEmail), expected \(targetEmail)."
                                )
                                continue
                            }
                        } else {
                            signedInEmail = nil
                        }
                        logLines.append("Loaded \(cookies.count) cookies from \(source.label).")
                        return OpenAIBrowserCookieImportResult(
                            cookieHeader: header,
                            sourceLabel: source.label,
                            debugLog: logLines.joined(separator: "\n"),
                            signedInEmail: signedInEmail
                        )
                    }
                    if !sources.isEmpty {
                        logLines.append("\(browser.displayName) had matching records but no usable Cookie header.")
                    }
                } catch {
                    logLines.append("\(browser.displayName): \(error.localizedDescription)")
                }
            }

            return nil
        }
        return await withTaskCancellationHandler {
            await importTask.value
        } onCancel: {
            importTask.cancel()
        }
        #else
        nil
        #endif
    }

    #if os(macOS)
    static func cookieHeader(
        from cookies: [HTTPCookie],
        for requestURL: URL,
        now: Date = Date()
    ) -> String? {
        guard requestURL.scheme?.lowercased() == "https",
              requestURL.host?.lowercased() == "chatgpt.com"
        else {
            return nil
        }
        let scopedCookies = cookies
            .filter { cookieMatches($0, requestURL: requestURL, now: now) }
            .sorted { lhs, rhs in
                if lhs.path.count == rhs.path.count {
                    return lhs.name < rhs.name
                }
                return lhs.path.count > rhs.path.count
            }
        guard !scopedCookies.isEmpty else { return nil }

        let header = HTTPCookie.requestHeaderFields(with: scopedCookies)["Cookie"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let header, !header.isEmpty else { return nil }
        return header
    }

    private static func cookieMatches(
        _ cookie: HTTPCookie,
        requestURL: URL,
        now: Date
    ) -> Bool {
        guard let requestHost = requestURL.host?.lowercased() else { return false }
        let cookieDomain = cookie.domain
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        guard !cookieDomain.isEmpty,
              requestHost == cookieDomain || requestHost.hasSuffix(".\(cookieDomain)")
        else {
            return false
        }

        if cookie.isSecure, requestURL.scheme?.lowercased() != "https" {
            return false
        }
        if let expiresDate = cookie.expiresDate, expiresDate <= now {
            return false
        }

        let requestPath = requestURL.path.isEmpty ? "/" : requestURL.path
        let cookiePath = cookie.path.isEmpty ? "/" : cookie.path
        guard requestPath.hasPrefix(cookiePath) else { return false }
        if requestPath == cookiePath || cookiePath.hasSuffix("/") {
            return true
        }
        let boundary = requestPath.index(requestPath.startIndex, offsetBy: cookiePath.count)
        return boundary < requestPath.endIndex && requestPath[boundary] == "/"
    }
    #endif
}

enum OpenAICookieIdentityVerifier {
    static func signedInEmail(
        cookieHeader: String,
        session: URLSession,
        timeout: TimeInterval = 5
    ) async -> String? {
        let endpoints = [
            "https://chatgpt.com/backend-api/me",
            "https://chatgpt.com/api/auth/session",
        ]

        let deadline = Date().addingTimeInterval(timeout)
        for endpoint in endpoints {
            guard !Task.isCancelled else { return nil }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return nil }
            guard let url = URL(string: endpoint) else { continue }
            var request = URLRequest(
                url: url,
                cachePolicy: .reloadIgnoringLocalCacheData,
                timeoutInterval: remaining
            )
            request.httpMethod = "GET"
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            request.setValue("AgentSignalLight", forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            do {
                let (data, response) = try await session.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode)
                else {
                    continue
                }
                if let email = firstEmail(in: data) {
                    return email
                }
            } catch {
                guard !Task.isCancelled else { return nil }
                continue
            }
        }
        return nil
    }

    static func normalizedEmail(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    private static func firstEmail(in data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        var queue: [Any] = [json]
        var inspected = 0

        while let value = queue.first, inspected < 2_000 {
            queue.removeFirst()
            inspected += 1
            if let dictionary = value as? [String: Any] {
                for (key, nestedValue) in dictionary {
                    let normalizedKey = key.lowercased().replacingOccurrences(of: "-", with: "_")
                    if ["email", "user_email", "preferred_username"].contains(normalizedKey),
                       let email = nestedValue as? String,
                       email.contains("@") {
                        return email.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    queue.append(nestedValue)
                }
            } else if let array = value as? [Any] {
                queue.append(contentsOf: array)
            }
        }
        return nil
    }
}

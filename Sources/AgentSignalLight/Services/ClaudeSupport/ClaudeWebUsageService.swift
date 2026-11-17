import Foundation
import SweetCookieKit

struct ClaudeWebOrganization: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
}

enum ClaudeWebCookie {
    static func normalized(_ raw: String) -> String? {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard input.utf8.count <= 16_384, !input.contains("\r"), !input.contains("\n") else { return nil }
        let text = input.lowercased().hasPrefix("cookie:") ? String(input.dropFirst(7)) : input
        // The API only needs this first-party session key. Do not copy unrelated browser cookies.
        for pair in text.split(separator: ";") {
            let pieces = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pieces.count == 2, pieces[0] == "sessionKey", !pieces[1].isEmpty,
               pieces[1].utf8.allSatisfy({ (0x21...0x7E).contains($0) && ![0x22, 0x2C, 0x3B, 0x5C].contains($0) }) {
                return "sessionKey=" + pieces[1]
            }
        }
        return nil
    }

    static func importFromBrowser(_ selected: String = "automatic") async throws -> String {
        let task = Task.detached(priority: .userInitiated) {
            let url = URL(string: "https://claude.ai/")!
            let query = BrowserCookieQuery(domains: ["claude.ai"], domainMatch: .suffix, origin: .fixed(url))
            let client = BrowserCookieClient()
            for browser in Browser.defaultImportOrder where selected == "automatic" || browser.displayName.lowercased().contains(selected.lowercased()) {
                try Task.checkCancellation()
                guard let sources = KeychainInteractionPolicy.whileInteractionAllowed({ try? client.records(matching: query, in: browser) }) else { continue }
                for source in sources {
                    for cookie in source.cookies(origin: query.origin) where cookie.name == "sessionKey" {
                        let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
                        guard domain == "claude.ai", cookie.path == "/", cookie.expiresDate.map({ $0 > Date() }) ?? true,
                              let header = normalized("sessionKey=" + cookie.value) else { continue }
                        return header
                    }
                }
            }
            throw ClaudeSupportError.webLoginRequired
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}

/// Optional first-party Web source. Never mixes its billing data into an OAuth/CLI snapshot.
actor ClaudeWebUsageService {
    private let transport: ClaudeUsageService.Transport
    private var blockedUntil: [String: Date] = [:]
    init(transport: @escaping ClaudeUsageService.Transport = ClaudeHTTPTransport.send) { self.transport = transport }

    func organizations(cookie: String) async throws -> [ClaudeWebOrganization] {
        let data = try await request("organizations", cookie: cookie)
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]], rows.count <= 200 else {
            throw ClaudeSupportError.invalidResponse
        }
        var seen = Set<String>()
        return rows.compactMap { row in
            guard let id = row["uuid"] as? String, UUID(uuidString: id) != nil, seen.insert(id).inserted else { return nil }
            return .init(id: id, name: ClaudeValue.text(row["name"]) ?? "Claude")
        }
    }

    func fetch(cookie: String, organization: ClaudeWebOrganization, now: Date = Date()) async throws -> ClaudeUsageSnapshot {
        guard UUID(uuidString: organization.id) != nil else { throw ClaudeSupportError.organizationRequired }
        let data = try await request("organizations/\(organization.id)/usage?cedar_ember=1", cookie: cookie)
        var result = try ClaudeUsageSnapshot.parseUsage(data,
            credentialID: ClaudeValue.key(cookie + "|" + organization.id), plan: nil, now: now,
            source: "Claude Web", allowsUnavailable: true)
        result.organization = organization.name
        return result
    }

    func enrich(_ initial: ClaudeUsageSnapshot, cookie: String, organization: ClaudeWebOrganization) async -> ClaudeUsageSnapshot {
        let prefix = "organizations/\(organization.id)/"
        async let account = optionalJSON("account", cookie: cookie)
        async let spend = optionalJSON(prefix + "overage_spend_limit", cookie: cookie)
        async let balance = optionalJSON(prefix + "prepaid/credits", cookie: cookie)
        async let dates = optionalJSON(prefix + "subscription_details", cookie: cookie)
        let values = await (account, spend, balance, dates)
        var result = initial
        if let root = values.0.flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) {
            result.email = ClaudeValue.text(root["email_address"]) ?? ClaudeValue.text(root["email"])
            if let id = ClaudeValue.text(root["uuid"]) {
                result.accountKey = ClaudeValue.key("web|" + id + "|" + organization.id)
            }
        }
        if let root = values.1.flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }),
           ClaudeValue.bool(root["is_enabled"]) == true {
            result.extraUsed = ClaudeValue.number(root["used_credits"]).map { $0 / 100 }
            result.extraLimit = ClaudeValue.number(root["monthly_credit_limit"]).map { $0 / 100 }
            result.extraCurrency = ClaudeValue.text(root["currency"])?.uppercased() ?? initial.extraCurrency
        }
        if let root = values.2.flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }),
           let amount = ClaudeValue.number(root["amount"]), let currency = ClaudeValue.text(root["currency"]) {
            result.prepaidBalance = amount / 100
            result.prepaidCurrency = currency.uppercased()
        }
        result.subscription = values.3.flatMap { try? JSONSerialization.jsonObject(with: $0) }.flatMap(ClaudeSubscriptionDates.parse)
        return result
    }

    private func optionalJSON(_ path: String, cookie: String) async -> Data? {
        try? await request(path, cookie: cookie, timeout: 2, affectsBackoff: false)
    }

    private func request(_ path: String, cookie: String, timeout: TimeInterval = 20, affectsBackoff: Bool = true) async throws -> Data {
        guard let cookie = ClaudeWebCookie.normalized(cookie) else { throw ClaudeSupportError.webLoginRequired }
        let owner = ClaudeValue.key(cookie)
        if let until = blockedUntil[owner], until > Date() { throw ClaudeSupportError.rateLimited(until) }
        guard let url = URL(string: "https://claude.ai/api/" + path), url.host == "claude.ai", url.scheme == "https" else { throw ClaudeSupportError.invalidResponse }
        var request = URLRequest(url: url); request.timeoutInterval = timeout; request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(cookie, forHTTPHeaderField: "Cookie"); request.setValue("application/json", forHTTPHeaderField: "Accept")
        var (data, response) = try await transport(request)
        if path.contains("?cedar_ember=1"), [400, 404, 422].contains(response.statusCode) {
            request.url = URL(string: "https://claude.ai/api/" + path.components(separatedBy: "?")[0])
            (data, response) = try await transport(request)
        }
        guard data.count <= 1_048_576 else { throw ClaudeSupportError.invalidResponse }
        switch response.statusCode {
        case 200: return data
        case 401: throw ClaudeSupportError.webLoginRequired
        case 403:
            let text = String(decoding: data.prefix(4096), as: UTF8.self).lowercased()
            if text.contains("cloudflare") || response.value(forHTTPHeaderField: "cf-mitigated") != nil { throw ClaudeSupportError.webChallenge }
            throw ClaudeSupportError.webLoginRequired
        case 429:
            let until = ClaudeHTTPTransport.retryDate(response: response, now: Date())
            if affectsBackoff { blockedUntil[owner] = until }
            throw ClaudeSupportError.rateLimited(until)
        default: throw ClaudeSupportError.server(response.statusCode)
        }
    }
}

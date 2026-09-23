import Combine
import Foundation

struct CurrencyRateResponse: Sendable {
    let data: Data
    let statusCode: Int
}

protocol CurrencyRateFetching: Sendable {
    func fetch() async throws -> CurrencyRateResponse
}

struct DailyCurrencyRateFetcher: CurrencyRateFetching {
    func fetch() async throws -> CurrencyRateResponse {
        // A public rates-only request: no account, token history or credentials are sent.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let url = URL(string: "https://open.er-api.com/v6/latest/USD")!
        let (data, response) = try await session.data(from: url)
        return CurrencyRateResponse(data: data, statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

struct CurrencyRateSnapshot: Codable, Equatable, Sendable {
    let updatedAt: Date
    let nextUpdateAt: Date
    let rates: [String: Double]

    func isValid(at now: Date) -> Bool {
        updatedAt.timeIntervalSince1970 > 0
            && updatedAt <= now.addingTimeInterval(300)
            && nextUpdateAt > updatedAt
            && nextUpdateAt.timeIntervalSince(updatedAt) <= 172_800
            && rates["USD"] == 1 && rates.count > 1
            && rates.allSatisfy { code, rate in
                code.utf8.count == 3 && code.utf8.allSatisfy { (65...90).contains($0) }
                    && rate.isFinite && rate > 0
            }
    }

    static func decode(_ response: CurrencyRateResponse, now: Date) throws -> Self {
        struct Payload: Decodable {
            let result: String
            let base_code: String
            let time_last_update_unix: Double
            let time_next_update_unix: Double
            let rates: [String: Double]
        }
        guard response.statusCode == 200, response.data.count <= 128 * 1024 else {
            throw URLError(.badServerResponse)
        }
        let payload = try JSONDecoder().decode(Payload.self, from: response.data)
        let snapshot = Self(updatedAt: Date(timeIntervalSince1970: payload.time_last_update_unix),
                            nextUpdateAt: Date(timeIntervalSince1970: payload.time_next_update_unix), rates: payload.rates)
        guard payload.result == "success", payload.base_code == "USD", snapshot.isValid(at: now) else {
            throw URLError(.cannotParseResponse)
        }
        return snapshot
    }
}

/// Presentation only. The usage ledger and model prices always retain their original USD amounts.
@MainActor
final class CostCurrencyStore: ObservableObject {
    static let supportedCodes = ["USD", "CNY", "NZD", "EUR", "GBP", "JPY", "KRW", "CAD", "AUD",
                                 "HKD", "TWD", "SGD", "INR", "CHF", "AED", "CZK", "TRY"]
    static let preferenceKey = "costDisplayCurrency"
    private static let cacheKey = "costExchangeRates.v1"
    @Published private(set) var preferredCode: String
    @Published private(set) var snapshot: CurrencyRateSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var refreshFailed = false
    private let defaults: UserDefaults
    private let fetcher: any CurrencyRateFetching
    private let now: () -> Date
    private var lastAttemptAt: Date?

    init(defaults: UserDefaults, fetcher: any CurrencyRateFetching = DailyCurrencyRateFetcher(),
         now: @escaping () -> Date = { Date() }) {
        self.defaults = defaults
        self.fetcher = fetcher
        self.now = now
        let code = Self.normalized(defaults.string(forKey: Self.preferenceKey) ?? "USD")
        preferredCode = Self.supportedCodes.contains(code) ? code : "USD"
        if let data = defaults.data(forKey: Self.cacheKey),
           let cached = try? JSONDecoder().decode(CurrencyRateSnapshot.self, from: data), cached.isValid(at: now()) {
            snapshot = cached
        }
    }

    func select(_ code: String) {
        let code = Self.normalized(code)
        guard Self.supportedCodes.contains(code), code != preferredCode else { return }
        preferredCode = code
        defaults.set(code, forKey: Self.preferenceKey)
    }

    var isUsingStaleRates: Bool { snapshot.map { now() >= $0.nextUpdateAt } ?? false }
    var isRateUnavailable: Bool { preferredCode != "USD" && snapshot?.rates[preferredCode] == nil }
    var canRefresh: Bool {
        !isRefreshing && (lastAttemptAt.map { now().timeIntervalSince($0) >= 60 } ?? true)
    }

    // Rates belong to the app, so disappearing views must not cancel a shared request.
    func requestRefresh(force: Bool = false) {
        Task { [weak self] in await self?.refreshIfNeeded(force: force) }
    }

    func refreshIfNeeded(force: Bool = false) async {
        guard preferredCode != "USD", canRefresh else { return }
        if !force {
            if let snapshot, now() < snapshot.nextUpdateAt { return }
            if let lastAttemptAt, now().timeIntervalSince(lastAttemptAt) < 3600 { return }
        }
        lastAttemptAt = now()
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let response = try await fetcher.fetch()
            try Task.checkCancellation()
            let next = try CurrencyRateSnapshot.decode(response, now: now())
            // A stale proxy response must never roll a newer, already confirmed rate back.
            if let snapshot, next.updatedAt < snapshot.updatedAt { throw URLError(.badServerResponse) }
            snapshot = next
            defaults.set(try JSONEncoder().encode(next), forKey: Self.cacheKey)
            refreshFailed = false
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                lastAttemptAt = nil
            } else {
                refreshFailed = true
            }
        }
    }

    struct Amount: Equatable {
        let value: Double
        let code: String
    }

    func amount(usd: Double?) -> Amount? {
        guard let usd, usd.isFinite else { return nil }
        let value = usd > 0 ? usd : 0
        guard preferredCode != "USD", let rate = snapshot?.rates[preferredCode],
              (value * rate).isFinite else { return Amount(value: value, code: "USD") }
        return Amount(value: value * rate, code: preferredCode)
    }

    func format(_ usd: Double?, partial: Bool = false, locale: Locale = .current) -> String {
        guard let amount = amount(usd: usd) else { return "—" }
        return (partial ? "≥ " : "") + amount.value.formatted(
            .currency(code: amount.code).presentation(.isoCode).locale(locale))
    }

    private static func normalized(_ code: String) -> String {
        code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }
}

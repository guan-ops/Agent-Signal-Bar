import XCTest
@testable import AgentSignalLight

@MainActor
final class CostCurrencyTests: XCTestCase {
    private let day = Date(timeIntervalSince1970: 1_790_121_600)

    private func defaults() -> UserDefaults {
        let name = "CostCurrencyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func response(rates: String = "\"USD\":1,\"CNY\":7,\"NZD\":1.6,\"JPY\":150",
                          updated: Double = 1_790_121_600, status: Int = 200) -> CurrencyRateResponse {
        .init(data: Data("""
        {"result":"success","provider":"https://www.exchangerate-api.com",
        "documentation":"https://www.exchangerate-api.com/docs/free",
        "terms_of_use":"https://www.exchangerate-api.com/terms",
        "time_last_update_unix":\(updated),"time_last_update_utc":"Wed, 23 Sep 2026 00:00:00 +0000",
        "time_next_update_unix":\(updated + 86400),"time_next_update_utc":"Thu, 24 Sep 2026 00:00:00 +0000",
        "time_eol_unix":0,"base_code":"USD","rates":{\(rates)}}
        """.utf8), statusCode: status)
    }

    func testSelectionConvertsDisplayAndPersistsWithoutChangingOriginalAmount() async throws {
        let settings = defaults()
        let source = FixtureCurrencyFetcher([response()])
        let store = CostCurrencyStore(defaults: settings, fetcher: source, now: { self.day })
        store.select(" cny ")
        await store.refreshIfNeeded()
        let originalUSD = 12.5
        XCTAssertEqual(store.amount(usd: originalUSD)?.value, 87.5)
        XCTAssertEqual(store.amount(usd: originalUSD)?.code, "CNY")
        store.select("NZD")
        XCTAssertEqual(store.amount(usd: originalUSD)?.value, 20)
        store.select("USD")
        XCTAssertEqual(store.amount(usd: originalUSD)?.value, 12.5)
        store.select("NZD")
        let reopened = CostCurrencyStore(defaults: settings, fetcher: source, now: { self.day })
        XCTAssertEqual(reopened.preferredCode, "NZD")
        XCTAssertEqual(reopened.amount(usd: originalUSD)?.value, 20)
        XCTAssertEqual(reopened.snapshot?.updatedAt, day)
    }

    func testRefreshWaitsForProviderNextUpdateThenRevaluesExistingUSD() async throws {
        var now = day
        let source = FixtureCurrencyFetcher([response(), response(rates: "\"USD\":1,\"CNY\":8", updated: day.timeIntervalSince1970 + 86400)])
        let store = CostCurrencyStore(defaults: defaults(), fetcher: source, now: { now })
        store.select("CNY")
        await store.refreshIfNeeded()
        now = day.addingTimeInterval(86399)
        await store.refreshIfNeeded()
        XCTAssertEqual(store.amount(usd: 10)?.value, 70)
        let firstCount = await source.count
        XCTAssertEqual(firstCount, 1)
        now = day.addingTimeInterval(86401)
        await store.refreshIfNeeded()
        XCTAssertEqual(store.amount(usd: 10)?.value, 80)
        XCTAssertFalse(store.isUsingStaleRates)
    }

    func testOfflineRetainsDatedCacheAndThrottlesRetries() async throws {
        var now = day
        let source = FixtureCurrencyFetcher([response()])
        let settings = defaults()
        let store = CostCurrencyStore(defaults: settings, fetcher: source, now: { now })
        store.select("CNY")
        await store.refreshIfNeeded()
        now = day.addingTimeInterval(86401)
        await store.refreshIfNeeded()
        XCTAssertTrue(store.isUsingStaleRates)
        XCTAssertTrue(store.refreshFailed)
        XCTAssertEqual(store.amount(usd: 10)?.value, 70)
        XCTAssertEqual(store.snapshot?.updatedAt, day)
        await store.refreshIfNeeded()
        let count = await source.count
        XCTAssertEqual(count, 2, "An offline UI must not retry for every redraw")
        let reopened = CostCurrencyStore(defaults: settings, fetcher: source, now: { now })
        XCTAssertTrue(reopened.isUsingStaleRates)
        XCTAssertEqual(reopened.amount(usd: 10)?.value, 70)
    }

    func testMissingRateKeepsUSDLabelAndNeverInventsZeroOrRenamesDollarAmount() async {
        let source = FixtureCurrencyFetcher([response(rates: "\"USD\":1,\"EUR\":0.9")])
        let store = CostCurrencyStore(defaults: defaults(), fetcher: source, now: { self.day })
        store.select("CNY")
        XCTAssertEqual(store.amount(usd: 10)?.code, "USD")
        await store.refreshIfNeeded()
        XCTAssertEqual(store.amount(usd: 10)?.value, 10)
        XCTAssertEqual(store.amount(usd: 10)?.code, "USD")
        XCTAssertTrue(store.isRateUnavailable)
        XCTAssertNil(store.amount(usd: nil))
        XCTAssertEqual(store.amount(usd: 0)?.value, 0)
        XCTAssertEqual(store.format(nil), "—")
    }

    func testRejectsInvalidResponsesAndDoesNotReplaceValidCache() async {
        for invalid in [response(status: 429), response(rates: "\"USD\":1,\"CNY\":0"),
                        response(rates: "\"USD\":2,\"CNY\":7"), response(updated: day.timeIntervalSince1970 + 86400),
                        CurrencyRateResponse(data: Data("{\"result\":\"error\"}".utf8), statusCode: 200)] {
            var now = day
            let source = FixtureCurrencyFetcher([response(), invalid])
            let store = CostCurrencyStore(defaults: defaults(), fetcher: source, now: { now })
            store.select("CNY")
            await store.refreshIfNeeded()
            now = day.addingTimeInterval(61)
            await store.refreshIfNeeded(force: true)
            XCTAssertEqual(store.amount(usd: 10)?.value, 70)
            XCTAssertEqual(store.snapshot?.updatedAt, day)
            XCTAssertTrue(store.refreshFailed)
        }
    }

    func testFormattingRespectsCurrencyMinorUnitsAndPartialCosts() async {
        let store = CostCurrencyStore(defaults: defaults(), fetcher: FixtureCurrencyFetcher([response()]), now: { self.day })
        store.select("JPY")
        await store.refreshIfNeeded()
        let locale = Locale(identifier: "en_US")
        XCTAssertEqual(store.format(1.25, partial: true, locale: locale), "≥ JPY 188")
        store.select("CNY")
        XCTAssertEqual(store.format(1.25, locale: locale), "CNY 8.75")
        XCTAssertEqual(store.format(-0.0, locale: locale), "CNY 0.00")
        XCTAssertEqual(store.format(.nan, locale: locale), "—")
        XCTAssertEqual(store.format(.infinity, locale: locale), "—")
        XCTAssertEqual(store.format(nil, partial: true, locale: locale), "—")
    }

    func testUSDDoesNotFetchAndInvalidPreferenceFallsBackToUSD() async {
        let settings = defaults()
        settings.set("NOT-CURRENCY", forKey: CostCurrencyStore.preferenceKey)
        let source = FixtureCurrencyFetcher([])
        let store = CostCurrencyStore(defaults: settings, fetcher: source, now: { self.day })
        await store.refreshIfNeeded()
        XCTAssertEqual(store.preferredCode, "USD")
        let count = await source.count
        XCTAssertEqual(count, 0)
        store.select("bogus")
        XCTAssertEqual(store.preferredCode, "USD")
    }

    func testConcurrentRefreshIsCoalescedAndSelectionDuringFetchUsesNewCurrency() async {
        let source = SuspendedCurrencyFetcher()
        let store = CostCurrencyStore(defaults: defaults(), fetcher: source, now: { self.day })
        store.select("CNY")
        let first = Task { await store.refreshIfNeeded() }
        await source.waitUntilStarted()
        await store.refreshIfNeeded(force: true)
        store.select("NZD")
        await source.complete(response())
        await first.value
        XCTAssertEqual(store.amount(usd: 10)?.value, 16)
        XCTAssertEqual(store.amount(usd: 10)?.code, "NZD")
        let count = await source.count
        XCTAssertEqual(count, 1)
        XCTAssertFalse(store.isRefreshing)
    }

    func testURLSessionCancellationAllowsImmediateRetryForNewCurrency() async {
        let source = CancelledCurrencyFetcher(response())
        let store = CostCurrencyStore(defaults: defaults(), fetcher: source, now: { self.day })
        store.select("CNY")
        await store.refreshIfNeeded()
        XCTAssertFalse(store.refreshFailed, "URLSession cancellation is not a failed rate update")
        store.select("NZD")
        await store.refreshIfNeeded()
        XCTAssertEqual(store.amount(usd: 10)?.code, "NZD")
        XCTAssertEqual(store.amount(usd: 10)?.value, 16)
    }

    func testCancelledOwnerDoesNotPublishResponseAndAllowsRetry() async {
        let source = SuspendedCurrencyFetcher()
        let store = CostCurrencyStore(defaults: defaults(), fetcher: source, now: { self.day })
        store.select("CNY")
        let first = Task { await store.refreshIfNeeded() }
        await source.waitUntilStarted()
        first.cancel()
        store.select("NZD")
        await source.complete(response())
        await first.value
        XCTAssertNil(store.snapshot)
        XCTAssertFalse(store.refreshFailed)
        let retry = Task { await store.refreshIfNeeded() }
        await source.waitUntilStarted()
        await source.complete(response())
        await retry.value
        XCTAssertEqual(store.amount(usd: 10)?.value, 16)
    }
}

private actor CancelledCurrencyFetcher: CurrencyRateFetching {
    let response: CurrencyRateResponse
    var didCancel = false
    init(_ response: CurrencyRateResponse) { self.response = response }
    func fetch() async throws -> CurrencyRateResponse {
        if !didCancel { didCancel = true; throw URLError(.cancelled) }
        return response
    }
}

private actor FixtureCurrencyFetcher: CurrencyRateFetching {
    var responses: [CurrencyRateResponse]
    private(set) var count = 0
    init(_ responses: [CurrencyRateResponse]) { self.responses = responses }
    func fetch() async throws -> CurrencyRateResponse {
        count += 1
        guard !responses.isEmpty else { throw URLError(.notConnectedToInternet) }
        return responses.removeFirst()
    }
}

private actor SuspendedCurrencyFetcher: CurrencyRateFetching {
    private var pending: CheckedContinuation<CurrencyRateResponse, any Error>?
    private var started: CheckedContinuation<Void, Never>?
    private(set) var count = 0
    func fetch() async throws -> CurrencyRateResponse {
        count += 1
        return try await withCheckedThrowingContinuation { pending = $0; started?.resume(); started = nil }
    }
    func waitUntilStarted() async {
        if pending != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func complete(_ response: CurrencyRateResponse) { pending?.resume(returning: response); pending = nil }
}

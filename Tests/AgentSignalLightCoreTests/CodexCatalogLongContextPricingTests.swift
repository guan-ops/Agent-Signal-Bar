import CryptoKit
import Foundation
import XCTest
@testable import AgentSignalLight

final class CodexCatalogLongContextPricingTests: XCTestCase {
    func testMissingCatalogContextBlockUsesBundledRatesAboveExactBoundary() throws {
        let catalog = try makeCatalog(model: "gpt-5.5", cost: #"{"input":5,"cache_read":0.5,"output":30}"#)
        for (input, expected) in [(272_000, 1.21), (272_001, 2.27001), (300_000, 2.55)] {
            XCTAssertEqual(try cost(model: "openai/gpt-5.5-2026-09-22", input: input, catalog: catalog),
                           expected, accuracy: 0.000_000_01)
        }
    }

    func testMissingCatalogContextBlockAlsoPreservesGPT54Rates() throws {
        let catalog = try makeCatalog(model: "gpt-5.4", cost: #"{"input":2.5,"cache_read":0.25,"output":15}"#)
        XCTAssertEqual(try cost(model: "gpt-5.4", input: 300_000, catalog: catalog),
                       1.275, accuracy: 0.000_000_01)
    }

    func testContextFallbackKeepsCatalogStandardRates() throws {
        let catalog = try makeCatalog(model: "gpt-5.5", cost: #"{"input":7,"cache_read":0.7,"output":40}"#)
        XCTAssertEqual(try cost(model: "gpt-5.5", input: 272_000, catalog: catalog),
                       1.674, accuracy: 0.000_000_01)
        XCTAssertEqual(try cost(model: "gpt-5.5", input: 300_000, catalog: catalog),
                       2.55, accuracy: 0.000_000_01)
    }

    func testExplicitCatalogContextRatesKeepKnownModelThreshold() throws {
        let catalog = try makeCatalog(model: "gpt-5.5", cost: #"{"input":5,"cache_read":0.5,"output":30,"context_over_200k":{"input":12,"cache_read":1.2,"output":60}}"#)
        XCTAssertEqual(try cost(model: "gpt-5.5", input: 250_000, catalog: catalog),
                       1.10, accuracy: 0.000_000_01)
        XCTAssertEqual(try cost(model: "gpt-5.5", input: 300_000, catalog: catalog),
                       3.12, accuracy: 0.000_000_01)
    }

    func testExplicitPartialContextBlockKeepsCatalogFallbackSemantics() throws {
        for (context, expected) in [(#"{"output":60}"#, 1.65), ("{}", 1.35)] {
            let catalog = try makeCatalog(model: "gpt-5.5", cost: """
                {"input":5,"cache_read":0.5,"output":30,"context_over_200k":\(context)}
                """)
            XCTAssertEqual(try cost(model: "gpt-5.5", input: 300_000, catalog: catalog),
                           expected, accuracy: 0.000_000_01)
        }
    }

    func testUnknownModelDoesNotInheritBundledContextRates() throws {
        let catalog = try makeCatalog(model: "future-model", cost: #"{"input":2,"cache_read":0.2,"output":10}"#)
        XCTAssertEqual(try cost(model: "future-model", input: 500_000, catalog: catalog),
                       0.92, accuracy: 0.000_000_01)
    }

    func testPreviousPricingPolicyRepricesUnchangedLogBeforeRefreshInterval() throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("codex-context-pricing-\(UUID())", isDirectory: true)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = sessions.appendingPathComponent("fixture.jsonl")
        let lines = [
            #"{"timestamp":"2026-09-22T12:00:00Z","type":"session_meta","payload":{"id":"long-context-fixture"}}"#,
            #"{"timestamp":"2026-09-22T12:00:00Z","type":"turn_context","payload":{"model":"gpt-5.5"}}"#,
            #"{"timestamp":"2026-09-22T12:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":300000,"cached_input_tokens":100000,"output_tokens":10000,"total_tokens":310000},"last_token_usage":{"input_tokens":300000,"cached_input_tokens":100000,"output_tokens":10000,"total_tokens":310000}}}}"#,
        ].joined(separator: "\n") + "\n"
        try lines.write(to: log, atomically: true, encoding: .utf8)
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-22T12:30:00Z"))
        let catalog = try makeCatalog(model: "gpt-5.5", cost: #"{"input":5,"cache_read":0.5,"output":30}"#)
        ModelsDevCache.save(catalog: catalog, fetchedAt: date, cacheRoot: cacheRoot)
        var options = CostUsageScanner.Options(
            codexSessionsRoot: sessions, cacheRoot: cacheRoot,
            codexTraceDatabaseURL: root.appendingPathComponent("absent-trace.sqlite"))
        options.refreshMinIntervalSeconds = 86_400
        let first = CostUsageScanner.loadDailyReport(
            provider: .codex, since: date, until: date, now: date, options: options)
        XCTAssertEqual(try XCTUnwrap(first.summary?.totalCostUSD), 2.55, accuracy: 0.000_000_01)

        var cache = try CostUsageCacheIO.loadRequired(provider: .codex, cacheRoot: cacheRoot)
        let currentPricingKey = try XCTUnwrap(cache.codexPricingKey)
        // Simulate a cache written by the released policy 5 with the same catalog and rate table.
        let oldFingerprint = (["costPolicyVersion=5"]
            + CostUsagePricing.codexBuiltInPricingFingerprint().components(separatedBy: "\n").dropFirst())
            .joined(separator: "\n")
        let oldHash = SHA256.hash(data: Data(oldFingerprint.utf8))
            .map { String(format: "%02x", $0) }.joined()
        cache.codexPricingKey = String(currentPricingKey.dropLast(64)) + oldHash
        for path in Array(cache.files.keys) {
            cache.files[path]?.codexCostNanos = ["2026-09-22": ["gpt-5.5": 1_350_000_000]]
            cache.files[path]?.codexStandardCostNanos = ["2026-09-22": ["gpt-5.5": 1_350_000_000]]
        }
        try CostUsageCacheIO.save(provider: .codex, cache: cache, cacheRoot: cacheRoot)
        let refreshed = CostUsageScanner.loadDailyReport(
            provider: .codex, since: date, until: date, now: date.addingTimeInterval(1), options: options)
        XCTAssertEqual(try XCTUnwrap(refreshed.summary?.totalCostUSD), 2.55, accuracy: 0.000_000_01)
        XCTAssertEqual(refreshed.summary?.totalTokens, 310_000)
        XCTAssertEqual(try CostUsageCacheIO.loadRequired(provider: .codex, cacheRoot: cacheRoot).codexPricingKey,
                       currentPricingKey)
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), lines)
    }

    private func makeCatalog(model: String, cost: String) throws -> ModelsDevCatalog {
        try JSONDecoder().decode(ModelsDevCatalog.self, from: Data("""
            {"openai":{"id":"openai","models":{"\(model)":{"id":"\(model)","cost":\(cost)}}}}
            """.utf8))
    }

    private func cost(model: String, input: Int, catalog: ModelsDevCatalog) throws -> Double {
        try XCTUnwrap(CostUsagePricing.codexCostUSD(
            model: model, inputTokens: input, cachedInputTokens: 100_000,
            outputTokens: 10_000, modelsDevCatalog: catalog))
    }
}

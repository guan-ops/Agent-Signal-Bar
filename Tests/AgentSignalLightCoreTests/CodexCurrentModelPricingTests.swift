import Foundation
import SQLite3
import XCTest
@testable import AgentSignalLight

final class CodexCurrentModelPricingTests: XCTestCase {
    func testSolAndLunaStandardPricesIncludeCachedInputAndContextBoundary() throws {
        let catalog = ModelsDevCatalog(providers: [:])
        for (model, prices) in [
            ("gpt-6-sol", [0.264, 0.608, 1.166004]),
            ("gpt-6-luna", [0.0132, 0.0304, 0.0583002]),
        ] {
            for (input, expected) in zip([100_000, 272_000, 272_001], prices) {
                let cost = try XCTUnwrap(CostUsagePricing.codexCostUSD(
                    model: "openai/\(model)-2026-09-22", inputTokens: input,
                    cachedInputTokens: 20_000, outputTokens: 10_000, modelsDevCatalog: catalog))
                XCTAssertEqual(cost, expected, accuracy: 0.000_000_01, model)
            }
        }
    }

    func testSolAndLunaFastPricesIncludeLongContext() throws {
        for (model, prices) in [
            ("gpt-6-sol", [0.528, 1.216, 2.332008]),
            ("gpt-6-luna", [0.0264, 0.0608, 0.1166004]),
        ] {
            for (input, expected) in zip([100_000, 272_000, 272_001], prices) {
                let cost = try XCTUnwrap(CostUsagePricing.codexPriorityCostUSD(
                    model: model, inputTokens: input, cachedInputTokens: 20_000, outputTokens: 10_000))
                XCTAssertEqual(cost, expected, accuracy: 0.000_000_01, model)
            }
        }
    }

    func testVerifiedPricesOverrideStaleCatalogWithoutLosingLongContextRates() throws {
        for (model, expected) in [
            ("gpt-6-astra", 5.83002), ("gpt-6-sol", 1.166004), ("gpt-6-luna", 0.0583002),
            ("gpt-5.6-sol", 2.332008), ("gpt-5.6-terra", 1.196004), ("gpt-5.6-luna", 0.1196004),
        ] {
            let catalog = try JSONDecoder().decode(ModelsDevCatalog.self, from: Data("""
                {"openai":{"id":"openai","models":{"\(model)":{
                  "id":"\(model)","cost":{"input":99,"cache_read":9,"output":999}
                }}}}
                """.utf8))
            let cost = try XCTUnwrap(CostUsagePricing.codexCostUSD(
                model: "openai/\(model)-2026-09-22", inputTokens: 272_001,
                cachedInputTokens: 20_000, outputTokens: 10_000, modelsDevCatalog: catalog))
            XCTAssertEqual(cost, expected, accuracy: 0.000_000_01, model)
        }
    }

    func testNewModelsScanAndRepriceUnchangedHistoricalFilesPerRequest() throws {
        try checkHistoricalRepricing(previousPricingKey: "old-prices-without-gpt-6-sol-and-luna")
    }

    func testHistoricalCacheWithoutPricingKeyIsAlsoRepriced() throws {
        try checkHistoricalRepricing(previousPricingKey: nil)
    }

    func testProductionScanSeparatesStandardAndFastForBothNewModels() throws {
        try checkHistoricalRepricing(previousPricingKey: "old-prices", serviceTier: "fast")
    }

    func testProductionScanAcceptsPriorityAliasForFast() throws {
        try checkHistoricalRepricing(previousPricingKey: "old-prices", serviceTier: "priority")
    }

    private func checkHistoricalRepricing(previousPricingKey: String?, serviceTier: String? = nil) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("model-pricing-\(UUID())")
        let sessions = root.appendingPathComponent("sessions")
        let cacheRoot = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for model in ["gpt-6-sol", "gpt-6-luna"] {
            var lines = [
                #"{"timestamp":"2026-09-22T10:00:00Z","type":"session_meta","payload":{"id":"fixture-\#(model)"}}"#,
            ]
            // Daily input exceeds 272K, but every request remains at the standard rate.
            for index in 1...3 {
                lines.append(#"{"timestamp":"2026-09-22T10:0\#(index):00Z","type":"event_msg","payload":{"type":"task_started","turn_id":"\#(model)-turn-\#(index)"}}"#)
                lines.append(#"{"timestamp":"2026-09-22T10:0\#(index):00Z","type":"turn_context","payload":{"model":"openai/\#(model)-2026-09-22","turn_id":"\#(model)-turn-\#(index)"}}"#)
                lines.append(#"{"timestamp":"2026-09-22T10:0\#(index):00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(100000 * index),"cached_input_tokens":\#(20000 * index),"output_tokens":\#(10000 * index),"total_tokens":\#(110000 * index)},"last_token_usage":{"input_tokens":100000,"cached_input_tokens":20000,"output_tokens":10000,"total_tokens":110000}}}}"#)
            }
            try (lines.joined(separator: "\n") + "\n").write(
                to: sessions.appendingPathComponent("\(model).jsonl"), atomically: true, encoding: .utf8)
        }
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-22T10:30:00Z"))
        let traceURL = root.appendingPathComponent("trace.sqlite")
        if let serviceTier { try createFastTrace(at: traceURL, date: date, serviceTier: serviceTier) }
        var options = CostUsageScanner.Options(
            codexSessionsRoot: sessions, cacheRoot: cacheRoot,
            codexTraceDatabaseURL: traceURL)
        options.refreshMinIntervalSeconds = 86_400
        let first = CostUsageScanner.loadDailyReport(
            provider: .codex, since: date, until: date, now: date, options: options)
        let requestRateCount = serviceTier == nil ? 3.0 : 4.0
        XCTAssertEqual(try XCTUnwrap(first.summary?.totalCostUSD), 0.2772 * requestRateCount, accuracy: 0.000_001)
        XCTAssertEqual(Set(first.data.flatMap { $0.modelBreakdowns ?? [] }.map(\.modelName)),
                       Set(["gpt-6-sol", "gpt-6-luna"]))

        var cache = try CostUsageCacheIO.loadRequired(provider: .codex, cacheRoot: cacheRoot)
        cache.codexPricingKey = previousPricingKey
        for path in Array(cache.files.keys) {
            var usage = try XCTUnwrap(cache.files[path])
            usage.codexCostNanos = usage.codexCostNanos?.mapValues { $0.mapValues { _ in 1 } }
            usage.codexStandardCostNanos = usage.codexCostNanos
            cache.files[path] = usage
        }
        try CostUsageCacheIO.save(provider: .codex, cache: cache, cacheRoot: cacheRoot)
        let refreshed = CostUsageScanner.loadDailyReport(
            provider: .codex, since: date, until: date, now: date.addingTimeInterval(1), options: options)
        XCTAssertEqual(try XCTUnwrap(refreshed.summary?.totalCostUSD), 0.2772 * requestRateCount, accuracy: 0.000_001)
        let breakdowns = refreshed.data.flatMap { $0.modelBreakdowns ?? [] }
        XCTAssertEqual(try XCTUnwrap(breakdowns.first { $0.modelName == "gpt-6-sol" }?.costUSD),
                       0.264 * requestRateCount, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(breakdowns.first { $0.modelName == "gpt-6-luna" }?.costUSD),
                       0.0132 * requestRateCount, accuracy: 0.000_001)
        if serviceTier != nil {
            for breakdown in breakdowns {
                XCTAssertEqual(breakdown.standardTokens, 220_000)
                XCTAssertEqual(breakdown.priorityTokens, 110_000)
            }
        }
    }

    private func createFastTrace(at url: URL, date: Date, serviceTier: String) throws {
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &connection), SQLITE_OK)
        let database = try XCTUnwrap(connection)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database,
            "CREATE TABLE logs (id INTEGER PRIMARY KEY, ts INTEGER, ts_nanos INTEGER DEFAULT 0, feedback_log_body TEXT)",
            nil, nil, nil), SQLITE_OK)
        for model in ["gpt-6-sol", "gpt-6-luna"] {
            let body = #"session_loop:turn{turn.id=\#(model)-turn-2 model=\#(model)}:run_sampling_request websocket request:{"type":"response.create","service_tier":"\#(serviceTier)","model":"\#(model)","turn_id":"\#(model)-turn-2"}"#
            var statement: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(database,
                "INSERT INTO logs (ts, feedback_log_body) VALUES (?, ?)", -1, &statement, nil), SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, Int64(date.addingTimeInterval(-1800).timeIntervalSince1970))
            sqlite3_bind_text(statement, 2, body, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        }
    }
}

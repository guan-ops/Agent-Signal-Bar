import Foundation
import SQLite3
import XCTest
@testable import AgentSignalLight

final class CodexUnknownFastCostTests: XCTestCase {
    private var date: Date { ISO8601DateFormatter().date(from: "2026-09-22T12:00:00Z")! }
    private var day: String { CostUsageScanner.CostUsageDayRange.dayKey(from: date) }
    private let catalog = ModelsDevCatalog(providers: [:])
    private var priorityTurns: [String: CostUsageScanner.CodexPriorityTurnMetadata] {
        ["unknown-fast": .init(turnID: "unknown-fast", model: "gpt-5.5"),
         "known-fast": .init(turnID: "known-fast", model: "gpt-5.5")]
    }
    private var unknownFast: CostUsageScanner.CodexUsageRow {
        .init(day: day, model: "gpt-5.5", turnID: "unknown-fast", input: 300_000, cached: 0, output: 1_000)
    }
    private var standard: CostUsageScanner.CodexUsageRow {
        .init(day: day, model: "gpt-5.5", turnID: "standard", input: 1_000, cached: 0, output: 1_000)
    }
    private var knownFast: CostUsageScanner.CodexUsageRow {
        .init(day: day, model: "gpt-5.5", turnID: "known-fast", input: 1_000, cached: 0, output: 1_000)
    }
    private var range: CostUsageScanner.CostUsageDayRange {
        return .init(since: date, until: date)
    }

    func testUnpricedLongContextFastRowDoesNotUseStandardRate() {
        let result = CostUsageScanner.codexRowCostBreakdown(rows: [unknownFast],
            priorityTurns: priorityTurns, modelsDevCatalog: catalog, modelsDevCacheRoot: nil)
        XCTAssertNil(result.totalCostUSD)
        XCTAssertNil(result.optionalPriorityCostUSD)
        XCTAssertNil(result.optionalStandardCostUSD)
        XCTAssertEqual(result.priorityTokens, 301_000)
    }

    func testUnknownFastRowPreservesOtherConfirmedCosts() throws {
        let result = CostUsageScanner.codexRowCostBreakdown(rows: [standard, unknownFast, knownFast],
            priorityTurns: priorityTurns, modelsDevCatalog: catalog, modelsDevCacheRoot: nil)
        XCTAssertEqual(try XCTUnwrap(result.optionalStandardCostUSD), 0.035, accuracy: 0.000_000_001)
        XCTAssertEqual(try XCTUnwrap(result.optionalPriorityCostUSD), 0.0875, accuracy: 0.000_000_001)
        XCTAssertEqual(try XCTUnwrap(result.totalCostUSD), 0.1225, accuracy: 0.000_000_001)
        XCTAssertEqual(result.priorityTokens, 303_000)
        XCTAssertEqual(result.standardTokens, 2_000)
    }

    func testModeCacheLeavesUnknownFastCostAbsent() {
        let maps = CostUsageScanner.codexModeSplitMaps(rows: [unknownFast], range: range,
            priorityTurns: priorityTurns, modelsDevCatalog: catalog, modelsDevCacheRoot: nil)
        XCTAssertNil(maps.priorityCostNanos)
        XCTAssertNil(maps.standardCostNanos)
        XCTAssertEqual(maps.priorityTokens?[day]?["gpt-5.5"], 301_000)
    }

    func testCachedReportDoesNotFallbackToBaseCostForUnknownFastUsage() throws {
        let report = makeReport(rows: [unknownFast])
        let model = try XCTUnwrap(report.data.first?.modelBreakdowns?.first)
        XCTAssertNil(model.costUSD)
        XCTAssertNil(model.priorityCostUSD)
        XCTAssertEqual(model.priorityTokens, 301_000)
        XCTAssertNil(report.summary?.totalCostUSD)
        XCTAssertEqual(report.summary?.totalTokens, 301_000)
    }

    func testCachedReportPreservesStandardCostBesideUnknownFastUsage() throws {
        let report = makeReport(rows: [standard, unknownFast])
        let model = try XCTUnwrap(report.data.first?.modelBreakdowns?.first)
        XCTAssertNil(model.priorityCostUSD)
        XCTAssertEqual(try XCTUnwrap(model.standardCostUSD), 0.035, accuracy: 0.000_000_001)
        XCTAssertEqual(try XCTUnwrap(report.summary?.totalCostUSD), 0.035, accuracy: 0.000_000_001)
        XCTAssertEqual(report.summary?.totalTokens, 303_000)
    }

    func testMixedKnownAndUnknownFastRequestsPreservePartialCostSignal() throws {
        let report = makeReport(rows: [knownFast, unknownFast])
        let model = try XCTUnwrap(report.data.first?.modelBreakdowns?.first)
        XCTAssertEqual(try XCTUnwrap(model.costUSD), 0.0875, accuracy: 0.000_000_001)
        XCTAssertEqual(model.totalTokens, 303_000)
        XCTAssertTrue(model.hasUnpricedUsage)
    }

    func testFullyPricedModesAreNotMarkedPartial() throws {
        let report = makeReport(rows: [standard, knownFast])
        let model = try XCTUnwrap(report.data.first?.modelBreakdowns?.first)
        XCTAssertEqual(try XCTUnwrap(model.costUSD), 0.1225, accuracy: 0.000_000_001)
        XCTAssertFalse(model.hasUnpricedUsage)
    }

    func testPricingPolicyChangeRebuildsPreviouslyMispricedUnchangedLog() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("unknown-fast-\(UUID())")
        let sessions = root.appendingPathComponent("sessions")
        let cacheRoot = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = sessions.appendingPathComponent("fixture.jsonl")
        let lines = [
            #"{"timestamp":"2026-09-22T12:00:00Z","type":"session_meta","payload":{"id":"fixture"}}"#,
            #"{"timestamp":"2026-09-22T12:00:00Z","type":"event_msg","payload":{"type":"task_started","turn_id":"unknown-fast"}}"#,
            #"{"timestamp":"2026-09-22T12:00:00Z","type":"turn_context","payload":{"model":"gpt-5.5","turn_id":"unknown-fast"}}"#,
            #"{"timestamp":"2026-09-22T12:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":300000,"cached_input_tokens":0,"output_tokens":1000,"total_tokens":301000},"last_token_usage":{"input_tokens":300000,"cached_input_tokens":0,"output_tokens":1000,"total_tokens":301000}}}}"#,
        ].joined(separator: "\n") + "\n"
        try lines.write(to: log, atomically: true, encoding: .utf8)
        let trace = root.appendingPathComponent("trace.sqlite")
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(trace.path, &connection), SQLITE_OK)
        let database = try XCTUnwrap(connection)
        defer { sqlite3_close(database) }
        let request = #"session_loop:turn{turn.id=unknown-fast model=gpt-5.5}:run_sampling_request websocket request:{"type":"response.create","service_tier":"fast","model":"gpt-5.5","turn_id":"unknown-fast"}"#
        XCTAssertEqual(sqlite3_exec(database,
            "CREATE TABLE logs (id INTEGER PRIMARY KEY, ts INTEGER, ts_nanos INTEGER DEFAULT 0, feedback_log_body TEXT); "
                + "INSERT INTO logs (ts, feedback_log_body) VALUES (\(Int(date.timeIntervalSince1970)), '\(request)')",
            nil, nil, nil), SQLITE_OK)
        var options = CostUsageScanner.Options(codexSessionsRoot: sessions, cacheRoot: cacheRoot,
            codexTraceDatabaseURL: trace)
        options.refreshMinIntervalSeconds = 86_400
        let first = CostUsageScanner.loadDailyReport(provider: .codex, since: date, until: date,
            now: date, options: options)
        XCTAssertEqual(first.summary?.totalTokens, 301_000)
        XCTAssertNil(first.summary?.totalCostUSD)
        var cache = try CostUsageCacheIO.loadRequired(provider: .codex, cacheRoot: cacheRoot)
        XCTAssertEqual(cache.files.count, 1)
        XCTAssertEqual(cache.files.values.first?.codexUnpricedTokens?[day]?["gpt-5.5"], 301_000)
        let details = CodexUsageDetails.build(cache: cache, now: date, modelsDevCatalog: catalog) { _, _ in nil }
        XCTAssertEqual(details.sessions.first?.hasUnpricedUsage, true)
        let currentPricingKey = try XCTUnwrap(cache.codexPricingKey)
        cache.codexPricingKey = "before-unknown-fast-cost-policy"
        for path in Array(cache.files.keys) {
            cache.files[path]?.codexPriorityCostNanos = [day: ["gpt-5.5": 3_045_000_000]]
        }
        try CostUsageCacheIO.save(provider: .codex, cache: cache, cacheRoot: cacheRoot)
        let refreshed = CostUsageScanner.loadDailyReport(provider: .codex, since: date, until: date,
            now: date.addingTimeInterval(1), options: options)
        XCTAssertNil(refreshed.summary?.totalCostUSD)
        XCTAssertEqual(refreshed.summary?.totalTokens, 301_000)
        XCTAssertEqual(try CostUsageCacheIO.loadRequired(provider: .codex, cacheRoot: cacheRoot).codexPricingKey,
                       currentPricingKey)
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), lines)
    }

    private func makeReport(rows: [CostUsageScanner.CodexUsageRow]) -> CostUsageDailyReport {
        let maps = CostUsageScanner.codexModeSplitMaps(rows: rows, range: range,
            priorityTurns: priorityTurns, modelsDevCatalog: catalog, modelsDevCacheRoot: nil)
        let packed = rows.reduce(into: [0, 0, 0]) { result, row in
            result[0] += row.input; result[1] += row.cached; result[2] += row.output
        }
        let days = [day: ["gpt-5.5": packed]]
        let usage = CostUsageFileUsage(mtimeUnixMs: 0, size: 0, days: days,
            codexCostNanos: CostUsageScanner.codexCostNanos(rows: rows, range: range,
                modelsDevCatalog: catalog, modelsDevCacheRoot: nil),
            codexStandardCostNanos: maps.standardCostNanos,
            codexPriorityCostNanos: maps.priorityCostNanos,
            codexStandardTokens: maps.standardTokens, codexPriorityTokens: maps.priorityTokens,
            codexUnpricedTokens: maps.unpricedTokens)
        var cache = CostUsageCache()
        cache.days = days
        cache.files = ["fixture": usage]
        return CostUsageScanner.buildCodexReportFromCache(cache: cache, range: range, modelsDevCatalog: catalog)
    }
}

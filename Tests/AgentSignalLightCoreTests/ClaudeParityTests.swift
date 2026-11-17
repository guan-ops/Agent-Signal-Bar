import Foundation
import XCTest
@testable import AgentSignalLight

final class ClaudeParityTests: XCTestCase {
    func testHistoryAcceptsJSONWhitespaceAndRebuildsLegacyEmptyCache() throws {
        let root = URL(fileURLWithPath: "/private/tmp/claude-whitespace-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let projects = root.appendingPathComponent("projects")
        let cacheRoot = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let now = Date()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: now)
        let rows = [":", ": ", " \t: \t"].enumerated().map { index, separator in
            """
            {"type"\(separator)"assistant","timestamp":"\(timestamp)","sessionId":"fixture","requestId":"r\(index)","message":{"id":"m\(index)","model":"claude-sonnet-4-6","usage":{"input_tokens":100,"output_tokens":20}}}
            """
        }
        let nonAssistant = rows[0].replacingOccurrences(of: "\"type\":\"assistant\"", with: "\"type\":\"user\"")
        try (rows.joined(separator: "\n") + "\n" + nonAssistant + "\n").write(
            to: projects.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
        let oldCache = cacheRoot.appendingPathComponent("cost-usage/claude-v4.json")
        try FileManager.default.createDirectory(at: oldCache.deletingLastPathComponent(), withIntermediateDirectories: true)
        let legacyData = try JSONEncoder().encode(CostUsageCache())
        try legacyData.write(to: oldCache)
        XCTAssertNotEqual(CostUsageCacheIO.cacheFileURL(provider: .claude, cacheRoot: cacheRoot), oldCache)
        for _ in 0..<2 {
            let report = try ClaudeSupportModel.scanHistory(roots: [projects], cacheRoot: cacheRoot, now: now)
            XCTAssertEqual(report.summary?.totalTokens, 360)
        }
        XCTAssertEqual(try Data(contentsOf: oldCache), legacyData)
    }

    func testInformationalRuntimeRecordsDoNotMakeAReadyHookLookBroken() throws {
        let summary = try XCTUnwrap(HookConnectionSummary.parse("""
        [dry-run] Claude Code: already configured
          file: /fixture/settings.json
        [info] Claude Code CLI: /fixture/.local/bin/claude
        [info] Claude Desktop: running
          note: presence alone is not a hook event
        """))
        XCTAssertTrue(summary.isReady)
        XCTAssertEqual(summary.items.count, 1)
        XCTAssertEqual(summary.items.first?.name, "Claude Code")
        XCTAssertTrue(summary.diagnostics.isEmpty)
    }

    private func entry(_ date: String, tokens: Int = 10, cost: Double? = 1,
                       breakdowns: [CostUsageDailyReport.ModelBreakdown]? = nil) -> CostUsageDailyReport.Entry {
        .init(date: date, inputTokens: tokens, outputTokens: 0, totalTokens: tokens,
              costUSD: cost, modelsUsed: nil, modelBreakdowns: breakdowns)
    }

    func testThirtyCalendarDaysAcrossDSTAndScopeBoundaries() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Pacific/Auckland")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 12))!
        let summary = ClaudeHistorySummary(days: [entry("2026-09-01", tokens: 999), entry("2026-09-02"),
            entry("2026-10-01", tokens: 20), entry("2026-10-02", tokens: 888)], updatedAt: now, now: now, calendar: calendar)
        XCTAssertEqual(summary.chartDays.count, 30)
        XCTAssertEqual(summary.month.tokens, 30)
        XCTAssertEqual(summary.today.tokens, 20)
        XCTAssertEqual(summary.entries.map(\.date), ["2026-09-02", "2026-10-01"])
        XCTAssertEqual(summary.chartDays.reduce(0) { $0 + $1.totalTokens }, 30)
        XCTAssertEqual(summary.chartDays.first?.day, calendar.date(from: DateComponents(year: 2026, month: 9, day: 2)))
    }

    func testUnscannedUnknownPartialAndScannedEmptyAreDistinct() {
        let now = Date()
        let key = CostUsageLocalDay.key(from: now)
        let unscanned = ClaudeHistorySummary(days: [], updatedAt: nil, now: now)
        XCTAssertNil(unscanned.today.tokens)
        XCTAssertNil(unscanned.month.costUSD)
        let empty = ClaudeHistorySummary(days: [], updatedAt: now, now: now)
        XCTAssertEqual(empty.today.tokens, 0)
        XCTAssertEqual(empty.month.costUSD, 0)
        let partial = ClaudeHistorySummary(days: [entry(key, tokens: 30, cost: 2, breakdowns: [
            .init(modelName: "known", costUSD: 2, totalTokens: 10),
            .init(modelName: "unknown", costUSD: nil, totalTokens: 20)
        ])], updatedAt: now, now: now)
        XCTAssertEqual(partial.month.costUSD, 2)
        XCTAssertTrue(partial.month.hasUnpricedUsage)
        XCTAssertEqual(partial.chartDays.last?.modelTokenTotals, ["known": 10, "unknown": 20])
        let unknown = ClaudeHistorySummary(days: [entry(key, cost: nil)], updatedAt: now, now: now)
        XCTAssertNil(unknown.month.costUSD)
        XCTAssertTrue(unknown.today.hasUnpricedUsage)
    }

    func testRootDiscoveryFindsDesktopAndSwapAndKeepsCustomProfileLiteral() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("claude-roots-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let desktop = home.appendingPathComponent("Library/Application Support/Claude/local-agent-mode-sessions/org/session/.claude/projects")
        let swap = home.appendingPathComponent(".claude-swap-backup/sessions/1-fixture/projects")
        for url in [desktop, swap] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        let roots = ClaudeHistoryRoots.projects(environment: [:], home: home)
        XCTAssertTrue(roots.contains { $0.path == desktop.path })
        XCTAssertTrue(roots.contains { $0.path == swap.path })
        let profile = home.appendingPathComponent("profile, with spaces")
        XCTAssertEqual(ClaudeHistoryRoots.projects(environment: ["CLAUDE_CONFIG_DIR": profile.path], home: home).map(\.path),
                       [profile.appendingPathComponent("projects").path])
        // A Desktop symlink must not escape into another directory tree.
        let outside = home.appendingPathComponent("outside/.claude/projects")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let link = home.appendingPathComponent("Library/Application Support/Claude/local-agent-mode-sessions/linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: home.appendingPathComponent("outside"))
        XCTAssertFalse(ClaudeHistoryRoots.projects(environment: [:], home: home).contains { $0.path.contains("linked") })
    }

    func testDetailsReconcileDuplicateRequestsAndSeparateCacheTokens() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("claude-details-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let projects = root.appendingPathComponent("projects")
        let parent = projects.appendingPathComponent("fixture")
        let subagent = parent.appendingPathComponent("subagents")
        try FileManager.default.createDirectory(at: subagent, withIntermediateDirectories: true)
        let now = Date()
        let timestamp = ISO8601DateFormatter().string(from: now)
        let record = "{\"type\":\"assistant\",\"timestamp\":\"\(timestamp)\",\"cwd\":\"/fixture/project\",\"sessionId\":\"fixture-session\",\"requestId\":\"r1\",\"message\":{\"id\":\"m1\",\"model\":\"claude-sonnet-4-5-20250929\",\"usage\":{\"input_tokens\":100,\"cache_read_input_tokens\":200,\"cache_creation_input_tokens\":300,\"output_tokens\":50}}}\n"
        try record.write(to: parent.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
        try record.write(to: subagent.appendingPathComponent("copy.jsonl"), atomically: true, encoding: .utf8)
        let cacheRoot = root.appendingPathComponent("cache")
        let report = try ClaudeSupportModel.scanHistory(roots: [projects], cacheRoot: cacheRoot, now: now)
        let cache = try CostUsageCacheIO.loadRequired(provider: .claude, cacheRoot: cacheRoot)
        let details = try CostUsageScanner.buildClaudeUsageDetails(cache: cache, now: now, modelsDevCacheRoot: cacheRoot)
        XCTAssertEqual(details.sessions.count, 1)
        let session = try XCTUnwrap(details.sessions.first)
        XCTAssertEqual(session.totalTokens, report.summary?.totalTokens)
        XCTAssertEqual(session.totalTokens, 650)
        XCTAssertEqual(session.inputTokens, 100)
        XCTAssertEqual(session.cachedTokens, 200)
        XCTAssertEqual(session.cacheCreationTokens, 300)
        XCTAssertEqual(session.outputTokens, 50)
        XCTAssertEqual(session.projectPath, "/fixture/project")
        XCTAssertEqual(session.costUSD, report.summary?.totalCostUSD)
        XCTAssertEqual(details.projects.first?.sessionCount, 1)
        XCTAssertThrowsError(try CostUsageScanner.buildClaudeUsageDetails(cache: cache, now: now,
            modelsDevCacheRoot: cacheRoot, checkCancellation: { throw CancellationError() })) {
                XCTAssertTrue($0 is CancellationError)
            }
    }

    @MainActor
    func testHistoryCompletesWhileNetworkQuotaIsStillWaiting() async throws {
        let suite = "claude-independent-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "claude.credentialConsent")
        let gate = AsyncStream<Void>.makeStream()
        defer { gate.continuation.finish() }
        let networkStarted = expectation(description: "network started")
        let service = ClaudeUsageService { request in
            if request.url?.lastPathComponent == "usage" {
                networkStarted.fulfill()
                for await _ in gate.stream { break }
            }
            return (Data(#"{"five_hour":{"utilization":20}}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let model = ClaudeSupportModel(defaults: defaults, service: service,
            readCredentials: { _ in .init(accessToken: "fixture", expiresAt: nil, plan: "pro") },
            historyLoader: { _ in .init(data: [], summary: nil) })
        model.refresh(force: true)
        await fulfillment(of: [networkStarted], timeout: 2)
        for _ in 0..<100 where model.historyUpdatedAt == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(model.historyUpdatedAt)
        XCTAssertFalse(model.isHistoryScanning)
        XCTAssertTrue(model.isRefreshing)
        XCTAssertNil(model.snapshot)
        gate.continuation.finish()
        for _ in 0..<100 where model.isRefreshing { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(model.snapshot)
        XCTAssertFalse(model.isRefreshing)
    }
}

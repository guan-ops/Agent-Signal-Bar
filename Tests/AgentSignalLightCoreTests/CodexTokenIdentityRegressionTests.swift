import Foundation
import XCTest
@testable import AgentSignalLight

final class CodexTokenIdentityRegressionTests: XCTestCase {
    func testChildRolloutsUseOwnIDInsteadOfSharedRootSessionID() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.write("parent", id: "parent", sharedSessionID: "parent", tokens: 100)
        _ = try fixture.write("child-a", id: "child-a", sharedSessionID: "parent", tokens: 25)
        _ = try fixture.write("child-b", id: "child-b", sharedSessionID: "parent", tokens: 50)

        let report = try fixture.scan()
        XCTAssertEqual(report.summary?.totalTokens, 175)
        XCTAssertTrue(report.warnings.isEmpty)
        let cache = try fixture.cache()
        XCTAssertEqual(Set(cache.files.values.compactMap(\.sessionId)), ["parent", "child-a", "child-b"])
    }

    func testFoundationFallbackAlsoPrefersOwnID() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.write("root", id: "root", sharedSessionID: "root", tokens: 100)
        _ = try fixture.write(
            "child", id: "child", sharedSessionID: "root", tokens: 25,
            escapedTypeKey: true
        )

        let report = try fixture.scan()
        XCTAssertEqual(report.summary?.totalTokens, 125)
        XCTAssertTrue(report.warnings.isEmpty)
        XCTAssertEqual(Set(try fixture.cache().files.values.compactMap(\.sessionId)), ["root", "child"])
    }

    func testLegacySessionIDRemainsSupportedWhenOwnIDIsAbsent() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.write("legacy", id: nil, sharedSessionID: "legacy", tokens: 40)
        let report = try fixture.scan()
        XCTAssertEqual(report.summary?.totalTokens, 40)
        XCTAssertEqual(try fixture.cache().files.values.first?.sessionId, "legacy")
    }

    func testFastAndFallbackIdentifiersAreTrimmedConsistently() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.write("fast", id: "  fast\n", sharedSessionID: "root", tokens: 20)
        _ = try fixture.write("fallback", id: "  fallback\n", sharedSessionID: "root", tokens: 30, escapedTypeKey: true)
        _ = try fixture.write("empty", id: " \n", sharedSessionID: " legacy ", tokens: 40)
        XCTAssertEqual(try fixture.scan().summary?.totalTokens, 90)
        XCTAssertEqual(Set(try fixture.cache().files.values.compactMap(\.sessionId)), ["fast", "fallback", "legacy"])
    }

    func testUnicodeEscapedOwnIDDoesNotFallBackToParentAlias() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.write("parent", id: "parent", tokens: 100)
        let child = try fixture.write("child", id: "child", sharedSessionID: "parent", tokens: 25)
        let source = try String(contentsOf: child, encoding: .utf8)
        try source.replacingOccurrences(of: "\"child\"", with: "\"chi\\u006cd\"")
            .write(to: child, atomically: true, encoding: .utf8)
        let report = try fixture.scan()
        XCTAssertEqual(report.summary?.totalTokens, 125)
        XCTAssertTrue(report.warnings.isEmpty)
        XCTAssertEqual(Set(try fixture.cache().files.values.compactMap(\.sessionId)), ["parent", "child"])
    }

    func testUnicodeEscapedIDKeyHasTheSamePriorityAsPlainID() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.write("parent", id: "parent", tokens: 100)
        let child = try fixture.write("child", id: "child", sharedSessionID: "parent", tokens: 25)
        let source = try String(contentsOf: child, encoding: .utf8)
        try source.replacingOccurrences(of: "\"id\"", with: "\"i\\u0064\"")
            .write(to: child, atomically: true, encoding: .utf8)
        let report = try fixture.scan()
        XCTAssertEqual(report.summary?.totalTokens, 125)
        XCTAssertTrue(report.warnings.isEmpty)
    }

    func testColdDivergentGroupDoesNotDiscardIndependentUsage() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try fixture.write("conflict-a", id: "conflict", tokens: 200)
        let second = try fixture.write("conflict-b", id: "conflict", tokens: 300)
        _ = try fixture.write("healthy", id: "healthy", tokens: 100)

        for _ in 0..<2 {
            let report = try fixture.scan()
            XCTAssertEqual(report.summary?.totalTokens, 100)
            let normalizedWarnings = report.warnings.map { warning in
                CostUsageScanWarning(
                    reason: warning.reason,
                    sessionID: warning.sessionID,
                    sourcePaths: warning.sourcePaths.map {
                        URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path
                    }
                )
            }
            XCTAssertEqual(normalizedWarnings, [CostUsageScanWarning(
                reason: .ambiguousSessionIdentity,
                sessionID: "conflict",
                sourcePaths: [first.path, second.path]
            )])
            let cache = try fixture.cache()
            let conflicts = cache.files.values.filter { $0.sessionId == "conflict" }
            XCTAssertEqual(conflicts.count, 2)
            XCTAssertTrue(conflicts.allSatisfy { $0.codexInventoryOnly == true && $0.codexIdentityConflict == true })
            XCTAssertTrue(conflicts.allSatisfy { $0.days.isEmpty && $0.lastTokenEventEndOffset == nil })
            XCTAssertEqual(cache.codexScanWarnings, report.warnings)
        }
    }

    func testIdentityRepairRechecksConflictAndClearsWarning() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.write("conflict-a", id: "conflict", tokens: 200)
        _ = try fixture.write("conflict-b", id: "conflict", tokens: 300)
        _ = try fixture.write("healthy", id: "healthy", tokens: 100)
        XCTAssertEqual(try fixture.scan().summary?.totalTokens, 100)

        _ = try fixture.write("conflict-b", id: "repaired", tokens: 300)
        let report = try fixture.scan()
        XCTAssertEqual(report.summary?.totalTokens, 600)
        XCTAssertTrue(report.warnings.isEmpty)
        XCTAssertFalse(try fixture.cache().files.values.contains { $0.codexIdentityConflict == true })
    }

    func testRemovingConflictingCopyPromotesRemainingSource() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.write("conflict-a", id: "conflict", tokens: 200)
        let removed = try fixture.write("conflict-b", id: "conflict", tokens: 300)
        _ = try fixture.write("healthy", id: "healthy", tokens: 100)
        XCTAssertEqual(try fixture.scan().summary?.totalTokens, 100)

        try FileManager.default.removeItem(at: removed)
        let report = try fixture.scan()
        XCTAssertEqual(report.summary?.totalTokens, 300)
        XCTAssertTrue(report.warnings.isEmpty)
    }

    func testChangedButStillDivergentGroupRemainsExplicitlyPartial() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.write("conflict-a", id: "conflict", tokens: 200)
        _ = try fixture.write("conflict-b", id: "conflict", tokens: 300)
        _ = try fixture.write("healthy", id: "healthy", tokens: 100)
        XCTAssertEqual(try fixture.scan().summary?.totalTokens, 100)

        _ = try fixture.write("conflict-a", id: "conflict", tokens: 250)
        let report = try fixture.scan()
        XCTAssertEqual(report.summary?.totalTokens, 100)
        XCTAssertEqual(report.warnings.count, 1)
    }

    func testRepairedPrefixGroupClearsUnchangedSentinelConflictAndExportsAlias() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try fixture.write("conflict-a", id: "conflict", tokens: 200)
        let second = try fixture.write("conflict-b", id: "conflict", tokens: 300)
        _ = try fixture.write("healthy", id: "healthy", tokens: 100)
        XCTAssertEqual(try fixture.scan().summary?.totalTokens, 100)

        let extensionLine = #"{"timestamp":"2026-09-02T08:30:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":250,"output_tokens":0},"last_token_usage":{"input_tokens":50,"output_tokens":0}}}}"#
        var repaired = try Data(contentsOf: first)
        repaired.append(Data("\(extensionLine)\n".utf8))
        try repaired.write(to: second)

        let report = try fixture.scan()
        XCTAssertEqual(report.summary?.totalTokens, 350)
        XCTAssertTrue(report.warnings.isEmpty)
        let cache = try fixture.cache()
        XCTAssertFalse(cache.files.values.contains { $0.codexIdentityConflict == true })
        let retainedAlias = cache.files.first {
            URL(fileURLWithPath: $0.key).standardizedFileURL.resolvingSymlinksInPath().path == first.path
        }?.value
        XCTAssertEqual(retainedAlias?.codexInventoryOnly, true)
        let scanner = CodexTokenActivityScanner(
            sessionRootURLs: [fixture.sessions], costUsageCacheRootURL: fixture.cacheRoot,
            usesAgentSignalCostUsageScanner: true
        )
        let watermarks = try scanner.agentSignalCostUsageScanWatermarks(through: fixture.now)
        XCTAssertEqual(Set(watermarks.filter { $0.sessionID == "conflict" }.map(\.sourceID)), [first.path, second.path])
    }

    func testForkCannotResolveBaselineFromAnAmbiguousParent() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.write("parent-a", id: "parent", tokens: 1_000)
        _ = try fixture.write("parent-b", id: "parent", tokens: 2_000)
        _ = try fixture.write(
            "child", id: "child", sharedSessionID: "parent", tokens: 1_050,
            lastTokens: 50, forkedFrom: "parent"
        )

        let report = try fixture.scan()
        // With no proven parent, only the child's explicit completed-turn
        // delta is counted; no arbitrary duplicate supplies inherited totals.
        XCTAssertEqual(report.summary?.totalTokens, 50)
        XCTAssertEqual(report.warnings.map(\.sessionID), ["parent"])
        let index = CostUsageScanner.CodexSessionFileIndex(
            files: [], roots: [fixture.sessions], excludedSessionIDs: ["parent"]
        )
        XCTAssertNil(try index.fileURL(for: "parent"))
    }

    func testReportMergeRetainsWarningsEvenWithoutDailyEntries() {
        let warning = CostUsageScanWarning(
            reason: .ambiguousSessionIdentity, sessionID: "conflict", sourcePaths: ["/b", "/a", "/a"]
        )
        let report = CostUsageDailyReport(data: [], summary: nil, warnings: [warning])
        XCTAssertEqual(CostUsageDailyReport.merged([report, report]).warnings, [warning])
        XCTAssertEqual(warning.sourcePaths, ["/a", "/b"])
    }

    private struct Fixture {
        let root: URL
        let sessions: URL
        let cacheRoot: URL
        let now = ISO8601DateFormatter().date(from: "2026-09-02T09:00:00Z")!

        init() throws {
            root = FileManager.default.temporaryDirectory
                .standardizedFileURL.resolvingSymlinksInPath()
                .appendingPathComponent("token-identity-regression-\(UUID().uuidString)", isDirectory: true)
            sessions = root.appendingPathComponent("sessions", isDirectory: true)
            cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
            try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }

        func write(
            _ name: String, id: String?, sharedSessionID: String? = nil, tokens: Int,
            lastTokens: Int? = nil, forkedFrom: String? = nil, escapedTypeKey: Bool = false
        ) throws -> URL {
            var payload: [String: Any] = [:]
            if let id { payload["id"] = id }
            if let sharedSessionID { payload["session_id"] = sharedSessionID }
            if let forkedFrom { payload["forked_from_id"] = forkedFrom }
            let metadata: [String: Any] = [
                "type": "session_meta", "timestamp": "2026-09-02T07:59:59Z", "payload": payload
            ]
            var header = String(decoding: try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]), as: UTF8.self)
            if escapedTypeKey { header = header.replacingOccurrences(of: "\"type\"", with: "\"ty\\u0070e\"") }
            let event: [String: Any] = [
                "type": "event_msg", "timestamp": "2026-09-02T08:00:00Z",
                "payload": ["type": "token_count", "info": [
                    "total_token_usage": ["input_tokens": tokens, "output_tokens": 0, "total_tokens": tokens],
                    "last_token_usage": ["input_tokens": lastTokens ?? tokens, "output_tokens": 0, "total_tokens": lastTokens ?? tokens]
                ]]
            ]
            let eventText = String(decoding: try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]), as: UTF8.self)
            let url = sessions.appendingPathComponent("rollout-2026-09-02T08-00-00-\(name).jsonl")
            try "\(header)\n\(eventText)\n".write(to: url, atomically: true, encoding: .utf8)
            return url.standardizedFileURL.resolvingSymlinksInPath()
        }

        func scan() throws -> CostUsageDailyReport {
            var options = CostUsageScanner.Options(
                codexSessionsRoots: [sessions], cacheRoot: cacheRoot,
                codexTraceDatabaseURL: root.appendingPathComponent("missing-priority.sqlite")
            )
            options.refreshMinIntervalSeconds = 0
            return try CostUsageScanner.loadDailyReportCancellable(
                provider: .codex, since: Calendar.current.startOfDay(for: now),
                until: now, now: now, options: options, checkCancellation: nil
            )
        }

        func cache() throws -> CostUsageCache {
            try CostUsageCacheIO.loadRequired(provider: .codex, cacheRoot: cacheRoot)
        }
    }
}

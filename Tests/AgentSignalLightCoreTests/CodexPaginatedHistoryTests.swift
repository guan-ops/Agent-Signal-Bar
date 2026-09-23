import Foundation
import XCTest
@testable import AgentSignalLight

final class CodexPaginatedHistoryTests: XCTestCase {
    func testCompletePairAppendedBeforeEOFRetainsConfirmedHistory() throws {
        // The first chunk has been read, but the stream has not reached EOF.
        try assertCompletePairAppendedDuringRecovery(atCheck: 4)
    }

    func testCompletePairAppendedDuringFingerprintRetainsConfirmedHistory() throws {
        // The small fixture prefix has been hashed, immediately before the
        // fingerprint helper rechecks source metadata.
        try assertCompletePairAppendedDuringRecovery(atCheck: 10)
    }

    private func assertCompletePairAppendedDuringRecovery(atCheck mutationCheck: Int) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        XCTAssertEqual(try fixture.scan().summary?.totalTokens, 150)
        let cacheURL = CostUsageCacheIO.cacheFileURL(provider: .codex, cacheRoot: fixture.cacheRoot)
        let committed = try Data(contentsOf: cacheURL)
        let rootPage = fixture.sessions.appendingPathComponent("rollout-2026-09-02T08-00-00-root.jsonl")
        // Trigger recovery instead of the unchanged-group fast path, while
        // retaining every byte of the already committed source.
        try fixture.append([Fixture.event("fixture_note", ordinal: 6, payload: [:])], to: rootPage)
        let state = RecoveryReadState()
        var options = CostUsageScanner.Options(codexSessionsRoots: [fixture.sessions],
            cacheRoot: fixture.cacheRoot, codexTraceDatabaseURL: fixture.root.appendingPathComponent("missing.sqlite"))
        options.refreshMinIntervalSeconds = 0
        options.codexScanProgress = { progress in
            if progress.phase == .validating { state.arm() }
        }
        XCTAssertThrowsError(try CostUsageScanner.loadDailyReportCancellable(provider: .codex,
            since: Calendar.current.startOfDay(for: fixture.now), until: fixture.now, now: fixture.now,
            options: options, checkCancellation: {
                if state.reached(check: mutationCheck) {
                    // Buffered events may land after scanning starts while
                    // their event timestamps still precede the scan cutoff.
                    try fixture.appendResponse(to: rootPage, ordinal: 7,
                        response: "buffered-response", usage: 40, total: 160)
                }
            })) { error in
                let error = error as NSError
                XCTAssertEqual(error.domain, "AgentSignalCostUsage.CodexConsistency")
                XCTAssertEqual(error.code, 3)
            }
        XCTAssertTrue(state.didMutate)
        XCTAssertEqual(try Data(contentsOf: cacheURL), committed)
        XCTAssertEqual(try fixture.scan().summary?.totalTokens, 190)
        XCTAssertEqual(try fixture.scan().summary?.totalTokens, 190)
    }

    private final class RecoveryReadState: @unchecked Sendable {
        private let lock = NSLock()
        private var checks: Int?
        private var mutated = false

        var didMutate: Bool {
            lock.lock()
            defer { lock.unlock() }
            return mutated
        }

        func arm() {
            lock.lock()
            defer { lock.unlock() }
            checks = 0
        }

        func reached(check: Int) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard let current = checks else { return false }
            checks = current + 1
            guard checks == check else { return false }
            mutated = true
            return true
        }
    }

    func testPaginatedOnlyCacheBootstrapsConfirmedHistory() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        XCTAssertEqual(try fixture.scan().summary?.totalTokens, 150)
        let days = try XCTUnwrap(fixture.scanner().cachedDailyActivity(now: fixture.now, days: 1))
        XCTAssertEqual(days.reduce(0) { $0 + $1.totalTokens }, 150)
    }

    func testPendingAppendRetainsPreviouslyConfirmedPaginatedHistory() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        XCTAssertEqual(try fixture.scan().summary?.totalTokens, 150)
        let cacheURL = CostUsageCacheIO.cacheFileURL(provider: .codex, cacheRoot: fixture.cacheRoot)
        let committed = try Data(contentsOf: cacheURL)
        try fixture.append([Fixture.record(ordinal: 9, response: "pending", usage: 40, total: 170)], to: fixture.page)
        XCTAssertThrowsError(try fixture.scan())
        XCTAssertEqual(try Data(contentsOf: cacheURL), committed)
        try fixture.append([Fixture.token(ordinal: 10, usage: 40, total: 170)], to: fixture.page)
        XCTAssertEqual(try fixture.scan().summary?.totalTokens, 190)
    }

    func testPendingAppendCannotPreserveARewrittenPeerPage() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.scan()
        let rootPage = fixture.sessions.appendingPathComponent("rollout-2026-09-02T08-00-00-root.jsonl")
        let contents = try String(contentsOf: rootPage, encoding: .utf8)
        try contents.replacingOccurrences(of: "gpt-5", with: "gpt-6").write(
            to: rootPage, atomically: false, encoding: .utf8)
        try fixture.append([Fixture.record(ordinal: 9, response: "pending", usage: 40, total: 170)], to: fixture.page)
        let report = try fixture.scan()
        XCTAssertEqual(report.warnings.count, 1)
        XCTAssertEqual(report.summary?.totalTokens ?? 0, 0)
        XCTAssertNil(try CostUsageCacheIO.loadRequired(provider: .codex,
            cacheRoot: fixture.cacheRoot).codexPaginatedLedgers)
    }

    func testPartialJSONAppendRetainsPreviouslyConfirmedPaginatedHistory() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        XCTAssertEqual(try fixture.scan().summary?.totalTokens, 150)
        let cacheURL = CostUsageCacheIO.cacheFileURL(provider: .codex, cacheRoot: fixture.cacheRoot)
        let committed = try Data(contentsOf: cacheURL)
        let record = try JSONSerialization.data(withJSONObject:
            Fixture.record(ordinal: 9, response: "partial", usage: 40, total: 170), options: [.sortedKeys])
        let split = record.count / 2
        let handle = try FileHandle(forWritingTo: fixture.page)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: record.prefix(split))
        XCTAssertThrowsError(try fixture.scan())
        XCTAssertEqual(try Data(contentsOf: cacheURL), committed)
        try handle.write(contentsOf: record.dropFirst(split) + Data([0x0a]))
        try fixture.append([Fixture.token(ordinal: 10, usage: 40, total: 170)], to: fixture.page)
        XCTAssertEqual(try fixture.scan().summary?.totalTokens, 190)
    }

    func testAppendAfterScanCutoffRetainsPreviouslyConfirmedPaginatedHistory() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        XCTAssertEqual(try fixture.scan().summary?.totalTokens, 150)
        let cacheURL = CostUsageCacheIO.cacheFileURL(provider: .codex, cacheRoot: fixture.cacheRoot)
        let committed = try Data(contentsOf: cacheURL)
        let stamp = ISO8601DateFormatter().string(from: fixture.now.addingTimeInterval(1))
        var record = Fixture.record(ordinal: 9, response: "after-cutoff", usage: 40, total: 170)
        var token = Fixture.token(ordinal: 10, usage: 40, total: 170)
        record["timestamp"] = stamp
        token["timestamp"] = stamp
        try fixture.append([record, token], to: fixture.page)
        XCTAssertThrowsError(try fixture.scan())
        XCTAssertEqual(try Data(contentsOf: cacheURL), committed)
        XCTAssertEqual(try fixture.scan(through: fixture.now.addingTimeInterval(2)).summary?.totalTokens, 190)
    }

    func testRecoveredDetailsContainOneSessionWithAllPageUsage() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.scan()
        let cache = try CostUsageCacheIO.loadRequired(provider: .codex, cacheRoot: fixture.cacheRoot)
        let details = CodexUsageDetails.build(cache: cache, now: fixture.now,
            modelsDevCatalog: ModelsDevCatalog(providers: [:]), projectPath: { _, _ in "/fixture" })
        XCTAssertEqual(details.sessions.count, 1)
        XCTAssertEqual(details.sessions.first?.totalTokens, 150)
        XCTAssertEqual(details.projects.first?.sessionCount, 1)
    }

    func testRecordAwaitingTokenEventCannotBePublishedEarly() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.append([Fixture.record(ordinal: 9, response: "pending", usage: 40, total: 170)], to: fixture.page)
        XCTAssertEqual(try fixture.scan().warnings.count, 1)
        XCTAssertTrue(try fixture.scanner().agentSignalCostUsageScanWatermarks(through: fixture.now).isEmpty)
        try fixture.append([Fixture.token(ordinal: 10, usage: 40, total: 170)], to: fixture.page)
        XCTAssertEqual(try fixture.scan().summary?.totalTokens, 190)
    }

    func testMismatchedCumulativeTotalCannotPublishHistoryOrWatermark() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.append([
            Fixture.record(ordinal: 9, response: "mismatch", usage: 40, total: 170),
            Fixture.token(ordinal: 10, usage: 40, total: 171),
        ], to: fixture.page)
        let report = try fixture.scan()
        XCTAssertEqual(report.warnings.count, 1)
        XCTAssertEqual(report.summary?.totalTokens ?? 0, 0)
        XCTAssertTrue(try fixture.scanner().agentSignalCostUsageScanWatermarks(through: fixture.now).isEmpty)
    }

    func testRecoveredSourcesExportSeparateExactWatermarks() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.scan()
        let scanner = fixture.scanner()
        let marks = try scanner.agentSignalCostUsageScanWatermarks(through: fixture.now)
        XCTAssertEqual(marks.count, 2)
        XCTAssertEqual(Set(marks.compactMap(\.totalTokens)), [120, 130])
        XCTAssertTrue(marks.allSatisfy { $0.sessionID == "paged-session" && $0.endOffset < .max })
        try fixture.appendResponse(to: fixture.page, ordinal: 9, response: "new", usage: 40, total: 170)
        XCTAssertThrowsError(try scanner.agentSignalCostUsageScanWatermarks(through: fixture.now))
        _ = try fixture.scan()
        XCTAssertEqual(Set(try scanner.agentSignalCostUsageScanWatermarks(through: fixture.now)
            .compactMap(\.totalTokens)), [120, 170])
    }

    func testCommitRacePreservesPreviouslyCommittedCache() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.scan()
        let cacheURL = CostUsageCacheIO.cacheFileURL(provider: .codex, cacheRoot: fixture.cacheRoot)
        let before = try Data(contentsOf: cacheURL)
        XCTAssertThrowsError(try fixture.scan(force: true, beforeCommit: {
            try! fixture.appendResponse(to: fixture.page, ordinal: 9, response: "new", usage: 40, total: 170)
        }))
        XCTAssertEqual(try Data(contentsOf: cacheURL), before)
    }

    func testAdditionalCopyInvalidatesCachedRecovery() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.scan()
        try FileManager.default.copyItem(at: fixture.page,
            to: fixture.sessions.appendingPathComponent("rollout-2026-09-02T08-30-00-copy.jsonl"))
        let report = try fixture.scan()
        XCTAssertEqual(report.warnings.count, 1)
        XCTAssertEqual(report.summary?.totalTokens ?? 0, 0)
    }

    func testCompactionResetDoesNotEraseOrRecountBilledResponses() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        // Codex reports compacted context size in this summary field even
        // though all billable components of last_token_usage are zero.
        var compactedUsage = Fixture.usage(0)
        compactedUsage["total_tokens"] = 99
        try fixture.append([Fixture.record(ordinal: 9, response: "compaction", usage: 40, total: 170),
            Fixture.event("compacted", ordinal: 10, payload: [:]),
            Fixture.event("event_msg", ordinal: 11, payload: ["type": "token_count", "info": [
                "last_token_usage": compactedUsage, "total_token_usage": Fixture.usage(0)]])], to: fixture.page)
        XCTAssertEqual(try fixture.scan().summary?.totalTokens, 190)
        XCTAssertEqual(Set(try fixture.scanner().agentSignalCostUsageScanWatermarks(through: fixture.now)
            .compactMap(\.totalTokens)), [0, 120])
        try fixture.appendResponse(to: fixture.page, ordinal: 12, response: "after-compaction", usage: 50, total: 50)
        let report = try fixture.scan(force: true)
        XCTAssertTrue(report.warnings.isEmpty)
        XCTAssertEqual(report.summary?.totalTokens, 240)
        XCTAssertEqual(try fixture.scan(force: true).summary?.totalTokens, 240)
    }

    func testMalformedBilledTotalCannotClearWarning() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var totals = Fixture.usage(0)
        totals["total_tokens"] = 100
        try fixture.append([Fixture.event("token_usage_record", ordinal: 9, payload: [
            "thread_id": "paged-session", "session_id": "paged-session", "response_id": "bad",
            "usage": totals, "thread_token_usage": Fixture.usage(130)]),
            Fixture.token(ordinal: 10, usage: 0, total: 130)], to: fixture.page)
        XCTAssertEqual(try fixture.scan().warnings.count, 1)
    }

    func testCompactionDoesNotPermitInconsistentPositiveLastUsage() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var usage = Fixture.usage(30)
        usage["total_tokens"] = 99
        try fixture.append([Fixture.event("compacted", ordinal: 9, payload: [:]),
            Fixture.event("event_msg", ordinal: 10, payload: ["type": "token_count", "info": [
                "last_token_usage": usage, "total_token_usage": Fixture.usage(130)]])], to: fixture.page)
        XCTAssertEqual(try fixture.scan().warnings.count, 1)
    }

    func testResumedPageCountsOwnResponsesWithoutRecountingInheritedHistory() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for _ in 0..<2 {
            let report = try fixture.scan()
            // Root: 100 + 20; continuation from the earlier 100 boundary: 30.
            XCTAssertEqual(report.summary?.totalTokens, 150)
            XCTAssertTrue(report.warnings.isEmpty)
            let cached = try CostUsageCacheIO.loadRequired(provider: .codex, cacheRoot: fixture.cacheRoot)
            let restored = CostUsageScanner.buildCodexReportFromCache(cache: cached, range: fixture.range)
            XCTAssertEqual(restored.summary?.totalTokens, 150)
            XCTAssertTrue(restored.warnings.isEmpty)
        }
    }

    func testAppendToResumedPageCountsEachResponseOnce() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        XCTAssertEqual(try fixture.scan().summary?.totalTokens, 150)
        try fixture.appendResponse(to: fixture.page, ordinal: 9, response: "page-next", usage: 40, total: 170)
        for _ in 0..<2 {
            let report = try fixture.scan()
            XCTAssertEqual(report.summary?.totalTokens, 190)
            XCTAssertTrue(report.warnings.isEmpty)
        }
    }

    func testOverlappingResponseIdentityRemainsExcluded() throws {
        let fixture = try Fixture(response: "root-response")
        defer { fixture.remove() }
        XCTAssertEqual(try fixture.scan().warnings.count, 1)
        XCTAssertEqual(try fixture.scan().summary?.totalTokens ?? 0, 0)
    }

    func testInvalidHistoryBoundaryRemainsExcluded() throws {
        let fixture = try Fixture(boundaryAdjustment: 1)
        defer { fixture.remove() }
        XCTAssertEqual(try fixture.scan().warnings.count, 1)
    }

    func testUnbackedTokenEventRevokesPreviouslyRecoveredHistory() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        XCTAssertEqual(try fixture.scan().summary?.totalTokens, 150)
        try fixture.append([Fixture.token(ordinal: 9, usage: 10, total: 140)], to: fixture.page)
        let report = try fixture.scan()
        XCTAssertEqual(report.warnings.count, 1)
        XCTAssertEqual(report.summary?.totalTokens ?? 0, 0)
    }

    private struct Fixture {
        let root: URL
        let sessions: URL
        let cacheRoot: URL
        let page: URL
        let now = ISO8601DateFormatter().date(from: "2026-09-02T09:00:00Z")!
        var range: CostUsageScanner.CostUsageDayRange {
            .init(since: Calendar.current.startOfDay(for: now), until: now)
        }

        init(response: String = "page-response", boundaryAdjustment: Int = 0) throws {
            root = URL(fileURLWithPath: "/private/tmp/asb-paginated-\(UUID().uuidString)")
                .standardizedFileURL.resolvingSymlinksInPath()
            sessions = root.appendingPathComponent("sessions")
            cacheRoot = root.appendingPathComponent("cache")
            page = sessions.appendingPathComponent("rollout-2026-09-02T08-10-00-page.jsonl")
            try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
            let first = sessions.appendingPathComponent("rollout-2026-09-02T08-00-00-root.jsonl")
            try append([
                Self.metadata(ordinal: 0),
                Self.context(ordinal: 1),
                Self.record(ordinal: 2, response: "root-response", usage: 100, total: 100),
                Self.token(ordinal: 3, usage: 100, total: 100),
            ], to: first)
            let boundary = try Data(contentsOf: first).count
            try appendResponse(to: first, ordinal: 4, response: "root-tail", usage: 20, total: 120)
            try append([
                Self.metadata(ordinal: 4, boundary: boundary + boundaryAdjustment),
                Self.context(ordinal: 5),
                Self.record(ordinal: 6, response: response, usage: 30, total: 130),
                Self.token(ordinal: 7, usage: 30, total: 130),
                Self.token(ordinal: 8, usage: 30, total: 130),
            ], to: page)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
        func appendResponse(to url: URL, ordinal: Int, response: String, usage: Int, total: Int) throws {
            try append([Self.record(ordinal: ordinal, response: response, usage: usage, total: total),
                        Self.token(ordinal: ordinal + 1, usage: usage, total: total)], to: url)
        }
        func append(_ lines: [[String: Any]], to url: URL) throws {
            var data = Data()
            for line in lines {
                data.append(try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]))
                data.append(0x0a)
            }
            if !FileManager.default.fileExists(atPath: url.path) { try Data().write(to: url) }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        }
        static func event(_ type: String, ordinal: Int, payload: [String: Any]) -> [String: Any] {
            ["type": type, "ordinal": ordinal, "timestamp": "2026-09-02T08:20:00Z", "payload": payload]
        }
        static func metadata(ordinal: Int, boundary: Int? = nil) -> [String: Any] {
            var payload: [String: Any] = ["id": "paged-session", "session_id": "paged-session",
                                          "history_mode": "paginated", "timestamp": "2026-09-02T08:00:00Z"]
            if let boundary {
                payload["history_base"] = ["thread_id": "paged-session", "end_ordinal_exclusive": ordinal,
                                           "end_byte_offset": boundary] as [String: Any]
            }
            return event("session_meta", ordinal: ordinal, payload: payload)
        }
        static func context(ordinal: Int) -> [String: Any] {
            event("turn_context", ordinal: ordinal, payload: ["model": "gpt-5", "turn_id": "fixture-turn"])
        }
        static func usage(_ total: Int) -> [String: Int] {
            ["input_tokens": total, "cached_input_tokens": 0, "output_tokens": 0, "total_tokens": total]
        }
        static func record(ordinal: Int, response: String, usage amount: Int, total: Int) -> [String: Any] {
            event("token_usage_record", ordinal: ordinal, payload: ["thread_id": "paged-session",
                  "session_id": "paged-session", "response_id": response, "turn_id": "fixture-turn",
                  "usage": usage(amount), "thread_token_usage": usage(total)])
        }
        static func token(ordinal: Int, usage amount: Int, total: Int) -> [String: Any] {
            event("event_msg", ordinal: ordinal, payload: ["type": "token_count", "info": [
                "last_token_usage": usage(amount), "total_token_usage": usage(total)]])
        }
        func scanner() -> CodexTokenActivityScanner {
            CodexTokenActivityScanner(sessionRootURLs: [sessions], cacheURL: root.appendingPathComponent("legacy.json"),
                costUsageCacheRootURL: cacheRoot, usesAgentSignalCostUsageScanner: true,
                priorityDatabaseURL: root.appendingPathComponent("missing.sqlite"))
        }
        func scan(force: Bool = false, beforeCommit: (() -> Void)? = nil,
                  through: Date? = nil) throws -> CostUsageDailyReport {
            let now = through ?? self.now
            var options = CostUsageScanner.Options(codexSessionsRoots: [sessions], cacheRoot: cacheRoot,
                codexTraceDatabaseURL: root.appendingPathComponent("missing.sqlite"), forceRescan: force)
            options.refreshMinIntervalSeconds = 0
            options.codexInventoryBeforeCommitHook = beforeCommit
            return try CostUsageScanner.loadDailyReportCancellable(provider: .codex,
                since: Calendar.current.startOfDay(for: now), until: now, now: now,
                options: options, checkCancellation: nil)
        }
    }
}

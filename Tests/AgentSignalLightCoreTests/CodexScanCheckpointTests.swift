import Foundation
import XCTest
@testable import AgentSignalLight

final class CodexScanCheckpointTests: XCTestCase {
    func testClearRejectsCandidateProducedByAnAlreadyRunningScan() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let checkpoint = CostUsageScanner.CodexScanCheckpoint()
        let scope = try XCTUnwrap(CostUsageScanner.codexCheckpointScope(options: fixture.options()))
        let oldGeneration = checkpoint.currentGeneration
        checkpoint.clear()
        checkpoint.store(CostUsageCache(), scope: scope, generation: oldGeneration)
        XCTAssertFalse(checkpoint.hasCandidate)
        checkpoint.store(CostUsageCache(), scope: scope, generation: checkpoint.currentGeneration)
        XCTAssertTrue(checkpoint.hasCandidate)
    }

    func testFailedInventoryRetainsOnlyUnpublishedRetryWork() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let checkpoint = CostUsageScanner.CodexScanCheckpoint()
        _ = try fixture.write("first", id: "first", tokens: 100)

        XCTAssertThrowsError(try fixture.scan(checkpoint: checkpoint, beforeCommit: {
            XCTAssertNoThrow(try fixture.write("guardian", id: "guardian", tokens: 10))
        }))
        XCTAssertTrue(checkpoint.hasCandidate)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.cacheURL.path))
        XCTAssertTrue(CostUsageCacheIO.load(provider: .codex, cacheRoot: fixture.cacheRoot).days.isEmpty)
        let candidate = try fixture.candidate(checkpoint)
        XCTAssertEqual(candidate.codexSessionInventoryComplete, false)
        XCTAssertNotNil(candidate.scanSinceKey)
        XCTAssertNotNil(candidate.codexPricingKey)
        XCTAssertEqual(candidate.files.count, 1)

        let complete = try fixture.scan(checkpoint: checkpoint)
        XCTAssertEqual(complete.summary?.totalTokens, 110)
        XCTAssertFalse(checkpoint.hasCandidate)
        XCTAssertEqual(try fixture.cache().codexSessionInventoryComplete, true)
    }

    func testRepeatedDirectoryGrowthAccumulatesRetryProgressWithoutPublishing() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let checkpoint = CostUsageScanner.CodexScanCheckpoint()
        _ = try fixture.write("first", id: "first", tokens: 100)

        for index in 0..<3 {
            XCTAssertThrowsError(try fixture.scan(checkpoint: checkpoint, beforeCommit: {
                XCTAssertNoThrow(try fixture.write("guardian-\(index)", id: "guardian-\(index)", tokens: 10))
            }))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.cacheURL.path))
            XCTAssertEqual(try fixture.candidate(checkpoint).files.count, index + 1)
        }

        XCTAssertEqual(try fixture.scan(checkpoint: checkpoint).summary?.totalTokens, 130)
        XCTAssertFalse(checkpoint.hasCandidate)
    }

    func testFailedRetryPreservesExistingCommittedCacheBytes() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.write("first", id: "first", tokens: 100)
        XCTAssertEqual(try fixture.scan().summary?.totalTokens, 100)
        let committed = try Data(contentsOf: fixture.cacheURL)
        _ = try fixture.write("next", id: "next", tokens: 50)
        let checkpoint = CostUsageScanner.CodexScanCheckpoint()

        XCTAssertThrowsError(try fixture.scan(checkpoint: checkpoint, beforeCommit: {
            XCTAssertNoThrow(try fixture.write("guardian", id: "guardian", tokens: 10))
        }))
        XCTAssertEqual(try Data(contentsOf: fixture.cacheURL), committed)
        XCTAssertTrue(checkpoint.hasCandidate)
        XCTAssertEqual(try fixture.scan(checkpoint: checkpoint).summary?.totalTokens, 160)
    }

    func testUncommittedOwnerCannotAuthorizeQuarantiningANewDivergentCopy() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let checkpoint = CostUsageScanner.CodexScanCheckpoint()
        _ = try fixture.write("healthy", id: "healthy", tokens: 100)
        _ = try fixture.write("duplicate-a", id: "duplicate", tokens: 200)
        XCTAssertThrowsError(try fixture.scan(checkpoint: checkpoint, beforeCommit: {
            XCTAssertNoThrow(try fixture.write("duplicate-b", id: "duplicate", tokens: 300))
        }))

        let report = try fixture.scan(checkpoint: checkpoint)
        XCTAssertEqual(report.summary?.totalTokens, 100)
        XCTAssertEqual(report.warnings.map(\.sessionID), ["duplicate"])
        let duplicates = try fixture.cache().files.values.filter { $0.sessionId == "duplicate" }
        XCTAssertEqual(duplicates.count, 2)
        XCTAssertTrue(duplicates.allSatisfy { $0.codexIdentityConflict == true && $0.days.isEmpty })
        XCTAssertFalse(duplicates.contains { $0.codexDuplicateQuarantined == true })
    }

    func testChangedSourcePrefixIsNotReused() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let checkpoint = CostUsageScanner.CodexScanCheckpoint()
        _ = try fixture.write("first", id: "first", tokens: 100)
        XCTAssertThrowsError(try fixture.scan(checkpoint: checkpoint, beforeCommit: {
            XCTAssertNoThrow(try fixture.write("guardian", id: "guardian", tokens: 10))
        }))
        _ = try fixture.write("first", id: "first", tokens: 500)

        XCTAssertEqual(try fixture.scan(checkpoint: checkpoint).summary?.totalTokens, 510)
        XCTAssertFalse(checkpoint.hasCandidate)
    }

    func testStableAppendIsReconciledWithCheckpointWithoutDoubleCounting() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let checkpoint = CostUsageScanner.CodexScanCheckpoint()
        let first = try fixture.write("first", id: "first", tokens: 100)
        XCTAssertThrowsError(try fixture.scan(checkpoint: checkpoint, beforeCommit: {
            XCTAssertNoThrow(try fixture.write("guardian", id: "guardian", tokens: 10))
        }))
        let handle = try FileHandle(forWritingTo: first)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((Fixture.tokenEvent(total: 150, last: 50) + "\n").utf8))
        try handle.close()

        XCTAssertEqual(try fixture.scan(checkpoint: checkpoint).summary?.totalTokens, 160)
        XCTAssertFalse(checkpoint.hasCandidate)
    }

    func testNewCommittedCacheInvalidatesCheckpointScope() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let checkpoint = CostUsageScanner.CodexScanCheckpoint()
        _ = try fixture.write("first", id: "first", tokens: 100)
        XCTAssertThrowsError(try fixture.scan(checkpoint: checkpoint, beforeCommit: {
            XCTAssertNoThrow(try fixture.write("guardian", id: "guardian", tokens: 10))
        }))
        XCTAssertEqual(try fixture.scan().summary?.totalTokens, 110)
        let scope = try XCTUnwrap(CostUsageScanner.codexCheckpointScope(options: fixture.options()))
        XCTAssertNil(checkpoint.load(scope: scope, throughUnixMs: fixture.nowMs))
        XCTAssertFalse(checkpoint.hasCandidate)
    }

    func testCheckpointRetryCannotOverwriteCacheCommittedDuringItsScan() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let checkpoint = CostUsageScanner.CodexScanCheckpoint()
        _ = try fixture.write("first", id: "first", tokens: 100)
        XCTAssertThrowsError(try fixture.scan(checkpoint: checkpoint, beforeCommit: {
            XCTAssertNoThrow(try fixture.write("guardian", id: "guardian", tokens: 10))
        }))
        var externalCommit: Data?
        XCTAssertThrowsError(try fixture.scan(checkpoint: checkpoint, beforeCommit: {
            // A distinct scanner publishes successfully while this retry is
            // about to commit. Its result must not be replaced by retry work.
            XCTAssertNoThrow(try fixture.scan())
            externalCommit = try? Data(contentsOf: fixture.cacheURL)
        }))
        XCTAssertEqual(try Data(contentsOf: fixture.cacheURL), try XCTUnwrap(externalCommit))
        XCTAssertFalse(checkpoint.hasCandidate)
    }

    func testCheckpointDoesNotCrossSessionRootsOrTravelBackBeforeCutoff() throws {
        let fixture = try Fixture()
        let other = try Fixture()
        defer { fixture.remove(); other.remove() }
        let checkpoint = CostUsageScanner.CodexScanCheckpoint()
        _ = try fixture.write("first", id: "first", tokens: 100)
        XCTAssertThrowsError(try fixture.scan(checkpoint: checkpoint, beforeCommit: {
            XCTAssertNoThrow(try fixture.write("guardian", id: "guardian", tokens: 10))
        }))
        let ownScope = try XCTUnwrap(CostUsageScanner.codexCheckpointScope(options: fixture.options()))
        XCTAssertNil(checkpoint.load(scope: ownScope, throughUnixMs: fixture.nowMs - 1))
        XCTAssertFalse(checkpoint.hasCandidate)

        XCTAssertThrowsError(try fixture.scan(checkpoint: checkpoint, beforeCommit: {
            XCTAssertNoThrow(try fixture.write("another", id: "another", tokens: 20))
        }))
        _ = try other.write("other", id: "other", tokens: 70)
        XCTAssertEqual(try other.scan(checkpoint: checkpoint).summary?.totalTokens, 70)
        XCTAssertFalse(checkpoint.hasCandidate)
    }

    private struct Fixture {
        let root: URL
        let sessions: URL
        let dayDirectory: URL
        let cacheRoot: URL
        let now = ISO8601DateFormatter().date(from: "2026-09-02T09:00:00Z")!
        var nowMs: Int64 { Int64(now.timeIntervalSince1970 * 1000) }
        var cacheURL: URL { CostUsageCacheIO.cacheFileURL(provider: .codex, cacheRoot: cacheRoot) }

        init() throws {
            root = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
                .appendingPathComponent("codex-checkpoint-regression-\(UUID().uuidString)", isDirectory: true)
            sessions = root.appendingPathComponent("sessions", isDirectory: true)
            dayDirectory = sessions.appendingPathComponent("2026/09/02", isDirectory: true)
            cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
            try FileManager.default.createDirectory(at: dayDirectory, withIntermediateDirectories: true)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }

        func write(_ name: String, id: String, tokens: Int) throws -> URL {
            let header = #"{"type":"session_meta","timestamp":"2026-09-02T07:59:59Z","payload":{"id":""#
                + id + #""}}"#
            let url = dayDirectory.appendingPathComponent("rollout-2026-09-02T08-00-00-\(name).jsonl")
            try "\(header)\n\(Self.tokenEvent(total: tokens, last: tokens))\n"
                .write(to: url, atomically: true, encoding: .utf8)
            return url
        }

        static func tokenEvent(total: Int, last: Int) -> String {
            #"{"timestamp":"2026-09-02T08:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(total),"output_tokens":0},"last_token_usage":{"input_tokens":\#(last),"output_tokens":0}}}}"#
        }

        func options(checkpoint: CostUsageScanner.CodexScanCheckpoint? = nil) -> CostUsageScanner.Options {
            var options = CostUsageScanner.Options(
                codexSessionsRoots: [sessions], cacheRoot: cacheRoot,
                codexTraceDatabaseURL: root.appendingPathComponent("missing-priority.sqlite"),
                codexScanCheckpoint: checkpoint
            )
            options.refreshMinIntervalSeconds = 0
            return options
        }

        func scan(
            checkpoint: CostUsageScanner.CodexScanCheckpoint? = nil,
            beforeCommit: (() throws -> Void)? = nil
        ) throws -> CostUsageDailyReport {
            var options = options(checkpoint: checkpoint)
            if let beforeCommit {
                options.codexInventoryBeforeCommitHook = {
                    do {
                        try beforeCommit()
                    } catch {
                        XCTFail("Checkpoint test mutation failed: \(error)")
                    }
                }
            }
            return try CostUsageScanner.loadDailyReportCancellable(
                provider: .codex, since: Calendar.current.startOfDay(for: now),
                until: now, now: now, options: options, checkCancellation: nil
            )
        }

        func candidate(_ checkpoint: CostUsageScanner.CodexScanCheckpoint) throws -> CostUsageCache {
            let scope = try XCTUnwrap(CostUsageScanner.codexCheckpointScope(options: options()))
            return try XCTUnwrap(checkpoint.load(scope: scope, throughUnixMs: nowMs))
        }

        func cache() throws -> CostUsageCache {
            try CostUsageCacheIO.loadRequired(provider: .codex, cacheRoot: cacheRoot)
        }
    }
}

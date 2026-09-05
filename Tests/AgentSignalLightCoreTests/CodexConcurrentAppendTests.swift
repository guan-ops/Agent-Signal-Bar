import Foundation
import XCTest
@testable import AgentSignalLight

final class CodexConcurrentAppendTests: XCTestCase {
    func testColdScanCommitsFixedPrefixAndNextScanCountsAppendOnce() throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.write(tokens: 100)
        XCTAssertEqual(try f.scan { try f.append(total: 150, last: 50) }.summary?.totalTokens, 100)
        XCTAssertEqual(try f.scan().summary?.totalTokens, 150)
        XCTAssertEqual(try f.scan().summary?.totalTokens, 150)
    }

    func testIncrementalScanDoesNotChaseConcurrentAppend() throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.write(tokens: 100)
        XCTAssertEqual(try f.scan().summary?.totalTokens, 100)
        try f.append(total: 150, last: 50)
        XCTAssertEqual(try f.scan { try f.append(total: 180, last: 30) }.summary?.totalTokens, 150)
        XCTAssertEqual(try f.scan().summary?.totalTokens, 180)
        XCTAssertEqual(try f.scan().summary?.totalTokens, 180)
    }

    func testRewriteWithAppendCannotPassPrefixValidation() throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.write(tokens: 100)
        _ = try f.scan()
        let committed = try Data(contentsOf: f.cacheURL)
        try f.append(total: 150, last: 50)
        XCTAssertThrowsError(try f.scan {
            let handle = try FileHandle(forWritingTo: f.source)
            defer { try? handle.close() }
            try handle.write(contentsOf: Data(f.log(tokens: 200).utf8))
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((Fixture.event(total: 300, last: 100) + "\n").utf8))
        })
        XCTAssertEqual(try Data(contentsOf: f.cacheURL), committed)
    }

    func testTruncationAndAtomicReplacementRejectSnapshot() throws {
        for replacement in [false, true] {
            let f = try Fixture()
            defer { f.remove() }
            try f.write(tokens: 100)
            _ = try f.scan()
            let committed = try Data(contentsOf: f.cacheURL)
            try f.append(total: 150, last: 50)
            XCTAssertThrowsError(try f.scan {
                if replacement { try f.write(tokens: 900) }
                else {
                    let handle = try FileHandle(forWritingTo: f.source)
                    defer { try? handle.close() }
                    try handle.truncate(atOffset: 0)
                }
            })
            XCTAssertEqual(try Data(contentsOf: f.cacheURL), committed)
        }
    }

    func testSourceChangeFailureDoesNotExposeLocalPath() {
        let result = CodexTokenActivityScanResult.failure(
            days: [], error: CostUsageScanner.codexChangedDuringScanError(path: "/private/fixture/session.jsonl"))
        XCTAssertFalse(result.isComplete)
        XCTAssertTrue(result.isSourceChanging)
        XCTAssertNil(result.failureDescription)
        XCTAssertTrue(result.watermarks.isEmpty)
        let ioFailure = CodexTokenActivityScanResult.failure(
            days: [], error: CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: "/private/fixture"]))
        XCTAssertFalse(ioFailure.isSourceChanging)
        XCTAssertFalse(ioFailure.failureDescription?.contains("/private/") == true)
    }

    private struct Fixture {
        let root: URL
        let sessions: URL
        let cache: URL
        let source: URL
        var cacheURL: URL { CostUsageCacheIO.cacheFileURL(provider: .codex, cacheRoot: cache) }
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("concurrent-append-\(UUID().uuidString)")
            sessions = root.appendingPathComponent("sessions")
            cache = root.appendingPathComponent("cache")
            source = sessions.appendingPathComponent("rollout-fixture.jsonl")
            try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
        static func event(total: Int, last: Int) -> String {
            #"{"timestamp":"2026-09-05T08:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(total),"output_tokens":0},"last_token_usage":{"input_tokens":\#(last),"output_tokens":0}}}}"#
        }
        func log(tokens: Int) -> String {
            #"{"timestamp":"2026-09-05T07:59:00Z","type":"session_meta","payload":{"id":"append-fixture"}}"#
                + "\n" + Self.event(total: tokens, last: tokens) + "\n"
        }
        func write(tokens: Int) throws { try log(tokens: tokens).write(to: source, atomically: true, encoding: .utf8) }
        func append(total: Int, last: Int) throws {
            let handle = try FileHandle(forWritingTo: source)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((Self.event(total: total, last: last) + "\n").utf8))
        }
        func scan(mutation: (() throws -> Void)? = nil) throws -> CostUsageDailyReport {
            var options = CostUsageScanner.Options(
                codexSessionsRoots: [sessions], cacheRoot: cache,
                codexTraceDatabaseURL: root.appendingPathComponent("absent.sqlite"))
            options.refreshMinIntervalSeconds = 0
            options.codexFileBeforeSnapshotValidationHook = { _ in
                do { try mutation?() } catch { XCTFail("Fixture mutation failed: \(error)") }
            }
            let now = ISO8601DateFormatter().date(from: "2026-09-05T09:00:00Z")!
            return try CostUsageScanner.loadDailyReportCancellable(
                provider: .codex, since: now.addingTimeInterval(-3600), until: now, now: now,
                options: options, checkCancellation: nil)
        }
    }
}

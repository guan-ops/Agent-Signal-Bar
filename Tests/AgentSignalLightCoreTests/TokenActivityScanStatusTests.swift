import Foundation
import XCTest
@testable import AgentSignalLight
@testable import AgentSignalLightCore

final class TokenActivityScanStatusTests: XCTestCase {
    func testAmbiguousGroupIsExplicitlyExcludedWithoutDiscardingHealthyHistory() throws {
        try withScanner { root, scanner, now in
            let first = root.appendingPathComponent("sessions/conflict-a.jsonl")
            let second = root.appendingPathComponent("sessions/conflict-b.jsonl")
            try log(sessionID: "conflict", tokens: 100).write(to: first, atomically: true, encoding: .utf8)
            try log(sessionID: "conflict", tokens: 200).write(to: second, atomically: true, encoding: .utf8)
            try log(sessionID: "healthy", tokens: 300).write(
                to: root.appendingPathComponent("sessions/healthy.jsonl"), atomically: true, encoding: .utf8)

            for _ in 0..<2 {
                let result = scanner.scanDailyActivityResult(now: now, days: 1, progress: nil)
                XCTAssertTrue(result.isComplete)
                XCTAssertNil(result.failureDescription)
                XCTAssertNotNil(result.warningDescription)
                XCTAssertEqual(result.days.reduce(0) { $0 + $1.totalTokens }, 300)
                XCTAssertEqual(result.excludedSessionIDs, ["conflict"])
                XCTAssertEqual(result.excludedSourceIDs, Set([first, second].map {
                    $0.standardizedFileURL.resolvingSymlinksInPath().path
                }))
                XCTAssertEqual(Set(result.watermarks.compactMap(\.sessionID)), ["healthy"])
                XCTAssertFalse(result.watermarks.contains { $0.endOffset == .max })
            }
        }
    }

    func testFailedScanReportsFailureAndRetainsLastGoodHistory() throws {
        try withScanner { root, scanner, now in
            let source = root.appendingPathComponent("sessions/owner.jsonl")
            try log(sessionID: "owner", tokens: 100).write(to: source, atomically: true, encoding: .utf8)
            let initial = scanner.scanDailyActivityResult(now: now, days: 1, progress: nil)
            XCTAssertTrue(initial.isComplete)

            let handle = try FileHandle(forWritingTo: source)
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"notice\"}}\n".utf8))
            try handle.close()

            let failed = scanner.scanDailyActivityResult(now: now, days: 1, progress: nil)
            XCTAssertFalse(failed.isComplete)
            XCTAssertNotNil(failed.failureDescription)
            XCTAssertEqual(failed.days, initial.days)
        }
    }

    func testEmptySuccessfulScanIsNotAReadFailure() throws {
        try withScanner { _, scanner, now in
            let result = scanner.scanDailyActivityResult(now: now, days: 1, progress: nil)
            XCTAssertTrue(result.isComplete)
            XCTAssertTrue(result.days.isEmpty)
            XCTAssertNil(result.failureDescription)
            XCTAssertNil(result.warningDescription)
            XCTAssertTrue(result.excludedSourceIDs.isEmpty)
            XCTAssertTrue(result.excludedSessionIDs.isEmpty)
        }
    }

    private func withScanner(
        _ body: (URL, CodexTokenActivityScanner, Date) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "token-scan-status-\(UUID().uuidString)", isDirectory: true)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let scanner = CodexTokenActivityScanner(
            sessionRootURLs: [sessions],
            costUsageCacheRootURL: root.appendingPathComponent("cache"),
            usesAgentSignalCostUsageScanner: true,
            priorityDatabaseURL: root.appendingPathComponent("missing.sqlite"),
            environment: [:])
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-02T10:00:00Z"))
        try body(root, scanner, now)
    }

    private func log(sessionID: String, tokens: Int) -> String {
        [
            #"{"timestamp":"2026-09-02T08:00:00Z","type":"session_meta","payload":{"id":"\#(sessionID)","originator":"Codex Desktop"}}"#,
            #"{"timestamp":"2026-09-02T08:01:00Z","type":"turn_context","payload":{"model":"gpt-5"}}"#,
            #"{"timestamp":"2026-09-02T08:02:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(tokens),"cached_input_tokens":0,"output_tokens":0,"total_tokens":\#(tokens)},"last_token_usage":{"input_tokens":\#(tokens),"cached_input_tokens":0,"output_tokens":0,"total_tokens":\#(tokens)}}}}"#,
        ].joined(separator: "\n") + "\n"
    }
}

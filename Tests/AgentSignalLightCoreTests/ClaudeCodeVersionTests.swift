import Foundation
import XCTest
@testable import AgentSignalLight

final class ClaudeCodeVersionTests: XCTestCase {
    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [(url: String, agent: String)] = []
        func append(_ request: URLRequest) {
            lock.lock(); defer { lock.unlock() }
            storage.append((request.url?.absoluteString ?? "", request.value(forHTTPHeaderField: "User-Agent") ?? ""))
        }
        var values: [(url: String, agent: String)] { lock.lock(); defer { lock.unlock() }; return storage }
    }

    override func setUp() { ClaudeCodeVersion.resetCacheForTesting() }
    override func tearDown() { ClaudeCodeVersion.resetCacheForTesting() }

    func testVersionTokenIsHeaderSafe() {
        XCTAssertEqual(ClaudeCodeVersion.normalized("2.1.236 (Claude Code)\n"), "2.1.236")
        XCTAssertEqual(ClaudeCodeVersion.normalized("2.1\r\nX-Injected: 1"), "2.1", "Only the first token is kept")
        XCTAssertNil(ClaudeCodeVersion.normalized("2.1;evil"))
        XCTAssertNil(ClaudeCodeVersion.normalized("   "))
        XCTAssertNil(ClaudeCodeVersion.normalized(String(repeating: "1", count: 64)))
        XCTAssertEqual(ClaudeCodeVersion.userAgents(version: "bad;value").legacy, "claude-code/2.1.0")
        XCTAssertEqual(ClaudeCodeVersion.userAgents(version: "2.3.4").primary, "claude-cli/2.3.4 (external, cli)")
    }

    func testDetectionRunsOnlyWhenAllowedAndReusesTheCachedExecutable() throws {
        let root = URL(fileURLWithPath: "/private/tmp/claude-version-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("claude")
        try Data("fixture".utf8).write(to: binary)
        var runs = 0
        let run: (URL) -> String? = { _ in runs += 1; return "2.9.\(runs) (Claude Code)" }
        let now = Date()
        XCTAssertNil(ClaudeCodeVersion.detect(binary: binary, allowExecution: false, now: now, run: run), "Background never starts the CLI")
        XCTAssertEqual(runs, 0)
        XCTAssertEqual(ClaudeCodeVersion.detect(binary: binary, allowExecution: true, now: now, run: run), "2.9.1")
        XCTAssertEqual(ClaudeCodeVersion.detect(binary: binary, allowExecution: true, now: now.addingTimeInterval(60), run: run), "2.9.1")
        let later = now.addingTimeInterval(ClaudeCodeVersion.cacheTTL + 1)
        XCTAssertEqual(ClaudeCodeVersion.detect(binary: binary, allowExecution: false, now: later, run: run), "2.9.1", "A stale value beats none")
        XCTAssertEqual(runs, 1)
        XCTAssertEqual(ClaudeCodeVersion.detect(binary: binary, allowExecution: true, now: later, run: run), "2.9.2")
        try Data("upgraded-fixture".utf8).write(to: binary)
        XCTAssertNil(ClaudeCodeVersion.detect(binary: binary, allowExecution: false, now: later, run: run), "A replaced executable invalidates the cache")
        XCTAssertNil(ClaudeCodeVersion.detect(binary: root.appendingPathComponent("missing"), allowExecution: true, now: later, run: run))
        XCTAssertEqual(runs, 2)
    }

    func testUsageRequestReportsInstalledVersionAndRetriesOnlyOptionalInventoryRejection() async throws {
        let usage = #"{"five_hour":{"utilization":10}}"#
        @Sendable func response(_ request: URLRequest, _ status: Int, _ body: String) -> (Data, HTTPURLResponse) {
            (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        let direct = Log()
        _ = try await ClaudeUsageService { request in direct.append(request); return response(request, 200, usage) }
            .fetch(.init(accessToken: "fixture-direct", expiresAt: nil, plan: nil), includeProfile: false, claudeVersion: "2.5.0")
        XCTAssertEqual(direct.values.map(\.agent), ["claude-cli/2.5.0 (external, cli)"])
        XCTAssertTrue(direct.values[0].url.hasSuffix("usage?cedar_ember=1"))

        let retried = Log()
        _ = try await ClaudeUsageService { request in
            retried.append(request)
            return request.url?.query == nil ? response(request, 200, usage) : response(request, 403, "forbidden")
        }.fetch(.init(accessToken: "fixture-retry", expiresAt: nil, plan: nil), includeProfile: false)
        XCTAssertEqual(retried.values.map(\.agent), ["claude-cli/2.1.0 (external, cli)", "claude-code/2.1.0"])
        XCTAssertTrue(retried.values[1].url.hasSuffix("/api/oauth/usage"))

        let scope = Log()
        do {
            _ = try await ClaudeUsageService { request in
                scope.append(request); return response(request, 403, #"{"error":"missing scope user:profile"}"#)
            }.fetch(.init(accessToken: "fixture-scope", expiresAt: nil, plan: nil), includeProfile: false)
            XCTFail("A missing scope must surface")
        } catch { XCTAssertEqual(error as? ClaudeSupportError, .server(403)) }
        XCTAssertEqual(scope.values.count, 1, "A real authorization answer is not retried")
    }
}

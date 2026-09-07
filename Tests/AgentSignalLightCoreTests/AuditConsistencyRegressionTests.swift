import Foundation
import XCTest
@testable import AgentSignalLight
@testable import AgentSignalLightCore

final class AuditConsistencyRegressionTests: XCTestCase {
    func testConcurrentStateWritesPreserveAllSessions() throws {
        try assertConcurrentStateWrites(multipleInstances: false)
    }

    func testConcurrentStateStoresShareProcessLock() throws {
        try assertConcurrentStateWrites(multipleInstances: true)
    }

    private func assertConcurrentStateWrites(multipleInstances: Bool) throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SignalStateStore(stateFileURL: root.appendingPathComponent("state.json"))
        _ = try store.clearSessions()
        DispatchQueue.concurrentPerform(iterations: 50) { index in
            let writer = multipleInstances ? SignalStateStore(stateFileURL: store.stateFileURL) : store
            do {
                _ = try writer.applySessionSignal(.working, sessionID: "fixture-\(index)", agent: "fixture")
                _ = writer.readSnapshot()
            } catch { XCTFail("Concurrent write failed: \(error)") }
        }
        XCTAssertEqual(Set(store.readSnapshot().sessions.map { $0.sessionID }),
                       Set((0..<50).map { "fixture-\($0)" }))
    }

    func testRemovalUsesInMemoryRefreshAndPersistsIt() throws {
        try assertRemovalUsesRefresh(clearMemory: false, keychainUnavailable: false)
    }

    func testRemovalUsesPersistedRefreshAfterRestart() throws {
        try assertRemovalUsesRefresh(clearMemory: true, keychainUnavailable: false)
    }

    func testRemovalWorksWhileNextAccountKeychainRemainsUnavailable() throws {
        try assertRemovalUsesRefresh(clearMemory: true, keychainUnavailable: true)
    }

    private func assertRemovalUsesRefresh(clearMemory: Bool, keychainUnavailable: Bool) throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let authRoot = root.appendingPathComponent("auth")
        try FileManager.default.createDirectory(at: authRoot, withIntermediateDirectories: true)
        let authURL = authRoot.appendingPathComponent("auth.json")
        let secrets = ConsistencySecrets()
        func manager() -> CodexAccountManager {
            CodexAccountManager(environment: ["CODEX_HOME": authRoot.path],
                storeURL: root.appendingPathComponent("accounts.json"),
                managedHomeRootURL: root.appendingPathComponent("managed"), credentialStore: secrets)
        }
        let initial = manager()
        let old = Data(#"{"OPENAI_API_KEY":"fixture-old"}"#.utf8)
        let fresh = Data(#"{"OPENAI_API_KEY":"fixture-fresh"}"#.utf8)
        try old.write(to: authURL)
        let next = try initial.saveCurrentAccount()
        defer { CodexActiveAuthFileCoordinator.clearRefreshedAuthData(replacingAuthFingerprint: next.authFingerprint) }
        secrets.unavailable = true
        try initial.persistRefreshedAuthData(fresh, replacingAuthFingerprint: next.authFingerprint)
        secrets.unavailable = false
        try Data(#"{"OPENAI_API_KEY":"fixture-active"}"#.utf8).write(to: authURL)
        let active = try initial.saveCurrentAccount()
        if clearMemory {
            CodexActiveAuthFileCoordinator.clearRefreshedAuthData(replacingAuthFingerprint: next.authFingerprint)
        }
        secrets.unavailable = keychainUnavailable
        let restarted = manager()
        try restarted.removeAccount(id: active.id)
        XCTAssertEqual(try Data(contentsOf: authURL), fresh)
        XCTAssertEqual(try restarted.loadState().savedAccounts.map { $0.id }, [next.id])
        let pending = root.appendingPathComponent("PendingCodexCredentialRefreshes")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: pending.path).isEmpty,
                       !keychainUnavailable)
        if !keychainUnavailable {
            XCTAssertEqual(secrets.values[try XCTUnwrap(next.credentialReference)], fresh)
        }
    }

    func testClaudeLargerReplacementDiscardsOldUsage() throws {
        try assertClaudeRewrite(atomic: true, sameSize: false)
    }

    func testClaudeInPlaceRewriteAndGrowthDiscardsOldUsage() throws {
        try assertClaudeRewrite(atomic: false, sameSize: false)
    }

    func testClaudeSameSizeRewriteWithRestoredMtimeIsNotSkipped() throws {
        try assertClaudeRewrite(atomic: false, sameSize: true)
    }

    private func assertClaudeRewrite(atomic: Bool, sameSize: Bool) throws {
        let fixture = try ClaudeConsistencyFixture()
        defer { fixture.remove() }
        try fixture.line("old", 100).write(to: fixture.file, atomically: true, encoding: .utf8)
        XCTAssertEqual(try fixture.scan().summary?.totalTokens, 100)
        let mtime = try fixture.file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
        let replacement = fixture.line("new", 200) + (sameSize ? "" : fixture.line("end", 300))
        try replacement.write(to: fixture.file, atomically: atomic, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: fixture.file.path)
        XCTAssertEqual(try fixture.scan().summary?.totalTokens, sameSize ? 200 : 500)
    }

    func testClaudeAppendAndPartialLineDoNotDuplicateUsage() throws {
        let fixture = try ClaudeConsistencyFixture()
        defer { fixture.remove() }
        let first = fixture.line("one", 100)
        let next = fixture.line("two", 200)
        try (first + String(next.prefix(40))).write(to: fixture.file, atomically: true, encoding: .utf8)
        XCTAssertEqual(try fixture.scan().summary?.totalTokens, 100)
        try fixture.append(String(next.dropFirst(40)))
        XCTAssertEqual(try fixture.scan().summary?.totalTokens, 300)
        XCTAssertEqual(try fixture.scan().summary?.totalTokens, 300)
        try fixture.append(fixture.line("two", 250)) // Same streamed message, updated cumulative usage.
        XCTAssertEqual(try fixture.scan().summary?.totalTokens, 350)
    }

    func testClaudeTruncationAndLegacyCacheRebuild() throws {
        let fixture = try ClaudeConsistencyFixture()
        defer { fixture.remove() }
        try (fixture.line("one", 100) + fixture.line("two", 200)).write(to: fixture.file, atomically: true, encoding: .utf8)
        XCTAssertEqual(try fixture.scan().summary?.totalTokens, 300)
        try fixture.line("one", 100).write(to: fixture.file, atomically: false, encoding: .utf8)
        XCTAssertEqual(try fixture.scan().summary?.totalTokens, 100)
        var cache = try CostUsageCacheIO.loadRequired(provider: .claude, cacheRoot: fixture.cacheRoot)
        for key in cache.files.keys {
            cache.files[key]?.sourceGeneration = nil
            cache.files[key]?.sourceStatFingerprint = nil
            cache.files[key]?.committedPrefixFingerprint = nil
            cache.files[key]?.claudeRows = []
        }
        try CostUsageCacheIO.save(provider: .claude, cache: cache, cacheRoot: fixture.cacheRoot)
        XCTAssertEqual(try fixture.scan().summary?.totalTokens, 100)
    }

    func testClaudeRewriteDuringScanDoesNotCommitCache() throws {
        let fixture = try ClaudeConsistencyFixture()
        defer { fixture.remove() }
        try fixture.line("one", 100).write(to: fixture.file, atomically: true, encoding: .utf8)
        XCTAssertEqual(try fixture.scan().summary?.totalTokens, 100)
        let cacheURL = CostUsageCacheIO.cacheFileURL(provider: .claude, cacheRoot: fixture.cacheRoot)
        let previous = try Data(contentsOf: cacheURL)
        try fixture.append(fixture.line("two", 200))
        XCTAssertThrowsError(try fixture.scan { url in
            do { try fixture.line("new", 900).write(to: url, atomically: true, encoding: .utf8) }
            catch { XCTFail("Fixture mutation failed: \(error)") }
        })
        XCTAssertEqual(try Data(contentsOf: cacheURL), previous)
        XCTAssertEqual(try fixture.scan().summary?.totalTokens, 900)
    }

    func testClaudeAppendDuringScanIsDeferredToNextScan() throws {
        let fixture = try ClaudeConsistencyFixture()
        defer { fixture.remove() }
        try fixture.line("one", 100).write(to: fixture.file, atomically: true, encoding: .utf8)
        XCTAssertEqual(try fixture.scan { _ in
            do { try fixture.append(fixture.line("two", 200)) }
            catch { XCTFail("Fixture append failed: \(error)") }
        }.summary?.totalTokens, 100)
        XCTAssertEqual(try fixture.scan().summary?.totalTokens, 300)
    }

    func testClaudeSnapshotPreservesSubagentAttribution() throws {
        let fixture = try ClaudeConsistencyFixture(subagent: true)
        defer { fixture.remove() }
        try fixture.line("one", 100).write(to: fixture.file, atomically: true, encoding: .utf8)
        XCTAssertEqual(try fixture.scan().summary?.totalTokens, 100)
        let cache = try CostUsageCacheIO.loadRequired(provider: .claude, cacheRoot: fixture.cacheRoot)
        XCTAssertEqual(cache.files.values.first?.claudeRows?.first?.pathRole, .subagent)
    }
}

private func temporaryRoot() -> URL {
    URL(fileURLWithPath: "/private/tmp").appendingPathComponent("signal-consistency-\(UUID().uuidString)")
}

private final class ClaudeConsistencyFixture {
    let root = temporaryRoot()
    let now = Date(timeIntervalSince1970: 1_788_840_000)
    let logs: URL
    let file: URL
    let cacheRoot: URL
    private var scans = 0

    init(subagent: Bool = false) throws {
        logs = root.appendingPathComponent("projects")
        file = logs.appendingPathComponent(subagent ? "session/subagents/agent-fixture.jsonl" : "session.jsonl")
        cacheRoot = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
    func line(_ id: String, _ tokens: Int) -> String {
        let timestamp = ISO8601DateFormatter().string(from: now)
        return "{\"type\":\"assistant\",\"timestamp\":\"\(timestamp)\",\"sessionId\":\"fixture\",\"requestId\":\"\(id)\",\"message\":{\"id\":\"\(id)\",\"model\":\"claude-sonnet-4-5-20250929\",\"usage\":{\"input_tokens\":\(tokens),\"output_tokens\":0}}}\n"
    }
    func append(_ text: String) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }
    func scan(beforeValidation: ((URL) -> Void)? = nil) throws -> CostUsageDailyReport {
        scans += 1
        var options = CostUsageScanner.Options(claudeProjectsRoots: [logs], cacheRoot: cacheRoot)
        options.refreshMinIntervalSeconds = 0
        options.claudeFileBeforeSnapshotValidationHook = beforeValidation
        let time = now.addingTimeInterval(Double(scans))
        return try CostUsageScanner.loadDailyReportCancellable(provider: .claude,
            since: now.addingTimeInterval(-86400), until: time, now: time,
            options: options, checkCancellation: {})
    }
}

private final class ConsistencySecrets: SecretStoring, @unchecked Sendable {
    var values: [String: Data] = [:]
    var unavailable = false
    func data(for key: String) throws -> Data? {
        if unavailable { throw CocoaError(.fileReadNoPermission) }
        return values[key]
    }
    func string(for key: String) throws -> String? { try data(for: key).flatMap { String(data: $0, encoding: .utf8) } }
    func set(_ data: Data, for key: String) throws {
        if unavailable { throw CocoaError(.fileWriteNoPermission) }
        values[key] = data
    }
    func set(_ string: String, for key: String) throws { try set(Data(string.utf8), for: key) }
    func delete(key: String) throws { values.removeValue(forKey: key) }
}

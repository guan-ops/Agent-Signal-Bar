import Darwin
import Foundation
import XCTest
@testable import AgentSignalLight

final class AuditFailureRecoveryTests: XCTestCase {
    private func temporaryRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("audit-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testCostCachesRejectDifferentAndMissingDayContexts() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let current = CostUsageDayContext.current
        let differentZone = CostUsageDayContext(
            calendarIdentifier: current.calendarIdentifier,
            timeZoneIdentifier: current.timeZoneIdentifier == "UTC" ? "Pacific/Auckland" : "UTC")
        let differentCalendar = CostUsageDayContext(
            calendarIdentifier: "different-calendar", timeZoneIdentifier: current.timeZoneIdentifier)

        for context in [current, differentZone, differentCalendar, nil] as [CostUsageDayContext?] {
            for provider in [UsageProvider.codex, .claude] {
                var cache = CostUsageCache()
                cache.dayContext = context
                cache.days = ["2026-09-05": ["fixture": [10, 0, 2]]]
                try CostUsageCacheIO.save(provider: provider, cache: cache, cacheRoot: root)
                let loaded = CostUsageCacheIO.load(provider: provider, cacheRoot: root)
                XCTAssertEqual(loaded.days.isEmpty, context != current)
            }
            var pi = PiSessionCostCache()
            pi.dayContext = context
            pi.lastScanUnixMs = 123
            try PiSessionCostCacheIO.save(cache: pi, cacheRoot: root)
            XCTAssertEqual(PiSessionCostCacheIO.load(cacheRoot: root).lastScanUnixMs,
                           context == current ? 123 : 0)
        }
    }

    func testOrdinaryScanRebuildsBucketsFromAnotherTimeZone() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions")
        let cacheRoot = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let data = Data([
            #"{"timestamp":"2026-09-05T08:00:00Z","type":"session_meta","payload":{"id":"timezone-fixture"}}"#,
            #"{"timestamp":"2026-09-05T08:00:01Z","type":"turn_context","payload":{"model":"gpt-5"}}"#,
            #"{"timestamp":"2026-09-05T08:00:02Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"output_tokens":100},"last_token_usage":{"input_tokens":1000,"output_tokens":100}}}}"#,
        ].joined(separator: "\n").utf8)
        let file = sessions.appendingPathComponent("rollout-timezone.jsonl")
        try data.write(to: file)
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-05T08:05:00Z"))
        let since = Calendar.current.startOfDay(for: now)
        let options = CostUsageScanner.Options(
            codexSessionsRoot: sessions, cacheRoot: cacheRoot,
            codexTraceDatabaseURL: root.appendingPathComponent("absent.sqlite"))
        let first = CostUsageScanner.loadDailyReport(
            provider: .codex, since: since, until: now, now: now, options: options)
        XCTAssertEqual(first.data.first?.totalTokens, 1100)
        var cache = try CostUsageCacheIO.loadRequired(provider: .codex, cacheRoot: cacheRoot)
        cache.dayContext = CostUsageDayContext(calendarIdentifier: "gregorian", timeZoneIdentifier: "old-zone")
        cache.days = ["1900-01-01": ["gpt-5": [1000, 0, 100]]]
        try CostUsageCacheIO.save(provider: .codex, cache: cache, cacheRoot: cacheRoot)
        let rebuilt = CostUsageScanner.loadDailyReport(
            provider: .codex, since: since, until: now, now: now, options: options)
        XCTAssertEqual(rebuilt.data.first?.totalTokens, 1100)
        XCTAssertEqual(rebuilt.data.first?.date, first.data.first?.date)
        XCTAssertEqual(try Data(contentsOf: file), data)
        XCTAssertEqual(try CostUsageCacheIO.loadRequired(provider: .codex, cacheRoot: cacheRoot).dayContext, .current)
    }

    func testRemovingActiveAccountRollsBackWhenAuthRemovalFails() throws {
        try assertRemovalRollback(hasNextAccount: false)
    }

    func testRemovingActiveAccountRollsBackWhenAuthReplacementFails() throws {
        try assertRemovalRollback(hasNextAccount: true)
    }

    private func assertRemovalRollback(hasNextAccount: Bool) throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let authRoot = root.appendingPathComponent("auth")
        try FileManager.default.createDirectory(at: authRoot, withIntermediateDirectories: true)
        let authURL = authRoot.appendingPathComponent("auth.json")
        let files = RecoveryFileManager()
        let secrets = RecoverySecretStore()
        let manager = CodexAccountManager(
            environment: ["CODEX_HOME": authRoot.path], fileManager: files,
            storeURL: root.appendingPathComponent("accounts.json"),
            managedHomeRootURL: root.appendingPathComponent("managed"), credentialStore: secrets)
        if hasNextAccount {
            try Data(#"{"OPENAI_API_KEY":"fixture-next"}"#.utf8).write(to: authURL)
            _ = try manager.saveCurrentAccount()
        }
        let original = Data(#"{"OPENAI_API_KEY":"fixture-current"}"#.utf8)
        try original.write(to: authURL)
        let active = try manager.saveCurrentAccount()
        let before = try manager.loadState().savedAccounts
        if hasNextAccount { files.failingDirectory = authRoot }
        else { files.failingRemoval = authURL }
        XCTAssertThrowsError(try manager.removeAccount(id: active.id))
        XCTAssertEqual(try manager.loadState().savedAccounts, before)
        XCTAssertEqual(try manager.loadState().activeSavedAccountID, active.id)
        XCTAssertEqual(try Data(contentsOf: authURL), original)
        XCTAssertTrue(secrets.deletedKeys.isEmpty)
        files.failingDirectory = nil
        files.failingRemoval = nil
        try manager.removeAccount(id: active.id)
        XCTAssertFalse(try manager.loadState().savedAccounts.contains { $0.id == active.id })
    }

    func testManagedLoginCleansCredentialsWhenKeychainSaveFails() async throws {
        try await assertManagedLoginCleanup(failKeychain: true, failMetadata: false, invalidJSON: false)
    }

    func testManagedLoginCleansCredentialsWhenMetadataSaveFails() async throws {
        try await assertManagedLoginCleanup(failKeychain: false, failMetadata: true, invalidJSON: false)
    }

    func testManagedLoginCleansCredentialsWhenIdentityParsingFails() async throws {
        try await assertManagedLoginCleanup(failKeychain: false, failMetadata: false, invalidJSON: true)
    }

    private func assertManagedLoginCleanup(
        failKeychain: Bool, failMetadata: Bool, invalidJSON: Bool
    ) async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let managed = root.appendingPathComponent("managed")
        let storeDirectory = root.appendingPathComponent("metadata")
        let store = storeDirectory.appendingPathComponent("accounts.json")
        let files = RecoveryFileManager()
        if failMetadata { files.failingDirectory = storeDirectory }
        let secrets = RecoverySecretStore()
        secrets.failsSet = failKeychain
        let manager = CodexAccountManager(
            environment: ["CODEX_HOME": root.appendingPathComponent("active").path],
            fileManager: files, storeURL: store, managedHomeRootURL: managed,
            loginRunner: RecoveryLoginRunner(data: Data(
                (invalidJSON ? "invalid JSON" : #"{"OPENAI_API_KEY":"fixture-login"}"#).utf8)),
            credentialStore: secrets)
        do {
            _ = try await manager.authenticateManagedAccount()
            XCTFail("Expected injected save/parse failure")
        } catch {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: managed.path), [])
    }

    func testTerminationEscalatesForChildIgnoringSIGTERM() throws {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // One process, no child tree. Signal readiness after installing the trap.
        process.arguments = ["-c", "trap '' TERM; printf ready; while :; do :; done"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        }
        XCTAssertEqual(String(data: output.fileHandleForReading.availableData, encoding: .utf8), "ready")
        let start = ProcessInfo.processInfo.systemUptime
        BoundedProcessTermination.terminate(process, gracePeriod: 0.1)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2)
        XCTAssertFalse(process.isRunning)
        if !process.isRunning { XCTAssertEqual(process.terminationStatus, SIGKILL) }
    }
}

private enum RecoveryInjectedError: Error { case failure }

private final class RecoveryFileManager: FileManager, @unchecked Sendable {
    var failingRemoval: URL?
    var failingDirectory: URL?
    override func removeItem(at URL: URL) throws {
        if URL.standardizedFileURL.path == failingRemoval?.standardizedFileURL.path {
            throw RecoveryInjectedError.failure
        }
        try super.removeItem(at: URL)
    }
    override func createDirectory(
        at url: URL, withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]? = nil
    ) throws {
        if url.standardizedFileURL.path == failingDirectory?.standardizedFileURL.path {
            throw RecoveryInjectedError.failure
        }
        try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
    }
}

private final class RecoverySecretStore: SecretStoring, @unchecked Sendable {
    var values: [String: Data] = [:]
    var deletedKeys: [String] = []
    var failsSet = false
    func data(for key: String) throws -> Data? { values[key] }
    func string(for key: String) throws -> String? { values[key].flatMap { String(data: $0, encoding: .utf8) } }
    func set(_ data: Data, for key: String) throws {
        if failsSet { throw RecoveryInjectedError.failure }
        values[key] = data
    }
    func set(_ string: String, for key: String) throws { try set(Data(string.utf8), for: key) }
    func delete(key: String) throws { deletedKeys.append(key); values.removeValue(forKey: key) }
}

private struct RecoveryLoginRunner: CodexAccountLoginRunning {
    let data: Data
    func run(homePath: String, timeout: TimeInterval, environment: [String: String]) async -> CodexAccountLoginResult {
        do {
            try data.write(to: URL(fileURLWithPath: homePath).appendingPathComponent("auth.json"))
            return CodexAccountLoginResult(outcome: .success, output: "")
        } catch {
            return CodexAccountLoginResult(outcome: .failed(status: 1), output: "")
        }
    }
}

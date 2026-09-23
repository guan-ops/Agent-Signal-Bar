import Foundation
import XCTest
import AgentSignalLightCore
@testable import AgentSignalLight

@MainActor
final class ClaudeHistoryIntegrationTests: XCTestCase {
    func testCancellationAfterParsingPreservesCacheAndRetryCountsEachRowOnce() async throws {
        let fixture = try ClaudeHistoryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        XCTAssertEqual(try fixture.scan().summary?.totalTokens, 100)
        let previousCache = try Data(contentsOf: fixture.cacheFile)
        try fixture.append(id: "second", tokens: 200)

        let suite = "claude-real-history-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let parsed = expectation(description: "real log parsed before cache commit")
        let cancelled = expectation(description: "scanner propagated cancellation")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let model = ClaudeSupportModel(defaults: defaults, historyLoader: { check in
            do {
                return try fixture.scan(check: check, afterParsing: {
                    parsed.fulfill()
                    _ = release.wait(timeout: .now() + 5)
                })
            } catch is CancellationError {
                cancelled.fulfill()
                throw CancellationError()
            }
        })
        model.refresh(force: true)
        await fulfillment(of: [parsed], timeout: 3)
        model.resetIdentity()
        release.signal()
        await fulfillment(of: [cancelled], timeout: 3)
        XCTAssertEqual(try Data(contentsOf: fixture.cacheFile), previousCache)
        XCTAssertNil(model.historyUpdatedAt)
        XCTAssertNil(model.historyIssue)
        XCTAssertFalse(model.isHistoryScanning)

        let retry = ClaudeSupportModel(defaults: defaults, historyLoader: { try fixture.scan(check: $0) })
        retry.refresh(force: true)
        for _ in 0..<300 where retry.isRefreshing { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(retry.isRefreshing)
        XCTAssertNil(retry.historyIssue)
        XCTAssertEqual(retry.days.compactMap(\.totalTokens).reduce(0, +), 300)
        XCTAssertEqual(try fixture.scan().summary?.totalTokens, 300)
        XCTAssertNotEqual(try Data(contentsOf: fixture.cacheFile), previousCache)
    }

    func testQueuedRefreshCancelledBeforeAdmissionNeverReadsOrWritesHistory() async throws {
        let fixture = try ClaudeHistoryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let occupied = expectation(description: "serial executor occupied")
        let unexpected = expectation(description: "cancelled queued loader must not run")
        unexpected.isInverted = true
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let blocker = Task {
            try await CostUsageScanExecutor.run { _ in
                occupied.fulfill()
                _ = release.wait(timeout: .now() + 5)
            }
        }
        await fulfillment(of: [occupied], timeout: 2)
        let suite = "claude-queued-history-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = ClaudeSupportModel(defaults: defaults, historyLoader: { check in
            unexpected.fulfill()
            return try fixture.scan(check: check)
        })
        model.refresh(force: true)
        for _ in 0..<100 where !model.isHistoryScanning { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(model.isHistoryScanning)
        model.resetIdentity()
        release.signal()
        try await blocker.value
        await fulfillment(of: [unexpected], timeout: 0.15)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.cacheFile.path))
        XCTAssertFalse(model.isRefreshing)
        XCTAssertFalse(model.isHistoryScanning)
        XCTAssertNil(model.historyUpdatedAt)
    }

    func testHistoryAdapterForwardsCancellationToTheRealScanner() throws {
        let fixture = try ClaudeHistoryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        XCTAssertThrowsError(try ClaudeSupportModel.scanHistory(
            roots: [fixture.logs], cacheRoot: fixture.cacheRoot, now: fixture.now,
            checkCancellation: { throw CancellationError() }
        )) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.cacheFile.path))
    }
}

private struct ClaudeHistoryFixture: Sendable {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("claude-integration-\(UUID())")
    let now = Date(timeIntervalSince1970: 1_788_840_000)
    var logs: URL { root.appendingPathComponent("projects") }
    var file: URL { logs.appendingPathComponent("session.jsonl") }
    var cacheRoot: URL { root.appendingPathComponent("cache") }
    var cacheFile: URL { CostUsageCacheIO.cacheFileURL(provider: .claude, cacheRoot: cacheRoot) }

    init() throws {
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try Data().write(to: file)
        try append(id: "first", tokens: 100)
    }

    func append(id: String, tokens: Int) throws {
        let timestamp = ISO8601DateFormatter().string(from: now)
        let row = "{\"type\":\"assistant\",\"timestamp\":\"\(timestamp)\",\"sessionId\":\"fixture\",\"requestId\":\"\(id)\",\"message\":{\"id\":\"\(id)\",\"model\":\"claude-sonnet-4-5-20250929\",\"usage\":{\"input_tokens\":\(tokens),\"output_tokens\":0}}}\n"
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(row.utf8))
    }

    func scan(check: @escaping @Sendable () throws -> Void = {}, afterParsing: (() -> Void)? = nil) throws -> CostUsageDailyReport {
        var options = CostUsageScanner.Options(claudeProjectsRoots: [logs], cacheRoot: cacheRoot)
        options.refreshMinIntervalSeconds = 0
        options.claudeFileBeforeSnapshotValidationHook = { _ in afterParsing?() }
        return try CostUsageScanner.loadDailyReportCancellable(provider: .claude,
            since: now.addingTimeInterval(-86400), until: now, now: now,
            options: options, checkCancellation: check)
    }
}

final class DiagnosticsExportIntegrationTests: XCTestCase {
    func testPackagingFailureReachesManagerAsFailureWithoutSuccessURL() throws {
        let fixture = try DiagnosticsFixture(validSource: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        XCTAssertThrowsError(try fixture.manager.export()) { error in
            guard case DiagnosticsExportError.commandFailed(let result) = error else {
                return XCTFail("Expected packaging failure, got \(error)")
            }
            XCTAssertNotEqual(result.exitCode, 0)
            XCTAssertNil(result.archiveURL)
            XCTAssertTrue(error.localizedDescription.contains("failed to create diagnostics archive"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.archive.path))
    }

    func testSuccessfulPackagingReturnsAValidatedArchiveToManager() throws {
        let fixture = try DiagnosticsFixture(validSource: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let result = try fixture.manager.export()
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.archiveURL, fixture.archive)
        let unzip = Process()
        let pipe = Pipe()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-p", fixture.archive.path, "fixture/note.txt"]
        unzip.standardOutput = pipe
        try unzip.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        unzip.waitUntilExit()
        XCTAssertEqual(unzip.terminationStatus, 0)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "synthetic diagnostics")
    }

    @MainActor
    func testPackagingFailureClearsAppProgressAndPublishesError() async throws {
        let fixture = try DiagnosticsFixture(validSource: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let suite = "diagnostics-app-integration-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("off", forKey: "codexOpenAICookieMode")
        let root = fixture.root
        let model = MenuBarStatusModel(
            store: SignalStateStore(stateFileURL: root.appendingPathComponent("state/status.json")),
            userDefaults: defaults, startsMonitoring: false,
            diagnosticsExportManager: fixture.manager,
            codexAccountManager: CodexAccountManager(
                environment: ["CODEX_HOME": root.appendingPathComponent("codex").path],
                storeURL: root.appendingPathComponent("accounts.json"),
                managedHomeRootURL: root.appendingPathComponent("managed")),
            codexUsageSnapshotStore: CodexAccountUsageSnapshotStore(fileURL: root.appendingPathComponent("usage.json")),
            codexTokenActivityScanner: CodexTokenActivityScanner(sessionRootURLs: [],
                cacheURL: root.appendingPathComponent("token.json"), costUsageCacheRootURL: root.appendingPathComponent("cost")),
            performsAccountSwitchBackgroundRefreshes: false)
        model.exportDiagnostics()
        XCTAssertTrue(model.isDiagnosticsExportRunning)
        for _ in 0..<300 where model.isDiagnosticsExportRunning { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.isDiagnosticsExportRunning)
        XCTAssertNil(model.diagnosticsExportMessage)
        XCTAssertTrue(model.lastError?.contains("failed to create diagnostics archive") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.archive.path))
    }
}

private struct DiagnosticsFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("diagnostics-integration-\(UUID())")
    var output: URL { root.appendingPathComponent("output with spaces") }
    var archive: URL { output.appendingPathComponent("fixture.zip") }
    var manager: DiagnosticsExportManager { .init(diagnosticsRootURL: root, outputDirectoryURL: output) }

    init(validSource: Bool) throws {
        let scripts = root.appendingPathComponent("script")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        if validSource {
            try FileManager.default.createDirectory(at: output.appendingPathComponent("fixture"), withIntermediateDirectories: true)
            try Data("synthetic diagnostics".utf8).write(to: output.appendingPathComponent("fixture/note.txt"))
        }
        // Use the production packaging commands while excluding real diagnostic collection.
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let production = try String(contentsOf: repo.appendingPathComponent("script/export_diagnostics.sh"), encoding: .utf8)
        let boundary = try XCTUnwrap(production.range(of: "\nrm -f \"$ARCHIVE\""))
        let preamble = """
        #!/bin/bash
        set -u
        [[ "$1" == "--output" ]] || exit 2
        OUTPUT_ROOT="$2"
        RUN_ID="fixture"
        WORK_DIR="$OUTPUT_ROOT/$RUN_ID"
        ARCHIVE="$OUTPUT_ROOT/fixture.zip"

        """
        let script = scripts.appendingPathComponent("export_diagnostics.sh")
        try (preamble + production[boundary.lowerBound...]).write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    }
}

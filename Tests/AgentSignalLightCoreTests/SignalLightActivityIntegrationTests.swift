import Foundation
import XCTest
import AgentSignalLightCore
@testable import AgentSignalLight

/// Exercises live input, persistence and both lamp snapshots without starting
/// the user's app or reading its accounts, usage caches or hook configuration.
@MainActor
final class SignalLightActivityIntegrationTests: XCTestCase {
    func testCloudClaudeUIUpdatesBothLightsWithoutWritingHookState() throws {
        let fixture = try ActivityIntegrationFixture()
        defer { fixture.cleanUp() }
        _ = try fixture.store.applySessionSignal(.idle, sessionID: "fixture", agent: "claude-code")
        let model = fixture.makeModel()
        let before = try Data(contentsOf: fixture.store.stateFileURL)
        model.isClaudeUIStatusMonitoringEnabled = true
        model.selectSignalLightProvider(.claude)
        model.acceptDesktopPresence([], claudeUI: .working)
        XCTAssertEqual(model.statusBarLightSnapshot.aggregate, .working)
        XCTAssertEqual(model.floatingSignalLightSnapshot.aggregate, .working)
        XCTAssertEqual(ActivityPresentation.visibleRunningSessions(from: model.activitySnapshot).count, 1)
        model.acceptDesktopPresence([], claudeUI: .notResponding)
        XCTAssertEqual(model.statusBarLightSnapshot.aggregate, .idle)
        XCTAssertEqual(model.floatingSignalLightSnapshot.aggregate, .idle)
        XCTAssertEqual(try Data(contentsOf: fixture.store.stateFileURL), before)
    }

    func testCloudClaudeDoesNotOverrideManualCodexOrDisabledMonitoring() throws {
        let fixture = try ActivityIntegrationFixture()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        XCTAssertFalse(model.isClaudeUIStatusMonitoringEnabled)
        model.acceptDesktopPresence([], claudeUI: .working)
        XCTAssertTrue(model.desktopAppSessions.isEmpty)
        model.isClaudeUIStatusMonitoringEnabled = true
        model.selectSignalLightProvider(.codex)
        model.acceptDesktopPresence([], claudeUI: .working)
        XCTAssertEqual(model.selectedSignalLightProvider, .codex)
        // Codex is idle, so by default the lamp borrows Claude; the selection stays Codex.
        XCTAssertEqual(model.signalLightIdleFallbackScope, .claudeCode)
        XCTAssertEqual(model.statusBarLightSnapshot.aggregate, .working)
        model.setSignalLightIdleFallbackEnabled(false)
        XCTAssertEqual(model.statusBarLightSnapshot.aggregate, .idle)
        XCTAssertEqual(model.selectedSignalLightProvider, .codex)
        XCTAssertTrue(model.activitySnapshot.sessions.contains { $0.agent == "claude-desktop" })
        model.isClaudeDesktopMonitoringEnabled = false
        model.acceptDesktopPresence([], claudeUI: .working)
        XCTAssertTrue(model.desktopAppSessions.isEmpty)
    }

    func testNewHookTaskInSameSecondAsCompletionRemainsVisibleForBothProviders() throws {
        let cases: [([(AgentSignal, String)], AgentSignal)] = [
            ([(.done, "Stop"), (.thinking, "UserPromptSubmit")], .thinking),
            ([(.done, "Stop"), (.thinking, "UserPromptSubmit"), (.working, "PreToolUse")], .working),
            ([(.thinking, "UserPromptSubmit"), (.done, "Stop")], .done),
            ([(.done, "Stop"), (.thinking, "DesktopActivityHeartbeat")], .done)
        ]
        for provider in SignalLightProvider.allCases {
            for (events, expected) in cases {
                let fixture = try ActivityIntegrationFixture()
                defer { fixture.cleanUp() }
                let timestamp = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
                let agent = provider == .claude ? "claude-code" : "codex-cli"
                for (signal, event) in events {
                    _ = try fixture.store.applySessionSignal(signal, sessionID: "fixture", agent: agent,
                        lastEvent: event, updatedAt: timestamp)
                }
                let model = fixture.makeModel()
                XCTAssertEqual(model.selectedSignalLightProvider, provider)
                XCTAssertEqual(model.statusBarLightSnapshot.aggregate, expected)
                XCTAssertEqual(model.floatingSignalLightSnapshot.aggregate, expected)
            }
        }
    }

    func testDesktopLogUpdatesBothLightsAndStartsAnotherTurnAfterCompletion() async throws {
        try await checkCodexLog(source: "desktop", originator: "Codex Desktop", agent: "codex-desktop")
    }

    func testWorkDesktopWithSharedVSCodeSourceReachesDesktopLights() async throws {
        try await checkCodexLog(source: "vscode", originator: "codex_work_desktop", agent: "codex-desktop")
    }

    func testCLILogUpdatesBothLightsAndStartsAnotherTurnAfterCompletion() async throws {
        try await checkCodexLog(source: "cli", originator: "codex_cli_rs", agent: "codex-cli")
    }

    func testLogDirectoryCreatedAfterMonitoringStartsIsDiscovered() async throws {
        let fixture = try ActivityIntegrationFixture()
        defer { fixture.cleanUp() }
        // Prime the monitor before Codex has ever created its sessions directory.
        XCTAssertTrue(fixture.monitor.poll().isEmpty)
        let model = fixture.makeModel()
        try fixture.createLog(source: "desktop", originator: "Codex Desktop")
        try fixture.append(type: "event_msg", payload: ["type": "task_started"])
        model.pollCodexDesktopActivity()
        try await expectLights(.thinking, in: model)
    }

    func testCodexAndClaudeHooksReachBothLightsThroughTheFileWatcher() async throws {
        for provider in SignalLightProvider.allCases {
            let fixture = try ActivityIntegrationFixture()
            defer { fixture.cleanUp() }
            let model = fixture.makeModel()
            model.selectSignalLightProvider(provider)
            let watcher = StateFileWatcher(stateFileURL: fixture.store.stateFileURL) {
                model.reloadFromWatcher()
            }
            watcher.start()
            defer { watcher.stop() }

            let events: [(String, AgentSignal)] = [
                ("UserPromptSubmit", .thinking), ("PreToolUse", .working),
                ("PermissionRequest", .permission), ("Stop", .done)
            ]
            for (event, expected) in events {
                let payload: [String: Any] = ["hook_event_name": event, "session_id": "fixture"]
                let signal = provider == .codex
                    ? CodexHookAdapter.chooseSignal(eventName: nil, payload: payload)
                    : ClaudeHookAdapter.chooseSignal(eventName: nil, payload: payload)
                _ = try fixture.store.applySessionSignal(signal, sessionID: "fixture",
                    agent: provider == .codex ? "codex-cli" : "claude-code", lastEvent: event)
                try await expectLights(expected, in: model)
            }
        }
    }

    func testResumeLoadsHookEventsReceivedWhilePaused() async throws {
        let fixture = try ActivityIntegrationFixture()
        defer { fixture.cleanUp() }
        _ = try fixture.store.applySessionSignal(.working, sessionID: "fixture",
            agent: "claude-code", lastEvent: "PreToolUse")
        let model = fixture.makeModel()
        // This case concerns hook reloads; keep unrelated Codex polling disabled.
        model.isCodexDesktopMonitoringEnabled = false
        model.setMonitoringPaused(true)
        model.clearDebugLight() // Finish the transition preview without a real animation timer.
        XCTAssertEqual(model.statusBarLightSnapshot.aggregate, .off)
        XCTAssertEqual(model.floatingSignalLightSnapshot.aggregate, .off)

        _ = try fixture.store.applySessionSignal(.done, sessionID: "fixture",
            agent: "claude-code", lastEvent: "Stop")
        model.reloadFromWatcher()
        XCTAssertEqual(model.snapshot.aggregate, .working)
        model.setMonitoringPaused(false)
        model.clearDebugLight()
        try await expectLights(.done, in: model)
    }

    func testEnablingCodexMonitoringLoadsAnAlreadyRunningTask() async throws {
        let fixture = try ActivityIntegrationFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(false, forKey: "isCodexDesktopMonitoringEnabled")
        try fixture.createLog(source: "desktop", originator: "Codex Desktop")
        try fixture.append(type: "response_item", payload: ["type": "function_call", "name": "exec_command"])
        let model = fixture.makeModel()
        model.pollCodexDesktopActivity()
        XCTAssertEqual(model.statusBarLightSnapshot.aggregate, .idle)
        model.setCodexDesktopMonitoringEnabled(true)
        try await expectLights(.working, in: model)
    }

    func testSelectedActivityDirectoryCannotAssignUnownedQuotaToTheCurrentAccount() async throws {
        let fixture = try ActivityIntegrationFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(fixture.root.path, forKey: CodexDataPaths.preferenceKey)
        try fixture.createLog(source: "desktop", originator: "Codex Desktop")
        try fixture.append(type: "event_msg", payload: ["type": "task_started"])
        try fixture.append(type: "event_msg", payload: [
            "type": "token_count",
            "rate_limits": ["primary": ["used_percent": 50, "window_minutes": 300,
                "resets_at": Int(Date().addingTimeInterval(3600).timeIntervalSince1970)]]
        ])
        let observed = CodexDesktopActivityMonitor(sessionsRootURL: fixture.sessions,
            vsCodeLogRootURL: fixture.root.appendingPathComponent("no-vscode"), replaysInitialHistory: true).pollResult()
        XCTAssertEqual(observed.quotaUpdates.first?.quota.windowMinutes, 300)
        let model = fixture.makeModel()
        model.pollCodexDesktopActivity()
        try await expectLights(.thinking, in: model)
        XCTAssertNil(model.latestAgentQuota)
        XCTAssertTrue(fixture.store.readSnapshot().sessions.allSatisfy { $0.quota == nil })
    }

    private func checkCodexLog(source: String, originator: String, agent: String) async throws {
        let fixture = try ActivityIntegrationFixture()
        defer { fixture.cleanUp() }
        try fixture.createLog(source: source, originator: originator)
        let model = fixture.makeModel()
        let steps: [(String, [String: Any], AgentSignal)] = [
            ("event_msg", ["type": "task_started"], .thinking),
            ("response_item", ["type": "function_call", "name": "exec_command"], .working),
            ("event_msg", ["type": "task_complete"], .done),
            ("event_msg", ["type": "task_started"], .thinking)
        ]
        for (type, payload, expected) in steps {
            try fixture.append(type: type, payload: payload)
            model.pollCodexDesktopActivity()
            try await expectLights(expected, in: model)
            XCTAssertEqual(model.displaySnapshot.sessions.first?.agent, agent)
        }
    }

    private func expectLights(_ signal: AgentSignal, in model: MenuBarStatusModel,
                              file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 {
            if model.statusBarLightSnapshot.aggregate == signal,
               model.floatingSignalLightSnapshot.aggregate == signal { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.statusBarLightSnapshot.aggregate, signal, file: file, line: line)
        XCTAssertEqual(model.floatingSignalLightSnapshot.aggregate, signal, file: file, line: line)
    }
}

@MainActor
private struct ActivityIntegrationFixture {
    let root: URL
    let suite: String
    let defaults: UserDefaults
    let store: SignalStateStore
    let monitor: CodexDesktopActivityMonitor
    var sessions: URL { root.appendingPathComponent("sessions") }
    var log: URL { sessions.appendingPathComponent("rollout-fixture.jsonl") }

    init() throws {
        root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("signal-activity-integration-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "signal-activity-integration-\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        defaults.set("off", forKey: "codexOpenAICookieMode")
        defaults.set(false, forKey: "isFloatingSignalSoundEnabled")
        defaults.set(false, forKey: "isDebugFileLoggingEnabled")
        store = SignalStateStore(stateFileURL: root.appendingPathComponent("state/status.json"))
        monitor = CodexDesktopActivityMonitor(sessionRootURLs: [root.appendingPathComponent("sessions")],
            vsCodeLogRootURL: root.appendingPathComponent("vscode-logs"), fullScanInterval: 0,
            replaysInitialHistory: true)
    }

    func makeModel() -> MenuBarStatusModel {
        MenuBarStatusModel(store: store, userDefaults: defaults, startsMonitoring: false,
            codexDesktopActivityMonitor: monitor,
            codexAccountManager: ActivityIntegrationAccounts(),
            codexUsageSnapshotStore: CodexAccountUsageSnapshotStore(fileURL: root.appendingPathComponent("usage.json")),
            codexCLIStatusProbe: ActivityIntegrationCLIProbe(),
            codexRPCStatusProbe: ActivityIntegrationRPCProbe(),
            codexServiceStatusFetcher: ActivityIntegrationServiceStatus(),
            codexRateLimitFetcher: CodexRateLimitFetcher(environment: ["CODEX_HOME": root.path],
                browserCookieImporter: ActivityIntegrationCookies()),
            codexTokenActivityScanner: CodexTokenActivityScanner(sessionRootURLs: [],
                cacheURL: root.appendingPathComponent("tokens.json"), costUsageCacheRootURL: root.appendingPathComponent("cost")),
            performsAccountSwitchBackgroundRefreshes: false)
    }

    func createLog(source: String, originator: String) throws {
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try Data().write(to: log)
        try append(type: "session_meta", payload: ["id": "fixture", "source": source, "originator": originator])
    }

    func append(type: String, payload: [String: Any]) throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var data = try JSONSerialization.data(withJSONObject: [
            "timestamp": formatter.string(from: Date()), "type": type, "payload": payload
        ])
        data.append(0x0a)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

private final class ActivityIntegrationAccounts: CodexAccountManaging, @unchecked Sendable {
    func loadState() throws -> CodexAccountState { .init(currentAccount: nil, savedAccounts: [], activeSavedAccountID: nil) }
    func saveCurrentAccount(label: String?) throws -> CodexAccountProfile { throw CodexAccountManagerError.accountNotFound }
    func switchToAccount(id: UUID) throws -> CodexAccountProfile { throw CodexAccountManagerError.accountNotFound }
    func authenticateManagedAccount(timeout: TimeInterval) async throws -> CodexAccountProfile { throw CodexAccountManagerError.accountNotFound }
    func removeAccount(id: UUID) throws {}
    func refreshSavedCurrentAccountIfPossible() throws -> CodexAccountProfile? { nil }
}

private struct ActivityIntegrationCLIProbe: CodexCLIStatusProbing {
    func probeStatus() -> CodexCLIStatus { .init(versionText: nil, checkedAt: Date()) }
}
private struct ActivityIntegrationRPCProbe: CodexRPCStatusProbing {
    func probeStatus() async -> CodexRPCStatus {
        .init(accountEmail: nil, accountPlanName: nil, rateLimitPlanName: nil, checkedAt: Date())
    }
}
private struct ActivityIntegrationServiceStatus: CodexServiceStatusFetching {
    func fetchStatus() async throws -> CodexServiceStatus {
        .init(indicator: .unknown, description: "isolated fixture", updatedAt: nil)
    }
}
private struct ActivityIntegrationCookies: OpenAIBrowserCookieImporting {
    func importCookieHeader(targetEmail: String?) async -> OpenAIBrowserCookieImportResult? { nil }
}

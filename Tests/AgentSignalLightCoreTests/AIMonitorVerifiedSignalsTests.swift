import Foundation
import XCTest
import AgentSignalLightCore
@testable import AgentSignalLight

final class AIMonitorVerifiedSignalsTests: XCTestCase {
    func testDoneSetsAwaitingViewAndSurvivesShortCompletedTTL() throws {
        let fixture = try SignalStoreFixture(sessionTTLSeconds: 1_800, completedTTLSeconds: 30)
        defer { fixture.cleanup() }

        let past = Date().addingTimeInterval(-60)
        _ = try fixture.store.applySessionSignal(
            .working,
            sessionID: "s1",
            agent: "claude-code",
            updatedAt: past.addingTimeInterval(-1)
        )
        let done = try fixture.store.applySessionSignal(
            .done,
            sessionID: "s1",
            agent: "claude-code",
            lastEvent: "Stop",
            updatedAt: past
        )
        let session = try XCTUnwrap(done.sessions.first { $0.sessionID == "s1" })
        XCTAssertTrue(session.awaitingView)
        XCTAssertEqual(session.signal, .done)

        let snap = fixture.store.readSnapshot()
        let still = try XCTUnwrap(snap.sessions.first { $0.sessionID == "s1" })
        XCTAssertTrue(still.awaitingView)
    }

    func testMarkViewedClearsAwaitingViewAndDropsFromAttentionBadge() throws {
        let fixture = try SignalStoreFixture()
        defer { fixture.cleanup() }

        _ = try fixture.store.applySessionSignal(
            .done,
            sessionID: "s1",
            agent: "claude-code",
            lastEvent: "Stop"
        )
        let snap = try fixture.store.markSessionViewed(sessionID: "s1")
        let session = try XCTUnwrap(snap.sessions.first { $0.sessionID == "s1" })
        XCTAssertFalse(session.awaitingView)

        let badge = ActivityPresentation.attentionBadgeSessions(from: snap)
        XCTAssertFalse(badge.contains { $0.sessionID == "s1" })
    }

    func testAttentionBadgeCountsPermissionBlockedAndAwaitingViewOnly() throws {
        let fixture = try SignalStoreFixture()
        defer { fixture.cleanup() }

        _ = try fixture.store.applySessionSignal(.working, sessionID: "run", agent: "claude-code")
        _ = try fixture.store.applySessionSignal(
            .done,
            sessionID: "done",
            agent: "claude-code",
            lastEvent: "Stop"
        )
        _ = try fixture.store.applySessionSignal(
            .permissionRequest,
            sessionID: "perm",
            agent: "claude-code"
        )
        _ = try fixture.store.applySessionSignal(
            .blocked,
            sessionID: "err",
            agent: "claude-code",
            lastEvent: "PostToolUseFailure"
        )
        let snap = fixture.store.readSnapshot()

        let badgeIDs = Set(ActivityPresentation.attentionBadgeSessions(from: snap).map(\.sessionID))
        XCTAssertEqual(badgeIDs, Set(["done", "perm", "err"]))
        XCTAssertFalse(badgeIDs.contains("run"))
    }

    func testMonitoredClientBundlePreferences() {
        XCTAssertEqual(
            MonitoredClientApp.chatgptDesktop.preferredBundleIdentifiers,
            ["com.openai.chat", "com.openai.codex"]
        )
        XCTAssertEqual(
            MonitoredClientApp.claudeDesktop.preferredBundleIdentifiers.first,
            "com.anthropic.claudefordesktop"
        )
        XCTAssertEqual(
            MonitoredClientApp.grokBot.preferredBundleIdentifiers,
            ["com.anysphere.sand"]
        )
    }

    func testClaudeHookAdapterMapsVerifiedEvents() {
        XCTAssertEqual(
            ClaudeHookAdapter.chooseSignal(eventName: "UserPromptSubmit", payload: [:]),
            .thinking
        )
        XCTAssertEqual(
            ClaudeHookAdapter.chooseSignal(eventName: "PreToolUse", payload: ["tool_name": "Write"]),
            .working
        )
        XCTAssertEqual(
            ClaudeHookAdapter.chooseSignal(eventName: "Stop", payload: [:]),
            .done
        )
        XCTAssertEqual(
            ClaudeHookAdapter.chooseSignal(eventName: "PostToolUseFailure", payload: ["error": "EPERM"]),
            .blocked
        )
    }

    func testActiveTTLExpiryBecomesStaleNotIdle() throws {
        let fixture = try SignalStoreFixture(sessionTTLSeconds: 5, completedTTLSeconds: 1)
        defer { fixture.cleanup() }

        let past = Date().addingTimeInterval(-10)
        _ = try fixture.store.applySessionSignal(
            .working,
            sessionID: "s1",
            agent: "claude-code",
            updatedAt: past
        )
        let snap = fixture.store.readSnapshot()
        XCTAssertTrue(snap.sessions.isEmpty)
        XCTAssertEqual(snap.aggregate, .stale)
    }
}

private struct SignalStoreFixture {
    let directory: URL
    let store: SignalStateStore

    init(sessionTTLSeconds: Double = 1_800, completedTTLSeconds: Double = 30) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aimonitor-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = SignalStateStore(
            stateFileURL: directory.appendingPathComponent("status.json"),
            sessionTTLSeconds: sessionTTLSeconds,
            completedTTLSeconds: completedTTLSeconds
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

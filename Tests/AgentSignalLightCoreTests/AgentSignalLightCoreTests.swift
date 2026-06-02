import Foundation
import XCTest
@testable import AgentSignalLight
@testable import AgentSignalLightCore

final class AgentSignalLightCoreTests: XCTestCase {
    func testSignalNormalizationAcceptsHumanInputVariants() {
        XCTAssert(AgentSignal.normalized("tool-done") == .toolDone)
        XCTAssert(AgentSignal.normalized(" session start ") == .sessionStart)
        XCTAssert(AgentSignal.normalized("PERMISSION") == .permission)
        XCTAssert(AgentSignal.normalized("PermissionRequest") == .permissionRequest)
        XCTAssert(AgentSignal.normalized("notification") == .notification)
        XCTAssert(AgentSignal.normalized("max-tokens") == .maxTokens)
    }

    func testJSONPayloadThrowsForInvalidHookPayload() {
        XCTAssertThrowsError(
            try JSONPayload.requiredObject(from: Data(#"{"event":"PreToolUse""#.utf8))
        )
        XCTAssertThrowsError(
            try JSONPayload.requiredObject(from: Data(#"["PreToolUse"]"#.utf8))
        )
        XCTAssertNoThrow(try JSONPayload.requiredObject(from: Data()))
    }

    func testCodexDesktopSessionParserMapsFunctionCallsToWorking() {
        let line = """
        {"timestamp":"2026-05-29T02:20:43.081Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","call_id":"call_1"}}
        """

        let activity = CodexDesktopSessionParser.activity(
            from: line,
            defaultSessionID: "codex-desktop:thread"
        )

        XCTAssert(activity?.signal == .working)
        XCTAssert(activity?.sessionID == "codex-desktop:thread")
        XCTAssert(activity?.event == "DesktopToolCall:exec_command")
        XCTAssert(activity?.timestamp != nil)
    }

    func testCodexDesktopSessionParserMapsTaskCompleteToDone() {
        let line = """
        {"timestamp":"2026-05-29T02:17:58.732Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1"}}
        """

        let activity = CodexDesktopSessionParser.activity(
            from: line,
            defaultSessionID: "codex-desktop:thread"
        )

        XCTAssert(activity?.signal == .done)
        XCTAssert(activity?.event == "DesktopTaskComplete")
    }

    func testCodexDesktopSessionParserMapsUserInputRequestsToAttention() {
        let line = """
        {"timestamp":"2026-05-29T02:20:43.081Z","type":"response_item","payload":{"type":"function_call","name":"request_user_input","call_id":"call_1"}}
        """

        let activity = CodexDesktopSessionParser.activity(
            from: line,
            defaultSessionID: "codex-desktop:thread"
        )

        XCTAssert(activity?.signal == .attention)
        XCTAssert(activity?.event == "DesktopToolCall:request_user_input")
    }

    func testCodexDesktopSessionParserDoesNotTreatPermissionProfileAsPermissionRequest() {
        let line = """
        {"timestamp":"2026-05-29T02:20:43.081Z","type":"turn_context","payload":{"approval_policy":"on-request","permission_profile":{"type":"managed","network":"restricted"}}}
        """

        XCTAssertNil(
            CodexDesktopSessionParser.activity(
                from: line,
                defaultSessionID: "codex-desktop:thread"
            )
        )
    }

    func testCodexDesktopSessionParserMapsHeartbeatAndCompactionToThinking() {
        let heartbeatLine = """
        {"timestamp":"2026-06-01T15:37:11.108Z","type":"event_msg","payload":{"type":"token_count","info":{"model_context_window":258400}}}
        """
        let compactedLine = """
        {"timestamp":"2026-06-01T15:34:42.602Z","type":"compacted","payload":{"message":"","replacement_history":[]}}
        """

        let heartbeatActivity = CodexDesktopSessionParser.activity(
            from: heartbeatLine,
            defaultSessionID: "codex-desktop:thread"
        )
        let compactedActivity = CodexDesktopSessionParser.activity(
            from: compactedLine,
            defaultSessionID: "codex-desktop:thread"
        )

        XCTAssert(heartbeatActivity?.signal == .thinking)
        XCTAssert(heartbeatActivity?.event == "DesktopActivityHeartbeat")
        XCTAssert(compactedActivity?.signal == .thinking)
        XCTAssert(compactedActivity?.event == "DesktopContextCompacted")
    }

    func testCodexDesktopActivityMonitorReturnsAllNewActivitiesInOrder() throws {
        let fixture = try makeTemporaryCodexSessionsRoot()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let now = Date()
        let reasoningTimestamp = isoTimestamp(now.addingTimeInterval(-2))
        let toolTimestamp = isoTimestamp(now.addingTimeInterval(-1))

        let sessionFile = fixture.sessionsRoot
            .appendingPathComponent("2026/06/02", isDirectory: true)
            .appendingPathComponent("rollout-2026-06-02T00-00-00-019e83ed-3f20-7000-9000-000000000001.jsonl")
        try FileManager.default.createDirectory(
            at: sessionFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try [
            #"{"timestamp":"\#(reasoningTimestamp)","type":"response_item","payload":{"type":"reasoning"}}"#,
            #"{"timestamp":"\#(toolTimestamp)","type":"response_item","payload":{"type":"function_call","name":"exec_command"}}"#
        ].joined(separator: "\n")
            .appending("\n")
            .write(to: sessionFile, atomically: true, encoding: .utf8)

        let monitor = CodexDesktopActivityMonitor(
            sessionsRootURL: fixture.sessionsRoot,
            replaysInitialHistory: true
        )
        let activities = monitor.poll(now: now)

        XCTAssertEqual(activities.map(\.signal), [.thinking, .working])
        XCTAssertEqual(activities.map(\.event), ["DesktopThinking", "DesktopToolCall:exec_command"])
    }

    func testCodexDesktopActivityMonitorKeepsPartialJSONLUntilComplete() throws {
        let fixture = try makeTemporaryCodexSessionsRoot()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let now = Date()
        let reasoningTimestamp = isoTimestamp(now.addingTimeInterval(-3))
        let toolTimestamp = isoTimestamp(now.addingTimeInterval(-1))

        let sessionFile = fixture.sessionsRoot
            .appendingPathComponent("rollout-2026-06-02T00-00-00-019e83ed-3f20-7000-9000-000000000002.jsonl")
        try #"{"timestamp":"\#(reasoningTimestamp)","type":"response_item","payload":{"type":"reasoning"}}"#
            .appending("\n")
            .write(to: sessionFile, atomically: true, encoding: .utf8)

        let monitor = CodexDesktopActivityMonitor(
            sessionsRootURL: fixture.sessionsRoot,
            replaysInitialHistory: true
        )
        _ = monitor.poll(now: now)

        let partialLine = #"{"timestamp":"\#(toolTimestamp)","type":"response_item","payload":{"type":"function_call","name":"apply_patch"}"#
        try FileHandle(forWritingTo: sessionFile).appendString(partialLine)
        XCTAssertEqual(monitor.poll(now: now.addingTimeInterval(1)), [])

        try FileHandle(forWritingTo: sessionFile).appendString("}\n")
        let completedActivities = monitor.poll(now: now.addingTimeInterval(2))

        XCTAssertEqual(completedActivities.count, 1)
        XCTAssertEqual(completedActivities.first?.signal, .working)
        XCTAssertEqual(completedActivities.first?.event, "DesktopToolCall:apply_patch")
    }

    func testCodexDesktopActivityMonitorDoesNotReplayHistoryByDefault() throws {
        let fixture = try makeTemporaryCodexSessionsRoot()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let now = Date()
        let oldTimestamp = isoTimestamp(now.addingTimeInterval(-10))
        let newTimestamp = isoTimestamp(now.addingTimeInterval(1))

        let sessionFile = fixture.sessionsRoot
            .appendingPathComponent("rollout-2026-06-02T00-00-00-019e83ed-3f20-7000-9000-000000000003.jsonl")
        try #"{"timestamp":"\#(oldTimestamp)","type":"response_item","payload":{"type":"reasoning"}}"#
            .appending("\n")
            .write(to: sessionFile, atomically: true, encoding: .utf8)

        let monitor = CodexDesktopActivityMonitor(sessionsRootURL: fixture.sessionsRoot)
        XCTAssert(monitor.poll(now: now).isEmpty)

        try FileHandle(forWritingTo: sessionFile)
            .appendString(#"{"timestamp":"\#(newTimestamp)","type":"response_item","payload":{"type":"function_call","name":"exec_command"}}"# + "\n")
        let activities = monitor.poll(now: now.addingTimeInterval(2))

        XCTAssertEqual(activities.map(\.signal), [.working])
        XCTAssertEqual(activities.map(\.event), ["DesktopToolCall:exec_command"])
    }

    func testCodexDesktopSessionParserIgnoresUserMessagesAndStartsNewTasks() {
        let userLine = """
        {"timestamp":"2026-05-29T02:18:00.000Z","type":"response_item","payload":{"type":"message","role":"user"}}
        """
        let startedLine = """
        {"timestamp":"2026-05-29T02:18:01.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-2"}}
        """
        let abortedLine = """
        {"timestamp":"2026-05-29T02:18:02.000Z","type":"event_msg","payload":{"type":"turn_aborted","turn_id":"turn-2"}}
        """

        XCTAssertNil(
            CodexDesktopSessionParser.activity(
                from: userLine,
                defaultSessionID: "codex-desktop:thread"
            )
        )

        let startedActivity = CodexDesktopSessionParser.activity(
            from: startedLine,
            defaultSessionID: "codex-desktop:thread"
        )
        XCTAssert(startedActivity?.signal == .thinking)
        XCTAssert(startedActivity?.event == "DesktopTaskStarted")

        let abortedActivity = CodexDesktopSessionParser.activity(
            from: abortedLine,
            defaultSessionID: "codex-desktop:thread"
        )
        XCTAssert(abortedActivity?.signal == .done)
        XCTAssert(abortedActivity?.event == "DesktopTurnAborted")
    }

    func testDisplayStateMappingMatchesV2Language() {
        XCTAssert(AgentSignal.idle.displayState == .ready)
        XCTAssert(AgentSignal.thinking.displayState == .active)
        XCTAssert(AgentSignal.working.displayState == .active)
        XCTAssert(AgentSignal.toolDone.displayState == .active)
        XCTAssert(AgentSignal.subagentStart.displayState == .active)
        XCTAssert(AgentSignal.done.displayState == .completed)
        XCTAssert(AgentSignal.attention.displayState == .needsReview)
        XCTAssert(AgentSignal.notification.displayState == .needsReview)
        XCTAssert(AgentSignal.permission.displayState == .permission)
        XCTAssert(AgentSignal.permissionRequest.displayState == .permission)
        XCTAssert(AgentSignal.blocked.displayState == .blocked)
        XCTAssert(AgentSignal.failure.displayState == .blocked)
        XCTAssert(AgentSignal.maxTokens.displayState == .blocked)
        XCTAssert(AgentSignal.stale.displayState == .stale)
        XCTAssert(AgentSignal.off.displayState == .paused)
    }

    func testAggregateKeepsPermissionAboveActiveAndReviewStates() {
        let now = Date()
        let document = SignalStateDocument(
            sessions: [
                "worker": SessionRecord(agent: "codex", signal: .working, updatedAt: now),
                "done": SessionRecord(agent: "claude-code", signal: .done, updatedAt: now),
                "permission": SessionRecord(agent: "codex", signal: .permission, updatedAt: now)
            ]
        )

        XCTAssert(document.aggregateSignal() == .permission)
    }

    func testBlockedWinsOverPermission() {
        let now = Date()
        let document = SignalStateDocument(
            sessions: [
                "permission": SessionRecord(agent: "codex", signal: .permission, updatedAt: now),
                "blocked": SessionRecord(agent: "claude-code", signal: .blocked, updatedAt: now)
            ]
        )

        XCTAssert(document.aggregateSignal() == .blocked)
    }

    func testV2AggregatePriorityCoversPausedStaleActiveAndCompleted() {
        let now = Date()

        XCTAssert(
            SignalStateDocument(
                sessions: [
                    "paused": SessionRecord(signal: .off, updatedAt: now),
                    "active": SessionRecord(signal: .working, updatedAt: now)
                ]
            ).aggregateSignal() == .off
        )
        XCTAssert(
            SignalStateDocument(
                aggregate: .off,
                sessions: [
                    "active": SessionRecord(signal: .working, updatedAt: now)
                ]
            ).aggregateSignal() == .working
        )
        XCTAssert(
            SignalStateDocument(
                aggregate: .stale,
                sessions: [
                    "active": SessionRecord(signal: .working, updatedAt: now)
                ]
            ).aggregateSignal() == .working
        )
        XCTAssert(
            SignalStateDocument(
                sessions: [
                    "completed": SessionRecord(signal: .done, updatedAt: now),
                    "active": SessionRecord(signal: .working, updatedAt: now)
                ]
            ).aggregateSignal() == .working
        )
        XCTAssert(
            SignalStateDocument(
                sessions: [
                    "completed": SessionRecord(signal: .done, updatedAt: now),
                    "ready": SessionRecord(signal: .idle, updatedAt: now)
                ]
            ).aggregateSignal() == .done
        )
        XCTAssert(
            SignalStateDocument(
                sessions: [
                    "stale": SessionRecord(signal: .stale, updatedAt: now),
                    "active": SessionRecord(signal: .working, updatedAt: now)
                ]
            ).aggregateSignal() == .stale
        )
        XCTAssert(
            SignalStateDocument(
                sessions: [
                    "stale": SessionRecord(signal: .stale, updatedAt: now),
                    "review": SessionRecord(signal: .attention, updatedAt: now)
                ]
            ).aggregateSignal() == .attention
        )
    }

    func testTurnEndDoesNotClearPermissionAlert() throws {
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        _ = try fixture.store.applySessionSignal(
            .permission,
            sessionID: "codex-main",
            agent: "codex",
            lastEvent: "PermissionRequest"
        )
        let snapshot = try fixture.store.applySessionSignal(
            .turnEnd,
            sessionID: "codex-main",
            agent: "codex",
            lastEvent: "Stop"
        )

        XCTAssert(snapshot.aggregate == .permission)
        XCTAssert(snapshot.sessions.map(\.sessionID) == ["codex-main"])
    }

    func testSuccessfulStopCompletesActiveSessionWithoutClearingAlerts() throws {
        let activeFixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: activeFixture.directory) }

        _ = try activeFixture.store.applySessionSignal(
            .working,
            sessionID: "codex-main",
            agent: "codex",
            lastEvent: "PreToolUse"
        )
        let completedSnapshot = try activeFixture.store.applySessionSignal(
            .done,
            sessionID: "codex-main",
            agent: "codex",
            lastEvent: "Stop"
        )

        XCTAssert(completedSnapshot.aggregate == .done)
        XCTAssert(completedSnapshot.sessions.first?.signal == .done)

        let alertFixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: alertFixture.directory) }

        _ = try alertFixture.store.applySessionSignal(
            .permission,
            sessionID: "codex-main",
            agent: "codex",
            lastEvent: "PermissionRequest"
        )
        let alertSnapshot = try alertFixture.store.applySessionSignal(
            .done,
            sessionID: "codex-main",
            agent: "codex",
            lastEvent: "Stop"
        )

        XCTAssert(alertSnapshot.aggregate == .permission)
        XCTAssert(alertSnapshot.sessions.first?.signal == .permission)
        XCTAssert(alertSnapshot.recentEvents.first?.signal == .done)
    }

    func testSessionEndPreservesCompletedAndAlertSessions() throws {
        let completedFixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: completedFixture.directory) }

        _ = try completedFixture.store.applySessionSignal(.done, sessionID: "codex-main")
        let completedSnapshot = try completedFixture.store.applySessionSignal(
            .sessionEnd,
            sessionID: "codex-main",
            lastEvent: "SessionEnd"
        )

        XCTAssert(completedSnapshot.aggregate == .done)
        XCTAssert(completedSnapshot.sessions.first?.signal == .done)
        XCTAssert(completedSnapshot.recentEvents.first?.signal == .sessionEnd)

        let alertFixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: alertFixture.directory) }

        _ = try alertFixture.store.applySessionSignal(.blocked, sessionID: "codex-main")
        let alertSnapshot = try alertFixture.store.applySessionSignal(
            .sessionEnd,
            sessionID: "codex-main",
            lastEvent: "SessionEnd"
        )

        XCTAssert(alertSnapshot.aggregate == .blocked)
        XCTAssert(alertSnapshot.sessions.first?.signal == .blocked)
        XCTAssert(alertSnapshot.recentEvents.first?.signal == .sessionEnd)
    }

    func testSessionEndDoesNotClearPausedAggregate() throws {
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        _ = try fixture.store.applySessionSignal(.off, sessionID: "manual", agent: "manual")
        let snapshot = try fixture.store.applySessionSignal(
            .sessionEnd,
            sessionID: "codex-main",
            agent: "codex",
            lastEvent: "SessionEnd"
        )

        XCTAssertEqual(snapshot.aggregate, .off)
        XCTAssert(snapshot.sessions.isEmpty)
    }

    func testClearWarningsKeepsWorkingSessions() throws {
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        _ = try fixture.store.applySessionSignal(
            .working,
            sessionID: "worker",
            agent: "codex",
            lastEvent: "PreToolUse"
        )
        _ = try fixture.store.applySessionSignal(
            .blocked,
            sessionID: "blocked",
            agent: "claude-code",
            lastEvent: "PostToolUseFailure"
        )

        let snapshot = try fixture.store.clearWarnings()

        XCTAssert(snapshot.aggregate == .working)
        XCTAssert(snapshot.sessions.map(\.sessionID) == ["worker"])
    }

    func testManualSignalsParticipateInSessionAggregation() throws {
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        _ = try fixture.store.applySessionSignal(
            .permission,
            sessionID: "codex-main",
            agent: "codex",
            lastEvent: "PermissionRequest"
        )
        let snapshot = try fixture.store.setManualSignal(.working)

        XCTAssert(snapshot.aggregate == .permission)
        XCTAssert(snapshot.sessions.map(\.sessionID) == ["codex-main", "manual"])
        XCTAssert(snapshot.sessions.first { $0.sessionID == "manual" }?.signal == .working)
        XCTAssert(snapshot.sessions.first { $0.sessionID == "manual" }?.agent == "manual")
        XCTAssert(snapshot.sessions.first { $0.sessionID == "manual" }?.lastEvent == "ManualSet")
    }

    func testManualIdleStillClearsSessions() throws {
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        _ = try fixture.store.applySessionSignal(.working, sessionID: "worker")
        let snapshot = try fixture.store.setManualSignal(.idle)

        XCTAssert(snapshot.aggregate == .idle)
        XCTAssert(snapshot.sessions.isEmpty)
        XCTAssert(snapshot.recentEvents.first?.event == "ManualSet")
    }

    func testNonPausedSignalsResumeFromPausedAggregate() throws {
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        _ = try fixture.store.applySessionSignal(.off, sessionID: "manual")
        let snapshot = try fixture.store.applySessionSignal(
            .working,
            sessionID: "worker",
            agent: "codex",
            lastEvent: "PreToolUse"
        )

        XCTAssert(snapshot.aggregate == .working)
        XCTAssert(snapshot.sessions.map(\.sessionID) == ["worker"])
    }

    func testNonStaleSignalsResumeFromStaleAggregate() throws {
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        try FileManager.default.createDirectory(
            at: fixture.store.stateFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let staleJSON = """
        {
          "schema_version": 1,
          "aggregate": "stale",
          "updated_at": "2026-05-28T00:00:00Z",
          "sessions": {},
          "events": []
        }
        """
        try staleJSON.write(to: fixture.store.stateFileURL, atomically: true, encoding: .utf8)

        let snapshot = try fixture.store.applySessionSignal(
            .working,
            sessionID: "worker",
            agent: "codex",
            lastEvent: "PreToolUse"
        )

        XCTAssert(snapshot.aggregate == .working)
        XCTAssert(snapshot.sessions.map(\.sessionID) == ["worker"])
    }

    func testEventLimitKeepsNewestEvents() throws {
        let fixture = try makeTemporaryStore(eventLimit: 2)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        _ = try fixture.store.applySessionSignal(.working, sessionID: "one", lastEvent: "one")
        _ = try fixture.store.applySessionSignal(.working, sessionID: "two", lastEvent: "two")
        let snapshot = try fixture.store.applySessionSignal(.working, sessionID: "three", lastEvent: "three")

        XCTAssert(snapshot.recentEvents.map(\.event) == ["three", "two"])
    }

    func testApplySessionSignalPreservesProvidedEventTimestamp() throws {
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let eventDate = Date(timeIntervalSince1970: 1_780_358_402)

        let snapshot = try fixture.store.applySessionSignal(
            .working,
            sessionID: "codex-main",
            agent: "codex",
            lastEvent: "DesktopToolCall:exec_command",
            updatedAt: eventDate
        )

        XCTAssertEqual(snapshot.sessions.first?.updatedAt, eventDate)
        XCTAssertEqual(snapshot.recentEvents.first?.updatedAt, eventDate)
        XCTAssertEqual(snapshot.updatedAt, eventDate)
    }

    func testApplySessionSignalIgnoresOlderEventsForSameSession() throws {
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let newerDate = Date(timeIntervalSince1970: 1_780_358_420)
        let olderDate = Date(timeIntervalSince1970: 1_780_358_400)

        _ = try fixture.store.applySessionSignal(
            .permission,
            sessionID: "codex-main",
            agent: "codex",
            lastEvent: "PermissionRequest",
            updatedAt: newerDate
        )
        let snapshot = try fixture.store.applySessionSignal(
            .working,
            sessionID: "codex-main",
            agent: "codex",
            lastEvent: "PreToolUse",
            updatedAt: olderDate
        )

        XCTAssertEqual(snapshot.aggregate, .permission)
        XCTAssertEqual(snapshot.sessions.first?.signal, .permission)
        XCTAssertEqual(snapshot.sessions.first?.updatedAt, newerDate)
        XCTAssertEqual(snapshot.recentEvents.map(\.event), ["PermissionRequest"])
    }

    func testDuplicateRecentEventsAreCollapsedBeforeCapping() throws {
        let fixture = try makeTemporaryStore(eventLimit: 4)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        _ = try fixture.store.applySessionSignal(.working, sessionID: "codex-main", agent: "codex", lastEvent: "PreToolUse")
        _ = try fixture.store.applySessionSignal(.working, sessionID: "codex-main", agent: "codex", lastEvent: "PreToolUse")
        _ = try fixture.store.applySessionSignal(.working, sessionID: "codex-main", agent: "codex", lastEvent: "PreToolUse")
        _ = try fixture.store.applySessionSignal(.toolDone, sessionID: "codex-main", agent: "codex", lastEvent: "PostToolUse")
        let snapshot = try fixture.store.applySessionSignal(.done, sessionID: "codex-main", agent: "codex", lastEvent: "Stop")

        XCTAssert(snapshot.recentEvents.map(\.event) == ["Stop", "PostToolUse", "PreToolUse"])
    }

    func testCodexHookMappingCoversCoreEventsAndFailures() {
        XCTAssert(CodexHookAdapter.chooseSignal(eventName: "PreToolUse", payload: [:]) == .working)
        XCTAssert(CodexHookAdapter.chooseSignal(eventName: "Stop", payload: [:]) == .done)
        XCTAssert(CodexHookAdapter.chooseSignal(eventName: " pre_tool_use ", payload: [:]) == .working)
        XCTAssert(CodexHookAdapter.chooseSignal(eventName: "permission-request", payload: [:]) == .permissionRequest)
        XCTAssert(
            CodexHookAdapter.chooseSignal(
                eventName: nil,
                payload: ["hookEventName": "post tool use"]
            ) == .toolDone
        )
        XCTAssert(
            CodexHookAdapter.chooseSignal(
                eventName: "PreToolUse",
                payload: ["signal": "attention"]
            ) == .attention
        )
        XCTAssert(
            CodexHookAdapter.chooseSignal(
                eventName: "PostToolUse",
                payload: ["exitStatus": 1]
            ).displayState == .blocked
        )
        XCTAssert(
            CodexHookAdapter.chooseSignal(
                eventName: nil,
                payload: ["Status": "failed"]
            ).displayState == .blocked
        )
    }

    func testCodexSessionKeyUsesNestedPayloadBeforeEnvironment() {
        let payload: [String: Any] = [
            "tool": [
                "context": [
                    "threadId": "nested-thread"
                ]
            ]
        ]

        XCTAssert(
            CodexHookAdapter.sessionKey(
                payload: payload,
                environment: ["CODEX_SESSION_ID": "env-session"]
            ) == "nested-thread"
        )
        XCTAssert(
            CodexHookAdapter.sessionKey(
                payload: ["sessionId": "camel-session"],
                environment: ["CODEX_SESSION_ID": "env-session"]
            ) == "camel-session"
        )
    }

    func testHookSessionKeysAcceptNumericPayloadValues() {
        XCTAssertEqual(
            CodexHookAdapter.sessionKey(payload: ["session_id": 12_345], environment: [:]),
            "12345"
        )
        XCTAssertEqual(
            ClaudeHookAdapter.sessionKey(payload: ["conversation_id": 67_890], environment: [:]),
            "67890"
        )
        XCTAssertEqual(
            GenericHookAdapter.sessionKey(payload: ["run_id": 42], environment: [:], agent: "local"),
            "42"
        )
    }

    func testClaudeHookMappingCoversAttentionAndStopFailures() {
        XCTAssert(ClaudeHookAdapter.chooseSignal(eventName: "UserPromptExpansion", payload: [:]) == .thinking)
        XCTAssert(ClaudeHookAdapter.chooseSignal(eventName: "Notification", payload: [:]).displayState == .needsReview)
        XCTAssert(ClaudeHookAdapter.chooseSignal(eventName: "Stop", payload: [:]) == .done)
        XCTAssert(ClaudeHookAdapter.chooseSignal(eventName: "StopFailure", payload: [:]) == .blocked)
        XCTAssert(ClaudeHookAdapter.chooseSignal(eventName: "PermissionDenied", payload: [:]) == .blocked)
        XCTAssert(ClaudeHookAdapter.chooseSignal(eventName: "TaskCreated", payload: [:]) == .subagentStart)
        XCTAssert(ClaudeHookAdapter.chooseSignal(eventName: "TaskCompleted", payload: [:]) == .subagentStop)
        XCTAssert(ClaudeHookAdapter.chooseSignal(eventName: "PostToolBatch", payload: [:]) == .toolDone)
        XCTAssert(ClaudeHookAdapter.chooseSignal(eventName: "PostCompact", payload: [:]) == .toolDone)
        XCTAssert(ClaudeHookAdapter.chooseSignal(eventName: "WorktreeCreate", payload: [:]) == .working)
        XCTAssert(ClaudeHookAdapter.chooseSignal(eventName: "WorktreeRemove", payload: [:]).displayState == .needsReview)
        XCTAssert(ClaudeHookAdapter.chooseSignal(eventName: "post_tool_use_failure", payload: [:]) == .blocked)
        XCTAssert(
            ClaudeHookAdapter.chooseSignal(
                eventName: nil,
                payload: ["event": "subagent stop"]
            ) == .subagentStop
        )
        XCTAssert(
            ClaudeHookAdapter.chooseSignal(
                eventName: " stop ",
                payload: ["stopReason": " max-tokens "]
            ) == .maxTokens
        )
        XCTAssert(
            ClaudeHookAdapter.chooseSignal(
                eventName: "Stop",
                payload: ["stopReason": "max_tokens"]
            ).displayState == .blocked
        )
        XCTAssert(
            ClaudeHookAdapter.chooseSignal(
                eventName: "Stop",
                payload: ["stopReason": " tool error "]
            ) == .error
        )
        XCTAssert(
            ClaudeHookAdapter.chooseSignal(
                eventName: "PreToolUse",
                payload: ["lampSignal": "permission"]
            ) == .permission
        )
        XCTAssert(
            ClaudeHookAdapter.chooseSignal(
                eventName: "PostToolUse",
                payload: ["exitStatus": 1]
            ).displayState == .blocked
        )
        XCTAssert(
            ClaudeHookAdapter.chooseSignal(
                eventName: nil,
                payload: ["Status": "failed"]
            ).displayState == .blocked
        )
        XCTAssert(
            ClaudeHookAdapter.sessionKey(
                payload: ["sessionId": "claude-camel"],
                environment: ["CLAUDE_SESSION_ID": "env-session"]
            ) == "claude-camel"
        )
        XCTAssert(
            ClaudeHookAdapter.eventName(payload: ["hookEventName": "PostToolBatch"]) == "PostToolBatch"
        )
        XCTAssert(
            ClaudeHookAdapter.displayEventName(
                eventName: "PreToolUse",
                payload: ["toolName": "Bash"]
            ) == "PreToolUse:Bash"
        )
        XCTAssert(
            ClaudeHookAdapter.sessionKey(
                payload: ["transcriptPath": "/tmp/claude/transcript-1.jsonl"],
                environment: [:]
            ) == "transcript:transcript-1.jsonl"
        )
    }

    func testSharedLampAnimationCoversIdleAndOff() {
        XCTAssert(SignalLampAnimation.isLit(.green, signal: .idle, tick: 0))
        XCTAssert(!SignalLampAnimation.isLit(.yellow, signal: .idle, tick: 0))
        XCTAssert(!SignalLampAnimation.isLit(.red, signal: .idle, tick: 0))
        XCTAssert(!SignalLampAnimation.isLit(.green, signal: .off, tick: 0))
        XCTAssert(SignalLampAnimation.isLit(.red, signal: .off, tick: 0, allLightsOn: true))
        XCTAssert(SignalLampAnimation.isLit(.yellow, signal: .off, tick: 0, allLightsOn: true))
        XCTAssert(SignalLampAnimation.isLit(.green, signal: .off, tick: 0, allLightsOn: true))
    }

    func testSharedLampAnimationKeepsActiveGreenOnly() {
        XCTAssert(SignalLampAnimation.intensity(.green, signal: .working, tick: 0) == 1)
        XCTAssert(SignalLampAnimation.intensity(.green, signal: .working, tick: 3) == 0)
        XCTAssert(!SignalLampAnimation.isLit(.yellow, signal: .working, tick: 0))
        XCTAssert(!SignalLampAnimation.isLit(.red, signal: .working, tick: 0))

        XCTAssert(SignalLampAnimation.intensity(.green, signal: .thinking, tick: 0) == 1)
        XCTAssert(SignalLampAnimation.intensity(.green, signal: .thinking, tick: 1) == 0)
        XCTAssert(!SignalLampAnimation.isLit(.yellow, signal: .thinking, tick: 0))
        XCTAssert(!SignalLampAnimation.isLit(.red, signal: .thinking, tick: 0))

        XCTAssert(SignalLampAnimation.intensity(.green, signal: .toolDone, tick: 0) == 1)
        XCTAssert(!SignalLampAnimation.isLit(.yellow, signal: .toolDone, tick: 4))
        XCTAssert(!SignalLampAnimation.isLit(.red, signal: .toolDone, tick: 4))
    }

    func testDefaultActiveAndCompletedAnimationsMatchProductDefaults() {
        XCTAssert(SignalLampAnimation.intensity(.green, signal: .thinking, tick: 0) == 1)
        XCTAssert(SignalLampAnimation.intensity(.green, signal: .thinking, tick: 1) == 0)
        XCTAssert(SignalLampAnimation.intensity(.green, signal: .working, tick: 0) == 1)
        XCTAssert(SignalLampAnimation.intensity(.green, signal: .working, tick: 3) == 0)
        XCTAssert(SignalLampAnimation.intensity(.green, signal: .done, tick: 0) == 1)
        XCTAssert(SignalLampAnimation.intensity(.green, signal: .done, tick: 3) == 1)
        XCTAssert(SignalLampAnimation.intensity(.yellow, signal: .done, tick: 0) == 0)
        XCTAssert(SignalLampAnimation.intensity(.red, signal: .done, tick: 0) == 0)
    }

    func testCustomLampAnimationCanCycleAndChangeDoneColor() {
        let trafficCycle = SignalEffectCustomization(activeEffect: .trafficCycle)
        XCTAssert(SignalLampAnimation.intensity(.red, signal: .working, tick: 0, customization: trafficCycle) == 1)
        XCTAssert(SignalLampAnimation.intensity(.yellow, signal: .working, tick: 0, customization: trafficCycle) == 0)
        XCTAssert(SignalLampAnimation.intensity(.yellow, signal: .working, tick: 4, customization: trafficCycle) == 1)
        XCTAssert(SignalLampAnimation.intensity(.red, signal: .working, tick: 4, customization: trafficCycle) == 0)
        XCTAssert(SignalLampAnimation.intensity(.green, signal: .working, tick: 8, customization: trafficCycle) == 1)
        XCTAssert(SignalLampAnimation.intensity(.yellow, signal: .working, tick: 8, customization: trafficCycle) == 0)
        XCTAssert(!SignalLampAnimation.isLit(.green, signal: .working, tick: 0, customization: trafficCycle))

        let greenSteady = SignalEffectCustomization(activeEffect: .greenSteady)
        XCTAssert(SignalLampAnimation.intensity(.green, signal: .working, tick: 3, customization: greenSteady) == 1)
        XCTAssert(!SignalLampAnimation.isLit(.yellow, signal: .working, tick: 3, customization: greenSteady))

        let greenSlowFlash = SignalEffectCustomization(activeEffect: .greenSlowFlash)
        XCTAssert(SignalLampAnimation.intensity(.green, signal: .working, tick: 0, customization: greenSlowFlash) == 1)
        XCTAssert(SignalLampAnimation.intensity(.green, signal: .working, tick: 3, customization: greenSlowFlash) == 0)

        let greenFastFlash = SignalEffectCustomization(activeEffect: .greenFastFlash)
        XCTAssert(SignalLampAnimation.intensity(.green, signal: .working, tick: 0, customization: greenFastFlash) == 1)
        XCTAssert(SignalLampAnimation.intensity(.green, signal: .working, tick: 1, customization: greenFastFlash) == 0)

        let thinkingBreathing = SignalEffectCustomization(thinkingEffect: .greenBreathing)
        XCTAssert(SignalLampAnimation.intensity(.green, signal: .thinking, tick: 0, customization: thinkingBreathing) < SignalLampAnimation.intensity(.green, signal: .thinking, tick: 5, customization: thinkingBreathing))

        let yellowDone = SignalEffectCustomization(completedEffect: .yellowSteady)
        XCTAssert(SignalLampAnimation.intensity(.yellow, signal: .done, tick: 0, customization: yellowDone) == 1)
        XCTAssert(!SignalLampAnimation.isLit(.green, signal: .done, tick: 0, customization: yellowDone))

        let allDone = SignalEffectCustomization(completedEffect: .allSteady)
        XCTAssert(SignalLampAnimation.intensity(.red, signal: .done, tick: 0, customization: allDone) == 1)
        XCTAssert(SignalLampAnimation.intensity(.yellow, signal: .done, tick: 0, customization: allDone) == 1)
        XCTAssert(SignalLampAnimation.intensity(.green, signal: .done, tick: 0, customization: allDone) == 1)

        let allFlash = SignalEffectCustomization(completedEffect: .allPulse)
        XCTAssert(SignalLampAnimation.intensity(.red, signal: .done, tick: 0, customization: allFlash) == 1)
        XCTAssert(SignalLampAnimation.intensity(.yellow, signal: .done, tick: 0, customization: allFlash) == 1)
        XCTAssert(SignalLampAnimation.intensity(.green, signal: .done, tick: 0, customization: allFlash) == 1)
        XCTAssert(SignalLampAnimation.intensity(.red, signal: .done, tick: 2, customization: allFlash) == 0)
        XCTAssert(SignalLampAnimation.intensity(.yellow, signal: .done, tick: 2, customization: allFlash) == 0)
        XCTAssert(SignalLampAnimation.intensity(.green, signal: .done, tick: 2, customization: allFlash) == 0)
    }

    func testMacOSVisualScaleStrengthsAreMeaningfullySeparated() {
        let breathing = SignalEffectCustomization(activeEffect: .greenBreathing)
        let baseScale = SignalLampAnimation.scale(.green, signal: .working, tick: 0, customization: breathing)
        let intensity = SignalLampAnimation.intensity(.green, signal: .working, tick: 0, customization: breathing)

        let standard = SignalVisualScale.lampScale(
            baseScale: baseScale,
            intensity: intensity,
            style: .macOS,
            macOSStrength: .standard
        )
        let pronounced = SignalVisualScale.lampScale(
            baseScale: baseScale,
            intensity: intensity,
            style: .macOS,
            macOSStrength: .pronounced
        )
        let maximum = SignalVisualScale.lampScale(
            baseScale: baseScale,
            intensity: intensity,
            style: .macOS,
            macOSStrength: .maximum
        )
        let maximumMid = SignalVisualScale.lampScale(
            baseScale: SignalLampAnimation.scale(.green, signal: .working, tick: 2, customization: breathing),
            intensity: SignalLampAnimation.intensity(.green, signal: .working, tick: 2, customization: breathing),
            style: .macOS,
            macOSStrength: .maximum
        )
        let maximumHigh = SignalVisualScale.lampScale(
            baseScale: SignalLampAnimation.scale(.green, signal: .working, tick: 4, customization: breathing),
            intensity: SignalLampAnimation.intensity(.green, signal: .working, tick: 4, customization: breathing),
            style: .macOS,
            macOSStrength: .maximum
        )

        XCTAssert(maximum < pronounced)
        XCTAssert(pronounced < standard)
        XCTAssert(maximum == baseScale)
        XCTAssert(maximumMid >= 0.74)
        XCTAssert(maximumMid <= 0.76)
        XCTAssert(maximumHigh >= 0.90)
        XCTAssert(maximumHigh <= 0.92)
        XCTAssert(standard - maximum >= 0.15)
        XCTAssert(
            SignalVisualScale.lampScale(
                baseScale: baseScale,
                intensity: intensity,
                style: .trafficLight,
                macOSStrength: .maximum
            ) == baseScale
        )
    }

    func testSharedLampAnimationUsesV2BlinkCadences() {
        XCTAssert(SignalLampAnimation.isLit(.green, signal: .done, tick: 0))
        XCTAssert(!SignalLampAnimation.isLit(.yellow, signal: .done, tick: 0))
        XCTAssert(!SignalLampAnimation.isLit(.red, signal: .done, tick: 0))

        XCTAssert(SignalLampAnimation.isLit(.yellow, signal: .attention, tick: 0))
        XCTAssert(!SignalLampAnimation.isLit(.yellow, signal: .attention, tick: 4))
        XCTAssert(SignalLampAnimation.scale(.yellow, signal: .attention, tick: 0) < SignalLampAnimation.scale(.yellow, signal: .attention, tick: 2))

        XCTAssert(SignalLampAnimation.isLit(.red, signal: .permission, tick: 0))
        XCTAssert(!SignalLampAnimation.isLit(.red, signal: .permission, tick: 4))

        XCTAssert(SignalLampAnimation.isLit(.red, signal: .blocked, tick: 0))
        XCTAssert(!SignalLampAnimation.isLit(.red, signal: .blocked, tick: 1))

        XCTAssert(SignalLampAnimation.intensity(.yellow, signal: .stale, tick: 0) > 0)
        XCTAssert(!SignalLampAnimation.isLit(.yellow, signal: .stale, tick: 4))
    }

    func testStaleIsProducedWhenStatusFileIsCorruptOrSessionExpires() throws {
        let corruptFixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: corruptFixture.directory) }

        try FileManager.default.createDirectory(
            at: corruptFixture.store.stateFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "{".write(to: corruptFixture.store.stateFileURL, atomically: true, encoding: .utf8)

        XCTAssert(corruptFixture.store.readSnapshot().aggregate == .stale)

        let ttlFixture = try makeTemporaryStore(sessionTTLSeconds: 0.01)
        defer { try? FileManager.default.removeItem(at: ttlFixture.directory) }
        let oldDate = Date(timeIntervalSince1970: 100)

        try writeDocument(
            SignalStateDocument(
                aggregate: .working,
                updatedAt: oldDate,
                sessions: ["worker": SessionRecord(signal: .working, updatedAt: oldDate)]
            ),
            in: ttlFixture.store
        )
        let snapshot = ttlFixture.store.readSnapshot()
        let storedDocument = try storedDocument(in: ttlFixture.store)

        XCTAssert(snapshot.aggregate == .stale)
        XCTAssert(snapshot.sessions.isEmpty)
        XCTAssert(storedDocument.aggregate == .stale)
        XCTAssert(storedDocument.sessions.isEmpty)
        XCTAssert((snapshot.updatedAt ?? .distantPast) > oldDate)
        XCTAssert((storedDocument.updatedAt ?? .distantPast) > oldDate)
    }

    func testStateStoreReadsFractionalSecondDatesFromExternalJSON() throws {
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let now = Date()
        let timestamp = isoTimestamp(now)
        let json = """
        {
          "schema_version": 1,
          "aggregate": "working",
          "updated_at": "\(timestamp)",
          "sessions": {
            "external": {
              "agent": "external",
              "signal": "working",
              "last_event": "ExternalWrite",
              "updated_at": "\(timestamp)"
            }
          },
          "events": [
            {
              "id": "external-event",
              "session_id": "external",
              "agent": "external",
              "signal": "working",
              "event": "ExternalWrite",
              "updated_at": "\(timestamp)"
            }
          ]
        }
        """

        try FileManager.default.createDirectory(
            at: fixture.store.stateFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try json.write(to: fixture.store.stateFileURL, atomically: true, encoding: .utf8)

        let snapshot = fixture.store.readSnapshot()

        XCTAssertEqual(snapshot.aggregate, .working)
        XCTAssertEqual(snapshot.sessions.first?.sessionID, "external")
        XCTAssertEqual(snapshot.sessions.first?.lastEvent, "ExternalWrite")
    }

    func testDefaultStateFileURLTrimsBlankEnvironmentValues() {
        let explicitFallback = SignalStateStore.defaultStateFileURL(
            environment: [
                "AGENT_SIGNAL_LIGHT_STATE_FILE": "   ",
                "AGENT_SIGNAL_LIGHT_STATE_DIR": "  /tmp/trimmed-agent-signal  "
            ]
        )
        XCTAssertEqual(explicitFallback.path, "/tmp/trimmed-agent-signal/status.json")

        let defaultFallback = SignalStateStore.defaultStateFileURL(
            environment: [
                "AGENT_SIGNAL_LIGHT_STATE_FILE": "\n\t",
                "AGENT_SIGNAL_LIGHT_STATE_DIR": "  ",
                "SIGNAL_LIGHT_STATE_DIR": "\n"
            ]
        )
        XCTAssertEqual(defaultFallback.path, "/tmp/agent-signal/status.json")
    }

    func testCompletedSessionExpiresBackToIdle() throws {
        let fixture = try makeTemporaryStore(completedTTLSeconds: 0.01)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let oldDate = Date(timeIntervalSince1970: 100)

        try writeDocument(
            SignalStateDocument(
                aggregate: .done,
                updatedAt: oldDate,
                sessions: ["worker": SessionRecord(signal: .done, updatedAt: oldDate)]
            ),
            in: fixture.store
        )
        let snapshot = fixture.store.readSnapshot()
        let storedDocument = try storedDocument(in: fixture.store)

        XCTAssert(snapshot.aggregate == .idle)
        XCTAssert(snapshot.sessions.isEmpty)
        XCTAssert(storedDocument.aggregate == .idle)
        XCTAssert(storedDocument.sessions.isEmpty)
        XCTAssert((snapshot.updatedAt ?? .distantPast) > oldDate)
        XCTAssert((storedDocument.updatedAt ?? .distantPast) > oldDate)
    }

    func testToolDoneSessionExpiresBackToIdle() throws {
        let fixture = try makeTemporaryStore(completedTTLSeconds: 0.01)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let oldDate = Date(timeIntervalSince1970: 100)

        try writeDocument(
            SignalStateDocument(
                aggregate: .toolDone,
                updatedAt: oldDate,
                sessions: ["worker": SessionRecord(signal: .toolDone, updatedAt: oldDate)]
            ),
            in: fixture.store
        )
        let snapshot = fixture.store.readSnapshot()
        let storedDocument = try storedDocument(in: fixture.store)

        XCTAssert(snapshot.aggregate == .idle)
        XCTAssert(snapshot.sessions.isEmpty)
        XCTAssert(storedDocument.aggregate == .idle)
        XCTAssert(storedDocument.sessions.isEmpty)
    }

    func testGitHubReleaseUpdateCheckerComparesSemanticVersions() {
        XCTAssertEqual(GitHubReleaseUpdateChecker.displayVersion(from: "v1.1.0"), "1.1.0")
        XCTAssertEqual(GitHubReleaseUpdateChecker.compareVersions("1.1.1", "1.1.0"), .orderedDescending)
        XCTAssertEqual(GitHubReleaseUpdateChecker.compareVersions("v1.1.0", "1.1"), .orderedSame)
        XCTAssertEqual(GitHubReleaseUpdateChecker.compareVersions("1.0.9", "1.1.0"), .orderedAscending)
    }

    func testGitHubReleaseUpdateCheckerDecodesLatestRelease() throws {
        let data = Data(
            """
            {
              "tag_name": "v1.2.0",
              "html_url": "https://github.com/guan-ops/Agent-Signal-Bar/releases/tag/v1.2.0",
              "assets": [
                {
                  "name": "AgentSignalLight-local.dmg",
                  "browser_download_url": "https://github.com/guan-ops/Agent-Signal-Bar/releases/download/v1.2.0/AgentSignalLight-local.dmg"
                }
              ]
            }
            """.utf8
        )

        let release = try GitHubReleaseUpdateChecker.decodeLatestRelease(from: data)

        XCTAssertEqual(release.tagName, "v1.2.0")
        XCTAssertEqual(release.preferredDownloadURL?.lastPathComponent, "AgentSignalLight-local.dmg")
    }

    private func makeTemporaryStore(
        sessionTTLSeconds: Double = 86_400,
        completedTTLSeconds: Double = 90,
        eventLimit: Int = 30
    ) throws -> (store: SignalStateStore, directory: URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("agent-signal-light-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let store = SignalStateStore(
            stateFileURL: directory.appendingPathComponent("status.json"),
            sessionTTLSeconds: sessionTTLSeconds,
            completedTTLSeconds: completedTTLSeconds,
            eventLimit: eventLimit
        )
        return (store, directory)
    }

    private func makeTemporaryCodexSessionsRoot() throws -> (sessionsRoot: URL, directory: URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("agent-signal-light-codex-sessions-\(UUID().uuidString)", isDirectory: true)
        let sessionsRoot = directory.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        return (sessionsRoot, directory)
    }

    private func isoTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func storedDocument(in store: SignalStateStore) throws -> SignalStateDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(contentsOf: store.stateFileURL)
        return try decoder.decode(SignalStateDocument.self, from: data)
    }

    private func writeDocument(_ document: SignalStateDocument, in store: SignalStateStore) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(
            at: store.stateFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(document).write(to: store.stateFileURL)
    }
}

private extension FileHandle {
    func appendString(_ value: String) throws {
        defer {
            try? close()
        }
        try seekToEnd()
        if let data = value.data(using: .utf8) {
            try write(contentsOf: data)
        }
    }
}

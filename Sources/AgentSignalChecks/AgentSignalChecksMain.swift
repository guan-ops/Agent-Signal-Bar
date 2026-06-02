import AgentSignalLightCore
import Foundation

@main
struct AgentSignalChecks {
    static func main() throws {
        try checkDisplayStateMappings()
        try checkActiveAnimationStaysGreenOnly()
        try checkMacOSBreathingScaleIsPronounced()
        try checkAggregateKeepsPermissionAboveWorkingAndAttention()
        try checkBlockedWinsOverPermissionWhenBothArePresent()
        try checkV2AggregatePriority()
        try checkStopHooksMapToCompleted()
        try checkTurnEndDoesNotClearRedSession()
        try checkDoneDoesNotClearWarningSession()
        try checkClearWarningPreservesWorkingSession()
        try checkManualSignalsParticipateInAggregation()
        try checkNonPausedSignalResumesFromPausedAggregate()
        try checkSessionEndRemovesSession()
        try checkSessionEndPreservesCompletedAndWarningSessions()
        try checkOffClearsAllSessions()
        try checkSessionTTLPrunesStaleSessions()
        try checkCompletedTTLReturnsToIdle()
        try checkRecentEventsAreStoredAndCapped()
        try checkStateFileSchemaRoundTrip()
        try checkAllSignalsAreCodable()
        try checkLegacyStatusFileCompatibility()
        try checkCorruptStatusFileFallsBackToStale()
        try checkUnknownSignalIsRejected()
        try checkCodexFailurePayloadMapsToBlocked()
        try checkClaudeFailurePayloadMapsToBlocked()
        try checkGenericHookAdapterMapsOtherAgents()
        try checkCodexDesktopSessionParserMapsDesktopEvents()
        print("agent-signal-checks: ok")
    }

    private static func checkDisplayStateMappings() throws {
        try expect(AgentSignal.working.displayState == .active, "working should display as active")
        try expect(AgentSignal.thinking.displayState == .active, "thinking should display as active")
        try expect(AgentSignal.toolDone.displayState == .active, "tool_done should display as active")
        try expect(AgentSignal.done.displayState == .completed, "done should display as completed")
        try expect(AgentSignal.notification.displayState == .needsReview, "notification should display as needs_review")
        try expect(AgentSignal.permissionRequest.displayState == .permission, "permission_request should display as permission")
        try expect(AgentSignal.maxTokens.displayState == .blocked, "max_tokens should display as blocked")
        try expect(AgentSignal.off.displayState == .paused, "off should display as paused")
    }

    private static func checkActiveAnimationStaysGreenOnly() throws {
        try expect(SignalLampAnimation.intensity(.green, signal: .working, tick: 0) == 1, "working should default to slow green flash")
        try expect(
            SignalLampAnimation.intensity(.green, signal: .working, tick: 3) == 0,
            "working slow green flash should turn off later"
        )
        try expect(SignalLampAnimation.intensity(.green, signal: .thinking, tick: 0) == 1, "thinking should default to fast green flash")
        try expect(SignalLampAnimation.intensity(.green, signal: .thinking, tick: 1) == 0, "thinking fast green flash should turn off on the next tick")
        try expect(SignalLampAnimation.intensity(.green, signal: .done, tick: 0) == 1, "done should default to steady green")
        try expect(SignalLampAnimation.intensity(.green, signal: .done, tick: 3) == 1, "done steady green should remain on")
        try expect(SignalLampAnimation.intensity(.yellow, signal: .working, tick: 0) == 0, "active should not show yellow")
        try expect(SignalLampAnimation.intensity(.red, signal: .working, tick: 0) == 0, "active should not show red")

        let trafficCycle = SignalEffectCustomization(activeEffect: .trafficCycle)
        try expect(
            SignalLampAnimation.intensity(.red, signal: .working, tick: 0, customization: trafficCycle) == 1,
            "custom active cycle should start with red"
        )
        try expect(
            SignalLampAnimation.intensity(.yellow, signal: .working, tick: 0, customization: trafficCycle) == 0,
            "custom active cycle should only light red at the first phase"
        )
        try expect(
            SignalLampAnimation.intensity(.yellow, signal: .working, tick: 4, customization: trafficCycle) == 1,
            "custom active cycle should move to yellow"
        )
        try expect(
            SignalLampAnimation.intensity(.red, signal: .working, tick: 4, customization: trafficCycle) == 0,
            "custom active cycle should only light yellow at the second phase"
        )
        try expect(
            SignalLampAnimation.intensity(.green, signal: .working, tick: 8, customization: trafficCycle) == 1,
            "custom active cycle should move to green"
        )
        try expect(
            SignalLampAnimation.intensity(.yellow, signal: .working, tick: 8, customization: trafficCycle) == 0,
            "custom active cycle should only light green at the third phase"
        )

        let greenSteady = SignalEffectCustomization(activeEffect: .greenSteady)
        try expect(
            SignalLampAnimation.intensity(.green, signal: .working, tick: 3, customization: greenSteady) == 1,
            "custom active effect should support steady green"
        )

        let greenSlowFlash = SignalEffectCustomization(activeEffect: .greenSlowFlash)
        try expect(
            SignalLampAnimation.intensity(.green, signal: .working, tick: 0, customization: greenSlowFlash) == 1,
            "custom active slow flash should light green first"
        )
        try expect(
            SignalLampAnimation.intensity(.green, signal: .working, tick: 3, customization: greenSlowFlash) == 0,
            "custom active slow flash should turn green off later"
        )

        let greenFastFlash = SignalEffectCustomization(activeEffect: .greenFastFlash)
        try expect(
            SignalLampAnimation.intensity(.green, signal: .working, tick: 0, customization: greenFastFlash) == 1,
            "custom active fast flash should light green first"
        )
        try expect(
            SignalLampAnimation.intensity(.green, signal: .working, tick: 1, customization: greenFastFlash) == 0,
            "custom active fast flash should turn green off on the next tick"
        )

        let yellowDone = SignalEffectCustomization(completedEffect: .yellowSteady)
        try expect(
            SignalLampAnimation.intensity(.yellow, signal: .done, tick: 0, customization: yellowDone) == 1,
            "custom completed effect should support steady yellow"
        )

        let allDone = SignalEffectCustomization(completedEffect: .allSteady)
        try expect(
            SignalLampAnimation.intensity(.red, signal: .done, tick: 0, customization: allDone) == 1
                && SignalLampAnimation.intensity(.yellow, signal: .done, tick: 0, customization: allDone) == 1
                && SignalLampAnimation.intensity(.green, signal: .done, tick: 0, customization: allDone) == 1,
            "custom completed effect should support all lights steady"
        )

        let allFlash = SignalEffectCustomization(completedEffect: .allPulse)
        try expect(
            SignalLampAnimation.intensity(.red, signal: .done, tick: 0, customization: allFlash) == 1
                && SignalLampAnimation.intensity(.yellow, signal: .done, tick: 0, customization: allFlash) == 1
                && SignalLampAnimation.intensity(.green, signal: .done, tick: 0, customization: allFlash) == 1,
            "custom completed effect should flash all lights together"
        )
        try expect(
            SignalLampAnimation.intensity(.red, signal: .done, tick: 2, customization: allFlash) == 0
                && SignalLampAnimation.intensity(.yellow, signal: .done, tick: 2, customization: allFlash) == 0
                && SignalLampAnimation.intensity(.green, signal: .done, tick: 2, customization: allFlash) == 0,
            "custom completed all-light flash should turn all lights off together"
        )
    }

    private static func checkMacOSBreathingScaleIsPronounced() throws {
        let breathing = SignalEffectCustomization(activeEffect: .greenBreathing)
        let baseScale = SignalLampAnimation.scale(.green, signal: .working, tick: 0, customization: breathing)
        let intensity = SignalLampAnimation.intensity(.green, signal: .working, tick: 0, customization: breathing)
        let lowScale = SignalVisualScale.lampScale(
            baseScale: baseScale,
            intensity: intensity,
            style: .macOS,
            macOSStrength: .maximum
        )
        let highScale = SignalVisualScale.lampScale(
            baseScale: SignalLampAnimation.scale(.green, signal: .working, tick: 5, customization: breathing),
            intensity: SignalLampAnimation.intensity(.green, signal: .working, tick: 5, customization: breathing),
            style: .macOS,
            macOSStrength: .maximum
        )
        let midScale = SignalVisualScale.lampScale(
            baseScale: SignalLampAnimation.scale(.green, signal: .working, tick: 2, customization: breathing),
            intensity: SignalLampAnimation.intensity(.green, signal: .working, tick: 2, customization: breathing),
            style: .macOS,
            macOSStrength: .maximum
        )
        let nearHighScale = SignalVisualScale.lampScale(
            baseScale: SignalLampAnimation.scale(.green, signal: .working, tick: 4, customization: breathing),
            intensity: SignalLampAnimation.intensity(.green, signal: .working, tick: 4, customization: breathing),
            style: .macOS,
            macOSStrength: .maximum
        )

        try expect(lowScale == baseScale, "macOS maximum breathing should match the activity detail lamp")
        try expect(midScale >= 0.74, "macOS maximum breathing should follow the shared detail curve")
        try expect(midScale <= 0.76, "macOS maximum breathing should not use the old tiny-dot curve")
        try expect(nearHighScale >= 0.90, "macOS maximum breathing should become clearly large before the peak")
        try expect(nearHighScale <= 0.92, "macOS maximum breathing should keep a visible step before the full ring")
        try expect(highScale == 1, "macOS maximum breathing should expand to the full ring")
    }

    private static func checkAggregateKeepsPermissionAboveWorkingAndAttention() throws {
        let now = Date().timeIntervalSince1970
        let document = SignalStateDocument(
            sessions: [
                "a": SessionRecord(signal: .working, updatedAt: Date(timeIntervalSince1970: now)),
                "b": SessionRecord(signal: .attention, updatedAt: Date(timeIntervalSince1970: now)),
                "c": SessionRecord(signal: .permission, updatedAt: Date(timeIntervalSince1970: now))
            ]
        )

        try expect(document.aggregateSignal() == .permission, "red priority should win")
    }

    private static func checkBlockedWinsOverPermissionWhenBothArePresent() throws {
        let now = Date().timeIntervalSince1970
        let document = SignalStateDocument(
            sessions: [
                "a": SessionRecord(signal: .permission, updatedAt: Date(timeIntervalSince1970: now)),
                "b": SessionRecord(signal: .blocked, updatedAt: Date(timeIntervalSince1970: now))
            ]
        )

        try expect(document.aggregateSignal() == .blocked, "blocked should win over permission")
    }

    private static func checkV2AggregatePriority() throws {
        let now = Date()

        try expect(
            SignalStateDocument(
                sessions: [
                    "paused": SessionRecord(signal: .off, updatedAt: now),
                    "active": SessionRecord(signal: .working, updatedAt: now)
                ]
            ).aggregateSignal() == .off,
            "paused session should win over active"
        )
        try expect(
            SignalStateDocument(
                aggregate: .off,
                sessions: ["active": SessionRecord(signal: .working, updatedAt: now)]
            ).aggregateSignal() == .working,
            "active session should resume from paused aggregate"
        )
        try expect(
            SignalStateDocument(
                sessions: [
                    "active": SessionRecord(signal: .working, updatedAt: now),
                    "completed": SessionRecord(signal: .done, updatedAt: now)
                ]
            ).aggregateSignal() == .working,
            "active should win over completed"
        )
        try expect(
            SignalStateDocument(
                sessions: [
                    "stale": SessionRecord(signal: .stale, updatedAt: now),
                    "active": SessionRecord(signal: .working, updatedAt: now)
                ]
            ).aggregateSignal() == .stale,
            "stale should win over active"
        )
        try expect(
            SignalStateDocument(
                sessions: [
                    "review": SessionRecord(signal: .attention, updatedAt: now),
                    "stale": SessionRecord(signal: .stale, updatedAt: now)
                ]
            ).aggregateSignal() == .attention,
            "needs_review should win over stale"
        )
    }

    private static func checkTurnEndDoesNotClearRedSession() throws {
        let store = makeStore()

        _ = try store.applySessionSignal(.permission, sessionID: "codex-1")
        let snapshot = try store.applySessionSignal(.turnEnd, sessionID: "codex-1")

        try expect(snapshot.aggregate == .permission, "turn_end should preserve permission")
        try expect(snapshot.sessions.count == 1, "turn_end should leave red session")
    }

    private static func checkStopHooksMapToCompleted() throws {
        try expect(
            CodexHookAdapter.chooseSignal(eventName: "Stop", payload: [:]) == .done,
            "Codex Stop should map to completed done"
        )
        try expect(
            ClaudeHookAdapter.chooseSignal(eventName: "Stop", payload: [:]) == .done,
            "Claude Stop should map to completed done"
        )
        try expect(
            CodexHookAdapter.chooseSignal(eventName: " pre_tool_use ", payload: [:]) == .working,
            "Codex hook event matching should tolerate snake case and whitespace"
        )
        try expect(
            ClaudeHookAdapter.chooseSignal(eventName: "post_tool_use_failure", payload: [:]) == .blocked,
            "Claude hook event matching should tolerate snake case"
        )
        try expect(
            ClaudeHookAdapter.chooseSignal(eventName: "StopFailure", payload: [:]) == .blocked,
            "Claude StopFailure should map to blocked"
        )
        try expect(
            ClaudeHookAdapter.chooseSignal(eventName: "PermissionDenied", payload: [:]) == .blocked,
            "Claude PermissionDenied should map to blocked"
        )
        try expect(
            ClaudeHookAdapter.chooseSignal(eventName: "TaskCreated", payload: [:]) == .subagentStart,
            "Claude TaskCreated should map to subagent start"
        )
        try expect(
            ClaudeHookAdapter.chooseSignal(eventName: "TaskCompleted", payload: [:]) == .subagentStop,
            "Claude TaskCompleted should map to subagent stop"
        )
        try expect(
            ClaudeHookAdapter.chooseSignal(eventName: "PostToolBatch", payload: [:]) == .toolDone,
            "Claude PostToolBatch should map to tool done"
        )
        try expect(
            ClaudeHookAdapter.chooseSignal(eventName: " stop ", payload: ["stop_reason": " max-tokens "]) == .maxTokens,
            "Claude Stop max_tokens reason should tolerate whitespace and separators"
        )
        try expect(
            ClaudeHookAdapter.chooseSignal(eventName: "Stop", payload: ["stopReason": " tool error "]) == .error,
            "Claude Stop error reason should tolerate key style and whitespace"
        )
        try expect(
            CodexHookAdapter.chooseSignal(eventName: nil, payload: ["hookEventName": "post tool use"]) == .toolDone,
            "Codex hook event name key should tolerate camelCase"
        )
        try expect(
            ClaudeHookAdapter.sessionKey(payload: ["sessionId": "claude-camel"], environment: ["CLAUDE_SESSION_ID": "env"]) == "claude-camel",
            "Claude session key should tolerate camelCase"
        )
        try expect(
            ClaudeHookAdapter.eventName(payload: ["hookEventName": "PostToolBatch"]) == "PostToolBatch",
            "Claude event name should tolerate camelCase"
        )
        try expect(
            ClaudeHookAdapter.displayEventName(eventName: "PreToolUse", payload: ["toolName": "Bash"]) == "PreToolUse:Bash",
            "Claude display event should include tool name"
        )
        try expect(
            CodexHookAdapter.chooseSignal(eventName: "PostToolUse", payload: ["exitStatus": 1]) == .blocked,
            "failure marker keys should tolerate camelCase"
        )
    }

    private static func checkGenericHookAdapterMapsOtherAgents() throws {
        try expect(
            GenericHookAdapter.chooseSignal(
                eventName: nil,
                payload: ["event": "AgentStarted", "agent": "local-script", "session_id": "local-script-main"]
            ) == .working,
            "generic hook should map AgentStarted to working"
        )
        try expect(
            GenericHookAdapter.chooseSignal(eventName: "ApprovalRequired", payload: [:]) == .permissionRequest,
            "generic hook should map approval requests to permission"
        )
        try expect(
            GenericHookAdapter.chooseSignal(eventName: nil, payload: ["status": "running"]) == .working,
            "generic hook should map running status to working"
        )
        try expect(
            GenericHookAdapter.chooseSignal(eventName: nil, payload: ["exitStatus": 7]) == .blocked,
            "generic hook should map failure markers to blocked"
        )
        try expect(
            GenericHookAdapter.chooseSignal(eventName: "AgentFinished", payload: [:]) == .done,
            "generic hook should map AgentFinished to done"
        )
        try expect(
            GenericHookAdapter.sessionKey(
                payload: ["agent": "local-script"],
                environment: [:],
                agent: "local-script"
            ) == "local-script:global",
            "generic hook should avoid global collisions when only agent is known"
        )
        try expect(
            GenericHookAdapter.agentName(payload: ["source": "local-agent"], environment: [:]) == "local-agent",
            "generic hook should read agent/source names from payload"
        )
    }

    private static func checkDoneDoesNotClearWarningSession() throws {
        let store = makeStore()

        _ = try store.applySessionSignal(.permission, sessionID: "codex-1")
        let snapshot = try store.applySessionSignal(.done, sessionID: "codex-1")

        try expect(snapshot.aggregate == .permission, "done should not clear permission")
        try expect(snapshot.sessions.first?.signal == .permission, "done should preserve the warning session")
        try expect(snapshot.recentEvents.first?.signal == .done, "done event should still be recorded")
    }

    private static func checkCodexFailurePayloadMapsToBlocked() throws {
        let signal = CodexHookAdapter.chooseSignal(
            eventName: "PostToolUse",
            payload: ["exit_status": 1]
        )

        try expect(signal == .blocked, "non-zero exit status should map to blocked")
    }

    private static func checkClaudeFailurePayloadMapsToBlocked() throws {
        let signal = ClaudeHookAdapter.chooseSignal(
            eventName: "PostToolUse",
            payload: ["exit_status": 1]
        )

        try expect(signal == .blocked, "Claude non-zero exit status should map to blocked")
    }

    private static func checkCodexDesktopSessionParserMapsDesktopEvents() throws {
        let toolLine = """
        {"timestamp":"2026-05-29T02:20:43.081Z","type":"response_item","payload":{"type":"function_call","name":"exec_command"}}
        """
        let doneLine = """
        {"timestamp":"2026-05-29T02:17:58.732Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1"}}
        """
        let userLine = """
        {"timestamp":"2026-05-29T02:18:00.000Z","type":"response_item","payload":{"type":"message","role":"user"}}
        """
        let startedLine = """
        {"timestamp":"2026-05-29T02:18:01.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-2"}}
        """
        let heartbeatLine = """
        {"timestamp":"2026-06-01T15:37:11.108Z","type":"event_msg","payload":{"type":"token_count","info":{"model_context_window":258400}}}
        """
        let compactedLine = """
        {"timestamp":"2026-06-01T15:34:42.602Z","type":"compacted","payload":{"message":"","replacement_history":[]}}
        """

        let toolActivity = CodexDesktopSessionParser.activity(from: toolLine, defaultSessionID: "codex-desktop:test")
        let doneActivity = CodexDesktopSessionParser.activity(from: doneLine, defaultSessionID: "codex-desktop:test")
        let userActivity = CodexDesktopSessionParser.activity(from: userLine, defaultSessionID: "codex-desktop:test")
        let startedActivity = CodexDesktopSessionParser.activity(from: startedLine, defaultSessionID: "codex-desktop:test")
        let heartbeatActivity = CodexDesktopSessionParser.activity(from: heartbeatLine, defaultSessionID: "codex-desktop:test")
        let compactedActivity = CodexDesktopSessionParser.activity(from: compactedLine, defaultSessionID: "codex-desktop:test")

        try expect(toolActivity?.signal == .working, "Desktop function_call should map to working")
        try expect(toolActivity?.event == "DesktopToolCall:exec_command", "Desktop tool name should be retained")
        try expect(doneActivity?.signal == .done, "Desktop task_complete should map to done")
        try expect(userActivity == nil, "Desktop user messages should not map to responding")
        try expect(startedActivity?.signal == .thinking, "Desktop task_started should map to thinking")
        try expect(heartbeatActivity?.signal == .thinking, "Desktop token_count heartbeat should keep Codex active")
        try expect(compactedActivity?.signal == .thinking, "Desktop compacted event should map to thinking")
    }

    private static func checkClearWarningPreservesWorkingSession() throws {
        let store = makeStore()

        _ = try store.applySessionSignal(.working, sessionID: "codex-working")
        _ = try store.applySessionSignal(.permission, sessionID: "codex-permission")
        let snapshot = try store.clearWarnings()

        try expect(snapshot.aggregate == .working, "clear warning should preserve working aggregate")
        try expect(snapshot.sessions.map(\.sessionID) == ["codex-working"], "clear warning should remove only warning sessions")
    }

    private static func checkManualSignalsParticipateInAggregation() throws {
        let store = makeStore()

        _ = try store.applySessionSignal(.permission, sessionID: "codex-permission")
        let snapshot = try store.setManualSignal(.working)

        try expect(snapshot.aggregate == .permission, "manual working should not override permission")
        try expect(
            snapshot.sessions.map(\.sessionID) == ["codex-permission", "manual"],
            "manual signals should be traceable as a session"
        )

        let resetSnapshot = try store.setManualSignal(.idle)
        try expect(resetSnapshot.aggregate == .idle, "manual idle should clear to idle")
        try expect(resetSnapshot.sessions.isEmpty, "manual idle should clear sessions")
    }

    private static func checkNonPausedSignalResumesFromPausedAggregate() throws {
        let store = makeStore()

        _ = try store.applySessionSignal(.off, sessionID: "manual")
        let snapshot = try store.applySessionSignal(.working, sessionID: "codex-main")

        try expect(snapshot.aggregate == .working, "working should resume from paused aggregate")
        try expect(snapshot.sessions.map(\.sessionID) == ["codex-main"], "resume should keep the new active session")
    }

    private static func checkSessionEndRemovesSession() throws {
        let store = makeStore()

        _ = try store.applySessionSignal(.working, sessionID: "codex-main")
        let snapshot = try store.applySessionSignal(.sessionEnd, sessionID: "codex-main")

        try expect(snapshot.aggregate == .idle, "session_end should return to idle when no sessions remain")
        try expect(snapshot.sessions.isEmpty, "session_end should remove the session")
    }

    private static func checkSessionEndPreservesCompletedAndWarningSessions() throws {
        let completedStore = makeStore()

        _ = try completedStore.applySessionSignal(.done, sessionID: "codex-main")
        let completedSnapshot = try completedStore.applySessionSignal(.sessionEnd, sessionID: "codex-main")

        try expect(completedSnapshot.aggregate == .done, "session_end should preserve completed hint")
        try expect(completedSnapshot.sessions.first?.signal == .done, "completed session should remain until completed TTL")

        let warningStore = makeStore()

        _ = try warningStore.applySessionSignal(.blocked, sessionID: "codex-main")
        let warningSnapshot = try warningStore.applySessionSignal(.sessionEnd, sessionID: "codex-main")

        try expect(warningSnapshot.aggregate == .blocked, "session_end should not clear blocked state")
        try expect(warningSnapshot.sessions.first?.signal == .blocked, "blocked session should remain for review")
    }

    private static func checkOffClearsAllSessions() throws {
        let store = makeStore()

        _ = try store.applySessionSignal(.working, sessionID: "codex-a")
        _ = try store.applySessionSignal(.permission, sessionID: "codex-b")
        let snapshot = try store.applySessionSignal(.off, sessionID: "manual")

        try expect(snapshot.aggregate == .off, "off should make aggregate off")
        try expect(snapshot.sessions.isEmpty, "off should clear sessions")
    }

    private static func checkSessionTTLPrunesStaleSessions() throws {
        let store = makeStore(sessionTTLSeconds: 0.01)
        let oldDate = Date(timeIntervalSince1970: 100)

        try writeDocument(
            SignalStateDocument(
                aggregate: .working,
                updatedAt: oldDate,
                sessions: ["codex-main": SessionRecord(signal: .working, updatedAt: oldDate)]
            ),
            in: store
        )
        let snapshot = store.readSnapshot()
        let storedDocument = try storedDocument(in: store)

        try expect(snapshot.aggregate == .stale, "expired sessions should produce stale aggregate")
        try expect(snapshot.sessions.isEmpty, "stale sessions should be pruned from snapshot")
        try expect(storedDocument.aggregate == .stale, "expired sessions should persist stale aggregate")
        try expect(storedDocument.sessions.isEmpty, "expired sessions should be pruned from persisted state")
        try expect(
            (snapshot.updatedAt ?? .distantPast) > oldDate,
            "stale transition should refresh snapshot updated_at"
        )
        try expect(
            (storedDocument.updatedAt ?? .distantPast) > oldDate,
            "stale transition should persist updated_at"
        )
    }

    private static func checkCompletedTTLReturnsToIdle() throws {
        let store = makeStore(completedTTLSeconds: 0.01)
        let oldDate = Date(timeIntervalSince1970: 100)

        try writeDocument(
            SignalStateDocument(
                aggregate: .done,
                updatedAt: oldDate,
                sessions: ["codex-main": SessionRecord(signal: .done, updatedAt: oldDate)]
            ),
            in: store
        )
        let snapshot = store.readSnapshot()
        let storedDocument = try storedDocument(in: store)

        try expect(snapshot.aggregate == .idle, "expired completed sessions should return to idle")
        try expect(snapshot.sessions.isEmpty, "expired completed sessions should be pruned from snapshot")
        try expect(storedDocument.aggregate == .idle, "expired completed sessions should persist idle aggregate")
        try expect(storedDocument.sessions.isEmpty, "expired completed sessions should be pruned from persisted state")
        try expect(
            (snapshot.updatedAt ?? .distantPast) > oldDate,
            "completed transition should refresh snapshot updated_at"
        )
        try expect(
            (storedDocument.updatedAt ?? .distantPast) > oldDate,
            "completed transition should persist updated_at"
        )
    }

    private static func checkRecentEventsAreStoredAndCapped() throws {
        let store = makeStore(eventLimit: 3)

        _ = try store.applySessionSignal(.thinking, sessionID: "codex-main", agent: "codex", lastEvent: "UserPromptSubmit")
        _ = try store.applySessionSignal(.working, sessionID: "codex-main", agent: "codex", lastEvent: "PreToolUse")
        _ = try store.applySessionSignal(.toolDone, sessionID: "codex-main", agent: "codex", lastEvent: "PostToolUse")
        let snapshot = try store.applySessionSignal(.permission, sessionID: "codex-main", agent: "codex", lastEvent: "PermissionRequest")
        let eventNames = Set(snapshot.recentEvents.compactMap(\.event))

        try expect(snapshot.recentEvents.count == 3, "recent events should be capped")
        try expect(snapshot.recentEvents.first?.event == "PermissionRequest", "newest event should be first in snapshot")
        try expect(eventNames.contains("PermissionRequest"), "newest event should be retained")
        try expect(eventNames.contains("PreToolUse"), "retained events should include the oldest in the capped window")
        try expect(!eventNames.contains("UserPromptSubmit"), "oldest overflow event should be dropped")
    }

    private static func checkStateFileSchemaRoundTrip() throws {
        let store = makeStore()

        _ = try store.applySessionSignal(.permission, sessionID: "codex-main", agent: "codex", lastEvent: "PermissionRequest")
        let data = try Data(contentsOf: store.stateFileURL)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        try expect(object?["schema_version"] as? Int == 1, "status JSON should include schema_version")
        try expect(object?["aggregate"] as? String == "permission", "status JSON should include aggregate")
        try expect(object?["updated_at"] is String, "status JSON should include ISO updated_at")
        try expect(object?["sessions"] is [String: Any], "status JSON should include sessions")
        try expect(object?["events"] is [Any], "status JSON should include events")
    }

    private static func checkAllSignalsAreCodable() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let now = Date()

        for signal in AgentSignal.allCases {
            let document = SignalStateDocument(
                aggregate: signal,
                updatedAt: now,
                sessions: [
                    "roundtrip": SessionRecord(signal: signal, updatedAt: now)
                ],
                events: [
                    SignalEventRecord(
                        sessionID: "roundtrip",
                        signal: signal,
                        event: "RoundTrip",
                        updatedAt: now
                    )
                ]
            )

            let data = try encoder.encode(document)
            let decoded = try decoder.decode(SignalStateDocument.self, from: data)

            try expect(decoded.aggregate == signal, "\(signal.rawValue) aggregate should round-trip")
            try expect(decoded.sessions["roundtrip"]?.signal == signal, "\(signal.rawValue) session should round-trip")
            try expect(decoded.events.first?.signal == signal, "\(signal.rawValue) event should round-trip")
        }
    }

    private static func checkLegacyStatusFileCompatibility() throws {
        let store = makeStore()
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let legacyJSON = """
        {
          "aggregate": "working",
          "updated_at": "\(timestamp)",
          "sessions": {
            "legacy": {
              "agent": "codex",
              "signal": "working",
              "last_event": "PreToolUse",
              "updated_at": "\(timestamp)"
            }
          }
        }
        """

        try FileManager.default.createDirectory(
            at: store.stateFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try legacyJSON.write(to: store.stateFileURL, atomically: true, encoding: .utf8)

        let snapshot = store.readSnapshot()

        try expect(snapshot.aggregate == .working, "legacy status file should preserve working aggregate")
        try expect(snapshot.sessions.map(\.sessionID) == ["legacy"], "legacy sessions should decode")
        try expect(snapshot.recentEvents.isEmpty, "legacy files without events should decode with an empty event list")
    }

    private static func checkCorruptStatusFileFallsBackToStale() throws {
        let store = makeStore()
        try FileManager.default.createDirectory(
            at: store.stateFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "{".write(to: store.stateFileURL, atomically: true, encoding: .utf8)

        let snapshot = store.readSnapshot()

        try expect(snapshot.aggregate == .stale, "corrupt status file should fall back to stale")
        try expect(snapshot.sessions.isEmpty, "corrupt status file should not expose sessions")
    }

    private static func checkUnknownSignalIsRejected() throws {
        try expect(AgentSignal.normalized("definitely_unknown") == nil, "unknown signal names should be rejected")
    }

    private static func makeStore(
        sessionTTLSeconds: Double = 60,
        completedTTLSeconds: Double = 90,
        eventLimit: Int = 30
    ) -> SignalStateStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = directory.appendingPathComponent("sessions.json")
        return SignalStateStore(
            stateFileURL: file,
            sessionTTLSeconds: sessionTTLSeconds,
            completedTTLSeconds: completedTTLSeconds,
            eventLimit: eventLimit
        )
    }

    private static func storedDocument(in store: SignalStateStore) throws -> SignalStateDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(contentsOf: store.stateFileURL)
        return try decoder.decode(SignalStateDocument.self, from: data)
    }

    private static func writeDocument(_ document: SignalStateDocument, in store: SignalStateStore) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(
            at: store.stateFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(document).write(to: store.stateFileURL)
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition {
            throw CheckError.failed(message)
        }
    }
}

enum CheckError: Error, LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message):
            return message
        }
    }
}

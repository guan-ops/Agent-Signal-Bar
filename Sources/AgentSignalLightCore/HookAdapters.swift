import Foundation

public enum JSONPayload {
    public static func object(from data: Data) -> [String: Any] {
        (try? requiredObject(from: data)) ?? [:]
    }

    public static func requiredObject(from data: Data) throws -> [String: Any] {
        guard !data.isEmpty else { return [:] }
        let parsed = try JSONSerialization.jsonObject(with: data)
        guard let object = parsed as? [String: Any] else {
            throw JSONPayloadError.topLevelValueIsNotObject
        }
        return object
    }
}

public enum JSONPayloadError: Error, LocalizedError {
    case topLevelValueIsNotObject

    public var errorDescription: String? {
        switch self {
        case .topLevelValueIsNotObject:
            return "Hook JSON payload must be an object."
        }
    }
}

public enum CodexHookAdapter {
    private static let eventToSignal = normalizedEventMap([
        "SessionStart": .sessionStart,
        "UserPromptSubmit": .thinking,
        "PreToolUse": .working,
        "PostToolUse": .toolDone,
        "PermissionRequest": .permissionRequest,
        "Stop": .done,
        "SessionEnd": .sessionEnd
    ])

    public static func chooseSignal(eventName: String?, payload: [String: Any]) -> AgentSignal {
        if let explicit = firstString(payload, keys: ["signal", "signal_name", "lamp_signal"]),
           let signal = AgentSignal.normalized(explicit) {
            return signal
        }

        if let status = firstString(payload, keys: ["status", "state"]) {
            let normalizedStatus = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let signal = AgentSignal.normalized(normalizedStatus) {
                return signal
            }
            if isFailureWord(normalizedStatus) {
                return .blocked
            }
        }

        if containsFailureMarker(payload) {
            return .blocked
        }

        let resolvedEvent = eventName
            ?? firstString(payload, keys: ["hook_event_name", "event_name", "event", "hook", "type"])
            ?? "Stop"
        return signal(for: resolvedEvent, in: eventToSignal) ?? .attention
    }

    public static func sessionKey(payload: [String: Any], environment: [String: String]) -> String {
        let directKeys = [
            "session_id",
            "conversation_id",
            "thread_id",
            "chat_id",
            "codex_session_id"
        ]

        if let explicit = firstString(payload, keys: directKeys) {
            return explicit.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let nested = findNestedString(payload, keys: directKeys) {
            return nested
        }

        for key in ["CODEX_SESSION_ID", "CODEX_CONVERSATION_ID", "CODEX_THREAD_ID"] {
            if let value = environment[key], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        if let cwd = firstString(payload, keys: ["cwd", "workspace", "workspace_dir", "project_dir"]) {
            return "cwd:\(cwd.trimmingCharacters(in: .whitespacesAndNewlines))"
        }

        return "global"
    }
}

public enum ClaudeHookAdapter {
    private static let eventToSignal = normalizedEventMap([
        "ConfigChange": .attention,
        "CwdChanged": .attention,
        "Elicitation": .attention,
        "ElicitationResult": .working,
        "FileChanged": .attention,
        "InstructionsLoaded": .attention,
        "SessionStart": .sessionStart,
        "TaskCreated": .subagentStart,
        "TaskCompleted": .subagentStop,
        "TeammateIdle": .idle,
        "UserPromptExpansion": .thinking,
        "UserPromptSubmit": .thinking,
        "PreToolUse": .working,
        "PostToolBatch": .toolDone,
        "PostToolUse": .toolDone,
        "PostToolUseFailure": .blocked,
        "PreCompact": .working,
        "PostCompact": .toolDone,
        "SubagentStart": .subagentStart,
        "SubagentStop": .subagentStop,
        "PermissionRequest": .permissionRequest,
        "PermissionDenied": .blocked,
        "Notification": .notification,
        "Stop": .done,
        "StopFailure": .blocked,
        "WorktreeCreate": .working,
        "WorktreeRemove": .attention,
        "SessionEnd": .sessionEnd
    ])

    public static func eventName(payload: [String: Any]) -> String? {
        firstString(
            payload,
            keys: ["hook_event_name", "event_name", "event", "hook", "type", "name"]
        ) ?? findNestedString(
            payload,
            keys: ["hook_event_name", "event_name", "event", "hook", "type", "name"]
        )
    }

    public static func displayEventName(eventName: String?, payload: [String: Any]) -> String? {
        let resolvedEvent = eventName ?? self.eventName(payload: payload)
        guard let resolvedEvent else { return nil }

        let normalized = normalizedEventName(resolvedEvent)
        if normalized == normalizedEventName("PreToolUse")
            || normalized == normalizedEventName("PostToolUse")
            || normalized == normalizedEventName("PostToolUseFailure")
        {
            if let toolName = firstString(payload, keys: ["tool_name", "tool", "name"]) {
                return "\(canonicalClaudeEventName(resolvedEvent)):\(toolName.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
        }

        return canonicalClaudeEventName(resolvedEvent)
    }

    public static func chooseSignal(eventName: String?, payload: [String: Any]) -> AgentSignal {
        if let explicit = firstString(payload, keys: ["signal", "signal_name", "lamp_signal"]),
           let signal = AgentSignal.normalized(explicit) {
            return signal
        }

        if let status = firstString(payload, keys: ["status", "state"]) {
            let normalizedStatus = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let signal = AgentSignal.normalized(normalizedStatus) {
                return signal
            }
            if isFailureWord(normalizedStatus) {
                return .blocked
            }
        }

        if containsFailureMarker(payload) {
            return .blocked
        }

        let stopReason = firstString(payload, keys: ["stop_reason"]).map(normalizedEventName)
        let resolvedEvent = eventName
            ?? self.eventName(payload: payload)
            ?? "Stop"
        if normalizedEventName(resolvedEvent) == normalizedEventName("Stop"), let stopReason {
            if stopReason == normalizedEventName("max_tokens") {
                return .maxTokens
            }
            if isFailureWord(stopReason) {
                return .error
            }
        }

        return signal(for: resolvedEvent, in: eventToSignal) ?? .attention
    }

    public static func sessionKey(payload: [String: Any], environment: [String: String]) -> String {
        let directKeys = [
            "session_id",
            "conversation_id",
            "thread_id",
            "chat_id",
            "claude_session_id"
        ]

        if let explicit = firstString(payload, keys: directKeys) {
            return explicit.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let nested = findNestedString(payload, keys: directKeys) {
            return nested
        }

        for key in ["CLAUDE_SESSION_ID", "ANTHROPIC_SESSION_ID"] {
            if let value = environment[key], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        if let transcriptPath = firstString(payload, keys: ["transcript_path"]) {
            let trimmed = transcriptPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return "transcript:\((trimmed as NSString).lastPathComponent)"
            }
        }

        if let cwd = firstString(payload, keys: ["cwd", "workspace", "workspace_dir", "project_dir"]) {
            return "cwd:\(cwd.trimmingCharacters(in: .whitespacesAndNewlines))"
        }

        return "claude-global"
    }
}

public enum GenericHookAdapter {
    private static let eventToSignal = normalizedEventMap([
        "SessionStart": .sessionStart,
        "Start": .working,
        "Started": .working,
        "AgentStarted": .working,
        "TaskStarted": .working,
        "RunStarted": .working,
        "PromptSubmitted": .thinking,
        "UserPromptSubmit": .thinking,
        "Thinking": .thinking,
        "Planning": .thinking,
        "PreToolUse": .working,
        "ToolStart": .working,
        "ToolCall": .working,
        "ToolDone": .toolDone,
        "PostToolUse": .toolDone,
        "ToolFinished": .toolDone,
        "ToolCompleted": .toolDone,
        "NeedsReview": .attention,
        "NeedsAttention": .attention,
        "Attention": .attention,
        "Notification": .notification,
        "PermissionRequest": .permissionRequest,
        "ApprovalRequired": .permissionRequest,
        "RequiresApproval": .permissionRequest,
        "WaitingForApproval": .permissionRequest,
        "Blocked": .blocked,
        "Failed": .blocked,
        "Failure": .blocked,
        "Error": .error,
        "Exception": .exception,
        "Done": .done,
        "Completed": .done,
        "Finished": .done,
        "Succeeded": .done,
        "Success": .done,
        "AgentFinished": .done,
        "TaskFinished": .done,
        "RunFinished": .done,
        "Stop": .done,
        "SessionEnd": .sessionEnd,
        "TurnEnd": .turnEnd,
        "Paused": .paused,
        "Pause": .pause,
        "Off": .off
    ])

    private static let statusToSignal = normalizedEventMap([
        "idle": .idle,
        "ready": .idle,
        "thinking": .thinking,
        "planning": .thinking,
        "working": .working,
        "running": .working,
        "active": .working,
        "busy": .working,
        "pending": .working,
        "waiting": .attention,
        "attention": .attention,
        "needs_review": .attention,
        "needs_attention": .attention,
        "notification": .notification,
        "permission": .permission,
        "permission_required": .permissionRequest,
        "approval_required": .permissionRequest,
        "blocked": .blocked,
        "failed": .blocked,
        "failure": .blocked,
        "error": .error,
        "done": .done,
        "complete": .done,
        "completed": .done,
        "success": .done,
        "succeeded": .done,
        "paused": .paused,
        "off": .off
    ])

    public static func chooseSignal(eventName: String?, payload: [String: Any]) -> AgentSignal {
        if let explicit = firstString(payload, keys: ["signal", "signal_name", "lamp_signal", "agent_signal"]),
           let signal = AgentSignal.normalized(explicit) {
            return signal
        }

        if let status = firstString(payload, keys: ["status", "state", "phase", "result", "outcome"]) {
            if let signal = AgentSignal.normalized(status) {
                return signal
            }
            if let signal = signal(for: status, in: statusToSignal) {
                return signal
            }
            if isFailureWord(status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) {
                return .blocked
            }
        }

        if containsFailureMarker(payload) {
            return .blocked
        }

        let resolvedEvent = eventName
            ?? firstString(payload, keys: ["hook_event_name", "event_name", "event", "hook", "type", "action", "name"])
            ?? "Notification"
        if isFailureWord(resolvedEvent.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) {
            return .blocked
        }
        return signal(for: resolvedEvent, in: eventToSignal) ?? .attention
    }

    public static func sessionKey(
        payload: [String: Any],
        environment: [String: String],
        agent: String? = nil
    ) -> String {
        let directKeys = [
            "session_id",
            "session",
            "conversation_id",
            "thread_id",
            "chat_id",
            "run_id",
            "job_id",
            "task_id",
            "request_id",
            "invocation_id"
        ]

        if let explicit = firstString(payload, keys: directKeys) {
            return explicit.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let nested = findNestedString(payload, keys: directKeys) {
            return nested
        }

        for key in [
            "AGENT_SIGNAL_SESSION_ID",
            "AGENT_SESSION_ID",
            "AI_AGENT_SESSION_ID",
            "SESSION_ID",
            "RUN_ID",
            "TASK_ID"
        ] {
            if let value = environment[key], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        if let cwd = firstString(payload, keys: ["cwd", "workspace", "workspace_dir", "project_dir", "repository"]) {
            return "cwd:\(cwd.trimmingCharacters(in: .whitespacesAndNewlines))"
        }

        let resolvedAgent = agent ?? agentName(payload: payload, environment: environment)
        if !resolvedAgent.isEmpty, resolvedAgent != "agent" {
            return "\(resolvedAgent):global"
        }

        return "global"
    }

    public static func agentName(payload: [String: Any], environment: [String: String]) -> String {
        if let explicit = firstString(
            payload,
            keys: ["agent", "agent_name", "source", "source_name", "app", "application", "client", "tool", "runner", "provider"]
        ) {
            return explicit.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let nested = findNestedString(
            payload,
            keys: ["agent", "agent_name", "source", "source_name", "app", "application", "client", "tool", "runner", "provider"]
        ) {
            return nested
        }

        for key in ["AGENT_SIGNAL_AGENT", "AGENT_NAME", "AGENT_SOURCE", "AI_AGENT_NAME"] {
            if let value = environment[key], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return "agent"
    }
}

private func normalizedEventMap(_ events: [String: AgentSignal]) -> [String: AgentSignal] {
    Dictionary(uniqueKeysWithValues: events.map { key, value in
        (normalizedEventName(key), value)
    })
}

private func signal(for eventName: String?, in events: [String: AgentSignal]) -> AgentSignal? {
    guard let eventName else { return nil }
    return events[normalizedEventName(eventName)]
}

private func normalizedEventName(_ value: String) -> String {
    String(value
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
        .filter { $0.isLetter || $0.isNumber })
}

private func canonicalClaudeEventName(_ value: String) -> String {
    switch normalizedEventName(value) {
    case normalizedEventName("ConfigChange"):
        return "ConfigChange"
    case normalizedEventName("CwdChanged"):
        return "CwdChanged"
    case normalizedEventName("Elicitation"):
        return "Elicitation"
    case normalizedEventName("ElicitationResult"):
        return "ElicitationResult"
    case normalizedEventName("FileChanged"):
        return "FileChanged"
    case normalizedEventName("InstructionsLoaded"):
        return "InstructionsLoaded"
    case normalizedEventName("SessionStart"):
        return "SessionStart"
    case normalizedEventName("TaskCreated"):
        return "TaskCreated"
    case normalizedEventName("TaskCompleted"):
        return "TaskCompleted"
    case normalizedEventName("TeammateIdle"):
        return "TeammateIdle"
    case normalizedEventName("UserPromptExpansion"):
        return "UserPromptExpansion"
    case normalizedEventName("UserPromptSubmit"):
        return "UserPromptSubmit"
    case normalizedEventName("PreToolUse"):
        return "PreToolUse"
    case normalizedEventName("PostToolBatch"):
        return "PostToolBatch"
    case normalizedEventName("PostToolUse"):
        return "PostToolUse"
    case normalizedEventName("PostToolUseFailure"):
        return "PostToolUseFailure"
    case normalizedEventName("PreCompact"):
        return "PreCompact"
    case normalizedEventName("PostCompact"):
        return "PostCompact"
    case normalizedEventName("SubagentStart"):
        return "SubagentStart"
    case normalizedEventName("SubagentStop"):
        return "SubagentStop"
    case normalizedEventName("PermissionRequest"):
        return "PermissionRequest"
    case normalizedEventName("PermissionDenied"):
        return "PermissionDenied"
    case normalizedEventName("Notification"):
        return "Notification"
    case normalizedEventName("Stop"):
        return "Stop"
    case normalizedEventName("StopFailure"):
        return "StopFailure"
    case normalizedEventName("WorktreeCreate"):
        return "WorktreeCreate"
    case normalizedEventName("WorktreeRemove"):
        return "WorktreeRemove"
    case normalizedEventName("SessionEnd"):
        return "SessionEnd"
    default:
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private func firstString(_ payload: [String: Any], keys: [String]) -> String? {
    for key in keys {
        if let value = scalarString(payload[key]),
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return value
        }
    }

    for expectedKey in keys.map(normalizedEventName) {
        for (key, value) in payload where normalizedEventName(key) == expectedKey {
            if let value = scalarString(value),
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
    }

    return nil
}

private func scalarString(_ value: Any?) -> String? {
    switch value {
    case let value as String:
        return value
    case let value as Bool:
        return value ? "true" : "false"
    case let value as NSNumber:
        return value.stringValue
    default:
        return nil
    }
}

private func findNestedString(_ value: Any, keys: [String]) -> String? {
    if let object = value as? [String: Any] {
        if let direct = firstString(object, keys: keys) {
            return direct.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for child in object.values {
            if let found = findNestedString(child, keys: keys) {
                return found
            }
        }
    } else if let array = value as? [Any] {
        for child in array {
            if let found = findNestedString(child, keys: keys) {
                return found
            }
        }
    }
    return nil
}

private func containsFailureMarker(_ value: Any) -> Bool {
    let failureKeys = Set([
        "error",
        "failure",
        "exception",
        "error_type",
        "error_message",
        "failure_reason",
        "exit_status",
        "tool_error"
    ].map(normalizedEventName))

    if let object = value as? [String: Any] {
        for (key, child) in object {
            let normalizedKey = normalizedEventName(key)
            if failureKeys.contains(normalizedKey) || isFailureWord(normalizedKey) {
                if failureValue(child) {
                    return true
                }
            }
            if containsFailureMarker(child) {
                return true
            }
        }
    } else if let array = value as? [Any] {
        return array.contains(where: containsFailureMarker)
    }
    return false
}

private func failureValue(_ value: Any) -> Bool {
    if let bool = value as? Bool {
        return bool
    }
    if let number = value as? NSNumber {
        return number.doubleValue != 0
    }
    if let string = value as? String {
        let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.isEmpty || ["0", "false", "no", "none", "null", "success", "ok"].contains(normalized) {
            return false
        }
        return true
    }
    return !(value is NSNull)
}

private func isFailureWord(_ value: String) -> Bool {
    value.contains("error") || value.contains("failed") || value.contains("failure") || value.contains("exception")
}

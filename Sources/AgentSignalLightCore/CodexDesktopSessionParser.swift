import Foundation

public struct CodexDesktopActivity: Equatable, Sendable {
    public let signal: AgentSignal
    public let sessionID: String
    public let agent: String
    public let event: String
    public let timestamp: Date?

    public init(
        signal: AgentSignal,
        sessionID: String,
        agent: String = "codex-desktop",
        event: String,
        timestamp: Date?
    ) {
        self.signal = signal
        self.sessionID = sessionID
        self.agent = agent
        self.event = event
        self.timestamp = timestamp
    }
}

public struct CodexDesktopQuotaUpdate: Equatable, Sendable {
    public let sessionID: String
    public let agent: String
    public let quota: AgentQuotaStatus
    public let tokenActivityUsage: AgentTokenUsage?
    public let forkedFromSessionID: String?
    public let tokenObservationCursor: CodexTokenObservationCursor?

    public init(
        sessionID: String,
        agent: String,
        quota: AgentQuotaStatus,
        tokenActivityUsage: AgentTokenUsage? = nil,
        forkedFromSessionID: String? = nil,
        tokenObservationCursor: CodexTokenObservationCursor? = nil
    ) {
        self.sessionID = sessionID
        self.agent = agent
        self.quota = quota
        self.tokenActivityUsage = tokenActivityUsage
        self.forkedFromSessionID = forkedFromSessionID
        self.tokenObservationCursor = tokenObservationCursor
    }
}

/// Stable evidence that a live token observation came from a specific complete
/// JSONL line. A usage scan may absorb the observation only after it reports a
/// watermark at or beyond this cursor for the same file generation.
public struct CodexTokenObservationCursor: Codable, Equatable, Hashable, Sendable {
    public let sourceID: String
    public let sourceGeneration: String
    public let sourceStatFingerprint: Int64?
    public let sourceChangeTimeNanoseconds: Int64?
    public let endOffset: UInt64
    public let lineFingerprint: String

    public init(
        sourceID: String,
        sourceGeneration: String,
        sourceStatFingerprint: Int64? = nil,
        sourceChangeTimeNanoseconds: Int64? = nil,
        endOffset: UInt64,
        lineFingerprint: String
    ) {
        self.sourceID = sourceID
        self.sourceGeneration = sourceGeneration
        self.sourceStatFingerprint = sourceStatFingerprint
        self.sourceChangeTimeNanoseconds = sourceChangeTimeNanoseconds
        self.endOffset = endOffset
        self.lineFingerprint = lineFingerprint
    }

    /// FNV-1a is used as a compact corruption/rewrite guard, not as a security
    /// primitive. Both the live tailer and the full scanner hash identical raw
    /// line bytes (without the trailing newline).
    public static func fingerprint(for data: Data) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in data {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}

public enum CodexDesktopSessionParser {
    public static func activity(
        from line: String,
        defaultSessionID: String,
        defaultAgent: String = "codex-desktop"
    ) -> CodexDesktopActivity? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        let timestamp = (object["timestamp"] as? String).flatMap(parseTimestamp)
        let topLevelType = object["type"] as? String
        let payload = object["payload"] as? [String: Any] ?? [:]
        let agent = agentName(in: payload) ?? defaultAgent
        let sessionID = sessionID(in: payload, agent: agent) ?? defaultSessionID

        switch topLevelType {
        case "compacted":
            return CodexDesktopActivity(
                signal: .thinking,
                sessionID: sessionID,
                agent: agent,
                event: "DesktopContextCompacted",
                timestamp: timestamp
            )
        case "event_msg":
            return activityFromEventMessage(
                payload,
                sessionID: sessionID,
                agent: agent,
                timestamp: timestamp
            )
        case "response_item":
            return activityFromResponseItem(
                payload,
                sessionID: sessionID,
                agent: agent,
                timestamp: timestamp
            )
        default:
            return nil
        }
    }

    public static func agentName(fromSessionMetaLine line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["type"] as? String) == "session_meta",
              let payload = object["payload"] as? [String: Any]
        else {
            return nil
        }

        return agentName(in: payload)
    }

    public static func sessionID(fromSessionMetaLine line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["type"] as? String) == "session_meta"
        else {
            return nil
        }
        let payload = object["payload"] as? [String: Any]
        // Subagent metadata can use session_id for its parent while id identifies this session.
        for value in [
            payload?["id"],
            payload?["session_id"],
            payload?["sessionId"],
            object["id"],
            object["session_id"],
            object["sessionId"],
        ] {
            guard let value = value as? String else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    public static func forkedFromSessionID(fromSessionMetaLine line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["type"] as? String) == "session_meta",
              let payload = object["payload"] as? [String: Any]
        else {
            return nil
        }
        for key in ["forked_from_id", "forkedFromId", "parent_session_id", "parentSessionId"] {
            guard let value = payload[key] as? String else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    public static func quotaUpdate(
        from line: String,
        defaultSessionID: String,
        defaultAgent: String = "codex-desktop",
        forkedFromSessionID: String? = nil,
        tokenObservationCursor: CodexTokenObservationCursor? = nil
    ) -> CodexDesktopQuotaUpdate? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["type"] as? String) == "event_msg",
              let payload = object["payload"] as? [String: Any],
              (payload["type"] as? String) == "token_count"
        else {
            return nil
        }

        let timestamp = (object["timestamp"] as? String).flatMap(parseTimestamp) ?? Date()
        let agent = agentName(in: payload) ?? defaultAgent
        let sessionID = sessionID(in: payload, agent: agent) ?? defaultSessionID
        guard let quota = quotaStatus(from: payload, timestamp: timestamp) else {
            return nil
        }
        let info = payload["info"] as? [String: Any]
        let contextWindow = info.flatMap { intValue($0["model_context_window"]) }
        let tokenActivityUsage = (info?["total_token_usage"] as? [String: Any])
            .flatMap { tokenUsage(from: $0, contextWindow: contextWindow) }

        return CodexDesktopQuotaUpdate(
            sessionID: sessionID,
            agent: agent,
            quota: quota,
            tokenActivityUsage: tokenActivityUsage,
            forkedFromSessionID: forkedFromSessionID,
            tokenObservationCursor: tokenObservationCursor
        )
    }

    public static func tokenActivityPoint(from line: String) -> AgentTokenActivityPoint? {
        guard let record = tokenActivityRecord(from: line),
              let usage = record.lastUsage,
              usage.effectiveTotalTokens != nil
        else {
            return nil
        }

        return AgentTokenActivityPoint(timestamp: record.timestamp, usage: usage)
    }

    public static func tokenActivityRecord(from line: String) -> AgentTokenActivityRecord? {
        guard line.contains("token_count"),
              line.contains("token_usage"),
              let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["type"] as? String) == "event_msg",
              let timestamp = (object["timestamp"] as? String).flatMap(parseTimestamp),
              let payload = object["payload"] as? [String: Any],
              (payload["type"] as? String) == "token_count",
              let info = payload["info"] as? [String: Any]
        else {
            return nil
        }

        let lastUsage = (info["last_token_usage"] as? [String: Any])
            .flatMap { tokenUsage(from: $0, contextWindow: intValue(info["model_context_window"])) }
        let totalUsage = (info["total_token_usage"] as? [String: Any])
            .flatMap { tokenUsage(from: $0, contextWindow: intValue(info["model_context_window"])) }

        guard lastUsage?.effectiveTotalTokens != nil || totalUsage?.effectiveTotalTokens != nil else {
            return nil
        }

        return AgentTokenActivityRecord(
            timestamp: timestamp,
            lastUsage: lastUsage,
            totalUsage: totalUsage
        )
    }
}

private extension CodexDesktopSessionParser {
    static func activityFromEventMessage(
        _ payload: [String: Any],
        sessionID: String,
        agent: String,
        timestamp: Date?
    ) -> CodexDesktopActivity? {
        switch payload["type"] as? String {
        case "token_count":
            // Codex writes token-count records both during and after a turn.
            // Treating them as activity causes completed turns to bounce back to
            // "thinking", so they are metadata only.
            return nil
        case "task_started", "user_message":
            return CodexDesktopActivity(
                signal: .thinking,
                sessionID: sessionID,
                agent: agent,
                event: "DesktopTaskStarted",
                timestamp: timestamp
            )
        case "task_complete":
            return CodexDesktopActivity(
                signal: .done,
                sessionID: sessionID,
                agent: agent,
                event: "DesktopTaskComplete",
                timestamp: timestamp
            )
        case "turn_aborted":
            return CodexDesktopActivity(
                signal: .done,
                sessionID: sessionID,
                agent: agent,
                event: "DesktopTurnAborted",
                timestamp: timestamp
            )
        case "agent_message":
            if (payload["phase"] as? String) == "final_answer" {
                return CodexDesktopActivity(
                    signal: .done,
                    sessionID: sessionID,
                    agent: agent,
                    event: "DesktopTaskComplete",
                    timestamp: timestamp
                )
            }
            return CodexDesktopActivity(
                signal: .working,
                sessionID: sessionID,
                agent: agent,
                event: "DesktopMessage",
                timestamp: timestamp
            )
        default:
            return nil
        }
    }

    static func quotaStatus(from payload: [String: Any], timestamp: Date) -> AgentQuotaStatus? {
        let info = payload["info"] as? [String: Any]
        let latestTokenUsage = info.flatMap { tokenUsage(from: $0) }

        if let rateLimits = payload["rate_limits"] as? [String: Any],
           let primary = rateLimits["primary"] as? [String: Any],
           let primaryWindow = quotaWindow(from: primary) {
            let secondaryWindow = (rateLimits["secondary"] as? [String: Any])
                .flatMap { quotaWindow(from: $0) }
            return AgentQuotaStatus(
                remainingPercent: primaryWindow.remainingPercent,
                usedPercent: primaryWindow.usedPercent,
                limitID: stringValue(rateLimits["limit_id"]),
                limitName: stringValue(rateLimits["limit_name"]),
                source: .desktopSession,
                windowMinutes: primaryWindow.windowMinutes,
                resetsAt: primaryWindow.resetsAt,
                updatedAt: timestamp,
                primary: primaryWindow,
                secondary: secondaryWindow,
                tokenUsage: latestTokenUsage
            )
        }

        guard let info,
              let contextWindow = numberValue(info["model_context_window"]),
              contextWindow > 0,
              let lastUsage = info["last_token_usage"] as? [String: Any],
              let inputTokens = numberValue(lastUsage["input_tokens"])
        else {
            return nil
        }

        let usedPercent = min(max(inputTokens / contextWindow * 100, 0), 100)
        return AgentQuotaStatus(
            remainingPercent: 100 - usedPercent,
            usedPercent: usedPercent,
            limitName: "Context",
            source: .desktopSession,
            windowMinutes: nil,
            resetsAt: nil,
            updatedAt: timestamp,
            tokenUsage: latestTokenUsage
        )
    }

    static func tokenUsage(from info: [String: Any]) -> AgentTokenUsage? {
        guard let lastUsage = info["last_token_usage"] as? [String: Any] else {
            return nil
        }

        return tokenUsage(from: lastUsage, contextWindow: intValue(info["model_context_window"]))
    }

    static func tokenUsage(from usagePayload: [String: Any], contextWindow: Int?) -> AgentTokenUsage? {
        let inputTokens = intValue(usagePayload["input_tokens"])
        let cachedInputTokens = intValue(usagePayload["cached_input_tokens"] ?? usagePayload["cache_read_input_tokens"])
        let outputTokens = intValue(usagePayload["output_tokens"])
        let reasoningOutputTokens = intValue(usagePayload["reasoning_output_tokens"])
        let totalTokens = intValue(usagePayload["total_tokens"])

        let usage = AgentTokenUsage(
            inputTokens: inputTokens,
            cachedInputTokens: cachedInputTokens,
            outputTokens: outputTokens,
            reasoningOutputTokens: reasoningOutputTokens,
            totalTokens: totalTokens,
            contextWindowTokens: contextWindow
        )

        if usage.effectiveTotalTokens == nil,
           usage.cachedInputTokens == nil,
           usage.reasoningOutputTokens == nil,
           usage.contextWindowTokens == nil {
            return nil
        }

        return usage
    }

    static func quotaWindow(from payload: [String: Any]) -> AgentQuotaWindowStatus? {
        guard let usedPercent = numberValue(payload["used_percent"]) else {
            return nil
        }

        return AgentQuotaWindowStatus(
            remainingPercent: 100 - usedPercent,
            usedPercent: usedPercent,
            windowMinutes: intValue(payload["window_minutes"]),
            resetsAt: numberValue(payload["resets_at"]).map { Date(timeIntervalSince1970: $0) }
        )
    }

    static func activityFromResponseItem(
        _ payload: [String: Any],
        sessionID: String,
        agent: String,
        timestamp: Date?
    ) -> CodexDesktopActivity? {
        switch payload["type"] as? String {
        case "reasoning":
            return CodexDesktopActivity(
                signal: .thinking,
                sessionID: sessionID,
                agent: agent,
                event: "DesktopThinking",
                timestamp: timestamp
            )
        case "function_call", "custom_tool_call":
            return CodexDesktopActivity(
                signal: toolCallSignal(payload),
                sessionID: sessionID,
                agent: agent,
                event: "DesktopToolCall:\(toolName(in: payload))",
                timestamp: timestamp
            )
        case "function_call_output":
            return CodexDesktopActivity(
                signal: .toolDone,
                sessionID: sessionID,
                agent: agent,
                event: "DesktopToolDone",
                timestamp: timestamp
            )
        case "message":
            if (payload["role"] as? String) == "user" {
                return nil
            }
            if (payload["phase"] as? String) == "final_answer" {
                return CodexDesktopActivity(
                    signal: .done,
                    sessionID: sessionID,
                    agent: agent,
                    event: "DesktopTaskComplete",
                    timestamp: timestamp
                )
            }
            return CodexDesktopActivity(
                signal: .working,
                sessionID: sessionID,
                agent: agent,
                event: "DesktopMessage",
                timestamp: timestamp
            )
        default:
            return nil
        }
    }

    static func toolCallSignal(_ payload: [String: Any]) -> AgentSignal {
        let name = toolName(in: payload).lowercased()
        if requiresEscalatedApproval(payload) {
            return .permissionRequest
        }
        if name == "request_user_input" {
            return .attention
        }
        return .working
    }

    static func requiresEscalatedApproval(_ payload: [String: Any]) -> Bool {
        if let arguments = payload["arguments"] as? [String: Any],
           (arguments["sandbox_permissions"] as? String) == "require_escalated" {
            return true
        }

        guard let arguments = payload["arguments"] as? String,
              arguments.contains("sandbox_permissions"),
              arguments.contains("require_escalated")
        else {
            return false
        }

        if let data = arguments.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return (object["sandbox_permissions"] as? String) == "require_escalated"
        }

        return arguments.contains(#""sandbox_permissions":"require_escalated""#)
            || arguments.contains(#""sandbox_permissions": "require_escalated""#)
    }

    static func toolName(in payload: [String: Any]) -> String {
        guard let name = payload["name"] as? String,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return "tool"
        }
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func sessionID(in payload: [String: Any], agent: String) -> String? {
        for key in ["threadId", "thread_id", "conversationId", "conversation_id"] {
            if let value = payload[key] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "\(sessionPrefix(for: agent)):\(value.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
        }
        return nil
    }

    static func agentName(in payload: [String: Any]) -> String? {
        let source = stringValue(
            in: payload,
            keys: ["source", "client", "app", "application", "entrypoint", "runner"]
        )?.lowercased() ?? ""
        let originator = stringValue(in: payload, keys: ["originator"])?.lowercased() ?? ""
        let combined = [source, originator].filter { !$0.isEmpty }.joined(separator: " ")

        if containsAny(source, tokens: ["exec", "cli", "terminal", "shell", "tui"]) {
            return "codex-cli"
        }
        if containsAny(originator, tokens: ["xcode"]) {
            return "codex-xcode"
        }
        if containsAny(originator, tokens: ["idea", "intellij"]) {
            return "codex-idea"
        }
        if containsAny(originator, tokens: ["jetbrains"]) {
            return "codex-jetbrains"
        }
        if containsAny(originator, tokens: ["codex desktop"]) {
            return "codex-desktop"
        }
        if containsAny(combined, tokens: ["idea", "intellij"]) {
            return "codex-idea"
        }
        if containsAny(combined, tokens: ["jetbrains"]) {
            return "codex-jetbrains"
        }
        if containsAny(combined, tokens: ["visual studio code", "vscode", "vs-code"]) {
            return "codex-vscode"
        }
        if containsAny(combined, tokens: ["xcode"]) {
            return "codex-xcode"
        }
        if containsAny(combined, tokens: ["ide"]) {
            return "codex-ide"
        }
        if containsAny(combined, tokens: ["desktop", "app"]) {
            return "codex-desktop"
        }
        return nil
    }

    static func sessionPrefix(for agent: String) -> String {
        switch agent.lowercased() {
        case "codex-cli":
            return "codex-cli"
        case "codex-idea", "codex-intellij":
            return "codex-idea"
        case "codex-jetbrains":
            return "codex-jetbrains"
        case "codex-vscode":
            return "codex-vscode"
        case "codex-xcode":
            return "codex-xcode"
        case "codex-ide":
            return "codex-ide"
        default:
            return "codex-desktop"
        }
    }

    static func stringValue(in payload: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = payload[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }

    static func stringValue(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func numberValue(_ value: Any?) -> Double? {
        switch value {
        case let value as Double:
            return value
        case let value as Float:
            return Double(value)
        case let value as Int:
            return Double(value)
        case let value as NSNumber:
            return value.doubleValue
        case let value as String:
            return Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    static func intValue(_ value: Any?) -> Int? {
        numberValue(value).map { Int($0) }
    }

    static func containsAny(_ value: String, tokens: [String]) -> Bool {
        tokens.contains { value.contains($0) }
    }

    static func parseTimestamp(_ value: String) -> Date? {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: value) {
            return date
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

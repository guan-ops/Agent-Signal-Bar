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

    public init(sessionID: String, agent: String, quota: AgentQuotaStatus) {
        self.sessionID = sessionID
        self.agent = agent
        self.quota = quota
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

    public static func quotaUpdate(
        from line: String,
        defaultSessionID: String,
        defaultAgent: String = "codex-desktop"
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

        return CodexDesktopQuotaUpdate(sessionID: sessionID, agent: agent, quota: quota)
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
                limitName: stringValue(rateLimits["limit_name"]),
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
        if name == "request_user_input" {
            return .attention
        }
        return .working
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

import Foundation

public struct CodexDesktopActivity: Equatable, Sendable {
    public let signal: AgentSignal
    public let sessionID: String
    public let event: String
    public let timestamp: Date?

    public init(signal: AgentSignal, sessionID: String, event: String, timestamp: Date?) {
        self.signal = signal
        self.sessionID = sessionID
        self.event = event
        self.timestamp = timestamp
    }
}

public enum CodexDesktopSessionParser {
    public static func activity(from line: String, defaultSessionID: String) -> CodexDesktopActivity? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        let timestamp = (object["timestamp"] as? String).flatMap(parseTimestamp)
        let topLevelType = object["type"] as? String
        let payload = object["payload"] as? [String: Any] ?? [:]
        let sessionID = sessionID(in: payload) ?? defaultSessionID

        switch topLevelType {
        case "compacted":
            return CodexDesktopActivity(
                signal: .thinking,
                sessionID: sessionID,
                event: "DesktopContextCompacted",
                timestamp: timestamp
            )
        case "event_msg":
            return activityFromEventMessage(
                payload,
                sessionID: sessionID,
                timestamp: timestamp
            )
        case "response_item":
            return activityFromResponseItem(
                payload,
                sessionID: sessionID,
                timestamp: timestamp
            )
        default:
            return nil
        }
    }
}

private extension CodexDesktopSessionParser {
    static func activityFromEventMessage(
        _ payload: [String: Any],
        sessionID: String,
        timestamp: Date?
    ) -> CodexDesktopActivity? {
        switch payload["type"] as? String {
        case "token_count":
            return CodexDesktopActivity(
                signal: .thinking,
                sessionID: sessionID,
                event: "DesktopActivityHeartbeat",
                timestamp: timestamp
            )
        case "task_started", "user_message":
            return CodexDesktopActivity(
                signal: .thinking,
                sessionID: sessionID,
                event: "DesktopTaskStarted",
                timestamp: timestamp
            )
        case "task_complete":
            return CodexDesktopActivity(
                signal: .done,
                sessionID: sessionID,
                event: "DesktopTaskComplete",
                timestamp: timestamp
            )
        case "turn_aborted":
            return CodexDesktopActivity(
                signal: .done,
                sessionID: sessionID,
                event: "DesktopTurnAborted",
                timestamp: timestamp
            )
        case "agent_message":
            if (payload["phase"] as? String) == "final_answer" {
                return CodexDesktopActivity(
                    signal: .done,
                    sessionID: sessionID,
                    event: "DesktopTaskComplete",
                    timestamp: timestamp
                )
            }
            return CodexDesktopActivity(
                signal: .working,
                sessionID: sessionID,
                event: "DesktopMessage",
                timestamp: timestamp
            )
        default:
            return nil
        }
    }

    static func activityFromResponseItem(
        _ payload: [String: Any],
        sessionID: String,
        timestamp: Date?
    ) -> CodexDesktopActivity? {
        switch payload["type"] as? String {
        case "reasoning":
            return CodexDesktopActivity(
                signal: .thinking,
                sessionID: sessionID,
                event: "DesktopThinking",
                timestamp: timestamp
            )
        case "function_call", "custom_tool_call":
            return CodexDesktopActivity(
                signal: toolCallSignal(payload),
                sessionID: sessionID,
                event: "DesktopToolCall:\(toolName(in: payload))",
                timestamp: timestamp
            )
        case "function_call_output":
            return CodexDesktopActivity(
                signal: .toolDone,
                sessionID: sessionID,
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
                    event: "DesktopTaskComplete",
                    timestamp: timestamp
                )
            }
            return CodexDesktopActivity(
                signal: .working,
                sessionID: sessionID,
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

    static func sessionID(in payload: [String: Any]) -> String? {
        for key in ["threadId", "thread_id", "conversationId", "conversation_id"] {
            if let value = payload[key] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "codex-desktop:\(value.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
        }
        return nil
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

import AgentSignalLightCore
import Foundation

struct ParsedArguments {
    var positionals: [String] = []
    var sessionID: String?
    var agent: String?
    var event: String?
    var printsJSON = false
}

@main
struct AgentSignalCLI {
    static func main() throws {
        let exitCode = run(arguments: Array(CommandLine.arguments.dropFirst()))
        if exitCode != 0 {
            Foundation.exit(Int32(exitCode))
        }
    }

    private static func run(arguments: [String]) -> Int {
        guard let command = arguments.first else {
            printUsage()
            return 0
        }

        let store = SignalStateStore()

        do {
            switch command {
            case "help", "--help", "-h":
                printUsage()
            case "list":
                printSignalList()
            case "status":
                let parsed = try parse(Array(arguments.dropFirst()))
                try requireNoPositionals(parsed)
                printStatus(store.readSnapshot(), asJSON: parsed.printsJSON)
            case "reset", "clear-all":
                let parsed = try parse(Array(arguments.dropFirst()))
                try requireNoPositionals(parsed)
                let snapshot = try store.clearSessions()
                printStatus(snapshot, asJSON: parsed.printsJSON)
            case "set", "play":
                let parsed = try parse(Array(arguments.dropFirst()))
                guard let rawSignal = parsed.positionals.first,
                      let signal = AgentSignal.normalized(rawSignal)
                else {
                    throw CLIError.message("Missing or unknown signal.")
                }
                try requirePositionals(parsed, count: 1)

                let snapshot: SignalSnapshot
                if let sessionID = parsed.sessionID {
                    snapshot = try store.applySessionSignal(
                        signal,
                        sessionID: sessionID,
                        agent: parsed.agent,
                        lastEvent: parsed.event
                    )
                } else {
                    snapshot = try store.setManualSignal(signal)
                }
                printStatus(snapshot, asJSON: parsed.printsJSON)
            case "session":
                let parsed = try parse(Array(arguments.dropFirst()))
                guard let rawSignal = parsed.positionals.first,
                      let signal = AgentSignal.normalized(rawSignal)
                else {
                    throw CLIError.message("Missing or unknown session signal.")
                }
                try requirePositionals(parsed, count: 1)
                let sessionID = parsed.sessionID ?? "global"
                let snapshot = try store.applySessionSignal(
                    signal,
                    sessionID: sessionID,
                    agent: parsed.agent,
                    lastEvent: parsed.event
                )
                printStatus(snapshot, asJSON: parsed.printsJSON)
            case "codex-hook":
                let parsed = try parse(Array(arguments.dropFirst()))
                try requireAtMostOnePositional(parsed)
                let payload = try JSONPayload.requiredObject(from: FileHandle.standardInput.readDataToEndOfFile())
                let eventName = parsed.positionals.first
                    ?? stringValue(payload, keys: ["hook_event_name", "event_name", "event", "hook", "type"])
                let signal = CodexHookAdapter.chooseSignal(eventName: eventName, payload: payload)
                let agent = parsed.agent
                    ?? CodexHookAdapter.agentName(payload: payload, environment: ProcessInfo.processInfo.environment)
                let rawSessionID = parsed.sessionID
                    ?? CodexHookAdapter.sessionKey(payload: payload, environment: ProcessInfo.processInfo.environment)
                let sessionID = parsed.sessionID
                    ?? CodexHookAdapter.sourceScopedSessionKey(rawSessionID, agent: agent)
                _ = try store.applySessionSignal(
                    signal,
                    sessionID: sessionID,
                    agent: agent,
                    lastEvent: parsed.event ?? eventName
                )
            case "claude-hook":
                let parsed = try parse(Array(arguments.dropFirst()))
                try requireAtMostOnePositional(parsed)
                let payload = try JSONPayload.requiredObject(from: FileHandle.standardInput.readDataToEndOfFile())
                let eventName = parsed.positionals.first
                    ?? ClaudeHookAdapter.eventName(payload: payload)
                let signal = ClaudeHookAdapter.chooseSignal(eventName: eventName, payload: payload)
                let sessionID = parsed.sessionID
                    ?? ClaudeHookAdapter.sessionKey(payload: payload, environment: ProcessInfo.processInfo.environment)
                _ = try store.applySessionSignal(
                    signal,
                    sessionID: sessionID,
                    agent: parsed.agent ?? "claude-code",
                    lastEvent: parsed.event ?? ClaudeHookAdapter.displayEventName(eventName: eventName, payload: payload)
                )
            case "agent-hook", "generic-hook", "hook":
                let parsed = try parse(Array(arguments.dropFirst()))
                try requireAtMostOnePositional(parsed)
                let payload = try JSONPayload.requiredObject(from: FileHandle.standardInput.readDataToEndOfFile())
                let eventName = parsed.positionals.first
                    ?? stringValue(payload, keys: ["hook_event_name", "event_name", "event", "hook", "type", "action", "name"])
                let signal = GenericHookAdapter.chooseSignal(eventName: eventName, payload: payload)
                let agent = parsed.agent
                    ?? GenericHookAdapter.agentName(payload: payload, environment: ProcessInfo.processInfo.environment)
                let sessionID = parsed.sessionID
                    ?? GenericHookAdapter.sessionKey(
                        payload: payload,
                        environment: ProcessInfo.processInfo.environment,
                        agent: agent
                    )
                _ = try store.applySessionSignal(
                    signal,
                    sessionID: sessionID,
                    agent: agent,
                    lastEvent: parsed.event ?? eventName
                )
            default:
                if let signal = AgentSignal.normalized(command) {
                    let parsed = try parse(Array(arguments.dropFirst()))
                    try requireNoPositionals(parsed)
                    let snapshot: SignalSnapshot
                    if let sessionID = parsed.sessionID {
                        snapshot = try store.applySessionSignal(
                            signal,
                            sessionID: sessionID,
                            agent: parsed.agent,
                            lastEvent: parsed.event
                        )
                    } else {
                        snapshot = try store.setManualSignal(signal)
                    }
                    printStatus(snapshot, asJSON: parsed.printsJSON)
                } else {
                    throw CLIError.message("Unknown command: \(command)")
                }
            }
            return 0
        } catch {
            fputs("\(commandName()): \(error.localizedDescription)\n", stderr)
            return 1
        }
    }
}

private enum CLIError: Error, LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let value):
            return value
        }
    }
}

private func parse(_ arguments: [String]) throws -> ParsedArguments {
    var parsed = ParsedArguments()
    var index = 0

    while index < arguments.count {
        let value = arguments[index]
        switch value {
        case "--session", "-s":
            parsed.sessionID = try optionValue(arguments, after: index, option: value)
            index += 2
        case "--agent", "--source":
            parsed.agent = try optionValue(arguments, after: index, option: value)
            index += 2
        case "--event", "--label":
            parsed.event = try optionValue(arguments, after: index, option: value)
            index += 2
        case "--json", "-j":
            parsed.printsJSON = true
            index += 1
        default:
            if value.hasPrefix("-") {
                throw CLIError.message("Unknown option: \(value)")
            }
            parsed.positionals.append(value)
            index += 1
        }
    }

    return parsed
}

private func optionValue(_ arguments: [String], after index: Int, option: String) throws -> String {
    guard index + 1 < arguments.count else {
        throw CLIError.message("Missing value for \(option).")
    }

    let value = arguments[index + 1]
    guard !value.hasPrefix("-") else {
        throw CLIError.message("Missing value for \(option).")
    }
    return value
}

private func requireNoPositionals(_ parsed: ParsedArguments) throws {
    guard parsed.positionals.isEmpty else {
        throw CLIError.message("Unexpected argument: \(parsed.positionals[0])")
    }
}

private func requireAtMostOnePositional(_ parsed: ParsedArguments) throws {
    guard parsed.positionals.count <= 1 else {
        throw CLIError.message("Unexpected argument: \(parsed.positionals[1])")
    }
}

private func requirePositionals(_ parsed: ParsedArguments, count: Int) throws {
    guard parsed.positionals.count == count else {
        if parsed.positionals.count < count {
            throw CLIError.message("Missing argument.")
        }
        throw CLIError.message("Unexpected argument: \(parsed.positionals[count])")
    }
}

private func stringValue(_ payload: [String: Any], keys: [String]) -> String? {
    for key in keys {
        if let value = scalarString(payload[key]),
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return value
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

private func commandName() -> String {
    URL(fileURLWithPath: CommandLine.arguments.first ?? "agent-signal-light").lastPathComponent
}

private func printUsage() {
    let command = commandName()
    print(
        """
        \(command)

        Usage:
          \(command) list
          \(command) status [--json]
          \(command) <signal> [--session <id>] [--agent <name>] [--event <event>] [--json]
          \(command) set <signal> [--json]
          \(command) session <signal> --session <id> [--json]
          \(command) codex-hook [event]
          \(command) claude-hook [event]
          \(command) agent-hook [event] [--agent <name>] [--session <id>]
          \(command) reset [--json]

        Examples:
          \(command) idle
          \(command) working --session codex-main --agent codex --event PreToolUse
          echo '{"event":"AgentStarted","agent":"local-script","session_id":"local-script-main"}' | \(command) agent-hook
          \(command) status --json
          \(command) permission --session codex-main --event PermissionRequest

        Signals:
          idle, thinking, working, tool_done, subagent_start, subagent_stop,
          attention, notification, done, permission, permission_request,
          blocked, failure, error, exception, max_tokens, stale,
          session_start, session_end, turn_end, off, pause, paused
        """
    )
}

private func printSignalList() {
    for signal in AgentSignal.allCases {
        print("\(signal.rawValue)\t\(signal.displayState.rawValue)\t\(signal.displayName)\t\(signal.humanAction)")
    }
}

private func printStatus(_ snapshot: SignalSnapshot, asJSON: Bool = false) {
    if asJSON {
        printStatusJSON(snapshot)
        return
    }

    print("aggregate: \(snapshot.aggregate.rawValue) (\(snapshot.aggregate.displayName))")
    print("action: \(snapshot.aggregate.humanAction)")
    print("state_file: \(snapshot.stateFileURL.path)")
    if let updatedAt = snapshot.updatedAt {
        print("updated_at: \(updatedAt.formatted(date: .numeric, time: .standard))")
    }

    if snapshot.sessions.isEmpty {
        print("sessions: none")
    } else {
        print("sessions:")
        for session in snapshot.sessions {
            let agent = session.agent.map { " agent=\($0)" } ?? ""
            let event = session.lastEvent.map { " event=\($0)" } ?? ""
            print("- \(session.sessionID): \(session.signal.rawValue)\(agent)\(event)")
        }
    }

    if !snapshot.recentEvents.isEmpty {
        print("recent_events:")
        for event in snapshot.recentEvents.prefix(10) {
            let agent = event.agent.map { " agent=\($0)" } ?? ""
            let eventName = event.event.map { " event=\($0)" } ?? ""
            print("- \(event.sessionID): \(event.signal.rawValue)\(agent)\(eventName)")
        }
    }
}

private func printStatusJSON(_ snapshot: SignalSnapshot) {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

    do {
        let data = try encoder.encode(StatusOutput(snapshot: snapshot))
        if let output = String(data: data, encoding: .utf8) {
            print(output)
        }
    } catch {
        fputs("\(commandName()): \(error.localizedDescription)\n", stderr)
    }
}

private struct StatusOutput: Encodable {
    let schemaVersion: Int
    let aggregate: AgentSignal
    let displayState: DisplayState
    let lampState: LampState
    let priority: Int
    let displayName: String
    let summary: String
    let action: String
    let stateFile: String
    let updatedAt: Date?
    let sessions: [SessionOutput]
    let recentEvents: [RecentEventOutput]

    init(snapshot: SignalSnapshot) {
        schemaVersion = 1
        aggregate = snapshot.aggregate
        displayState = snapshot.aggregate.displayState
        lampState = snapshot.aggregate.lampState
        priority = snapshot.aggregate.priority
        displayName = snapshot.aggregate.displayName
        summary = snapshot.aggregate.summary
        action = snapshot.aggregate.humanAction
        stateFile = snapshot.stateFileURL.path
        updatedAt = snapshot.updatedAt
        sessions = snapshot.sessions.map(SessionOutput.init)
        recentEvents = snapshot.recentEvents.map(RecentEventOutput.init)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case aggregate
        case displayState = "display_state"
        case lampState = "lamp_state"
        case priority
        case displayName = "display_name"
        case summary
        case action
        case stateFile = "state_file"
        case updatedAt = "updated_at"
        case sessions
        case recentEvents = "recent_events"
    }
}

private struct SessionOutput: Encodable {
    let sessionID: String
    let agent: String?
    let signal: AgentSignal
    let lastEvent: String?
    let updatedAt: Date

    init(session: SessionStatus) {
        sessionID = session.sessionID
        agent = session.agent
        signal = session.signal
        lastEvent = session.lastEvent
        updatedAt = session.updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case agent
        case signal
        case lastEvent = "last_event"
        case updatedAt = "updated_at"
    }
}

private struct RecentEventOutput: Encodable {
    let id: String
    let sessionID: String
    let agent: String?
    let signal: AgentSignal
    let event: String?
    let updatedAt: Date

    init(event: RecentSignalEvent) {
        id = event.id
        sessionID = event.sessionID
        agent = event.agent
        signal = event.signal
        self.event = event.event
        updatedAt = event.updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case sessionID = "session_id"
        case agent
        case signal
        case event
        case updatedAt = "updated_at"
    }
}

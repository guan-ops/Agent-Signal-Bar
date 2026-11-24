// Golden generator for the Codex data layer: compiled with Sources/AgentSignalLightCore/*.swift
// by tests/golden/generate.sh. Prints parser results for lines.jsonl and the snapshots of
// SignalStateStore after scripted event sequences; tst_codex.cpp replays both.
import Foundation

func orNull(_ value: String?) -> Any { value.map { $0 as Any } ?? NSNull() }

func emit(_ row: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
    print(String(data: data, encoding: .utf8)!)
}

func ms(_ date: Date?) -> Any {
    guard let date else { return NSNull() }
    return Int64((date.timeIntervalSince1970 * 1000).rounded())
}

let linesURL = URL(fileURLWithPath: CommandLine.arguments[1])
let lines = try! String(contentsOf: linesURL, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
    .map(String.init).filter { !$0.isEmpty }

for (index, line) in lines.enumerated() {
    for agent in ["codex-desktop", "codex-cli"] {
        var row: [String: Any] = ["kind": "activity", "line": index, "defaultAgent": agent]
        if let a = CodexDesktopSessionParser.activity(from: line, defaultSessionID: "default-session", defaultAgent: agent) {
            row["result"] = ["signal": a.signal.rawValue, "sessionID": a.sessionID, "agent": a.agent,
                             "event": a.event, "timestamp": ms(a.timestamp)]
        } else {
            row["result"] = NSNull()
        }
        emit(row)
    }
    emit(["kind": "meta", "line": index,
          "agent": orNull(CodexDesktopSessionParser.agentName(fromSessionMetaLine: line)),
          "sessionID": orNull(CodexDesktopSessionParser.sessionID(fromSessionMetaLine: line)),
          "forkedFrom": orNull(CodexDesktopSessionParser.forkedFromSessionID(fromSessionMetaLine: line))])
}

// Claude Code hook payloads (ClaudeHookAdapter), as agent-signal claude-hook resolves them.
let claudeURL = URL(fileURLWithPath: CommandLine.arguments[3])
let claudeLines = try! String(contentsOf: claudeURL, encoding: .utf8).split(separator: "\n").map(String.init)
for (index, line) in claudeLines.enumerated() {
    let fixture = try! JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
    let env = fixture["env"] as! [String: String]
    let payload = fixture["payload"] as! [String: Any]
    let eventName = (fixture["event"] as? String) ?? ClaudeHookAdapter.eventName(payload: payload)
    emit(["kind": "claude", "line": index,
          "signal": ClaudeHookAdapter.chooseSignal(eventName: eventName, payload: payload).rawValue,
          "sessionID": ClaudeHookAdapter.sessionKey(payload: payload, environment: env),
          "agent": ClaudeHookAdapter.agentName(environment: env),
          "event": orNull(ClaudeHookAdapter.displayEventName(eventName: eventName, payload: payload))])
}

// Store sequences. Event dates are whole seconds before `base`; the store prunes against the
// real clock, which stays well under a second from `base` while this runs. The state file
// encodes dates with second precision, so whole seconds keep the replay exact.
struct Step {
    let offset: Int // seconds relative to base; nil-equivalent "read" when signal is empty
    let signal: String
    let session: String
    let agent: String
    let event: String
}

func s(_ offset: Int, _ signal: String, _ session: String = "codex-desktop:s1", _ event: String = "", agent: String = "codex-desktop") -> Step {
    Step(offset: offset, signal: signal, session: session, agent: agent, event: event)
}
let read = Step(offset: 0, signal: "", session: "", agent: "", event: "")

let scenarios: [(String, [Step])] = [
    ("turn", [s(-60, "thinking", "codex-desktop:s1", "DesktopTaskStarted"), s(-50, "working", "codex-desktop:s1", "DesktopToolCall:shell"),
              s(-45, "tool_done", "codex-desktop:s1", "DesktopToolDone"), s(-40, "done", "codex-desktop:s1", "DesktopTaskComplete"), read]),
    ("recentDone", [s(-20, "working", "codex-desktop:s1", "DesktopMessage"), s(-10, "done", "codex-desktop:s1", "DesktopTaskComplete"), read]),
    ("stale", [s(-1900, "working", "codex-cli:s2", "DesktopToolCall:shell", agent: "codex-cli"), read]),
    ("expiredIdle", [s(-1900, "session_start", "codex-cli:s2", "SessionStart", agent: "codex-cli"), read]),
    ("permissionHold", [s(-20, "permission_request", "codex-desktop:s1", "DesktopToolCall:shell"), s(-17, "working", "codex-desktop:s1", "DesktopMessage"),
                        s(-10, "working", "codex-desktop:s1", "DesktopToolCall:shell"), read]),
    ("outOfOrder", [s(-10, "working", "codex-desktop:s1", "DesktopToolCall:shell"), s(-20, "thinking", "codex-desktop:s1", "DesktopThinking"), read]),
    ("completedReplay", [s(-10, "done", "codex-desktop:s1", "DesktopTaskComplete"), s(-5, "working", "codex-desktop:s1", "DesktopMessage"),
                         s(-3, "thinking", "codex-desktop:s1", "DesktopTaskStarted"), read]),
    ("blockedPreserved", [s(-10, "blocked", "codex-cli:s1", "StopFailure"), s(-8, "done", "codex-cli:s1", "Stop"),
                          s(-6, "turn_end", "codex-cli:s1", "TurnEnd"), s(-4, "session_end", "codex-cli:s1", "SessionEnd"), read]),
    ("multiSession", [s(-10, "working", "codex-desktop:s1", "DesktopMessage"), s(-8, "attention", "codex-cli:s2", "Notification"),
                      s(-7, "session_end", "codex-cli:s2", "SessionEnd"), s(-6, "session_end", "codex-desktop:s1", "SessionEnd"),
                      s(-5, "off", "manual", "Off"), s(-4, "thinking", "codex-desktop:s1", "DesktopTaskStarted"), read]),
    ("dedupe", [s(-10, "working", "codex-desktop:s1", "DesktopToolCall:shell"), s(-8, "working", "codex-desktop:s1", "DesktopToolCall:shell"),
                s(-2, "working", "codex-desktop:s1", "DesktopToolCall:shell"), read]),
    ("sessionStart", [s(-10, "session_start", "codex-desktop:s1", "SessionStart"), s(-5, "idle", "codex-desktop:s2", ""), read]),
]

let base = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
let stateDirectory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
try? FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)

for (name, steps) in scenarios {
    let file = stateDirectory.appendingPathComponent("\(name).json")
    try? FileManager.default.removeItem(at: file)
    let store = SignalStateStore(stateFileURL: file)
    for (index, step) in steps.enumerated() {
        let snapshot: SignalSnapshot
        if step.signal.isEmpty {
            snapshot = store.readSnapshot()
        } else {
            snapshot = try! store.applySessionSignal(AgentSignal(rawValue: step.signal)!, sessionID: step.session,
                agent: step.agent, lastEvent: step.event.isEmpty ? nil : step.event,
                updatedAt: base.addingTimeInterval(TimeInterval(step.offset)))
        }
        let rel: (Date) -> Int = { Int(($0.timeIntervalSince(base)).rounded()) }
        emit(["kind": "store", "scenario": name, "step": index,
              "input": ["offset": step.offset, "signal": step.signal, "session": step.session, "agent": step.agent, "event": step.event],
              "aggregate": snapshot.aggregate.rawValue,
              "sessions": snapshot.sessions.map { ["id": $0.sessionID, "signal": $0.signal.rawValue,
                                                   "event": $0.lastEvent ?? "", "offset": rel($0.updatedAt)] },
              "events": snapshot.recentEvents.map { ["session": $0.sessionID, "signal": $0.signal.rawValue,
                                                     "event": $0.event ?? "", "offset": rel($0.updatedAt)] }])
    }
}

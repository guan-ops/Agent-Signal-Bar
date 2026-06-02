import AgentSignalLightCore
import Foundation

enum ActivitySessionRuntimeKind {
    case desktop
    case cli
    case local
}

enum ActivityPresentation {
    static let currentSessionLimit = 4
    private static let liveSessionWindow: TimeInterval = 5 * 60

    static func visibleSessions(
        from snapshot: SignalSnapshot,
        now: Date = Date(),
        limit: Int? = nil
    ) -> [SessionStatus] {
        visibleSessions(from: snapshot.sessions, now: now, limit: limit)
    }

    static func visibleSessions(
        from sourceSessions: [SessionStatus],
        now: Date = Date(),
        limit: Int? = nil
    ) -> [SessionStatus] {
        var seenAgents: Set<String> = []
        var sessions: [SessionStatus] = []

        for session in sourceSessions {
            guard isVisibleSession(session, now: now) else { continue }

            let agentKey = normalizedAgentKey(session.agent, fallback: session.sessionID)
            guard !seenAgents.contains(agentKey) else { continue }
            seenAgents.insert(agentKey)
            sessions.append(session)

            if let limit, sessions.count >= limit {
                break
            }
        }

        return sessions
    }

    static func recentEvents(
        from snapshot: SignalSnapshot,
        excluding currentSessions: [SessionStatus],
        limit: Int? = nil
    ) -> [RecentSignalEvent] {
        let currentSessionKeys = Set(
            currentSessions.map { session in
                "\(session.sessionID)|\(session.signal.rawValue)|\(session.lastEvent ?? "")"
            }
        )

        let filtered = snapshot.recentEvents.lazy.filter { event in
            let eventKey = "\(event.sessionID)|\(event.signal.rawValue)|\(event.event ?? "")"
            return !currentSessionKeys.contains(eventKey)
        }

        if let limit {
            return Array(filtered.prefix(limit))
        }

        return Array(filtered)
    }

    static func normalizedAgentKey(_ agent: String?, fallback: String) -> String {
        guard let agent, !agent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return fallback
        }

        let normalized = normalizedAgentName(agent)

        switch normalized {
        case "codex", "codex-desktop", "codex-cli", "codex-ide":
            return "codex"
        case "claude", "claude-code", "claude-desktop":
            return "claude"
        default:
            return normalized
        }
    }

    static func runtimeKind(for session: SessionStatus) -> ActivitySessionRuntimeKind {
        let agent = normalizedAgentName(session.agent)
        let sessionID = session.sessionID.lowercased()
        let event = (session.lastEvent ?? "").lowercased()

        if sessionID.hasPrefix("desktop-app:")
            || sessionID.hasPrefix("codex-desktop:")
            || agent == "codex-desktop"
            || agent == "claude-desktop"
            || event.hasPrefix("desktop") {
            return .desktop
        }

        if agent == "claude-code" || agent == "claude"
            || agent == "codex-cli" || agent == "codex-ide" || agent == "codex" {
            return .cli
        }

        return .local
    }

    static func statusSubtitle(
        for session: SessionStatus,
        status: String,
        friendlyEventName: (String) -> String
    ) -> String {
        guard let rawEvent = session.lastEvent?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawEvent.isEmpty
        else {
            return status
        }

        let event = rawEvent.lowercased()
        guard !event.hasPrefix("desktop") else {
            return status
        }

        let eventName = friendlyEventName(rawEvent)
        guard eventName != status else {
            return status
        }

        return "\(status) · \(eventName)"
    }

    static func eventTitle(
        for event: RecentSignalEvent,
        agentName: String,
        status: String,
        friendlyEventName: (String) -> String
    ) -> String {
        if let eventName = event.event, !eventName.isEmpty {
            return "\(agentName) · \(friendlyEventName(eventName))"
        }

        return "\(agentName) · \(status)"
    }

    private static func isVisibleSession(_ session: SessionStatus, now: Date) -> Bool {
        if isDesktopPresenceSession(session) {
            return true
        }

        switch session.signal.displayState {
        case .active:
            return now.timeIntervalSince(session.updatedAt) <= liveSessionWindow
        case .completed, .needsReview, .permission, .blocked, .stale:
            return true
        case .ready, .paused:
            return false
        }
    }

    private static func isDesktopPresenceSession(_ session: SessionStatus) -> Bool {
        session.sessionID.hasPrefix("desktop-app:") || session.lastEvent == "DesktopAppRunning"
    }

    private static func normalizedAgentName(_ agent: String?) -> String {
        guard let agent else { return "" }
        return agent
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")
    }
}

extension MenuBarStatusModel {
    func activitySessionTitle(for session: SessionStatus) -> String {
        "\(friendlyAgentName(session.agent)) · \(activitySessionRuntimeLabel(for: session))"
    }

    func activitySessionRuntimeLabel(for session: SessionStatus) -> String {
        switch ActivityPresentation.runtimeKind(for: session) {
        case .desktop:
            return text("桌面版运行中", "Desktop running")
        case .cli:
            return text("CLI 运行中", "CLI running")
        case .local:
            return text("本地运行中", "Local running")
        }
    }

    func activitySessionStatusSubtitle(for session: SessionStatus) -> String {
        ActivityPresentation.statusSubtitle(
            for: session,
            status: displayName(for: session.signal),
            friendlyEventName: friendlyEventName
        )
    }

    func activityEventTitle(for event: RecentSignalEvent) -> String {
        ActivityPresentation.eventTitle(
            for: event,
            agentName: friendlyAgentName(event.agent),
            status: displayName(for: event.signal),
            friendlyEventName: friendlyEventName
        )
    }
}

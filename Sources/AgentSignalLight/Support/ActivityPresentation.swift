import AgentSignalLightCore
import Foundation

enum ActivitySessionRuntimeKind {
    case desktop
    case terminal
    case ide
    case local
}

enum ActivityPresentation {
    static let currentSessionLimit = 6
    private static let liveSessionWindow: TimeInterval = 5 * 60
    private static let passiveActiveSessionWindow: TimeInterval = 45
    private static let alertResolutionGraceWindow: TimeInterval = 5

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
        var seenSources: Set<String> = []
        var sourceIndexes: [String: Int] = [:]
        var sessions: [SessionStatus] = []

        for session in sourceSessions {
            guard isVisibleSession(session, now: now) else { continue }

            let sourceKey = activitySourceKey(for: session)
            if let index = sourceIndexes[sourceKey] {
                if shouldPreferVisibleSession(session, over: sessions[index]) {
                    sessions[index] = session
                }
                continue
            }

            seenSources.insert(sourceKey)
            sourceIndexes[sourceKey] = sessions.count
            sessions.append(session)
        }

        if let limit {
            return Array(sessions.prefix(limit))
        }

        return sessions
    }

    static func visibleRunningSessions(
        from snapshot: SignalSnapshot,
        now: Date = Date(),
        limit: Int? = currentSessionLimit
    ) -> [SessionStatus] {
        visibleSessions(from: snapshot, now: now, limit: limit)
            .filter(isRunningCurrentSession)
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
        let currentSourceEventKeys = Set(
            currentSessions.map { session in
                "\(activitySourceKey(for: session))|\(session.signal.rawValue)|\(session.lastEvent ?? "")"
            }
        )

        let filtered = snapshot.recentEvents.lazy.filter { event in
            guard !MenuBarStatusModel.isManualIdleControlEvent(event) else {
                return false
            }

            let eventKey = "\(event.sessionID)|\(event.signal.rawValue)|\(event.event ?? "")"
            let sourceEventKey = "\(activitySourceKey(for: event))|\(event.signal.rawValue)|\(event.event ?? "")"
            return !currentSessionKeys.contains(eventKey)
                && !currentSourceEventKeys.contains(sourceEventKey)
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
        case "codex", "codex-desktop", "codex-cli", "codex-ide", "codex-xcode",
             "codex-terminal", "terminal-codex", "codex-tui", "codex-shell",
             "idea-codex", "intellij-codex", "jetbrains-codex", "codex-idea",
             "codex-intellij", "codex-jetbrains", "codex-vscode", "vscode-codex",
             "xcode-codex":
            return "codex"
        case "claude", "claude-code", "claude-desktop", "claude-cli",
             "claude-terminal", "terminal-claude", "claude-ide",
             "idea-claude", "intellij-claude", "jetbrains-claude":
            return "claude"
        case "antigravity", "antigravity-ide", "antigravity-app", "antigravity-cli",
             "antigravity-terminal", "agy", "localharness":
            return "antigravity"
        default:
            return normalized
        }
    }

    static func activitySourceKey(for session: SessionStatus) -> String {
        activitySourceKey(agent: session.agent, sessionID: session.sessionID, event: session.lastEvent)
    }

    static func activitySourceKey(for event: RecentSignalEvent) -> String {
        activitySourceKey(agent: event.agent, sessionID: event.sessionID, event: event.event)
    }

    static func runtimeKind(for session: SessionStatus) -> ActivitySessionRuntimeKind {
        runtimeKind(agent: session.agent, sessionID: session.sessionID, event: session.lastEvent)
    }

    static func runtimeKind(for event: RecentSignalEvent) -> ActivitySessionRuntimeKind {
        runtimeKind(agent: event.agent, sessionID: event.sessionID, event: event.event)
    }

    static func sourceDetail(for session: SessionStatus) -> String? {
        sourceDetail(agent: session.agent, sessionID: session.sessionID, event: session.lastEvent)
    }

    static func sourceDetail(for event: RecentSignalEvent) -> String? {
        sourceDetail(agent: event.agent, sessionID: event.sessionID, event: event.event)
    }

    private static func sourceDetail(agent rawAgent: String?, sessionID rawSessionID: String, event rawEvent: String?) -> String? {
        let agent = normalizedAgentName(rawAgent)
        let sessionID = rawSessionID.lowercased()
        let event = (rawEvent ?? "").lowercased()

        if containsIDEIdentity(agent, sessionID, event) {
            if containsAny([agent, sessionID, event], tokens: ["idea", "intellij"]) {
                return "IDEA"
            }
            if containsAny([agent, sessionID, event], tokens: ["jetbrains"]) {
                return "JetBrains"
            }
            if containsAny([agent, sessionID, event], tokens: ["vscode", "vs-code", "visual-studio-code"]) {
                return "VS Code"
            }
            if containsAny([agent, sessionID, event], tokens: ["xcode"]) {
                return "Xcode"
            }
            return "IDE"
        }

        return nil
    }

    private static func activitySourceKey(agent: String?, sessionID: String, event: String?) -> String {
        let agentKey = normalizedAgentKey(agent, fallback: sessionID)
        switch agentKey {
        case "codex", "claude":
            let runtime = runtimeKind(agent: agent, sessionID: sessionID, event: event)
            if case .ide = runtime,
               let detail = sourceDetail(
                for: SessionStatus(
                    sessionID: sessionID,
                    signal: .working,
                    updatedAt: Date(timeIntervalSince1970: 0),
                    agent: agent,
                    lastEvent: event
                )
               ) {
                return "\(agentKey):ide:\(detail.lowercased().replacingOccurrences(of: " ", with: "-"))"
            }
            return "\(agentKey):\(runtime)"
        default:
            return "\(agentKey):\(sessionID)"
        }
    }

    private static func runtimeKind(agent rawAgent: String?, sessionID rawSessionID: String, event rawEvent: String?) -> ActivitySessionRuntimeKind {
        let agent = normalizedAgentName(rawAgent)
        let sessionID = rawSessionID.lowercased()
        let event = (rawEvent ?? "").lowercased()

        if containsIDEIdentity(agent, sessionID, event) {
            return .ide
        }

        if agent == "claude-code" || agent == "claude"
            || agent == "claude-cli" || agent == "claude-terminal"
            || sessionID.hasPrefix("claude-cli:")
            || agent == "codex-cli" || agent == "codex-terminal"
            || agent == "codex-tui" || agent == "codex-shell"
            || agent == "codex" || sessionID.hasPrefix("codex-cli:")
            || agent == "agy" || agent == "antigravity-cli" {
            return .terminal
        }

        if sessionID.hasPrefix("desktop-app:")
            || sessionID.hasPrefix("codex-desktop:")
            || agent == "codex-desktop"
            || agent == "claude-desktop"
            || agent == "antigravity-app"
            || event.hasPrefix("desktop") {
            return .desktop
        }

        return .local
    }

    private static func containsIDEIdentity(_ values: String...) -> Bool {
        containsAny(
            values,
            tokens: [
                "codex-ide", "claude-ide", "-ide", ":ide",
                "idea", "intellij", "jetbrains",
                "vscode", "vs-code", "visual-studio-code",
                "xcode"
            ]
        )
    }

    private static func containsAny(_ values: [String], tokens: [String]) -> Bool {
        values.contains { value in
            tokens.contains { value.contains($0) }
        }
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
        guard !event.hasPrefix("platformpresence:"),
              event != "desktopapprunning"
        else {
            return status
        }

        if rawEvent.hasPrefix("DesktopToolCall:"),
           session.signal.displayState == .needsReview || session.signal.displayState == .permission {
            let toolName = String(rawEvent.dropFirst("DesktopToolCall:".count))
            return toolName.isEmpty ? status : "\(status) · \(toolName)"
        }

        let eventName = friendlyEventName(rawEvent)
        return eventName.isEmpty ? status : eventName
    }

    static func eventTitle(
        for event: RecentSignalEvent,
        agentName: String
    ) -> String {
        agentName
    }

    static func eventSubtitle(
        for event: RecentSignalEvent,
        status: String,
        friendlyEventName: (String) -> String
    ) -> String {
        guard let eventName = event.event?.trimmingCharacters(in: .whitespacesAndNewlines),
              !eventName.isEmpty
        else {
            return status
        }

        return friendlyEventName(eventName)
    }

    private static func isVisibleSession(_ session: SessionStatus, now: Date) -> Bool {
        if isPresenceSession(session) {
            return true
        }

        switch session.signal.displayState {
        case .active:
            return now.timeIntervalSince(session.updatedAt) <= activeSessionWindow(for: session)
        case .completed, .needsReview, .permission, .blocked, .stale:
            return true
        case .ready, .paused:
            return false
        }
    }

    private static func isRunningCurrentSession(_ session: SessionStatus) -> Bool {
        switch session.signal.displayState {
        case .active, .completed, .needsReview, .permission, .blocked, .stale:
            return true
        case .ready, .paused:
            return false
        }
    }

    private static func shouldPreferVisibleSession(_ candidate: SessionStatus, over current: SessionStatus) -> Bool {
        let candidateIsPresence = isPresenceSession(candidate)
        let currentIsPresence = isPresenceSession(current)
        if candidateIsPresence != currentIsPresence {
            if candidateIsPresence {
                return shouldPresenceOverrideStaleActivity(candidate, nonPresence: current)
            }
            if currentIsPresence {
                return !shouldPresenceOverrideStaleActivity(current, nonPresence: candidate)
            }
        }

        if shouldResolvingSessionOverride(candidate, current: current) {
            return true
        }
        if shouldResolvingSessionOverride(current, current: candidate) {
            return false
        }

        let candidateIsAlert = isPersistentAlert(candidate.signal.displayState)
        let currentIsAlert = isPersistentAlert(current.signal.displayState)
        if candidateIsAlert || currentIsAlert {
            let candidatePriority = candidate.signal.displayState.priority
            let currentPriority = current.signal.displayState.priority
            if candidatePriority != currentPriority {
                return candidatePriority > currentPriority
            }
        }

        if candidate.updatedAt != current.updatedAt {
            return candidate.updatedAt > current.updatedAt
        }

        return candidate.signal.displayState.priority > current.signal.displayState.priority
    }

    private static func shouldResolvingSessionOverride(
        _ candidate: SessionStatus,
        current: SessionStatus
    ) -> Bool {
        guard isResolvingState(candidate.signal.displayState),
              isResolvingOverrideableAlert(current.signal.displayState),
              candidate.updatedAt >= current.updatedAt
        else {
            return false
        }

        if current.signal.displayState == .permission,
           candidate.signal.displayState == .active {
            return candidate.updatedAt.timeIntervalSince(current.updatedAt) >= alertResolutionGraceWindow
        }

        return true
    }

    private static func shouldPresenceOverrideStaleActivity(
        _ presence: SessionStatus,
        nonPresence: SessionStatus
    ) -> Bool {
        guard nonPresence.signal.displayState == .active else {
            return false
        }

        return presence.updatedAt.timeIntervalSince(nonPresence.updatedAt) > activeSessionWindow(for: nonPresence)
    }

    private static func activeSessionWindow(for session: SessionStatus) -> TimeInterval {
        isPassiveActiveSession(session) ? passiveActiveSessionWindow : liveSessionWindow
    }

    private static func isPassiveActiveSession(_ session: SessionStatus) -> Bool {
        guard session.signal.displayState == .active else { return false }

        switch session.lastEvent {
        case "DesktopActivityHeartbeat", "DesktopThinking", "DesktopMessage":
            return true
        default:
            return false
        }
    }

    private static func isPersistentAlert(_ displayState: DisplayState) -> Bool {
        switch displayState {
        case .needsReview, .permission, .blocked, .stale, .paused:
            return true
        case .ready, .active, .completed:
            return false
        }
    }

    private static func isResolvingOverrideableAlert(_ displayState: DisplayState) -> Bool {
        displayState == .permission
    }

    private static func isResolvingState(_ displayState: DisplayState) -> Bool {
        displayState == .active || displayState == .completed
    }

    private static func isPresenceSession(_ session: SessionStatus) -> Bool {
        session.sessionID.hasPrefix("desktop-app:")
            || session.sessionID.hasPrefix("platform-presence:")
            || session.lastEvent == "DesktopAppRunning"
            || session.lastEvent?.hasPrefix("PlatformPresence:") == true
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
        case .terminal:
            return text("终端运行中", "Terminal running")
        case .ide:
            if let detail = ActivityPresentation.sourceDetail(for: session) {
                return text("\(detail) 运行中", "\(detail) running")
            }
            return text("IDE 运行中", "IDE running")
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
            agentName: activityEventAgentTitle(for: event)
        )
    }

    func activityEventSubtitle(for event: RecentSignalEvent) -> String {
        ActivityPresentation.eventSubtitle(
            for: event,
            status: displayName(for: event.signal),
            friendlyEventName: friendlyEventName
        )
    }

    private func activityEventAgentTitle(for event: RecentSignalEvent) -> String {
        let baseName = friendlyAgentName(event.agent)

        switch ActivityPresentation.runtimeKind(for: event) {
        case .desktop:
            return "\(baseName) Desktop"
        case .terminal:
            return "\(baseName) CLI"
        case .ide:
            if let detail = ActivityPresentation.sourceDetail(for: event) {
                return "\(baseName) \(detail)"
            }
            return "\(baseName) IDE"
        case .local:
            return baseName
        }
    }
}

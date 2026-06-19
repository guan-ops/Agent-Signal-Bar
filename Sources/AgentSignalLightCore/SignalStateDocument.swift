import Foundation

public struct SessionRecord: Codable, Equatable, Sendable {
    public var agent: String?
    public var signal: AgentSignal
    public var lastEvent: String?
    public var updatedAt: Date
    public var quota: AgentQuotaStatus?

    public init(
        agent: String? = nil,
        signal: AgentSignal,
        lastEvent: String? = nil,
        updatedAt: Date,
        quota: AgentQuotaStatus? = nil
    ) {
        self.agent = agent
        self.signal = signal
        self.lastEvent = lastEvent
        self.updatedAt = updatedAt
        self.quota = quota
    }

    private enum CodingKeys: String, CodingKey {
        case agent
        case signal
        case lastEvent = "last_event"
        case updatedAt = "updated_at"
        case quota
    }
}

public struct SignalEventRecord: Codable, Equatable, Sendable {
    public var id: String
    public var sessionID: String
    public var agent: String?
    public var signal: AgentSignal
    public var event: String?
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        sessionID: String,
        agent: String? = nil,
        signal: AgentSignal,
        event: String? = nil,
        updatedAt: Date
    ) {
        self.id = id
        self.sessionID = sessionID
        self.agent = agent
        self.signal = signal
        self.event = event
        self.updatedAt = updatedAt
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

public struct SignalStateDocument: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var aggregate: AgentSignal?
    public var updatedAt: Date?
    public var sessions: [String: SessionRecord]
    public var events: [SignalEventRecord]

    public init(
        schemaVersion: Int = 1,
        aggregate: AgentSignal? = nil,
        updatedAt: Date? = nil,
        sessions: [String: SessionRecord] = [:],
        events: [SignalEventRecord] = []
    ) {
        self.schemaVersion = schemaVersion
        self.aggregate = aggregate
        self.updatedAt = updatedAt
        self.sessions = sessions
        self.events = events
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case aggregate
        case updatedAt = "updated_at"
        case sessions
        case events
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        aggregate = try container.decodeIfPresent(AgentSignal.self, forKey: .aggregate)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
        sessions = try container.decodeIfPresent([String: SessionRecord].self, forKey: .sessions) ?? [:]
        events = try container.decodeIfPresent([SignalEventRecord].self, forKey: .events) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encodeIfPresent(aggregate, forKey: .aggregate)
        try container.encodeIfPresent(updatedAt, forKey: .updatedAt)
        try container.encode(sessions, forKey: .sessions)
        try container.encode(events, forKey: .events)
    }
}

public extension SignalStateDocument {
    mutating func pruneSessions(now: Date, ttlSeconds: TimeInterval) {
        sessions = sessions.filter { _, record in
            now.timeIntervalSince(record.updatedAt) <= ttlSeconds
        }
    }

    func aggregateSignal() -> AgentSignal {
        var candidates = sessions.values.map(\.signal)
        if let aggregate, candidates.isEmpty {
            candidates.append(aggregate)
        }

        return candidates
            .max { lhs, rhs in lhs.displayState.priority < rhs.displayState.priority }?
            .normalizedAggregateSignal ?? .idle
    }

    func snapshot(stateFileURL: URL) -> SignalSnapshot {
        let sessionStatuses = sessions
            .map { key, record in
                SessionStatus(
                    sessionID: key,
                    signal: record.signal,
                    updatedAt: record.updatedAt,
                    agent: record.agent,
                    lastEvent: record.lastEvent,
                    quota: record.quota
                )
            }
            .sorted { lhs, rhs in
                if lhs.signal.displayState.priority != rhs.signal.displayState.priority {
                    return lhs.signal.displayState.priority > rhs.signal.displayState.priority
                }
                return lhs.updatedAt > rhs.updatedAt
            }
        let recentEvents = events.reversed()
            .map { record in
                RecentSignalEvent(
                    id: record.id,
                    sessionID: record.sessionID,
                    signal: record.signal,
                    updatedAt: record.updatedAt,
                    agent: record.agent,
                    event: record.event
                )
            }

        return SignalSnapshot(
            aggregate: aggregateSignal(),
            sessions: sessionStatuses,
            recentEvents: recentEvents,
            stateFileURL: stateFileURL,
            updatedAt: updatedAt
        )
    }
}

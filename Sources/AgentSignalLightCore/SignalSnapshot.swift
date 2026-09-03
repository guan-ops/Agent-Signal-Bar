import Foundation

public struct SessionStatus: Identifiable, Equatable, Sendable {
    public var id: String { sessionID }

    public let sessionID: String
    public let signal: AgentSignal
    public let updatedAt: Date
    public let agent: String?
    public let lastEvent: String?
    public let quota: AgentQuotaStatus?

    public init(
        sessionID: String,
        signal: AgentSignal,
        updatedAt: Date,
        agent: String? = nil,
        lastEvent: String? = nil,
        quota: AgentQuotaStatus? = nil
    ) {
        self.sessionID = sessionID
        self.signal = signal
        self.updatedAt = updatedAt
        self.agent = agent
        self.lastEvent = lastEvent
        self.quota = quota
    }
}

public struct AgentQuotaStatus: Codable, Equatable, Sendable {
    public let remainingPercent: Double
    public let usedPercent: Double?
    public let limitID: String?
    public let limitName: String?
    public let accountScopeID: UUID?
    public let source: AgentQuotaSource?
    public let windowMinutes: Int?
    public let resetsAt: Date?
    public let updatedAt: Date
    public let primary: AgentQuotaWindowStatus?
    public let secondary: AgentQuotaWindowStatus?
    public let tokenUsage: AgentTokenUsage?

    public init(
        remainingPercent: Double,
        usedPercent: Double? = nil,
        limitID: String? = nil,
        limitName: String? = nil,
        accountScopeID: UUID? = nil,
        source: AgentQuotaSource? = nil,
        windowMinutes: Int? = nil,
        resetsAt: Date? = nil,
        updatedAt: Date,
        primary: AgentQuotaWindowStatus? = nil,
        secondary: AgentQuotaWindowStatus? = nil,
        tokenUsage: AgentTokenUsage? = nil
    ) {
        self.remainingPercent = min(max(remainingPercent, 0), 100)
        self.usedPercent = usedPercent.map { min(max($0, 0), 100) }
        self.limitID = limitID
        self.limitName = limitName
        self.accountScopeID = accountScopeID
        self.source = source
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
        self.updatedAt = updatedAt
        self.tokenUsage = tokenUsage
        self.primary = primary ?? usedPercent.map {
            AgentQuotaWindowStatus(
                remainingPercent: 100 - $0,
                usedPercent: $0,
                windowMinutes: windowMinutes,
                resetsAt: resetsAt
            )
        }
        self.secondary = secondary
    }

    public var primaryWindow: AgentQuotaWindowStatus? {
        if let primary {
            return primary
        }
        return AgentQuotaWindowStatus(
            remainingPercent: remainingPercent,
            usedPercent: usedPercent ?? (100 - remainingPercent),
            windowMinutes: windowMinutes,
            resetsAt: resetsAt
        )
    }

    public var secondaryWindow: AgentQuotaWindowStatus? {
        secondary
    }

    public func attributed(
        to accountScopeID: UUID?,
        source: AgentQuotaSource? = nil
    ) -> AgentQuotaStatus {
        AgentQuotaStatus(
            remainingPercent: remainingPercent,
            usedPercent: usedPercent,
            limitID: limitID,
            limitName: limitName,
            accountScopeID: accountScopeID,
            source: source ?? self.source,
            windowMinutes: windowMinutes,
            resetsAt: resetsAt,
            updatedAt: updatedAt,
            primary: primary,
            secondary: secondary,
            tokenUsage: tokenUsage
        )
    }

    private enum CodingKeys: String, CodingKey {
        case remainingPercent = "remaining_percent"
        case usedPercent = "used_percent"
        case limitID = "limit_id"
        case limitName = "limit_name"
        case accountScopeID = "account_scope_id"
        case source
        case windowMinutes = "window_minutes"
        case resetsAt = "resets_at"
        case updatedAt = "updated_at"
        case primary
        case secondary
        case tokenUsage = "token_usage"
    }
}

public enum AgentQuotaSource: String, Codable, Equatable, Sendable {
    case manualCookie = "manual-cookie"
    case browserCookie = "browser-cookie"
    case oauth
    case apiKey = "api-key"
    case desktopSession = "desktop-session"
    case unknown

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = Self(rawValue: rawValue) ?? .unknown
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct AgentQuotaWindowStatus: Codable, Equatable, Sendable {
    public let remainingPercent: Double
    public let usedPercent: Double
    public let windowMinutes: Int?
    public let resetsAt: Date?

    public init(
        remainingPercent: Double,
        usedPercent: Double,
        windowMinutes: Int? = nil,
        resetsAt: Date? = nil
    ) {
        self.remainingPercent = min(max(remainingPercent, 0), 100)
        self.usedPercent = min(max(usedPercent, 0), 100)
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
    }

    private enum CodingKeys: String, CodingKey {
        case remainingPercent = "remaining_percent"
        case usedPercent = "used_percent"
        case windowMinutes = "window_minutes"
        case resetsAt = "resets_at"
    }
}

public struct AgentTokenUsage: Codable, Equatable, Sendable {
    public let inputTokens: Int?
    public let cachedInputTokens: Int?
    public let outputTokens: Int?
    public let reasoningOutputTokens: Int?
    public let totalTokens: Int?
    public let contextWindowTokens: Int?

    public init(
        inputTokens: Int? = nil,
        cachedInputTokens: Int? = nil,
        outputTokens: Int? = nil,
        reasoningOutputTokens: Int? = nil,
        totalTokens: Int? = nil,
        contextWindowTokens: Int? = nil
    ) {
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
        self.totalTokens = totalTokens
        self.contextWindowTokens = contextWindowTokens
    }

    public var effectiveTotalTokens: Int? {
        if let totalTokens {
            return totalTokens
        }

        let total = [inputTokens, outputTokens]
            .compactMap { $0 }
            .reduce(0, +)
        return total > 0 ? total : nil
    }

    private enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case cachedInputTokens = "cached_input_tokens"
        case outputTokens = "output_tokens"
        case reasoningOutputTokens = "reasoning_output_tokens"
        case totalTokens = "total_tokens"
        case contextWindowTokens = "context_window_tokens"
    }
}

public struct AgentTokenActivityPoint: Equatable, Sendable {
    public let timestamp: Date
    public let usage: AgentTokenUsage

    public init(timestamp: Date, usage: AgentTokenUsage) {
        self.timestamp = timestamp
        self.usage = usage
    }
}

public struct AgentTokenActivityRecord: Equatable, Sendable {
    public let timestamp: Date
    public let lastUsage: AgentTokenUsage?
    public let totalUsage: AgentTokenUsage?

    public init(
        timestamp: Date,
        lastUsage: AgentTokenUsage?,
        totalUsage: AgentTokenUsage?
    ) {
        self.timestamp = timestamp
        self.lastUsage = lastUsage
        self.totalUsage = totalUsage
    }
}

public struct RecentSignalEvent: Identifiable, Equatable, Sendable {
    public let id: String
    public let sessionID: String
    public let signal: AgentSignal
    public let updatedAt: Date
    public let agent: String?
    public let event: String?

    public init(
        id: String,
        sessionID: String,
        signal: AgentSignal,
        updatedAt: Date,
        agent: String? = nil,
        event: String? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.signal = signal
        self.updatedAt = updatedAt
        self.agent = agent
        self.event = event
    }
}

public struct SignalSnapshot: Equatable, Sendable {
    public let aggregate: AgentSignal
    public let sessions: [SessionStatus]
    public let recentEvents: [RecentSignalEvent]
    public let stateFileURL: URL
    public let updatedAt: Date?

    public init(
        aggregate: AgentSignal,
        sessions: [SessionStatus],
        recentEvents: [RecentSignalEvent] = [],
        stateFileURL: URL,
        updatedAt: Date? = nil
    ) {
        self.aggregate = aggregate
        self.sessions = sessions
        self.recentEvents = recentEvents
        self.stateFileURL = stateFileURL
        self.updatedAt = updatedAt
    }

    public static func idle(stateFileURL: URL) -> SignalSnapshot {
        SignalSnapshot(
            aggregate: .idle,
            sessions: [],
            recentEvents: [],
            stateFileURL: stateFileURL,
            updatedAt: nil
        )
    }
}

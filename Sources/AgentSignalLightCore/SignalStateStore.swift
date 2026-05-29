import Darwin
import Foundation

public enum SignalStateStoreError: Error, LocalizedError {
    case cannotCreateStateDirectory(URL, Error)
    case cannotOpenLock(String)

    public var errorDescription: String? {
        switch self {
        case .cannotCreateStateDirectory(let url, let error):
            return "Cannot create state directory at \(url.path): \(error.localizedDescription)"
        case .cannotOpenLock(let path):
            return "Cannot open state lock at \(path)."
        }
    }
}

public final class SignalStateStore: @unchecked Sendable {
    public let stateFileURL: URL
    public let sessionTTLSeconds: Double
    public let completedTTLSeconds: Double
    public let eventLimit: Int

    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    public init(
        stateFileURL: URL = SignalStateStore.defaultStateFileURL(),
        sessionTTLSeconds: Double = SignalStateStore.defaultSessionTTL(),
        completedTTLSeconds: Double = SignalStateStore.defaultCompletedTTL(),
        eventLimit: Int = SignalStateStore.defaultEventLimit()
    ) {
        self.stateFileURL = stateFileURL
        self.sessionTTLSeconds = sessionTTLSeconds
        self.completedTTLSeconds = completedTTLSeconds
        self.eventLimit = eventLimit
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    public static func defaultStateFileURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let explicit = environment["AGENT_SIGNAL_LIGHT_STATE_FILE"], !explicit.isEmpty {
            return URL(fileURLWithPath: explicit.expandingTildeInPath)
        }

        let stateDirectory = environment["AGENT_SIGNAL_LIGHT_STATE_DIR"]
            ?? environment["SIGNAL_LIGHT_STATE_DIR"]
            ?? "/tmp/agent-signal"
        return URL(fileURLWithPath: stateDirectory.expandingTildeInPath, isDirectory: true)
            .appendingPathComponent("status.json")
    }

    public static func defaultSessionTTL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Double {
        guard let rawValue = environment["SIGNAL_LIGHT_SESSION_TTL_SECONDS"],
              let value = Double(rawValue),
              value > 0
        else {
            return 30 * 60
        }
        return value
    }

    public static func defaultCompletedTTL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Double {
        guard let rawValue = environment["AGENT_SIGNAL_LIGHT_COMPLETED_TTL_SECONDS"]
                ?? environment["SIGNAL_LIGHT_COMPLETED_TTL_SECONDS"],
              let value = Double(rawValue),
              value > 0
        else {
            return 8
        }
        return value
    }

    public static func defaultEventLimit(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int {
        guard let rawValue = environment["AGENT_SIGNAL_LIGHT_EVENT_LIMIT"],
              let value = Int(rawValue),
              value > 0
        else {
            return 30
        }
        return value
    }

    public func readSnapshot() -> SignalSnapshot {
        do {
            return try withStateLock {
                try readSnapshotLocked(persistingRuntimeChanges: true)
            }
        } catch {
            return readSnapshotWithoutLock()
        }
    }

    public func setManualSignal(_ signal: AgentSignal) throws -> SignalSnapshot {
        try withStateLock {
            let now = Date()
            var resolvedSignal = signal

            if signal == .sessionStart || signal == .sessionEnd || signal == .turnEnd {
                resolvedSignal = .idle
            }

            var document = readDocument()
            _ = pruneRuntimeSessions(in: &document, now: now)

            switch resolvedSignal.displayState {
            case .ready:
                document.sessions.removeAll()
                document.aggregate = .idle
            case .paused:
                document.sessions.removeAll()
                document.aggregate = resolvedSignal.normalizedAggregateSignal
            default:
                document.sessions["manual"] = SessionRecord(
                    agent: "manual",
                    signal: resolvedSignal,
                    lastEvent: "ManualSet",
                    updatedAt: now
                )
                document.aggregate = document.aggregateSignal()
            }

            appendEvent(
                to: &document,
                sessionID: "manual",
                agent: "manual",
                signal: resolvedSignal,
                event: "ManualSet",
                updatedAt: now
            )
            document.updatedAt = now
            try writeDocument(document)
            return document.snapshot(stateFileURL: stateFileURL)
        }
    }

    public func setSignalTestSignal(_ signal: AgentSignal) throws -> SignalSnapshot {
        try withStateLock {
            let now = Date()
            var resolvedSignal = signal

            if signal == .sessionStart || signal == .sessionEnd || signal == .turnEnd {
                resolvedSignal = .idle
            }

            var document = readDocument()
            _ = pruneRuntimeSessions(in: &document, now: now)
            document.sessions["manual"] = SessionRecord(
                agent: "manual",
                signal: resolvedSignal,
                lastEvent: "SignalTest",
                updatedAt: now
            )
            document.aggregate = document.aggregateSignal()

            appendEvent(
                to: &document,
                sessionID: "manual",
                agent: "manual",
                signal: resolvedSignal,
                event: "SignalTest",
                updatedAt: now
            )
            document.updatedAt = now
            try writeDocument(document)
            return document.snapshot(stateFileURL: stateFileURL)
        }
    }

    public func clearSignalTestSignal() throws -> SignalSnapshot {
        try withStateLock {
            let now = Date()
            var document = readDocument()
            _ = pruneRuntimeSessions(in: &document, now: now)
            document.sessions.removeValue(forKey: "manual")
            document.aggregate = document.sessions.isEmpty ? .idle : document.aggregateSignal()

            appendEvent(
                to: &document,
                sessionID: "manual",
                agent: "manual",
                signal: document.aggregate ?? .idle,
                event: "SignalTestOff",
                updatedAt: now
            )
            document.updatedAt = now
            try writeDocument(document)
            return document.snapshot(stateFileURL: stateFileURL)
        }
    }

    public func clearSessions() throws -> SignalSnapshot {
        try setManualSignal(.idle)
    }

    public func clearWarnings() throws -> SignalSnapshot {
        try withStateLock {
            let now = Date()
            var document = readDocument()
            _ = pruneRuntimeSessions(in: &document, now: now)
            document.sessions = document.sessions.filter { _, record in
                !record.signal.shouldClearWarning
            }

            if document.sessions.isEmpty {
                if document.aggregate?.displayState != .paused {
                    document.aggregate = .idle
                }
            } else {
                document.aggregate = document.aggregateSignal()
            }

            appendEvent(
                to: &document,
                sessionID: "manual",
                agent: "manual",
                signal: document.aggregate ?? .idle,
                event: "ClearWarning",
                updatedAt: now
            )
            document.updatedAt = now
            try writeDocument(document)
            return document.snapshot(stateFileURL: stateFileURL)
        }
    }

    public func applySessionSignal(
        _ signal: AgentSignal,
        sessionID: String,
        agent: String? = nil,
        lastEvent: String? = nil
    ) throws -> SignalSnapshot {
        try withStateLock {
            let now = Date()
            var document = readDocument()
            _ = pruneRuntimeSessions(in: &document, now: now)

            switch signal {
            case .off, .pause, .paused:
                document.sessions.removeAll()
                document.aggregate = .off
            case .sessionEnd:
                let currentSignal = document.sessions[sessionID]?.signal
                if currentSignal == nil || currentSignal?.preserveAgainstSessionEndSignal == false {
                    document.sessions.removeValue(forKey: sessionID)
                }
                if document.sessions.isEmpty {
                    document.aggregate = .idle
                }
            case .turnEnd:
                let currentSignal = document.sessions[sessionID]?.signal
                if currentSignal == nil || currentSignal?.blocksTurnEndClear == false {
                    document.sessions.removeValue(forKey: sessionID)
                }
                if document.sessions.isEmpty && document.aggregate?.displayState != .paused {
                    document.aggregate = .idle
                }
            case .idle, .sessionStart:
                document.sessions[sessionID] = SessionRecord(
                    agent: agent,
                    signal: .idle,
                    lastEvent: lastEvent,
                    updatedAt: now
                )
            case .done:
                if document.sessions[sessionID]?.signal.preserveAgainstCompletedSignal != true {
                    document.sessions[sessionID] = SessionRecord(
                        agent: agent,
                        signal: signal,
                        lastEvent: lastEvent,
                        updatedAt: now
                    )
                }
            default:
                document.sessions[sessionID] = SessionRecord(
                    agent: agent,
                    signal: signal,
                    lastEvent: lastEvent,
                    updatedAt: now
                )
            }

            if signal.displayState != .paused {
                document.aggregate = document.aggregateSignal()
            }
            appendEvent(
                to: &document,
                sessionID: sessionID,
                agent: agent,
                signal: signal,
                event: lastEvent,
                updatedAt: now
            )
            document.updatedAt = now
            try writeDocument(document)
            return document.snapshot(stateFileURL: stateFileURL)
        }
    }

}

private extension AgentSignal {
    var preserveAgainstSessionEndSignal: Bool {
        switch displayState {
        case .completed, .needsReview, .permission, .blocked, .stale, .paused:
            return true
        case .ready, .active:
            return false
        }
    }

    var preserveAgainstCompletedSignal: Bool {
        switch displayState {
        case .needsReview, .permission, .blocked, .stale, .paused:
            return true
        case .ready, .active, .completed:
            return false
        }
    }
}

private extension SignalStateStore {
    struct RuntimePruneResult {
        let hadSessionsBeforePrune: Bool
        let removedNonCompletedSession: Bool
    }

    func pruneRuntimeSessions(in document: inout SignalStateDocument, now: Date) -> RuntimePruneResult {
        let previousSessions = document.sessions
        var removedNonCompletedSession = false

        document.sessions = previousSessions.filter { _, record in
            let ttlSeconds = runtimeTTLSeconds(for: record.signal)
            let shouldKeep = now.timeIntervalSince(record.updatedAt) <= ttlSeconds
            if !shouldKeep && shouldExpiredSessionMarkStateStale(record.signal) {
                removedNonCompletedSession = true
            }
            return shouldKeep
        }

        return RuntimePruneResult(
            hadSessionsBeforePrune: !previousSessions.isEmpty,
            removedNonCompletedSession: removedNonCompletedSession
        )
    }

    func runtimeTTLSeconds(for signal: AgentSignal) -> Double {
        switch signal {
        case .done, .toolDone, .subagentStop:
            return completedTTLSeconds
        default:
            return sessionTTLSeconds
        }
    }

    func shouldExpiredSessionMarkStateStale(_ signal: AgentSignal) -> Bool {
        switch signal {
        case .done, .toolDone, .subagentStop, .idle, .sessionStart, .sessionEnd, .turnEnd:
            return false
        default:
            return signal.displayState != .completed
        }
    }

    func readSnapshotLocked(persistingRuntimeChanges: Bool) throws -> SignalSnapshot {
        var document = readDocument()
        let originalDocument = document
        let now = Date()
        prepareSnapshotDocument(&document, now: now)

        if persistingRuntimeChanges && document != originalDocument {
            document.updatedAt = now
            try writeDocument(document)
        }

        return document.snapshot(stateFileURL: stateFileURL)
    }

    func readSnapshotWithoutLock() -> SignalSnapshot {
        var document = readDocument()
        let originalDocument = document
        let now = Date()
        prepareSnapshotDocument(&document, now: now)
        if document != originalDocument {
            document.updatedAt = now
        }
        return document.snapshot(stateFileURL: stateFileURL)
    }

    func prepareSnapshotDocument(_ document: inout SignalStateDocument, now: Date) {
        let pruneResult = pruneRuntimeSessions(in: &document, now: now)
        if pruneResult.hadSessionsBeforePrune && document.sessions.isEmpty && document.aggregate?.displayState != .paused {
            document.aggregate = pruneResult.removedNonCompletedSession ? .stale : .idle
        } else if !document.sessions.isEmpty {
            document.aggregate = document.aggregateSignal()
        }
    }

    func appendEvent(
        to document: inout SignalStateDocument,
        sessionID: String,
        agent: String?,
        signal: AgentSignal,
        event: String?,
        updatedAt: Date
    ) {
        let record = SignalEventRecord(
            sessionID: sessionID,
            agent: agent,
            signal: signal,
            event: event,
            updatedAt: updatedAt
        )
        document.events.append(
            record
        )

        if document.events.count > eventLimit {
            document.events = Array(document.events.suffix(eventLimit))
        }
    }

    func readDocument() -> SignalStateDocument {
        guard let data = try? Data(contentsOf: stateFileURL) else {
            return SignalStateDocument()
        }

        do {
            return try decoder.decode(SignalStateDocument.self, from: data)
        } catch {
            return SignalStateDocument(aggregate: .stale, updatedAt: Date())
        }
    }

    func writeDocument(_ document: SignalStateDocument) throws {
        let directory = stateFileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            throw SignalStateStoreError.cannotCreateStateDirectory(directory, error)
        }

        let data = try encoder.encode(document)
        try data.write(to: stateFileURL, options: [.atomic])
    }

    func withStateLock<T>(_ body: () throws -> T) throws -> T {
        let directory = stateFileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            throw SignalStateStoreError.cannotCreateStateDirectory(directory, error)
        }

        let lockURL = directory.appendingPathComponent("state.lock")
        let fileDescriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, mode_t(0o600))
        guard fileDescriptor >= 0 else {
            throw SignalStateStoreError.cannotOpenLock(lockURL.path)
        }

        var lock = flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        _ = fcntl(fileDescriptor, F_SETLKW, &lock)
        defer {
            var unlock = flock()
            unlock.l_type = Int16(F_UNLCK)
            unlock.l_whence = Int16(SEEK_SET)
            _ = fcntl(fileDescriptor, F_SETLK, &unlock)
            Darwin.close(fileDescriptor)
        }

        return try body()
    }
}

private extension String {
    var expandingTildeInPath: String {
        (self as NSString).expandingTildeInPath
    }
}

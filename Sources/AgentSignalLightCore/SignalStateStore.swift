import Darwin
import Foundation

public enum SignalStateStoreError: Error, LocalizedError {
    case cannotCreateStateDirectory(URL, Error)
    case unsafeStateDirectory(URL)
    case unsafeStateFile(URL)
    case cannotOpenLock(String)
    case cannotAcquireLock(String, Int32)

    public var errorDescription: String? {
        switch self {
        case .cannotCreateStateDirectory(let url, let error):
            return "Cannot create state directory at \(url.path): \(error.localizedDescription)"
        case .unsafeStateDirectory(let url):
            return "State directory is not a private directory owned by the current user: \(url.path)."
        case .unsafeStateFile(let url):
            return "State file is not a regular file owned by the current user: \(url.path)."
        case .cannotOpenLock(let path):
            return "Cannot open state lock at \(path)."
        case .cannotAcquireLock(let path, let errorCode):
            return "Cannot acquire state lock at \(path): errno \(errorCode)."
        }
    }
}

public final class SignalStateStore: @unchecked Sendable {
    public let stateFileURL: URL
    public let sessionTTLSeconds: Double
    public let completedTTLSeconds: Double
    public let eventLimit: Int
    private static let duplicateEventWindow: TimeInterval = 4
    private static let transientAlertHoldWindow: TimeInterval = 5
    // fcntl record locks are process-owned, not thread-owned. Serialize all
    // instances before opening the lock file: closing another descriptor for
    // that file can also release this process's record lock.
    private static let processLock = NSLock()

    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private let enforcesPrivateStateDirectory: Bool

    public init(
        stateFileURL: URL? = nil,
        sessionTTLSeconds: Double = SignalStateStore.defaultSessionTTL(),
        completedTTLSeconds: Double = SignalStateStore.defaultCompletedTTL(),
        eventLimit: Int = SignalStateStore.defaultEventLimit()
    ) {
        let environment = ProcessInfo.processInfo.environment
        self.stateFileURL = stateFileURL ?? SignalStateStore.defaultStateFileURL(environment: environment)
        enforcesPrivateStateDirectory = stateFileURL == nil
            && !SignalStateStore.hasExplicitStateLocation(environment: environment)
        self.sessionTTLSeconds = sessionTTLSeconds
        self.completedTTLSeconds = completedTTLSeconds
        self.eventLimit = eventLimit
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(Self.decodeDate)
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    public static func defaultStateFileURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        applicationSupportDirectory: URL? = nil
    ) -> URL {
        if let explicit = nonEmptyEnvironmentValue("AGENT_SIGNAL_LIGHT_STATE_FILE", in: environment) {
            return URL(fileURLWithPath: explicit.expandingTildeInPath)
        }

        return defaultStateDirectoryURL(
            environment: environment,
            applicationSupportDirectory: applicationSupportDirectory
        )
            .appendingPathComponent("status.json")
    }

    public static func defaultStateDirectoryURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        applicationSupportDirectory: URL? = nil
    ) -> URL {
        if let stateDirectory = nonEmptyEnvironmentValue("AGENT_SIGNAL_LIGHT_STATE_DIR", in: environment)
            ?? nonEmptyEnvironmentValue("SIGNAL_LIGHT_STATE_DIR", in: environment)
        {
            return URL(fileURLWithPath: stateDirectory.expandingTildeInPath, isDirectory: true)
        }

        let baseDirectory = applicationSupportDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return baseDirectory
            .appendingPathComponent("Agent Signal Bar", isDirectory: true)
            .appendingPathComponent("SignalState", isDirectory: true)
    }

    public static func hasExplicitStateLocation(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        nonEmptyEnvironmentValue("AGENT_SIGNAL_LIGHT_STATE_FILE", in: environment) != nil
            || hasExplicitStateDirectory(environment: environment)
    }

    public static func hasExplicitStateDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        nonEmptyEnvironmentValue("AGENT_SIGNAL_LIGHT_STATE_DIR", in: environment) != nil
            || nonEmptyEnvironmentValue("SIGNAL_LIGHT_STATE_DIR", in: environment) != nil
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
            return 30
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
            return 50
        }
        return value
    }

    private static func nonEmptyEnvironmentValue(
        _ key: String,
        in environment: [String: String]
    ) -> String? {
        guard let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else {
            return nil
        }
        return value
    }

    private static func decodeDate(from decoder: Decoder) throws -> Date {
        let container = try decoder.singleValueContainer()

        if let string = try? container.decode(String.self) {
            if let date = date(fromISO8601String: string) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO8601 date: \(string)"
            )
        }

        if let timestamp = try? container.decode(Double.self) {
            return Date(timeIntervalSince1970: timestamp)
        }

        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Expected ISO8601 date string or UNIX timestamp"
        )
    }

    private static func date(fromISO8601String value: String) -> Date? {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: value) {
            return date
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    public func readSnapshot() -> SignalSnapshot {
        do {
            return try withStateLock {
                try readSnapshotLocked(persistingRuntimeChanges: true)
            }
        } catch {
            return SignalSnapshot(
                aggregate: .stale,
                sessions: [],
                stateFileURL: stateFileURL,
                updatedAt: nil
            )
        }
    }

    public func setManualSignal(_ signal: AgentSignal) throws -> SignalSnapshot {
        try withStateLock {
            let now = Date()
            var resolvedSignal = signal

            if signal == .sessionStart || signal == .sessionEnd || signal == .turnEnd {
                resolvedSignal = .idle
            }

            var document = try readDocument()
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

    public func clearSessions() throws -> SignalSnapshot {
        try setManualSignal(.idle)
    }

    public func applySessionSignal(
        _ signal: AgentSignal,
        sessionID: String,
        agent: String? = nil,
        lastEvent: String? = nil,
        updatedAt: Date = Date(),
        quota: AgentQuotaStatus? = nil
    ) throws -> SignalSnapshot {
        try withStateLock {
            let now = Date()
            let eventDate = updatedAt
            var document = try readDocument()
            let existingBeforePrune = document.sessions[sessionID]

            if shouldIgnoreOutOfOrderEvent(
                existing: existingBeforePrune,
                updatedAt: eventDate
            ) {
                return document.snapshot(stateFileURL: stateFileURL)
            }

            let pruneResult = pruneRuntimeSessions(in: &document, now: now)

            if shouldIgnoreCompletedSessionReplay(
                existing: document.sessions[sessionID] ?? existingBeforePrune,
                signal: signal,
                event: lastEvent
            ) {
                updateAggregateAfterPruning(in: &document, pruneResult: pruneResult)
                return document.snapshot(stateFileURL: stateFileURL)
            }

            let shouldHoldCurrentAlert = shouldHoldTransientAlert(
                existing: document.sessions[sessionID] ?? existingBeforePrune,
                incomingSignal: signal,
                updatedAt: eventDate
            )

            switch signal {
            case .off, .pause, .paused:
                document.sessions.removeAll()
                document.aggregate = .off
            case .sessionEnd:
                let currentSignal = document.sessions[sessionID]?.signal
                if currentSignal == nil || currentSignal?.preserveAgainstSessionEndSignal == false {
                    document.sessions.removeValue(forKey: sessionID)
                }
                if document.sessions.isEmpty && document.aggregate?.displayState != .paused {
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
                    agent: agent ?? existingBeforePrune?.agent,
                    signal: .idle,
                    lastEvent: lastEvent,
                    updatedAt: eventDate,
                    quota: quota ?? existingBeforePrune?.quota
                )
            case .done:
                if document.sessions[sessionID]?.signal.preserveAgainstCompletedSignal != true {
                    document.sessions[sessionID] = SessionRecord(
                        agent: agent ?? existingBeforePrune?.agent,
                        signal: signal,
                        lastEvent: lastEvent,
                        updatedAt: eventDate,
                        quota: quota ?? existingBeforePrune?.quota
                    )
                }
            default:
                if !shouldHoldCurrentAlert {
                    document.sessions[sessionID] = SessionRecord(
                        agent: agent ?? existingBeforePrune?.agent,
                        signal: signal,
                        lastEvent: lastEvent,
                        updatedAt: eventDate,
                        quota: quota ?? existingBeforePrune?.quota
                    )
                }
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
                updatedAt: eventDate
            )
            document.updatedAt = eventDate
            try writeDocument(document)
            return document.snapshot(stateFileURL: stateFileURL)
        }
    }

    public func applySessionQuota(
        _ quota: AgentQuotaStatus,
        sessionID: String,
        agent: String? = nil,
        updatedAt: Date = Date()
    ) throws -> SignalSnapshot {
        try withStateLock {
            let now = Date()
            var document = try readDocument()
            let pruneResult = pruneRuntimeSessions(in: &document, now: now)

            if var record = document.sessions[sessionID] {
                record.quota = quota
                record.updatedAt = max(record.updatedAt, updatedAt)
                if record.agent == nil {
                    record.agent = agent
                }
                document.sessions[sessionID] = record
            } else {
                document.sessions[sessionID] = SessionRecord(
                    agent: agent,
                    signal: .idle,
                    lastEvent: "DesktopQuota",
                    updatedAt: updatedAt,
                    quota: quota
                )
            }

            updateAggregateAfterPruning(in: &document, pruneResult: pruneResult)
            document.updatedAt = max(document.updatedAt ?? updatedAt, updatedAt)
            try writeDocument(document)
            return document.snapshot(stateFileURL: stateFileURL)
        }
    }

}

private extension AgentSignal {
    // 会话结束（sessionEnd）是明确的终态事件，不应被之前的 blocked 状态保留，
    // 否则即便 agent 已结束/解除阻塞，红灯仍会卡到 TTL 过期才熄灭。
    var preserveAgainstSessionEndSignal: Bool {
        switch displayState {
        case .completed, .needsReview, .stale, .paused:
            return true
        case .ready, .active, .permission, .blocked:
            return false
        }
    }

    // 收到明确的完成信号（done）时，blocked 状态也应被覆盖，
    // 否则 blocked 红灯会一直保留到 TTL 过期。
    var preserveAgainstCompletedSignal: Bool {
        switch displayState {
        case .stale, .paused:
            return true
        case .ready, .active, .completed, .needsReview, .permission, .blocked:
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
        var document = try readDocument()
        let originalDocument = document
        let now = Date()
        prepareSnapshotDocument(&document, now: now)

        if persistingRuntimeChanges && document != originalDocument {
            document.updatedAt = now
            try writeDocument(document)
        }

        return document.snapshot(stateFileURL: stateFileURL)
    }

    func prepareSnapshotDocument(_ document: inout SignalStateDocument, now: Date) {
        let pruneResult = pruneRuntimeSessions(in: &document, now: now)
        compactEventHistory(in: &document)
        updateAggregateAfterPruning(in: &document, pruneResult: pruneResult)
    }

    func updateAggregateAfterPruning(
        in document: inout SignalStateDocument,
        pruneResult: RuntimePruneResult
    ) {
        if pruneResult.hadSessionsBeforePrune && document.sessions.isEmpty && document.aggregate?.displayState != .paused {
            document.aggregate = pruneResult.removedNonCompletedSession ? .stale : .idle
        } else if !document.sessions.isEmpty {
            document.aggregate = document.aggregateSignal()
        }
    }

    func shouldIgnoreOutOfOrderEvent(
        existing: SessionRecord?,
        updatedAt eventDate: Date
    ) -> Bool {
        guard let existing else { return false }
        return existing.updatedAt > eventDate
    }

    func shouldIgnoreCompletedSessionReplay(
        existing: SessionRecord?,
        signal: AgentSignal,
        event: String?
    ) -> Bool {
        guard existing?.signal.displayState == .completed,
              signal.displayState == .active,
              let event
        else {
            return false
        }

        switch event {
        case "DesktopActivityHeartbeat",
             "DesktopThinking",
             "DesktopMessage",
             "DesktopToolDone":
            return true
        default:
            return false
        }
    }

    func shouldHoldTransientAlert(
        existing: SessionRecord?,
        incomingSignal: AgentSignal,
        updatedAt eventDate: Date
    ) -> Bool {
        guard let existing,
              isTransientAlert(existing.signal.displayState),
              isResolvingOrLowerPriorityAlert(incomingSignal.displayState)
        else {
            return false
        }

        return eventDate.timeIntervalSince(existing.updatedAt) <= Self.transientAlertHoldWindow
    }

    func isTransientAlert(_ displayState: DisplayState) -> Bool {
        displayState == .permission || displayState == .needsReview
    }

    func isResolvingOrLowerPriorityAlert(_ displayState: DisplayState) -> Bool {
        switch displayState {
        case .active, .completed, .needsReview:
            return true
        case .ready, .permission, .blocked, .stale, .paused:
            return false
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

        removeDuplicateEvent(record, from: &document.events)
        document.events.append(
            record
        )

        compactEventHistory(in: &document)
    }

    func eventDeduplicationKey(
        sessionID: String,
        agent: String?,
        signal: AgentSignal,
        event: String?
    ) -> String {
        let normalizedAgent = agent?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")
            ?? ""
        let normalizedEvent = event?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        ?? signal.rawValue

        return "\(sessionID)|\(normalizedAgent)|\(signal.rawValue)|\(normalizedEvent)"
    }

    func removeDuplicateEvent(_ event: SignalEventRecord, from events: inout [SignalEventRecord]) {
        let duplicateKey = eventDeduplicationKey(
            sessionID: event.sessionID,
            agent: event.agent,
            signal: event.signal,
            event: event.event
        )
        guard let duplicateIndex = events.lastIndex(where: { existing in
            eventDeduplicationKey(
                sessionID: existing.sessionID,
                agent: existing.agent,
                signal: existing.signal,
                event: existing.event
            ) == duplicateKey
                && abs(existing.updatedAt.timeIntervalSince(event.updatedAt)) <= Self.duplicateEventWindow
        }) else {
            return
        }

        events.remove(at: duplicateIndex)
    }

    func compactEventHistory(in document: inout SignalStateDocument) {
        var compactedEvents: [SignalEventRecord] = []
        for event in document.events {
            removeDuplicateEvent(event, from: &compactedEvents)
            compactedEvents.append(event)
        }

        if compactedEvents.count > eventLimit {
            compactedEvents = Array(compactedEvents.suffix(eventLimit))
        }

        document.events = compactedEvents
    }

    func readDocument() throws -> SignalStateDocument {
        guard let data = try readSecureStateDataIfPresent() else {
            return SignalStateDocument()
        }

        do {
            return try decoder.decode(SignalStateDocument.self, from: data)
        } catch {
            return SignalStateDocument(aggregate: .stale, updatedAt: Date())
        }
    }

    func writeDocument(_ document: SignalStateDocument) throws {
        try prepareStateDirectory()
        _ = try validateSecureStateFileIfPresent()
        let data = try encoder.encode(document)
        try writeSecureAtomicData(data, to: stateFileURL)
    }

    func withStateLock<T>(_ body: () throws -> T) throws -> T {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        try prepareStateDirectory()
        let directory = stateFileURL.deletingLastPathComponent()
        let lockURL = directory.appendingPathComponent("state.lock")
        let fileDescriptor = Darwin.open(
            lockURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard fileDescriptor >= 0 else {
            throw SignalStateStoreError.cannotOpenLock(lockURL.path)
        }

        var lockInfo = stat()
        guard Darwin.fstat(fileDescriptor, &lockInfo) == 0,
              isSecureRegularFile(lockInfo)
        else {
            Darwin.close(fileDescriptor)
            throw SignalStateStoreError.cannotOpenLock(lockURL.path)
        }
        do {
            try hardenPrivateLeafDescriptor(fileDescriptor)
        } catch {
            Darwin.close(fileDescriptor)
            throw SignalStateStoreError.cannotOpenLock(lockURL.path)
        }

        var lock = flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        while fcntl(fileDescriptor, F_SETLKW, &lock) != 0 {
            let errorCode = errno
            if errorCode == EINTR {
                continue
            }

            Darwin.close(fileDescriptor)
            throw SignalStateStoreError.cannotAcquireLock(lockURL.path, errorCode)
        }
        defer {
            var unlock = flock()
            unlock.l_type = Int16(F_UNLCK)
            unlock.l_whence = Int16(SEEK_SET)
            _ = fcntl(fileDescriptor, F_SETLK, &unlock)
            Darwin.close(fileDescriptor)
        }

        return try body()
    }

    func prepareStateDirectory() throws {
        let directory = stateFileURL.deletingLastPathComponent()
        if enforcesPrivateStateDirectory {
            try ensureDirectory(
                at: directory.deletingLastPathComponent(),
                requiresPrivateExistingDirectory: true
            )
        }
        try ensureDirectory(
            at: directory,
            requiresPrivateExistingDirectory: enforcesPrivateStateDirectory
        )
    }

    func ensureDirectory(
        at directory: URL,
        requiresPrivateExistingDirectory: Bool
    ) throws {
        var info = stat()
        let existed = Darwin.lstat(directory.path, &info) == 0

        if !existed {
            guard errno == ENOENT else {
                throw SignalStateStoreError.unsafeStateDirectory(directory)
            }
            do {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: NSNumber(value: 0o700)]
                )
            } catch {
                throw SignalStateStoreError.cannotCreateStateDirectory(directory, error)
            }
        }

        let directoryDescriptor = Darwin.open(
            directory.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard directoryDescriptor >= 0 else {
            throw SignalStateStoreError.unsafeStateDirectory(directory)
        }
        defer { Darwin.close(directoryDescriptor) }

        guard Darwin.fstat(directoryDescriptor, &info) == 0,
              isDirectory(info),
              info.st_uid == geteuid(),
              (info.st_mode & mode_t(0o022)) == 0
        else {
            throw SignalStateStoreError.unsafeStateDirectory(directory)
        }

        do {
            if !existed || requiresPrivateExistingDirectory {
                try removeExtendedACL(from: directoryDescriptor)
                guard Darwin.fchmod(directoryDescriptor, mode_t(0o700)) == 0 else {
                    throw SignalStateStoreError.unsafeStateDirectory(directory)
                }
            } else if try hasExtendedACL(on: directoryDescriptor) {
                throw SignalStateStoreError.unsafeStateDirectory(directory)
            }
        } catch let error as SignalStateStoreError {
            throw error
        } catch {
            throw SignalStateStoreError.unsafeStateDirectory(directory)
        }
    }

    func validateSecureStateFileIfPresent() throws -> Bool {
        guard let fileDescriptor = try openSecureStateFileIfPresent() else { return false }
        Darwin.close(fileDescriptor)
        return true
    }

    func readSecureStateDataIfPresent() throws -> Data? {
        guard let fileDescriptor = try openSecureStateFileIfPresent() else { return nil }
        defer { Darwin.close(fileDescriptor) }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let bytesRead = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(fileDescriptor, bytes.baseAddress, bytes.count)
            }
            if bytesRead == 0 {
                return data
            }
            if bytesRead < 0 {
                if errno == EINTR { continue }
                throw SignalStateStoreError.unsafeStateFile(stateFileURL)
            }
            data.append(contentsOf: buffer.prefix(Int(bytesRead)))
        }
    }

    func openSecureStateFileIfPresent() throws -> Int32? {
        let fileDescriptor = Darwin.open(
            stateFileURL.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard fileDescriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw SignalStateStoreError.unsafeStateFile(stateFileURL)
        }

        var info = stat()
        guard Darwin.fstat(fileDescriptor, &info) == 0,
              isSecureRegularFile(info)
        else {
            Darwin.close(fileDescriptor)
            throw SignalStateStoreError.unsafeStateFile(stateFileURL)
        }

        do {
            try hardenPrivateLeafDescriptor(fileDescriptor)
        } catch {
            Darwin.close(fileDescriptor)
            throw SignalStateStoreError.unsafeStateFile(stateFileURL)
        }
        return fileDescriptor
    }

    func writeSecureAtomicData(_ data: Data, to destination: URL) throws {
        let temporaryURL = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
        )
        var fileDescriptor = Darwin.open(
            temporaryURL.path,
            O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard fileDescriptor >= 0 else {
            throw posixError()
        }

        var shouldRemoveTemporaryFile = true
        defer {
            if fileDescriptor >= 0 {
                Darwin.close(fileDescriptor)
            }
            if shouldRemoveTemporaryFile {
                Darwin.unlink(temporaryURL.path)
            }
        }

        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                guard let baseAddress = bytes.baseAddress else { break }
                let written = Darwin.write(
                    fileDescriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if written < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw posixError()
                }
                guard written > 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
                }
                offset += written
            }
        }

        try hardenPrivateLeafDescriptor(fileDescriptor)
        guard Darwin.fsync(fileDescriptor) == 0 else {
            throw posixError()
        }
        let closeResult = Darwin.close(fileDescriptor)
        fileDescriptor = -1
        guard closeResult == 0 else {
            throw posixError()
        }
        guard Darwin.rename(temporaryURL.path, destination.path) == 0 else {
            throw posixError()
        }
        shouldRemoveTemporaryFile = false

        let directoryDescriptor = Darwin.open(
            destination.deletingLastPathComponent().path,
            O_RDONLY | O_CLOEXEC
        )
        if directoryDescriptor >= 0 {
            _ = Darwin.fsync(directoryDescriptor)
            Darwin.close(directoryDescriptor)
        }
    }

    func isDirectory(_ info: stat) -> Bool {
        (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
    }

    func isSecureRegularFile(_ info: stat) -> Bool {
        (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
            && info.st_uid == geteuid()
            && info.st_nlink == 1
    }

    func hardenPrivateLeafDescriptor(_ fileDescriptor: Int32) throws {
        try removeExtendedACL(from: fileDescriptor)
        guard Darwin.fchmod(fileDescriptor, mode_t(0o600)) == 0 else {
            throw posixError()
        }
    }

    func hasExtendedACL(on fileDescriptor: Int32) throws -> Bool {
        errno = 0
        guard let acl = acl_get_fd_np(fileDescriptor, ACL_TYPE_EXTENDED) else {
            if errno == ENOENT { return false }
            throw posixError()
        }
        acl_free(UnsafeMutableRawPointer(acl))
        return true
    }

    func removeExtendedACL(from fileDescriptor: Int32) throws {
        guard try hasExtendedACL(on: fileDescriptor) else { return }
        guard let emptyACL = acl_init(1) else {
            throw posixError()
        }
        defer { acl_free(UnsafeMutableRawPointer(emptyACL)) }
        guard acl_set_fd_np(fileDescriptor, emptyACL, ACL_TYPE_EXTENDED) == 0 else {
            throw posixError()
        }
    }

    func posixError() -> Error {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}

private extension String {
    var expandingTildeInPath: String {
        (self as NSString).expandingTildeInPath
    }
}

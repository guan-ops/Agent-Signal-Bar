import AgentSignalLightCore
import Foundation

final class CodexDesktopActivityMonitor: @unchecked Sendable {
    private struct SessionFile {
        let url: URL
        let path: String
        let modifiedAt: Date
        let size: UInt64
        let forcedAgent: String?
    }

    private let sessionRootURLs: [URL]
    private let forcedAgentsByRootPath: [String: String]
    private let vsCodeLogRootURL: URL?
    private let fileManager: FileManager
    private let recentFileLimit: Int
    private let initialLookbackSeconds: TimeInterval
    private let completedLookbackSeconds: TimeInterval
    private let maxInitialTailBytes: UInt64
    private let fullScanInterval: TimeInterval
    private let vsCodeHintScanInterval: TimeInterval
    private let vsCodeHintLookbackSeconds: TimeInterval
    private let maxVSCodeLogBytes: UInt64
    private let replaysInitialHistory: Bool
    private let stateLock = NSLock()
    private var offsetsByPath: [String: UInt64] = [:]
    private var agentsByPath: [String: String] = [:]
    private var forcedAgentsBySessionID: [String: String] = [:]
    private var completedAtBySessionID: [String: Date] = [:]
    private var cachedRecentFiles: [SessionFile] = []
    private var lastFullScanAt: Date?
    private var lastVSCodeHintScanAt: Date?
    private var hasPrimedExistingFiles = false

    init(
        sessionsRootURL: URL? = nil,
        sessionRootURLs: [URL]? = nil,
        forcedAgentsByRootPath: [String: String] = [:],
        vsCodeLogRootURL: URL? = nil,
        fileManager: FileManager = .default,
        recentFileLimit: Int = 8,
        initialLookbackSeconds: TimeInterval = 30 * 60,
        completedLookbackSeconds: TimeInterval = 15,
        maxInitialTailBytes: UInt64 = 512 * 1024,
        fullScanInterval: TimeInterval = 1.5,
        vsCodeHintScanInterval: TimeInterval = 5,
        vsCodeHintLookbackSeconds: TimeInterval = 24 * 60 * 60,
        maxVSCodeLogBytes: UInt64 = 256 * 1024,
        replaysInitialHistory: Bool = false
    ) {
        self.fileManager = fileManager
        let home = fileManager.homeDirectoryForCurrentUser
        let defaults = Self.defaultSessionRoots(fileManager: fileManager)
        if let sessionRootURLs {
            self.sessionRootURLs = sessionRootURLs
        } else if let sessionsRootURL {
            self.sessionRootURLs = [sessionsRootURL]
        } else {
            self.sessionRootURLs = defaults.map { $0.url }
        }
        let normalizedForcedAgents = Dictionary(
            uniqueKeysWithValues: forcedAgentsByRootPath.map { key, value in
                (Self.normalizedPath(key), value)
            }
        )
        self.forcedAgentsByRootPath = normalizedForcedAgents.merging(
            Dictionary(uniqueKeysWithValues: defaults.compactMap { root in
                root.forcedAgent.map { (Self.normalizedPath(root.url.path), $0) }
            }),
            uniquingKeysWith: { explicit, _ in explicit }
        )
        self.vsCodeLogRootURL = vsCodeLogRootURL
            ?? home.appendingPathComponent("Library/Application Support/Code/logs", isDirectory: true)
        self.recentFileLimit = recentFileLimit
        self.initialLookbackSeconds = initialLookbackSeconds
        self.completedLookbackSeconds = completedLookbackSeconds
        self.maxInitialTailBytes = maxInitialTailBytes
        self.fullScanInterval = fullScanInterval
        self.vsCodeHintScanInterval = vsCodeHintScanInterval
        self.vsCodeHintLookbackSeconds = vsCodeHintLookbackSeconds
        self.maxVSCodeLogBytes = maxVSCodeLogBytes
        self.replaysInitialHistory = replaysInitialHistory
    }

    private static func defaultSessionRoots(fileManager: FileManager) -> [(url: URL, forcedAgent: String?)] {
        let home = fileManager.homeDirectoryForCurrentUser
        var roots: [(url: URL, forcedAgent: String?)] = [
            (home.appendingPathComponent(".codex/sessions", isDirectory: true), nil)
        ]

        let xcodeSessions = home.appendingPathComponent(
            "Library/Developer/Xcode/CodingAssistant/codex/sessions",
            isDirectory: true
        )
        var isXcodeDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: xcodeSessions.path, isDirectory: &isXcodeDirectory),
           isXcodeDirectory.boolValue {
            roots.append((xcodeSessions, "codex-xcode"))
        }

        let jetBrainsCache = home.appendingPathComponent(
            "Library/Caches/JetBrains",
            isDirectory: true
        )
        if let products = try? fileManager.contentsOfDirectory(
            at: jetBrainsCache,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for product in products {
                let sessionsRoot = product
                    .appendingPathComponent("aia/codex/sessions", isDirectory: true)
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: sessionsRoot.path, isDirectory: &isDirectory),
                      isDirectory.boolValue
                else {
                    continue
                }
                roots.append((sessionsRoot, forcedAgentName(forJetBrainsProduct: product.lastPathComponent)))
            }
        }

        return roots
    }

    func reset() {
        stateLock.lock()
        defer { stateLock.unlock() }
        offsetsByPath.removeAll()
        agentsByPath.removeAll()
        forcedAgentsBySessionID.removeAll()
        completedAtBySessionID.removeAll()
        cachedRecentFiles.removeAll()
        lastFullScanAt = nil
        lastVSCodeHintScanAt = nil
        hasPrimedExistingFiles = false
    }

    func poll(now: Date = Date()) -> [CodexDesktopActivity] {
        stateLock.lock()
        defer { stateLock.unlock() }

        let files = recentSessionFiles(now: now)
        if !hasPrimedExistingFiles {
            hasPrimedExistingFiles = true
            let activities = primeExistingFiles(files, returningActivities: replaysInitialHistory)
            guard replaysInitialHistory else { return [] }
            return sortedAcceptedActivities(from: activities, now: now)
        }

        var activities: [CodexDesktopActivity] = []

        for file in files {
            let lines = readNewLines(from: file, now: now)
            activities.append(contentsOf: parsedActivities(from: lines, file: file))
        }

        return acceptedActivities(from: activities, now: now)
    }

    private func recentSessionFiles(now: Date) -> [SessionFile] {
        refreshExternalSessionSourceHints(now: now)

        if let lastFullScanAt, now.timeIntervalSince(lastFullScanAt) < fullScanInterval {
            cachedRecentFiles = refreshCachedSessionFiles()
            return cachedRecentFiles
        }

        cachedRecentFiles = scanRecentSessionFiles()
        lastFullScanAt = now
        return cachedRecentFiles
    }

    private func refreshCachedSessionFiles() -> [SessionFile] {
        Array(
            cachedRecentFiles
                .compactMap { sessionFile(for: $0.url) }
                .sorted { $0.modifiedAt > $1.modifiedAt }
                .prefix(recentFileLimit)
        )
    }

    private func scanRecentSessionFiles() -> [SessionFile] {
        var files: [SessionFile] = []
        var seenPaths = Set<String>()

        for rootURL in sessionRootURLs {
            guard let enumerator = fileManager.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for case let url as URL in enumerator {
                guard url.lastPathComponent.hasPrefix("rollout-"),
                      url.pathExtension == "jsonl",
                      !seenPaths.contains(url.path),
                      let values = try? url.resourceValues(forKeys: [
                        .isRegularFileKey,
                        .contentModificationDateKey,
                        .fileSizeKey
                      ]),
                      values.isRegularFile == true,
                      let modifiedAt = values.contentModificationDate,
                      let size = values.fileSize
                else {
                    continue
                }

                seenPaths.insert(url.path)
                files.append(
                    SessionFile(
                        url: url,
                        path: url.path,
                        modifiedAt: modifiedAt,
                        size: UInt64(size),
                        forcedAgent: forcedAgent(for: url)
                    )
                )
            }
        }

        return Array(
            files
                .sorted { $0.modifiedAt > $1.modifiedAt }
                .prefix(recentFileLimit)
        )
    }

    private func sessionFile(for url: URL) -> SessionFile? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular,
              let modifiedAt = attributes[.modificationDate] as? Date,
              let size = attributes[.size] as? NSNumber
        else {
            return nil
        }

        return SessionFile(
            url: url,
            path: url.path,
            modifiedAt: modifiedAt,
            size: size.uint64Value,
            forcedAgent: forcedAgent(for: url)
        )
    }

    private func forcedAgent(for url: URL) -> String? {
        let path = Self.normalizedPath(url.path)
        let match = forcedAgentsByRootPath
            .filter { rootPath, _ in
                path == rootPath || path.hasPrefix(rootPath + "/")
            }
            .sorted { $0.key.count > $1.key.count }
            .first
        if let rootAgent = match?.value {
            return rootAgent
        }

        guard let sessionID = Self.rolloutSessionID(from: url) else {
            return nil
        }
        return forcedAgentsBySessionID[sessionID]
    }

    private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    private func refreshExternalSessionSourceHints(now: Date) {
        guard let root = vsCodeLogRootURL else { return }
        if let lastVSCodeHintScanAt,
           now.timeIntervalSince(lastVSCodeHintScanAt) < vsCodeHintScanInterval {
            return
        }
        lastVSCodeHintScanAt = now

        for logFile in recentVSCodeLogFiles(root: root, now: now) {
            guard let data = readTailData(from: logFile, maxBytes: maxVSCodeLogBytes),
                  let text = String(data: data, encoding: .utf8)
            else {
                continue
            }

            for sessionID in Self.conversationIDs(in: text) {
                forcedAgentsBySessionID[sessionID] = "codex-vscode"
            }
        }
    }

    private func recentVSCodeLogFiles(root: URL, now: Date) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [(url: URL, modifiedAt: Date)] = []
        for case let url as URL in enumerator {
            guard url.lastPathComponent.hasPrefix("Codex"),
                  url.pathExtension == "log",
                  url.path.contains("/openai.chatgpt/"),
                  let values = try? url.resourceValues(forKeys: [
                    .isRegularFileKey,
                    .contentModificationDateKey
                  ]),
                  values.isRegularFile == true,
                  let modifiedAt = values.contentModificationDate,
                  now.timeIntervalSince(modifiedAt) <= vsCodeHintLookbackSeconds
            else {
                continue
            }
            files.append((url, modifiedAt))
        }

        return files
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(12)
            .map(\.url)
    }

    private func readTailData(from url: URL, maxBytes: UInt64) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        do {
            let size = try handle.seekToEnd()
            let offset = size > maxBytes ? size - maxBytes : 0
            try handle.seek(toOffset: offset)
            return try handle.readToEnd()
        } catch {
            return nil
        }
    }

    private static func conversationIDs(in text: String) -> Set<String> {
        let pattern = #"conversationId=([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: nsRange)
        return Set(matches.compactMap { match in
            guard let range = Range(match.range(at: 1), in: text) else {
                return nil
            }
            return String(text[range]).lowercased()
        })
    }

    private static func rolloutSessionID(from url: URL) -> String? {
        let basename = url.deletingPathExtension().lastPathComponent
        let parts = basename.split(separator: "-")
        guard parts.count >= 5 else { return nil }

        let candidate = parts.suffix(5).joined(separator: "-").lowercased()
        guard candidate.count == 36 else { return nil }
        return candidate
    }

    private func primeExistingFiles(
        _ files: [SessionFile],
        returningActivities: Bool
    ) -> [CodexDesktopActivity] {
        var activities: [CodexDesktopActivity] = []

        for file in files {
            let initialTail = readInitialTailLines(from: file)
            offsetsByPath[file.path] = initialTail.nextOffset

            for line in initialTail.lines {
                if let forcedAgent = file.forcedAgent,
                   CodexDesktopSessionParser.agentName(fromSessionMetaLine: line) != nil {
                    agentsByPath[file.path] = forcedAgent
                    break
                }
                if let agent = CodexDesktopSessionParser.agentName(fromSessionMetaLine: line) {
                    agentsByPath[file.path] = agent
                    break
                }
            }

            let fileActivities = parsedActivities(from: initialTail.lines, file: file)

            guard returningActivities else {
                rememberCompletionState(from: fileActivities, now: Date())
                continue
            }

            activities.append(contentsOf: fileActivities)
        }

        return activities
    }

    private func parsedActivities(from lines: [String], file: SessionFile) -> [CodexDesktopActivity] {
        var activities: [CodexDesktopActivity] = []

        for line in lines {
            if let forcedAgent = file.forcedAgent,
               CodexDesktopSessionParser.agentName(fromSessionMetaLine: line) != nil {
                agentsByPath[file.path] = forcedAgent
                continue
            }
            if let agent = CodexDesktopSessionParser.agentName(fromSessionMetaLine: line) {
                agentsByPath[file.path] = agent
                continue
            }

            let agent = file.forcedAgent ?? agentsByPath[file.path] ?? "codex-desktop"
            if let forcedAgent = file.forcedAgent {
                agentsByPath[file.path] = forcedAgent
            }
            let defaultSessionID = sessionID(for: file.url, agent: agent)
            guard let activity = CodexDesktopSessionParser.activity(
                from: line,
                defaultSessionID: defaultSessionID,
                defaultAgent: agent
            ) else {
                continue
            }
            activities.append(activity)
        }

        return activities
    }

    private func readNewLines(from file: SessionFile, now: Date) -> [String] {
        let previousOffset = offsetsByPath[file.path]
        let startOffset: UInt64
        let shouldDropLeadingPartialLine: Bool

        if let previousOffset {
            guard file.size > previousOffset else {
                if file.size < previousOffset {
                    offsetsByPath[file.path] = 0
                }
                return []
            }
            startOffset = previousOffset
            shouldDropLeadingPartialLine = false
        } else {
            guard now.timeIntervalSince(file.modifiedAt) <= initialLookbackSeconds else {
                offsetsByPath[file.path] = file.size
                return []
            }
            startOffset = file.size > maxInitialTailBytes ? file.size - maxInitialTailBytes : 0
            shouldDropLeadingPartialLine = startOffset > 0
        }

        guard let data = readData(from: file.url, offset: startOffset),
              !data.isEmpty
        else {
            return []
        }

        let result = completeDecodedLines(
            in: data,
            startOffset: startOffset,
            shouldDropLeadingPartialLine: shouldDropLeadingPartialLine
        )
        offsetsByPath[file.path] = result.nextOffset
        return result.lines
    }

    private func readInitialTailLines(from file: SessionFile) -> (lines: [String], nextOffset: UInt64) {
        let startOffset = file.size > maxInitialTailBytes ? file.size - maxInitialTailBytes : 0
        let shouldDropLeadingPartialLine = startOffset > 0

        guard let data = readData(from: file.url, offset: startOffset),
              !data.isEmpty
        else {
            return ([], startOffset)
        }

        return completeDecodedLines(
            in: data,
            startOffset: startOffset,
            shouldDropLeadingPartialLine: shouldDropLeadingPartialLine
        )
    }

    private func completeDecodedLines(
        in data: Data,
        startOffset: UInt64,
        shouldDropLeadingPartialLine: Bool
    ) -> (lines: [String], nextOffset: UInt64) {
        var result = completeLineData(in: data, startOffset: startOffset)
        if shouldDropLeadingPartialLine, !result.lines.isEmpty {
            result.lines.removeFirst()
        }

        return (
            result.lines.compactMap { String(data: $0, encoding: .utf8) },
            result.nextOffset
        )
    }

    private func completeLineData(
        in data: Data,
        startOffset: UInt64
    ) -> (lines: [Data], nextOffset: UInt64) {
        guard let lastNewlineIndex = data.lastIndex(of: 0x0A) else {
            return ([], startOffset)
        }

        let completedEnd = data.index(after: lastNewlineIndex)
        let completedData = data[..<completedEnd]
        let completedByteCount = data.distance(from: data.startIndex, to: completedEnd)
        let lines = completedData
            .split(separator: 0x0A, omittingEmptySubsequences: true)
            .map { Data($0) }

        return (lines, startOffset + UInt64(completedByteCount))
    }

    private func readData(from url: URL, offset: UInt64) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer {
            try? handle.close()
        }

        do {
            try handle.seek(toOffset: offset)
            return try handle.readToEnd()
        } catch {
            return nil
        }
    }

    private func shouldAccept(_ activity: CodexDesktopActivity, now: Date) -> Bool {
        guard let timestamp = activity.timestamp else {
            return true
        }

        let age = now.timeIntervalSince(timestamp)
        if isShortLivedReplaySignal(activity.signal) {
            return age <= completedLookbackSeconds
        }
        return age <= initialLookbackSeconds
    }

    private func sortedAcceptedActivities(
        from activities: [CodexDesktopActivity],
        now: Date
    ) -> [CodexDesktopActivity] {
        acceptedActivities(from: activities, now: now)
            .filter { !isSupersededByCompletion($0, in: activities) }
    }

    private func sortedActivities(_ activities: [CodexDesktopActivity]) -> [CodexDesktopActivity] {
        activities.sorted { lhs, rhs in
            (lhs.timestamp ?? .distantPast) < (rhs.timestamp ?? .distantPast)
        }
    }

    private func acceptedActivities(
        from activities: [CodexDesktopActivity],
        now: Date
    ) -> [CodexDesktopActivity] {
        var accepted: [CodexDesktopActivity] = []

        for activity in sortedActivities(activities) {
            guard shouldAccept(activity, now: now),
                  shouldAcceptAfterCompletion(activity)
            else {
                continue
            }

            rememberCompletionState(from: activity, now: now)

            accepted.append(activity)
        }

        return accepted
    }

    private func rememberCompletionState(from activities: [CodexDesktopActivity], now: Date) {
        for activity in sortedActivities(activities) {
            rememberCompletionState(from: activity, now: now)
        }
    }

    private func rememberCompletionState(from activity: CodexDesktopActivity, now: Date) {
        if activity.signal.displayState == .completed {
            completedAtBySessionID[activity.sessionID] = activity.timestamp ?? now
        } else if startsNewTurn(activity) {
            completedAtBySessionID.removeValue(forKey: activity.sessionID)
        }
    }

    private func shouldAcceptAfterCompletion(_ activity: CodexDesktopActivity) -> Bool {
        guard let completedAt = completedAtBySessionID[activity.sessionID],
              activity.signal.displayState == .active
        else {
            return true
        }

        if startsNewTurn(activity) {
            return true
        }

        guard let timestamp = activity.timestamp else {
            return true
        }

        if timestamp <= completedAt {
            return false
        }

        return !isCompletionReplayActivity(activity)
    }

    private func startsNewTurn(_ activity: CodexDesktopActivity) -> Bool {
        activity.event == "DesktopTaskStarted"
            || activity.event.hasPrefix("DesktopToolCall:")
    }

    private func isCompletionReplayActivity(_ activity: CodexDesktopActivity) -> Bool {
        switch activity.event {
        case "DesktopActivityHeartbeat",
             "DesktopThinking",
             "DesktopMessage",
             "DesktopToolDone":
            return true
        default:
            return false
        }
    }

    private func isSupersededByCompletion(
        _ activity: CodexDesktopActivity,
        in activities: [CodexDesktopActivity]
    ) -> Bool {
        guard activity.signal.displayState != .completed,
              let activityTimestamp = activity.timestamp
        else {
            return false
        }

        return activities.contains { candidate in
            guard candidate.sessionID == activity.sessionID,
                  candidate.signal.displayState == .completed,
                  let completionTimestamp = candidate.timestamp
            else {
                return false
            }

            return completionTimestamp >= activityTimestamp
        }
    }

    private func isShortLivedReplaySignal(_ signal: AgentSignal) -> Bool {
        switch signal {
        case .done, .toolDone, .subagentStop:
            return true
        default:
            return signal.displayState == .completed
        }
    }

    private func sessionID(for url: URL, agent: String) -> String {
        let basename = url.deletingPathExtension().lastPathComponent
        let parts = basename.split(separator: "-")
        let prefix = sessionPrefix(for: agent)
        guard parts.count >= 5 else { return prefix }

        let candidate = parts.suffix(5).joined(separator: "-")
        if candidate.count == 36 {
            return "\(prefix):\(candidate)"
        }
        return prefix
    }

    private func sessionPrefix(for agent: String) -> String {
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

    private static func forcedAgentName(forJetBrainsProduct productName: String) -> String {
        let normalized = productName.lowercased()
        if normalized.contains("intellij") || normalized.contains("idea") {
            return "codex-idea"
        }
        return "codex-jetbrains"
    }
}

import AgentSignalLightCore
import Foundation

struct CodexDesktopActivityPollResult: Sendable {
    var activities: [CodexDesktopActivity] = []
    var quotaUpdates: [CodexDesktopQuotaUpdate] = []
}

final class CodexDesktopActivityMonitor: @unchecked Sendable {
    private struct SessionFile {
        let url: URL
        let path: String
        let generation: String
        let statFingerprint: Int64
        let changeTimeNanoseconds: Int64
        let contentAnchor: FileContentAnchor
        let modifiedAt: Date
        let changedAt: Date
        let size: UInt64
        let forcedAgent: String?

        var activityAt: Date {
            max(modifiedAt, changedAt)
        }
    }

    private struct DecodedLine {
        let text: String
        let bytes: Data
        let endOffset: UInt64
    }

    private struct FileCursor {
        let generation: String
        let statFingerprint: Int64
        let changeTimeNanoseconds: Int64
        let offset: UInt64
        let contentAnchor: FileContentAnchor
    }

    private struct FileContentAnchor: Equatable {
        let throughOffset: UInt64
        let prefix: Data
        let suffix: Data
    }

    private struct FileReadResult {
        let data: Data
        let metadata: CostUsageScanner.CodexFileMetadata
    }

    private let sessionRootURLs: [URL]
    private let forcedAgentsByRootPath: [String: String]
    private let vsCodeLogRootURL: URL?
    private let fileManager: FileManager
    private let recentFileLimit: Int
    private let initialLookbackSeconds: TimeInterval
    private let completedLookbackSeconds: TimeInterval
    private let maxInitialTailBytes: UInt64
    private let maxSessionMetadataProbeBytes: Int
    private let fullScanInterval: TimeInterval
    private let vsCodeHintScanInterval: TimeInterval
    private let vsCodeHintLookbackSeconds: TimeInterval
    private let maxVSCodeLogBytes: UInt64
    private let replaysInitialHistory: Bool
    private let beforeSessionSnapshotReadHook: ((URL) -> Void)?
    private let beforeFileReadHook: ((URL) -> Void)?
    private static let contentAnchorSampleBytes = 4 * 1024
    private let stateLock = NSLock()
    private var cursorsByPath: [String: FileCursor] = [:]
    private var agentsByPath: [String: String] = [:]
    private var forkParentsByPath: [String: String] = [:]
    private var confirmedSessionIDsByPath: [String: String] = [:]
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
        maxSessionMetadataProbeBytes: Int = 256 * 1024,
        fullScanInterval: TimeInterval = 10,
        vsCodeHintScanInterval: TimeInterval = 30,
        vsCodeHintLookbackSeconds: TimeInterval = 24 * 60 * 60,
        maxVSCodeLogBytes: UInt64 = 256 * 1024,
        replaysInitialHistory: Bool = false,
        beforeSessionSnapshotReadHook: ((URL) -> Void)? = nil,
        beforeFileReadHook: ((URL) -> Void)? = nil
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
        self.maxSessionMetadataProbeBytes = max(1, maxSessionMetadataProbeBytes)
        self.fullScanInterval = fullScanInterval
        self.vsCodeHintScanInterval = vsCodeHintScanInterval
        self.vsCodeHintLookbackSeconds = vsCodeHintLookbackSeconds
        self.maxVSCodeLogBytes = maxVSCodeLogBytes
        self.replaysInitialHistory = replaysInitialHistory
        self.beforeSessionSnapshotReadHook = beforeSessionSnapshotReadHook
        self.beforeFileReadHook = beforeFileReadHook
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
        cursorsByPath.removeAll()
        agentsByPath.removeAll()
        forkParentsByPath.removeAll()
        confirmedSessionIDsByPath.removeAll()
        forcedAgentsBySessionID.removeAll()
        completedAtBySessionID.removeAll()
        cachedRecentFiles.removeAll()
        lastFullScanAt = nil
        lastVSCodeHintScanAt = nil
        hasPrimedExistingFiles = false
    }

    func poll(now: Date = Date()) -> [CodexDesktopActivity] {
        pollResult(now: now).activities
    }

    func pollResult(now: Date = Date()) -> CodexDesktopActivityPollResult {
        stateLock.lock()
        defer { stateLock.unlock() }

        let files = recentSessionFiles(now: now)
        if !hasPrimedExistingFiles {
            hasPrimedExistingFiles = true
            let result = primeExistingFiles(files, returningActivities: replaysInitialHistory)
            guard replaysInitialHistory else { return CodexDesktopActivityPollResult() }
            return CodexDesktopActivityPollResult(
                activities: sortedAcceptedActivities(from: result.activities, now: now),
                quotaUpdates: result.quotaUpdates
            )
        }

        var result = CodexDesktopActivityPollResult()

        for file in files {
            let lines = readNewLines(from: file, now: now)
            let fileResult = parsedActivityPollResult(from: lines, file: file)
            result.activities.append(contentsOf: fileResult.activities)
            result.quotaUpdates.append(contentsOf: fileResult.quotaUpdates)
        }

        result.activities = acceptedActivities(from: result.activities, now: now)
        return result
    }

    private func recentSessionFiles(now: Date) -> [SessionFile] {
        refreshExternalSessionSourceHints(now: now)

        if let lastFullScanAt, now.timeIntervalSince(lastFullScanAt) < fullScanInterval {
            cachedRecentFiles = refreshCachedSessionFiles()
            return cachedRecentFiles
        }

        let previousFiles = cachedRecentFiles
        let scannedFiles = scanRecentSessionFiles()
        let scannedPaths = Set(scannedFiles.map(\.path))
        let transientFallbacks = previousFiles.filter { file in
            !scannedPaths.contains(file.path) && isExistingRegularFile(atPath: file.path)
        }
        cachedRecentFiles = Array(
            (scannedFiles + transientFallbacks)
                .sorted { $0.activityAt > $1.activityAt }
                .prefix(recentFileLimit)
        )
        lastFullScanAt = now
        return cachedRecentFiles
    }

    private func refreshCachedSessionFiles() -> [SessionFile] {
        Array(
            cachedRecentFiles
                .compactMap { cached in
                    refreshedSessionFile(from: cached)
                        ?? (isExistingRegularFile(atPath: cached.path) ? cached : nil)
                }
                .sorted { $0.activityAt > $1.activityAt }
                .prefix(recentFileLimit)
        )
    }

    private func refreshedSessionFile(from cached: SessionFile) -> SessionFile? {
        guard isExistingRegularFile(atPath: cached.path) else { return nil }
        let pathMetadata = CostUsageScanner.codexFileMetadata(fileURL: cached.url)
        guard pathMetadata.fileId != nil else { return nil }
        if metadata(pathMetadata, matches: cached),
           isStableUnchangedSessionFile(cached, expectedMetadata: pathMetadata) {
            // The full directory scan periodically revalidates the descriptor and
            // content anchor. Between scans, unchanged stat metadata is enough to
            // avoid resampling every idle file on each short poll. The lightweight
            // descriptor/path check still binds this fast path to the same inode.
            return cached
        }
        return sessionFile(for: cached.url, expectedMetadata: pathMetadata)
    }

    private func isStableUnchangedSessionFile(
        _ cached: SessionFile,
        expectedMetadata: CostUsageScanner.CodexFileMetadata
    ) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: cached.url) else { return false }
        defer { try? handle.close() }
        let descriptorMetadata = CostUsageScanner.codexFileMetadata(
            fileDescriptor: handle.fileDescriptor,
            path: cached.path
        )
        let pathAfterOpen = CostUsageScanner.codexFileMetadata(fileURL: cached.url)
        return metadata(descriptorMetadata, matches: cached)
            && CostUsageScanner.codexFileMetadataIsSameSnapshot(
                descriptorMetadata,
                expectedMetadata
            )
            && CostUsageScanner.codexFileMetadataIsSameSnapshot(
                pathAfterOpen,
                descriptorMetadata
            )
    }

    private func isExistingRegularFile(atPath path: String) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: path)
        else { return false }
        return (attributes[.type] as? FileAttributeType) == .typeRegular
    }

    private func scanRecentSessionFiles() -> [SessionFile] {
        struct Candidate {
            let url: URL
            let metadata: CostUsageScanner.CodexFileMetadata
            let activityAt: Date
        }

        var candidates: [Candidate] = []
        var seenPaths = Set<String>()

        for rootURL in sessionRootURLs {
            guard let enumerator = fileManager.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for case let url as URL in enumerator {
                guard url.lastPathComponent.hasPrefix("rollout-"),
                      url.pathExtension == "jsonl",
                      !seenPaths.contains(url.path),
                      (try? url.resourceValues(forKeys: [.isRegularFileKey]))?
                        .isRegularFile == true
                else {
                    continue
                }
                seenPaths.insert(url.path)
                let metadata = CostUsageScanner.codexFileMetadata(fileURL: url)
                guard metadata.fileId != nil,
                      metadata.statFingerprint != nil,
                      let changeTimeNanoseconds = metadata.changeTimeNanoseconds,
                      metadata.size >= 0
                else { continue }
                candidates.append(Candidate(
                    url: url,
                    metadata: metadata,
                    activityAt: max(
                        Date(timeIntervalSince1970: Double(metadata.mtimeUnixMs) / 1_000),
                        Date(
                            timeIntervalSince1970:
                                Double(changeTimeNanoseconds) / 1_000_000_000
                        )
                    )
                ))
            }
        }

        var files: [SessionFile] = []
        for candidate in candidates.sorted(by: { $0.activityAt > $1.activityAt }) {
            guard files.count < recentFileLimit else { break }
            if let file = sessionFile(
                for: candidate.url,
                expectedMetadata: candidate.metadata
            ) {
                files.append(file)
            }
        }
        return files
    }

    private func sessionFile(for url: URL) -> SessionFile? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular
        else {
            return nil
        }

        let pathMetadata = CostUsageScanner.codexFileMetadata(fileURL: url)
        return sessionFile(for: url, expectedMetadata: pathMetadata)
    }

    private func sessionFile(
        for url: URL,
        expectedMetadata pathMetadata: CostUsageScanner.CodexFileMetadata
    ) -> SessionFile? {
        guard let snapshot = stableSessionSnapshot(
            for: url,
            expectedMetadata: pathMetadata
        ) else { return nil }
        let metadata = snapshot.metadata
        guard let generation = metadata.fileId,
              let statFingerprint = metadata.statFingerprint,
              let changeTimeNanoseconds = metadata.changeTimeNanoseconds,
              metadata.size >= 0
        else { return nil }

        return SessionFile(
            url: url,
            path: url.path,
            generation: generation,
            statFingerprint: statFingerprint,
            changeTimeNanoseconds: changeTimeNanoseconds,
            contentAnchor: snapshot.contentAnchor,
            modifiedAt: Date(timeIntervalSince1970: Double(metadata.mtimeUnixMs) / 1000),
            changedAt: Date(timeIntervalSince1970: Double(changeTimeNanoseconds) / 1_000_000_000),
            size: UInt64(metadata.size),
            forcedAgent: forcedAgent(for: url)
        )
    }

    private func stableSessionSnapshot(
        for url: URL,
        expectedMetadata: CostUsageScanner.CodexFileMetadata
    ) -> (metadata: CostUsageScanner.CodexFileMetadata, contentAnchor: FileContentAnchor)? {
        guard expectedMetadata.fileId != nil,
              expectedMetadata.size >= 0
        else { return nil }
        beforeSessionSnapshotReadHook?(url)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        do {
            let descriptorBefore = CostUsageScanner.codexFileMetadata(
                fileDescriptor: handle.fileDescriptor,
                path: url.path
            )
            let pathBefore = CostUsageScanner.codexFileMetadata(fileURL: url)
            guard CostUsageScanner.codexFileMetadataIsSameSnapshot(
                descriptorBefore,
                expectedMetadata
            ),
            CostUsageScanner.codexFileMetadataIsSameSnapshot(pathBefore, descriptorBefore),
            let size = UInt64(exactly: descriptorBefore.size),
            let anchorBefore = try contentAnchor(from: handle, throughOffset: size)
            else { return nil }

            let descriptorAfter = CostUsageScanner.codexFileMetadata(
                fileDescriptor: handle.fileDescriptor,
                path: url.path
            )
            let pathAfter = CostUsageScanner.codexFileMetadata(fileURL: url)
            guard CostUsageScanner.codexFileMetadataIsSameSnapshot(
                descriptorAfter,
                descriptorBefore
            ),
            CostUsageScanner.codexFileMetadataIsSameSnapshot(pathAfter, descriptorBefore),
            let anchorAfter = try contentAnchor(from: handle, throughOffset: size),
            anchorAfter == anchorBefore
            else { return nil }
            return (descriptorBefore, anchorBefore)
        } catch {
            return nil
        }
    }

    private func contentAnchor(
        from handle: FileHandle,
        throughOffset: UInt64
    ) throws -> FileContentAnchor? {
        let prefixCount = Int(min(
            throughOffset,
            UInt64(Self.contentAnchorSampleBytes)
        ))
        try handle.seek(toOffset: 0)
        guard let prefix = try readExactly(prefixCount, from: handle) else { return nil }

        let suffixStart = throughOffset > UInt64(Self.contentAnchorSampleBytes)
            ? throughOffset - UInt64(Self.contentAnchorSampleBytes)
            : 0
        let suffixCount = Int(throughOffset - suffixStart)
        let suffix: Data
        if suffixStart == 0 {
            suffix = prefix
        } else {
            try handle.seek(toOffset: suffixStart)
            guard let bytes = try readExactly(suffixCount, from: handle) else { return nil }
            suffix = bytes
        }
        return FileContentAnchor(
            throughOffset: throughOffset,
            prefix: prefix,
            suffix: suffix
        )
    }

    private func readExactly(_ count: Int, from handle: FileHandle) throws -> Data? {
        guard count > 0 else { return Data() }
        var result = Data()
        result.reserveCapacity(count)
        while result.count < count {
            guard let chunk = try handle.read(upToCount: count - result.count),
                  !chunk.isEmpty
            else { return nil }
            result.append(chunk)
        }
        return result
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

    private func readPrefixData(from file: SessionFile, maxBytes: Int) -> Data? {
        readData(from: file, offset: 0, maxBytes: maxBytes)?.data
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

    private func confirmSessionMetadataIfNeeded(for file: SessionFile) {
        guard confirmedSessionIDsByPath[file.path] == nil,
              let data = readPrefixData(
                  from: file,
                  maxBytes: maxSessionMetadataProbeBytes
              ),
              !data.isEmpty
        else {
            return
        }
        let lines = completeDecodedLines(
            in: data,
            startOffset: 0,
            shouldDropLeadingPartialLine: false
        ).lines
        for line in lines {
            recordSessionMetadata(from: line.text, file: file)
            if confirmedSessionIDsByPath[file.path] != nil { return }
        }
    }

    private func recordSessionMetadata(from line: String, file: SessionFile) {
        if let sessionID = CodexDesktopSessionParser.sessionID(fromSessionMetaLine: line) {
            confirmedSessionIDsByPath[file.path] = sessionID
        }
        if let forkParent = CodexDesktopSessionParser.forkedFromSessionID(
            fromSessionMetaLine: line
        ) {
            forkParentsByPath[file.path] = forkParent
        }
        if let forcedAgent = file.forcedAgent,
           CodexDesktopSessionParser.agentName(fromSessionMetaLine: line) != nil {
            agentsByPath[file.path] = forcedAgent
        } else if let agent = CodexDesktopSessionParser.agentName(fromSessionMetaLine: line) {
            agentsByPath[file.path] = agent
        }
    }

    private func confirmedSessionID(for file: SessionFile, agent: String) -> String? {
        confirmedSessionIDsByPath[file.path].map { "\(sessionPrefix(for: agent)):\($0)" }
    }

    private func primeExistingFiles(
        _ files: [SessionFile],
        returningActivities: Bool
    ) -> CodexDesktopActivityPollResult {
        var result = CodexDesktopActivityPollResult()

        for file in files {
            confirmSessionMetadataIfNeeded(for: file)
            guard let initialTail = readInitialTailLines(from: file) else { continue }
            cursorsByPath[file.path] = FileCursor(
                generation: file.generation,
                statFingerprint: initialTail.metadata.statFingerprint ?? file.statFingerprint,
                changeTimeNanoseconds: initialTail.metadata.changeTimeNanoseconds
                    ?? file.changeTimeNanoseconds,
                offset: initialTail.nextOffset,
                contentAnchor: initialTail.contentAnchor
            )

            for line in initialTail.lines {
                recordSessionMetadata(from: line.text, file: file)
                if let forkParent = CodexDesktopSessionParser.forkedFromSessionID(
                    fromSessionMetaLine: line.text
                ) {
                    forkParentsByPath[file.path] = forkParent
                }
                if let forcedAgent = file.forcedAgent,
                   CodexDesktopSessionParser.agentName(fromSessionMetaLine: line.text) != nil {
                    agentsByPath[file.path] = forcedAgent
                    break
                }
                if let agent = CodexDesktopSessionParser.agentName(fromSessionMetaLine: line.text) {
                    agentsByPath[file.path] = agent
                    break
                }
            }

            let fileResult = parsedActivityPollResult(from: initialTail.lines, file: file)

            guard returningActivities else {
                rememberCompletionState(from: fileResult.activities, now: Date())
                continue
            }

            result.activities.append(contentsOf: fileResult.activities)
            result.quotaUpdates.append(contentsOf: fileResult.quotaUpdates)
        }

        return result
    }

    private func parsedActivities(from lines: [DecodedLine], file: SessionFile) -> [CodexDesktopActivity] {
        parsedActivityPollResult(from: lines, file: file).activities
    }

    private func parsedActivityPollResult(
        from lines: [DecodedLine],
        file: SessionFile
    ) -> CodexDesktopActivityPollResult {
        var result = CodexDesktopActivityPollResult()
        var activities: [CodexDesktopActivity] = []

        for line in lines {
            recordSessionMetadata(from: line.text, file: file)
            if let forkParent = CodexDesktopSessionParser.forkedFromSessionID(
                fromSessionMetaLine: line.text
            ) {
                forkParentsByPath[file.path] = forkParent
            }
            if let forcedAgent = file.forcedAgent,
               CodexDesktopSessionParser.agentName(fromSessionMetaLine: line.text) != nil {
                agentsByPath[file.path] = forcedAgent
                continue
            }
            if let agent = CodexDesktopSessionParser.agentName(fromSessionMetaLine: line.text) {
                agentsByPath[file.path] = agent
                continue
            }

            let agent = file.forcedAgent ?? agentsByPath[file.path] ?? "codex-desktop"
            if let forcedAgent = file.forcedAgent {
                agentsByPath[file.path] = forcedAgent
            }
            let defaultSessionID = confirmedSessionID(for: file, agent: agent)
                ?? sessionID(for: file.url, agent: agent)
            if confirmedSessionIDsByPath[file.path] != nil,
               let quotaUpdate = CodexDesktopSessionParser.quotaUpdate(
                from: line.text,
                defaultSessionID: defaultSessionID,
                defaultAgent: agent,
                forkedFromSessionID: forkParentsByPath[file.path],
                tokenObservationCursor: CodexTokenObservationCursor(
                    sourceID: Self.normalizedPath(file.path),
                    sourceGeneration: file.generation,
                    sourceStatFingerprint: file.statFingerprint,
                    sourceChangeTimeNanoseconds: file.changeTimeNanoseconds,
                    endOffset: line.endOffset,
                    lineFingerprint: CodexTokenObservationCursor.fingerprint(for: line.bytes)
                )
            ) {
                result.quotaUpdates.append(quotaUpdate)
            }
            guard let activity = CodexDesktopSessionParser.activity(
                from: line.text,
                defaultSessionID: defaultSessionID,
                defaultAgent: agent
            ) else {
                continue
            }
            activities.append(activity)
        }

        result.activities = activities
        return result
    }

    private func readNewLines(from file: SessionFile, now: Date) -> [DecodedLine] {
        let previousCursor = cursorsByPath[file.path]
        var previousOffset: UInt64?
        if let previousCursor, previousCursor.generation == file.generation {
            let metadataChanged = previousCursor.statFingerprint != file.statFingerprint
                || previousCursor.changeTimeNanoseconds != file.changeTimeNanoseconds
            if !metadataChanged,
               file.size == previousCursor.offset,
               file.contentAnchor == previousCursor.contentAnchor {
                return []
            }
            if file.size < previousCursor.offset
                || (metadataChanged && file.size <= previousCursor.offset) {
                // A changed snapshot that did not grow cannot be an append. Reset
                // even when the sampled first/last 4 KiB are unchanged: a large
                // file may have been rewritten only in its middle.
                clearPathState(file.path, includingCursor: true)
                previousOffset = nil
            } else {
                guard let currentAnchor = stableContentAnchor(
                    for: file,
                    throughOffset: previousCursor.offset
                ) else { return [] }
                if currentAnchor != previousCursor.contentAnchor {
                    // dev/inode values can be reused immediately, and metadata
                    // timestamps can collide. Verify bytes already committed by
                    // the cursor before treating the current file as an append.
                    clearPathState(file.path, includingCursor: true)
                    previousOffset = nil
                } else {
                    previousOffset = previousCursor.offset
                }
                // A growing file whose committed bytes still match is a normal
                // append. Keep its confirmed identity so we do not reread the
                // metadata prefix on every token event.
            }
        } else {
            previousOffset = nil
            if previousCursor != nil {
                // A rollout can be atomically replaced at the same path. Path-only
                // state belongs to the old inode and must not affect the new file.
                clearPathState(file.path, includingCursor: true)
            }
        }
        confirmSessionMetadataIfNeeded(for: file)
        let startOffset: UInt64
        let shouldDropLeadingPartialLine: Bool

        if let previousOffset {
            guard file.size > previousOffset else { return [] }
            startOffset = previousOffset
            shouldDropLeadingPartialLine = false
        } else {
            guard now.timeIntervalSince(file.activityAt) <= initialLookbackSeconds else {
                cursorsByPath[file.path] = FileCursor(
                    generation: file.generation,
                    statFingerprint: file.statFingerprint,
                    changeTimeNanoseconds: file.changeTimeNanoseconds,
                    offset: file.size,
                    contentAnchor: file.contentAnchor
                )
                return []
            }
            startOffset = file.size > maxInitialTailBytes ? file.size - maxInitialTailBytes : 0
            shouldDropLeadingPartialLine = startOffset > 0
        }

        guard let read = readData(from: file, offset: startOffset) else { return [] }
        guard !read.data.isEmpty else { return [] }

        let result = completeDecodedLines(
            in: read.data,
            startOffset: startOffset,
            shouldDropLeadingPartialLine: shouldDropLeadingPartialLine
        )
        guard let cursorAnchor = stableContentAnchor(
            for: file,
            throughOffset: result.nextOffset
        ) else { return [] }
        cursorsByPath[file.path] = FileCursor(
            generation: file.generation,
            statFingerprint: read.metadata.statFingerprint ?? file.statFingerprint,
            changeTimeNanoseconds: read.metadata.changeTimeNanoseconds
                ?? file.changeTimeNanoseconds,
            offset: result.nextOffset,
            contentAnchor: cursorAnchor
        )
        return result.lines
    }

    private func readInitialTailLines(
        from file: SessionFile
    ) -> (
        lines: [DecodedLine],
        nextOffset: UInt64,
        metadata: CostUsageScanner.CodexFileMetadata,
        contentAnchor: FileContentAnchor
    )? {
        let startOffset = file.size > maxInitialTailBytes ? file.size - maxInitialTailBytes : 0
        let shouldDropLeadingPartialLine = startOffset > 0

        guard let read = readData(from: file, offset: startOffset) else { return nil }
        guard !read.data.isEmpty else {
            guard let anchor = stableContentAnchor(for: file, throughOffset: startOffset)
            else { return nil }
            return ([], startOffset, read.metadata, anchor)
        }

        let decoded = completeDecodedLines(
            in: read.data,
            startOffset: startOffset,
            shouldDropLeadingPartialLine: shouldDropLeadingPartialLine
        )
        guard let anchor = stableContentAnchor(for: file, throughOffset: decoded.nextOffset)
        else { return nil }
        return (decoded.lines, decoded.nextOffset, read.metadata, anchor)
    }

    private func clearPathState(_ path: String, includingCursor: Bool) {
        if includingCursor {
            cursorsByPath.removeValue(forKey: path)
        }
        agentsByPath.removeValue(forKey: path)
        forkParentsByPath.removeValue(forKey: path)
        confirmedSessionIDsByPath.removeValue(forKey: path)
    }

    private func completeDecodedLines(
        in data: Data,
        startOffset: UInt64,
        shouldDropLeadingPartialLine: Bool
    ) -> (lines: [DecodedLine], nextOffset: UInt64) {
        var result = completeLineData(in: data, startOffset: startOffset)
        if shouldDropLeadingPartialLine, !result.lines.isEmpty {
            result.lines.removeFirst()
        }

        return (result.lines.compactMap { line in
            guard let text = String(data: line.bytes, encoding: .utf8) else { return nil }
            return DecodedLine(text: text, bytes: line.bytes, endOffset: line.endOffset)
        }, result.nextOffset)
    }

    private func completeLineData(
        in data: Data,
        startOffset: UInt64
    ) -> (lines: [(bytes: Data, endOffset: UInt64)], nextOffset: UInt64) {
        var lines: [(bytes: Data, endOffset: UInt64)] = []
        var lineStart = data.startIndex
        var nextOffset = startOffset

        while lineStart < data.endIndex,
              let newline = data[lineStart...].firstIndex(of: 0x0A) {
            let afterNewline = data.index(after: newline)
            let completedByteCount = data.distance(from: data.startIndex, to: afterNewline)
            if lineStart < newline {
                lines.append((
                    bytes: Data(data[lineStart..<newline]),
                    endOffset: startOffset + UInt64(completedByteCount - 1)
                ))
            }
            nextOffset = startOffset + UInt64(completedByteCount)
            lineStart = afterNewline
        }

        return (lines, nextOffset)
    }

    private func stableContentAnchor(
        for file: SessionFile,
        throughOffset: UInt64
    ) -> FileContentAnchor? {
        guard throughOffset <= file.size else { return nil }
        beforeFileReadHook?(file.url)
        guard let handle = try? FileHandle(forReadingFrom: file.url) else { return nil }
        defer { try? handle.close() }

        do {
            let descriptorBefore = CostUsageScanner.codexFileMetadata(
                fileDescriptor: handle.fileDescriptor,
                path: file.path
            )
            let pathBefore = CostUsageScanner.codexFileMetadata(fileURL: file.url)
            guard metadata(descriptorBefore, matches: file),
                  CostUsageScanner.codexFileMetadataIsSameSnapshot(pathBefore, descriptorBefore),
                  let fullAnchorBefore = try contentAnchor(
                      from: handle,
                      throughOffset: file.size
                  ),
                  fullAnchorBefore == file.contentAnchor,
                  let requestedAnchor = try contentAnchor(
                      from: handle,
                      throughOffset: throughOffset
                  )
            else { return nil }

            let descriptorAfter = CostUsageScanner.codexFileMetadata(
                fileDescriptor: handle.fileDescriptor,
                path: file.path
            )
            let pathAfter = CostUsageScanner.codexFileMetadata(fileURL: file.url)
            guard CostUsageScanner.codexFileMetadataIsSameSnapshot(
                descriptorAfter,
                descriptorBefore
            ),
            CostUsageScanner.codexFileMetadataIsSameSnapshot(pathAfter, descriptorBefore),
            let fullAnchorAfter = try contentAnchor(from: handle, throughOffset: file.size),
            fullAnchorAfter == fullAnchorBefore
            else { return nil }
            return requestedAnchor
        } catch {
            return nil
        }
    }

    private func readData(
        from file: SessionFile,
        offset: UInt64,
        maxBytes: Int? = nil
    ) -> FileReadResult? {
        beforeFileReadHook?(file.url)
        guard let handle = try? FileHandle(forReadingFrom: file.url) else { return nil }
        defer {
            try? handle.close()
        }

        do {
            let descriptorBefore = CostUsageScanner.codexFileMetadata(
                fileDescriptor: handle.fileDescriptor,
                path: file.path
            )
            let pathBefore = CostUsageScanner.codexFileMetadata(fileURL: file.url)
            guard metadata(descriptorBefore, matches: file),
                  CostUsageScanner.codexFileMetadataIsSameSnapshot(pathBefore, descriptorBefore),
                  let fullAnchorBefore = try contentAnchor(
                      from: handle,
                      throughOffset: file.size
                  ),
                  fullAnchorBefore == file.contentAnchor
            else { return nil }

            try handle.seek(toOffset: offset)
            let data: Data
            if let maxBytes {
                data = try handle.read(upToCount: maxBytes) ?? Data()
            } else {
                data = try handle.readToEnd() ?? Data()
            }

            let descriptorAfter = CostUsageScanner.codexFileMetadata(
                fileDescriptor: handle.fileDescriptor,
                path: file.path
            )
            let pathAfter = CostUsageScanner.codexFileMetadata(fileURL: file.url)
            guard CostUsageScanner.codexFileMetadataIsSameSnapshot(
                descriptorAfter,
                descriptorBefore
            ),
            CostUsageScanner.codexFileMetadataIsSameSnapshot(pathAfter, descriptorBefore),
            let fullAnchorAfter = try contentAnchor(from: handle, throughOffset: file.size),
            fullAnchorAfter == fullAnchorBefore
            else { return nil }
            return FileReadResult(data: data, metadata: descriptorBefore)
        } catch {
            return nil
        }
    }

    private func metadata(
        _ metadata: CostUsageScanner.CodexFileMetadata,
        matches file: SessionFile
    ) -> Bool {
        metadata.fileId == file.generation
            && metadata.statFingerprint == file.statFingerprint
            && metadata.changeTimeNanoseconds == file.changeTimeNanoseconds
            && metadata.size >= 0
            && UInt64(metadata.size) == file.size
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

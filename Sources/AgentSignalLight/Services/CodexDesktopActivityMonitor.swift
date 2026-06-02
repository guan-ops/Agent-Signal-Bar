import AgentSignalLightCore
import Foundation

final class CodexDesktopActivityMonitor: @unchecked Sendable {
    private struct SessionFile {
        let url: URL
        let path: String
        let modifiedAt: Date
        let size: UInt64
    }

    private let sessionsRootURL: URL
    private let fileManager: FileManager
    private let recentFileLimit: Int
    private let initialLookbackSeconds: TimeInterval
    private let completedLookbackSeconds: TimeInterval
    private let maxInitialTailBytes: UInt64
    private let fullScanInterval: TimeInterval
    private let replaysInitialHistory: Bool
    private let stateLock = NSLock()
    private var offsetsByPath: [String: UInt64] = [:]
    private var cachedRecentFiles: [SessionFile] = []
    private var lastFullScanAt: Date?
    private var hasPrimedExistingFiles = false

    init(
        sessionsRootURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true),
        fileManager: FileManager = .default,
        recentFileLimit: Int = 8,
        initialLookbackSeconds: TimeInterval = 30 * 60,
        completedLookbackSeconds: TimeInterval = 15,
        maxInitialTailBytes: UInt64 = 512 * 1024,
        fullScanInterval: TimeInterval = 1.5,
        replaysInitialHistory: Bool = false
    ) {
        self.sessionsRootURL = sessionsRootURL
        self.fileManager = fileManager
        self.recentFileLimit = recentFileLimit
        self.initialLookbackSeconds = initialLookbackSeconds
        self.completedLookbackSeconds = completedLookbackSeconds
        self.maxInitialTailBytes = maxInitialTailBytes
        self.fullScanInterval = fullScanInterval
        self.replaysInitialHistory = replaysInitialHistory
    }

    func reset() {
        stateLock.lock()
        defer { stateLock.unlock() }
        offsetsByPath.removeAll()
        cachedRecentFiles.removeAll()
        lastFullScanAt = nil
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
            let defaultSessionID = sessionID(for: file.url)
            let lines = readNewLines(from: file, now: now)
            for line in lines {
                guard let activity = CodexDesktopSessionParser.activity(
                    from: line,
                    defaultSessionID: defaultSessionID
                ), shouldAccept(activity, now: now)
                else {
                    continue
                }
                activities.append(activity)
            }
        }

        return sortedActivities(activities)
    }

    private func recentSessionFiles(now: Date) -> [SessionFile] {
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
        guard let enumerator = fileManager.enumerator(
            at: sessionsRootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [SessionFile] = []
        for case let url as URL in enumerator {
            guard url.lastPathComponent.hasPrefix("rollout-"),
                  url.pathExtension == "jsonl",
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

            files.append(
                SessionFile(
                    url: url,
                    path: url.path,
                    modifiedAt: modifiedAt,
                    size: UInt64(size)
                )
            )
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
            size: size.uint64Value
        )
    }

    private func primeExistingFiles(
        _ files: [SessionFile],
        returningActivities: Bool
    ) -> [CodexDesktopActivity] {
        var activities: [CodexDesktopActivity] = []

        for file in files {
            let defaultSessionID = sessionID(for: file.url)
            let initialTail = readInitialTailLines(from: file)
            offsetsByPath[file.path] = initialTail.nextOffset
            guard returningActivities else { continue }

            for line in initialTail.lines {
                guard let activity = CodexDesktopSessionParser.activity(
                    from: line,
                    defaultSessionID: defaultSessionID
                ) else {
                    continue
                }
                activities.append(activity)
            }
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
        sortedActivities(activities.filter { shouldAccept($0, now: now) })
    }

    private func sortedActivities(_ activities: [CodexDesktopActivity]) -> [CodexDesktopActivity] {
        activities.sorted { lhs, rhs in
            (lhs.timestamp ?? .distantPast) < (rhs.timestamp ?? .distantPast)
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

    private func sessionID(for url: URL) -> String {
        let basename = url.deletingPathExtension().lastPathComponent
        let parts = basename.split(separator: "-")
        guard parts.count >= 5 else { return "codex-desktop" }

        let candidate = parts.suffix(5).joined(separator: "-")
        if candidate.count == 36 {
            return "codex-desktop:\(candidate)"
        }
        return "codex-desktop"
    }
}

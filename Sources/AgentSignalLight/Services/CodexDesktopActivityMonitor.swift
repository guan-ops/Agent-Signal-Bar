import AgentSignalLightCore
import Foundation

final class CodexDesktopActivityMonitor {
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
        fullScanInterval: TimeInterval = 6,
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
        offsetsByPath.removeAll()
        cachedRecentFiles.removeAll()
        lastFullScanAt = nil
        hasPrimedExistingFiles = false
    }

    func poll(now: Date = Date()) -> CodexDesktopActivity? {
        let files = recentSessionFiles(now: now)
        if shouldPrimeExistingFiles {
            for file in files {
                offsetsByPath[file.path] = file.size
            }
            hasPrimedExistingFiles = true
            return nil
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

        return activities.max { lhs, rhs in
            (lhs.timestamp ?? .distantPast) < (rhs.timestamp ?? .distantPast)
        }
    }

    private var shouldPrimeExistingFiles: Bool {
        !replaysInitialHistory && !hasPrimedExistingFiles
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
        guard let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey,
            .contentModificationDateKey,
            .fileSizeKey
        ]),
        values.isRegularFile == true,
        let modifiedAt = values.contentModificationDate,
        let size = values.fileSize
        else {
            return nil
        }

        return SessionFile(
            url: url,
            path: url.path,
            modifiedAt: modifiedAt,
            size: UInt64(size)
        )
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
              let text = String(data: data, encoding: .utf8),
              !text.isEmpty
        else {
            return []
        }

        offsetsByPath[file.path] = file.size
        var lines = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)

        if shouldDropLeadingPartialLine && !lines.isEmpty {
            lines.removeFirst()
        }

        return lines
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
        if activity.signal.displayState == .completed {
            return age <= completedLookbackSeconds
        }
        return age <= initialLookbackSeconds
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

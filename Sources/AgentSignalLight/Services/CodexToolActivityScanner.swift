import AgentSignalLightCore
import Foundation

struct CodexToolActivityItem: Identifiable, Equatable, Sendable {
    let name: String
    let count: Int

    var id: String { name }
}

struct CodexToolActivitySummary: Equatable, Sendable {
    static let empty = CodexToolActivitySummary(
        totalCalls: 0,
        todayCalls: 0,
        last30DaysCalls: 0,
        topTools: []
    )

    let totalCalls: Int
    let todayCalls: Int
    let last30DaysCalls: Int
    let topTools: [CodexToolActivityItem]

    var isEmpty: Bool {
        totalCalls <= 0 && topTools.isEmpty
    }

    func addingLiveToolCall(
        name: String,
        timestamp: Date?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> CodexToolActivitySummary {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedName.isEmpty == false else { return self }

        let eventDay = calendar.startOfDay(for: timestamp ?? now)
        let today = calendar.startOfDay(for: now)
        let startDay = calendar.date(byAdding: .day, value: -29, to: today) ?? today

        var nextTopTools = topTools
        if let index = nextTopTools.firstIndex(where: { $0.name == normalizedName }) {
            let current = nextTopTools[index]
            nextTopTools[index] = CodexToolActivityItem(name: current.name, count: current.count + 1)
        } else {
            nextTopTools.append(CodexToolActivityItem(name: normalizedName, count: 1))
        }

        nextTopTools = Array(nextTopTools.sorted { lhs, rhs in
            if lhs.count != rhs.count {
                return lhs.count > rhs.count
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }.prefix(5))

        return CodexToolActivitySummary(
            totalCalls: totalCalls + 1,
            todayCalls: todayCalls + (calendar.isDate(eventDay, inSameDayAs: today) ? 1 : 0),
            last30DaysCalls: last30DaysCalls + ((eventDay >= startDay && eventDay <= today) ? 1 : 0),
            topTools: nextTopTools
        )
    }
}

final class CodexToolActivityScanner: @unchecked Sendable {
    private static let cacheVersion = 1
    private static let toolCallNeedles = [
        #""type":"function_call""#,
        #""type":"custom_tool_call""#
    ]

    private let sessionRootURLs: [URL]
    private let fileManager: FileManager
    private let calendar: Calendar
    private let readChunkBytes: Int
    private let cacheURL: URL?

    init(
        sessionRootURLs: [URL]? = nil,
        fileManager: FileManager = .default,
        calendar: Calendar = .current,
        readChunkBytes: Int = 4 * 1024 * 1024,
        cacheURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.fileManager = fileManager
        self.sessionRootURLs = sessionRootURLs ?? Self.defaultSessionRootURLs(
            fileManager: fileManager,
            environment: environment
        )
        self.calendar = calendar
        self.readChunkBytes = readChunkBytes
        self.cacheURL = cacheURL ?? Self.defaultCacheURL(fileManager: fileManager)
    }

    func cachedSummary(now: Date = Date()) -> CodexToolActivitySummary? {
        guard let cache = loadCompatibleCache(),
              cache.isComplete,
              cache.files.isEmpty == false
        else {
            return nil
        }

        return summary(from: cache, now: now)
    }

    func scanSummary(now: Date = Date()) -> CodexToolActivitySummary {
        var cache = loadCompatibleCache() ?? CodexToolActivityCache(
            version: Self.cacheVersion,
            calendar: calendar,
            roots: sessionRootURLs
        )
        cache.isComplete = false

        var newFiles: [URL] = []
        var metadataByPath: [String: CodexToolActivityFileMetadata] = [:]
        let urls = sessionFiles(cachedFiles: cache.files)

        for url in urls {
            guard let metadata = fileMetadata(for: url) else {
                cache.files.removeValue(forKey: url.path)
                continue
            }

            let path = url.path
            metadataByPath[path] = metadata
            let cached = cache.files[path]

            if let cached,
               cached.size == metadata.size,
               cached.mtimeUnixMs == metadata.mtimeUnixMs {
                continue
            }

            if let cached,
               let parsedBytes = cached.parsedBytes,
               parsedBytes > 0,
               parsedBytes <= metadata.size {
                let delta = scanToolActivity(in: url, startOffset: parsedBytes)
                cache.files[path] = CodexToolActivityFileCache(
                    size: metadata.size,
                    mtimeUnixMs: metadata.mtimeUnixMs,
                    parsedBytes: delta.parsedBytes,
                    totalCounts: adding(cached.totalCounts, delta.totalCounts),
                    days: adding(cached.days, delta.days)
                )
                continue
            }

            newFiles.append(url)
        }

        if newFiles.isEmpty == false {
            let results = scanToolActivityBatch(in: newFiles)
            for url in newFiles {
                let metadata = metadataByPath[url.path] ?? fileMetadata(for: url)
                let result = results[url.path] ?? CodexToolActivityFileScanResult.empty
                guard let metadata else { continue }

                cache.files[url.path] = CodexToolActivityFileCache(
                    size: metadata.size,
                    mtimeUnixMs: metadata.mtimeUnixMs,
                    parsedBytes: result.parsedBytes > 0 ? result.parsedBytes : metadata.size,
                    totalCounts: result.totalCounts,
                    days: result.days
                )
            }
        }

        cache.isComplete = true
        saveCache(cache)
        return summary(from: cache, now: now)
    }

    private func scanToolActivityBatch(in urls: [URL]) -> [String: CodexToolActivityFileScanResult] {
        guard urls.isEmpty == false else { return [:] }

        var states: [String: CodexToolActivityFileScanState] = [:]
        if let parsedBytesByPath = RipgrepRelevantJSONLLineScanner.scan(
            fileURLs: urls,
            needles: Self.toolCallNeedles,
            onLine: { url, lineData in
                guard let call = toolCall(from: lineData, defaultSessionID: url.lastPathComponent) else {
                    return
                }
                states[url.path, default: CodexToolActivityFileScanState()].add(call, calendar: calendar)
            }
        ) {
            var results: [String: CodexToolActivityFileScanResult] = [:]
            for url in urls {
                let state = states[url.path] ?? CodexToolActivityFileScanState()
                let parsedBytes = parsedBytesByPath[url.path]
                    ?? Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                results[url.path] = CodexToolActivityFileScanResult(
                    parsedBytes: parsedBytes,
                    totalCounts: state.totalCounts,
                    days: state.days
                )
            }
            return results
        }

        return Dictionary(
            uniqueKeysWithValues: urls.map { url in
                (url.path, scanToolActivity(in: url, startOffset: 0))
            }
        )
    }

    private func scanToolActivity(
        in url: URL,
        startOffset: Int64
    ) -> CodexToolActivityFileScanResult {
        var state = CodexToolActivityFileScanState()
        let parsedBytes = try? RelevantJSONLLineScanner.scan(
            fileURL: url,
            offset: max(0, startOffset),
            chunkBytes: readChunkBytes,
            maximumLineBytes: 256 * 1024,
            needles: Self.toolCallNeedles.map { Data($0.utf8) }
        ) { lineData in
            guard let call = toolCall(from: lineData, defaultSessionID: url.lastPathComponent) else {
                return
            }
            state.add(call, calendar: calendar)
        }

        return CodexToolActivityFileScanResult(
            parsedBytes: parsedBytes ?? max(0, startOffset),
            totalCounts: state.totalCounts,
            days: state.days
        )
    }

    private func toolCall(
        from lineData: Data,
        defaultSessionID: String
    ) -> CodexToolActivityCall? {
        guard let line = String(data: lineData, encoding: .utf8),
              let activity = CodexDesktopSessionParser.activity(
                from: line,
                defaultSessionID: defaultSessionID
              ),
              activity.event.hasPrefix("DesktopToolCall:")
        else {
            return nil
        }

        let name = String(activity.event.dropFirst("DesktopToolCall:".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.isEmpty == false else { return nil }

        return CodexToolActivityCall(
            name: name,
            timestamp: activity.timestamp
        )
    }

    private func sessionFiles(cachedFiles: [String: CodexToolActivityFileCache]) -> [URL] {
        var urls: [(url: URL, modifiedAt: Date)] = []
        var seenPaths = Set<String>()

        for rootURL in sessionRootURLs {
            guard let enumerator = fileManager.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [
                    .isRegularFileKey,
                    .contentModificationDateKey
                ],
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
                        .contentModificationDateKey
                      ]),
                      values.isRegularFile == true,
                      let modifiedAt = values.contentModificationDate
                else {
                    continue
                }

                seenPaths.insert(url.path)
                urls.append((url, modifiedAt))
            }
        }

        for path in cachedFiles.keys where !seenPaths.contains(path) && fileManager.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path)
            guard let metadata = fileMetadata(for: url) else { continue }
            seenPaths.insert(path)
            urls.append((url, metadata.modifiedAt))
        }

        return urls
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .map(\.url)
    }

    private static func defaultSessionRootURLs(
        fileManager: FileManager,
        environment: [String: String]
    ) -> [URL] {
        let home = fileManager.homeDirectoryForCurrentUser
        if let codexHome = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !codexHome.isEmpty {
            let root = URL(fileURLWithPath: (codexHome as NSString).expandingTildeInPath, isDirectory: true)
            return [
                root.appendingPathComponent("sessions", isDirectory: true),
                root.appendingPathComponent("archived_sessions", isDirectory: true)
            ]
        }

        var roots: [URL] = [
            home.appendingPathComponent(".codex/sessions", isDirectory: true),
            home.appendingPathComponent(".codex/archived_sessions", isDirectory: true)
        ]

        let xcodeSessions = home.appendingPathComponent(
            "Library/Developer/Xcode/CodingAssistant/codex/sessions",
            isDirectory: true
        )
        var isXcodeDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: xcodeSessions.path, isDirectory: &isXcodeDirectory),
           isXcodeDirectory.boolValue {
            roots.append(xcodeSessions)
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
                roots.append(sessionsRoot)
            }
        }

        return roots
    }

    private static func defaultCacheURL(fileManager: FileManager) -> URL? {
        fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("AgentSignalLight", isDirectory: true)
            .appendingPathComponent("codex-tool-activity-v\(cacheVersion).json", isDirectory: false)
    }

    private func loadCompatibleCache() -> CodexToolActivityCache? {
        guard let cacheURL,
              let data = try? Data(contentsOf: cacheURL),
              let cache = try? JSONDecoder().decode(CodexToolActivityCache.self, from: data),
              cache.isCompatible(
                version: Self.cacheVersion,
                calendar: calendar,
                roots: sessionRootURLs
              )
        else {
            return nil
        }

        return cache
    }

    private func saveCache(_ cache: CodexToolActivityCache) {
        guard let cacheURL,
              let data = try? JSONEncoder().encode(cache)
        else {
            return
        }

        let directory = cacheURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let temporaryURL = directory.appendingPathComponent(".tmp-\(UUID().uuidString).json")
            try data.write(to: temporaryURL, options: [.atomic])
            if fileManager.fileExists(atPath: cacheURL.path) {
                _ = try fileManager.replaceItemAt(cacheURL, withItemAt: temporaryURL)
            } else {
                try fileManager.moveItem(at: temporaryURL, to: cacheURL)
            }
        } catch {
            return
        }
    }

    private func summary(
        from cache: CodexToolActivityCache,
        now: Date
    ) -> CodexToolActivitySummary {
        let today = calendar.startOfDay(for: now)
        let startDay = calendar.date(byAdding: .day, value: -29, to: today) ?? today
        let todayKey = dayKey(for: today)
        let startKey = dayKey(for: startDay)

        var totalCounts: [String: Int] = [:]
        var todayCalls = 0
        var last30DaysCalls = 0

        for file in cache.files.values {
            for (name, count) in file.totalCounts where count > 0 {
                totalCounts[name, default: 0] += count
            }

            for (day, dayCounts) in file.days where day >= startKey && day <= todayKey {
                let dayTotal = dayCounts.values.reduce(0, +)
                last30DaysCalls += dayTotal
                if day == todayKey {
                    todayCalls += dayTotal
                }
            }
        }

        let topTools = totalCounts
            .map { CodexToolActivityItem(name: $0.key, count: $0.value) }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count {
                    return lhs.count > rhs.count
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            .prefix(5)

        return CodexToolActivitySummary(
            totalCalls: totalCounts.values.reduce(0, +),
            todayCalls: todayCalls,
            last30DaysCalls: last30DaysCalls,
            topTools: Array(topTools)
        )
    }

    private func adding(
        _ lhs: [String: Int],
        _ rhs: [String: Int]
    ) -> [String: Int] {
        var result = lhs
        for (name, count) in rhs where count > 0 {
            result[name, default: 0] += count
        }
        return result
    }

    private func adding(
        _ lhs: [String: [String: Int]],
        _ rhs: [String: [String: Int]]
    ) -> [String: [String: Int]] {
        var result = lhs
        for (day, counts) in rhs {
            for (name, count) in counts where count > 0 {
                result[day, default: [:]][name, default: 0] += count
            }
        }
        return result
    }

    private func dayKey(for date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    private func fileMetadata(for url: URL) -> CodexToolActivityFileMetadata? {
        guard let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey
        ]),
            values.isRegularFile == true,
            let fileSize = values.fileSize,
            let modifiedAt = values.contentModificationDate
        else {
            return nil
        }

        return CodexToolActivityFileMetadata(
            size: Int64(fileSize),
            mtimeUnixMs: Int64(modifiedAt.timeIntervalSince1970 * 1_000),
            modifiedAt: modifiedAt
        )
    }
}

private struct CodexToolActivityCall {
    let name: String
    let timestamp: Date?
}

private struct CodexToolActivityFileScanState {
    var totalCounts: [String: Int] = [:]
    var days: [String: [String: Int]] = [:]

    mutating func add(_ call: CodexToolActivityCall, calendar: Calendar) {
        totalCounts[call.name, default: 0] += 1

        guard let timestamp = call.timestamp else {
            return
        }

        let components = calendar.dateComponents([.year, .month, .day], from: timestamp)
        let dayKey = String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
        days[dayKey, default: [:]][call.name, default: 0] += 1
    }
}

private struct CodexToolActivityFileMetadata {
    let size: Int64
    let mtimeUnixMs: Int64
    let modifiedAt: Date
}

private struct CodexToolActivityFileScanResult {
    static let empty = CodexToolActivityFileScanResult(
        parsedBytes: 0,
        totalCounts: [:],
        days: [:]
    )

    let parsedBytes: Int64
    let totalCounts: [String: Int]
    let days: [String: [String: Int]]
}

private struct CodexToolActivityCache: Codable {
    var version: Int
    var calendarIdentifier: String
    var timeZoneIdentifier: String
    var roots: [String]
    var isComplete: Bool
    var files: [String: CodexToolActivityFileCache]

    init(version: Int, calendar: Calendar, roots: [URL]) {
        self.version = version
        calendarIdentifier = String(describing: calendar.identifier)
        timeZoneIdentifier = calendar.timeZone.identifier
        self.roots = roots.map(\.path).sorted()
        isComplete = false
        files = [:]
    }

    func isCompatible(version: Int, calendar: Calendar, roots: [URL]) -> Bool {
        self.version == version
            && calendarIdentifier == String(describing: calendar.identifier)
            && timeZoneIdentifier == calendar.timeZone.identifier
            && self.roots == roots.map(\.path).sorted()
    }
}

private struct CodexToolActivityFileCache: Codable {
    let size: Int64
    let mtimeUnixMs: Int64
    let parsedBytes: Int64?
    let totalCounts: [String: Int]
    let days: [String: [String: Int]]
}

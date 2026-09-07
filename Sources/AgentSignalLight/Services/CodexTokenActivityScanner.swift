import AgentSignalLightCore
import Foundation
import OSLog
#if canImport(SQLite3)
import SQLite3
#endif

struct CodexTokenActivityDay: Codable, Identifiable, Equatable, Sendable {
    let day: Date
    let totalTokens: Int
    let estimatedCostUSD: Double?
    let modelTokenTotals: [String: Int]
    let modelEstimatedCostTotals: [String: Double]
    let modelStandardTokenTotals: [String: Int]
    let modelPriorityTokenTotals: [String: Int]
    let modelStandardEstimatedCostTotals: [String: Double]
    let modelPriorityEstimatedCostTotals: [String: Double]

    init(
        day: Date,
        totalTokens: Int,
        estimatedCostUSD: Double? = nil,
        modelTokenTotals: [String: Int] = [:],
        modelEstimatedCostTotals: [String: Double] = [:],
        modelStandardTokenTotals: [String: Int] = [:],
        modelPriorityTokenTotals: [String: Int] = [:],
        modelStandardEstimatedCostTotals: [String: Double] = [:],
        modelPriorityEstimatedCostTotals: [String: Double] = [:]
    ) {
        self.day = day
        self.totalTokens = totalTokens
        self.estimatedCostUSD = estimatedCostUSD
        self.modelTokenTotals = modelTokenTotals
        self.modelEstimatedCostTotals = modelEstimatedCostTotals
        self.modelStandardTokenTotals = modelStandardTokenTotals
        self.modelPriorityTokenTotals = modelPriorityTokenTotals
        self.modelStandardEstimatedCostTotals = modelStandardEstimatedCostTotals
        self.modelPriorityEstimatedCostTotals = modelPriorityEstimatedCostTotals
    }

    var id: TimeInterval {
        day.timeIntervalSince1970
    }
}

struct CodexTokenActivityScanWatermark: Equatable, Sendable {
    let sessionID: String?
    let sourceID: String
    let sourceGeneration: String
    let sourceStatFingerprint: Int64?
    let sourceChangeTimeNanoseconds: Int64?
    let endOffset: UInt64
    let lineFingerprint: String
    let eventTimestamp: Date?
    let totalTokens: Int?

    init(
        sessionID: String?,
        sourceID: String,
        sourceGeneration: String,
        endOffset: UInt64,
        lineFingerprint: String,
        eventTimestamp: Date?,
        totalTokens: Int?,
        sourceStatFingerprint: Int64? = nil,
        sourceChangeTimeNanoseconds: Int64? = nil
    ) {
        self.sessionID = sessionID
        self.sourceID = sourceID
        self.sourceGeneration = sourceGeneration
        self.sourceStatFingerprint = sourceStatFingerprint
        self.sourceChangeTimeNanoseconds = sourceChangeTimeNanoseconds
        self.endOffset = endOffset
        self.lineFingerprint = lineFingerprint
        self.eventTimestamp = eventTimestamp
        self.totalTokens = totalTokens
    }
}

struct CodexTokenActivityScanResult: Equatable, Sendable {
    let days: [CodexTokenActivityDay]
    let details: CodexUsageDetails?
    let watermarks: [CodexTokenActivityScanWatermark]
    /// A complete transaction can still exclude explicitly ambiguous sources.
    /// Those sources never contribute days or absorbing watermarks.
    let isComplete: Bool
    let failureDescription: String?
    let isSourceChanging: Bool
    let warningDescription: String?
    let excludedSourceIDs: Set<String>
    let excludedSessionIDs: Set<String>

    init(
        days: [CodexTokenActivityDay],
        watermarks: [CodexTokenActivityScanWatermark],
        isComplete: Bool = true,
        failureDescription: String? = nil,
        isSourceChanging: Bool = false,
        warningDescription: String? = nil,
        excludedSourceIDs: Set<String> = [],
        excludedSessionIDs: Set<String> = [],
        details: CodexUsageDetails? = nil
    ) {
        self.days = days
        self.details = details
        self.watermarks = watermarks
        self.isComplete = isComplete
        self.failureDescription = failureDescription
        self.isSourceChanging = isSourceChanging
        self.warningDescription = warningDescription
        self.excludedSourceIDs = excludedSourceIDs
        self.excludedSessionIDs = excludedSessionIDs
    }

    static func failure(days: [CodexTokenActivityDay], error: Error) -> Self {
        let nsError = error as NSError
        Logger(subsystem: "com.agentsignallight.AgentSignalLight", category: "TokenScan")
            .error("History scan failed: domain=\(nsError.domain, privacy: .public) code=\(nsError.code)")
        let changing = (nsError.domain == "AgentSignalCostUsage.CodexConsistency" && nsError.code == 3)
            || (error as? CostUsageScanner.CodexInventoryError).map {
                if case .changedDuringEnumeration = $0 { return true }
                return false
            } == true
            || nsError.domain == "AgentSignalCostUsage.CodexCheckpoint"
        return Self(
            days: days, watermarks: [], isComplete: false,
            failureDescription: changing ? nil : "Local session history could not be read.",
            isSourceChanging: changing)
    }
}

protocol CodexTokenActivityScanning: Sendable {
    func scanDailyActivityResult(now: Date, days: Int,
        scanProgress: @escaping @Sendable (TokenScanProgress) -> Void) -> CodexTokenActivityScanResult

    func cachedDailyActivity(now: Date, days: Int) -> [CodexTokenActivityDay]?

    func clearCache()

    /// Returns activity through `now`; events timestamped after that cutoff must
    /// remain available to a later incremental scan.
    func scanDailyActivity(
        now: Date,
        days: Int,
        progress: (([CodexTokenActivityDay]) -> Void)?
    ) -> [CodexTokenActivityDay]

    func scanDailyActivityResult(
        now: Date,
        days: Int,
        progress: (([CodexTokenActivityDay]) -> Void)?
    ) -> CodexTokenActivityScanResult
}

extension CodexTokenActivityScanning {
    func scanDailyActivityResult(now: Date, days: Int,
        scanProgress: @escaping @Sendable (TokenScanProgress) -> Void) -> CodexTokenActivityScanResult {
        scanProgress(.init(phase: .discovering))
        let result = scanDailyActivityResult(now: now, days: days, progress: nil)
        scanProgress(.init(phase: .validating))
        return result
    }

    func clearCache() {}

    func scanDailyActivityResult(
        now: Date,
        days: Int,
        progress: (([CodexTokenActivityDay]) -> Void)?
    ) -> CodexTokenActivityScanResult {
        CodexTokenActivityScanResult(
            days: scanDailyActivity(now: now, days: days, progress: progress),
            watermarks: []
        )
    }
}

final class CodexTokenActivityScanner: CodexTokenActivityScanning, @unchecked Sendable {
    private typealias ModelContext = (lineNumber: Int, model: String, turnID: String?)

    static let currentCacheVersion = 25

    private static let newlineNeedle = Data([0x0A])
    private static let tokenCountNeedle = Data("token_count".utf8)
    private static let tokenUsageNeedle = Data("token_usage".utf8)
    private static let sessionMetaNeedle = Data("session_meta".utf8)
    private static let turnContextNeedle = Data("turn_context".utf8)
    private static let cacheVersion = currentCacheVersion
    private static let ripgrepContextFastPathMinimumBytes: Int64 = 1_000_000
    private static let legacyImportedCostUsageCacheRootName = ["codex", "bar-cost-usage"].joined()

    private let sessionRootURLs: [URL]
    private let fileManager: FileManager
    private let calendar: Calendar
    private let readChunkBytes: Int
    private let cacheURL: URL?
    private let costUsageCacheRoot: URL?
    private let usesAgentSignalCostUsageScanner: Bool
    private let priorityDatabaseURL: URL?
    private let costUsageScanCheckpoint = CostUsageScanner.CodexScanCheckpoint()

    init(
        sessionRootURLs: [URL]? = nil,
        fileManager: FileManager = .default,
        calendar: Calendar = .autoupdatingCurrent,
        readChunkBytes: Int = 4 * 1024 * 1024,
        cacheURL: URL? = nil,
        costUsageCacheRootURL: URL? = nil,
        usesAgentSignalCostUsageScanner: Bool? = nil,
        priorityDatabaseURL: URL? = nil,
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
        self.usesAgentSignalCostUsageScanner = usesAgentSignalCostUsageScanner ?? (cacheURL == nil)
        self.costUsageCacheRoot = costUsageCacheRootURL ?? Self.defaultCostUsageCacheRoot(
            fileManager: fileManager,
            cacheURL: cacheURL
        )
        self.priorityDatabaseURL = priorityDatabaseURL ?? Self.defaultPriorityDatabaseURL(
            fileManager: fileManager,
            environment: environment
        )
    }

    func scanDailyActivity(
        now: Date = Date(),
        days: Int = 365,
        progress: (([CodexTokenActivityDay]) -> Void)? = nil
    ) -> [CodexTokenActivityDay] {
        guard usesAgentSignalCostUsageScanner else {
            return legacyScanDailyActivity(now: now, days: days, progress: progress)
        }
        let costUsageDays = agentSignalCostUsageDailyActivity(now: now, days: days, forceRefresh: true)
        progress?(costUsageDays)
        return costUsageDays
    }

    func scanDailyActivityResult(
        now: Date,
        days: Int,
        progress: (([CodexTokenActivityDay]) -> Void)? = nil
    ) -> CodexTokenActivityScanResult {
        performDailyActivityScan(now: now, days: days, progress: progress, scanProgress: nil)
    }

    func scanDailyActivityResult(now: Date, days: Int,
        scanProgress: @escaping @Sendable (TokenScanProgress) -> Void) -> CodexTokenActivityScanResult {
        performDailyActivityScan(now: now, days: days, progress: nil, scanProgress: scanProgress)
    }

    private func performDailyActivityScan(now: Date, days: Int,
        progress: (([CodexTokenActivityDay]) -> Void)?,
        scanProgress: (@Sendable (TokenScanProgress) -> Void)?) -> CodexTokenActivityScanResult {
        guard usesAgentSignalCostUsageScanner else {
            let activity = scanDailyActivity(now: now, days: days, progress: progress)
            return CodexTokenActivityScanResult(days: activity, watermarks: [])
        }
        do {
            let report = try agentSignalCostUsageDailyActivityResult(now: now, days: days, scanProgress: scanProgress)
            let activity = codexTokenActivityDays(from: report)
            let cache = try CostUsageCacheIO.loadRequired(provider: .codex, cacheRoot: costUsageCacheRoot)
            let watermarks = try agentSignalCostUsageScanWatermarks(through: now, committedCache: cache)
            let details = CodexUsageDetails.build(cache: cache, now: now,
                modelsDevCatalog: CostUsagePricing.modelsDevCatalog(cacheRoot: costUsageCacheRoot)
                    ?? ModelsDevCatalog(providers: [:]))
            progress?(activity)
            return CodexTokenActivityScanResult(
                days: activity,
                watermarks: watermarks,
                warningDescription: report.warnings.isEmpty ? nil
                    : "Excluded \(report.warnings.count) ambiguous session group(s).",
                excludedSourceIDs: Set(report.warnings.flatMap(\.sourcePaths).map(Self.canonicalTokenSourceID)),
                excludedSessionIDs: Set(report.warnings.map(\.sessionID)),
                details: details
            )
        } catch {
            // Preserve the last known-good aggregate. The model will retry with
            // backoff, but an I/O/enumeration failure cannot flash usage to zero.
            return .failure(days: cachedDailyActivity(now: now, days: days) ?? [], error: error)
        }
    }

    func clearCache() {
        costUsageScanCheckpoint.clear()
        if let cacheURL {
            try? fileManager.removeItem(at: cacheURL)
        }
        guard usesAgentSignalCostUsageScanner else { return }
        let currentCostCacheURL = CostUsageCacheIO.cacheFileURL(
            provider: .codex,
            cacheRoot: costUsageCacheRoot
        )
        let costCacheDirectory = currentCostCacheURL.deletingLastPathComponent()
        if let artifacts = try? fileManager.contentsOfDirectory(
            at: costCacheDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for artifact in artifacts {
                let name = artifact.lastPathComponent
                guard name.hasSuffix(".json"),
                      (name.hasPrefix("codex-v") || name.hasPrefix("pi-sessions-v"))
                else { continue }
                try? fileManager.removeItem(at: artifact)
            }
        } else {
            try? fileManager.removeItem(at: currentCostCacheURL)
            try? fileManager.removeItem(
                at: PiSessionCostCacheIO.cacheFileURL(cacheRoot: costUsageCacheRoot)
            )
        }
    }

    func legacyScanDailyActivity(
        now: Date = Date(),
        days: Int = 365,
        progress: (([CodexTokenActivityDay]) -> Void)? = nil
    ) -> [CodexTokenActivityDay] {
        let today = calendar.startOfDay(for: now)
        let startDay = calendar.date(byAdding: .day, value: -max(days - 1, 0), to: today) ?? today
        let startKey = dayKey(for: startDay)
        let todayKey = dayKey(for: today)
        let priorityTurns = priorityTurnMetadata(startDay: startDay, today: today)
        var cache = loadCache(historyDays: days)
        cache.historyDays = max(cache.historyDays, days)
        cache.isComplete = false
        var totalsByDay: [Date: CodexTokenActivityDayCache] = [:]
        let filesToScan = sessionFiles(
            modifiedSince: startDay,
            cachedFiles: cache.files,
            startKey: startKey,
            todayKey: todayKey
        )
        let forkResolver = CodexForkBaselineResolver(
            sessionIndex: sessionIndex(from: allSessionFiles(cachedFiles: cache.files)),
            scanner: self
        )
        var batchScanURLs: [URL] = []
        var batchMetadataByPath: [String: CodexTokenActivityFileMetadata] = [:]

        for url in filesToScan {
            guard let metadata = fileMetadata(for: url) else {
                continue
            }

            let path = url.path
            let cached = cache.files[path]
            let fileDays: [String: CodexTokenActivityDayCache]

            if let cached,
               cached.size == metadata.size,
               cached.mtimeUnixMs == metadata.mtimeUnixMs {
                fileDays = cached.days
            } else if let cached,
                      let parsedBytes = cached.parsedBytes,
                      parsedBytes > 0,
                      parsedBytes <= metadata.size {
                let result = scanTokenActivity(
                    in: url,
                    startOffset: parsedBytes,
                    initialBaseline: cached.baseline,
                    initialRawTotalsBaseline: cached.rawBaseline,
                    initialHasDivergentTotals: cached.hasDivergentTotals ?? false,
                    initialCurrentModel: cached.currentModel,
                    initialCurrentTurnID: cached.currentTurnID,
                    priorityTurns: priorityTurns,
                    forkResolver: forkResolver,
                    startDay: startDay,
                    today: today
                )
                fileDays = addingDays(cached.days, result.days)
                cache.files[path] = CodexTokenActivityFileCache(
                    size: metadata.size,
                    mtimeUnixMs: metadata.mtimeUnixMs,
                    parsedBytes: result.parsedBytes,
                    baseline: result.baseline,
                    rawBaseline: result.rawBaseline,
                    hasDivergentTotals: result.hasDivergentTotals,
                    sessionID: result.sessionID ?? cached.sessionID,
                    forkedFromID: result.forkedFromID ?? cached.forkedFromID,
                    forkTimestamp: result.forkTimestamp ?? cached.forkTimestamp,
                    currentModel: result.currentModel ?? cached.currentModel,
                    currentTurnID: result.currentTurnID ?? cached.currentTurnID,
                    days: fileDays
                )
            } else if cached == nil,
                      shouldUseRipgrepContextFastPath(metadata: metadata) {
                batchScanURLs.append(url)
                batchMetadataByPath[path] = metadata
                continue
            } else {
                let result = scanTokenActivity(
                    in: url,
                    startOffset: 0,
                    initialBaseline: nil,
                    initialRawTotalsBaseline: nil,
                    initialHasDivergentTotals: false,
                    initialCurrentModel: nil,
                    initialCurrentTurnID: nil,
                    priorityTurns: priorityTurns,
                    forkResolver: forkResolver,
                    startDay: startDay,
                    today: today
                )
                fileDays = result.days
                cache.files[path] = CodexTokenActivityFileCache(
                    size: metadata.size,
                    mtimeUnixMs: metadata.mtimeUnixMs,
                    parsedBytes: result.parsedBytes,
                    baseline: result.baseline,
                    rawBaseline: result.rawBaseline,
                    hasDivergentTotals: result.hasDivergentTotals,
                    sessionID: result.sessionID,
                    forkedFromID: result.forkedFromID,
                    forkTimestamp: result.forkTimestamp,
                    currentModel: result.currentModel,
                    currentTurnID: result.currentTurnID,
                    days: fileDays
                )
            }

            merge(fileDays, into: &totalsByDay, startKey: startKey, todayKey: todayKey)
            saveCache(cache)
            progress?(activityDays(from: totalsByDay))
        }

        if !batchScanURLs.isEmpty,
           let batchResults = scanTokenActivityBatch(
            in: batchScanURLs,
            forkResolver: forkResolver,
            priorityTurns: priorityTurns,
            startDay: startDay,
            today: today
           ) {
            for url in batchScanURLs {
                let path = url.path
                guard let metadata = batchMetadataByPath[path],
                      let result = batchResults[path]
                else {
                    continue
                }

                let fileDays = result.days
                cache.files[path] = CodexTokenActivityFileCache(
                    size: metadata.size,
                    mtimeUnixMs: metadata.mtimeUnixMs,
                    parsedBytes: result.parsedBytes,
                    baseline: result.baseline,
                    rawBaseline: result.rawBaseline,
                    hasDivergentTotals: result.hasDivergentTotals,
                    sessionID: result.sessionID,
                    forkedFromID: result.forkedFromID,
                    forkTimestamp: result.forkTimestamp,
                    currentModel: result.currentModel,
                    currentTurnID: result.currentTurnID,
                    days: fileDays
                )
                merge(fileDays, into: &totalsByDay, startKey: startKey, todayKey: todayKey)
            }
            saveCache(cache)
            progress?(activityDays(from: totalsByDay))
        } else {
            for url in batchScanURLs {
                guard let metadata = batchMetadataByPath[url.path] else {
                    continue
                }

                let result = scanTokenActivity(
                    in: url,
                    startOffset: 0,
                    initialBaseline: nil,
                    initialRawTotalsBaseline: nil,
                    initialHasDivergentTotals: false,
                    initialCurrentModel: nil,
                    initialCurrentTurnID: nil,
                    priorityTurns: priorityTurns,
                    forkResolver: forkResolver,
                    startDay: startDay,
                    today: today
                )
                let fileDays = result.days
                cache.files[url.path] = CodexTokenActivityFileCache(
                    size: metadata.size,
                    mtimeUnixMs: metadata.mtimeUnixMs,
                    parsedBytes: result.parsedBytes,
                    baseline: result.baseline,
                    rawBaseline: result.rawBaseline,
                    hasDivergentTotals: result.hasDivergentTotals,
                    sessionID: result.sessionID,
                    forkedFromID: result.forkedFromID,
                    forkTimestamp: result.forkTimestamp,
                    currentModel: result.currentModel,
                    currentTurnID: result.currentTurnID,
                    days: fileDays
                )
                merge(fileDays, into: &totalsByDay, startKey: startKey, todayKey: todayKey)
                saveCache(cache)
                progress?(activityDays(from: totalsByDay))
            }
        }

        pruneMissingFiles(from: &cache)
        cache.isComplete = true
        saveCache(cache)

        return activityDays(from: totalsByDay)
    }

    func cachedDailyActivity(
        now: Date = Date(),
        days: Int = 365
    ) -> [CodexTokenActivityDay]? {
        guard usesAgentSignalCostUsageScanner else {
            return legacyCachedDailyActivity(now: now, days: days)
        }
        let activity = agentSignalCachedCostUsageDailyActivity(now: now, days: days)
        return activity.isEmpty ? nil : activity
    }

    func legacyCachedDailyActivity(
        now: Date = Date(),
        days: Int = 365
    ) -> [CodexTokenActivityDay]? {
        if let cache = loadCompatibleCache(
            from: cacheURL,
            version: Self.cacheVersion,
            historyDays: days
        ),
           cache.isComplete {
            let activity = dailyActivity(from: cache, now: now, days: days)
            return activity.isEmpty ? nil : activity
        }

        return nil
    }

    private func agentSignalCostUsageDailyActivity(
        now: Date,
        days: Int,
        forceRefresh: Bool
    ) -> [CodexTokenActivityDay] {
        let range = agentSignalCostUsageDateRange(now: now, days: days)
        let options = agentSignalCostUsageOptions(forceRefresh: forceRefresh)
        let codexReport = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: range.since,
            until: range.until,
            now: now,
            options: options
        )

        var piOptions = PiSessionCostScanner.Options(
            cacheRoot: options.cacheRoot,
            refreshMinIntervalSeconds: forceRefresh ? 0 : options.refreshMinIntervalSeconds,
            forceRescan: false
        )
        if forceRefresh {
            piOptions.refreshMinIntervalSeconds = 0
        }
        let piReport = PiSessionCostScanner.loadDailyReport(
            provider: .codex,
            since: range.since,
            until: range.until,
            now: now,
            options: piOptions
        )
        return codexTokenActivityDays(from: CostUsageDailyReport.merged([codexReport, piReport]))
    }

    private func agentSignalCostUsageDailyActivityResult(
        now: Date,
        days: Int,
        scanProgress: (@Sendable (TokenScanProgress) -> Void)? = nil
    ) throws -> CostUsageDailyReport {
        let range = agentSignalCostUsageDateRange(now: now, days: days)
        var options = agentSignalCostUsageOptions(forceRefresh: true)
        options.codexScanProgress = scanProgress
        let codexReport = try CostUsageScanner.loadDailyReportCancellable(
            provider: .codex,
            since: range.since,
            until: range.until,
            now: now,
            options: options,
            checkCancellation: nil
        )
        var piOptions = PiSessionCostScanner.Options(
            cacheRoot: options.cacheRoot,
            refreshMinIntervalSeconds: 0,
            forceRescan: false
        )
        piOptions.refreshMinIntervalSeconds = 0
        let piReport = try PiSessionCostScanner.loadDailyReportCancellable(
            provider: .codex,
            since: range.since,
            until: range.until,
            now: now,
            options: piOptions,
            checkCancellation: nil
        )
        return CostUsageDailyReport.merged([codexReport, piReport])
    }

    private func agentSignalCachedCostUsageDailyActivity(
        now: Date,
        days: Int
    ) -> [CodexTokenActivityDay] {
        let range = agentSignalCostUsageDateRange(now: now, days: days)
        let costRange = CostUsageScanner.CostUsageDayRange(since: range.since, until: range.until)
        let options = agentSignalCostUsageOptions(forceRefresh: false)
        var reports: [CostUsageDailyReport] = []

        let cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: options.cacheRoot)
        let currentRootIdentities = Set(CostUsageScanner.codexRootsFingerprint(options: options).keys)
        if !cache.days.isEmpty,
           cache.roots.map({ Set($0.keys) }) == currentRootIdentities,
           !CostUsageScanner.requestedWindowExpandsCache(range: costRange, cache: cache) {
            let report = CostUsageScanner.buildCodexReportFromCache(
                cache: cache,
                range: costRange,
                modelsDevCacheRoot: options.cacheRoot
            )
            if !report.data.isEmpty {
                reports.append(report)
            }
        }

        if let piReport = PiSessionCostScanner.loadCachedDailyReport(
            provider: .codex,
            since: range.since,
            until: range.until,
            now: now,
            cacheRoot: options.cacheRoot
        ) {
            reports.append(piReport)
        }

        guard !reports.isEmpty else { return [] }
        return codexTokenActivityDays(from: CostUsageDailyReport.merged(reports))
    }

    func agentSignalCostUsageScanWatermarks(
        through: Date,
        committedCache: CostUsageCache? = nil
    ) throws -> [CodexTokenActivityScanWatermark] {
        let options = agentSignalCostUsageOptions(forceRefresh: false)
        // A complete scan promises both an aggregate and the exact frontier
        // that produced it. Treat a failed cache read as an incomplete scan;
        // returning an empty/old frontier here can double-count the next poll.
        let cache = try committedCache ?? CostUsageCacheIO.loadRequired(
            provider: .codex,
            cacheRoot: options.cacheRoot
        )
        let owners = cache.files.compactMap { path, usage -> (String, String, CostUsageFileUsage)? in
            guard usage.codexInventoryOnly != true,
                  usage.codexNoncontributingDuplicate != true,
                  let sessionID = usage.sessionId,
                  !sessionID.isEmpty
            else { return nil }
            return (sessionID, path, usage)
        }
        let ownerGroups = Dictionary(grouping: owners, by: { $0.0 })
        let uniqueOwnerBySessionID = ownerGroups.compactMapValues { entries -> (String, CostUsageFileUsage)? in
            guard entries.count == 1, let entry = entries.first else { return nil }
            return (entry.1, entry.2)
        }

        var watermarks: [CodexTokenActivityScanWatermark] = []
        for (path, usage) in cache.files.sorted(by: { $0.key < $1.key }) {
            guard usage.codexInventoryOnly != true,
                  usage.codexNoncontributingDuplicate != true,
                  let generation = usage.sourceGeneration,
                  let event = Self.costUsageTokenEventFrontier(usage, through: through)
            else { continue }

            // The aggregate and its cursor are only one atomic promise if the
            // committed prefix still belongs to this generation. A stable
            // append is safe: the old prefix remains proven and the exported
            // offset deliberately does not cover the new live bytes.
            let fileURL = URL(fileURLWithPath: path)
            let currentMetadata = CostUsageScanner.codexFileMetadata(fileURL: fileURL)
            if let currentGeneration = currentMetadata.fileId {
                let parsedBytes = usage.parsedBytes ?? usage.size
                guard currentGeneration == generation,
                      event.endOffset <= parsedBytes,
                      try CostUsageScanner.codexFileMatchesCommittedFrontier(
                          fileURL: fileURL,
                          cached: usage,
                          checkCancellation: nil
                      )
                else {
                    throw CostUsageScanner.codexChangedDuringScanError(path: path)
                }
            } else if fileManager.fileExists(atPath: path) {
                throw CostUsageScanner.codexChangedDuringScanError(path: path)
            }

            // Parsing is sequential, so the greatest committed offset proves
            // every earlier line in this file generation. Exporting one exact
            // frontier keeps reconciliation bounded even for long sessions.
            watermarks.append(CodexTokenActivityScanWatermark(
                sessionID: usage.sessionId,
                sourceID: Self.canonicalTokenSourceID(path),
                sourceGeneration: generation,
                endOffset: UInt64(event.endOffset),
                lineFingerprint: event.lineFingerprint,
                eventTimestamp: event.eventTimestamp,
                totalTokens: event.totalTokens,
                sourceStatFingerprint: usage.sourceStatFingerprint,
                sourceChangeTimeNanoseconds: usage.sourceChangeTimeNanoseconds
            ))
        }

        // The live tailer can observe a byte-for-byte rollout copy that the cost
        // cache retains as an inventory-only duplicate. Its inode differs from
        // the aggregate owner's inode, so the owner's watermark alone cannot
        // absorb that exact cursor. Export a generation-specific alias only after
        // re-proving the common prefix against the committed owner frontier.
        for (path, usage) in cache.files
        where usage.codexInventoryOnly == true || usage.codexNoncontributingDuplicate == true {
            if usage.codexNoncontributingDuplicate == true {
                // This source was proven to contain no numeric token event at
                // all. It is not a copy of the owner's token-bearing prefix,
                // so it must never export an alias or absorbing tombstone.
                // Re-prove the entire snapshot: even a stable append could
                // introduce usage that needs a new duplicate reconciliation.
                guard try Self.verifiedNoncontributingDuplicate(
                    path: path,
                    usage: usage
                ) else {
                    throw CostUsageScanner.codexChangedDuringScanError(path: path)
                }
                continue
            }
            // No owner was established for an identity conflict. In particular,
            // do not publish a quarantine tombstone that would discard live
            // usage merely because this group's history could not be counted.
            guard usage.codexIdentityConflict != true else { continue }
            guard let sessionID = usage.sessionId,
                  !sessionID.isEmpty
            else { continue }

            let sentinelURL = URL(fileURLWithPath: path)
            let sentinelMetadata = CostUsageScanner.codexFileMetadata(fileURL: sentinelURL)
            if sentinelMetadata.fileId != nil {
                guard Self.costUsageFileMetadata(sentinelMetadata, matches: usage) else {
                    throw CostUsageScanner.codexChangedDuringScanError(path: path)
                }
            } else if fileManager.fileExists(atPath: path) {
                throw CostUsageScanner.codexChangedDuringScanError(path: path)
            } else {
                continue
            }

            if usage.codexDuplicateQuarantined == true,
               let generation = usage.sourceGeneration,
               Self.costUsageFileMetadata(sentinelMetadata, matches: usage) {
                // Reconciliation has explicitly rejected this unchanged file
                // generation as a divergent duplicate. Publish a strict
                // session+generation tombstone so its live cursor is disposed
                // instead of being added beside the authoritative owner or
                // keeping every later scan in an unabsorbable retry loop.
                watermarks.append(CodexTokenActivityScanWatermark(
                    sessionID: sessionID,
                    sourceID: Self.canonicalTokenSourceID(path),
                    sourceGeneration: generation,
                    endOffset: .max,
                    lineFingerprint: "",
                    eventTimestamp: nil,
                    totalTokens: nil,
                    sourceStatFingerprint: usage.sourceStatFingerprint,
                    sourceChangeTimeNanoseconds: usage.sourceChangeTimeNanoseconds
                ))
                continue
            }

            guard let owner = uniqueOwnerBySessionID[sessionID],
                  Self.costUsageTokenEventFrontier(owner.1, through: through) != nil
            else { continue }
            guard let alias = Self.verifiedDuplicateAliasWatermark(
                sentinelPath: path,
                sentinelUsage: usage,
                ownerPath: owner.0,
                ownerUsage: owner.1,
                through: through
            ) else {
                throw CostUsageScanner.codexChangedDuringScanError(path: path)
            }
            watermarks.append(alias)
        }

        return watermarks.sorted {
            if $0.sourceID != $1.sourceID { return $0.sourceID < $1.sourceID }
            return $0.endOffset < $1.endOffset
        }
    }

    private static func verifiedNoncontributingDuplicate(
        path: String,
        usage: CostUsageFileUsage
    ) throws -> Bool {
        guard usage.codexInventoryOnly == true,
              usage.codexDuplicateQuarantined != true,
              usage.codexIdentityConflict != true,
              usage.sessionId?.isEmpty == false,
              usage.size > 0,
              usage.parsedBytes == usage.size,
              usage.sourceGeneration != nil,
              usage.sourceStatFingerprint != nil,
              usage.sourceChangeTimeNanoseconds != nil,
              let expectedFingerprint = usage.committedPrefixFingerprint,
              !expectedFingerprint.isEmpty,
              usage.days.isEmpty,
              usage.codexRows?.isEmpty != false,
              usage.tokenEventWatermarks?.isEmpty != false,
              usage.lastTokenEventEndOffset == nil,
              usage.lastTokenEventFingerprint == nil,
              usage.lastTokenEventTimestamp == nil,
              usage.lastTokenEventTotalTokens == nil
        else { return false }

        let fileURL = URL(fileURLWithPath: path)
        guard Self.costUsageFileMetadata(
            CostUsageScanner.codexFileMetadata(fileURL: fileURL), matches: usage
        ),
            try CostUsageScanner.codexCommittedPrefixFingerprint(
                fileURL: fileURL,
                throughOffset: usage.size,
                checkCancellation: nil
            ) == expectedFingerprint,
            Self.costUsageFileMetadata(
                CostUsageScanner.codexFileMetadata(fileURL: fileURL), matches: usage
            )
        else { return false }
        return true
    }

    private static func costUsageTokenEventFrontier(
        _ usage: CostUsageFileUsage,
        through: Date
    ) -> CostUsageTokenEventWatermark? {
        let cachedEvents: [CostUsageTokenEventWatermark]
        if let events = usage.tokenEventWatermarks {
            cachedEvents = events
        } else if let endOffset = usage.lastTokenEventEndOffset,
                  let fingerprint = usage.lastTokenEventFingerprint {
            cachedEvents = [CostUsageTokenEventWatermark(
                endOffset: endOffset,
                lineFingerprint: fingerprint,
                eventTimestamp: usage.lastTokenEventTimestamp,
                totalTokens: usage.lastTokenEventTotalTokens
            )]
        } else {
            cachedEvents = []
        }
        return cachedEvents
            .filter { event in
                event.endOffset >= 0
                    && (event.eventTimestamp.map { $0 <= through } ?? true)
            }
            .max(by: { $0.endOffset < $1.endOffset })
    }

    private static func verifiedDuplicateAliasWatermark(
        sentinelPath: String,
        sentinelUsage: CostUsageFileUsage,
        ownerPath: String,
        ownerUsage: CostUsageFileUsage,
        through: Date
    ) -> CodexTokenActivityScanWatermark? {
        guard let sessionID = sentinelUsage.sessionId,
              let sentinelGeneration = sentinelUsage.sourceGeneration,
              let ownerEvent = Self.costUsageTokenEventFrontier(ownerUsage, through: through)
        else { return nil }

        let sentinelURL = URL(fileURLWithPath: sentinelPath)
        let ownerURL = URL(fileURLWithPath: ownerPath)
        let sentinelMetadata = CostUsageScanner.codexFileMetadata(fileURL: sentinelURL)
        let ownerMetadata = CostUsageScanner.codexFileMetadata(fileURL: ownerURL)
        let ownerParsedBytes = ownerUsage.parsedBytes ?? ownerUsage.size
        guard Self.costUsageFileMetadata(sentinelMetadata, matches: sentinelUsage),
              ownerMetadata.fileId == ownerUsage.sourceGeneration,
              ownerMetadata.size >= ownerParsedBytes,
              (try? CostUsageScanner.codexFileMatchesCommittedFrontier(
                  fileURL: ownerURL,
                  cached: ownerUsage,
                  checkCancellation: nil
              )) == true
        else { return nil }

        // A newline-terminated live cursor ends at the newline byte, so a proven
        // byte count equal to the sentinel size is strictly beyond every cursor
        // the tailer can emit from that file. If the owner's exact token frontier
        // is earlier, retain its fingerprint for equality at that offset.
        let provenEndOffset = min(ownerEvent.endOffset, sentinelUsage.size)
        guard provenEndOffset > 0,
              provenEndOffset <= sentinelMetadata.size,
              provenEndOffset <= ownerMetadata.size,
              let sentinelFingerprint = try? CostUsageScanner.codexCommittedPrefixFingerprint(
                  fileURL: sentinelURL,
                  throughOffset: provenEndOffset,
                  checkCancellation: nil
              ),
              let ownerFingerprint = try? CostUsageScanner.codexCommittedPrefixFingerprint(
                  fileURL: ownerURL,
                  throughOffset: provenEndOffset,
                  checkCancellation: nil
              ),
              sentinelFingerprint == ownerFingerprint,
              Self.costUsageFileMetadata(
                  CostUsageScanner.codexFileMetadata(fileURL: sentinelURL),
                  matches: sentinelUsage
              ),
              CostUsageScanner.codexFileMetadata(fileURL: ownerURL).fileId
                  == ownerUsage.sourceGeneration,
              (try? CostUsageScanner.codexFileMatchesCommittedFrontier(
                  fileURL: ownerURL,
                  cached: ownerUsage,
                  checkCancellation: nil
              )) == true
        else { return nil }

        let aliasesExactOwnerEvent = provenEndOffset == ownerEvent.endOffset
        return CodexTokenActivityScanWatermark(
            sessionID: sessionID,
            sourceID: Self.canonicalTokenSourceID(sentinelPath),
            sourceGeneration: sentinelGeneration,
            endOffset: UInt64(provenEndOffset),
            lineFingerprint: aliasesExactOwnerEvent ? ownerEvent.lineFingerprint : "",
            eventTimestamp: aliasesExactOwnerEvent ? ownerEvent.eventTimestamp : nil,
            totalTokens: aliasesExactOwnerEvent ? ownerEvent.totalTokens : nil,
            sourceStatFingerprint: sentinelUsage.sourceStatFingerprint,
            sourceChangeTimeNanoseconds: sentinelUsage.sourceChangeTimeNanoseconds
        )
    }

    private static func costUsageFileMetadata(
        _ metadata: CostUsageScanner.CodexFileMetadata,
        matches usage: CostUsageFileUsage
    ) -> Bool {
        let generation = metadata.fileId
            ?? URL(fileURLWithPath: metadata.path).standardizedFileURL.resolvingSymlinksInPath().path
        return metadata.fileId != nil
            && usage.sourceGeneration == generation
            && usage.sourceStatFingerprint == metadata.statFingerprint
            && usage.sourceChangeTimeNanoseconds == metadata.changeTimeNanoseconds
            && usage.mtimeUnixMs == metadata.mtimeUnixMs
            && usage.size == metadata.size
    }

    private static func canonicalTokenSourceID(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    private func agentSignalCostUsageDateRange(now: Date, days: Int) -> (since: Date, until: Date) {
        let clampedDays = max(1, min(365, days))
        let today = calendar.startOfDay(for: now)
        let since = calendar.date(byAdding: .day, value: -(clampedDays - 1), to: today) ?? today
        return (since, now)
    }

    private func agentSignalCostUsageOptions(forceRefresh: Bool) -> CostUsageScanner.Options {
        var options = CostUsageScanner.Options(
            cacheRoot: costUsageCacheRoot,
            codexTraceDatabaseURL: priorityDatabaseURL,
            codexScanCheckpoint: costUsageScanCheckpoint,
            forceRescan: false
        )
        options.codexSessionsRoots = sessionRootURLs
        if forceRefresh {
            options.refreshMinIntervalSeconds = 0
        }
        return options
    }

    private func codexTokenActivityDays(from report: CostUsageDailyReport) -> [CodexTokenActivityDay] {
        report.data.compactMap { entry in
            guard let date = CostUsageDateParser.parse(entry.date) else { return nil }
            var modelTokenTotals: [String: Int] = [:]
            var modelCostTotals: [String: Double] = [:]
            var modelStandardTokenTotals: [String: Int] = [:]
            var modelPriorityTokenTotals: [String: Int] = [:]
            var modelStandardCostTotals: [String: Double] = [:]
            var modelPriorityCostTotals: [String: Double] = [:]

            for breakdown in entry.modelBreakdowns ?? [] {
                if let tokens = breakdown.totalTokens, tokens > 0 {
                    modelTokenTotals[breakdown.modelName, default: 0] += tokens
                }
                if let cost = breakdown.costUSD, cost > 0 {
                    modelCostTotals[breakdown.modelName, default: 0] += cost
                }
                if let tokens = breakdown.standardTokens, tokens > 0 {
                    modelStandardTokenTotals[breakdown.modelName, default: 0] += tokens
                }
                if let tokens = breakdown.priorityTokens, tokens > 0 {
                    modelPriorityTokenTotals[breakdown.modelName, default: 0] += tokens
                }
                if let cost = breakdown.standardCostUSD, cost > 0 {
                    modelStandardCostTotals[breakdown.modelName, default: 0] += cost
                }
                if let cost = breakdown.priorityCostUSD, cost > 0 {
                    modelPriorityCostTotals[breakdown.modelName, default: 0] += cost
                }
            }

            return CodexTokenActivityDay(
                day: calendar.startOfDay(for: date),
                totalTokens: max(entry.totalTokens ?? 0, 0),
                estimatedCostUSD: entry.costUSD,
                modelTokenTotals: modelTokenTotals,
                modelEstimatedCostTotals: modelCostTotals,
                modelStandardTokenTotals: modelStandardTokenTotals,
                modelPriorityTokenTotals: modelPriorityTokenTotals,
                modelStandardEstimatedCostTotals: modelStandardCostTotals,
                modelPriorityEstimatedCostTotals: modelPriorityCostTotals
            )
        }
        .sorted { $0.day < $1.day }
    }

    private func scanTokenActivity(
        in url: URL,
        startOffset: Int64,
        initialBaseline: TokenTotals?,
        initialRawTotalsBaseline: TokenTotals?,
        initialHasDivergentTotals: Bool,
        initialCurrentModel: String?,
        initialCurrentTurnID: String?,
        priorityTurns: [String: CodexPriorityTurnMetadata],
        forkResolver: CodexForkBaselineResolver?,
        startDay: Date,
        today: Date
    ) -> CodexTokenActivityFileScanResult {
        var baseline = initialBaseline
        var rawTotalsBaseline = initialRawTotalsBaseline ?? initialBaseline
        var sawDivergentTotals = initialHasDivergentTotals
        var sessionID: String?
        var forkedFromID: String?
        var forkTimestamp: String?
        var forkBaselineResolved = false
        var inheritedTotals: TokenTotals?
        var remainingInheritedTotals: TokenTotals?
        var hasUnresolvedForkBaseline = false
        var unresolvedForkTotalWatermark: TokenTotals?
        var currentModel = initialCurrentModel.flatMap { normalizedCodexModel($0) }
        var currentTurnID = initialCurrentTurnID
        var days: [String: CodexTokenActivityDayCache] = [:]

        if startOffset == 0,
           let metadata = sessionMetadata(in: url) {
            sessionID = metadata.sessionID
            forkedFromID = metadata.forkedFromID
            forkTimestamp = metadata.forkTimestamp
            resolveForkBaselineIfNeeded(
                forkedFromID: forkedFromID,
                forkTimestamp: forkTimestamp,
                forkBaselineResolved: &forkBaselineResolved,
                inheritedTotals: &inheritedTotals,
                remainingInheritedTotals: &remainingInheritedTotals,
                hasUnresolvedForkBaseline: &hasUnresolvedForkBaseline,
                forkResolver: forkResolver
            )
        }

        let parsedBytes: UInt64
        if startOffset == 0,
           let fastScanBytes = scanTokenActivityWithLineNumbers(
            in: url,
            baseline: &baseline,
            rawTotalsBaseline: &rawTotalsBaseline,
            sawDivergentTotals: &sawDivergentTotals,
            sessionID: &sessionID,
            forkedFromID: &forkedFromID,
            forkTimestamp: &forkTimestamp,
            forkBaselineResolved: &forkBaselineResolved,
            inheritedTotals: &inheritedTotals,
            remainingInheritedTotals: &remainingInheritedTotals,
            hasUnresolvedForkBaseline: &hasUnresolvedForkBaseline,
            unresolvedForkTotalWatermark: &unresolvedForkTotalWatermark,
            currentModel: &currentModel,
            currentTurnID: &currentTurnID,
            days: &days,
            priorityTurns: priorityTurns,
            forkResolver: forkResolver,
            startDay: startDay,
            today: today
           ) {
            parsedBytes = fastScanBytes
        } else {
            parsedBytes = forEachLineData(
                in: url,
                startOffset: UInt64(startOffset),
                needles: ["token_count", "turn_context"],
                useRipgrep: false
            ) { lineData in
                applyTokenActivityLine(
                    lineData,
                    baseline: &baseline,
                    rawTotalsBaseline: &rawTotalsBaseline,
                    sawDivergentTotals: &sawDivergentTotals,
                    sessionID: &sessionID,
                    forkedFromID: &forkedFromID,
                    forkTimestamp: &forkTimestamp,
                    forkBaselineResolved: &forkBaselineResolved,
                    inheritedTotals: &inheritedTotals,
                    remainingInheritedTotals: &remainingInheritedTotals,
                    hasUnresolvedForkBaseline: &hasUnresolvedForkBaseline,
                    unresolvedForkTotalWatermark: &unresolvedForkTotalWatermark,
                    currentModel: &currentModel,
                    currentTurnID: &currentTurnID,
                    days: &days,
                    priorityTurns: priorityTurns,
                    forkResolver: forkResolver,
                    startDay: startDay,
                    today: today
                )
            }
        }

        return CodexTokenActivityFileScanResult(
            days: days,
            parsedBytes: Int64(parsedBytes),
            baseline: baseline,
            rawBaseline: rawTotalsBaseline,
            hasDivergentTotals: sawDivergentTotals && !TokenTotals.equal(rawTotalsBaseline, baseline),
            sessionID: sessionID,
            forkedFromID: forkedFromID,
            forkTimestamp: forkTimestamp,
            currentModel: currentModel,
            currentTurnID: currentTurnID
        )
    }

    private func scanTokenActivityBatch(
        in urls: [URL],
        forkResolver: CodexForkBaselineResolver?,
        priorityTurns: [String: CodexPriorityTurnMetadata],
        startDay: Date,
        today: Date
    ) -> [String: CodexTokenActivityFileScanResult]? {
        guard urls.allSatisfy({ url in
            fileMetadata(for: url).map(shouldUseRipgrepContextFastPath(metadata:)) ?? false
        }) else {
            return nil
        }

        var states = Dictionary(
            uniqueKeysWithValues: urls.map { ($0.path, CodexTokenActivityFileScanState()) }
        )
        for url in urls {
            guard let metadata = sessionMetadata(in: url) else {
                continue
            }
            var state = states[url.path] ?? CodexTokenActivityFileScanState()
            state.sessionID = metadata.sessionID
            state.forkedFromID = metadata.forkedFromID
            state.forkTimestamp = metadata.forkTimestamp
            resolveForkBaselineIfNeeded(
                forkedFromID: state.forkedFromID,
                forkTimestamp: state.forkTimestamp,
                forkBaselineResolved: &state.forkBaselineResolved,
                inheritedTotals: &state.inheritedTotals,
                remainingInheritedTotals: &state.remainingInheritedTotals,
                hasUnresolvedForkBaseline: &state.hasUnresolvedForkBaseline,
                forkResolver: forkResolver
            )
            states[url.path] = state
        }

        let modelContextsByPath = RipgrepRelevantJSONLLineScanner.scanTurnContextModels(fileURLs: urls) ?? [:]
        guard urls.allSatisfy({ !(modelContextsByPath[$0.path]?.isEmpty ?? true) }) else {
            return nil
        }
        guard let parsedBytes = RipgrepRelevantJSONLLineScanner.scanNumbered(
            fileURLs: urls,
            needles: ["token_count"],
            onLine: { url, lineNumber, lineData in
                let path = url.path
                var state = states[path] ?? CodexTokenActivityFileScanState()
                if let context = modelContext(beforeOrAt: lineNumber, in: modelContextsByPath[path] ?? []) {
                    state.currentModel = context.model
                    state.currentTurnID = context.turnID
                }
                applyTokenActivityLine(
                    lineData,
                    baseline: &state.baseline,
                    rawTotalsBaseline: &state.rawBaseline,
                    sawDivergentTotals: &state.hasDivergentTotals,
                    sessionID: &state.sessionID,
                    forkedFromID: &state.forkedFromID,
                    forkTimestamp: &state.forkTimestamp,
                    forkBaselineResolved: &state.forkBaselineResolved,
                    inheritedTotals: &state.inheritedTotals,
                    remainingInheritedTotals: &state.remainingInheritedTotals,
                    hasUnresolvedForkBaseline: &state.hasUnresolvedForkBaseline,
                    unresolvedForkTotalWatermark: &state.unresolvedForkTotalWatermark,
                    currentModel: &state.currentModel,
                    currentTurnID: &state.currentTurnID,
                    days: &state.days,
                    priorityTurns: priorityTurns,
                    forkResolver: forkResolver,
                    startDay: startDay,
                    today: today
                )
                states[path] = state
            }
        ) else {
            return nil
        }

        var results: [String: CodexTokenActivityFileScanResult] = [:]
        for url in urls {
            let path = url.path
            let state = states[path] ?? CodexTokenActivityFileScanState()
            let finalCurrentModel = (modelContextsByPath[path]?.last?.model)
                .flatMap { normalizedCodexModel($0) } ?? state.currentModel
            let finalCurrentTurnID = modelContextsByPath[path]?.last?.turnID ?? state.currentTurnID
            results[path] = CodexTokenActivityFileScanResult(
                days: state.days,
                parsedBytes: parsedBytes[path] ?? 0,
                baseline: state.baseline,
                rawBaseline: state.rawBaseline,
                hasDivergentTotals: state.hasDivergentTotals && !TokenTotals.equal(
                    state.rawBaseline,
                    state.baseline
                ),
                sessionID: state.sessionID,
                forkedFromID: state.forkedFromID,
                forkTimestamp: state.forkTimestamp,
                currentModel: finalCurrentModel,
                currentTurnID: finalCurrentTurnID
            )
        }
        return results
    }

    private func scanTokenActivityWithLineNumbers(
        in url: URL,
        baseline: inout TokenTotals?,
        rawTotalsBaseline: inout TokenTotals?,
        sawDivergentTotals: inout Bool,
        sessionID: inout String?,
        forkedFromID: inout String?,
        forkTimestamp: inout String?,
        forkBaselineResolved: inout Bool,
        inheritedTotals: inout TokenTotals?,
        remainingInheritedTotals: inout TokenTotals?,
        hasUnresolvedForkBaseline: inout Bool,
        unresolvedForkTotalWatermark: inout TokenTotals?,
        currentModel: inout String?,
        currentTurnID: inout String?,
        days: inout [String: CodexTokenActivityDayCache],
        priorityTurns: [String: CodexPriorityTurnMetadata],
        forkResolver: CodexForkBaselineResolver?,
        startDay: Date,
        today: Date
    ) -> UInt64? {
        guard let metadata = fileMetadata(for: url),
              shouldUseRipgrepContextFastPath(metadata: metadata)
        else {
            return nil
        }

        let modelContexts = RipgrepRelevantJSONLLineScanner.scanTurnContextModels(fileURLs: [url])?[url.path] ?? []
        guard modelContexts.isEmpty == false else {
            return nil
        }
        guard let parsedBytes = RipgrepRelevantJSONLLineScanner.scanNumbered(
            fileURLs: [url],
            needles: ["token_count"],
            onLine: { _, lineNumber, lineData in
                if let context = modelContext(beforeOrAt: lineNumber, in: modelContexts) {
                    currentModel = context.model
                    currentTurnID = context.turnID
                }
                applyTokenActivityLine(
                    lineData,
                    baseline: &baseline,
                    rawTotalsBaseline: &rawTotalsBaseline,
                    sawDivergentTotals: &sawDivergentTotals,
                    sessionID: &sessionID,
                    forkedFromID: &forkedFromID,
                    forkTimestamp: &forkTimestamp,
                    forkBaselineResolved: &forkBaselineResolved,
                    inheritedTotals: &inheritedTotals,
                    remainingInheritedTotals: &remainingInheritedTotals,
                    hasUnresolvedForkBaseline: &hasUnresolvedForkBaseline,
                    unresolvedForkTotalWatermark: &unresolvedForkTotalWatermark,
                    currentModel: &currentModel,
                    currentTurnID: &currentTurnID,
                    days: &days,
                    priorityTurns: priorityTurns,
                    forkResolver: forkResolver,
                    startDay: startDay,
                    today: today
                )
            }
        ) else {
            return nil
        }

        if let rawLastModel = modelContexts.last?.model,
           let lastModel = normalizedCodexModel(rawLastModel) {
            currentModel = lastModel
        }
        if let lastTurnID = modelContexts.last?.turnID {
            currentTurnID = lastTurnID
        }
        return UInt64(max(0, parsedBytes[url.path] ?? 0))
    }

    private func modelContext(beforeOrAt lineNumber: Int, in contexts: [ModelContext]) -> (model: String, turnID: String?)? {
        guard contexts.isEmpty == false else { return nil }

        var low = 0
        var high = contexts.count
        while low < high {
            let mid = (low + high) / 2
            if contexts[mid].lineNumber <= lineNumber {
                low = mid + 1
            } else {
                high = mid
            }
        }

        guard low > 0 else { return nil }
        let context = contexts[low - 1]
        guard let model = normalizedCodexModel(context.model) else { return nil }
        return (model: model, turnID: context.turnID)
    }

    private func applyTokenActivityLine(
        _ lineData: Data,
        baseline: inout TokenTotals?,
        rawTotalsBaseline: inout TokenTotals?,
        sawDivergentTotals: inout Bool,
        sessionID: inout String?,
        forkedFromID: inout String?,
        forkTimestamp: inout String?,
        forkBaselineResolved: inout Bool,
        inheritedTotals: inout TokenTotals?,
        remainingInheritedTotals: inout TokenTotals?,
        hasUnresolvedForkBaseline: inout Bool,
        unresolvedForkTotalWatermark: inout TokenTotals?,
        currentModel: inout String?,
        currentTurnID: inout String?,
        days: inout [String: CodexTokenActivityDayCache],
        priorityTurns: [String: CodexPriorityTurnMetadata],
        forkResolver: CodexForkBaselineResolver?,
        startDay: Date,
        today: Date
    ) {
        let hasSessionMeta = lineData.firstRange(of: Self.sessionMetaNeedle) != nil
        let hasTurnContext = lineData.firstRange(of: Self.turnContextNeedle) != nil
        let hasTokenCount = lineData.firstRange(of: Self.tokenCountNeedle) != nil
            && lineData.firstRange(of: Self.tokenUsageNeedle) != nil
        if hasTokenCount,
           let fastRecord = CodexTokenActivityFastParser.parseTokenCountLine(lineData) {
            applyTokenCountRecord(
                fastRecord,
                baseline: &baseline,
                rawTotalsBaseline: &rawTotalsBaseline,
                sawDivergentTotals: &sawDivergentTotals,
                inheritedTotals: &inheritedTotals,
                remainingInheritedTotals: &remainingInheritedTotals,
                hasUnresolvedForkBaseline: &hasUnresolvedForkBaseline,
                unresolvedForkTotalWatermark: &unresolvedForkTotalWatermark,
                currentModel: &currentModel,
                currentTurnID: currentTurnID,
                days: &days,
                priorityTurns: priorityTurns,
                startDay: startDay,
                today: today
            )
            return
        }

        guard hasSessionMeta || hasTurnContext || hasTokenCount,
              let parsedLine = CodexTokenActivityFastParser.parseLine(lineData)
        else {
            return
        }

        if case let .sessionMeta(fastMetadata) = parsedLine {
            if sessionID == nil {
                sessionID = fastMetadata.sessionID
            }
            if forkedFromID == nil {
                forkedFromID = fastMetadata.forkedFromID
            }
            if forkTimestamp == nil {
                forkTimestamp = fastMetadata.forkTimestamp
            }
            resolveForkBaselineIfNeeded(
                forkedFromID: forkedFromID,
                forkTimestamp: forkTimestamp,
                forkBaselineResolved: &forkBaselineResolved,
                inheritedTotals: &inheritedTotals,
                remainingInheritedTotals: &remainingInheritedTotals,
                hasUnresolvedForkBaseline: &hasUnresolvedForkBaseline,
                forkResolver: forkResolver
            )
            return
        }

        if case let .turnContext(record) = parsedLine {
            if let model = record.model.flatMap({ normalizedCodexModel($0) }) {
                currentModel = model
            }
            if let turnID = record.turnID {
                currentTurnID = turnID
            }
            return
        }

        let fastRecord: CodexTokenActivityFastParser.TokenCountRecord?
        if hasTokenCount,
           case let .tokenCount(record) = parsedLine {
            fastRecord = record
        } else {
            fastRecord = nil
        }

        guard let fastRecord else {
            return
        }

        applyTokenCountRecord(
            fastRecord,
            baseline: &baseline,
            rawTotalsBaseline: &rawTotalsBaseline,
            sawDivergentTotals: &sawDivergentTotals,
            inheritedTotals: &inheritedTotals,
            remainingInheritedTotals: &remainingInheritedTotals,
            hasUnresolvedForkBaseline: &hasUnresolvedForkBaseline,
            unresolvedForkTotalWatermark: &unresolvedForkTotalWatermark,
            currentModel: &currentModel,
            currentTurnID: currentTurnID,
            days: &days,
            priorityTurns: priorityTurns,
            startDay: startDay,
            today: today
        )
    }

    private func applyTokenCountRecord(
        _ fastRecord: CodexTokenActivityFastParser.TokenCountRecord,
        baseline: inout TokenTotals?,
        rawTotalsBaseline: inout TokenTotals?,
        sawDivergentTotals: inout Bool,
        inheritedTotals: inout TokenTotals?,
        remainingInheritedTotals: inout TokenTotals?,
        hasUnresolvedForkBaseline: inout Bool,
        unresolvedForkTotalWatermark: inout TokenTotals?,
        currentModel: inout String?,
        currentTurnID: String?,
        days: inout [String: CodexTokenActivityDayCache],
        priorityTurns: [String: CodexPriorityTurnMetadata],
        startDay: Date,
        today: Date
    ) {

        var total = fastRecord.total
        var last = fastRecord.last
        let delta: TokenTotals?

        if hasUnresolvedForkBaseline, let rawTotal = total {
            defer { unresolvedForkTotalWatermark = rawTotal }
            guard let watermark = unresolvedForkTotalWatermark else {
                return
            }
            let rawTotalDelta = TokenTotals.totalDelta(from: watermark, to: rawTotal)
            if let rawLast = last {
                last = TokenTotals.minimum(rawLast, rawTotalDelta)
            } else {
                last = rawTotalDelta
            }
            total = nil
        } else {
            if let rawTotal = total,
               let inheritedTotals {
                total = rawTotal.subtractingClamped(inheritedTotals)
            }
            if let rawLast = last {
                last = adjustedLastDelta(rawLast, remainingInheritedTotals: &remainingInheritedTotals)
            }
        }

        if let total {
            if let countedBaseline = baseline {
                let totalDelta = sawDivergentTotals
                    ? TokenTotals.divergentTotalDelta(
                        rawBaseline: rawTotalsBaseline,
                        countedBaseline: countedBaseline,
                        current: total
                    )
                    : TokenTotals.totalDelta(from: rawTotalsBaseline, to: total)
                if let last,
                   TokenTotals.shouldPreferTotalDelta(
                    rawBaseline: rawTotalsBaseline,
                    currentTotal: total,
                    totalDelta: totalDelta,
                    lastDelta: last,
                    sawDivergentTotals: sawDivergentTotals
                   ) {
                    delta = totalDelta.positive
                } else {
                    delta = total.effectiveTotalTokens >= countedBaseline.effectiveTotalTokens
                        ? totalDelta.positive
                        : last ?? total
                }
                if let delta {
                    baseline = countedBaseline.adding(delta)
                }
                rawTotalsBaseline = total
                if !TokenTotals.equal(rawTotalsBaseline, baseline) {
                    sawDivergentTotals = true
                }
            } else {
                delta = last ?? total
                baseline = delta
                rawTotalsBaseline = total
            }
        } else if let last {
            delta = last.effectiveTotalTokens > 0 ? last : nil
            if let delta {
                baseline = baseline?.adding(delta) ?? delta
                rawTotalsBaseline = baseline
            }
        } else {
            delta = nil
        }

        guard let timestamp = parseTimestamp(fastRecord.timestamp) else {
            return
        }
        let day = calendar.startOfDay(for: timestamp)
        guard day >= startDay,
              day <= today,
              let delta,
              delta.effectiveTotalTokens > 0
        else {
            return
        }

        let recordModel = fastRecord.model.flatMap { normalizedCodexModel($0) }
        if let recordModel {
            currentModel = recordModel
        }
        let priorityMetadata = currentTurnID.flatMap { priorityTurns[$0] }
        let usageMode: CodexTokenUsageMode = priorityMetadata == nil ? .standard : .priority
        let model = priorityMetadata?.model.flatMap { normalizedCodexModel($0) } ?? recordModel ?? currentModel
        let cost = model.flatMap {
            estimatedCodexCostUSD(model: $0, totals: delta, mode: usageMode)
        }
        days[dayKey(for: day), default: .empty].add(
            tokens: delta.effectiveTotalTokens,
            estimatedCostUSD: cost,
            model: model,
            mode: usageMode
        )
    }

    @discardableResult
    private func forEachLineData(
        in url: URL,
        startOffset: UInt64,
        needles: [String] = ["token_count"],
        useRipgrep: Bool = true,
        _ body: (Data) -> Void
    ) -> UInt64 {
        if useRipgrep,
           startOffset == 0,
           let parsedBytes = RipgrepRelevantJSONLLineScanner.scan(
            fileURL: url,
            needles: needles,
            onLine: body
           ) {
            return UInt64(max(0, parsedBytes))
        }

        let needleData = needles.map { Data($0.utf8) }
        let parsedBytes = try? BoundedJSONLLineScanner.scan(
            fileURL: url,
            offset: Int64(startOffset),
            maximumLineBytes: 256 * 1024,
            retainedPrefixBytes: 256 * 1024
        ) { line in
            guard needleData.contains(where: { line.data.firstRange(of: $0) != nil }) else {
                return
            }
            body(line.data)
        }
        return UInt64(max(Int64(startOffset), parsedBytes ?? Int64(startOffset)))
    }

    private func sessionFiles(
        modifiedSince startDay: Date,
        cachedFiles: [String: CodexTokenActivityFileCache],
        startKey: String,
        todayKey: String
    ) -> [URL] {
        var files: [(url: URL, modifiedAt: Date)] = []
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
                let fileDayKey = sessionDayKey(for: url)
                if let fileDayKey,
                   fileDayKey > todayKey {
                    continue
                }

                guard url.lastPathComponent.hasPrefix("rollout-"),
                      url.pathExtension == "jsonl",
                      !seenPaths.contains(url.path),
                      let values = try? url.resourceValues(forKeys: [
                        .isRegularFileKey,
                        .contentModificationDateKey
                      ]),
                      values.isRegularFile == true,
                      let modifiedAt = values.contentModificationDate,
                      modifiedAt >= startDay || isSessionDayKey(fileDayKey, in: startKey...todayKey)
                else {
                    continue
                }

                seenPaths.insert(url.path)
                files.append((url, modifiedAt))
            }
        }

        for (path, cached) in cachedFiles where !seenPaths.contains(path) {
            let url = URL(fileURLWithPath: path)
            guard cached.days.isEmpty == false,
                  cached.days.keys.contains(where: { $0 >= startKey && $0 <= todayKey }),
                  fileManager.fileExists(atPath: path),
                  let metadata = fileMetadata(for: url)
            else {
                continue
            }

            seenPaths.insert(path)
            files.append((url, metadata.modifiedAt))
        }

        return files
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .map(\.url)
    }

    private func isSessionDayKey(_ key: String?, in range: ClosedRange<String>) -> Bool {
        guard let key else { return false }
        return range.contains(key)
    }

    private func allSessionFiles(cachedFiles: [String: CodexTokenActivityFileCache]) -> [URL] {
        var urls: [URL] = []
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
                      let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                      values.isRegularFile == true
                else {
                    continue
                }

                seenPaths.insert(url.path)
                urls.append(url)
            }
        }

        for path in cachedFiles.keys where !seenPaths.contains(path) && fileManager.fileExists(atPath: path) {
            seenPaths.insert(path)
            urls.append(URL(fileURLWithPath: path))
        }

        return urls
    }

    private func sessionIndex(from urls: [URL]) -> [String: URL] {
        var index: [String: URL] = [:]
        for url in urls {
            guard let sessionID = sessionMetadata(in: url)?.sessionID,
                  index[sessionID] == nil
            else {
                continue
            }
            index[sessionID] = url
        }
        return index
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

        return [
            home.appendingPathComponent(".codex/sessions", isDirectory: true),
            home.appendingPathComponent(".codex/archived_sessions", isDirectory: true),
            home.appendingPathComponent("Library/Developer/Xcode/CodingAssistant/codex/sessions", isDirectory: true)
        ] + jetBrainsCodexSessionRootURLs(home: home, fileManager: fileManager)
    }

    private static func defaultPriorityDatabaseURL(
        fileManager: FileManager,
        environment: [String: String]
    ) -> URL? {
        if let codexHome = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !codexHome.isEmpty {
            return URL(fileURLWithPath: (codexHome as NSString).expandingTildeInPath, isDirectory: true)
                .appendingPathComponent("logs_2.sqlite", isDirectory: false)
        }

        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/logs_2.sqlite", isDirectory: false)
    }

    private static func defaultCacheURL(fileManager: FileManager) -> URL? {
        fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("AgentSignalLight", isDirectory: true)
            .appendingPathComponent("codex-token-activity-v\(cacheVersion).json", isDirectory: false)
    }

    private static func defaultCostUsageCacheRoot(fileManager: FileManager, cacheURL: URL?) -> URL? {
        if let cacheURL {
            let base = cacheURL.deletingLastPathComponent()
            let newRoot = base.appendingPathComponent("agent-signal-cost-usage", isDirectory: true)
            migrateCostUsageCacheRootIfNeeded(
                from: base.appendingPathComponent(legacyImportedCostUsageCacheRootName, isDirectory: true),
                to: newRoot,
                fileManager: fileManager
            )
            return newRoot
        }
        guard let cachesRoot = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let appRoot = cachesRoot.appendingPathComponent("AgentSignalBar", isDirectory: true)
        let newRoot = appRoot.appendingPathComponent("agent-signal-cost-usage", isDirectory: true)
        migrateCostUsageCacheRootIfNeeded(
            from: appRoot.appendingPathComponent(legacyImportedCostUsageCacheRootName, isDirectory: true),
            to: newRoot,
            fileManager: fileManager
        )
        return newRoot
    }

    private static func migrateCostUsageCacheRootIfNeeded(
        from oldRoot: URL,
        to newRoot: URL,
        fileManager: FileManager
    ) {
        guard fileManager.fileExists(atPath: oldRoot.path),
              !fileManager.fileExists(atPath: newRoot.path)
        else {
            return
        }
        try? fileManager.createDirectory(
            at: newRoot.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? fileManager.copyItem(at: oldRoot, to: newRoot)
    }

    private static func jetBrainsCodexSessionRootURLs(home: URL, fileManager: FileManager) -> [URL] {
        let jetBrainsRoot = home.appendingPathComponent("Library/Caches/JetBrains", isDirectory: true)
        guard let enumerator = fileManager.enumerator(
            at: jetBrainsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var roots: [URL] = []
        for case let url as URL in enumerator {
            guard url.path.hasSuffix("/aia/codex/sessions") else { continue }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true {
                roots.append(url)
            }
        }
        return roots.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func loadCache(historyDays: Int) -> CodexTokenActivityCache {
        guard let cache = loadCompatibleCache(
            from: cacheURL,
            version: Self.cacheVersion,
            historyDays: historyDays
        ) else {
            return CodexTokenActivityCache(
                version: Self.cacheVersion,
                historyDays: historyDays,
                calendar: calendar,
                roots: sessionRootURLs
            )
        }

        return cache
    }

    private func loadCompatibleCache(
        from url: URL?,
        version: Int,
        historyDays: Int
    ) -> CodexTokenActivityCache? {
        guard let url,
              let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(CodexTokenActivityCache.self, from: data),
              cache.isCompatible(
                version: version,
                historyDays: historyDays,
                calendar: calendar,
                roots: sessionRootURLs
              )
        else {
            return nil
        }

        return cache
    }

    private func dailyActivity(
        from cache: CodexTokenActivityCache,
        now: Date,
        days: Int
    ) -> [CodexTokenActivityDay] {
        let today = calendar.startOfDay(for: now)
        let startDay = calendar.date(byAdding: .day, value: -max(days - 1, 0), to: today) ?? today
        let startKey = dayKey(for: startDay)
        let todayKey = dayKey(for: today)
        var totalsByDay: [Date: CodexTokenActivityDayCache] = [:]

        for file in cache.files.values {
            merge(file.days, into: &totalsByDay, startKey: startKey, todayKey: todayKey)
        }

        return activityDays(from: totalsByDay)
    }

    private func saveCache(_ cache: CodexTokenActivityCache) {
        guard let cacheURL,
              cache.isComplete,
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

    private func resolveForkBaselineIfNeeded(
        forkedFromID: String?,
        forkTimestamp: String?,
        forkBaselineResolved: inout Bool,
        inheritedTotals: inout TokenTotals?,
        remainingInheritedTotals: inout TokenTotals?,
        hasUnresolvedForkBaseline: inout Bool,
        forkResolver: CodexForkBaselineResolver?
    ) {
        guard !forkBaselineResolved,
              let forkedFromID
        else {
            return
        }

        forkBaselineResolved = true
        if let inherited = forkResolver?.baseline(parentSessionID: forkedFromID, forkTimestamp: forkTimestamp) {
            inheritedTotals = inherited
            remainingInheritedTotals = inherited
            hasUnresolvedForkBaseline = false
        } else {
            hasUnresolvedForkBaseline = true
        }
    }

    private func adjustedLastDelta(
        _ rawDelta: TokenTotals,
        remainingInheritedTotals: inout TokenTotals?
    ) -> TokenTotals {
        guard let remaining = remainingInheritedTotals else {
            return rawDelta
        }

        let adjusted = rawDelta.subtractingClamped(remaining)
        let nextRemaining = remaining.subtractingClamped(rawDelta)
        remainingInheritedTotals = nextRemaining.effectiveTotalTokens > 0 ? nextRemaining : nil
        return adjusted
    }

    private func fileMetadata(for url: URL) -> CodexTokenActivityFileMetadata? {
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

        return CodexTokenActivityFileMetadata(
            size: Int64(fileSize),
            mtimeUnixMs: Int64(modifiedAt.timeIntervalSince1970 * 1_000),
            modifiedAt: modifiedAt
        )
    }

    private func shouldUseRipgrepContextFastPath(metadata: CodexTokenActivityFileMetadata) -> Bool {
        metadata.size >= Self.ripgrepContextFastPathMinimumBytes
    }

    private func merge(
        _ days: [String: CodexTokenActivityDayCache],
        into totalsByDay: inout [Date: CodexTokenActivityDayCache],
        startKey: String,
        todayKey: String
    ) {
        for (key, stats) in days where key >= startKey && key <= todayKey && stats.totalTokens > 0 {
            guard let day = day(from: key) else {
                continue
            }
            totalsByDay[day, default: .empty].merge(stats)
        }
    }

    private func addingDays(
        _ lhs: [String: CodexTokenActivityDayCache],
        _ rhs: [String: CodexTokenActivityDayCache]
    ) -> [String: CodexTokenActivityDayCache] {
        var merged = lhs
        for (key, value) in rhs where value.totalTokens > 0 {
            merged[key, default: .empty].merge(value)
        }
        return merged
    }

    private func activityDays(from totalsByDay: [Date: CodexTokenActivityDayCache]) -> [CodexTokenActivityDay] {
        totalsByDay
            .map {
                CodexTokenActivityDay(
                    day: $0.key,
                    totalTokens: $0.value.totalTokens,
                    estimatedCostUSD: $0.value.estimatedCostUSD,
                    modelTokenTotals: $0.value.modelTokenTotals,
                    modelEstimatedCostTotals: $0.value.modelEstimatedCostTotals,
                    modelStandardTokenTotals: $0.value.modelStandardTokenTotals,
                    modelPriorityTokenTotals: $0.value.modelPriorityTokenTotals,
                    modelStandardEstimatedCostTotals: $0.value.modelStandardEstimatedCostTotals,
                    modelPriorityEstimatedCostTotals: $0.value.modelPriorityEstimatedCostTotals
                )
            }
            .sorted { $0.day < $1.day }
    }

    private func pruneMissingFiles(from cache: inout CodexTokenActivityCache) {
        for path in cache.files.keys where !fileManager.fileExists(atPath: path) {
            cache.files.removeValue(forKey: path)
        }
    }

    private func dayKey(for date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 1,
            components.day ?? 1
        )
    }

    private func day(from key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else {
            return nil
        }

        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        return calendar.date(from: components)
    }

    private func normalizedCodexModel(_ raw: String) -> String? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let colonIndex = trimmed.firstIndex(of: ":") {
            trimmed = String(trimmed[..<colonIndex])
        }
        if let dateRange = trimmed.range(of: #"-\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) {
            trimmed.removeSubrange(dateRange)
        }
        if trimmed.isEmpty {
            return nil
        }
        return trimmed
    }

    private func estimatedCodexCostUSD(
        model: String,
        totals: TokenTotals,
        mode: CodexTokenUsageMode
    ) -> Double? {
        CodexTokenActivityPricing.estimatedCostUSD(model: model, totals: totals, mode: mode)
    }

    private func priorityTurnMetadata(
        startDay: Date,
        today: Date
    ) -> [String: CodexPriorityTurnMetadata] {
#if canImport(SQLite3)
        guard let priorityDatabaseURL,
              fileManager.fileExists(atPath: priorityDatabaseURL.path)
        else {
            return [:]
        }

        var database: OpaquePointer?
        guard sqlite3_open_v2(
            priorityDatabaseURL.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX,
            nil
        ) == SQLITE_OK,
            let database
        else {
            return [:]
        }
        defer { sqlite3_close(database) }

        let endDay = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        let sql = """
        SELECT ts, feedback_log_body
        FROM logs
        WHERE ts >= ? AND ts < ?
          AND feedback_log_body IS NOT NULL
          AND (
            feedback_log_body LIKE '%service_tier%'
            OR feedback_log_body LIKE '%response.completed%'
          )
        ORDER BY ts ASC, ts_nanos ASC, id ASC
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            return [:]
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, Int64(startDay.timeIntervalSince1970))
        sqlite3_bind_int64(statement, 2, Int64(endDay.timeIntervalSince1970))

        var priorityTurns: [String: CodexPriorityTurnMetadata] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let timestamp = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 0)))
            guard let textPointer = sqlite3_column_text(statement, 1) else {
                continue
            }
            let body = String(cString: textPointer)

            if let request = priorityRequestTrace(in: body) {
                priorityTurns[request.turnID] = CodexPriorityTurnMetadata(
                    model: request.model.flatMap { normalizedCodexModel($0) },
                    timestamp: timestamp
                )
                continue
            }

            guard let completed = completedResponseTrace(in: body),
                  var metadata = priorityTurns[completed.turnID]
            else {
                continue
            }
            if metadata.model == nil,
               let model = completed.model.flatMap({ normalizedCodexModel($0) }) {
                metadata = CodexPriorityTurnMetadata(model: model, timestamp: metadata.timestamp ?? timestamp)
                priorityTurns[completed.turnID] = metadata
            }
        }

        return priorityTurns
#else
        return [:]
#endif
    }

    private func priorityRequestTrace(in body: String) -> (turnID: String, model: String?)? {
        guard let marker = body.range(of: "websocket request:") else {
            return nil
        }

        let prefix = String(body[..<marker.lowerBound])
        guard let object = traceJSONObject(after: marker, in: body),
              stringValue(object["type"]) == "response.create",
              isFastCodexServiceTier(
                  stringValue(object["service_tier"])
                      ?? stringValue(object["preferred_service_tier"])
              ),
              let turnID = traceTurnID(in: prefix)
                ?? stringValue(object["turn_id"])
                ?? stringValue(object["turnId"])
        else {
            return nil
        }

        return (turnID: turnID, model: stringValue(object["model"]))
    }

    private func isFastCodexServiceTier(_ serviceTier: String?) -> Bool {
        guard let serviceTier = serviceTier?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        else {
            return false
        }
        return serviceTier == "fast" || serviceTier == "priority"
    }

    private func completedResponseTrace(in body: String) -> (turnID: String, model: String?)? {
        guard let marker = body.range(of: "websocket event:") else {
            return nil
        }

        let prefix = String(body[..<marker.lowerBound])
        guard let object = traceJSONObject(after: marker, in: body),
              stringValue(object["type"]) == "response.completed",
              let turnID = traceTurnID(in: prefix)
                ?? stringValue(object["turn_id"])
                ?? stringValue(object["turnId"])
        else {
            return nil
        }

        let response = object["response"] as? [String: Any]
        return (turnID: turnID, model: stringValue(response?["model"]) ?? stringValue(object["model"]))
    }

    private func traceJSONObject(
        after marker: Range<String.Index>,
        in body: String
    ) -> [String: Any]? {
        let jsonText = String(body[marker.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard jsonText.isEmpty == false,
              let data = jsonText.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return object
    }

    private func traceTurnID(in prefix: String) -> String? {
        for key in ["turn.id", "turn_id", "turnId"] {
            if let value = traceValue(named: key, in: prefix) {
                return value
            }
        }
        return nil
    }

    private func traceValue(named name: String, in text: String) -> String? {
        guard let range = text.range(of: "\(name)=") ?? text.range(of: "\(name):") else {
            return nil
        }

        var index = range.upperBound
        while index < text.endIndex,
              text[index].isWhitespace || text[index] == "\"" || text[index] == "'" {
            index = text.index(after: index)
        }

        var value = ""
        while index < text.endIndex {
            let character = text[index]
            if character.isLetter || character.isNumber || character == "-" || character == "_" {
                value.append(character)
                index = text.index(after: index)
            } else {
                break
            }
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func sessionDayKey(for url: URL) -> String? {
        let filename = url.lastPathComponent
        if let range = filename.range(
            of: #"\d{4}-\d{2}-\d{2}"#,
            options: .regularExpression
        ) {
            let key = String(filename[range])
            if isValidDayKey(key) {
                return key
            }
        }

        let parts = url.pathComponents
        guard parts.count >= 4 else {
            return nil
        }

        for index in 0..<(parts.count - 3) {
            let year = parts[index]
            let month = parts[index + 1]
            let day = parts[index + 2]
            let key = "\(year)-\(month)-\(day)"
            if isValidDayKey(key) {
                return key
            }
        }
        return nil
    }

    private func isValidDayKey(_ key: String) -> Bool {
        guard key.count == 10 else {
            return false
        }
        let characters = Array(key)
        let digitIndexes = [0, 1, 2, 3, 5, 6, 8, 9]
        guard characters[4] == "-",
              characters[7] == "-",
              digitIndexes.allSatisfy({ characters[$0].isNumber })
        else {
            return false
        }
        return true
    }

    private func sessionMetadata(in url: URL) -> CodexSessionMetadata? {
        firstLineData(in: url, maxLines: 24) { lineData in
            lineData.firstRange(of: Self.sessionMetaNeedle) != nil
        }
        .flatMap(sessionMetadata(from:))
    }

    private func sessionMetadata(from lineData: Data) -> CodexSessionMetadata? {
        if case let .sessionMeta(metadata) = CodexTokenActivityFastParser.parseLine(lineData) {
            return CodexSessionMetadata(
                sessionID: metadata.sessionID,
                forkedFromID: metadata.forkedFromID,
                forkTimestamp: metadata.forkTimestamp
            )
        }

        if let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
           (object["type"] as? String) == "session_meta",
           let payload = object["payload"] as? [String: Any] {
            return CodexSessionMetadata(
                sessionID: stringValue(payload["id"])
                    ?? stringValue(payload["session_id"])
                    ?? stringValue(payload["sessionId"])
                    ?? stringValue(object["id"]),
                forkedFromID: stringValue(payload["forked_from_id"])
                    ?? stringValue(payload["forkedFromId"])
                    ?? stringValue(payload["parent_session_id"])
                    ?? stringValue(payload["parentSessionId"]),
                forkTimestamp: stringValue(payload["timestamp"]) ?? stringValue(object["timestamp"])
            )
        }

        return CodexSessionMetadata(
            sessionID: stringField(in: lineData, key: "id")
                ?? stringField(in: lineData, key: "session_id")
                ?? stringField(in: lineData, key: "sessionId"),
            forkedFromID: stringField(in: lineData, key: "forked_from_id")
                ?? stringField(in: lineData, key: "forkedFromId")
                ?? stringField(in: lineData, key: "parent_session_id")
                ?? stringField(in: lineData, key: "parentSessionId"),
            forkTimestamp: stringField(in: lineData, key: "timestamp")
        )
    }

    fileprivate func parentTokenSnapshots(in url: URL) -> [CodexTokenSnapshot] {
        var snapshots: [CodexTokenSnapshot] = []
        forEachLineData(in: url, startOffset: 0) { lineData in
            guard lineData.firstRange(of: Self.tokenCountNeedle) != nil,
                  lineData.firstRange(of: Self.tokenUsageNeedle) != nil,
                  case let .tokenCount(record) = CodexTokenActivityFastParser.parseLine(lineData),
                  let timestamp = parseTimestamp(record.timestamp),
                  let totals = record.total
            else {
                return
            }
            snapshots.append(CodexTokenSnapshot(timestamp: timestamp, totals: totals))
        }
        return snapshots
    }

    private func firstLineData(
        in url: URL,
        maxLines: Int,
        matching predicate: (Data) -> Bool
    ) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }

        var linesRead = 0
        var buffer = Data()
        let newline = UInt8(ascii: "\n")

        while linesRead < maxLines,
              let chunk = try? handle.read(upToCount: 16 * 1024),
              !chunk.isEmpty {
            buffer.append(chunk)

            while linesRead < maxLines,
                  let newlineIndex = buffer.firstIndex(of: newline) {
                let lineData = buffer[..<newlineIndex]
                let nextIndex = buffer.index(after: newlineIndex)
                buffer.removeSubrange(..<nextIndex)
                linesRead += 1

                if predicate(Data(lineData)) {
                    return Data(lineData)
                }
            }
        }

        if linesRead < maxLines, !buffer.isEmpty {
            linesRead += 1
            if predicate(buffer) {
                return buffer
            }
        }

        return nil
    }

    private func stringValue(_ value: Any?) -> String? {
        guard let value = value as? String else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func stringField(in data: Data, key: String) -> String? {
        guard let text = String(data: data, encoding: .utf8),
              let keyRange = text.range(of: "\"\(key)\""),
              let colonRange = text[keyRange.upperBound...].range(of: ":")
        else {
            return nil
        }

        var index = colonRange.upperBound
        while index < text.endIndex,
              text[index].isWhitespace {
            index = text.index(after: index)
        }
        guard index < text.endIndex,
              text[index] == "\""
        else {
            return nil
        }

        index = text.index(after: index)
        var value = ""
        var isEscaped = false
        while index < text.endIndex {
            let character = text[index]
            if isEscaped {
                value.append(character)
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else if character == "\"" {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            } else {
                value.append(character)
            }
            index = text.index(after: index)
        }
        return nil
    }

    fileprivate func parseTimestamp(_ value: String?) -> Date? {
        guard let value else {
            return nil
        }
        return CodexTokenActivityTimestampParser.parseISO(value)
    }
}

private enum CodexTokenUsageMode: String, Codable, Sendable {
    case standard
    case priority
}

private struct CodexPriorityTurnMetadata: Sendable {
    let model: String?
    let timestamp: Date?
}

private struct CodexTokenActivityFileMetadata {
    let size: Int64
    let mtimeUnixMs: Int64
    let modifiedAt: Date
}

private struct CodexTokenActivityFileScanResult {
    let days: [String: CodexTokenActivityDayCache]
    let parsedBytes: Int64
    let baseline: TokenTotals?
    let rawBaseline: TokenTotals?
    let hasDivergentTotals: Bool
    let sessionID: String?
    let forkedFromID: String?
    let forkTimestamp: String?
    let currentModel: String?
    let currentTurnID: String?
}

private struct CodexTokenActivityFileScanState {
    var days: [String: CodexTokenActivityDayCache] = [:]
    var baseline: TokenTotals?
    var rawBaseline: TokenTotals?
    var hasDivergentTotals = false
    var sessionID: String?
    var forkedFromID: String?
    var forkTimestamp: String?
    var forkBaselineResolved = false
    var inheritedTotals: TokenTotals?
    var remainingInheritedTotals: TokenTotals?
    var hasUnresolvedForkBaseline = false
    var unresolvedForkTotalWatermark: TokenTotals?
    var currentModel: String?
    var currentTurnID: String?
}

private struct CodexTokenActivityDayCache: Codable, Equatable {
    static let empty = CodexTokenActivityDayCache(
        totalTokens: 0,
        estimatedCostUSD: nil,
        modelTokenTotals: [:],
        modelEstimatedCostTotals: [:],
        modelStandardTokenTotals: [:],
        modelPriorityTokenTotals: [:],
        modelStandardEstimatedCostTotals: [:],
        modelPriorityEstimatedCostTotals: [:]
    )

    var totalTokens: Int
    var estimatedCostUSD: Double?
    var modelTokenTotals: [String: Int]
    var modelEstimatedCostTotals: [String: Double]
    var modelStandardTokenTotals: [String: Int]
    var modelPriorityTokenTotals: [String: Int]
    var modelStandardEstimatedCostTotals: [String: Double]
    var modelPriorityEstimatedCostTotals: [String: Double]

    mutating func add(
        tokens: Int,
        estimatedCostUSD cost: Double?,
        model: String?,
        mode: CodexTokenUsageMode
    ) {
        let positiveTokens = max(tokens, 0)
        guard positiveTokens > 0 else { return }
        totalTokens += positiveTokens
        if let cost {
            estimatedCostUSD = (estimatedCostUSD ?? 0) + max(cost, 0)
        }
        if let model,
           !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            modelTokenTotals[model, default: 0] += positiveTokens
            switch mode {
            case .standard:
                modelStandardTokenTotals[model, default: 0] += positiveTokens
            case .priority:
                modelPriorityTokenTotals[model, default: 0] += positiveTokens
            }
            if let cost {
                modelEstimatedCostTotals[model, default: 0] += max(cost, 0)
                switch mode {
                case .standard:
                    modelStandardEstimatedCostTotals[model, default: 0] += max(cost, 0)
                case .priority:
                    modelPriorityEstimatedCostTotals[model, default: 0] += max(cost, 0)
                }
            }
        }
    }

    mutating func merge(_ other: CodexTokenActivityDayCache) {
        totalTokens += max(other.totalTokens, 0)
        if let otherCost = other.estimatedCostUSD {
            estimatedCostUSD = (estimatedCostUSD ?? 0) + max(otherCost, 0)
        }
        for (model, tokens) in other.modelTokenTotals where tokens > 0 {
            modelTokenTotals[model, default: 0] += tokens
        }
        for (model, cost) in other.modelEstimatedCostTotals where cost > 0 {
            modelEstimatedCostTotals[model, default: 0] += cost
        }
        for (model, tokens) in other.modelStandardTokenTotals where tokens > 0 {
            modelStandardTokenTotals[model, default: 0] += tokens
        }
        for (model, tokens) in other.modelPriorityTokenTotals where tokens > 0 {
            modelPriorityTokenTotals[model, default: 0] += tokens
        }
        for (model, cost) in other.modelStandardEstimatedCostTotals where cost > 0 {
            modelStandardEstimatedCostTotals[model, default: 0] += cost
        }
        for (model, cost) in other.modelPriorityEstimatedCostTotals where cost > 0 {
            modelPriorityEstimatedCostTotals[model, default: 0] += cost
        }
    }
}

private struct CodexSessionMetadata {
    let sessionID: String?
    let forkedFromID: String?
    let forkTimestamp: String?
}

private struct CodexTokenSnapshot {
    let timestamp: Date
    let totals: TokenTotals
}

private enum CodexTokenActivityPricing {
    private struct Pricing {
        let inputCostPerToken: Double
        let outputCostPerToken: Double
        let cacheReadInputCostPerToken: Double?
        let thresholdTokens: Int?
        let inputCostPerTokenAboveThreshold: Double?
        let outputCostPerTokenAboveThreshold: Double?
        let cacheReadInputCostPerTokenAboveThreshold: Double?
        let priorityInputCostPerToken: Double?
        let priorityOutputCostPerToken: Double?
        let priorityCacheReadInputCostPerToken: Double?

        init(
            inputCostPerToken: Double,
            outputCostPerToken: Double,
            cacheReadInputCostPerToken: Double?,
            thresholdTokens: Int?,
            inputCostPerTokenAboveThreshold: Double?,
            outputCostPerTokenAboveThreshold: Double?,
            cacheReadInputCostPerTokenAboveThreshold: Double?,
            priorityInputCostPerToken: Double? = nil,
            priorityOutputCostPerToken: Double? = nil,
            priorityCacheReadInputCostPerToken: Double? = nil
        ) {
            self.inputCostPerToken = inputCostPerToken
            self.outputCostPerToken = outputCostPerToken
            self.cacheReadInputCostPerToken = cacheReadInputCostPerToken
            self.thresholdTokens = thresholdTokens
            self.inputCostPerTokenAboveThreshold = inputCostPerTokenAboveThreshold
            self.outputCostPerTokenAboveThreshold = outputCostPerTokenAboveThreshold
            self.cacheReadInputCostPerTokenAboveThreshold = cacheReadInputCostPerTokenAboveThreshold
            self.priorityInputCostPerToken = priorityInputCostPerToken
            self.priorityOutputCostPerToken = priorityOutputCostPerToken
            self.priorityCacheReadInputCostPerToken = priorityCacheReadInputCostPerToken
        }
    }

    private static let pricingByModel: [String: Pricing] = [
        "gpt-5": Pricing(inputCostPerToken: 1.25e-6, outputCostPerToken: 1e-5, cacheReadInputCostPerToken: 1.25e-7, thresholdTokens: nil, inputCostPerTokenAboveThreshold: nil, outputCostPerTokenAboveThreshold: nil, cacheReadInputCostPerTokenAboveThreshold: nil),
        "gpt-5-codex": Pricing(inputCostPerToken: 1.25e-6, outputCostPerToken: 1e-5, cacheReadInputCostPerToken: 1.25e-7, thresholdTokens: nil, inputCostPerTokenAboveThreshold: nil, outputCostPerTokenAboveThreshold: nil, cacheReadInputCostPerTokenAboveThreshold: nil),
        "gpt-5-mini": Pricing(inputCostPerToken: 2.5e-7, outputCostPerToken: 2e-6, cacheReadInputCostPerToken: 2.5e-8, thresholdTokens: nil, inputCostPerTokenAboveThreshold: nil, outputCostPerTokenAboveThreshold: nil, cacheReadInputCostPerTokenAboveThreshold: nil),
        "gpt-5-nano": Pricing(inputCostPerToken: 5e-8, outputCostPerToken: 4e-7, cacheReadInputCostPerToken: 5e-9, thresholdTokens: nil, inputCostPerTokenAboveThreshold: nil, outputCostPerTokenAboveThreshold: nil, cacheReadInputCostPerTokenAboveThreshold: nil),
        "gpt-5-pro": Pricing(inputCostPerToken: 1.5e-5, outputCostPerToken: 1.2e-4, cacheReadInputCostPerToken: nil, thresholdTokens: nil, inputCostPerTokenAboveThreshold: nil, outputCostPerTokenAboveThreshold: nil, cacheReadInputCostPerTokenAboveThreshold: nil),
        "gpt-5.1": Pricing(inputCostPerToken: 1.25e-6, outputCostPerToken: 1e-5, cacheReadInputCostPerToken: 1.25e-7, thresholdTokens: nil, inputCostPerTokenAboveThreshold: nil, outputCostPerTokenAboveThreshold: nil, cacheReadInputCostPerTokenAboveThreshold: nil),
        "gpt-5.1-codex": Pricing(inputCostPerToken: 1.25e-6, outputCostPerToken: 1e-5, cacheReadInputCostPerToken: 1.25e-7, thresholdTokens: nil, inputCostPerTokenAboveThreshold: nil, outputCostPerTokenAboveThreshold: nil, cacheReadInputCostPerTokenAboveThreshold: nil),
        "gpt-5.1-codex-max": Pricing(inputCostPerToken: 1.25e-6, outputCostPerToken: 1e-5, cacheReadInputCostPerToken: 1.25e-7, thresholdTokens: nil, inputCostPerTokenAboveThreshold: nil, outputCostPerTokenAboveThreshold: nil, cacheReadInputCostPerTokenAboveThreshold: nil),
        "gpt-5.1-codex-mini": Pricing(inputCostPerToken: 2.5e-7, outputCostPerToken: 2e-6, cacheReadInputCostPerToken: 2.5e-8, thresholdTokens: nil, inputCostPerTokenAboveThreshold: nil, outputCostPerTokenAboveThreshold: nil, cacheReadInputCostPerTokenAboveThreshold: nil),
        "gpt-5.2": Pricing(inputCostPerToken: 1.75e-6, outputCostPerToken: 1.4e-5, cacheReadInputCostPerToken: 1.75e-7, thresholdTokens: nil, inputCostPerTokenAboveThreshold: nil, outputCostPerTokenAboveThreshold: nil, cacheReadInputCostPerTokenAboveThreshold: nil),
        "gpt-5.2-codex": Pricing(inputCostPerToken: 1.75e-6, outputCostPerToken: 1.4e-5, cacheReadInputCostPerToken: 1.75e-7, thresholdTokens: nil, inputCostPerTokenAboveThreshold: nil, outputCostPerTokenAboveThreshold: nil, cacheReadInputCostPerTokenAboveThreshold: nil),
        "gpt-5.2-pro": Pricing(inputCostPerToken: 2.1e-5, outputCostPerToken: 1.68e-4, cacheReadInputCostPerToken: nil, thresholdTokens: nil, inputCostPerTokenAboveThreshold: nil, outputCostPerTokenAboveThreshold: nil, cacheReadInputCostPerTokenAboveThreshold: nil),
        "gpt-5.3-codex": Pricing(inputCostPerToken: 1.75e-6, outputCostPerToken: 1.4e-5, cacheReadInputCostPerToken: 1.75e-7, thresholdTokens: nil, inputCostPerTokenAboveThreshold: nil, outputCostPerTokenAboveThreshold: nil, cacheReadInputCostPerTokenAboveThreshold: nil),
        "gpt-5.4": Pricing(inputCostPerToken: 2.5e-6, outputCostPerToken: 1.5e-5, cacheReadInputCostPerToken: 2.5e-7, thresholdTokens: 272_000, inputCostPerTokenAboveThreshold: 5e-6, outputCostPerTokenAboveThreshold: 2.25e-5, cacheReadInputCostPerTokenAboveThreshold: 5e-7, priorityInputCostPerToken: 5e-6, priorityOutputCostPerToken: 3e-5, priorityCacheReadInputCostPerToken: 5e-7),
        "gpt-5.4-mini": Pricing(inputCostPerToken: 7.5e-7, outputCostPerToken: 4.5e-6, cacheReadInputCostPerToken: 7.5e-8, thresholdTokens: nil, inputCostPerTokenAboveThreshold: nil, outputCostPerTokenAboveThreshold: nil, cacheReadInputCostPerTokenAboveThreshold: nil, priorityInputCostPerToken: 1.5e-6, priorityOutputCostPerToken: 9e-6, priorityCacheReadInputCostPerToken: 1.5e-7),
        "gpt-5.4-nano": Pricing(inputCostPerToken: 2e-7, outputCostPerToken: 1.25e-6, cacheReadInputCostPerToken: 2e-8, thresholdTokens: nil, inputCostPerTokenAboveThreshold: nil, outputCostPerTokenAboveThreshold: nil, cacheReadInputCostPerTokenAboveThreshold: nil),
        "gpt-5.4-pro": Pricing(inputCostPerToken: 3e-5, outputCostPerToken: 1.8e-4, cacheReadInputCostPerToken: nil, thresholdTokens: nil, inputCostPerTokenAboveThreshold: nil, outputCostPerTokenAboveThreshold: nil, cacheReadInputCostPerTokenAboveThreshold: nil),
        "gpt-5.5": Pricing(inputCostPerToken: 5e-6, outputCostPerToken: 3e-5, cacheReadInputCostPerToken: 5e-7, thresholdTokens: 272_000, inputCostPerTokenAboveThreshold: 1e-5, outputCostPerTokenAboveThreshold: 4.5e-5, cacheReadInputCostPerTokenAboveThreshold: 1e-6, priorityInputCostPerToken: 1.25e-5, priorityOutputCostPerToken: 7.5e-5, priorityCacheReadInputCostPerToken: 1.25e-6),
        "gpt-5.5-pro": Pricing(inputCostPerToken: 3e-5, outputCostPerToken: 1.8e-4, cacheReadInputCostPerToken: nil, thresholdTokens: nil, inputCostPerTokenAboveThreshold: nil, outputCostPerTokenAboveThreshold: nil, cacheReadInputCostPerTokenAboveThreshold: nil),
    ]

    static func estimatedCostUSD(
        model: String,
        totals: TokenTotals,
        mode: CodexTokenUsageMode
    ) -> Double? {
        guard let pricing = pricingByModel[model] else { return nil }
        let input = max(totals.inputTokens, 0)
        let cached = min(max(totals.cachedInputTokens, 0), input)
        let nonCached = max(input - cached, 0)
        let output = max(totals.outputTokens, 0)
        if mode == .priority,
           let priorityInputRate = pricing.priorityInputCostPerToken,
           let priorityOutputRate = pricing.priorityOutputCostPerToken {
            guard input <= 272_000 else { return nil }
            let priorityCachedRate = pricing.priorityCacheReadInputCostPerToken ?? priorityInputRate
            return Double(nonCached) * priorityInputRate
                + Double(cached) * priorityCachedRate
                + Double(output) * priorityOutputRate
        }

        let usesLongContextRates = pricing.thresholdTokens.map { input > $0 } ?? false
        let inputRate = usesLongContextRates
            ? pricing.inputCostPerTokenAboveThreshold ?? pricing.inputCostPerToken
            : pricing.inputCostPerToken
        let cachedRate = usesLongContextRates
            ? pricing.cacheReadInputCostPerTokenAboveThreshold
                ?? pricing.cacheReadInputCostPerToken
                ?? pricing.inputCostPerToken
            : pricing.cacheReadInputCostPerToken ?? pricing.inputCostPerToken
        let outputRate = usesLongContextRates
            ? pricing.outputCostPerTokenAboveThreshold ?? pricing.outputCostPerToken
            : pricing.outputCostPerToken

        return Double(nonCached) * inputRate
            + Double(cached) * cachedRate
            + Double(output) * outputRate
    }
}

private final class CodexForkBaselineResolver {
    private let sessionIndex: [String: URL]
    private unowned let scanner: CodexTokenActivityScanner
    private var snapshotsBySessionID: [String: [CodexTokenSnapshot]] = [:]
    private var missingSessionIDs = Set<String>()

    init(sessionIndex: [String: URL], scanner: CodexTokenActivityScanner) {
        self.sessionIndex = sessionIndex
        self.scanner = scanner
    }

    func baseline(parentSessionID: String, forkTimestamp: String?) -> TokenTotals? {
        guard let cutoff = scanner.parseTimestamp(forkTimestamp),
              let snapshots = snapshots(for: parentSessionID)
        else {
            return nil
        }

        return snapshots
            .filter { $0.timestamp <= cutoff }
            .max { $0.timestamp < $1.timestamp }?
            .totals
    }

    private func snapshots(for sessionID: String) -> [CodexTokenSnapshot]? {
        if let cached = snapshotsBySessionID[sessionID] {
            return cached
        }
        if missingSessionIDs.contains(sessionID) {
            return nil
        }
        guard let url = sessionIndex[sessionID] else {
            missingSessionIDs.insert(sessionID)
            return nil
        }

        let snapshots = scanner.parentTokenSnapshots(in: url)
        snapshotsBySessionID[sessionID] = snapshots
        return snapshots
    }
}

private struct CodexTokenActivityCache: Codable {
    var version: Int
    var historyDays: Int
    var calendarIdentifier: String
    var timeZoneIdentifier: String
    var roots: [String]
    var isComplete: Bool
    var files: [String: CodexTokenActivityFileCache]

    init(version: Int, historyDays: Int, calendar: Calendar, roots: [URL]) {
        self.version = version
        self.historyDays = historyDays
        calendarIdentifier = String(describing: calendar.identifier)
        timeZoneIdentifier = calendar.timeZone.identifier
        self.roots = roots.map(\.path).sorted()
        isComplete = false
        files = [:]
    }

    func isCompatible(version: Int, historyDays: Int, calendar: Calendar, roots: [URL]) -> Bool {
        self.version == version
            && self.historyDays >= historyDays
            && calendarIdentifier == String(describing: calendar.identifier)
            && timeZoneIdentifier == calendar.timeZone.identifier
            && self.roots == roots.map(\.path).sorted()
    }
}

private struct CodexTokenActivityFileCache: Codable {
    let size: Int64
    let mtimeUnixMs: Int64
    let parsedBytes: Int64?
    let baseline: TokenTotals?
    let rawBaseline: TokenTotals?
    let hasDivergentTotals: Bool?
    let sessionID: String?
    let forkedFromID: String?
    let forkTimestamp: String?
    let currentModel: String?
    let currentTurnID: String?
    let days: [String: CodexTokenActivityDayCache]
}

struct TokenTotals: Codable {
    static let zero = TokenTotals(
        inputTokens: 0,
        cachedInputTokens: 0,
        outputTokens: 0,
        reasoningOutputTokens: 0,
        totalTokens: 0
    )

    let inputTokens: Int
    let cachedInputTokens: Int
    let outputTokens: Int
    let reasoningOutputTokens: Int
    let totalTokens: Int?

    init?(usage: AgentTokenUsage?) {
        guard let usage else {
            return nil
        }

        self.init(
            inputTokens: usage.inputTokens ?? 0,
            cachedInputTokens: usage.cachedInputTokens ?? 0,
            outputTokens: usage.outputTokens ?? 0,
            reasoningOutputTokens: usage.reasoningOutputTokens ?? 0,
            totalTokens: usage.totalTokens
        )

        guard effectiveTotalTokens > 0 else {
            return nil
        }
    }

    init(
        inputTokens: Int,
        cachedInputTokens: Int,
        outputTokens: Int,
        reasoningOutputTokens: Int,
        totalTokens: Int?
    ) {
        self.inputTokens = max(inputTokens, 0)
        self.cachedInputTokens = max(cachedInputTokens, 0)
        self.outputTokens = max(outputTokens, 0)
        self.reasoningOutputTokens = max(reasoningOutputTokens, 0)
        self.totalTokens = totalTokens.map { max($0, 0) }
    }

    var effectiveTotalTokens: Int {
        inputTokens + outputTokens
    }

    var positive: TokenTotals? {
        effectiveTotalTokens > 0 ? self : nil
    }

    var agentTokenUsage: AgentTokenUsage {
        AgentTokenUsage(
            inputTokens: inputTokens,
            cachedInputTokens: cachedInputTokens,
            outputTokens: outputTokens,
            reasoningOutputTokens: reasoningOutputTokens,
            totalTokens: effectiveTotalTokens
        )
    }

    func delta(from baseline: TokenTotals) -> TokenTotals? {
        let delta = TokenTotals(
            inputTokens: inputTokens - baseline.inputTokens,
            cachedInputTokens: cachedInputTokens - baseline.cachedInputTokens,
            outputTokens: outputTokens - baseline.outputTokens,
            reasoningOutputTokens: reasoningOutputTokens - baseline.reasoningOutputTokens,
            totalTokens: nil
        )
        return delta.positive
    }

    func adding(_ other: TokenTotals) -> TokenTotals {
        TokenTotals(
            inputTokens: inputTokens + other.inputTokens,
            cachedInputTokens: cachedInputTokens + other.cachedInputTokens,
            outputTokens: outputTokens + other.outputTokens,
            reasoningOutputTokens: reasoningOutputTokens + other.reasoningOutputTokens,
            totalTokens: effectiveTotalTokens + other.effectiveTotalTokens
        )
    }

    func subtracting(_ other: TokenTotals) -> TokenTotals? {
        subtractingClamped(other).positive
    }

    func subtractingClamped(_ other: TokenTotals) -> TokenTotals {
        TokenTotals(
            inputTokens: inputTokens - other.inputTokens,
            cachedInputTokens: cachedInputTokens - other.cachedInputTokens,
            outputTokens: outputTokens - other.outputTokens,
            reasoningOutputTokens: reasoningOutputTokens - other.reasoningOutputTokens,
            totalTokens: nil
        )
    }

    func remaining(afterConsuming consumed: TokenTotals) -> TokenTotals? {
        let remaining = TokenTotals(
            inputTokens: inputTokens - consumed.inputTokens,
            cachedInputTokens: cachedInputTokens - consumed.cachedInputTokens,
            outputTokens: outputTokens - consumed.outputTokens,
            reasoningOutputTokens: reasoningOutputTokens - consumed.reasoningOutputTokens,
            totalTokens: effectiveTotalTokens - consumed.effectiveTotalTokens
        )
        return remaining.effectiveTotalTokens > 0 ? remaining : nil
    }

    static func equal(_ lhs: TokenTotals?, _ rhs: TokenTotals?) -> Bool {
        lhs?.inputTokens == rhs?.inputTokens
            && lhs?.cachedInputTokens == rhs?.cachedInputTokens
            && lhs?.outputTokens == rhs?.outputTokens
    }

    static func totalDelta(from baseline: TokenTotals?, to current: TokenTotals) -> TokenTotals {
        let baseline = baseline ?? .zero
        return current.subtractingClamped(baseline)
    }

    static func divergentTotalDelta(
        rawBaseline: TokenTotals?,
        countedBaseline: TokenTotals?,
        current: TokenTotals
    ) -> TokenTotals {
        let rawBaseline = rawBaseline ?? .zero
        let countedBaseline = countedBaseline ?? .zero

        func delta(raw: Int, counted: Int, current: Int) -> Int {
            if current >= raw {
                return max(0, current - raw)
            }
            return max(0, current - counted)
        }

        return TokenTotals(
            inputTokens: delta(raw: rawBaseline.inputTokens, counted: countedBaseline.inputTokens, current: current.inputTokens),
            cachedInputTokens: delta(
                raw: rawBaseline.cachedInputTokens,
                counted: countedBaseline.cachedInputTokens,
                current: current.cachedInputTokens
            ),
            outputTokens: delta(raw: rawBaseline.outputTokens, counted: countedBaseline.outputTokens, current: current.outputTokens),
            reasoningOutputTokens: 0,
            totalTokens: nil
        )
    }

    static func shouldPreferTotalDelta(
        rawBaseline: TokenTotals?,
        currentTotal: TokenTotals,
        totalDelta: TokenTotals,
        lastDelta: TokenTotals,
        sawDivergentTotals: Bool
    ) -> Bool {
        guard !sawDivergentTotals,
              let rawBaseline
        else {
            return false
        }
        return currentTotal.inputTokens >= rawBaseline.inputTokens
            && currentTotal.cachedInputTokens >= rawBaseline.cachedInputTokens
            && currentTotal.outputTokens >= rawBaseline.outputTokens
            && totalDelta.inputTokens <= lastDelta.inputTokens
            && totalDelta.cachedInputTokens <= lastDelta.cachedInputTokens
            && totalDelta.outputTokens <= lastDelta.outputTokens
    }

    static func minimum(_ lhs: TokenTotals, _ rhs: TokenTotals) -> TokenTotals {
        TokenTotals(
            inputTokens: min(lhs.inputTokens, rhs.inputTokens),
            cachedInputTokens: min(lhs.cachedInputTokens, rhs.cachedInputTokens),
            outputTokens: min(lhs.outputTokens, rhs.outputTokens),
            reasoningOutputTokens: min(lhs.reasoningOutputTokens, rhs.reasoningOutputTokens),
            totalTokens: min(lhs.effectiveTotalTokens, rhs.effectiveTotalTokens)
        )
    }
}

private final class CodexTokenActivityISO8601FormatterBox: @unchecked Sendable {
    let lock = NSLock()
    let withFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

private enum CodexTokenActivityTimestampParser {
    static let box = CodexTokenActivityISO8601FormatterBox()

    static func parseISO(_ text: String) -> Date? {
        if let date = parseCommonUTC(text) {
            return date
        }

        box.lock.lock()
        defer { box.lock.unlock() }
        return box.withFractional.date(from: text) ?? box.plain.date(from: text)
    }

    private static func parseCommonUTC(_ text: String) -> Date? {
        let bytes = Array(text.utf8)
        guard bytes.count >= 20,
              bytes[4] == 0x2D,
              bytes[7] == 0x2D,
              bytes[10] == 0x54,
              bytes[13] == 0x3A,
              bytes[16] == 0x3A
        else {
            return nil
        }

        let timezoneStart: Int
        if bytes[19] == 0x5A {
            timezoneStart = 19
        } else if bytes[19] == 0x2E {
            var cursor = 20
            while cursor < bytes.count,
                  bytes[cursor] >= 0x30,
                  bytes[cursor] <= 0x39 {
                cursor += 1
            }
            timezoneStart = cursor
        } else {
            return nil
        }

        guard timezoneStart < bytes.count,
              bytes[timezoneStart] == 0x5A,
              let year = integer(bytes, 0, 4),
              let month = integer(bytes, 5, 2),
              let day = integer(bytes, 8, 2),
              let hour = integer(bytes, 11, 2),
              let minute = integer(bytes, 14, 2),
              let second = integer(bytes, 17, 2),
              month >= 1,
              month <= 12,
              day >= 1,
              day <= 31,
              hour < 24,
              minute < 60,
              second < 61
        else {
            return nil
        }

        let days = daysFromCivil(year: year, month: month, day: day)
        let wholeSeconds = days * 86_400 + hour * 3_600 + minute * 60 + second
        return Date(timeIntervalSince1970: TimeInterval(wholeSeconds))
    }

    private static func integer(_ bytes: [UInt8], _ start: Int, _ count: Int) -> Int? {
        guard start >= 0,
              count > 0,
              start + count <= bytes.count
        else {
            return nil
        }

        var value = 0
        for index in start..<(start + count) {
            let byte = bytes[index]
            guard byte >= 0x30,
                  byte <= 0x39
            else {
                return nil
            }
            value = value * 10 + Int(byte - 0x30)
        }
        return value
    }

    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        var adjustedYear = year
        adjustedYear -= month <= 2 ? 1 : 0
        let era = (adjustedYear >= 0 ? adjustedYear : adjustedYear - 399) / 400
        let yearOfEra = adjustedYear - era * 400
        let monthPrime = month + (month > 2 ? -3 : 9)
        let dayOfYear = (153 * monthPrime + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }
}

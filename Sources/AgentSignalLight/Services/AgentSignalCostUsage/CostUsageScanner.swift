#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import AgentSignalLightCore
import Foundation

// swiftlint:disable type_body_length file_length
enum CostUsageScanner {
    typealias CancellationCheck = () throws -> Void

    static let log = AgentSignalCostUsageLog.logger(LogCategories.tokenCost)
    static let codexActiveSessionLookbackDays = 30
    static let costScale = 1_000_000_000.0

    enum ClaudeLogProviderFilter {
        case all
        case vertexAIOnly
        case excludeVertexAI
    }

    struct Options {
        var codexSessionsRoot: URL?
        var codexSessionsRoots: [URL]?
        var claudeProjectsRoots: [URL]?
        var cacheRoot: URL?
        var codexTraceDatabaseURL: URL?
        var refreshMinIntervalSeconds: TimeInterval = 60
        var claudeLogProviderFilter: ClaudeLogProviderFilter = .all
        /// Force a full rescan, ignoring per-file cache and incremental offsets.
        var forceRescan: Bool = false
        /// Test seam used to mutate a sessions tree between inventory capture
        /// and its final consistency validation.
        var codexInventoryBeforeCommitHook: (() -> Void)?
        /// Test seam used to mutate an existing file after inventory metadata
        /// has been captured but before the inventory is validated.
        var codexInventoryAfterMetadataHook: (() -> Void)?

        init(
            codexSessionsRoot: URL? = nil,
            codexSessionsRoots: [URL]? = nil,
            claudeProjectsRoots: [URL]? = nil,
            cacheRoot: URL? = nil,
            codexTraceDatabaseURL: URL? = nil,
            claudeLogProviderFilter: ClaudeLogProviderFilter = .all,
            forceRescan: Bool = false)
        {
            self.codexSessionsRoot = codexSessionsRoot
            self.codexSessionsRoots = codexSessionsRoots
            self.claudeProjectsRoots = claudeProjectsRoots
            self.cacheRoot = cacheRoot
            self.codexTraceDatabaseURL = codexTraceDatabaseURL
            self.claudeLogProviderFilter = claudeLogProviderFilter
            self.forceRescan = forceRescan
        }
    }

    struct CodexParseResult {
        let days: [String: [String: [Int]]]
        var parsedBytes: Int64
        let lastModel: String?
        let lastTotals: CostUsageCodexTotals?
        let lastCountedTotals: CostUsageCodexTotals?
        let lastRawTotalsBaseline: CostUsageCodexTotals?
        let hasDivergentTotals: Bool
        let lastCodexTurnID: String?
        let sessionId: String?
        let forkedFromId: String?
        let lastTokenEventEndOffset: Int64?
        let lastTokenEventFingerprint: String?
        let lastTokenEventTimestamp: Date?
        let lastTokenEventTotalTokens: Int?
        let tokenEventWatermarks: [CostUsageTokenEventWatermark]
        let rows: [CodexUsageRow]
    }

    struct CodexUsageRow: Codable, Equatable {
        let day: String
        let model: String
        let turnID: String?
        let input: Int
        let cached: Int
        let output: Int
    }

    struct CodexScanState {
        var seenSessionIds: Set<String> = []
        var seenFileIds: Set<String> = []
    }

    private struct CodexTimestampedTotals {
        let timestamp: String
        let date: Date?
        let totals: CostUsageCodexTotals
    }

    enum CodexForkBaseline {
        case resolved(CostUsageCodexTotals?)
        case unresolved
    }

    private static func codexTotalsEqual(_ lhs: CostUsageCodexTotals?, _ rhs: CostUsageCodexTotals?) -> Bool {
        lhs?.input == rhs?.input && lhs?.cached == rhs?.cached && lhs?.output == rhs?.output
    }

    private static func codexTotalsAtLeast(_ lhs: CostUsageCodexTotals, _ rhs: CostUsageCodexTotals) -> Bool {
        lhs.input >= rhs.input && lhs.cached >= rhs.cached && lhs.output >= rhs.output
    }

    private static func codexTotalsAtMost(_ lhs: CostUsageCodexTotals, _ rhs: CostUsageCodexTotals) -> Bool {
        lhs.input <= rhs.input && lhs.cached <= rhs.cached && lhs.output <= rhs.output
    }

    private static func codexShouldPreferTotalDelta(
        rawBaseline: CostUsageCodexTotals?,
        currentTotal: CostUsageCodexTotals,
        totalDelta: CostUsageCodexTotals,
        lastDelta: CostUsageCodexTotals,
        sawDivergentTotals: Bool) -> Bool
    {
        guard !sawDivergentTotals, let rawBaseline else { return false }
        return Self.codexTotalsAtLeast(currentTotal, rawBaseline)
            && Self.codexTotalsAtMost(totalDelta, lastDelta)
    }

    private static func codexAddTotals(
        _ lhs: CostUsageCodexTotals,
        _ rhs: CostUsageCodexTotals) -> CostUsageCodexTotals
    {
        CostUsageCodexTotals(
            input: lhs.input + rhs.input,
            cached: lhs.cached + rhs.cached,
            output: lhs.output + rhs.output)
    }

    private static func codexMinTotals(
        _ lhs: CostUsageCodexTotals,
        _ rhs: CostUsageCodexTotals) -> CostUsageCodexTotals
    {
        CostUsageCodexTotals(
            input: min(lhs.input, rhs.input),
            cached: min(lhs.cached, rhs.cached),
            output: min(lhs.output, rhs.output))
    }

    private static func codexTotalDelta(
        from baseline: CostUsageCodexTotals?,
        to current: CostUsageCodexTotals) -> CostUsageCodexTotals
    {
        let baseline = baseline ?? .init(input: 0, cached: 0, output: 0)
        return CostUsageCodexTotals(
            input: max(0, current.input - baseline.input),
            cached: max(0, current.cached - baseline.cached),
            output: max(0, current.output - baseline.output))
    }

    private static func codexDivergentTotalDelta(
        rawBaseline: CostUsageCodexTotals?,
        countedBaseline: CostUsageCodexTotals?,
        current: CostUsageCodexTotals) -> CostUsageCodexTotals
    {
        let rawBaseline = rawBaseline ?? .init(input: 0, cached: 0, output: 0)
        let countedBaseline = countedBaseline ?? .init(input: 0, cached: 0, output: 0)

        func delta(raw: Int, counted: Int, current: Int) -> Int {
            if current >= raw {
                return max(0, current - raw)
            }
            return max(0, current - counted)
        }

        return CostUsageCodexTotals(
            input: delta(raw: rawBaseline.input, counted: countedBaseline.input, current: current.input),
            cached: delta(raw: rawBaseline.cached, counted: countedBaseline.cached, current: current.cached),
            output: delta(raw: rawBaseline.output, counted: countedBaseline.output, current: current.output))
    }

    struct CodexScanResources {
        let fileIndex: CodexSessionFileIndex
        let inheritedResolver: CodexInheritedTotalsResolver
        let modelsDevCatalog: ModelsDevCatalog?
        let modelsDevCacheRoot: URL?
        let priorityTurns: [String: CodexPriorityTurnMetadata]
    }

    struct CodexFileScanContext {
        let range: CostUsageDayRange
        let through: Date
        let forceFullScan: Bool
        let dropDeferredCodexRows: Bool
        let requiresTurnIDCache: Bool
        let changedPriorityTurnIDs: Set<String>
        let resources: CodexScanResources
        let checkCancellation: CancellationCheck?
    }

    struct CodexRefreshPlan {
        let refreshMs: Int64
        let roots: [URL]
        let rootsFingerprint: [String: Int64]
        let rootsChanged: Bool
        let needsSessionInventory: Bool
        let windowExpanded: Bool
        let needsCostCacheMigration: Bool
        let modelsDevCatalog: ModelsDevCatalog?
        let codexPricingKey: String
        let codexPriorityMetadataKey: String
        let hasPriorityMetadata: Bool
        let priorityTurns: [String: CodexPriorityTurnMetadata]
        let priorityTurnKeys: [String: String]
        let priorityTurnIDsByDay: [String: [String]]
        let pricingChanged: Bool
        let priorityMetadataChanged: Bool
        let priorityTurnsChanged: Bool
        let needsTurnIDCacheMigration: Bool
        let changedPriorityTurnIDs: Set<String>
        let shouldRefresh: Bool
    }

    final class CodexSessionFileIndex {
        private let files: [URL]
        private let filePaths: Set<String>
        private let roots: [URL]
        private let checkCancellation: CancellationCheck?
        private var nextUnindexedFile = 0
        private var didIndexRoots = false
        private var fileURLBySessionId: [String: URL] = [:]
        private var missingSessionIds: Set<String> = []

        init(
            files: [URL],
            roots: [URL],
            cachedSessionFiles: [String: URL] = [:],
            checkCancellation: CancellationCheck? = nil)
        {
            self.files = files
            self.filePaths = Set(files.map(\.path))
            self.roots = roots
            self.fileURLBySessionId = cachedSessionFiles
            self.checkCancellation = checkCancellation
        }

        func remember(fileURL: URL, sessionId: String?) {
            guard let sessionId, !sessionId.isEmpty else { return }
            self.fileURLBySessionId[sessionId] = fileURL
        }

        func fileURL(for sessionId: String) throws -> URL? {
            if let cached = self.fileURLBySessionId[sessionId] {
                return cached
            }
            if self.missingSessionIds.contains(sessionId) {
                return nil
            }

            while self.nextUnindexedFile < self.files.count {
                try self.checkCancellation?()
                let fileURL = self.files[self.nextUnindexedFile]
                self.nextUnindexedFile += 1
                guard let indexedSessionId = try CostUsageScanner.parseCodexSessionIdentifier(
                    fileURL: fileURL,
                    checkCancellation: self.checkCancellation)
                else {
                    continue
                }
                self.fileURLBySessionId[indexedSessionId] = fileURL
                if indexedSessionId == sessionId {
                    return fileURL
                }
            }

            if !self.didIndexRoots {
                try self.indexRoots()
                if let indexed = self.fileURLBySessionId[sessionId] {
                    return indexed
                }
            }

            self.missingSessionIds.insert(sessionId)
            return nil
        }

        private func indexRoots() throws {
            self.didIndexRoots = true
            guard !self.roots.isEmpty else { return }
            for root in self.roots {
                try self.checkCancellation?()
                guard let enumerator = FileManager.default.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants])
                else { continue }

                while let fileURL = enumerator.nextObject() as? URL {
                    try self.checkCancellation?()
                    guard fileURL.pathExtension.lowercased() == "jsonl" else { continue }
                    guard !self.filePaths.contains(fileURL.path) else { continue }
                    guard let indexedSessionId = try CostUsageScanner.parseCodexSessionIdentifier(
                        fileURL: fileURL,
                        checkCancellation: self.checkCancellation)
                    else {
                        continue
                    }
                    self.fileURLBySessionId[indexedSessionId] = fileURL
                }
            }
        }
    }

    final class CodexInheritedTotalsResolver {
        private let fileIndex: CodexSessionFileIndex
        private let checkCancellation: CancellationCheck?
        private var snapshotsBySessionId: [String: [CodexTimestampedTotals]] = [:]

        init(fileIndex: CodexSessionFileIndex, checkCancellation: CancellationCheck?) {
            self.fileIndex = fileIndex
            self.checkCancellation = checkCancellation
        }

        func inheritedTotals(for sessionId: String, atOrBefore cutoffTimestamp: String) throws -> CodexForkBaseline {
            guard !cutoffTimestamp.isEmpty else {
                CostUsageScanner.log.warning(
                    "Codex cost usage fork timestamp missing; treating parent baseline as unresolved",
                    metadata: ["sessionId": sessionId])
                return .unresolved
            }
            let cutoffDate = CostUsageScanner.dateFromTimestamp(cutoffTimestamp)
            if cutoffDate == nil {
                CostUsageScanner.log.warning(
                    "Codex cost usage could not parse fork timestamp; falling back to lexical comparison",
                    metadata: ["sessionId": sessionId, "timestamp": cutoffTimestamp])
            }
            guard let snapshots = try self.snapshots(for: sessionId) else { return .unresolved }
            var inherited: CostUsageCodexTotals?
            for snapshot in snapshots {
                let isAtOrBefore: Bool = if let snapshotDate = snapshot.date, let cutoffDate {
                    snapshotDate <= cutoffDate
                } else {
                    snapshot.timestamp <= cutoffTimestamp
                }
                if isAtOrBefore {
                    inherited = snapshot.totals
                }
            }
            return .resolved(inherited)
        }

        private func snapshots(for sessionId: String) throws -> [CodexTimestampedTotals]? {
            if let cached = self.snapshotsBySessionId[sessionId] {
                return cached
            }
            try self.checkCancellation?()
            guard let fileURL = try self.fileIndex.fileURL(for: sessionId) else {
                CostUsageScanner.log.warning(
                    "Codex cost usage parent session file not found",
                    metadata: ["sessionId": sessionId])
                return nil
            }
            let parsed = try CostUsageScanner.parseCodexTokenSnapshots(
                fileURL: fileURL,
                checkCancellation: self.checkCancellation)
            guard let parsedSessionId = parsed.sessionId else {
                CostUsageScanner.log.warning(
                    "Codex cost usage parent session missing session metadata",
                    metadata: ["sessionId": sessionId, "path": fileURL.path])
                return nil
            }
            if parsedSessionId != sessionId {
                CostUsageScanner.log.warning(
                    "Codex cost usage parent session resolved to mismatched session id",
                    metadata: [
                        "requestedSessionId": sessionId,
                        "resolvedSessionId": parsedSessionId,
                        "path": fileURL.path,
                    ])
                return nil
            }
            self.snapshotsBySessionId[sessionId] = parsed.snapshots
            return parsed.snapshots
        }
    }

    struct ClaudeParseResult {
        let days: [String: [String: [Int]]]
        let rows: [ClaudeUsageRow]
        let parsedBytes: Int64
    }

    enum ClaudePathRole: String, Codable {
        case parent
        case subagent
    }

    struct ClaudeUsageRow: Codable {
        let dayKey: String
        let model: String
        let sessionId: String?
        let messageId: String?
        let requestId: String?
        let timestampUnixMs: Int64?
        let isSidechain: Bool
        let pathRole: ClaudePathRole
        let input: Int
        let cacheRead: Int
        let cacheCreate: Int
        let cacheCreate1h: Int?
        let output: Int
        let costNanos: Int
        let costPriced: Bool?
    }

    static func loadDailyReport(
        provider: UsageProvider,
        since: Date,
        until: Date,
        now: Date = Date(),
        options: Options = Options()) -> CostUsageDailyReport
    {
        (
            try? self.loadDailyReportCancellable(
                provider: provider,
                since: since,
                until: until,
                now: now,
                options: options,
                checkCancellation: nil)) ?? CostUsageDailyReport(data: [], summary: nil)
    }

    static func loadDailyReportCancellable(
        provider: UsageProvider,
        since: Date,
        until: Date,
        now: Date = Date(),
        options: Options = Options(),
        checkCancellation: CancellationCheck?) throws -> CostUsageDailyReport
    {
        let range = CostUsageDayRange(since: since, until: until)
        let emptyReport = CostUsageDailyReport(data: [], summary: nil)
        try checkCancellation?()

        switch provider {
        case .codex:
            return try self.loadCodexDaily(
                range: range,
                now: now,
                options: options,
                checkCancellation: checkCancellation)
        case .claude:
            return try self.loadClaudeDaily(
                provider: .claude,
                range: range,
                now: now,
                options: options,
                checkCancellation: checkCancellation)
        case .vertexai:
            var filtered = options
            if filtered.claudeLogProviderFilter == .all {
                filtered.claudeLogProviderFilter = .vertexAIOnly
            }
            return try self.loadClaudeDaily(
                provider: .vertexai,
                range: range,
                now: now,
                options: filtered,
                checkCancellation: checkCancellation)
        case .openai, .azureopenai, .zai, .gemini, .antigravity, .cursor, .opencode, .opencodego, .alibaba,
             .alibabatokenplan, .factory,
             .copilot, .devin, .minimax, .manus, .kilo, .kiro, .kimi, .kimik2, .moonshot, .augment, .jetbrains, .amp,
             .ollama, .t3chat, .synthetic, .openrouter, .elevenlabs, .warp, .perplexity, .mimo, .doubao, .abacus,
             .mistral, .deepseek, .codebuff, .crof, .windsurf, .zed, .venice, .commandcode, .stepfun, .bedrock, .grok,
             .groq, .llmproxy, .litellm, .deepgram, .poe, .chutes:
            return emptyReport
        }
    }

    // MARK: - Day keys

    struct CostUsageDayRange {
        let sinceKey: String
        let untilKey: String
        let scanSinceKey: String
        let scanUntilKey: String

        init(since: Date, until: Date) {
            self.sinceKey = Self.dayKey(from: since)
            self.untilKey = Self.dayKey(from: until)
            self.scanSinceKey = Self.dayKey(from: Calendar.current.date(byAdding: .day, value: -1, to: since) ?? since)
            self.scanUntilKey = Self.dayKey(from: Calendar.current.date(byAdding: .day, value: 1, to: until) ?? until)
        }

        static func dayKey(from date: Date) -> String {
            let cal = Calendar.current
            let comps = cal.dateComponents([.year, .month, .day], from: date)
            let y = comps.year ?? 1970
            let m = comps.month ?? 1
            let d = comps.day ?? 1
            return String(format: "%04d-%02d-%02d", y, m, d)
        }

        static func isInRange(dayKey: String, since: String, until: String) -> Bool {
            if dayKey < since { return false }
            if dayKey > until { return false }
            return true
        }
    }

    // MARK: - Codex

    private static func defaultCodexSessionsRoot(options: Options) -> URL {
        if let override = options.codexSessionsRoot { return override }
        let env = ProcessInfo.processInfo.environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let env, !env.isEmpty {
            return URL(fileURLWithPath: env).appendingPathComponent("sessions", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    private static func codexSessionsRoots(options: Options) -> [URL] {
        let candidateRoots: [URL]
        if let explicitRoots = options.codexSessionsRoots, !explicitRoots.isEmpty {
            candidateRoots = explicitRoots
        } else {
            let root = self.defaultCodexSessionsRoot(options: options)
            if let archived = self.codexArchivedSessionsRoot(sessionsRoot: root) {
                candidateRoots = [root, archived]
            } else {
                candidateRoots = [root]
            }
        }

        // Cache keys, containment checks and token cursors all use canonical
        // paths. Re-resolving here on every refresh also turns a symlink
        // retarget into a roots fingerprint change.
        var seen = Set<String>()
        return candidateRoots.compactMap { root in
            let canonical = root.standardizedFileURL.resolvingSymlinksInPath()
            return seen.insert(canonical.path).inserted ? canonical : nil
        }
    }

    private static func codexArchivedSessionsRoot(sessionsRoot: URL) -> URL? {
        guard sessionsRoot.lastPathComponent == "sessions" else { return nil }
        return sessionsRoot
            .deletingLastPathComponent()
            .appendingPathComponent("archived_sessions", isDirectory: true)
    }

    private static func listCodexSessionFiles(
        root: URL,
        scanSinceKey: String,
        scanUntilKey: String,
        includeRecursive: Bool) throws -> [URL]
    {
        let partitioned = try self.listCodexSessionFilesByDatePartition(
            root: root,
            scanSinceKey: scanSinceKey,
            scanUntilKey: scanUntilKey)
        let flat = try self.listCodexSessionFilesFlat(
            root: root,
            scanSinceKey: scanSinceKey,
            scanUntilKey: scanUntilKey
        )
        let recursive = includeRecursive ? try self.listCodexLegacySessionFilesRecursive(root: root) : []
        var seen: Set<String> = []
        var out: [URL] = []
        for item in partitioned + flat + recursive where !seen.contains(item.path) {
            seen.insert(item.path)
            out.append(item)
        }
        return out
    }

    private static func cachedCodexSessionFiles(
        cache: CostUsageCache,
        range: CostUsageDayRange,
        roots: [URL],
        excludingPaths: Set<String>) -> [URL]
    {
        cache.files.compactMap { path, usage in
            guard !excludingPaths.contains(path) else { return nil }
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            let fileURL = URL(fileURLWithPath: path)
            guard Self.isWithinCodexRoots(fileURL: fileURL, roots: roots) else { return nil }

            let hasRelevantDay = usage.days.keys.contains {
                CostUsageDayRange.isInRange(dayKey: $0, since: range.scanSinceKey, until: range.scanUntilKey)
            }
            let metadata = Self.codexFileMetadata(fileURL: fileURL)
            let currentGeneration = metadata.fileId
                ?? fileURL.standardizedFileURL.resolvingSymlinksInPath().path
            let cachedParsedBytes = usage.parsedBytes ?? usage.size
            let changedOrDeferred = usage.sourceGeneration != currentGeneration
                || usage.sourceStatFingerprint != metadata.statFingerprint
                || usage.sourceChangeTimeNanoseconds != metadata.changeTimeNanoseconds
                || usage.mtimeUnixMs != metadata.mtimeUnixMs
                || usage.size != metadata.size
                || cachedParsedBytes < metadata.size
            // A rollout can remain open for months. If an old cached file is
            // appended today, its historical contribution may be outside the
            // current window, but the new bytes still have to be scanned.
            guard hasRelevantDay || changedOrDeferred else { return nil }
            return fileURL
        }
    }

    private static func cachedCodexSessionIndex(
        cache: CostUsageCache,
        roots: [URL],
        knownExistingPaths: Set<String>) -> [String: URL]
    {
        var out: [String: URL] = [:]
        for (path, usage) in cache.files {
            guard usage.codexInventoryOnly != true else { continue }
            guard let sessionId = usage.sessionId, !sessionId.isEmpty else { continue }
            if knownExistingPaths.contains(path) {
                out[sessionId] = URL(fileURLWithPath: path)
                continue
            }
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let fileURL = URL(fileURLWithPath: path)
            guard Self.isWithinCodexRoots(fileURL: fileURL, roots: roots) else { continue }
            out[sessionId] = fileURL
        }
        return out
    }

    private static func codexRootsFingerprint(_ roots: [URL]) -> [String: Int64] {
        var out: [String: Int64] = [:]
        for root in roots {
            let canonical = root.standardizedFileURL.resolvingSymlinksInPath()
            let metadata = Self.codexFileMetadata(fileURL: canonical)
            let identity = metadata.fileId ?? "missing"
            out["\(canonical.path)|\(identity)"] =
                (try? Self.codexDirectoryFingerprint(at: canonical)) ?? -1
        }
        return out
    }

    static func codexRootsFingerprint(options: Options) -> [String: Int64] {
        self.codexRootsFingerprint(self.codexSessionsRoots(options: options))
    }

    private static func codexPricingKey(modelsDevArtifact: ModelsDevCacheArtifact?) -> String {
        let builtInFingerprint = CostUsagePricing.codexBuiltInPricingFingerprint()
        let builtInHash = Self.sha256Hex(Data(builtInFingerprint.utf8))
        guard let modelsDevArtifact else {
            return "builtin-\(builtInHash)"
        }
        let modelsDevFingerprint = self.modelsDevPricingFingerprint(modelsDevArtifact.catalog)
        let modelsDevHash = Self.sha256Hex(Data(modelsDevFingerprint.utf8))
        return "models-dev-v\(modelsDevArtifact.version)-\(modelsDevHash)-builtin-\(builtInHash)"
    }

    private static func modelsDevPricingFingerprint(_ catalog: ModelsDevCatalog) -> String {
        var parts: [String] = []
        for providerID in catalog.providers.keys.sorted() {
            guard let provider = catalog.providers[providerID] else { continue }
            parts.append("provider=\(providerID)|\(provider.id ?? "")")
            for modelKey in provider.models.keys.sorted() {
                guard let model = provider.models[modelKey] else { continue }
                let cost = model.cost
                let contextOver200K = cost?.contextOver200K
                parts.append([
                    "model=\(modelKey)",
                    model.id,
                    Self.optionalDoubleFingerprint(cost?.input),
                    Self.optionalDoubleFingerprint(cost?.output),
                    Self.optionalDoubleFingerprint(cost?.cacheRead),
                    Self.optionalDoubleFingerprint(cost?.cacheWrite),
                    Self.optionalDoubleFingerprint(contextOver200K?.input),
                    Self.optionalDoubleFingerprint(contextOver200K?.output),
                    Self.optionalDoubleFingerprint(contextOver200K?.cacheRead),
                    Self.optionalDoubleFingerprint(contextOver200K?.cacheWrite),
                    model.limit?.context.map(String.init) ?? "nil",
                ].joined(separator: "|"))
            }
        }
        return parts.joined(separator: "\n")
    }

    private static func optionalDoubleFingerprint(_ value: Double?) -> String {
        guard let value else { return "nil" }
        return String(format: "%.17g", value)
    }

    private static func codexPriorityMetadataKey(databaseURL: URL?) -> String {
        let url = databaseURL ?? self.defaultCodexPriorityDatabaseURL()
        let path = url.standardizedFileURL.path
        return FileManager.default.fileExists(atPath: path) ? "sqlite:\(path)" : "missing:\(path)"
    }

    private static func codexPriorityMetadataChanged(old: String?, new: String) -> Bool {
        guard let old, old != new else { return false }
        return new.hasPrefix("sqlite:")
    }

    private static func codexPriorityTurnKeys(
        _ priorityTurns: [String: CodexPriorityTurnMetadata]) -> [String: String]
    {
        var partsByDay: [String: [String]] = [:]
        for (turnID, turn) in priorityTurns {
            guard let dayKey = self.codexPriorityDayKey(turn) else { continue }
            partsByDay[dayKey, default: []].append([
                turnID,
                turn.model ?? "",
                turn.timestamp ?? "",
                turn.threadID ?? "",
            ].joined(separator: "|"))
        }
        var out: [String: String] = [:]
        for (dayKey, parts) in partsByDay {
            out[dayKey] = self.sha256Hex(Data(parts.sorted().joined(separator: "\n").utf8))
        }
        return out
    }

    private static func codexPriorityTurnIDsByDay(
        _ priorityTurns: [String: CodexPriorityTurnMetadata]) -> [String: [String]]
    {
        var out: [String: Set<String>] = [:]
        for (turnID, turn) in priorityTurns {
            guard let dayKey = self.codexPriorityDayKey(turn) else { continue }
            out[dayKey, default: []].insert(turnID)
        }
        return out.mapValues { $0.sorted() }
    }

    private static func codexPriorityDayKey(_ turn: CodexPriorityTurnMetadata) -> String? {
        guard let timestamp = turn.timestamp else { return nil }
        let dayKeyFromEpoch = Int64(timestamp).map {
            CostUsageDayRange.dayKey(from: Date(timeIntervalSince1970: TimeInterval($0)))
        }
        return dayKeyFromEpoch ?? self.dayKeyFromTimestamp(timestamp) ?? self.dayKeyFromParsedISO(timestamp)
    }

    private static func codexPriorityTurnKeysChanged(
        old: [String: String]?,
        new: [String: String],
        range: CostUsageDayRange) -> Bool
    {
        for dayKey in self.dayKeys(sinceKey: range.scanSinceKey, untilKey: range.scanUntilKey)
            where old?[dayKey] != new[dayKey]
        {
            return true
        }
        return false
    }

    private static func changedPriorityTurnIDs(
        old: [String: [String]]?,
        new: [String: [String]],
        oldKeys: [String: String]?,
        newKeys: [String: String],
        range: CostUsageDayRange) -> Set<String>
    {
        var out = Set<String>()
        for dayKey in self.dayKeys(sinceKey: range.scanSinceKey, untilKey: range.scanUntilKey) {
            let oldIDs = Set(old?[dayKey] ?? [])
            let newIDs = Set(new[dayKey] ?? [])
            if oldIDs != newIDs || oldKeys?[dayKey] != newKeys[dayKey] {
                out.formUnion(oldIDs)
                out.formUnion(newIDs)
            }
        }
        return out
    }

    private static func mergePriorityTurnKeys(
        existing: [String: String]?,
        new: [String: String],
        range: CostUsageDayRange,
        retainedSinceKey: String,
        retainedUntilKey: String) -> [String: String]?
    {
        var out = existing ?? [:]
        for dayKey in self.dayKeys(sinceKey: range.scanSinceKey, untilKey: range.scanUntilKey) {
            out[dayKey] = new[dayKey]
        }
        out = out.filter { key, _ in
            CostUsageDayRange.isInRange(dayKey: key, since: retainedSinceKey, until: retainedUntilKey)
        }
        return out.isEmpty ? nil : out
    }

    private static func mergePriorityTurnIDsByDay(
        existing: [String: [String]]?,
        new: [String: [String]],
        range: CostUsageDayRange,
        retainedSinceKey: String,
        retainedUntilKey: String) -> [String: [String]]?
    {
        var out = existing ?? [:]
        for dayKey in self.dayKeys(sinceKey: range.scanSinceKey, untilKey: range.scanUntilKey) {
            out[dayKey] = new[dayKey] ?? []
        }
        out = out.filter { key, _ in
            CostUsageDayRange.isInRange(dayKey: key, since: retainedSinceKey, until: retainedUntilKey)
        }
        return out.isEmpty ? nil : out
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private struct CodexSessionInventoryFile {
        let url: URL
        let metadata: CodexFileMetadata
        let sessionId: String?
        let forkedFromId: String?
    }

    private struct CodexSessionInventory {
        let files: [CodexSessionInventoryFile]
        let directoryFingerprints: [String: Int64]
    }

    private struct CodexDuplicateCurrentCopy {
        let path: String
        let url: URL
        let cached: CostUsageFileUsage
        let metadata: CodexFileMetadata
        let currentSessionId: String
        let currentForkedFromId: String?
        let changed: Bool
    }

    private struct CodexDuplicateReconciliation {
        let scanURLs: [URL]
        let quarantinedPaths: Set<String>
    }

    enum CodexInventoryError: Error {
        case changedDuringEnumeration
        case ambiguousDuplicateSession(String)
    }

    enum CodexFilePrefixRelationship {
        case identical
        case lhsIsPrefix
        case rhsIsPrefix
        case divergent
    }

    static func codexStableStatFingerprint(_ info: stat) -> Int64 {
        #if os(Linux)
        let modifiedSeconds = Int64(info.st_mtim.tv_sec)
        let modifiedNanoseconds = Int64(info.st_mtim.tv_nsec)
        let changedSeconds = Int64(info.st_ctim.tv_sec)
        let changedNanoseconds = Int64(info.st_ctim.tv_nsec)
        let createdSeconds: Int64 = 0
        let createdNanoseconds: Int64 = 0
        #else
        let modifiedSeconds = Int64(info.st_mtimespec.tv_sec)
        let modifiedNanoseconds = Int64(info.st_mtimespec.tv_nsec)
        let changedSeconds = Int64(info.st_ctimespec.tv_sec)
        let changedNanoseconds = Int64(info.st_ctimespec.tv_nsec)
        let createdSeconds = Int64(info.st_birthtimespec.tv_sec)
        let createdNanoseconds = Int64(info.st_birthtimespec.tv_nsec)
        #endif
        var hash: UInt64 = 14_695_981_039_346_656_037
        func mix(_ value: Int64) {
            hash ^= UInt64(bitPattern: value)
            hash &*= 1_099_511_628_211
        }
        mix(Int64(info.st_dev))
        mix(Int64(info.st_ino))
        mix(Int64(info.st_mode))
        mix(modifiedSeconds)
        mix(modifiedNanoseconds)
        mix(changedSeconds)
        mix(changedNanoseconds)
        mix(createdSeconds)
        mix(createdNanoseconds)
        return Int64(bitPattern: hash)
    }

    private static func codexDirectoryFingerprint(at url: URL) throws -> Int64 {
        var info = stat()
        let result = url.path.withCString { lstat($0, &info) }
        if result != 0 {
            if errno == ENOENT { return -1 }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return Self.codexStableStatFingerprint(info)
    }

    private static func currentCodexDirectoryFingerprints(
        paths: Dictionary<String, Int64>.Keys
    ) throws -> [String: Int64] {
        var result: [String: Int64] = [:]
        for path in paths {
            result[path] = try self.codexDirectoryFingerprint(at: URL(fileURLWithPath: path))
        }
        return result
    }

    private static func inventoryCodexSessionFiles(
        roots: [URL],
        afterMetadataHook: (() -> Void)?,
        checkCancellation: CancellationCheck?
    ) throws -> CodexSessionInventory {
        var rawFiles: [(url: URL, metadata: CodexFileMetadata)] = []
        var directoryFingerprints: [String: Int64] = [:]
        var seenPaths = Set<String>()

        for root in roots {
            try checkCancellation?()
            let normalizedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
            directoryFingerprints[normalizedRoot.path] = try self.codexDirectoryFingerprint(at: normalizedRoot)
            guard FileManager.default.fileExists(atPath: normalizedRoot.path) else { continue }

            var enumerationError: Error?
            guard let enumerator = FileManager.default.enumerator(
                at: normalizedRoot,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, error in
                    enumerationError = error
                    return false
                }
            ) else {
                throw NSError(
                    domain: NSCocoaErrorDomain,
                    code: NSFileReadUnknownError,
                    userInfo: [NSFilePathErrorKey: normalizedRoot.path]
                )
            }

            while let item = enumerator.nextObject() as? URL {
                try checkCancellation?()
                let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
                if values.isDirectory == true {
                    let normalizedDirectory = item.standardizedFileURL.resolvingSymlinksInPath()
                    directoryFingerprints[normalizedDirectory.path] = try self.codexDirectoryFingerprint(
                        at: normalizedDirectory
                    )
                    continue
                }
                guard values.isRegularFile == true,
                      item.pathExtension.lowercased() == "jsonl"
                else { continue }

                let metadata = Self.codexFileMetadata(fileURL: item)
                guard metadata.fileId != nil else {
                    throw NSError(
                        domain: NSCocoaErrorDomain,
                        code: NSFileReadUnknownError,
                        userInfo: [NSFilePathErrorKey: item.path]
                    )
                }
                guard seenPaths.insert(metadata.path).inserted else { continue }
                rawFiles.append((url: item, metadata: metadata))
            }
            if let enumerationError { throw enumerationError }
        }

        var files: [CodexSessionInventoryFile] = []
        files.reserveCapacity(rawFiles.count)
        for rawFile in rawFiles {
            try checkCancellation?()
            let sessionMetadata = try Self.parseCodexSessionMetadata(
                fileURL: rawFile.url,
                checkCancellation: checkCancellation
            )
            files.append(CodexSessionInventoryFile(
                url: rawFile.url,
                metadata: rawFile.metadata,
                sessionId: sessionMetadata?.sessionId,
                forkedFromId: sessionMetadata?.forkedFromId
            ))
        }

        afterMetadataHook?()

        // Do not commit a mixed inventory if a directory changed while it was
        // being walked. An append to an existing generation is allowed: its
        // captured size remains a safe lower frontier and the normal scan path
        // will consume the appended bytes now or on the next refresh.
        guard try Self.currentCodexDirectoryFingerprints(paths: directoryFingerprints.keys)
            == directoryFingerprints
        else {
            throw CodexInventoryError.changedDuringEnumeration
        }
        for file in files {
            let current = Self.codexFileMetadata(fileURL: file.url)
            guard current.fileId == file.metadata.fileId else {
                throw CodexInventoryError.changedDuringEnumeration
            }
        }

        return CodexSessionInventory(
            files: files,
            directoryFingerprints: directoryFingerprints
        )
    }

    static func codexFilePrefixRelationship(
        lhsURL: URL,
        rhsURL: URL,
        checkCancellation: CancellationCheck?
    ) throws -> CodexFilePrefixRelationship {
        let lhsStart = Self.codexFileMetadata(fileURL: lhsURL)
        let rhsStart = Self.codexFileMetadata(fileURL: rhsURL)
        guard lhsStart.fileId != nil, rhsStart.fileId != nil else {
            throw CodexInventoryError.changedDuringEnumeration
        }
        let lhsFingerprint = try Self.codexDirectoryFingerprint(at: lhsURL)
        let rhsFingerprint = try Self.codexDirectoryFingerprint(at: rhsURL)

        try checkCancellation?()
        let lhsHandle = try FileHandle(forReadingFrom: lhsURL)
        defer { try? lhsHandle.close() }
        let rhsHandle = try FileHandle(forReadingFrom: rhsURL)
        defer { try? rhsHandle.close() }
        try checkCancellation?()

        let lhsDescriptorStart = Self.codexFileMetadata(
            fileDescriptor: lhsHandle.fileDescriptor,
            path: lhsURL.path
        )
        let rhsDescriptorStart = Self.codexFileMetadata(
            fileDescriptor: rhsHandle.fileDescriptor,
            path: rhsURL.path
        )
        guard Self.codexFileMetadataIsSameSnapshot(lhsDescriptorStart, lhsStart),
              Self.codexFileMetadataIsSameSnapshot(rhsDescriptorStart, rhsStart),
              Self.codexFileMetadataIsSameSnapshot(
                  Self.codexFileMetadata(fileURL: lhsURL),
                  lhsStart
              ),
              Self.codexFileMetadataIsSameSnapshot(
                  Self.codexFileMetadata(fileURL: rhsURL),
                  rhsStart
              )
        else {
            throw CodexInventoryError.changedDuringEnumeration
        }

        var remaining = min(lhsStart.size, rhsStart.size)
        var matched = true
        while remaining > 0 {
            try checkCancellation?()
            let count = Int(min(remaining, 64 * 1024))
            guard let lhsChunk = try lhsHandle.read(upToCount: count), lhsChunk.count == count,
                  let rhsChunk = try rhsHandle.read(upToCount: count), rhsChunk.count == count
            else {
                throw CodexInventoryError.changedDuringEnumeration
            }
            if lhsChunk != rhsChunk {
                matched = false
                break
            }
            remaining -= Int64(count)
        }

        let lhsDescriptorEnd = Self.codexFileMetadata(
            fileDescriptor: lhsHandle.fileDescriptor,
            path: lhsURL.path
        )
        let rhsDescriptorEnd = Self.codexFileMetadata(
            fileDescriptor: rhsHandle.fileDescriptor,
            path: rhsURL.path
        )
        let lhsEnd = Self.codexFileMetadata(fileURL: lhsURL)
        let rhsEnd = Self.codexFileMetadata(fileURL: rhsURL)
        guard Self.codexFileMetadataIsSameSnapshot(lhsDescriptorEnd, lhsDescriptorStart),
              Self.codexFileMetadataIsSameSnapshot(rhsDescriptorEnd, rhsDescriptorStart),
              Self.codexFileMetadataIsSameSnapshot(lhsEnd, lhsStart),
              Self.codexFileMetadataIsSameSnapshot(rhsEnd, rhsStart),
              try Self.codexDirectoryFingerprint(at: lhsURL) == lhsFingerprint,
              try Self.codexDirectoryFingerprint(at: rhsURL) == rhsFingerprint
        else {
            throw CodexInventoryError.changedDuringEnumeration
        }

        guard matched else { return .divergent }
        if lhsStart.size == rhsStart.size { return .identical }
        return lhsStart.size < rhsStart.size ? .lhsIsPrefix : .rhsIsPrefix
    }

    private static func codexInventoryOwnerPaths(
        files: [CodexSessionInventoryFile],
        cache: CostUsageCache,
        previousOwnerUsageBySessionId: [String: CostUsageFileUsage],
        quarantinedPaths: inout Set<String>,
        checkCancellation: CancellationCheck?
    ) throws -> [String: String] {
        let grouped = Dictionary(grouping: files) { entry in
            entry.sessionId.flatMap { $0.isEmpty ? nil : $0 }
        }
        var result: [String: String] = [:]

        for (sessionID, entries) in grouped {
            guard let sessionID else { continue }
            let eligibleEntries = entries.filter { entry in
                guard let cached = cache.files[entry.metadata.path],
                      cached.codexDuplicateQuarantined == true
                else { return true }
                let generation = entry.metadata.fileId
                    ?? entry.url.standardizedFileURL.resolvingSymlinksInPath().path
                let quarantineIsStillCurrent = cached.sessionId == sessionID
                    && cached.sourceGeneration == generation
                    && cached.sourceStatFingerprint == entry.metadata.statFingerprint
                    && cached.sourceChangeTimeNanoseconds == entry.metadata.changeTimeNanoseconds
                    && cached.mtimeUnixMs == entry.metadata.mtimeUnixMs
                    && cached.size == entry.metadata.size
                return !quarantineIsStillCurrent
            }
            guard !eligibleEntries.isEmpty else {
                throw CodexInventoryError.ambiguousDuplicateSession(sessionID)
            }
            if eligibleEntries.count == 1 {
                result[sessionID] = eligibleEntries[0].metadata.path
                continue
            }

            let cachedOwnerPaths = Set(cache.files.compactMap { path, usage in
                usage.codexInventoryOnly != true && usage.sessionId == sessionID ? path : nil
            })
            let candidates = eligibleEntries.sorted { lhs, rhs in
                let lhsWasOwner = cachedOwnerPaths.contains(lhs.metadata.path)
                let rhsWasOwner = cachedOwnerPaths.contains(rhs.metadata.path)
                if lhsWasOwner != rhsWasOwner { return lhsWasOwner }
                if lhs.metadata.size != rhs.metadata.size { return lhs.metadata.size > rhs.metadata.size }
                return lhs.metadata.path < rhs.metadata.path
            }

            var selected: CodexSessionInventoryFile?
            for candidate in candidates {
                var coversEveryCopy = true
                for other in eligibleEntries where other.metadata.path != candidate.metadata.path {
                    let relationship = try Self.codexFilePrefixRelationship(
                        lhsURL: candidate.url,
                        rhsURL: other.url,
                        checkCancellation: checkCancellation
                    )
                    guard relationship == .identical || relationship == .rhsIsPrefix else {
                        coversEveryCopy = false
                        break
                    }
                }
                if coversEveryCopy {
                    selected = candidate
                    break
                }
            }

            if selected == nil {
                // Inventory runs before the global duplicate reconciler. Apply
                // the same committed-frontier fallback here so an atomic owner
                // replacement cannot block recovery from a stable full copy.
                let cachedOwners = cache.files.filter { _, usage in
                    usage.codexInventoryOnly != true && usage.sessionId == sessionID
                }.sorted(by: { $0.key < $1.key })
                guard cachedOwners.count <= 1 else {
                    throw CodexInventoryError.ambiguousDuplicateSession(sessionID)
                }
                guard let cachedOwnerUsage = cachedOwners.first?.value
                    ?? previousOwnerUsageBySessionId[sessionID]
                else { throw CodexInventoryError.ambiguousDuplicateSession(sessionID) }
                var frontierCandidates: [CodexSessionInventoryFile] = []
                for candidate in eligibleEntries {
                    if try Self.codexFileMatchesCommittedFrontier(
                        fileURL: candidate.url,
                        cached: cachedOwnerUsage,
                        checkCancellation: checkCancellation
                    ) {
                        frontierCandidates.append(candidate)
                    }
                }
                let orderedTrusted = frontierCandidates.sorted { lhs, rhs in
                    if lhs.metadata.size != rhs.metadata.size {
                        return lhs.metadata.size > rhs.metadata.size
                    }
                    return lhs.metadata.path < rhs.metadata.path
                }
                for candidate in orderedTrusted {
                    var coversEveryTrustedCopy = true
                    for other in frontierCandidates
                        where other.metadata.path != candidate.metadata.path
                    {
                        let relationship = try Self.codexFilePrefixRelationship(
                            lhsURL: candidate.url,
                            rhsURL: other.url,
                            checkCancellation: checkCancellation
                        )
                        guard relationship == .identical || relationship == .rhsIsPrefix else {
                            coversEveryTrustedCopy = false
                            break
                        }
                    }
                    if coversEveryTrustedCopy {
                        selected = candidate
                        break
                    }
                }
                guard let trusted = selected else {
                    throw CodexInventoryError.ambiguousDuplicateSession(sessionID)
                }
                for candidate in eligibleEntries where candidate.metadata.path != trusted.metadata.path {
                    let relationship = try Self.codexFilePrefixRelationship(
                        lhsURL: trusted.url,
                        rhsURL: candidate.url,
                        checkCancellation: checkCancellation
                    )
                    if relationship != .identical && relationship != .rhsIsPrefix {
                        quarantinedPaths.insert(candidate.metadata.path)
                    }
                }
            }
            guard let selected else { throw CodexInventoryError.ambiguousDuplicateSession(sessionID) }
            result[sessionID] = selected.metadata.path
        }

        return result
    }

    private static func reconcileCodexDuplicateRolesBeforeScan(
        cache: inout CostUsageCache,
        checkCancellation: CancellationCheck?
    ) throws -> CodexDuplicateReconciliation {
        var pathsNeedingScan: [URL] = []
        var quarantinedPaths = Set<String>()

        func coveringCopy(
            in candidates: [CodexDuplicateCurrentCopy],
            preferExistingOwner: Bool
        ) throws -> CodexDuplicateCurrentCopy? {
            let ordered = candidates.sorted { lhs, rhs in
                if preferExistingOwner {
                    let lhsWasOwner = lhs.cached.codexInventoryOnly != true
                        && lhs.cached.sessionId == lhs.currentSessionId
                    let rhsWasOwner = rhs.cached.codexInventoryOnly != true
                        && rhs.cached.sessionId == rhs.currentSessionId
                    if lhsWasOwner != rhsWasOwner { return lhsWasOwner }
                }
                if lhs.metadata.size != rhs.metadata.size { return lhs.metadata.size > rhs.metadata.size }
                return lhs.path < rhs.path
            }
            for candidate in ordered {
                var coversEveryCopy = true
                for other in candidates where other.path != candidate.path {
                    let relationship = try Self.codexFilePrefixRelationship(
                        lhsURL: candidate.url,
                        rhsURL: other.url,
                        checkCancellation: checkCancellation
                    )
                    guard relationship == .identical || relationship == .rhsIsPrefix else {
                        coversEveryCopy = false
                        break
                    }
                }
                if coversEveryCopy { return candidate }
            }
            return nil
        }

        // Reconcile every duplicate component from one immutable filesystem/cache
        // snapshot. Mutating one cached session group before inspecting another
        // makes simultaneous A -> B / B -> C moves depend on dictionary order.
        let cachedFilesSnapshot = cache.files
        let originalEntries: [(path: String, usage: CostUsageFileUsage, sessionId: String)] =
            cachedFilesSnapshot.compactMap { path, usage in
                guard let sessionId = usage.sessionId, !sessionId.isEmpty else { return nil }
                return (path: path, usage: usage, sessionId: sessionId)
            }
        let originalGroups = Dictionary(grouping: originalEntries, by: { $0.sessionId })

        var copiesByPath: [String: CodexDuplicateCurrentCopy] = [:]
        var snapshotErrorsByPath: [String: Error] = [:]
        var missingMetadataPaths = Set<String>()
        var repairedNoMetadataSessionIds = Set<String>()
        copiesByPath.reserveCapacity(originalEntries.count)

        for entry in originalEntries.sorted(by: { $0.path < $1.path }) {
            try checkCancellation?()
            let url = URL(fileURLWithPath: entry.path)
            let metadata = Self.codexFileMetadata(fileURL: url)
            guard metadata.fileId != nil else {
                missingMetadataPaths.insert(entry.path)
                continue
            }
            let currentGeneration = metadata.fileId
                ?? url.standardizedFileURL.resolvingSymlinksInPath().path
            let changed = entry.usage.sourceGeneration != currentGeneration
                || entry.usage.sourceStatFingerprint != metadata.statFingerprint
                || entry.usage.sourceChangeTimeNanoseconds != metadata.changeTimeNanoseconds
                || entry.usage.mtimeUnixMs != metadata.mtimeUnixMs
                || entry.usage.size != metadata.size

            var parsedMetadata: CodexSessionMetadata?
            if changed {
                do {
                    parsedMetadata = try Self.parseCodexSessionMetadata(
                        fileURL: url,
                        checkCancellation: checkCancellation
                    )
                } catch {
                    snapshotErrorsByPath[entry.path] = error
                    continue
                }
            }
            let currentSessionId = parsedMetadata?.sessionId ?? (changed ? nil : entry.sessionId)
            guard let currentSessionId, !currentSessionId.isEmpty else {
                missingMetadataPaths.insert(entry.path)
                continue
            }
            copiesByPath[entry.path] = CodexDuplicateCurrentCopy(
                path: entry.path,
                url: url,
                cached: entry.usage,
                metadata: metadata,
                currentSessionId: currentSessionId,
                currentForkedFromId: parsedMetadata?.forkedFromId ?? entry.usage.forkedFromId,
                changed: changed
            )
        }

        // A metadata-less inventory sentinel may be repaired or replaced later.
        // Parse all such paths into the same immutable plan so two repairs to the
        // same session cannot manufacture an owner stub in path order.
        let deferredNoMetadataEntries = cachedFilesSnapshot.filter { _, usage in
            usage.codexInventoryOnly == true && usage.sessionId == nil
        }.sorted(by: { $0.key < $1.key })
        for (path, usage) in deferredNoMetadataEntries {
            try checkCancellation?()
            let url = URL(fileURLWithPath: path)
            let metadata = Self.codexFileMetadata(fileURL: url)
            guard metadata.fileId != nil else { continue }
            guard let parsedMetadata = try Self.parseCodexSessionMetadata(
                fileURL: url,
                checkCancellation: checkCancellation
            ), let sessionId = parsedMetadata.sessionId, !sessionId.isEmpty else {
                continue
            }
            copiesByPath[path] = CodexDuplicateCurrentCopy(
                path: path,
                url: url,
                cached: usage,
                metadata: metadata,
                currentSessionId: sessionId,
                currentForkedFromId: parsedMetadata.forkedFromId,
                changed: true
            )
            repairedNoMetadataSessionIds.insert(sessionId)
        }

        let currentGroups = Dictionary(grouping: copiesByPath.values, by: { $0.currentSessionId })
        var affectedSessionIds = Set(
            originalGroups.compactMap { sessionId, entries in entries.count > 1 ? sessionId : nil }
        )
        affectedSessionIds.formUnion(
            currentGroups.compactMap { sessionId, entries in entries.count > 1 ? sessionId : nil }
        )
        affectedSessionIds.formUnion(repairedNoMetadataSessionIds)

        // Session-ID rewrites connect the cached identity and the identity now
        // on disk. Expand from every duplicate so all related groups are planned
        // together, including an external owner that moves again in this scan.
        var adjacentSessionIds: [String: Set<String>] = [:]
        for copy in copiesByPath.values {
            guard let originalSessionId = copy.cached.sessionId,
                  originalSessionId != copy.currentSessionId
            else { continue }
            adjacentSessionIds[originalSessionId, default: []].insert(copy.currentSessionId)
            adjacentSessionIds[copy.currentSessionId, default: []].insert(originalSessionId)
        }
        var pendingSessionIds = Array(affectedSessionIds)
        while let sessionId = pendingSessionIds.popLast() {
            for adjacent in adjacentSessionIds[sessionId] ?? []
                where affectedSessionIds.insert(adjacent).inserted
            {
                pendingSessionIds.append(adjacent)
            }
        }

        if !affectedSessionIds.isEmpty {
            for entry in originalEntries where affectedSessionIds.contains(entry.sessionId) {
                if let error = snapshotErrorsByPath[entry.path] { throw error }
                guard !missingMetadataPaths.contains(entry.path), copiesByPath[entry.path] != nil else {
                    throw Self.codexMissingSessionMetadataError(
                        previousSessionId: entry.sessionId,
                        path: entry.path
                    )
                }
            }

            var originalOwnerBySessionId: [String: (path: String, usage: CostUsageFileUsage)] = [:]
            for sessionId in affectedSessionIds.sorted() {
                let entries = originalGroups[sessionId] ?? []
                let owners = entries.filter { $0.usage.codexInventoryOnly != true }
                guard owners.count <= 1 else {
                    throw Self.codexAmbiguousDuplicateSessionError(
                        sessionId: sessionId,
                        path: entries.map(\.path).sorted().first ?? ""
                    )
                }
                if entries.count > 1, owners.isEmpty {
                    throw Self.codexAmbiguousDuplicateSessionError(
                        sessionId: sessionId,
                        path: entries.map(\.path).sorted().first ?? ""
                    )
                }
                if let owner = owners.first {
                    originalOwnerBySessionId[sessionId] = (owner.path, owner.usage)
                }
            }

            let affectedCopies = copiesByPath.values.filter { copy in
                copy.cached.sessionId.map(affectedSessionIds.contains) == true
                    || affectedSessionIds.contains(copy.currentSessionId)
            }
            let affectedCurrentGroups = Dictionary(
                grouping: affectedCopies,
                by: { $0.currentSessionId }
            )
            var ownerPathByCurrentSessionId: [String: String] = [:]

            for currentSessionId in affectedCurrentGroups.keys.sorted() {
                try checkCancellation?()
                guard let candidates = affectedCurrentGroups[currentSessionId] else { continue }
                if !candidates.contains(where: \.changed) {
                    let cachedOwners = candidates.filter {
                        $0.cached.codexInventoryOnly != true
                            && $0.cached.sessionId == currentSessionId
                    }
                    if cachedOwners.count == 1 {
                        ownerPathByCurrentSessionId[currentSessionId] = cachedOwners[0].path
                        continue
                    }

                    // The former owner can move to another session while an
                    // unchanged, previously proven sentinel remains behind. Its
                    // full committed-prefix proof below makes promotion safe.
                    guard cachedOwners.isEmpty,
                          let originalOwner = originalOwnerBySessionId[currentSessionId],
                          copiesByPath[originalOwner.path]?.currentSessionId != currentSessionId,
                          let trusted = try coveringCopy(
                              in: candidates,
                              preferExistingOwner: true
                          )
                    else {
                        throw Self.codexAmbiguousDuplicateSessionError(
                            sessionId: currentSessionId,
                            path: candidates.map(\.path).sorted().first ?? ""
                        )
                    }
                    ownerPathByCurrentSessionId[currentSessionId] = trusted.path
                    continue
                }
                if let covering = try coveringCopy(in: candidates, preferExistingOwner: true) {
                    ownerPathByCurrentSessionId[currentSessionId] = covering.path
                    continue
                }

                // A destructively rewritten former owner is less trustworthy
                // than another copy that still covers its committed frontier.
                // Select the longest mutually consistent trusted chain, even if
                // that chain contains a valid append from this same refresh.
                guard let originalOwner = originalOwnerBySessionId[currentSessionId],
                      candidates.contains(where: {
                          $0.path == originalOwner.path && $0.changed
                      })
                else {
                    throw Self.codexAmbiguousDuplicateSessionError(
                        sessionId: currentSessionId,
                        path: candidates.map(\.path).sorted().first ?? ""
                    )
                }
                var frontierCandidates: [CodexDuplicateCurrentCopy] = []
                for candidate in candidates {
                    if try Self.codexFileMatchesCommittedFrontier(
                        fileURL: candidate.url,
                        cached: originalOwner.usage,
                        checkCancellation: checkCancellation
                    ) {
                        frontierCandidates.append(candidate)
                    }
                }
                guard let trusted = try coveringCopy(
                    in: frontierCandidates,
                    preferExistingOwner: true
                ) else {
                    throw Self.codexAmbiguousDuplicateSessionError(
                        sessionId: currentSessionId,
                        path: candidates.map(\.path).sorted().first ?? ""
                    )
                }
                ownerPathByCurrentSessionId[currentSessionId] = trusted.path
                for candidate in candidates where candidate.path != trusted.path {
                    let relationship = try Self.codexFilePrefixRelationship(
                        lhsURL: trusted.url,
                        rhsURL: candidate.url,
                        checkCancellation: checkCancellation
                    )
                    if relationship != .identical && relationship != .rhsIsPrefix {
                        quarantinedPaths.insert(candidate.path)
                    }
                }
            }

            // Validate every old aggregate frontier before mutating any role or
            // total. This is the transaction boundary for the global plan.
            var transferredUsageByReplacementPath: [String: CostUsageFileUsage] = [:]
            var transferredOriginalOwnerPaths = Set<String>()
            for originalSessionId in originalOwnerBySessionId.keys.sorted() {
                guard let originalOwner = originalOwnerBySessionId[originalSessionId] else { continue }
                guard let replacementPath = ownerPathByCurrentSessionId[originalSessionId],
                      let replacement = copiesByPath[replacementPath]
                else {
                    throw Self.codexAmbiguousDuplicateSessionError(
                        sessionId: originalSessionId,
                        path: originalOwner.path
                    )
                }
                let keepsOriginalOwner = replacementPath == originalOwner.path
                    && replacement.currentSessionId == originalSessionId
                if !keepsOriginalOwner {
                    guard try Self.codexFileMatchesCommittedFrontier(
                        fileURL: replacement.url,
                        cached: originalOwner.usage,
                        checkCancellation: checkCancellation
                    ) else {
                        throw Self.codexAmbiguousDuplicateSessionError(
                            sessionId: originalSessionId,
                            path: replacementPath
                        )
                    }
                    var transferred = originalOwner.usage
                    transferred.sessionId = originalSessionId
                    transferred.forkedFromId = replacement.currentForkedFromId
                    transferred.sourceGeneration = replacement.metadata.fileId
                        ?? replacement.url.standardizedFileURL.resolvingSymlinksInPath().path
                    transferred.sourceStatFingerprint = replacement.metadata.statFingerprint
                    transferred.sourceChangeTimeNanoseconds = replacement.metadata.changeTimeNanoseconds
                    transferred.codexInventoryOnly = false
                    transferred.codexDuplicateQuarantined = nil
                    transferredUsageByReplacementPath[replacementPath] = transferred
                    transferredOriginalOwnerPaths.insert(originalOwner.path)
                }
            }

            for copy in affectedCopies.sorted(by: { $0.path < $1.path }) {
                let isOwner = ownerPathByCurrentSessionId[copy.currentSessionId] == copy.path
                let keptExistingOwner = isOwner
                    && copy.cached.codexInventoryOnly != true
                    && copy.cached.sessionId == copy.currentSessionId
                let keptStableSentinel = !isOwner
                    && !copy.changed
                    && copy.cached.codexInventoryOnly == true
                    && copy.cached.sessionId == copy.currentSessionId

                if isOwner, let transferred = transferredUsageByReplacementPath[copy.path] {
                    // The replacement proved the exact committed prefix, so move
                    // the full retained ledger instead of rebuilding only the
                    // currently requested reporting window.
                    cache.files[copy.path] = transferred
                    pathsNeedingScan.append(copy.url)
                    continue
                }

                if keptExistingOwner {
                    if copy.changed { pathsNeedingScan.append(copy.url) }
                    continue
                }
                if keptStableSentinel { continue }

                if copy.cached.codexInventoryOnly != true,
                   !transferredOriginalOwnerPaths.contains(copy.path) {
                    Self.applyFileDays(cache: &cache, fileDays: copy.cached.days, sign: -1)
                }
                cache.files[copy.path] = Self.makeFileUsage(
                    mtimeUnixMs: copy.metadata.mtimeUnixMs,
                    size: copy.metadata.size,
                    days: [:],
                    parsedBytes: isOwner ? 0 : copy.metadata.size,
                    sessionId: copy.currentSessionId,
                    forkedFromId: copy.currentForkedFromId,
                    sourceGeneration: copy.metadata.fileId
                        ?? copy.url.standardizedFileURL.resolvingSymlinksInPath().path,
                    sourceStatFingerprint: copy.metadata.statFingerprint,
                    sourceChangeTimeNanoseconds: copy.metadata.changeTimeNanoseconds,
                    codexInventoryOnly: !isOwner,
                    codexDuplicateQuarantined: quarantinedPaths.contains(copy.path) ? true : nil
                )
                if isOwner { pathsNeedingScan.append(copy.url) }
            }
        }

        let ownerEntries: [(path: String, sessionId: String)] = cache.files.compactMap { path, usage in
            guard usage.codexInventoryOnly != true,
                  let sessionId = usage.sessionId,
                  !sessionId.isEmpty
            else { return nil }
            return (path: path, sessionId: sessionId)
        }
        let duplicateOwners = Dictionary(grouping: ownerEntries, by: { $0.sessionId })
            .first { $0.value.count > 1 }
        if let duplicateOwners {
            throw Self.codexAmbiguousDuplicateSessionError(
                sessionId: duplicateOwners.key,
                path: duplicateOwners.value.map { $0.path }.sorted().first ?? ""
            )
        }

        var seenPaths = Set<String>()
        return CodexDuplicateReconciliation(
            scanURLs: pathsNeedingScan.filter { seenPaths.insert($0.path).inserted },
            quarantinedPaths: quarantinedPaths
        )
    }

    private static func listCodexRecentlyModifiedFiles(
        root: URL,
        scanSinceKey: String,
        scanUntilKey: String,
        modifiedSince: Date) throws -> [URL]
    {
        let lookbackSinceKey = self.dayKey(scanSinceKey, addingDays: -self.codexActiveSessionLookbackDays)
            ?? scanSinceKey
        let partitioned = try self.listCodexSessionFilesByDatePartition(
            root: root,
            scanSinceKey: lookbackSinceKey,
            scanUntilKey: scanUntilKey)
        let partitionedModified = try self.filterRecentlyModified(
            files: partitioned,
            modifiedSince: modifiedSince
        )

        let legacyRecursive = try self.listCodexRecentlyModifiedFilesRecursive(
            root: root,
            modifiedSince: modifiedSince
        )
        var seen = Set(partitionedModified.map(\.path))
        var out = partitionedModified
        for fileURL in legacyRecursive where !seen.contains(fileURL.path) {
            seen.insert(fileURL.path)
            out.append(fileURL)
        }
        return out
    }

    private static func filterRecentlyModified(files: [URL], modifiedSince: Date) throws -> [URL] {
        var output: [URL] = []
        for fileURL in files {
            do {
                let values = try fileURL.resourceValues(
                    forKeys: [.isRegularFileKey, .contentModificationDateKey]
                )
                guard values.isRegularFile == true,
                      let modifiedAt = values.contentModificationDate,
                      modifiedAt >= modifiedSince
                else {
                    continue
                }
                output.append(fileURL)
            } catch {
                if self.isMissingFileError(error) { continue }
                throw error
            }
        }
        return output
    }

    private static func isDatePartitionComponent(_ value: String, length: Int) -> Bool {
        value.count == length && value.allSatisfy(\.isNumber)
    }

    private static func dayKey(_ dayKey: String, addingDays days: Int) -> String? {
        guard let date = self.parseDayKey(dayKey) else { return nil }
        guard let shifted = Calendar.current.date(byAdding: .day, value: days, to: date) else { return nil }
        return CostUsageDayRange.dayKey(from: shifted)
    }

    private static func dayKeys(sinceKey: String, untilKey: String) -> [String] {
        guard let since = self.parseDayKey(sinceKey),
              self.parseDayKey(untilKey) != nil
        else { return sinceKey <= untilKey ? [sinceKey] : [] }

        var out: [String] = []
        var cursor = since
        let calendar = Calendar.current
        while CostUsageDayRange.dayKey(from: cursor) <= untilKey {
            out.append(CostUsageDayRange.dayKey(from: cursor))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            if next <= cursor { break }
            cursor = next
        }
        return out
    }

    private static func listCodexRecentlyModifiedFilesRecursive(
        root: URL,
        modifiedSince: Date
    ) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, error in
                enumerationError = error
                return false
            })
        else {
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileReadUnknownError,
                userInfo: [NSFilePathErrorKey: root.path]
            )
        }

        var out: [URL] = []
        while let fileURL = enumerator.nextObject() as? URL {
            guard fileURL.pathExtension.lowercased() == "jsonl" else { continue }
            do {
                let values = try fileURL.resourceValues(
                    forKeys: [.isRegularFileKey, .contentModificationDateKey]
                )
                guard values.isRegularFile == true,
                      let modifiedAt = values.contentModificationDate,
                      modifiedAt >= modifiedSince
                else {
                    continue
                }
                out.append(fileURL)
            } catch {
                if self.isMissingFileError(error) { continue }
                throw error
            }
        }
        if let enumerationError { throw enumerationError }
        return out
    }

    private static func isWithinCodexRoots(fileURL: URL, roots: [URL]) -> Bool {
        let filePath = fileURL.standardizedFileURL.resolvingSymlinksInPath().path
        return roots.contains { root in
            let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
            if filePath == rootPath { return true }
            let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            return filePath.hasPrefix(prefix)
        }
    }

    private static func listCodexSessionFilesByDatePartition(
        root: URL,
        scanSinceKey: String,
        scanUntilKey: String) throws -> [URL]
    {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        var out: [URL] = []
        var date = Self.parseDayKey(scanSinceKey) ?? Date()
        let untilDate = Self.parseDayKey(scanUntilKey) ?? date

        while date <= untilDate {
            let comps = Calendar.current.dateComponents([.year, .month, .day], from: date)
            let y = String(format: "%04d", comps.year ?? 1970)
            let m = String(format: "%02d", comps.month ?? 1)
            let d = String(format: "%02d", comps.day ?? 1)

            let dayDir = root.appendingPathComponent(y, isDirectory: true)
                .appendingPathComponent(m, isDirectory: true)
                .appendingPathComponent(d, isDirectory: true)

            do {
                guard FileManager.default.fileExists(atPath: dayDir.path) else {
                    date = Calendar.current.date(byAdding: .day, value: 1, to: date)
                        ?? untilDate.addingTimeInterval(1)
                    continue
                }
                let items = try FileManager.default.contentsOfDirectory(
                    at: dayDir,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                )
                for item in items where item.pathExtension.lowercased() == "jsonl" {
                    out.append(item)
                }
            } catch {
                if !self.isMissingFileError(error) { throw error }
            }

            date = Calendar.current.date(byAdding: .day, value: 1, to: date) ?? untilDate.addingTimeInterval(1)
        }

        return out
    }

    private static func listCodexSessionFilesFlat(
        root: URL,
        scanSinceKey: String,
        scanUntilKey: String
    ) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let items: [URL]
        do {
            items = try FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
        } catch {
            if self.isMissingFileError(error) { return [] }
            throw error
        }

        var out: [URL] = []
        for item in items where item.pathExtension.lowercased() == "jsonl" {
            if let dayKey = Self.dayKeyFromFilename(item.lastPathComponent) {
                if !CostUsageDayRange.isInRange(dayKey: dayKey, since: scanSinceKey, until: scanUntilKey) {
                    continue
                }
            }
            out.append(item)
        }
        return out
    }

    private static func listCodexLegacySessionFilesRecursive(root: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let rootPath = root.standardizedFileURL.path
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, error in
                enumerationError = error
                return false
            })
        else {
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileReadUnknownError,
                userInfo: [NSFilePathErrorKey: root.path]
            )
        }

        var out: [URL] = []
        while let item = enumerator.nextObject() as? URL {
            if Self.isCodexDatePartitionAncestor(item, rootPath: rootPath) {
                enumerator.skipDescendants()
                continue
            }
            guard item.pathExtension.lowercased() == "jsonl" else { continue }
            out.append(item)
        }
        if let enumerationError { throw enumerationError }
        return out
    }

    private static func isMissingFileError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain
            && nsError.code == NSFileNoSuchFileError
    }

    private static func isCodexDatePartitionAncestor(_ url: URL, rootPath: String) -> Bool {
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return false }
        let relative = String(path.dropFirst(rootPath.count + 1))
        let parts = relative.split(separator: "/")
        guard parts.count == 1 else { return false }
        return Self.isDatePartitionComponent(String(parts[0]), length: 4)
    }

    private static let codexFilenameDateRegex = try? NSRegularExpression(pattern: "(\\d{4}-\\d{2}-\\d{2})")

    private static func dayKeyFromFilename(_ filename: String) -> String? {
        guard let regex = self.codexFilenameDateRegex else { return nil }
        let range = NSRange(filename.startIndex..<filename.endIndex, in: filename)
        guard let match = regex.firstMatch(in: filename, range: range) else { return nil }
        guard let matchRange = Range(match.range(at: 1), in: filename) else { return nil }
        return String(filename[matchRange])
    }

    private struct CodexSessionMetadata {
        let sessionId: String?
        let forkedFromId: String?
        let forkTimestamp: String?
    }

    private struct CodexTokenCountRecord {
        let timestamp: String
        let model: String?
        let turnID: String?
        let last: CostUsageCodexTotals?
        let total: CostUsageCodexTotals?
    }

    private enum CodexFastLine {
        case sessionMeta(CodexSessionMetadata)
        case turnContext(model: String?)
        case taskStarted(turnID: String?)
        case tokenCount(CodexTokenCountRecord)
    }

    private static let codexJSONFieldCachedInputTokens = Array("cached_input_tokens".utf8)
    private static let codexJSONFieldCacheReadInputTokens = Array("cache_read_input_tokens".utf8)
    private static let codexJSONFieldForkedFromId = Array("forked_from_id".utf8)
    private static let codexJSONFieldForkedFromIdCamel = Array("forkedFromId".utf8)
    private static let codexJSONFieldId = Array("id".utf8)
    private static let codexJSONFieldInfo = Array("info".utf8)
    private static let codexJSONFieldInputTokens = Array("input_tokens".utf8)
    private static let codexJSONFieldLastTokenUsage = Array("last_token_usage".utf8)
    private static let codexJSONFieldModel = Array("model".utf8)
    private static let codexJSONFieldModelName = Array("model_name".utf8)
    private static let codexJSONFieldOutputTokens = Array("output_tokens".utf8)
    private static let codexJSONFieldParentSessionId = Array("parent_session_id".utf8)
    private static let codexJSONFieldParentSessionIdCamel = Array("parentSessionId".utf8)
    private static let codexJSONFieldPayload = Array("payload".utf8)
    private static let codexJSONFieldSessionId = Array("session_id".utf8)
    private static let codexJSONFieldSessionIdCamel = Array("sessionId".utf8)
    private static let codexJSONFieldTimestamp = Array("timestamp".utf8)
    private static let codexJSONFieldTotalTokenUsage = Array("total_token_usage".utf8)
    private static let codexJSONFieldTurnId = Array("turn_id".utf8)
    private static let codexJSONFieldTurnIdCamel = Array("turnId".utf8)
    private static let codexJSONFieldType = Array("type".utf8)

    private static func codexForkParentId(from payload: [String: Any]?) -> String? {
        guard let payload else { return nil }
        for key in ["forked_from_id", "forkedFromId", "parent_session_id", "parentSessionId"] {
            guard let value = payload[key] as? String else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    private static func codexForkParentId(
        from bytes: UnsafeBufferPointer<UInt8>,
        in payloadRange: Range<Int>) -> String?
    {
        for key in [
            self.codexJSONFieldForkedFromId,
            self.codexJSONFieldForkedFromIdCamel,
            self.codexJSONFieldParentSessionId,
            self.codexJSONFieldParentSessionIdCamel,
        ] {
            guard let value = extractJSONByteStringField(key, from: bytes, in: payloadRange, atDepth: 1)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !value.isEmpty
            else { continue }
            return value
        }
        return nil
    }

    private static func codexTurnID(from bytes: UnsafeBufferPointer<UInt8>, in payloadRange: Range<Int>) -> String? {
        for key in [self.codexJSONFieldTurnId, self.codexJSONFieldTurnIdCamel, self.codexJSONFieldId] {
            if let value = extractJSONByteStringField(key, from: bytes, in: payloadRange, atDepth: 1), !value.isEmpty {
                return value
            }
        }
        if let infoRange = extractJSONByteObjectField(codexJSONFieldInfo, from: bytes, in: payloadRange, atDepth: 1) {
            for key in [self.codexJSONFieldTurnId, self.codexJSONFieldTurnIdCamel, self.codexJSONFieldId] {
                if let value = extractJSONByteStringField(key, from: bytes, in: infoRange, atDepth: 1), !value.isEmpty {
                    return value
                }
            }
        }
        return nil
    }

    private static func codexSessionId(
        from bytes: UnsafeBufferPointer<UInt8>,
        in rootRange: Range<Int>,
        payloadRange: Range<Int>?) -> String?
    {
        if let payloadRange {
            for key in [self.codexJSONFieldSessionId, self.codexJSONFieldSessionIdCamel, self.codexJSONFieldId] {
                if let value = extractJSONByteStringField(key, from: bytes, in: payloadRange, atDepth: 1),
                   !value.isEmpty
                {
                    return value
                }
            }
        }
        for key in [Self.codexJSONFieldSessionId, Self.codexJSONFieldSessionIdCamel, Self.codexJSONFieldId] {
            if let value = Self.extractJSONByteStringField(key, from: bytes, in: rootRange, atDepth: 1),
               !value.isEmpty
            {
                return value
            }
        }
        return nil
    }

    private static func codexTotals(
        from bytes: UnsafeBufferPointer<UInt8>,
        in objectRange: Range<Int>?) -> CostUsageCodexTotals?
    {
        guard let objectRange else { return nil }
        let input = max(
            0,
            Self.extractJSONByteIntField(Self.codexJSONFieldInputTokens, from: bytes, in: objectRange, atDepth: 1) ?? 0)
        let cached = max(
            0,
            Self.extractJSONByteIntField(Self.codexJSONFieldCachedInputTokens, from: bytes, in: objectRange, atDepth: 1)
                ?? Self.extractJSONByteIntField(
                    Self.codexJSONFieldCacheReadInputTokens,
                    from: bytes,
                    in: objectRange,
                    atDepth: 1)
                ?? 0)
        let output = max(
            0,
            Self
                .extractJSONByteIntField(Self.codexJSONFieldOutputTokens, from: bytes, in: objectRange, atDepth: 1) ??
                0)
        return CostUsageCodexTotals(input: input, cached: cached, output: output)
    }

    private static func codexTimestamp(in lineData: Data) -> Date? {
        lineData.withUnsafeBytes { rawBytes in
            let bytes = rawBytes.bindMemory(to: UInt8.self)
            guard !bytes.isEmpty,
                  let timestamp = Self.extractJSONByteStringField(
                      Self.codexJSONFieldTimestamp,
                      from: bytes,
                      in: 0..<bytes.count,
                      atDepth: 1
                  )
            else {
                return nil
            }
            return Self.dateFromTimestamp(timestamp)
        }
    }

    private static func parseCodexFastLine(_ bytes: Data) -> CodexFastLine? {
        bytes.withUnsafeBytes { rawBytes in
            let rawBuffer = rawBytes.bindMemory(to: UInt8.self)
            guard !rawBuffer.isEmpty else { return nil }
            let objectRange = 0..<rawBuffer.count
            guard let type = Self.extractJSONByteStringField(
                Self.codexJSONFieldType,
                from: rawBuffer,
                in: objectRange,
                atDepth: 1)
            else { return nil }

            switch type {
            case "session_meta":
                let payloadRange = Self.extractJSONByteObjectField(
                    Self.codexJSONFieldPayload,
                    from: rawBuffer,
                    in: objectRange,
                    atDepth: 1)
                return .sessionMeta(CodexSessionMetadata(
                    sessionId: Self.codexSessionId(from: rawBuffer, in: objectRange, payloadRange: payloadRange),
                    forkedFromId: payloadRange.flatMap { Self.codexForkParentId(from: rawBuffer, in: $0) },
                    forkTimestamp: payloadRange.flatMap {
                        Self.extractJSONByteStringField(
                            Self.codexJSONFieldTimestamp,
                            from: rawBuffer,
                            in: $0,
                            atDepth: 1)
                    } ?? Self.extractJSONByteStringField(
                        Self.codexJSONFieldTimestamp,
                        from: rawBuffer,
                        in: objectRange,
                        atDepth: 1)))

            case "turn_context":
                guard let payloadRange = Self.extractJSONByteObjectField(
                    Self.codexJSONFieldPayload,
                    from: rawBuffer,
                    in: objectRange,
                    atDepth: 1)
                else { return .turnContext(model: nil) }
                let model = Self.extractJSONByteStringField(
                    Self.codexJSONFieldModel,
                    from: rawBuffer,
                    in: payloadRange,
                    atDepth: 1)
                    ?? Self.extractJSONByteStringField(
                        Self.codexJSONFieldModelName,
                        from: rawBuffer,
                        in: payloadRange,
                        atDepth: 1)
                    ?? Self.extractJSONByteObjectField(
                        Self.codexJSONFieldInfo,
                        from: rawBuffer,
                        in: payloadRange,
                        atDepth: 1).flatMap {
                        Self.extractJSONByteStringField(
                            Self.codexJSONFieldModel,
                            from: rawBuffer,
                            in: $0,
                            atDepth: 1)
                            ?? Self.extractJSONByteStringField(
                                Self.codexJSONFieldModelName,
                                from: rawBuffer,
                                in: $0,
                                atDepth: 1)
                    }
                return .turnContext(model: model)

            case "event_msg":
                guard let payloadRange = Self.extractJSONByteObjectField(
                    Self.codexJSONFieldPayload,
                    from: rawBuffer,
                    in: objectRange,
                    atDepth: 1),
                    let payloadType = Self.extractJSONByteStringField(
                        Self.codexJSONFieldType,
                        from: rawBuffer,
                        in: payloadRange,
                        atDepth: 1)
                else { return nil }

                if payloadType == "task_started" {
                    return .taskStarted(turnID: Self.codexTurnID(from: rawBuffer, in: payloadRange))
                }

                guard payloadType == "token_count",
                      let timestamp = Self.extractJSONByteStringField(
                          Self.codexJSONFieldTimestamp,
                          from: rawBuffer,
                          in: objectRange,
                          atDepth: 1),
                      let infoRange = Self.extractJSONByteObjectField(
                          Self.codexJSONFieldInfo,
                          from: rawBuffer,
                          in: payloadRange,
                          atDepth: 1)
                else { return nil }

                let model = Self.extractJSONByteStringField(
                    Self.codexJSONFieldModel,
                    from: rawBuffer,
                    in: infoRange,
                    atDepth: 1)
                    ?? Self.extractJSONByteStringField(
                        Self.codexJSONFieldModelName,
                        from: rawBuffer,
                        in: infoRange,
                        atDepth: 1)
                    ?? Self.extractJSONByteStringField(
                        Self.codexJSONFieldModel,
                        from: rawBuffer,
                        in: payloadRange,
                        atDepth: 1)
                    ?? Self.extractJSONByteStringField(
                        Self.codexJSONFieldModel,
                        from: rawBuffer,
                        in: objectRange,
                        atDepth: 1)
                let total = Self.codexTotals(
                    from: rawBuffer,
                    in: Self.extractJSONByteObjectField(
                        Self.codexJSONFieldTotalTokenUsage,
                        from: rawBuffer,
                        in: infoRange,
                        atDepth: 1))
                let last = Self.codexTotals(
                    from: rawBuffer,
                    in: Self.extractJSONByteObjectField(
                        Self.codexJSONFieldLastTokenUsage,
                        from: rawBuffer,
                        in: infoRange,
                        atDepth: 1))
                return .tokenCount(CodexTokenCountRecord(
                    timestamp: timestamp,
                    model: model,
                    turnID: Self.codexTurnID(from: rawBuffer, in: payloadRange),
                    last: last,
                    total: total))

            default:
                return nil
            }
        }
    }

    private static func parseCodexSessionIdentifier(
        fileURL: URL,
        checkCancellation: CancellationCheck? = nil) throws -> String?
    {
        try self.parseCodexSessionMetadata(fileURL: fileURL, checkCancellation: checkCancellation)?.sessionId
    }

    private static func parseCodexSessionMetadata(
        fileURL: URL,
        checkCancellation: CancellationCheck? = nil) throws -> CodexSessionMetadata?
    {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: fileURL)
        } catch {
            self.log.warning(
                "Codex cost usage failed to open session file for session id parsing",
                metadata: ["path": fileURL.path, "error": error.localizedDescription])
            throw error
        }
        defer { try? handle.close() }

        var buffer = Data()
        let newline = Data([0x0A])

        func parseSessionMetadata(from lineData: Data) -> CodexSessionMetadata? {
            guard !lineData.isEmpty else { return nil }
            if case let .sessionMeta(metadata) = Self.parseCodexFastLine(lineData) {
                return metadata
            }
            return autoreleasepool {
                guard let obj = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any]
                else { return nil }
                guard obj["type"] as? String == "session_meta" else { return nil }
                let payload = obj["payload"] as? [String: Any]
                return CodexSessionMetadata(
                    sessionId: payload?["session_id"] as? String
                        ?? payload?["sessionId"] as? String
                        ?? payload?["id"] as? String
                        ?? obj["session_id"] as? String
                        ?? obj["sessionId"] as? String
                        ?? obj["id"] as? String,
                    forkedFromId: Self.codexForkParentId(from: payload),
                    forkTimestamp: payload?["timestamp"] as? String
                        ?? obj["timestamp"] as? String)
            }
        }

        do {
            while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                try checkCancellation?()
                buffer.append(chunk)
                while let newlineRange = buffer.range(of: newline) {
                    let lineData = buffer.subdata(in: 0..<newlineRange.lowerBound)
                    buffer.removeSubrange(0..<newlineRange.upperBound)
                    if let metadata = parseSessionMetadata(from: lineData) {
                        return metadata
                    }
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            self.log.warning(
                "Codex cost usage failed while reading session file for session id parsing",
                metadata: ["path": fileURL.path, "error": error.localizedDescription])
            throw error
        }

        if let metadata = parseSessionMetadata(from: buffer) {
            return metadata
        }
        return nil
    }

    private static func parseCodexTokenSnapshots(
        fileURL: URL,
        checkCancellation: CancellationCheck? = nil) throws -> (
        sessionId: String?,
        snapshots: [CodexTimestampedTotals])
    {
        var sessionId: String?
        var previousTotals: CostUsageCodexTotals?
        var rawTotalsBaseline: CostUsageCodexTotals?
        var sawDivergentTotals = false
        var snapshots: [CodexTimestampedTotals] = []
        var warnedAboutUnparsedTimestamp = false

        func parsedSnapshotDate(timestamp: String) -> Date? {
            let date = Self.dateFromTimestamp(timestamp)
            if date == nil, !warnedAboutUnparsedTimestamp {
                warnedAboutUnparsedTimestamp = true
                self.log.warning(
                    "Codex cost usage could not parse parent token snapshot timestamp; "
                        + "falling back to lexical comparison",
                    metadata: ["path": fileURL.path, "timestamp": timestamp])
            }
            return date
        }

        func appendSnapshot(timestamp: String, last: CostUsageCodexTotals?, total: CostUsageCodexTotals?) {
            if let last {
                let rawDelta = last
                let base = previousTotals ?? .init(input: 0, cached: 0, output: 0)
                var countedDelta = rawDelta

                if let total {
                    let rawTotals = total
                    let totalDelta = Self.codexTotalDelta(from: rawTotalsBaseline, to: rawTotals)
                    if Self.codexShouldPreferTotalDelta(
                        rawBaseline: rawTotalsBaseline,
                        currentTotal: rawTotals,
                        totalDelta: totalDelta,
                        lastDelta: rawDelta,
                        sawDivergentTotals: sawDivergentTotals)
                    {
                        countedDelta = totalDelta
                    }
                    let next = Self.codexAddTotals(base, countedDelta)
                    previousTotals = next
                    rawTotalsBaseline = rawTotals
                    if !Self.codexTotalsEqual(rawTotals, next) {
                        sawDivergentTotals = true
                    }
                } else {
                    let next = Self.codexAddTotals(base, countedDelta)
                    previousTotals = next
                    rawTotalsBaseline = next
                }

                snapshots.append(CodexTimestampedTotals(
                    timestamp: timestamp,
                    date: parsedSnapshotDate(timestamp: timestamp),
                    totals: previousTotals ?? base))
            } else if let total {
                let next = total
                let delta = sawDivergentTotals
                    ? Self.codexDivergentTotalDelta(
                        rawBaseline: rawTotalsBaseline,
                        countedBaseline: previousTotals,
                        current: next)
                    : Self.codexTotalDelta(from: rawTotalsBaseline, to: next)
                let base = previousTotals ?? .init(input: 0, cached: 0, output: 0)
                let countedTotals = Self.codexAddTotals(base, delta)
                previousTotals = countedTotals
                rawTotalsBaseline = next
                if !Self.codexTotalsEqual(next, countedTotals) {
                    sawDivergentTotals = true
                }
                snapshots.append(CodexTimestampedTotals(
                    timestamp: timestamp,
                    date: parsedSnapshotDate(timestamp: timestamp),
                    totals: countedTotals))
            }
        }

        do {
            _ = try CostUsageJsonl.scan(
                fileURL: fileURL,
                maxLineBytes: 512 * 1024,
                prefixBytes: 512 * 1024,
                checkCancellation: checkCancellation,
                onLine: { line in
                    guard !line.bytes.isEmpty, !line.wasTruncated else { return }
                    if let fastLine = Self.parseCodexFastLine(line.bytes) {
                        switch fastLine {
                        case let .sessionMeta(metadata):
                            if sessionId == nil {
                                sessionId = metadata.sessionId
                            }
                        case let .tokenCount(record):
                            appendSnapshot(timestamp: record.timestamp, last: record.last, total: record.total)
                        case .turnContext, .taskStarted:
                            break
                        }
                        return
                    }

                    autoreleasepool {
                        guard let obj = (try? JSONSerialization.jsonObject(with: line.bytes)) as? [String: Any]
                        else { return }

                        if obj["type"] as? String == "session_meta" {
                            let payload = obj["payload"] as? [String: Any]
                            if sessionId == nil {
                                sessionId = payload?["session_id"] as? String
                                    ?? payload?["sessionId"] as? String
                                    ?? payload?["id"] as? String
                                    ?? obj["session_id"] as? String
                                    ?? obj["sessionId"] as? String
                                    ?? obj["id"] as? String
                            }
                            return
                        }

                        guard obj["type"] as? String == "event_msg" else { return }
                        guard let payload = obj["payload"] as? [String: Any] else { return }
                        guard payload["type"] as? String == "token_count" else { return }
                        guard let info = payload["info"] as? [String: Any] else { return }
                        guard let timestamp = obj["timestamp"] as? String else { return }

                        func toInt(_ value: Any?) -> Int {
                            if let number = value as? NSNumber { return number.intValue }
                            return 0
                        }

                        let total = (info["total_token_usage"] as? [String: Any]).map {
                            CostUsageCodexTotals(
                                input: toInt($0["input_tokens"]),
                                cached: toInt($0["cached_input_tokens"] ?? $0["cache_read_input_tokens"]),
                                output: toInt($0["output_tokens"]))
                        }
                        let last = (info["last_token_usage"] as? [String: Any]).map {
                            CostUsageCodexTotals(
                                input: max(0, toInt($0["input_tokens"])),
                                cached: max(0, toInt($0["cached_input_tokens"] ?? $0["cache_read_input_tokens"])),
                                output: max(0, toInt($0["output_tokens"])))
                        }
                        appendSnapshot(timestamp: timestamp, last: last, total: total)
                    }
                })
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            self.log.warning(
                "Codex cost usage failed while scanning parent token snapshots",
                metadata: ["path": fileURL.path, "error": error.localizedDescription])
        }

        return (sessionId, snapshots)
    }

    static func parseCodexFile(
        fileURL: URL,
        range: CostUsageDayRange,
        through: Date? = nil,
        startOffset: Int64 = 0,
        initialModel: String? = nil,
        initialTotals: CostUsageCodexTotals? = nil,
        initialRawTotalsBaseline: CostUsageCodexTotals? = nil,
        initialHasDivergentTotals: Bool = false,
        initialCodexTurnID: String? = nil,
        inheritedTotalsResolver: ((String, String) -> CodexForkBaseline)? = nil) -> CodexParseResult
    {
        let throwingResolver: ((String, String) throws -> CodexForkBaseline)? = inheritedTotalsResolver
            .map { resolver in
                { sessionId, timestamp in resolver(sessionId, timestamp) }
            }
        return (
            try? Self.parseCodexFileCancellable(
                fileURL: fileURL,
                range: range,
                through: through,
                startOffset: startOffset,
                initialModel: initialModel,
                initialTotals: initialTotals,
                initialRawTotalsBaseline: initialRawTotalsBaseline,
                initialHasDivergentTotals: initialHasDivergentTotals,
                initialCodexTurnID: initialCodexTurnID,
                inheritedTotalsResolver: throwingResolver,
                checkCancellation: nil)) ?? CodexParseResult(
            days: [:],
            parsedBytes: startOffset,
            lastModel: initialModel,
            lastTotals: initialTotals,
            lastCountedTotals: initialTotals,
            lastRawTotalsBaseline: initialRawTotalsBaseline,
            hasDivergentTotals: initialHasDivergentTotals,
            lastCodexTurnID: initialCodexTurnID,
            sessionId: nil,
            forkedFromId: nil,
            lastTokenEventEndOffset: nil,
            lastTokenEventFingerprint: nil,
            lastTokenEventTimestamp: nil,
            lastTokenEventTotalTokens: nil,
            tokenEventWatermarks: [],
            rows: [])
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func parseCodexFileCancellable(
        fileURL: URL,
        range: CostUsageDayRange,
        through: Date? = nil,
        startOffset: Int64 = 0,
        initialModel: String? = nil,
        initialTotals: CostUsageCodexTotals? = nil,
        initialRawTotalsBaseline: CostUsageCodexTotals? = nil,
        initialHasDivergentTotals: Bool = false,
        initialCodexTurnID: String? = nil,
        inheritedTotalsResolver: ((String, String) throws -> CodexForkBaseline)? = nil,
        checkCancellation: CancellationCheck? = nil) throws -> CodexParseResult
    {
        var currentModel = initialModel
        var previousTotals = initialTotals
        var sessionId: String?
        var forkedFromId: String?
        var inheritedTotals: CostUsageCodexTotals?
        var remainingInheritedTotals: CostUsageCodexTotals?
        var forkBaselineResolved = false
        var hasUnresolvedForkBaseline = false
        var unresolvedForkTotalWatermark: CostUsageCodexTotals?
        var currentTurnID = initialCodexTurnID
        var rawTotalsBaseline = initialRawTotalsBaseline ?? initialTotals
        var sawDivergentTotals = initialHasDivergentTotals
        var deferredError: Error?
        var lastTokenEventEndOffset: Int64?
        var lastTokenEventFingerprint: String?
        var lastTokenEventTimestamp: Date?
        var lastTokenEventTotalTokens: Int?
        var tokenEventWatermarks: [CostUsageTokenEventWatermark] = []

        var days: [String: [String: [Int]]] = [:]
        var rows: [CodexUsageRow] = []

        func add(dayKey: String, model: String, input: Int, cached: Int, output: Int) {
            guard CostUsageDayRange.isInRange(dayKey: dayKey, since: range.scanSinceKey, until: range.scanUntilKey)
            else { return }
            let normModel = CostUsagePricing.normalizeCodexModel(model)

            var dayModels = days[dayKey] ?? [:]
            var packed = dayModels[normModel] ?? [0, 0, 0]
            packed[0] = (packed[safe: 0] ?? 0) + input
            packed[1] = (packed[safe: 1] ?? 0) + cached
            packed[2] = (packed[safe: 2] ?? 0) + output
            dayModels[normModel] = packed
            days[dayKey] = dayModels
        }

        func resolveForkBaseline(parentSessionId: String, forkedAt: String) throws {
            guard !forkBaselineResolved else { return }
            guard let inheritedTotalsResolver else { return }
            forkBaselineResolved = true
            switch try inheritedTotalsResolver(parentSessionId, forkedAt) {
            case let .resolved(totals):
                inheritedTotals = totals
                remainingInheritedTotals = totals
                hasUnresolvedForkBaseline = false
            case .unresolved:
                hasUnresolvedForkBaseline = true
            }
        }

        func handleSessionMetadata(_ metadata: CodexSessionMetadata) throws {
            if sessionId == nil {
                sessionId = metadata.sessionId
            }
            if forkedFromId == nil {
                forkedFromId = metadata.forkedFromId
            }
            if let forkedFromId {
                try resolveForkBaseline(parentSessionId: forkedFromId, forkedAt: metadata.forkTimestamp ?? "")
            }
        }

        // swiftlint:disable:next function_body_length
        func handleTokenCount(_ record: CodexTokenCountRecord, line: CostUsageJsonl.Line) throws {
            let eventTimestamp = Self.dateFromTimestamp(record.timestamp)
            let eventDayKey = Self.dayKeyFromTimestamp(record.timestamp)
                ?? Self.dayKeyFromParsedISO(record.timestamp)
            lastTokenEventEndOffset = line.endOffset
            lastTokenEventFingerprint = CodexTokenObservationCursor.fingerprint(for: line.bytes)
            lastTokenEventTimestamp = eventTimestamp
            lastTokenEventTotalTokens = record.total.map { max(0, $0.input) + max(0, $0.output) }
            guard let dayKey = eventDayKey else { return }

            let model = currentModel ?? record.model ?? "gpt-5"
            let total = record.total
            let last = record.last

            var deltaInput = 0
            var deltaCached = 0
            var deltaOutput = 0

            func adjustedLastDelta(_ rawDelta: CostUsageCodexTotals) -> CostUsageCodexTotals {
                guard var remaining = remainingInheritedTotals else { return rawDelta }

                let adjusted = CostUsageCodexTotals(
                    input: max(0, rawDelta.input - remaining.input),
                    cached: max(0, rawDelta.cached - remaining.cached),
                    output: max(0, rawDelta.output - remaining.output))

                remaining.input = max(0, remaining.input - rawDelta.input)
                remaining.cached = max(0, remaining.cached - rawDelta.cached)
                remaining.output = max(0, remaining.output - rawDelta.output)
                remainingInheritedTotals = if remaining.input == 0, remaining.cached == 0,
                                              remaining.output == 0
                {
                    nil
                } else {
                    remaining
                }

                return adjusted
            }

            let handledUnresolvedForkTotal = hasUnresolvedForkBaseline && total != nil
            if hasUnresolvedForkBaseline, let total {
                let currentRawTotals = total
                defer {
                    unresolvedForkTotalWatermark = currentRawTotals
                }
                guard let last else { return }

                let rawLastDelta = last
                let adjustedDelta = if let watermark = unresolvedForkTotalWatermark {
                    Self.codexMinTotals(
                        rawLastDelta,
                        Self.codexTotalDelta(from: watermark, to: currentRawTotals)
                    )
                } else {
                    // The parent file is unavailable, but last_token_usage is
                    // still the fork child's own completed turn. This is the
                    // same conservative baseline used by the live poll path.
                    rawLastDelta
                }
                deltaInput = adjustedDelta.input
                deltaCached = adjustedDelta.cached
                deltaOutput = adjustedDelta.output
                let prev = previousTotals ?? .init(input: 0, cached: 0, output: 0)
                previousTotals = Self.codexAddTotals(prev, adjustedDelta)
                rawTotalsBaseline = previousTotals
            }

            if !handledUnresolvedForkTotal,
               let total,
               forkedFromId != nil,
               !hasUnresolvedForkBaseline
            {
                let rawTotals = total
                let currentTotals: CostUsageCodexTotals = if let inheritedTotals {
                    CostUsageCodexTotals(
                        input: max(0, rawTotals.input - inheritedTotals.input),
                        cached: max(0, rawTotals.cached - inheritedTotals.cached),
                        output: max(0, rawTotals.output - inheritedTotals.output))
                } else {
                    rawTotals
                }
                let delta = sawDivergentTotals
                    ? Self.codexDivergentTotalDelta(
                        rawBaseline: rawTotalsBaseline,
                        countedBaseline: previousTotals,
                        current: currentTotals)
                    : Self.codexTotalDelta(from: rawTotalsBaseline, to: currentTotals)
                deltaInput = delta.input
                deltaCached = delta.cached
                deltaOutput = delta.output
                let prev = previousTotals ?? .init(input: 0, cached: 0, output: 0)
                previousTotals = Self.codexAddTotals(prev, delta)
                rawTotalsBaseline = currentTotals
                if !Self.codexTotalsEqual(rawTotalsBaseline, previousTotals) {
                    sawDivergentTotals = true
                }
                remainingInheritedTotals = nil
            } else if !handledUnresolvedForkTotal, let last {
                let rawDelta = last
                let hadRemainingInheritedTotals = remainingInheritedTotals != nil
                var adjustedDelta = adjustedLastDelta(rawDelta)
                deltaInput = adjustedDelta.input
                deltaCached = adjustedDelta.cached
                deltaOutput = adjustedDelta.output
                let prev = previousTotals ?? .init(input: 0, cached: 0, output: 0)

                if let total, !hasUnresolvedForkBaseline {
                    let rawTotals = total
                    let currentTotals: CostUsageCodexTotals = if let inheritedTotals {
                        CostUsageCodexTotals(
                            input: max(0, rawTotals.input - inheritedTotals.input),
                            cached: max(0, rawTotals.cached - inheritedTotals.cached),
                            output: max(0, rawTotals.output - inheritedTotals.output))
                    } else {
                        rawTotals
                    }
                    let totalDelta = Self.codexTotalDelta(from: rawTotalsBaseline, to: currentTotals)
                    if !hadRemainingInheritedTotals,
                       Self.codexShouldPreferTotalDelta(
                           rawBaseline: rawTotalsBaseline,
                           currentTotal: currentTotals,
                           totalDelta: totalDelta,
                           lastDelta: rawDelta,
                           sawDivergentTotals: sawDivergentTotals)
                    {
                        adjustedDelta = totalDelta
                        deltaInput = adjustedDelta.input
                        deltaCached = adjustedDelta.cached
                        deltaOutput = adjustedDelta.output
                        remainingInheritedTotals = nil
                    }
                    let countedTotals = Self.codexAddTotals(prev, adjustedDelta)
                    previousTotals = countedTotals
                    rawTotalsBaseline = currentTotals
                    if !Self.codexTotalsEqual(currentTotals, countedTotals) {
                        sawDivergentTotals = true
                    }
                } else {
                    let countedTotals = Self.codexAddTotals(prev, adjustedDelta)
                    previousTotals = countedTotals
                    rawTotalsBaseline = countedTotals
                }
            } else if !handledUnresolvedForkTotal, let total {
                let rawTotals = total

                let currentTotals: CostUsageCodexTotals = if let inheritedTotals {
                    CostUsageCodexTotals(
                        input: max(0, rawTotals.input - inheritedTotals.input),
                        cached: max(0, rawTotals.cached - inheritedTotals.cached),
                        output: max(0, rawTotals.output - inheritedTotals.output))
                } else {
                    rawTotals
                }

                let delta = sawDivergentTotals
                    ? Self.codexDivergentTotalDelta(
                        rawBaseline: rawTotalsBaseline,
                        countedBaseline: previousTotals,
                        current: currentTotals)
                    : Self.codexTotalDelta(from: rawTotalsBaseline, to: currentTotals)
                deltaInput = delta.input
                deltaCached = delta.cached
                deltaOutput = delta.output
                let prev = previousTotals ?? .init(input: 0, cached: 0, output: 0)
                previousTotals = Self.codexAddTotals(prev, delta)
                rawTotalsBaseline = currentTotals
                if !Self.codexTotalsEqual(rawTotalsBaseline, previousTotals) {
                    sawDivergentTotals = true
                }
                remainingInheritedTotals = nil
            } else if !handledUnresolvedForkTotal {
                return
            }

            if CostUsageDayRange.isInRange(
                dayKey: dayKey,
                since: range.scanSinceKey,
                until: range.scanUntilKey
            ) {
                tokenEventWatermarks.append(CostUsageTokenEventWatermark(
                    endOffset: line.endOffset,
                    lineFingerprint: CodexTokenObservationCursor.fingerprint(for: line.bytes),
                    eventTimestamp: eventTimestamp,
                    totalTokens: lastTokenEventTotalTokens
                ))
            }
            if deltaInput == 0, deltaCached == 0, deltaOutput == 0 { return }
            let cachedClamp = min(deltaCached, deltaInput)
            let normModel = CostUsagePricing.normalizeCodexModel(model)
            add(
                dayKey: dayKey,
                model: normModel,
                input: deltaInput,
                cached: cachedClamp,
                output: deltaOutput)
            if CostUsageDayRange.isInRange(
                dayKey: dayKey,
                since: range.scanSinceKey,
                until: range.scanUntilKey)
            {
                rows.append(CodexUsageRow(
                    day: dayKey,
                    model: normModel,
                    turnID: record.turnID ?? currentTurnID,
                    input: deltaInput,
                    cached: cachedClamp,
                    output: deltaOutput))
            }
        }

        func handleFastLine(_ fastLine: CodexFastLine, line: CostUsageJsonl.Line) throws {
            switch fastLine {
            case let .sessionMeta(metadata):
                try handleSessionMetadata(metadata)
            case let .turnContext(model):
                if let model {
                    currentModel = model
                }
            case let .taskStarted(turnID):
                currentTurnID = turnID
            case let .tokenCount(record):
                try handleTokenCount(record, line: line)
            }
        }

        let maxLineBytes = 256 * 1024
        let prefixBytes = maxLineBytes

        if startOffset == 0,
           let metadata = try Self.parseCodexSessionMetadata(
               fileURL: fileURL,
               checkCancellation: checkCancellation)
        {
            sessionId = metadata.sessionId
            forkedFromId = metadata.forkedFromId
            if let forkedFromId = metadata.forkedFromId,
               inheritedTotals == nil
            {
                let forkedAt = metadata.forkTimestamp ?? ""
                try resolveForkBaseline(parentSessionId: forkedFromId, forkedAt: forkedAt)
            }
        }

        var parsedBytes: Int64
        do {
            parsedBytes = try CostUsageJsonl.scan(
                fileURL: fileURL,
                offset: startOffset,
                maxLineBytes: maxLineBytes,
                prefixBytes: prefixBytes,
                checkCancellation: checkCancellation,
                stopBeforeLine: { line in
                    guard let through,
                          let timestamp = Self.codexTimestamp(in: line.bytes)
                    else {
                        return false
                    }
                    return timestamp > through
                },
                onLine: { line in
                    if deferredError != nil { return }
                    guard !line.bytes.isEmpty else { return }
                    if line.wasTruncated {
                        // `turn_context` can carry very large prompts, but its model usually appears near the start.
                        if let model = Self.extractCodexTurnContextModel(from: line.bytes) {
                            currentModel = model
                        }
                        return
                    }

                    guard
                        line.bytes.containsAscii(#""type":"event_msg""#)
                        || line.bytes.containsAscii(#""type":"turn_context""#)
                        || line.bytes.containsAscii(#""type":"session_meta""#)
                    else { return }

                    if line.bytes.containsAscii(#""type":"event_msg""#),
                       !line.bytes.containsAscii(#""token_count""#),
                       !line.bytes.containsAscii(#""task_started""#)
                    {
                        return
                    }

                    if let fastLine = Self.parseCodexFastLine(line.bytes) {
                        do {
                            try handleFastLine(fastLine, line: line)
                        } catch {
                            deferredError = error
                        }
                        return
                    }

                    autoreleasepool {
                        guard
                            let obj = (try? JSONSerialization.jsonObject(with: line.bytes)) as? [String: Any],
                            let type = obj["type"] as? String
                        else { return }

                        if type == "session_meta" {
                            let payload = obj["payload"] as? [String: Any]
                            if sessionId == nil {
                                sessionId = payload?["session_id"] as? String
                                    ?? payload?["sessionId"] as? String
                                    ?? payload?["id"] as? String
                                    ?? obj["session_id"] as? String
                                    ?? obj["sessionId"] as? String
                                    ?? obj["id"] as? String
                            }
                            if forkedFromId == nil {
                                forkedFromId = Self.codexForkParentId(from: payload)
                            }
                            if let forkedFromId {
                                let forkedAt = payload?["timestamp"] as? String
                                    ?? obj["timestamp"] as? String
                                    ?? ""
                                do {
                                    try resolveForkBaseline(parentSessionId: forkedFromId, forkedAt: forkedAt)
                                } catch {
                                    deferredError = error
                                    return
                                }
                            }
                            return
                        }

                        guard let tsText = obj["timestamp"] as? String else { return }
                        guard let dayKey = Self.dayKeyFromTimestamp(tsText) ?? Self.dayKeyFromParsedISO(tsText)
                        else { return }

                        if type == "turn_context" {
                            if let payload = obj["payload"] as? [String: Any] {
                                if let model = payload["model"] as? String {
                                    currentModel = model
                                } else if let info = payload["info"] as? [String: Any],
                                          let model = info["model"] as? String
                                {
                                    currentModel = model
                                }
                            }
                            return
                        }

                        guard type == "event_msg" else { return }
                        guard let payload = obj["payload"] as? [String: Any] else { return }
                        if (payload["type"] as? String) == "task_started" {
                            currentTurnID = Self.codexTurnID(from: payload)
                            return
                        }
                        guard (payload["type"] as? String) == "token_count" else { return }

                        let info = payload["info"] as? [String: Any]
                        let modelFromInfo = info?["model"] as? String
                            ?? info?["model_name"] as? String
                            ?? payload["model"] as? String
                            ?? obj["model"] as? String
                        let model = currentModel ?? modelFromInfo ?? "gpt-5"

                        func toInt(_ v: Any?) -> Int {
                            if let n = v as? NSNumber { return n.intValue }
                            return 0
                        }

                        func tokenTotals(_ usage: [String: Any]) -> CostUsageCodexTotals {
                            CostUsageCodexTotals(
                                input: max(0, toInt(usage["input_tokens"])),
                                cached: max(0, toInt(usage["cached_input_tokens"] ?? usage["cache_read_input_tokens"])),
                                output: max(0, toInt(usage["output_tokens"])))
                        }

                        let total = (info?["total_token_usage"] as? [String: Any])
                        let last = (info?["last_token_usage"] as? [String: Any])

                        lastTokenEventEndOffset = line.endOffset
                        lastTokenEventFingerprint = CodexTokenObservationCursor.fingerprint(for: line.bytes)
                        lastTokenEventTimestamp = Self.dateFromTimestamp(tsText)
                        lastTokenEventTotalTokens = total.map {
                            let totals = tokenTotals($0)
                            return max(0, totals.input) + max(0, totals.output)
                        }
                        var deltaInput = 0
                        var deltaCached = 0
                        var deltaOutput = 0

                        func adjustedLastDelta(_ rawDelta: CostUsageCodexTotals) -> CostUsageCodexTotals {
                            guard var remaining = remainingInheritedTotals else { return rawDelta }

                            let adjusted = CostUsageCodexTotals(
                                input: max(0, rawDelta.input - remaining.input),
                                cached: max(0, rawDelta.cached - remaining.cached),
                                output: max(0, rawDelta.output - remaining.output))

                            remaining.input = max(0, remaining.input - rawDelta.input)
                            remaining.cached = max(0, remaining.cached - rawDelta.cached)
                            remaining.output = max(0, remaining.output - rawDelta.output)
                            remainingInheritedTotals = if remaining.input == 0, remaining.cached == 0,
                                                          remaining.output == 0
                            {
                                nil
                            } else {
                                remaining
                            }

                            return adjusted
                        }

                        let handledUnresolvedForkTotal = hasUnresolvedForkBaseline && total != nil
                        if hasUnresolvedForkBaseline, let total {
                            let currentRawTotals = tokenTotals(total)
                            defer {
                                unresolvedForkTotalWatermark = currentRawTotals
                            }
                            guard let last else { return }

                            let rawLastDelta = tokenTotals(last)
                            let adjustedDelta = if let watermark = unresolvedForkTotalWatermark {
                                Self.codexMinTotals(
                                    rawLastDelta,
                                    Self.codexTotalDelta(from: watermark, to: currentRawTotals)
                                )
                            } else {
                                rawLastDelta
                            }
                            deltaInput = adjustedDelta.input
                            deltaCached = adjustedDelta.cached
                            deltaOutput = adjustedDelta.output
                            let prev = previousTotals ?? .init(input: 0, cached: 0, output: 0)
                            previousTotals = Self.codexAddTotals(prev, adjustedDelta)
                            rawTotalsBaseline = previousTotals
                        }

                        if !handledUnresolvedForkTotal,
                           let total,
                           forkedFromId != nil,
                           !hasUnresolvedForkBaseline
                        {
                            let rawTotals = tokenTotals(total)
                            let currentTotals: CostUsageCodexTotals = if let inheritedTotals {
                                CostUsageCodexTotals(
                                    input: max(0, rawTotals.input - inheritedTotals.input),
                                    cached: max(0, rawTotals.cached - inheritedTotals.cached),
                                    output: max(0, rawTotals.output - inheritedTotals.output))
                            } else {
                                rawTotals
                            }
                            let delta = sawDivergentTotals
                                ? Self.codexDivergentTotalDelta(
                                    rawBaseline: rawTotalsBaseline,
                                    countedBaseline: previousTotals,
                                    current: currentTotals)
                                : Self.codexTotalDelta(from: rawTotalsBaseline, to: currentTotals)
                            deltaInput = delta.input
                            deltaCached = delta.cached
                            deltaOutput = delta.output
                            let prev = previousTotals ?? .init(input: 0, cached: 0, output: 0)
                            previousTotals = Self.codexAddTotals(prev, delta)
                            rawTotalsBaseline = currentTotals
                            if !Self.codexTotalsEqual(rawTotalsBaseline, previousTotals) {
                                sawDivergentTotals = true
                            }
                            remainingInheritedTotals = nil
                        } else if !handledUnresolvedForkTotal, let last {
                            let rawDelta = CostUsageCodexTotals(
                                input: max(0, toInt(last["input_tokens"])),
                                cached: max(0, toInt(last["cached_input_tokens"] ?? last["cache_read_input_tokens"])),
                                output: max(0, toInt(last["output_tokens"])))
                            let hadRemainingInheritedTotals = remainingInheritedTotals != nil
                            var adjustedDelta = adjustedLastDelta(rawDelta)
                            deltaInput = adjustedDelta.input
                            deltaCached = adjustedDelta.cached
                            deltaOutput = adjustedDelta.output
                            let prev = previousTotals ?? .init(input: 0, cached: 0, output: 0)

                            if let total, !hasUnresolvedForkBaseline {
                                let rawTotals = tokenTotals(total)
                                let currentTotals: CostUsageCodexTotals = if let inheritedTotals {
                                    CostUsageCodexTotals(
                                        input: max(0, rawTotals.input - inheritedTotals.input),
                                        cached: max(0, rawTotals.cached - inheritedTotals.cached),
                                        output: max(0, rawTotals.output - inheritedTotals.output))
                                } else {
                                    rawTotals
                                }
                                let totalDelta = Self.codexTotalDelta(from: rawTotalsBaseline, to: currentTotals)
                                if !hadRemainingInheritedTotals,
                                   Self.codexShouldPreferTotalDelta(
                                       rawBaseline: rawTotalsBaseline,
                                       currentTotal: currentTotals,
                                       totalDelta: totalDelta,
                                       lastDelta: rawDelta,
                                       sawDivergentTotals: sawDivergentTotals)
                                {
                                    adjustedDelta = totalDelta
                                    deltaInput = adjustedDelta.input
                                    deltaCached = adjustedDelta.cached
                                    deltaOutput = adjustedDelta.output
                                    remainingInheritedTotals = nil
                                }
                                let countedTotals = Self.codexAddTotals(prev, adjustedDelta)
                                previousTotals = countedTotals
                                rawTotalsBaseline = currentTotals
                                if !Self.codexTotalsEqual(currentTotals, countedTotals) {
                                    sawDivergentTotals = true
                                }
                            } else {
                                let countedTotals = Self.codexAddTotals(prev, adjustedDelta)
                                previousTotals = countedTotals
                                rawTotalsBaseline = countedTotals
                            }
                        } else if !handledUnresolvedForkTotal, let total {
                            let rawTotals = tokenTotals(total)

                            let currentTotals: CostUsageCodexTotals = if let inheritedTotals {
                                CostUsageCodexTotals(
                                    input: max(0, rawTotals.input - inheritedTotals.input),
                                    cached: max(0, rawTotals.cached - inheritedTotals.cached),
                                    output: max(0, rawTotals.output - inheritedTotals.output))
                            } else {
                                rawTotals
                            }

                            let delta = sawDivergentTotals
                                ? Self.codexDivergentTotalDelta(
                                    rawBaseline: rawTotalsBaseline,
                                    countedBaseline: previousTotals,
                                    current: currentTotals)
                                : Self.codexTotalDelta(from: rawTotalsBaseline, to: currentTotals)
                            deltaInput = delta.input
                            deltaCached = delta.cached
                            deltaOutput = delta.output
                            let prev = previousTotals ?? .init(input: 0, cached: 0, output: 0)
                            previousTotals = Self.codexAddTotals(prev, delta)
                            rawTotalsBaseline = currentTotals
                            if !Self.codexTotalsEqual(rawTotalsBaseline, previousTotals) {
                                sawDivergentTotals = true
                            }
                            remainingInheritedTotals = nil
                        } else if !handledUnresolvedForkTotal {
                            return
                        }

                        if CostUsageDayRange.isInRange(
                            dayKey: dayKey,
                            since: range.scanSinceKey,
                            until: range.scanUntilKey
                        ) {
                            tokenEventWatermarks.append(CostUsageTokenEventWatermark(
                                endOffset: line.endOffset,
                                lineFingerprint: CodexTokenObservationCursor.fingerprint(for: line.bytes),
                                eventTimestamp: lastTokenEventTimestamp,
                                totalTokens: lastTokenEventTotalTokens
                            ))
                        }
                        if deltaInput == 0, deltaCached == 0, deltaOutput == 0 { return }
                        let cachedClamp = min(deltaCached, deltaInput)
                        let normModel = CostUsagePricing.normalizeCodexModel(model)
                        add(
                            dayKey: dayKey,
                            model: normModel,
                            input: deltaInput,
                            cached: cachedClamp,
                            output: deltaOutput)
                        if CostUsageDayRange.isInRange(
                            dayKey: dayKey,
                            since: range.scanSinceKey,
                            until: range.scanUntilKey)
                        {
                            rows.append(CodexUsageRow(
                                day: dayKey,
                                model: normModel,
                                turnID: Self.codexTurnID(from: payload) ?? currentTurnID,
                                input: deltaInput,
                                cached: cachedClamp,
                                output: deltaOutput))
                        }
                    }
                })
            if let deferredError {
                throw deferredError
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            self.log.warning(
                "Codex cost usage failed while scanning session file",
                metadata: ["path": fileURL.path, "error": error.localizedDescription])
            throw error
        }

        return CodexParseResult(
            days: days,
            parsedBytes: parsedBytes,
            lastModel: currentModel,
            lastTotals: sawDivergentTotals && !Self.codexTotalsEqual(rawTotalsBaseline, previousTotals)
                ? nil
                : previousTotals,
            lastCountedTotals: previousTotals,
            lastRawTotalsBaseline: rawTotalsBaseline,
            hasDivergentTotals: sawDivergentTotals && !Self.codexTotalsEqual(rawTotalsBaseline, previousTotals),
            lastCodexTurnID: currentTurnID,
            sessionId: sessionId,
            forkedFromId: forkedFromId,
            lastTokenEventEndOffset: lastTokenEventEndOffset,
            lastTokenEventFingerprint: lastTokenEventFingerprint,
            lastTokenEventTimestamp: lastTokenEventTimestamp,
            lastTokenEventTotalTokens: lastTokenEventTotalTokens,
            tokenEventWatermarks: tokenEventWatermarks,
            rows: rows)
    }

    private static func codexTurnID(from payload: [String: Any]) -> String? {
        if let turnID = payload["turn_id"] as? String ?? payload["turnId"] as? String ?? payload["id"] as? String {
            return turnID
        }
        if let info = payload["info"] as? [String: Any] {
            return info["turn_id"] as? String ?? info["turnId"] as? String ?? info["id"] as? String
        }
        return nil
    }

    private static func scanCodexFile(
        fileURL: URL,
        context: CodexFileScanContext,
        cache: inout CostUsageCache,
        state: inout CodexScanState) throws
    {
        try context.checkCancellation?()
        let metadata = Self.codexFileMetadata(fileURL: fileURL)
        let cached = cache.files[metadata.path]
        if let cached,
           cached.codexInventoryOnly == true,
           let sessionId = cached.sessionId,
           !sessionId.isEmpty,
           try Self.resolveChangedCodexInventorySentinel(
               fileURL: fileURL,
               metadata: metadata,
               cached: cached,
               sessionId: sessionId,
               context: context,
               cache: &cache
           ) {
            return
        }
        if let fileId = metadata.fileId, state.seenFileIds.contains(fileId) {
            Self.dropCachedCodexFile(path: metadata.path, cached: cache.files[metadata.path], cache: &cache)
            return
        }

        if let cachedSessionId = cached?.sessionId, state.seenSessionIds.contains(cachedSessionId) {
            throw Self.codexAmbiguousDuplicateSessionError(
                sessionId: cachedSessionId,
                path: metadata.path
            )
        }

        let input = CodexFileScanInput(fileURL: fileURL, metadata: metadata, cached: cached)
        if Self.keepCachedCodexFileIfFresh(input: input, context: context, cache: &cache, state: &state) {
            return
        }
        if try Self.appendCodexFileIncrementIfPossible(input: input, context: context, cache: &cache, state: &state) {
            return
        }
        try Self.rescanCodexFile(input: input, context: context, cache: &cache, state: &state)
    }

    private static func resolveChangedCodexInventorySentinel(
        fileURL: URL,
        metadata: CodexFileMetadata,
        cached: CostUsageFileUsage,
        sessionId: String,
        context: CodexFileScanContext,
        cache: inout CostUsageCache
    ) throws -> Bool {
        let owner = cache.files
            .filter { path, usage in
                path != metadata.path
                    && usage.codexInventoryOnly != true
                    && usage.sessionId == sessionId
            }
            .sorted(by: { $0.key < $1.key })
            .first

        guard let owner else {
            throw Self.codexAmbiguousDuplicateSessionError(
                sessionId: sessionId,
                path: metadata.path
            )
        }
        let ownerURL = URL(fileURLWithPath: owner.key)
        let ownerMetadata = Self.codexFileMetadata(fileURL: ownerURL)
        guard ownerMetadata.fileId != nil else {
            throw Self.codexAmbiguousDuplicateSessionError(
                sessionId: sessionId,
                path: metadata.path
            )
        }
        let relationship = try Self.codexFilePrefixRelationship(
            lhsURL: fileURL,
            rhsURL: ownerURL,
            checkCancellation: context.checkCancellation
        )
        guard relationship == .identical || relationship == .lhsIsPrefix else {
            // Role changes must happen in the pre-scan duplicate reconciliation
            // pass so the fork resolver cannot retain snapshots from an old owner.
            throw Self.codexAmbiguousDuplicateSessionError(
                sessionId: sessionId,
                path: metadata.path
            )
        }
        cache.files[metadata.path] = Self.makeFileUsage(
            mtimeUnixMs: metadata.mtimeUnixMs,
            size: metadata.size,
            days: [:],
            parsedBytes: metadata.size,
            sessionId: sessionId,
            forkedFromId: cached.forkedFromId,
            sourceGeneration: metadata.fileId
                ?? fileURL.standardizedFileURL.resolvingSymlinksInPath().path,
            sourceStatFingerprint: metadata.statFingerprint,
            sourceChangeTimeNanoseconds: metadata.changeTimeNanoseconds,
            codexInventoryOnly: true
        )
        return true
    }

    private static func makeCodexRefreshPlan(
        cache: CostUsageCache,
        range: CostUsageDayRange,
        now: Date,
        nowMs: Int64,
        options: Options) throws -> CodexRefreshPlan
    {
        let refreshMs = Int64(max(0, options.refreshMinIntervalSeconds) * 1000)
        let roots = self.codexSessionsRoots(options: options)
        let rootsFingerprint = Self.codexRootsFingerprint(roots)
        let rootsChanged = cache.roots != rootsFingerprint
        let directoryFingerprintsChanged = if let cachedFingerprints = cache.codexSessionDirectoryFingerprints {
            try Self.currentCodexDirectoryFingerprints(paths: cachedFingerprints.keys) != cachedFingerprints
        } else {
            true
        }
        let needsSessionInventory = options.forceRescan
            || cache.codexSessionInventoryComplete != true
            || rootsChanged
            || directoryFingerprintsChanged
        let windowExpanded = Self.requestedWindowExpandsCache(range: range, cache: cache)
        let needsCostCacheMigration = cache.files.values.contains { Self.needsCodexCostCache($0, range: range) }
        let modelsDevLoad = ModelsDevCache.load(now: now, cacheRoot: options.cacheRoot)
        let modelsDevCatalog = modelsDevLoad.artifact?.catalog
        let codexPricingKey = Self.codexPricingKey(modelsDevArtifact: modelsDevLoad.artifact)
        let codexPriorityMetadataKey = Self.codexPriorityMetadataKey(databaseURL: options.codexTraceDatabaseURL)
        let hasPriorityMetadata = codexPriorityMetadataKey.hasPrefix("sqlite:")
        let pricingChanged = cache.codexPricingKey != nil && cache.codexPricingKey != codexPricingKey
        let priorityMetadataChanged = Self.codexPriorityMetadataChanged(
            old: cache.codexPriorityMetadataKey,
            new: codexPriorityMetadataKey)
        let needsTurnIDCacheMigration = hasPriorityMetadata && cache.files.values.contains {
            $0.codexTurnIDs == nil && $0.touchesCodexScanWindow(
                sinceKey: range.scanSinceKey,
                untilKey: range.scanUntilKey)
        }
        let shouldInspectPriorityTurns = options.forceRescan
            || windowExpanded
            || rootsChanged
            || needsCostCacheMigration
            || needsTurnIDCacheMigration
            || pricingChanged
            || priorityMetadataChanged
            || refreshMs == 0
            || cache.lastScanUnixMs == 0
            || nowMs - cache.lastScanUnixMs > refreshMs
        let priorityTurns = shouldInspectPriorityTurns ? Self.codexPriorityTurns(
            databaseURL: options.codexTraceDatabaseURL,
            sinceDayKey: range.scanSinceKey,
            untilDayKey: range.scanUntilKey) : [:]
        let priorityTurnKeys = Self.codexPriorityTurnKeys(priorityTurns)
        let priorityTurnIDsByDay = Self.codexPriorityTurnIDsByDay(priorityTurns)
        let priorityTurnsChanged = shouldInspectPriorityTurns
            && hasPriorityMetadata
            && Self.codexPriorityTurnKeysChanged(
                old: cache.codexPriorityTurnKeys,
                new: priorityTurnKeys,
                range: range)
        let changedPriorityTurnIDs = shouldInspectPriorityTurns && hasPriorityMetadata
            ? Self.changedPriorityTurnIDs(
                old: cache.codexPriorityTurnIDsByDay,
                new: priorityTurnIDsByDay,
                oldKeys: cache.codexPriorityTurnKeys,
                newKeys: priorityTurnKeys,
                range: range)
            : []
        let shouldRefresh = options.forceRescan
            || windowExpanded
            || rootsChanged
            || needsSessionInventory
            || needsCostCacheMigration
            || needsTurnIDCacheMigration
            || pricingChanged
            || priorityMetadataChanged
            || priorityTurnsChanged
            || refreshMs == 0
            || cache.lastScanUnixMs == 0
            || nowMs - cache.lastScanUnixMs > refreshMs

        return CodexRefreshPlan(
            refreshMs: refreshMs,
            roots: roots,
            rootsFingerprint: rootsFingerprint,
            rootsChanged: rootsChanged,
            needsSessionInventory: needsSessionInventory,
            windowExpanded: windowExpanded,
            needsCostCacheMigration: needsCostCacheMigration,
            modelsDevCatalog: modelsDevCatalog,
            codexPricingKey: codexPricingKey,
            codexPriorityMetadataKey: codexPriorityMetadataKey,
            hasPriorityMetadata: hasPriorityMetadata,
            priorityTurns: priorityTurns,
            priorityTurnKeys: priorityTurnKeys,
            priorityTurnIDsByDay: priorityTurnIDsByDay,
            pricingChanged: pricingChanged,
            priorityMetadataChanged: priorityMetadataChanged,
            priorityTurnsChanged: priorityTurnsChanged,
            needsTurnIDCacheMigration: needsTurnIDCacheMigration,
            changedPriorityTurnIDs: changedPriorityTurnIDs,
            shouldRefresh: shouldRefresh)
    }

    private static func loadCodexDaily(
        range: CostUsageDayRange,
        now: Date,
        options: Options,
        checkCancellation: CancellationCheck?) throws -> CostUsageDailyReport
    {
        var cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: options.cacheRoot)
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let plan = try Self.makeCodexRefreshPlan(
            cache: cache,
            range: range,
            now: now,
            nowMs: nowMs,
            options: options
        )

        if plan.shouldRefresh {
            try checkCancellation?()
            if options.forceRescan {
                cache = CostUsageCache()
            }

            let hadCompletedSessionInventory = cache.codexSessionInventoryComplete == true
            let sessionInventory = plan.needsSessionInventory
                ? try Self.inventoryCodexSessionFiles(
                    roots: plan.roots,
                    afterMetadataHook: options.codexInventoryAfterMetadataHook,
                    checkCancellation: checkCancellation
                )
                : nil
            let inventoryPaths = Set(sessionInventory?.files.map(\.metadata.path) ?? [])
            var newlyDiscoveredInventoryPaths = Set<String>()
            var promotedInventoryOwnerPaths = Set<String>()
            var transferredInventoryOwnerPaths = Set<String>()
            var inventoryQuarantinedPaths = Set<String>()

            if let sessionInventory {
                let cachedOwnersBeforeInventory = cache.files.filter {
                    $0.value.codexInventoryOnly != true
                        && $0.value.sessionId?.isEmpty == false
                }
                var previousOwnerUsageBySessionId: [String: CostUsageFileUsage] = [:]
                for (_, usage) in cachedOwnersBeforeInventory {
                    if let sessionId = usage.sessionId, !sessionId.isEmpty {
                        previousOwnerUsageBySessionId[sessionId] = usage
                    }
                }
                var cachedEntriesByGeneration: [String: [(path: String, usage: CostUsageFileUsage)]] = [:]
                for (path, usage) in cache.files {
                    guard let generation = usage.sourceGeneration else { continue }
                    cachedEntriesByGeneration[generation, default: []].append((path, usage))
                }
                var relocatedCachePathByOriginalPath: [String: String] = [:]
                var prunedInventoryOwnerPaths = Set<String>()
                // Preserve aggregates and exact frontiers across the normal
                // sessions -> archived_sessions rename. A destination path can
                // already have a stale cache entry when an atomic replacement
                // reuses that name, so generation identity (not key presence)
                // decides whether the owner ledger still needs relocating.
                for entry in sessionInventory.files.sorted(by: { $0.metadata.path < $1.metadata.path }) {
                    guard let generation = entry.metadata.fileId else { continue }
                    if let existing = cache.files[entry.metadata.path],
                       existing.sourceGeneration == generation,
                       existing.codexInventoryOnly != true {
                        continue
                    }
                    let relocationCandidates = (cachedEntriesByGeneration[generation] ?? [])
                        .filter {
                            !inventoryPaths.contains($0.path)
                                && $0.usage.codexInventoryOnly != true
                        }
                        .sorted { $0.path < $1.path }
                    guard let oldPath = relocationCandidates
                        .first(where: { cache.files[$0.path] != nil })?.path,
                          let oldUsage = cache.files.removeValue(forKey: oldPath)
                    else { continue }
                    if let displaced = cache.files.removeValue(forKey: entry.metadata.path) {
                        Self.applyFileDays(cache: &cache, fileDays: displaced.days, sign: -1)
                        if displaced.codexInventoryOnly != true {
                            prunedInventoryOwnerPaths.insert(entry.metadata.path)
                        }
                    }
                    cache.files[entry.metadata.path] = oldUsage
                    relocatedCachePathByOriginalPath[oldPath] = entry.metadata.path
                }

                // Inventory stubs outside the report window are still real
                // cache entries; remove their tombstones when paths disappear.
                for path in Array(cache.files.keys) where !inventoryPaths.contains(path) {
                    guard let old = cache.files.removeValue(forKey: path) else { continue }
                    Self.applyFileDays(cache: &cache, fileDays: old.days, sign: -1)
                    if old.codexInventoryOnly != true {
                        prunedInventoryOwnerPaths.insert(path)
                    }
                }

                let ownerPathBySessionID = try Self.codexInventoryOwnerPaths(
                    files: sessionInventory.files,
                    cache: cache,
                    previousOwnerUsageBySessionId: previousOwnerUsageBySessionId,
                    quarantinedPaths: &inventoryQuarantinedPaths,
                    checkCancellation: checkCancellation
                )

                var transferredUsageByReplacementPath: [String: CostUsageFileUsage] = [:]
                var transferredOriginalOwnerPaths = Set<String>()
                for (oldPath, oldOwner) in cachedOwnersBeforeInventory {
                    guard let oldSessionID = oldOwner.sessionId, !oldSessionID.isEmpty else { continue }
                    let relocatedEntry = relocatedCachePathByOriginalPath[oldPath].flatMap { relocatedPath in
                        sessionInventory.files.first(where: { $0.metadata.path == relocatedPath })
                    }
                    let sameGenerationEntry = relocatedEntry ?? oldOwner.sourceGeneration.flatMap { generation in
                        let matches = sessionInventory.files.filter { $0.metadata.fileId == generation }
                        return matches.first(where: {
                            $0.metadata.path == ownerPathBySessionID[oldSessionID]
                        }) ?? matches.sorted(by: { $0.metadata.path < $1.metadata.path }).first
                    }
                    let currentEntry = sameGenerationEntry
                        ?? sessionInventory.files.first(where: { $0.metadata.path == oldPath })
                    let retainedOwnerPath = currentEntry.flatMap { entry -> String? in
                        guard entry.sessionId == oldSessionID,
                              ownerPathBySessionID[oldSessionID] == entry.metadata.path,
                              let cachedAtCurrentPath = cache.files[entry.metadata.path],
                              cachedAtCurrentPath.codexInventoryOnly != true,
                              cachedAtCurrentPath.sessionId == oldSessionID,
                              cachedAtCurrentPath.sourceGeneration == oldOwner.sourceGeneration
                        else { return nil }
                        return entry.metadata.path
                    }
                    if retainedOwnerPath != nil { continue }

                    if let replacementPath = ownerPathBySessionID[oldSessionID],
                       let replacement = sessionInventory.files.first(where: {
                           $0.metadata.path == replacementPath
                        }) {
                        let isUncommittedEmptyOwnerStub = oldOwner.days.isEmpty
                            && oldOwner.committedPrefixFingerprint == nil
                        if !isUncommittedEmptyOwnerStub {
                            guard try Self.codexFileMatchesCommittedFrontier(
                                fileURL: replacement.url,
                                cached: oldOwner,
                                checkCancellation: checkCancellation
                            ) else {
                                throw Self.codexAmbiguousDuplicateSessionError(
                                    sessionId: oldSessionID,
                                    path: replacementPath
                                )
                            }
                        }
                        let replacementGeneration = replacement.metadata.fileId
                            ?? replacement.url.standardizedFileURL.resolvingSymlinksInPath().path
                        let transferred: CostUsageFileUsage
                        if isUncommittedEmptyOwnerStub {
                            // A cold/forced inventory deliberately records
                            // dormant owners without parsing their bytes. The
                            // duplicate planner already proved that this chosen
                            // replacement covers the old file byte-for-byte, so
                            // move only the empty identity and force a full scan.
                            transferred = Self.makeFileUsage(
                                mtimeUnixMs: replacement.metadata.mtimeUnixMs,
                                size: replacement.metadata.size,
                                days: [:],
                                parsedBytes: 0,
                                sessionId: oldSessionID,
                                forkedFromId: replacement.forkedFromId,
                                sourceGeneration: replacementGeneration,
                                sourceStatFingerprint: replacement.metadata.statFingerprint,
                                sourceChangeTimeNanoseconds: replacement.metadata.changeTimeNanoseconds,
                                codexInventoryOnly: false
                            )
                        } else {
                            var value = oldOwner
                            value.sessionId = oldSessionID
                            value.forkedFromId = replacement.forkedFromId
                            value.sourceGeneration = replacementGeneration
                            value.sourceStatFingerprint = replacement.metadata.statFingerprint
                            value.sourceChangeTimeNanoseconds = replacement.metadata.changeTimeNanoseconds
                            value.codexInventoryOnly = false
                            value.codexDuplicateQuarantined = nil
                            transferred = value
                        }
                        transferredUsageByReplacementPath[replacementPath] = transferred
                        let aggregateOwnerCachePath = relocatedCachePathByOriginalPath[oldPath] ?? oldPath
                        if prunedInventoryOwnerPaths.contains(aggregateOwnerCachePath) {
                            Self.applyFileDays(cache: &cache, fileDays: oldOwner.days, sign: 1)
                        } else {
                            transferredOriginalOwnerPaths.insert(aggregateOwnerCachePath)
                        }
                    } else if let currentEntry, currentEntry.sessionId == nil {
                        throw Self.codexMissingSessionMetadataError(
                            previousSessionId: oldSessionID,
                            path: currentEntry.metadata.path
                        )
                    }
                }

                // Persist every path/generation. Session identity chooses one
                // aggregate owner; duplicate paths and malformed/no-meta files
                // remain metadata-only sentinels so later appends cannot vanish.
                for entry in sessionInventory.files.sorted(by: { $0.metadata.path < $1.metadata.path }) {
                    let path = entry.metadata.path
                    let sessionID = entry.sessionId.flatMap { $0.isEmpty ? nil : $0 }
                    let isOwner = sessionID.map { ownerPathBySessionID[$0] == path } ?? false
                    let shouldBeInventoryOnly = !isOwner
                    if let old = cache.files[path] {
                        if old.codexInventoryOnly != true,
                           let previousSessionID = old.sessionId,
                           !previousSessionID.isEmpty,
                           sessionID == nil,
                           ownerPathBySessionID[previousSessionID] == nil {
                            throw Self.codexMissingSessionMetadataError(
                                previousSessionId: previousSessionID,
                                path: path
                            )
                        }
                        let sameIdentity = old.sessionId == sessionID
                            && old.sourceGeneration == entry.metadata.fileId
                            && old.sourceStatFingerprint == entry.metadata.statFingerprint
                            && old.sourceChangeTimeNanoseconds == entry.metadata.changeTimeNanoseconds
                        let sameRole = (old.codexInventoryOnly == true) == shouldBeInventoryOnly
                        let preservesOwnerLedgerAcrossGeneration = old.codexInventoryOnly != true
                            && !shouldBeInventoryOnly
                            && old.sessionId == sessionID
                        if (sameIdentity && sameRole || preservesOwnerLedgerAcrossGeneration),
                           transferredUsageByReplacementPath[path] == nil,
                           !inventoryQuarantinedPaths.contains(path) {
                            continue
                        }
                        if old.codexInventoryOnly != true,
                           !transferredOriginalOwnerPaths.contains(path) {
                            Self.applyFileDays(cache: &cache, fileDays: old.days, sign: -1)
                        }
                        if isOwner { promotedInventoryOwnerPaths.insert(path) }
                    } else {
                        newlyDiscoveredInventoryPaths.insert(path)
                    }

                    if var transferred = transferredUsageByReplacementPath[path] {
                        transferred.sessionId = sessionID
                        transferred.forkedFromId = entry.forkedFromId
                        transferred.codexInventoryOnly = false
                        transferred.codexDuplicateQuarantined = nil
                        cache.files[path] = transferred
                        promotedInventoryOwnerPaths.insert(path)
                        transferredInventoryOwnerPaths.insert(path)
                        continue
                    }

                    cache.files[path] = Self.makeFileUsage(
                        mtimeUnixMs: entry.metadata.mtimeUnixMs,
                        size: entry.metadata.size,
                        days: [:],
                        // No-meta sentinels deliberately remain deferred so a
                        // repaired header is probed on a later refresh.
                        parsedBytes: sessionID == nil || promotedInventoryOwnerPaths.contains(path)
                            ? 0
                            : entry.metadata.size,
                        sessionId: sessionID,
                        forkedFromId: entry.forkedFromId,
                        sourceGeneration: entry.metadata.fileId,
                        sourceStatFingerprint: entry.metadata.statFingerprint,
                        sourceChangeTimeNanoseconds: entry.metadata.changeTimeNanoseconds,
                        codexInventoryOnly: shouldBeInventoryOnly,
                        codexDuplicateQuarantined: inventoryQuarantinedPaths.contains(path)
                            ? true
                            : nil
                    )
                }
            }

            let cachedSinceKey = cache.scanSinceKey
            let cachedUntilKey = cache.scanUntilKey
            let shouldRunColdCacheLookback = cache.files.isEmpty || plan.rootsChanged
            let coldCacheLookbackStart = Self.parseDayKey(range.scanSinceKey)
                .map { Calendar.current.startOfDay(for: $0) }
            var seenPaths: Set<String> = []
            var files: [URL] = []
            for root in plan.roots {
                let rootFiles = try Self.listCodexSessionFiles(
                    root: root,
                    scanSinceKey: range.scanSinceKey,
                    scanUntilKey: range.scanUntilKey,
                    includeRecursive: options.forceRescan)
                for fileURL in rootFiles.sorted(by: { $0.path < $1.path }) where !seenPaths.contains(fileURL.path) {
                    if let sentinel = cache.files[fileURL.path], sentinel.codexInventoryOnly == true {
                        let metadata = Self.codexFileMetadata(fileURL: fileURL)
                        let currentGeneration = metadata.fileId
                            ?? fileURL.standardizedFileURL.resolvingSymlinksInPath().path
                        let parsedBytes = sentinel.parsedBytes ?? sentinel.size
                        let changedOrDeferred = sentinel.sourceGeneration != currentGeneration
                            || sentinel.sourceStatFingerprint != metadata.statFingerprint
                            || sentinel.sourceChangeTimeNanoseconds != metadata.changeTimeNanoseconds
                            || sentinel.mtimeUnixMs != metadata.mtimeUnixMs
                            || sentinel.size != metadata.size
                            || parsedBytes < metadata.size
                        guard changedOrDeferred else { continue }
                    }
                    if newlyDiscoveredInventoryPaths.contains(fileURL.path),
                       cache.files[fileURL.path]?.codexInventoryOnly != true {
                        // The inventory stub only captured metadata. A file
                        // selected by the active window must still be parsed.
                        cache.files[fileURL.path]?.parsedBytes = 0
                    }
                    seenPaths.insert(fileURL.path)
                    files.append(fileURL)
                }

            }

            if let sessionInventory {
                for entry in sessionInventory.files.sorted(by: { $0.metadata.path < $1.metadata.path }) {
                    if cache.files[entry.metadata.path]?.codexInventoryOnly == true,
                       entry.sessionId != nil {
                        // A stable duplicate is represented by its sentinel;
                        // only a later metadata change should make it enter the
                        // scan path and trigger ambiguity handling.
                        continue
                    }
                    let isNewPath = newlyDiscoveredInventoryPaths.contains(entry.metadata.path)
                    let wasModifiedInLookback = coldCacheLookbackStart.map {
                        Date(timeIntervalSince1970: Double(entry.metadata.mtimeUnixMs) / 1000) >= $0
                    } ?? false
                    let shouldScan = promotedInventoryOwnerPaths.contains(entry.metadata.path)
                        || (shouldRunColdCacheLookback && wasModifiedInLookback)
                        || (hadCompletedSessionInventory && isNewPath)
                    guard shouldScan, seenPaths.insert(entry.metadata.path).inserted else { continue }
                    if cache.files[entry.metadata.path]?.codexInventoryOnly != true,
                       !transferredInventoryOwnerPaths.contains(entry.metadata.path) {
                        cache.files[entry.metadata.path]?.parsedBytes = 0
                    }
                    files.append(entry.url)
                }
            }

            for fileURL in Self.cachedCodexSessionFiles(
                cache: cache,
                range: range,
                roots: plan.roots,
                excludingPaths: seenPaths)
                .sorted(by: { $0.path < $1.path })
            {
                seenPaths.insert(fileURL.path)
                files.append(fileURL)
            }

            let duplicateReconciliation = try Self.reconcileCodexDuplicateRolesBeforeScan(
                cache: &cache,
                checkCancellation: checkCancellation
            )
            if !duplicateReconciliation.quarantinedPaths.isEmpty {
                files.removeAll { duplicateReconciliation.quarantinedPaths.contains($0.path) }
                seenPaths.subtract(duplicateReconciliation.quarantinedPaths)
            }
            for fileURL in duplicateReconciliation.scanURLs where seenPaths.insert(fileURL.path).inserted {
                files.append(fileURL)
            }
            files.sort(by: { $0.path < $1.path })

            let filePathsInScan = Set(files.map(\.path))
            var scanState = CodexScanState()
            let fileIndex = CodexSessionFileIndex(
                files: files,
                roots: plan.roots,
                cachedSessionFiles: Self.cachedCodexSessionIndex(
                    cache: cache,
                    roots: plan.roots,
                    knownExistingPaths: filePathsInScan),
                checkCancellation: checkCancellation)
            let inheritedResolver = CodexInheritedTotalsResolver(
                fileIndex: fileIndex,
                checkCancellation: checkCancellation)
            let resources = CodexScanResources(
                fileIndex: fileIndex,
                inheritedResolver: inheritedResolver,
                modelsDevCatalog: plan.modelsDevCatalog,
                modelsDevCacheRoot: options.cacheRoot,
                priorityTurns: plan.priorityTurns)
            for fileURL in files {
                try Self.scanCodexFile(
                    fileURL: fileURL,
                    context: CodexFileScanContext(
                        range: range,
                        through: now,
                        forceFullScan: options
                            .forceRescan || plan.windowExpanded || plan.pricingChanged || plan.priorityMetadataChanged,
                        dropDeferredCodexRows: options.forceRescan || plan.pricingChanged || plan
                            .priorityMetadataChanged
                            || plan.needsTurnIDCacheMigration,
                        requiresTurnIDCache: plan.needsTurnIDCacheMigration,
                        changedPriorityTurnIDs: plan.changedPriorityTurnIDs,
                        resources: resources,
                        checkCancellation: checkCancellation),
                    cache: &cache,
                    state: &scanState)
            }
            try checkCancellation?()

            Self.pruneForceRescanFilesOutsideWindow(
                cache: &cache,
                range: range,
                isForceRescan: options.forceRescan,
                preservingPaths: inventoryPaths)

            let shouldDropAllUnscannedFiles = options.forceRescan || plan.rootsChanged || cache.files.isEmpty
            for key in cache.files.keys where !filePathsInScan.contains(key) {
                // A validated inventory entry is intentionally retained even
                // when it is outside the active report window. Its metadata is
                // what makes a future append discoverable.
                if inventoryPaths.contains(key) { continue }
                guard let old = cache.files[key] else { continue }
                let shouldDrop = shouldDropAllUnscannedFiles ||
                    old.touchesCodexScanWindow(sinceKey: range.scanSinceKey, untilKey: range.scanUntilKey)
                guard shouldDrop else { continue }
                Self.applyFileDays(cache: &cache, fileDays: old.days, sign: -1)
                cache.files.removeValue(forKey: key)
            }

            if !shouldDropAllUnscannedFiles {
                for key in cache.files.keys {
                    guard let old = cache.files[key] else { continue }
                    guard old.touchesCodexScanWindow(sinceKey: range.scanSinceKey, untilKey: range.scanUntilKey)
                    else { continue }
                    guard FileManager.default.fileExists(atPath: key) else {
                        Self.applyFileDays(cache: &cache, fileDays: old.days, sign: -1)
                        cache.files.removeValue(forKey: key)
                        continue
                    }
                }
            }

            if let sessionInventory {
                options.codexInventoryBeforeCommitHook?()
                guard try Self.currentCodexDirectoryFingerprints(
                    paths: sessionInventory.directoryFingerprints.keys
                ) == sessionInventory.directoryFingerprints else {
                    throw CodexInventoryError.changedDuringEnumeration
                }
                cache.codexSessionInventoryComplete = true
                cache.codexSessionDirectoryFingerprints = sessionInventory.directoryFingerprints
            }

            let shouldRetainWiderWindow = !options.forceRescan && !plan.pricingChanged && !plan
                .priorityMetadataChanged && !plan.needsTurnIDCacheMigration
            let retainedSinceKey = shouldRetainWiderWindow
                ? [cachedSinceKey, range.scanSinceKey].compactMap(\.self).min() ?? range.scanSinceKey
                : range.scanSinceKey
            let retainedUntilKey = shouldRetainWiderWindow
                ? [cachedUntilKey, range.scanUntilKey].compactMap(\.self).max() ?? range.scanUntilKey
                : range.scanUntilKey
            Self.pruneDays(cache: &cache, sinceKey: retainedSinceKey, untilKey: retainedUntilKey)
            cache.roots = plan.rootsFingerprint
            cache.scanSinceKey = retainedSinceKey
            cache.scanUntilKey = retainedUntilKey
            cache.codexPricingKey = plan.codexPricingKey
            cache.codexPriorityMetadataKey = plan.codexPriorityMetadataKey
            if plan.hasPriorityMetadata {
                cache.codexPriorityTurnKeys = Self.mergePriorityTurnKeys(
                    existing: shouldRetainWiderWindow ? cache.codexPriorityTurnKeys : nil,
                    new: plan.priorityTurnKeys,
                    range: range,
                    retainedSinceKey: retainedSinceKey,
                    retainedUntilKey: retainedUntilKey)
                cache.codexPriorityTurnIDsByDay = Self.mergePriorityTurnIDsByDay(
                    existing: shouldRetainWiderWindow ? cache.codexPriorityTurnIDsByDay : nil,
                    new: plan.priorityTurnIDsByDay,
                    range: range,
                    retainedSinceKey: retainedSinceKey,
                    retainedUntilKey: retainedUntilKey)
            }
            cache.lastScanUnixMs = nowMs
            try checkCancellation?()
            try CostUsageCacheIO.save(provider: .codex, cache: cache, cacheRoot: options.cacheRoot)
        }

        return Self.buildCodexReportFromCache(
            cache: cache,
            range: range,
            modelsDevCatalog: plan.modelsDevCatalog,
            modelsDevCacheRoot: options.cacheRoot,
            priorityTurns: plan.priorityTurns)
    }
}

// swiftlint:enable type_body_length

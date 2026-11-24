import Foundation

extension CostUsageScanner {
    // MARK: - Claude

    private struct ClaudeTokens {
        let input: Int
        let cacheRead: Int
        let cacheCreate: Int
        let cacheCreate1h: Int
        let output: Int
        let costNanos: Int
        let costPriced: Bool
        let isIncomplete: Bool
    }

    private struct ClaudeDayModelKey: Hashable {
        let day: String
        let model: String
    }

    private struct ClaudeRepricedCost {
        var total: Double = 0
        var sampleCount: Int = 0
        var unresolved = false
    }

    private static func defaultClaudeProjectsRoots(options: Options) -> [URL] {
        if let override = options.claudeProjectsRoots { return override }
        return ClaudeHistoryRoots.projects()
    }

    static func parseClaudeFile(
        fileURL: URL,
        range: CostUsageDayRange,
        providerFilter: ClaudeLogProviderFilter,
        startOffset: Int64 = 0,
        modelsDevCatalog: ModelsDevCatalog? = nil,
        modelsDevCacheRoot: URL? = nil) -> ClaudeParseResult
    {
        (
            try? self.parseClaudeFileCancellable(
                fileURL: fileURL,
                range: range,
                providerFilter: providerFilter,
                startOffset: startOffset,
                modelsDevCatalog: modelsDevCatalog,
                modelsDevCacheRoot: modelsDevCacheRoot,
                checkCancellation: nil)) ?? ClaudeParseResult(days: [:], rows: [], parsedBytes: startOffset)
    }

    static func parseClaudeFileCancellable(
        fileURL: URL,
        range: CostUsageDayRange,
        providerFilter: ClaudeLogProviderFilter,
        startOffset: Int64 = 0,
        modelsDevCatalog: ModelsDevCatalog? = nil,
        modelsDevCacheRoot: URL? = nil,
        checkCancellation: CancellationCheck? = nil,
        sourceFileURL: URL? = nil) throws -> ClaudeParseResult
    {
        func add(dayKey: String, model: String, tokens: ClaudeTokens, days: inout [String: [String: [Int]]]) {
            guard CostUsageDayRange.isInRange(dayKey: dayKey, since: range.scanSinceKey, until: range.scanUntilKey)
            else { return }
            let normModel = CostUsagePricing.normalizeClaudeModel(model)
            var dayModels = days[dayKey] ?? [:]
            var packed = dayModels[normModel] ?? [0, 0, 0, 0, 0, 0, 0, 0, 0]
            if tokens.isIncomplete {
                packed[8] += 1
                dayModels[normModel] = packed
                days[dayKey] = dayModels
                return
            }
            packed[0] = (packed[safe: 0] ?? 0) + tokens.input
            packed[1] = (packed[safe: 1] ?? 0) + tokens.cacheRead
            packed[2] = (packed[safe: 2] ?? 0) + tokens.cacheCreate
            packed[3] = (packed[safe: 3] ?? 0) + tokens.output
            packed[4] = (packed[safe: 4] ?? 0) + tokens.costNanos
            packed[5] = (packed[safe: 5] ?? 0) + 1
            packed[6] = (packed[safe: 6] ?? 0) + (tokens.costPriced ? 1 : 0)
            packed[7] = (packed[safe: 7] ?? 0) + tokens.cacheCreate1h
            dayModels[normModel] = packed
            days[dayKey] = dayModels
        }

        func toInt(_ v: Any?) -> Int {
            if let n = v as? NSNumber { return n.intValue }
            return 0
        }

        func toBool(_ value: Any?) -> Bool {
            if let bool = value as? Bool { return bool }
            if let number = value as? NSNumber { return number.boolValue }
            return false
        }

        let pathRole = Self.claudePathRole(fileURL: sourceFileURL ?? fileURL)
        var keyedRows: [String: ClaudeUsageRow] = [:]
        var unkeyedRows: [ClaudeUsageRow] = []

        let maxLineBytes = 512 * 1024
        // Keep the full line so usage at the tail isn't dropped on large tool outputs.
        let prefixBytes = maxLineBytes
        let costScale = 1_000_000_000.0

        let parsedBytes: Int64
        do {
            parsedBytes = try CostUsageJsonl.scan(
                fileURL: fileURL,
                offset: startOffset,
                maxLineBytes: maxLineBytes,
                prefixBytes: prefixBytes,
                checkCancellation: checkCancellation,
                onLine: { line in
                    guard !line.bytes.isEmpty else { return }
                    guard !line.wasTruncated else { return }
                    // JSON permits whitespace around ':'. Validate the type after decoding,
                    // otherwise valid exported/rewritten session rows silently become zero usage.
                    guard line.bytes.containsAscii(#""usage""#) else { return }

                    autoreleasepool {
                        guard
                            let obj = (try? JSONSerialization.jsonObject(with: line.bytes)) as? [String: Any],
                            let type = obj["type"] as? String,
                            type == "assistant"
                        else { return }
                        guard Self.matchesClaudeProviderFilter(obj: obj, filter: providerFilter) else { return }

                        guard let tsText = obj["timestamp"] as? String, let timestamp = Self.dateFromTimestamp(tsText)
                        else { return }
                        guard let dayKey = Self.dayKeyFromTimestamp(tsText) ?? Self.dayKeyFromParsedISO(tsText)
                        else { return }

                        guard let message = obj["message"] as? [String: Any] else { return }
                        guard let model = message["model"] as? String else { return }
                        guard let usage = message["usage"] as? [String: Any] else { return }

                        let input = max(0, toInt(usage["input_tokens"]))
                        let cacheCreate = max(0, toInt(usage["cache_creation_input_tokens"]))
                        let cacheCreate1h = Self.claudeOneHourCacheCreationTokens(
                            usage: usage,
                            total: cacheCreate)
                        let cacheRead = max(0, toInt(usage["cache_read_input_tokens"]))
                        let output = max(0, toInt(usage["output_tokens"]))
                        if input == 0, cacheCreate == 0, cacheRead == 0, output == 0 { return }

                        let incomplete = message["stop_reason"] is NSNull && input > 0
                            && output == 0 && cacheCreate == 0 && cacheRead == 0
                        let cost = incomplete ? nil : CostUsagePricing.claudeCostUSD(
                            model: model,
                            inputTokens: input,
                            cacheReadInputTokens: cacheRead,
                            cacheCreationInputTokens: cacheCreate,
                            cacheCreationInputTokens1h: cacheCreate1h,
                            outputTokens: output,
                            pricingDate: timestamp,
                            modelsDevCatalog: modelsDevCatalog,
                            modelsDevCacheRoot: modelsDevCacheRoot)
                        let costNanos = cost.map { Int(($0 * costScale).rounded()) } ?? 0
                        let tokens = ClaudeTokens(
                            input: input,
                            cacheRead: cacheRead,
                            cacheCreate: cacheCreate,
                            cacheCreate1h: cacheCreate1h,
                            output: output,
                            costNanos: costNanos,
                            costPriced: cost != nil, isIncomplete: incomplete)

                        guard CostUsageDayRange.isInRange(
                            dayKey: dayKey,
                            since: range.scanSinceKey,
                            until: range.scanUntilKey)
                        else { return }

                        let messageId = message["id"] as? String
                        let requestId = (obj["requestId"] as? String) ?? (obj["request_id"] as? String)
                        let sessionId = obj["sessionId"] as? String
                            ?? obj["session_id"] as? String
                            ?? (obj["metadata"] as? [String: Any])?["sessionId"] as? String
                            ?? (message["metadata"] as? [String: Any])?["sessionId"] as? String
                        let normalizedModel = CostUsagePricing.normalizeClaudeModel(model)
                        let row = ClaudeUsageRow(
                            dayKey: dayKey,
                            model: normalizedModel,
                            sessionId: sessionId,
                            messageId: messageId,
                            requestId: requestId,
                            timestampUnixMs: Int64((timestamp.timeIntervalSince1970 * 1000).rounded()),
                            isSidechain: toBool(obj["isSidechain"]),
                            pathRole: pathRole,
                            input: tokens.input,
                            cacheRead: tokens.cacheRead,
                            cacheCreate: tokens.cacheCreate,
                            cacheCreate1h: tokens.cacheCreate1h,
                            output: tokens.output,
                            costNanos: tokens.costNanos,
                            costPriced: tokens.costPriced, isIncomplete: incomplete)

                        // Streaming chunks share message.id + requestId inside a file.
                        // Keep overwriting so the final cumulative chunk wins.
                        if let key = Self.claudeInFileKey(row) {
                            if keyedRows[key]?.isIncomplete != false || !incomplete { keyedRows[key] = row }
                        } else {
                            // Older logs omit IDs; treat each line as distinct to avoid dropping usage.
                            unkeyedRows.append(row)
                        }
                    }
                })
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // An I/O failure is not an empty session. Abort before committing a partial cache.
            throw error
        }

        let rows = keyedRows.keys.sorted().compactMap { keyedRows[$0] } + unkeyedRows
        var days: [String: [String: [Int]]] = [:]
        for row in rows {
            let tokens = ClaudeTokens(
                input: row.input,
                cacheRead: row.cacheRead,
                cacheCreate: row.cacheCreate,
                cacheCreate1h: row.cacheCreate1h ?? 0,
                output: row.output,
                costNanos: row.costNanos,
                costPriced: row.costPriced ?? (row.costNanos > 0), isIncomplete: row.isIncomplete == true)
            add(dayKey: row.dayKey, model: row.model, tokens: tokens, days: &days)
        }

        return ClaudeParseResult(days: days, rows: rows, parsedBytes: parsedBytes)
    }

    private static func claudeOneHourCacheCreationTokens(usage: [String: Any], total: Int) -> Int {
        guard let cacheCreation = usage["cache_creation"] as? [String: Any] else { return 0 }
        let tokens = (cacheCreation["ephemeral_1h_input_tokens"] as? NSNumber)?.intValue ?? 0
        return min(total, max(0, tokens))
    }

    private static func claudePathRole(fileURL: URL) -> ClaudePathRole {
        fileURL.path.contains("/subagents/") ? .subagent : .parent
    }

    private static func claudeCanonicalRowKey(_ row: ClaudeUsageRow) -> String? {
        func nonblank(_ value: String?) -> String? {
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return value
        }
        guard let message = nonblank(row.messageId) else { return nil }
        // Length prefixes prevent collisions in externally supplied IDs.
        if let request = nonblank(row.requestId) { return "r:\(message.utf8.count):\(message)\(request)" }
        guard let session = nonblank(row.sessionId) else { return nil }
        return "s:\(message.utf8.count):\(message)\(session)"
    }

    private static func mergeClaudeRows(existing: [ClaudeUsageRow], delta: [ClaudeUsageRow]) -> [ClaudeUsageRow] {
        var keyedRows: [String: ClaudeUsageRow] = [:]
        var unkeyedRows: [ClaudeUsageRow] = []

        for row in existing {
            if let key = Self.claudeInFileKey(row) {
                if keyedRows[key]?.isIncomplete != false || row.isIncomplete != true { keyedRows[key] = row }
            } else {
                unkeyedRows.append(row)
            }
        }
        for row in delta {
            if let key = Self.claudeInFileKey(row) {
                if keyedRows[key]?.isIncomplete != false || row.isIncomplete != true { keyedRows[key] = row }
            } else {
                unkeyedRows.append(row)
            }
        }

        return keyedRows.keys.sorted().compactMap { keyedRows[$0] } + unkeyedRows
    }

    private static func claudeInFileKey(_ row: ClaudeUsageRow) -> String? {
        claudeCanonicalRowKey(row)
    }

    private static func claudeRowWins(
        lhs: (path: String, row: ClaudeUsageRow),
        rhs: (path: String, row: ClaudeUsageRow)) -> Bool
    {
        if (lhs.row.isIncomplete == true) != (rhs.row.isIncomplete == true) { return rhs.row.isIncomplete == true }
        if lhs.row.isSidechain != rhs.row.isSidechain {
            return rhs.row.isSidechain
        }
        if lhs.row.pathRole != rhs.row.pathRole {
            return rhs.row.pathRole == .subagent
        }
        return lhs.path < rhs.path
    }

    private static func reconciledClaudeRows(cache: CostUsageCache) -> [ClaudeUsageRow] {
        reconciledClaudeRowsWithSources(cache: cache).map(\.row)
    }

    static func reconciledClaudeRowsWithSources(cache: CostUsageCache) -> [(path: String, row: ClaudeUsageRow)] {
        var rows: [(path: String, row: ClaudeUsageRow)] = []
        var winners: [String: (path: String, row: ClaudeUsageRow)] = [:]

        for path in cache.files.keys.sorted() {
            guard let fileRows = cache.files[path]?.claudeRows else { continue }
            for row in fileRows {
                guard let canonicalKey = Self.claudeCanonicalRowKey(row) else {
                    rows.append((path: path, row: row))
                    continue
                }
                let candidate = (path: path, row: row)
                if let existing = winners[canonicalKey] {
                    if Self.claudeRowWins(lhs: candidate, rhs: existing) {
                        winners[canonicalKey] = candidate
                    }
                } else {
                    winners[canonicalKey] = candidate
                }
            }
        }

        rows.append(contentsOf: winners.keys.sorted().compactMap { winners[$0] })
        return rows
    }

    /// Use the same reconciled owners and pricing as the daily report, including parent/subagent deduplication.
    static func buildClaudeUsageDetails(cache: CostUsageCache, now: Date,
                                       modelsDevCacheRoot: URL? = nil,
                                       projectPath: (String, String?) -> String? = ClaudeProjectHeader.read,
                                       checkCancellation: () throws -> Void = {}) throws -> CodexUsageDetails {
        try checkCancellation()
        let start = Calendar.current.date(byAdding: .day, value: -29, to: Calendar.current.startOfDay(for: now))!
        let range = CostUsageDayRange(since: start, until: now)
        let rows = reconciledClaudeRowsWithSources(cache: cache).filter {
            CostUsageDayRange.isInRange(dayKey: $0.row.dayKey, since: range.sinceKey, until: range.untilKey)
        }
        let groups = Dictionary(grouping: rows) { $0.row.sessionId ?? $0.path }
        let sessions = try groups.compactMap { id, rows -> CodexUsageDetails.Session? in
            try checkCancellation()
            var subset = CostUsageCache()
            for (path, fileRows) in Dictionary(grouping: rows, by: \.path) {
                try checkCancellation()
                subset.files[path] = makeClaudeFileUsage(mtimeMs: 0, size: 0, rows: fileRows.map(\.row), parsedBytes: nil)
            }
            rebuildClaudeDays(cache: &subset)
            let report = buildClaudeReportFromCache(cache: subset, range: range, modelsDevCacheRoot: modelsDevCacheRoot)
            guard let total = report.summary?.totalTokens, total > 0 else { return nil }
            let projects = Set(try Set(rows.map(\.path)).compactMap { path in
                try checkCancellation()
                return projectPath(path, rows.first(where: { $0.path == path })?.row.sessionId)
            })
            let dates = rows.compactMap { $0.row.timestampUnixMs.map { Date(timeIntervalSince1970: Double($0) / 1000) } }
            return .init(id: id, projectPath: projects.count == 1 ? projects.first : nil, lastActivity: dates.max(),
                         inputTokens: report.summary?.totalInputTokens ?? 0,
                         cachedTokens: report.summary?.cacheReadTokens ?? 0,
                         outputTokens: report.summary?.totalOutputTokens ?? 0,
                         totalTokens: total, costUSD: report.summary?.totalCostUSD,
                         hasUnpricedUsage: report.data.contains(where: ClaudeHistorySummary.hasUnpricedUsage),
                         models: Array(Set(rows.map { $0.row.model })).sorted(),
                         cacheCreationTokens: report.summary?.cacheCreationTokens ?? 0)
        }.sorted {
            if $0.lastActivity != $1.lastActivity { return ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
            return $0.id < $1.id
        }
        return CodexUsageDetails(sessions: sessions, updatedAt: now)
    }

    private static func rebuildClaudeDays(cache: inout CostUsageCache) {
        var days: [String: [String: [Int]]] = [:]

        for row in Self.reconciledClaudeRows(cache: cache) {
            var dayModels = days[row.dayKey] ?? [:]
            var packed = dayModels[row.model] ?? [0, 0, 0, 0, 0, 0, 0, 0, 0]
            if row.isIncomplete == true {
                packed[8] += 1
                dayModels[row.model] = packed
                days[row.dayKey] = dayModels
                continue
            }
            packed[0] = (packed[safe: 0] ?? 0) + row.input
            packed[1] = (packed[safe: 1] ?? 0) + row.cacheRead
            packed[2] = (packed[safe: 2] ?? 0) + row.cacheCreate
            packed[3] = (packed[safe: 3] ?? 0) + row.output
            packed[4] = (packed[safe: 4] ?? 0) + row.costNanos
            packed[5] = (packed[safe: 5] ?? 0) + 1
            packed[6] = (packed[safe: 6] ?? 0) + ((row.costPriced ?? (row.costNanos > 0)) ? 1 : 0)
            packed[7] = (packed[safe: 7] ?? 0) + (row.cacheCreate1h ?? 0)
            dayModels[row.model] = packed
            days[row.dayKey] = dayModels
        }

        cache.days = days
    }

    private static func makeClaudeFileUsage(
        mtimeMs: Int64,
        size: Int64,
        rows: [ClaudeUsageRow],
        parsedBytes: Int64?) -> CostUsageFileUsage
    {
        makeFileUsage(
            mtimeUnixMs: mtimeMs,
            size: size,
            days: [:],
            parsedBytes: parsedBytes,
            claudeRows: rows)
    }

    private static let vertexProviderKeys: Set<String> = [
        "provider",
        "platform",
        "backend",
        "api_provider",
        "apiprovider",
        "api_type",
        "apitype",
        "source",
        "vendor",
        "client",
    ]

    private static func matchesClaudeProviderFilter(
        obj: [String: Any],
        filter: ClaudeLogProviderFilter) -> Bool
    {
        switch filter {
        case .all:
            true
        case .vertexAIOnly:
            self.isVertexAIUsageEntry(obj: obj)
        case .excludeVertexAI:
            !self.isVertexAIUsageEntry(obj: obj)
        }
    }

    private static func isVertexAIUsageEntry(obj: [String: Any]) -> Bool {
        // Primary detection: Vertex AI message IDs and request IDs have "vrtx" prefix
        // e.g., "msg_vrtx_0154LUXjFVzQGUca3yK2RUeo", "req_vrtx_011CWjK86SWeFuXqZKUtgB1H"
        if let message = obj["message"] as? [String: Any],
           let messageId = message["id"] as? String,
           messageId.contains("_vrtx_")
        {
            return true
        }
        if let requestId = (obj["requestId"] as? String) ?? (obj["request_id"] as? String),
           requestId.contains("_vrtx_")
        {
            return true
        }

        // Secondary detection: model name with @ version separator (Vertex AI format)
        // e.g., "claude-opus-4-5@20251101" vs "claude-opus-4-5-20251101"
        if let message = obj["message"] as? [String: Any],
           let model = message["model"] as? String,
           Self.modelNameLooksVertex(model)
        {
            return true
        }

        // Fallback: check for explicit Vertex AI metadata fields
        var candidates: [[String: Any]] = [obj]
        if let metadata = obj["metadata"] as? [String: Any] { candidates.append(metadata) }
        if let request = obj["request"] as? [String: Any] { candidates.append(request) }
        if let context = obj["context"] as? [String: Any] { candidates.append(context) }
        if let client = obj["client"] as? [String: Any] { candidates.append(client) }
        if let message = obj["message"] as? [String: Any] {
            if let metadata = message["metadata"] as? [String: Any] { candidates.append(metadata) }
            if let request = message["request"] as? [String: Any] { candidates.append(request) }
        }

        return candidates.contains { Self.containsVertexAIMetadata(in: $0) }
    }

    /// Detects Vertex AI model names by format.
    /// Vertex AI uses @ for version separator: claude-opus-4-5@20251101
    /// Anthropic API uses -: claude-opus-4-5-20251101
    private static func modelNameLooksVertex(_ model: String) -> Bool {
        // Vertex AI model format: claude-{variant}@{version}
        // Examples: claude-opus-4-5@20251101, claude-sonnet-4-5@20250514
        guard model.hasPrefix("claude-") else { return false }
        return model.contains("@")
    }

    private static func containsVertexAIMetadata(in dict: [String: Any]) -> Bool {
        for (key, value) in dict {
            let lowerKey = key.lowercased()
            if lowerKey.contains("vertex") || lowerKey.contains("gcp") {
                return true
            }
            if Self.vertexProviderKeys.contains(lowerKey),
               let text = value as? String,
               Self.stringLooksVertex(text)
            {
                return true
            }
            if let nested = value as? [String: Any] {
                if Self.containsVertexAIMetadata(in: nested) { return true }
            } else if let array = value as? [Any] {
                if Self.containsVertexAIMetadata(in: array) { return true }
            }
        }

        return false
    }

    private static func containsVertexAIMetadata(in array: [Any]) -> Bool {
        for entry in array {
            if let dict = entry as? [String: Any] {
                if self.containsVertexAIMetadata(in: dict) { return true }
            }
        }

        return false
    }

    private static func stringLooksVertex(_ value: String) -> Bool {
        value.lowercased().contains("vertex")
    }

    private static func claudeRootCandidates(for rootPath: String) -> [String] {
        if rootPath.hasPrefix("/var/") {
            return ["/private" + rootPath, rootPath]
        }
        if rootPath.hasPrefix("/private/var/") {
            let trimmed = String(rootPath.dropFirst("/private".count))
            return [rootPath, trimmed]
        }
        return [rootPath]
    }

    private final class ClaudeScanState {
        var cache: CostUsageCache
        var touched: Set<String>
        let range: CostUsageDayRange
        let providerFilter: ClaudeLogProviderFilter
        let forceFullScan: Bool
        let modelsDevCatalog: ModelsDevCatalog?
        let modelsDevCacheRoot: URL?
        let checkCancellation: CancellationCheck?
        let beforeSnapshotValidation: ((URL) -> Void)?

        init(
            cache: CostUsageCache,
            range: CostUsageDayRange,
            providerFilter: ClaudeLogProviderFilter,
            forceFullScan: Bool,
            modelsDevCatalog: ModelsDevCatalog?,
            modelsDevCacheRoot: URL?,
            checkCancellation: CancellationCheck?,
            beforeSnapshotValidation: ((URL) -> Void)?)
        {
            self.cache = cache
            self.touched = []
            self.range = range
            self.providerFilter = providerFilter
            self.forceFullScan = forceFullScan
            self.modelsDevCatalog = modelsDevCatalog
            self.modelsDevCacheRoot = modelsDevCacheRoot
            self.checkCancellation = checkCancellation
            self.beforeSnapshotValidation = beforeSnapshotValidation
        }
    }

    private static func processClaudeFile(
        url: URL,
        state: ClaudeScanState) throws
    {
        try state.checkCancellation?()
        let path = url.path
        let metadata = Self.codexFileMetadata(fileURL: url)
        guard metadata.fileId != nil else {
            // Claude Code prunes old sessions. A file deleted after enumeration is
            // treated as never seen: left untouched, its cached rows are dropped.
            if Self.claudePathIsMissing(path) { return }
            throw CocoaError(.fileReadUnknown)
        }
        state.touched.insert(path)
        let cached = state.cache.files[path]

        // These byte-level snapshot primitives are shared with Codex. Legacy
        // Claude entries lack identity/proof fields and must be parsed again.
        if let cached, !state.forceFullScan,
           cached.sourceGeneration == metadata.fileId,
           cached.sourceStatFingerprint != nil,
           cached.sourceStatFingerprint == metadata.statFingerprint,
           cached.mtimeUnixMs == metadata.mtimeUnixMs,
           cached.size == metadata.size,
           cached.claudeRows != nil,
           cached.parsedBytes == 0 || cached.committedPrefixFingerprint != nil {
            return
        }

        do {
            let input = CodexFileScanInput(fileURL: url, metadata: metadata, cached: cached)
            let snapshot = try Self.codexReadSnapshot(input: input, checkCancellation: state.checkCancellation)
            var startOffset: Int64 = 0
            var previousRows: [ClaudeUsageRow] = []
            if let cached, !state.forceFullScan,
               cached.sourceGeneration == metadata.fileId,
               metadata.size > cached.size,
               let offset = cached.parsedBytes, offset > 0, offset <= metadata.size,
               let rows = cached.claudeRows,
               try Self.codexFileMatchesCommittedFrontier(
                   fileURL: snapshot.url, cached: cached, checkCancellation: state.checkCancellation) {
                startOffset = offset
                previousRows = rows
            }
            let parsed = try Self.parseClaudeFileCancellable(
                fileURL: snapshot.url,
                range: state.range,
                providerFilter: state.providerFilter,
                startOffset: startOffset,
                modelsDevCatalog: state.modelsDevCatalog,
                modelsDevCacheRoot: state.modelsDevCacheRoot,
                checkCancellation: state.checkCancellation,
                sourceFileURL: url)
            state.beforeSnapshotValidation?(url)
            let fingerprint = try Self.verifiedCodexSnapshotPrefix(
                snapshot: snapshot, input: input, parsedBytes: parsed.parsedBytes,
                checkCancellation: state.checkCancellation)
            var usage = Self.makeClaudeFileUsage(
                mtimeMs: metadata.mtimeUnixMs,
                size: metadata.size,
                rows: Self.mergeClaudeRows(existing: previousRows, delta: parsed.rows),
                parsedBytes: parsed.parsedBytes)
            usage.sourceGeneration = metadata.fileId
            usage.sourceStatFingerprint = metadata.statFingerprint
            usage.sourceChangeTimeNanoseconds = metadata.changeTimeNanoseconds
            usage.committedPrefixFingerprint = fingerprint
            state.cache.files[path] = usage
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Deleted mid-read: same as deleted before it was reached. No partial
            // result was committed, so dropping the entry is consistent.
            if Self.claudePathIsMissing(path) {
                state.touched.remove(path)
                return
            }
            let nsError = error as NSError
            guard nsError.domain == "AgentSignalCostUsage.CodexConsistency" else { throw error }
            throw NSError(domain: Self.claudeConsistencyErrorDomain, code: nsError.code,
                          userInfo: [NSLocalizedDescriptionKey: "Claude session changed while being scanned"])
        }
    }

    static let claudeConsistencyErrorDomain = "AgentSignalCostUsage.ClaudeConsistency"

    /// A session that is still being written or rewritten; retrying shortly is expected to succeed.
    static func isClaudeSourceChanging(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == claudeConsistencyErrorDomain && nsError.code == 3
    }

    /// True only when the path itself is gone, not for permission or other I/O errors.
    private static func claudePathIsMissing(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) != 0 else { return false }
        return errno == ENOENT || errno == ENOTDIR
    }

    private static func scanClaudeRoot(
        root: URL,
        state: ClaudeScanState) throws
    {
        try state.checkCancellation?()
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        let rootPath = root.path
        let rootCandidates = Self.claudeRootCandidates(for: rootPath)
        let prefixes = Set(rootCandidates).map { path in
            path.hasSuffix("/") ? path : "\(path)/"
        }
        let rootExists = rootCandidates.contains { FileManager.default.fileExists(atPath: $0) }

        guard rootExists else {
            let stale = state.cache.files.keys.filter { path in
                path == rootPath || prefixes.contains(where: { path.hasPrefix($0) })
            }
            for path in stale {
                state.cache.files.removeValue(forKey: path)
            }
            return
        }

        // Always enumerate the directory tree. The per-file mtime/size cache in
        // processClaudeFile already skips unchanged files, so the only cost here is
        // the directory walk itself. The previous root-mtime optimization skipped
        // enumeration entirely when the root directory mtime was unchanged, but on
        // POSIX systems a directory mtime only updates for direct child changes —
        // not for files created or modified inside subdirectories. This caused new
        // session logs to go undetected until the cache was manually cleared.
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey,
            .contentModificationDateKey,
            .fileSizeKey,
        ]

        let rootValues = try root.resourceValues(forKeys: Set(keys))
        if rootValues.isRegularFile == true, root.lastPathComponent == "audit.jsonl" {
            try Self.processClaudeFile(url: root, state: state)
            return
        }
        guard rootValues.isDirectory == true else {
            throw CocoaError(.fileReadUnknown)
        }
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { url, error in
                // A directory removed during the walk is skipped; any other error
                // (such as permission denied) still fails the scan rather than
                // silently dropping that directory's cached usage.
                if Self.claudePathIsMissing(url.path) { return true }
                enumerationError = error
                return false
            })
        else { throw CocoaError(.fileReadUnknown) }

        for case let url as URL in enumerator {
            try state.checkCancellation?()
            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: Set(keys))
            } catch {
                if Self.claudePathIsMissing(url.path) { continue }
                throw error
            }
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            if values.isDirectory == true, ["outputs", "node_modules", ".git"].contains(url.lastPathComponent) {
                enumerator.skipDescendants(); continue
            }
            guard url.pathExtension.lowercased() == "jsonl" else { continue }
            guard values.isRegularFile == true else { continue }
            let size = Int64(values.fileSize ?? 0)
            if size <= 0 { continue }

            try Self.processClaudeFile(url: url, state: state)
        }

        if let enumerationError { throw enumerationError }
        // Root mtime caching removed — see comment above.
    }

    static func loadClaudeDaily(
        provider: UsageProvider,
        range: CostUsageDayRange,
        now: Date,
        options: Options,
        checkCancellation: CancellationCheck?) throws -> CostUsageDailyReport
    {
        var cache = CostUsageCacheIO.load(provider: provider, cacheRoot: options.cacheRoot)
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)

        let refreshMs = Int64(max(0, options.refreshMinIntervalSeconds) * 1000)
        let windowExpanded = Self.requestedWindowExpandsCache(range: range, cache: cache)
        let shouldRefresh = options.forceRescan
            || windowExpanded
            || refreshMs == 0
            || cache.lastScanUnixMs == 0
            || nowMs - cache.lastScanUnixMs > refreshMs

        let roots = self.defaultClaudeProjectsRoots(options: options)
        let providerFilter = options.claudeLogProviderFilter

        var touched: Set<String> = []

        if shouldRefresh {
            try checkCancellation?()
            if options.forceRescan {
                cache = CostUsageCache()
            }
            let modelsDevCatalog = CostUsagePricing.modelsDevCatalog(now: now, cacheRoot: options.cacheRoot)
            let scanState = ClaudeScanState(
                cache: cache,
                range: range,
                providerFilter: providerFilter,
                forceFullScan: options.forceRescan || windowExpanded,
                modelsDevCatalog: modelsDevCatalog,
                modelsDevCacheRoot: options.cacheRoot,
                checkCancellation: checkCancellation,
                beforeSnapshotValidation: options.claudeFileBeforeSnapshotValidationHook)

            for root in roots {
                try Self.scanClaudeRoot(
                    root: root,
                    state: scanState)
            }
            try checkCancellation?()

            cache = scanState.cache
            touched = scanState.touched
            cache.roots = nil

            for key in cache.files.keys where !touched.contains(key) {
                cache.files.removeValue(forKey: key)
            }

            Self.rebuildClaudeDays(cache: &cache)
            Self.pruneDays(cache: &cache, sinceKey: range.scanSinceKey, untilKey: range.scanUntilKey)
            cache.scanSinceKey = range.scanSinceKey
            cache.scanUntilKey = range.scanUntilKey
            cache.lastScanUnixMs = nowMs
            try checkCancellation?()
            try? CostUsageCacheIO.save(provider: provider, cache: cache, cacheRoot: options.cacheRoot)
        }

        let modelsDevCatalog = CostUsagePricing.modelsDevCatalog(now: now, cacheRoot: options.cacheRoot)
        return Self.buildClaudeReportFromCache(
            cache: cache,
            range: range,
            modelsDevCatalog: modelsDevCatalog,
            modelsDevCacheRoot: options.cacheRoot)
    }

    private static func buildClaudeReportFromCache(
        cache: CostUsageCache,
        range: CostUsageDayRange,
        modelsDevCatalog: ModelsDevCatalog? = nil,
        modelsDevCacheRoot: URL? = nil) -> CostUsageDailyReport
    {
        var entries: [CostUsageDailyReport.Entry] = []
        var totalInput = 0
        var totalOutput = 0
        var totalCacheRead = 0
        var totalCacheCreate = 0
        var totalTokens = 0
        var totalCost: Double = 0
        var costSeen = false
        var completeSeen = false
        let costScale = 1_000_000_000.0
        var repricedCosts: [ClaudeDayModelKey: ClaudeRepricedCost] = [:]

        for row in Self.reconciledClaudeRows(cache: cache) {
            guard row.isIncomplete != true else { continue }
            let key = ClaudeDayModelKey(day: row.dayKey, model: row.model)
            var aggregate = repricedCosts[key] ?? ClaudeRepricedCost()
            aggregate.sampleCount += 1
            let isPriced = row.costPriced ?? (row.costNanos > 0)
            let currentPricingCost = CostUsagePricing.claudeCostUSD(
                model: row.model,
                inputTokens: row.input,
                cacheReadInputTokens: row.cacheRead,
                cacheCreationInputTokens: row.cacheCreate,
                cacheCreationInputTokens1h: row.cacheCreate1h ?? 0,
                outputTokens: row.output,
                pricingDate: row.timestampUnixMs.map {
                    Date(timeIntervalSince1970: Double($0) / 1000)
                },
                modelsDevCatalog: modelsDevCatalog,
                modelsDevCacheRoot: modelsDevCacheRoot)
            let cost: Double? = if isPriced, row.costNanos == 0 {
                0
            } else if let currentPricingCost {
                currentPricingCost
            } else if isPriced {
                Double(row.costNanos) / costScale
            } else {
                nil
            }
            if let cost {
                aggregate.total += cost
            } else {
                aggregate.unresolved = true
            }
            repricedCosts[key] = aggregate
        }

        let dayKeys = cache.days.keys.sorted().filter {
            CostUsageDayRange.isInRange(dayKey: $0, since: range.sinceKey, until: range.untilKey)
        }

        for day in dayKeys {
            guard let models = cache.days[day] else { continue }
            let modelNames = models.keys.sorted()

            var dayInput = 0
            var dayOutput = 0
            var dayCacheRead = 0
            var dayCacheCreate = 0

            var breakdown: [CostUsageDailyReport.ModelBreakdown] = []
            var dayCost: Double = 0
            var dayCostSeen = false
            var daySamples = 0
            var dayIncomplete = 0

            for model in modelNames {
                let packed = models[model] ?? [0, 0, 0, 0]
                let input = packed[safe: 0] ?? 0
                let cacheRead = packed[safe: 1] ?? 0
                let cacheCreate = packed[safe: 2] ?? 0
                let output = packed[safe: 3] ?? 0
                let sampleCount = packed[safe: 5] ?? 0
                let incomplete = packed[safe: 8] ?? 0
                daySamples += sampleCount
                dayIncomplete += incomplete
                let totalTokens = input + cacheRead + cacheCreate + output

                // Cache tokens are tracked separately; totalTokens includes input + cache.
                dayInput += input
                dayCacheRead += cacheRead
                dayCacheCreate += cacheCreate
                dayOutput += output

                let repricedCost = repricedCosts[ClaudeDayModelKey(day: day, model: model)]
                let currentPricingCost: Double? = if let repricedCost,
                                                     repricedCost.sampleCount == sampleCount,
                                                     !repricedCost.unresolved
                {
                    repricedCost.total
                } else {
                    nil
                }
                let cost = currentPricingCost
                breakdown.append(
                    CostUsageDailyReport.ModelBreakdown(
                        modelName: model,
                        costUSD: cost,
                        totalTokens: sampleCount > 0 ? totalTokens : nil, incompleteRequestCount: incomplete))
                if let cost {
                    dayCost += cost
                    dayCostSeen = true
                }
            }

            let sortedBreakdown = Self.sortedModelBreakdowns(breakdown)

            let dayTotal = dayInput + dayCacheRead + dayCacheCreate + dayOutput
            let entryCost = dayCostSeen ? dayCost : nil
            entries.append(CostUsageDailyReport.Entry(
                date: day,
                inputTokens: daySamples > 0 ? dayInput : nil,
                outputTokens: daySamples > 0 ? dayOutput : nil,
                cacheReadTokens: daySamples > 0 ? dayCacheRead : nil,
                cacheCreationTokens: daySamples > 0 ? dayCacheCreate : nil,
                totalTokens: daySamples > 0 ? dayTotal : nil,
                costUSD: entryCost,
                modelsUsed: modelNames,
                modelBreakdowns: sortedBreakdown, incompleteRequestCount: dayIncomplete))
            completeSeen = completeSeen || daySamples > 0

            totalInput += dayInput
            totalOutput += dayOutput
            totalCacheRead += dayCacheRead
            totalCacheCreate += dayCacheCreate
            totalTokens += dayTotal
            if let entryCost {
                totalCost += entryCost
                costSeen = true
            }
        }

        let summary: CostUsageDailyReport.Summary? = entries.isEmpty
            ? nil
            : CostUsageDailyReport.Summary(
                totalInputTokens: completeSeen ? totalInput : nil,
                totalOutputTokens: completeSeen ? totalOutput : nil,
                cacheReadTokens: completeSeen ? totalCacheRead : nil,
                cacheCreationTokens: completeSeen ? totalCacheCreate : nil,
                totalTokens: completeSeen ? totalTokens : nil,
                totalCostUSD: costSeen ? totalCost : nil)

        return CostUsageDailyReport(data: entries, summary: summary)
    }
}

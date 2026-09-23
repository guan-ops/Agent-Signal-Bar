import Foundation
import CoreFoundation
import AgentSignalLightCore

extension CostUsageScanner {
    /// The ordinary duplicate ledger intentionally requires a single byte-prefix
    /// owner. Paginated continuations can instead prove disjoint billed responses.
    /// Keep that proof separate so it cannot change fork-parent authority.
    static func recoverCodexPaginatedHistory(
        cache: inout CostUsageCache, range: CostUsageDayRange, through: Date,
        rebuild: Bool, resources: CodexScanResources, checkCancellation: CancellationCheck?
    ) throws {
        var recovered: [String: [String: CostUsageFileUsage]] = [:]
        for warning in cache.codexScanWarnings ?? [] {
            try checkCancellation?()
            let paths = Set(warning.sourcePaths)
            guard paths.count > 1,
                  paths.allSatisfy({ cache.files[$0]?.codexIdentityConflict == true }) else { continue }
            if !rebuild, let old = cache.codexPaginatedLedgers?[warning.sessionID],
               Set(old.keys) == paths,
               old.allSatisfy({ paginatedSnapshotMatches(path: $0.key, usage: $0.value) }) {
                recovered[warning.sessionID] = old
                continue
            }
            var pages: [String: PaginatedPage] = [:]
            var responseIDs = Set<String>()
            var valid = true
            for path in paths.sorted() {
                do {
                    guard let page = try readPaginatedPage(path: path, sessionID: warning.sessionID,
                        through: through, checkCancellation: checkCancellation),
                          responseIDs.isDisjoint(with: page.responseIDs) else {
                        valid = false
                        break
                    }
                    responseIDs.formUnion(page.responseIDs)
                    pages[path] = page
                } catch PaginatedReadError.deferredTail {
                    // A writer can pause between a billed record and its token
                    // event, or finish after this scan's cutoff. Keep the last
                    // committed transaction through the existing retry path;
                    // never publish a partial group or advance its watermarks.
                    if let old = cache.codexPaginatedLedgers?[warning.sessionID],
                       Set(old.keys) == paths,
                       try paginatedGroupRetainsCommittedPrefixes(old, growingPath: path,
                           checkCancellation: checkCancellation) {
                        throw codexChangedDuringScanError(path: path)
                    }
                    valid = false
                    break
                }
            }
            guard valid, pages.count == paths.count,
                  pages.values.filter({ $0.base == nil }).count == 1 else { continue }
            // Every continuation must point into an earlier page at an exact
            // byte/ordinal boundary, forming a rooted, acyclic history chain.
            var linked = Set(pages.filter { $0.value.base == nil }.keys)
            while linked.count < pages.count {
                let before = linked.count
                for (path, page) in pages where !linked.contains(path) {
                    guard let base = page.base,
                          linked.contains(where: {
                              guard let parent = pages[$0],
                                    parent.boundaries[base.ordinal] == base.offset else { return false }
                              guard let initial = page.initialRecord else { return true }
                              guard let inherited = parent.confirmedTotals[base.ordinal] else { return false }
                              return initial.total.isSum(of: inherited, plus: initial.usage)
                          }) else { continue }
                    linked.insert(path)
                }
                if linked.count == before { break }
            }
            guard linked.count == pages.count else { continue }
            let context = CodexFileScanContext(range: range, through: through, forceFullScan: true,
                dropDeferredCodexRows: false, requiresTurnIDCache: false, changedPriorityTurnIDs: [],
                resources: resources, checkCancellation: checkCancellation)
            recovered[warning.sessionID] = pages.mapValues {
                codexFileUsageWithCostCache($0.usage, context: context)
            }
        }
        cache.codexPaginatedLedgers = recovered.isEmpty ? nil : recovered
    }

    /// Apply only whole groups; never persist this view as ordinary inventory.
    static func cacheIncludingCodexPaginatedHistory(_ original: CostUsageCache) -> CostUsageCache {
        var cache = original
        for warning in original.codexScanWarnings ?? [] {
            guard let group = original.codexPaginatedLedgers?[warning.sessionID],
                  Set(group.keys) == Set(warning.sourcePaths),
                  group.keys.allSatisfy({ original.files[$0]?.codexIdentityConflict == true }) else { continue }
            for (path, usage) in group {
                if let old = cache.files[path] { applyFileDays(cache: &cache, fileDays: old.days, sign: -1) }
                cache.files[path] = usage
                applyFileDays(cache: &cache, fileDays: usage.days, sign: 1)
            }
            cache.codexScanWarnings?.removeAll { $0.sessionID == warning.sessionID }
        }
        cache.codexPaginatedLedgers = nil
        return cache
    }

    static func validateCodexPaginatedSnapshots(cache: CostUsageCache, checkCancellation: CancellationCheck?) throws {
        for group in cache.codexPaginatedLedgers?.values ?? [:].values {
            for (path, usage) in group {
                try checkCancellation?()
                guard paginatedSnapshotMatches(path: path, usage: usage) else {
                    throw codexChangedDuringScanError(path: path)
                }
            }
        }
    }

    private static func paginatedSnapshotMatches(path: String, usage: CostUsageFileUsage) -> Bool {
        let metadata = codexFileMetadata(fileURL: URL(fileURLWithPath: path))
        return metadata.fileId != nil && metadata.fileId == usage.sourceGeneration
            && metadata.statFingerprint == usage.sourceStatFingerprint
            && metadata.changeTimeNanoseconds == usage.sourceChangeTimeNanoseconds
            && metadata.mtimeUnixMs == usage.mtimeUnixMs && metadata.size == usage.size
            && usage.parsedBytes == usage.size && usage.committedPrefixFingerprint?.isEmpty == false
    }

    private struct PaginatedPage {
        let base: (ordinal: Int, offset: Int64)?
        let boundaries: [Int: Int64]
        let confirmedTotals: [Int: PageTokens]
        let initialRecord: (usage: PageTokens, total: PageTokens)?
        let responseIDs: Set<String>
        let usage: CostUsageFileUsage
    }

    private enum PaginatedReadError: Error { case deferredTail }

    private static func paginatedGroupRetainsCommittedPrefixes(
        _ group: [String: CostUsageFileUsage], growingPath: String,
        checkCancellation: CancellationCheck?
    ) throws -> Bool {
        for (path, usage) in group {
            let url = URL(fileURLWithPath: path)
            let metadata = codexFileMetadata(fileURL: url)
            guard metadata.fileId != nil, metadata.fileId == usage.sourceGeneration,
                  metadata.size >= usage.size,
                  path != growingPath || metadata.size > usage.size,
                  try codexFileMatchesCommittedFrontier(fileURL: url, cached: usage,
                      checkCancellation: checkCancellation),
                  codexFileMetadata(fileURL: url).fileId == usage.sourceGeneration
            else { return false }
        }
        return true
    }

    private struct PageTokens: Equatable {
        let input: Int
        let cached: Int
        let output: Int
        var total: Int { input + output }

        func isSum(of baseline: PageTokens, plus usage: PageTokens) -> Bool {
            // Parsed components are bounded to Int.max / 4, so sums are safe.
            input == baseline.input + usage.input
                && cached == baseline.cached + usage.cached
                && output == baseline.output + usage.output
        }

        init?(_ value: Any?, allowZeroCompactionSummary: Bool = false) {
            guard let fields = value as? [String: Any],
                  let input = pageInteger(fields["input_tokens"]),
                  let cached = pageInteger(fields["cached_input_tokens"]),
                  let output = pageInteger(fields["output_tokens"]),
                  cached <= input
            else { return nil }
            if let explicitTotal = fields["total_tokens"] {
                guard let total = pageInteger(explicitTotal),
                      total == input + output
                        || (allowZeroCompactionSummary && input == 0 && cached == 0 && output == 0)
                else { return nil }
            }
            self.input = input
            self.cached = cached
            self.output = output
        }
    }

    private static func pageInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              let integer = Int(number.stringValue), integer >= 0, integer <= Int.max / 4 else { return nil }
        return integer
    }

    private static func readPaginatedPage(
        path: String, sessionID: String, through: Date, checkCancellation: CancellationCheck?
    ) throws -> PaginatedPage? {
        let url = URL(fileURLWithPath: path)
        let before = codexFileMetadata(fileURL: url)
        guard before.fileId != nil else { return nil }
        var valid = true
        var hasDeferredTail = false
        var sawMetadata = false
        var base: (ordinal: Int, offset: Int64)?
        var previousOrdinal: Int?
        var boundaries: [Int: Int64] = [:]
        var confirmedTotals: [Int: PageTokens] = [:]
        var initialRecord: (usage: PageTokens, total: PageTokens)?
        var responseIDs = Set<String>()
        var model: String?
        var lastRecord: PageTokens?
        var lastRecordTotal: PageTokens?
        var lastToken: PageTokens?
        var newRecord = false
        var compacted = false
        var rows: [CodexUsageRow] = []
        var days: [String: [String: [Int]]] = [:]
        var frontier: CostUsageTokenEventWatermark?
        let limit = 8 * 1024 * 1024
        let parsed = try CostUsageJsonl.scan(fileURL: url, maxLineBytes: limit, prefixBytes: limit,
            checkCancellation: checkCancellation, onLine: { line in
                guard valid, !hasDeferredTail else { return }
                autoreleasepool {
                    guard !line.wasTruncated,
                          let object = (try? JSONSerialization.jsonObject(with: line.bytes)) as? [String: Any],
                          let type = object["type"] as? String,
                          let ordinal = pageInteger(object["ordinal"]),
                          previousOrdinal == nil || ordinal == previousOrdinal! + 1 else {
                        valid = false; return
                    }
                    previousOrdinal = ordinal
                    // history_base points to the next record's byte offset;
                    // token cursors instead end before the newline delimiter.
                    boundaries[ordinal] = line.startOffset
                    if !newRecord { confirmedTotals[ordinal] = lastToken }
                    let payload = object["payload"] as? [String: Any] ?? [:]
                    if !sawMetadata {
                        guard type == "session_meta", payload["id"] as? String == sessionID,
                              payload["session_id"] as? String == sessionID,
                              payload["history_mode"] as? String == "paginated",
                              ["forked_from_id", "forkedFromId", "parent_session_id", "parentSessionId"]
                                .allSatisfy({ payload[$0] == nil }) else { valid = false; return }
                        sawMetadata = true
                        if let history = payload["history_base"] as? [String: Any] {
                            guard history["thread_id"] as? String == sessionID,
                                  let end = pageInteger(history["end_ordinal_exclusive"]), end == ordinal, end > 0,
                                  let offset = pageInteger(history["end_byte_offset"]), offset > 0
                            else { valid = false; return }
                            base = (end, Int64(offset))
                        } else if payload["history_base"] != nil || ordinal != 0 { valid = false }
                        return
                    }
                    switch type {
                    case "session_meta", "token_count": valid = false
                    case "turn_context":
                        if let name = payload["model"] as? String, !name.isEmpty {
                            model = CostUsagePricing.normalizeCodexModel(name)
                        }
                    case "compacted": compacted = true
                    case "token_usage_record":
                        guard payload["thread_id"] as? String == sessionID,
                              payload["session_id"] as? String == sessionID,
                              let response = payload["response_id"] as? String, !response.isEmpty,
                              responseIDs.insert(response).inserted,
                              let usage = PageTokens(payload["usage"]),
                              let recordTotal = PageTokens(payload["thread_token_usage"]),
                              let model,
                              let timestamp = object["timestamp"] as? String,
                              let date = dateFromTimestamp(timestamp),
                              let day = dayKeyFromTimestamp(timestamp) ?? dayKeyFromParsedISO(timestamp)
                        else { valid = false; return }
                        guard date <= through else { hasDeferredTail = true; return }
                        if let baseline = newRecord ? lastRecordTotal : lastToken {
                            guard recordTotal.isSum(of: baseline, plus: usage) else {
                                valid = false; return
                            }
                        } else if base == nil {
                            guard recordTotal == usage else { valid = false; return }
                        } else {
                            guard initialRecord == nil else { valid = false; return }
                            initialRecord = (usage, recordTotal)
                        }
                        var packed = days[day]?[model] ?? [0, 0, 0]
                        for (index, amount) in [usage.input, usage.cached, usage.output].enumerated() {
                            let sum = packed[index].addingReportingOverflow(amount)
                            guard !sum.overflow else { valid = false; return }
                            packed[index] = sum.partialValue
                        }
                        days[day, default: [:]][model] = packed
                        rows.append(CodexUsageRow(day: day, model: model, turnID: payload["turn_id"] as? String,
                            input: usage.input, cached: usage.cached, output: usage.output))
                        lastRecord = usage
                        lastRecordTotal = recordTotal
                        newRecord = true
                    case "event_msg" where payload["type"] as? String == "token_count":
                        guard let infoValue = payload["info"], !(infoValue is NSNull) else { return }
                        guard let info = infoValue as? [String: Any],
                              let usage = PageTokens(info["last_token_usage"],
                                  allowZeroCompactionSummary: compacted),
                              let total = PageTokens(info["total_token_usage"]),
                              let timestamp = object["timestamp"] as? String,
                              let date = dateFromTimestamp(timestamp),
                              (usage == lastRecord && total == (newRecord ? lastRecordTotal : lastToken))
                                || (usage.total == 0 && compacted)
                        else { valid = false; return }
                        guard date <= through else { hasDeferredTail = true; return }
                        // Compaction can itself have a billed response just
                        // before this zero-component context summary. This
                        // later cursor confirms those response bytes too.
                        frontier = .init(endOffset: line.endOffset,
                            lineFingerprint: CodexTokenObservationCursor.fingerprint(for: line.bytes),
                            eventTimestamp: date, totalTokens: total.total)
                        lastToken = total
                        newRecord = false
                        compacted = false
                    default: break
                    }
                }
            })
        if let previousOrdinal {
            boundaries[previousOrdinal + 1] = parsed
            if !newRecord { confirmedTotals[previousOrdinal + 1] = lastToken }
        }
        if valid, sawMetadata, hasDeferredTail || newRecord || parsed != before.size {
            throw PaginatedReadError.deferredTail
        }
        guard valid, sawMetadata, !responseIDs.isEmpty, !newRecord, frontier != nil, parsed == before.size
        else { return nil }
        guard let digest = try codexCommittedPrefixFingerprint(fileURL: url, throughOffset: parsed,
            checkCancellation: checkCancellation) else {
            throw PaginatedReadError.deferredTail
        }
        let usage = makeFileUsage(mtimeUnixMs: before.mtimeUnixMs, size: before.size, days: days,
            parsedBytes: parsed, lastModel: model, sessionId: sessionID, sourceGeneration: before.fileId,
            sourceStatFingerprint: before.statFingerprint, sourceChangeTimeNanoseconds: before.changeTimeNanoseconds,
            committedPrefixFingerprint: digest,
            lastTokenEventEndOffset: frontier?.endOffset, lastTokenEventFingerprint: frontier?.lineFingerprint,
            lastTokenEventTimestamp: frontier?.eventTimestamp, lastTokenEventTotalTokens: frontier?.totalTokens,
            tokenEventWatermarks: frontier.map { [$0] }, codexRows: rows)
        guard paginatedSnapshotMatches(path: path, usage: usage) else {
            throw PaginatedReadError.deferredTail
        }
        return PaginatedPage(base: base, boundaries: boundaries, confirmedTotals: confirmedTotals,
            initialRecord: initialRecord, responseIDs: responseIDs, usage: usage)
    }
}

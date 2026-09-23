import Foundation

enum CostUsageCacheIO {
    private enum RequiredLoadError: Error {
        case incompatibleVersion
        case producerMismatch
        case dayContextMismatch
    }

    private static let compatibleCodexProducerKeys: Set<String> = [
        "codex:cu:p3c27f997569eb3c5",
    ]

    private static func artifactVersion(for provider: UsageProvider) -> Int {
        switch provider {
        case .codex:
            16
        case .claude, .vertexai:
            4
        default:
            1
        }
    }

    private static func defaultCacheRoot() -> URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return root.appendingPathComponent("AgentSignalBar", isDirectory: true)
    }

    static func cacheFileURL(provider: UsageProvider, cacheRoot: URL? = nil) -> URL {
        let root = cacheRoot ?? self.defaultCacheRoot()
        let artifactVersion = self.artifactVersion(for: provider)
        return root
            .appendingPathComponent("cost-usage", isDirectory: true)
            .appendingPathComponent("\(provider.rawValue)-v\(artifactVersion).json", isDirectory: false)
    }

    static func load(
        provider: UsageProvider,
        cacheRoot: URL? = nil,
        producerKey: String? = nil) -> CostUsageCache
    {
        (try? self.loadRequired(
            provider: provider,
            cacheRoot: cacheRoot,
            producerKey: producerKey)) ?? CostUsageCache()
    }

    static func loadRequired(
        provider: UsageProvider,
        cacheRoot: URL? = nil,
        producerKey: String? = nil) throws -> CostUsageCache
    {
        let url = self.cacheFileURL(provider: provider, cacheRoot: cacheRoot)
        let expectedProducerKey = producerKey ?? self.currentProducerKey(provider: provider)
        let compatibleProducerKeys = producerKey == nil && provider == .codex
            ? self.compatibleCodexProducerKeys
            : []
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(CostUsageCache.self, from: data)
        guard decoded.version == 1 else { throw RequiredLoadError.incompatibleVersion }
        guard decoded.dayContext == CostUsageDayContext.current else {
            throw RequiredLoadError.dayContextMismatch
        }
        if let expectedProducerKey {
            guard decoded.producerKey == expectedProducerKey
                || decoded.producerKey.map(compatibleProducerKeys.contains) == true
            else { throw RequiredLoadError.producerMismatch }
        }
        return decoded
    }

    static func save(
        provider: UsageProvider,
        cache: CostUsageCache,
        cacheRoot: URL? = nil,
        producerKey: String? = nil) throws
    {
        let url = self.cacheFileURL(provider: provider, cacheRoot: cacheRoot)
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var cache = cache
        cache.producerKey = producerKey ?? self.currentProducerKey(provider: provider)

        let tmp = dir.appendingPathComponent(".tmp-\(UUID().uuidString).json", isDirectory: false)
        let data = try JSONEncoder().encode(cache)
        do {
            try data.write(to: tmp, options: [.atomic])
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }

    static func currentProducerKey(
        provider: UsageProvider,
        parserHash: String = CodexParserHash.value) -> String?
    {
        guard provider == .codex else { return nil }
        return "\(provider.rawValue):cu:p\(parserHash)"
    }
}

struct CostUsageCache: Codable {
    var version: Int = 1
    var dayContext: CostUsageDayContext? = .current
    var producerKey: String?
    var lastScanUnixMs: Int64 = 0
    var scanSinceKey: String?
    var scanUntilKey: String?
    var codexPricingKey: String?
    var codexPriorityMetadataKey: String?
    var codexPriorityTurnKeys: [String: String]?
    var codexPriorityTurnIDsByDay: [String: [String]]?
    var codexSessionInventoryComplete: Bool?
    var codexSessionDirectoryFingerprints: [String: Int64]?
    var codexScanWarnings: [CostUsageScanWarning]?
    /// Migrate identity decisions without discarding the confirmed usage ledger.
    var codexIdentityPolicyVersion: Int?
    /// These owners depend on revocable no-usage proofs, not byte-equivalent copies.
    var codexNoncontributingSessionIDs: [String]?
    /// Proven, disjoint response ledgers for paginated rollouts sharing a thread ID.
    /// Keep them separate from the single-owner inventory and inherited-fork index.
    var codexPaginatedLedgers: [String: [String: CostUsageFileUsage]]?

    /// filePath -> file usage
    var files: [String: CostUsageFileUsage] = [:]

    /// dayKey -> model -> packed usage
    var days: [String: [String: [Int]]] = [:]

    /// rootPath -> mtime (for Claude roots)
    var roots: [String: Int64]?
}

/// Context used to assign timestamps to daily buckets. Legacy caches without
/// this information must be rebuilt rather than guessed to be local.
struct CostUsageDayContext: Codable, Equatable {
    let calendarIdentifier: String
    let timeZoneIdentifier: String

    static var current: Self {
        let calendar = Calendar.current
        return Self(
            calendarIdentifier: String(describing: calendar.identifier),
            timeZoneIdentifier: calendar.timeZone.identifier
        )
    }
}

struct CostUsageFileUsage: Codable {
    var mtimeUnixMs: Int64
    var size: Int64
    var days: [String: [String: [Int]]]
    var parsedBytes: Int64?
    var lastModel: String?
    var lastTotals: CostUsageCodexTotals?
    var lastCountedTotals: CostUsageCodexTotals?
    var lastRawTotalsBaseline: CostUsageCodexTotals?
    var hasDivergentTotals: Bool?
    var lastCodexTurnID: String?
    var sessionId: String?
    var forkedFromId: String?
    var sourceGeneration: String?
    /// Stable stat hash including nanosecond mtime and ctime for this source.
    var sourceStatFingerprint: Int64?
    /// Nanosecond ctime for ordering snapshots of the same device/inode.
    var sourceChangeTimeNanoseconds: Int64?
    /// SHA-256 of the exact committed prefix `[0..<parsedBytes]`.
    var committedPrefixFingerprint: String?
    /// True for paths retained only so metadata changes cannot be missed.
    /// Inventory-only entries never contribute `days` to the aggregate.
    var codexInventoryOnly: Bool?
    /// True when this unchanged duplicate diverges from the proven owner chain.
    /// A metadata change clears the quarantine through normal reconciliation.
    var codexDuplicateQuarantined: Bool?
    /// No copy in this session group has a provable aggregate owner. Unlike a
    /// rejected copy beside a verified owner, this never authorizes a watermark.
    var codexIdentityConflict: Bool?
    /// A fully parsed, unchanged no-usage copy. Its full-file SHA-256 is stored
    /// in committedPrefixFingerprint; it is never a usage/watermark alias.
    var codexNoncontributingDuplicate: Bool?
    var lastTokenEventEndOffset: Int64?
    var lastTokenEventFingerprint: String?
    var lastTokenEventTimestamp: Date?
    var lastTokenEventTotalTokens: Int?
    var tokenEventWatermarks: [CostUsageTokenEventWatermark]?
    var codexCostNanos: [String: [String: Int64]]?
    var codexPrioritySurchargeNanos: [String: [String: Int64]]?
    var codexStandardCostNanos: [String: [String: Int64]]?
    var codexPriorityCostNanos: [String: [String: Int64]]?
    var codexStandardTokens: [String: [String: Int]]?
    var codexPriorityTokens: [String: [String: Int]]?
    var codexUnpricedTokens: [String: [String: Int]]?
    var codexTurnIDs: [String]?
    var codexRows: [CostUsageScanner.CodexUsageRow]?
    var claudeRows: [CostUsageScanner.ClaudeUsageRow]?
}

struct CostUsageTokenEventWatermark: Codable, Equatable {
    let endOffset: Int64
    let lineFingerprint: String
    let eventTimestamp: Date?
    let totalTokens: Int?
}

struct CostUsageCodexTotals: Codable {
    var input: Int
    var cached: Int
    var output: Int
}

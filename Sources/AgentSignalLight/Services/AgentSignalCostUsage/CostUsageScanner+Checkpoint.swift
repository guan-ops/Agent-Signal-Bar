import Foundation

extension CostUsageScanner {
    /// Retry work only. This is never a published cache and cannot supply a
    /// report without another inventory, source-prefix proof and atomic commit.
    final class CodexScanCheckpoint: @unchecked Sendable {
        struct Scope: Equatable {
            let cachePath: String
            let producerKey: String?
            let rootIdentities: [String]
            let committedCacheFingerprint: String
            let calendarIdentifier: String
            let timeZoneIdentifier: String
        }

        private struct Candidate {
            let scope: Scope
            let cache: CostUsageCache
        }

        private let lock = NSLock()
        private var candidate: Candidate?
        private var generation: UInt64 = 0

        func clear() {
            self.lock.lock()
            self.candidate = nil
            self.generation &+= 1
            self.lock.unlock()
        }

        var currentGeneration: UInt64 {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.generation
        }

        var hasCandidate: Bool {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.candidate != nil
        }

        func load(scope: Scope, throughUnixMs: Int64) -> CostUsageCache? {
            self.lock.lock()
            defer { self.lock.unlock() }
            guard let candidate = self.candidate,
                  candidate.scope == scope,
                  candidate.cache.lastScanUnixMs <= throughUnixMs
            else {
                self.candidate = nil
                return nil
            }
            return candidate.cache
        }

        func store(_ cache: CostUsageCache, scope: Scope, generation: UInt64) {
            var uncommitted = cache
            uncommitted.codexSessionInventoryComplete = false
            self.lock.lock()
            defer { self.lock.unlock() }
            guard self.generation == generation else { return }
            self.candidate = Candidate(scope: scope, cache: uncommitted)
        }
    }

    static func codexCheckpointScope(options: Options) -> CodexScanCheckpoint.Scope? {
        let cacheURL = CostUsageCacheIO.cacheFileURL(provider: .codex, cacheRoot: options.cacheRoot)
            .standardizedFileURL.resolvingSymlinksInPath()
        let metadata = Self.codexFileMetadata(fileURL: cacheURL)
        let baseline: String
        if let generation = metadata.fileId,
           let fingerprint = metadata.statFingerprint {
            baseline = "\(generation)|\(metadata.size)|\(fingerprint)"
        } else {
            guard !FileManager.default.fileExists(atPath: cacheURL.path) else { return nil }
            baseline = "missing"
        }
        return CodexScanCheckpoint.Scope(
            cachePath: cacheURL.path,
            producerKey: CostUsageCacheIO.currentProducerKey(provider: .codex),
            rootIdentities: Self.codexRootsFingerprint(options: options).keys.sorted(),
            committedCacheFingerprint: baseline,
            calendarIdentifier: String(describing: Calendar.current.identifier),
            timeZoneIdentifier: TimeZone.current.identifier
        )
    }

    static func codexCheckpointPrefixesRemainValid(
        cache: CostUsageCache,
        checkCancellation: CancellationCheck?
    ) throws -> Bool {
        for (path, usage) in cache.files.sorted(by: { $0.key < $1.key }) {
            try checkCancellation?()
            guard usage.codexInventoryOnly != true,
                  usage.committedPrefixFingerprint != nil
            else { continue }
            guard try Self.codexFileMatchesCommittedFrontier(
                fileURL: URL(fileURLWithPath: path), cached: usage,
                checkCancellation: checkCancellation
            ) else { return false }
        }
        return true
    }
}

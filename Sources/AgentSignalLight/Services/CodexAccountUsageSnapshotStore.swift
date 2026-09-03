import AgentSignalLightCore
import Foundation

struct CodexUsageFetchState: Codable, Equatable, Sendable {
    var source: CodexUsageFetchSource?
    var lastSuccessfulAt: Date?
    var lastAttemptedAt: Date?
    var errorMessage: String?
    var isStale: Bool
}

struct CodexResetCreditsFetchState: Codable, Equatable, Sendable {
    var lastSuccessfulAt: Date?
    var lastAttemptedAt: Date?
    var errorMessage: String?
    var isStale: Bool
}

struct CodexLiveTokenCounterSnapshot: Codable, Equatable, Sendable {
    let key: String
    let sessionID: String?
    let totalTokens: Int
    let scannedBaseline: Int
    let day: Date
    let updatedAt: Date?
    let observationCursor: CodexTokenObservationCursor?

    init(
        key: String,
        sessionID: String?,
        totalTokens: Int,
        scannedBaseline: Int,
        day: Date,
        updatedAt: Date?,
        observationCursor: CodexTokenObservationCursor? = nil
    ) {
        self.key = key
        self.sessionID = sessionID
        self.totalTokens = totalTokens
        self.scannedBaseline = scannedBaseline
        self.day = day
        self.updatedAt = updatedAt
        self.observationCursor = observationCursor
    }
}

struct CodexLiveTokenCarrySnapshot: Codable, Equatable, Sendable {
    let key: String?
    let sessionID: String?
    let day: Date
    let totalTokens: Int
    let updatedAt: Date?
    let observationCursor: CodexTokenObservationCursor?

    init(
        key: String? = nil,
        sessionID: String? = nil,
        day: Date,
        totalTokens: Int,
        updatedAt: Date? = nil,
        observationCursor: CodexTokenObservationCursor? = nil
    ) {
        self.key = key
        self.sessionID = sessionID
        self.day = day
        self.totalTokens = totalTokens
        self.updatedAt = updatedAt
        self.observationCursor = observationCursor
    }
}

struct CodexLiveTokenScanWatermarkSnapshot: Codable, Equatable, Sendable {
    let sessionID: String?
    let sourceID: String
    let sourceGeneration: String
    let sourceStatFingerprint: Int64?
    let sourceChangeTimeNanoseconds: Int64?
    let endOffset: UInt64
    let lineFingerprint: String
    let eventTimestamp: Date?
    let totalTokens: Int?
}

struct CodexLegacyUnscopedTokenFloorSnapshot: Codable, Equatable, Sendable {
    let totalTokens: Int
    let day: Date
}

struct CodexAccountUsageSnapshot: Codable, Equatable, Sendable {
    let accountKey: String
    let email: String?
    let accountID: String?
    let authFingerprint: String?
    var quota: AgentQuotaStatus?
    var credits: CodexCreditStatus?
    var resetCredits: CodexRateLimitResetCreditsSnapshot?
    var usageFetchState: CodexUsageFetchState?
    var resetCreditsFetchState: CodexResetCreditsFetchState?
    var tokenUsage: AgentTokenUsage?
    var liveTokenUsageScanBaseline: Int?
    var unscannedLiveTokenCarry: Int?
    var liveTokenCounters: [CodexLiveTokenCounterSnapshot]?
    var unscannedLiveTokenCarryByDay: [CodexLiveTokenCarrySnapshot]?
    var liveTokenUsageScanCutoff: Date?
    var liveTokenScanWatermarks: [CodexLiveTokenScanWatermarkSnapshot]?
    var legacyUnscopedTokenFloor: CodexLegacyUnscopedTokenFloorSnapshot?
    var tokenActivityCacheVersion: Int?
    var tokenActivityDays: [CodexTokenActivityDay]
    var updatedAt: Date
}

/// Token activity is derived from all Codex JSONL files visible to this Mac
/// user. Those files do not carry a trustworthy saved-account identity, so the
/// ledger must never be stored in (or restored from) an account-owned record.
struct CodexDeviceTokenUsageSnapshot: Codable, Equatable, Sendable {
    var tokenUsage: AgentTokenUsage?
    var tokenUsageSessionID: String?
    var tokenUsageUpdatedAt: Date?
    var liveTokenUsageScanBaseline: Int?
    var unscannedLiveTokenCarry: Int?
    var liveTokenCounters: [CodexLiveTokenCounterSnapshot]?
    var unscannedLiveTokenCarryByDay: [CodexLiveTokenCarrySnapshot]?
    var liveTokenUsageScanCutoff: Date?
    var liveTokenScanWatermarks: [CodexLiveTokenScanWatermarkSnapshot]?
    var legacyUnscopedTokenFloor: CodexLegacyUnscopedTokenFloorSnapshot?
    var tokenActivityCacheVersion: Int?
    var tokenActivityDays: [CodexTokenActivityDay]
    var tokenActivityExcludedSessionCount: Int? = nil
    var updatedAt: Date
}

final class CodexAccountUsageSnapshotStore: @unchecked Sendable {
    private struct StoreDocument: Codable {
        var version: Int
        var snapshots: [CodexAccountUsageSnapshot]
        var deviceTokenSnapshot: CodexDeviceTokenUsageSnapshot?
    }

    private static let currentVersion = 2
    nonisolated(unsafe) static var defaultFileURLOverride: URL?

    private let fileURL: URL
    private let fileManager: FileManager

    init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.fileURL = fileURL
            ?? Self.defaultFileURLOverride
            ?? Self.defaultURL(fileManager: fileManager)
    }

    func snapshot(for account: CodexCurrentAccount) -> CodexAccountUsageSnapshot? {
        loadDocument().snapshots.first { $0.matches(account) }
    }

    func deviceTokenSnapshot() -> CodexDeviceTokenUsageSnapshot? {
        loadDocument().deviceTokenSnapshot
    }

    func store(
        account: CodexCurrentAccount,
        quota: AgentQuotaStatus?,
        credits: CodexCreditStatus?,
        resetCredits: CodexRateLimitResetCreditsSnapshot? = nil,
        usageFetchState: CodexUsageFetchState? = nil,
        resetCreditsFetchState: CodexResetCreditsFetchState? = nil,
        tokenUsage: AgentTokenUsage?,
        tokenUsageSessionID: String? = nil,
        tokenUsageUpdatedAt: Date? = nil,
        liveTokenUsageScanBaseline: Int? = nil,
        unscannedLiveTokenCarry: Int? = nil,
        liveTokenCounters: [CodexLiveTokenCounterSnapshot]? = nil,
        unscannedLiveTokenCarryByDay: [CodexLiveTokenCarrySnapshot]? = nil,
        liveTokenUsageScanCutoff: Date? = nil,
        liveTokenScanWatermarks: [CodexLiveTokenScanWatermarkSnapshot]? = nil,
        legacyUnscopedTokenFloor: CodexLegacyUnscopedTokenFloorSnapshot? = nil,
        tokenActivityCacheVersion: Int?,
        tokenActivityDays: [CodexTokenActivityDay],
        tokenActivityExcludedSessionCount: Int? = nil,
        updatedAt: Date = Date()
    ) {
        var document = loadDocument()
        var snapshots = document.snapshots
        let snapshot = CodexAccountUsageSnapshot(
            accountKey: account.usageSnapshotKey,
            email: account.normalizedUsageEmail,
            accountID: account.normalizedUsageAccountID,
            authFingerprint: account.authFingerprint,
            quota: Self.accountScopedQuota(quota),
            credits: credits,
            resetCredits: resetCredits,
            usageFetchState: usageFetchState,
            resetCreditsFetchState: resetCreditsFetchState,
            // These fields remain decodable solely for migration from version 1.
            // New account records intentionally contain no device token ledger.
            tokenUsage: nil,
            liveTokenUsageScanBaseline: nil,
            unscannedLiveTokenCarry: nil,
            liveTokenCounters: nil,
            unscannedLiveTokenCarryByDay: nil,
            liveTokenUsageScanCutoff: nil,
            liveTokenScanWatermarks: nil,
            legacyUnscopedTokenFloor: nil,
            tokenActivityCacheVersion: nil,
            tokenActivityDays: [],
            updatedAt: updatedAt
        )

        if let index = snapshots.firstIndex(where: { $0.matches(account) }) {
            snapshots[index] = snapshot
        } else {
            snapshots.append(snapshot)
        }
        document.version = Self.currentVersion
        document.snapshots = snapshots
        document.deviceTokenSnapshot = Self.makeDeviceTokenSnapshot(
            tokenUsage: tokenUsage,
            tokenUsageSessionID: tokenUsageSessionID,
            tokenUsageUpdatedAt: tokenUsageUpdatedAt,
            liveTokenUsageScanBaseline: liveTokenUsageScanBaseline,
            unscannedLiveTokenCarry: unscannedLiveTokenCarry,
            liveTokenCounters: liveTokenCounters,
            unscannedLiveTokenCarryByDay: unscannedLiveTokenCarryByDay,
            liveTokenUsageScanCutoff: liveTokenUsageScanCutoff,
            liveTokenScanWatermarks: liveTokenScanWatermarks,
            legacyUnscopedTokenFloor: legacyUnscopedTokenFloor,
            tokenActivityCacheVersion: tokenActivityCacheVersion,
            tokenActivityDays: tokenActivityDays,
            tokenActivityExcludedSessionCount: tokenActivityExcludedSessionCount,
            updatedAt: updatedAt
        )
        storeDocument(document)
    }

    func storeDeviceTokenSnapshot(
        tokenUsage: AgentTokenUsage?,
        tokenUsageSessionID: String? = nil,
        tokenUsageUpdatedAt: Date? = nil,
        liveTokenUsageScanBaseline: Int? = nil,
        unscannedLiveTokenCarry: Int? = nil,
        liveTokenCounters: [CodexLiveTokenCounterSnapshot]? = nil,
        unscannedLiveTokenCarryByDay: [CodexLiveTokenCarrySnapshot]? = nil,
        liveTokenUsageScanCutoff: Date? = nil,
        liveTokenScanWatermarks: [CodexLiveTokenScanWatermarkSnapshot]? = nil,
        legacyUnscopedTokenFloor: CodexLegacyUnscopedTokenFloorSnapshot? = nil,
        tokenActivityCacheVersion: Int?,
        tokenActivityDays: [CodexTokenActivityDay],
        tokenActivityExcludedSessionCount: Int? = nil,
        updatedAt: Date = Date()
    ) {
        var document = loadDocument()
        document.version = Self.currentVersion
        document.deviceTokenSnapshot = Self.makeDeviceTokenSnapshot(
            tokenUsage: tokenUsage,
            tokenUsageSessionID: tokenUsageSessionID,
            tokenUsageUpdatedAt: tokenUsageUpdatedAt,
            liveTokenUsageScanBaseline: liveTokenUsageScanBaseline,
            unscannedLiveTokenCarry: unscannedLiveTokenCarry,
            liveTokenCounters: liveTokenCounters,
            unscannedLiveTokenCarryByDay: unscannedLiveTokenCarryByDay,
            liveTokenUsageScanCutoff: liveTokenUsageScanCutoff,
            liveTokenScanWatermarks: liveTokenScanWatermarks,
            legacyUnscopedTokenFloor: legacyUnscopedTokenFloor,
            tokenActivityCacheVersion: tokenActivityCacheVersion,
            tokenActivityDays: tokenActivityDays,
            tokenActivityExcludedSessionCount: tokenActivityExcludedSessionCount,
            updatedAt: updatedAt
        )
        storeDocument(document)
    }

    func remove(for account: CodexAccountProfile) {
        var document = loadDocument()
        document.snapshots.removeAll { $0.matches(account) }
        storeDocument(document)
    }

    func removeAll() {
        try? fileManager.removeItem(at: fileURL)
    }

    private func loadDocument() -> StoreDocument {
        guard fileManager.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              var document = try? JSONDecoder().decode(StoreDocument.self, from: data),
              document.version == 1 || document.version == Self.currentVersion
        else {
            return StoreDocument(
                version: Self.currentVersion,
                snapshots: [],
                deviceTokenSnapshot: nil
            )
        }

        if document.deviceTokenSnapshot == nil {
            document.deviceTokenSnapshot = Self.migratedDeviceTokenSnapshot(
                from: document.snapshots
            )
        }
        document.snapshots = document.snapshots.map(Self.accountScopedSnapshot)
        document.version = Self.currentVersion
        return document
    }

    private func storeDocument(_ document: StoreDocument) {
        do {
            let directory = fileURL.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: directory.path) {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(document).write(to: fileURL, options: .atomic)
            try? fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: fileURL.path
            )
        } catch {
            // Usage snapshots are best-effort; refreshes should not fail because cache persistence failed.
        }
    }

    private static func migratedDeviceTokenSnapshot(
        from snapshots: [CodexAccountUsageSnapshot]
    ) -> CodexDeviceTokenUsageSnapshot? {
        let legacy = snapshots.filter { snapshot in
                snapshot.tokenUsage != nil
                    || snapshot.quota?.tokenUsage != nil
                    || !(snapshot.liveTokenCounters ?? []).isEmpty
                    || !(snapshot.unscannedLiveTokenCarryByDay ?? []).isEmpty
                    || !snapshot.tokenActivityDays.isEmpty
                    || snapshot.legacyUnscopedTokenFloor != nil
            }
        guard !legacy.isEmpty else { return nil }

        // Version-1 account records were snapshots of one device-wide JSONL
        // ledger, not independent account ledgers. Union identity-bearing
        // history, but never add two whole-record totals: account switches can
        // leave identical or partially overlapping copies behind.
        let newestLegacy = legacy.max { $0.updatedAt < $1.updatedAt }!
        let selectedCacheVersion = legacy
            .filter { $0.tokenActivityCacheVersion != nil }
            .max { $0.updatedAt < $1.updatedAt }?
            .tokenActivityCacheVersion
        let compatibleHistory = legacy.filter {
            $0.tokenActivityCacheVersion == selectedCacheVersion
        }
        let tokenCandidate = legacy
            .compactMap(Self.legacyTokenUsageCandidate)
            .max(by: Self.legacyTokenUsageCandidateIsOlder)
        let tokenUsage = tokenCandidate?.usage
        let watermarks = Self.mergedLegacyWatermarks(from: compatibleHistory)
        let counters = Self.mergedLegacyCounters(from: compatibleHistory).map { counter in
            guard counter.scannedBaseline < counter.totalTokens,
                  Self.legacyObservationIsCovered(
                      sessionID: counter.sessionID,
                      cursor: counter.observationCursor,
                      watermarks: watermarks ?? []
                  )
            else {
                return counter
            }
            // A later account copy may omit a live counter because its exact
            // line has already entered the daily scan. Preserve the identity
            // for the latest-usage display, but do not revive it as pending.
            return CodexLiveTokenCounterSnapshot(
                key: counter.key,
                sessionID: counter.sessionID,
                totalTokens: counter.totalTokens,
                scannedBaseline: counter.totalTokens,
                day: counter.day,
                updatedAt: counter.updatedAt,
                observationCursor: counter.observationCursor
            )
        }
        let newestMatchingCounter = counters
            .filter { $0.totalTokens == tokenUsage?.effectiveTotalTokens }
            .max(by: Self.legacyCounterIsOlder)
        let tokenUsageUpdatedAt = newestMatchingCounter?.updatedAt
            ?? tokenCandidate?.observedAt
        let tokenUsageSessionID = newestMatchingCounter?.sessionID

        return CodexDeviceTokenUsageSnapshot(
            tokenUsage: tokenUsage,
            tokenUsageSessionID: tokenUsageSessionID,
            tokenUsageUpdatedAt: tokenUsageUpdatedAt,
            liveTokenUsageScanBaseline: newestMatchingCounter?.scannedBaseline
                ?? tokenCandidate?.snapshot.liveTokenUsageScanBaseline,
            unscannedLiveTokenCarry: compatibleHistory
                .compactMap(\.unscannedLiveTokenCarry)
                .map { max(0, $0) }
                .max(),
            liveTokenCounters: counters.isEmpty ? nil : counters,
            unscannedLiveTokenCarryByDay: Self.mergedLegacyCarries(
                from: compatibleHistory
            )?.filter {
                !Self.legacyObservationIsCovered(
                    sessionID: $0.sessionID,
                    cursor: $0.observationCursor,
                    watermarks: watermarks ?? []
                )
            },
            liveTokenUsageScanCutoff: compatibleHistory
                .compactMap(\.liveTokenUsageScanCutoff)
                .max(),
            liveTokenScanWatermarks: watermarks,
            legacyUnscopedTokenFloor: Self.mergedLegacyFloor(
                from: compatibleHistory
            ),
            tokenActivityCacheVersion: selectedCacheVersion,
            tokenActivityDays: Self.mergedLegacyActivityDays(
                from: compatibleHistory
            ),
            updatedAt: newestLegacy.updatedAt
        )
    }

    private struct LegacyTokenUsageCandidate {
        let usage: AgentTokenUsage
        let observedAt: Date?
        let snapshot: CodexAccountUsageSnapshot
    }

    private struct LegacyCounterCandidate {
        let counter: CodexLiveTokenCounterSnapshot
        let snapshotUpdatedAt: Date
    }

    private static func legacyTokenUsageCandidate(
        from snapshot: CodexAccountUsageSnapshot
    ) -> LegacyTokenUsageCandidate? {
        guard let usage = snapshot.tokenUsage ?? snapshot.quota?.tokenUsage else {
            return nil
        }
        let matchingCounter = snapshot.liveTokenCounters?
            .filter { $0.totalTokens == usage.effectiveTotalTokens }
            .max(by: legacyCounterIsOlder)
        let quotaObservedAt = snapshot.quota?.tokenUsage == usage
            ? snapshot.quota?.updatedAt
            : nil
        return LegacyTokenUsageCandidate(
            usage: usage,
            observedAt: matchingCounter?.updatedAt ?? quotaObservedAt,
            snapshot: snapshot
        )
    }

    private static func legacyTokenUsageCandidateIsOlder(
        _ lhs: LegacyTokenUsageCandidate,
        _ rhs: LegacyTokenUsageCandidate
    ) -> Bool {
        let lhsDate = lhs.observedAt ?? lhs.snapshot.updatedAt
        let rhsDate = rhs.observedAt ?? rhs.snapshot.updatedAt
        if lhsDate != rhsDate { return lhsDate < rhsDate }
        return (lhs.usage.effectiveTotalTokens ?? 0)
            < (rhs.usage.effectiveTotalTokens ?? 0)
    }

    private static func mergedLegacyCounters(
        from snapshots: [CodexAccountUsageSnapshot]
    ) -> [CodexLiveTokenCounterSnapshot] {
        var merged: [String: LegacyCounterCandidate] = [:]
        for snapshot in snapshots {
            for counter in snapshot.liveTokenCounters ?? [] {
                let key = normalizedLegacySessionID(counter.sessionID)
                let candidate = LegacyCounterCandidate(
                    counter: counter,
                    snapshotUpdatedAt: snapshot.updatedAt
                )
                guard let existing = merged[key] else {
                    merged[key] = candidate
                    continue
                }
                if legacyCounterCandidateIsOlder(existing, candidate) {
                    merged[key] = candidate
                } else if !legacyCounterCandidateIsOlder(candidate, existing),
                          counter.totalTokens == existing.counter.totalTokens,
                          counter.scannedBaseline > existing.counter.scannedBaseline {
                    merged[key] = LegacyCounterCandidate(
                        counter: CodexLiveTokenCounterSnapshot(
                            key: existing.counter.key,
                            sessionID: existing.counter.sessionID,
                            totalTokens: existing.counter.totalTokens,
                            scannedBaseline: counter.scannedBaseline,
                            day: existing.counter.day,
                            updatedAt: existing.counter.updatedAt,
                            observationCursor: existing.counter.observationCursor
                        ),
                        snapshotUpdatedAt: existing.snapshotUpdatedAt
                    )
                }
            }
        }
        return merged.values.map(\.counter).sorted {
            normalizedLegacySessionID($0.sessionID)
                < normalizedLegacySessionID($1.sessionID)
        }
    }

    private static func legacyCounterCandidateIsOlder(
        _ lhs: LegacyCounterCandidate,
        _ rhs: LegacyCounterCandidate
    ) -> Bool {
        if legacyCounterIsOlder(lhs.counter, rhs.counter) { return true }
        if legacyCounterIsOlder(rhs.counter, lhs.counter) { return false }
        if lhs.snapshotUpdatedAt != rhs.snapshotUpdatedAt {
            return lhs.snapshotUpdatedAt < rhs.snapshotUpdatedAt
        }
        return lhs.counter.totalTokens < rhs.counter.totalTokens
    }

    private static func legacyCounterIsOlder(
        _ lhs: CodexLiveTokenCounterSnapshot,
        _ rhs: CodexLiveTokenCounterSnapshot
    ) -> Bool {
        if let lhsCursor = lhs.observationCursor,
           let rhsCursor = rhs.observationCursor,
           lhsCursor.sourceGeneration == rhsCursor.sourceGeneration {
            if let lhsChange = lhsCursor.sourceChangeTimeNanoseconds,
               let rhsChange = rhsCursor.sourceChangeTimeNanoseconds,
               lhsChange != rhsChange {
                return lhsChange < rhsChange
            }
            let sameContentSnapshot = lhsCursor.sourceStatFingerprint
                == rhsCursor.sourceStatFingerprint
            if sameContentSnapshot,
               lhsCursor.endOffset != rhsCursor.endOffset {
                return lhsCursor.endOffset < rhsCursor.endOffset
            }
        }
        let lhsDate = lhs.updatedAt ?? .distantPast
        let rhsDate = rhs.updatedAt ?? .distantPast
        if lhsDate != rhsDate { return lhsDate < rhsDate }
        return lhs.totalTokens < rhs.totalTokens
    }

    private static func mergedLegacyCarries(
        from snapshots: [CodexAccountUsageSnapshot]
    ) -> [CodexLiveTokenCarrySnapshot]? {
        var merged: [String: CodexLiveTokenCarrySnapshot] = [:]
        for snapshot in snapshots {
            for carry in snapshot.unscannedLiveTokenCarryByDay ?? [] {
                let key = legacyCarryIdentity(carry)
                guard let existing = merged[key] else {
                    merged[key] = carry
                    continue
                }
                if carry.totalTokens > existing.totalTokens
                    || (carry.totalTokens == existing.totalTokens
                        && (carry.updatedAt ?? snapshot.updatedAt)
                            > (existing.updatedAt ?? .distantPast)) {
                    merged[key] = carry
                }
            }
        }
        return merged.isEmpty ? nil : merged.values.sorted {
            legacyCarryIdentity($0) < legacyCarryIdentity($1)
        }
    }

    private static func legacyCarryIdentity(
        _ carry: CodexLiveTokenCarrySnapshot
    ) -> String {
        if let key = carry.key, !key.isEmpty { return "key:\(key)" }
        if let cursor = carry.observationCursor {
            return "cursor:\(cursor.sourceGeneration):\(cursor.endOffset):\(cursor.lineFingerprint)"
        }
        return "legacy:\(normalizedLegacySessionID(carry.sessionID)):\(Calendar.current.startOfDay(for: carry.day).timeIntervalSince1970):\(carry.updatedAt?.timeIntervalSince1970 ?? 0)"
    }

    private static func mergedLegacyWatermarks(
        from snapshots: [CodexAccountUsageSnapshot]
    ) -> [CodexLiveTokenScanWatermarkSnapshot]? {
        var merged: [String: (CodexLiveTokenScanWatermarkSnapshot, Date)] = [:]
        for snapshot in snapshots {
            for watermark in snapshot.liveTokenScanWatermarks ?? [] {
                let key = "\(watermark.sourceGeneration)\u{0}\(normalizedLegacySessionID(watermark.sessionID))"
                guard let existing = merged[key] else {
                    merged[key] = (watermark, snapshot.updatedAt)
                    continue
                }
                if legacyWatermarkIsOlder(
                    existing.0,
                    existingSnapshotUpdatedAt: existing.1,
                    than: watermark,
                    candidateSnapshotUpdatedAt: snapshot.updatedAt
                ) {
                    merged[key] = (watermark, snapshot.updatedAt)
                }
            }
        }
        return merged.isEmpty ? nil : merged.values.map(\.0).sorted {
            if $0.sourceGeneration != $1.sourceGeneration {
                return $0.sourceGeneration < $1.sourceGeneration
            }
            return normalizedLegacySessionID($0.sessionID)
                < normalizedLegacySessionID($1.sessionID)
        }
    }

    private static func legacyWatermarkIsOlder(
        _ existing: CodexLiveTokenScanWatermarkSnapshot,
        existingSnapshotUpdatedAt: Date,
        than candidate: CodexLiveTokenScanWatermarkSnapshot,
        candidateSnapshotUpdatedAt: Date
    ) -> Bool {
        if let existingChange = existing.sourceChangeTimeNanoseconds,
           let candidateChange = candidate.sourceChangeTimeNanoseconds,
           existingChange != candidateChange {
            return existingChange < candidateChange
        }
        if existing.sourceStatFingerprint == candidate.sourceStatFingerprint,
           existing.endOffset != candidate.endOffset {
            return existing.endOffset < candidate.endOffset
        }
        if existingSnapshotUpdatedAt != candidateSnapshotUpdatedAt {
            return existingSnapshotUpdatedAt < candidateSnapshotUpdatedAt
        }
        return existing.endOffset < candidate.endOffset
    }

    private enum LegacySourceSnapshotRelation {
        case same
        case lhsNewer
        case lhsOlder
        case legacy
        case incomparable
    }

    private static func legacyObservationIsCovered(
        sessionID: String?,
        cursor: CodexTokenObservationCursor?,
        watermarks: [CodexLiveTokenScanWatermarkSnapshot]
    ) -> Bool {
        guard sessionID != nil, let cursor else { return false }
        let normalizedSessionID = normalizedLegacySessionID(sessionID)
        return watermarks.contains { watermark in
            guard watermark.sourceGeneration == cursor.sourceGeneration,
                  normalizedLegacySessionID(watermark.sessionID) == normalizedSessionID
            else {
                return false
            }
            let exactLine = watermark.endOffset == cursor.endOffset
                && watermark.lineFingerprint == cursor.lineFingerprint
            switch legacySourceSnapshotRelation(
                lhsChangeTimeNanoseconds: watermark.sourceChangeTimeNanoseconds,
                lhsStatFingerprint: watermark.sourceStatFingerprint,
                rhsChangeTimeNanoseconds: cursor.sourceChangeTimeNanoseconds,
                rhsStatFingerprint: cursor.sourceStatFingerprint
            ) {
            case .lhsNewer:
                return true
            case .lhsOlder, .incomparable:
                return exactLine
            case .same, .legacy:
                return watermark.endOffset == .max
                    || watermark.endOffset > cursor.endOffset
                    || exactLine
            }
        }
    }

    private static func legacySourceSnapshotRelation(
        lhsChangeTimeNanoseconds: Int64?,
        lhsStatFingerprint: Int64?,
        rhsChangeTimeNanoseconds: Int64?,
        rhsStatFingerprint: Int64?
    ) -> LegacySourceSnapshotRelation {
        if let lhsChangeTimeNanoseconds, let rhsChangeTimeNanoseconds {
            if lhsChangeTimeNanoseconds > rhsChangeTimeNanoseconds { return .lhsNewer }
            if lhsChangeTimeNanoseconds < rhsChangeTimeNanoseconds { return .lhsOlder }
            if let lhsStatFingerprint, let rhsStatFingerprint,
               lhsStatFingerprint != rhsStatFingerprint {
                return .incomparable
            }
            return .same
        }
        if let lhsStatFingerprint, let rhsStatFingerprint {
            return lhsStatFingerprint == rhsStatFingerprint ? .same : .incomparable
        }
        if lhsChangeTimeNanoseconds == nil,
           rhsChangeTimeNanoseconds == nil,
           lhsStatFingerprint == nil,
           rhsStatFingerprint == nil {
            return .legacy
        }
        return .incomparable
    }

    private static func mergedLegacyFloor(
        from snapshots: [CodexAccountUsageSnapshot]
    ) -> CodexLegacyUnscopedTokenFloorSnapshot? {
        snapshots.compactMap(\.legacyUnscopedTokenFloor).max {
            let lhsDay = Calendar.current.startOfDay(for: $0.day)
            let rhsDay = Calendar.current.startOfDay(for: $1.day)
            if lhsDay != rhsDay { return lhsDay < rhsDay }
            return $0.totalTokens < $1.totalTokens
        }
    }

    private static func mergedLegacyActivityDays(
        from snapshots: [CodexAccountUsageSnapshot]
    ) -> [CodexTokenActivityDay] {
        var merged: [Date: (day: CodexTokenActivityDay, snapshotUpdatedAt: Date)] = [:]
        for snapshot in snapshots {
            for day in snapshot.tokenActivityDays {
                let key = Calendar.current.startOfDay(for: day.day)
                guard let existing = merged[key] else {
                    merged[key] = (day, snapshot.updatedAt)
                    continue
                }
                if day.totalTokens > existing.day.totalTokens
                    || (day.totalTokens == existing.day.totalTokens
                        && snapshot.updatedAt > existing.snapshotUpdatedAt) {
                    merged[key] = (day, snapshot.updatedAt)
                }
            }
        }
        return merged.values.map(\.day).sorted { $0.day < $1.day }
    }

    private static func normalizedLegacySessionID(_ sessionID: String?) -> String {
        let normalized = sessionID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        return normalized.isEmpty ? "__unknown__" : normalized
    }

    private static func makeDeviceTokenSnapshot(
        tokenUsage: AgentTokenUsage?,
        tokenUsageSessionID: String?,
        tokenUsageUpdatedAt: Date?,
        liveTokenUsageScanBaseline: Int?,
        unscannedLiveTokenCarry: Int?,
        liveTokenCounters: [CodexLiveTokenCounterSnapshot]?,
        unscannedLiveTokenCarryByDay: [CodexLiveTokenCarrySnapshot]?,
        liveTokenUsageScanCutoff: Date?,
        liveTokenScanWatermarks: [CodexLiveTokenScanWatermarkSnapshot]?,
        legacyUnscopedTokenFloor: CodexLegacyUnscopedTokenFloorSnapshot?,
        tokenActivityCacheVersion: Int?,
        tokenActivityDays: [CodexTokenActivityDay],
        tokenActivityExcludedSessionCount: Int?,
        updatedAt: Date
    ) -> CodexDeviceTokenUsageSnapshot {
        CodexDeviceTokenUsageSnapshot(
            tokenUsage: tokenUsage,
            tokenUsageSessionID: tokenUsageSessionID,
            tokenUsageUpdatedAt: tokenUsageUpdatedAt,
            liveTokenUsageScanBaseline: liveTokenUsageScanBaseline,
            unscannedLiveTokenCarry: unscannedLiveTokenCarry,
            liveTokenCounters: liveTokenCounters,
            unscannedLiveTokenCarryByDay: unscannedLiveTokenCarryByDay,
            liveTokenUsageScanCutoff: liveTokenUsageScanCutoff,
            liveTokenScanWatermarks: liveTokenScanWatermarks,
            legacyUnscopedTokenFloor: legacyUnscopedTokenFloor,
            tokenActivityCacheVersion: tokenActivityCacheVersion,
            tokenActivityDays: tokenActivityDays,
            tokenActivityExcludedSessionCount: tokenActivityExcludedSessionCount,
            updatedAt: updatedAt
        )
    }

    private static func accountScopedQuota(_ quota: AgentQuotaStatus?) -> AgentQuotaStatus? {
        guard let quota else { return nil }
        return AgentQuotaStatus(
            remainingPercent: quota.remainingPercent,
            usedPercent: quota.usedPercent,
            limitID: quota.limitID,
            limitName: quota.limitName,
            accountScopeID: quota.accountScopeID,
            source: quota.source,
            windowMinutes: quota.windowMinutes,
            resetsAt: quota.resetsAt,
            updatedAt: quota.updatedAt,
            primary: quota.primary,
            secondary: quota.secondary,
            tokenUsage: nil
        )
    }

    private static func accountScopedSnapshot(
        _ snapshot: CodexAccountUsageSnapshot
    ) -> CodexAccountUsageSnapshot {
        CodexAccountUsageSnapshot(
            accountKey: snapshot.accountKey,
            email: snapshot.email,
            accountID: snapshot.accountID,
            authFingerprint: snapshot.authFingerprint,
            quota: accountScopedQuota(snapshot.quota),
            credits: snapshot.credits,
            resetCredits: snapshot.resetCredits,
            usageFetchState: snapshot.usageFetchState,
            resetCreditsFetchState: snapshot.resetCreditsFetchState,
            tokenUsage: nil,
            liveTokenUsageScanBaseline: nil,
            unscannedLiveTokenCarry: nil,
            liveTokenCounters: nil,
            unscannedLiveTokenCarryByDay: nil,
            liveTokenUsageScanCutoff: nil,
            liveTokenScanWatermarks: nil,
            legacyUnscopedTokenFloor: nil,
            tokenActivityCacheVersion: nil,
            tokenActivityDays: [],
            updatedAt: snapshot.updatedAt
        )
    }

    private static func defaultURL(fileManager: FileManager) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("AgentSignalLight", isDirectory: true)
            .appendingPathComponent("codex-account-usage-snapshots.json", isDirectory: false)
    }
}

private extension CodexAccountUsageSnapshot {
    func matches(_ account: CodexCurrentAccount) -> Bool {
        guard accountKey == account.usageSnapshotKey else { return false }

        if accountID != nil || account.normalizedUsageAccountID != nil {
            return accountID == account.normalizedUsageAccountID
        }
        if email != nil || account.normalizedUsageEmail != nil {
            return email == account.normalizedUsageEmail
        }
        return authFingerprint == account.authFingerprint
    }

    func matches(_ account: CodexAccountProfile) -> Bool {
        guard accountKey == account.usageSnapshotKey else { return false }

        if accountID != nil || account.normalizedUsageAccountID != nil {
            return accountID == account.normalizedUsageAccountID
        }
        if email != nil || account.normalizedUsageEmail != nil {
            return email == account.normalizedUsageEmail
        }
        return authFingerprint == account.authFingerprint
    }
}

extension CodexCurrentAccount {
    var usageSnapshotKey: String {
        if let accountID = normalizedUsageAccountID {
            return "account:\(accountID)"
        }
        if let email = normalizedUsageEmail {
            return "email:\(email)"
        }
        return "auth:\(authFingerprint)"
    }

    var normalizedUsageEmail: String? {
        CodexAccountUsageSnapshotStore.normalized(email)
    }

    var normalizedUsageAccountID: String? {
        CodexAccountUsageSnapshotStore.normalized(accountID)
    }
}

extension CodexAccountProfile {
    var usageSnapshotKey: String {
        if let accountID = normalizedUsageAccountID {
            return "account:\(accountID)"
        }
        if let email = normalizedUsageEmail {
            return "email:\(email)"
        }
        return "auth:\(authFingerprint)"
    }

    var normalizedUsageEmail: String? {
        CodexAccountUsageSnapshotStore.normalized(email)
    }

    var normalizedUsageAccountID: String? {
        CodexAccountUsageSnapshotStore.normalized(accountID)
    }
}

private extension CodexAccountUsageSnapshotStore {
    static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }
}

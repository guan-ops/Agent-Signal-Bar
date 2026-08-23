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

final class CodexAccountUsageSnapshotStore: @unchecked Sendable {
    private struct StoreDocument: Codable {
        var version: Int
        var snapshots: [CodexAccountUsageSnapshot]
    }

    private static let currentVersion = 1

    private let fileURL: URL
    private let fileManager: FileManager

    init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.fileURL = fileURL ?? Self.defaultURL(fileManager: fileManager)
    }

    func snapshot(for account: CodexCurrentAccount) -> CodexAccountUsageSnapshot? {
        loadSnapshots().first { $0.matches(account) }
    }

    func store(
        account: CodexCurrentAccount,
        quota: AgentQuotaStatus?,
        credits: CodexCreditStatus?,
        resetCredits: CodexRateLimitResetCreditsSnapshot? = nil,
        usageFetchState: CodexUsageFetchState? = nil,
        resetCreditsFetchState: CodexResetCreditsFetchState? = nil,
        tokenUsage: AgentTokenUsage?,
        liveTokenUsageScanBaseline: Int? = nil,
        unscannedLiveTokenCarry: Int? = nil,
        liveTokenCounters: [CodexLiveTokenCounterSnapshot]? = nil,
        unscannedLiveTokenCarryByDay: [CodexLiveTokenCarrySnapshot]? = nil,
        liveTokenUsageScanCutoff: Date? = nil,
        liveTokenScanWatermarks: [CodexLiveTokenScanWatermarkSnapshot]? = nil,
        legacyUnscopedTokenFloor: CodexLegacyUnscopedTokenFloorSnapshot? = nil,
        tokenActivityCacheVersion: Int?,
        tokenActivityDays: [CodexTokenActivityDay],
        updatedAt: Date = Date()
    ) {
        var snapshots = loadSnapshots()
        let snapshot = CodexAccountUsageSnapshot(
            accountKey: account.usageSnapshotKey,
            email: account.normalizedUsageEmail,
            accountID: account.normalizedUsageAccountID,
            authFingerprint: account.authFingerprint,
            quota: quota,
            credits: credits,
            resetCredits: resetCredits,
            usageFetchState: usageFetchState,
            resetCreditsFetchState: resetCreditsFetchState,
            tokenUsage: tokenUsage,
            liveTokenUsageScanBaseline: liveTokenUsageScanBaseline,
            unscannedLiveTokenCarry: unscannedLiveTokenCarry,
            liveTokenCounters: liveTokenCounters,
            unscannedLiveTokenCarryByDay: unscannedLiveTokenCarryByDay,
            liveTokenUsageScanCutoff: liveTokenUsageScanCutoff,
            liveTokenScanWatermarks: liveTokenScanWatermarks,
            legacyUnscopedTokenFloor: legacyUnscopedTokenFloor,
            tokenActivityCacheVersion: tokenActivityCacheVersion,
            tokenActivityDays: tokenActivityDays,
            updatedAt: updatedAt
        )

        if let index = snapshots.firstIndex(where: { $0.matches(account) }) {
            snapshots[index] = snapshot
        } else {
            snapshots.append(snapshot)
        }
        storeSnapshots(snapshots)
    }

    func remove(for account: CodexAccountProfile) {
        let snapshots = loadSnapshots().filter { !$0.matches(account) }
        storeSnapshots(snapshots)
    }

    func removeAll() {
        try? fileManager.removeItem(at: fileURL)
    }

    private func loadSnapshots() -> [CodexAccountUsageSnapshot] {
        guard fileManager.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let document = try? JSONDecoder().decode(StoreDocument.self, from: data),
              document.version == Self.currentVersion
        else {
            return []
        }
        return document.snapshots
    }

    private func storeSnapshots(_ snapshots: [CodexAccountUsageSnapshot]) {
        let document = StoreDocument(version: Self.currentVersion, snapshots: snapshots)
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

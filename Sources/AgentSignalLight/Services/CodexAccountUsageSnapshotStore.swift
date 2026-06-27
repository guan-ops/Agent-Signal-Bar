import AgentSignalLightCore
import Foundation

struct CodexAccountUsageSnapshot: Codable, Equatable, Sendable {
    let accountKey: String
    let email: String?
    let accountID: String?
    let authFingerprint: String?
    var quota: AgentQuotaStatus?
    var credits: CodexCreditStatus?
    var tokenUsage: AgentTokenUsage?
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
        tokenUsage: AgentTokenUsage?,
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
            tokenUsage: tokenUsage,
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

import CryptoKit
import Darwin
import Foundation

struct CodexAccountProfile: Codable, Equatable, Identifiable, Sendable {
    enum CredentialKind: String, Codable, Sendable {
        case oauth
        case apiKey
        case unknown
    }

    let id: UUID
    var label: String
    var email: String?
    var accountID: String?
    var credentialKind: CredentialKind
    var planName: String?
    var authFingerprint: String
    var credentialReference: String?
    var authDataBase64: String?
    var managedHomePath: String?
    var createdAt: Date
    var updatedAt: Date

    var legacyAuthData: Data? {
        authDataBase64.flatMap { Data(base64Encoded: $0) }
    }

    var displayName: String {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedLabel.isEmpty { return trimmedLabel }
        if let email, !email.isEmpty { return email }
        if let accountID, !accountID.isEmpty {
            return "Codex \(Self.compactAccountID(accountID))"
        }
        return credentialKind == .apiKey ? "OpenAI API Key" : "Codex Account"
    }

    var detailText: String {
        if let email, !email.isEmpty {
            return email
        }
        if let accountID, !accountID.isEmpty {
            return Self.compactAccountID(accountID)
        }
        switch credentialKind {
        case .oauth:
            return "OAuth"
        case .apiKey:
            return "API Key"
        case .unknown:
            return "Unknown"
        }
    }

    static func compactAccountID(_ accountID: String) -> String {
        let trimmed = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 10 else { return trimmed }
        return "\(trimmed.prefix(6))...\(trimmed.suffix(4))"
    }
}

struct CodexCurrentAccount: Equatable, Sendable {
    let email: String?
    let accountID: String?
    let credentialKind: CodexAccountProfile.CredentialKind
    let planName: String?
    let authFingerprint: String
    let authFileURL: URL

    var displayName: String {
        if let email, !email.isEmpty { return email }
        if let accountID, !accountID.isEmpty {
            return "Codex \(CodexAccountProfile.compactAccountID(accountID))"
        }
        return credentialKind == .apiKey ? "OpenAI API Key" : "Codex Account"
    }

    var detailText: String {
        let source = authFileURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        switch credentialKind {
        case .oauth:
            return "OAuth - \(source)"
        case .apiKey:
            return "API Key - \(source)"
        case .unknown:
            return source
        }
    }
}

struct CodexAccountState: Equatable, Sendable {
    var currentAccount: CodexCurrentAccount?
    var savedAccounts: [CodexAccountProfile]
    var activeSavedAccountID: UUID?
}

enum CodexAccountManagerError: LocalizedError, Equatable {
    case missingAuthFile(String)
    case unreadableAuthFile(String)
    case invalidAuthFile(String)
    case accountNotFound
    case emptyStoredAuth
    case writeFailed(String)
    case missingCodexBinary
    case codexLoginTimedOut
    case codexLoginFailed(Int32, String)
    case codexLoginLaunchFailed(String)
    case missingManagedAuth(String)
    case missingStoredCredential
    case keychainFailure(String)

    var errorDescription: String? {
        switch self {
        case let .missingAuthFile(path):
            return "Codex auth file was not found at \(path)."
        case let .unreadableAuthFile(path):
            return "Codex auth file could not be read at \(path)."
        case let .invalidAuthFile(path):
            return "Codex auth file is not valid JSON at \(path)."
        case .accountNotFound:
            return "Saved Codex account was not found."
        case .emptyStoredAuth:
            return "Saved Codex account has no auth data."
        case let .writeFailed(path):
            return "Could not write Codex auth file at \(path)."
        case .missingCodexBinary:
            return "Could not find the codex command. Install Codex CLI, then try adding the account again."
        case .codexLoginTimedOut:
            return "Codex login timed out. Try adding the account again."
        case let .codexLoginFailed(status, output):
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "codex login exited with status \(status)."
            }
            return "codex login exited with status \(status): \(trimmed)"
        case let .codexLoginLaunchFailed(message):
            return "Could not start codex login: \(message)"
        case let .missingManagedAuth(path):
            return "Codex login finished, but no auth.json was found at \(path)."
        case .missingStoredCredential:
            return "Saved Codex account credentials were not found in Keychain."
        case let .keychainFailure(message):
            return "Could not access saved Codex account credentials: \(message)"
        }
    }
}

struct CodexAccountLoginResult: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        case success
        case timedOut
        case failed(status: Int32)
        case missingBinary
        case launchFailed(String)
    }

    let outcome: Outcome
    let output: String
}

protocol CodexAccountLoginRunning: Sendable {
    func run(homePath: String, timeout: TimeInterval, environment: [String: String]) async -> CodexAccountLoginResult
}

final class CodexAccountManager: @unchecked Sendable {
    private struct StoreDocument: Codable {
        var version: Int
        var accounts: [CodexAccountProfile]
    }

    private struct ParsedAuthIdentity {
        var email: String?
        var accountID: String?
        var credentialKind: CodexAccountProfile.CredentialKind
        var planName: String?

        var suggestedLabel: String {
            if let email, !email.isEmpty { return email }
            if let accountID, !accountID.isEmpty {
                return "Codex \(CodexAccountProfile.compactAccountID(accountID))"
            }
            return credentialKind == .apiKey ? "OpenAI API Key" : "Codex Account"
        }
    }

    private static let currentStoreVersion = 1

    private let environment: [String: String]
    private let fileManager: FileManager
    private let storeURL: URL
    private let managedHomeRootURL: URL
    private let loginRunner: any CodexAccountLoginRunning
    private let credentialStore: any SecretStoring

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        storeURL: URL? = nil,
        managedHomeRootURL: URL? = nil,
        loginRunner: any CodexAccountLoginRunning = CodexAccountLoginRunner(),
        credentialStore: (any SecretStoring)? = nil
    ) {
        self.environment = environment
        self.fileManager = fileManager
        let resolvedStoreURL = storeURL ?? Self.defaultStoreURL(fileManager: fileManager)
        self.storeURL = resolvedStoreURL
        self.managedHomeRootURL = managedHomeRootURL ?? Self.defaultManagedHomeRootURL(fileManager: fileManager)
        self.loginRunner = loginRunner
        self.credentialStore = credentialStore ?? Self.defaultCredentialStore(
            explicitStoreURL: storeURL,
            resolvedStoreURL: resolvedStoreURL,
            fileManager: fileManager
        )
    }

    func loadState() throws -> CodexAccountState {
        let accounts = try loadAccounts()
        let current = try? currentAccount()
        return CodexAccountState(
            currentAccount: current,
            savedAccounts: accounts,
            activeSavedAccountID: current.flatMap { activeAccountID(for: $0, in: accounts) }
        )
    }

    func currentAccount() throws -> CodexCurrentAccount {
        let url = authFileURL()
        guard fileManager.fileExists(atPath: url.path) else {
            throw CodexAccountManagerError.missingAuthFile(url.path)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw CodexAccountManagerError.unreadableAuthFile(url.path)
        }
        let identity = try parseAuthIdentity(data: data, authFileURL: url)
        return CodexCurrentAccount(
            email: identity.email,
            accountID: identity.accountID,
            credentialKind: identity.credentialKind,
            planName: identity.planName,
            authFingerprint: Self.fingerprint(data),
            authFileURL: url
        )
    }

    func saveCurrentAccount(label requestedLabel: String? = nil) throws -> CodexAccountProfile {
        let url = authFileURL()
        guard fileManager.fileExists(atPath: url.path) else {
            throw CodexAccountManagerError.missingAuthFile(url.path)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw CodexAccountManagerError.unreadableAuthFile(url.path)
        }
        let identity = try parseAuthIdentity(data: data, authFileURL: url)
        let fingerprint = Self.fingerprint(data)
        let now = Date()
        var accounts = try loadAccounts()
        let requestedLabel = requestedLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = (requestedLabel?.isEmpty == false) ? requestedLabel! : identity.suggestedLabel

        if let index = matchingAccountIndex(
            identity: identity,
            fingerprint: fingerprint,
            in: accounts
        ) {
            let existing = accounts[index]
            let credentialReference = existing.credentialReference ?? Self.credentialReference(for: existing.id)
            accounts[index] = CodexAccountProfile(
                id: existing.id,
                label: (requestedLabel?.isEmpty == false) ? label : existing.displayName,
                email: identity.email,
                accountID: identity.accountID,
                credentialKind: identity.credentialKind,
                planName: identity.planName,
                authFingerprint: fingerprint,
                credentialReference: credentialReference,
                authDataBase64: nil,
                managedHomePath: nil,
                createdAt: existing.createdAt,
                updatedAt: now
            )
            try storeAuthData(data, reference: credentialReference)
            if let managedHomeURL = managedHomeURL(for: existing) {
                try? removeManagedHomeIfSafe(at: managedHomeURL)
            }
            try storeAccounts(accounts)
            return accounts[index]
        }

        let id = UUID()
        let credentialReference = Self.credentialReference(for: id)
        let account = CodexAccountProfile(
            id: id,
            label: uniqueLabel(label, existingAccounts: accounts),
            email: identity.email,
            accountID: identity.accountID,
            credentialKind: identity.credentialKind,
            planName: identity.planName,
            authFingerprint: fingerprint,
            credentialReference: credentialReference,
            authDataBase64: nil,
            managedHomePath: nil,
            createdAt: now,
            updatedAt: now
        )
        try storeAuthData(data, reference: credentialReference)
        accounts.append(account)
        try storeAccounts(accounts)
        return account
    }

    func switchToAccount(id: UUID) throws -> CodexAccountProfile {
        let stateBeforeSwitch = try loadState()
        if stateBeforeSwitch.currentAccount != nil,
           stateBeforeSwitch.activeSavedAccountID != id {
            _ = try saveCurrentAccount()
        }

        let accounts = try loadAccounts()
        guard let account = accounts.first(where: { $0.id == id }) else {
            throw CodexAccountManagerError.accountNotFound
        }
        let data = try storedAuthData(for: account)
        guard !data.isEmpty else {
            throw CodexAccountManagerError.emptyStoredAuth
        }
        try writeActiveAuthData(data)
        return account
    }

    func authenticateManagedAccount(timeout: TimeInterval = 120) async throws -> CodexAccountProfile {
        let homeURL = makeManagedHomeURL()
        try fileManager.createDirectory(at: homeURL, withIntermediateDirectories: true)
        try? fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: homeURL.path
        )

        let result = await loginRunner.run(
            homePath: homeURL.path,
            timeout: timeout,
            environment: environment
        )
        guard case .success = result.outcome else {
            try? removeManagedHomeIfSafe(at: homeURL)
            throw error(from: result)
        }

        let authURL = homeURL.appendingPathComponent("auth.json", isDirectory: false)
        guard fileManager.fileExists(atPath: authURL.path) else {
            try? removeManagedHomeIfSafe(at: homeURL)
            throw CodexAccountManagerError.missingManagedAuth(authURL.path)
        }

        let data: Data
        do {
            data = try Data(contentsOf: authURL)
        } catch {
            try? removeManagedHomeIfSafe(at: homeURL)
            throw CodexAccountManagerError.unreadableAuthFile(authURL.path)
        }

        let identity = try parseAuthIdentity(data: data, authFileURL: authURL)
        let fingerprint = Self.fingerprint(data)
        let now = Date()
        var accounts = try loadAccounts()
        let label = uniqueLabel(identity.suggestedLabel, existingAccounts: accounts)
        let existingIndex = matchingAccountIndex(
            identity: identity,
            fingerprint: fingerprint,
            in: accounts
        )
        let existing = existingIndex.map { accounts[$0] }
        let existingManagedHomeToRemove = existing?.managedHomePath.flatMap(URL.init(fileURLWithPath:))
        let id = existing?.id ?? UUID()
        let credentialReference = existing?.credentialReference ?? Self.credentialReference(for: id)

        let account = CodexAccountProfile(
            id: id,
            label: existing?.displayName ?? label,
            email: identity.email,
            accountID: identity.accountID,
            credentialKind: identity.credentialKind,
            planName: identity.planName,
            authFingerprint: fingerprint,
            credentialReference: credentialReference,
            authDataBase64: nil,
            managedHomePath: nil,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now
        )
        try storeAuthData(data, reference: credentialReference)

        if let existingIndex {
            accounts[existingIndex] = account
        } else {
            accounts.append(account)
        }
        try storeAccounts(accounts)

        try? removeManagedHomeIfSafe(at: homeURL)
        if let existingManagedHomeToRemove {
            try? removeManagedHomeIfSafe(at: existingManagedHomeToRemove)
        }

        return account
    }

    func removeAccount(id: UUID) throws {
        let accounts = try loadAccounts()
        let removedAccounts = accounts.filter { $0.id == id }
        let filtered = accounts.filter { $0.id != id }
        guard filtered.count != accounts.count else { return }
        try storeAccounts(filtered)
        for account in removedAccounts {
            try? deleteStoredAuthData(for: account)
            if let managedHomeURL = managedHomeURL(for: account) {
                try? removeManagedHomeIfSafe(at: managedHomeURL)
            }
        }
    }

    func refreshSavedCurrentAccountIfPossible() throws -> CodexAccountProfile? {
        let state = try loadState()
        guard state.activeSavedAccountID != nil else {
            return nil
        }
        return try saveCurrentAccount()
    }

    private func loadAccounts() throws -> [CodexAccountProfile] {
        guard fileManager.fileExists(atPath: storeURL.path) else { return [] }
        let data = try Data(contentsOf: storeURL)
        let document = try JSONDecoder().decode(StoreDocument.self, from: data)
        guard document.version <= Self.currentStoreVersion else { return [] }
        return try migrateAccountsIfNeeded(document.accounts)
    }

    private func migrateAccountsIfNeeded(_ loadedAccounts: [CodexAccountProfile]) throws -> [CodexAccountProfile] {
        var didMigrate = false
        var accounts: [CodexAccountProfile] = []

        for var account in loadedAccounts {
            let reference = account.credentialReference ?? Self.credentialReference(for: account.id)
            var dataToStore: Data?

            if try keychainAuthData(reference: reference) == nil {
                if let legacyData = account.legacyAuthData, !legacyData.isEmpty {
                    dataToStore = legacyData
                } else if let managedHomeURL = managedHomeURL(for: account) {
                    let authURL = managedHomeURL.appendingPathComponent("auth.json", isDirectory: false)
                    if fileManager.fileExists(atPath: authURL.path),
                       let managedData = try? Data(contentsOf: authURL),
                       !managedData.isEmpty {
                        dataToStore = managedData
                    }
                }
            }

            if let dataToStore {
                try storeAuthData(dataToStore, reference: reference)
                didMigrate = true
            }

            if account.credentialReference != reference
                || account.authDataBase64 != nil
                || account.managedHomePath != nil {
                if let managedHomeURL = managedHomeURL(for: account) {
                    try? removeManagedHomeIfSafe(at: managedHomeURL)
                }
                account.credentialReference = reference
                account.authDataBase64 = nil
                account.managedHomePath = nil
                didMigrate = true
            }

            accounts.append(account)
        }

        if didMigrate {
            try storeAccounts(accounts)
        }
        return accounts
    }

    private func storedAuthData(for account: CodexAccountProfile) throws -> Data {
        if let reference = account.credentialReference,
           let data = try keychainAuthData(reference: reference),
           !data.isEmpty {
            return data
        }
        if let legacyData = account.legacyAuthData, !legacyData.isEmpty {
            return legacyData
        }
        throw CodexAccountManagerError.missingStoredCredential
    }

    private func keychainAuthData(reference: String) throws -> Data? {
        do {
            return try credentialStore.data(for: reference)
        } catch {
            throw CodexAccountManagerError.keychainFailure(error.localizedDescription)
        }
    }

    private func storeAuthData(_ data: Data, reference: String) throws {
        do {
            try credentialStore.set(data, for: reference)
        } catch {
            throw CodexAccountManagerError.keychainFailure(error.localizedDescription)
        }
    }

    private func deleteStoredAuthData(for account: CodexAccountProfile) throws {
        let reference = account.credentialReference ?? Self.credentialReference(for: account.id)
        do {
            try credentialStore.delete(key: reference)
        } catch {
            throw CodexAccountManagerError.keychainFailure(error.localizedDescription)
        }
    }

    private func storeAccounts(_ accounts: [CodexAccountProfile]) throws {
        let document = StoreDocument(
            version: Self.currentStoreVersion,
            accounts: accounts.sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        let directory = storeURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: storeURL, options: .atomic)
        try? fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: storeURL.path
        )
    }

    private func activeAccountID(
        for current: CodexCurrentAccount,
        in accounts: [CodexAccountProfile]
    ) -> UUID? {
        let identity = ParsedAuthIdentity(
            email: current.email,
            accountID: current.accountID,
            credentialKind: current.credentialKind,
            planName: current.planName
        )
        return matchingAccountIndex(
            identity: identity,
            fingerprint: current.authFingerprint,
            in: accounts
        ).map { accounts[$0].id }
    }

    private func matchingAccountIndex(
        identity: ParsedAuthIdentity,
        fingerprint: String,
        in accounts: [CodexAccountProfile]
    ) -> Int? {
        if let accountID = normalize(identity.accountID) {
            return accounts.firstIndex(where: { normalize($0.accountID) == accountID })
        }
        if let email = normalize(identity.email),
           let index = accounts.firstIndex(where: {
               normalize($0.email) == email
                   && normalize($0.accountID) == nil
                   && $0.credentialKind == identity.credentialKind
           }) {
            return index
        }
        return accounts.firstIndex { $0.authFingerprint == fingerprint }
    }

    private func uniqueLabel(
        _ baseLabel: String,
        existingAccounts: [CodexAccountProfile]
    ) -> String {
        let trimmed = baseLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "Codex Account" : trimmed
        let existing = Set(existingAccounts.map { $0.displayName.lowercased() })
        guard existing.contains(base.lowercased()) else { return base }

        var index = 2
        while existing.contains("\(base) \(index)".lowercased()) {
            index += 1
        }
        return "\(base) \(index)"
    }

    private func writeActiveAuthData(_ data: Data) throws {
        let url = authFileURL()
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let stagedURL = directory.appendingPathComponent(
            "auth.json.agent-signal-staged-\(UUID().uuidString)",
            isDirectory: false
        )

        do {
            try data.write(to: stagedURL)
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: stagedURL.path
            )
            let result = stagedURL.path.withCString { sourcePath in
                url.path.withCString { destinationPath in
                    rename(sourcePath, destinationPath)
                }
            }
            guard result == 0 else {
                throw CodexAccountManagerError.writeFailed(url.path)
            }
        } catch let error as CodexAccountManagerError {
            try? fileManager.removeItem(at: stagedURL)
            throw error
        } catch {
            try? fileManager.removeItem(at: stagedURL)
            throw CodexAccountManagerError.writeFailed(url.path)
        }
    }

    private func makeManagedHomeURL() -> URL {
        managedHomeRootURL
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func managedHomeURL(for account: CodexAccountProfile) -> URL? {
        guard let managedHomePath = account.managedHomePath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !managedHomePath.isEmpty
        else {
            return nil
        }
        return URL(fileURLWithPath: (managedHomePath as NSString).expandingTildeInPath, isDirectory: true)
    }

    private func removeManagedHomeIfSafe(at url: URL) throws {
        let standardizedRoot = managedHomeRootURL.standardizedFileURL.path
        let standardizedPath = url.standardizedFileURL.path
        let rootPrefix = standardizedRoot.hasSuffix("/") ? standardizedRoot : "\(standardizedRoot)/"
        guard standardizedPath.hasPrefix(rootPrefix),
              standardizedPath != standardizedRoot
        else {
            return
        }
        if fileManager.fileExists(atPath: standardizedPath) {
            try fileManager.removeItem(at: url)
        }
    }

    private func error(from result: CodexAccountLoginResult) -> CodexAccountManagerError {
        switch result.outcome {
        case .success:
            return .missingManagedAuth(makeManagedHomeURL().appendingPathComponent("auth.json").path)
        case .timedOut:
            return .codexLoginTimedOut
        case let .failed(status):
            return .codexLoginFailed(status, result.output)
        case .missingBinary:
            return .missingCodexBinary
        case let .launchFailed(message):
            return .codexLoginLaunchFailed(message)
        }
    }

    private func authFileURL() -> URL {
        if let codexHome = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !codexHome.isEmpty {
            return URL(fileURLWithPath: (codexHome as NSString).expandingTildeInPath)
                .appendingPathComponent("auth.json", isDirectory: false)
        }

        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("auth.json", isDirectory: false)
    }

    private func parseAuthIdentity(data: Data, authFileURL: URL) throws -> ParsedAuthIdentity {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexAccountManagerError.invalidAuthFile(authFileURL.path)
        }

        if let apiKey = json["OPENAI_API_KEY"] as? String,
           !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ParsedAuthIdentity(
                email: nil,
                accountID: nil,
                credentialKind: .apiKey,
                planName: nil
            )
        }

        let tokens = json["tokens"] as? [String: Any] ?? [:]
        let idToken = stringValue(in: tokens, keys: ["id_token", "idToken"])
        let payload = idToken.flatMap(Self.jwtPayload)
        let authPayload = payload?["https://api.openai.com/auth"] as? [String: Any]
        let email = firstString([
            payload?["email"],
            payload?["preferred_username"],
            authPayload?["email"]
        ])
        let accountID = firstString([
            stringValue(in: tokens, keys: ["account_id", "accountId"]),
            json["account_id"],
            json["accountId"],
            authPayload?["chatgpt_account_id"],
            payload?["chatgpt_account_id"]
        ])
        let planName = firstString([
            authPayload?["plan"],
            authPayload?["plan_name"],
            authPayload?["plan_type"],
            authPayload?["chatgpt_plan"],
            authPayload?["chatgpt_plan_name"],
            authPayload?["chatgpt_plan_type"],
            payload?["plan"],
            payload?["plan_name"],
            payload?["plan_type"],
            payload?["chatgpt_plan"],
            payload?["chatgpt_plan_name"],
            payload?["chatgpt_plan_type"],
            json["plan"],
            json["plan_name"],
            json["plan_type"]
        ])

        let hasOAuthTokens = stringValue(in: tokens, keys: ["access_token", "accessToken"]) != nil
        return ParsedAuthIdentity(
            email: normalize(email),
            accountID: normalize(accountID),
            credentialKind: hasOAuthTokens ? .oauth : .unknown,
            planName: normalize(planName)
        )
    }

    private func stringValue(in dictionary: [String: Any], keys: [String]) -> String? {
        firstString(keys.map { dictionary[$0] })
    }

    private func firstString(_ values: [Any?]) -> String? {
        for value in values {
            if let string = value as? String,
               let normalized = normalize(string) {
                return normalized
            }
        }
        return nil
    }

    private func normalize(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }
        return trimmed
    }

    private static func jwtPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = payload.count % 4
        if padding > 0 {
            payload += String(repeating: "=", count: 4 - padding)
        }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return json
    }

    private static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func credentialReference(for id: UUID) -> String {
        "codex-account.\(id.uuidString)"
    }

    private static func defaultCredentialStore(
        explicitStoreURL: URL?,
        resolvedStoreURL: URL,
        fileManager: FileManager
    ) -> any SecretStoring {
        if explicitStoreURL != nil {
            return FileSecretStore(
                rootURL: resolvedStoreURL
                    .deletingLastPathComponent()
                    .appendingPathComponent("codex-account-credentials", isDirectory: true),
                fileManager: fileManager
            )
        }
        return KeychainSecretStore(service: "com.agentsignallight.codex-accounts")
    }

    private static func defaultStoreURL(fileManager: FileManager) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("AgentSignalLight", isDirectory: true)
            .appendingPathComponent("codex-accounts.json", isDirectory: false)
    }

    private static func defaultManagedHomeRootURL(fileManager: FileManager) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("AgentSignalLight", isDirectory: true)
            .appendingPathComponent("managed-codex-homes", isDirectory: true)
    }
}

struct CodexAccountLoginRunner: CodexAccountLoginRunning {
    func run(
        homePath: String,
        timeout: TimeInterval,
        environment: [String: String]
    ) async -> CodexAccountLoginResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.runSynchronously(
                    homePath: homePath,
                    timeout: timeout,
                    environment: environment
                ))
            }
        }
    }

    private static func runSynchronously(
        homePath: String,
        timeout: TimeInterval,
        environment: [String: String]
    ) -> CodexAccountLoginResult {
        var scopedEnvironment = environment
        scopedEnvironment["CODEX_HOME"] = homePath
        scopedEnvironment["PATH"] = effectivePATH(from: environment)

        guard let executable = resolveCodexExecutable(environment: scopedEnvironment) else {
            return CodexAccountLoginResult(outcome: .missingBinary, output: "")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable, "login"]
        process.environment = scopedEnvironment

        let stdoutURL = temporaryCaptureURL(suffix: "out")
        let stderrURL = temporaryCaptureURL(suffix: "err")
        do {
            try Data().write(to: stdoutURL)
            try Data().write(to: stderrURL)
            let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
            let stderrHandle = try FileHandle(forWritingTo: stderrURL)
            defer {
                try? stdoutHandle.close()
                try? stderrHandle.close()
                try? FileManager.default.removeItem(at: stdoutURL)
                try? FileManager.default.removeItem(at: stderrURL)
            }
            process.standardOutput = stdoutHandle
            process.standardError = stderrHandle

            do {
                try process.run()
            } catch {
                return CodexAccountLoginResult(
                    outcome: .launchFailed(error.localizedDescription),
                    output: ""
                )
            }

            let timedOut = waitForProcess(process, timeout: timeout)
            let output = combinedOutput(stdoutURL: stdoutURL, stderrURL: stderrURL)
            if timedOut {
                return CodexAccountLoginResult(outcome: .timedOut, output: output)
            }
            if process.terminationStatus == 0 {
                return CodexAccountLoginResult(outcome: .success, output: output)
            }
            return CodexAccountLoginResult(
                outcome: .failed(status: process.terminationStatus),
                output: output
            )
        } catch {
            return CodexAccountLoginResult(
                outcome: .launchFailed(error.localizedDescription),
                output: ""
            )
        }
    }

    private static func waitForProcess(_ process: Process, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard process.isRunning else { return false }
        process.terminate()
        process.waitUntilExit()
        return true
    }

    private static func combinedOutput(stdoutURL: URL, stderrURL: URL) -> String {
        let stdout = String(
            data: (try? Data(contentsOf: stdoutURL)) ?? Data(),
            encoding: .utf8
        ) ?? ""
        let stderr = String(
            data: (try? Data(contentsOf: stderrURL)) ?? Data(),
            encoding: .utf8
        ) ?? ""
        return [stdout, stderr]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private static func temporaryCaptureURL(suffix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-signal-codex-login-\(UUID().uuidString).\(suffix)")
    }

    private static func effectivePATH(from environment: [String: String]) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            environment["PATH"],
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.local/bin",
            "\(home)/.npm-global/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        var seen = Set<String>()
        return candidates
            .flatMap { ($0 ?? "").split(separator: ":").map(String.init) }
            .filter { path in
                let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !seen.contains(trimmed) else { return false }
                seen.insert(trimmed)
                return true
            }
            .joined(separator: ":")
    }

    private static func resolveCodexExecutable(environment: [String: String]) -> String? {
        if let explicit = environment["CODEX_BINARY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty,
           FileManager.default.isExecutableFile(atPath: explicit) {
            return explicit
        }

        let pathValue = environment["PATH"] ?? ""
        for directory in pathValue.split(separator: ":").map(String.init) {
            let executable = URL(fileURLWithPath: directory)
                .appendingPathComponent("codex", isDirectory: false)
                .path
            if FileManager.default.isExecutableFile(atPath: executable) {
                return executable
            }
        }

        return nil
    }
}

import Foundation
import XCTest
@testable import AgentSignalLight
@testable import AgentSignalLightCore

@MainActor
final class QuotaIdentityPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_788_400_000)
    private let savedAccountID = UUID()

    func testConfirmedOAuthQuotaOmitsWarningWithoutInventingLimitIdentity() throws {
        let fixture = try makeFixture(fetchState: successfulFetchState())
        defer { fixture.cleanUp() }
        let quota = try XCTUnwrap(fixture.model.latestAgentQuota)

        let presentation = fixture.model.codexQuotaIdentityPresentation(for: quota)
        XCTAssertEqual(presentation.title, "Codex 配额")
        XCTAssertEqual(presentation.context, "quota-fixture@example.invalid · Codex OAuth")
        XCTAssertFalse(presentation.hasKnownLimitIdentity)
        XCTAssertNil(presentation.limitID)
        XCTAssertNil(quota.limitID)
        XCTAssertNil(quota.limitName)
        XCTAssertEqual(quota.accountScopeID, savedAccountID)
        XCTAssertEqual(quota.remainingPercent, 67)

        fixture.model.setAppLanguage(.english)
        let english = fixture.model.codexQuotaIdentityPresentation(for: quota)
        XCTAssertEqual(english.title, "Codex quota")
        XCTAssertEqual(english.context, "quota-fixture@example.invalid · Codex OAuth")
        XCTAssertFalse(english.hasKnownLimitIdentity)
        XCTAssertEqual(fixture.model.latestAgentQuota, quota)
    }

    func testStaleOAuthQuotaRetainsUnknownScopeWarning() throws {
        var state = successfulFetchState()
        state.isStale = true
        let fixture = try makeFixture(fetchState: state)
        defer { fixture.cleanUp() }

        assertUnknownScope(try XCTUnwrap(fixture.model.latestAgentQuota), in: fixture.model)
        XCTAssertEqual(fixture.model.codexUsageFetchState?.isStale, true)
    }

    func testFailedOAuthRefreshRetainsWarningAndError() throws {
        var state = successfulFetchState()
        state.errorMessage = "fixture refresh failed"
        let fixture = try makeFixture(fetchState: state)
        defer { fixture.cleanUp() }

        assertUnknownScope(try XCTUnwrap(fixture.model.latestAgentQuota), in: fixture.model)
        XCTAssertEqual(fixture.model.codexUsageFetchState?.errorMessage, "fixture refresh failed")
    }

    func testMissingOrNonmatchingSuccessfulOAuthFetchRetainsWarning() throws {
        var noSuccess = successfulFetchState()
        noSuccess.lastSuccessfulAt = nil
        var differentSnapshot = successfulFetchState()
        differentSnapshot.lastSuccessfulAt = now.addingTimeInterval(-1)
        var otherSource = successfulFetchState()
        otherSource.source = .manualCookie

        for state in [nil, noSuccess, differentSnapshot, otherSource] as [CodexUsageFetchState?] {
            let fixture = try makeFixture(fetchState: state)
            defer { fixture.cleanUp() }
            assertUnknownScope(try XCTUnwrap(fixture.model.latestAgentQuota), in: fixture.model)
        }
    }

    func testMismatchedAccountAndNoncurrentQuotaRetainWarning() throws {
        let fixture = try makeFixture(fetchState: successfulFetchState())
        defer { fixture.cleanUp() }
        let current = try XCTUnwrap(fixture.model.latestAgentQuota)
        let differentAccount = current.attributed(to: UUID(), source: .oauth)
        assertUnknownScope(differentAccount, in: fixture.model)
        XCTAssertTrue(fixture.model.codexQuotaIdentityPresentation(for: differentAccount)
            .context.contains("已保存账户"))

        let differentSnapshot = quota(updatedAt: now.addingTimeInterval(-1))
        assertUnknownScope(differentSnapshot, in: fixture.model)
        XCTAssertEqual(fixture.model.latestAgentQuota, current)
    }

    func testUnverifiedSavedAccountOrCredentialsRetainWarning() throws {
        let missingSavedAccount = try makeFixture(
            fetchState: successfulFetchState(), hasSavedAccount: false
        )
        defer { missingSavedAccount.cleanUp() }
        assertUnknownScope(
            try XCTUnwrap(missingSavedAccount.model.latestAgentQuota), in: missingSavedAccount.model
        )

        let unknownCredentials = try makeFixture(
            fetchState: successfulFetchState(), credentialKind: .unknown
        )
        defer { unknownCredentials.cleanUp() }
        assertUnknownScope(
            try XCTUnwrap(unknownCredentials.model.latestAgentQuota), in: unknownCredentials.model
        )

        let noActiveAccount = try makeFixture(
            fetchState: successfulFetchState(), hasActiveSavedAccount: false
        )
        defer { noActiveAccount.cleanUp() }
        let unverified = try XCTUnwrap(noActiveAccount.model.latestAgentQuota)
        assertUnknownScope(unverified, in: noActiveAccount.model)
        XCTAssertTrue(noActiveAccount.model.codexQuotaIdentityPresentation(for: unverified)
            .context.contains("账户未验证"))
    }

    func testLocalSessionObservationRetainsUnknownScopeAndUnverifiedAccount() throws {
        let fixture = try makeFixture(fetchState: successfulFetchState())
        defer { fixture.cleanUp() }
        let local = quota(source: .desktopSession).attributed(to: nil)

        let presentation = fixture.model.codexQuotaIdentityPresentation(for: local)
        XCTAssertEqual(presentation.title, "Codex 配额")
        XCTAssertEqual(presentation.context, "额度范围未知 · 账户未验证 · 本地会话")
        XCTAssertFalse(presentation.hasKnownLimitIdentity)

        fixture.model.setAppLanguage(.english)
        XCTAssertEqual(
            fixture.model.codexQuotaIdentityPresentation(for: local).context,
            "Scope unavailable · Account unverified · Local session"
        )
    }

    func testKnownModelQuotaKeepsItsNameAndIdentifier() throws {
        let fixture = try makeFixture(
            authoritativeQuota: quota(limitID: "fixture-model", limitName: "Fixture Model"),
            fetchState: successfulFetchState()
        )
        defer { fixture.cleanUp() }
        let quota = try XCTUnwrap(fixture.model.latestAgentQuota)

        let presentation = fixture.model.codexQuotaIdentityPresentation(for: quota)
        XCTAssertEqual(presentation.title, "Fixture Model")
        XCTAssertEqual(presentation.limitID, "fixture-model")
        XCTAssertTrue(presentation.hasKnownLimitIdentity)
        XCTAssertEqual(presentation.context, "quota-fixture@example.invalid · Codex OAuth")
        XCTAssertEqual(quota.limitID, "fixture-model")
        XCTAssertEqual(quota.limitName, "Fixture Model")
    }

    private func assertUnknownScope(
        _ quota: AgentQuotaStatus,
        in model: MenuBarStatusModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let presentation = model.codexQuotaIdentityPresentation(for: quota)
        XCTAssertTrue(presentation.context.contains("额度范围未知"), file: file, line: line)
        XCTAssertFalse(presentation.hasKnownLimitIdentity, file: file, line: line)
    }

    private func quota(
        limitID: String? = nil,
        limitName: String? = nil,
        source: AgentQuotaSource = .oauth,
        updatedAt: Date? = nil
    ) -> AgentQuotaStatus {
        AgentQuotaStatus(
            remainingPercent: 67, usedPercent: 33,
            limitID: limitID, limitName: limitName,
            accountScopeID: savedAccountID, source: source,
            windowMinutes: 7 * 24 * 60,
            resetsAt: now.addingTimeInterval(4 * 24 * 60 * 60),
            updatedAt: updatedAt ?? now
        )
    }

    private func successfulFetchState() -> CodexUsageFetchState {
        CodexUsageFetchState(
            source: .oauth, lastSuccessfulAt: now, lastAttemptedAt: now,
            errorMessage: nil, isStale: false
        )
    }

    private func makeFixture(
        authoritativeQuota: AgentQuotaStatus? = nil,
        fetchState: CodexUsageFetchState?,
        hasSavedAccount: Bool = true,
        hasActiveSavedAccount: Bool = true,
        credentialKind: CodexAccountProfile.CredentialKind = .oauth
    ) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("quota-identity-presentation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suiteName = "AgentSignalQuotaIdentityPresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.set(AppLanguage.zhHans.rawValue, forKey: "appLanguage")
        let account = CodexCurrentAccount(
            email: "quota-fixture@example.invalid", accountID: "quota-fixture-account",
            credentialKind: credentialKind, planName: nil,
            authFingerprint: "quota-fixture-fingerprint",
            authFileURL: directory.appendingPathComponent("unused-auth.json")
        )
        let profile = CodexAccountProfile(
            id: savedAccountID, label: "quota-fixture@example.invalid",
            email: account.email, accountID: account.accountID,
            credentialKind: credentialKind, planName: nil,
            authFingerprint: account.authFingerprint, credentialReference: nil,
            authDataBase64: nil, managedHomePath: nil, createdAt: now, updatedAt: now
        )
        let state = CodexAccountState(
            currentAccount: account, savedAccounts: hasSavedAccount ? [profile] : [],
            activeSavedAccountID: hasActiveSavedAccount ? savedAccountID : nil
        )
        let usageStore = CodexAccountUsageSnapshotStore(fileURL: directory.appendingPathComponent("usage.json"))
        usageStore.store(
            account: account, quota: authoritativeQuota ?? quota(), credits: nil,
            usageFetchState: fetchState, tokenUsage: nil,
            tokenActivityCacheVersion: CodexTokenActivityScanner.currentCacheVersion,
            tokenActivityDays: [], updatedAt: now
        )
        let fixedNow = now
        let model = MenuBarStatusModel(
            store: SignalStateStore(stateFileURL: directory.appendingPathComponent("state.json")),
            userDefaults: defaults, startsMonitoring: false,
            codexAccountManager: QuotaIdentityFixtureAccountManager(state: state),
            codexUsageSnapshotStore: usageStore,
            codexTokenActivityScanner: QuotaIdentityUnusedTokenScanner(),
            performsAccountSwitchBackgroundRefreshes: false, nowProvider: { fixedNow }
        )
        return Fixture(model: model, directory: directory, defaults: defaults, suiteName: suiteName)
    }

    private struct Fixture {
        let model: MenuBarStatusModel
        let directory: URL
        let defaults: UserDefaults
        let suiteName: String

        func cleanUp() {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
    }
}

private final class QuotaIdentityFixtureAccountManager: CodexAccountManaging, @unchecked Sendable {
    private let state: CodexAccountState

    init(state: CodexAccountState) { self.state = state }

    func loadState() throws -> CodexAccountState { state }
    func loadMetadataState() throws -> CodexAccountState { state }
    func saveCurrentAccount(label: String?) throws -> CodexAccountProfile { throw CodexAccountManagerError.accountNotFound }
    func switchToAccount(id: UUID) throws -> CodexAccountProfile { throw CodexAccountManagerError.accountNotFound }
    func authenticateManagedAccount(timeout: TimeInterval) async throws -> CodexAccountProfile { throw CodexAccountManagerError.accountNotFound }
    func removeAccount(id: UUID) throws {}
    func refreshSavedCurrentAccountIfPossible() throws -> CodexAccountProfile? { nil }
}

private struct QuotaIdentityUnusedTokenScanner: CodexTokenActivityScanning {
    func cachedDailyActivity(now: Date, days: Int) -> [CodexTokenActivityDay]? { nil }
    func scanDailyActivity(
        now: Date, days: Int, progress: (([CodexTokenActivityDay]) -> Void)?
    ) -> [CodexTokenActivityDay] { [] }
}

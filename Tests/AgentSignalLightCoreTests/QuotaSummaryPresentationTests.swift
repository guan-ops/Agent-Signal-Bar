import Foundation
import XCTest
@testable import AgentSignalLight
@testable import AgentSignalLightCore

@MainActor
final class QuotaSummaryPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_788_400_000)

    func testUnnamedAccountQuotaDoesNotAddDuplicateNamedLocalObservation() throws {
        let authoritative = quota(remaining: 67, source: .oauth)
        let local = quota(remaining: 67, limitID: "codex", source: .desktopSession)
        let fixture = try makeFixture(authoritativeQuota: authoritative)
        defer { fixture.cleanUp() }
        observe(local, in: fixture.model)

        XCTAssertEqual(fixture.model.latestAgentQuota, authoritative)
        XCTAssertNil(fixture.model.recentLocalQuotaObservation(now: now))
        XCTAssertEqual(
            fixture.model.codexQuotaSummaryState(now: now),
            .authoritative(authoritative, localObservation: nil)
        )
        XCTAssertEqual(fixture.model.latestLocalAgentQuotaObservation, local)
    }

    func testDifferentLocalQuotaFieldsDoNotCreateAnAdditionalCard() throws {
        let authoritative = quota(remaining: 67, limitID: "codex", source: .oauth)
        let local = quota(
            remaining: 25, limitID: "different-local-pool", limitName: "Local model quota",
            source: .desktopSession, windowMinutes: 300, updatedAt: now.addingTimeInterval(1)
        )
        let fixture = try makeFixture(authoritativeQuota: authoritative)
        defer { fixture.cleanUp() }
        observe(local, in: fixture.model)

        XCTAssertNil(fixture.model.recentLocalQuotaObservation(now: now))
        let state = fixture.model.codexQuotaSummaryState(now: now)
        XCTAssertEqual(state, .authoritative(authoritative, localObservation: nil))
        XCTAssertEqual(state.displayedQuota, authoritative)
        XCTAssertEqual(fixture.model.latestLocalAgentQuotaObservation, local)
    }

    func testFreshLocalObservationRemainsAvailableWithoutAccountQuota() throws {
        let local = quota(remaining: 67, limitID: "codex", source: .desktopSession)
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        observe(local, in: fixture.model)

        XCTAssertNil(fixture.model.latestAgentQuota)
        XCTAssertEqual(fixture.model.recentLocalQuotaObservation(now: now), local)
        let state = fixture.model.codexQuotaSummaryState(now: now)
        XCTAssertEqual(state, .localObservation(local))
        XCTAssertEqual(state.displayedQuota, local)
        XCTAssertEqual(fixture.model.latestLocalAgentQuotaObservation, local)
    }

    func testExpiredLocalObservationIsUnavailableWithoutAccountQuota() throws {
        let local = quota(
            remaining: 67, limitID: "codex", source: .desktopSession,
            updatedAt: now.addingTimeInterval(-15 * 60 - 1)
        )
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        observe(local, in: fixture.model)

        XCTAssertNil(fixture.model.latestAgentQuota)
        XCTAssertNil(fixture.model.recentLocalQuotaObservation(now: now))
        let state = fixture.model.codexQuotaSummaryState(now: now)
        XCTAssertEqual(state, .unavailable)
        XCTAssertNil(state.displayedQuota)
        XCTAssertEqual(fixture.model.latestLocalAgentQuotaObservation, local)
    }

    private func quota(
        remaining: Double,
        limitID: String? = nil,
        limitName: String? = nil,
        source: AgentQuotaSource,
        windowMinutes: Int = 7 * 24 * 60,
        updatedAt: Date? = nil
    ) -> AgentQuotaStatus {
        AgentQuotaStatus(
            remainingPercent: remaining, usedPercent: 100 - remaining,
            limitID: limitID, limitName: limitName, source: source,
            windowMinutes: windowMinutes, resetsAt: now.addingTimeInterval(4 * 24 * 60 * 60),
            updatedAt: updatedAt ?? now
        )
    }

    private func observe(_ quota: AgentQuotaStatus, in model: MenuBarStatusModel) {
        XCTAssertTrue(model.updateLatestLocalQuotaObservation(CodexDesktopQuotaUpdate(
            sessionID: "codex-desktop:quota-summary-fixture", agent: "codex-desktop", quota: quota
        )))
    }

    private func makeFixture(authoritativeQuota: AgentQuotaStatus? = nil) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("quota-summary-presentation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suiteName = "AgentSignalQuotaSummaryPresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let account = CodexCurrentAccount(
            email: "quota-fixture@example.invalid", accountID: "quota-fixture-account",
            credentialKind: .oauth, planName: nil, authFingerprint: "quota-fixture-fingerprint",
            authFileURL: directory.appendingPathComponent("unused-auth.json")
        )
        let usageStore = CodexAccountUsageSnapshotStore(fileURL: directory.appendingPathComponent("usage.json"))
        if let authoritativeQuota {
            usageStore.store(
                account: account, quota: authoritativeQuota, credits: nil, tokenUsage: nil,
                tokenActivityCacheVersion: CodexTokenActivityScanner.currentCacheVersion,
                tokenActivityDays: [], updatedAt: now
            )
        }
        let fixedNow = now
        let model = MenuBarStatusModel(
            store: SignalStateStore(stateFileURL: directory.appendingPathComponent("state.json")),
            userDefaults: defaults, startsMonitoring: false,
            codexAccountManager: QuotaSummaryFixtureAccountManager(account: account),
            codexUsageSnapshotStore: usageStore,
            codexTokenActivityScanner: QuotaSummaryUnusedTokenScanner(),
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

private final class QuotaSummaryFixtureAccountManager: CodexAccountManaging, @unchecked Sendable {
    private let account: CodexCurrentAccount

    init(account: CodexCurrentAccount) { self.account = account }

    func loadState() throws -> CodexAccountState {
        CodexAccountState(currentAccount: account, savedAccounts: [], activeSavedAccountID: nil)
    }
    func loadMetadataState() throws -> CodexAccountState { try loadState() }
    func saveCurrentAccount(label: String?) throws -> CodexAccountProfile { throw CodexAccountManagerError.accountNotFound }
    func switchToAccount(id: UUID) throws -> CodexAccountProfile { throw CodexAccountManagerError.accountNotFound }
    func authenticateManagedAccount(timeout: TimeInterval) async throws -> CodexAccountProfile { throw CodexAccountManagerError.accountNotFound }
    func removeAccount(id: UUID) throws {}
    func refreshSavedCurrentAccountIfPossible() throws -> CodexAccountProfile? { nil }
}

private struct QuotaSummaryUnusedTokenScanner: CodexTokenActivityScanning {
    func cachedDailyActivity(now: Date, days: Int) -> [CodexTokenActivityDay]? { nil }
    func scanDailyActivity(
        now: Date, days: Int, progress: (([CodexTokenActivityDay]) -> Void)?
    ) -> [CodexTokenActivityDay] { [] }
}

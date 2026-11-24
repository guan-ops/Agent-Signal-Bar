import AppKit
import SwiftUI
import XCTest
import AgentSignalLightCore
@testable import AgentSignalLight

@MainActor
final class CodexCreditsPresentationTests: XCTestCase {
    // XCTest builds every test instance when the run starts; a stored `now` would be minutes old by
    // the time a late test hydrates its snapshot, which the model then correctly treats as stale.
    private lazy var now = Date()
    private func credits(_ balance: Double = 125.5, date: Date? = nil) -> CodexCreditStatus {
        .init(title: "Credits", used: nil, limit: nil, remaining: balance, remainingPercent: nil,
              resetsAt: nil, updatedAt: date ?? now, balance: balance)
    }
    private func state(stale: Bool = false, error: String? = nil) -> CodexUsageFetchState {
        .init(source: .oauth, lastSuccessfulAt: now, lastAttemptedAt: now, errorMessage: error, isStale: stale)
    }
    private func quota(_ primary: Double, _ weekly: Double? = 70, reset: Date? = nil) -> AgentQuotaStatus {
        .init(remainingPercent: primary, usedPercent: 100 - primary, source: .oauth, windowMinutes: 300,
              resetsAt: reset ?? now.addingTimeInterval(3600), updatedAt: now,
              primary: .init(remainingPercent: primary, usedPercent: 100 - primary, windowMinutes: 300,
                             resetsAt: reset ?? now.addingTimeInterval(3600)),
              secondary: weekly.map { .init(remainingPercent: $0, usedPercent: 100 - $0, windowMinutes: 10080,
                                            resetsAt: reset ?? now.addingTimeInterval(86400)) })
    }
    func testCreditsAutomaticallyReplaceEitherExhaustedWindowAndReturnAfterRecovery() {
        for value in [quota(0), quota(70, 0), quota(0, 0)] {
            XCTAssertTrue(CodexCreditsDisplay.usesCredits(quota: value, credits: credits(), fetchState: state(), now: now))
        }
        XCTAssertFalse(CodexCreditsDisplay.usesCredits(quota: quota(40), credits: credits(), fetchState: state(), now: now))
        XCTAssertFalse(CodexCreditsDisplay.usesCredits(quota: quota(0, 0, reset: now), credits: credits(), fetchState: state(), now: now))
        XCTAssertTrue(CodexCreditsDisplay.usesCredits(quota: nil, credits: credits(), fetchState: state(), now: now))
    }
    func testZeroMissingExpiredAndFailedBalancesNeverTriggerAutomaticFallback() {
        for value in [nil, credits(0), credits(-1), credits(.infinity), credits(date: now.addingTimeInterval(-301))] {
            XCTAssertFalse(CodexCreditsDisplay.usesCredits(quota: quota(0), credits: value, fetchState: state(), now: now))
        }
        for value in [nil, state(stale: true), state(error: "Fixture refresh failure")] {
            XCTAssertFalse(CodexCreditsDisplay.usesCredits(quota: quota(0), credits: credits(), fetchState: value, now: now))
        }
        XCTAssertEqual(CodexCreditsDisplay.badgeText(125.5), "125c")
        XCTAssertEqual(CodexCreditsDisplay.badgeText(0.3), "<1c")
        XCTAssertEqual(CodexCreditsDisplay.badgeText(1250), "1.2Kc")
    }
    func testParserAcceptsCreditOnlyAndMonthlyPlusPurchasedBalanceWithoutInventingQuota() throws {
        func parse(_ text: String) throws -> CodexUsageStatus {
            try CodexRateLimitFetcher.usageStatus(from: JSONDecoder().decode(CodexUsageResponse.self, from: Data(text.utf8)),
                                                updatedAt: now, source: .oauth)
        }
        let only = try parse(#"{"credits":{"balance":"125.5"}}"#)
        XCTAssertNil(only.quota)
        XCTAssertEqual(only.credits?.remaining, 125.5)
        let both = try parse(#"{"individual_limit":{"limit":1000,"used":100},"credits":{"balance":42}}"#)
        XCTAssertNil(both.quota)
        XCTAssertEqual(both.credits?.remaining, 900)
        XCTAssertEqual(both.credits?.balance, 42)
        XCTAssertEqual(try parse(#"{"credits":{"balance":0}}"#).credits?.remaining, 0)
        for text in [#"{"credits":{"balance":-1}}"#, #"{"credits":{"balance":"nan"}}"#,
                     #"{"individual_limit":{"limit":1000}}"#, #"{"credits":{"unlimited":true}}"#] {
            XCTAssertThrowsError(try parse(text))
        }
    }
    func testBalanceCacheHydratesAndAccountChangeClearsAllCreditSurfaces() throws {
        let f = try CreditFixture(quota: quota(0), credits: credits(), state: state()); defer { f.clean() }
        let model = f.model()
        XCTAssertEqual(model.codexFloatingCredits?.remaining, 125.5)
        model.selectSignalLightProvider(.claude)
        XCTAssertEqual(model.floatingQuotaContent, .claude)
        model.selectSignalLightProvider(.codex)
        XCTAssertNotNil(model.codexFloatingCredits)
        f.accounts.account = .init(email: "other@example.invalid", accountID: "other-fixture", credentialKind: .oauth,
                                  planName: "Pro", authFingerprint: "other-owner", authFileURL: f.root.appendingPathComponent("other.json"))
        model.refreshCodexAccounts()
        XCTAssertNil(model.latestCodexCredits, "A different account must never inherit this balance")
        f.accounts.account = nil
        model.refreshCodexAccounts()
        XCTAssertNil(model.latestCodexCredits)
        XCTAssertNil(model.codexFloatingCredits)
        XCTAssertNil(model.floatingQuotaContent)
    }
    func testForgottenRemoteQuotaIsNotRestoredFromTheStateFile() throws {
        let f = try CreditFixture(quota: nil, credits: credits(), state: state()); defer { f.clean() }
        let store = SignalStateStore(stateFileURL: f.root.appendingPathComponent("status.json"))
        _ = try store.applySessionQuota(quota(40), sessionID: "codex-rate-limits", agent: "Codex", updatedAt: now)
        let model = f.model()
        // Settings → clear usage cache must forget the quota everywhere, not only in memory.
        model.clearDebugUsageCache()
        XCTAssertNil(model.latestAgentQuota)
        XCTAssertNil(store.readSnapshot().sessions.first { $0.sessionID == "codex-rate-limits" }?.quota)
        model.reload()
        XCTAssertNil(model.latestAgentQuota, "A reload must not restore it")
        XCTAssertNil(f.model().latestAgentQuota, "A relaunch must not restore it from the state file")
    }

    func testClearingASessionQuotaKeepsTheSessionAndSkipsNeedlessWrites() throws {
        let root = URL(fileURLWithPath: "/private/tmp/clear-session-quota-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("status.json")
        let store = SignalStateStore(stateFileURL: file)
        _ = try store.applySessionQuota(quota(40), sessionID: "codex-rate-limits", agent: "Codex", updatedAt: now)
        let cleared = try store.clearSessionQuota(sessionID: "codex-rate-limits")
        let session = try XCTUnwrap(cleared.sessions.first { $0.sessionID == "codex-rate-limits" })
        XCTAssertNil(session.quota)
        XCTAssertEqual(session.agent, "Codex")
        let bytes = try Data(contentsOf: file)
        _ = try store.clearSessionQuota(sessionID: "codex-rate-limits")
        _ = try store.clearSessionQuota(sessionID: "missing")
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testCreditOnlyAndStaleCachedBalancesKeepZeroAndUnknownSeparate() throws {
        for stale in [false, true] {
            let f = try CreditFixture(quota: nil, credits: credits(0), state: state(stale: stale)); defer { f.clean() }
            let model = f.model()
            XCTAssertEqual(model.floatingQuotaContent, .codexCredits)
            XCTAssertEqual(model.latestCodexCredits?.remaining, 0)
            XCTAssertEqual(model.codexFloatingCredits?.remaining, stale ? nil : 0)
        }
    }
    func testCreditBadgeAndDetailsRenderInBothThemes() async throws {
        let f = try CreditFixture(quota: quota(0), credits: credits(), state: state()); defer { f.clean() }
        let model = f.model()
        _ = NSApplication.shared
        for theme in [AppTheme.light, .dark] {
            model.setAppTheme(theme)
            let host = NSHostingView(rootView: VStack(spacing: 16) {
                FloatingSignalPanelView(model: model, animationClock: model.animationClock,
                    hide: {}, smaller: {}, larger: {}, toggleLayout: {}, toggleSound: {},
                    previewCompletionSound: {}, previewWaitingSound: {}, resizeFromHandle: { _, _ in }, openSettings: {})
                FloatingSignalQuotaPopoverView(model: model, quota: .codex(quota(0)))
            }.padding(16).frame(width: 380, height: 610).preferredColorScheme(theme == .dark ? .dark : .light))
            host.frame = NSRect(x: 0, y: 0, width: 380, height: 610)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host; window.appearance = NSAppearance(named: theme == .dark ? .darkAqua : .aqua)
            host.wantsLayer = true; host.layer?.backgroundColor = NSColor(white: theme == .dark ? 0.12 : 0.94, alpha: 1).cgColor
            window.orderFront(nil); defer { window.orderOut(nil) }
            try await Task.sleep(for: .milliseconds(600))
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            XCTAssertGreaterThan(bitmap.pixelsWide, 0)
            if let path = ProcessInfo.processInfo.environment["ASB_CREDIT_PREVIEW"] {
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path).appendingPathComponent("codex-credits-\(theme.rawValue).png"))
            }
        }
    }
}

@MainActor
private struct CreditFixture {
    let root: URL
    let suite: String
    let defaults: UserDefaults
    let accounts: CreditAccounts
    let usageStore: CodexAccountUsageSnapshotStore
    init(quota: AgentQuotaStatus?, credits: CodexCreditStatus?, state: CodexUsageFetchState) throws {
        root = URL(fileURLWithPath: "/private/tmp/codex-credits-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "codex-credits-\(UUID())"; defaults = UserDefaults(suiteName: suite)!
        defaults.set("en", forKey: "appLanguage"); defaults.set("off", forKey: "codexOpenAICookieMode")
        defaults.set(true, forKey: "isFloatingSignalQuotaBadgeEnabled")
        defaults.set(false, forKey: "isFloatingSignalSoundEnabled")
        let account = CodexCurrentAccount(email: "credits@example.invalid", accountID: "fixture-credits", credentialKind: .oauth,
            planName: "Pro", authFingerprint: "fixture-owner", authFileURL: root.appendingPathComponent("auth.json"))
        accounts = CreditAccounts(account: account)
        usageStore = .init(fileURL: root.appendingPathComponent("usage.json"))
        usageStore.store(account: account, quota: quota, credits: credits, usageFetchState: state,
            tokenUsage: nil, tokenActivityCacheVersion: nil, tokenActivityDays: [])
    }
    func model() -> MenuBarStatusModel {
        let model = MenuBarStatusModel(store: SignalStateStore(stateFileURL: root.appendingPathComponent("status.json")),
            userDefaults: defaults, startsMonitoring: false, codexAccountManager: accounts,
            codexUsageSnapshotStore: usageStore,
            codexTokenActivityScanner: CodexTokenActivityScanner(sessionRootURLs: [], cacheURL: root.appendingPathComponent("tokens.json"), costUsageCacheRootURL: root.appendingPathComponent("cost")),
            performsAccountSwitchBackgroundRefreshes: false)
        model.selectSignalLightProvider(.codex)
        return model
    }
    func clean() { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
}

private final class CreditAccounts: CodexAccountManaging, @unchecked Sendable {
    var account: CodexCurrentAccount?
    init(account: CodexCurrentAccount) { self.account = account }
    func loadState() throws -> CodexAccountState { .init(currentAccount: account, savedAccounts: [], activeSavedAccountID: nil) }
    func saveCurrentAccount(label: String?) throws -> CodexAccountProfile { throw CodexAccountManagerError.accountNotFound }
    func switchToAccount(id: UUID) throws -> CodexAccountProfile { throw CodexAccountManagerError.accountNotFound }
    func authenticateManagedAccount(timeout: TimeInterval) async throws -> CodexAccountProfile { throw CodexAccountManagerError.accountNotFound }
    func removeAccount(id: UUID) throws {}
    func refreshSavedCurrentAccountIfPossible() throws -> CodexAccountProfile? { nil }
}

import Foundation
import AppKit
import SwiftUI
import XCTest
@testable import AgentSignalLight
@testable import AgentSignalLightCore
@testable import AgentSignalLightUI

@MainActor
final class TokenActivityPresentationTests: XCTestCase {
    private var now: Date {
        Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 60 * 60)
    }

    func testPartialCostSurvivesSnapshotAndRespectsSelectedPeriod() async throws {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        let partial = CodexTokenActivityDay(day: yesterday, totalTokens: 303_000,
            estimatedCostUSD: 0.035, hasUnpricedUsage: true)
        let restored = try JSONDecoder().decode(CodexTokenActivityDay.self,
            from: JSONEncoder().encode(partial))
        let history = [restored, CodexTokenActivityDay(day: now, totalTokens: 2_000, estimatedCostUSD: 0.1)]
        let fixture = try makeFixture(scanner: PresentationTokenScanner(result: .init(days: history, watermarks: [])),
            history: history) { _ in }
        defer { fixture.cleanUp() }
        XCTAssertFalse(fixture.model.tokenActivityCostIsPartial(for: .today, now: now))
        XCTAssertTrue(fixture.model.tokenActivityCostIsPartial(for: .last30Days, now: now))
        let cost = try XCTUnwrap(fixture.model.tokenActivityEstimatedCost(for: .last30Days, now: now))
        XCTAssertEqual(cost, 0.135, accuracy: 0.000_000_001)
        XCTAssertTrue(fixture.model.estimatedCostText(cost,
            partial: fixture.model.tokenActivityCostIsPartial(for: .last30Days, now: now)).hasPrefix("≥"))

        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(partial)) as? [String: Any])
        legacy.removeValue(forKey: "hasUnpricedUsage")
        legacy.removeValue(forKey: "modelUnpricedTokenTotals")
        let oldSnapshot = try JSONDecoder().decode(CodexTokenActivityDay.self,
            from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(oldSnapshot.estimatedCostUSD, 0.035)
        if let directory = ProcessInfo.processInfo.environment["ASB_PARTIAL_MENU_PREVIEW"] {
            _ = NSApplication.shared
            let host = NSHostingView(rootView: MenuUsageSummaryView(model: fixture.model,
                claude: ClaudeSupportModel(defaults: fixture.defaults), navigation: UsageMenuNavigation(),
                nativeMenu: true, onOpenSettings: { _ in }).padding(12).frame(width: 380)
                    .background(Color(red: 0.12, green: 0.12, blue: 0.12)).preferredColorScheme(.dark))
            let size = host.fittingSize
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            window.appearance = NSAppearance(named: .darkAqua)
            window.orderFront(nil)
            defer { window.orderOut(nil) }
            try await Task.sleep(for: .milliseconds(200))
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("partial-menu.png"))
        }
    }

    func testFailedFirstScanIsUnavailableInsteadOfMeasuredZero() async throws {
        let failed = expectation(description: "failed scan visibly defers")
        let scanner = PresentationTokenScanner(result: CodexTokenActivityScanResult(
            days: [], watermarks: [], isComplete: false, failureDescription: "fixture read failure"
        ))
        let fixture = try makeFixture(scanner: scanner) {
            if $0 == .deferredWithRetryPending { failed.fulfill() }
        }
        defer { fixture.cleanUp() }
        XCTAssertNil(fixture.model.tokenActivityDisplayTotal(for: .today, now: now))

        fixture.model.refreshTokenActivityIfNeeded(force: true)
        await fulfillment(of: [failed], timeout: 3)

        XCTAssertNil(fixture.model.tokenActivityDisplayTotal(for: .last30Days, now: now))
        XCTAssertTrue(fixture.model.tokenActivityIssue?.contains("fixture read failure") == true)
        XCTAssertFalse(fixture.model.isTokenActivityLoading)
        XCTAssertFalse(fixture.model.hasCompletedTokenActivityScan)
    }

    func testConcurrentWriteShowsSyncStatusAndRetainsHistory() async throws {
        let deferred = expectation(description: "source change retries")
        let scanner = PresentationTokenScanner(result: .failure(
            days: [], error: CostUsageScanner.codexChangedDuringScanError(path: "/private/fixture.jsonl")))
        let fixture = try makeFixture(scanner: scanner, history: [CodexTokenActivityDay(
            day: now, totalTokens: 100, estimatedCostUSD: 0.01
        )]) {
            if $0 == .deferredWithRetryPending { deferred.fulfill() }
        }
        defer { fixture.cleanUp() }
        fixture.model.refreshTokenActivityIfNeeded(force: true)
        await fulfillment(of: [deferred], timeout: 3)
        XCTAssertEqual(fixture.model.tokenActivityDisplayTotal(for: .today, now: now), 100)
        let issue = try XCTUnwrap(fixture.model.tokenActivityIssue)
        XCTAssertTrue(issue.contains("同步") || issue.contains("Syncing"))
        XCTAssertFalse(issue.contains("扫描失败"))
        XCTAssertFalse(issue.contains("/private/"))
    }

    func testFailureRetainsConfirmedHistoryAndUnpricedLiveCounters() async throws {
        let failed = expectation(description: "failure preserves existing data")
        let scanner = PresentationTokenScanner(result: CodexTokenActivityScanResult(
            days: [], watermarks: [], isComplete: false, failureDescription: "unreadable fixture"
        ))
        let fixture = try makeFixture(scanner: scanner, history: [CodexTokenActivityDay(
            day: now, totalTokens: 100, estimatedCostUSD: 0.01
        )]) {
            if $0 == .deferredWithRetryPending { failed.fulfill() }
        }
        defer { fixture.cleanUp() }
        fixture.model.updateLatestAgentTokenUsage(
            AgentTokenUsage(totalTokens: 30), sessionID: "new-session", updatedAt: now
        )
        fixture.model.refreshTokenActivityIfNeeded(force: true)
        await fulfillment(of: [failed], timeout: 3)

        XCTAssertEqual(fixture.model.tokenActivityDisplayTotal(for: .today, now: now), 130)
        XCTAssertEqual(fixture.model.tokenActivityDays.map(\.totalTokens), [100])
        XCTAssertEqual(fixture.model.tokenActivityEstimatedCost(for: .today, now: now), 0.01)
    }

    func testPartialScanPublishesTrustedHistoryAndRetainsExcludedLiveUsage() async throws {
        let applied = expectation(description: "partial history applied")
        let result = CodexTokenActivityScanResult(
            days: [CodexTokenActivityDay(day: now, totalTokens: 100)],
            watermarks: [], warningDescription: "conflicting group",
            excludedSourceIDs: ["/fixture/conflict.jsonl"], excludedSessionIDs: ["conflict"]
        )
        let fixture = try makeFixture(scanner: PresentationTokenScanner(result: result)) {
            if $0 == .applied { applied.fulfill() }
        }
        defer { fixture.cleanUp() }
        fixture.model.updateLatestAgentTokenUsage(
            AgentTokenUsage(totalTokens: 30), sessionID: "conflict", updatedAt: now,
            observationCursor: cursor(offset: 10, source: "/fixture/conflict.jsonl")
        )
        fixture.model.refreshTokenActivityIfNeeded(force: true)
        await fulfillment(of: [applied], timeout: 3)

        XCTAssertEqual(fixture.model.tokenActivityDays.map(\.totalTokens), [100])
        XCTAssertEqual(fixture.model.tokenActivityDisplayTotal(for: .today, now: now), 130)
        XCTAssertTrue(fixture.model.tokenActivityIsPartial)
        XCTAssertTrue(fixture.model.tokenActivityStatusText?.contains("1 个会话") == true)
    }

    func testEntirelyExcludedScanIsNotReportedAsZero() async throws {
        let applied = expectation(description: "empty partial result applied")
        let fixture = try makeFixture(scanner: PresentationTokenScanner(result: CodexTokenActivityScanResult(
            days: [], watermarks: [], warningDescription: "all sources excluded",
            excludedSessionIDs: ["conflict"]
        ))) {
            if $0 == .applied { applied.fulfill() }
        }
        defer { fixture.cleanUp() }
        fixture.model.refreshTokenActivityIfNeeded(force: true)
        await fulfillment(of: [applied], timeout: 3)

        XCTAssertTrue(fixture.model.hasCompletedTokenActivityScan)
        XCTAssertNil(fixture.model.tokenActivityDisplayTotal(for: .today, now: now))
        XCTAssertNil(fixture.model.tokenActivityDisplayTotal(for: .last30Days, now: now))
    }

    func testPartialCoverageSurvivesRelaunchWhileMonitoringIsPaused() async throws {
        let applied = expectation(description: "partial coverage persisted")
        let scanner = PresentationTokenScanner(result: CodexTokenActivityScanResult(
            days: [CodexTokenActivityDay(day: now, totalTokens: 100)], watermarks: [],
            warningDescription: "conflicting records", excludedSessionIDs: ["one", "two"]
        ))
        let fixture = try makeFixture(scanner: scanner) {
            if $0 == .applied { applied.fulfill() }
        }
        defer { fixture.cleanUp() }
        fixture.model.refreshTokenActivityIfNeeded(force: true)
        await fulfillment(of: [applied], timeout: 3)

        let fixedNow = now
        let restored = MenuBarStatusModel(
            store: SignalStateStore(stateFileURL: fixture.directory.appendingPathComponent("relaunch-state.json")),
            userDefaults: fixture.defaults, startsMonitoring: false,
            codexAccountManager: PresentationEmptyAccountManager(),
            codexUsageSnapshotStore: CodexAccountUsageSnapshotStore(fileURL: fixture.directory.appendingPathComponent("usage.json")),
            codexTokenActivityScanner: scanner, performsAccountSwitchBackgroundRefreshes: false,
            nowProvider: { fixedNow }
        )
        restored.isMonitoringPaused = true
        XCTAssertTrue(restored.tokenActivityIsPartial)
        XCTAssertEqual(restored.tokenActivityDisplayTotal(for: .today, now: now), 100)
        XCTAssertTrue(restored.tokenActivityStatusText?.contains("2 个会话") == true)
        XCTAssertEqual(scanner.scanCount, 1)
    }

    func testCoveredLiveRevisionDuringScanDoesNotDiscardTheResult() async throws {
        let applied = expectation(description: "covered newer observation applies first scan")
        let scanner = PresentationTokenScanner(result: CodexTokenActivityScanResult(
            days: [CodexTokenActivityDay(day: now, totalTokens: 150)],
            watermarks: [watermark(offset: 20, total: 150)]
        ), blocksFirstScan: true)
        let fixture = try makeFixture(scanner: scanner) {
            if $0 == .applied { applied.fulfill() }
        }
        defer { scanner.release(); fixture.cleanUp() }
        fixture.model.updateLatestAgentTokenUsage(
            AgentTokenUsage(totalTokens: 100), sessionID: "session", updatedAt: now.addingTimeInterval(-10),
            observationCursor: cursor(offset: 10)
        )
        fixture.model.refreshTokenActivityIfNeeded(force: true)
        let didStart = await Task.detached { scanner.waitUntilStarted() }.value
        XCTAssertTrue(didStart)
        fixture.model.updateLatestAgentTokenUsage(
            AgentTokenUsage(totalTokens: 150), sessionID: "session", updatedAt: now,
            observationCursor: cursor(offset: 20)
        )
        scanner.release()
        await fulfillment(of: [applied], timeout: 3)

        XCTAssertEqual(scanner.scanCount, 1)
        XCTAssertEqual(fixture.model.tokenActivityDisplayTotal(for: .today, now: now), 150)
    }

    func testCompletedPrefixRetainsOnlyTheUnscannedLiveSuffix() async throws {
        let applied = expectation(description: "completed prefix applied during continued growth")
        let scanner = PresentationTokenScanner(result: CodexTokenActivityScanResult(
            days: [CodexTokenActivityDay(day: now, totalTokens: 100)],
            watermarks: [watermark(offset: 10, total: 100)]
        ), blocksFirstScan: true)
        let fixture = try makeFixture(scanner: scanner) {
            if $0 == .applied { applied.fulfill() }
        }
        defer { scanner.release(); fixture.cleanUp() }
        fixture.model.updateLatestAgentTokenUsage(
            AgentTokenUsage(totalTokens: 100), sessionID: "session", updatedAt: now,
            observationCursor: cursor(offset: 10)
        )
        fixture.model.refreshTokenActivityIfNeeded(force: true)
        let didStart = await Task.detached { scanner.waitUntilStarted() }.value
        XCTAssertTrue(didStart)
        fixture.model.updateLatestAgentTokenUsage(
            AgentTokenUsage(totalTokens: 150), sessionID: "session", updatedAt: now.addingTimeInterval(1),
            observationCursor: cursor(offset: 20)
        )
        scanner.release()
        await fulfillment(of: [applied], timeout: 3)

        XCTAssertEqual(scanner.scanCount, 1)
        XCTAssertEqual(fixture.model.tokenActivityDays.map(\.totalTokens), [100])
        XCTAssertEqual(fixture.model.tokenActivityDisplayTotal(for: .today, now: now), 150)
        XCTAssertTrue(fixture.model.tokenActivityStatusText?.contains("实时 Token") == true)
    }

    func testOldSessionLabelCanBeAbsorbedByExactSourceProof() async throws {
        let applied = expectation(description: "legacy label reconciles to actual source")
        let result = CodexTokenActivityScanResult(
            days: [CodexTokenActivityDay(day: now, totalTokens: 100)],
            watermarks: [watermark(offset: 10, total: 100, sessionID: "actual-child")]
        )
        let fixture = try makeFixture(scanner: PresentationTokenScanner(result: result)) {
            if $0 == .applied { applied.fulfill() }
        }
        defer { fixture.cleanUp() }
        fixture.model.updateLatestAgentTokenUsage(
            AgentTokenUsage(totalTokens: 100), sessionID: "old-root-label", updatedAt: now,
            observationCursor: cursor(offset: 10)
        )
        fixture.model.refreshTokenActivityIfNeeded(force: true)
        await fulfillment(of: [applied], timeout: 3)

        XCTAssertEqual(fixture.model.tokenActivityDisplayTotal(for: .today, now: now), 100)
    }

    func testRealAppendAfterCommittedScanAppliesHistoryWithoutRetryOrDoubleCounting() async throws {
        try await assertRealAppendReconciliation()
    }

    func testAppendAfterPrefixVerificationStillDefersUnprovenLiveSnapshot() async throws {
        try await assertRealAppendReconciliation(appendAfterProof: true)
    }

    func testRewriteBeforeAppendCannotObtainPrefixProof() async throws {
        try await assertRealAppendReconciliation(rewriteBeforeProof: true)
    }

    private func assertRealAppendReconciliation(
        appendAfterProof: Bool = false, rewriteBeforeProof: Bool = false
    ) async throws {
        let root = URL(fileURLWithPath: "/private/tmp/asb-live-append-\(UUID().uuidString)")
        let sessions = root.appendingPathComponent("sessions")
        let cache = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = sessions.appendingPathComponent("rollout-live-fixture.jsonl")
        let eventAt = now.addingTimeInterval(-10)
        let stamp = ISO8601DateFormatter().string(from: eventAt)
        func event(_ total: Int, _ last: Int) -> String {
            #"{"timestamp":"\#(stamp)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(total),"output_tokens":0},"last_token_usage":{"input_tokens":\#(last),"output_tokens":0}}}}"#
        }
        let header = #"{"timestamp":"\#(stamp)","type":"session_meta","payload":{"id":"live-fixture"}}"#
        try (header + "\n" + event(100, 100) + "\n").write(to: source, atomically: true, encoding: .utf8)
        var options = CostUsageScanner.Options(codexSessionsRoots: [sessions], cacheRoot: cache,
            codexTraceDatabaseURL: root.appendingPathComponent("missing.sqlite"))
        options.refreshMinIntervalSeconds = 0
        let report = try CostUsageScanner.loadDailyReportCancellable(provider: .codex,
            since: Calendar.current.startOfDay(for: now), until: now, now: now,
            options: options, checkCancellation: nil)
        XCTAssertEqual(report.summary?.totalTokens, 100)
        let exporter = CodexTokenActivityScanner(sessionRootURLs: [sessions],
            cacheURL: root.appendingPathComponent("unused.json"), costUsageCacheRootURL: cache,
            usesAgentSignalCostUsageScanner: true, priorityDatabaseURL: root.appendingPathComponent("missing.sqlite"))
        let before = try XCTUnwrap(exporter.agentSignalCostUsageScanWatermarks(through: now).first)
        let suffix = event(150, 50)
        let handle = try FileHandle(forWritingTo: source)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((suffix + "\n").utf8))
        try handle.close()
        let metadata = CostUsageScanner.codexFileMetadata(fileURL: source)
        XCTAssertNotEqual(metadata.changeTimeNanoseconds, before.sourceChangeTimeNanoseconds)
        var cursor = CodexTokenObservationCursor(sourceID: before.sourceID,
            sourceGeneration: try XCTUnwrap(metadata.fileId),
            sourceStatFingerprint: metadata.statFingerprint,
            sourceChangeTimeNanoseconds: metadata.changeTimeNanoseconds,
            endOffset: UInt64(metadata.size - 1),
            lineFingerprint: CodexTokenObservationCursor.fingerprint(for: Data(suffix.utf8)))
        if rewriteBeforeProof {
            let handle = try FileHandle(forWritingTo: source)
            try handle.write(contentsOf: Data((header + "\n" + event(200, 200) + "\n").utf8))
            try handle.close()
            XCTAssertThrowsError(try exporter.agentSignalCostUsageScanWatermarks(through: now))
            return
        }
        let watermarks = try exporter.agentSignalCostUsageScanWatermarks(through: now)
        XCTAssertEqual(watermarks.first?.endOffset, before.endOffset)
        XCTAssertEqual(watermarks.first?.totalTokens, 100)
        XCTAssertEqual(watermarks.first?.sourceChangeTimeNanoseconds, before.sourceChangeTimeNanoseconds)
        XCTAssertEqual(watermarks.first?.verifiedPrefixSnapshot?.matches(cursor), true)
        XCTAssertEqual(watermarks.first?.sourceID, cursor.sourceID)
        XCTAssertEqual(watermarks.first?.sourceGeneration, cursor.sourceGeneration)
        XCTAssertNotNil(watermarks.first?.eventTimestamp)
        if appendAfterProof {
            let laterSuffix = event(180, 30)
            let handle = try FileHandle(forWritingTo: source)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((laterSuffix + "\n").utf8))
            try handle.close()
            let later = CostUsageScanner.codexFileMetadata(fileURL: source)
            XCTAssertNotEqual(later.changeTimeNanoseconds, metadata.changeTimeNanoseconds)
            cursor = CodexTokenObservationCursor(sourceID: before.sourceID,
                sourceGeneration: try XCTUnwrap(later.fileId),
                sourceStatFingerprint: later.statFingerprint,
                sourceChangeTimeNanoseconds: later.changeTimeNanoseconds,
                endOffset: UInt64(later.size - 1),
                lineFingerprint: CodexTokenObservationCursor.fingerprint(for: Data(laterSuffix.utf8)))
        }
        let scanner = PresentationTokenScanner(result: .init(
            days: [.init(day: now, totalTokens: 100)], watermarks: watermarks))
        let finished = expectation(description: "scan completes or defers")
        let fixture = try makeFixture(scanner: scanner) {
            if $0 == .applied || $0 == .deferredWithRetryPending { finished.fulfill() }
        }
        defer { fixture.cleanUp() }
        let liveTotal = appendAfterProof ? 180 : 150
        fixture.model.updateLatestAgentTokenUsage(AgentTokenUsage(totalTokens: liveTotal),
            sessionID: "live-fixture", updatedAt: eventAt, observationCursor: cursor)
        fixture.model.refreshTokenActivityIfNeeded(force: true)
        await fulfillment(of: [finished], timeout: 3)
        if appendAfterProof {
            XCTAssertEqual(scanner.scanCount, 2)
            XCTAssertFalse(fixture.model.hasCompletedTokenActivityScan)
            XCTAssertNotNil(fixture.model.tokenActivityIssue)
            XCTAssertEqual(fixture.model.tokenActivityDisplayTotal(for: .today, now: now), 180)
            return
        }
        XCTAssertEqual(scanner.scanCount, 1)
        XCTAssertTrue(fixture.model.hasCompletedTokenActivityScan)
        XCTAssertNil(fixture.model.tokenActivityIssue)
        XCTAssertEqual(fixture.model.tokenActivityDays.map(\.totalTokens), [100])
        XCTAssertEqual(fixture.model.tokenActivityDisplayTotal(for: .today, now: now), 150)
    }

    func testExactGoodSourceOutranksAnExcludedLegacySessionLabel() async throws {
        let applied = expectation(description: "exact good child is not counted twice")
        let result = CodexTokenActivityScanResult(
            days: [CodexTokenActivityDay(day: now, totalTokens: 100)],
            watermarks: [watermark(offset: 10, total: 100, sessionID: "good-child")],
            warningDescription: "different source excluded",
            excludedSourceIDs: ["/fixture/bad-source.jsonl"], excludedSessionIDs: ["old-root-label"]
        )
        let fixture = try makeFixture(scanner: PresentationTokenScanner(result: result)) {
            if $0 == .applied { applied.fulfill() }
        }
        defer { fixture.cleanUp() }
        fixture.model.updateLatestAgentTokenUsage(
            AgentTokenUsage(totalTokens: 100), sessionID: "old-root-label", updatedAt: now,
            observationCursor: cursor(offset: 10)
        )
        fixture.model.refreshTokenActivityIfNeeded(force: true)
        await fulfillment(of: [applied], timeout: 3)

        XCTAssertEqual(fixture.model.tokenActivityDisplayTotal(for: .today, now: now), 100)
    }

    func testLegacyCompleteSourceProofSurvivesDisplayCacheMigration() async throws {
        for legacyVersion in [24, 25] {
            let applied = expectation(description: "legacy fully proven cursor reconciles after relaunch")
            let scanner = PresentationTokenScanner(result: CodexTokenActivityScanResult(
                days: [CodexTokenActivityDay(day: now, totalTokens: 100)],
                watermarks: [watermark(offset: 10, total: 100, sessionID: "actual-child")]
            ))
            let fixture = try makeFixture(scanner: scanner) { _ in }
            defer { fixture.cleanUp() }
            let store = CodexAccountUsageSnapshotStore(fileURL: fixture.directory.appendingPathComponent("usage.json"))
            store.storeDeviceTokenSnapshot(
                tokenUsage: AgentTokenUsage(totalTokens: 100),
                liveTokenCounters: [CodexLiveTokenCounterSnapshot(
                    key: "old-root-label", sessionID: "old-root-label", totalTokens: 100,
                    scannedBaseline: 100, day: now, updatedAt: now, observationCursor: cursor(offset: 10)
                )],
                tokenActivityCacheVersion: legacyVersion,
                tokenActivityDays: [CodexTokenActivityDay(day: now, totalTokens: 999)]
            )
            let fixedNow = now
            let restored = MenuBarStatusModel(
                store: SignalStateStore(stateFileURL: fixture.directory.appendingPathComponent("migration-state.json")),
                userDefaults: fixture.defaults, startsMonitoring: false,
                codexAccountManager: PresentationEmptyAccountManager(), codexUsageSnapshotStore: store,
                codexTokenActivityScanner: scanner,
                tokenActivityScanObserver: { if $0 == .applied { applied.fulfill() } },
                performsAccountSwitchBackgroundRefreshes: false, nowProvider: { fixedNow }
            )
            XCTAssertTrue(restored.tokenActivityDays.isEmpty)
            restored.refreshTokenActivityIfNeeded(force: true)
            await fulfillment(of: [applied], timeout: 3)

            XCTAssertEqual(restored.tokenActivityDisplayTotal(for: .today, now: now), 100)
            XCTAssertEqual(scanner.scanCount, 1)
        }
    }

    func testLoggedOutQuotaRefreshRemainsUnavailableWithoutStartingRequests() throws {
        let fixture = try makeFixture(scanner: PresentationTokenScanner(result: .init(
            days: [], watermarks: [], isComplete: true))) { _ in }
        defer { fixture.cleanUp() }
        fixture.model.codexOpenAICookieMode = .off
        for _ in 0..<5 {
            fixture.model.refreshCodexAccounts()
            fixture.model.pollCodexRateLimitsIfNeeded(force: true)
            XCTAssertTrue(fixture.model.codexUsageRequiresLogin)
            XCTAssertNil(fixture.model.latestAgentQuota)
            XCTAssertFalse(fixture.model.isCodexRateLimitFetchInFlight)
        }
    }

    func testExplicitCookieRouteRemainsAvailableWithoutCLIAccount() throws {
        let fixture = try makeFixture(scanner: PresentationTokenScanner(result: .init(
            days: [], watermarks: [], isComplete: true))) { _ in }
        defer { fixture.cleanUp() }
        fixture.model.codexUsageDataSource = .automatic
        fixture.model.codexOpenAICookieMode = .manual
        XCTAssertFalse(fixture.model.codexUsageRequiresLogin)
        fixture.model.codexUsageDataSource = .oauthAPI
        XCTAssertTrue(fixture.model.codexUsageRequiresLogin)
    }

    private func cursor(offset: UInt64, source: String = "/fixture/session.jsonl") -> CodexTokenObservationCursor {
        CodexTokenObservationCursor(
            sourceID: source, sourceGeneration: "fixture-generation",
            sourceStatFingerprint: 100, sourceChangeTimeNanoseconds: 100,
            endOffset: offset, lineFingerprint: "line-\(offset)"
        )
    }

    private func watermark(offset: UInt64, total: Int, sessionID: String = "session") -> CodexTokenActivityScanWatermark {
        CodexTokenActivityScanWatermark(
            sessionID: sessionID, sourceID: "/fixture/session.jsonl", sourceGeneration: "fixture-generation",
            endOffset: offset, lineFingerprint: "line-\(offset)", eventTimestamp: now, totalTokens: total,
            sourceStatFingerprint: 100, sourceChangeTimeNanoseconds: 100
        )
    }

    func testLongSuccessfulScanCooldownStartsAtCompletionAndUnchangedHistoryWaits() async throws {
        let applied = expectation(description: "first applied")
        let reapplied = expectation(description: "idle discovery")
        var appliedCount = 0
        let clock = ProgressTestClock(now)
        let scanner = PresentationTokenScanner(result: .init(days: [], watermarks: []), blocksFirstScan: true)
        let fixture = try makeFixture(scanner: scanner, clock: { clock.now }) {
            if $0 == .applied {
                appliedCount += 1
                if appliedCount == 1 { applied.fulfill() } else { reapplied.fulfill() }
            }
        }
        defer { scanner.release(); fixture.cleanUp() }
        fixture.model.refreshTokenActivityIfNeeded(force: true)
        XCTAssertTrue(scanner.waitUntilStarted())
        XCTAssertTrue(fixture.model.isTokenActivityLoading)
        clock.advance(120)
        scanner.release()
        await fulfillment(of: [applied], timeout: 3)
        XCTAssertFalse(fixture.model.isTokenActivityLoading)
        XCTAssertEqual(fixture.model.tokenActivityScanProgress?.phase, .complete)
        XCTAssertEqual(fixture.model.tokenActivityScanProgress?.fraction, 1)
        XCTAssertEqual(fixture.model.tokenActivityCompletedAt, clock.now)
        fixture.model.refreshTokenActivityIfNeeded()
        clock.advance(299)
        fixture.model.refreshTokenActivityIfNeeded()
        XCTAssertEqual(scanner.scanCount, 1)
        clock.advance(1)
        fixture.model.refreshTokenActivityIfNeeded()
        await fulfillment(of: [reapplied], timeout: 3)
        XCTAssertEqual(scanner.scanCount, 2)
    }

    func testNewLiveUsageUsesNormalIntervalAfterCompletion() async throws {
        let applied = expectation(description: "first applied")
        let clock = ProgressTestClock(now)
        let scanner = PresentationTokenScanner(result: .init(days: [], watermarks: []))
        let fixture = try makeFixture(scanner: scanner, clock: { clock.now }) { if $0 == .applied { applied.fulfill() } }
        defer { fixture.cleanUp() }
        fixture.model.refreshTokenActivityIfNeeded(force: true)
        await fulfillment(of: [applied], timeout: 3)
        fixture.model.updateLatestAgentTokenUsage(AgentTokenUsage(totalTokens: 10), sessionID: "new", updatedAt: clock.now)
        clock.advance(59)
        fixture.model.refreshTokenActivityIfNeeded()
        XCTAssertEqual(scanner.scanCount, 1)
        clock.advance(1)
        fixture.model.refreshTokenActivityIfNeeded()
        XCTAssertTrue(fixture.model.isTokenActivityLoading)
        for _ in 0..<200 where fixture.model.isTokenActivityLoading { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(fixture.model.isTokenActivityLoading)
    }

    private func makeFixture(
        scanner: PresentationTokenScanner,
        history: [CodexTokenActivityDay] = [],
        clock: (@Sendable () -> Date)? = nil,
        observer: @escaping (TokenActivityScanDisposition) -> Void
    ) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("token-presentation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suiteName = "AgentSignalTokenPresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.set("zh-Hans", forKey: "appLanguage")
        let usageStore = CodexAccountUsageSnapshotStore(fileURL: directory.appendingPathComponent("usage.json"))
        if !history.isEmpty {
            usageStore.storeDeviceTokenSnapshot(tokenUsage: nil, tokenActivityCacheVersion: CodexTokenActivityScanner.currentCacheVersion, tokenActivityDays: history)
        }
        let fixedNow = now
        let model = MenuBarStatusModel(
            store: SignalStateStore(stateFileURL: directory.appendingPathComponent("state.json")),
            userDefaults: defaults, startsMonitoring: false,
            codexAccountManager: PresentationEmptyAccountManager(), codexUsageSnapshotStore: usageStore,
            codexTokenActivityScanner: scanner, tokenActivityScanObserver: observer,
            performsAccountSwitchBackgroundRefreshes: false, nowProvider: { clock?() ?? fixedNow }
        )
        model.isCodexDesktopMonitoringEnabled = true
        model.isMonitoringPaused = false
        model.appLanguage = .zhHans
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

private final class PresentationTokenScanner: CodexTokenActivityScanning, @unchecked Sendable {
    let result: CodexTokenActivityScanResult
    private let blocksFirstScan: Bool
    private let started = DispatchSemaphore(value: 0)
    private let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var count = 0
    var scanCount: Int { lock.withLock { count } }

    init(result: CodexTokenActivityScanResult, blocksFirstScan: Bool = false) {
        self.result = result
        self.blocksFirstScan = blocksFirstScan
    }

    func cachedDailyActivity(now: Date, days: Int) -> [CodexTokenActivityDay]? { nil }
    func scanDailyActivity(now: Date, days: Int, progress: (([CodexTokenActivityDay]) -> Void)?) -> [CodexTokenActivityDay] {
        scanDailyActivityResult(now: now, days: days, progress: progress).days
    }
    func scanDailyActivityResult(now: Date, days: Int, progress: (([CodexTokenActivityDay]) -> Void)?) -> CodexTokenActivityScanResult {
        let ordinal = lock.withLock { count += 1; return count }
        started.signal()
        if blocksFirstScan && ordinal == 1 { gate.wait() }
        return result
    }
    func waitUntilStarted() -> Bool { started.wait(timeout: .now() + 2) == .success }
    func release() { gate.signal() }
}

private final class PresentationEmptyAccountManager: CodexAccountManaging, @unchecked Sendable {
    func loadState() throws -> CodexAccountState { CodexAccountState(currentAccount: nil, savedAccounts: [], activeSavedAccountID: nil) }
    func loadMetadataState() throws -> CodexAccountState { try loadState() }
    func saveCurrentAccount(label: String?) throws -> CodexAccountProfile { throw CodexAccountManagerError.accountNotFound }
    func switchToAccount(id: UUID) throws -> CodexAccountProfile { throw CodexAccountManagerError.accountNotFound }
    func authenticateManagedAccount(timeout: TimeInterval) async throws -> CodexAccountProfile { throw CodexAccountManagerError.accountNotFound }
    func removeAccount(id: UUID) throws {}
    func refreshSavedCurrentAccountIfPossible() throws -> CodexAccountProfile? { nil }
}

private final class ProgressTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
}

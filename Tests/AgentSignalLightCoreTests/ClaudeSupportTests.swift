import Foundation
import XCTest
import SwiftUI
import AppKit
import AgentSignalLightCore
@testable import AgentSignalLight

final class ClaudeSupportTests: XCTestCase {
    func testCredentialDecodingDoesNotRequireOrStoreRefreshToken() throws {
        let value = try ClaudeCredential.decode(Data(#"{"claudeAiOauth":{"accessToken":"fixture-a","expiresAt":2000000000000,"subscriptionType":"max","refreshToken":"unused-fixture"}}"#.utf8))
        XCTAssertEqual(value.accessToken, "fixture-a")
        XCTAssertEqual(value.plan, "max")
        XCTAssertEqual(value.expiresAt?.timeIntervalSince1970, 2_000_000_000)
        XCTAssertFalse(value.identity.contains("fixture"))
        XCTAssertThrowsError(try ClaudeCredential.decode(Data(#"{"OPENAI_API_KEY":"fixture"}"#.utf8)))
    }

    func testQuotaParsingPreservesAbsentWindowsAndRejectsBadNumbers() throws {
        let windows = try ClaudeUsageSnapshot.windows(from: Data(#"{"five_hour":null,"seven_day":{"utilization":75.5,"resets_at":"2026-09-12T10:20:30.123Z"},"seven_day_opus":{"utilization":true},"seven_day_sonnet":{"utilization":101}}"#.utf8))
        XCTAssertEqual(windows.map(\.id), ["seven_day"])
        XCTAssertEqual(windows.first?.usedPercent, 75.5)
        XCTAssertNotNil(windows.first?.resetsAt)
        XCTAssertThrowsError(try ClaudeUsageSnapshot.windows(from: Data(#"{"five_hour":{"utilization":false}}"#.utf8)))
        XCTAssertThrowsError(try ClaudeUsageSnapshot.windows(from: Data("{}".utf8)))
    }

    func testOAuthRequestsUseSameCredentialAndCorrectExtraUsageUnits() async throws {
        let service = ClaudeUsageService { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-a")
            XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
            let text = request.url!.lastPathComponent == "profile"
                ? #"{"account":{"email":"fixture@example.invalid"},"organization":{"name":"Fixture Org"}}"#
                : #"{"five_hour":{"utilization":0},"extra_usage":{"is_enabled":true,"used_credits":123,"monthly_limit":5000,"currency":"eur"}}"#
            return (Data(text.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let result = try await service.fetch(.init(accessToken: "fixture-a", expiresAt: nil, plan: "pro"))
        XCTAssertEqual(result.email, "fixture@example.invalid")
        XCTAssertEqual(result.extraUsed, 1.23)
        XCTAssertEqual(result.extraLimit, 50)
        XCTAssertEqual(result.extraCurrency, "EUR")
        XCTAssertEqual(result.windows.first?.usedPercent, 0)
    }

    func testExtraUsageRejectsBooleansAndNegativeAmounts() async throws {
        let service = ClaudeUsageService { request in
            let data = Data(#"{"five_hour":{"utilization":12},"extra_usage":{"is_enabled":true,"used_credits":true,"monthly_limit":-100}}"#.utf8)
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let result = try await service.fetch(.init(accessToken: "fixture", expiresAt: nil, plan: nil))
        XCTAssertNil(result.extraUsed)
        XCTAssertNil(result.extraLimit)
        XCTAssertEqual(result.extraCurrency, "USD")
    }

    func testRateLimitIsCredentialScopedAndCannotBeBypassedByRefresh() async throws {
        let counter = RequestCounter()
        let service = ClaudeUsageService { request in
            await counter.increment()
            let limited = request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-a"
            return (Data(#"{"five_hour":{"utilization":20}}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: limited ? 429 : 200, httpVersion: nil,
                                    headerFields: ["Retry-After":"600"])!)
        }
        let now = Date(timeIntervalSince1970: 1_000)
        for _ in 0..<2 {
            do { _ = try await service.fetch(.init(accessToken: "fixture-a", expiresAt: nil, plan: nil), now: now); XCTFail("Expected rate limit") }
            catch ClaudeSupportError.rateLimited(let until) { XCTAssertEqual(until, now.addingTimeInterval(600)) }
        }
        let requests = await counter.value
        XCTAssertEqual(requests, 1)
        _ = try await service.fetch(.init(accessToken: "fixture-b", expiresAt: nil, plan: nil), now: now)
        let total = await counter.value
        XCTAssertEqual(total, 3)
    }

    func testExpiredCredentialDoesNotMakeNetworkRequest() async throws {
        let service = ClaudeUsageService { _ in XCTFail("Expired token sent"); throw ClaudeSupportError.invalidResponse }
        do {
            _ = try await service.fetch(.init(accessToken: "fixture", expiresAt: .distantPast, plan: nil))
            XCTFail("Expected login requirement")
        } catch { XCTAssertEqual(error as? ClaudeSupportError, .loginRequired) }
    }

    func testSwapParsingRejectsUnknownSchemaBooleanSlotAndDuplicateSlots() throws {
        let row = #"{"number":1,"email":"fixture@example.invalid","organizationName":"","active":true,"usageStatus":"ok","usage":{"fiveHour":{"pct":20}}}"#
        let valid = "{\"schemaVersion\":1,\"activeAccountNumber\":1,\"accounts\":[\(row)]}"
        XCTAssertEqual(try ClaudeSwapListParser.parse(Data(valid.utf8)).accounts.first?.fiveHour?.usedPercent, 20)
        // The source parser validates all top-level and account fields; malformed inputs never activate slots.
        XCTAssertThrowsError(try ClaudeSwapListParser.parse(Data(valid.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2").utf8)))
        XCTAssertThrowsError(try ClaudeSwapListParser.parse(Data(valid.replacingOccurrences(of: "\"number\":1", with: "\"number\":true").utf8)))
        XCTAssertThrowsError(try ClaudeSwapListParser.parse(Data("{\"schemaVersion\":1,\"activeAccountNumber\":1,\"accounts\":[\(row),\(row)]}".utf8)))
    }

    func testSwitchParserValidatesTargetAndSchema() throws {
        let data = Data(#"{"schemaVersion":1,"switched":true,"from":{"number":1},"to":{"number":2},"reason":"manual"}"#.utf8)
        XCTAssertEqual(try ClaudeSwapSwitchParser.parse(data).toAccountNumber, 2)
        XCTAssertThrowsError(try ClaudeSwapSwitchParser.parse(Data(#"{"schemaVersion":1,"switched":true,"from":null,"to":{"number":true},"reason":"manual"}"#.utf8)))
    }

    func testCommandTimeoutAndArgumentBoundaries() throws {
        let data = try ClaudeCommandRunner.run(URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["%s", "literal $(touch forbidden); space"])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "literal $(touch forbidden); space")
        XCTAssertThrowsError(try ClaudeCommandRunner.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], timeout: 0.1)) {
            XCTAssertEqual($0 as? ClaudeSupportError, .timedOut)
        }
    }

    func testHistoryUsesIsolatedClaudeRootsAndCache() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("claude-history-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("projects/project")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let now = Date()
        let timestamp = ISO8601DateFormatter().string(from: now)
        let line = "{\"type\":\"assistant\",\"timestamp\":\"\(timestamp)\",\"sessionId\":\"fixture\",\"requestId\":\"request\",\"message\":{\"id\":\"m1\",\"model\":\"claude-sonnet-4-5-20250929\",\"usage\":{\"input_tokens\":100,\"output_tokens\":50}}}\n"
        let file = sessions.appendingPathComponent("session.jsonl")
        try line.write(to: file, atomically: true, encoding: .utf8)
        let report = try ClaudeSupportModel.scanHistory(roots: [root.appendingPathComponent("projects")], cacheRoot: root.appendingPathComponent("cache"), now: now)
        XCTAssertEqual(report.summary?.totalTokens, 150)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), line)
    }

    func testHistoryInvalidRootDoesNotCommitEmptyCache() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("claude-failure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let invalid = root.appendingPathComponent("projects")
        try Data("not a directory".utf8).write(to: invalid)
        XCTAssertThrowsError(try ClaudeSupportModel.scanHistory(roots: [invalid], cacheRoot: root.appendingPathComponent("cache")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("cache/claude-v1.json").path))
    }

    @MainActor
    func testHistoryProgressEndsOnSuccessAndFailure() async throws {
        for fails in [false, true] {
            let suite = "claude-progress-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let started = expectation(description: "scan started")
            let gate = DispatchSemaphore(value: 0)
            defer { gate.signal() }
            let model = ClaudeSupportModel(defaults: defaults, readCredentials: { _ in
                XCTFail("History must not read credentials")
                throw ClaudeSupportError.loginRequired
            }, historyLoader: {
                started.fulfill()
                guard gate.wait(timeout: .now() + 5) == .success else { throw ClaudeSupportError.timedOut }
                if fails { throw ClaudeSupportError.commandFailed }
                return CostUsageDailyReport(data: [], summary: nil)
            })
            model.refresh(force: true)
            await fulfillment(of: [started], timeout: 2)
            XCTAssertTrue(model.isHistoryScanning)
            gate.signal()
            for _ in 0..<200 where model.isRefreshing { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertFalse(model.isRefreshing)
            XCTAssertFalse(model.isHistoryScanning)
            XCTAssertEqual(model.historyIssue != nil, fails)
            XCTAssertEqual(model.historyUpdatedAt != nil, !fails)
        }
    }

    @MainActor
    func testHistoryProgressClearsWhenScanIsInvalidated() async throws {
        let suite = "claude-progress-reset-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let started = expectation(description: "scan started")
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let model = ClaudeSupportModel(defaults: defaults, historyLoader: {
            started.fulfill()
            _ = gate.wait(timeout: .now() + 5)
            return CostUsageDailyReport(data: [], summary: nil)
        })
        model.refresh(force: true)
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(model.isHistoryScanning)
        model.resetIdentity()
        XCTAssertFalse(model.isHistoryScanning)
        XCTAssertFalse(model.isRefreshing)
        gate.signal()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(model.historyUpdatedAt)
    }

    @MainActor
    func testUsageSettingsNavigationRepeatsAndPreservesProvider() {
        let navigation = UsageMenuNavigation()
        navigation.openSettings(for: .claude)
        let first = navigation.request?.id
        XCTAssertEqual(navigation.provider, .claude)
        XCTAssertEqual(navigation.request?.provider, .claude)
        navigation.openSettings(for: .claude)
        XCTAssertNotEqual(first, navigation.request?.id)
        navigation.openSettings(for: .codex)
        XCTAssertEqual(navigation.request?.provider, .codex)
    }

    @MainActor
    func testClaudeViewRendersWithIsolatedFixtures() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("claude-render-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "claude-render-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("zh-Hans", forKey: "appLanguage")
        defaults.set("dark", forKey: "appTheme")
        defaults.set("off", forKey: "codexOpenAICookieMode")
        defaults.set(true, forKey: "claude.credentialConsent")
        let service = ClaudeUsageService { request in
            let text = request.url!.lastPathComponent == "profile"
                ? #"{"account":{"email":"demo@example.invalid"}}"#
                : #"{"five_hour":{"utilization":42,"resets_at":"2026-09-06T08:00:00Z"},"seven_day":{"utilization":65,"resets_at":"2026-09-12T08:00:00Z"}}"#
            return (Data(text.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let previewDays = (0..<30).map { offset -> CostUsageDailyReport.Entry in
            let day = Calendar.current.date(byAdding: .day, value: -offset, to: Date())!
            let tokens = (offset % 7 == 0 ? 3_000_000 : 100_000) * (1 + offset % 4)
            return .init(date: CostUsageLocalDay.key(from: day, calendar: .current),
                         inputTokens: nil, outputTokens: nil, totalTokens: tokens,
                         costUSD: Double(tokens) / 100_000, modelsUsed: ["claude-sonnet-4-6"],
                         modelBreakdowns: [.init(modelName: "claude-sonnet-4-6", costUSD: nil, totalTokens: tokens)])
        }
        let support = ClaudeSupportModel(defaults: defaults, service: service,
            readCredentials: { _ in .init(accessToken: "fixture", expiresAt: nil, plan: "Max") },
            historyLoader: { CostUsageDailyReport(data: previewDays, summary: nil) })
        support.refresh(force: true)
        for _ in 0..<200 where support.isRefreshing { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(support.snapshot?.windows.count, 2)
        let model = MenuBarStatusModel(
            store: SignalStateStore(stateFileURL: root.appendingPathComponent("state.json")),
            userDefaults: defaults, startsMonitoring: false, codexAccountManager: ClaudePreviewAccountManager(),
            codexUsageSnapshotStore: CodexAccountUsageSnapshotStore(fileURL: root.appendingPathComponent("usage.json")),
            codexTokenActivityScanner: CodexTokenActivityScanner(sessionRootURLs: [], cacheURL: root.appendingPathComponent("token.json"), costUsageCacheRootURL: root.appendingPathComponent("cost")),
            performsAccountSwitchBackgroundRefreshes: false)
        _ = NSApplication.shared
        var routedProviders: [UsageMenuNavigation.Provider] = []
        let nativeAccounts = MenuUsageSummaryView.nativeAccountMenuItem(model: model, claude: support) {
            routedProviders.append($0)
        }
        let groups = try XCTUnwrap(nativeAccounts.submenu).items
        XCTAssertEqual(groups.count, 2)
        for group in groups {
            let actions = try XCTUnwrap(group.submenu)
            actions.performActionForItem(at: actions.numberOfItems - 1)
        }
        XCTAssertEqual(routedProviders, [.codex, .claude])
        let navigation = UsageMenuNavigation()
        navigation.provider = .claude
        let nativeItem = MenuUsageSummaryView.nativeMenuItem(model: model, claude: support,
                                                            navigation: navigation, onOpenSettings: { _ in })
        let nativeHost = try XCTUnwrap(nativeItem.view)
        let detailHost = NSHostingView(rootView: MenuBarPanelView(model: model, claudeSupport: support,
                                                                 usageNavigation: navigation))
        func containsScrollView(_ view: NSView) -> Bool {
            view is NSScrollView || view.subviews.contains(where: containsScrollView)
        }
        for (name, menuHost) in [("native", nativeHost), ("detailed", detailHost as NSView)] {
            let size = menuHost.fittingSize
            XCTAssertEqual(size.width, 360, accuracy: 1)
            XCTAssertGreaterThan(size.height, 200)
            XCTAssertLessThan(size.height, 720, "\(name) menu should fit without an embedded scroll view")
            menuHost.setFrameSize(size)
            let menuWindow = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                      styleMask: [.titled], backing: .buffered, defer: false)
            menuWindow.contentView = menuHost
            menuWindow.appearance = NSAppearance(named: .darkAqua)
            menuHost.wantsLayer = true
            menuHost.layer?.backgroundColor = NSColor(white: 0.16, alpha: 1).cgColor
            menuWindow.orderFront(nil)
            try await Task.sleep(for: .milliseconds(150))
            menuHost.layoutSubtreeIfNeeded()
            XCTAssertFalse(containsScrollView(menuHost), "\(name) menu must not contain scrolling content")
            XCTAssertEqual(menuHost.frame.height, menuHost.fittingSize.height, accuracy: 1)
            if let directory = ProcessInfo.processInfo.environment["ASB_MENU_LAYOUT_PREVIEW"],
               let bitmap = menuHost.bitmapImageRepForCachingDisplay(in: menuHost.bounds) {
                menuHost.cacheDisplay(in: menuHost.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(
                    to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
            }
            menuWindow.orderOut(nil)
        }
        let host = NSHostingView(rootView: ScrollView {
            ClaudeUsageSettingsView(model: model, support: support, onConnections: {}).padding(16)
        }.frame(width: 540, height: 820))
        host.frame = NSRect(x: 0, y: 0, width: 540, height: 820)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.appearance = NSAppearance(named: .aqua)
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(500))
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.width, 0)
        XCTAssertGreaterThan(host.fittingSize.height, 0)
        window.orderOut(nil)
    }

    @MainActor
    func testModelDiscardsResponseAfterExternalCredentialChange() async throws {
        let identity = CredentialSequence()
        let finished = expectation(description: "history completion")
        let suite = "claude-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "claude.credentialConsent")
        let service = ClaudeUsageService { request in
            (Data(#"{"five_hour":{"utilization":20}}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let model = ClaudeSupportModel(defaults: defaults, service: service, readCredentials: { _ in identity.next() }, historyLoader: {
            finished.fulfill()
            return CostUsageDailyReport(data: [], summary: nil)
        })
        model.refresh(force: true)
        for _ in 0..<100 where model.isRefreshing { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(model.snapshot)
        XCTAssertTrue(model.quotaIssue?.contains("Account changed") == true)
        // Identity mismatch returns before local history; no unrelated source is fetched as a fallback.
        finished.isInverted = true
        await fulfillment(of: [finished], timeout: 0.05)
    }
}

private actor RequestCounter {
    var value = 0
    func increment() { value += 1 }
}
private final class CredentialSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> ClaudeCredential {
        lock.lock(); defer { lock.unlock() }
        count += 1
        return .init(accessToken: count == 1 ? "fixture-old" : "fixture-new", expiresAt: nil, plan: nil)
    }
}

private final class ClaudePreviewAccountManager: CodexAccountManaging, @unchecked Sendable {
    func loadState() throws -> CodexAccountState { .init(currentAccount: nil, savedAccounts: [], activeSavedAccountID: nil) }
    func loadMetadataState() throws -> CodexAccountState { try loadState() }
    func saveCurrentAccount(label: String?) throws -> CodexAccountProfile { throw CodexAccountManagerError.accountNotFound }
    func switchToAccount(id: UUID) throws -> CodexAccountProfile { throw CodexAccountManagerError.accountNotFound }
    func authenticateManagedAccount(timeout: TimeInterval) async throws -> CodexAccountProfile { throw CodexAccountManagerError.accountNotFound }
    func removeAccount(id: UUID) throws {}
    func refreshSavedCurrentAccountIfPossible() throws -> CodexAccountProfile? { nil }
}

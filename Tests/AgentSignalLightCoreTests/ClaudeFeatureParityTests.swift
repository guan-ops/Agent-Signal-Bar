import AppKit
import SwiftUI
import XCTest
import AgentSignalLightCore
@testable import AgentSignalLight

final class ClaudeFeatureDataTests: XCTestCase {
    func testExtraOnlyAndDistinctCreditPools() throws {
        let value = try ClaudeUsageSnapshot.parseUsage(Data(#"{"extra_usage":{"is_enabled":true,"used_credits":125,"monthly_limit":1000,"currency":"EUR"},"iguana_necktie":{"remaining_dollars":25,"limit_dollars":50,"used_dollars":25}}"#.utf8), credentialID: "fixture", plan: nil, now: Date())
        XCTAssertTrue(value.windows.isEmpty)
        XCTAssertEqual(value.extraUsed, 1.25)
        XCTAssertEqual(value.extraLimit, 10)
        XCTAssertEqual(value.extraRemainingPercent, 87.5)
        XCTAssertEqual(value.cloudCredits?.remaining, 25)
        XCTAssertNil(value.prepaidBalance)
        XCTAssertThrowsError(try ClaudeUsageSnapshot.windows(from: Data("{}".utf8)))
        XCTAssertThrowsError(try ClaudeUsageSnapshot.parseUsage(Data("{}".utf8), credentialID: "fixture", plan: nil, now: Date()))
        XCTAssertNil(ClaudeCloudCredits.parse(["remaining_dollars": true, "limit_dollars": 50, "used_dollars": 25]))
        XCTAssertNil(ClaudeCloudCredits.parse(["remaining_dollars": -1]))
        XCTAssertFalse(try XCTUnwrap(ClaudeCloudCredits.parse(["remaining_dollars": 0, "locked_reason": "unavailable"])).isAvailable(at: Date()))
    }
    func testResetInventoryFiltersEligibilityExpiryAndMalformedFlags() throws {
        let now = Date(), iso = ISO8601DateFormatter()
        let valid: [String: Any] = ["paused": false, "resets_left": 2, "resets_total": 3, "ends_at": iso.string(from: now.addingTimeInterval(60))]
        let expired: [String: Any] = ["paused": false, "resets_left": 1, "ends_at": iso.string(from: now.addingTimeInterval(-60))]
        let invalid: [String: Any] = ["paused": 0, "resets_left": 4]
        let result = try XCTUnwrap(ClaudeResetInventory.parse(["eligible": true, "grants": [valid, expired, invalid]], now: now))
        XCTAssertEqual(result.available(at: now).count, 2)
        XCTAssertTrue(result.available(at: now.addingTimeInterval(61)).isEmpty)
        XCTAssertNil(ClaudeResetInventory.parse(["eligible": 1, "grants": [valid]], now: now))
    }
    func testSubscriptionStatusDateOnlyAndCancellation() throws {
        func fields(_ value: [String: Any]) -> [String: Any] {
            ["next_charge_at": NSNull(), "next_charge_date": NSNull(), "plan_ending_at": NSNull(), "plan_ending_before": NSNull()].merging(value) { _, new in new }
        }
        let date = try XCTUnwrap(ClaudeSubscriptionDates.parse(fields(["status": "active", "next_charge_date": "2026-12-01"])))
        XCTAssertTrue(date.isDateOnly)
        XCTAssertEqual(date.renewsAt, ClaudeUsageSnapshot.date("2026-12-01T00:00:00Z"))
        XCTAssertNil(ClaudeSubscriptionDates.parse(fields(["status": "canceled", "next_charge_date": "2026-12-01"])))
        XCTAssertNil(ClaudeSubscriptionDates.parse(["status": "unknown", "next_charge_date": "2026-12-01"]))
        let end = try XCTUnwrap(ClaudeSubscriptionDates.parse(fields(["status": "active", "next_charge_date": "2026-12-01", "plan_ending_before": "2026-11-30"])))
        XCTAssertNil(end.renewsAt); XCTAssertNotNil(end.expiresAt)
    }
    func testCLIParsingANSIModelWindowsAndIncompletePanels() throws {
        let now = Date()
        let text = "\u{1B}[2J\u{1B}[HCurrent session\n32% used\nResets in 2h 30m\nCurrent week (all models)\n40% left\nResets Friday (Pacific/Auckland)\nCurrent week (Sonnet)\n20% used\nWhat's contributing to your limits usage?\nCurrent session\n99% used\n"
        let value = try ClaudeCLIUsageProbe.parse(text, owner: "fixture", now: now)
        XCTAssertEqual(value.windows.map(\.usedPercent), [32, 60, 20])
        XCTAssertEqual(value.windows.first?.resetsAt, now.addingTimeInterval(9000))
        XCTAssertNil(value.windows[1].resetsAt)
        XCTAssertTrue(value.windows[1].resetDescription?.contains("Friday") == true)
        XCTAssertEqual(value.freshnessInterval, 900)
        for bad in ["Current session\nRefreshing…\n", "Current session\n32% used\nCurrent week (all models)\n", "Please run /login"] {
            XCTAssertThrowsError(try ClaudeCLIUsageProbe.parse(bad, owner: "fixture"))
        }
    }
    func testRoutinesAliasesShareOneStableWindow() throws {
        let keys = ["seven_day_routines", "seven_day_claude_routines", "claude_routines", "routines", "routine", "seven_day_cowork", "cowork"]
        for key in keys {
            let data = try JSONSerialization.data(withJSONObject: [key: ["utilization": 42]])
            let windows = try ClaudeUsageSnapshot.windows(from: data)
            XCTAssertEqual(windows.map(\.id), ["claude-routines"])
            XCTAssertEqual(windows.first?.usedPercent, 42)
        }
        let duplicate = try JSONSerialization.data(withJSONObject: ["seven_day_routines": ["utilization": 42], "cowork": ["utilization": 99]])
        XCTAssertEqual(try ClaudeUsageSnapshot.windows(from: duplicate).count, 1)
        XCTAssertNil(ClaudeSubscriptionDates.parse(["status": "active", "next_charge_date": "2026-12-01"]))
    }
    func testCookieNormalizationRejectsInjectionAndCopiesOnlySession() {
        XCTAssertEqual(ClaudeWebCookie.normalized("Cookie: unrelated=x; sessionKey=sk-ant-fixture; a=b"), "sessionKey=sk-ant-fixture")
        for value in ["sessionKey=foo\r\nX-Test: bad", "sessionKey=foo\tbar", "sessionKey=☃", "sessionKey=\"abc\"", "other=value"] {
            XCTAssertNil(ClaudeWebCookie.normalized(value))
        }
    }
    func testWebBillingSourcesUnitsAndOptionalFailures() async throws {
        let http = FeatureHTTP()
        let service = ClaudeWebUsageService { request in try http.respond(request) }
        let organizations = try await service.organizations(cookie: "sessionKey=fixture")
        let org = try XCTUnwrap(organizations.first)
        let quota = try await service.fetch(cookie: "sessionKey=fixture", organization: org)
        XCTAssertEqual(quota.windows.count, 2)
        XCTAssertNil(quota.prepaidBalance)
        let value = await service.enrich(quota, cookie: "sessionKey=fixture", organization: org)
        XCTAssertEqual(value.prepaidBalance, 12.34); XCTAssertEqual(value.prepaidCurrency, "EUR")
        XCTAssertEqual(value.extraUsed, 2); XCTAssertEqual(value.extraLimit, 20)
        XCTAssertEqual(value.cloudCredits?.remaining, 25)
        XCTAssertNotNil(value.accountKey); XCTAssertNotNil(value.subscription)
        XCTAssertTrue(http.requests.allSatisfy { $0.url?.scheme == "https" && $0.url?.host == "claude.ai" && $0.value(forHTTPHeaderField: "Cookie") == "sessionKey=fixture" && $0.value(forHTTPHeaderField: "Authorization") == nil })
        http.mode = .optionalFailure
        let partial = await service.enrich(quota, cookie: "sessionKey=fixture", organization: org)
        XCTAssertEqual(partial.windows, quota.windows); XCTAssertNil(partial.prepaidBalance)
    }
    func testWebRateLimitAndUnsupportedOptInRetry() async throws {
        let http = FeatureHTTP(); http.mode = .unsupportedOptIn
        let service = ClaudeWebUsageService { request in try http.respond(request) }
        _ = try await service.fetch(cookie: "sessionKey=fixture", organization: FeatureHTTP.organization)
        XCTAssertEqual(http.requests.count, 2)
        XCTAssertNotNil(http.requests[0].url?.query); XCTAssertNil(http.requests[1].url?.query)
        let limited = FeatureHTTP(); limited.mode = .rateLimit
        let blocked = ClaudeWebUsageService { request in try limited.respond(request) }
        for _ in 0..<2 {
            do { _ = try await blocked.fetch(cookie: "sessionKey=fixture", organization: FeatureHTTP.organization); XCTFail("Must back off") }
            catch ClaudeSupportError.rateLimited { } catch { XCTFail("Unexpected \(error)") }
        }
        XCTAssertEqual(limited.requests.count, 1)
    }
    func testCoworkAuditDiscoveryAliasDedupAndIncompleteRecovery() throws {
        let root = URL(fileURLWithPath: "/private/tmp/claude-cowork-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let desktop = root.appendingPathComponent("Library/Application Support/Claude/local-agent-mode-sessions/org/session")
        let projects = root.appendingPathComponent(".claude/projects")
        for dir in [desktop, projects] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        let audit = desktop.appendingPathComponent("audit.jsonl"), native = projects.appendingPathComponent("native.jsonl")
        let now = Date(), timestamp = ISO8601DateFormatter().string(from: now)
        func row(_ message: String, session: String = "s1", request: String? = nil, incomplete: Bool = false) -> String {
            var object: [String: Any] = ["type": "assistant", "timestamp": timestamp, "session_id": session,
                "message": ["id": message, "model": "claude-sonnet-4-6", "stop_reason": incomplete ? NSNull() : "end_turn",
                    "usage": ["input_tokens": 100, "output_tokens": incomplete ? 0 : 20]]]
            if let request { object["request_id"] = request }
            return String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)! + "\n"
        }
        try (row("a") + row("pending", incomplete: true)).write(to: audit, atomically: true, encoding: .utf8)
        try (row("a") + row("a", session: "s2") + row("a", request: "r1") + row("a", request: "r2")).write(to: native, atomically: true, encoding: .utf8)
        let outside = root.appendingPathComponent("outside.jsonl")
        try row("excluded").write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: projects.appendingPathComponent("nested.jsonl"), withDestinationURL: outside)
        let roots = ClaudeHistoryRoots.projects(environment: [:], home: root)
        XCTAssertTrue(roots.contains { $0.resolvingSymlinksInPath().path == audit.resolvingSymlinksInPath().path }, "\(roots.map(\.path)); expected \(audit.path)")
        var options = CostUsageScanner.Options(); options.claudeProjectsRoots = roots; options.cacheRoot = root.appendingPathComponent("cache"); options.refreshMinIntervalSeconds = 0
        func scan() throws -> CostUsageDailyReport { try CostUsageScanner.loadDailyReportCancellable(provider: .claude, since: now, until: now, now: now, options: options, checkCancellation: {}) }
        var result = try scan()
        XCTAssertEqual(result.summary?.totalTokens, 480)
        XCTAssertEqual(result.data.first?.incompleteRequestCount, 1)
        XCTAssertEqual(ClaudeHistorySummary(days: result.data, updatedAt: now, now: now).month.incompleteRequests, 1)
        let handle = try FileHandle(forWritingTo: audit); try handle.seekToEnd(); try handle.write(contentsOf: Data(row("pending").utf8)); try handle.close()
        result = try scan()
        XCTAssertEqual(result.summary?.totalTokens, 600)
        XCTAssertEqual(result.data.first?.incompleteRequestCount, 0)
        // Complete cumulative chunks win even if a later proxy copy is incomplete.
        let again = try FileHandle(forWritingTo: audit); try again.seekToEnd(); try again.write(contentsOf: Data(row("pending", incomplete: true).utf8)); try again.close()
        XCTAssertEqual(try scan().summary?.totalTokens, 600)
        let incompleteRoot = root.appendingPathComponent("incomplete"); try FileManager.default.createDirectory(at: incompleteRoot, withIntermediateDirectories: true)
        try row("only", incomplete: true).write(to: incompleteRoot.appendingPathComponent("only.jsonl"), atomically: true, encoding: .utf8)
        options.claudeProjectsRoots = [incompleteRoot]; options.forceRescan = true
        result = try scan()
        XCTAssertNil(result.summary?.totalTokens); XCTAssertNil(result.summary?.totalCostUSD)
        XCTAssertNil(result.data.first?.modelBreakdowns?.first?.totalTokens)
        XCTAssertEqual(result.data.first?.incompleteRequestCount, 1)
        XCTAssertNil(ClaudeHistorySummary(days: result.data, updatedAt: now, now: now).month.tokens)
    }
    func testPassivePTYUsesOwnedDirectoryAndDisabledHooksTools() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/claude-probe-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let binary = root.appendingPathComponent("fixture-cli")
        let script = """
        #!/bin/sh
        printf '%s\\n' "$@" > args.txt
        read command
        if [ "$command" = /usage ]; then
            printf 'Current session\\n22%% used\\nResets in 2h\\n'
        fi
        """
        try script.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let result = try await ClaudeCLIUsageProbe.run(binary, owner: "fixture", timeout: 5, directory: root)
        XCTAssertEqual(result.windows.first?.usedPercent, 22)
        let args = try String(contentsOf: root.appendingPathComponent("args.txt"), encoding: .utf8)
        XCTAssertTrue(args.contains("--strict-mcp-config")); XCTAssertTrue(args.contains("disableAllHooks")); XCTAssertTrue(args.contains("--allowed-tools\n\n"))
        XCTAssertFalse(args.contains("--dangerously"))
    }
}

@MainActor
final class ClaudeFeatureModelTests: XCTestCase {
    func testQuotaWarningsRecoveryHistoryReloadAndSourceIsolation() throws {
        let root = URL(fileURLWithPath: "/private/tmp/claude-quota-history-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ClaudeQuotaHistory(fileURL: root), prefs = ClaudeQuotaHistory.Preferences(low: true, reset: true)
        let now = Date(), reset = now.addingTimeInterval(3600)
        func value(_ used: Double, _ offset: Double, source: String = "Claude Code OAuth", account: String? = nil, credential: String = "fixture") -> ClaudeUsageSnapshot {
            .init(credentialID: credential, email: nil, organization: nil, plan: nil,
                  windows: [.init(id: "five_hour", title: "5h", usedPercent: used, resetsAt: reset)], extraUsed: nil, extraLimit: nil,
                  extraCurrency: "USD", updatedAt: now.addingTimeInterval(offset), source: source, accountKey: account)
        }
        func record(_ v: ClaudeUsageSnapshot) -> [ClaudeQuotaNotice] { store.record(v, preferences: prefs, now: v.updatedAt) }
        XCTAssertTrue(record(value(70, 0)).isEmpty)
        XCTAssertEqual(record(value(81, 301)).map(\.kind), [.low])
        XCTAssertTrue(record(value(82, 602)).isEmpty)
        XCTAssertEqual(record(value(100, 903)).map(\.kind), [.low])
        XCTAssertEqual(record(value(20, 1204)).map(\.kind), [.restored])
        XCTAssertEqual(record(value(85, 1505)).map(\.kind), [.low])
        XCTAssertTrue(record(value(99, 1806, source: "Claude Web")).isEmpty)
        XCTAssertEqual(ClaudeQuotaHistory(fileURL: root).samples(snapshot: value(85, 1505), windowID: "five_hour").count, 6)
        _ = record(value(85, 1505, account: "verified"))
        XCTAssertEqual(record(value(95, 2107, account: "verified", credential: "rotated")).map(\.kind), [.low])
        XCTAssertTrue(record(value(99, 2408, credential: "cli-unverified-test")).isEmpty)
        let data = try String(contentsOf: root, encoding: .utf8)
        XCTAssertFalse(data.contains("rotated")); XCTAssertFalse(data.contains("fixture"))
    }
    func testForecastRequiresRecentSameCycleConsumptionAndWarnsOnce() {
        let now = Date(), reset = now.addingTimeInterval(3600)
        let samples: [ClaudeQuotaSample] = (0...3).map { (step: Int) -> ClaudeQuotaSample in
            let offset: TimeInterval = Double(step - 3) * 300
            let usedPercent: Double = Double(40 + step * 10)
            return ClaudeQuotaSample(date: now.addingTimeInterval(offset), usedPercent: usedPercent, resetsAt: reset)
        }
        XCTAssertFalse(ClaudeQuotaHistory.forecast(samples, now: now)!.willLastToReset)
        XCTAssertNil(ClaudeQuotaHistory.forecast(Array(samples.suffix(2)), now: now))
        XCTAssertNil(ClaudeQuotaHistory.forecast(samples, now: now.addingTimeInterval(901)))
        XCTAssertNil(ClaudeQuotaHistory.forecast(samples + [.init(date: now, usedPercent: 10, resetsAt: reset)], now: now))
        let store = ClaudeQuotaHistory(), prefs = ClaudeQuotaHistory.Preferences(predicted: true)
        var notices: [ClaudeQuotaNotice] = []
        for sample in samples {
            let value = ClaudeUsageSnapshot(credentialID: "fixture", email: nil, organization: nil, plan: nil,
                windows: [.init(id: "five_hour", title: "5h", usedPercent: sample.usedPercent, resetsAt: reset)],
                extraUsed: nil, extraLimit: nil, extraCurrency: "USD", updatedAt: sample.date)
            notices += store.record(value, preferences: prefs, now: sample.date)
        }
        XCTAssertEqual(notices.map(\.kind), [.predicted])
    }
    func testWebOptInOrganizationsIdentityAndForget() async throws {
        let f = try FeatureFixture(); defer { f.clean() }
        f.support.refresh(force: true); try await f.wait()
        XCTAssertTrue(f.http.requests.isEmpty); XCTAssertEqual(f.secrets.readCount, 0)
        f.http.mode = .multipleOrganizations
        f.support.saveWebCookie("sessionKey=fixture"); try await f.wait()
        XCTAssertNil(f.support.snapshot); XCTAssertEqual(f.support.webOrganizations.count, 2)
        XCTAssertTrue(f.support.quotaIssue?.contains("组织") == true)
        f.support.webOrganizationID = FeatureHTTP.organization.id
        f.support.refresh(force: true); try await f.wait()
        XCTAssertEqual(f.support.snapshot?.source, "Claude Web")
        XCTAssertEqual(f.support.snapshot?.prepaidBalance, 12.34)
        XCTAssertFalse(f.defaults.dictionaryRepresentation().description.contains("sessionKey=fixture"))
        f.support.usageSource = .oauth
        XCTAssertNil(f.support.snapshot)
        f.support.forgetWebCookie()
        XCTAssertNil(try f.secrets.string(for: "session")); XCTAssertFalse(f.support.webEnabled)
    }
    func testQuotaPublishesBeforeOptionalProfileAndSourceChangeDiscardsLateEnrichment() async throws {
        let suite = "claude-fast-quota-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "claude.credentialConsent")
        let service = ClaudeUsageService { request in
            if request.url?.lastPathComponent == "profile" { try? await Task.sleep(for: .milliseconds(400)) }
            let data = request.url?.lastPathComponent == "profile"
                ? Data(#"{"account":{"email":"fixture@example.invalid","uuid":"account"},"organization":{"uuid":"org"}}"#.utf8)
                : Data(#"{"five_hour":{"utilization":35}}"#.utf8)
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let model = ClaudeSupportModel(defaults: defaults, service: service,
            readCredentials: { _ in .init(accessToken: "fixture", expiresAt: nil, plan: "max") }, historyLoader: { _ in .init(data: [], summary: nil) })
        model.refresh(force: true)
        for _ in 0..<100 where model.snapshot == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(model.snapshot?.windows.first?.usedPercent, 35)
        XCTAssertTrue(model.isRefreshing); XCTAssertNil(model.snapshot?.email)
        model.usageSource = .web
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertNil(model.snapshot); XCTAssertFalse(model.isRefreshing)
        model.resetIdentity()
    }
    func testAutomaticRateLimitDoesNotSwitchSources() async throws {
        let suite = "claude-rate-limit-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "claude.credentialConsent"); defaults.set("automatic", forKey: "claude.providerSource")
        defaults.set(true, forKey: "claude.cliFallback"); defaults.set("/bin/echo", forKey: "claude.executablePath")
        let service = ClaudeUsageService { request in
            (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "120"])!)
        }
        let model = ClaudeSupportModel(defaults: defaults, service: service,
            readCredentials: { _ in .init(accessToken: "fixture", expiresAt: nil, plan: nil) }, historyLoader: { _ in .init(data: [], summary: nil) },
            cliProbe: { _, _ in XCTFail("Rate limits must not trigger CLI fallback"); throw ClaudeSupportError.commandFailed })
        model.refresh(force: true)
        for _ in 0..<100 where model.isRefreshing { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(model.snapshot); XCTAssertTrue(model.quotaIssue?.contains("rate limited") == true)
        model.resetIdentity()
    }
    func testProfileEnrichmentDoesNotDuplicateLowQuotaNotice() {
        let now = Date(), store = ClaudeQuotaHistory(), prefs = ClaudeQuotaHistory.Preferences(low: true)
        func snapshot(_ used: Double, _ offset: Double, account: String? = nil) -> ClaudeUsageSnapshot {
            .init(credentialID: "fixture", email: nil, organization: nil, plan: nil,
                windows: [.init(id: "five_hour", title: "5h", usedPercent: used, resetsAt: nil)], extraUsed: nil, extraLimit: nil,
                extraCurrency: "USD", updatedAt: now.addingTimeInterval(offset), accountKey: account)
        }
        let baseline = snapshot(50, 0), low = snapshot(85, 301), enriched = snapshot(85, 301, account: "verified")
        XCTAssertTrue(store.record(baseline, preferences: prefs, now: baseline.updatedAt).isEmpty)
        XCTAssertEqual(store.record(low, preferences: prefs, now: low.updatedAt).count, 1)
        XCTAssertTrue(store.record(enriched, preferences: prefs, now: enriched.updatedAt).isEmpty)
    }
    func testAccountComparisonAndObservedForecastRender() async throws {
        let history = ClaudeQuotaHistory(), now = Date(), org = FeatureHTTP.organization.id
        for (offset, used) in [(-900.0, 15.0), (-600, 20), (-300, 25)] {
            let value = ClaudeUsageSnapshot(credentialID: ClaudeValue.key("sessionKey=fixture|" + org), email: nil, organization: nil, plan: nil,
                windows: [.init(id: "five_hour", title: "5 小时 / 5 hours", usedPercent: used, resetsAt: now.addingTimeInterval(3600))],
                extraUsed: nil, extraLimit: nil, extraCurrency: "USD", updatedAt: now.addingTimeInterval(offset), source: "Claude Web",
                accountKey: ClaudeValue.key("web|fixture-account|" + org))
            _ = history.record(value, preferences: .init(), now: value.updatedAt)
        }
        let f = try FeatureFixture(historyStore: history); defer { f.clean() }
        let binary = f.root.appendingPathComponent("fixture-swap")
        let reset = ISO8601DateFormatter().string(from: now.addingTimeInterval(3600))
        let accounts: [String: Any] = ["schemaVersion": 1, "activeAccountNumber": 1, "accounts": [
            ["number": 1, "email": "first@example.invalid", "active": true, "usageStatus": "ok", "usage": ["fiveHour": ["pct": 75, "resetsAt": reset], "sevenDay": ["pct": 80]]],
            ["number": 2, "email": "second@example.invalid", "active": false, "usageStatus": "ok", "usage": ["fiveHour": ["pct": 15, "resetsAt": reset], "sevenDay": ["pct": 30]]]]]
        let payload = String(decoding: try JSONSerialization.data(withJSONObject: accounts), as: UTF8.self)
        try ("#!/bin/sh\nprintf '%s' " + ClaudeCommandRunner.shellQuote(payload) + "\n").write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        f.support.swapPath = binary.path; f.support.swapEnabled = true
        f.support.saveWebCookie("sessionKey=fixture"); try await f.wait()
        XCTAssertEqual(f.support.accounts.count, 2); XCTAssertEqual(f.support.bestAvailableAccount, 2)
        XCTAssertGreaterThanOrEqual(f.support.quotaSamples(windowID: "five_hour").count, 3)
        XCTAssertNotNil(f.support.quotaForecast(windowID: "five_hour"))
        f.support.inspectedAccountNumber = 2; f.support.hidePersonalInfo = true
        XCTAssertEqual(f.support.accountLabel(f.support.accounts[1]), "Account #2")
        let model = f.model(); model.setAppTheme(.light)
        _ = NSApplication.shared
        let host = NSHostingView(rootView: VStack(alignment: .leading, spacing: 20) {
            ClaudeAccountsOverviewView(model: model, support: f.support)
            Divider()
            ClaudeQuotaHistoryView(model: model, support: f.support)
        }.padding(20).frame(width: 440, height: 510, alignment: .top).preferredColorScheme(.light))
        host.frame = NSRect(x: 0, y: 0, width: 440, height: 510)
        host.wantsLayer = true; host.layer?.backgroundColor = NSColor(white: 0.96, alpha: 1).cgColor
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; window.appearance = NSAppearance(named: .aqua); window.orderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(600)); host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: bitmap)
        XCTAssertGreaterThan(bitmap.pixelsWide, 0)
        if let path = ProcessInfo.processInfo.environment["ASB_CLAUDE_FEATURE_PREVIEW"] {
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path).appendingPathComponent("claude-accounts-forecast.png"))
        }
    }
    func testExtraOnlyBadgePrepaidAndSharedUIRender() async throws {
        let f = try FeatureFixture(); defer { f.clean() }
        f.http.mode = .extraOnly
        f.support.saveWebCookie("sessionKey=fixture"); try await f.wait()
        let model = f.model(); model.selectSignalLightProvider(.claude)
        XCTAssertEqual(model.claudeFloatingRemainingPercent(), 90)
        model.selectClaudeFloatingQuotaWindow("prepaid")
        XCTAssertNil(model.claudeFloatingRemainingPercent())
        XCTAssertTrue(model.claudeFloatingBadgeText.contains("12"))
        model.selectClaudeFloatingQuotaWindow("extra_usage")
        XCTAssertEqual(model.claudeFloatingRemainingPercent(), 90)
        f.support.hidePersonalInfo = true
        _ = NSApplication.shared
        for dark in [false, true] {
            model.setAppTheme(dark ? .dark : .light)
            let host = NSHostingView(rootView: HStack(alignment: .top) {
                ScrollView { ClaudeUsageSettingsView(model: model, support: f.support, onConnections: {}) }.frame(width: 490)
                VStack { ClaudeFloatingQuotaPopoverView(model: model); ClaudeSourceSettingsView(model: model, support: f.support) }.frame(width: 340)
            }.padding(12).frame(width: 870, height: 900).preferredColorScheme(dark ? .dark : .light))
            host.frame = NSRect(x: 0, y: 0, width: 870, height: 900)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            host.wantsLayer = true; host.layer?.backgroundColor = NSColor(white: dark ? 0.12 : 0.94, alpha: 1).cgColor
            window.contentView = host; window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua); window.orderFront(nil)
            defer { window.orderOut(nil) }
            try await Task.sleep(for: .milliseconds(500)); host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: bitmap)
            XCTAssertGreaterThan(bitmap.pixelsWide, 0)
            if let path = ProcessInfo.processInfo.environment["ASB_CLAUDE_FEATURE_PREVIEW"] {
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path).appendingPathComponent("claude-features-\(dark ? "dark" : "light").png"))
            }
        }
    }
}

private final class FeatureHTTP: @unchecked Sendable {
    enum Mode { case normal, optionalFailure, unsupportedOptIn, rateLimit, multipleOrganizations, extraOnly }
    static let organization = ClaudeWebOrganization(id: "11111111-1111-1111-1111-111111111111", name: "Fixture workspace")
    private let lock = NSLock()
    private var storedMode: Mode = .normal, captured: [URLRequest] = []
    var mode: Mode { get { lock.lock(); defer { lock.unlock() }; return storedMode } set { lock.lock(); storedMode = newValue; lock.unlock() } }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return captured }
    func respond(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        lock.lock(); captured.append(request); let mode = storedMode; lock.unlock()
        let path = request.url!.lastPathComponent
        var status = 200, object: Any = [String: String]()
        if mode == .rateLimit { status = 429 }
        else if mode == .unsupportedOptIn && request.url?.query != nil { status = 400 }
        else if mode == .optionalFailure && path != "usage" { status = 503 }
        else if path == "organizations" {
            object = [["uuid": Self.organization.id, "name": Self.organization.name]] + (mode == .multipleOrganizations ? [["uuid": "22222222-2222-2222-2222-222222222222", "name": "Second"]] : [])
        } else if path == "usage" {
            var root: [String: Any] = ["iguana_necktie": ["remaining_dollars": 25], "extra_usage": ["is_enabled": true, "used_credits": 200, "monthly_limit": 2000]]
            if mode != .extraOnly {
                let reset = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
                root["five_hour"] = ["utilization": 30, "resets_at": reset]; root["seven_day"] = ["utilization": 50, "resets_at": reset]
            }
            object = root
        } else if path == "account" { object = ["uuid": "fixture-account", "email_address": "fixture@example.invalid"] }
        else if path == "overage_spend_limit" { object = ["is_enabled": true, "used_credits": 200, "monthly_credit_limit": 2000, "currency": "USD"] }
        else if path == "credits" { object = ["amount": 1234, "currency": "EUR"] }
        else if path == "subscription_details" { object = ["status": "active", "next_charge_date": "2026-12-01", "next_charge_at": NSNull(), "plan_ending_at": NSNull(), "plan_ending_before": NSNull()] }
        return (try JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Retry-After": "120"])!)
    }
}
private final class FeatureSecrets: SecretStoring, @unchecked Sendable {
    private let lock = NSLock(); private var storage: [String: Data] = [:]; private var reads = 0
    var readCount: Int { lock.lock(); defer { lock.unlock() }; return reads }
    func data(for key: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; reads += 1; return storage[key] }
    func string(for key: String) throws -> String? { try data(for: key).flatMap { String(data: $0, encoding: .utf8) } }
    func set(_ data: Data, for key: String) throws { lock.lock(); defer { lock.unlock() }; storage[key] = data }
    func set(_ string: String, for key: String) throws { try set(Data(string.utf8), for: key) }
    func delete(key: String) throws { lock.lock(); defer { lock.unlock() }; storage.removeValue(forKey: key) }
}
@MainActor
private struct FeatureFixture {
    let root: URL, suite: String, defaults: UserDefaults, http: FeatureHTTP, secrets: FeatureSecrets, support: ClaudeSupportModel
    init(historyStore: ClaudeQuotaHistory? = nil) throws {
        root = URL(fileURLWithPath: "/private/tmp/claude-features-\(UUID())"); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "claude-features-\(UUID())"; defaults = UserDefaults(suiteName: suite)!
        defaults.set("en", forKey: "appLanguage"); defaults.set(false, forKey: "isFloatingSignalSoundEnabled")
        http = FeatureHTTP(); secrets = FeatureSecrets(); let http = http
        support = ClaudeSupportModel(defaults: defaults, readCredentials: { _ in throw ClaudeSupportError.loginRequired },
            historyLoader: { _ in .init(data: [], summary: nil) }, webService: .init { try http.respond($0) }, webSecrets: secrets,
            browserImporter: { _ in throw ClaudeSupportError.webLoginRequired }, quotaHistory: historyStore ?? .init(), notificationHandler: { _, _ in })
    }
    func wait() async throws { for _ in 0..<500 where support.isRefreshing { try await Task.sleep(for: .milliseconds(10)) }; XCTAssertFalse(support.isRefreshing) }
    func clean() { support.resetIdentity(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    func model() -> MenuBarStatusModel {
        MenuBarStatusModel(store: SignalStateStore(stateFileURL: root.appendingPathComponent("state.json")), userDefaults: defaults,
            startsMonitoring: false, codexAccountManager: FeatureEmptyAccounts(), codexUsageSnapshotStore: .init(fileURL: root.appendingPathComponent("usage.json")),
            codexTokenActivityScanner: CodexTokenActivityScanner(sessionRootURLs: [], cacheURL: root.appendingPathComponent("tokens.json"), costUsageCacheRootURL: root.appendingPathComponent("cost")),
            performsAccountSwitchBackgroundRefreshes: false, claudeSupport: support)
    }
}
private final class FeatureEmptyAccounts: CodexAccountManaging, @unchecked Sendable {
    func loadState() throws -> CodexAccountState { .init(currentAccount: nil, savedAccounts: [], activeSavedAccountID: nil) }
    func saveCurrentAccount(label: String?) throws -> CodexAccountProfile { throw CodexAccountManagerError.accountNotFound }
    func switchToAccount(id: UUID) throws -> CodexAccountProfile { throw CodexAccountManagerError.accountNotFound }
    func authenticateManagedAccount(timeout: TimeInterval) async throws -> CodexAccountProfile { throw CodexAccountManagerError.accountNotFound }
    func removeAccount(id: UUID) throws {}
    func refreshSavedCurrentAccountIfPossible() throws -> CodexAccountProfile? { nil }
}

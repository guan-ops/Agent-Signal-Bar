import AppKit
import SwiftUI
import XCTest
import AgentSignalLightCore
@testable import AgentSignalLight

@MainActor
final class ClaudeFloatingParityTests: XCTestCase {
    func testSharedProviderStateNeverFallsBackToCodexTokensOrQuota() async throws {
        let f = try ClaudeFloatingFixture(); defer { f.clean() }
        let model = f.model()
        model.updateLatestAgentTokenUsage(AgentTokenUsage(totalTokens: 99_000))
        model.selectSignalLightProvider(.claude)
        XCTAssertTrue(model.claudeSupport === f.support)
        XCTAssertEqual(model.floatingQuotaContent, .claude)
        XCTAssertNil(model.floatingUsageTokens(for: .today))
        XCTAssertNil(model.claudeFloatingRemainingPercent())
        try await f.refresh()
        XCTAssertEqual(model.floatingUsageTokens(for: .today), 1_000)
        XCTAssertEqual(model.claudeFloatingRemainingPercent(), 58)
        model.selectClaudeFloatingQuotaWindow("seven_day")
        XCTAssertEqual(model.claudeFloatingRemainingPercent(), 35)
        XCTAssertEqual(f.defaults.string(forKey: "claude.floatingQuotaWindow"), "seven_day")
        model.selectSignalLightProvider(.codex)
        XCTAssertEqual(model.floatingUsageProviderName, "Codex")
        model.selectSignalLightProvider(.claude)
        XCTAssertEqual(model.claudeFloatingRemainingPercent(), 35)
        model.isMonitoringPaused = true
        XCTAssertNil(model.floatingQuotaContent)
    }

    func testUnknownZeroAndPartialCostRemainDistinct() async throws {
        let f = try ClaudeFloatingFixture(); defer { f.clean() }
        let model = f.model(); model.selectSignalLightProvider(.claude)
        XCTAssertNil(model.floatingUsageTokens(for: .today))
        XCTAssertNil(model.floatingUsageCost(for: .today))
        try await f.refresh()
        XCTAssertEqual(model.floatingUsageTokens(for: .today), 1_000)
        XCTAssertEqual(model.floatingUsageCost(for: .today), 1.5)
        XCTAssertTrue(model.floatingUsageHasUnpricedCost(for: .today))
        XCTAssertTrue(model.floatingUsageCostText(for: .today).contains("≥"))
        XCTAssertEqual(model.floatingUsageTokens(for: .last30Days), 1_600)
        model.setFloatingSignalTokenBadgeWindow(.last30Days)
        XCTAssertEqual(f.defaults.string(forKey: "floatingSignalTokenBadgeWindow"), "last-30-days")
        XCTAssertEqual(model.floatingUsageCost(for: .last30Days), 2.5)
        model.costCurrency.select("NZD")
        let convertedCost = model.floatingUsageCostText(for: .last30Days)
        XCTAssertTrue(convertedCost.contains("NZD") && convertedCost.contains("4.00"), convertedCost)
        XCTAssertEqual(model.floatingUsageCost(for: .last30Days), 2.5, "Currency selection only changes display")
        XCTAssertTrue(model.claudeFloatingExtraUsageText?.contains("EUR") == true)
        XCTAssertFalse(model.claudeFloatingExtraUsageText?.contains("USD") == true)
        XCTAssertNil(model.claudeFloatingRemainingPercent(now: Date().addingTimeInterval(301)))
        f.support.stopCredentialRead()
        XCTAssertNil(model.claudeFloatingRemainingPercent())
        XCTAssertEqual(model.floatingUsageTokens(for: .today), 1_000, "Device history survives sign-out")
        let empty = ClaudeHistorySummary(days: [], updatedAt: Date())
        XCTAssertEqual(empty.today.tokens, 0)
        XCTAssertEqual(empty.today.costUSD, 0)
    }

    func testPausedMonitoringStopsClaudeRefreshesUntilResumed() async throws {
        let f = try ClaudeFloatingFixture(); defer { f.clean() }
        let model = f.model(); model.selectSignalLightProvider(.claude)
        model.setMonitoringPaused(true)
        // Menu, settings and refresh buttons all call refresh directly.
        f.support.refresh(force: true)
        XCTAssertFalse(f.support.isRefreshing)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(f.http.requestCount, 0)
        XCTAssertNil(f.support.snapshot)
        XCTAssertTrue(f.support.days.isEmpty)

        model.setMonitoringPaused(false)
        try await f.refresh()
        let requests = f.http.requestCount
        XCTAssertGreaterThan(requests, 0)
        XCTAssertNotNil(f.support.snapshot)

        // Pausing cancels an in-flight refresh but keeps the last results,
        // and resuming does not wait out the 60-second throttle.
        f.support.refresh(force: true)
        XCTAssertTrue(f.support.isRefreshing)
        model.setMonitoringPaused(true)
        XCTAssertFalse(f.support.isRefreshing)
        XCTAssertNotNil(f.support.snapshot)
        model.setMonitoringPaused(false)
        f.support.refresh()
        XCTAssertTrue(f.support.isRefreshing)
        for _ in 0..<300 where f.support.isRefreshing { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(f.support.isRefreshing)
    }

    func testOpeningTokenPanelKeepsTheRefreshThrottle() async throws {
        let f = try ClaudeFloatingFixture(); defer { f.clean() }
        let model = f.model(); model.selectSignalLightProvider(.claude)
        try await f.refresh()
        let requests = f.http.requestCount
        XCTAssertGreaterThan(requests, 0)
        for _ in 0..<3 {
            model.refreshFloatingUsageForPanel()
            XCTAssertFalse(f.support.isRefreshing, "Opening the panel inside the refresh interval must not refetch")
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(f.http.requestCount, requests)
    }

    func testFailedRefreshRetainsLabeledSnapshotButHidesLivePercentage() async throws {
        let f = try ClaudeFloatingFixture(); defer { f.clean() }
        let model = f.model(); model.selectSignalLightProvider(.claude)
        try await f.refresh()
        f.http.setFailure(true)
        try await f.refresh()
        XCTAssertNotNil(f.support.snapshot)
        XCTAssertNotNil(f.support.quotaIssue)
        XCTAssertNil(model.claudeFloatingRemainingPercent())
        XCTAssertEqual(model.floatingUsageTokens(for: .today), 1_000)
        XCTAssertTrue(model.claudeFloatingQuotaMessage.contains("Previous snapshot"))
    }

    func testSwitchClearsAllSurfacesBeforeNewCredentialsArePublished() async throws {
        let f = try ClaudeFloatingFixture(withSwap: true); defer { f.clean() }
        let model = f.model(); model.selectSignalLightProvider(.claude)
        try await f.refresh()
        XCTAssertEqual(f.support.accounts.count, 2)
        XCTAssertEqual(model.claudeFloatingRemainingPercent(), 58)
        f.support.switchAccount(2)
        XCTAssertTrue(f.support.isSwitching)
        XCTAssertNil(model.claudeFloatingRemainingPercent())
        XCTAssertEqual(model.floatingUsageTokens(for: .today), 1_000)
        for _ in 0..<400 where f.support.isSwitching || f.support.isRefreshing { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(f.support.switchIssue)
        XCTAssertEqual(f.support.snapshot?.email, "second@example.invalid")
        XCTAssertEqual(model.claudeFloatingRemainingPercent(), 14)
        XCTAssertEqual(f.support.accounts.first?.number, 2)
    }

    func testAccountLabelsAndActivationPolicyMatchSourceCapabilities() throws {
        func row(_ n: Int, _ status: ClaudeSwapUsageStatus, active: Bool = false) -> ClaudeSwapAccountRow {
            .init(number: n, email: "same@example.invalid", organizationName: "Workspace", isActive: active,
                  usageStatus: status, fiveHour: nil, sevenDay: nil)
        }
        let rows = [row(1, .ok), row(2, .ok)]
        XCTAssertNotEqual(ClaudeAccountPresentation.label(rows[0], among: rows), ClaudeAccountPresentation.label(rows[1], among: rows))
        let longLabel = String(repeating: "long-name", count: 8)
        XCTAssertNotEqual(ClaudeAccountPresentation.menuLabel(longLabel + " · #1"), ClaudeAccountPresentation.menuLabel(longLabel + " · #2"))
        XCTAssertEqual(ClaudeAccountPresentation.menuLabel(longLabel + " · #1").count, 30)
        XCTAssertTrue(ClaudeAccountPresentation.canActivate(row(1, .unavailable)))
        XCTAssertTrue(ClaudeAccountPresentation.canActivate(row(1, .apiKey)))
        XCTAssertTrue(ClaudeAccountPresentation.canActivate(row(1, .foreignCredential, active: true)))
        XCTAssertFalse(ClaudeAccountPresentation.canActivate(row(1, .ok, active: true)))
        for status in [ClaudeSwapUsageStatus.tokenExpired, .reloginRequired, .noCredentials, .keychainUnavailable, .unknown("future")] {
            XCTAssertFalse(ClaudeAccountPresentation.canActivate(row(1, status)))
        }
        let list = try ClaudeSwapListParser.parse(Data(#"{"schemaVersion":1,"activeAccountNumber":null,"supportsAccountSwitching":false,"accounts":[]}"#.utf8))
        XCTAssertFalse(list.supportsAccountSwitching)
    }

    func testScopedWeeklyWindowsUseStableIDsAndRejectUnrelatedOrDuplicateWindows() throws {
        func limit(_ name: String, id: String, group: String = "weekly", kind: String = "weekly_scoped") -> [String: Any] {
            ["kind":kind,"group":group,"percent":42,"scope":["model":["id":id,"display_name":name]]]
        }
        let limits = [limit("Example",id:"model-example"), limit("All models",id:"all-models"),
                      limit("Example",id:"model-example"), limit("Daily",id:"daily",group:"daily")]
        func windows(_ values: [[String: Any]]) throws -> [ClaudeQuotaWindow] {
            try ClaudeUsageSnapshot.windows(from: JSONSerialization.data(withJSONObject: ["limits":values]))
        }
        XCTAssertEqual(try windows(limits).map(\.id), ["scoped-model-example"])
        XCTAssertEqual(try windows(limits.reversed()).map(\.id), ["scoped-model-example"])
        let mixed: [Any] = [NSNull(), "malformed", limits[0]]
        let parsed = try ClaudeUsageSnapshot.windows(from: JSONSerialization.data(withJSONObject: ["limits": mixed]))
        XCTAssertEqual(parsed.map(\.id), ["scoped-model-example"])
    }

    func testEveryReturnedQuotaWindowIsSelectableAndRestored() async throws {
        let f = try ClaudeFloatingFixture(); defer { f.clean() }
        let model = f.model(); model.selectSignalLightProvider(.claude)
        try await f.refresh()
        let windows = try XCTUnwrap(f.support.snapshot?.windows)
        XCTAssertEqual(windows.count, 6)
        for window in windows {
            model.selectClaudeFloatingQuotaWindow(window.id)
            XCTAssertEqual(model.claudeFloatingRemainingPercent(), 100 - window.usedPercent)
            XCTAssertFalse(model.localizedClaudeText(window.title).contains("天"))
        }
        model.selectClaudeFloatingQuotaWindow("missing")
        XCTAssertEqual(model.claudeFloatingQuotaWindowID, windows.last?.id)
        XCTAssertEqual(f.model().claudeFloatingQuotaWindowID, windows.last?.id)
        model.setFloatingSignalQuotaBadgeEnabled(false)
        XCTAssertNil(model.floatingQuotaContent)
        model.setFloatingSignalQuotaBadgeEnabled(true)
        XCTAssertEqual(model.floatingQuotaContent, .claude)
    }

    func testClaudeBadgeControlsOpenBothPanelsAndPersistDragging() async throws {
        let f = try ClaudeFloatingFixture(); defer { f.clean() }
        let model = f.model(); model.selectSignalLightProvider(.claude)
        model.setFloatingSignalInfoBadgeEnabled(false)
        try await f.refresh()
        _ = NSApplication.shared
        let host = NSHostingView(rootView: FloatingSignalPanelView(model: model, animationClock: model.animationClock,
            hide: {}, smaller: {}, larger: {}, toggleLayout: {}, toggleSound: {},
            previewCompletionSound: {}, previewWaitingSound: {}, resizeFromHandle: { _, _ in }, openSettings: {}))
        host.frame = NSRect(x: 0, y: 0, width: 350, height: 220)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; window.orderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(300))
        func controls(_ view: NSView) -> [FloatingSignalInfoBadgeDragView] {
            (view as? FloatingSignalInfoBadgeDragView).map { [$0] } ?? view.subviews.flatMap(controls)
        }
        let badges = controls(host)
        XCTAssertEqual(badges.count, 2)
        var opened = Set<String>()
        for badge in badges {
            badge.onClick?()
            try await Task.sleep(for: .milliseconds(150))
            opened.formUnion(NSApp.windows.filter { $0.isVisible && $0.title.hasPrefix("Floating Signal ") }.map(\.title))
            badge.onClick?()
            try await Task.sleep(for: .milliseconds(150))
        }
        XCTAssertEqual(opened, ["Floating Signal Quota", "Floating Signal Token Usage"])
        let before = [model.floatingSignalQuotaBadgeCorner, model.floatingSignalTokenBadgeCorner]
        let drag = CGSize(width: 400, height: 400)
        let badge = try XCTUnwrap(badges.first)
        badge.onDragChanged?(drag)
        badge.onDragEnded?(drag)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNotEqual([model.floatingSignalQuotaBadgeCorner, model.floatingSignalTokenBadgeCorner], before)
        XCTAssertEqual(f.defaults.string(forKey: "floatingSignalQuotaBadgeCorner"), model.floatingSignalQuotaBadgeCorner.rawValue)
        XCTAssertNotEqual(model.floatingSignalQuotaBadgeCorner, model.floatingSignalTokenBadgeCorner)
    }

    func testBothProvidersUseSameFloatingRowsAndBoundedMenus() async throws {
        let f = try ClaudeFloatingFixture(withSwap: true); defer { f.clean() }
        f.support.hidePersonalInfo = true
        let model = f.model(); try await f.refresh()
        let now = Date(), reset = now.addingTimeInterval(3600)
        let codex = AgentQuotaStatus(remainingPercent: 58, usedPercent: 42, limitName: "Codex quota", source: .oauth,
            windowMinutes: 300, resetsAt: reset, updatedAt: now,
            primary: .init(remainingPercent: 58, usedPercent: 42, windowMinutes: 300, resetsAt: reset),
            secondary: .init(remainingPercent: 35, usedPercent: 65, windowMinutes: 10080, resetsAt: reset))
        _ = NSApplication.shared
        func capture(_ host: NSView, _ name: String) throws {
            host.layoutSubtreeIfNeeded()
            func invalidate(_ view: NSView) {
                view.needsDisplay = true
                view.layer?.setNeedsDisplay()
                view.subviews.forEach(invalidate)
            }
            invalidate(host)
            host.display()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let directory = ProcessInfo.processInfo.environment["ASB_MENU_FLOAT_PREVIEW"] {
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
            }
        }
        func click(_ window: NSWindow, _ point: NSPoint) {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { window.sendEvent(event) }
            }
        }
        for dark in [false, true] {
            model.setAppTheme(dark ? .dark : .light)
            for provider in [SignalLightProvider.codex, .claude] {
                model.selectSignalLightProvider(provider)
                model.setFloatingSignalQuotaBadgeWindow(.fiveHours)
                model.selectClaudeFloatingQuotaWindow("five_hour")
                let content: FloatingQuotaContent = provider == .claude ? .claude : .codex(codex)
                let host = NSHostingView(rootView: FloatingSignalQuotaPopoverView(model: model, quota: content))
                let size = host.fittingSize
                XCTAssertEqual(size.width, 302, accuracy: 1)
                XCTAssertGreaterThan(size.height, 120); XCTAssertLessThanOrEqual(size.height, 566)
                host.setFrameSize(size)
                let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
                window.contentView = host; window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua); window.makeKeyAndOrderFront(nil)
                defer { window.orderOut(nil) }
                try await Task.sleep(for: .milliseconds(350))
                let name = "\(provider.rawValue.lowercased())-quota-\(dark ? "dark" : "light")"
                try capture(host, name)
                // The two providers share the header and first two selection rows (UI 2.0 rows
                // carry a quota meter, so the second row starts lower than before).
                click(window, NSPoint(x: 260, y: size.height - 172))
                try await Task.sleep(for: .milliseconds(150))
                if provider == .claude { XCTAssertEqual(model.claudeFloatingQuotaWindowID, "seven_day") }
                else { XCTAssertEqual(model.floatingSignalQuotaBadgeWindow, .weekly) }
                // cacheDisplay may capture only changed SwiftUI layers on its second call.
                // The click above is tested in place; render its resulting selection in a fresh host for evidence.
                let selectedHost = NSHostingView(rootView: FloatingSignalQuotaPopoverView(model: model, quota: content))
                selectedHost.setFrameSize(size); window.contentView = selectedHost
                try await Task.sleep(for: .milliseconds(200))
                try capture(selectedHost, name + "-weekly")
                window.orderOut(nil)

                model.setFloatingSignalTokenBadgeWindow(.today)
                let tokenHost = NSHostingView(rootView: FloatingSignalTokenPopoverView(model: model))
                tokenHost.setFrameSize(tokenHost.fittingSize)
                XCTAssertEqual(tokenHost.frame.width, 266, accuracy: 1)
                let tokenWindow = NSWindow(contentRect: tokenHost.frame, styleMask: [.titled], backing: .buffered, defer: false)
                tokenWindow.contentView = tokenHost; tokenWindow.makeKeyAndOrderFront(nil)
                try await Task.sleep(for: .milliseconds(300))
                click(tokenWindow, NSPoint(x: 220, y: tokenHost.frame.height - 100))
                try await Task.sleep(for: .milliseconds(150))
                XCTAssertEqual(model.floatingSignalTokenBadgeWindow, .last30Days)
                try capture(tokenHost, "\(provider.rawValue.lowercased())-tokens-\(dark ? "dark" : "light")")
                tokenWindow.orderOut(nil)

                let nav = UsageMenuNavigation(); nav.provider = provider == .claude ? .claude : .codex
                var routed: [UsageMenuNavigation.Provider] = []
                let native = MenuUsageSummaryView.nativeMenuItem(model: model, claude: f.support, navigation: nav) { routed.append($0) }
                let nativeHost = try XCTUnwrap(native.view)
                let detailed = NSHostingView(rootView: MenuUsageSummaryView(model: model, claude: f.support, navigation: nav, onOpenSettings: { routed.append($0) }).padding(10).frame(width: 360))
                for (kind, menuHost) in [("native", nativeHost), ("detailed", detailed as NSView)] {
                    menuHost.setFrameSize(menuHost.fittingSize)
                    let menuWindow = NSWindow(contentRect: menuHost.frame, styleMask: [.titled], backing: .buffered, defer: false)
                    menuWindow.contentView = menuHost; menuWindow.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    menuHost.wantsLayer = true; menuHost.layer?.backgroundColor = NSColor(white: dark ? 0.16 : 0.96, alpha: 1).cgColor
                    menuWindow.orderFront(nil)
                    try await Task.sleep(for: .milliseconds(300)); menuHost.layoutSubtreeIfNeeded(); menuHost.setFrameSize(menuHost.fittingSize)
                    XCTAssertEqual(menuHost.frame.width, 360, accuracy: 1)
                    XCTAssertLessThan(menuHost.frame.height, 720, "Inline Claude account settings must not inflate menu height")
                    try capture(menuHost, "\(provider.rawValue.lowercased())-\(kind)-\(dark ? "dark" : "light")")
                    menuWindow.orderOut(nil)
                }
                let accountMenu = try XCTUnwrap(MenuUsageSummaryView.nativeAccountMenuItem(model: model, claude: f.support) { routed.append($0) }.submenu)
                for group in accountMenu.items { if let submenu = group.submenu { submenu.performActionForItem(at: submenu.numberOfItems - 1) } }
                XCTAssertEqual(routed.suffix(2), [.codex, .claude])
            }
        }
    }

    func testClaudeBadgeAndQuotaPanelRenderInBothThemes() async throws {
        let f = try ClaudeFloatingFixture(); defer { f.clean() }
        let model = f.model(); model.selectSignalLightProvider(.claude)
        try await f.refresh()
        _ = NSApplication.shared
        for theme in [AppTheme.light, .dark] {
            model.setAppTheme(theme)
            let content = HStack(alignment: .top, spacing: 12) {
              VStack(spacing: 12) {
                FloatingSignalPanelView(model: model, animationClock: model.animationClock,
                    hide: {}, smaller: {}, larger: {}, toggleLayout: {}, toggleSound: {},
                    previewCompletionSound: {}, previewWaitingSound: {}, resizeFromHandle: { _, _ in }, openSettings: {})
                FloatingSignalTokenPopoverView(model: model)
              }
                ClaudeFloatingQuotaPopoverView(model: model)
            }.padding(16).frame(width: 660, height: 660).preferredColorScheme(theme == .dark ? .dark : .light)
            let host = NSHostingView(rootView: content)
            host.frame = NSRect(x: 0, y: 0, width: 660, height: 660)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            window.appearance = NSAppearance(named: theme == .dark ? .darkAqua : .aqua)
            host.wantsLayer = true
            host.layer?.backgroundColor = NSColor(white: theme == .dark ? 0.12 : 0.94, alpha: 1).cgColor
            window.orderFront(nil)
            defer { window.orderOut(nil) }
            try await Task.sleep(for: .milliseconds(600))
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            XCTAssertGreaterThan(bitmap.pixelsWide, 0)
            // UI 2.0 panels follow the appearance, so count pixels that clearly differ from the
            // backdrop (panel text and meters) instead of assuming a black panel.
            let backdrop: CGFloat = theme == .dark ? 0.12 : 0.94
            var panelPixels = 0
            for y in stride(from: bitmap.pixelsHigh / 2, to: bitmap.pixelsHigh * 4 / 5, by: 2) {
                for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.5 else { continue }
                    if abs(color.redComponent - backdrop) > 0.35 { panelPixels += 1 }
                }
            }
            XCTAssertGreaterThan(panelPixels, 40, "Quota panel must actually render, not only allocate a frame")
            if let path = ProcessInfo.processInfo.environment["ASB_CLAUDE_FLOATING_PREVIEW"] {
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path).appendingPathComponent("claude-floating-\(theme.rawValue).png"))
            }
        }
    }
}

@MainActor
private struct ClaudeFloatingFixture {
    let root: URL
    let defaults: UserDefaults
    let suite: String
    let http: ClaudeFloatingHTTP
    let support: ClaudeSupportModel
    init(withSwap: Bool = false) throws {
        root = URL(fileURLWithPath: "/private/tmp/claude-floating-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "claude-floating-\(UUID())"; defaults = UserDefaults(suiteName: suite)!
        defaults.set("en", forKey: "appLanguage"); defaults.set("off", forKey: "codexOpenAICookieMode")
        defaults.set(true, forKey: "claude.credentialConsent")
        defaults.set(true, forKey: "isFloatingSignalQuotaBadgeEnabled")
        defaults.set(true, forKey: "isFloatingSignalTokenBadgeEnabled")
        defaults.set(false, forKey: "isFloatingSignalSoundEnabled")
        let rates = CurrencyRateSnapshot(updatedAt: Date(), nextUpdateAt: Date().addingTimeInterval(86400),
                                         rates: ["USD": 1, "NZD": 1.6])
        defaults.set(try JSONEncoder().encode(rates), forKey: "costExchangeRates.v1")
        let marker = root.appendingPathComponent("switched")
        if withSwap {
            let binary = root.appendingPathComponent("fixture-cswap")
            let list1 = #"{"schemaVersion":1,"activeAccountNumber":1,"accounts":[{"number":1,"email":"first@example.invalid","active":true,"usageStatus":"ok"},{"number":2,"email":"second@example.invalid","active":false,"usageStatus":"ok"}]}"#
            let list2 = #"{"schemaVersion":1,"activeAccountNumber":2,"accounts":[{"number":1,"email":"first@example.invalid","active":false,"usageStatus":"ok"},{"number":2,"email":"second@example.invalid","active":true,"usageStatus":"ok"}]}"#
            let script = """
            #!/bin/sh
            if [ "$1" = "--list" ]; then
              if [ -f \(ClaudeCommandRunner.shellQuote(marker.path)) ]; then
                printf '%s' '\(list2)'
              else
                printf '%s' '\(list1)'
              fi
            elif [ "$1" = "--switch-to" ] && [ "$2" = "2" ]; then
              /bin/sleep 0.2
              /usr/bin/touch \(ClaudeCommandRunner.shellQuote(marker.path))
              printf '%s' '{"schemaVersion":1,"switched":true,"from":{"number":1},"to":{"number":2},"reason":"fixture"}'
            else
              exit 1
            fi
            """
            try script.write(to: binary, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
            defaults.set(true, forKey: "claude.swapEnabled"); defaults.set(binary.path, forKey: "claude.swapPath")
        }
        http = ClaudeFloatingHTTP()
        let serviceHTTP = http
        let service = ClaudeUsageService { request in try serviceHTTP.respond(request) }
        support = ClaudeSupportModel(defaults: defaults, service: service, readCredentials: { _ in
            .init(accessToken: FileManager.default.fileExists(atPath: marker.path) ? "fixture-second" : "fixture-first", expiresAt: nil, plan: "Max")
        }, historyLoader: { _ in
            .init(data: [.init(date: CostUsageLocalDay.key(from: Calendar.current.date(byAdding: .day, value: -1, to: Date())!),
                inputTokens: 500, outputTokens: 100, totalTokens: 600, costUSD: 1, modelsUsed: ["known"], modelBreakdowns: nil),
                .init(date: CostUsageLocalDay.key(from: Date()), inputTokens: nil, outputTokens: nil,
                totalTokens: 1_000, costUSD: 1.5, modelsUsed: ["fixture-model"], modelBreakdowns: [
                    .init(modelName: "known", costUSD: 1.5, totalTokens: 900),
                    .init(modelName: "unknown", costUSD: nil, totalTokens: 100)])], summary: nil)
        })
    }
    func model() -> MenuBarStatusModel {
        MenuBarStatusModel(store: SignalStateStore(stateFileURL: root.appendingPathComponent("state.json")), userDefaults: defaults,
            startsMonitoring: false, codexAccountManager: ClaudeFloatingEmptyAccounts(),
            codexUsageSnapshotStore: .init(fileURL: root.appendingPathComponent("usage.json")),
            codexRateLimitFetcher: .init(environment: ["CODEX_HOME": root.path]),
            codexTokenActivityScanner: CodexTokenActivityScanner(sessionRootURLs: [], cacheURL: root.appendingPathComponent("tokens.json"), costUsageCacheRootURL: root.appendingPathComponent("cost")),
            performsAccountSwitchBackgroundRefreshes: false, claudeSupport: support)
    }
    func refresh() async throws {
        support.refresh(force: true)
        for _ in 0..<300 where support.isRefreshing { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(support.isRefreshing)
    }
    func clean() { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
}
private final class ClaudeFloatingHTTP: @unchecked Sendable {
    private let lock = NSLock(); private var failed = false; private var requests = 0
    var requestCount: Int { lock.lock(); defer { lock.unlock() }; return requests }
    func setFailure(_ value: Bool) { lock.lock(); failed = value; lock.unlock() }
    func respond(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        lock.lock(); let failed = failed; requests += 1; lock.unlock()
        if failed { throw URLError(.notConnectedToInternet) }
        let second = request.value(forHTTPHeaderField: "Authorization")?.contains("fixture-second") == true
        let data: [String: Any]
        if request.url?.lastPathComponent == "profile" {
            data = ["account": ["email": second ? "second@example.invalid" : "first@example.invalid"]]
        } else {
            let reset = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
            data = ["five_hour": ["utilization": second ? 86 : 42, "resets_at": reset], "seven_day": ["utilization": 65, "resets_at": reset],
                    "seven_day_sonnet": ["utilization": 20, "resets_at": reset],
                    "seven_day_opus": ["utilization": 35, "resets_at": reset],
                    "seven_day_oauth_apps": ["utilization": 10, "resets_at": reset],
                    "limits": [["kind": "weekly_scoped", "group": "weekly", "percent": 50, "resets_at": reset,
                               "scope": ["model": ["id": "fixture-model", "display_name": "Fixture model"]]]],
                    "extra_usage": ["is_enabled": true, "used_credits": 125, "monthly_limit": 1000, "currency": "EUR"]]
        }
        return (try JSONSerialization.data(withJSONObject: data), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
private final class ClaudeFloatingEmptyAccounts: CodexAccountManaging, @unchecked Sendable {
    func loadState() throws -> CodexAccountState { .init(currentAccount: nil, savedAccounts: [], activeSavedAccountID: nil) }
    func saveCurrentAccount(label: String?) throws -> CodexAccountProfile { throw CodexAccountManagerError.accountNotFound }
    func switchToAccount(id: UUID) throws -> CodexAccountProfile { throw CodexAccountManagerError.accountNotFound }
    func authenticateManagedAccount(timeout: TimeInterval) async throws -> CodexAccountProfile { throw CodexAccountManagerError.accountNotFound }
    func removeAccount(id: UUID) throws {}
    func refreshSavedCurrentAccountIfPossible() throws -> CodexAccountProfile? { nil }
}

import AppKit
import SwiftUI
import XCTest
import AgentSignalLightCore
@testable import AgentSignalLight

@MainActor
final class UsageSettingsSharedUITests: XCTestCase {
    func testBothProvidersUseWorkingSharedDetailsAndCardGeometry() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/usage-shared-ui-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "usage-shared-ui-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        defaults.set("zh-Hans", forKey: "appLanguage")
        defaults.set(true, forKey: "claude.credentialConsent")
        defaults.set(root.path, forKey: CodexDataPaths.preferenceKey)
        defaults.set("/bin/echo", forKey: "claude.executablePath")
        defaults.set(false, forKey: "isFloatingSignalSoundEnabled")
        let support = ClaudeSupportModel(defaults: defaults, service: .init { request in
            let reset = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
            let body = request.url?.lastPathComponent == "profile"
                ? #"{"account":{"email":"fixture@example.invalid"}}"#
                : "{\"five_hour\":{\"utilization\":42,\"resets_at\":\"\(reset)\"},\"seven_day\":{\"utilization\":65,\"resets_at\":\"\(reset)\"}}"
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, readCredentials: { _ in .init(accessToken: "synthetic-ui", expiresAt: nil, plan: "Pro") },
            historyLoader: { _ in .init(data: [], summary: nil) })
        let model = MenuBarStatusModel(store: SignalStateStore(stateFileURL: root.appendingPathComponent("state.json")), userDefaults: defaults,
            startsMonitoring: false, codexAccountManager: SharedUIAccounts(root: root),
            codexUsageSnapshotStore: .init(fileURL: root.appendingPathComponent("usage.json")),
            codexCLIStatusProbe: SharedUIStatus(), codexRPCStatusProbe: SharedUIStatus(), codexServiceStatusFetcher: SharedUIStatus(),
            codexRateLimitFetcher: .init(environment: ["CODEX_HOME": root.path]),
            codexTokenActivityScanner: CodexTokenActivityScanner(sessionRootURLs: [], cacheURL: root.appendingPathComponent("token.json"), costUsageCacheRootURL: root.appendingPathComponent("cost")),
            performsAccountSwitchBackgroundRefreshes: false, claudeSupport: support)
        model.codexOpenAICookieMode = .off; model.codexUsageDataSource = .oauthAPI
        support.refresh(force: true)
        for _ in 0..<200 where support.isRefreshing { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(support.snapshot?.email, "fixture@example.invalid")
        _ = NSApplication.shared
        for dark in [false, true] {
            model.setAppTheme(dark ? .dark : .light)
            for provider in UsageMenuNavigation.Provider.allCases {
                let navigation = UsageMenuNavigation(); navigation.openSettings(for: provider)
                let host = NSHostingView(rootView: DebugWindowView(model: model, updater: SparkleUpdaterService(), claudeSupport: support, usageNavigation: navigation))
                host.frame = NSRect(x: 0, y: 0, width: SettingsWindowMetrics.width, height: SettingsWindowMetrics.height)
                let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
                window.contentView = host; window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.makeKeyAndOrderFront(nil)
                defer { window.orderOut(nil) }
                try await Task.sleep(for: .milliseconds(650)); host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                try capture(host, name: "\(provider.rawValue.lowercased())-\(dark ? "dark" : "light")")
                for _ in 0..<200 where model.isTokenActivityLoading { try await Task.sleep(for: .milliseconds(10)) }
                host.layoutSubtreeIfNeeded()
                let collapsedHeight = documentHeight(host)
                XCTAssertGreaterThan(collapsedHeight, 100)
                // The shared row is at the same location in both full settings pages.
                // Coordinates are in window points, from the inspected fixture captures. Aim well
                // inside the row: an always-visible scroller narrows the content by about 17pt.
                click(window, at: NSPoint(x: host.frame.width - 200, y: host.frame.height - 240))
                try await Task.sleep(for: .milliseconds(350)); host.layoutSubtreeIfNeeded()
                let expandedHeight = documentHeight(host)
                XCTAssertGreaterThan(expandedHeight, collapsedHeight + 50, "\(provider) must expand the mounted details state")
                try capture(host, name: "\(provider.rawValue.lowercased())-details-\(dark ? "dark" : "light")")
                click(window, at: NSPoint(x: host.frame.width - 200, y: host.frame.height - 240))
                try await Task.sleep(for: .milliseconds(350)); host.layoutSubtreeIfNeeded()
                XCTAssertEqual(documentHeight(host), collapsedHeight, accuracy: 2, "The same row must collapse again")
                window.orderOut(nil)
            }

        }
        support.resetIdentity()
    }

    private func documentHeight(_ view: NSView) -> CGFloat {
        let own = (view as? NSScrollView).flatMap { $0.frame.width > 300 ? $0.documentView?.frame.height : nil } ?? 0
        return max(own, view.subviews.map(documentHeight).max() ?? 0)
    }
    private func click(_ window: NSWindow, at point: NSPoint) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                window.sendEvent(event)
            }
        }
    }
    private func capture(_ host: NSView, name: String) throws {
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        if let directory = ProcessInfo.processInfo.environment["ASB_SHARED_UI_PREVIEW"] {
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
        }
    }
}

private struct SharedUIStatus: CodexCLIStatusProbing, CodexRPCStatusProbing, CodexServiceStatusFetching {
    func probeStatus() -> CodexCLIStatus { .init(versionText: "fixture", checkedAt: Date()) }
    func probeStatus() async -> CodexRPCStatus { .init(accountEmail: "fixture@example.invalid", accountPlanName: "Pro", rateLimitPlanName: "Pro", checkedAt: Date()) }
    func fetchStatus() async throws -> CodexServiceStatus { .init(indicator: .none, description: "Fixture", updatedAt: Date()) }
}
private final class SharedUIAccounts: CodexAccountManaging, @unchecked Sendable {
    let root: URL
    init(root: URL) { self.root = root }
    func loadState() throws -> CodexAccountState {
        let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let profile = CodexAccountProfile(id: id, label: "fixture@example.invalid", email: "fixture@example.invalid", accountID: "fixture", credentialKind: .oauth,
            planName: "Pro", authFingerprint: "fixture", credentialReference: nil, authDataBase64: nil, managedHomePath: nil, createdAt: Date(), updatedAt: Date())
        return .init(currentAccount: .init(email: profile.email, accountID: "fixture", credentialKind: .oauth, planName: "Pro", authFingerprint: "fixture", authFileURL: root.appendingPathComponent("auth.json")), savedAccounts: [profile], activeSavedAccountID: id)
    }
    func saveCurrentAccount(label: String?) throws -> CodexAccountProfile { throw CodexAccountManagerError.accountNotFound }
    func switchToAccount(id: UUID) throws -> CodexAccountProfile { throw CodexAccountManagerError.accountNotFound }
    func authenticateManagedAccount(timeout: TimeInterval) async throws -> CodexAccountProfile { throw CodexAccountManagerError.accountNotFound }
    func removeAccount(id: UUID) throws {}
    func refreshSavedCurrentAccountIfPossible() throws -> CodexAccountProfile? { nil }
}

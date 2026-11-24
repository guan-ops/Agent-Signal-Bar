import AppKit
import SwiftUI
import XCTest
import AgentSignalLightCore
@testable import AgentSignalLight

/// Renders every settings page offscreen with fixture data. Set ASB_SETTINGS_PREVIEW to a
/// folder to keep PNGs of each page in light and dark for design review.
@MainActor
final class SettingsWindowPreviewTests: XCTestCase {
    private let tabs = ["activity", "usage", "light", "connections", "general", "about"]

    func testEverySettingsPageRendersInBothAppearances() async throws {
        let output = ProcessInfo.processInfo.environment["ASB_SETTINGS_PREVIEW"].map(URL.init(fileURLWithPath:))
        _ = NSApplication.shared
        for theme in [AppTheme.light, .dark] {
            let fixture = try SettingsPreviewFixture()
            defer { fixture.cleanUp() }
            let model = try fixture.makeModel()
            model.setAppTheme(theme)
            let pages = output == nil ? ["activity", "light"] : tabs
            for tab in pages {
                let host = NSHostingView(rootView: DebugWindowView(model: model, updater: SparkleUpdaterService(), initialTab: tab))
                host.frame = NSRect(x: 0, y: 0, width: SettingsWindowMetrics.width, height: SettingsWindowMetrics.height)
                let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .fullSizeContentView],
                                      backing: .buffered, defer: false)
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
                window.contentView = host
                window.appearance = theme.nsAppearance
                window.orderFront(nil)
                defer { window.orderOut(nil) }
                try await Task.sleep(for: .milliseconds(output == nil ? 200 : 700))
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                XCTAssertGreaterThan(bitmap.pixelsWide, 0, tab)
                if let output {
                    try bitmap.representation(using: .png, properties: [:])?
                        .write(to: output.appendingPathComponent("settings-\(tab)-\(theme.rawValue).png"))
                }
            }
        }
    }
}

@MainActor
private struct SettingsPreviewFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("settings-preview-\(UUID())")
    let suite = "settings-preview-\(UUID())"

    func makeModel() throws -> MenuBarStatusModel {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set("zh-Hans", forKey: "appLanguage")
        defaults.set("off", forKey: "codexOpenAICookieMode")
        defaults.set(false, forKey: "isFloatingSignalSoundEnabled")
        let store = SignalStateStore(stateFileURL: root.appendingPathComponent("state.json"))
        _ = try store.applySessionSignal(.working, sessionID: "codex-desktop:01a1d80a-f46d-7203-9255-980664aaaaaa",
                                         agent: "codex-desktop", lastEvent: "DesktopToolCall:exec_command")
        _ = try store.applySessionSignal(.permissionRequest, sessionID: "claude-preview-session",
                                         agent: "claude-desktop", lastEvent: "PermissionRequest")
        return MenuBarStatusModel(
            store: store, userDefaults: defaults, startsMonitoring: false,
            codexAccountManager: CodexAccountManager(
                environment: ["HOME": root.path, "CODEX_HOME": root.path],
                storeURL: root.appendingPathComponent("accounts.json"),
                managedHomeRootURL: root.appendingPathComponent("homes")),
            codexUsageSnapshotStore: CodexAccountUsageSnapshotStore(fileURL: root.appendingPathComponent("usage.json")),
            codexTokenActivityScanner: CodexTokenActivityScanner(
                sessionRootURLs: [], cacheURL: root.appendingPathComponent("tokens.json"),
                costUsageCacheRootURL: root.appendingPathComponent("cost")),
            performsAccountSwitchBackgroundRefreshes: false,
            claudeSupport: ClaudeSupportModel(defaults: defaults, historyLoader: { _ in .init(data: [], summary: nil) }))
    }

    func cleanUp() {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

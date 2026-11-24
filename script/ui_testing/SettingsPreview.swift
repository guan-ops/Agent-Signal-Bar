import AppKit
import SwiftUI
import AgentSignalLightCore
@testable import AgentSignalLight

@main struct Preview {
    @MainActor static func main() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-signal-ui-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "agent-signal-sidebar-preview")!
        defaults.set("zh-Hans", forKey: "appLanguage")
        defaults.set("off", forKey: "codexOpenAICookieMode")
        let model = MenuBarStatusModel(
            store: SignalStateStore(stateFileURL: root.appendingPathComponent("state.json")),
            userDefaults: defaults,
            startsMonitoring: false,
            codexAccountManager: CodexAccountManager(environment: ["HOME": root.path, "CODEX_HOME": root.path], storeURL: root.appendingPathComponent("accounts.json"), managedHomeRootURL: root.appendingPathComponent("homes")),
            codexUsageSnapshotStore: CodexAccountUsageSnapshotStore(fileURL: root.appendingPathComponent("usage.json")),
            codexCLIStatusProbe: PreviewCLIProbe(),
            codexRPCStatusProbe: PreviewRPCProbe(),
            codexServiceStatusFetcher: PreviewServiceStatus(),
            codexRateLimitFetcher: CodexRateLimitFetcher(environment: ["HOME": root.path, "CODEX_HOME": root.path], browserCookieImporter: PreviewCookieImporter()),
            codexTokenActivityScanner: CodexTokenActivityScanner(sessionRootURLs: [], cacheURL: root.appendingPathComponent("tokens.json"), costUsageCacheRootURL: root.appendingPathComponent("cost"))
        )
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: SettingsWindowMetrics.width, height: SettingsWindowMetrics.height), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Agent Signal Bar · UI Test 7"
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.appearance = model.appTheme.nsAppearance
        window.contentView = NSHostingView(rootView: DebugWindowView(model: model, updater: SparkleUpdaterService()))
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        app.run()
    }
}

private struct PreviewCLIProbe: CodexCLIStatusProbing {
    func probeStatus() -> CodexCLIStatus {
        CodexCLIStatus(versionText: nil, checkedAt: Date())
    }
}
private struct PreviewRPCProbe: CodexRPCStatusProbing {
    func probeStatus() async -> CodexRPCStatus {
        CodexRPCStatus(accountEmail: nil, accountPlanName: nil, rateLimitPlanName: nil, checkedAt: Date())
    }
}
private struct PreviewServiceStatus: CodexServiceStatusFetching {
    func fetchStatus() async throws -> CodexServiceStatus {
        CodexServiceStatus(indicator: .unknown, description: "UI preview", updatedAt: nil)
    }
}
private struct PreviewCookieImporter: OpenAIBrowserCookieImporting {
    func importCookieHeader(targetEmail: String?) async -> OpenAIBrowserCookieImportResult? { nil }
}

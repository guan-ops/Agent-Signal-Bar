import AppKit
import SwiftUI
import XCTest
import AgentSignalLightCore
@testable import AgentSignalLight

@MainActor
final class SignalLightProviderSelectionTests: XCTestCase {
    func testProviderSelectionImmediatelyChangesBothLightsWithoutDroppingOtherActivity() throws {
        let fixture = try LightSelectionFixture()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        XCTAssertEqual(model.signalLightAgentSelectionMode, .following)
        XCTAssertEqual(model.lightSnapshot.aggregate, .permission)
        let allSessions = Set(model.activitySnapshot.sessions.map(\.sessionID))

        model.selectSignalLightProvider(.codex)
        XCTAssertEqual(model.signalLightAgentScopes, SignalLightAgentScope.codexCases)
        XCTAssertEqual(model.signalLightAgentSelectionMode, .manual)
        XCTAssertEqual(model.selectedSignalLightProvider, .codex)
        XCTAssertEqual(model.statusBarLightSnapshot.aggregate, .working)
        XCTAssertEqual(model.floatingSignalLightSnapshot.aggregate, .working)
        XCTAssertTrue(model.showsCodexFloatingUsage)
        XCTAssertEqual(Set(model.displaySnapshot.sessions.map(\.sessionID)), ["codex-desktop:fixture"])

        model.selectSignalLightProvider(.claude)
        XCTAssertEqual(model.signalLightAgentScopes, SignalLightAgentScope.claudeCases)
        XCTAssertEqual(model.selectedSignalLightProvider, .claude)
        XCTAssertEqual(model.statusBarLightSnapshot.aggregate, .permission)
        XCTAssertEqual(model.floatingSignalLightSnapshot.aggregate, .permission)
        XCTAssertFalse(model.showsCodexFloatingUsage)
        XCTAssertEqual(Set(model.displaySnapshot.sessions.map(\.sessionID)), ["claude-code:fixture"])
        XCTAssertEqual(Set(model.activitySnapshot.sessions.map(\.sessionID)), allSessions)
    }

    func testRepeatedSelectionIsStablePersistsAndCanReturnToAutomaticFollowing() throws {
        let fixture = try LightSelectionFixture()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        model.selectSignalLightProvider(.codex)
        model.selectSignalLightProvider(.codex)
        XCTAssertEqual(model.selectedSignalLightProvider, .codex)
        let restored = fixture.makeModel()
        XCTAssertEqual(restored.signalLightAgentSelectionMode, .manual)
        XCTAssertEqual(restored.selectedSignalLightProvider, .codex)
        XCTAssertEqual(restored.floatingSignalLightSnapshot.aggregate, .working)

        restored.followSignalLightAutomatically()
        XCTAssertEqual(restored.signalLightAgentSelectionMode, .following)
        XCTAssertEqual(restored.selectedSignalLightProvider, .claude)
        XCTAssertEqual(restored.floatingSignalLightSnapshot.aggregate, .permission)
        XCTAssertEqual(fixture.makeModel().signalLightAgentSelectionMode, .following)
    }

    func testIdleSelectionBorrowsAnotherAgentsLampButNeverItsUsage() throws {
        let fixture = try LightSelectionFixture(includeClaude: false)
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        model.selectSignalLightProvider(.claude)
        XCTAssertTrue(model.isSignalLightIdleFallbackEnabled, "On by default so the light is never silently dark")
        // Claude is not running and Codex is working: the lamp shows Codex.
        XCTAssertEqual(model.signalLightIdleFallbackScope, .codexDesktop)
        XCTAssertEqual(model.floatingSignalLightSnapshot.aggregate, .working)
        XCTAssertEqual(model.statusBarLightSnapshot.aggregate, .working)
        XCTAssertEqual(model.signalLightSummary.signal, .working)
        XCTAssertEqual(Set(model.displaySnapshot.sessions.map(\.sessionID)), ["codex-desktop:fixture"])
        // The selection, menu highlight and usage provider stay on Claude.
        XCTAssertEqual(model.selectedSignalLightProvider, .claude)
        XCTAssertEqual(model.displaySignalLightAgentScopes, SignalLightAgentScope.claudeCases)
        XCTAssertFalse(model.showsCodexFloatingUsage)
        XCTAssertTrue(model.signalLightAgentUnavailableHint?.contains("暂时显示") == true, model.signalLightAgentUnavailableHint ?? "nil")

        // With the switch off the lamp stays on the idle selection and the hint says why.
        model.setSignalLightIdleFallbackEnabled(false)
        XCTAssertNil(model.signalLightIdleFallbackScope)
        XCTAssertEqual(model.floatingSignalLightSnapshot.aggregate, .idle)
        XCTAssertEqual(model.statusBarLightSnapshot.aggregate, .idle)
        XCTAssertTrue(model.displaySnapshot.sessions.isEmpty)
        XCTAssertFalse(model.activitySnapshot.sessions.isEmpty)
        XCTAssertTrue(model.signalLightAgentUnavailableHint?.contains("尚未运行") == true, model.signalLightAgentUnavailableHint ?? "nil")
        XCTAssertFalse(fixture.makeModel().isSignalLightIdleFallbackEnabled, "The switch persists")
    }

    /// Writes a session the way a hook does, then waits for the model's asynchronous reload.
    /// Timestamps are persisted to the second, so each write is placed `secondsLater` after
    /// the fixture's sessions; otherwise ties would be settled by list order, not recency.
    private func apply(_ signal: AgentSignal, _ sessionID: String, agent: String, secondsLater: TimeInterval = 2,
                       to fixture: LightSelectionFixture, model: MenuBarStatusModel) async throws {
        _ = try fixture.store.applySessionSignal(signal, sessionID: sessionID, agent: agent, lastEvent: "Fixture",
                                                 updatedAt: Date().addingTimeInterval(secondsLater))
        model.reload()
        for _ in 0..<300 {
            if model.snapshot.sessions.contains(where: { $0.sessionID == sessionID && $0.signal == signal }) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The model never loaded \(sessionID) = \(signal)")
    }

    func testAutoFollowStaysOnAWorkingAgentUntilItStopsOrSomethingMoreUrgentAppears() async throws {
        let fixture = try LightSelectionFixture(includeClaude: false)
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        XCTAssertEqual(model.displaySignalLightAgentScopes, [.codexDesktop])

        // Claude starts working later than Codex: both are working, so the light stays on Codex.
        try await apply(.working, "claude-code:busy", agent: "claude-code", to: fixture, model: model)
        XCTAssertTrue(model.activitySnapshot.sessions.contains { $0.sessionID == "claude-code:busy" })
        XCTAssertEqual(model.displaySignalLightAgentScopes, [.codexDesktop])
        XCTAssertEqual(model.displaySignalLightAgentScopes, [.codexDesktop], "Stable across repeated reads")

        // Codex finishes: the light hands over to the agent that is still working.
        try await apply(.done, "codex-desktop:fixture", agent: "codex-desktop", secondsLater: 3, to: fixture, model: model)
        XCTAssertEqual(model.displaySignalLightAgentScopes, [.claudeCode])

        // Something more urgent always takes over at once.
        let urgent = try LightSelectionFixture(includeClaude: false)
        defer { urgent.cleanUp() }
        let following = urgent.makeModel()
        XCTAssertEqual(following.displaySignalLightAgentScopes, [.codexDesktop])
        try await apply(.permissionRequest, "claude-code:ask", agent: "claude-code", to: urgent, model: following)
        XCTAssertEqual(following.displaySignalLightAgentScopes, [.claudeCode])
        XCTAssertEqual(following.statusBarLightSnapshot.aggregate.displayState, .permission)
    }

    func testIdleFallbackIsStickyToo() async throws {
        let fixture = try LightSelectionFixture(includeClaude: false)
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        model.selectSignalLightProvider(.claude)
        XCTAssertEqual(model.signalLightIdleFallbackScope, .codexDesktop)
        try await apply(.working, "codex-cli:later", agent: "codex-cli", to: fixture, model: model)
        XCTAssertTrue(model.activitySnapshot.sessions.contains { $0.sessionID == "codex-cli:later" })
        XCTAssertEqual(model.signalLightIdleFallbackScope, .codexDesktop, "A second working agent does not steal the borrowed light")
    }

    func testAutoFollowIsTheFreshDefaultAndCanBeChosenAgain() throws {
        let fixture = try LightSelectionFixture(includeClaude: false)
        defer { fixture.cleanUp() }
        let fresh = fixture.makeModel()
        XCTAssertEqual(fresh.signalLightAgentSelectionMode, .following, "A new install follows the active agent")
        XCTAssertEqual(fresh.statusBarLightSnapshot.aggregate, .working)
        XCTAssertNil(fresh.signalLightIdleFallbackScope, "Following never needs to borrow")

        fresh.selectSignalLightProvider(.claude)
        XCTAssertEqual(fresh.signalLightAgentSelectionMode, .manual)
        fresh.followSignalLightAutomatically()
        XCTAssertEqual(fresh.signalLightAgentSelectionMode, .following)
        XCTAssertNil(fresh.signalLightIdleFallbackScope)
        XCTAssertEqual(fresh.statusBarLightSnapshot.aggregate, .working)
        XCTAssertEqual(fixture.makeModel().signalLightAgentSelectionMode, .following, "The choice persists")
    }

    func testABusySelectedAgentKeepsTheLampEvenWhenAnotherOutranksIt() throws {
        let fixture = try LightSelectionFixture()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        // Codex is working, Claude waits for permission: selecting Codex never borrows Claude.
        model.selectSignalLightProvider(.codex)
        XCTAssertNil(model.signalLightIdleFallbackScope)
        XCTAssertEqual(model.statusBarLightSnapshot.aggregate, .working)

        // An idle selected session is not activity; a just-finished one is, and keeps the lamp.
        for (signal, borrows) in [(AgentSignal.idle, true), (.done, false)] {
            let codexOnly = try LightSelectionFixture(includeClaude: false)
            defer { codexOnly.cleanUp() }
            _ = try codexOnly.store.applySessionSignal(signal, sessionID: "claude-code:fixture", agent: "claude-code", lastEvent: "Fixture")
            let claudeSelected = codexOnly.makeModel()
            claudeSelected.selectSignalLightProvider(.claude)
            XCTAssertEqual(claudeSelected.signalLightIdleFallbackScope != nil, borrows, "\(signal)")
            if borrows { XCTAssertEqual(claudeSelected.statusBarLightSnapshot.aggregate, .working) }
        }
    }

    func testProviderMappingIncludesClaudeIDEAndDoesNotCaptureLocalScripts() {
        for agent in ["claude-code", "claude-cli", "claude-desktop", "claude-vscode", "claude-ide", "claude-idea"] {
            let session = SessionStatus(sessionID: "\(agent):fixture", signal: .working, updatedAt: Date(), agent: agent, lastEvent: "PreToolUse")
            XCTAssertEqual(SignalLightProvider.matching(session), .claude, agent)
            XCTAssertTrue(SignalLightAgentScope.claudeCode.matches(session: session), agent)
            XCTAssertFalse(SignalLightAgentScope.codex.matches(session: session), agent)
        }
        let local = SessionStatus(sessionID: "fixture:script", signal: .working, updatedAt: Date(), agent: "local-script")
        XCTAssertNil(SignalLightProvider.matching(local))
    }

    func testRenderedLampChangesImmediatelyAndSelectorRetainsBothProviders() async throws {
        let fixture = try LightSelectionFixture()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        model.selectSignalLightProvider(.codex)
        _ = NSApplication.shared
        let host = NSHostingView(rootView: LightSelectionPreview(model: model))
        host.frame = NSRect(x: 0, y: 0, width: 270, height: 430)
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Signal selection · isolated fixture"
        window.contentView = host
        window.appearance = NSAppearance(named: .darkAqua)
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        for provider in SignalLightProvider.allCases {
            model.selectSignalLightProvider(provider)
            try await Task.sleep(for: .milliseconds(200))
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            XCTAssertEqual(ActivityPresentation.visibleRunningSessions(from: model.activitySnapshot).count, 2)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            // Inspect only the lower lamp area, excluding both providers' always-visible status dots.
            // This catches a stale cached lamp even when the selector itself has already updated.
            let colors = lampPixelCounts(bitmap)
            if provider == .claude { XCTAssertGreaterThan(colors.red, colors.green + 10) }
            else { XCTAssertGreaterThan(colors.green, colors.red + 10) }
            if let directory = ProcessInfo.processInfo.environment["ASB_LIGHT_SELECTION_PREVIEW"] {
                try bitmap.representation(using: .png, properties: [:])?.write(
                    to: URL(fileURLWithPath: directory).appendingPathComponent("light-\(provider.rawValue.lowercased()).png"))
            }
        }
    }

    private func lampPixelCounts(_ bitmap: NSBitmapImageRep) -> (red: Int, green: Int) {
        var red = 0
        var green = 0
        for y in stride(from: bitmap.pixelsHigh * 2 / 5, to: bitmap.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.5 else { continue }
                // Display profiles can lift a green lamp's red channel above 0.5.
                // Require bright, dominant hue instead of an absolute cross-channel ceiling.
                if color.redComponent > 0.65, color.redComponent - color.greenComponent > 0.18,
                   color.redComponent - color.blueComponent > 0.18 { red += 1 }
                if color.greenComponent > 0.6, color.greenComponent - color.redComponent > 0.15,
                   color.greenComponent - color.blueComponent > 0.15 { green += 1 }
            }
        }
        return (red, green)
    }
}

private struct LightSelectionPreview: View {
    @ObservedObject var model: MenuBarStatusModel
    var body: some View {
        VStack(alignment: .trailing, spacing: 12) {
            FloatingSignalInfoPopoverView(model: model)
            FloatingSignalPanelView(model: model, animationClock: model.animationClock,
                hide: {}, smaller: {}, larger: {}, toggleLayout: {}, toggleSound: {},
                previewCompletionSound: {}, previewWaitingSound: {}, resizeFromHandle: { _, _ in }, openSettings: {})
        }.padding(10).frame(width: 270, height: 430, alignment: .topTrailing).preferredColorScheme(.dark)
    }
}

@MainActor
private struct LightSelectionFixture {
    let root: URL
    let suite: String
    let defaults: UserDefaults
    let store: SignalStateStore

    init(includeClaude: Bool = true) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("light-selection-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "light-selection-\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        defaults.set("zh-Hans", forKey: "appLanguage")
        defaults.set("dark", forKey: "appTheme")
        defaults.set("off", forKey: "codexOpenAICookieMode")
        defaults.set(false, forKey: "isFloatingSignalSoundEnabled")
        store = SignalStateStore(stateFileURL: root.appendingPathComponent("state.json"))
        let now = Date()
        var sessions: [String: SessionRecord] = ["codex-desktop:fixture": .init(agent: "codex-desktop", signal: .working,
            lastEvent: "DesktopToolCall:exec_command", updatedAt: now)]
        if includeClaude {
            sessions["claude-code:fixture"] = .init(agent: "claude-code", signal: .permission,
                lastEvent: "PermissionRequest", updatedAt: now)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(SignalStateDocument(aggregate: includeClaude ? .permission : .working,
            updatedAt: now, sessions: sessions)).write(to: store.stateFileURL)
    }

    func makeModel() -> MenuBarStatusModel {
        MenuBarStatusModel(store: store, userDefaults: defaults, startsMonitoring: false,
            codexAccountManager: LightSelectionAccounts(),
            codexUsageSnapshotStore: CodexAccountUsageSnapshotStore(fileURL: root.appendingPathComponent("usage.json")),
            codexTokenActivityScanner: CodexTokenActivityScanner(sessionRootURLs: [],
                cacheURL: root.appendingPathComponent("tokens.json"), costUsageCacheRootURL: root.appendingPathComponent("cost")),
            performsAccountSwitchBackgroundRefreshes: false,
            claudeSupport: ClaudeSupportModel(defaults: defaults, historyLoader: { _ in .init(data: [], summary: nil) }))
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

private final class LightSelectionAccounts: CodexAccountManaging, @unchecked Sendable {
    func loadState() throws -> CodexAccountState { .init(currentAccount: nil, savedAccounts: [], activeSavedAccountID: nil) }
    func saveCurrentAccount(label: String?) throws -> CodexAccountProfile { throw CodexAccountManagerError.accountNotFound }
    func switchToAccount(id: UUID) throws -> CodexAccountProfile { throw CodexAccountManagerError.accountNotFound }
    func authenticateManagedAccount(timeout: TimeInterval) async throws -> CodexAccountProfile { throw CodexAccountManagerError.accountNotFound }
    func removeAccount(id: UUID) throws {}
    func refreshSavedCurrentAccountIfPossible() throws -> CodexAccountProfile? { nil }
}

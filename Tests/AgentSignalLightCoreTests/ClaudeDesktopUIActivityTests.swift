import XCTest
import AgentSignalLightCore
@testable import AgentSignalLight

final class ClaudeDesktopUIActivityTests: XCTestCase {
    private struct Node {
        var role: String = "AXGroup"
        var label: String = ""
        var enabled = true
        var host: String? = nil
        var children: [Node] = []
    }
    private func scan(_ children: [Node], maxNodes: Int = 1500, expired: Bool = false) -> ClaudeDesktopUIActivityMonitor.Observation {
        ClaudeDesktopUIActivityMonitor.scan(root: Node(role: "AXWebArea", host: "claude.ai", children: children),
            maxNodes: maxNodes, expired: { expired }, role: { $0.role }, label: { $0.label },
            enabled: { $0.enabled }, url: { $0.host }, children: { node, _ in node.children })
    }
    func testHookEventsFromTheDesktopAppAreNotLabeledAsTerminal() {
        // Captured from a Claude desktop Code-tab session: it inherits TERM_PROGRAM from the shell.
        let desktop = ["CLAUDE_CODE_ENTRYPOINT": "claude-desktop", "TERM_PROGRAM": "Apple_Terminal",
                       "__CFBundleIdentifier": "com.anthropic.claudefordesktop"]
        XCTAssertEqual(ClaudeHookAdapter.agentName(environment: desktop), "claude-desktop")
        XCTAssertEqual(ClaudeHookAdapter.agentName(environment: ["__CFBundleIdentifier": "com.anthropic.claudefordesktop"]), "claude-desktop")
        // An explicit CLI entrypoint wins over an inherited desktop bundle identifier.
        XCTAssertEqual(ClaudeHookAdapter.agentName(environment: ["CLAUDE_CODE_ENTRYPOINT": "cli",
            "__CFBundleIdentifier": "com.anthropic.claudefordesktop"]), "claude-code")
        XCTAssertEqual(ClaudeHookAdapter.agentName(environment: ["TERM_PROGRAM": "Apple_Terminal",
            "__CFBundleIdentifier": "com.apple.Terminal"]), "claude-code")
        XCTAssertEqual(ClaudeHookAdapter.agentName(environment: ["CLAUDE_CODE_ENTRYPOINT": "claude-vscode"]), "claude-vscode")
        XCTAssertEqual(ClaudeHookAdapter.agentName(environment: [:]), "claude-code")

        func session(_ agent: String) -> SessionStatus {
            SessionStatus(sessionID: UUID().uuidString, signal: .working, updatedAt: Date(), agent: agent, lastEvent: "PreToolUse")
        }
        guard case .desktop = ActivityPresentation.runtimeKind(for: session("claude-desktop")) else {
            return XCTFail("Desktop hook sessions must present as the desktop app")
        }
        XCTAssertEqual(ActivityPresentation.activitySourceKey(for: session("claude-desktop")), "claude:desktop")
        guard case .terminal = ActivityPresentation.runtimeKind(for: session("claude-code")) else {
            return XCTFail("CLI hook sessions remain terminal sessions")
        }
        guard case .ide = ActivityPresentation.runtimeKind(for: session("claude-vscode")) else {
            return XCTFail("VS Code hook sessions present as an IDE")
        }
    }

    @MainActor
    func testLightSummaryFollowsTheSelectedAgentOnly() throws {
        let root = URL(fileURLWithPath: "/private/tmp/light-summary-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "light-summary-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SignalStateStore(stateFileURL: root.appendingPathComponent("status.json"))
        // Codex outranks Claude, so an all-agent summary would show Codex's state.
        _ = try store.applySessionSignal(.permissionRequest, sessionID: "codex-desktop:01a1d80a-f46d-7203-9255-980664aaaaaa",
                                         agent: "codex-desktop", lastEvent: "PermissionRequest")
        _ = try store.applySessionSignal(.working, sessionID: "4aa5a2f3-cc5d-436a-8940-f4e709e35e1b",
                                         agent: "claude-desktop", lastEvent: "PreToolUse:Bash")
        let model = MenuBarStatusModel(store: store, userDefaults: defaults, startsMonitoring: false,
            codexTokenActivityScanner: CodexTokenActivityScanner(sessionRootURLs: [], cacheURL: root.appendingPathComponent("tokens.json"),
                                                                 costUsageCacheRootURL: root.appendingPathComponent("cost")),
            performsAccountSwitchBackgroundRefreshes: false)
        model.setSignalLightAgentScopes([.claudeCode])

        let summary = model.signalLightSummary
        XCTAssertEqual(summary.signal, model.statusBarLightSnapshot.aggregate)
        XCTAssertEqual(summary.signal.displayState, .active, "Claude is working; Codex's permission request must not leak in")
        XCTAssertEqual(summary.sessionCount, 1)

        model.setSignalLightAgentScopes(SignalLightAgentScope.codexCases)
        XCTAssertEqual(model.signalLightSummary.signal.displayState, .permission)
    }

    func testDisabledDoesNotAccessAccessibility() {
        XCTAssertEqual(ClaudeDesktopUIActivityMonitor.observe(enabled: false), .disabled)
    }
    func testResponseControlInChineseAndEnglish() {
        for label in ["停止回复", "停止回覆", "Stop response", "Stop generating"] {
            XCTAssertEqual(scan([Node(role: "AXButton", label: label)]), .working)
        }
    }
    func testTextTitlesGenericStopAndDisabledButtonsCannotReportWorking() {
        for node in [Node(role: "AXStaticText", label: "停止回复"),
                     Node(role: "AXButton", label: "Stop"),
                     Node(role: "AXButton", label: "任务运行中"),
                     Node(role: "AXButton", label: "停止回复", enabled: false)] {
            XCTAssertEqual(scan([node]), .notResponding)
        }
    }
    func testChatAndArtifactSubtreesCannotSpoofRunning() {
        let button = Node(role: "AXButton", label: "停止回复")
        XCTAssertEqual(scan([Node(label: "对话消息", children: [button])]), .notResponding)
        XCTAssertEqual(scan([Node(role: "AXWebArea", host: "example.claudeusercontent.com", children: [button])]), .notResponding)
    }
    func testBoundsFailClosedAndAbsenceDoesNotMeanCompletion() {
        XCTAssertEqual(scan([], expired: true), .unavailable)
        XCTAssertEqual(scan([Node(), Node()], maxNodes: 1), .unavailable)
        XCTAssertEqual(scan([]), .notResponding)
        XCTAssertEqual(ClaudeDesktopUIActivityMonitor.applying(.notResponding, to: []).count, 0)
        XCTAssertEqual(ClaudeDesktopUIActivityMonitor.applying(.permissionRequired, to: []).count, 0)
    }
    func testWorkingReplacesOnlyClaudePresence() {
        let now = Date()
        let presence = CodexPlatformPresenceMonitor.detectSessions(applications: [
            .init(bundleIdentifier: "com.anthropic.claudefordesktop", localizedName: "Claude"),
            .init(bundleIdentifier: "com.openai.codex", localizedName: "Codex")], processes: [], now: now)
        let sessions = ClaudeDesktopUIActivityMonitor.applying(.working, to: presence, now: now)
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions.filter { $0.agent == "claude-desktop" }.map(\.signal), [.working])
        XCTAssertEqual(sessions.filter { $0.agent == "codex-desktop" }.map(\.signal), [.idle])
        XCTAssertEqual(ActivityPresentation.activitySourceKey(for: sessions.last!), "claude:desktop")
    }
}

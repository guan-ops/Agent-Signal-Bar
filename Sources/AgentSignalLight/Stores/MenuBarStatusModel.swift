import AgentSignalLightCore
import AgentSignalLightUI
import AppKit
import Foundation

@MainActor
final class SignalAnimationClock: ObservableObject {
    @Published private(set) var tick: Int = 0

    func advance() {
        tick = (tick + 1) % 10_000
    }

    func reset() {
        if tick != 0 {
            tick = 0
        }
    }
}

enum SignalLightAgentScope: String, CaseIterable, Hashable {
    case codex
    case claude

    var agentKey: String {
        switch self {
        case .codex:
            return "codex"
        case .claude:
            return "claude"
        }
    }
}

enum SettingsGlassEffect: String, CaseIterable, Hashable {
    case standard
    case enhanced
}

@MainActor
final class MenuBarStatusModel: ObservableObject {
    @Published private(set) var snapshot: SignalSnapshot
    @Published var displayLayout: TrafficSignalLayout
    @Published var statusBarStyle: TrafficSignalStyle
    @Published var macOSBreathingStrength: MacOSBreathingStrength
    @Published var thinkingSignalEffect: ActiveSignalEffect
    @Published var activeSignalEffect: ActiveSignalEffect
    @Published var activeEffectSpeed: SignalEffectSpeed
    @Published var alertEffectSpeed: SignalEffectSpeed
    @Published var completedSignalEffect: CompletedSignalEffect
    @Published var macOSHorizontalUsesTrafficLightSize: Bool
    @Published var trafficLightVerticalUsesMacOSSize: Bool
    @Published var isStatusBarIconEnabled: Bool
    @Published var isStatusBarAllLightsOn: Bool
    @Published var signalLightAgentScope: SignalLightAgentScope
    @Published var isSignalTestModeEnabled = false
    @Published var isCodexDesktopMonitoringEnabled: Bool
    @Published var appLanguage: AppLanguage
    @Published var appTheme: AppTheme
    @Published var isSettingsGlassEnabled: Bool
    @Published var settingsGlassEffect: SettingsGlassEffect
    @Published var isMonitoringPaused = false
    @Published private(set) var desktopAppSessions: [SessionStatus] = []
    @Published private(set) var isLaunchAtLoginEnabled = false
    @Published private(set) var isLaunchAtLoginChangeRunning = false
    @Published var isHookInstallRunning = false
    @Published var hookInstallMessage: String?
    @Published var isDiagnosticsExportRunning = false
    @Published var diagnosticsExportMessage: String?
    @Published private(set) var releaseInfo: ReleaseInfo = .current()
    @Published var updateCheckMessage: String?
    @Published var lastError: String?

    let animationClock = SignalAnimationClock()

    private let store: SignalStateStore
    private let launchAtLoginManager: LaunchAtLoginManager
    private let hookInstallManager: HookInstallManager
    private let diagnosticsExportManager: DiagnosticsExportManager
    private let codexDesktopActivityMonitor: CodexDesktopActivityMonitor
    private var pollTimer: Timer?
    private var animationTimer: Timer?
    private var codexDesktopTimer: Timer?
    private var desktopAppTimer: Timer?
    private var watcher: StateFileWatcher?

    private static let defaultDisplayLayout: TrafficSignalLayout = .horizontal
    private static let defaultStatusBarStyle: TrafficSignalStyle = .trafficLight
    private static let defaultMacOSHorizontalUsesTrafficLightSize = true
    private static let defaultTrafficLightVerticalUsesMacOSSize = false
    private static let effectDefaultsVersion = 2
    private static let statePollInterval: TimeInterval = 2.0
    private static let animationTickInterval: TimeInterval = 0.25
    private static let agentPollInterval: TimeInterval = 1.5
    private static let desktopAppPresencePollInterval: TimeInterval = 8.0
    private static let desktopAppSuppressionWindow: TimeInterval = 5 * 60

    private struct LaunchAtLoginUpdateResult: Sendable {
        let isEnabled: Bool
        let errorMessage: String?
    }

    private struct DesktopAgentApp: Sendable {
        let sessionID: String
        let agent: String
        let event: String
        let bundleIdentifiers: Set<String>
        let appNames: Set<String>
    }

    private static let desktopAgentApps: [DesktopAgentApp] = [
        DesktopAgentApp(
            sessionID: "desktop-app:codex",
            agent: "codex-desktop",
            event: "DesktopAppRunning",
            bundleIdentifiers: [
                "com.openai.codex"
            ],
            appNames: ["codex"]
        ),
        DesktopAgentApp(
            sessionID: "desktop-app:claude",
            agent: "claude-desktop",
            event: "DesktopAppRunning",
            bundleIdentifiers: [
                "com.anthropic.claudefordesktop",
                "com.anthropic.claude"
            ],
            appNames: ["claude"]
        )
    ]

    init(
        store: SignalStateStore = SignalStateStore(),
        launchAtLoginManager: LaunchAtLoginManager = LaunchAtLoginManager(),
        hookInstallManager: HookInstallManager = HookInstallManager(),
        diagnosticsExportManager: DiagnosticsExportManager = DiagnosticsExportManager(),
        codexDesktopActivityMonitor: CodexDesktopActivityMonitor = CodexDesktopActivityMonitor()
    ) {
        self.store = store
        self.launchAtLoginManager = launchAtLoginManager
        self.hookInstallManager = hookInstallManager
        self.diagnosticsExportManager = diagnosticsExportManager
        self.codexDesktopActivityMonitor = codexDesktopActivityMonitor
        let storedLayout = UserDefaults.standard.string(forKey: "trafficSignalLayout")
        let storedStyle = UserDefaults.standard.string(forKey: "trafficSignalStyle")
        let storedMacOSStrength = UserDefaults.standard.string(forKey: "macOSBreathingStrength")
        let storedThinkingSignalEffect = UserDefaults.standard.string(forKey: "thinkingSignalEffect")
        let storedActiveSignalEffect = UserDefaults.standard.string(forKey: "activeSignalEffect")
        let storedActiveEffectSpeed = UserDefaults.standard.string(forKey: "activeEffectSpeed")
        let storedAlertEffectSpeed = UserDefaults.standard.string(forKey: "alertEffectSpeed")
        let storedCompletedSignalEffect = UserDefaults.standard.string(forKey: "completedSignalEffect")
        let storedLanguage = UserDefaults.standard.string(forKey: "appLanguage")
        let storedTheme = UserDefaults.standard.string(forKey: "appTheme")
        let storedSettingsGlassEnabled = UserDefaults.standard.object(forKey: "isSettingsGlassEnabled") as? Bool
        let storedSettingsGlassEffect =
            UserDefaults.standard.string(forKey: "settingsGlassEffect")
            ?? UserDefaults.standard.string(forKey: "settingsMenuGlassEffect")
        let storedSignalLightAgentScope = UserDefaults.standard.string(forKey: "signalLightAgentScope")
        let shouldApplyEffectDefaults = UserDefaults.standard.integer(forKey: "signalEffectDefaultsVersion") < Self.effectDefaultsVersion
        displayLayout = storedLayout.flatMap(TrafficSignalLayout.init(rawValue:)) ?? Self.defaultDisplayLayout
        statusBarStyle = storedStyle.flatMap(TrafficSignalStyle.init(rawValue:)) ?? Self.defaultStatusBarStyle
        macOSBreathingStrength = storedMacOSStrength.flatMap(MacOSBreathingStrength.init(rawValue:)) ?? .maximum
        let resolvedThinkingSignalEffect: ActiveSignalEffect = shouldApplyEffectDefaults
            ? .greenFastFlash
            : storedThinkingSignalEffect.flatMap(ActiveSignalEffect.init(rawValue:)) ?? .greenFastFlash
        let resolvedActiveSignalEffect: ActiveSignalEffect = shouldApplyEffectDefaults
            ? .greenSlowFlash
            : storedActiveSignalEffect.flatMap(ActiveSignalEffect.init(rawValue:)) ?? .greenSlowFlash
        thinkingSignalEffect = resolvedThinkingSignalEffect
        activeSignalEffect = resolvedActiveSignalEffect
        activeEffectSpeed = storedActiveEffectSpeed.flatMap(SignalEffectSpeed.init(rawValue:)) ?? .standard
        alertEffectSpeed = storedAlertEffectSpeed.flatMap(SignalEffectSpeed.init(rawValue:)) ?? .standard
        let resolvedCompletedSignalEffect: CompletedSignalEffect = shouldApplyEffectDefaults
            ? .greenSteady
            : storedCompletedSignalEffect.flatMap(CompletedSignalEffect.init(rawValue:)) ?? .greenSteady
        completedSignalEffect = resolvedCompletedSignalEffect
        if shouldApplyEffectDefaults {
            UserDefaults.standard.set(resolvedThinkingSignalEffect.rawValue, forKey: "thinkingSignalEffect")
            UserDefaults.standard.set(resolvedActiveSignalEffect.rawValue, forKey: "activeSignalEffect")
            UserDefaults.standard.set(resolvedCompletedSignalEffect.rawValue, forKey: "completedSignalEffect")
            UserDefaults.standard.set(Self.effectDefaultsVersion, forKey: "signalEffectDefaultsVersion")
        }
        appLanguage = storedLanguage.flatMap(AppLanguage.init(rawValue:)) ?? .system
        appTheme = storedTheme.flatMap(AppTheme.init(rawValue:)) ?? .system
        isSettingsGlassEnabled = storedSettingsGlassEnabled ?? true
        settingsGlassEffect =
            storedSettingsGlassEffect.flatMap(SettingsGlassEffect.init(rawValue:)) ?? .enhanced
        macOSHorizontalUsesTrafficLightSize =
            UserDefaults.standard.object(forKey: "macOSHorizontalUsesTrafficLightSize") as? Bool
            ?? UserDefaults.standard.object(forKey: "macOSUsesTrafficLightSize") as? Bool
            ?? Self.defaultMacOSHorizontalUsesTrafficLightSize
        trafficLightVerticalUsesMacOSSize =
            UserDefaults.standard.object(forKey: "trafficLightVerticalUsesMacOSSize") as? Bool
            ?? Self.defaultTrafficLightVerticalUsesMacOSSize
        let storedStatusBarIconEnabled = UserDefaults.standard.object(forKey: "isStatusBarIconEnabled") as? Bool ?? true
        isStatusBarIconEnabled = DebugLaunchOptions.shouldForceStatusBarIconEnabled ? true : storedStatusBarIconEnabled
        isStatusBarAllLightsOn = UserDefaults.standard.object(forKey: "isStatusBarAllLightsOn") as? Bool ?? false
        signalLightAgentScope = storedSignalLightAgentScope.flatMap(SignalLightAgentScope.init(rawValue:)) ?? .codex
        isCodexDesktopMonitoringEnabled =
            UserDefaults.standard.object(forKey: "isCodexDesktopMonitoringEnabled") as? Bool ?? true
        snapshot = store.readSnapshot()
        isSignalTestModeEnabled = isStatusBarAllLightsOn || Self.snapshotContainsSignalTest(snapshot)
        isLaunchAtLoginEnabled = launchAtLoginManager.isEnabled
        desktopAppSessions = Self.detectDesktopAppSessions()
        watcher = StateFileWatcher(stateFileURL: snapshot.stateFileURL) { [weak self] in
            self?.reloadFromWatcher()
        }
        watcher?.start()
        startTimers()
    }

    func reload() {
        let latestSnapshot = store.readSnapshot()
        if latestSnapshot != snapshot {
            snapshot = latestSnapshot
        }
        if Self.snapshotContainsSignalTest(latestSnapshot) {
            isSignalTestModeEnabled = true
        }
        let latestReleaseInfo = ReleaseInfo.current()
        if latestReleaseInfo != releaseInfo {
            releaseInfo = latestReleaseInfo
        }
        pollDesktopAppPresence()
    }

    func reloadFromWatcher() {
        guard !isMonitoringPaused else { return }
        reload()
    }

    func setManualSignal(_ signal: AgentSignal) {
        do {
            snapshot = try store.setManualSignal(signal)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func setSignalTestModeEnabled(_ enabled: Bool) {
        guard enabled != isSignalTestModeEnabled else { return }
        isSignalTestModeEnabled = enabled

        if !enabled {
            clearSignalTestState(keepModeEnabled: false)
        }
    }

    func setSignalTestSignal(_ signal: AgentSignal) {
        guard isSignalTestModeEnabled else { return }

        do {
            snapshot = try store.setSignalTestSignal(signal)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func clearSignalTestState(keepModeEnabled: Bool = true) {
        do {
            if isStatusBarAllLightsOn {
                setStatusBarAllLightsOn(false)
            }
            snapshot = try store.clearSignalTestSignal()
            isSignalTestModeEnabled = keepModeEnabled
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func clearSessions() {
        do {
            snapshot = try store.clearSessions()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func clearWarnings() {
        do {
            snapshot = try store.clearWarnings()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func toggleMonitoring() {
        isMonitoringPaused.toggle()
        if !isMonitoringPaused {
            reload()
        }
    }

    func setDisplayLayout(_ layout: TrafficSignalLayout) {
        displayLayout = layout
        UserDefaults.standard.set(layout.rawValue, forKey: "trafficSignalLayout")
    }

    func setStatusBarStyle(_ style: TrafficSignalStyle) {
        statusBarStyle = style
        UserDefaults.standard.set(style.rawValue, forKey: "trafficSignalStyle")
    }

    func setMacOSBreathingStrength(_ strength: MacOSBreathingStrength) {
        macOSBreathingStrength = strength
        UserDefaults.standard.set(strength.rawValue, forKey: "macOSBreathingStrength")
    }

    func setThinkingSignalEffect(_ effect: ActiveSignalEffect) {
        thinkingSignalEffect = effect
        UserDefaults.standard.set(effect.rawValue, forKey: "thinkingSignalEffect")
    }

    func setActiveSignalEffect(_ effect: ActiveSignalEffect) {
        activeSignalEffect = effect
        UserDefaults.standard.set(effect.rawValue, forKey: "activeSignalEffect")
    }

    func setActiveEffectSpeed(_ speed: SignalEffectSpeed) {
        activeEffectSpeed = speed
        UserDefaults.standard.set(speed.rawValue, forKey: "activeEffectSpeed")
    }

    func setAlertEffectSpeed(_ speed: SignalEffectSpeed) {
        alertEffectSpeed = speed
        UserDefaults.standard.set(speed.rawValue, forKey: "alertEffectSpeed")
    }

    func setCompletedSignalEffect(_ effect: CompletedSignalEffect) {
        completedSignalEffect = effect
        UserDefaults.standard.set(effect.rawValue, forKey: "completedSignalEffect")
    }

    var signalEffectCustomization: SignalEffectCustomization {
        SignalEffectCustomization(
            thinkingEffect: thinkingSignalEffect,
            activeEffect: activeSignalEffect,
            activeSpeed: activeEffectSpeed,
            alertSpeed: alertEffectSpeed,
            completedEffect: completedSignalEffect
        )
    }

    var tick: Int {
        animationClock.tick
    }

    func setMacOSHorizontalUsesTrafficLightSize(_ enabled: Bool) {
        macOSHorizontalUsesTrafficLightSize = enabled
        UserDefaults.standard.set(enabled, forKey: "macOSHorizontalUsesTrafficLightSize")
    }

    func setTrafficLightVerticalUsesMacOSSize(_ enabled: Bool) {
        trafficLightVerticalUsesMacOSSize = enabled
        UserDefaults.standard.set(enabled, forKey: "trafficLightVerticalUsesMacOSSize")
    }

    func setStatusBarIconEnabled(_ enabled: Bool) {
        isStatusBarIconEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isStatusBarIconEnabled")
    }

    func setStatusBarAllLightsOn(_ enabled: Bool) {
        if enabled {
            isSignalTestModeEnabled = true
        }
        isStatusBarAllLightsOn = enabled
        UserDefaults.standard.set(enabled, forKey: "isStatusBarAllLightsOn")
    }

    func setSignalLightAgentScope(_ scope: SignalLightAgentScope) {
        signalLightAgentScope = scope
        UserDefaults.standard.set(scope.rawValue, forKey: "signalLightAgentScope")
    }

    func setCodexDesktopMonitoringEnabled(_ enabled: Bool) {
        isCodexDesktopMonitoringEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isCodexDesktopMonitoringEnabled")
        if enabled {
            codexDesktopActivityMonitor.reset()
            pollCodexDesktopActivity()
        }
    }

    func setAppLanguage(_ language: AppLanguage) {
        appLanguage = language
        UserDefaults.standard.set(language.rawValue, forKey: "appLanguage")
    }

    func setAppTheme(_ theme: AppTheme) {
        appTheme = theme
        UserDefaults.standard.set(theme.rawValue, forKey: "appTheme")
    }

    func setSettingsGlassEnabled(_ enabled: Bool) {
        isSettingsGlassEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isSettingsGlassEnabled")
    }

    func setSettingsGlassEffect(_ effect: SettingsGlassEffect) {
        settingsGlassEffect = effect
        UserDefaults.standard.set(effect.rawValue, forKey: "settingsGlassEffect")
    }

    var statusBarTooltip: String {
        let displaySnapshot = displaySnapshot
        var lines = [
            "Agent Signal Bar",
            "\(displayName(for: displaySnapshot.aggregate)) - \(humanAction(for: displaySnapshot.aggregate))"
        ]

        if isStatusBarAllLightsOn {
            lines.append(text("状态栏全亮预览", "All lights preview"))
        }

        lines.append("\(text("灯效 Agent", "Light Agent")): \(displayName(for: signalLightAgentScope))")

        if statusBarStyle == .macOS && displayLayout == .horizontal && !macOSHorizontalUsesTrafficLightSize {
            lines.append(text("圆点横向尺寸：小", "Horizontal dot size: Small"))
        }

        if statusBarStyle == .trafficLight && displayLayout == .vertical && trafficLightVerticalUsesMacOSSize {
            lines.append(text("灯牌竖向尺寸：大", "Vertical lamp size: Large"))
        }

        if isCodexDesktopMonitoringEnabled {
            lines.append(text("Codex Desktop 监控已开启", "Codex Desktop monitoring is on"))
        }

        if let session = displaySnapshot.sessions.first {
            var detail = session.sessionID
            if let agent = session.agent, !agent.isEmpty {
                detail += " / \(agent)"
            }
            if let event = session.lastEvent, !event.isEmpty {
                detail += " / \(event)"
            }
            lines.append(detail)
        }

        return lines.joined(separator: "\n")
    }

    var displaySnapshot: SignalSnapshot {
        let displaySessions = combinedDisplaySessions()

        return SignalSnapshot(
            aggregate: aggregateForSignalLightScope(sessions: displaySessions),
            sessions: displaySessions,
            recentEvents: snapshot.recentEvents,
            stateFileURL: snapshot.stateFileURL,
            updatedAt: snapshot.updatedAt
        )
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        guard enabled != isLaunchAtLoginEnabled else { return }
        guard !isLaunchAtLoginChangeRunning else { return }

        isLaunchAtLoginChangeRunning = true
        isLaunchAtLoginEnabled = enabled
        let manager = launchAtLoginManager

        Task { [weak self] in
            let result = await Self.updateLaunchAtLogin(manager: manager, enabled: enabled)

            guard let self else { return }
            isLaunchAtLoginEnabled = result.isEnabled
            lastError = result.errorMessage
            isLaunchAtLoginChangeRunning = false
        }
    }

    func toggleLaunchAtLogin() {
        setLaunchAtLoginEnabled(!isLaunchAtLoginEnabled)
    }

    nonisolated private static func updateLaunchAtLogin(
        manager: LaunchAtLoginManager,
        enabled: Bool
    ) async -> LaunchAtLoginUpdateResult {
        await Task.detached(priority: .userInitiated) {
            do {
                try manager.setEnabled(enabled)
                return LaunchAtLoginUpdateResult(isEnabled: manager.isEnabled, errorMessage: nil)
            } catch {
                return LaunchAtLoginUpdateResult(
                    isEnabled: manager.isEnabled,
                    errorMessage: error.localizedDescription
                )
            }
        }.value
    }

    func previewHookInstall() {
        runHookInstall { manager in
            try manager.preview()
        }
    }

    func installHooks() {
        runHookInstall { manager in
            try manager.install()
        }
    }

    func previewClaudeHookInstall() {
        runHookInstall { manager in
            try manager.previewClaude()
        }
    }

    func installClaudeHooks() {
        runHookInstall { manager in
            try manager.installClaude()
        }
    }

    func openCodex() {
        openAgentApplication(appName: "Codex", displayName: "Codex")
    }

    func openClaude() {
        openAgentApplication(appName: "Claude", displayName: "Claude")
    }

    func showStateFile() {
        NSWorkspace.shared.activateFileViewerSelecting([snapshot.stateFileURL])
    }

    func copyStateFilePath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(snapshot.stateFileURL.path, forType: .string)
    }

    func showReleaseInfoFile() {
        guard let releaseFileURL = releaseInfo.releaseFileURL else {
            lastError = text("没有找到 release 信息文件。", "Release info file was not found.")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([releaseFileURL])
    }

    func copyReleaseInfo() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(releaseInfo.clipboardText, forType: .string)
    }

    func checkForUpdates() {
        let prefix = text("当前版本", "Current version")
        let suffix = text("暂无可用更新。", "No updates are available.")
        updateCheckMessage = "\(prefix) \(releaseInfo.version)。\(suffix)"
        lastError = nil
    }

    func copyGenericAgentHookCommand() {
        guard let hookURL = genericAgentHookURL() else {
            lastError = text("没有找到通用 Agent hook 脚本。", "Generic agent hook script was not found.")
            return
        }

        let escapedPath = hookURL.path.replacingOccurrences(of: "\"", with: "\\\"")
        let command = """
        printf '{"event":"AgentStarted","agent":"local-script","session_id":"local-script-main"}' | "\(escapedPath)"
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        hookInstallMessage = text("已复制通用 Agent Hook 命令。", "Generic agent hook command copied.")
        lastError = nil
    }

    func exportDiagnostics() {
        guard !isDiagnosticsExportRunning else { return }
        isDiagnosticsExportRunning = true
        diagnosticsExportMessage = text("正在导出诊断...", "Exporting diagnostics...")
        lastError = nil

        let manager = diagnosticsExportManager
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try manager.export()
            }

            Task { @MainActor in
                self.isDiagnosticsExportRunning = false
                switch result {
                case .success(let output):
                    self.diagnosticsExportMessage = output.displayText
                    self.lastError = nil
                    if let archiveURL = output.archiveURL {
                        NSWorkspace.shared.activateFileViewerSelecting([archiveURL])
                    }
                case .failure(let error):
                    self.lastError = error.localizedDescription
                    self.diagnosticsExportMessage = nil
                }
            }
        }
    }

    private func startTimers() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.statePollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.reloadFromWatcher()
            }
        }
        pollTimer?.tolerance = 0.5

        animationTimer = Timer.scheduledTimer(withTimeInterval: Self.animationTickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard self.shouldAnimateCurrentSignal else {
                    self.animationClock.reset()
                    return
                }
                self.animationClock.advance()
            }
        }
        animationTimer?.tolerance = 0.05

        codexDesktopTimer = Timer.scheduledTimer(withTimeInterval: Self.agentPollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollCodexDesktopActivity()
            }
        }
        codexDesktopTimer?.tolerance = 0.5

        desktopAppTimer = Timer.scheduledTimer(
            withTimeInterval: Self.desktopAppPresencePollInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.pollDesktopAppPresence()
            }
        }
        desktopAppTimer?.tolerance = 2.0
    }

    private var shouldAnimateCurrentSignal: Bool {
        guard !isStatusBarAllLightsOn else { return false }

        let aggregate = displaySnapshot.aggregate
        switch aggregate.displayState {
        case .ready, .paused:
            return false
        case .active:
            let effect = aggregate == .thinking ? thinkingSignalEffect : activeSignalEffect
            return effect != .greenSteady
        case .completed:
            switch completedSignalEffect {
            case .greenSteady, .yellowSteady, .allSteady:
                return false
            case .greenPulse, .yellowPulse, .allPulse:
                return true
            }
        case .needsReview, .permission, .blocked, .stale:
            return true
        }
    }

    private func pollCodexDesktopActivity() {
        guard isCodexDesktopMonitoringEnabled, !isMonitoringPaused else { return }
        guard let activity = codexDesktopActivityMonitor.poll() else { return }

        do {
            snapshot = try store.applySessionSignal(
                activity.signal,
                sessionID: activity.sessionID,
                agent: "codex-desktop",
                lastEvent: activity.event
            )
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func pollDesktopAppPresence() {
        let latestSessions = Self.detectDesktopAppSessions()
        if latestSessions != desktopAppSessions {
            desktopAppSessions = latestSessions
        }
    }

    private func combinedDisplaySessions() -> [SessionStatus] {
        var sessions = snapshot.sessions
        let now = Date()
        let liveAgentKeys = Set(
            sessions.compactMap { session -> String? in
                guard Self.shouldSuppressDesktopPresence(for: session, now: now) else { return nil }
                return Self.normalizedAgentKey(session.agent, fallback: session.sessionID)
            }
        )

        for desktopSession in desktopAppSessions {
            let agentKey = Self.normalizedAgentKey(desktopSession.agent, fallback: desktopSession.sessionID)
            guard !liveAgentKeys.contains(agentKey) else { continue }
            sessions.append(desktopSession)
        }

        return sessions.sorted { lhs, rhs in
            if lhs.signal.displayState.priority != rhs.signal.displayState.priority {
                return lhs.signal.displayState.priority > rhs.signal.displayState.priority
            }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    private func aggregateForSignalLightScope(sessions: [SessionStatus]) -> AgentSignal {
        if isSignalTestModeEnabled, Self.snapshotContainsSignalTest(snapshot) {
            return snapshot.aggregate
        }

        let selectedAgentKey = signalLightAgentScope.agentKey
        let selectedSignals = sessions.compactMap { session -> AgentSignal? in
            let agentKey = Self.normalizedAgentKey(session.agent, fallback: session.sessionID)
            guard agentKey == selectedAgentKey else { return nil }
            return session.signal
        }

        return selectedSignals
            .max { lhs, rhs in lhs.displayState.priority < rhs.displayState.priority }?
            .normalizedAggregateSignal ?? .idle
    }

    private static func detectDesktopAppSessions() -> [SessionStatus] {
        let runningApplications = NSWorkspace.shared.runningApplications
        let now = Date()

        return desktopAgentApps.compactMap { app in
            let isRunning = runningApplications.contains { runningApp in
                if let bundleIdentifier = runningApp.bundleIdentifier?.lowercased(),
                   app.bundleIdentifiers.contains(bundleIdentifier) {
                    return true
                }

                let localizedName = runningApp.localizedName?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                return localizedName.map(app.appNames.contains) ?? false
            }

            guard isRunning else { return nil }
            return SessionStatus(
                sessionID: app.sessionID,
                signal: .idle,
                updatedAt: now,
                agent: app.agent,
                lastEvent: app.event
            )
        }
    }

    private static func shouldSuppressDesktopPresence(for session: SessionStatus, now: Date) -> Bool {
        switch session.signal.displayState {
        case .active:
            return now.timeIntervalSince(session.updatedAt) <= desktopAppSuppressionWindow
        case .needsReview, .permission, .blocked, .stale:
            return true
        case .ready, .completed, .paused:
            return false
        }
    }

    private static func normalizedAgentKey(_ agent: String?, fallback: String) -> String {
        guard let agent, !agent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return fallback
        }

        let normalized = agent
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")

        switch normalized {
        case "claude", "claude-code", "claude-desktop":
            return "claude"
        case "codex", "codex-desktop", "codex-cli", "codex-ide":
            return "codex"
        default:
            return normalized
        }
    }

    private func genericAgentHookURL() -> URL? {
        bundledScriptURL(named: "generic-agent-signal-hook")
    }

    private func bundledScriptURL(named scriptName: String) -> URL? {
        var candidates: [URL] = []

        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL.appendingPathComponent("scripts/\(scriptName)"))
        }

        let bundleURL = Bundle.main.bundleURL.standardizedFileURL
        let distParent = bundleURL.deletingLastPathComponent()
        if distParent.lastPathComponent == "dist" {
            candidates.append(
                distParent
                    .deletingLastPathComponent()
                    .appendingPathComponent("scripts/\(scriptName)")
            )
        }

        candidates.append(
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("scripts/\(scriptName)")
        )

        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private func openAgentApplication(appName: String, displayName: String) {
        let candidates = [
            URL(fileURLWithPath: "/Applications/\(appName).app"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/\(appName).app")
        ]

        guard let appURL = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            lastError = text("没有找到 \(displayName).app。", "\(displayName).app was not found.")
            return
        }

        NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
        lastError = nil
    }

    private func runHookInstall(_ action: @escaping @Sendable (HookInstallManager) throws -> HookInstallResult) {
        guard !isHookInstallRunning else { return }
        isHookInstallRunning = true
        hookInstallMessage = text("正在处理 hooks...", "Processing hooks...")
        lastError = nil

        let manager = hookInstallManager
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try action(manager)
            }

            Task { @MainActor in
                self.isHookInstallRunning = false
                switch result {
                case .success(let output):
                    self.hookInstallMessage = output.displayText
                    self.lastError = nil
                case .failure(let error):
                    self.lastError = error.localizedDescription
                    self.hookInstallMessage = nil
                }
            }
        }
    }
}

private extension MenuBarStatusModel {
    static func snapshotContainsSignalTest(_ snapshot: SignalSnapshot) -> Bool {
        snapshot.sessions.contains { $0.sessionID == "manual" }
    }
}

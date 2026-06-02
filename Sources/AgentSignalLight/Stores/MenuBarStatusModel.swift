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
    case reduced
    case standard

    static func preferenceValue(for rawValue: String?) -> SettingsGlassEffect? {
        guard let rawValue else { return nil }
        if rawValue == "enhanced" {
            return .standard
        }
        return SettingsGlassEffect(rawValue: rawValue)
    }
}

enum StatusMenuMode: String, CaseIterable, Hashable {
    case detailed
    case simple
}

struct StatusLightOverrideFrame: Equatable {
    let signal: AgentSignal
    let tick: Int
    let allLightsOn: Bool
    let usesSystemGrayLights: Bool
    let effectCustomization: SignalEffectCustomization

    init(
        signal: AgentSignal,
        tick: Int,
        allLightsOn: Bool,
        usesSystemGrayLights: Bool = false,
        effectCustomization: SignalEffectCustomization
    ) {
        self.signal = signal
        self.tick = tick
        self.allLightsOn = allLightsOn
        self.usesSystemGrayLights = usesSystemGrayLights
        self.effectCustomization = effectCustomization
    }
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
    @Published var signalLightAgentScope: SignalLightAgentScope
    @Published var statusMenuMode: StatusMenuMode
    @Published var isCodexDesktopMonitoringEnabled: Bool
    @Published var appLanguage: AppLanguage
    @Published var appTheme: AppTheme
    @Published var isSettingsGlassEnabled: Bool
    @Published var settingsGlassEffect: SettingsGlassEffect
    @Published var isMonitoringPaused = false
    @Published private(set) var statusLightOverride: StatusLightOverrideFrame?
    @Published private(set) var desktopAppSessions: [SessionStatus] = []
    @Published private(set) var isLaunchAtLoginEnabled = false
    @Published private(set) var isLaunchAtLoginChangeRunning = false
    @Published var isHookInstallRunning = false
    @Published var hookInstallMessage: String?
    @Published var isDiagnosticsExportRunning = false
    @Published var diagnosticsExportMessage: String?
    @Published private(set) var releaseInfo: ReleaseInfo = .current()
    @Published private(set) var isUpdateCheckRunning = false
    @Published var updateCheckMessage: String?
    @Published private(set) var updateReleasePageURL: URL?
    @Published var lastError: String?

    let animationClock = SignalAnimationClock()

    private let store: SignalStateStore
    private let launchAtLoginManager: LaunchAtLoginManager
    private let hookInstallManager: HookInstallManager
    private let diagnosticsExportManager: DiagnosticsExportManager
    private let codexDesktopActivityMonitor: CodexDesktopActivityMonitor
    private let updateChecker: GitHubReleaseUpdateChecker
    private let codexDesktopPollQueue = DispatchQueue(label: "com.agentsignallight.codex-desktop-poll")
    private var pollTimer: Timer?
    private var animationTimer: Timer?
    private var codexDesktopTimer: Timer?
    private var desktopAppTimer: Timer?
    private var watcher: StateFileWatcher?
    private static let recentEventDeduplicationWindow: TimeInterval = 4
    private static let completedDisplayWindow: TimeInterval = 90
    private static let recentActivityFallbackWindow: TimeInterval = 5 * 60
    private static let desktopPresenceSuppressionWindow: TimeInterval = 5 * 60
    private var statusLightSequence: [StatusLightOverrideFrame] = []
    private var statusLightSequenceIndex = 0
    private var isCodexDesktopPollInFlight = false

    private static let defaultDisplayLayout: TrafficSignalLayout = .horizontal
    private static let defaultStatusBarStyle: TrafficSignalStyle = .macOS
    private static let defaultMacOSHorizontalUsesTrafficLightSize = true
    private static let defaultTrafficLightVerticalUsesMacOSSize = false
    private static let effectDefaultsVersion = 2
    private static let statePollInterval: TimeInterval = 0.75
    private static let animationTickInterval: TimeInterval = 0.25
    private static let agentPollInterval: TimeInterval = 0.5
    private static let desktopAppPresencePollInterval: TimeInterval = 3.0
    private static let activeDisplayWindow: TimeInterval = SignalStateStore.defaultSessionTTL()

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
        codexDesktopActivityMonitor: CodexDesktopActivityMonitor = CodexDesktopActivityMonitor(),
        updateChecker: GitHubReleaseUpdateChecker = GitHubReleaseUpdateChecker()
    ) {
        self.store = store
        self.launchAtLoginManager = launchAtLoginManager
        self.hookInstallManager = hookInstallManager
        self.diagnosticsExportManager = diagnosticsExportManager
        self.codexDesktopActivityMonitor = codexDesktopActivityMonitor
        self.updateChecker = updateChecker
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
        let storedStatusMenuMode = UserDefaults.standard.string(forKey: "statusMenuMode")
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
            SettingsGlassEffect.preferenceValue(for: storedSettingsGlassEffect) ?? .reduced
        macOSHorizontalUsesTrafficLightSize =
            UserDefaults.standard.object(forKey: "macOSHorizontalUsesTrafficLightSize") as? Bool
            ?? UserDefaults.standard.object(forKey: "macOSUsesTrafficLightSize") as? Bool
            ?? Self.defaultMacOSHorizontalUsesTrafficLightSize
        trafficLightVerticalUsesMacOSSize =
            UserDefaults.standard.object(forKey: "trafficLightVerticalUsesMacOSSize") as? Bool
            ?? Self.defaultTrafficLightVerticalUsesMacOSSize
        let storedStatusBarIconEnabled = UserDefaults.standard.object(forKey: "isStatusBarIconEnabled") as? Bool ?? true
        isStatusBarIconEnabled = DebugLaunchOptions.shouldForceStatusBarIconEnabled ? true : storedStatusBarIconEnabled
        UserDefaults.standard.set(false, forKey: "isStatusBarAllLightsOn")
        signalLightAgentScope = storedSignalLightAgentScope.flatMap(SignalLightAgentScope.init(rawValue:)) ?? .codex
        statusMenuMode = storedStatusMenuMode.flatMap(StatusMenuMode.init(rawValue:)) ?? .detailed
        isCodexDesktopMonitoringEnabled =
            UserDefaults.standard.object(forKey: "isCodexDesktopMonitoringEnabled") as? Bool ?? true
        snapshot = store.readSnapshot()
        isLaunchAtLoginEnabled = launchAtLoginManager.isEnabled
        desktopAppSessions = Self.detectDesktopAppSessions()
        watcher = StateFileWatcher(stateFileURL: snapshot.stateFileURL) { [weak self] in
            self?.reloadFromWatcher()
        }
        watcher?.start()
        startTimers()
        startMonitoringResumeLightSequence()
    }

    func reload() {
        let latestSnapshot = store.readSnapshot()
        if latestSnapshot != snapshot {
            snapshot = latestSnapshot
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

    func setMonitoringPaused(_ paused: Bool) {
        guard paused != isMonitoringPaused else { return }
        isMonitoringPaused = paused

        if paused {
            startMonitoringPauseLightSequence()
        } else {
            reload()
            startMonitoringResumeLightSequence()
        }
    }

    func toggleMonitoring() {
        setMonitoringPaused(!isMonitoringPaused)
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

    var lightSnapshot: SignalSnapshot {
        let baseSnapshot = displaySnapshot
        if let statusLightOverride {
            return snapshot(baseSnapshot, overridingAggregate: statusLightOverride.signal)
        }

        if isMonitoringPaused {
            return snapshot(baseSnapshot, overridingAggregate: .off)
        }

        return baseSnapshot
    }

    var lightTick: Int {
        statusLightOverride?.tick ?? animationClock.tick
    }

    var lightAllLightsOn: Bool {
        if statusLightOverride == nil, isMonitoringPaused {
            return true
        }

        return statusLightOverride?.allLightsOn ?? false
    }

    var lightUsesSystemGrayLights: Bool {
        statusLightOverride?.usesSystemGrayLights ?? isMonitoringPaused
    }

    var lightEffectCustomization: SignalEffectCustomization {
        statusLightOverride?.effectCustomization ?? signalEffectCustomization
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

    func setSignalLightAgentScope(_ scope: SignalLightAgentScope) {
        signalLightAgentScope = scope
        UserDefaults.standard.set(scope.rawValue, forKey: "signalLightAgentScope")
    }

    func setStatusMenuMode(_ mode: StatusMenuMode) {
        statusMenuMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "statusMenuMode")
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
        let displaySnapshot = lightSnapshot
        var lines = [
            "Agent Signal Bar",
            "\(displayName(for: displaySnapshot.aggregate)) - \(humanAction(for: displaySnapshot.aggregate))"
        ]

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
        let scopedDisplaySessions = displaySessions.filter { sessionMatchesSignalLightScope($0) }
        let deduplicatedSessions = deduplicatedDisplaySessions(scopedDisplaySessions)
        let scopedRecentEvents = snapshot.recentEvents
            .filter { !Self.isSignalTestEvent($0.event) }
            .filter { recentEventMatchesSignalLightScope($0) }
        let deduplicatedRecentEvents = deduplicatedRecentEvents(scopedRecentEvents)
        let displayUpdatedAt = deduplicatedSessions.map(\.updatedAt).max()

        return SignalSnapshot(
            aggregate: aggregateForSignalLightScope(
                sessions: scopedDisplaySessions,
                fallback: snapshot.aggregate
            ),
            sessions: deduplicatedSessions,
            recentEvents: deduplicatedRecentEvents,
            stateFileURL: snapshot.stateFileURL,
            updatedAt: displayUpdatedAt ?? snapshot.updatedAt
        )
    }

    var activitySnapshot: SignalSnapshot {
        let displaySessions = combinedDisplaySessions()
        let visibleRecentEvents = snapshot.recentEvents
            .filter { !Self.isSignalTestEvent($0.event) }
        let deduplicatedRecentEvents = deduplicatedRecentEvents(visibleRecentEvents)
        let displayUpdatedAt = displaySessions.map(\.updatedAt).max()

        return SignalSnapshot(
            aggregate: aggregateForSessions(displaySessions, fallback: snapshot.aggregate),
            sessions: displaySessions,
            recentEvents: deduplicatedRecentEvents,
            stateFileURL: snapshot.stateFileURL,
            updatedAt: displayUpdatedAt ?? snapshot.updatedAt
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

    func previewCodexHookInstall() {
        runHookInstall { manager in
            try manager.previewCodex()
        }
    }

    func installCodexHooks() {
        runHookInstall { manager in
            try manager.installCodex()
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
        guard !isUpdateCheckRunning else { return }

        let currentVersion = releaseInfo.version
        let checker = updateChecker
        isUpdateCheckRunning = true
        updateReleasePageURL = nil
        updateCheckMessage = text("正在检查 GitHub Releases...", "Checking GitHub Releases...")
        lastError = nil

        Task {
            do {
                let result = try await checker.check(currentVersion: currentVersion)
                await MainActor.run {
                    self.isUpdateCheckRunning = false
                    self.updateReleasePageURL = result.isUpdateAvailable ? result.releasePageURL : nil
                    if result.isUpdateAvailable {
                        self.updateCheckMessage = self.text(
                            "发现新版本 \(result.latestVersion)（当前 \(result.currentVersion)）。",
                            "Version \(result.latestVersion) is available. Current version: \(result.currentVersion)."
                        )
                    } else {
                        self.updateCheckMessage = self.text(
                            "当前版本 \(result.currentVersion)。已是最新版本。",
                            "Current version \(result.currentVersion). You are up to date."
                        )
                    }
                    self.lastError = nil
                }
            } catch {
                let errorMessage = error.localizedDescription
                await MainActor.run {
                    self.isUpdateCheckRunning = false
                    self.updateReleasePageURL = GitHubReleaseUpdateChecker.fallbackReleasePageURL
                    self.updateCheckMessage = self.text(
                        "检查更新失败：\(errorMessage)",
                        "Update check failed: \(errorMessage)"
                    )
                    self.lastError = nil
                }
            }
        }
    }

    func openLatestReleasePage() {
        let url = updateReleasePageURL ?? GitHubReleaseUpdateChecker.fallbackReleasePageURL
        NSWorkspace.shared.open(url)
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
        let pollTimer = Timer(timeInterval: Self.statePollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.reloadFromWatcher()
            }
        }
        pollTimer.tolerance = 0.15
        RunLoop.main.add(pollTimer, forMode: .common)
        self.pollTimer = pollTimer

        let animationTimer = Timer(timeInterval: Self.animationTickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.advanceStatusLightSequenceIfNeeded() {
                    return
                }
                guard self.shouldAnimateCurrentSignal else {
                    self.animationClock.reset()
                    return
                }
                self.animationClock.advance()
            }
        }
        animationTimer.tolerance = 0.05
        RunLoop.main.add(animationTimer, forMode: .common)
        self.animationTimer = animationTimer

        let codexDesktopTimer = Timer(timeInterval: Self.agentPollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollCodexDesktopActivity()
            }
        }
        codexDesktopTimer.tolerance = 0.1
        RunLoop.main.add(codexDesktopTimer, forMode: .common)
        self.codexDesktopTimer = codexDesktopTimer

        let desktopAppTimer = Timer(
            timeInterval: Self.desktopAppPresencePollInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.pollDesktopAppPresence()
            }
        }
        desktopAppTimer.tolerance = 0.5
        RunLoop.main.add(desktopAppTimer, forMode: .common)
        self.desktopAppTimer = desktopAppTimer
    }

    private func startMonitoringResumeLightSequence() {
        startStatusLightSequence(Self.monitoringResumeLightSequence)
    }

    private func startMonitoringPauseLightSequence() {
        startStatusLightSequence(Self.monitoringPauseLightSequence)
    }

    private func startStatusLightSequence(_ frames: [StatusLightOverrideFrame]) {
        guard let firstFrame = frames.first else {
            statusLightSequence = []
            statusLightSequenceIndex = 0
            statusLightOverride = nil
            return
        }

        statusLightSequence = frames
        statusLightSequenceIndex = 0
        statusLightOverride = firstFrame
    }

    private func advanceStatusLightSequenceIfNeeded() -> Bool {
        guard !statusLightSequence.isEmpty else { return false }

        let nextIndex = statusLightSequenceIndex + 1
        if nextIndex < statusLightSequence.count {
            statusLightSequenceIndex = nextIndex
            statusLightOverride = statusLightSequence[nextIndex]
        } else {
            statusLightSequence = []
            statusLightSequenceIndex = 0
            statusLightOverride = nil
        }

        return true
    }

    private static var monitoringTransitionCustomization: SignalEffectCustomization {
        SignalEffectCustomization(
            thinkingEffect: .trafficCycle,
            activeEffect: .trafficCycle,
            activeSpeed: .standard,
            alertSpeed: .standard,
            completedEffect: .allSteady
        )
    }

    private static var monitoringResumeLightSequence: [StatusLightOverrideFrame] {
        let customization = monitoringTransitionCustomization
        return [
            StatusLightOverrideFrame(signal: .done, tick: 0, allLightsOn: true, effectCustomization: customization),
            StatusLightOverrideFrame(signal: .done, tick: 0, allLightsOn: true, effectCustomization: customization),
            StatusLightOverrideFrame(signal: .working, tick: 0, allLightsOn: false, effectCustomization: customization),
            StatusLightOverrideFrame(signal: .working, tick: 0, allLightsOn: false, effectCustomization: customization),
            StatusLightOverrideFrame(signal: .working, tick: 4, allLightsOn: false, effectCustomization: customization),
            StatusLightOverrideFrame(signal: .working, tick: 4, allLightsOn: false, effectCustomization: customization),
            StatusLightOverrideFrame(signal: .working, tick: 8, allLightsOn: false, effectCustomization: customization),
            StatusLightOverrideFrame(signal: .working, tick: 8, allLightsOn: false, effectCustomization: customization)
        ]
    }

    private static var monitoringPauseLightSequence: [StatusLightOverrideFrame] {
        let customization = monitoringTransitionCustomization
        return [
            StatusLightOverrideFrame(
                signal: .off,
                tick: 0,
                allLightsOn: true,
                usesSystemGrayLights: true,
                effectCustomization: customization
            )
        ]
    }

    private var shouldAnimateCurrentSignal: Bool {
        let aggregate = lightSnapshot.aggregate
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
        guard !isCodexDesktopPollInFlight else { return }

        isCodexDesktopPollInFlight = true
        let monitor = codexDesktopActivityMonitor
        let store = store

        codexDesktopPollQueue.async { [weak self] in
            let activities = monitor.poll()
            var latestSnapshot: SignalSnapshot?
            var errorMessage: String?

            if !activities.isEmpty {
                do {
                    for activity in activities {
                        latestSnapshot = try store.applySessionSignal(
                            activity.signal,
                            sessionID: activity.sessionID,
                            agent: "codex-desktop",
                            lastEvent: activity.event,
                            updatedAt: activity.timestamp ?? Date()
                        )
                    }
                } catch {
                    errorMessage = error.localizedDescription
                }
            }

            DispatchQueue.main.async { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.isCodexDesktopPollInFlight = false
                    if let latestSnapshot {
                        self.snapshot = latestSnapshot
                    }
                    self.lastError = errorMessage
                }
            }
        }
    }

    private func pollDesktopAppPresence() {
        let latestSessions = Self.detectDesktopAppSessions()
        if latestSessions != desktopAppSessions {
            desktopAppSessions = latestSessions
        }
    }

    private func combinedDisplaySessions() -> [SessionStatus] {
        let now = Date()
        var sessions = snapshot.sessions.filter { session in
            Self.shouldIncludeStoredSessionInDisplay(session, now: now)
        }
        sessions.append(contentsOf: recentActivityFallbackSessions(existingSessions: sessions, now: now))

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

    private func recentActivityFallbackSessions(
        existingSessions: [SessionStatus],
        now: Date
    ) -> [SessionStatus] {
        let activeAgentKeys = Set(
            existingSessions.compactMap { session -> String? in
                guard Self.shouldSuppressDesktopPresence(for: session, now: now) else { return nil }
                return Self.normalizedAgentKey(session.agent, fallback: session.sessionID)
            }
        )
        var handledAgentKeys: Set<String> = []
        var fallbackSessions: [SessionStatus] = []

        for event in snapshot.recentEvents {
            guard !Self.isSignalTestEvent(event.event) else { continue }

            let agentKey = Self.normalizedAgentKey(event.agent, fallback: event.sessionID)
            guard !activeAgentKeys.contains(agentKey),
                  !handledAgentKeys.contains(agentKey)
            else {
                continue
            }

            handledAgentKeys.insert(agentKey)
            guard event.signal.displayState == .active,
                  now.timeIntervalSince(event.updatedAt) <= Self.recentActivityFallbackWindow
            else {
                continue
            }

            fallbackSessions.append(
                SessionStatus(
                    sessionID: "recent-activity:\(agentKey)",
                    signal: event.signal,
                    updatedAt: event.updatedAt,
                    agent: event.agent,
                    lastEvent: event.event
                )
            )
        }

        return fallbackSessions
    }

    private func deduplicatedDisplaySessions(_ sessions: [SessionStatus]) -> [SessionStatus] {
        var sessionsByAgentKey: [String: SessionStatus] = [:]

        for session in sessions {
            let agentKey = Self.normalizedAgentKey(session.agent, fallback: session.sessionID)
            guard let current = sessionsByAgentKey[agentKey] else {
                sessionsByAgentKey[agentKey] = session
                continue
            }

            if Self.shouldPreferDisplaySession(session, over: current) {
                sessionsByAgentKey[agentKey] = session
            }
        }

        return sessionsByAgentKey.values.sorted { lhs, rhs in
            if lhs.signal.displayState.priority != rhs.signal.displayState.priority {
                return lhs.signal.displayState.priority > rhs.signal.displayState.priority
            }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    private static func shouldPreferDisplaySession(_ candidate: SessionStatus, over current: SessionStatus) -> Bool {
        let candidatePriority = deduplicationPriority(for: candidate.signal)
        let currentPriority = deduplicationPriority(for: current.signal)

        if candidatePriority != currentPriority {
            return candidatePriority > currentPriority
        }

        let candidateIsDesktopPresence = isDesktopPresenceSession(candidate)
        let currentIsDesktopPresence = isDesktopPresenceSession(current)
        if candidateIsDesktopPresence != currentIsDesktopPresence {
            return !candidateIsDesktopPresence
        }

        if candidate.updatedAt != current.updatedAt {
            return candidate.updatedAt > current.updatedAt
        }

        return false
    }

    private static func deduplicationPriority(for signal: AgentSignal) -> Int {
        switch signal.displayState {
        case .blocked, .permission, .needsReview, .stale, .paused:
            return signal.displayState.priority
        case .active, .completed, .ready:
            return signal.displayState.priority
        }
    }

    private func deduplicatedRecentEvents(_ events: [RecentSignalEvent]) -> [RecentSignalEvent] {
        var acceptedAtByKey: [String: Date] = [:]
        var result: [RecentSignalEvent] = []

        for event in events {
            let key = Self.recentEventDeduplicationKey(for: event)
            if let acceptedAt = acceptedAtByKey[key],
               abs(acceptedAt.timeIntervalSince(event.updatedAt)) <= Self.recentEventDeduplicationWindow {
                continue
            }

            acceptedAtByKey[key] = event.updatedAt
            result.append(event)
        }

        return result
    }

    private static func recentEventDeduplicationKey(for event: RecentSignalEvent) -> String {
        let agentKey = normalizedAgentKey(event.agent, fallback: event.sessionID)
        let semanticEvent = normalizedEventDeduplicationKey(event.event, signal: event.signal)
        return "\(agentKey)|\(semanticEvent)"
    }

    private static func normalizedEventDeduplicationKey(_ event: String?, signal: AgentSignal) -> String {
        guard let event,
              !event.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return signal.normalizedAggregateSignal.rawValue
        }

        let normalized = event
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")

        if normalized.hasPrefix("desktoptoolcall:") {
            return "tool-call:\(String(normalized.dropFirst("desktoptoolcall:".count)))"
        }

        if normalized.hasPrefix("pretooluse:") {
            return "tool-call:\(String(normalized.dropFirst("pretooluse:".count)))"
        }

        if normalized.hasPrefix("posttooluse:") || normalized.hasPrefix("posttoolusefailure:") {
            return normalized.hasPrefix("posttoolusefailure:") ? "tool-failed" : "tool-done"
        }

        switch normalized {
        case "desktopthinking", "desktoptaskstarted", "userpromptsubmit":
            return "thinking"
        case "desktopmessage", "pretooluse", "tooluse", "tool-use":
            return "tool-call"
        case "desktoptooldone", "posttooluse", "posttoolbatch", "function-call-output":
            return "tool-done"
        case "desktoptaskcomplete", "desktopturnaborted", "stop", "taskcompleted":
            return "done"
        case "permissionrequest", "permission-request":
            return "permission"
        default:
            return "\(signal.normalizedAggregateSignal.rawValue):\(normalized)"
        }
    }

    private func aggregateForSignalLightScope(
        sessions: [SessionStatus],
        fallback: AgentSignal
    ) -> AgentSignal {
        let selectedAgentKey = signalLightAgentScope.agentKey
        let selectedSignals = sessions.compactMap { session -> AgentSignal? in
            let agentKey = Self.normalizedAgentKey(session.agent, fallback: session.sessionID)
            guard agentKey == selectedAgentKey else { return nil }
            return session.signal
        }

        if let aggregate = selectedSignals
            .max(by: { lhs, rhs in lhs.displayState.priority < rhs.displayState.priority })?
            .normalizedAggregateSignal {
            return aggregate
        }

        return fallbackForEmptyDisplaySessions(fallback)
    }

    private func aggregateForSessions(
        _ sessions: [SessionStatus],
        fallback: AgentSignal
    ) -> AgentSignal {
        if let aggregate = sessions
            .map(\.signal)
            .max(by: { lhs, rhs in lhs.displayState.priority < rhs.displayState.priority })?
            .normalizedAggregateSignal {
            return aggregate
        }

        return fallbackForEmptyDisplaySessions(fallback)
    }

    private func fallbackForEmptyDisplaySessions(_ fallback: AgentSignal) -> AgentSignal {
        switch fallback.displayState {
        case .paused, .stale, .needsReview, .permission, .blocked:
            return fallback.normalizedAggregateSignal
        case .ready, .active, .completed:
            return .idle
        }
    }

    private func sessionMatchesSignalLightScope(_ session: SessionStatus) -> Bool {
        Self.normalizedAgentKey(session.agent, fallback: session.sessionID) == signalLightAgentScope.agentKey
    }

    private func recentEventMatchesSignalLightScope(_ event: RecentSignalEvent) -> Bool {
        Self.normalizedAgentKey(event.agent, fallback: event.sessionID) == signalLightAgentScope.agentKey
    }

    private func snapshot(_ snapshot: SignalSnapshot, overridingAggregate aggregate: AgentSignal) -> SignalSnapshot {
        SignalSnapshot(
            aggregate: aggregate,
            sessions: snapshot.sessions,
            recentEvents: snapshot.recentEvents,
            stateFileURL: snapshot.stateFileURL,
            updatedAt: snapshot.updatedAt
        )
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

    private static func shouldIncludeStoredSessionInDisplay(_ session: SessionStatus, now: Date) -> Bool {
        if isSignalTestEvent(session.lastEvent) {
            return false
        }

        if isDesktopPresenceSession(session) {
            return true
        }

        switch session.signal.displayState {
        case .active:
            return now.timeIntervalSince(session.updatedAt) <= activeDisplayWindow
        case .completed:
            return now.timeIntervalSince(session.updatedAt) <= completedDisplayWindow
        case .needsReview, .permission, .blocked, .stale:
            return true
        case .ready, .paused:
            return false
        }
    }

    private static func shouldSuppressDesktopPresence(for session: SessionStatus, now: Date) -> Bool {
        if isSignalTestEvent(session.lastEvent) {
            return false
        }

        switch session.signal.displayState {
        case .active:
            return now.timeIntervalSince(session.updatedAt) <= desktopPresenceSuppressionWindow
        case .needsReview, .permission, .blocked, .stale:
            return true
        case .ready, .completed, .paused:
            return false
        }
    }

    private static func isDesktopPresenceSession(_ session: SessionStatus) -> Bool {
        session.sessionID.hasPrefix("desktop-app:") || session.lastEvent == "DesktopAppRunning"
    }

    private static func isSignalTestEvent(_ event: String?) -> Bool {
        event == "SignalTest" || event == "SignalTestOff"
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

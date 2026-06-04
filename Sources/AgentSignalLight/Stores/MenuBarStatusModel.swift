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

enum SignalLightAgentScopeGroup: Int, CaseIterable, Hashable {
    case codex
    case claude
    case other
}

enum SignalLightAgentScope: String, CaseIterable, Hashable {
    case codex
    case claude
    case codexDesktop = "codex-desktop"
    case codexCLI = "codex-cli"
    case codexVSCode = "codex-vscode"
    case codexXcode = "codex-xcode"
    case codexIDEA = "codex-idea"
    case claudeCode = "claude-code"
    case claudeDesktop = "claude-desktop"
    case localScript = "local-script"

    static let selectableCases: [SignalLightAgentScope] = [
        .codexDesktop,
        .codexCLI,
        .codexVSCode,
        .codexXcode,
        .codexIDEA,
        .claudeCode,
        .localScript
    ]

    static let allCases: [SignalLightAgentScope] = selectableCases

    static let defaultSelectedCases: Set<SignalLightAgentScope> = [
        .codexDesktop,
        .codexCLI,
        .codexVSCode,
        .codexXcode,
        .codexIDEA
    ]

    static let codexCases: Set<SignalLightAgentScope> = [
        .codexDesktop,
        .codexCLI,
        .codexVSCode,
        .codexXcode,
        .codexIDEA
    ]

    static let claudeCases: Set<SignalLightAgentScope> = [
        .claudeCode
    ]

    var group: SignalLightAgentScopeGroup {
        switch self {
        case .codex, .codexDesktop, .codexCLI, .codexVSCode, .codexXcode, .codexIDEA:
            return .codex
        case .claude, .claudeCode, .claudeDesktop:
            return .claude
        case .localScript:
            return .other
        }
    }

    var sortOrder: Int {
        switch self {
        case .codexDesktop:
            return 0
        case .codexCLI:
            return 1
        case .codexVSCode:
            return 2
        case .codexXcode:
            return 3
        case .codexIDEA:
            return 4
        case .claudeCode:
            return 5
        case .claudeDesktop:
            return 6
        case .localScript:
            return 7
        case .codex:
            return 100
        case .claude:
            return 101
        }
    }

    var expandedSelection: Set<SignalLightAgentScope> {
        switch self {
        case .codex:
            return Self.codexCases
        case .claude:
            return Self.claudeCases
        default:
            return Self.selectableCases.contains(self) ? [self] : []
        }
    }

    func matches(session: SessionStatus) -> Bool {
        matches(
            sourceKey: ActivityPresentation.activitySourceKey(for: session),
            agent: session.agent,
            sessionID: session.sessionID
        )
    }

    func matches(event: RecentSignalEvent) -> Bool {
        matches(
            sourceKey: ActivityPresentation.activitySourceKey(for: event),
            agent: event.agent,
            sessionID: event.sessionID
        )
    }

    private func matches(sourceKey: String, agent: String?, sessionID: String) -> Bool {
        let normalizedAgent = Self.normalizedAgentName(agent)
        let normalizedSessionID = sessionID.lowercased()

        switch self {
        case .codex:
            return sourceKey.hasPrefix("codex:")
        case .claude:
            return sourceKey.hasPrefix("claude:")
        case .codexDesktop:
            return sourceKey == "codex:desktop"
                || normalizedAgent == "codex-desktop"
                || normalizedSessionID.hasPrefix("codex-desktop:")
        case .codexCLI:
            return sourceKey == "codex:terminal"
                || normalizedAgent == "codex-cli"
                || normalizedAgent == "codex-terminal"
                || normalizedSessionID.hasPrefix("codex-cli:")
        case .codexVSCode:
            return sourceKey == "codex:ide:vs-code"
                || normalizedAgent == "codex-vscode"
                || normalizedAgent == "vscode-codex"
                || normalizedSessionID.hasPrefix("codex-vscode:")
        case .codexXcode:
            return sourceKey == "codex:ide:xcode"
                || normalizedAgent == "codex-xcode"
                || normalizedAgent == "xcode-codex"
                || normalizedSessionID.hasPrefix("codex-xcode:")
        case .codexIDEA:
            return sourceKey == "codex:ide:idea"
                || sourceKey == "codex:ide:jetbrains"
                || normalizedAgent == "codex-idea"
                || normalizedAgent == "codex-intellij"
                || normalizedAgent == "codex-jetbrains"
                || normalizedSessionID.hasPrefix("codex-idea:")
        case .claudeCode:
            return sourceKey == "claude:terminal"
                || sourceKey == "claude:desktop"
                || normalizedAgent == "claude-code"
                || normalizedAgent == "claude-cli"
                || normalizedAgent == "claude-desktop"
                || normalizedSessionID.hasPrefix("claude-code:")
                || normalizedSessionID.hasPrefix("claude-cli:")
                || normalizedSessionID.hasPrefix("claude-desktop:")
        case .claudeDesktop:
            return sourceKey == "claude:desktop"
                || normalizedAgent == "claude-desktop"
                || normalizedSessionID.hasPrefix("claude-desktop:")
        case .localScript:
            return !sourceKey.hasPrefix("codex:")
                && !sourceKey.hasPrefix("claude:")
                && !normalizedAgent.isEmpty
        }
    }

    private static func normalizedAgentName(_ agent: String?) -> String {
        guard let agent else { return "" }
        return agent
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")
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

enum HookInstallOperation: Hashable {
    case preview
    case install
    case uninstall
    case message
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
    @Published var signalLightAgentScopes: Set<SignalLightAgentScope>
    @Published var statusMenuMode: StatusMenuMode
    @Published var isCodexDesktopMonitoringEnabled: Bool
    @Published var isClaudeDesktopMonitoringEnabled: Bool
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
    @Published var hookInstallOperation: HookInstallOperation = .message
    @Published var isDiagnosticsExportRunning = false
    @Published var diagnosticsExportMessage: String?
    @Published private(set) var releaseInfo: ReleaseInfo = .current()
    @Published private(set) var isUpdateCheckRunning = false
    @Published var updateCheckMessage: String?
    @Published private(set) var updateReleasePageURL: URL?
    @Published var lastError: String?
    @Published private(set) var presentationRefreshTick = 0

    let animationClock = SignalAnimationClock()

    private let store: SignalStateStore
    private let launchAtLoginManager: LaunchAtLoginManager
    private let hookInstallManager: HookInstallManager
    private let diagnosticsExportManager: DiagnosticsExportManager
    private let codexDesktopActivityMonitor: CodexDesktopActivityMonitor
    private let codexPlatformPresenceMonitor: CodexPlatformPresenceMonitor
    private let updateChecker: GitHubReleaseUpdateChecker
    private let codexDesktopPollQueue = DispatchQueue(label: "com.agentsignallight.codex-desktop-poll")
    private let platformPresencePollQueue = DispatchQueue(label: "com.agentsignallight.platform-presence-poll")
    private var pollTimer: Timer?
    private var animationTimer: Timer?
    private var presentationTimer: Timer?
    private var codexDesktopTimer: Timer?
    private var desktopAppTimer: Timer?
    private var watcher: StateFileWatcher?
    private static let recentEventDeduplicationWindow: TimeInterval = 4
    private static let completedDisplayWindow: TimeInterval = 30
    private static let recentActivityFallbackWindow: TimeInterval = 5 * 60
    private static let desktopPresenceSuppressionWindow: TimeInterval = 5 * 60
    private static let passiveActiveDisplayWindow: TimeInterval = 45
    private var statusLightSequence: [StatusLightOverrideFrame] = []
    private var statusLightSequenceIndex = 0
    private var isCodexDesktopPollInFlight = false
    private var isPlatformPresencePollInFlight = false

    private static let defaultDisplayLayout: TrafficSignalLayout = .horizontal
    private static let defaultStatusBarStyle: TrafficSignalStyle = .macOS
    private static let defaultMacOSHorizontalUsesTrafficLightSize = true
    private static let defaultTrafficLightVerticalUsesMacOSSize = false
    private static let effectDefaultsVersion = 2
    private static let statePollInterval: TimeInterval = 0.75
    private static let animationTickInterval: TimeInterval = 0.25
    private static let agentPollInterval: TimeInterval = 0.5
    private static let desktopAppPresencePollInterval: TimeInterval = 1.0
    private static let activeDisplayWindow: TimeInterval = SignalStateStore.defaultSessionTTL()

    private struct LaunchAtLoginUpdateResult: Sendable {
        let isEnabled: Bool
        let errorMessage: String?
    }

    init(
        store: SignalStateStore = SignalStateStore(),
        launchAtLoginManager: LaunchAtLoginManager = LaunchAtLoginManager(),
        hookInstallManager: HookInstallManager = HookInstallManager(),
        diagnosticsExportManager: DiagnosticsExportManager = DiagnosticsExportManager(),
        codexDesktopActivityMonitor: CodexDesktopActivityMonitor = CodexDesktopActivityMonitor(),
        codexPlatformPresenceMonitor: CodexPlatformPresenceMonitor = CodexPlatformPresenceMonitor(),
        updateChecker: GitHubReleaseUpdateChecker = GitHubReleaseUpdateChecker()
    ) {
        self.store = store
        self.launchAtLoginManager = launchAtLoginManager
        self.hookInstallManager = hookInstallManager
        self.diagnosticsExportManager = diagnosticsExportManager
        self.codexDesktopActivityMonitor = codexDesktopActivityMonitor
        self.codexPlatformPresenceMonitor = codexPlatformPresenceMonitor
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
        let storedSignalLightAgentScopes = UserDefaults.standard.stringArray(forKey: "signalLightAgentScopes")
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
        signalLightAgentScopes = Self.resolvedSignalLightAgentScopes(
            storedScopes: storedSignalLightAgentScopes,
            legacyScope: storedSignalLightAgentScope
        )
        statusMenuMode = storedStatusMenuMode.flatMap(StatusMenuMode.init(rawValue:)) ?? .detailed
        isCodexDesktopMonitoringEnabled =
            UserDefaults.standard.object(forKey: "isCodexDesktopMonitoringEnabled") as? Bool ?? true
        isClaudeDesktopMonitoringEnabled =
            UserDefaults.standard.object(forKey: "isClaudeDesktopMonitoringEnabled") as? Bool ?? true
        snapshot = store.readSnapshot()
        isLaunchAtLoginEnabled = launchAtLoginManager.isEnabled
        desktopAppSessions = filteredPlatformPresenceSessions(codexPlatformPresenceMonitor.detectSessions())
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

    func setSignalLightAgentScopes(_ scopes: Set<SignalLightAgentScope>) {
        let selectableScopes = Set(SignalLightAgentScope.selectableCases)
        let resolvedScopes = scopes.intersection(selectableScopes)
        guard !resolvedScopes.isEmpty else { return }

        signalLightAgentScopes = resolvedScopes
        UserDefaults.standard.set(
            resolvedScopes
                .sorted { $0.sortOrder < $1.sortOrder }
                .map(\.rawValue),
            forKey: "signalLightAgentScopes"
        )
    }

    func toggleSignalLightAgentScope(_ scope: SignalLightAgentScope) {
        var updatedScopes = signalLightAgentScopes
        if updatedScopes.contains(scope) {
            updatedScopes.remove(scope)
        } else {
            updatedScopes.insert(scope)
        }

        setSignalLightAgentScopes(updatedScopes)
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
        pollDesktopAppPresence()
    }

    func setClaudeDesktopMonitoringEnabled(_ enabled: Bool) {
        isClaudeDesktopMonitoringEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isClaudeDesktopMonitoringEnabled")
        pollDesktopAppPresence()
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

        lines.append("\(text("灯效 Agent", "Light Agent")): \(displayName(for: signalLightAgentScopes))")

        if statusBarStyle == .macOS && displayLayout == .horizontal && !macOSHorizontalUsesTrafficLightSize {
            lines.append(text("圆点横向尺寸：小", "Horizontal dot size: Small"))
        }

        if statusBarStyle == .trafficLight && displayLayout == .vertical && trafficLightVerticalUsesMacOSSize {
            lines.append(text("灯牌竖向尺寸：大", "Vertical lamp size: Large"))
        }

        if isCodexDesktopMonitoringEnabled {
            lines.append(text("Codex 自动监控已开启", "Codex auto monitoring is on"))
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
        let scopedDisplaySessions = displaySessions.filter { sessionMatchesSignalLightScopes($0) }
        let deduplicatedSessions = deduplicatedDisplaySessions(scopedDisplaySessions)
        let scopedRecentEvents = snapshot.recentEvents
            .filter { !Self.isSignalTestEvent($0.event) }
            .filter { recentEventMatchesSignalLightScopes($0) }
        let deduplicatedRecentEvents = deduplicatedRecentEvents(scopedRecentEvents)
        let displayUpdatedAt = deduplicatedSessions.map(\.updatedAt).max()

        return SignalSnapshot(
            aggregate: aggregateForSignalLightScopes(
                sessions: deduplicatedSessions,
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
        let deduplicatedSessions = deduplicatedDisplaySessions(displaySessions)
        let visibleRecentEvents = snapshot.recentEvents
            .filter { !Self.isSignalTestEvent($0.event) }
        let deduplicatedRecentEvents = deduplicatedRecentEvents(visibleRecentEvents)
        let displayUpdatedAt = deduplicatedSessions.map(\.updatedAt).max()

        return SignalSnapshot(
            aggregate: aggregateForSessions(deduplicatedSessions, fallback: snapshot.aggregate),
            sessions: deduplicatedSessions,
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
        runHookInstall(operation: .preview) { manager in
            try manager.preview()
        }
    }

    func installHooks() {
        runHookInstall(operation: .install) { manager in
            try manager.install()
        }
    }

    func previewCodexHookInstall() {
        runHookInstall(operation: .preview) { manager in
            try manager.previewCodex()
        }
    }

    func installCodexHooks() {
        runHookInstall(operation: .install) { manager in
            try manager.installCodex()
        }
    }

    func uninstallCodexHooks() {
        runHookInstall(operation: .uninstall) { manager in
            try manager.uninstallCodex()
        }
    }

    func previewClaudeHookInstall() {
        runHookInstall(operation: .preview) { manager in
            try manager.previewClaude()
        }
    }

    func installClaudeHooks() {
        runHookInstall(operation: .install) { manager in
            try manager.installClaude()
        }
    }

    func uninstallClaudeHooks() {
        runHookInstall(operation: .uninstall) { manager in
            try manager.uninstallClaude()
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
        hookInstallOperation = .message
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

        let presentationTimer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.presentationRefreshTick &+= 1
            }
        }
        presentationTimer.tolerance = 0.25
        RunLoop.main.add(presentationTimer, forMode: .common)
        self.presentationTimer = presentationTimer

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
        desktopAppTimer.tolerance = 0.2
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
                            agent: activity.agent,
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
        guard !isPlatformPresencePollInFlight else { return }

        isPlatformPresencePollInFlight = true
        let monitor = codexPlatformPresenceMonitor

        platformPresencePollQueue.async { [weak self] in
            let detectedSessions = monitor.detectSessions()

            DispatchQueue.main.async { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.isPlatformPresencePollInFlight = false
                    let latestSessions = self.filteredPlatformPresenceSessions(detectedSessions)
                    if latestSessions != self.desktopAppSessions {
                        self.desktopAppSessions = latestSessions
                    }
                }
            }
        }
    }

    func filteredPlatformPresenceSessions(_ sessions: [SessionStatus]) -> [SessionStatus] {
        sessions.filter { session in
            let sourceKey = ActivityPresentation.activitySourceKey(for: session)
            if sourceKey.hasPrefix("codex:") {
                return isCodexDesktopMonitoringEnabled
            }
            if sourceKey.hasPrefix("claude:") {
                return isClaudeDesktopMonitoringEnabled
            }
            return true
        }
    }

    private func combinedDisplaySessions() -> [SessionStatus] {
        let now = Date()
        let visibleRecentEvents = snapshot.recentEvents.filter { !Self.isSignalTestEvent($0.event) }
        let completionCutoffsBySourceKey = Self.latestCompletionCutoffsBySourceKey(visibleRecentEvents)
        var sessions = snapshot.sessions.filter { session in
            Self.shouldIncludeStoredSessionInDisplay(session, now: now)
                && !Self.isSupersededByCompletedRecentEvent(
                    session,
                    completionCutoffsBySourceKey: completionCutoffsBySourceKey
                )
        }
        sessions.append(
            contentsOf: recentActivityFallbackSessions(
                from: visibleRecentEvents,
                existingSessions: sessions,
                completionCutoffsBySourceKey: completionCutoffsBySourceKey,
                now: now
            )
        )

        let liveAgentKeys = Set(
            sessions.compactMap { session -> String? in
                guard Self.shouldSuppressDesktopPresence(for: session, now: now) else { return nil }
                return ActivityPresentation.activitySourceKey(for: session)
            }
        )

        for desktopSession in desktopAppSessions {
            let sourceKey = ActivityPresentation.activitySourceKey(for: desktopSession)
            guard !liveAgentKeys.contains(sourceKey) else { continue }
            sessions.append(desktopSession)
        }

        return sessions.sorted(by: Self.displaySessionSortPrecedes)
    }

    private func recentActivityFallbackSessions(
        from recentEvents: [RecentSignalEvent],
        existingSessions: [SessionStatus],
        completionCutoffsBySourceKey: [String: Date],
        now: Date
    ) -> [SessionStatus] {
        let latestExistingSessionBySourceKey = Dictionary(
            grouping: existingSessions,
            by: ActivityPresentation.activitySourceKey(for:)
        ).compactMapValues { sessions in
            sessions.max(by: { lhs, rhs in lhs.updatedAt < rhs.updatedAt })
        }
        var handledSourceKeys: Set<String> = []
        var fallbackSessions: [SessionStatus] = []

        for event in recentEvents.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            let sourceKey = ActivityPresentation.activitySourceKey(for: event)
            guard !handledSourceKeys.contains(sourceKey)
            else {
                continue
            }

            if let existingSession = latestExistingSessionBySourceKey[sourceKey],
               existingSession.updatedAt >= event.updatedAt {
                continue
            }

            if event.signal.displayState == .active,
               let completedAt = completionCutoffsBySourceKey[sourceKey],
               event.updatedAt <= completedAt {
                continue
            }

            guard Self.shouldUseRecentEventAsFallbackSession(event, now: now) else { continue }

            handledSourceKeys.insert(sourceKey)
            fallbackSessions.append(
                SessionStatus(
                    sessionID: "recent-activity:\(sourceKey)",
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
        var sessionsBySourceKey: [String: SessionStatus] = [:]

        for session in sessions {
            let sourceKey = ActivityPresentation.activitySourceKey(for: session)
            guard let current = sessionsBySourceKey[sourceKey] else {
                sessionsBySourceKey[sourceKey] = session
                continue
            }

            if Self.shouldPreferDisplaySession(session, over: current) {
                sessionsBySourceKey[sourceKey] = session
            }
        }

        return sessionsBySourceKey.values.sorted(by: Self.displaySessionSortPrecedes)
    }

    private static func displaySessionSortPrecedes(_ lhs: SessionStatus, _ rhs: SessionStatus) -> Bool {
        if lhs.signal.displayState.priority != rhs.signal.displayState.priority {
            return lhs.signal.displayState.priority > rhs.signal.displayState.priority
        }

        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt > rhs.updatedAt
        }

        return ActivityPresentation.activitySourceKey(for: lhs)
            < ActivityPresentation.activitySourceKey(for: rhs)
    }

    private static func shouldPreferDisplaySession(_ candidate: SessionStatus, over current: SessionStatus) -> Bool {
        let candidateIsDesktopPresence = isPresenceSession(candidate)
        let currentIsDesktopPresence = isPresenceSession(current)
        if candidateIsDesktopPresence != currentIsDesktopPresence {
            if candidateIsDesktopPresence {
                return shouldPresenceOverrideStaleActivity(candidate, nonPresence: current)
            }
            if currentIsDesktopPresence {
                return !shouldPresenceOverrideStaleActivity(current, nonPresence: candidate)
            }
        }

        let candidateIsAlert = isPersistentAlert(candidate.signal.displayState)
        let currentIsAlert = isPersistentAlert(current.signal.displayState)
        if candidateIsAlert || currentIsAlert {
            let candidatePriority = deduplicationPriority(for: candidate.signal)
            let currentPriority = deduplicationPriority(for: current.signal)
            if candidatePriority != currentPriority {
                return candidatePriority > currentPriority
            }
        }

        if candidate.updatedAt != current.updatedAt {
            return candidate.updatedAt > current.updatedAt
        }

        return deduplicationPriority(for: candidate.signal) > deduplicationPriority(for: current.signal)
    }

    private static func shouldPresenceOverrideStaleActivity(
        _ presence: SessionStatus,
        nonPresence: SessionStatus
    ) -> Bool {
        guard nonPresence.signal.displayState == .active else {
            return false
        }

        return presence.updatedAt.timeIntervalSince(nonPresence.updatedAt) > activeDisplayWindow(for: nonPresence)
    }

    private static func deduplicationPriority(for signal: AgentSignal) -> Int {
        switch signal.displayState {
        case .blocked, .permission, .needsReview, .stale, .paused:
            return signal.displayState.priority
        case .active, .completed, .ready:
            return signal.displayState.priority
        }
    }

    private static func isPersistentAlert(_ displayState: DisplayState) -> Bool {
        switch displayState {
        case .needsReview, .permission, .blocked, .stale, .paused:
            return true
        case .ready, .active, .completed:
            return false
        }
    }

    static func shouldUseRecentEventAsFallbackSession(_ event: RecentSignalEvent, now: Date) -> Bool {
        if event.event == "ClearWarning" {
            return false
        }

        let age = now.timeIntervalSince(event.updatedAt)
        switch event.signal.displayState {
        case .active:
            return age <= recentActivityFallbackWindow(for: event)
        case .completed:
            return age <= completedDisplayWindow
        case .needsReview, .permission, .blocked, .stale:
            return true
        case .ready, .paused:
            return false
        }
    }

    private static func recentActivityFallbackWindow(for event: RecentSignalEvent) -> TimeInterval {
        isPassiveActiveEvent(event) ? passiveActiveDisplayWindow : recentActivityFallbackWindow
    }

    private static func isPassiveActiveEvent(_ event: RecentSignalEvent) -> Bool {
        guard event.signal.displayState == .active else { return false }

        switch event.event {
        case "DesktopActivityHeartbeat", "DesktopThinking":
            return true
        default:
            return false
        }
    }

    private static func latestCompletionCutoffsBySourceKey(_ events: [RecentSignalEvent]) -> [String: Date] {
        var cutoffs: [String: Date] = [:]

        for event in events where event.signal.displayState == .completed {
            let sourceKey = ActivityPresentation.activitySourceKey(for: event)
            if let existing = cutoffs[sourceKey], existing >= event.updatedAt {
                continue
            }
            cutoffs[sourceKey] = event.updatedAt
        }

        return cutoffs
    }

    private static func isSupersededByCompletedRecentEvent(
        _ session: SessionStatus,
        completionCutoffsBySourceKey: [String: Date]
    ) -> Bool {
        guard !isPresenceSession(session),
              session.signal.displayState == .active
        else {
            return false
        }

        let sourceKey = ActivityPresentation.activitySourceKey(for: session)
        guard let completedAt = completionCutoffsBySourceKey[sourceKey] else {
            return false
        }

        return completedAt >= session.updatedAt
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
        let sourceKey = ActivityPresentation.activitySourceKey(for: event)
        let semanticEvent = normalizedEventDeduplicationKey(event.event, signal: event.signal)
        return "\(sourceKey)|\(semanticEvent)"
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

    var activeSignalLightAgentScopes: Set<SignalLightAgentScope> {
        let visibleSessions = ActivityPresentation.visibleSessions(from: activitySnapshot, limit: nil)
        return Set(
            SignalLightAgentScope.selectableCases.filter { scope in
                visibleSessions.contains { scope.matches(session: $0) }
            }
        )
    }

    private static func resolvedSignalLightAgentScopes(
        storedScopes: [String]?,
        legacyScope: String?
    ) -> Set<SignalLightAgentScope> {
        let selectableScopes = Set(SignalLightAgentScope.selectableCases)
        let resolvedStoredScopes = Set(
            (storedScopes ?? [])
                .compactMap(SignalLightAgentScope.init(rawValue:))
                .flatMap(\.expandedSelection)
        )
        .intersection(selectableScopes)

        if !resolvedStoredScopes.isEmpty {
            return resolvedStoredScopes
        }

        if let legacyScope,
           let legacySelection = SignalLightAgentScope(rawValue: legacyScope) {
            let resolvedLegacyScopes = legacySelection.expandedSelection.intersection(selectableScopes)
            if !resolvedLegacyScopes.isEmpty {
                return resolvedLegacyScopes
            }
        }

        return SignalLightAgentScope.defaultSelectedCases
    }

    private func aggregateForSignalLightScopes(
        sessions: [SessionStatus],
        fallback: AgentSignal
    ) -> AgentSignal {
        let selectedSignals = sessions.compactMap { session -> AgentSignal? in
            guard sessionMatchesSignalLightScopes(session) else { return nil }
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

    private func sessionMatchesSignalLightScopes(_ session: SessionStatus) -> Bool {
        signalLightAgentScopes.contains { $0.matches(session: session) }
    }

    private func recentEventMatchesSignalLightScopes(_ event: RecentSignalEvent) -> Bool {
        signalLightAgentScopes.contains { $0.matches(event: event) }
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

    private static func shouldIncludeStoredSessionInDisplay(_ session: SessionStatus, now: Date) -> Bool {
        if isSignalTestEvent(session.lastEvent) {
            return false
        }

        if isPresenceSession(session) {
            return true
        }

        switch session.signal.displayState {
        case .active:
            return now.timeIntervalSince(session.updatedAt) <= activeDisplayWindow(for: session)
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
            return now.timeIntervalSince(session.updatedAt) <= activeDisplayWindow(for: session)
        case .needsReview, .permission, .blocked, .stale:
            return true
        case .ready, .completed, .paused:
            return false
        }
    }

    private static func isPresenceSession(_ session: SessionStatus) -> Bool {
        session.sessionID.hasPrefix("desktop-app:")
            || session.sessionID.hasPrefix("platform-presence:")
            || session.lastEvent == "DesktopAppRunning"
            || session.lastEvent?.hasPrefix("PlatformPresence:") == true
    }

    private static func activeDisplayWindow(for session: SessionStatus) -> TimeInterval {
        isPassiveActiveSession(session) ? passiveActiveDisplayWindow : activeDisplayWindow
    }

    private static func isPassiveActiveSession(_ session: SessionStatus) -> Bool {
        guard session.signal.displayState == .active else { return false }

        switch session.lastEvent {
        case "DesktopActivityHeartbeat", "DesktopThinking":
            return true
        default:
            return false
        }
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
        case "claude", "claude-code", "claude-desktop", "claude-cli",
             "claude-terminal", "terminal-claude", "claude-ide",
             "idea-claude", "intellij-claude", "jetbrains-claude":
            return "claude"
        case "codex", "codex-desktop", "codex-cli", "codex-ide", "codex-xcode",
             "codex-terminal", "terminal-codex", "codex-tui", "codex-shell",
             "idea-codex", "intellij-codex", "jetbrains-codex", "codex-idea",
             "codex-intellij", "codex-jetbrains", "codex-vscode", "vscode-codex",
             "xcode-codex":
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

    private func runHookInstall(
        operation: HookInstallOperation,
        _ action: @escaping @Sendable (HookInstallManager) throws -> HookInstallResult
    ) {
        guard !isHookInstallRunning else { return }
        isHookInstallRunning = true
        hookInstallOperation = operation
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

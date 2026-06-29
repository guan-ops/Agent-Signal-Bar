import AgentSignalLightCore
import AgentSignalLightUI
import AppKit
import Foundation
@preconcurrency import UserNotifications

@MainActor
final class SignalAnimationClock: ObservableObject {
    @Published private(set) var tick: Int = 0

    func advance(by step: Int = 1) {
        tick = (tick + max(step, 1)) % 10_000
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

    static let visibleCases: [SignalLightAgentScope] = [
        .codexDesktop,
        .codexCLI,
        .codexVSCode,
        .codexXcode,
        .codexIDEA,
        .claudeCode
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
    case simple
    case detailed
}

enum SignalLightAgentSelectionMode: String, Hashable {
    case following
    case manual
}

enum StatusLightOverrideTarget: String, CaseIterable, Hashable {
    case statusBar
    case floatingSignal
}

struct StatusLightOverrideFrame: Equatable {
    let signal: AgentSignal
    let tick: Int
    let allLightsOn: Bool
    let usesSystemGrayLights: Bool
    let effectCustomization: SignalEffectCustomization
    let targets: Set<StatusLightOverrideTarget>
    let usesLiveTick: Bool

    init(
        signal: AgentSignal,
        tick: Int,
        allLightsOn: Bool,
        usesSystemGrayLights: Bool = false,
        effectCustomization: SignalEffectCustomization,
        targets: Set<StatusLightOverrideTarget> = Set(StatusLightOverrideTarget.allCases),
        usesLiveTick: Bool = false
    ) {
        self.signal = signal
        self.tick = tick
        self.allLightsOn = allLightsOn
        self.usesSystemGrayLights = usesSystemGrayLights
        self.effectCustomization = effectCustomization
        self.targets = targets
        self.usesLiveTick = usesLiveTick
    }
}

struct RuntimeTimingProfile: Equatable {
    let statePollInterval: TimeInterval
    let statePollTolerance: TimeInterval
    let animationTickInterval: TimeInterval
    let animationTickTolerance: TimeInterval
    let agentPollInterval: TimeInterval
    let agentPollTolerance: TimeInterval
    let desktopAppPresencePollInterval: TimeInterval
    let desktopAppPresencePollTolerance: TimeInterval
    let automaticUpdateCheckTimerInterval: TimeInterval
    let automaticUpdateCheckTimerTolerance: TimeInterval

    static let standard = RuntimeTimingProfile(
        statePollInterval: 5.0,
        statePollTolerance: 1.0,
        animationTickInterval: 0.45,
        animationTickTolerance: 0.15,
        agentPollInterval: 2.0,
        agentPollTolerance: 0.75,
        desktopAppPresencePollInterval: 20.0,
        desktopAppPresencePollTolerance: 5.0,
        automaticUpdateCheckTimerInterval: 60 * 60,
        automaticUpdateCheckTimerTolerance: 5 * 60
    )

    static let lowPower = RuntimeTimingProfile(
        statePollInterval: 15.0,
        statePollTolerance: 4.0,
        animationTickInterval: 0.9,
        animationTickTolerance: 0.3,
        agentPollInterval: 6.0,
        agentPollTolerance: 2.0,
        desktopAppPresencePollInterval: 60.0,
        desktopAppPresencePollTolerance: 15.0,
        automaticUpdateCheckTimerInterval: 60 * 60,
        automaticUpdateCheckTimerTolerance: 5 * 60
    )
}

enum HookInstallOperation: Hashable {
    case preview
    case install
    case uninstall
    case message
}

enum FloatingSignalInfoBadgeCorner: String, CaseIterable, Hashable {
    case topLeft = "top-left"
    case topRight = "top-right"
    case bottomLeft = "bottom-left"
}

enum FloatingSignalQuotaBadgeWindow: String, CaseIterable, Hashable {
    case fiveHours = "five-hours"
    case weekly = "weekly"
}

enum FloatingSignalTokenBadgeWindow: String, CaseIterable, Hashable {
    case today
    case last30Days = "last-30-days"
}

enum CodexUsageDataSource: String, CaseIterable, Hashable, Identifiable {
    case automatic
    case oauthAPI = "oauth-api"
    case cliRPCPTY = "cli-rpc-pty"

    var id: String { rawValue }

    static let selectableCases: [CodexUsageDataSource] = [.automatic, .oauthAPI]

    var resolvedSelectableValue: CodexUsageDataSource {
        Self.selectableCases.contains(self) ? self : .automatic
    }
}

enum CodexOpenAICookieMode: String, CaseIterable, Hashable, Identifiable {
    case automatic
    case manual
    case off

    var id: String { rawValue }

    static let selectableCases: [CodexOpenAICookieMode] = [.automatic, .manual, .off]

    var resolvedSelectableValue: CodexOpenAICookieMode {
        Self.selectableCases.contains(self) ? self : .off
    }
}

enum DebugLogLevel: String, CaseIterable, Hashable, Identifiable {
    case error
    case info
    case verbose

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .error:
            return "Error"
        case .info:
            return "Info"
        case .verbose:
            return "Verbose"
        }
    }
}

private struct CLIInstallError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
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
    @Published var needsReviewSignalEffect: AlertSignalEffect
    @Published var permissionSignalEffect: AlertSignalEffect
    @Published var blockedSignalEffect: AlertSignalEffect
    @Published var macOSHorizontalUsesTrafficLightSize: Bool
    @Published var trafficLightVerticalUsesMacOSSize: Bool
    @Published var isStatusBarIconEnabled: Bool
    @Published var signalLightAgentScopes: Set<SignalLightAgentScope>
    @Published private(set) var signalLightAgentSelectionMode: SignalLightAgentSelectionMode
    @Published var statusMenuMode: StatusMenuMode
    @Published var isCodexDesktopMonitoringEnabled: Bool
    @Published var isClaudeDesktopMonitoringEnabled: Bool
    @Published var appLanguage: AppLanguage
    @Published var appTheme: AppTheme
    @Published var isSettingsGlassEnabled: Bool
    @Published var isDebugSettingsVisible: Bool
    @Published var isDebugFileLoggingEnabled: Bool
    @Published var debugLogLevel: DebugLogLevel
    @Published var settingsGlassEffect: SettingsGlassEffect
    @Published var isLowPowerModeEnabled: Bool
    @Published var isNewZealandTrafficLightModeEnabled: Bool
    @Published var isMonitoringPaused = false
    @Published var isFloatingSignalEnabled: Bool
    @Published var floatingSignalScale: FloatingSignalScale
    @Published var floatingSignalVisualScale: CGFloat
    @Published var floatingSignalLayout: TrafficSignalLayout
    @Published var isFloatingSignalSoundEnabled: Bool
    @Published var floatingSignalCompletionSound: FloatingSignalCompletionSound
    @Published var floatingSignalWaitingSound: FloatingSignalWaitingSound
    @Published var isFloatingSignalCompletionSoundEnabled: Bool
    @Published var isFloatingSignalWaitingSoundEnabled: Bool
    @Published var floatingSignalSoundLevel: FloatingSignalSoundLevel
    @Published var isFloatingSignalInfoBadgeEnabled: Bool
    @Published var isFloatingSignalQuotaBadgeEnabled: Bool
    @Published var isFloatingSignalTokenBadgeEnabled: Bool
    @Published var floatingSignalInfoBadgeCorner: FloatingSignalInfoBadgeCorner
    @Published var floatingSignalQuotaBadgeCorner: FloatingSignalInfoBadgeCorner
    @Published var floatingSignalTokenBadgeCorner: FloatingSignalInfoBadgeCorner
    @Published var floatingSignalQuotaBadgeWindow: FloatingSignalQuotaBadgeWindow
    @Published var floatingSignalTokenBadgeWindow: FloatingSignalTokenBadgeWindow
    @Published private(set) var latestAgentQuota: AgentQuotaStatus?
    @Published private(set) var latestCodexCredits: CodexCreditStatus?
    @Published private(set) var latestAgentTokenUsage: AgentTokenUsage?
    @Published private(set) var statusLightOverride: StatusLightOverrideFrame?
    @Published private(set) var isLightDebugModeEnabled = false
    @Published private(set) var desktopAppSessions: [SessionStatus] = []
    @Published private(set) var isLaunchAtLoginEnabled = false
    @Published private(set) var isLaunchAtLoginChangeRunning = false
    @Published var isHookInstallRunning = false
    @Published var hookInstallMessage: String?
    @Published var hookInstallOperation: HookInstallOperation = .message
    @Published private(set) var isCLIInstallRunning = false
    @Published var cliInstallMessage: String?
    @Published var isDiagnosticsExportRunning = false
    @Published var diagnosticsExportMessage: String?
    @Published private(set) var releaseInfo: ReleaseInfo = .current()
    @Published private(set) var isUpdateCheckRunning = false
    @Published private(set) var isAutomaticUpdateCheckEnabled = false
    @Published private(set) var lastAutomaticUpdateCheckAt: Date?
    @Published var updateCheckMessage: String?
    @Published private(set) var updateReleasePageURL: URL?
    @Published var lastError: String?
    @Published private(set) var floatingSignalSoundTestTick = 0
    @Published private(set) var floatingSignalWaitingSoundTestTick = 0
    @Published private(set) var tokenActivityDays: [CodexTokenActivityDay] = []
    @Published private(set) var isTokenActivityLoading = false
    @Published private(set) var isCodexRateLimitFetchInFlight = false
    @Published private(set) var codexCurrentAccount: CodexCurrentAccount?
    @Published private(set) var codexSavedAccounts: [CodexAccountProfile] = []
    @Published private(set) var codexActiveSavedAccountID: UUID?
    @Published private(set) var isCodexAccountActionRunning = false
    @Published var codexAccountMessage: String?
    @Published var codexUsageDataSource: CodexUsageDataSource
    @Published var codexOpenAICookieMode: CodexOpenAICookieMode
    @Published var codexManualOpenAICookieHeader: String
    @Published private(set) var codexCLIVersionText: String?
    @Published private(set) var codexProviderAccountEmail: String?
    @Published private(set) var codexProviderPlanName: String?
    @Published private(set) var codexProviderServiceStatusText: String?
    @Published private(set) var codexProviderDetailsCheckedAt: Date?
    @Published private(set) var isCodexProviderDetailsLoading = false
    @Published private(set) var debugCacheMessage: String?

    let animationClock = SignalAnimationClock()

    private let store: SignalStateStore
    private let launchAtLoginManager: LaunchAtLoginManager
    private let hookInstallManager: HookInstallManager
    private let diagnosticsExportManager: DiagnosticsExportManager
    private let codexDesktopActivityMonitor: CodexDesktopActivityMonitor
    private let codexAccountManager: any CodexAccountManaging
    private let codexUsageSnapshotStore: CodexAccountUsageSnapshotStore
    private let codexCLIStatusProbe: CodexCLIStatusProbe
    private let codexRPCStatusProbe: CodexRPCStatusProbe
    private let codexServiceStatusFetcher: CodexServiceStatusFetcher
    private let codexRateLimitFetcher: CodexRateLimitFetcher
    private let codexTokenActivityScanner: CodexTokenActivityScanner
    private let codexPlatformPresenceMonitor: CodexPlatformPresenceMonitor
    private let openAICookieStore: KeychainSecretStore
    private let updateChecker: GitHubReleaseUpdateChecker
    private let stateReloadQueue = DispatchQueue(label: "com.agentsignallight.state-reload")
    private let codexDesktopPollQueue = DispatchQueue(label: "com.agentsignallight.codex-desktop-poll")
    private let tokenActivityQueue = DispatchQueue(label: "com.agentsignallight.token-activity")
    private let platformPresencePollQueue = DispatchQueue(label: "com.agentsignallight.platform-presence-poll")
    private var pollTimer: Timer?
    private var animationTimer: Timer?
    private var codexDesktopTimer: Timer?
    private var desktopAppTimer: Timer?
    private var automaticUpdateCheckTimer: Timer?
    private var watcher: StateFileWatcher?
    private static let recentEventDeduplicationWindow: TimeInterval = 4
    private static let completedDisplayWindow: TimeInterval = 30
    private static let recentActivityFallbackWindow: TimeInterval = 5 * 60
    private static let desktopPresenceSuppressionWindow: TimeInterval = 5 * 60
    private static let transientAlertDisplayWindow: TimeInterval = 5 * 60
    private static let passiveActiveDisplayWindow: TimeInterval = 45
    private var statusLightSequence: [StatusLightOverrideFrame] = []
    private var statusLightSequenceIndex = 0
    private var animationFrameSkipCounter = 0
    private var isStateReloadInFlight = false
    private var isStateReloadQueued = false
    private var isCodexDesktopPollInFlight = false
    private var isTokenActivityScanInFlight = false
    private var codexUsageRefreshGeneration = 0
    private var tokenActivityScanGeneration = 0
    private var isPlatformPresencePollInFlight = false
    private var isAutomaticUpdateCheckInFlight = false
    private var lastNotifiedUpdateVersion: String?
    private var lastCodexRateLimitFetchAt: Date?
    private var lastTokenActivityScanAt: Date?
    private var liveTokenUsageScanBaseline: Int?
    private var lastObservedLiveTokenUsageTotal: Int?

    private static let defaultDisplayLayout: TrafficSignalLayout = .horizontal
    private static let defaultStatusBarStyle: TrafficSignalStyle = .macOS
    private static let defaultMacOSHorizontalUsesTrafficLightSize = true
    private static let defaultTrafficLightVerticalUsesMacOSSize = false
    private static let effectDefaultsVersion = 2
    private static let floatingSignalScaleDefaultsVersion = 3
    private static let preferenceDefaultsVersion = 1
    private static let automaticUpdateCheckInterval: TimeInterval = 24 * 60 * 60
    private static let codexRateLimitRefreshInterval: TimeInterval = 60
    private static let codexProviderDetailsRefreshInterval: TimeInterval = 60
    private static let tokenActivityRefreshInterval: TimeInterval = 60
    private static let cachedLatestAgentQuotaKey = "cachedLatestAgentQuota"
    private static let cachedLatestAgentTokenUsageKey = "cachedLatestAgentTokenUsage"
    private static let manualOpenAICookieKey = "manualOpenAICookieHeader"
    private static let legacyManualOpenAICookieUserDefaultsKey = "codexManualOpenAICookieHeader"
    private static let activeDisplayWindow: TimeInterval = 5 * 60
    private static let debugLogFileName = "AgentSignalLight.log"

    private struct LaunchAtLoginUpdateResult: Sendable {
        let isEnabled: Bool
        let errorMessage: String?
    }

    private struct AnimationTickCadence {
        let timerFramesPerAdvance: Int
        let tickAdvance: Int

        static let everyFrame = AnimationTickCadence(timerFramesPerAdvance: 1, tickAdvance: 1)
    }

    init(
        store: SignalStateStore = SignalStateStore(),
        launchAtLoginManager: LaunchAtLoginManager = LaunchAtLoginManager(),
        hookInstallManager: HookInstallManager = HookInstallManager(),
        diagnosticsExportManager: DiagnosticsExportManager = DiagnosticsExportManager(),
        codexDesktopActivityMonitor: CodexDesktopActivityMonitor = CodexDesktopActivityMonitor(replaysInitialHistory: true),
        codexAccountManager: any CodexAccountManaging = CodexAccountManager(),
        codexUsageSnapshotStore: CodexAccountUsageSnapshotStore = CodexAccountUsageSnapshotStore(),
        codexCLIStatusProbe: CodexCLIStatusProbe = CodexCLIStatusProbe(),
        codexRPCStatusProbe: CodexRPCStatusProbe = CodexRPCStatusProbe(),
        codexServiceStatusFetcher: CodexServiceStatusFetcher = CodexServiceStatusFetcher(),
        codexRateLimitFetcher: CodexRateLimitFetcher = CodexRateLimitFetcher(),
        codexTokenActivityScanner: CodexTokenActivityScanner = CodexTokenActivityScanner(),
        codexPlatformPresenceMonitor: CodexPlatformPresenceMonitor = CodexPlatformPresenceMonitor(),
        updateChecker: GitHubReleaseUpdateChecker = GitHubReleaseUpdateChecker()
    ) {
        self.store = store
        self.launchAtLoginManager = launchAtLoginManager
        self.hookInstallManager = hookInstallManager
        self.diagnosticsExportManager = diagnosticsExportManager
        self.codexDesktopActivityMonitor = codexDesktopActivityMonitor
        self.codexAccountManager = codexAccountManager
        self.codexUsageSnapshotStore = codexUsageSnapshotStore
        self.codexCLIStatusProbe = codexCLIStatusProbe
        self.codexRPCStatusProbe = codexRPCStatusProbe
        self.codexServiceStatusFetcher = codexServiceStatusFetcher
        self.codexRateLimitFetcher = codexRateLimitFetcher
        self.codexTokenActivityScanner = codexTokenActivityScanner
        self.codexPlatformPresenceMonitor = codexPlatformPresenceMonitor
        let openAICookieStore = KeychainSecretStore(service: "com.agentsignallight.openai-cookie")
        self.openAICookieStore = openAICookieStore
        self.updateChecker = updateChecker
        let storedLayout = UserDefaults.standard.string(forKey: "trafficSignalLayout")
        let storedStyle = UserDefaults.standard.string(forKey: "trafficSignalStyle")
        let storedMacOSStrength = UserDefaults.standard.string(forKey: "macOSBreathingStrength")
        let storedThinkingSignalEffect = UserDefaults.standard.string(forKey: "thinkingSignalEffect")
        let storedActiveSignalEffect = UserDefaults.standard.string(forKey: "activeSignalEffect")
        let storedActiveEffectSpeed = UserDefaults.standard.string(forKey: "activeEffectSpeed")
        let storedAlertEffectSpeed = UserDefaults.standard.string(forKey: "alertEffectSpeed")
        let storedCompletedSignalEffect = UserDefaults.standard.string(forKey: "completedSignalEffect")
        let storedNeedsReviewSignalEffect = UserDefaults.standard.string(forKey: "needsReviewSignalEffect")
        let storedPermissionSignalEffect = UserDefaults.standard.string(forKey: "permissionSignalEffect")
        let storedBlockedSignalEffect = UserDefaults.standard.string(forKey: "blockedSignalEffect")
        let storedLanguage = UserDefaults.standard.string(forKey: "appLanguage")
        let storedTheme = UserDefaults.standard.string(forKey: "appTheme")
        let storedSettingsGlassEnabled = UserDefaults.standard.object(forKey: "isSettingsGlassEnabled") as? Bool
        let storedDebugSettingsVisible =
            UserDefaults.standard.object(forKey: "isDebugSettingsVisible") as? Bool
        let storedDebugFileLoggingEnabled =
            UserDefaults.standard.object(forKey: "isDebugFileLoggingEnabled") as? Bool
        let storedDebugLogLevel = UserDefaults.standard.string(forKey: "debugLogLevel")
        let storedSettingsGlassEffect =
            UserDefaults.standard.string(forKey: "settingsGlassEffect")
            ?? UserDefaults.standard.string(forKey: "settingsMenuGlassEffect")
        let storedLowPowerModeEnabled =
            UserDefaults.standard.object(forKey: "isLowPowerModeEnabled") as? Bool
        let storedNewZealandTrafficLightModeEnabled =
            UserDefaults.standard.object(forKey: "isNewZealandTrafficLightModeEnabled") as? Bool
        let storedSignalLightAgentScope = UserDefaults.standard.string(forKey: "signalLightAgentScope")
        let storedSignalLightAgentScopes = UserDefaults.standard.stringArray(forKey: "signalLightAgentScopes")
        let storedSignalLightAgentSelectionMode = UserDefaults.standard.string(forKey: "signalLightAgentSelectionMode")
        let storedCodexUsageDataSource = UserDefaults.standard.string(forKey: "codexUsageDataSource")
        let storedCodexOpenAICookieMode = UserDefaults.standard.string(forKey: "codexOpenAICookieMode")
        let storedStatusMenuMode = UserDefaults.standard.string(forKey: "statusMenuMode")
        let storedFloatingSignalScale = UserDefaults.standard.string(forKey: "floatingSignalScale")
        let storedFloatingSignalVisualScale =
            UserDefaults.standard.object(forKey: "floatingSignalVisualScale") as? Double
        let storedFloatingSignalLayout = UserDefaults.standard.string(forKey: "floatingSignalLayout")
        let storedFloatingSignalScaleDefaultsVersion =
            UserDefaults.standard.integer(forKey: "floatingSignalScaleDefaultsVersion")
        let storedFloatingSignalSoundLevel = UserDefaults.standard.string(forKey: "floatingSignalSoundLevel")
        let storedFloatingSignalInfoBadgeEnabled =
            UserDefaults.standard.object(forKey: "isFloatingSignalInfoBadgeEnabled") as? Bool
        let storedFloatingSignalQuotaBadgeEnabled =
            UserDefaults.standard.object(forKey: "isFloatingSignalQuotaBadgeEnabled") as? Bool
        let storedFloatingSignalTokenBadgeEnabled =
            UserDefaults.standard.object(forKey: "isFloatingSignalTokenBadgeEnabled") as? Bool
        let storedFloatingSignalInfoBadgeCorner =
            UserDefaults.standard.string(forKey: "floatingSignalInfoBadgeCorner")
        let storedFloatingSignalQuotaBadgeCorner =
            UserDefaults.standard.string(forKey: "floatingSignalQuotaBadgeCorner")
        let storedFloatingSignalTokenBadgeCorner =
            UserDefaults.standard.string(forKey: "floatingSignalTokenBadgeCorner")
        let storedFloatingSignalQuotaBadgeWindow =
            UserDefaults.standard.string(forKey: "floatingSignalQuotaBadgeWindow")
        let storedFloatingSignalTokenBadgeWindow =
            UserDefaults.standard.string(forKey: "floatingSignalTokenBadgeWindow")
        let storedFloatingSignalCompletionSound =
            UserDefaults.standard.string(forKey: "floatingSignalCompletionSound")
        let storedFloatingSignalWaitingSound =
            UserDefaults.standard.string(forKey: "floatingSignalWaitingSound")
        let storedFloatingSignalSoundEnabled =
            UserDefaults.standard.object(forKey: "isFloatingSignalSoundEnabled") as? Bool
        let storedFloatingSignalCompletionSoundEnabled =
            UserDefaults.standard.object(forKey: "isFloatingSignalCompletionSoundEnabled") as? Bool
        let storedFloatingSignalWaitingSoundEnabled =
            UserDefaults.standard.object(forKey: "isFloatingSignalWaitingSoundEnabled") as? Bool
        let storedAutomaticUpdateCheckEnabled =
            UserDefaults.standard.object(forKey: "isAutomaticUpdateCheckEnabled") as? Bool
        let storedLastAutomaticUpdateCheckAt =
            UserDefaults.standard.object(forKey: "lastAutomaticUpdateCheckAt") as? Date
        let shouldApplyPreferenceDefaults =
            UserDefaults.standard.integer(forKey: "settingsPreferenceDefaultsVersion")
                < Self.preferenceDefaultsVersion
        let shouldApplyEffectDefaults = UserDefaults.standard.integer(forKey: "signalEffectDefaultsVersion") < Self.effectDefaultsVersion
        let resolvedDisplayLayout =
            storedLayout.flatMap(TrafficSignalLayout.init(rawValue:)) ?? Self.defaultDisplayLayout
        displayLayout = resolvedDisplayLayout
        statusBarStyle = storedStyle.flatMap(TrafficSignalStyle.init(rawValue:)) ?? Self.defaultStatusBarStyle
        let storedMacOSBreathingStrength = storedMacOSStrength.flatMap(MacOSBreathingStrength.init(rawValue:))
        let resolvedMacOSBreathingStrength = storedMacOSBreathingStrength ?? .pronounced
        macOSBreathingStrength = resolvedMacOSBreathingStrength
        if storedMacOSBreathingStrength == nil {
            UserDefaults.standard.set(resolvedMacOSBreathingStrength.rawValue, forKey: "macOSBreathingStrength")
        }
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
        let resolvedNeedsReviewSignalEffect = Self.resolvedAlertSignalEffect(
            rawValue: storedNeedsReviewSignalEffect,
            defaultEffect: .slowFlash,
            legacyPulseReplacement: .slowFlash
        )
        let resolvedPermissionSignalEffect = Self.resolvedAlertSignalEffect(
            rawValue: storedPermissionSignalEffect,
            defaultEffect: .slowFlash,
            legacyPulseReplacement: .slowFlash
        )
        let resolvedBlockedSignalEffect = Self.resolvedAlertSignalEffect(
            rawValue: storedBlockedSignalEffect,
            defaultEffect: .fastFlash,
            legacyPulseReplacement: .fastFlash
        )
        needsReviewSignalEffect = resolvedNeedsReviewSignalEffect
        permissionSignalEffect = resolvedPermissionSignalEffect
        blockedSignalEffect = resolvedBlockedSignalEffect
        if shouldApplyEffectDefaults {
            UserDefaults.standard.set(resolvedThinkingSignalEffect.rawValue, forKey: "thinkingSignalEffect")
            UserDefaults.standard.set(resolvedActiveSignalEffect.rawValue, forKey: "activeSignalEffect")
            UserDefaults.standard.set(resolvedCompletedSignalEffect.rawValue, forKey: "completedSignalEffect")
            UserDefaults.standard.set(Self.effectDefaultsVersion, forKey: "signalEffectDefaultsVersion")
        }
        if storedNeedsReviewSignalEffect == nil || storedNeedsReviewSignalEffect == AlertSignalEffect.pulse.rawValue {
            UserDefaults.standard.set(resolvedNeedsReviewSignalEffect.rawValue, forKey: "needsReviewSignalEffect")
        }
        if storedPermissionSignalEffect == nil || storedPermissionSignalEffect == AlertSignalEffect.pulse.rawValue {
            UserDefaults.standard.set(resolvedPermissionSignalEffect.rawValue, forKey: "permissionSignalEffect")
        }
        if storedBlockedSignalEffect == nil || storedBlockedSignalEffect == AlertSignalEffect.pulse.rawValue {
            UserDefaults.standard.set(resolvedBlockedSignalEffect.rawValue, forKey: "blockedSignalEffect")
        }
        appLanguage = storedLanguage.flatMap(AppLanguage.init(rawValue:)) ?? .system
        appTheme = storedTheme.flatMap(AppTheme.init(rawValue:)) ?? .system
        isSettingsGlassEnabled = storedSettingsGlassEnabled ?? true
        isDebugSettingsVisible = storedDebugSettingsVisible ?? false
        isDebugFileLoggingEnabled = storedDebugFileLoggingEnabled ?? false
        debugLogLevel = storedDebugLogLevel.flatMap(DebugLogLevel.init(rawValue:)) ?? .verbose
        settingsGlassEffect =
            SettingsGlassEffect.preferenceValue(for: storedSettingsGlassEffect) ?? .reduced
        isLowPowerModeEnabled = storedLowPowerModeEnabled ?? false
        let resolvedNewZealandTrafficLightModeEnabled = storedNewZealandTrafficLightModeEnabled ?? true
        isNewZealandTrafficLightModeEnabled = resolvedNewZealandTrafficLightModeEnabled
        if storedNewZealandTrafficLightModeEnabled == nil {
            UserDefaults.standard.set(
                resolvedNewZealandTrafficLightModeEnabled,
                forKey: "isNewZealandTrafficLightModeEnabled"
            )
        }
        isFloatingSignalEnabled =
            UserDefaults.standard.object(forKey: "isFloatingSignalEnabled") as? Bool ?? true
        let resolvedFloatingSignalScale = Self.resolvedFloatingSignalScale(
            storedRawValue: storedFloatingSignalScale,
            storedDefaultsVersion: storedFloatingSignalScaleDefaultsVersion
        )
        floatingSignalScale = resolvedFloatingSignalScale
        let resolvedFloatingSignalVisualScale = FloatingSignalScale.clampedVisualScale(
            CGFloat(storedFloatingSignalVisualScale ?? Double(resolvedFloatingSignalScale.visualScale))
        )
        floatingSignalVisualScale = resolvedFloatingSignalVisualScale
        if storedFloatingSignalVisualScale == nil {
            UserDefaults.standard.set(Double(resolvedFloatingSignalVisualScale), forKey: "floatingSignalVisualScale")
        }
        if storedFloatingSignalScaleDefaultsVersion < Self.floatingSignalScaleDefaultsVersion {
            UserDefaults.standard.set(resolvedFloatingSignalScale.rawValue, forKey: "floatingSignalScale")
            UserDefaults.standard.set(
                Self.floatingSignalScaleDefaultsVersion,
                forKey: "floatingSignalScaleDefaultsVersion"
            )
        }
        let storedFloatingSignalLayoutValue = storedFloatingSignalLayout.flatMap(TrafficSignalLayout.init(rawValue:))
        let resolvedFloatingSignalLayout: TrafficSignalLayout
        if shouldApplyPreferenceDefaults,
           storedFloatingSignalLayoutValue == nil || storedFloatingSignalLayoutValue == .horizontal {
            resolvedFloatingSignalLayout = .vertical
        } else {
            resolvedFloatingSignalLayout = storedFloatingSignalLayoutValue ?? .vertical
        }
        floatingSignalLayout = resolvedFloatingSignalLayout
        if storedFloatingSignalLayoutValue != resolvedFloatingSignalLayout {
            UserDefaults.standard.set(resolvedFloatingSignalLayout.rawValue, forKey: "floatingSignalLayout")
        }
        let resolvedFloatingSignalSoundEnabled = storedFloatingSignalSoundEnabled ?? true
        isFloatingSignalSoundEnabled = resolvedFloatingSignalSoundEnabled
        let resolvedFloatingSignalCompletionSound =
            storedFloatingSignalCompletionSound.flatMap(FloatingSignalCompletionSound.init(rawValue:))
            ?? ((storedFloatingSignalCompletionSoundEnabled ?? resolvedFloatingSignalSoundEnabled)
                ? .newZealandCrossing
                : .off)
        floatingSignalCompletionSound = resolvedFloatingSignalCompletionSound
        isFloatingSignalCompletionSoundEnabled = resolvedFloatingSignalCompletionSound.isEnabled
        let resolvedFloatingSignalWaitingSound =
            storedFloatingSignalWaitingSound.flatMap(FloatingSignalWaitingSound.init(rawValue:))
            ?? ((storedFloatingSignalWaitingSoundEnabled ?? resolvedFloatingSignalSoundEnabled)
                ? .newZealandCrossing
                : .off)
        floatingSignalWaitingSound = resolvedFloatingSignalWaitingSound
        isFloatingSignalWaitingSoundEnabled = resolvedFloatingSignalWaitingSound.isEnabled
        floatingSignalSoundLevel =
            storedFloatingSignalSoundLevel.flatMap(FloatingSignalSoundLevel.init(rawValue:)) ?? .standard
        isFloatingSignalInfoBadgeEnabled = storedFloatingSignalInfoBadgeEnabled ?? true
        isFloatingSignalQuotaBadgeEnabled = storedFloatingSignalQuotaBadgeEnabled ?? true
        isFloatingSignalTokenBadgeEnabled = storedFloatingSignalTokenBadgeEnabled ?? true
        if storedFloatingSignalInfoBadgeEnabled == nil {
            UserDefaults.standard.set(true, forKey: "isFloatingSignalInfoBadgeEnabled")
        }
        if storedFloatingSignalQuotaBadgeEnabled == nil {
            UserDefaults.standard.set(true, forKey: "isFloatingSignalQuotaBadgeEnabled")
        }
        if storedFloatingSignalTokenBadgeEnabled == nil {
            UserDefaults.standard.set(true, forKey: "isFloatingSignalTokenBadgeEnabled")
        }
        let resolvedFloatingSignalInfoBadgeCorner =
            storedFloatingSignalInfoBadgeCorner.flatMap(FloatingSignalInfoBadgeCorner.init(rawValue:)) ?? .topRight
        floatingSignalInfoBadgeCorner = resolvedFloatingSignalInfoBadgeCorner
        if storedFloatingSignalInfoBadgeCorner != resolvedFloatingSignalInfoBadgeCorner.rawValue {
            UserDefaults.standard.set(resolvedFloatingSignalInfoBadgeCorner.rawValue, forKey: "floatingSignalInfoBadgeCorner")
        }
        let resolvedFloatingSignalQuotaBadgeCorner =
            storedFloatingSignalQuotaBadgeCorner.flatMap(FloatingSignalInfoBadgeCorner.init(rawValue:)) ?? .topLeft
        floatingSignalQuotaBadgeCorner = resolvedFloatingSignalQuotaBadgeCorner
        if storedFloatingSignalQuotaBadgeCorner != resolvedFloatingSignalQuotaBadgeCorner.rawValue {
            UserDefaults.standard.set(resolvedFloatingSignalQuotaBadgeCorner.rawValue, forKey: "floatingSignalQuotaBadgeCorner")
        }
        let resolvedFloatingSignalTokenBadgeCorner =
            storedFloatingSignalTokenBadgeCorner.flatMap(FloatingSignalInfoBadgeCorner.init(rawValue:)) ?? .bottomLeft
        floatingSignalTokenBadgeCorner = resolvedFloatingSignalTokenBadgeCorner
        if storedFloatingSignalTokenBadgeCorner != resolvedFloatingSignalTokenBadgeCorner.rawValue {
            UserDefaults.standard.set(resolvedFloatingSignalTokenBadgeCorner.rawValue, forKey: "floatingSignalTokenBadgeCorner")
        }
        let resolvedFloatingSignalQuotaBadgeWindow =
            storedFloatingSignalQuotaBadgeWindow.flatMap(FloatingSignalQuotaBadgeWindow.init(rawValue:)) ?? .fiveHours
        floatingSignalQuotaBadgeWindow = resolvedFloatingSignalQuotaBadgeWindow
        if storedFloatingSignalQuotaBadgeWindow != resolvedFloatingSignalQuotaBadgeWindow.rawValue {
            UserDefaults.standard.set(resolvedFloatingSignalQuotaBadgeWindow.rawValue, forKey: "floatingSignalQuotaBadgeWindow")
        }
        let resolvedFloatingSignalTokenBadgeWindow =
            storedFloatingSignalTokenBadgeWindow.flatMap(FloatingSignalTokenBadgeWindow.init(rawValue:)) ?? .today
        floatingSignalTokenBadgeWindow = resolvedFloatingSignalTokenBadgeWindow
        if storedFloatingSignalTokenBadgeWindow != resolvedFloatingSignalTokenBadgeWindow.rawValue {
            UserDefaults.standard.set(resolvedFloatingSignalTokenBadgeWindow.rawValue, forKey: "floatingSignalTokenBadgeWindow")
        }
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
        signalLightAgentSelectionMode = Self.resolvedSignalLightAgentSelectionMode(
            storedMode: storedSignalLightAgentSelectionMode,
            storedScopes: storedSignalLightAgentScopes,
            legacyScope: storedSignalLightAgentScope
        )
        codexUsageDataSource =
            (storedCodexUsageDataSource.flatMap(CodexUsageDataSource.init(rawValue:)) ?? .automatic)
            .resolvedSelectableValue
        codexOpenAICookieMode =
            (storedCodexOpenAICookieMode.flatMap(CodexOpenAICookieMode.init(rawValue:)) ?? .off)
            .resolvedSelectableValue
        codexManualOpenAICookieHeader = Self.loadManualOpenAICookieHeader(
            secretStore: openAICookieStore,
            allowsUserInteraction: false
        )
        let storedStatusMenuModeValue = storedStatusMenuMode.flatMap(StatusMenuMode.init(rawValue:))
        let resolvedStatusMenuMode = storedStatusMenuModeValue ?? .simple
        statusMenuMode = resolvedStatusMenuMode
        if storedStatusMenuModeValue == nil {
            UserDefaults.standard.set(resolvedStatusMenuMode.rawValue, forKey: "statusMenuMode")
        }
        isCodexDesktopMonitoringEnabled =
            UserDefaults.standard.object(forKey: "isCodexDesktopMonitoringEnabled") as? Bool ?? true
        isClaudeDesktopMonitoringEnabled =
            UserDefaults.standard.object(forKey: "isClaudeDesktopMonitoringEnabled") as? Bool ?? true
        let resolvedAutomaticUpdateCheckEnabled = false
        isAutomaticUpdateCheckEnabled = resolvedAutomaticUpdateCheckEnabled
        if storedAutomaticUpdateCheckEnabled != resolvedAutomaticUpdateCheckEnabled {
            UserDefaults.standard.set(resolvedAutomaticUpdateCheckEnabled, forKey: "isAutomaticUpdateCheckEnabled")
        }
        lastAutomaticUpdateCheckAt = storedLastAutomaticUpdateCheckAt
        lastNotifiedUpdateVersion = UserDefaults.standard.string(forKey: "lastNotifiedUpdateVersion")
        snapshot = store.readSnapshot()
        let snapshotQuota = Self.latestQuota(in: snapshot)
        let cachedQuota = Self.cachedLatestAgentQuota()
        latestAgentQuota = Self.latestQuota(snapshotQuota, isNewerThan: cachedQuota) ? snapshotQuota : cachedQuota
        latestAgentTokenUsage = Self.latestTokenUsage(in: snapshot)
            ?? latestAgentQuota?.tokenUsage
            ?? Self.cachedLatestAgentTokenUsage()
        liveTokenUsageScanBaseline = latestAgentTokenUsage?.effectiveTotalTokens
        lastObservedLiveTokenUsageTotal = latestAgentTokenUsage?.effectiveTotalTokens
        isLaunchAtLoginEnabled = launchAtLoginManager.isEnabled
        refreshCodexAccounts()
        hydrateCodexUsageSnapshotForCurrentAccount()
        if shouldApplyPreferenceDefaults {
            enableLaunchAtLoginByDefaultIfNeeded()
            UserDefaults.standard.set(Self.preferenceDefaultsVersion, forKey: "settingsPreferenceDefaultsVersion")
        }
        desktopAppSessions = filteredPlatformPresenceSessions(codexPlatformPresenceMonitor.detectSessions())
        watcher = StateFileWatcher(stateFileURL: snapshot.stateFileURL) { [weak self] in
            self?.reloadFromWatcher()
        }
        watcher?.start()
        startTimers()
    }

    func reload() {
        let latestReleaseInfo = ReleaseInfo.current()
        if latestReleaseInfo != releaseInfo {
            releaseInfo = latestReleaseInfo
        }

        enqueueStateReload()
    }

    func reloadFromWatcher() {
        guard !isMonitoringPaused else { return }
        reload()
    }

    func refreshCodexAccounts() {
        do {
            let state = try codexAccountManager.loadMetadataState()
            applyCodexAccountState(state)
            codexAccountMessage = nil
        } catch {
            codexAccountMessage = error.localizedDescription
        }
    }

    func refreshCodexProviderDetails(force: Bool = false) {
        let now = Date()
        if !force,
           let codexProviderDetailsCheckedAt,
           now.timeIntervalSince(codexProviderDetailsCheckedAt) < Self.codexProviderDetailsRefreshInterval {
            return
        }
        guard !isCodexProviderDetailsLoading else { return }

        isCodexProviderDetailsLoading = true
        let cliProbe = codexCLIStatusProbe
        let rpcProbe = codexRPCStatusProbe
        let serviceStatusFetcher = codexServiceStatusFetcher
        Task(priority: .utility) { [weak self] in
            async let cliStatus = Task.detached(priority: .utility) {
                cliProbe.probe()
            }.value
            async let rpcStatus = rpcProbe.probe()
            async let serviceStatus = try? serviceStatusFetcher.fetch()
            let (resolvedCLIStatus, resolvedRPCStatus, resolvedServiceStatus) = await (
                cliStatus,
                rpcStatus,
                serviceStatus
            )

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.codexCLIVersionText = resolvedCLIStatus.versionText
                self.codexProviderAccountEmail = resolvedRPCStatus.accountEmail
                self.codexProviderPlanName = resolvedRPCStatus.displayPlanName
                self.codexProviderServiceStatusText = resolvedServiceStatus?.displayText
                self.codexProviderDetailsCheckedAt = max(
                    resolvedCLIStatus.checkedAt,
                    resolvedRPCStatus.checkedAt,
                    resolvedServiceStatus?.updatedAt ?? resolvedRPCStatus.checkedAt
                )
                self.isCodexProviderDetailsLoading = false
            }
        }
    }

    func saveCurrentCodexAccount() {
        guard !isCodexAccountActionRunning else { return }
        isCodexAccountActionRunning = true
        do {
            let account = try codexAccountManager.saveCurrentAccount()
            applyCodexAccountState(try codexAccountManager.loadState())
            persistCodexUsageSnapshotForCurrentAccount()
            codexAccountMessage = text("已保存 \(account.displayName)。", "Saved \(account.displayName).")
            lastError = nil
        } catch {
            codexAccountMessage = nil
            lastError = error.localizedDescription
        }
        isCodexAccountActionRunning = false
    }

    func addCodexAccount() {
        guard !isCodexAccountActionRunning else { return }
        isCodexAccountActionRunning = true
        codexAccountMessage = text(
            "正在打开 Codex 登录，请在浏览器完成授权。",
            "Opening Codex login. Complete authorization in the browser."
        )

        Task { [weak self] in
            guard let self else { return }
            do {
                let account = try await codexAccountManager.authenticateManagedAccount()
                let switchedAccount = try codexAccountManager.switchToAccount(id: account.id)
                applyCodexAccountState(try codexAccountManager.loadState())
                prepareCodexUsageAfterAccountChange()
                refreshCodexProviderDetails(force: true)
                codexAccountMessage = text(
                    "已添加并切换到 \(switchedAccount.displayName)。",
                    "Added and switched to \(switchedAccount.displayName)."
                )
                lastError = nil
                pollCodexRateLimitsIfNeeded(force: true)
                refreshTokenActivityIfNeeded()
            } catch {
                codexAccountMessage = nil
                lastError = error.localizedDescription
            }
            isCodexAccountActionRunning = false
        }
    }

    func switchCodexAccount(_ account: CodexAccountProfile) {
        guard !isCodexAccountActionRunning,
              codexActiveSavedAccountID != account.id
        else {
            return
        }

        isCodexAccountActionRunning = true
        do {
            let switchedAccount = try codexAccountManager.switchToAccount(id: account.id)
            applyCodexAccountState(try codexAccountManager.loadState())
            prepareCodexUsageAfterAccountChange()
            refreshCodexProviderDetails(force: true)
            codexAccountMessage = text(
                "已切换到 \(switchedAccount.displayName)。",
                "Switched to \(switchedAccount.displayName)."
            )
            lastError = nil
            pollCodexRateLimitsIfNeeded(force: true)
            refreshTokenActivityIfNeeded()
        } catch {
            codexAccountMessage = nil
            lastError = error.localizedDescription
        }
        isCodexAccountActionRunning = false
    }

    func removeCodexAccount(_ account: CodexAccountProfile) {
        guard !isCodexAccountActionRunning else { return }
        isCodexAccountActionRunning = true
        do {
            try codexAccountManager.removeAccount(id: account.id)
            codexUsageSnapshotStore.remove(for: account)
            applyCodexAccountState(try codexAccountManager.loadState())
            codexAccountMessage = text("已删除保存的账户。", "Saved account removed.")
            lastError = nil
        } catch {
            codexAccountMessage = nil
            lastError = error.localizedDescription
        }
        isCodexAccountActionRunning = false
    }

    func isActiveCodexAccount(_ account: CodexAccountProfile) -> Bool {
        codexActiveSavedAccountID == account.id
    }

    func setManualSignal(_ signal: AgentSignal) {
        do {
            snapshot = try store.setManualSignal(signal)
            updateLatestAgentQuota(from: snapshot)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func clearSessions() {
        do {
            snapshot = try store.clearSessions()
            updateLatestAgentQuota(from: snapshot)
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
            pollDesktopAppPresence()
        } else {
            reload()
            pollCodexRateLimitsIfNeeded(force: true)
            pollDesktopAppPresence()
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

    private static func resolvedAlertSignalEffect(
        rawValue: String?,
        defaultEffect: AlertSignalEffect,
        legacyPulseReplacement: AlertSignalEffect
    ) -> AlertSignalEffect {
        let effect = rawValue.flatMap(AlertSignalEffect.init(rawValue:)) ?? defaultEffect
        return effect == .pulse ? legacyPulseReplacement : effect
    }

    func setNeedsReviewSignalEffect(_ effect: AlertSignalEffect) {
        needsReviewSignalEffect = effect
        UserDefaults.standard.set(effect.rawValue, forKey: "needsReviewSignalEffect")
    }

    func setPermissionSignalEffect(_ effect: AlertSignalEffect) {
        permissionSignalEffect = effect
        UserDefaults.standard.set(effect.rawValue, forKey: "permissionSignalEffect")
    }

    func setBlockedSignalEffect(_ effect: AlertSignalEffect) {
        blockedSignalEffect = effect
        UserDefaults.standard.set(effect.rawValue, forKey: "blockedSignalEffect")
    }

    var signalEffectCustomization: SignalEffectCustomization {
        SignalEffectCustomization(
            thinkingEffect: thinkingSignalEffect,
            activeEffect: activeSignalEffect,
            activeSpeed: activeEffectSpeed,
            alertSpeed: alertEffectSpeed,
            completedEffect: completedSignalEffect,
            needsReviewEffect: needsReviewSignalEffect,
            permissionEffect: permissionSignalEffect,
            blockedEffect: blockedSignalEffect
        )
    }

    var tick: Int {
        animationClock.tick
    }

    var lightSnapshot: SignalSnapshot {
        lightSnapshot(for: nil)
    }

    var statusBarLightSnapshot: SignalSnapshot {
        lightSnapshot(for: .statusBar)
    }

    var floatingSignalLightSnapshot: SignalSnapshot {
        lightSnapshot(for: .floatingSignal)
    }

    var isSignalSoundSurfaceEnabled: Bool {
        isStatusBarIconEnabled || isFloatingSignalEnabled
    }

    var lightTick: Int {
        return statusLightOverride?.tick ?? animationClock.tick
    }

    var statusBarLightTick: Int {
        lightTick(for: .statusBar)
    }

    var floatingSignalLightTick: Int {
        lightTick(for: .floatingSignal)
    }

    var lightAllLightsOn: Bool {
        lightAllLightsOn(for: nil)
    }

    var statusBarLightAllLightsOn: Bool {
        lightAllLightsOn(for: .statusBar)
    }

    var floatingSignalLightAllLightsOn: Bool {
        lightAllLightsOn(for: .floatingSignal)
    }

    var lightUsesSystemGrayLights: Bool {
        lightUsesSystemGrayLights(for: nil)
    }

    var statusBarLightUsesSystemGrayLights: Bool {
        lightUsesSystemGrayLights(for: .statusBar)
    }

    var floatingSignalLightUsesSystemGrayLights: Bool {
        lightUsesSystemGrayLights(for: .floatingSignal)
    }

    var lightEffectCustomization: SignalEffectCustomization {
        lightEffectCustomization(for: nil)
    }

    var statusBarLightEffectCustomization: SignalEffectCustomization {
        lightEffectCustomization(for: .statusBar)
    }

    var floatingSignalLightEffectCustomization: SignalEffectCustomization {
        lightEffectCustomization(for: .floatingSignal)
    }

    var statusBarStatusLightOverride: StatusLightOverrideFrame? {
        statusLightOverride(for: .statusBar)
    }

    var floatingSignalStatusLightOverride: StatusLightOverrideFrame? {
        statusLightOverride(for: .floatingSignal)
    }

    var runtimeTimingProfile: RuntimeTimingProfile {
        isLowPowerModeEnabled ? .lowPower : .standard
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

    func setFloatingSignalEnabled(_ enabled: Bool) {
        isFloatingSignalEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isFloatingSignalEnabled")
    }

    func setFloatingSignalScale(_ scale: FloatingSignalScale) {
        floatingSignalScale = scale
        UserDefaults.standard.set(scale.rawValue, forKey: "floatingSignalScale")
        setFloatingSignalVisualScale(scale.visualScale, persist: true)
        UserDefaults.standard.set(
            Self.floatingSignalScaleDefaultsVersion,
            forKey: "floatingSignalScaleDefaultsVersion"
        )
    }

    func setFloatingSignalVisualScale(_ visualScale: CGFloat, persist: Bool) {
        let clampedScale = FloatingSignalScale.clampedVisualScale(visualScale)
        guard abs(floatingSignalVisualScale - clampedScale) > 0.001 || persist else { return }

        floatingSignalVisualScale = clampedScale
        if persist {
            UserDefaults.standard.set(Double(clampedScale), forKey: "floatingSignalVisualScale")
        }
    }

    func setFloatingSignalLayout(_ layout: TrafficSignalLayout) {
        floatingSignalLayout = layout
        UserDefaults.standard.set(layout.rawValue, forKey: "floatingSignalLayout")
    }

    func makeFloatingSignalSmaller() {
        setFloatingSignalVisualScale(floatingSignalVisualScale - 0.18, persist: true)
    }

    func makeFloatingSignalLarger() {
        setFloatingSignalVisualScale(floatingSignalVisualScale + 0.18, persist: true)
    }

    func setFloatingSignalSoundEnabled(_ enabled: Bool) {
        isFloatingSignalSoundEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isFloatingSignalSoundEnabled")
    }

    func setFloatingSignalCompletionSoundEnabled(_ enabled: Bool) {
        setFloatingSignalCompletionSound(enabled ? .newZealandCrossing : .off)
    }

    func setFloatingSignalWaitingSoundEnabled(_ enabled: Bool) {
        setFloatingSignalWaitingSound(enabled ? .newZealandCrossing : .off)
    }

    func setFloatingSignalCompletionSound(_ sound: FloatingSignalCompletionSound) {
        floatingSignalCompletionSound = sound
        isFloatingSignalCompletionSoundEnabled = sound.isEnabled
        UserDefaults.standard.set(sound.rawValue, forKey: "floatingSignalCompletionSound")
        UserDefaults.standard.set(sound.isEnabled, forKey: "isFloatingSignalCompletionSoundEnabled")
    }

    func setFloatingSignalWaitingSound(_ sound: FloatingSignalWaitingSound) {
        floatingSignalWaitingSound = sound
        isFloatingSignalWaitingSoundEnabled = sound.isEnabled
        UserDefaults.standard.set(sound.rawValue, forKey: "floatingSignalWaitingSound")
        UserDefaults.standard.set(sound.isEnabled, forKey: "isFloatingSignalWaitingSoundEnabled")
    }

    func setFloatingSignalSoundLevel(_ level: FloatingSignalSoundLevel) {
        floatingSignalSoundLevel = level
        UserDefaults.standard.set(level.rawValue, forKey: "floatingSignalSoundLevel")
    }

    func setFloatingSignalInfoBadgeEnabled(_ enabled: Bool) {
        guard isFloatingSignalInfoBadgeEnabled != enabled else { return }
        isFloatingSignalInfoBadgeEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isFloatingSignalInfoBadgeEnabled")
    }

    func setFloatingSignalQuotaBadgeEnabled(_ enabled: Bool) {
        guard isFloatingSignalQuotaBadgeEnabled != enabled else { return }
        isFloatingSignalQuotaBadgeEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isFloatingSignalQuotaBadgeEnabled")
        if enabled {
            pollCodexRateLimitsIfNeeded(force: true)
        }
    }

    func setFloatingSignalTokenBadgeEnabled(_ enabled: Bool) {
        guard isFloatingSignalTokenBadgeEnabled != enabled else { return }
        isFloatingSignalTokenBadgeEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isFloatingSignalTokenBadgeEnabled")
        if enabled {
            refreshTokenActivityIfNeeded(force: tokenActivityDays.isEmpty)
        }
    }

    func setFloatingSignalInfoBadgeCorner(_ corner: FloatingSignalInfoBadgeCorner) {
        guard floatingSignalInfoBadgeCorner != corner else { return }
        floatingSignalInfoBadgeCorner = corner
        UserDefaults.standard.set(corner.rawValue, forKey: "floatingSignalInfoBadgeCorner")
    }

    func setFloatingSignalQuotaBadgeCorner(_ corner: FloatingSignalInfoBadgeCorner) {
        guard floatingSignalQuotaBadgeCorner != corner else { return }
        floatingSignalQuotaBadgeCorner = corner
        UserDefaults.standard.set(corner.rawValue, forKey: "floatingSignalQuotaBadgeCorner")
    }

    func setFloatingSignalTokenBadgeCorner(_ corner: FloatingSignalInfoBadgeCorner) {
        guard floatingSignalTokenBadgeCorner != corner else { return }
        floatingSignalTokenBadgeCorner = corner
        UserDefaults.standard.set(corner.rawValue, forKey: "floatingSignalTokenBadgeCorner")
    }

    func setFloatingSignalQuotaBadgeWindow(_ window: FloatingSignalQuotaBadgeWindow) {
        guard floatingSignalQuotaBadgeWindow != window else { return }
        floatingSignalQuotaBadgeWindow = window
        UserDefaults.standard.set(window.rawValue, forKey: "floatingSignalQuotaBadgeWindow")
    }

    func setFloatingSignalTokenBadgeWindow(_ window: FloatingSignalTokenBadgeWindow) {
        guard floatingSignalTokenBadgeWindow != window else { return }
        floatingSignalTokenBadgeWindow = window
        UserDefaults.standard.set(window.rawValue, forKey: "floatingSignalTokenBadgeWindow")
    }

    func tokenActivityTotal(for window: FloatingSignalTokenBadgeWindow, now: Date = Date()) -> Int {
        let scannedTotal = tokenActivityDays(for: window, now: now)
            .map(\.totalTokens)
            .reduce(0, +)
        guard tokenWindowIncludesToday(window, now: now) else {
            return scannedTotal
        }
        return scannedTotal + liveTokenUsageSupplement
    }

    func tokenActivityEstimatedCost(for window: FloatingSignalTokenBadgeWindow, now: Date = Date()) -> Double? {
        let costs = tokenActivityDays(for: window, now: now)
            .compactMap(\.estimatedCostUSD)
        return costs.isEmpty ? nil : costs.reduce(0, +)
    }

    private func tokenActivityDays(for window: FloatingSignalTokenBadgeWindow, now: Date) -> [CodexTokenActivityDay] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)

        switch window {
        case .today:
            return tokenActivityDays.filter { calendar.isDate($0.day, inSameDayAs: today) }
        case .last30Days:
            let startDay = calendar.date(byAdding: .day, value: -29, to: today) ?? today
            return tokenActivityDays.filter {
                let day = calendar.startOfDay(for: $0.day)
                return day >= startDay && day <= today
            }
        }
    }

    private var liveTokenUsageSupplement: Int {
        guard let latestTotal = latestAgentTokenUsage?.effectiveTotalTokens else {
            return 0
        }

        let baseline = liveTokenUsageScanBaseline ?? 0
        return max(0, latestTotal - baseline)
    }

    private func tokenWindowIncludesToday(_ window: FloatingSignalTokenBadgeWindow, now: Date) -> Bool {
        switch window {
        case .today, .last30Days:
            return true
        }
    }

    func previewFloatingSignalSound() {
        floatingSignalSoundTestTick &+= 1
    }

    func previewFloatingSignalWaitingSound() {
        floatingSignalWaitingSoundTestTick &+= 1
    }

    func savedFloatingSignalOrigin() -> NSPoint? {
        guard let x = UserDefaults.standard.object(forKey: "floatingSignalOriginX") as? Double,
              let y = UserDefaults.standard.object(forKey: "floatingSignalOriginY") as? Double
        else {
            return nil
        }

        return NSPoint(x: x, y: y)
    }

    func setFloatingSignalOrigin(_ origin: NSPoint) {
        UserDefaults.standard.set(Double(origin.x), forKey: "floatingSignalOriginX")
        UserDefaults.standard.set(Double(origin.y), forKey: "floatingSignalOriginY")
    }

    func setSignalLightAgentScopes(_ scopes: Set<SignalLightAgentScope>) {
        let selectableScopes = Set(SignalLightAgentScope.selectableCases)
        let resolvedScopes = scopes.intersection(selectableScopes)
        guard !resolvedScopes.isEmpty else { return }

        signalLightAgentScopes = resolvedScopes
        signalLightAgentSelectionMode = .manual
        UserDefaults.standard.set(
            resolvedScopes
                .sorted { $0.sortOrder < $1.sortOrder }
                .map(\.rawValue),
            forKey: "signalLightAgentScopes"
        )
        UserDefaults.standard.set(
            signalLightAgentSelectionMode.rawValue,
            forKey: "signalLightAgentSelectionMode"
        )
    }

    func toggleSignalLightAgentScope(_ scope: SignalLightAgentScope) {
        if signalLightAgentSelectionMode == .following {
            setSignalLightAgentScopes([scope])
            return
        }

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

    func setCodexUsageDataSource(_ source: CodexUsageDataSource) {
        let resolvedSource = source.resolvedSelectableValue
        guard codexUsageDataSource != resolvedSource else { return }
        codexUsageDataSource = resolvedSource
        UserDefaults.standard.set(resolvedSource.rawValue, forKey: "codexUsageDataSource")
        lastCodexRateLimitFetchAt = nil
        lastError = nil
        pollCodexRateLimitsIfNeeded(force: true)
    }

    func setCodexOpenAICookieMode(_ mode: CodexOpenAICookieMode) {
        let resolvedMode = mode.resolvedSelectableValue
        guard codexOpenAICookieMode != resolvedMode else { return }
        codexOpenAICookieMode = resolvedMode
        UserDefaults.standard.set(resolvedMode.rawValue, forKey: "codexOpenAICookieMode")
        lastCodexRateLimitFetchAt = nil
        pollCodexRateLimitsIfNeeded(force: true)
    }

    func setCodexManualOpenAICookieHeader(_ header: String) {
        codexManualOpenAICookieHeader = header
        do {
            if header.isEmpty {
                try openAICookieStore.delete(key: Self.manualOpenAICookieKey)
            } else {
                try openAICookieStore.set(header, for: Self.manualOpenAICookieKey)
            }
            UserDefaults.standard.removeObject(forKey: Self.legacyManualOpenAICookieUserDefaultsKey)
        } catch {
            lastError = text(
                "无法保存 OpenAI Cookie：\(error.localizedDescription)",
                "Could not save OpenAI Cookie: \(error.localizedDescription)"
            )
        }
        lastCodexRateLimitFetchAt = nil
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

    func setDebugSettingsVisible(_ visible: Bool) {
        isDebugSettingsVisible = visible
        UserDefaults.standard.set(visible, forKey: "isDebugSettingsVisible")
    }

    func setDebugFileLoggingEnabled(_ enabled: Bool) {
        isDebugFileLoggingEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isDebugFileLoggingEnabled")
        if enabled {
            appendDebugLog("file logging enabled")
        }
    }

    func setDebugLogLevel(_ level: DebugLogLevel) {
        debugLogLevel = level
        UserDefaults.standard.set(level.rawValue, forKey: "debugLogLevel")
        appendDebugLog("log level set to \(level.displayName)")
    }

    var debugLogFileURL: URL {
        let logsDirectory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
        return logsDirectory
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("AgentSignalLight", isDirectory: true)
            .appendingPathComponent(Self.debugLogFileName, isDirectory: false)
    }

    func openDebugLogFile() {
        ensureDebugLogFileExists()
        NSWorkspace.shared.open(debugLogFileURL)
    }

    func copyDebugLog() {
        let text = loadDebugLogText()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func copyDebugText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func loadDebugLogText() -> String {
        ensureDebugLogFileExists()
        return (try? String(contentsOf: debugLogFileURL, encoding: .utf8))
            ?? text("尚无日志。", "No log yet.")
    }

    func debugProbeLog(provider: String) -> String {
        let now = Date().formatted(date: .numeric, time: .standard)
        switch provider.lowercased() {
        case "codex":
            let account = codexProviderAccountEmail ?? codexCurrentAccount?.displayName ?? "--"
            let plan = codexProviderPlanName ?? "--"
            let source = codexUsageDataSource.rawValue
            let quota = latestAgentQuota.map { quotaDebugLine($0) } ?? "quota unavailable"
            let tokens = latestAgentTokenUsage.map {
                "tokens total=\($0.effectiveTotalTokens.map(String.init) ?? "--") input=\($0.inputTokens.map(String.init) ?? "--") output=\($0.outputTokens.map(String.init) ?? "--")"
            } ?? "tokens unavailable"
            return """
            [\(now)] Codex probe
            account=\(account)
            plan=\(plan)
            source=\(source)
            cli=\(codexCLIVersionText ?? "--")
            service=\(codexProviderServiceStatusText ?? "--")
            \(quota)
            \(tokens)
            rateLimitInFlight=\(isCodexRateLimitFetchInFlight)
            tokenScanInFlight=\(isTokenActivityLoading)
            """
        case "claude":
            let sessions = activitySnapshot.sessions.filter {
                let haystack = [$0.sessionID, $0.agent ?? "", $0.lastEvent ?? ""].joined(separator: " ").lowercased()
                return haystack.contains("claude")
            }
            return """
            [\(now)] Claude probe
            monitoringEnabled=\(isClaudeDesktopMonitoringEnabled)
            sessions=\(sessions.count)
            latest=\(sessions.map { $0.updatedAt.formatted(date: .numeric, time: .standard) }.max() ?? "--")
            source=desktop/activity monitor
            """
        default:
            return "[\(now)] \(provider) probe unavailable."
        }
    }

    func debugFetchStrategyLog(provider: String) -> String {
        switch provider.lowercased() {
        case "codex":
            let oauthAvailable = codexCurrentAccount?.credentialKind == .oauth
            let cliAvailable = codexCLIVersionText != nil
            return """
            codex.oauth (oauth) \(oauthAvailable ? "available" : "unavailable")
            codex.rate_limits (oauth api) \(codexUsageDataSource == .cliRPCPTY ? "skipped source=cli-rpc-pty" : "available")
            codex.cli_status (cli) \(cliAvailable ? "available" : "unavailable")
            codex.local_token_scan (local) available
            """
        case "claude":
            return """
            claude.desktop_monitor (local) \(isClaudeDesktopMonitoringEnabled ? "available" : "disabled")
            claude.code_hook (hook) displayed when hook events arrive
            claude.usage_api unavailable
            """
        default:
            return "\(provider) strategy unavailable."
        }
    }

    func debugOpenAICookieLog() -> String {
        """
        OpenAI Cookie mode: \(codexOpenAICookieMode.rawValue)
        Current Codex account: \(codexCurrentAccount?.displayName ?? "--")
        Manual Cookie header length: \(codexManualOpenAICookieHeader.count)
        Normalized Cookie header available: \(CodexRateLimitFetcher.normalizedCookieHeader(codexManualOpenAICookieHeader) == nil ? "false" : "true")
        Cookie usage fetch: \(codexOpenAICookieMode == .off ? "disabled" : "enabled")
        """
    }

    func clearDebugUsageCache() {
        clearLatestAgentQuotaCache()
        clearLatestAgentTokenUsageCache()
        clearTokenActivityCache()
        codexUsageSnapshotStore.removeAll()
        debugCacheMessage = text("已清除费用/用量缓存。", "Usage cache cleared.")
        appendDebugLog("usage cache cleared")
    }

    func clearDebugCookieCache() {
        codexManualOpenAICookieHeader = ""
        try? openAICookieStore.delete(key: Self.manualOpenAICookieKey)
        UserDefaults.standard.removeObject(forKey: Self.legacyManualOpenAICookieUserDefaultsKey)
        lastCodexRateLimitFetchAt = nil
        debugCacheMessage = text("已清除保存的 OpenAI Cookie。", "Saved OpenAI Cookie cleared.")
        appendDebugLog("saved OpenAI cookie cleared")
    }

    func installBundledCLI() {
        guard !isCLIInstallRunning else { return }
        guard let sourceURL = bundledCLIURL() else {
            cliInstallMessage = text(
                "没有找到内置 agent-signal-light CLI。请先重新构建或安装正式版 App。",
                "Bundled agent-signal-light CLI was not found. Rebuild or install the packaged app first."
            )
            return
        }

        isCLIInstallRunning = true
        cliInstallMessage = text("正在安装 agent-signal-light CLI...", "Installing agent-signal-light CLI...")

        let installDirectory = preferredCLIInstallDirectory()
        let installPath = installDirectory.appendingPathComponent("agent-signal-light", isDirectory: false)
        let sourcePath = sourceURL.path
        let destinationPath = installPath.path

        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try Self.installCLI(sourcePath: sourcePath, destinationPath: destinationPath)
            }

            DispatchQueue.main.async {
                self.isCLIInstallRunning = false
                switch result {
                case .success:
                    self.cliInstallMessage = self.text(
                        "已安装：\(destinationPath)",
                        "Installed: \(destinationPath)"
                    )
                    self.lastError = nil
                case .failure(let error):
                    self.cliInstallMessage = self.text(
                        "安装失败：\(error.localizedDescription)",
                        "Install failed: \(error.localizedDescription)"
                    )
                }
            }
        }
    }

    func runDebugLightSignal(_ signal: AgentSignal, targets: Set<StatusLightOverrideTarget> = Set(StatusLightOverrideTarget.allCases)) {
        guard !targets.isEmpty else { return }
        setDebugLight(
            signal: signal,
            allLightsOn: false,
            effectCustomization: signalEffectCustomization,
            targets: targets
        )
        appendDebugLog("debug light signal \(signal.rawValue)")
    }

    func setDebugLight(
        signal: AgentSignal,
        allLightsOn: Bool = false,
        effectCustomization: SignalEffectCustomization? = nil,
        targets: Set<StatusLightOverrideTarget> = Set(StatusLightOverrideTarget.allCases)
    ) {
        guard !targets.isEmpty else { return }
        let frame = StatusLightOverrideFrame(
            signal: signal,
            tick: 0,
            allLightsOn: allLightsOn,
            effectCustomization: effectCustomization ?? signalEffectCustomization,
            targets: targets,
            usesLiveTick: true
        )
        statusLightSequence = []
        statusLightSequenceIndex = 0
        statusLightOverride = frame
        appendDebugLog("debug light set \(signal.rawValue)")
    }

    func setLightDebugModeEnabled(
        _ enabled: Bool,
        targets: Set<StatusLightOverrideTarget> = Set(StatusLightOverrideTarget.allCases)
    ) {
        let shouldLogStateChange = isLightDebugModeEnabled != enabled
        let effectiveTargets = targets.isEmpty ? Set(StatusLightOverrideTarget.allCases) : targets
        isLightDebugModeEnabled = enabled
        if enabled {
            setDebugLight(signal: .idle, targets: effectiveTargets)
            if shouldLogStateChange {
                appendDebugLog("debug light mode enabled")
            }
        } else {
            clearDebugLight()
            if shouldLogStateChange {
                appendDebugLog("debug light mode disabled")
            }
        }
    }

    func previewDebugLight(
        signal: AgentSignal,
        allLightsOn: Bool = false,
        effectCustomization: SignalEffectCustomization,
        targets: Set<StatusLightOverrideTarget> = Set(StatusLightOverrideTarget.allCases)
    ) {
        guard !targets.isEmpty else { return }
        let frames = (0..<24).map { tick in
            StatusLightOverrideFrame(
                signal: signal,
                tick: tick,
                allLightsOn: allLightsOn,
                effectCustomization: effectCustomization,
                targets: targets
            )
        }
        startStatusLightSequence(frames)
        appendDebugLog("debug light preview \(signal.rawValue)")
    }

    func clearDebugLight() {
        statusLightSequence = []
        statusLightSequenceIndex = 0
        statusLightOverride = nil
        appendDebugLog("debug light cleared")
    }

    func replayDebugLightSequence(targets: Set<StatusLightOverrideTarget> = Set(StatusLightOverrideTarget.allCases)) {
        guard !targets.isEmpty else { return }
        let customization = signalEffectCustomization
        startStatusLightSequence([
            StatusLightOverrideFrame(signal: .working, tick: 0, allLightsOn: false, effectCustomization: customization, targets: targets),
            StatusLightOverrideFrame(signal: .working, tick: 4, allLightsOn: false, effectCustomization: customization, targets: targets),
            StatusLightOverrideFrame(signal: .permission, tick: 0, allLightsOn: false, effectCustomization: customization, targets: targets),
            StatusLightOverrideFrame(signal: .blocked, tick: 0, allLightsOn: false, effectCustomization: customization, targets: targets),
            StatusLightOverrideFrame(signal: .done, tick: 0, allLightsOn: true, effectCustomization: customization, targets: targets)
        ])
        appendDebugLog("debug light sequence replayed")
    }

    func blinkDebugLightNow() {
        startStatusLightSequence([
            StatusLightOverrideFrame(signal: .done, tick: 0, allLightsOn: true, effectCustomization: signalEffectCustomization),
            StatusLightOverrideFrame(signal: .idle, tick: 0, allLightsOn: false, effectCustomization: signalEffectCustomization),
            StatusLightOverrideFrame(signal: .done, tick: 0, allLightsOn: true, effectCustomization: signalEffectCustomization)
        ])
        appendDebugLog("debug light blink")
    }

    func setSettingsGlassEffect(_ effect: SettingsGlassEffect) {
        settingsGlassEffect = effect
        UserDefaults.standard.set(effect.rawValue, forKey: "settingsGlassEffect")
    }

    func setLowPowerModeEnabled(_ enabled: Bool) {
        guard enabled != isLowPowerModeEnabled else { return }
        isLowPowerModeEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isLowPowerModeEnabled")
        animationFrameSkipCounter = 0
        animationClock.reset()
        restartTimers()
        reload()
        pollCodexDesktopActivity()
        pollDesktopAppPresence()
    }

    func setNewZealandTrafficLightModeEnabled(_ enabled: Bool) {
        guard enabled != isNewZealandTrafficLightModeEnabled else { return }
        isNewZealandTrafficLightModeEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isNewZealandTrafficLightModeEnabled")
        if enabled {
            setFloatingSignalCompletionSound(.newZealandCrossing)
            setFloatingSignalWaitingSound(.newZealandCrossing)
        }
        animationFrameSkipCounter = 0
        animationClock.reset()
    }

    func setAutomaticUpdateCheckEnabled(_ enabled: Bool) {
        guard enabled != isAutomaticUpdateCheckEnabled else { return }
        isAutomaticUpdateCheckEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isAutomaticUpdateCheckEnabled")

        if enabled {
            requestUpdateNotificationAuthorizationIfNeeded()
            performAutomaticUpdateCheckIfNeeded(force: true)
        } else {
            updateCheckMessage = text(
                "已关闭自动检查更新。",
                "Automatic update checks are off."
            )
        }
    }

    var statusBarTooltip: String {
        let displaySnapshot = lightSnapshot
        var lines = [
            "Agent Signal Bar",
            "\(displayName(for: displaySnapshot.aggregate)) - \(humanAction(for: displaySnapshot.aggregate))"
        ]

        lines.append("\(text("灯效 Agent", "Light Agent")): \(displayName(for: displaySignalLightAgentScopes))")

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
        let displayScopes = signalLightAgentScopesForDisplay(from: displaySessions)
        let scopedDisplaySessions = displaySessions.filter { Self.session($0, matches: displayScopes) }
        let deduplicatedSessions = deduplicatedDisplaySessions(scopedDisplaySessions)
        let scopedRecentEvents = snapshot.recentEvents
            .filter { !Self.isSignalTestEvent($0.event) }
            .filter { Self.event($0, matches: displayScopes) }
        let deduplicatedRecentEvents = deduplicatedRecentEvents(scopedRecentEvents)
        let displayUpdatedAt = deduplicatedSessions.map(\.updatedAt).max()

        return SignalSnapshot(
            aggregate: aggregateForSignalLightScopes(
                sessions: deduplicatedSessions,
                fallback: snapshot.aggregate,
                scopes: displayScopes
            ),
            sessions: deduplicatedSessions,
            recentEvents: deduplicatedRecentEvents,
            stateFileURL: snapshot.stateFileURL,
            updatedAt: displayUpdatedAt
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

    private func enableLaunchAtLoginByDefaultIfNeeded() {
        guard !isLaunchAtLoginEnabled else { return }
        setLaunchAtLoginEnabled(true)
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

    private func performAutomaticUpdateCheckIfNeeded(force: Bool = false) {
        guard isAutomaticUpdateCheckEnabled else { return }
        guard !isUpdateCheckRunning, !isAutomaticUpdateCheckInFlight else { return }

        let now = Date()
        if !force,
           let lastAutomaticUpdateCheckAt,
           now.timeIntervalSince(lastAutomaticUpdateCheckAt) < Self.automaticUpdateCheckInterval
        {
            return
        }

        let currentVersion = releaseInfo.version
        let checker = updateChecker
        isAutomaticUpdateCheckInFlight = true

        Task {
            let checkedAt = Date()

            do {
                let result = try await checker.check(currentVersion: currentVersion)
                await MainActor.run {
                    self.isAutomaticUpdateCheckInFlight = false
                    self.lastAutomaticUpdateCheckAt = checkedAt
                    UserDefaults.standard.set(checkedAt, forKey: "lastAutomaticUpdateCheckAt")

                    if result.isUpdateAvailable {
                        self.updateReleasePageURL = result.releasePageURL
                        self.updateCheckMessage = self.text(
                            "发现新版本 \(result.latestVersion)（当前 \(result.currentVersion)）。",
                            "Version \(result.latestVersion) is available. Current version: \(result.currentVersion)."
                        )
                        self.notifyUpdateAvailable(result)
                    } else if force {
                        self.updateReleasePageURL = nil
                        self.updateCheckMessage = self.text(
                            "自动检查完成：当前版本 \(result.currentVersion)，已是最新版本。",
                            "Automatic check complete: current version \(result.currentVersion), you are up to date."
                        )
                    }
                }
            } catch {
                let errorMessage = error.localizedDescription
                await MainActor.run {
                    self.isAutomaticUpdateCheckInFlight = false
                    self.lastAutomaticUpdateCheckAt = checkedAt
                    UserDefaults.standard.set(checkedAt, forKey: "lastAutomaticUpdateCheckAt")

                    if force {
                        self.updateReleasePageURL = GitHubReleaseUpdateChecker.fallbackReleasePageURL
                        self.updateCheckMessage = self.text(
                            "自动检查更新失败：\(errorMessage)",
                            "Automatic update check failed: \(errorMessage)"
                        )
                    }
                }
            }
        }
    }

    private func requestUpdateNotificationAuthorizationIfNeeded() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    private func notifyUpdateAvailable(_ result: GitHubUpdateCheckResult) {
        guard result.isUpdateAvailable else { return }
        guard lastNotifiedUpdateVersion != result.latestVersion else { return }

        lastNotifiedUpdateVersion = result.latestVersion
        UserDefaults.standard.set(result.latestVersion, forKey: "lastNotifiedUpdateVersion")

        let content = UNMutableNotificationContent()
        content.title = "Agent Signal Bar"
        content.subtitle = text(
            "发现新版本 \(result.latestVersion)",
            "Version \(result.latestVersion) is available"
        )
        content.body = text(
            "打开关于页面或下载页面更新。",
            "Open the About page or download page to update."
        )
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "agent-signal-bar-update-\(result.latestVersion)",
            content: content,
            trigger: nil
        )

        deliverUpdateNotification(request)
    }

    private func deliverUpdateNotification(_ request: UNNotificationRequest) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                center.add(request)
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    guard granted else { return }
                    center.add(request)
                }
            case .denied:
                break
            @unknown default:
                break
            }
        }
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

    func checkForUpdatesFromAppMenu() {
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
                    self.showUpdateCheckDialog(for: result)
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
                    self.showUpdateCheckFailureDialog(message: errorMessage)
                }
            }
        }
    }

    private func showUpdateCheckDialog(for result: GitHubUpdateCheckResult) {
        let alert = NSAlert()
        alert.alertStyle = result.isUpdateAvailable ? .informational : .informational
        alert.messageText = result.isUpdateAvailable
            ? text("发现新版本", "Update Available")
            : text("Agent Signal Bar 已是最新版本", "Agent Signal Bar Is Up to Date")
        alert.informativeText = result.isUpdateAvailable
            ? text(
                "版本 \(result.latestVersion) 可用。当前版本：\(result.currentVersion)。",
                "Version \(result.latestVersion) is available. Current version: \(result.currentVersion)."
            )
            : text(
                "当前版本 \(result.currentVersion) 已经是最新版本。",
                "Current version \(result.currentVersion) is already the latest version."
            )

        if result.isUpdateAvailable {
            alert.addButton(withTitle: text("打开下载页面", "Open Download Page"))
            alert.addButton(withTitle: text("稍后", "Later"))
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(result.releasePageURL)
            }
        } else {
            alert.addButton(withTitle: text("好", "OK"))
            alert.runModal()
        }
    }

    private func showUpdateCheckFailureDialog(message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = text("检查更新失败", "Update Check Failed")
        alert.informativeText = message
        alert.addButton(withTitle: text("打开下载页面", "Open Download Page"))
        alert.addButton(withTitle: text("好", "OK"))

        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(GitHubReleaseUpdateChecker.fallbackReleasePageURL)
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
        let timingProfile = runtimeTimingProfile

        let pollTimer = Timer(timeInterval: timingProfile.statePollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.reloadFromWatcher()
            }
        }
        pollTimer.tolerance = timingProfile.statePollTolerance
        RunLoop.main.add(pollTimer, forMode: .common)
        self.pollTimer = pollTimer

        let animationTimer = Timer(timeInterval: timingProfile.animationTickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.advanceStatusLightSequenceIfNeeded() {
                    self.animationFrameSkipCounter = 0
                    return
                }
                guard self.shouldAnimateCurrentSignal else {
                    self.animationFrameSkipCounter = 0
                    self.animationClock.reset()
                    return
                }
                let cadence = self.animationTickCadenceForCurrentSignal
                self.animationFrameSkipCounter += 1
                guard self.animationFrameSkipCounter >= cadence.timerFramesPerAdvance else {
                    return
                }
                self.animationFrameSkipCounter = 0
                self.animationClock.advance(by: cadence.tickAdvance)
            }
        }
        animationTimer.tolerance = timingProfile.animationTickTolerance
        RunLoop.main.add(animationTimer, forMode: .common)
        self.animationTimer = animationTimer

        let codexDesktopTimer = Timer(timeInterval: timingProfile.agentPollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollCodexDesktopActivity()
            }
        }
        codexDesktopTimer.tolerance = timingProfile.agentPollTolerance
        RunLoop.main.add(codexDesktopTimer, forMode: .common)
        self.codexDesktopTimer = codexDesktopTimer

        let desktopAppTimer = Timer(
            timeInterval: timingProfile.desktopAppPresencePollInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.pollDesktopAppPresence()
            }
        }
        desktopAppTimer.tolerance = timingProfile.desktopAppPresencePollTolerance
        RunLoop.main.add(desktopAppTimer, forMode: .common)
        self.desktopAppTimer = desktopAppTimer

        let automaticUpdateCheckTimer = Timer(
            timeInterval: timingProfile.automaticUpdateCheckTimerInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.performAutomaticUpdateCheckIfNeeded()
            }
        }
        automaticUpdateCheckTimer.tolerance = timingProfile.automaticUpdateCheckTimerTolerance
        RunLoop.main.add(automaticUpdateCheckTimer, forMode: .common)
        self.automaticUpdateCheckTimer = automaticUpdateCheckTimer
    }

    private func restartTimers() {
        stopTimers()
        startTimers()
    }

    private func stopTimers() {
        pollTimer?.invalidate()
        animationTimer?.invalidate()
        codexDesktopTimer?.invalidate()
        desktopAppTimer?.invalidate()
        automaticUpdateCheckTimer?.invalidate()
        pollTimer = nil
        animationTimer = nil
        codexDesktopTimer = nil
        desktopAppTimer = nil
        automaticUpdateCheckTimer = nil
    }

    private func startMonitoringResumeLightSequence() {
        startStatusLightSequence(Self.monitoringResumeLightSequence)
    }

    private func startMonitoringPauseLightSequence() {
        startStatusLightSequence(Self.monitoringPauseLightSequence)
    }

    private func enqueueStateReload() {
        if isStateReloadInFlight {
            isStateReloadQueued = true
            return
        }

        isStateReloadInFlight = true
        let store = store

        stateReloadQueue.async { [weak self] in
            let latestSnapshot = store.readSnapshot()

            DispatchQueue.main.async { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.isStateReloadInFlight = false

                    if latestSnapshot != self.snapshot {
                        self.snapshot = latestSnapshot
                        self.updateLatestAgentQuota(from: latestSnapshot)
                    }

                    if self.isStateReloadQueued {
                        self.isStateReloadQueued = false
                        self.enqueueStateReload()
                    }
                }
            }
        }
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
            let previousTargets = statusLightOverride?.targets ?? Set(StatusLightOverrideTarget.allCases)
            statusLightSequence = []
            statusLightSequenceIndex = 0
            if isLightDebugModeEnabled {
                statusLightOverride = StatusLightOverrideFrame(
                    signal: .idle,
                    tick: 0,
                    allLightsOn: false,
                    effectCustomization: signalEffectCustomization,
                    targets: previousTargets,
                    usesLiveTick: true
                )
            } else {
                statusLightOverride = nil
            }
        }

        return true
    }

    private func statusLightOverride(for target: StatusLightOverrideTarget?) -> StatusLightOverrideFrame? {
        guard let target else { return statusLightOverride }
        guard let statusLightOverride, statusLightOverride.targets.contains(target) else {
            return nil
        }
        return statusLightOverride
    }

    private func lightSnapshot(for target: StatusLightOverrideTarget?) -> SignalSnapshot {
        let baseSnapshot = displaySnapshot
        if let override = statusLightOverride(for: target) {
            return snapshot(baseSnapshot, overridingAggregate: override.signal)
        }

        if isMonitoringPaused {
            return snapshot(baseSnapshot, overridingAggregate: .off)
        }

        return baseSnapshot
    }

    private func lightTick(for target: StatusLightOverrideTarget?) -> Int {
        guard let override = statusLightOverride(for: target) else {
            return animationClock.tick
        }
        return override.usesLiveTick ? animationClock.tick : override.tick
    }

    private func lightAllLightsOn(for target: StatusLightOverrideTarget?) -> Bool {
        if statusLightOverride(for: target) == nil, isMonitoringPaused {
            return true
        }

        return statusLightOverride(for: target)?.allLightsOn ?? false
    }

    private func lightUsesSystemGrayLights(for target: StatusLightOverrideTarget?) -> Bool {
        statusLightOverride(for: target)?.usesSystemGrayLights ?? isMonitoringPaused
    }

    private func lightEffectCustomization(for target: StatusLightOverrideTarget?) -> SignalEffectCustomization {
        statusLightOverride(for: target)?.effectCustomization ?? signalEffectCustomization
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
        case .needsReview, .permission, .blocked:
            return alertEffect(for: aggregate.displayState) != .steady
        case .stale:
            return true
        }
    }

    private var animationTickCadenceForCurrentSignal: AnimationTickCadence {
        if isNewZealandTrafficLightModeEnabled {
            return newZealandAnimationTickCadenceForCurrentSignal
        }

        guard isLowPowerModeEnabled else {
            return .everyFrame
        }

        return lowPowerAnimationTickCadenceForCurrentSignal
    }

    private var lowPowerAnimationTickCadenceForCurrentSignal: AnimationTickCadence {
        let aggregate = lightSnapshot.aggregate
        switch aggregate.displayState {
        case .active:
            let effect = aggregate == .thinking ? thinkingSignalEffect : activeSignalEffect
            switch effect {
            case .greenBreathing, .greenSlowFlash, .trafficCycle:
                return AnimationTickCadence(timerFramesPerAdvance: 1, tickAdvance: 2)
            case .greenFastFlash:
                return .everyFrame
            case .greenSteady:
                return .everyFrame
            }
        case .completed:
            switch completedSignalEffect {
            case .greenPulse, .yellowPulse, .allPulse:
                return AnimationTickCadence(timerFramesPerAdvance: 1, tickAdvance: 2)
            case .greenSteady, .yellowSteady, .allSteady:
                return .everyFrame
            }
        case .needsReview, .permission, .blocked:
            return lowPowerAnimationTickCadence(for: alertEffect(for: aggregate.displayState))
        case .stale:
            return AnimationTickCadence(timerFramesPerAdvance: 1, tickAdvance: 2)
        case .ready, .paused:
            return .everyFrame
        }
    }

    private var newZealandAnimationTickCadenceForCurrentSignal: AnimationTickCadence {
        let aggregate = lightSnapshot.aggregate
        switch aggregate.displayState {
        case .active:
            let effect = aggregate == .thinking ? thinkingSignalEffect : activeSignalEffect
            switch effect {
            case .greenSlowFlash:
                // New Zealand original mode: 0.9s on / 0.9s off, one green flash every 1.8s.
                return AnimationTickCadence(
                    timerFramesPerAdvance: isLowPowerModeEnabled ? 1 : 2,
                    tickAdvance: 3
                )
            case .trafficCycle:
                return AnimationTickCadence(
                    timerFramesPerAdvance: isLowPowerModeEnabled ? 2 : 4,
                    tickAdvance: 4
                )
            case .greenBreathing:
                return isLowPowerModeEnabled
                    ? AnimationTickCadence(timerFramesPerAdvance: 1, tickAdvance: 2)
                    : .everyFrame
            case .greenFastFlash:
                return .everyFrame
            case .greenSteady:
                return .everyFrame
            }
        case .completed:
            switch completedSignalEffect {
            case .greenPulse, .yellowPulse, .allPulse:
                return AnimationTickCadence(
                    timerFramesPerAdvance: isLowPowerModeEnabled ? 1 : 2,
                    tickAdvance: 2
                )
            case .greenSteady, .yellowSteady, .allSteady:
                return .everyFrame
            }
        case .needsReview, .permission, .blocked:
            return newZealandAnimationTickCadence(for: alertEffect(for: aggregate.displayState))
        case .ready, .stale, .paused:
            return isLowPowerModeEnabled
                ? lowPowerAnimationTickCadenceForCurrentSignal
                : .everyFrame
        }
    }

    private func alertEffect(for displayState: DisplayState) -> AlertSignalEffect {
        switch displayState {
        case .needsReview:
            return needsReviewSignalEffect
        case .permission:
            return permissionSignalEffect
        case .blocked:
            return blockedSignalEffect
        case .ready, .active, .completed, .stale, .paused:
            return .slowFlash
        }
    }

    private func lowPowerAnimationTickCadence(for effect: AlertSignalEffect) -> AnimationTickCadence {
        switch effect {
        case .pulse, .breathing, .slowFlash:
            return AnimationTickCadence(timerFramesPerAdvance: 1, tickAdvance: 2)
        case .fastFlash, .steady:
            return .everyFrame
        case .trafficCycle:
            return AnimationTickCadence(timerFramesPerAdvance: 2, tickAdvance: 4)
        }
    }

    private func newZealandAnimationTickCadence(for effect: AlertSignalEffect) -> AnimationTickCadence {
        switch effect {
        case .slowFlash:
            // Match the green slow-flash strategy so red/yellow slow flash keep the same cadence.
            return AnimationTickCadence(
                timerFramesPerAdvance: isLowPowerModeEnabled ? 1 : 2,
                tickAdvance: 3
            )
        case .breathing:
            return isLowPowerModeEnabled
                ? AnimationTickCadence(timerFramesPerAdvance: 1, tickAdvance: 2)
                : .everyFrame
        case .pulse:
            return isLowPowerModeEnabled
                ? AnimationTickCadence(timerFramesPerAdvance: 1, tickAdvance: 2)
                : .everyFrame
        case .trafficCycle:
            return AnimationTickCadence(
                timerFramesPerAdvance: isLowPowerModeEnabled ? 2 : 4,
                tickAdvance: 4
            )
        case .fastFlash, .steady:
            return .everyFrame
        }
    }

    private func pollCodexDesktopActivity() {
        guard isCodexDesktopMonitoringEnabled, !isMonitoringPaused else { return }
        pollCodexRateLimitsIfNeeded()
        guard !isCodexDesktopPollInFlight else { return }

        isCodexDesktopPollInFlight = true
        let monitor = codexDesktopActivityMonitor
        let store = store

        codexDesktopPollQueue.async { [weak self] in
            let pollResult = monitor.pollResult()
            var latestSnapshot: SignalSnapshot?
            var latestQuota: AgentQuotaStatus?
            var errorMessage: String?

            if !pollResult.quotaUpdates.isEmpty {
                do {
                    for quotaUpdate in pollResult.quotaUpdates {
                        if let currentLatestQuota = latestQuota {
                            if quotaUpdate.quota.updatedAt > currentLatestQuota.updatedAt {
                                latestQuota = quotaUpdate.quota
                            }
                        } else {
                            latestQuota = quotaUpdate.quota
                        }
                        latestSnapshot = try store.applySessionQuota(
                            quotaUpdate.quota,
                            sessionID: quotaUpdate.sessionID,
                            agent: quotaUpdate.agent,
                            updatedAt: quotaUpdate.quota.updatedAt
                        )
                    }
                } catch {
                    errorMessage = error.localizedDescription
                }
            }

            if !pollResult.activities.isEmpty {
                do {
                    for activity in pollResult.activities {
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
                    guard self.isCodexDesktopMonitoringEnabled, !self.isMonitoringPaused else { return }
                    if let latestQuota, self.shouldApplyLocalCodexQuotaUpdates {
                        self.updateLatestAgentQuota(latestQuota)
                        if let tokenUsage = latestQuota.tokenUsage {
                            self.updateLatestAgentTokenUsage(tokenUsage)
                            self.refreshTokenActivityIfNeeded()
                        }
                    }
                    if let latestSnapshot {
                        self.snapshot = latestSnapshot
                        self.updateLatestAgentQuota(from: latestSnapshot)
                    }
                    self.lastError = errorMessage
                }
            }
        }
    }

    func refreshTokenActivityIfNeeded(force: Bool = false) {
        guard isCodexDesktopMonitoringEnabled,
              !isMonitoringPaused
        else {
            return
        }

        let now = Date()
        if !force,
           let lastTokenActivityScanAt,
           now.timeIntervalSince(lastTokenActivityScanAt) < Self.tokenActivityRefreshInterval {
            return
        }
        guard !isTokenActivityScanInFlight else { return }

        isTokenActivityScanInFlight = true
        isTokenActivityLoading = true
        lastTokenActivityScanAt = now
        tokenActivityScanGeneration += 1
        let scanGeneration = tokenActivityScanGeneration
        let expectedAccountFingerprint = codexCurrentAccount?.authFingerprint
        let scanner = codexTokenActivityScannerForCurrentAccount()

        tokenActivityQueue.async { [weak self] in
            let cachedDays = scanner.cachedDailyActivity(now: now, days: 30)
            if let cachedDays {
                DispatchQueue.main.async { [weak self] in
                    Task { @MainActor in
                        guard let self,
                              self.isTokenActivityScanInFlight,
                              self.tokenActivityScanGeneration == scanGeneration,
                              self.codexCurrentAccount?.authFingerprint == expectedAccountFingerprint,
                              self.isCodexDesktopMonitoringEnabled,
                              !self.isMonitoringPaused
                        else {
                            return
                        }

                        self.tokenActivityDays = cachedDays
                        self.persistCodexUsageSnapshotForCurrentAccount()
                    }
                }

                if !force {
                    DispatchQueue.main.async { [weak self] in
                        Task { @MainActor in
                            guard let self else { return }
                            guard self.tokenActivityScanGeneration == scanGeneration,
                                  self.codexCurrentAccount?.authFingerprint == expectedAccountFingerprint
                            else {
                                return
                            }
                            self.isTokenActivityScanInFlight = false
                            self.isTokenActivityLoading = false
                            self.liveTokenUsageScanBaseline = self.latestAgentTokenUsage?.effectiveTotalTokens
                            self.lastObservedLiveTokenUsageTotal = self.latestAgentTokenUsage?.effectiveTotalTokens
                        }
                    }
                    return
                }
            }

            let days = scanner.scanDailyActivity(now: now, days: 30)

            DispatchQueue.main.async { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    guard self.tokenActivityScanGeneration == scanGeneration,
                          self.codexCurrentAccount?.authFingerprint == expectedAccountFingerprint
                    else {
                        return
                    }
                    self.isTokenActivityScanInFlight = false
                    self.isTokenActivityLoading = false
                    self.liveTokenUsageScanBaseline = self.latestAgentTokenUsage?.effectiveTotalTokens
                    guard self.isCodexDesktopMonitoringEnabled,
                          !self.isMonitoringPaused
                    else {
                        return
                    }

                    self.tokenActivityDays = days
                    self.persistCodexUsageSnapshotForCurrentAccount()
                }
            }
        }
    }

    func refreshCodexUsageForCurrentAccount(force: Bool = false) {
        pollCodexRateLimitsIfNeeded(force: force)
        refreshTokenActivityIfNeeded(force: force)
    }

    private func codexRateLimitFetchRoute() -> CodexRateLimitFetchRoute {
        let manualCookieHeader = codexOpenAICookieMode == .manual ? codexManualOpenAICookieHeader : nil
        let importsBrowserCookies = codexOpenAICookieMode == .automatic
        switch codexUsageDataSource.resolvedSelectableValue {
        case .automatic:
            return .automatic(cookieHeader: manualCookieHeader, importsBrowserCookies: importsBrowserCookies)
        case .oauthAPI:
            return .oauthAPI
        case .cliRPCPTY:
            return .automatic(cookieHeader: manualCookieHeader, importsBrowserCookies: importsBrowserCookies)
        }
    }

    func pollCodexRateLimitsIfNeeded(force: Bool = false) {
        guard isCodexDesktopMonitoringEnabled,
              !isMonitoringPaused
        else {
            return
        }

        let now = Date()
        if !force,
           let lastCodexRateLimitFetchAt,
           now.timeIntervalSince(lastCodexRateLimitFetchAt) < Self.codexRateLimitRefreshInterval {
            return
        }
        guard !isCodexRateLimitFetchInFlight else { return }

        isCodexRateLimitFetchInFlight = true
        lastCodexRateLimitFetchAt = now
        codexUsageRefreshGeneration += 1
        let refreshGeneration = codexUsageRefreshGeneration
        let expectedAccountFingerprint = codexCurrentAccount?.authFingerprint
        let fetchRoute = codexRateLimitFetchRoute()
        let fetcher = codexRateLimitFetcher
        let store = store

        Task(priority: .utility) { [fetcher, store, fetchRoute, weak self] in
            do {
                let usageStatus = try await fetcher.fetchUsageStatus(route: fetchRoute)
                let quota = usageStatus.quota
                guard let self else { return }
                guard self.codexUsageRefreshGeneration == refreshGeneration,
                      self.codexCurrentAccount?.authFingerprint == expectedAccountFingerprint
                else {
                    return
                }
                let snapshot = try store.applySessionQuota(
                    quota,
                    sessionID: "codex-rate-limits",
                    agent: "Codex",
                    updatedAt: quota.updatedAt
                )
                self.isCodexRateLimitFetchInFlight = false
                guard self.isCodexDesktopMonitoringEnabled,
                      !self.isMonitoringPaused
                else {
                    return
                }

                self.updateLatestAgentQuota(quota)
                self.latestCodexCredits = usageStatus.credits
                self.persistCodexUsageSnapshotForCurrentAccount()
                self.refreshCodexAccounts()
                self.persistCodexUsageSnapshotForCurrentAccount()
                self.snapshot = snapshot
            } catch {
                guard let self else { return }
                guard self.codexUsageRefreshGeneration == refreshGeneration else { return }
                self.isCodexRateLimitFetchInFlight = false
            }
        }
    }

    private func pollDesktopAppPresence() {
        guard shouldPollPlatformPresence else {
            if !desktopAppSessions.isEmpty {
                desktopAppSessions = []
            }
            return
        }

        guard !isPlatformPresencePollInFlight else { return }

        isPlatformPresencePollInFlight = true
        let monitor = codexPlatformPresenceMonitor

        platformPresencePollQueue.async { [weak self] in
            let detectedSessions = monitor.detectSessions()

            DispatchQueue.main.async { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.isPlatformPresencePollInFlight = false
                    guard self.shouldPollPlatformPresence else {
                        if !self.desktopAppSessions.isEmpty {
                            self.desktopAppSessions = []
                        }
                        return
                    }
                    let latestSessions = self.filteredPlatformPresenceSessions(detectedSessions)
                    if latestSessions != self.desktopAppSessions {
                        self.desktopAppSessions = latestSessions
                    }
                }
            }
        }
    }

    private var shouldPollPlatformPresence: Bool {
        !isMonitoringPaused
            && (isCodexDesktopMonitoringEnabled || isClaudeDesktopMonitoringEnabled)
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
        let resolvingCutoffsBySourceKey = Self.latestResolvingCutoffsBySourceKey(visibleRecentEvents)
        var sessions = snapshot.sessions.filter { session in
            Self.shouldIncludeStoredSessionInDisplay(session, now: now)
                && !Self.isSupersededByCompletedRecentEvent(
                    session,
                    completionCutoffsBySourceKey: completionCutoffsBySourceKey
                )
                && !Self.isSupersededByResolvingRecentEvent(
                    session,
                    resolvingCutoffsBySourceKey: resolvingCutoffsBySourceKey
                )
        }
        sessions.append(
            contentsOf: recentActivityFallbackSessions(
                from: visibleRecentEvents,
                existingSessions: sessions,
                completionCutoffsBySourceKey: completionCutoffsBySourceKey,
                resolvingCutoffsBySourceKey: resolvingCutoffsBySourceKey,
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
        resolvingCutoffsBySourceKey: [String: Date],
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
               existingSession.updatedAt >= event.updatedAt,
               !Self.isPresenceSession(existingSession) {
                continue
            }

            if Self.isSupersededByCompletedRecentEvent(
                event,
                completionCutoffsBySourceKey: completionCutoffsBySourceKey
            ) {
                continue
            }

            if Self.isSupersededByResolvingRecentEvent(
                event,
                resolvingCutoffsBySourceKey: resolvingCutoffsBySourceKey
            ) {
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

        if shouldResolvingDisplaySessionOverride(candidate, current: current) {
            return true
        }
        if shouldResolvingDisplaySessionOverride(current, current: candidate) {
            return false
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

    private static func shouldResolvingDisplaySessionOverride(
        _ candidate: SessionStatus,
        current: SessionStatus
    ) -> Bool {
        isResolvingSignal(candidate.signal)
            && shouldResolvingEventSupersedeSessionDisplayState(current.signal.displayState)
            && candidate.updatedAt >= current.updatedAt
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
        if isManualIdleControlEvent(event) {
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

    nonisolated static func isManualIdleControlEvent(_ event: RecentSignalEvent) -> Bool {
        event.sessionID == "manual"
            && (event.agent ?? "manual") == "manual"
            && event.signal.displayState == .ready
    }

    private static func isPassiveActiveEvent(_ event: RecentSignalEvent) -> Bool {
        guard event.signal.displayState == .active else { return false }

        switch event.event {
        case "DesktopActivityHeartbeat", "DesktopThinking", "DesktopMessage":
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

    private static func latestResolvingCutoffsBySourceKey(_ events: [RecentSignalEvent]) -> [String: Date] {
        var cutoffs: [String: Date] = [:]

        for event in events where isResolvingSignal(event.signal) {
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
              shouldCompletedEventSupersedeDisplayState(session.signal.displayState)
        else {
            return false
        }

        let sourceKey = ActivityPresentation.activitySourceKey(for: session)
        guard let completedAt = completionCutoffsBySourceKey[sourceKey] else {
            return false
        }

        return completedAt >= session.updatedAt
    }

    private static func isSupersededByCompletedRecentEvent(
        _ event: RecentSignalEvent,
        completionCutoffsBySourceKey: [String: Date]
    ) -> Bool {
        guard event.signal.displayState == .active else {
            return false
        }

        let sourceKey = ActivityPresentation.activitySourceKey(for: event)
        guard let completedAt = completionCutoffsBySourceKey[sourceKey] else {
            return false
        }

        return completedAt >= event.updatedAt
    }

    private static func isSupersededByResolvingRecentEvent(
        _ session: SessionStatus,
        resolvingCutoffsBySourceKey: [String: Date]
    ) -> Bool {
        guard !isPresenceSession(session),
              shouldResolvingEventSupersedeSessionDisplayState(session.signal.displayState)
        else {
            return false
        }

        let sourceKey = ActivityPresentation.activitySourceKey(for: session)
        guard let resolvedAt = resolvingCutoffsBySourceKey[sourceKey] else {
            return false
        }

        return resolvedAt >= session.updatedAt
    }

    private static func isSupersededByResolvingRecentEvent(
        _ event: RecentSignalEvent,
        resolvingCutoffsBySourceKey: [String: Date]
    ) -> Bool {
        guard shouldResolvingEventSupersedeDisplayState(event.signal.displayState) else {
            return false
        }

        let sourceKey = ActivityPresentation.activitySourceKey(for: event)
        guard let resolvedAt = resolvingCutoffsBySourceKey[sourceKey] else {
            return false
        }

        return resolvedAt > event.updatedAt
    }

    private static func shouldResolvingEventSupersedeDisplayState(_ displayState: DisplayState) -> Bool {
        switch displayState {
        case .needsReview, .permission:
            return true
        case .ready, .active, .completed, .blocked, .stale, .paused:
            return false
        }
    }

    private static func shouldResolvingEventSupersedeSessionDisplayState(_ displayState: DisplayState) -> Bool {
        switch displayState {
        case .needsReview, .permission:
            return true
        case .ready, .active, .completed, .blocked, .stale, .paused:
            return false
        }
    }

    private static func shouldCompletedEventSupersedeDisplayState(_ displayState: DisplayState) -> Bool {
        switch displayState {
        case .active, .needsReview, .permission:
            return true
        case .ready, .completed, .blocked, .stale, .paused:
            return false
        }
    }

    private static func isResolvingDisplayState(_ displayState: DisplayState) -> Bool {
        switch displayState {
        case .active, .completed:
            return true
        case .ready, .needsReview, .permission, .blocked, .stale, .paused:
            return false
        }
    }

    private static func isResolvingSignal(_ signal: AgentSignal) -> Bool {
        switch signal {
        case .thinking, .working, .toolDone, .subagentStart, .subagentStop, .done:
            return true
        case .idle, .attention, .notification, .permission,
             .permissionRequest, .blocked, .failure, .error, .exception, .maxTokens,
             .stale, .sessionStart, .sessionEnd, .turnEnd, .off, .pause, .paused:
            return false
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
            SignalLightAgentScope.visibleCases.filter { scope in
                visibleSessions.contains { scope.matches(session: $0) }
            }
        )
    }

    var displaySignalLightAgentScopes: Set<SignalLightAgentScope> {
        signalLightAgentScopesForDisplay(from: combinedDisplaySessions())
    }

    var signalLightAgentMenuTitle: String {
        displayName(for: displaySignalLightAgentScopes)
    }

    var signalLightAgentUnavailableHint: String? {
        guard signalLightAgentSelectionMode == .manual else { return nil }
        let selectedVisibleScopes = signalLightAgentScopes.intersection(Set(SignalLightAgentScope.visibleCases))
        guard !selectedVisibleScopes.isEmpty else { return nil }

        let visibleSessions = ActivityPresentation.visibleSessions(from: activitySnapshot, limit: nil)
        let selectedHasVisibleSession = visibleSessions.contains { session in
            Self.session(session, matches: selectedVisibleScopes)
        }
        guard !selectedHasVisibleSession else { return nil }

        let otherVisibleScopes = Set(
            SignalLightAgentScope.visibleCases.filter { scope in
                !selectedVisibleScopes.contains(scope)
                    && visibleSessions.contains { scope.matches(session: $0) }
            }
        )
        guard !otherVisibleScopes.isEmpty else { return nil }

        return text(
            "已选 Agent 尚未运行。其他 Agent 正在运行，可在灯效 Agent 中切换。",
            "The selected agent is not running. Other agents are running; switch in Light Agent if needed."
        )
    }

    private static func resolvedFloatingSignalScale(
        storedRawValue: String?,
        storedDefaultsVersion: Int
    ) -> FloatingSignalScale {
        let storedScale = storedRawValue.flatMap(FloatingSignalScale.init(rawValue:))
        guard storedDefaultsVersion >= floatingSignalScaleDefaultsVersion else {
            switch storedScale {
            case .compact?:
                return .standard
            case .standard?, .large?:
                return .large
            case nil:
                return .standard
            }
        }

        return storedScale ?? .standard
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

    private static func resolvedSignalLightAgentSelectionMode(
        storedMode: String?,
        storedScopes: [String]?,
        legacyScope: String?
    ) -> SignalLightAgentSelectionMode {
        if let storedMode,
           let mode = SignalLightAgentSelectionMode(rawValue: storedMode) {
            return mode
        }

        if storedScopes != nil || legacyScope != nil {
            return .manual
        }

        return .following
    }

    private func signalLightAgentScopesForDisplay(from displaySessions: [SessionStatus]) -> Set<SignalLightAgentScope> {
        switch signalLightAgentSelectionMode {
        case .manual:
            return signalLightAgentScopes.intersection(Set(SignalLightAgentScope.visibleCases))
        case .following:
            guard let scope = followedSignalLightAgentScope(in: displaySessions) else {
                return []
            }
            return [scope]
        }
    }

    private func followedSignalLightAgentScope(in displaySessions: [SessionStatus]) -> SignalLightAgentScope? {
        struct Candidate {
            let scope: SignalLightAgentScope
            let priority: Int
            let updatedAt: Date
        }

        let candidates = SignalLightAgentScope.visibleCases.compactMap { scope -> Candidate? in
            let matchingSessions = displaySessions.filter {
                scope.matches(session: $0) && Self.isFollowCandidateSession($0)
            }

            guard let bestSession = matchingSessions.max(by: { lhs, rhs in
                if lhs.signal.displayState.priority != rhs.signal.displayState.priority {
                    return lhs.signal.displayState.priority < rhs.signal.displayState.priority
                }
                return lhs.updatedAt < rhs.updatedAt
            }) else {
                return nil
            }

            return Candidate(
                scope: scope,
                priority: bestSession.signal.displayState.priority,
                updatedAt: bestSession.updatedAt
            )
        }

        return candidates.max { lhs, rhs in
            if lhs.priority != rhs.priority {
                return lhs.priority < rhs.priority
            }
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt < rhs.updatedAt
            }
            return lhs.scope.sortOrder > rhs.scope.sortOrder
        }?.scope
    }

    private static func isFollowCandidateSession(_ session: SessionStatus) -> Bool {
        if isSignalTestEvent(session.lastEvent) {
            return false
        }

        switch session.signal.displayState {
        case .paused:
            return false
        case .ready, .active, .completed, .needsReview, .permission, .blocked, .stale:
            return true
        }
    }

    private func aggregateForSignalLightScopes(
        sessions: [SessionStatus],
        fallback: AgentSignal,
        scopes: Set<SignalLightAgentScope>
    ) -> AgentSignal {
        let selectedSignals = sessions.compactMap { session -> AgentSignal? in
            guard Self.session(session, matches: scopes) else { return nil }
            return session.signal
        }

        if let aggregate = selectedSignals
            .max(by: { lhs, rhs in lhs.displayState.priority < rhs.displayState.priority })?
            .normalizedAggregateSignal {
            return aggregate
        }

        return fallbackForEmptySignalLightSessions(fallback, scopes: scopes)
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
        case .paused, .blocked:
            return fallback.normalizedAggregateSignal
        case .ready, .active, .completed, .needsReview, .permission, .stale:
            return .idle
        }
    }

    private func fallbackForEmptySignalLightSessions(
        _ fallback: AgentSignal,
        scopes: Set<SignalLightAgentScope>
    ) -> AgentSignal {
        if signalLightAgentSelectionMode == .manual, !scopes.isEmpty {
            switch fallback.displayState {
            case .paused:
                return fallback.normalizedAggregateSignal
            case .ready, .active, .completed, .needsReview, .permission, .blocked, .stale:
                return .idle
            }
        }

        return fallbackForEmptyDisplaySessions(fallback)
    }

    private func sessionMatchesSignalLightScopes(_ session: SessionStatus) -> Bool {
        Self.session(session, matches: signalLightAgentScopes)
    }

    private func recentEventMatchesSignalLightScopes(_ event: RecentSignalEvent) -> Bool {
        Self.event(event, matches: signalLightAgentScopes)
    }

    private static func session(_ session: SessionStatus, matches scopes: Set<SignalLightAgentScope>) -> Bool {
        scopes.contains { $0.matches(session: session) }
    }

    private static func event(_ event: RecentSignalEvent, matches scopes: Set<SignalLightAgentScope>) -> Bool {
        scopes.contains { $0.matches(event: event) }
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

    private func updateLatestAgentQuota(from snapshot: SignalSnapshot) {
        if shouldApplyLocalCodexQuotaUpdates,
           let quota = Self.latestQuota(in: snapshot),
           Self.latestQuota(quota, isNewerThan: latestAgentQuota) {
            updateLatestAgentQuota(quota)
        }

        if let tokenUsage = Self.latestTokenUsage(in: snapshot) ?? latestAgentQuota?.tokenUsage {
            updateLatestAgentTokenUsage(tokenUsage)
        }
    }

    private func updateLatestAgentQuota(_ quota: AgentQuotaStatus) {
        latestAgentQuota = quota
        Self.cacheLatestAgentQuota(quota)
        persistCodexUsageSnapshotForCurrentAccount()
    }

    private var shouldApplyLocalCodexQuotaUpdates: Bool {
        codexUsageDataSource == .cliRPCPTY
    }

    private func clearLatestAgentQuotaCache() {
        latestAgentQuota = nil
        latestCodexCredits = nil
        UserDefaults.standard.removeObject(forKey: Self.cachedLatestAgentQuotaKey)
    }

    private func clearLatestAgentTokenUsageCache() {
        latestAgentTokenUsage = nil
        liveTokenUsageScanBaseline = nil
        lastObservedLiveTokenUsageTotal = nil
        UserDefaults.standard.removeObject(forKey: Self.cachedLatestAgentTokenUsageKey)
    }

    private func clearTokenActivityCache() {
        tokenActivityDays = []
        lastTokenActivityScanAt = nil
        isTokenActivityLoading = false
    }

    private func ensureDebugLogFileExists() {
        let directory = debugLogFileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: debugLogFileURL.path) {
            let header = "Agent Signal Bar debug log\n"
            try? header.write(to: debugLogFileURL, atomically: true, encoding: .utf8)
        }
    }

    private func appendDebugLog(_ message: String) {
        guard isDebugFileLoggingEnabled else { return }
        ensureDebugLogFileExists()
        let line = "[\(Date().formatted(date: .numeric, time: .standard))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: debugLogFileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            _ = try? handle.write(contentsOf: data)
        }
    }

    private func quotaDebugLine(_ quota: AgentQuotaStatus) -> String {
        let reset = quota.resetsAt?.formatted(date: .numeric, time: .shortened) ?? "--"
        return "quota window=\(quota.windowMinutes.map(String.init) ?? "--")m remaining=\(Int(quota.remainingPercent.rounded()))% resets=\(reset)"
    }

    private func prepareCodexUsageAfterAccountChange() {
        codexUsageRefreshGeneration += 1
        tokenActivityScanGeneration += 1
        isCodexRateLimitFetchInFlight = false
        isTokenActivityScanInFlight = false
        clearLatestAgentQuotaCache()
        clearLatestAgentTokenUsageCache()
        clearTokenActivityCache()
        lastCodexRateLimitFetchAt = nil
        hydrateCodexUsageSnapshotForCurrentAccount()
    }

    private func codexTokenActivityScannerForCurrentAccount() -> CodexTokenActivityScanner {
        codexTokenActivityScanner
    }

    private func hydrateCodexUsageSnapshotForCurrentAccount() {
        guard let account = codexCurrentAccount,
              let snapshot = codexUsageSnapshotStore.snapshot(for: account)
        else {
            return
        }

        latestAgentQuota = snapshot.quota
        latestCodexCredits = snapshot.credits
        if snapshot.tokenActivityCacheVersion == CodexTokenActivityScanner.currentCacheVersion {
            latestAgentTokenUsage = snapshot.tokenUsage ?? snapshot.quota?.tokenUsage
            tokenActivityDays = snapshot.tokenActivityDays
        } else {
            latestAgentTokenUsage = nil
            tokenActivityDays = []
        }
        liveTokenUsageScanBaseline = latestAgentTokenUsage?.effectiveTotalTokens
        lastObservedLiveTokenUsageTotal = latestAgentTokenUsage?.effectiveTotalTokens
        if let quota = snapshot.quota {
            Self.cacheLatestAgentQuota(quota)
        }
        if let tokenUsage = latestAgentTokenUsage {
            Self.cacheLatestAgentTokenUsage(tokenUsage)
        }
    }

    private func persistCodexUsageSnapshotForCurrentAccount() {
        guard let account = codexCurrentAccount else { return }
        codexUsageSnapshotStore.store(
            account: account,
            quota: latestAgentQuota,
            credits: latestCodexCredits,
            tokenUsage: latestAgentTokenUsage,
            tokenActivityCacheVersion: CodexTokenActivityScanner.currentCacheVersion,
            tokenActivityDays: tokenActivityDays
        )
    }

    private func applyCodexAccountState(_ state: CodexAccountState) {
        codexCurrentAccount = state.currentAccount
        codexSavedAccounts = state.savedAccounts
        codexActiveSavedAccountID = state.activeSavedAccountID
    }

    private func updateLatestAgentTokenUsage(_ usage: AgentTokenUsage) {
        if let total = usage.effectiveTotalTokens {
            if let previous = lastObservedLiveTokenUsageTotal,
               total < previous {
                liveTokenUsageScanBaseline = 0
            }
            lastObservedLiveTokenUsageTotal = total
        }
        latestAgentTokenUsage = usage
        Self.cacheLatestAgentTokenUsage(usage)
        persistCodexUsageSnapshotForCurrentAccount()
    }

    private static func latestQuota(_ quota: AgentQuotaStatus?, isNewerThan other: AgentQuotaStatus?) -> Bool {
        guard let quota else {
            return false
        }
        guard let other else {
            return true
        }
        return quota.updatedAt >= other.updatedAt
    }

    private static func cachedLatestAgentQuota() -> AgentQuotaStatus? {
        cachedValue(forKey: cachedLatestAgentQuotaKey, as: AgentQuotaStatus.self)
    }

    private static func cacheLatestAgentQuota(_ quota: AgentQuotaStatus) {
        cacheValue(quota, forKey: cachedLatestAgentQuotaKey)
    }

    private static func cachedLatestAgentTokenUsage() -> AgentTokenUsage? {
        cachedValue(forKey: cachedLatestAgentTokenUsageKey, as: AgentTokenUsage.self)
    }

    private static func cacheLatestAgentTokenUsage(_ usage: AgentTokenUsage) {
        cacheValue(usage, forKey: cachedLatestAgentTokenUsageKey)
    }

    private static func loadManualOpenAICookieHeader(
        secretStore: KeychainSecretStore,
        allowsUserInteraction: Bool = true
    ) -> String {
        let storedValue = allowsUserInteraction
            ? try? secretStore.string(for: manualOpenAICookieKey)
            : try? secretStore.nonInteractiveString(for: manualOpenAICookieKey)
        if let value = storedValue,
           !value.isEmpty {
            UserDefaults.standard.removeObject(forKey: legacyManualOpenAICookieUserDefaultsKey)
            return value
        }

        guard let legacyValue = UserDefaults.standard.string(forKey: legacyManualOpenAICookieUserDefaultsKey),
              !legacyValue.isEmpty
        else {
            UserDefaults.standard.removeObject(forKey: legacyManualOpenAICookieUserDefaultsKey)
            return ""
        }

        guard allowsUserInteraction else {
            return legacyValue
        }

        do {
            try secretStore.set(legacyValue, for: manualOpenAICookieKey)
            UserDefaults.standard.removeObject(forKey: legacyManualOpenAICookieUserDefaultsKey)
        } catch {
            return legacyValue
        }
        return legacyValue
    }

    private static func cachedValue<T: Decodable>(forKey key: String, as type: T.Type) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else {
            return nil
        }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func cacheValue<T: Encodable>(_ value: T, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else {
            return
        }
        UserDefaults.standard.set(data, forKey: key)
    }

    private static func latestQuota(in snapshot: SignalSnapshot) -> AgentQuotaStatus? {
        snapshot.sessions
            .compactMap(\.quota)
            .max { lhs, rhs in lhs.updatedAt < rhs.updatedAt }
    }

    private static func latestTokenUsage(in snapshot: SignalSnapshot) -> AgentTokenUsage? {
        snapshot.sessions
            .compactMap(\.quota)
            .filter { $0.tokenUsage != nil }
            .max { lhs, rhs in lhs.updatedAt < rhs.updatedAt }?
            .tokenUsage
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
        case .needsReview, .permission:
            return now.timeIntervalSince(session.updatedAt) <= transientAlertDisplayWindow
        case .blocked, .stale:
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
        case "DesktopActivityHeartbeat", "DesktopThinking", "DesktopMessage":
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

    private func bundledCLIURL() -> URL? {
        var candidates: [URL] = []
        let cliNames = ["agent-signal-light", "agent-signal"]

        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(contentsOf: cliNames.map { resourceURL.appendingPathComponent("dist/bin/\($0)") })
        }

        let bundleURL = Bundle.main.bundleURL.standardizedFileURL
        let distParent = bundleURL.deletingLastPathComponent()
        if distParent.lastPathComponent == "dist" {
            candidates.append(contentsOf: cliNames.map {
                distParent
                    .deletingLastPathComponent()
                    .appendingPathComponent("dist/bin/\($0)")
            })
        }

        candidates.append(contentsOf: cliNames.map {
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("dist/bin/\($0)")
        })

        let developmentBuildRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build")
        if let enumerator = FileManager.default.enumerator(
            at: developmentBuildRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) {
            for case let candidate as URL in enumerator where cliNames.contains(candidate.lastPathComponent) {
                candidates.append(candidate)
            }
        }

        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private func preferredCLIInstallDirectory() -> URL {
        let homebrewBin = URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true)
        if FileManager.default.fileExists(atPath: homebrewBin.path) {
            return homebrewBin
        }

        return URL(fileURLWithPath: "/usr/local/bin", isDirectory: true)
    }

    nonisolated private static func installCLI(sourcePath: String, destinationPath: String) throws {
        let destinationDirectory = URL(fileURLWithPath: destinationPath).deletingLastPathComponent()
        let fileManager = FileManager.default

        if fileManager.isWritableFile(atPath: destinationDirectory.path) {
            try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: destinationPath) {
                try fileManager.removeItem(atPath: destinationPath)
            }
            try fileManager.copyItem(atPath: sourcePath, toPath: destinationPath)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destinationPath)
            return
        }

        let command = """
        mkdir -p \(Self.shellQuoted(destinationDirectory.path)) && \
        rm -f \(Self.shellQuoted(destinationPath)) && \
        cp \(Self.shellQuoted(sourcePath)) \(Self.shellQuoted(destinationPath)) && \
        chmod 755 \(Self.shellQuoted(destinationPath))
        """
        let script = "do shell script \(Self.appleScriptQuoted(command)) with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw CLIInstallError(message: message?.isEmpty == false ? message! : "administrator authorization was cancelled or failed")
        }
    }

    nonisolated private static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    nonisolated private static func appleScriptQuoted(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
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

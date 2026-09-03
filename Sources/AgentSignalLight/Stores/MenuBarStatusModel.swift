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

enum TokenActivityScanDisposition: Equatable {
    case applied
    case retryingAfterUnabsorbedUsage
    case deferredWithRetryPending
    case discardedStaleContext
    case discardedInactive
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
    @Published private(set) var latestLocalAgentQuotaObservation: AgentQuotaStatus? = nil
    @Published private(set) var latestCodexCredits: CodexCreditStatus?
    @Published private(set) var latestCodexResetCredits: CodexRateLimitResetCreditsSnapshot?
    @Published private(set) var codexUsageFetchState: CodexUsageFetchState?
    @Published private(set) var codexResetCreditsFetchState: CodexResetCreditsFetchState?
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
    @Published private(set) var tokenUsageReconciliationRevision = 0
    @Published private(set) var isTokenActivityLoading = false
    @Published private(set) var tokenActivityIssue: String?
    @Published private(set) var tokenActivityIsPartial = false
    @Published private(set) var hasCompletedTokenActivityScan = false
    @Published private(set) var isCodexRateLimitFetchInFlight = false
    @Published private(set) var codexCurrentAccount: CodexCurrentAccount?
    @Published private(set) var codexSavedAccounts: [CodexAccountProfile] = []
    @Published private(set) var codexActiveSavedAccountID: UUID?
    @Published private(set) var isCodexAccountActionRunning = false
    @Published var codexAccountMessage: String?
    @Published private(set) var isCodexAccountMessageError = false
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
    private let userDefaults: UserDefaults
    private let launchAtLoginManager: LaunchAtLoginManager
    private let hookInstallManager: HookInstallManager
    private let diagnosticsExportManager: DiagnosticsExportManager
    private let codexDesktopActivityMonitor: CodexDesktopActivityMonitor
    private let codexAccountManager: any CodexAccountManaging
    private let codexUsageSnapshotStore: CodexAccountUsageSnapshotStore
    private let codexCLIStatusProbe: any CodexCLIStatusProbing
    private let codexRPCStatusProbe: any CodexRPCStatusProbing
    private let codexServiceStatusFetcher: any CodexServiceStatusFetching
    private let codexRateLimitFetcher: CodexRateLimitFetcher
    private let codexTokenActivityScanner: any CodexTokenActivityScanning
    private let tokenActivityScanObserver: ((TokenActivityScanDisposition) -> Void)?
    private let performsAccountSwitchBackgroundRefreshes: Bool
    private let nowProvider: @Sendable () -> Date
    private let codexPlatformPresenceMonitor: CodexPlatformPresenceMonitor
    private let openAICookieStore: KeychainSecretStore
    private let updateChecker: GitHubReleaseUpdateChecker
    private let stateReloadQueue = DispatchQueue(label: "com.agentsignallight.state-reload")
    private let codexDesktopPollQueue: DispatchQueue
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
    private var activeCodexUsageRefreshGeneration: Int?
    private var codexUsageRefreshPending = false
    private var codexUsageRefreshTask: Task<Void, Never>?
    private var codexProviderDetailsRefreshGeneration = 0
    private var codexLiveObservationGeneration = 0
    private var codexDevicePollGeneration = 0
    private var codexAccountObservationStartedAt: Date?
    private var codexDeviceObservationStartedAt: Date?
    private var latestLocalAgentQuotaObservationCursor: CodexTokenObservationCursor?
    private var tokenActivityScanGeneration = 0
    private var tokenActivityScanRetryPending = false
    private var tokenActivityScanRetryAttempt = 0
    private var isPlatformPresencePollInFlight = false
    private var isAutomaticUpdateCheckInFlight = false
    private var lastNotifiedUpdateVersion: String?
    private var lastCodexRateLimitFetchAt: Date?
    private var lastTokenActivityScanAt: Date?
    private var tokenActivityExcludedSessionCount: Int?
    private var liveTokenCounters: [String: LiveTokenCounterState] = [:]
    private var unscannedLiveTokenCarries: [String: LiveTokenCarryState] = [:]
    private var liveTokenUsageScanCutoff: Date?
    private var liveTokenScanWatermarks: [CodexTokenActivityScanWatermark] = []
    private var recentExactLiveTokenObservationSignatures:
        [String: [ExactLiveTokenObservationSignature]] = [:]
    private var legacyUnscopedTokenFloor: LegacyUnscopedTokenFloor?
    private var latestAgentTokenUsageSessionID: String?
    private var latestAgentTokenUsageUpdatedAt: Date?
    private var liveTokenUsageRevision = 0

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
    private static let tokenActivityRetryBaseInterval: TimeInterval = 5
    private static let unknownLiveTokenSessionKey = "__unknown__"
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

    private struct CodexUsageAccountIdentity: Equatable, Sendable {
        let usageSnapshotKey: String
        let authFingerprint: String
    }

    private struct LiveTokenCounterState: Equatable, Sendable {
        let sessionID: String?
        var totalTokens: Int
        var scannedBaseline: Int
        var day: Date
        var updatedAt: Date?
        var observationCursor: CodexTokenObservationCursor? = nil
    }

    private struct LiveTokenCarryState: Equatable, Sendable {
        let sessionID: String?
        let totalTokens: Int
        let day: Date
        let updatedAt: Date?
        let observationCursor: CodexTokenObservationCursor?
    }

    private struct ExactLiveTokenObservationSignature: Equatable, Sendable {
        let usage: AgentTokenUsage
        let stateFileTimestampSecond: Int64
    }

    private enum TokenObservationDisposition {
        case unmatched
        case covered
        case rejected
    }

    private enum SourceSnapshotRelation: Equatable {
        case same
        case lhsNewer
        case lhsOlder
        case legacy
        case incomparable
    }

    private struct LegacyUnscopedTokenFloor: Equatable, Sendable {
        let totalTokens: Int
        let day: Date
    }

    private struct LiveTokenUsageObservation: Equatable, Sendable {
        let usage: AgentTokenUsage
        let sessionID: String?
        let updatedAt: Date?
    }

    private struct AnimationTickCadence {
        let timerFramesPerAdvance: Int
        let tickAdvance: Int

        static let everyFrame = AnimationTickCadence(timerFramesPerAdvance: 1, tickAdvance: 1)
    }

    init(
        store: SignalStateStore = SignalStateStore(),
        userDefaults: UserDefaults = .standard,
        startsMonitoring: Bool = true,
        launchAtLoginManager: LaunchAtLoginManager = LaunchAtLoginManager(),
        hookInstallManager: HookInstallManager = HookInstallManager(),
        diagnosticsExportManager: DiagnosticsExportManager = DiagnosticsExportManager(),
        codexDesktopActivityMonitor: CodexDesktopActivityMonitor = CodexDesktopActivityMonitor(replaysInitialHistory: true),
        codexDesktopPollQueue: DispatchQueue = DispatchQueue(
            label: "com.agentsignallight.codex-desktop-poll"
        ),
        codexAccountManager: any CodexAccountManaging = CodexAccountManager(),
        codexUsageSnapshotStore: CodexAccountUsageSnapshotStore = CodexAccountUsageSnapshotStore(),
        codexCLIStatusProbe: any CodexCLIStatusProbing = CodexCLIStatusProbe(),
        codexRPCStatusProbe: any CodexRPCStatusProbing = CodexRPCStatusProbe(),
        codexServiceStatusFetcher: any CodexServiceStatusFetching = CodexServiceStatusFetcher(),
        codexRateLimitFetcher: CodexRateLimitFetcher? = nil,
        codexTokenActivityScanner: any CodexTokenActivityScanning = CodexTokenActivityScanner(),
        tokenActivityScanObserver: ((TokenActivityScanDisposition) -> Void)? = nil,
        performsAccountSwitchBackgroundRefreshes: Bool = true,
        nowProvider: @escaping @Sendable () -> Date = { Date() },
        codexPlatformPresenceMonitor: CodexPlatformPresenceMonitor = CodexPlatformPresenceMonitor(),
        updateChecker: GitHubReleaseUpdateChecker = GitHubReleaseUpdateChecker()
    ) {
        self.store = store
        self.userDefaults = userDefaults
        self.launchAtLoginManager = launchAtLoginManager
        self.hookInstallManager = hookInstallManager
        self.diagnosticsExportManager = diagnosticsExportManager
        self.codexDesktopActivityMonitor = codexDesktopActivityMonitor
        self.codexDesktopPollQueue = codexDesktopPollQueue
        self.codexAccountManager = codexAccountManager
        self.codexUsageSnapshotStore = codexUsageSnapshotStore
        self.codexCLIStatusProbe = codexCLIStatusProbe
        self.codexRPCStatusProbe = codexRPCStatusProbe
        self.codexServiceStatusFetcher = codexServiceStatusFetcher
        self.codexRateLimitFetcher = codexRateLimitFetcher ?? CodexRateLimitFetcher(
            credentialPersistence: codexAccountManager as? any CodexRefreshedCredentialPersisting
        )
        self.codexTokenActivityScanner = codexTokenActivityScanner
        self.tokenActivityScanObserver = tokenActivityScanObserver
        self.performsAccountSwitchBackgroundRefreshes = performsAccountSwitchBackgroundRefreshes
        self.nowProvider = nowProvider
        self.codexPlatformPresenceMonitor = codexPlatformPresenceMonitor
        let openAICookieStore = KeychainSecretStore(service: "com.agentsignallight.openai-cookie")
        self.openAICookieStore = openAICookieStore
        self.updateChecker = updateChecker
        self.codexDeviceObservationStartedAt = nowProvider()
        let storedLayout = userDefaults.string(forKey: "trafficSignalLayout")
        let storedStyle = userDefaults.string(forKey: "trafficSignalStyle")
        let storedMacOSStrength = userDefaults.string(forKey: "macOSBreathingStrength")
        let storedThinkingSignalEffect = userDefaults.string(forKey: "thinkingSignalEffect")
        let storedActiveSignalEffect = userDefaults.string(forKey: "activeSignalEffect")
        let storedActiveEffectSpeed = userDefaults.string(forKey: "activeEffectSpeed")
        let storedAlertEffectSpeed = userDefaults.string(forKey: "alertEffectSpeed")
        let storedCompletedSignalEffect = userDefaults.string(forKey: "completedSignalEffect")
        let storedNeedsReviewSignalEffect = userDefaults.string(forKey: "needsReviewSignalEffect")
        let storedPermissionSignalEffect = userDefaults.string(forKey: "permissionSignalEffect")
        let storedBlockedSignalEffect = userDefaults.string(forKey: "blockedSignalEffect")
        let storedLanguage = userDefaults.string(forKey: "appLanguage")
        let storedTheme = userDefaults.string(forKey: "appTheme")
        let storedSettingsGlassEnabled = userDefaults.object(forKey: "isSettingsGlassEnabled") as? Bool
        let storedDebugSettingsVisible =
            userDefaults.object(forKey: "isDebugSettingsVisible") as? Bool
        let storedDebugFileLoggingEnabled =
            userDefaults.object(forKey: "isDebugFileLoggingEnabled") as? Bool
        let storedDebugLogLevel = userDefaults.string(forKey: "debugLogLevel")
        let storedSettingsGlassEffect =
            userDefaults.string(forKey: "settingsGlassEffect")
            ?? userDefaults.string(forKey: "settingsMenuGlassEffect")
        let storedLowPowerModeEnabled =
            userDefaults.object(forKey: "isLowPowerModeEnabled") as? Bool
        let storedNewZealandTrafficLightModeEnabled =
            userDefaults.object(forKey: "isNewZealandTrafficLightModeEnabled") as? Bool
        let storedSignalLightAgentScope = userDefaults.string(forKey: "signalLightAgentScope")
        let storedSignalLightAgentScopes = userDefaults.stringArray(forKey: "signalLightAgentScopes")
        let storedSignalLightAgentSelectionMode = userDefaults.string(forKey: "signalLightAgentSelectionMode")
        let storedCodexUsageDataSource = userDefaults.string(forKey: "codexUsageDataSource")
        let storedCodexOpenAICookieMode = userDefaults.string(forKey: "codexOpenAICookieMode")
        let storedStatusMenuMode = userDefaults.string(forKey: "statusMenuMode")
        let storedFloatingSignalScale = userDefaults.string(forKey: "floatingSignalScale")
        let storedFloatingSignalVisualScale =
            userDefaults.object(forKey: "floatingSignalVisualScale") as? Double
        let storedFloatingSignalLayout = userDefaults.string(forKey: "floatingSignalLayout")
        let storedFloatingSignalScaleDefaultsVersion =
            userDefaults.integer(forKey: "floatingSignalScaleDefaultsVersion")
        let storedFloatingSignalSoundLevel = userDefaults.string(forKey: "floatingSignalSoundLevel")
        let storedFloatingSignalInfoBadgeEnabled =
            userDefaults.object(forKey: "isFloatingSignalInfoBadgeEnabled") as? Bool
        let storedFloatingSignalQuotaBadgeEnabled =
            userDefaults.object(forKey: "isFloatingSignalQuotaBadgeEnabled") as? Bool
        let storedFloatingSignalTokenBadgeEnabled =
            userDefaults.object(forKey: "isFloatingSignalTokenBadgeEnabled") as? Bool
        let storedFloatingSignalInfoBadgeCorner =
            userDefaults.string(forKey: "floatingSignalInfoBadgeCorner")
        let storedFloatingSignalQuotaBadgeCorner =
            userDefaults.string(forKey: "floatingSignalQuotaBadgeCorner")
        let storedFloatingSignalTokenBadgeCorner =
            userDefaults.string(forKey: "floatingSignalTokenBadgeCorner")
        let storedFloatingSignalQuotaBadgeWindow =
            userDefaults.string(forKey: "floatingSignalQuotaBadgeWindow")
        let storedFloatingSignalTokenBadgeWindow =
            userDefaults.string(forKey: "floatingSignalTokenBadgeWindow")
        let storedFloatingSignalCompletionSound =
            userDefaults.string(forKey: "floatingSignalCompletionSound")
        let storedFloatingSignalWaitingSound =
            userDefaults.string(forKey: "floatingSignalWaitingSound")
        let storedFloatingSignalSoundEnabled =
            userDefaults.object(forKey: "isFloatingSignalSoundEnabled") as? Bool
        let storedFloatingSignalCompletionSoundEnabled =
            userDefaults.object(forKey: "isFloatingSignalCompletionSoundEnabled") as? Bool
        let storedFloatingSignalWaitingSoundEnabled =
            userDefaults.object(forKey: "isFloatingSignalWaitingSoundEnabled") as? Bool
        let storedAutomaticUpdateCheckEnabled =
            userDefaults.object(forKey: "isAutomaticUpdateCheckEnabled") as? Bool
        let storedLastAutomaticUpdateCheckAt =
            userDefaults.object(forKey: "lastAutomaticUpdateCheckAt") as? Date
        let shouldApplyPreferenceDefaults =
            userDefaults.integer(forKey: "settingsPreferenceDefaultsVersion")
                < Self.preferenceDefaultsVersion
        let shouldApplyEffectDefaults = userDefaults.integer(forKey: "signalEffectDefaultsVersion") < Self.effectDefaultsVersion
        let resolvedDisplayLayout =
            storedLayout.flatMap(TrafficSignalLayout.init(rawValue:)) ?? Self.defaultDisplayLayout
        displayLayout = resolvedDisplayLayout
        statusBarStyle = storedStyle.flatMap(TrafficSignalStyle.init(rawValue:)) ?? Self.defaultStatusBarStyle
        let storedMacOSBreathingStrength = storedMacOSStrength.flatMap(MacOSBreathingStrength.init(rawValue:))
        let resolvedMacOSBreathingStrength = storedMacOSBreathingStrength ?? .pronounced
        macOSBreathingStrength = resolvedMacOSBreathingStrength
        if storedMacOSBreathingStrength == nil {
            userDefaults.set(resolvedMacOSBreathingStrength.rawValue, forKey: "macOSBreathingStrength")
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
            userDefaults.set(resolvedThinkingSignalEffect.rawValue, forKey: "thinkingSignalEffect")
            userDefaults.set(resolvedActiveSignalEffect.rawValue, forKey: "activeSignalEffect")
            userDefaults.set(resolvedCompletedSignalEffect.rawValue, forKey: "completedSignalEffect")
            userDefaults.set(Self.effectDefaultsVersion, forKey: "signalEffectDefaultsVersion")
        }
        if storedNeedsReviewSignalEffect == nil || storedNeedsReviewSignalEffect == AlertSignalEffect.pulse.rawValue {
            userDefaults.set(resolvedNeedsReviewSignalEffect.rawValue, forKey: "needsReviewSignalEffect")
        }
        if storedPermissionSignalEffect == nil || storedPermissionSignalEffect == AlertSignalEffect.pulse.rawValue {
            userDefaults.set(resolvedPermissionSignalEffect.rawValue, forKey: "permissionSignalEffect")
        }
        if storedBlockedSignalEffect == nil || storedBlockedSignalEffect == AlertSignalEffect.pulse.rawValue {
            userDefaults.set(resolvedBlockedSignalEffect.rawValue, forKey: "blockedSignalEffect")
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
            userDefaults.set(
                resolvedNewZealandTrafficLightModeEnabled,
                forKey: "isNewZealandTrafficLightModeEnabled"
            )
        }
        isFloatingSignalEnabled =
            userDefaults.object(forKey: "isFloatingSignalEnabled") as? Bool ?? true
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
            userDefaults.set(Double(resolvedFloatingSignalVisualScale), forKey: "floatingSignalVisualScale")
        }
        if storedFloatingSignalScaleDefaultsVersion < Self.floatingSignalScaleDefaultsVersion {
            userDefaults.set(resolvedFloatingSignalScale.rawValue, forKey: "floatingSignalScale")
            userDefaults.set(
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
            userDefaults.set(resolvedFloatingSignalLayout.rawValue, forKey: "floatingSignalLayout")
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
            userDefaults.set(true, forKey: "isFloatingSignalInfoBadgeEnabled")
        }
        if storedFloatingSignalQuotaBadgeEnabled == nil {
            userDefaults.set(true, forKey: "isFloatingSignalQuotaBadgeEnabled")
        }
        if storedFloatingSignalTokenBadgeEnabled == nil {
            userDefaults.set(true, forKey: "isFloatingSignalTokenBadgeEnabled")
        }
        let resolvedFloatingSignalInfoBadgeCorner =
            storedFloatingSignalInfoBadgeCorner.flatMap(FloatingSignalInfoBadgeCorner.init(rawValue:)) ?? .topRight
        floatingSignalInfoBadgeCorner = resolvedFloatingSignalInfoBadgeCorner
        if storedFloatingSignalInfoBadgeCorner != resolvedFloatingSignalInfoBadgeCorner.rawValue {
            userDefaults.set(resolvedFloatingSignalInfoBadgeCorner.rawValue, forKey: "floatingSignalInfoBadgeCorner")
        }
        let resolvedFloatingSignalQuotaBadgeCorner =
            storedFloatingSignalQuotaBadgeCorner.flatMap(FloatingSignalInfoBadgeCorner.init(rawValue:)) ?? .topLeft
        floatingSignalQuotaBadgeCorner = resolvedFloatingSignalQuotaBadgeCorner
        if storedFloatingSignalQuotaBadgeCorner != resolvedFloatingSignalQuotaBadgeCorner.rawValue {
            userDefaults.set(resolvedFloatingSignalQuotaBadgeCorner.rawValue, forKey: "floatingSignalQuotaBadgeCorner")
        }
        let resolvedFloatingSignalTokenBadgeCorner =
            storedFloatingSignalTokenBadgeCorner.flatMap(FloatingSignalInfoBadgeCorner.init(rawValue:)) ?? .bottomLeft
        floatingSignalTokenBadgeCorner = resolvedFloatingSignalTokenBadgeCorner
        if storedFloatingSignalTokenBadgeCorner != resolvedFloatingSignalTokenBadgeCorner.rawValue {
            userDefaults.set(resolvedFloatingSignalTokenBadgeCorner.rawValue, forKey: "floatingSignalTokenBadgeCorner")
        }
        let resolvedFloatingSignalQuotaBadgeWindow =
            storedFloatingSignalQuotaBadgeWindow.flatMap(FloatingSignalQuotaBadgeWindow.init(rawValue:)) ?? .fiveHours
        floatingSignalQuotaBadgeWindow = resolvedFloatingSignalQuotaBadgeWindow
        if storedFloatingSignalQuotaBadgeWindow != resolvedFloatingSignalQuotaBadgeWindow.rawValue {
            userDefaults.set(resolvedFloatingSignalQuotaBadgeWindow.rawValue, forKey: "floatingSignalQuotaBadgeWindow")
        }
        let resolvedFloatingSignalTokenBadgeWindow =
            storedFloatingSignalTokenBadgeWindow.flatMap(FloatingSignalTokenBadgeWindow.init(rawValue:)) ?? .today
        floatingSignalTokenBadgeWindow = resolvedFloatingSignalTokenBadgeWindow
        if storedFloatingSignalTokenBadgeWindow != resolvedFloatingSignalTokenBadgeWindow.rawValue {
            userDefaults.set(resolvedFloatingSignalTokenBadgeWindow.rawValue, forKey: "floatingSignalTokenBadgeWindow")
        }
        macOSHorizontalUsesTrafficLightSize =
            userDefaults.object(forKey: "macOSHorizontalUsesTrafficLightSize") as? Bool
            ?? userDefaults.object(forKey: "macOSUsesTrafficLightSize") as? Bool
            ?? Self.defaultMacOSHorizontalUsesTrafficLightSize
        trafficLightVerticalUsesMacOSSize =
            userDefaults.object(forKey: "trafficLightVerticalUsesMacOSSize") as? Bool
            ?? Self.defaultTrafficLightVerticalUsesMacOSSize
        let storedStatusBarIconEnabled = userDefaults.object(forKey: "isStatusBarIconEnabled") as? Bool ?? true
        isStatusBarIconEnabled = DebugLaunchOptions.shouldForceStatusBarIconEnabled ? true : storedStatusBarIconEnabled
        userDefaults.set(false, forKey: "isStatusBarAllLightsOn")
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
        codexManualOpenAICookieHeader = startsMonitoring ? Self.loadManualOpenAICookieHeader(
            secretStore: openAICookieStore,
            userDefaults: userDefaults,
            allowsUserInteraction: false
        ) : ""
        let storedStatusMenuModeValue = storedStatusMenuMode.flatMap(StatusMenuMode.init(rawValue:))
        let resolvedStatusMenuMode = storedStatusMenuModeValue ?? .simple
        statusMenuMode = resolvedStatusMenuMode
        if storedStatusMenuModeValue == nil {
            userDefaults.set(resolvedStatusMenuMode.rawValue, forKey: "statusMenuMode")
        }
        isCodexDesktopMonitoringEnabled =
            userDefaults.object(forKey: "isCodexDesktopMonitoringEnabled") as? Bool ?? true
        isClaudeDesktopMonitoringEnabled =
            userDefaults.object(forKey: "isClaudeDesktopMonitoringEnabled") as? Bool ?? true
        let resolvedAutomaticUpdateCheckEnabled = false
        isAutomaticUpdateCheckEnabled = resolvedAutomaticUpdateCheckEnabled
        if storedAutomaticUpdateCheckEnabled != resolvedAutomaticUpdateCheckEnabled {
            userDefaults.set(resolvedAutomaticUpdateCheckEnabled, forKey: "isAutomaticUpdateCheckEnabled")
        }
        lastAutomaticUpdateCheckAt = storedLastAutomaticUpdateCheckAt
        lastNotifiedUpdateVersion = userDefaults.string(forKey: "lastNotifiedUpdateVersion")
        snapshot = store.readSnapshot()
        let snapshotQuota = Self.latestQuota(in: snapshot)
        let snapshotTokenObservation = Self.latestTokenUsageObservation(in: snapshot)
        let cachedQuota = Self.cachedLatestAgentQuota(userDefaults: userDefaults)
        latestAgentQuota = Self.latestQuota(snapshotQuota, isNewerThan: cachedQuota) ? snapshotQuota : cachedQuota
        latestAgentTokenUsage = snapshotTokenObservation?.usage
            ?? latestAgentQuota?.tokenUsage
            ?? Self.cachedLatestAgentTokenUsage(userDefaults: userDefaults)
        latestAgentTokenUsageSessionID = snapshotTokenObservation?.sessionID
        latestAgentTokenUsageUpdatedAt = snapshotTokenObservation?.updatedAt
            ?? latestAgentQuota.flatMap { quota in
                quota.tokenUsage == nil ? nil : quota.updatedAt
            }
        // The process-global UserDefaults value has no account or session
        // identity. It may populate the UI briefly, but must never become a
        // pending counter. Only the state snapshot can prove ownership here.
        if let observation = snapshotTokenObservation,
           let totalTokens = observation.usage.effectiveTotalTokens {
            let key = Self.liveTokenSessionKey(observation.sessionID)
            liveTokenCounters[key] = LiveTokenCounterState(
                sessionID: observation.sessionID,
                totalTokens: totalTokens,
                scannedBaseline: 0,
                day: Calendar.current.startOfDay(
                    for: observation.updatedAt ?? snapshot.updatedAt ?? nowProvider()
                ),
                updatedAt: observation.updatedAt
            )
        }
        isLaunchAtLoginEnabled = startsMonitoring && launchAtLoginManager.isEnabled
        refreshCodexAccounts()
        hydrateCodexUsageSnapshotForCurrentAccount()
        hydrateCodexDeviceTokenSnapshot()
        if shouldApplyPreferenceDefaults && startsMonitoring {
            enableLaunchAtLoginByDefaultIfNeeded()
            userDefaults.set(Self.preferenceDefaultsVersion, forKey: "settingsPreferenceDefaultsVersion")
        }
        guard startsMonitoring else { return }
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
            if applyCodexAccountState(state) {
                prepareCodexUsageAfterAccountChange()
            } else if state.currentAccount == nil, state.savedAccounts.isEmpty {
                // Startup initially has no account identity, so applying the
                // empty discovered state is not an identity transition. Any
                // quota restored before discovery is nevertheless account-
                // scoped and must not survive a confirmed no-account state.
                clearLatestAgentQuotaCache()
            }
            codexAccountMessage = nil
            isCodexAccountMessageError = false
        } catch {
            codexAccountMessage = error.localizedDescription
            isCodexAccountMessageError = true
        }
    }

    func refreshCodexProviderDetails(force: Bool = false) {
        let now = Date()
        if !force,
           let codexProviderDetailsCheckedAt,
           now.timeIntervalSince(codexProviderDetailsCheckedAt) < Self.codexProviderDetailsRefreshInterval {
            return
        }
        if isCodexProviderDetailsLoading, !force { return }

        codexProviderDetailsRefreshGeneration &+= 1
        let refreshGeneration = codexProviderDetailsRefreshGeneration
        let expectedAccountIdentity = codexUsageAccountIdentity(for: codexCurrentAccount)
        let expectedAccountScopeID = codexActiveSavedAccountID
        isCodexProviderDetailsLoading = true
        let cliProbe = codexCLIStatusProbe
        let rpcProbe = codexRPCStatusProbe
        let serviceStatusFetcher = codexServiceStatusFetcher
        Task(priority: .utility) { [weak self] in
            async let cliStatus = Task.detached(priority: .utility) {
                cliProbe.probeStatus()
            }.value
            async let rpcStatus = rpcProbe.probeStatus()
            async let serviceStatus = try? serviceStatusFetcher.fetchStatus()
            let (resolvedCLIStatus, resolvedRPCStatus, resolvedServiceStatus) = await (
                cliStatus,
                rpcStatus,
                serviceStatus
            )

            await MainActor.run { [weak self] in
                guard let self,
                      self.codexProviderDetailsRefreshGeneration == refreshGeneration,
                      self.codexUsageAccountIdentity(for: self.codexCurrentAccount)
                        == expectedAccountIdentity,
                      self.codexActiveSavedAccountID == expectedAccountScopeID
                else {
                    return
                }
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
            if applyCodexAccountState(try codexAccountManager.loadState()) {
                prepareCodexUsageAfterAccountChange()
            } else {
                persistCodexUsageSnapshotForCurrentAccount()
            }
            codexAccountMessage = text("已保存 \(account.displayName)。", "Saved \(account.displayName).")
            isCodexAccountMessageError = false
            lastError = nil
        } catch {
            let message = codexAccountActionFailureMessage(error)
            codexAccountMessage = message
            isCodexAccountMessageError = true
            lastError = message
        }
        isCodexAccountActionRunning = false
    }

    func addCodexAccount() {
        guard !isCodexAccountActionRunning else { return }
        isCodexAccountActionRunning = true
        codexAccountMessage = text(
            "正在打开 Codex 登录；如果浏览器未打开，可在终端运行 codex login，完成后点“保存当前”。",
            "Opening Codex login. If the browser does not open, run codex login in Terminal, then use Save Current."
        )
        isCodexAccountMessageError = false

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
                isCodexAccountMessageError = false
                lastError = nil
                pollCodexRateLimitsIfNeeded(force: true)
                refreshTokenActivityIfNeeded()
            } catch {
                let message = codexAccountActionFailureMessage(error)
                codexAccountMessage = message
                isCodexAccountMessageError = true
                lastError = message
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
            if performsAccountSwitchBackgroundRefreshes {
                refreshCodexProviderDetails(force: true)
            }
            codexAccountMessage = text(
                "已切换到 \(switchedAccount.displayName)。",
                "Switched to \(switchedAccount.displayName)."
            )
            isCodexAccountMessageError = false
            lastError = nil
            if performsAccountSwitchBackgroundRefreshes {
                pollCodexRateLimitsIfNeeded(force: true)
            }
            refreshTokenActivityIfNeeded()
        } catch {
            let message = codexAccountActionFailureMessage(error)
            codexAccountMessage = message
            isCodexAccountMessageError = true
            lastError = message
        }
        isCodexAccountActionRunning = false
    }

    func removeCodexAccount(_ account: CodexAccountProfile) {
        guard !isCodexAccountActionRunning else { return }
        let removesActiveAccount = codexActiveSavedAccountID == account.id
        isCodexAccountActionRunning = true
        do {
            try codexAccountManager.removeAccount(id: account.id)
            codexUsageSnapshotStore.remove(for: account)
            applyCodexAccountState(try codexAccountManager.loadState())
            if removesActiveAccount {
                prepareCodexUsageAfterAccountChange()
                codexProviderAccountEmail = nil
                codexProviderPlanName = nil
                codexProviderServiceStatusText = nil
                codexProviderDetailsCheckedAt = nil
                if codexCurrentAccount != nil {
                    refreshCodexProviderDetails(force: true)
                    pollCodexRateLimitsIfNeeded(force: true)
                    refreshTokenActivityIfNeeded()
                }
            }
            codexAccountMessage = text("已删除保存的账户。", "Saved account removed.")
            isCodexAccountMessageError = false
            lastError = nil
        } catch {
            let message = codexAccountActionFailureMessage(error)
            codexAccountMessage = message
            isCodexAccountMessageError = true
            lastError = message
        }
        isCodexAccountActionRunning = false
    }

    func isActiveCodexAccount(_ account: CodexAccountProfile) -> Bool {
        codexActiveSavedAccountID == account.id
    }

    private func codexAccountActionFailureMessage(_ error: Error) -> String {
        if let managerError = error as? CodexAccountManagerError {
            if managerError == .missingCodexBinary {
                return text(
                    "没有找到 codex 命令。请先安装 Codex CLI；如果终端里可以运行 codex login，先在终端完成登录，再回到这里点“保存当前”。",
                    "Could not find the codex command. Install Codex CLI. If codex login works in Terminal, finish it there, then return here and use Save Current."
                )
            }
            if case let .keychainFailure(message) = managerError,
               message.contains("-25293") {
                return text(
                    "无法解锁“登录”钥匙串。请打开“钥匙串访问”并解锁“登录”钥匙串，然后重试；这里需要的是 Mac 钥匙串密码，不是 Codex 密码。",
                    "Could not unlock the login keychain. Open Keychain Access and unlock the login keychain, then try again. This needs your Mac keychain password, not your Codex password."
                )
            }
        }
        return error.localizedDescription
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
        invalidateCodexLiveObservationContext()
        invalidateCodexDevicePollContext()

        if paused {
            invalidateCodexUsageRefresh()
            codexUsageRefreshPending = false
            invalidateTokenActivityScan()
            startMonitoringPauseLightSequence()
            pollDesktopAppPresence()
        } else {
            reload()
            pollCodexRateLimitsIfNeeded(force: true)
            refreshTokenActivityIfNeeded(force: true)
            pollDesktopAppPresence()
            startMonitoringResumeLightSequence()
        }
    }

    func toggleMonitoring() {
        setMonitoringPaused(!isMonitoringPaused)
    }

    func setDisplayLayout(_ layout: TrafficSignalLayout) {
        displayLayout = layout
        userDefaults.set(layout.rawValue, forKey: "trafficSignalLayout")
    }

    func setStatusBarStyle(_ style: TrafficSignalStyle) {
        statusBarStyle = style
        userDefaults.set(style.rawValue, forKey: "trafficSignalStyle")
    }

    func setMacOSBreathingStrength(_ strength: MacOSBreathingStrength) {
        macOSBreathingStrength = strength
        userDefaults.set(strength.rawValue, forKey: "macOSBreathingStrength")
    }

    func setThinkingSignalEffect(_ effect: ActiveSignalEffect) {
        thinkingSignalEffect = effect
        userDefaults.set(effect.rawValue, forKey: "thinkingSignalEffect")
    }

    func setActiveSignalEffect(_ effect: ActiveSignalEffect) {
        activeSignalEffect = effect
        userDefaults.set(effect.rawValue, forKey: "activeSignalEffect")
    }

    func setActiveEffectSpeed(_ speed: SignalEffectSpeed) {
        activeEffectSpeed = speed
        userDefaults.set(speed.rawValue, forKey: "activeEffectSpeed")
    }

    func setAlertEffectSpeed(_ speed: SignalEffectSpeed) {
        alertEffectSpeed = speed
        userDefaults.set(speed.rawValue, forKey: "alertEffectSpeed")
    }

    func setCompletedSignalEffect(_ effect: CompletedSignalEffect) {
        completedSignalEffect = effect
        userDefaults.set(effect.rawValue, forKey: "completedSignalEffect")
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
        userDefaults.set(effect.rawValue, forKey: "needsReviewSignalEffect")
    }

    func setPermissionSignalEffect(_ effect: AlertSignalEffect) {
        permissionSignalEffect = effect
        userDefaults.set(effect.rawValue, forKey: "permissionSignalEffect")
    }

    func setBlockedSignalEffect(_ effect: AlertSignalEffect) {
        blockedSignalEffect = effect
        userDefaults.set(effect.rawValue, forKey: "blockedSignalEffect")
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
        userDefaults.set(enabled, forKey: "macOSHorizontalUsesTrafficLightSize")
    }

    func setTrafficLightVerticalUsesMacOSSize(_ enabled: Bool) {
        trafficLightVerticalUsesMacOSSize = enabled
        userDefaults.set(enabled, forKey: "trafficLightVerticalUsesMacOSSize")
    }

    func setStatusBarIconEnabled(_ enabled: Bool) {
        isStatusBarIconEnabled = enabled
        userDefaults.set(enabled, forKey: "isStatusBarIconEnabled")
    }

    func setFloatingSignalEnabled(_ enabled: Bool) {
        isFloatingSignalEnabled = enabled
        userDefaults.set(enabled, forKey: "isFloatingSignalEnabled")
    }

    func setFloatingSignalScale(_ scale: FloatingSignalScale) {
        floatingSignalScale = scale
        userDefaults.set(scale.rawValue, forKey: "floatingSignalScale")
        setFloatingSignalVisualScale(scale.visualScale, persist: true)
        userDefaults.set(
            Self.floatingSignalScaleDefaultsVersion,
            forKey: "floatingSignalScaleDefaultsVersion"
        )
    }

    func setFloatingSignalVisualScale(_ visualScale: CGFloat, persist: Bool) {
        let clampedScale = FloatingSignalScale.clampedVisualScale(visualScale)
        guard abs(floatingSignalVisualScale - clampedScale) > 0.001 || persist else { return }

        floatingSignalVisualScale = clampedScale
        if persist {
            userDefaults.set(Double(clampedScale), forKey: "floatingSignalVisualScale")
        }
    }

    func setFloatingSignalLayout(_ layout: TrafficSignalLayout) {
        floatingSignalLayout = layout
        userDefaults.set(layout.rawValue, forKey: "floatingSignalLayout")
    }

    func makeFloatingSignalSmaller() {
        setFloatingSignalVisualScale(floatingSignalVisualScale - 0.18, persist: true)
    }

    func makeFloatingSignalLarger() {
        setFloatingSignalVisualScale(floatingSignalVisualScale + 0.18, persist: true)
    }

    func setFloatingSignalSoundEnabled(_ enabled: Bool) {
        isFloatingSignalSoundEnabled = enabled
        userDefaults.set(enabled, forKey: "isFloatingSignalSoundEnabled")
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
        userDefaults.set(sound.rawValue, forKey: "floatingSignalCompletionSound")
        userDefaults.set(sound.isEnabled, forKey: "isFloatingSignalCompletionSoundEnabled")
    }

    func setFloatingSignalWaitingSound(_ sound: FloatingSignalWaitingSound) {
        floatingSignalWaitingSound = sound
        isFloatingSignalWaitingSoundEnabled = sound.isEnabled
        userDefaults.set(sound.rawValue, forKey: "floatingSignalWaitingSound")
        userDefaults.set(sound.isEnabled, forKey: "isFloatingSignalWaitingSoundEnabled")
    }

    func setFloatingSignalSoundLevel(_ level: FloatingSignalSoundLevel) {
        floatingSignalSoundLevel = level
        userDefaults.set(level.rawValue, forKey: "floatingSignalSoundLevel")
    }

    func setFloatingSignalInfoBadgeEnabled(_ enabled: Bool) {
        guard isFloatingSignalInfoBadgeEnabled != enabled else { return }
        isFloatingSignalInfoBadgeEnabled = enabled
        userDefaults.set(enabled, forKey: "isFloatingSignalInfoBadgeEnabled")
    }

    func setFloatingSignalQuotaBadgeEnabled(_ enabled: Bool) {
        guard isFloatingSignalQuotaBadgeEnabled != enabled else { return }
        isFloatingSignalQuotaBadgeEnabled = enabled
        userDefaults.set(enabled, forKey: "isFloatingSignalQuotaBadgeEnabled")
        if enabled {
            pollCodexRateLimitsIfNeeded(force: true)
        }
    }

    func setFloatingSignalTokenBadgeEnabled(_ enabled: Bool) {
        guard isFloatingSignalTokenBadgeEnabled != enabled else { return }
        isFloatingSignalTokenBadgeEnabled = enabled
        userDefaults.set(enabled, forKey: "isFloatingSignalTokenBadgeEnabled")
        if enabled {
            refreshTokenActivityIfNeeded(force: tokenActivityDays.isEmpty)
        }
    }

    func setFloatingSignalInfoBadgeCorner(_ corner: FloatingSignalInfoBadgeCorner) {
        guard floatingSignalInfoBadgeCorner != corner else { return }
        floatingSignalInfoBadgeCorner = corner
        userDefaults.set(corner.rawValue, forKey: "floatingSignalInfoBadgeCorner")
    }

    func setFloatingSignalQuotaBadgeCorner(_ corner: FloatingSignalInfoBadgeCorner) {
        guard floatingSignalQuotaBadgeCorner != corner else { return }
        floatingSignalQuotaBadgeCorner = corner
        userDefaults.set(corner.rawValue, forKey: "floatingSignalQuotaBadgeCorner")
    }

    func setFloatingSignalTokenBadgeCorner(_ corner: FloatingSignalInfoBadgeCorner) {
        guard floatingSignalTokenBadgeCorner != corner else { return }
        floatingSignalTokenBadgeCorner = corner
        userDefaults.set(corner.rawValue, forKey: "floatingSignalTokenBadgeCorner")
    }

    func setFloatingSignalQuotaBadgeWindow(_ window: FloatingSignalQuotaBadgeWindow) {
        guard floatingSignalQuotaBadgeWindow != window else { return }
        floatingSignalQuotaBadgeWindow = window
        userDefaults.set(window.rawValue, forKey: "floatingSignalQuotaBadgeWindow")
    }

    func setFloatingSignalTokenBadgeWindow(_ window: FloatingSignalTokenBadgeWindow) {
        guard floatingSignalTokenBadgeWindow != window else { return }
        floatingSignalTokenBadgeWindow = window
        userDefaults.set(window.rawValue, forKey: "floatingSignalTokenBadgeWindow")
    }

    func tokenActivityTotal(for window: FloatingSignalTokenBadgeWindow, now: Date = Date()) -> Int {
        let scannedTotal = scannedTokenActivityTotal(
            in: tokenActivityDays,
            for: window,
            now: now
        )
        let pendingTotal = pendingLiveTokenUsageTotal(for: window, now: now)
        let accountedTotal = scannedTotal + pendingTotal
        guard let floor = legacyUnscopedTokenFloor,
              tokenActivityDayIsIncluded(floor.day, in: window, now: now)
        else {
            return accountedTotal
        }

        let scannedOnFloorDay = tokenActivityDays
            .filter { Calendar.current.isDate($0.day, inSameDayAs: floor.day) }
            .map(\.totalTokens)
            .reduce(0, +)
        let pendingOnFloorDay = pendingLiveTokenUsageByDay(now: now)[
            Calendar.current.startOfDay(for: floor.day),
            default: 0
        ]
        return accountedTotal + max(0, floor.totalTokens - scannedOnFloorDay - pendingOnFloorDay)
    }

    /// A missing/failed first scan is unknown, not a measured zero. Existing
    /// history and unscanned live counters remain useful while a scan retries.
    func tokenActivityDisplayTotal(for window: FloatingSignalTokenBadgeWindow, now: Date = Date()) -> Int? {
        let total = tokenActivityTotal(for: window, now: now)
        if total == 0 && tokenActivityIsPartial { return nil }
        return total > 0 || hasCompletedTokenActivityScan || !tokenActivityDays.isEmpty ? total : nil
    }

    var tokenActivityStatusText: String? {
        if let tokenActivityIssue {
            return tokenActivityIssue
        }
        if isTokenActivityLoading {
            return text("正在扫描本机会话；已确认的数据会保留。", "Scanning local sessions; confirmed usage is retained.")
        }
        if !isCodexDesktopMonitoringEnabled || isMonitoringPaused {
            return text("监控已暂停；这里保留上次已确认的用量。", "Monitoring is paused; showing the last confirmed usage.")
        }
        if !hasCompletedTokenActivityScan && tokenActivityDays.isEmpty {
            return text("等待本机会话扫描；暂无结果不代表用量为零。", "Waiting for a local scan; unavailable usage does not mean zero.")
        }
        if pendingLiveTokenUsageTotal(for: .last30Days, now: nowProvider()) > 0 {
            return text("包含尚未计价的实时 Token；图表和费用仅显示已扫描历史。", "Includes unpriced live tokens; chart and costs show scanned history only.")
        }
        return nil
    }

    private func tokenActivityPartialStatusText(excludedCount: Int) -> String {
        text(
            "\(excludedCount) 个会话存在记录冲突，暂未计入历史；其余可信用量已显示，实时计数仍保留。",
            "\(excludedCount) sessions have conflicting records and are excluded from history; trusted usage and live counters are retained."
        )
    }

    func tokenActivityEstimatedCost(for window: FloatingSignalTokenBadgeWindow, now: Date = Date()) -> Double? {
        let costs = tokenActivityDays(for: window, now: now)
            .compactMap(\.estimatedCostUSD)
        return costs.isEmpty ? nil : costs.reduce(0, +)
    }

    private func tokenActivityDays(for window: FloatingSignalTokenBadgeWindow, now: Date) -> [CodexTokenActivityDay] {
        tokenActivityDays(in: tokenActivityDays, for: window, now: now)
    }

    private func tokenActivityDays(
        in days: [CodexTokenActivityDay],
        for window: FloatingSignalTokenBadgeWindow,
        now: Date
    ) -> [CodexTokenActivityDay] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)

        switch window {
        case .today:
            return days.filter { calendar.isDate($0.day, inSameDayAs: today) }
        case .last30Days:
            let startDay = calendar.date(byAdding: .day, value: -29, to: today) ?? today
            return days.filter {
                let day = calendar.startOfDay(for: $0.day)
                return day >= startDay && day <= today
            }
        }
    }

    private func scannedTokenActivityTotal(
        in days: [CodexTokenActivityDay],
        for window: FloatingSignalTokenBadgeWindow,
        now: Date
    ) -> Int {
        tokenActivityDays(in: days, for: window, now: now)
            .map(\.totalTokens)
            .reduce(0, +)
    }

    private func pendingLiveTokenUsageTotal(
        for window: FloatingSignalTokenBadgeWindow,
        now: Date
    ) -> Int {
        let counterTotal = liveTokenCounters.values.reduce(into: 0) { total, state in
            guard tokenActivityDayIsIncluded(state.day, in: window, now: now) else { return }
            total += max(0, state.totalTokens - state.scannedBaseline)
        }
        let carryTotal = unscannedLiveTokenCarries.values.reduce(into: 0) { total, carry in
            guard tokenActivityDayIsIncluded(carry.day, in: window, now: now) else { return }
            total += max(0, carry.totalTokens)
        }
        return counterTotal + carryTotal
    }

    private func tokenActivityDayIsIncluded(
        _ date: Date,
        in window: FloatingSignalTokenBadgeWindow,
        now: Date
    ) -> Bool {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: date)
        let today = calendar.startOfDay(for: now)
        switch window {
        case .today:
            return day == today
        case .last30Days:
            let startDay = calendar.date(byAdding: .day, value: -29, to: today) ?? today
            return day >= startDay && day <= today
        }
    }

    func previewFloatingSignalSound() {
        floatingSignalSoundTestTick &+= 1
    }

    func previewFloatingSignalWaitingSound() {
        floatingSignalWaitingSoundTestTick &+= 1
    }

    func savedFloatingSignalOrigin() -> NSPoint? {
        guard let x = userDefaults.object(forKey: "floatingSignalOriginX") as? Double,
              let y = userDefaults.object(forKey: "floatingSignalOriginY") as? Double
        else {
            return nil
        }

        return NSPoint(x: x, y: y)
    }

    func setFloatingSignalOrigin(_ origin: NSPoint) {
        userDefaults.set(Double(origin.x), forKey: "floatingSignalOriginX")
        userDefaults.set(Double(origin.y), forKey: "floatingSignalOriginY")
    }

    func setSignalLightAgentScopes(_ scopes: Set<SignalLightAgentScope>) {
        let selectableScopes = Set(SignalLightAgentScope.selectableCases)
        let resolvedScopes = scopes.intersection(selectableScopes)
        guard !resolvedScopes.isEmpty else { return }

        signalLightAgentScopes = resolvedScopes
        signalLightAgentSelectionMode = .manual
        userDefaults.set(
            resolvedScopes
                .sorted { $0.sortOrder < $1.sortOrder }
                .map(\.rawValue),
            forKey: "signalLightAgentScopes"
        )
        userDefaults.set(
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
        userDefaults.set(mode.rawValue, forKey: "statusMenuMode")
    }

    func setCodexUsageDataSource(_ source: CodexUsageDataSource) {
        let resolvedSource = source.resolvedSelectableValue
        guard codexUsageDataSource != resolvedSource else { return }
        codexUsageDataSource = resolvedSource
        userDefaults.set(resolvedSource.rawValue, forKey: "codexUsageDataSource")
        invalidateCodexUsageRefresh()
        lastError = nil
        pollCodexRateLimitsIfNeeded(force: true)
    }

    func setCodexOpenAICookieMode(_ mode: CodexOpenAICookieMode) {
        let resolvedMode = mode.resolvedSelectableValue
        guard codexOpenAICookieMode != resolvedMode else { return }
        codexOpenAICookieMode = resolvedMode
        userDefaults.set(resolvedMode.rawValue, forKey: "codexOpenAICookieMode")
        invalidateCodexUsageRefresh()
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
            userDefaults.removeObject(forKey: Self.legacyManualOpenAICookieUserDefaultsKey)
        } catch {
            lastError = text(
                "无法保存 OpenAI Cookie：\(error.localizedDescription)",
                "Could not save OpenAI Cookie: \(error.localizedDescription)"
            )
        }
        invalidateCodexUsageRefresh()
    }

    func setCodexDesktopMonitoringEnabled(_ enabled: Bool) {
        isCodexDesktopMonitoringEnabled = enabled
        userDefaults.set(enabled, forKey: "isCodexDesktopMonitoringEnabled")
        invalidateCodexLiveObservationContext()
        invalidateCodexDevicePollContext()
        if enabled {
            codexDesktopActivityMonitor.reset()
            pollCodexDesktopActivity()
            refreshTokenActivityIfNeeded(force: true)
        } else {
            invalidateCodexUsageRefresh()
            codexUsageRefreshPending = false
            invalidateTokenActivityScan()
        }
        pollDesktopAppPresence()
    }

    func setClaudeDesktopMonitoringEnabled(_ enabled: Bool) {
        isClaudeDesktopMonitoringEnabled = enabled
        userDefaults.set(enabled, forKey: "isClaudeDesktopMonitoringEnabled")
        pollDesktopAppPresence()
    }

    func setAppLanguage(_ language: AppLanguage) {
        appLanguage = language
        userDefaults.set(language.rawValue, forKey: "appLanguage")
    }

    func setAppTheme(_ theme: AppTheme) {
        appTheme = theme
        userDefaults.set(theme.rawValue, forKey: "appTheme")
    }

    func setSettingsGlassEnabled(_ enabled: Bool) {
        isSettingsGlassEnabled = enabled
        userDefaults.set(enabled, forKey: "isSettingsGlassEnabled")
    }

    func setDebugSettingsVisible(_ visible: Bool) {
        isDebugSettingsVisible = visible
        userDefaults.set(visible, forKey: "isDebugSettingsVisible")
    }

    func setDebugFileLoggingEnabled(_ enabled: Bool) {
        isDebugFileLoggingEnabled = enabled
        userDefaults.set(enabled, forKey: "isDebugFileLoggingEnabled")
        if enabled {
            appendDebugLog("file logging enabled")
        }
    }

    func setDebugLogLevel(_ level: DebugLogLevel) {
        debugLogLevel = level
        userDefaults.set(level.rawValue, forKey: "debugLogLevel")
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
        invalidateCodexUsageRefresh()
        codexUsageRefreshPending = false
        invalidateCodexLiveObservationContext()
        invalidateCodexDevicePollContext()
        invalidateTokenActivityScan()
        clearLatestAgentQuotaCache()
        clearLatestAgentTokenUsageCache()
        clearTokenActivityCache()
        codexUsageSnapshotStore.removeAll()
        let scanner = codexTokenActivityScanner
        tokenActivityQueue.async {
            // Serialize behind any in-flight scan so an old completion cannot
            // recreate the files after the user cleared them.
            scanner.clearCache()
        }
        debugCacheMessage = text("已清除费用/用量缓存。", "Usage cache cleared.")
        appendDebugLog("usage cache cleared")
    }

    func clearDebugCookieCache() {
        codexManualOpenAICookieHeader = ""
        try? openAICookieStore.delete(key: Self.manualOpenAICookieKey)
        userDefaults.removeObject(forKey: Self.legacyManualOpenAICookieUserDefaultsKey)
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
        userDefaults.set(effect.rawValue, forKey: "settingsGlassEffect")
    }

    func setLowPowerModeEnabled(_ enabled: Bool) {
        guard enabled != isLowPowerModeEnabled else { return }
        isLowPowerModeEnabled = enabled
        userDefaults.set(enabled, forKey: "isLowPowerModeEnabled")
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
        userDefaults.set(enabled, forKey: "isNewZealandTrafficLightModeEnabled")
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
        userDefaults.set(enabled, forKey: "isAutomaticUpdateCheckEnabled")

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
                    userDefaults.set(checkedAt, forKey: "lastAutomaticUpdateCheckAt")

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
                    userDefaults.set(checkedAt, forKey: "lastAutomaticUpdateCheckAt")

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
        userDefaults.set(result.latestVersion, forKey: "lastNotifiedUpdateVersion")

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
        let observationGeneration = codexLiveObservationGeneration
        let expectedAccountIdentity = codexUsageAccountIdentity(for: codexCurrentAccount)

        stateReloadQueue.async { [weak self] in
            let latestSnapshot = store.readSnapshot()

            DispatchQueue.main.async { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.isStateReloadInFlight = false

                    let mayApplyCodexObservations =
                        self.codexLiveObservationGeneration == observationGeneration
                        && self.codexUsageAccountIdentity(for: self.codexCurrentAccount) == expectedAccountIdentity
                        && self.isCodexDesktopMonitoringEnabled
                        && !self.isMonitoringPaused

                    if latestSnapshot != self.snapshot {
                        self.snapshot = latestSnapshot
                        if mayApplyCodexObservations {
                            self.updateLatestAgentQuota(from: latestSnapshot)
                        }
                    }

                    if self.isStateReloadQueued {
                        self.isStateReloadQueued = false
                        self.enqueueStateReload()
                    } else {
                        // No background snapshot can still replay an older
                        // exact observation. Retain only the current signature
                        // for active state so the guard remains bounded.
                        self.pruneExactLiveTokenObservationSignaturesAfterReload()
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

    func pollCodexDesktopActivity() {
        guard isCodexDesktopMonitoringEnabled, !isMonitoringPaused else { return }
        pollCodexRateLimitsIfNeeded()
        guard !isCodexDesktopPollInFlight else { return }

        isCodexDesktopPollInFlight = true
        let monitor = codexDesktopActivityMonitor
        let store = store
        let observationGeneration = codexLiveObservationGeneration
        let devicePollGeneration = codexDevicePollGeneration
        let expectedAccountIdentity = codexUsageAccountIdentity(for: codexCurrentAccount)

        codexDesktopPollQueue.async { [weak self] in
            let pollResult = monitor.pollResult()
            let quotaUpdates = pollResult.quotaUpdates

            DispatchQueue.main.async { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.isCodexDesktopPollInFlight = false
                    guard self.codexDevicePollGeneration == devicePollGeneration,
                          self.isCodexDesktopMonitoringEnabled,
                          !self.isMonitoringPaused
                    else {
                        return
                    }
                    let accountContextMatches =
                        self.codexLiveObservationGeneration == observationGeneration
                        && self.codexUsageAccountIdentity(for: self.codexCurrentAccount)
                            == expectedAccountIdentity
                    // The monitor advances file cursors off-main, but account
                    // ownership can change before that poll returns. Session
                    // activity and JSONL token observations are device-wide,
                    // so retain them after an account switch. Quota remains
                    // account-scoped and is written only for the captured
                    // account context.
                    var latestSnapshot: SignalSnapshot?
                    var errorMessage: String?
                    do {
                        for activity in pollResult.activities {
                            latestSnapshot = try store.applySessionSignal(
                                activity.signal,
                                sessionID: activity.sessionID,
                                agent: activity.agent,
                                lastEvent: activity.event,
                                updatedAt: activity.timestamp ?? self.nowProvider()
                            )
                        }
                        if accountContextMatches {
                            for quotaUpdate in quotaUpdates.sorted(by: {
                                $0.quota.updatedAt < $1.quota.updatedAt
                            }) {
                                latestSnapshot = try store.applySessionQuota(
                                    quotaUpdate.quota,
                                    sessionID: quotaUpdate.sessionID,
                                    agent: quotaUpdate.agent,
                                    updatedAt: quotaUpdate.quota.updatedAt
                                )
                            }
                        }
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                    let applicableLocalQuotaUpdates = accountContextMatches
                        ? quotaUpdates.filter {
                            self.shouldApplyLocalQuotaObservation(updatedAt: $0.quota.updatedAt)
                        }
                        : []
                    var acceptedLocalQuotaUpdate = false
                    for quotaUpdate in applicableLocalQuotaUpdates
                        where quotaUpdate.quota.windowMinutes != nil {
                        acceptedLocalQuotaUpdate = self.updateLatestLocalQuotaObservation(
                            quotaUpdate
                        ) || acceptedLocalQuotaUpdate
                    }
                    if acceptedLocalQuotaUpdate,
                       self.shouldApplyLocalCodexQuotaUpdates,
                       let latestLocalAgentQuotaObservation = self.latestLocalAgentQuotaObservation {
                        self.updateLatestAgentQuota(latestLocalAgentQuotaObservation)
                    }

                    let applicableTokenUpdates = quotaUpdates.filter {
                        self.shouldApplyReplayedTokenObservation(
                            sessionID: $0.sessionID,
                            updatedAt: $0.quota.updatedAt,
                            observationCursor: $0.tokenObservationCursor
                        )
                    }
                    for quotaUpdate in applicableTokenUpdates {
                        guard let tokenUsage = quotaUpdate.tokenActivityUsage ?? quotaUpdate.quota.tokenUsage else {
                            continue
                        }
                        self.updateLatestAgentTokenUsage(
                            tokenUsage,
                            sessionID: quotaUpdate.sessionID,
                            updatedAt: quotaUpdate.quota.updatedAt,
                            observationCursor: quotaUpdate.tokenObservationCursor,
                            stateShadowUsage: quotaUpdate.quota.tokenUsage,
                            initialScannedBaseline: self.initialLiveTokenBaseline(
                                forForkedFromSessionID: quotaUpdate.forkedFromSessionID,
                                observedTotal: tokenUsage.effectiveTotalTokens,
                                lastTurnTotal: quotaUpdate.quota.tokenUsage?.effectiveTotalTokens
                            )
                        )
                    }
                    if !applicableTokenUpdates.isEmpty {
                        self.refreshTokenActivityIfNeeded()
                    }
                    if let latestSnapshot {
                        self.snapshot = latestSnapshot
                        if accountContextMatches {
                            self.updateLatestAgentQuota(
                                from: latestSnapshot,
                                appliesTokenUsage: applicableTokenUpdates.isEmpty
                            )
                        }
                    }
                    if self.tokenActivityScanRetryPending {
                        self.refreshTokenActivityIfNeeded()
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

        let now = nowProvider()
        let wasRetryPending = tokenActivityScanRetryPending
        if !force, let lastTokenActivityScanAt {
            let refreshInterval = wasRetryPending
                ? tokenActivityPendingRetryInterval
                : Self.tokenActivityRefreshInterval
            if now.timeIntervalSince(lastTokenActivityScanAt) < refreshInterval {
                return
            }
        }
        guard !isTokenActivityScanInFlight else { return }

        tokenActivityScanRetryPending = false
        if force || !wasRetryPending {
            tokenActivityScanRetryAttempt = 0
        }
        startTokenActivityScan(
            now: now,
            allowsImmediateRetry: force || !wasRetryPending
        )
    }

    private var tokenActivityPendingRetryInterval: TimeInterval {
        let exponent = min(max(tokenActivityScanRetryAttempt - 1, 0), 4)
        let multiplier = 1 << exponent
        return min(
            Self.tokenActivityRefreshInterval,
            Self.tokenActivityRetryBaseInterval * Double(multiplier)
        )
    }

    private func startTokenActivityScan(
        now: Date,
        allowsImmediateRetry: Bool
    ) {
        isTokenActivityScanInFlight = true
        isTokenActivityLoading = true
        tokenActivityIssue = nil
        lastTokenActivityScanAt = now
        tokenActivityScanGeneration += 1
        let scanGeneration = tokenActivityScanGeneration
        let scanner = codexDeviceTokenActivityScanner()
        let liveTokenUsageRevisionAtStart = liveTokenUsageRevision

        tokenActivityQueue.async { [weak self] in
            let cachedDays = scanner.cachedDailyActivity(now: now, days: 30)
            if let cachedDays {
                DispatchQueue.main.async { [weak self] in
                    Task { @MainActor in
                        guard let self,
                              self.isTokenActivityScanInFlight,
                              self.tokenActivityScanGeneration == scanGeneration,
                              self.isCodexDesktopMonitoringEnabled,
                              !self.isMonitoringPaused
                        else {
                            return
                        }

                        // A disk cache is only a bootstrap. Do not guess that a
                        // cached aggregate contains a pending per-session counter:
                        // without an event watermark that would double-count it.
                        guard self.tokenActivityDays.isEmpty else { return }
                        let cachedByDay = self.tokenActivityTotalsByDay(
                            cachedDays,
                            now: now
                        )
                        let pendingByDay = self.pendingLiveTokenUsageByDay(now: now)
                        let hasAmbiguousOverlap = cachedByDay.contains { day, cachedTotal in
                            cachedTotal > 0 && pendingByDay[day, default: 0] > 0
                        }
                        guard !hasAmbiguousOverlap else { return }
                        self.tokenActivityDays = cachedDays
                        self.persistCodexUsageSnapshotForCurrentAccount()
                    }
                }
            }

            // Cached days are only a fast UI bootstrap. Every admitted refresh must
            // continue into the incremental scan so today's appended events are found.
            let scanResult = scanner.scanDailyActivityResult(now: now, days: 30, progress: nil)

            DispatchQueue.main.async { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    guard self.tokenActivityScanGeneration == scanGeneration else {
                        self.tokenActivityScanObserver?(.discardedStaleContext)
                        return
                    }
                    guard self.isCodexDesktopMonitoringEnabled,
                          !self.isMonitoringPaused
                    else {
                        self.isTokenActivityScanInFlight = false
                        self.isTokenActivityLoading = false
                        self.tokenActivityScanRetryPending = false
                        self.tokenActivityScanRetryAttempt = 0
                        self.tokenActivityScanObserver?(.discardedInactive)
                        return
                    }

                    guard scanResult.isComplete else {
                        self.tokenActivityIssue = self.text(
                            "Token 历史扫描失败；已确认用量和实时计数已保留。",
                            "Token history scan failed; confirmed usage and live counters are retained."
                        ) + (scanResult.failureDescription.map { " \($0)" } ?? "")
                        self.finishUnabsorbedTokenActivityScan(
                            allowsImmediateRetry: allowsImmediateRetry
                        )
                        return
                    }

                    // Timestamp-only observations cannot prove which numeric
                    // value a concurrently captured scan contains. Preserve the
                    // old retry rule for these legacy/anonymous pending values;
                    // exact source cursors are reconciled below instead.
                    if self.liveTokenUsageRevision != liveTokenUsageRevisionAtStart,
                       self.hasUnprovenConcurrentTokenUsage(in: scanResult) {
                        self.finishUnabsorbedTokenActivityScan(allowsImmediateRetry: allowsImmediateRetry)
                        return
                    }

                    guard Calendar.current.isDate(now, inSameDayAs: self.nowProvider()) else {
                        self.finishUnabsorbedTokenActivityScan(
                            allowsImmediateRetry: allowsImmediateRetry
                        )
                        return
                    }

                    guard self.tokenActivityScanCanAbsorbCurrentUsage(scanResult, now: now) else {
                        // Compare every day in the scan window. A today-only guard
                        // would move yesterday's pending usage across midnight.
                        self.tokenActivityIssue = self.text(
                            "部分会话仍在变化，正在核对历史；实时 Token 已保留。",
                            "Some sessions are still changing; reconciling history while retaining live tokens."
                        )
                        self.finishUnabsorbedTokenActivityScan(
                            allowsImmediateRetry: allowsImmediateRetry
                        )
                        return
                    }

                    self.reconcileLiveTokenUsage(
                        afterScanStartedAt: now,
                        result: scanResult
                    )
                    self.tokenActivityDays = scanResult.days
                    self.hasCompletedTokenActivityScan = true
                    self.tokenActivityIsPartial = scanResult.warningDescription != nil
                    self.tokenActivityExcludedSessionCount = self.tokenActivityIsPartial
                        ? scanResult.excludedSessionIDs.count : nil
                    self.tokenActivityIssue = scanResult.warningDescription.map { _ in
                        self.tokenActivityPartialStatusText(excludedCount: scanResult.excludedSessionIDs.count)
                    }
                    self.isTokenActivityScanInFlight = false
                    self.isTokenActivityLoading = false
                    self.tokenActivityScanRetryPending = false
                    self.tokenActivityScanRetryAttempt = 0
                    self.persistCodexUsageSnapshotForCurrentAccount()
                    self.tokenActivityScanObserver?(.applied)
                }
            }
        }
    }

    private func finishUnabsorbedTokenActivityScan(allowsImmediateRetry: Bool) {
        isTokenActivityScanInFlight = false
        if allowsImmediateRetry {
            tokenActivityScanRetryPending = false
            tokenActivityScanObserver?(.retryingAfterUnabsorbedUsage)
            startTokenActivityScan(now: nowProvider(), allowsImmediateRetry: false)
        } else {
            isTokenActivityLoading = false
            tokenActivityScanRetryPending = true
            tokenActivityScanRetryAttempt += 1
            // Backoff begins when the failed scan finishes. Long scans must not
            // immediately start another full disk walk.
            lastTokenActivityScanAt = nowProvider()
            tokenActivityScanObserver?(.deferredWithRetryPending)
        }
    }

    private func tokenActivityScanCanAbsorbCurrentUsage(
        _ result: CodexTokenActivityScanResult,
        now: Date
    ) -> Bool {
        guard result.isComplete else { return false }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let startDay = calendar.date(byAdding: .day, value: -29, to: today) ?? today
        guard liveTokenCounters.values.allSatisfy({ state in
            if tokenObservationIsExcluded(sessionID: state.sessionID, cursor: state.observationCursor, from: result) {
                return true
            }
            let disposition = tokenObservationDisposition(
                sessionID: state.sessionID,
                totalTokens: state.totalTokens,
                updatedAt: state.updatedAt,
                cursor: state.observationCursor,
                watermarks: result.watermarks
            )
            // A quarantine tombstone rejects the entire source generation,
            // including observations with a future or malformed timestamp.
            if disposition == .rejected { return true }
            let day = calendar.startOfDay(for: state.day)
            let pending = max(0, state.totalTokens - state.scannedBaseline)
            if pending == 0 || day < startDay { return true }
            if pendingBaseline(after: result, for: state) != nil { return day <= today }
            guard day <= today,
                  state.updatedAt.map({ $0 <= now }) ?? true
            else {
                return false
            }
            return state.sessionID == nil || disposition == .covered
        }) else {
            return false
        }
        guard unscannedLiveTokenCarries.values.allSatisfy({ carry in
            if tokenObservationIsExcluded(sessionID: carry.sessionID, cursor: carry.observationCursor, from: result) {
                return true
            }
            let disposition = tokenObservationDisposition(
                sessionID: carry.sessionID,
                totalTokens: nil,
                updatedAt: carry.updatedAt,
                cursor: carry.observationCursor,
                watermarks: result.watermarks
            )
            if disposition == .rejected { return true }
            let day = calendar.startOfDay(for: carry.day)
            if carry.totalTokens == 0 || day < startDay { return true }
            guard day <= today,
                  carry.updatedAt.map({ $0 <= now }) ?? true
            else {
                return false
            }
            return carry.sessionID == nil || disposition == .covered
        }) else {
            return false
        }
        // Once every identified live observation is proven present in the
        // authoritative scan, the historical aggregate may legitimately move
        // down (deleted/truncated JSONL, pricing/parser correction). Preserve a
        // lower bound only for legacy observations that have no session identity
        // and therefore cannot be matched to a scanner watermark.
        let existingTotals = tokenActivityTotalsByDay(tokenActivityDays, now: now)
        var unidentifiedPendingByDay: [Date: Int] = [:]
        for state in liveTokenCounters.values where state.sessionID == nil {
            let day = calendar.startOfDay(for: state.day)
            guard tokenActivityDayIsIncluded(day, in: .last30Days, now: now) else { continue }
            unidentifiedPendingByDay[day, default: 0] += max(
                0,
                state.totalTokens - state.scannedBaseline
            )
        }
        for carry in unscannedLiveTokenCarries.values where carry.sessionID == nil {
            let day = calendar.startOfDay(for: carry.day)
            guard tokenActivityDayIsIncluded(day, in: .last30Days, now: now) else { continue }
            unidentifiedPendingByDay[day, default: 0] += max(0, carry.totalTokens)
        }
        var lowerBounds: [Date: Int] = [:]
        for (day, pendingTotal) in unidentifiedPendingByDay {
            lowerBounds[day] = existingTotals[day, default: 0] + pendingTotal
        }
        if let floor = legacyUnscopedTokenFloor,
           tokenActivityDayIsIncluded(floor.day, in: .last30Days, now: now) {
            let day = calendar.startOfDay(for: floor.day)
            lowerBounds[day] = max(lowerBounds[day, default: 0], floor.totalTokens)
        }
        let candidateTotals = tokenActivityTotalsByDay(result.days, now: now)
        return lowerBounds.allSatisfy { day, lowerBound in
            candidateTotals[day, default: 0] >= lowerBound
        }
    }

    private func tokenActivityTotalsByDay(
        _ days: [CodexTokenActivityDay],
        now: Date
    ) -> [Date: Int] {
        let calendar = Calendar.current
        return days.reduce(into: [:]) { totals, activity in
            let day = calendar.startOfDay(for: activity.day)
            guard tokenActivityDayIsIncluded(day, in: .last30Days, now: now) else { return }
            totals[day, default: 0] += max(0, activity.totalTokens)
        }
    }

    private func tokenObservationIsExcluded(
        sessionID: String?,
        cursor: CodexTokenObservationCursor?,
        from result: CodexTokenActivityScanResult
    ) -> Bool {
        // Exact source proof outranks a v24 root-session label. Falling back to
        // that obsolete label could preserve an already-scanned child's usage
        // merely because an unrelated source in the root group was excluded.
        if let cursor { return result.excludedSourceIDs.contains(cursor.sourceID) }
        guard let sessionID else { return false }
        let normalized = Self.normalizedLiveTokenSessionID(sessionID)
        return result.excludedSessionIDs.contains { Self.normalizedLiveTokenSessionID($0) == normalized }
    }

    private func hasUnprovenConcurrentTokenUsage(in result: CodexTokenActivityScanResult) -> Bool {
        liveTokenCounters.values.contains {
            $0.observationCursor == nil && $0.totalTokens > $0.scannedBaseline
                && !tokenObservationIsExcluded(sessionID: $0.sessionID, cursor: nil, from: result)
        } || unscannedLiveTokenCarries.values.contains {
            $0.observationCursor == nil && $0.totalTokens > 0
                && !tokenObservationIsExcluded(sessionID: $0.sessionID, cursor: nil, from: result)
        } || legacyUnscopedTokenFloor != nil
    }

    /// Accept a completed prefix while a session keeps growing. A numeric delta
    /// is safe only when the scan and live cursor prove the same source snapshot,
    /// the counter is monotonic, and both observations belong to the same day.
    /// A rewrite, reset, or midnight crossing still uses the conservative retry.
    private func pendingBaseline(
        after result: CodexTokenActivityScanResult,
        for state: LiveTokenCounterState
    ) -> Int? {
        guard let cursor = state.observationCursor else { return nil }
        return result.watermarks.compactMap { watermark -> Int? in
            guard watermark.endOffset != .max,
                  watermark.sourceGeneration == cursor.sourceGeneration,
                  watermark.sourceID == cursor.sourceID,
                  watermark.endOffset < cursor.endOffset,
                  sourceSnapshotRelation(watermark: watermark, cursor: cursor) == .same,
                  let total = watermark.totalTokens,
                  total >= state.scannedBaseline,
                  state.totalTokens >= total,
                  let observedAt = watermark.eventTimestamp,
                  Calendar.current.isDate(observedAt, inSameDayAs: state.day)
            else { return nil }
            return max(0, total)
        }.max()
    }

    private func pendingLiveTokenUsageByDay(now: Date) -> [Date: Int] {
        let calendar = Calendar.current
        var totals: [Date: Int] = [:]
        for state in liveTokenCounters.values {
            let day = calendar.startOfDay(for: state.day)
            guard tokenActivityDayIsIncluded(day, in: .last30Days, now: now) else { continue }
            totals[day, default: 0] += max(0, state.totalTokens - state.scannedBaseline)
        }
        for carry in unscannedLiveTokenCarries.values {
            let day = calendar.startOfDay(for: carry.day)
            guard tokenActivityDayIsIncluded(day, in: .last30Days, now: now) else { continue }
            totals[day, default: 0] += max(0, carry.totalTokens)
        }
        return totals
    }

    private func reconcileLiveTokenUsage(
        afterScanStartedAt scanStartedAt: Date,
        result: CodexTokenActivityScanResult
    ) {
        let watermarks = result.watermarks
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: scanStartedAt)
        let startDay = calendar.date(byAdding: .day, value: -29, to: today) ?? today

        for key in Array(liveTokenCounters.keys) {
            guard var state = liveTokenCounters[key] else { continue }
            if tokenObservationIsExcluded(sessionID: state.sessionID, cursor: state.observationCursor, from: result) {
                continue
            }
            let disposition = tokenObservationDisposition(
                sessionID: state.sessionID,
                totalTokens: state.totalTokens,
                updatedAt: state.updatedAt,
                cursor: state.observationCursor,
                watermarks: watermarks
            )
            if disposition == .rejected {
                if let frontier = authoritativeLiveTokenFrontier(
                    sessionID: state.sessionID,
                    cursor: state.observationCursor,
                    watermarks: watermarks
                ) {
                    liveTokenCounters[key] = liveTokenCounterState(
                        sessionID: state.sessionID,
                        frontier: frontier,
                        fallbackDate: scanStartedAt
                    )
                } else {
                    liveTokenCounters.removeValue(forKey: key)
                }
                continue
            }
            let day = calendar.startOfDay(for: state.day)
            if day < startDay {
                liveTokenCounters.removeValue(forKey: key)
            } else if let baseline = pendingBaseline(after: result, for: state) {
                state.scannedBaseline = baseline
                liveTokenCounters[key] = state
            } else if day <= today,
                      state.updatedAt.map({ $0 <= scanStartedAt }) ?? true,
                      state.sessionID == nil || disposition == .covered {
                if let frontier = authoritativeLiveTokenFrontier(
                    sessionID: state.sessionID,
                    cursor: state.observationCursor,
                    watermarks: watermarks
                ) {
                    liveTokenCounters[key] = liveTokenCounterState(
                        sessionID: state.sessionID,
                        frontier: frontier,
                        fallbackDate: scanStartedAt
                    )
                } else {
                    state.scannedBaseline = state.totalTokens
                    liveTokenCounters[key] = state
                }
            }
        }
        unscannedLiveTokenCarries = unscannedLiveTokenCarries.filter { _, carry in
            if tokenObservationIsExcluded(sessionID: carry.sessionID, cursor: carry.observationCursor, from: result) {
                return true
            }
            let disposition = tokenObservationDisposition(
                sessionID: carry.sessionID,
                totalTokens: nil,
                updatedAt: carry.updatedAt,
                cursor: carry.observationCursor,
                watermarks: watermarks
            )
            if disposition == .rejected { return false }
            let normalizedDay = calendar.startOfDay(for: carry.day)
            if normalizedDay < startDay { return false }
            if normalizedDay > today { return true }
            guard carry.sessionID != nil else { return false }
            return disposition != .covered
        }
        legacyUnscopedTokenFloor = nil
        liveTokenScanWatermarks = retainedLiveTokenScanWatermarks(from: watermarks)
        liveTokenUsageScanCutoff = scanStartedAt
    }

    private func retainedLiveTokenScanWatermarks(
        from watermarks: [CodexTokenActivityScanWatermark]
    ) -> [CodexTokenActivityScanWatermark] {
        // Keep one scanned frontier per file generation and session. A disk scan
        // can run ahead of the desktop poll by several token lines; retaining
        // only the poll's current exact cursor loses that lead and double-counts
        // each delayed line. Do not filter a newly discovered generation by the
        // previous scan cutoff: a delayed poll may legitimately replay its older
        // timestamp after this scan has already committed it.
        var frontierByGenerationAndSession: [String: CodexTokenActivityScanWatermark] = [:]
        for watermark in watermarks {
            let normalizedSessionID = watermark.sessionID
                .map(Self.normalizedLiveTokenSessionID) ?? ""
            let frontierKey = "\(watermark.sourceGeneration)\u{0}\(normalizedSessionID)"
            if let existing = frontierByGenerationAndSession[frontierKey],
               existing.endOffset >= watermark.endOffset {
                continue
            }
            frontierByGenerationAndSession[frontierKey] = watermark
        }
        return Array(frontierByGenerationAndSession.values)
    }

    private func tokenObservationDisposition(
        sessionID: String?,
        totalTokens: Int?,
        updatedAt: Date?,
        cursor: CodexTokenObservationCursor?,
        watermarks: [CodexTokenActivityScanWatermark]
    ) -> TokenObservationDisposition {
        if let cursor {
            let matchingWatermarks = watermarks.filter { watermark in
                guard watermark.sourceGeneration == cursor.sourceGeneration
                else {
                    return false
                }
                if let sessionID {
                    guard watermark.sessionID.map(Self.normalizedLiveTokenSessionID)
                        == Self.normalizedLiveTokenSessionID(sessionID)
                        || watermark.sourceID == cursor.sourceID
                    else {
                        return false
                    }
                }
                return true
            }
            if sessionID != nil,
               matchingWatermarks.contains(where: { watermark in
                   guard watermark.endOffset == .max else { return false }
                   switch sourceSnapshotRelation(watermark: watermark, cursor: cursor) {
                   case .same, .lhsNewer, .legacy:
                       return true
                   case .lhsOlder, .incomparable:
                       return false
                   }
               }) {
                return .rejected
            }
            let isCovered = matchingWatermarks.contains { watermark in
                guard watermark.endOffset != .max else { return false }
                let isExactLine = watermark.endOffset == cursor.endOffset
                    && watermark.lineFingerprint == cursor.lineFingerprint
                switch sourceSnapshotRelation(watermark: watermark, cursor: cursor) {
                case .lhsNewer:
                    // A complete scan of a later ctime snapshot supersedes any
                    // observation from the older content epoch.
                    return true
                case .lhsOlder, .incomparable:
                    // Do not let an old scan's greater byte offset cross a
                    // same-inode rewrite. An exact line remains valid evidence.
                    return isExactLine
                case .same, .legacy:
                    break
                }
                // Codex moves completed rollouts from `sessions` to
                // `archived_sessions`. The stable device/inode generation and
                // exact line fingerprint survive that rename; the path does not.
                if watermark.endOffset > cursor.endOffset {
                    return true
                }
                return isExactLine
            }
            return isCovered ? .covered : .unmatched
        }

        guard let sessionID, let updatedAt else { return .unmatched }
        let normalizedSessionID = Self.normalizedLiveTokenSessionID(sessionID)
        let isCovered = watermarks.contains { watermark in
            guard watermark.endOffset != .max else { return false }
            guard watermark.sessionID.map(Self.normalizedLiveTokenSessionID) == normalizedSessionID,
                  let watermarkTimestamp = watermark.eventTimestamp
            else {
                return false
            }
            if watermarkTimestamp > updatedAt { return true }
            return watermarkTimestamp == updatedAt
                && totalTokens != nil
                && watermark.totalTokens == totalTokens
        }
        return isCovered ? .covered : .unmatched
    }

    private func sourceSnapshotRelation(
        watermark: CodexTokenActivityScanWatermark,
        cursor: CodexTokenObservationCursor
    ) -> SourceSnapshotRelation {
        Self.sourceSnapshotRelation(
            lhsChangeTimeNanoseconds: watermark.sourceChangeTimeNanoseconds,
            lhsStatFingerprint: watermark.sourceStatFingerprint,
            rhsChangeTimeNanoseconds: cursor.sourceChangeTimeNanoseconds,
            rhsStatFingerprint: cursor.sourceStatFingerprint
        )
    }

    private static func sourceSnapshotRelation(
        lhsChangeTimeNanoseconds: Int64?,
        lhsStatFingerprint: Int64?,
        rhsChangeTimeNanoseconds: Int64?,
        rhsStatFingerprint: Int64?
    ) -> SourceSnapshotRelation {
        if let lhsChangeTimeNanoseconds, let rhsChangeTimeNanoseconds {
            if lhsChangeTimeNanoseconds > rhsChangeTimeNanoseconds { return .lhsNewer }
            if lhsChangeTimeNanoseconds < rhsChangeTimeNanoseconds { return .lhsOlder }
            if let lhsStatFingerprint, let rhsStatFingerprint,
               lhsStatFingerprint != rhsStatFingerprint {
                return .incomparable
            }
            return .same
        }
        if let lhsStatFingerprint, let rhsStatFingerprint {
            return lhsStatFingerprint == rhsStatFingerprint ? .same : .incomparable
        }
        if lhsChangeTimeNanoseconds == nil,
           rhsChangeTimeNanoseconds == nil,
           lhsStatFingerprint == nil,
           rhsStatFingerprint == nil {
            return .legacy
        }
        return .incomparable
    }

    private static func liveTokenCursorIsStaleOrConflicting(
        _ cursor: CodexTokenObservationCursor,
        totalTokens: Int,
        comparedWith previousCursor: CodexTokenObservationCursor,
        previousTotalTokens: Int
    ) -> Bool {
        let relation = sourceSnapshotRelation(
            lhsChangeTimeNanoseconds: cursor.sourceChangeTimeNanoseconds,
            lhsStatFingerprint: cursor.sourceStatFingerprint,
            rhsChangeTimeNanoseconds: previousCursor.sourceChangeTimeNanoseconds,
            rhsStatFingerprint: previousCursor.sourceStatFingerprint
        )
        switch relation {
        case .lhsOlder:
            return true
        case .lhsNewer:
            return false
        case .same, .legacy:
            return cursor.endOffset < previousCursor.endOffset
                || (cursor.endOffset == previousCursor.endOffset
                    && (cursor.lineFingerprint != previousCursor.lineFingerprint
                        || totalTokens != previousTotalTokens))
        case .incomparable:
            // A lower offset may be the first complete line of a rewritten
            // content epoch. Only an exact-offset conflict is certainly stale.
            return cursor.endOffset == previousCursor.endOffset
                && (cursor.lineFingerprint != previousCursor.lineFingerprint
                    || totalTokens != previousTotalTokens)
        }
    }

    private func authoritativeLiveTokenFrontier(
        sessionID: String?,
        cursor: CodexTokenObservationCursor?,
        watermarks: [CodexTokenActivityScanWatermark]
    ) -> CodexTokenActivityScanWatermark? {
        guard let sessionID else { return nil }
        let normalizedSessionID = Self.normalizedLiveTokenSessionID(sessionID)
        let numeric = watermarks.filter { watermark in
            watermark.endOffset != .max
                && watermark.totalTokens != nil
                && (watermark.sessionID.map(Self.normalizedLiveTokenSessionID) == normalizedSessionID
                    || cursor.map {
                        watermark.sourceGeneration == $0.sourceGeneration && watermark.sourceID == $0.sourceID
                    } == true)
        }
        let sameGeneration = cursor.map { cursor in
            numeric.filter { $0.sourceGeneration == cursor.sourceGeneration }
        } ?? []
        let candidates = sameGeneration.isEmpty ? numeric : sameGeneration
        return candidates.max { lhs, rhs in
            if lhs.sourceGeneration == rhs.sourceGeneration {
                switch Self.sourceSnapshotRelation(
                    lhsChangeTimeNanoseconds: lhs.sourceChangeTimeNanoseconds,
                    lhsStatFingerprint: lhs.sourceStatFingerprint,
                    rhsChangeTimeNanoseconds: rhs.sourceChangeTimeNanoseconds,
                    rhsStatFingerprint: rhs.sourceStatFingerprint
                ) {
                case .lhsOlder:
                    return true
                case .lhsNewer:
                    return false
                case .same, .legacy:
                    if lhs.endOffset != rhs.endOffset {
                        return lhs.endOffset < rhs.endOffset
                    }
                case .incomparable:
                    break
                }
            }
            let lhsDate = lhs.eventTimestamp ?? .distantPast
            let rhsDate = rhs.eventTimestamp ?? .distantPast
            if lhsDate != rhsDate { return lhsDate < rhsDate }
            if lhs.sourceGeneration == rhs.sourceGeneration,
               lhs.endOffset != rhs.endOffset {
                return lhs.endOffset < rhs.endOffset
            }
            return lhs.sourceID < rhs.sourceID
        }
    }

    private func liveTokenCounterState(
        sessionID: String?,
        frontier: CodexTokenActivityScanWatermark,
        fallbackDate: Date
    ) -> LiveTokenCounterState {
        let totalTokens = max(0, frontier.totalTokens ?? 0)
        let observedAt = frontier.eventTimestamp ?? fallbackDate
        return LiveTokenCounterState(
            sessionID: sessionID,
            totalTokens: totalTokens,
            scannedBaseline: totalTokens,
            day: Calendar.current.startOfDay(for: observedAt),
            updatedAt: frontier.eventTimestamp,
            observationCursor: CodexTokenObservationCursor(
                sourceID: frontier.sourceID,
                sourceGeneration: frontier.sourceGeneration,
                sourceStatFingerprint: frontier.sourceStatFingerprint,
                sourceChangeTimeNanoseconds: frontier.sourceChangeTimeNanoseconds,
                endOffset: frontier.endOffset,
                lineFingerprint: frontier.lineFingerprint
            )
        )
    }

    private func scannedNumericBaselineForUncoveredObservation(
        sessionID: String?,
        totalTokens: Int,
        cursor: CodexTokenObservationCursor?,
        watermarks: [CodexTokenActivityScanWatermark]
    ) -> Int? {
        guard let cursor,
              let frontier = authoritativeLiveTokenFrontier(
                  sessionID: sessionID,
                  cursor: cursor,
                  watermarks: watermarks
              ),
              let frontierTotal = frontier.totalTokens,
              totalTokens >= frontierTotal
        else { return nil }
        let normalizedSessionID = sessionID.map(Self.normalizedLiveTokenSessionID)
        let generationHasScannedPrefix = watermarks.contains { watermark in
            guard watermark.endOffset != .max,
                  watermark.sourceGeneration == cursor.sourceGeneration,
                  watermark.endOffset < cursor.endOffset
            else { return false }
            guard let normalizedSessionID else { return true }
            return watermark.sessionID.map(Self.normalizedLiveTokenSessionID) == normalizedSessionID
        }
        return generationHasScannedPrefix ? max(0, frontierTotal) : nil
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

    var isCodexCookieControlEnabled: Bool {
        codexUsageDataSource.resolvedSelectableValue == .automatic
    }

    private func codexFetchErrorMessage(_ error: Error) -> String {
        guard let fetchError = error as? CodexRateLimitFetchError else {
            return error.localizedDescription
        }
        switch fetchError {
        case .missingCredentials:
            return text(
                "没有可用的 Codex 凭据，请先登录 Codex。",
                "Codex credentials are unavailable. Sign in to Codex and try again."
            )
        case .invalidCredentials:
            return text(
                "保存的 Codex 凭据无效，请重新登录。",
                "The saved Codex credentials are invalid. Sign in again and retry."
            )
        case .invalidCookieHeader:
            return text(
                "OpenAI Cookie 标头为空或格式无效。",
                "The OpenAI Cookie header is empty or invalid."
            )
        case .cookieUnavailable:
            return text(
                "没有找到与当前 Codex 账号匹配的浏览器 Cookie。",
                "No usable browser Cookie was found for the selected Codex account."
            )
        case .cookieAccountMismatch:
            return text(
                "OpenAI Cookie 与当前选择的 Codex 账号不匹配。",
                "The OpenAI Cookie does not match the selected Codex account."
            )
        case .invalidResponse:
            return text(
                "Codex 返回了无效的用量数据。",
                "Codex returned an invalid usage response."
            )
        case .unauthorized:
            return text(
                "Codex 拒绝了当前凭据，请重新登录。",
                "Codex rejected the saved credentials. Sign in again and retry."
            )
        case .oauthCredentialsRequired:
            return text(
                "限额重置额度需要 Codex OAuth 登录。",
                "Limit reset credits require Codex OAuth credentials."
            )
        case .refreshFailed:
            return text(
                "暂时无法刷新 Codex OAuth 凭据，将保留缓存数据。",
                "Codex OAuth credentials could not be refreshed right now. Cached data is retained."
            )
        case .refreshRejected:
            return text(
                "Codex 已拒绝 OAuth 刷新令牌，请重新登录。",
                "Codex rejected the OAuth refresh token. Sign in again and retry."
            )
        case .credentialsChanged:
            return text(
                "刷新期间 Codex 账号已切换，将使用当前账号重新获取。",
                "The Codex account changed during refresh. Usage will be fetched again for the current account."
            )
        case let .serverError(statusCode):
            return text(
                "Codex 用量请求失败（HTTP \(statusCode)）。",
                "Codex usage request failed with HTTP status \(statusCode)."
            )
        case .noRateLimits:
            return text(
                "此账号没有返回限额数据。",
                "Codex did not return rate-limit data for this account."
            )
        }
    }

    private func shouldRetainCodexUsageCache(after error: Error) -> Bool {
        guard let fetchError = error as? CodexRateLimitFetchError else {
            return true
        }
        switch fetchError {
        case .missingCredentials, .invalidCredentials, .unauthorized,
             .cookieAccountMismatch, .refreshRejected:
            return false
        case .invalidCookieHeader, .cookieUnavailable, .invalidResponse,
             .oauthCredentialsRequired, .refreshFailed, .credentialsChanged,
             .serverError, .noRateLimits:
            return true
        }
    }

    private func shouldRetainCodexResetCreditsCache(after error: Error) -> Bool {
        guard let fetchError = error as? CodexRateLimitFetchError else {
            return true
        }
        switch fetchError {
        case .missingCredentials, .invalidCredentials, .unauthorized,
             .cookieAccountMismatch, .oauthCredentialsRequired, .refreshRejected:
            return false
        case .invalidCookieHeader, .cookieUnavailable, .invalidResponse,
             .refreshFailed, .credentialsChanged, .serverError, .noRateLimits:
            return true
        }
    }

    private func isCurrentCodexUsageRefresh(
        generation: Int,
        accountKey: String?,
        authFingerprint: String?,
        accountScopeID: UUID?
    ) -> Bool {
        codexUsageRefreshGeneration == generation
            && activeCodexUsageRefreshGeneration == generation
            && codexCurrentAccount?.usageSnapshotKey == accountKey
            && codexCurrentAccount?.authFingerprint == authFingerprint
            && codexActiveSavedAccountID == accountScopeID
    }

    private func invalidateCodexUsageRefresh() {
        codexUsageRefreshGeneration += 1
        lastCodexRateLimitFetchAt = nil
        codexUsageRefreshTask?.cancel()
    }

    private func finishCodexUsageRefresh(generation: Int) {
        guard activeCodexUsageRefreshGeneration == generation else { return }
        activeCodexUsageRefreshGeneration = nil
        codexUsageRefreshTask = nil
        isCodexRateLimitFetchInFlight = false

        let shouldRunPendingRefresh = codexUsageRefreshPending
        codexUsageRefreshPending = false
        if shouldRunPendingRefresh,
           isCodexDesktopMonitoringEnabled,
           !isMonitoringPaused {
            pollCodexRateLimitsIfNeeded(force: true)
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
        if activeCodexUsageRefreshGeneration != nil {
            if force {
                codexUsageRefreshPending = true
            }
            return
        }

        isCodexRateLimitFetchInFlight = true
        lastCodexRateLimitFetchAt = now
        codexUsageRefreshGeneration += 1
        let refreshGeneration = codexUsageRefreshGeneration
        activeCodexUsageRefreshGeneration = refreshGeneration
        codexUsageRefreshPending = false
        let expectedAccountKey = codexCurrentAccount?.usageSnapshotKey
        let expectedAccountFingerprint = codexCurrentAccount?.authFingerprint
        let expectedAccountScopeID = codexActiveSavedAccountID
        let fetchRoute = codexRateLimitFetchRoute()
        let fetcher = codexRateLimitFetcher
        let store = store

        codexUsageRefreshTask = Task(priority: .utility) { [fetcher, store, fetchRoute, weak self] in
            guard let self else { return }
            defer {
                self.finishCodexUsageRefresh(generation: refreshGeneration)
            }
            let usageAttemptedAt = Date()
            let usageStatus: CodexUsageStatus
            do {
                let fetchedUsageStatus = try await fetcher.fetchUsageStatus(
                    route: fetchRoute,
                    expectedAuthFingerprint: expectedAccountFingerprint
                )
                try fetcher.validateActiveAuthFingerprint(
                    fetchedUsageStatus.authFingerprint
                )
                usageStatus = fetchedUsageStatus
            } catch {
                guard self.isCurrentCodexUsageRefresh(
                    generation: refreshGeneration,
                    accountKey: expectedAccountKey,
                    authFingerprint: expectedAccountFingerprint,
                    accountScopeID: expectedAccountScopeID)
                else {
                    return
                }
                guard self.isCodexDesktopMonitoringEnabled,
                      !self.isMonitoringPaused
                else {
                    return
                }
                if let fetchError = error as? CodexRateLimitFetchError,
                   case .credentialsChanged = fetchError {
                    do {
                        self.applyCodexAccountState(try self.codexAccountManager.loadMetadataState())
                        self.prepareCodexUsageAfterAccountChange()
                        self.codexUsageRefreshPending = true
                        return
                    } catch {
                        // Fall through and surface the original refresh error.
                    }
                }
                let previousState = self.codexUsageFetchState
                let retainsCachedUsage = self.shouldRetainCodexUsageCache(after: error)
                if !retainsCachedUsage {
                    self.clearLatestAgentQuotaCache()
                }
                self.codexUsageFetchState = CodexUsageFetchState(
                    source: retainsCachedUsage ? previousState?.source : nil,
                    lastSuccessfulAt: retainsCachedUsage ? previousState?.lastSuccessfulAt : nil,
                    lastAttemptedAt: usageAttemptedAt,
                    errorMessage: self.codexFetchErrorMessage(error),
                    isStale: retainsCachedUsage && self.latestAgentQuota != nil
                )
                self.persistCodexUsageSnapshotForCurrentAccount()
                return
            }

            guard self.isCurrentCodexUsageRefresh(
                generation: refreshGeneration,
                accountKey: expectedAccountKey,
                authFingerprint: expectedAccountFingerprint,
                accountScopeID: expectedAccountScopeID)
            else {
                return
            }
            guard self.isCodexDesktopMonitoringEnabled,
                  !self.isMonitoringPaused
            else {
                return
            }

            let quota = usageStatus.quota.attributed(to: expectedAccountScopeID)
            self.codexUsageFetchState = CodexUsageFetchState(
                source: usageStatus.source,
                lastSuccessfulAt: quota.updatedAt,
                lastAttemptedAt: usageAttemptedAt,
                errorMessage: nil,
                isStale: false
            )
            self.updateLatestAgentQuota(quota)
            self.latestCodexCredits = usageStatus.credits
            self.persistCodexUsageSnapshotForCurrentAccount()

            do {
                let snapshot = try store.applySessionQuota(
                    quota,
                    sessionID: "codex-rate-limits",
                    agent: "Codex",
                    updatedAt: quota.updatedAt
                )
                self.snapshot = snapshot
            } catch {
                self.lastError = self.text(
                    "用量已获取，但无法更新本地状态：\(error.localizedDescription)",
                    "Usage was fetched, but local state could not be updated: \(error.localizedDescription)"
                )
            }

            let resetCreditsAttemptedAt = Date()
            do {
                let resetCredits = try await fetcher.fetchRateLimitResetCredits(
                    expectedAuthFingerprint: usageStatus.authFingerprint
                )
                try fetcher.validateActiveAuthFingerprint(
                    usageStatus.authFingerprint
                )
                guard self.isCurrentCodexUsageRefresh(
                    generation: refreshGeneration,
                    accountKey: expectedAccountKey,
                    authFingerprint: expectedAccountFingerprint,
                    accountScopeID: expectedAccountScopeID)
                else {
                    return
                }
                guard self.isCodexDesktopMonitoringEnabled,
                      !self.isMonitoringPaused
                else {
                    return
                }
                self.latestCodexResetCredits = resetCredits
                self.codexResetCreditsFetchState = CodexResetCreditsFetchState(
                    lastSuccessfulAt: resetCredits.updatedAt,
                    lastAttemptedAt: resetCreditsAttemptedAt,
                    errorMessage: nil,
                    isStale: false
                )
                self.persistCodexUsageSnapshotForCurrentAccount()
            } catch {
                guard self.isCurrentCodexUsageRefresh(
                    generation: refreshGeneration,
                    accountKey: expectedAccountKey,
                    authFingerprint: expectedAccountFingerprint,
                    accountScopeID: expectedAccountScopeID)
                else {
                    return
                }
                guard self.isCodexDesktopMonitoringEnabled,
                      !self.isMonitoringPaused
                else {
                    return
                }
                if let fetchError = error as? CodexRateLimitFetchError,
                   case .credentialsChanged = fetchError {
                    do {
                        self.applyCodexAccountState(try self.codexAccountManager.loadMetadataState())
                        self.prepareCodexUsageAfterAccountChange()
                        self.codexUsageRefreshPending = true
                        return
                    } catch {
                        // Fall through and surface the original refresh error.
                    }
                }
                let previousState = self.codexResetCreditsFetchState
                let retainsCachedCredits = self.shouldRetainCodexResetCreditsCache(after: error)
                if !retainsCachedCredits {
                    self.latestCodexResetCredits = nil
                }
                self.codexResetCreditsFetchState = CodexResetCreditsFetchState(
                    lastSuccessfulAt: retainsCachedCredits ? previousState?.lastSuccessfulAt : nil,
                    lastAttemptedAt: resetCreditsAttemptedAt,
                    errorMessage: self.codexFetchErrorMessage(error),
                    isStale: retainsCachedCredits && self.latestCodexResetCredits != nil
                )
                self.persistCodexUsageSnapshotForCurrentAccount()
            }
            do {
                let accountState = try self.codexAccountManager.loadMetadataState()
                let authChangedDuringRefresh = accountState.currentAccount?.authFingerprint
                    != usageStatus.authFingerprint
                self.applyCodexAccountState(accountState)
                if authChangedDuringRefresh {
                    self.prepareCodexUsageAfterAccountChange()
                    self.codexUsageRefreshPending = true
                    return
                }
                self.codexAccountMessage = nil
                self.isCodexAccountMessageError = false
            } catch {
                self.codexAccountMessage = error.localizedDescription
                self.isCodexAccountMessageError = true
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

        if ActivityPresentation.isPresenceOnlySession(session) {
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

    private func updateLatestAgentQuota(
        from snapshot: SignalSnapshot,
        appliesTokenUsage: Bool = true
    ) {
        if shouldApplyLocalCodexQuotaUpdates,
           let quota = Self.latestQuota(in: snapshot),
           Self.latestQuota(quota, isNewerThan: latestAgentQuota) {
            updateLatestAgentQuota(quota)
        }

        guard appliesTokenUsage else { return }
        let observations = Self.tokenUsageObservations(in: snapshot)
        if observations.isEmpty,
           let tokenUsage = latestAgentQuota?.tokenUsage,
           shouldApplyReplayedTokenObservation(
               sessionID: nil,
               updatedAt: latestAgentQuota?.updatedAt
           ) {
            updateLatestAgentTokenUsage(
                tokenUsage,
                sessionID: nil,
                updatedAt: latestAgentQuota?.updatedAt
            )
        } else {
            for observation in observations where shouldApplyReplayedTokenObservation(
                sessionID: observation.sessionID,
                updatedAt: observation.updatedAt
            ) {
                updateLatestAgentTokenUsage(
                    observation.usage,
                    sessionID: observation.sessionID,
                    updatedAt: observation.updatedAt
                )
            }
        }
    }

    private func shouldApplyReplayedTokenObservation(
        sessionID: String?,
        updatedAt: Date?,
        observationCursor: CodexTokenObservationCursor? = nil
    ) -> Bool {
        // JSONL token activity is device-local and cannot be assigned to the
        // selected saved account. Account activation therefore must not form a
        // token boundary. Exact source evidence or a known device counter is
        // sufficient; cursor-less replay still needs app-lifetime freshness.
        if liveTokenCounters[Self.liveTokenSessionKey(sessionID)] != nil
            || observationCursor != nil {
            return true
        }
        guard let startedAt = codexDeviceObservationStartedAt,
              let updatedAt
        else {
            return false
        }
        return updatedAt >= startedAt
    }

    private func shouldApplyLocalQuotaObservation(updatedAt: Date) -> Bool {
        guard codexCurrentAccount != nil else { return true }
        guard let startedAt = codexAccountObservationStartedAt else { return false }
        return updatedAt >= startedAt
    }

    @discardableResult
    func updateLatestLocalQuotaObservation(
        _ update: CodexDesktopQuotaUpdate
    ) -> Bool {
        guard let current = latestLocalAgentQuotaObservation else {
            latestLocalAgentQuotaObservation = update.quota
            latestLocalAgentQuotaObservationCursor = update.tokenObservationCursor
            return true
        }

        let shouldReplace: Bool
        if let candidateCursor = update.tokenObservationCursor,
           let currentCursor = latestLocalAgentQuotaObservationCursor,
           candidateCursor.sourceGeneration == currentCursor.sourceGeneration {
            switch Self.sourceSnapshotRelation(
                lhsChangeTimeNanoseconds: candidateCursor.sourceChangeTimeNanoseconds,
                lhsStatFingerprint: candidateCursor.sourceStatFingerprint,
                rhsChangeTimeNanoseconds: currentCursor.sourceChangeTimeNanoseconds,
                rhsStatFingerprint: currentCursor.sourceStatFingerprint
            ) {
            case .lhsNewer:
                shouldReplace = true
            case .lhsOlder:
                shouldReplace = false
            case .same, .legacy:
                // The JSONL byte frontier is authoritative within one content
                // snapshot, even when the later line carries an earlier event
                // timestamp because clocks or event delivery are reordered.
                shouldReplace = candidateCursor.endOffset > currentCursor.endOffset
            case .incomparable:
                shouldReplace = update.quota.updatedAt >= current.updatedAt
            }
        } else {
            shouldReplace = update.quota.updatedAt >= current.updatedAt
        }

        guard shouldReplace else { return false }
        latestLocalAgentQuotaObservation = update.quota
        latestLocalAgentQuotaObservationCursor = update.tokenObservationCursor
        return true
    }

    private func updateLatestAgentQuota(_ quota: AgentQuotaStatus) {
        latestAgentQuota = quota
        Self.cacheLatestAgentQuota(quota, userDefaults: userDefaults)
        persistCodexUsageSnapshotForCurrentAccount()
    }

    private var shouldApplyLocalCodexQuotaUpdates: Bool {
        codexUsageDataSource == .cliRPCPTY
    }

    private func clearLatestAgentQuotaCache() {
        latestAgentQuota = nil
        latestCodexCredits = nil
        latestCodexResetCredits = nil
        codexUsageFetchState = nil
        codexResetCreditsFetchState = nil
        userDefaults.removeObject(forKey: Self.cachedLatestAgentQuotaKey)
    }

    private func clearLatestAgentTokenUsageCache() {
        latestAgentTokenUsage = nil
        latestAgentTokenUsageSessionID = nil
        latestAgentTokenUsageUpdatedAt = nil
        liveTokenCounters.removeAll()
        unscannedLiveTokenCarries.removeAll()
        legacyUnscopedTokenFloor = nil
        liveTokenUsageScanCutoff = nil
        liveTokenScanWatermarks.removeAll()
        recentExactLiveTokenObservationSignatures.removeAll()
        liveTokenUsageRevision &+= 1
        userDefaults.removeObject(forKey: Self.cachedLatestAgentTokenUsageKey)
    }

    private func clearTokenActivityCache() {
        tokenActivityDays = []
        hasCompletedTokenActivityScan = false
        tokenActivityIssue = nil
        tokenActivityIsPartial = false
        tokenActivityExcludedSessionCount = nil
        lastTokenActivityScanAt = nil
        isTokenActivityLoading = false
    }

    private func invalidateTokenActivityScan() {
        tokenActivityScanGeneration &+= 1
        isTokenActivityScanInFlight = false
        isTokenActivityLoading = false
        tokenActivityScanRetryPending = false
        tokenActivityScanRetryAttempt = 0
        lastTokenActivityScanAt = nil
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
        return "quota id=\(quota.limitID ?? "--") name=\(quota.limitName ?? "--") source=\(quota.source?.rawValue ?? "--") window=\(quota.windowMinutes.map(String.init) ?? "--")m remaining=\(Int(quota.remainingPercent.rounded()))% resets=\(reset)"
    }

    private func prepareCodexUsageAfterAccountChange() {
        invalidateCodexUsageRefresh()
        codexUsageRefreshPending = false
        invalidateCodexProviderDetailsRefresh()
        invalidateCodexLiveObservationContext()
        latestLocalAgentQuotaObservation = nil
        latestLocalAgentQuotaObservationCursor = nil
        clearLatestAgentQuotaCache()
        hydrateCodexUsageSnapshotForCurrentAccount()
    }

    private func invalidateCodexProviderDetailsRefresh() {
        codexProviderDetailsRefreshGeneration &+= 1
        isCodexProviderDetailsLoading = false
        codexProviderAccountEmail = nil
        codexProviderPlanName = nil
        codexProviderDetailsCheckedAt = nil
    }

    private func invalidateCodexLiveObservationContext() {
        codexLiveObservationGeneration &+= 1
        codexAccountObservationStartedAt = nowProvider()
    }

    private func invalidateCodexDevicePollContext() {
        codexDevicePollGeneration &+= 1
        codexDeviceObservationStartedAt = nowProvider()
    }

    private func codexDeviceTokenActivityScanner() -> any CodexTokenActivityScanning {
        codexTokenActivityScanner
    }

    private func hydrateCodexUsageSnapshotForCurrentAccount() {
        guard let account = codexCurrentAccount,
              let snapshot = codexUsageSnapshotStore.snapshot(for: account)
        else {
            return
        }

        latestAgentQuota = snapshot.quota?.attributed(
            to: codexActiveSavedAccountID,
            source: snapshot.quota?.source
                ?? snapshot.usageFetchState?.source?.agentQuotaSource
        )
        latestCodexCredits = snapshot.credits
        latestCodexResetCredits = snapshot.resetCredits
        codexUsageFetchState = snapshot.usageFetchState
        codexResetCreditsFetchState = snapshot.resetCreditsFetchState
        let now = nowProvider()
        if latestAgentQuota != nil,
           let lastSuccessfulAt = codexUsageFetchState?.lastSuccessfulAt,
           now.timeIntervalSince(lastSuccessfulAt) >= Self.codexRateLimitRefreshInterval {
            codexUsageFetchState?.isStale = true
        }
        if latestCodexResetCredits != nil,
           let lastSuccessfulAt = codexResetCreditsFetchState?.lastSuccessfulAt,
           now.timeIntervalSince(lastSuccessfulAt) >= Self.codexRateLimitRefreshInterval {
            codexResetCreditsFetchState?.isStale = true
        }
    }

    private func hydrateCodexDeviceTokenSnapshot() {
        guard let snapshot = codexUsageSnapshotStore.deviceTokenSnapshot() else {
            return
        }

        let now = nowProvider()
        let hasCompatibleActivityCache =
            snapshot.tokenActivityCacheVersion == CodexTokenActivityScanner.currentCacheVersion
        latestAgentTokenUsage = snapshot.tokenUsage
        tokenActivityDays = hasCompatibleActivityCache ? snapshot.tokenActivityDays : []
        hasCompletedTokenActivityScan = hasCompatibleActivityCache && !snapshot.tokenActivityDays.isEmpty
        tokenActivityExcludedSessionCount = hasCompatibleActivityCache ? snapshot.tokenActivityExcludedSessionCount : nil
        tokenActivityIsPartial = tokenActivityExcludedSessionCount != nil
        tokenActivityIssue = tokenActivityExcludedSessionCount.map { tokenActivityPartialStatusText(excludedCount: $0) }
        liveTokenCounters.removeAll()
        unscannedLiveTokenCarries.removeAll()
        recentExactLiveTokenObservationSignatures.removeAll()
        legacyUnscopedTokenFloor = hasCompatibleActivityCache
            ? snapshot.legacyUnscopedTokenFloor.map {
                LegacyUnscopedTokenFloor(
                    totalTokens: max(0, $0.totalTokens),
                    day: Calendar.current.startOfDay(for: $0.day)
                )
            }
            : nil
        liveTokenUsageScanCutoff = if hasCompatibleActivityCache,
                                      let cutoff = snapshot.liveTokenUsageScanCutoff,
                                      cutoff <= now {
            cutoff
        } else {
            nil
        }
        liveTokenScanWatermarks = hasCompatibleActivityCache
            ? (snapshot.liveTokenScanWatermarks ?? []).map {
                CodexTokenActivityScanWatermark(
                    sessionID: $0.sessionID,
                    sourceID: $0.sourceID,
                    sourceGeneration: $0.sourceGeneration,
                    endOffset: $0.endOffset,
                    lineFingerprint: $0.lineFingerprint,
                    eventTimestamp: $0.eventTimestamp,
                    totalTokens: $0.totalTokens,
                    sourceStatFingerprint: $0.sourceStatFingerprint,
                    sourceChangeTimeNanoseconds: $0.sourceChangeTimeNanoseconds
                )
            }
            : []
        let today = Calendar.current.startOfDay(for: now)
        let startDay = Calendar.current.date(byAdding: .day, value: -29, to: today) ?? today

        if let persistedCounters = snapshot.liveTokenCounters {
            for persisted in persistedCounters {
                let persistedDay = Calendar.current.startOfDay(for: persisted.day)
                guard persistedDay >= startDay, persistedDay <= today else { continue }
                let totalTokens = max(0, persisted.totalTokens)
                // v25 corrects session metadata identity, not byte-cursor
                // semantics. Retain v24 source proof so old root/child labels
                // can be reconciled against their exact file generation.
                let preservesSourceProof = hasCompatibleActivityCache
                    || Self.preservesV24TokenSourceProof(persisted.observationCursor, cacheVersion: snapshot.tokenActivityCacheVersion)
                let persistedObservationCursor = preservesSourceProof
                    ? persisted.observationCursor
                    : nil
                let baseline = hasCompatibleActivityCache
                    ? min(max(0, persisted.scannedBaseline), totalTokens)
                    : 0
                // Snapshot keys are an encoding detail, not identity. Rebuild
                // the canonical key so older ledger schemas cannot coexist with
                // the current session counter and double-count it.
                let key = Self.liveTokenSessionKey(persisted.sessionID)
                let candidate = LiveTokenCounterState(
                    sessionID: persisted.sessionID,
                    totalTokens: totalTokens,
                    scannedBaseline: baseline,
                    day: persistedDay,
                    updatedAt: persisted.updatedAt,
                    observationCursor: persistedObservationCursor
                )
                if let existing = liveTokenCounters[key],
                   Self.isNewerLiveTokenCounter(existing, than: candidate) {
                    continue
                }
                liveTokenCounters[key] = candidate
            }
            for persisted in snapshot.unscannedLiveTokenCarryByDay ?? [] {
                let day = Calendar.current.startOfDay(for: persisted.day)
                guard day >= startDay, day <= today else { continue }
                let persistedObservationCursor = hasCompatibleActivityCache
                    || Self.preservesV24TokenSourceProof(persisted.observationCursor, cacheVersion: snapshot.tokenActivityCacheVersion)
                    ? persisted.observationCursor
                    : nil
                let key = persisted.key ?? Self.liveTokenCarryKey(
                    sessionID: persisted.sessionID,
                    day: day,
                    updatedAt: persisted.updatedAt,
                    cursor: persistedObservationCursor
                )
                let candidate = LiveTokenCarryState(
                    sessionID: persisted.sessionID,
                    totalTokens: max(0, persisted.totalTokens),
                    day: day,
                    updatedAt: persisted.updatedAt,
                    observationCursor: persistedObservationCursor
                )
                if let existing = unscannedLiveTokenCarries[key] {
                    unscannedLiveTokenCarries[key] = LiveTokenCarryState(
                        sessionID: existing.sessionID ?? candidate.sessionID,
                        totalTokens: existing.totalTokens + candidate.totalTokens,
                        day: day,
                        updatedAt: existing.updatedAt ?? candidate.updatedAt,
                        observationCursor: existing.observationCursor ?? candidate.observationCursor
                    )
                } else {
                    unscannedLiveTokenCarries[key] = candidate
                }
            }
        } else if hasCompatibleActivityCache,
                  legacyUnscopedTokenFloor == nil,
                  let liveTotal = latestAgentTokenUsage?.effectiveTotalTokens,
                  let legacyObservationAt = Self.trustedLegacyTokenObservationDate(
                      snapshot: snapshot,
                      now: now
                  ) {
            // A v1 snapshot stored quota.last_token_usage without a session ID.
            // Preserve it only as a per-day display floor. It cannot be added to
            // an aggregate cache or assigned to whichever session replays first.
            let day = Calendar.current.startOfDay(for: legacyObservationAt)
            let cachedTotalForDay = tokenActivityDays
                .filter { Calendar.current.isDate($0.day, inSameDayAs: day) }
                .map { max(0, $0.totalTokens) }
                .reduce(0, +)
            let legacyCarry = max(0, snapshot.unscannedLiveTokenCarry ?? 0)
            let floorTotal: Int
            if let persistedBaseline = snapshot.liveTokenUsageScanBaseline {
                // v2 snapshots recorded exactly how much of the scalar had
                // already reached the daily cache, so only preserve its delta.
                floorTotal = cachedTotalForDay
                    + max(0, liveTotal - max(0, persistedBaseline))
                    + legacyCarry
            } else {
                // Older snapshots did not distinguish a cached scalar from a
                // live supplement. Treat it as a lower bound, while the
                // separately persisted carry remains explicitly additive.
                floorTotal = max(cachedTotalForDay, max(0, liveTotal)) + legacyCarry
            }
            legacyUnscopedTokenFloor = LegacyUnscopedTokenFloor(
                totalTokens: floorTotal,
                day: day
            )
        }

        let newestCounter = liveTokenCounters.values.max(by: {
            ($0.updatedAt ?? .distantPast) < ($1.updatedAt ?? .distantPast)
        })
        if let explicitSessionID = snapshot.tokenUsageSessionID {
            latestAgentTokenUsageSessionID = explicitSessionID
            latestAgentTokenUsageUpdatedAt = snapshot.tokenUsageUpdatedAt
        } else if let newestCounter,
           latestAgentTokenUsage?.effectiveTotalTokens == newestCounter.totalTokens {
            latestAgentTokenUsageSessionID = newestCounter.sessionID
            latestAgentTokenUsageUpdatedAt = newestCounter.updatedAt
        } else {
            latestAgentTokenUsageSessionID = nil
            // `snapshot.updatedAt` is a general file-write timestamp and can
            // come from a newer credits or quota-only refresh. Without token
            // evidence it cannot order later token observations.
            latestAgentTokenUsageUpdatedAt = nil
        }
        if let tokenUsage = latestAgentTokenUsage {
            Self.cacheLatestAgentTokenUsage(tokenUsage, userDefaults: userDefaults)
        }
    }

    private static func preservesV24TokenSourceProof(
        _ cursor: CodexTokenObservationCursor?,
        cacheVersion: Int?
    ) -> Bool {
        // Only a fully identified content epoch survives the parser correction.
        // An older cursor lacking stat/ctime can refer to a same-inode rewrite;
        // preserving it would reject a valid replacement line at the same offset.
        cacheVersion == 24
            && CodexTokenActivityScanner.currentCacheVersion == 25
            && cursor?.sourceStatFingerprint != nil
            && cursor?.sourceChangeTimeNanoseconds != nil
    }

    private func persistCodexUsageSnapshotForCurrentAccount() {
        let counterSnapshots = liveTokenCounters.map { key, state in
            CodexLiveTokenCounterSnapshot(
                key: key,
                sessionID: state.sessionID,
                totalTokens: state.totalTokens,
                scannedBaseline: state.scannedBaseline,
                day: state.day,
                updatedAt: state.updatedAt,
                observationCursor: state.observationCursor
            )
        }
        .sorted { $0.key < $1.key }
        let carrySnapshots = unscannedLiveTokenCarries.map { key, carry in
            CodexLiveTokenCarrySnapshot(
                key: key,
                sessionID: carry.sessionID,
                day: carry.day,
                totalTokens: carry.totalTokens,
                updatedAt: carry.updatedAt,
                observationCursor: carry.observationCursor
            )
        }
        .sorted { ($0.key ?? "") < ($1.key ?? "") }
        let watermarkSnapshots = liveTokenScanWatermarks.map {
            CodexLiveTokenScanWatermarkSnapshot(
                sessionID: $0.sessionID,
                sourceID: $0.sourceID,
                sourceGeneration: $0.sourceGeneration,
                sourceStatFingerprint: $0.sourceStatFingerprint,
                sourceChangeTimeNanoseconds: $0.sourceChangeTimeNanoseconds,
                endOffset: $0.endOffset,
                lineFingerprint: $0.lineFingerprint,
                eventTimestamp: $0.eventTimestamp,
                totalTokens: $0.totalTokens
            )
        }
        let latestCounter = liveTokenCounters[
            Self.liveTokenSessionKey(latestAgentTokenUsageSessionID)
        ]
        let carryTotal = unscannedLiveTokenCarries.values
            .filter { Calendar.current.isDate($0.day, inSameDayAs: nowProvider()) }
            .map(\.totalTokens)
            .reduce(0, +)
        let legacyFloor = legacyUnscopedTokenFloor.map {
            CodexLegacyUnscopedTokenFloorSnapshot(
                totalTokens: $0.totalTokens,
                day: $0.day
            )
        }
        if let account = codexCurrentAccount {
            codexUsageSnapshotStore.store(
                account: account,
                quota: latestAgentQuota,
                credits: latestCodexCredits,
                resetCredits: latestCodexResetCredits,
                usageFetchState: codexUsageFetchState,
                resetCreditsFetchState: codexResetCreditsFetchState,
                tokenUsage: latestAgentTokenUsage,
                tokenUsageSessionID: latestAgentTokenUsageSessionID,
                tokenUsageUpdatedAt: latestAgentTokenUsageUpdatedAt,
                liveTokenUsageScanBaseline: latestCounter?.scannedBaseline,
                unscannedLiveTokenCarry: carryTotal,
                liveTokenCounters: counterSnapshots,
                unscannedLiveTokenCarryByDay: carrySnapshots,
                liveTokenUsageScanCutoff: liveTokenUsageScanCutoff,
                liveTokenScanWatermarks: watermarkSnapshots,
                legacyUnscopedTokenFloor: legacyFloor,
                tokenActivityCacheVersion: CodexTokenActivityScanner.currentCacheVersion,
                tokenActivityDays: tokenActivityDays,
                tokenActivityExcludedSessionCount: tokenActivityExcludedSessionCount
            )
        } else {
            codexUsageSnapshotStore.storeDeviceTokenSnapshot(
                tokenUsage: latestAgentTokenUsage,
                tokenUsageSessionID: latestAgentTokenUsageSessionID,
                tokenUsageUpdatedAt: latestAgentTokenUsageUpdatedAt,
                liveTokenUsageScanBaseline: latestCounter?.scannedBaseline,
                unscannedLiveTokenCarry: carryTotal,
                liveTokenCounters: counterSnapshots,
                unscannedLiveTokenCarryByDay: carrySnapshots,
                liveTokenUsageScanCutoff: liveTokenUsageScanCutoff,
                liveTokenScanWatermarks: watermarkSnapshots,
                legacyUnscopedTokenFloor: legacyFloor,
                tokenActivityCacheVersion: CodexTokenActivityScanner.currentCacheVersion,
                tokenActivityDays: tokenActivityDays,
                tokenActivityExcludedSessionCount: tokenActivityExcludedSessionCount
            )
        }
    }

    @discardableResult
    private func applyCodexAccountState(_ state: CodexAccountState) -> Bool {
        let previousIdentity = codexUsageAccountIdentity(for: codexCurrentAccount)
        let previousActiveSavedAccountID = codexActiveSavedAccountID
        codexCurrentAccount = state.currentAccount
        codexSavedAccounts = state.savedAccounts
        codexActiveSavedAccountID = state.activeSavedAccountID
        return previousIdentity != codexUsageAccountIdentity(for: state.currentAccount)
            || previousActiveSavedAccountID != state.activeSavedAccountID
    }

    private func codexUsageAccountIdentity(
        for account: CodexCurrentAccount?
    ) -> CodexUsageAccountIdentity? {
        account.map {
            CodexUsageAccountIdentity(
                usageSnapshotKey: $0.usageSnapshotKey,
                authFingerprint: $0.authFingerprint
            )
        }
    }

    private static func liveTokenSessionKey(_ sessionID: String?) -> String {
        let normalized = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalized.isEmpty ? unknownLiveTokenSessionKey : normalized
    }

    private static func normalizedLiveTokenSessionID(_ sessionID: String) -> String {
        let normalized = sessionID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let separator = normalized.lastIndex(of: ":") {
            let suffix = normalized[normalized.index(after: separator)...]
            if !suffix.isEmpty { return String(suffix) }
        }
        return normalized
    }

    private func initialLiveTokenBaseline(
        forForkedFromSessionID parentSessionID: String?,
        observedTotal: Int?,
        lastTurnTotal: Int?
    ) -> Int? {
        guard parentSessionID != nil, let observedTotal else { return nil }
        let normalizedTotal = max(0, observedTotal)
        if let lastTurnTotal {
            let normalizedLastTurn = max(0, lastTurnTotal)
            if normalizedLastTurn <= normalizedTotal {
                // A fork's cumulative total includes the parent's state at the
                // instant of the fork. The parent may continue growing before
                // this child line is polled, so its current live total is not a
                // safe inherited baseline. Subtract the child line's own turn
                // delta instead; the remainder is the exact inherited prefix.
                return normalizedTotal - normalizedLastTurn
            }
        }
        // Without a valid last-turn delta, remain conservative and let the
        // authoritative scanner account for the child's first contribution.
        return normalizedTotal
    }

    private static func liveTokenCarryKey(
        sessionID: String?,
        day: Date,
        updatedAt: Date?,
        cursor: CodexTokenObservationCursor?
    ) -> String {
        if let cursor {
            return [
                cursor.sourceID,
                cursor.sourceGeneration,
                String(cursor.endOffset),
                cursor.lineFingerprint,
            ].joined(separator: "|")
        }
        return [
            liveTokenSessionKey(sessionID),
            String(Int64(day.timeIntervalSince1970)),
            String(Int64((updatedAt ?? day).timeIntervalSince1970 * 1_000)),
        ].joined(separator: "|")
    }

    private func preserveUnscannedLiveTokenCarry(
        from state: LiveTokenCounterState,
        totalTokens: Int
    ) {
        let normalizedTotal = max(0, totalTokens)
        guard normalizedTotal > 0 else { return }
        let key = Self.liveTokenCarryKey(
            sessionID: state.sessionID,
            day: state.day,
            updatedAt: state.updatedAt,
            cursor: state.observationCursor
        )
        let candidate = LiveTokenCarryState(
            sessionID: state.sessionID,
            totalTokens: normalizedTotal,
            day: state.day,
            updatedAt: state.updatedAt,
            observationCursor: state.observationCursor
        )
        if let existing = unscannedLiveTokenCarries[key] {
            unscannedLiveTokenCarries[key] = LiveTokenCarryState(
                sessionID: existing.sessionID ?? candidate.sessionID,
                totalTokens: max(existing.totalTokens, candidate.totalTokens),
                day: existing.day,
                updatedAt: existing.updatedAt ?? candidate.updatedAt,
                observationCursor: existing.observationCursor ?? candidate.observationCursor
            )
        } else {
            unscannedLiveTokenCarries[key] = candidate
        }
    }

    private static func isNewerLiveTokenCounter(
        _ existing: LiveTokenCounterState,
        than candidate: LiveTokenCounterState
    ) -> Bool {
        if let existingCursor = existing.observationCursor,
           let candidateCursor = candidate.observationCursor,
           existingCursor.sourceGeneration == candidateCursor.sourceGeneration {
            switch sourceSnapshotRelation(
                lhsChangeTimeNanoseconds: existingCursor.sourceChangeTimeNanoseconds,
                lhsStatFingerprint: existingCursor.sourceStatFingerprint,
                rhsChangeTimeNanoseconds: candidateCursor.sourceChangeTimeNanoseconds,
                rhsStatFingerprint: candidateCursor.sourceStatFingerprint
            ) {
            case .lhsNewer:
                return true
            case .lhsOlder:
                return false
            case .same, .legacy:
                if existingCursor.endOffset != candidateCursor.endOffset {
                    return existingCursor.endOffset > candidateCursor.endOffset
                }
            case .incomparable:
                break
            }
        }
        return (existing.updatedAt ?? .distantPast) > (candidate.updatedAt ?? .distantPast)
    }

    private func rememberExactLiveTokenObservation(
        key: String,
        usage: AgentTokenUsage,
        updatedAt: Date?
    ) {
        guard let updatedAt else { return }
        let signature = ExactLiveTokenObservationSignature(
            usage: usage,
            stateFileTimestampSecond: Self.stateFileTimestampSecond(updatedAt)
        )
        var signatures = recentExactLiveTokenObservationSignatures[key] ?? []
        signatures.removeAll { $0 == signature }
        signatures.append(signature)
        recentExactLiveTokenObservationSignatures[key] = signatures
    }

    private func isKnownCursorlessShadow(
        key: String,
        usage: AgentTokenUsage,
        updatedAt: Date?
    ) -> Bool {
        guard let updatedAt else { return false }
        return recentExactLiveTokenObservationSignatures[key]?.contains(
            ExactLiveTokenObservationSignature(
                usage: usage,
                stateFileTimestampSecond: Self.stateFileTimestampSecond(updatedAt)
            )
        ) == true
    }

    private static func stateFileTimestampSecond(_ date: Date) -> Int64 {
        // SignalStateStore encodes Date with JSONEncoder's `.iso8601`
        // strategy, which omits fractional seconds. Compare shadows at the
        // same precision they have after the state-file round trip.
        Int64(date.timeIntervalSince1970.rounded(.down))
    }

    private func pruneExactLiveTokenObservationSignaturesAfterReload() {
        var retainedKeys = Set(liveTokenCounters.keys)
        retainedKeys.formUnion(
            unscannedLiveTokenCarries.values.map {
                Self.liveTokenSessionKey($0.sessionID)
            }
        )
        retainedKeys.formUnion(
            Self.tokenUsageObservations(in: snapshot).map {
                Self.liveTokenSessionKey($0.sessionID)
            }
        )
        recentExactLiveTokenObservationSignatures =
            recentExactLiveTokenObservationSignatures.reduce(into: [:]) { result, entry in
                guard retainedKeys.contains(entry.key), let latest = entry.value.last else { return }
                result[entry.key] = [latest]
            }
    }

    private static func trustedLegacyTokenObservationDate(
        snapshot: CodexDeviceTokenUsageSnapshot,
        now: Date
    ) -> Date? {
        if let tokenUsageUpdatedAt = snapshot.tokenUsageUpdatedAt,
           tokenUsageUpdatedAt <= now.addingTimeInterval(60) {
            return tokenUsageUpdatedAt
        }

        // `snapshot.updatedAt` is normally just the file write time and can be
        // changed by an unrelated credits refresh. Use it only as a narrowly
        // scoped same-session migration hint while it is still fresh.
        let age = now.timeIntervalSince(snapshot.updatedAt)
        guard age >= -60,
              age <= 10 * 60,
              Calendar.current.isDate(snapshot.updatedAt, inSameDayAs: now)
        else {
            return nil
        }
        return snapshot.updatedAt
    }

    func updateLatestAgentTokenUsage(
        _ usage: AgentTokenUsage,
        sessionID: String? = nil,
        updatedAt: Date? = nil,
        observationCursor: CodexTokenObservationCursor? = nil,
        stateShadowUsage: AgentTokenUsage? = nil,
        initialScannedBaseline: Int? = nil
    ) {
        let key = Self.liveTokenSessionKey(sessionID)
        let observationDate = updatedAt ?? nowProvider()
        let observationDay = Calendar.current.startOfDay(for: observationDate)
        var didChangeTokenAccounting = false
        var rejectedStaleObservation = false
        var acceptedSourceOrderIsNewer = false
        var acceptedObservationMatchesCounter = false

        if let totalTokens = usage.effectiveTotalTokens {
            let normalizedTotal = max(0, totalTokens)
            let observationDisposition = tokenObservationDisposition(
                sessionID: sessionID,
                totalTokens: normalizedTotal,
                updatedAt: updatedAt,
                cursor: observationCursor,
                watermarks: liveTokenScanWatermarks
            )
            if observationCursor != nil, let stateShadowUsage {
                // The state-file watcher can replay the cursor-less copy of an
                // exact desktop observation after a newer file snapshot. Record
                // the copy even when a quarantine watermark rejects its cursor:
                // the poll has already written the cursor-less value to disk.
                rememberExactLiveTokenObservation(
                    key: key,
                    usage: stateShadowUsage,
                    updatedAt: updatedAt
                )
            }
            // A persisted quarantine tombstone is a rejection, not proof that
            // the divergent counter belongs in the scanned baseline.
            if observationDisposition == .rejected { return }
            if observationCursor == nil,
               isKnownCursorlessShadow(
                   key: key,
                   usage: usage,
                   updatedAt: updatedAt
               ) {
                // Reject only a cursor-less SignalState value already observed
                // with exact source evidence. Genuinely new cursor-less growth
                // and counter resets remain usable.
                return
            }
            let authoritativeFrontier = authoritativeLiveTokenFrontier(
                sessionID: sessionID,
                cursor: observationCursor,
                watermarks: liveTokenScanWatermarks
            )

            // Old scalar snapshots used quota.last_token_usage and had no
            // session identity. They are suitable only as a temporary display
            // value: assigning one to the first file replayed can attach a newer
            // session's scalar to an older session and permanently double-count
            // the real owner. Replace the provisional value with the first
            // identified cumulative counter instead of migrating it.
            if key != Self.unknownLiveTokenSessionKey,
               liveTokenCounters[key] == nil,
               liveTokenCounters.keys.allSatisfy({ $0 == Self.unknownLiveTokenSessionKey }) {
                liveTokenCounters.removeValue(forKey: Self.unknownLiveTokenSessionKey)
                unscannedLiveTokenCarries = unscannedLiveTokenCarries.filter { _, carry in
                    carry.sessionID != nil
                }
            }

            let isCoveredByCommittedScan = observationDisposition == .covered
            if var state = liveTokenCounters[key] {
                let sameGenerationSnapshotRelation: SourceSnapshotRelation? = {
                    guard let previousCursor = state.observationCursor,
                          let observationCursor,
                          previousCursor.sourceGeneration == observationCursor.sourceGeneration
                    else { return nil }
                    return Self.sourceSnapshotRelation(
                        lhsChangeTimeNanoseconds: observationCursor.sourceChangeTimeNanoseconds,
                        lhsStatFingerprint: observationCursor.sourceStatFingerprint,
                        rhsChangeTimeNanoseconds: previousCursor.sourceChangeTimeNanoseconds,
                        rhsStatFingerprint: previousCursor.sourceStatFingerprint
                    )
                }()
                let sameGenerationCursorIsStaleOrConflicting: Bool = {
                    guard let previousCursor = state.observationCursor,
                          let observationCursor,
                          previousCursor.sourceGeneration == observationCursor.sourceGeneration
                    else { return false }
                    return Self.liveTokenCursorIsStaleOrConflicting(
                        observationCursor,
                        totalTokens: normalizedTotal,
                        comparedWith: previousCursor,
                        previousTotalTokens: state.totalTokens
                    )
                }()
                let sameSnapshotCursorMovedForward: Bool = {
                    guard sameGenerationSnapshotRelation == .same
                            || sameGenerationSnapshotRelation == .legacy,
                          let previousCursor = state.observationCursor,
                          let observationCursor
                    else { return false }
                    return observationCursor.endOffset > previousCursor.endOffset
                }()
                let exactCursorSupersedesCursorlessSameSecond: Bool = {
                    guard state.observationCursor == nil,
                          observationCursor != nil,
                          normalizedTotal >= state.totalTokens,
                          let previousUpdatedAt = state.updatedAt,
                          let updatedAt
                    else {
                        return false
                    }
                    // JSONL timestamps carry milliseconds while SignalState
                    // shadows can be rounded to whole seconds. Exact source
                    // evidence for non-decreasing cumulative usage must win
                    // within that shared second, or a delayed poll can be
                    // discarded solely because of serialization precision.
                    return Self.stateFileTimestampSecond(previousUpdatedAt)
                        == Self.stateFileTimestampSecond(updatedAt)
                }()
                let cursorlessRegressionConflictsWithExactSameSecond: Bool = {
                    guard state.observationCursor != nil,
                          observationCursor == nil,
                          normalizedTotal < state.totalTokens,
                          let previousUpdatedAt = state.updatedAt,
                          let updatedAt
                    else {
                        return false
                    }
                    // The inverse precision race is a cursor-less SignalState
                    // shadow that looks fractionally newer while carrying a
                    // lower cumulative value. It cannot override exact JSONL
                    // evidence within the same serialized second.
                    return Self.stateFileTimestampSecond(previousUpdatedAt)
                        == Self.stateFileTimestampSecond(updatedAt)
                }()
                let sourceOrderIsNewer = sameGenerationSnapshotRelation == .lhsNewer
                    || sameSnapshotCursorMovedForward
                    || exactCursorSupersedesCursorlessSameSecond
                let sourceOrderIsOlder = sameGenerationSnapshotRelation == .lhsOlder
                    || ((sameGenerationSnapshotRelation == .same
                            || sameGenerationSnapshotRelation == .legacy)
                        && sameGenerationCursorIsStaleOrConflicting)
                    || cursorlessRegressionConflictsWithExactSameSecond

                if sourceOrderIsOlder {
                    // Within one device/inode generation, content-snapshot order
                    // comes first; within one snapshot, JSONL byte order comes
                    // next. Event timestamps cannot reverse either ordering.
                    rejectedStaleObservation = true
                } else if !sourceOrderIsNewer,
                          let previousUpdatedAt = state.updatedAt,
                          let updatedAt,
                          updatedAt < previousUpdatedAt {
                    rejectedStaleObservation = true
                } else if !sourceOrderIsNewer,
                          let previousUpdatedAt = state.updatedAt,
                          let updatedAt,
                          updatedAt == previousUpdatedAt,
                          sameGenerationCursorIsStaleOrConflicting {
                    // Several token events can share the same JSON timestamp.
                    // Within one file generation, byte order is authoritative:
                    // accepting an older cursor as a counter reset would turn
                    // the newer pending value into carry and double-count it.
                    rejectedStaleObservation = true
                } else if observationDay < state.day {
                    // Source ordering resolves rewrites and delivery races within
                    // an accounting day. It must not reassign today's live counter
                    // to an earlier local day because an old event was replayed.
                    rejectedStaleObservation = true
                } else if isCoveredByCommittedScan {
                    let previous = state
                    if let authoritativeFrontier {
                        let candidate = liveTokenCounterState(
                            sessionID: sessionID,
                            frontier: authoritativeFrontier,
                            fallbackDate: observationDate
                        )
                        if !Self.isNewerLiveTokenCounter(state, than: candidate) {
                            state = candidate
                        }
                    } else {
                        state.totalTokens = normalizedTotal
                        state.scannedBaseline = normalizedTotal
                        state.day = observationDay
                        state.updatedAt = updatedAt ?? state.updatedAt
                        state.observationCursor = observationCursor ?? state.observationCursor
                    }
                    liveTokenCounters[key] = state
                    didChangeTokenAccounting = previous != state
                } else if observationDay > state.day {
                    let previousPending = max(0, state.totalTokens - state.scannedBaseline)
                    if previousPending > 0 {
                        preserveUnscannedLiveTokenCarry(from: state, totalTokens: previousPending)
                    }
                    let baseline: Int
                    if isCoveredByCommittedScan {
                        baseline = normalizedTotal
                    } else if normalizedTotal >= state.totalTokens {
                        // A cumulative counter crossing midnight contributes only
                        // the increment to the new local day.
                        baseline = min(normalizedTotal, state.totalTokens)
                    } else {
                        baseline = 0
                    }
                    liveTokenCounters[key] = LiveTokenCounterState(
                        sessionID: sessionID,
                        totalTokens: normalizedTotal,
                        scannedBaseline: baseline,
                        day: observationDay,
                        updatedAt: updatedAt,
                        observationCursor: observationCursor
                    )
                    didChangeTokenAccounting = previousPending > 0
                        || normalizedTotal != baseline
                        || state.day != observationDay
                } else {
                    let previousTotal = state.totalTokens
                    let previousBaseline = state.scannedBaseline
                    let previousCursor = state.observationCursor
                    if isCoveredByCommittedScan {
                        state.totalTokens = normalizedTotal
                        state.scannedBaseline = normalizedTotal
                    } else if normalizedTotal < state.totalTokens {
                        let previousPending = max(0, state.totalTokens - state.scannedBaseline)
                        if previousPending > 0 {
                            preserveUnscannedLiveTokenCarry(from: state, totalTokens: previousPending)
                        }
                        state.totalTokens = normalizedTotal
                        state.scannedBaseline = 0
                    } else {
                        state.totalTokens = normalizedTotal
                    }
                    state.updatedAt = updatedAt ?? state.updatedAt
                    state.observationCursor = observationCursor ?? state.observationCursor
                    liveTokenCounters[key] = state
                    didChangeTokenAccounting = previousTotal != state.totalTokens
                        || previousBaseline != state.scannedBaseline
                        || previousCursor != state.observationCursor
                }
                acceptedSourceOrderIsNewer = sourceOrderIsNewer
                    && liveTokenCounters[key]?.observationCursor == observationCursor
                if let acceptedState = liveTokenCounters[key],
                   acceptedState.totalTokens == normalizedTotal,
                   let acceptedCursor = acceptedState.observationCursor,
                   let observationCursor,
                   acceptedCursor.sourceGeneration == observationCursor.sourceGeneration,
                   acceptedCursor.endOffset == observationCursor.endOffset,
                   acceptedCursor.lineFingerprint == observationCursor.lineFingerprint {
                    let relation = Self.sourceSnapshotRelation(
                        lhsChangeTimeNanoseconds: observationCursor.sourceChangeTimeNanoseconds,
                        lhsStatFingerprint: observationCursor.sourceStatFingerprint,
                        rhsChangeTimeNanoseconds: acceptedCursor.sourceChangeTimeNanoseconds,
                        rhsStatFingerprint: acceptedCursor.sourceStatFingerprint
                    )
                    acceptedObservationMatchesCounter = relation == .same || relation == .legacy
                }
            } else {
                if isCoveredByCommittedScan, let authoritativeFrontier {
                    liveTokenCounters[key] = liveTokenCounterState(
                        sessionID: sessionID,
                        frontier: authoritativeFrontier,
                        fallbackDate: observationDate
                    )
                } else {
                    let scannedFrontierBaseline = scannedNumericBaselineForUncoveredObservation(
                        sessionID: sessionID,
                        totalTokens: normalizedTotal,
                        cursor: observationCursor,
                        watermarks: liveTokenScanWatermarks
                    ) ?? 0
                    let baseline = isCoveredByCommittedScan
                        ? normalizedTotal
                        : min(
                            normalizedTotal,
                            max(scannedFrontierBaseline, max(0, initialScannedBaseline ?? 0))
                        )
                    liveTokenCounters[key] = LiveTokenCounterState(
                        sessionID: sessionID,
                        totalTokens: normalizedTotal,
                        scannedBaseline: baseline,
                        day: observationDay,
                        updatedAt: updatedAt,
                        observationCursor: observationCursor
                    )
                    didChangeTokenAccounting = !isCoveredByCommittedScan
                        && normalizedTotal > baseline
                }
            }
        }

        guard !rejectedStaleObservation else { return }

        if didChangeTokenAccounting {
            liveTokenUsageRevision &+= 1
            tokenUsageReconciliationRevision &+= 1
            if (liveTokenUsageScanCutoff != nil
                || isTokenActivityScanInFlight
                || tokenActivityScanRetryPending),
               pendingLiveTokenUsageByDay(now: observationDate).values.contains(where: { $0 > 0 }) {
                tokenActivityScanRetryPending = true
            }
        }

        let shouldReplaceLatestUsage: Bool
        if latestAgentTokenUsage == nil {
            // A quota or account snapshot may be newer while carrying no token
            // data. Its timestamp must not block the first valid observation.
            shouldReplaceLatestUsage = true
        } else if (acceptedSourceOrderIsNewer || acceptedObservationMatchesCounter),
           Self.liveTokenSessionKey(latestAgentTokenUsageSessionID) == key {
            // Keep the persisted/displayed usage aligned with the accepted
            // counter when a newer source snapshot or later JSONL byte carries
            // an earlier event timestamp.
            shouldReplaceLatestUsage = true
        } else if let updatedAt, let latestAgentTokenUsageUpdatedAt {
            shouldReplaceLatestUsage = updatedAt >= latestAgentTokenUsageUpdatedAt
        } else {
            shouldReplaceLatestUsage = true
        }
        if shouldReplaceLatestUsage {
            latestAgentTokenUsage = usage
            latestAgentTokenUsageSessionID = sessionID
            latestAgentTokenUsageUpdatedAt = updatedAt
            Self.cacheLatestAgentTokenUsage(usage, userDefaults: userDefaults)
        }
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

    private static func cachedLatestAgentQuota(userDefaults: UserDefaults) -> AgentQuotaStatus? {
        cachedValue(forKey: cachedLatestAgentQuotaKey, as: AgentQuotaStatus.self, userDefaults: userDefaults)
    }

    private static func cacheLatestAgentQuota(_ quota: AgentQuotaStatus, userDefaults: UserDefaults) {
        cacheValue(quota, forKey: cachedLatestAgentQuotaKey, userDefaults: userDefaults)
    }

    private static func cachedLatestAgentTokenUsage(userDefaults: UserDefaults) -> AgentTokenUsage? {
        cachedValue(forKey: cachedLatestAgentTokenUsageKey, as: AgentTokenUsage.self, userDefaults: userDefaults)
    }

    private static func cacheLatestAgentTokenUsage(_ usage: AgentTokenUsage, userDefaults: UserDefaults) {
        cacheValue(usage, forKey: cachedLatestAgentTokenUsageKey, userDefaults: userDefaults)
    }

    private static func loadManualOpenAICookieHeader(
        secretStore: KeychainSecretStore,
        userDefaults: UserDefaults,
        allowsUserInteraction: Bool = true
    ) -> String {
        let storedValue = allowsUserInteraction
            ? try? secretStore.string(for: manualOpenAICookieKey)
            : try? secretStore.nonInteractiveString(for: manualOpenAICookieKey)
        if let value = storedValue,
           !value.isEmpty {
            userDefaults.removeObject(forKey: legacyManualOpenAICookieUserDefaultsKey)
            return value
        }

        guard let legacyValue = userDefaults.string(forKey: legacyManualOpenAICookieUserDefaultsKey),
              !legacyValue.isEmpty
        else {
            userDefaults.removeObject(forKey: legacyManualOpenAICookieUserDefaultsKey)
            return ""
        }

        guard allowsUserInteraction else {
            return legacyValue
        }

        do {
            try secretStore.set(legacyValue, for: manualOpenAICookieKey)
            userDefaults.removeObject(forKey: legacyManualOpenAICookieUserDefaultsKey)
        } catch {
            return legacyValue
        }
        return legacyValue
    }

    private static func cachedValue<T: Decodable>(forKey key: String, as type: T.Type, userDefaults: UserDefaults) -> T? {
        guard let data = userDefaults.data(forKey: key) else {
            return nil
        }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func cacheValue<T: Encodable>(_ value: T, forKey key: String, userDefaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(value) else {
            return
        }
        userDefaults.set(data, forKey: key)
    }

    private static func latestQuota(in snapshot: SignalSnapshot) -> AgentQuotaStatus? {
        snapshot.sessions
            .compactMap(\.quota)
            .max { lhs, rhs in lhs.updatedAt < rhs.updatedAt }
    }

    private static func latestTokenUsage(in snapshot: SignalSnapshot) -> AgentTokenUsage? {
        latestTokenUsageObservation(in: snapshot)?.usage
    }

    private static func latestTokenUsageObservation(
        in snapshot: SignalSnapshot
    ) -> LiveTokenUsageObservation? {
        tokenUsageObservations(in: snapshot).last
    }

    private static func tokenUsageObservations(
        in snapshot: SignalSnapshot
    ) -> [LiveTokenUsageObservation] {
        snapshot.sessions.compactMap { session in
            guard let quota = session.quota,
                  let usage = quota.tokenUsage
            else {
                return nil
            }
            return LiveTokenUsageObservation(
                usage: usage,
                sessionID: session.sessionID,
                updatedAt: quota.updatedAt
            )
        }
        .sorted {
            if $0.updatedAt == $1.updatedAt {
                return Self.liveTokenSessionKey($0.sessionID) < Self.liveTokenSessionKey($1.sessionID)
            }
            return ($0.updatedAt ?? .distantPast) < ($1.updatedAt ?? .distantPast)
        }
    }

    private static func shouldIncludeStoredSessionInDisplay(_ session: SessionStatus, now: Date) -> Bool {
        if isSignalTestEvent(session.lastEvent) {
            return false
        }

        if isPresenceSession(session) {
            return false
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

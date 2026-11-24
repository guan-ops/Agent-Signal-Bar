import AppKit
import Foundation
import Combine

@MainActor
final class ClaudeSupportModel: ObservableObject {
    typealias HistoryLoader = @Sendable (@escaping @Sendable () throws -> Void) throws -> CostUsageDailyReport
    @Published private(set) var snapshot: ClaudeUsageSnapshot?
    @Published private(set) var quotaIssue: String?
    @Published private(set) var historyIssue: String?
    @Published private(set) var swapIssue: String?
    @Published private(set) var switchIssue: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isHistoryScanning = false
    @Published private(set) var isSwitching = false
    @Published private(set) var days: [CostUsageDailyReport.Entry] = []
    @Published private(set) var historyUpdatedAt: Date?
    @Published private(set) var historyDetails: CodexUsageDetails?
    @Published private(set) var supportsAccountSwitching = true
    @Published private(set) var accounts: [ClaudeSwapAccountRow] = []
    @Published private(set) var isLoggingIn = false
    private var loginTask: Task<Void, Never>?
    private let loginRunner: @Sendable (URL) async throws -> Void
    @Published var loginMessage: String?
    @Published var claudePath: String { didSet { defaults.set(claudePath, forKey: "claude.executablePath") } }
    @Published var swapPath: String { didSet { defaults.set(swapPath, forKey: "claude.swapPath"); resetIdentity() } }
    @Published var swapEnabled: Bool { didSet { defaults.set(swapEnabled, forKey: "claude.swapEnabled"); resetIdentity() } }
    @Published private(set) var credentialConsent: Bool
    @Published private(set) var credentialReadBlocked = false
    @Published var usageSource: ClaudeUsageSource { didSet { defaults.set(usageSource.rawValue, forKey: "claude.providerSource"); resetIdentity() } }
    @Published var cliFallbackEnabled: Bool { didSet { defaults.set(cliFallbackEnabled, forKey: "claude.cliFallback") } }
    @Published var cliBackgroundEnabled: Bool { didSet { defaults.set(cliBackgroundEnabled, forKey: "claude.cliBackground") } }
    @Published var webEnabled: Bool { didSet { defaults.set(webEnabled, forKey: "claude.webEnabled"); if !webEnabled { cachedWebCookie = nil }; resetIdentity() } }
    @Published var webBrowser: String { didSet { defaults.set(webBrowser, forKey: "claude.webBrowserChoice") } }
    @Published var webOrganizationID: String { didSet { defaults.set(webOrganizationID, forKey: "claude.webOrganization"); resetIdentity() } }
    @Published var quotaWarningsEnabled: Bool { didSet { defaults.set(quotaWarningsEnabled, forKey: "claude.quotaWarnings") } }
    @Published var resetNotificationsEnabled: Bool { didSet { defaults.set(resetNotificationsEnabled, forKey: "claude.resetNotifications") } }
    @Published var predictionWarningsEnabled: Bool { didSet { defaults.set(predictionWarningsEnabled, forKey: "claude.predictionWarnings") } }
    @Published var warningThreshold: Int { didSet { defaults.set(warningThreshold, forKey: "claude.warningThreshold") } }
    @Published var quotaHistoryEnabled: Bool { didSet { defaults.set(quotaHistoryEnabled, forKey: "claude.quotaHistory") } }
    @Published var hidePersonalInfo: Bool { didSet { defaults.set(hidePersonalInfo, forKey: "claude.hidePersonalInfo") } }
    @Published var inspectedAccountNumber: Int?
    @Published private(set) var accountsUpdatedAt: Date?
    @Published private(set) var webOrganizations: [ClaudeWebOrganization] = []
    @Published private(set) var isImportingWeb = false
    @Published private(set) var webMessage: String?
    @Published private(set) var lastQuotaNotice: ClaudeQuotaNotice?
    private let webService: ClaudeWebUsageService
    private let webSecrets: any SecretStoring
    private let browserImporter: @Sendable (String) async throws -> String
    private let cliProbe: @Sendable (URL, String) async throws -> ClaudeUsageSnapshot
    private let versionDetector: (@Sendable (URL, Bool) -> String?)?
    private let quotaHistory: ClaudeQuotaHistory
    private let transientQuotaHistory = ClaudeQuotaHistory()
    private let notificationHandler: @Sendable (ClaudeQuotaNotice, Bool) -> Void
    private var cachedWebCookie: String?
    private var cachedCLI: ClaudeUsageSnapshot?
    // Stable until the identity is reset, so a fresh unverified CLI result is reused
    // instead of starting another CLI session on every background refresh.
    private var unverifiedCLIOwner = "cli-unverified-" + UUID().uuidString
    private var webImportTask: Task<Void, Never>?
    private let defaults: UserDefaults
    private let readCredentials: @Sendable (Bool) throws -> ClaudeCredential
    private let historyLoader: HistoryLoader
    private let loadsHistoryDetails: Bool
    private let service: ClaudeUsageService
    private var generation = UUID()
    private var lastRefresh: Date?
    private var refreshTask: Task<Void, Never>?
    private var switchingTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, service: ClaudeUsageService = .init(),
         readCredentials: @escaping @Sendable (Bool) throws -> ClaudeCredential = { try ClaudeCredentialReader.read(allowPrompt: $0) },
         loginRunner: @escaping @Sendable (URL) async throws -> Void = { try await ClaudeLoginRunner.run($0) },
         historyLoader: HistoryLoader? = nil,
         webService: ClaudeWebUsageService = .init(), webSecrets: (any SecretStoring)? = nil,
         browserImporter: @escaping @Sendable (String) async throws -> String = { try await ClaudeWebCookie.importFromBrowser($0) },
         cliProbe: @escaping @Sendable (URL, String) async throws -> ClaudeUsageSnapshot = { try await ClaudeCLIUsageProbe.run($0, owner: $1) },
         versionDetector: (@Sendable (URL, Bool) -> String?)? = nil,
         quotaHistory: ClaudeQuotaHistory? = nil,
         notificationHandler: @escaping @Sendable (ClaudeQuotaNotice, Bool) -> Void = { ClaudeQuotaNotifications.deliver($0, english: $1) }) {
        self.loginRunner = loginRunner
        defaults.removeObject(forKey: "claude.usageSource")
        defaults.removeObject(forKey: "claude.webBrowser")
        self.readCredentials = readCredentials
        self.historyLoader = historyLoader ?? { try ClaudeSupportModel.scanHistory(checkCancellation: $0) }
        self.loadsHistoryDetails = historyLoader == nil
        self.defaults = defaults
        self.service = service
        self.webService = webService
        self.webSecrets = webSecrets ?? KeychainSecretStore(service: "com.agentsignallight.claude-web")
        self.browserImporter = browserImporter
        self.cliProbe = cliProbe
        self.versionDetector = versionDetector
        self.quotaHistory = quotaHistory ?? ClaudeQuotaHistory(fileURL: historyLoader == nil ? ClaudeQuotaHistory.defaultURL : nil)
        self.notificationHandler = notificationHandler
        usageSource = ClaudeUsageSource(rawValue: defaults.string(forKey: "claude.providerSource") ?? "oauth") ?? .oauth
        cliFallbackEnabled = defaults.bool(forKey: "claude.cliFallback")
        cliBackgroundEnabled = defaults.bool(forKey: "claude.cliBackground")
        webEnabled = defaults.bool(forKey: "claude.webEnabled")
        webBrowser = defaults.string(forKey: "claude.webBrowserChoice") ?? "automatic"
        webOrganizationID = defaults.string(forKey: "claude.webOrganization") ?? ""
        quotaWarningsEnabled = defaults.bool(forKey: "claude.quotaWarnings")
        resetNotificationsEnabled = defaults.bool(forKey: "claude.resetNotifications")
        predictionWarningsEnabled = defaults.bool(forKey: "claude.predictionWarnings")
        warningThreshold = defaults.object(forKey: "claude.warningThreshold") == nil ? 20 : max(1, min(90, defaults.integer(forKey: "claude.warningThreshold")))
        quotaHistoryEnabled = defaults.object(forKey: "claude.quotaHistory") == nil || defaults.bool(forKey: "claude.quotaHistory")
        hidePersonalInfo = defaults.bool(forKey: "claude.hidePersonalInfo")
        claudePath = defaults.string(forKey: "claude.executablePath") ?? ""
        swapPath = defaults.string(forKey: "claude.swapPath") ?? ""
        swapEnabled = defaults.bool(forKey: "claude.swapEnabled")
        credentialConsent = defaults.bool(forKey: "claude.credentialConsent")
    }

    func stopCredentialRead() {
        credentialReadBlocked = false
        credentialConsent = false
        defaults.set(false, forKey: "claude.credentialConsent")
        resetIdentity()
    }

    func allowCredentialRead() {
        credentialConsent = true
        defaults.set(true, forKey: "claude.credentialConsent")
        credentialReadBlocked = false
        refresh(force: true)
    }

    /// The only entry point that may display the Claude Code keychain authorization dialog.
    func authorizeCredentialRead() {
        guard !accountActionInProgress else { return }
        resetIdentity()
        credentialConsent = true
        defaults.set(true, forKey: "claude.credentialConsent")
        credentialReadBlocked = false
        refresh(force: true, allowPrompt: true)
    }

    func useCLIWithoutCredentialRead() {
        stopCredentialRead()
        usageSource = .cli
        refresh(force: true)
    }

    private func readCredential(allowPrompt: Bool) async throws -> ClaudeCredential {
        guard allowPrompt || !credentialReadBlocked else { throw ClaudeSupportError.keychainDenied }
        let reader = readCredentials, generation = generation
        do {
            let value = try await Task.detached { try reader(allowPrompt) }.value
            guard generation == self.generation, !Task.isCancelled else { throw CancellationError() }
            return value
        } catch {
            if generation == self.generation, !Task.isCancelled, error as? ClaudeSupportError == .keychainDenied {
                credentialReadBlocked = true
            }
            throw error
        }
    }

    func resetIdentity() {
        if isImportingWeb { webImportTask?.cancel(); isImportingWeb = false }
        generation = UUID()
        refreshTask?.cancel()
        loginTask?.cancel()
        isLoggingIn = false
        loginMessage = nil
        isRefreshing = false
        isHistoryScanning = false
        snapshot = nil
        cachedCLI = nil
        unverifiedCLIOwner = "cli-unverified-" + UUID().uuidString
        accounts = []
        quotaIssue = nil
        swapIssue = nil
        lastRefresh = nil
    }

    /// Mirrors the app's monitoring pause. While paused no quota request, history scan,
    /// account list or CLI probe starts; an in-flight refresh is cancelled without
    /// discarding the last results, and the next refresh after resuming is not throttled.
    var isMonitoringPaused = false {
        didSet {
            guard isMonitoringPaused, !oldValue else { return }
            refreshTask?.cancel()
            isRefreshing = false
            isHistoryScanning = false
            lastRefresh = nil
        }
    }

    func refresh(force: Bool = false, allowPrompt: Bool = false) {
        guard !isMonitoringPaused, !isRefreshing, !isSwitching, !isLoggingIn else { return }
        if !force, let lastRefresh, Date().timeIntervalSince(lastRefresh) < 60 { return }
        isRefreshing = true
        lastRefresh = Date()
        let generation = generation
        refreshTask = Task { [weak self] in
            guard let self, self.generation == generation, !Task.isCancelled else { return }
            defer {
                // Whoever cancels (identity reset, pause) clears these flags itself; a late
                // cancelled task must not clear them for a refresh started after it.
                if self.generation == generation, !Task.isCancelled {
                    self.isRefreshing = false
                    self.isHistoryScanning = false
                }
            }
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self.refreshAccount(generation: generation, allowPrompt: allowPrompt, manual: force) }
                group.addTask { await self.refreshSavedAccounts(generation: generation) }
                group.addTask { await self.refreshHistory(generation: generation) }
            }
        }
    }

    private func refreshAccount(generation: UUID, allowPrompt: Bool, manual: Bool) async {
        guard self.generation == generation, !Task.isCancelled else { return }
        do {
            switch usageSource {
            case .oauth:
                if credentialConsent { try await refreshOAuth(generation: generation, allowPrompt: allowPrompt, manual: manual) }
            case .cli:
                try await refreshCLI(generation: generation, manual: manual)
            case .web:
                try await refreshWeb(generation: generation)
            case .automatic:
                var failure: Error = ClaudeSupportError.sourceDisabled
                if credentialConsent {
                    do { try await refreshOAuth(generation: generation, allowPrompt: allowPrompt, manual: manual); return }
                    catch { failure = error }
                }
                if case ClaudeSupportError.rateLimited = failure { throw failure }
                try Task.checkCancellation()
                if cliFallbackEnabled {
                    do { try await refreshCLI(generation: generation, manual: manual); return }
                    catch { failure = error }
                }
                try Task.checkCancellation()
                if webEnabled {
                    do { try await refreshWeb(generation: generation); return }
                    catch { failure = error }
                }
                throw failure
            }
        } catch {
            guard self.generation == generation, !Task.isCancelled else { return }
            if snapshot?.source == "Claude Code OAuth" || snapshot?.source == "Claude CLI" {
                let current = credentialConsent ? try? await readCredential(allowPrompt: false) : nil
                guard self.generation == generation else { return }
                if current?.identity != snapshot?.credentialID { snapshot = nil }
            } else if error as? ClaudeSupportError == .webLoginRequired {
                snapshot = nil
            }
            quotaIssue = Self.message(error)
        }
    }

    /// Installed Claude Code version for the request identity. The CLI is only started on a
    /// manual refresh or with background CLI runs enabled; otherwise a cached value or none.
    private func claudeVersion(manual: Bool) async -> String? {
        guard let versionDetector, let binary = ClaudeCommandRunner.executable("claude", custom: claudePath) else { return nil }
        let allowExecution = manual || cliBackgroundEnabled
        return await Task.detached { versionDetector(binary, allowExecution) }.value
    }

    private func refreshOAuth(generation: UUID, allowPrompt: Bool, manual: Bool) async throws {
        let credential = try await readCredential(allowPrompt: allowPrompt)
        guard self.generation == generation, !Task.isCancelled else { throw CancellationError() }
        if snapshot?.credentialID != credential.identity { snapshot = nil }
        let version = await claudeVersion(manual: manual)
        guard self.generation == generation, !Task.isCancelled else { throw CancellationError() }
        let value = try await service.fetch(credential, includeProfile: false, claudeVersion: version)
        let current = try await readCredential(allowPrompt: false)
        guard self.generation == generation, !Task.isCancelled else { throw CancellationError() }
        guard current.identity == credential.identity else { snapshot = nil; throw ClaudeSupportError.accountChanged }
        publish(value)
        // Quota is already visible while the optional two-second profile request is in flight.
        let enriched = await service.enrichProfile(value, credential: credential, claudeVersion: version)
        let finalOwner = try? await readCredential(allowPrompt: false)
        guard self.generation == generation, !Task.isCancelled else { throw CancellationError() }
        guard finalOwner?.identity == credential.identity else { snapshot = nil; throw ClaudeSupportError.accountChanged }
        publish(enriched)
    }

    private func refreshCLI(generation: UUID, manual: Bool) async throws {
        let credential = credentialConsent ? try? await readCredential(allowPrompt: false) : nil
        let owner = credential?.identity ?? unverifiedCLIOwner
        if let cachedCLI, cachedCLI.credentialID == owner, cachedCLI.isFresh(at: Date()),
           cachedCLI.windows.allSatisfy({ $0.resetsAt.map { $0 > Date() } ?? true }), !manual {
            publish(cachedCLI); return
        }
        guard manual || cliBackgroundEnabled else { throw ClaudeSupportError.manualCLIRequired }
        guard let binary = ClaudeCommandRunner.executable("claude", custom: claudePath) else { throw ClaudeSupportError.missingCLI }
        let value = try await cliProbe(binary, owner)
        guard self.generation == generation, !Task.isCancelled else { throw CancellationError() }
        if let credential {
            let current = try await readCredential(allowPrompt: false)
            guard current.identity == credential.identity else { snapshot = nil; throw ClaudeSupportError.accountChanged }
        }
        cachedCLI = value
        publish(value)
    }

    private func refreshWeb(generation: UUID) async throws {
        guard webEnabled else { throw ClaudeSupportError.sourceDisabled }
        let cookie = try webCookie()
        let organizations = try await webService.organizations(cookie: cookie)
        guard self.generation == generation, !Task.isCancelled else { throw CancellationError() }
        webOrganizations = organizations
        guard let organization = organizations.first(where: { $0.id == webOrganizationID })
                ?? (organizations.count == 1 && webOrganizationID.isEmpty ? organizations.first : nil) else {
            snapshot = nil; throw ClaudeSupportError.organizationRequired
        }
        let owner = ClaudeValue.key(cookie + "|" + organization.id)
        if snapshot?.credentialID != owner { snapshot = nil }
        let value = try await webService.fetch(cookie: cookie, organization: organization)
        guard self.generation == generation, !Task.isCancelled else { throw CancellationError() }
        publish(value)
        let enriched = await webService.enrich(value, cookie: cookie, organization: organization)
        guard self.generation == generation, !Task.isCancelled else { throw CancellationError() }
        publish(enriched)
    }

    private func publish(_ value: ClaudeUsageSnapshot) {
        snapshot = value; quotaIssue = nil; loginMessage = nil
        if quotaHistoryEnabled || quotaWarningsEnabled || resetNotificationsEnabled || predictionWarningsEnabled {
            let prefs = ClaudeQuotaHistory.Preferences(low: quotaWarningsEnabled, reset: resetNotificationsEnabled,
                predicted: predictionWarningsEnabled, threshold: warningThreshold)
            let recorder = quotaHistoryEnabled ? quotaHistory : transientQuotaHistory
            for event in recorder.record(value, preferences: prefs) {
                lastQuotaNotice = event
                notificationHandler(event, defaults.string(forKey: "appLanguage") == "en")
            }
        }
    }

    private func refreshSavedAccounts(generation: UUID) async {
        if swapEnabled {
            let swapPath = swapPath
            do {
                let values = try await Task.detached {
                    guard let executable = ClaudeCommandRunner.executable("cswap", custom: swapPath) else { throw ClaudeSupportError.missingCLI }
                    return try ClaudeSwapListParser.parse(ClaudeCommandRunner.run(executable, arguments: ["--list", "--json"]))
                }.value
                guard self.generation == generation, !Task.isCancelled else { return }
                self.accounts = values.accounts.sorted { lhs, rhs in
                    lhs.isActive != rhs.isActive ? lhs.isActive : lhs.number < rhs.number
                }
                self.accountsUpdatedAt = Date()
                self.supportsAccountSwitching = values.supportsAccountSwitching
                self.swapIssue = nil
            } catch {
                guard self.generation == generation, !Task.isCancelled else { return }
                self.swapIssue = Self.message(error)
            }
        }
    }

    private func refreshHistory(generation: UUID) async {
        guard self.generation == generation, !Task.isCancelled else { return }
        isHistoryScanning = true
        historyIssue = nil
        defer { if self.generation == generation, !Task.isCancelled { isHistoryScanning = false } }
        let historyLoader = historyLoader
        let loadsDetails = loadsHistoryDetails
        var attempt = 1
        while true {
            do {
                // Serialize disk/cache work and propagate reset cancellation into
                // the scanner, including work still queued behind an older scan.
                let result = try await CostUsageScanExecutor.run { checkCancellation in
                    try checkCancellation()
                    let report = try historyLoader(checkCancellation)
                    try checkCancellation()
                    let details = loadsDetails ? try Self.loadHistoryDetails(checkCancellation: checkCancellation) : nil
                    try checkCancellation()
                    return (report, details)
                }
                guard self.generation == generation, !Task.isCancelled else { return }
                self.days = result.0.data
                self.historyDetails = result.1
                self.historyUpdatedAt = Date()
                self.historyIssue = nil
                return
            } catch {
                guard self.generation == generation, !Task.isCancelled else { return }
                guard CostUsageScanner.isClaudeSourceChanging(error) else {
                    self.historyIssue = "本机历史暂不可读，保留上次结果。 / Local history unavailable; previous results retained."
                    return
                }
                // A session being written while it was read is not a read failure.
                // The committed cache is intact, so retry shortly before reporting.
                guard attempt < Self.historyChangeAttempts else {
                    self.historyIssue = "正在同步最新的本机历史，保留上次结果，下次刷新时重试。 / Syncing latest local history; previous results retained. Retrying on the next refresh."
                    return
                }
                attempt += 1
                try? await Task.sleep(for: Self.historyChangeRetryDelay)
                guard self.generation == generation, !Task.isCancelled else { return }
            }
        }
    }

    nonisolated static let historyChangeAttempts = 3
    nonisolated static let historyChangeRetryDelay: Duration = .milliseconds(300)

    func historySummary(now: Date = Date()) -> ClaudeHistorySummary {
        ClaudeHistorySummary(days: days, updatedAt: historyUpdatedAt, now: now)
    }

    nonisolated private static var historyCacheRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentSignalLight/ClaudeUsage", isDirectory: true)
    }

    nonisolated private static func loadHistoryDetails(checkCancellation: () throws -> Void) throws -> CodexUsageDetails {
        try checkCancellation()
        let cache = try CostUsageCacheIO.loadRequired(provider: .claude, cacheRoot: historyCacheRoot)
        return try CostUsageScanner.buildClaudeUsageDetails(cache: cache, now: Date(), modelsDevCacheRoot: historyCacheRoot,
                                                            checkCancellation: checkCancellation)
    }

    nonisolated static func scanHistory(
        roots: [URL]? = nil, cacheRoot: URL? = nil, now: Date = Date(),
        checkCancellation: @escaping @Sendable () throws -> Void = { try Task.checkCancellation() }
    ) throws -> CostUsageDailyReport {
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: now))!
        let cache = cacheRoot ?? historyCacheRoot
        var options = CostUsageScanner.Options()
        options.claudeProjectsRoots = roots
        options.cacheRoot = cache
        return try CostUsageScanner.loadDailyReportCancellable(provider: .claude, since: start, until: now,
            now: now, options: options, checkCancellation: checkCancellation)
    }

    /// A hung switch must not lock refresh, sign-in and install forever. The external
    /// credential transaction is never killed; only the interface stops waiting for it.
    nonisolated static let switchWaitLimit: Duration = .seconds(120)

    func switchAccount(_ number: Int) {
        guard swapEnabled, supportsAccountSwitching, swapIssue == nil, !isSwitching, !isLoggingIn,
              accounts.contains(where: { $0.number == number && ClaudeAccountPresentation.canActivate($0) }),
              let binary = ClaudeCommandRunner.executable("cswap", custom: swapPath) else { return }
        resetIdentity()
        switchIssue = nil
        isSwitching = true
        let generation = generation
        switchingTask = Task { [weak self] in
            let watchdog = Task { [weak self] in
                try? await Task.sleep(for: Self.switchWaitLimit)
                guard !Task.isCancelled, let self, self.generation == generation, self.isSwitching else { return }
                self.isSwitching = false
                self.switchIssue = Self.message(ClaudeSupportError.timedOut)
            }
            defer { watchdog.cancel() }
            let result: Result<Void, Error> = await Task.detached {
                do {
                    let data = try ClaudeCommandRunner.run(binary, arguments: ["--switch-to", String(number), "--json"], timeout: nil)
                    let value = try ClaudeSwapSwitchParser.parse(data)
                    guard value.toAccountNumber == number else { throw ClaudeSupportError.invalidResponse }
                    return .success(())
                } catch { return .failure(error) }
            }.value
            guard let self else { return }
            self.isSwitching = false
            guard self.generation == generation else { return }
            if case .failure(let error) = result { self.switchIssue = Self.message(error) } else { self.switchIssue = nil }
            self.refresh(force: true)
        }
    }

    var accountActionInProgress: Bool { isSwitching || isLoggingIn || isImportingWeb }
    func canSwitchAccount(_ row: ClaudeSwapAccountRow) -> Bool {
        swapEnabled && supportsAccountSwitching && swapIssue == nil && !accountActionInProgress
            && ClaudeAccountPresentation.canActivate(row)
    }
    func accountLabel(_ row: ClaudeSwapAccountRow) -> String { hidePersonalInfo ? "Account #\(row.number)" : ClaudeAccountPresentation.label(row, among: accounts) }

    var accountsAreStale: Bool { swapIssue != nil || accountsUpdatedAt.map { Date().timeIntervalSince($0) >= 300 } ?? true }
    var bestAvailableAccount: Int? {
        guard !accountsAreStale else { return nil }
        return accounts.filter { canSwitchAccount($0) }.compactMap { row -> (Int, Double)? in
            let remaining = [row.fiveHour, row.sevenDay].compactMap { $0 }.filter { $0.resetsAt.map { $0 > Date() } ?? true }.map { 100 - $0.usedPercent }
                + row.scoped.filter { $0.resetsAt.map { $0 > Date() } ?? true }.map { 100 - $0.usedPercent }
            return remaining.min().map { (row.number, $0) }
        }.max { $0.1 < $1.1 }?.0
    }
    func quotaSamples(windowID: String) -> [ClaudeQuotaSample] {
        guard quotaHistoryEnabled, let snapshot else { return [] }
        return quotaHistory.samples(snapshot: snapshot, windowID: windowID)
    }
    func quotaForecast(windowID: String) -> ClaudeQuotaForecast? {
        guard quotaHistoryEnabled, quotaIssue == nil, let snapshot, snapshot.isFresh(at: Date()) else { return nil }
        return quotaHistory.forecast(snapshot: snapshot, windowID: windowID)
    }
    func clearQuotaHistory() { quotaHistory.clear(); transientQuotaHistory.clear(); objectWillChange.send() }
    func requestNotificationPermission() { ClaudeQuotaNotifications.requestPermission() }

    private func webCookie() throws -> String {
        if let cachedWebCookie { return cachedWebCookie }
        let value: String?
        if let keychain = webSecrets as? KeychainSecretStore {
            value = try keychain.nonInteractiveString(for: "session")
        } else { value = try webSecrets.string(for: "session") }
        guard let value, let normalized = ClaudeWebCookie.normalized(value) else { throw ClaudeSupportError.webLoginRequired }
        cachedWebCookie = normalized
        return normalized
    }
    func saveWebCookie(_ value: String) {
        do {
            guard let cookie = ClaudeWebCookie.normalized(value) else { throw ClaudeSupportError.webLoginRequired }
            try webSecrets.set(cookie, for: "session")
            cachedWebCookie = cookie; webOrganizations = []; webOrganizationID = ""
            webEnabled = true; usageSource = .web; webMessage = nil
            refresh(force: true)
        } catch { webMessage = Self.message(error) }
    }
    func forgetWebCookie() {
        webImportTask?.cancel(); isImportingWeb = false
        do { try webSecrets.delete(key: "session") }
        catch { webMessage = Self.message(error); return }
        cachedWebCookie = nil; webOrganizations = []; webOrganizationID = ""; webEnabled = false
        if usageSource == .web { usageSource = .oauth }
        resetIdentity()
    }
    func importWebSession() {
        guard !accountActionInProgress else { return }
        isImportingWeb = true; webMessage = nil
        let importer = browserImporter, browser = webBrowser
        webImportTask = Task { [weak self] in
            do {
                let cookie = try await importer(browser)
                guard let self, !Task.isCancelled else { return }
                self.isImportingWeb = false; self.webImportTask = nil; self.saveWebCookie(cookie)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.isImportingWeb = false; self.webMessage = Self.message(error)
            }
        }
    }

    var hasClaudeCLI: Bool { ClaudeCommandRunner.executable("claude", custom: claudePath) != nil }

    /// As in CodexBar: the app never downloads or runs an installer on the user's behalf.
    static let installCommand = "npm i -g @anthropic-ai/claude-code"
    static let missingCLIMessage = "未找到 Claude Code。请先自行安装（\(installCommand)），或在详情中选择已安装的可执行文件，然后重试。 / Claude Code was not found. Install it yourself (\(installCommand)) or choose the installed executable in Details, then try again."

    func cancelLogin() {
        resetIdentity()
        loginMessage = "已取消本次登录。 / Login cancelled."
    }

    func login() {
        guard !isSwitching, !isLoggingIn else { return }
        guard let binary = ClaudeCommandRunner.executable("claude", custom: claudePath) else {
            loginMessage = Self.missingCLIMessage
            return
        }
        resetIdentity()
        isLoggingIn = true
        loginMessage = "正在通过 Claude Code 打开浏览器；完成授权后会自动读取账号与配额。 / Opening browser sign-in through Claude Code. Account and usage refresh automatically after authorization."
        let generation = generation
        let runner = loginRunner
        loginTask = Task { [weak self] in
            do {
                try await runner(binary)
                guard let self, self.generation == generation, !Task.isCancelled else { return }
                self.isLoggingIn = false
                if self.usageSource != .cli {
                    self.credentialConsent = true
                    self.defaults.set(true, forKey: "claude.credentialConsent")
                }
                self.credentialReadBlocked = false
                self.loginMessage = "登录完成，正在读取账号与配额。 / Signed in. Reading account and usage."
                self.refresh(force: true)
            } catch {
                guard let self, self.generation == generation, !Task.isCancelled else { return }
                self.isLoggingIn = false
                self.loginMessage = (error as? ClaudeSupportError) == .timedOut
                    ? "登录等待超时，请重试。 / Sign-in timed out. Please try again."
                    : "登录未完成，请重试；也可在终端运行 claude auth login --claudeai 检查原因。 / Sign-in did not complete. Retry, or run claude auth login --claudeai in Terminal to diagnose."
            }
        }
    }

    static func message(_ error: Error) -> String {
        (error as? ClaudeSupportError)?.message ?? "操作暂未成功，请重试。 / Operation failed; please retry."
    }
}

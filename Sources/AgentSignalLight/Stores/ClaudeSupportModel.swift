import AppKit
import Foundation
import Combine

@MainActor
final class ClaudeSupportModel: ObservableObject {
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
    @Published private(set) var accounts: [ClaudeSwapAccountRow] = []
    @Published private(set) var isInstallingCLI = false
    private var installationTask: Task<Void, Never>?
    private let installRunner: @Sendable () async throws -> URL
    @Published private(set) var isLoggingIn = false
    private var loginTask: Task<Void, Never>?
    private let loginRunner: @Sendable (URL) async throws -> Void
    @Published var loginMessage: String?
    @Published var claudePath: String { didSet { defaults.set(claudePath, forKey: "claude.executablePath") } }
    @Published var swapPath: String { didSet { defaults.set(swapPath, forKey: "claude.swapPath"); resetIdentity() } }
    @Published var swapEnabled: Bool { didSet { defaults.set(swapEnabled, forKey: "claude.swapEnabled"); resetIdentity() } }
    @Published private(set) var credentialConsent: Bool
    private let defaults: UserDefaults
    private let readCredentials: @Sendable (Bool) throws -> ClaudeCredential
    private let historyLoader: @Sendable () throws -> CostUsageDailyReport
    private let service: ClaudeUsageService
    private var generation = UUID()
    private var lastRefresh: Date?
    private var refreshTask: Task<Void, Never>?
    private var switchingTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, service: ClaudeUsageService = .init(),
         readCredentials: @escaping @Sendable (Bool) throws -> ClaudeCredential = { try ClaudeCredentialReader.read(allowPrompt: $0) },
         loginRunner: @escaping @Sendable (URL) async throws -> Void = { try await ClaudeLoginRunner.run($0) },
         installRunner: @escaping @Sendable () async throws -> URL = { try await ClaudeCLIInstaller.install() },
         historyLoader: @escaping @Sendable () throws -> CostUsageDailyReport = { try ClaudeSupportModel.scanHistory() }) {
        self.installRunner = installRunner
        self.loginRunner = loginRunner
        defaults.removeObject(forKey: "claude.usageSource")
        defaults.removeObject(forKey: "claude.webBrowser")
        self.readCredentials = readCredentials
        self.historyLoader = historyLoader
        self.defaults = defaults
        self.service = service
        claudePath = defaults.string(forKey: "claude.executablePath") ?? ""
        swapPath = defaults.string(forKey: "claude.swapPath") ?? ""
        swapEnabled = defaults.bool(forKey: "claude.swapEnabled")
        credentialConsent = defaults.bool(forKey: "claude.credentialConsent")
    }

    func stopCredentialRead() {
        credentialConsent = false
        defaults.set(false, forKey: "claude.credentialConsent")
        resetIdentity()
    }

    func allowCredentialRead() {
        credentialConsent = true
        defaults.set(true, forKey: "claude.credentialConsent")
        refresh(force: true, allowPrompt: true)
    }

    func resetIdentity() {
        generation = UUID()
        refreshTask?.cancel()
        loginTask?.cancel()
        isLoggingIn = false
        loginMessage = nil
        isRefreshing = false
        isHistoryScanning = false
        snapshot = nil
        accounts = []
        quotaIssue = nil
        swapIssue = nil
        lastRefresh = nil
    }

    func refresh(force: Bool = false, allowPrompt: Bool = false) {
        guard !isRefreshing, !isSwitching, !isLoggingIn, !isInstallingCLI else { return }
        if !force, let lastRefresh, Date().timeIntervalSince(lastRefresh) < 60 { return }
        isRefreshing = true
        lastRefresh = Date()
        let generation = generation
        let reader = readCredentials
        let historyLoader = historyLoader
        let consent = credentialConsent
        let swapEnabled = swapEnabled
        let swapPath = swapPath
        refreshTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generation == generation {
                    self.isRefreshing = false
                    self.isHistoryScanning = false
                }
            }
            if consent {
                do {
                    let credential = try await Task.detached { try reader(allowPrompt) }.value
                    guard self.generation == generation, !Task.isCancelled else { return }
                    if self.snapshot?.credentialID != credential.identity { self.snapshot = nil }
                    let value = try await self.service.fetch(credential)
                    // Re-read the current owner before publishing, so an external account switch cannot
                    // publish the preceding account's response as current.
                    let current = try await Task.detached { try reader(false) }.value
                    guard self.generation == generation, !Task.isCancelled else { return }
                    guard current.identity == credential.identity else {
                        self.snapshot = nil
                        self.quotaIssue = "账号已变化，请刷新。 / Account changed; refresh again."
                        return
                    }
                    self.snapshot = value
                    self.quotaIssue = nil
                    self.loginMessage = nil
                } catch {
                    guard self.generation == generation, !Task.isCancelled else { return }
                    self.quotaIssue = Self.message(error)
                }
            }
            if swapEnabled {
                do {
                    let values = try await Task.detached {
                        guard let executable = ClaudeCommandRunner.executable("cswap", custom: swapPath) else { throw ClaudeSupportError.missingCLI }
                        return try ClaudeSwapListParser.parse(ClaudeCommandRunner.run(executable, arguments: ["--list", "--json"]))
                    }.value
                    guard self.generation == generation, !Task.isCancelled else { return }
                    self.accounts = values.accounts
                    self.swapIssue = nil
                } catch {
                    guard self.generation == generation, !Task.isCancelled else { return }
                    self.swapIssue = Self.message(error)
                }
            }
            self.isHistoryScanning = true
            self.historyIssue = nil
            do {
                let report = try await Task.detached(priority: .utility) { try historyLoader() }.value
                guard self.generation == generation, !Task.isCancelled else { return }
                self.days = report.data
                self.historyUpdatedAt = Date()
                self.historyIssue = nil
            } catch {
                guard self.generation == generation, !Task.isCancelled else { return }
                self.historyIssue = "本机历史暂不可读，保留上次结果。 / Local history unavailable; previous results retained."
            }
        }
    }

    nonisolated static func scanHistory(roots: [URL]? = nil, cacheRoot: URL? = nil, now: Date = Date()) throws -> CostUsageDailyReport {
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: now))!
        let cache = cacheRoot ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentSignalLight/ClaudeUsage", isDirectory: true)
        var options = CostUsageScanner.Options()
        options.claudeProjectsRoots = roots
        options.cacheRoot = cache
        return try CostUsageScanner.loadDailyReportCancellable(provider: .claude, since: start, until: now,
            now: now, options: options, checkCancellation: { try Task.checkCancellation() })
    }

    func switchAccount(_ number: Int) {
        guard swapEnabled, !isSwitching, !isLoggingIn, !isInstallingCLI,
              accounts.contains(where: { $0.number == number && !$0.isActive && $0.usageStatus == .ok }),
              let binary = ClaudeCommandRunner.executable("cswap", custom: swapPath) else { return }
        resetIdentity()
        switchIssue = nil
        isSwitching = true
        let generation = generation
        switchingTask = Task { [weak self] in
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
            if case .failure(let error) = result { self.switchIssue = Self.message(error) }
            self.refresh(force: true)
        }
    }

    var hasClaudeCLI: Bool { ClaudeCommandRunner.executable("claude", custom: claudePath) != nil }

    func installAndLogin() {
        guard !isInstallingCLI, !isLoggingIn, !isSwitching else { return }
        if hasClaudeCLI { login(); return }
        resetIdentity()
        isInstallingCLI = true
        loginMessage = "正在下载并运行 Claude Code 官方安装器，完成后自动打开浏览器登录… / Downloading and running the official Claude Code installer. Browser sign-in starts automatically when ready…"
        let runner = installRunner
        let generation = generation
        installationTask = Task { [weak self] in
            do {
                let binary = try await runner()
                guard let self else { return }
                self.isInstallingCLI = false
                guard self.generation == generation else { return }
                self.claudePath = binary.path
                self.login()
            } catch {
                guard let self else { return }
                self.isInstallingCLI = false
                guard self.generation == generation else { return }
                self.loginMessage = "Claude Code 安装未完成，请检查网络后重试。 / Claude Code installation did not complete. Check your connection and retry."
            }
        }
    }

    func cancelLogin() {
        resetIdentity()
        loginMessage = "已取消本次登录。 / Login cancelled."
    }

    func login() {
        guard !isSwitching, !isLoggingIn, !isInstallingCLI else { return }
        guard let binary = ClaudeCommandRunner.executable("claude", custom: claudePath) else {
            loginMessage = "尚未安装 Claude Code。请点击“一键安装并登录”。 / Claude Code is not installed. Click Install and sign in."
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
                self.credentialConsent = true
                self.defaults.set(true, forKey: "claude.credentialConsent")
                self.loginMessage = "登录完成，正在读取账号与配额。 / Signed in. Reading account and usage."
                self.refresh(force: true, allowPrompt: true)
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

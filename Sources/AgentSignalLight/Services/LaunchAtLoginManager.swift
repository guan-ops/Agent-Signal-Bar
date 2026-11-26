import Darwin
import AgentSignalLightCore
import Foundation

/// Runs `launchctl`. Production uses `SystemLaunchctlRunner`; tests inject a fake so a test
/// run can never bootstrap or boot out the user's real login item.
protocol LaunchctlRunning: Sendable {
    /// Runs `launchctl` with `arguments` and returns its exit status and standard error.
    func run(arguments: [String]) throws -> LaunchctlResult
}

struct LaunchctlResult: Sendable, Equatable {
    var terminationStatus: Int32
    var standardError: String

    init(terminationStatus: Int32, standardError: String = "") {
        self.terminationStatus = terminationStatus
        self.standardError = standardError
    }
}

/// Detects whether the current process is a test runner (`xctest`, `swiftpm-testing-helper`,
/// or any process with XCTest loaded). Used as a last line of defence so tests never touch
/// the real LaunchAgents directory or `launchctl`, even if a test forgets to inject fakes.
enum LaunchAtLoginTestProcess {
    static let isRunningTests: Bool = {
        let environment = ProcessInfo.processInfo.environment
        if environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil {
            return true
        }
        let processName = ProcessInfo.processInfo.processName
        if processName == "xctest" || processName == "swiftpm-testing-helper" {
            return true
        }
        return NSClassFromString("XCTestCase") != nil
    }()
}

/// The real `/bin/launchctl`. Refuses to run inside a test process.
struct SystemLaunchctlRunner: LaunchctlRunning {
    static let timeout: TimeInterval = 5

    private static let invocationLock = NSLock()
    nonisolated(unsafe) private static var invocations = 0

    /// How many times this process has launched the real `/bin/launchctl`. Tests assert this
    /// stays at zero.
    static var invocationCount: Int {
        invocationLock.lock()
        defer { invocationLock.unlock() }
        return invocations
    }

    private let refusesInTestProcess: Bool

    init(refusesInTestProcess: Bool = LaunchAtLoginTestProcess.isRunningTests) {
        self.refusesInTestProcess = refusesInTestProcess
    }

    func run(arguments: [String]) throws -> LaunchctlResult {
        guard !refusesInTestProcess else {
            throw LaunchAtLoginError.launchctlUnavailableInTests
        }

        Self.invocationLock.lock()
        Self.invocations += 1
        Self.invocationLock.unlock()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        if let nullHandle = FileHandle(forWritingAtPath: "/dev/null") {
            process.standardOutput = nullHandle
        }
        let errorPipe = Pipe()
        process.standardError = errorPipe

        try process.run()
        let deadline = Date().addingTimeInterval(Self.timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            throw LaunchAtLoginError.launchctlFailed("launchctl timed out")
        }

        let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let message = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return LaunchctlResult(terminationStatus: process.terminationStatus, standardError: message)
    }
}

/// `launchctl` stand-in used by the default manager inside a test process: it records nothing,
/// runs nothing, and reports every job as not loaded.
struct InertLaunchctlRunner: LaunchctlRunning {
    func run(arguments: [String]) throws -> LaunchctlResult {
        LaunchctlResult(terminationStatus: 1, standardError: "launchctl is disabled in tests")
    }
}

struct LaunchAtLoginManager: Sendable {
    static let defaultLabel = "com.agentsignallight.AgentSignalLight"

    let label: String
    /// The `.app` bundle the LaunchAgent opens, or nil when the process is not running from an
    /// app bundle (tests, `swift run`). Installing without one fails instead of writing a plist
    /// that points at the test runner or a build directory.
    let appURL: URL?
    let launchAgentDirectory: URL
    let stateDirectoryURL: URL
    let launchctl: any LaunchctlRunning
    let userID: uid_t
    private let securesStateDirectory: Bool

    init(
        label: String = LaunchAtLoginManager.defaultLabel,
        appURL: URL? = LaunchAtLoginManager.appBundleURL(),
        launchAgentDirectory: URL = LaunchAtLoginManager.defaultLaunchAgentDirectory(),
        stateDirectoryURL: URL? = nil,
        launchctl: any LaunchctlRunning = LaunchAtLoginManager.defaultLaunchctlRunner(),
        userID: uid_t = getuid()
    ) {
        let environment = ProcessInfo.processInfo.environment
        self.label = label
        self.appURL = appURL
        self.launchAgentDirectory = launchAgentDirectory
        self.launchctl = launchctl
        self.userID = userID
        self.stateDirectoryURL = stateDirectoryURL
            ?? SignalStateStore.defaultStateDirectoryURL(environment: environment)
        securesStateDirectory = stateDirectoryURL == nil
            && !SignalStateStore.hasExplicitStateDirectory(environment: environment)
    }

    /// The enclosing `.app` bundle, taken from the bundle rather than the running executable.
    /// Returns nil when the process is not an app (for example the XCTest runner, whose main
    /// bundle is `/Applications/Xcode.app/Contents/Developer/usr/bin`, or `swift run`).
    static func appBundleURL(
        bundle: Bundle = .main,
        isRunningTests: Bool = LaunchAtLoginTestProcess.isRunningTests
    ) -> URL? {
        guard !isRunningTests else { return nil }
        let url = bundle.bundleURL.standardizedFileURL
        guard url.pathExtension == "app" else { return nil }
        return url
    }

    /// `~/Library/LaunchAgents`, or a throwaway temporary directory inside a test process so
    /// the user's real login item can never be overwritten by a test.
    static func defaultLaunchAgentDirectory(
        isRunningTests: Bool = LaunchAtLoginTestProcess.isRunningTests
    ) -> URL {
        if isRunningTests {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("agent-signal-tests-launch-agents-\(getpid())", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }

    static func defaultLaunchctlRunner(
        isRunningTests: Bool = LaunchAtLoginTestProcess.isRunningTests
    ) -> any LaunchctlRunning {
        isRunningTests ? InertLaunchctlRunner() : SystemLaunchctlRunner()
    }

    var plistURL: URL {
        launchAgentDirectory.appendingPathComponent("\(label).plist")
    }

    private var domain: String { "gui/\(userID)" }

    var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path) && launchctlPrintSucceeds()
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try install()
        } else {
            try uninstall()
        }
    }

    private func install() throws {
        guard let appURL else {
            throw LaunchAtLoginError.notRunningFromAppBundle
        }

        try FileManager.default.createDirectory(
            at: launchAgentDirectory,
            withIntermediateDirectories: true
        )

        try prepareStateDirectoryAndLogs()
        try launchAgentPlistData(appURL: appURL).write(to: plistURL, options: .atomic)

        do {
            try? runLaunchctl(arguments: ["bootout", domain, plistURL.path], allowsFailure: true)
            try runLaunchctl(arguments: ["bootstrap", domain, plistURL.path])
        } catch {
            try? FileManager.default.removeItem(at: plistURL)
            throw error
        }
    }

    private func uninstall() throws {
        try? runLaunchctl(arguments: ["bootout", domain, plistURL.path], allowsFailure: true)
        try? FileManager.default.removeItem(at: plistURL)
    }

    func launchAgentPlistData(appURL: URL) throws -> Data {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [
                "/usr/bin/open",
                appURL.path
            ],
            "RunAtLoad": true,
            "StandardOutPath": stateDirectoryURL.appendingPathComponent("app.out.log").path,
            "StandardErrorPath": stateDirectoryURL.appendingPathComponent("app.err.log").path
        ]

        return try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
    }

    func prepareStateDirectoryAndLogs() throws {
        try prepareStateDirectory()
        try prepareLaunchLogFile(at: stateDirectoryURL.appendingPathComponent("app.out.log"))
        try prepareLaunchLogFile(at: stateDirectoryURL.appendingPathComponent("app.err.log"))
    }

    private func prepareStateDirectory() throws {
        var info = stat()
        let existed = Darwin.lstat(stateDirectoryURL.path, &info) == 0
        if !existed {
            guard errno == ENOENT else {
                throw SignalStateStoreError.unsafeStateDirectory(stateDirectoryURL)
            }
            do {
                try FileManager.default.createDirectory(
                    at: stateDirectoryURL,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: NSNumber(value: 0o700)]
                )
            } catch {
                throw SignalStateStoreError.cannotCreateStateDirectory(stateDirectoryURL, error)
            }
        }

        let directoryDescriptor = Darwin.open(
            stateDirectoryURL.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard directoryDescriptor >= 0 else {
            throw SignalStateStoreError.unsafeStateDirectory(stateDirectoryURL)
        }
        defer { Darwin.close(directoryDescriptor) }

        guard Darwin.fstat(directoryDescriptor, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              info.st_uid == geteuid(),
              (info.st_mode & mode_t(0o022)) == 0
        else {
            throw SignalStateStoreError.unsafeStateDirectory(stateDirectoryURL)
        }

        do {
            if !existed || securesStateDirectory {
                try removeExtendedACL(from: directoryDescriptor)
                guard Darwin.fchmod(directoryDescriptor, mode_t(0o700)) == 0 else {
                    throw SignalStateStoreError.unsafeStateDirectory(stateDirectoryURL)
                }
            } else if try hasExtendedACL(on: directoryDescriptor) {
                throw SignalStateStoreError.unsafeStateDirectory(stateDirectoryURL)
            }
        } catch let error as SignalStateStoreError {
            throw error
        } catch {
            throw SignalStateStoreError.unsafeStateDirectory(stateDirectoryURL)
        }
    }

    private func prepareLaunchLogFile(at url: URL) throws {
        let fileDescriptor = Darwin.open(
            url.path,
            O_CREAT | O_WRONLY | O_APPEND | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard fileDescriptor >= 0 else {
            throw SignalStateStoreError.unsafeStateFile(url)
        }
        defer { Darwin.close(fileDescriptor) }

        var info = stat()
        guard Darwin.fstat(fileDescriptor, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              info.st_uid == geteuid(),
              info.st_nlink == 1
        else {
            throw SignalStateStoreError.unsafeStateFile(url)
        }

        do {
            try removeExtendedACL(from: fileDescriptor)
            guard Darwin.fchmod(fileDescriptor, mode_t(0o600)) == 0 else {
                throw SignalStateStoreError.unsafeStateFile(url)
            }
        } catch let error as SignalStateStoreError {
            throw error
        } catch {
            throw SignalStateStoreError.unsafeStateFile(url)
        }
    }

    private func hasExtendedACL(on fileDescriptor: Int32) throws -> Bool {
        errno = 0
        guard let acl = acl_get_fd_np(fileDescriptor, ACL_TYPE_EXTENDED) else {
            if errno == ENOENT { return false }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        acl_free(UnsafeMutableRawPointer(acl))
        return true
    }

    private func removeExtendedACL(from fileDescriptor: Int32) throws {
        guard try hasExtendedACL(on: fileDescriptor) else { return }
        guard let emptyACL = acl_init(1) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { acl_free(UnsafeMutableRawPointer(emptyACL)) }
        guard acl_set_fd_np(fileDescriptor, emptyACL, ACL_TYPE_EXTENDED) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    private func launchctlPrintSucceeds() -> Bool {
        guard let result = try? launchctl.run(arguments: ["print", "\(domain)/\(label)"]) else {
            return false
        }
        return result.terminationStatus == 0
    }

    private func runLaunchctl(arguments: [String], allowsFailure: Bool = false) throws {
        let result = try launchctl.run(arguments: arguments)
        if result.terminationStatus != 0 && !allowsFailure {
            throw LaunchAtLoginError.launchctlFailed(
                result.standardError.isEmpty ? "launchctl failed" : result.standardError
            )
        }
    }
}

enum LaunchAtLoginError: Error, LocalizedError, Equatable {
    case launchctlFailed(String)
    case launchctlUnavailableInTests
    case notRunningFromAppBundle

    var errorDescription: String? {
        switch self {
        case .launchctlFailed(let message):
            return message
        case .launchctlUnavailableInTests:
            return "launchctl is disabled while tests are running"
        case .notRunningFromAppBundle:
            return "Open at Login needs Agent Signal Light to run from its .app bundle"
        }
    }
}

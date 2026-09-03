import Darwin
import AgentSignalLightCore
import Foundation

struct LaunchAtLoginManager: Sendable {
    private static let launchctlTimeout: TimeInterval = 5

    let label: String
    let appURL: URL
    let launchAgentDirectory: URL
    let stateDirectoryURL: URL
    private let securesStateDirectory: Bool

    init(
        label: String = "com.agentsignallight.AgentSignalLight",
        appURL: URL = Bundle.main.bundleURL,
        launchAgentDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true),
        stateDirectoryURL: URL? = nil
    ) {
        let environment = ProcessInfo.processInfo.environment
        self.label = label
        self.appURL = appURL
        self.launchAgentDirectory = launchAgentDirectory
        self.stateDirectoryURL = stateDirectoryURL
            ?? SignalStateStore.defaultStateDirectoryURL(environment: environment)
        securesStateDirectory = stateDirectoryURL == nil
            && !SignalStateStore.hasExplicitStateDirectory(environment: environment)
    }

    var plistURL: URL {
        launchAgentDirectory.appendingPathComponent("\(label).plist")
    }

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
        try FileManager.default.createDirectory(
            at: launchAgentDirectory,
            withIntermediateDirectories: true
        )

        try prepareStateDirectoryAndLogs()
        try launchAgentPlistData().write(to: plistURL, options: .atomic)

        do {
            try? runLaunchctl(arguments: ["bootout", "gui/\(getuid())", plistURL.path], allowsFailure: true)
            try runLaunchctl(arguments: ["bootstrap", "gui/\(getuid())", plistURL.path])
        } catch {
            try? FileManager.default.removeItem(at: plistURL)
            throw error
        }
    }

    private func uninstall() throws {
        try? runLaunchctl(arguments: ["bootout", "gui/\(getuid())", plistURL.path], allowsFailure: true)
        try? FileManager.default.removeItem(at: plistURL)
    }

    private func launchAgentPlistData() throws -> Data {
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "gui/\(getuid())/\(label)"]

        if let nullHandle = FileHandle(forWritingAtPath: "/dev/null") {
            process.standardOutput = nullHandle
            process.standardError = nullHandle
        }

        do {
            try process.run()
        } catch {
            return false
        }

        let deadline = Date().addingTimeInterval(Self.launchctlTimeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            return false
        }

        return process.terminationStatus == 0
    }

    private func runLaunchctl(arguments: [String], allowsFailure: Bool = false) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments

        let errorPipe = Pipe()
        process.standardError = errorPipe

        try process.run()
        let deadline = Date().addingTimeInterval(Self.launchctlTimeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            throw LaunchAtLoginError.launchctlFailed("launchctl timed out")
        }

        if process.terminationStatus != 0 && !allowsFailure {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw LaunchAtLoginError.launchctlFailed(message ?? "launchctl failed")
        }
    }
}

enum LaunchAtLoginError: Error, LocalizedError {
    case launchctlFailed(String)

    var errorDescription: String? {
        switch self {
        case .launchctlFailed(let message):
            return message
        }
    }
}

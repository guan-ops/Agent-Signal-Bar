import Darwin
import Foundation
import XCTest
@testable import AgentSignalLight
@testable import AgentSignalLightCore

/// Running the test suite must never rewrite the user's real login item or call the real
/// `launchctl`. These tests pin that down.
final class LaunchAtLoginIsolationTests: XCTestCase {
    private let realLaunchAgentPlist: URL = {
        // Resolve the account's home from the password database, not $HOME, so a redirected
        // HOME cannot hide a write to the real LaunchAgents directory.
        let home = getpwuid(getuid()).flatMap { String(validatingCString: $0.pointee.pw_dir) }
            ?? NSHomeDirectory()
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(LaunchAtLoginManager.defaultLabel).plist")
    }()

    func testTestProcessIsDetected() {
        XCTAssertTrue(LaunchAtLoginTestProcess.isRunningTests)
    }

    func testDefaultManagerInTestsUsesNoRealHomeAppOrLaunchctl() {
        let manager = LaunchAtLoginManager()

        XCTAssertNil(manager.appURL, "the XCTest runner must never be used as the login item")
        XCTAssertTrue(manager.launchctl is InertLaunchctlRunner)
        XCTAssertNotEqual(
            manager.plistURL.standardizedFileURL.path,
            realLaunchAgentPlist.standardizedFileURL.path
        )
        XCTAssertTrue(
            manager.launchAgentDirectory.standardizedFileURL.path
                .hasPrefix(FileManager.default.temporaryDirectory.standardizedFileURL.path)
        )
    }

    func testAppBundleURLComesFromAppBundleNotCurrentProcess() throws {
        // The test runner's main bundle is not an .app, so it can never be the login item.
        XCTAssertNil(LaunchAtLoginManager.appBundleURL())
        XCTAssertNil(LaunchAtLoginManager.appBundleURL(bundle: .main, isRunningTests: false))

        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let appURL = root.appendingPathComponent("AgentSignalLight.app", isDirectory: true)
        let contents = appURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "com.agentsignallight.AgentSignalLight"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let bundle = try XCTUnwrap(Bundle(url: appURL))

        XCTAssertEqual(
            LaunchAtLoginManager.appBundleURL(bundle: bundle, isRunningTests: false)?.path,
            appURL.standardizedFileURL.path
        )
        XCTAssertNil(LaunchAtLoginManager.appBundleURL(bundle: bundle, isRunningTests: true))
    }

    func testInstallWritesOnlyInjectedDirectoryAndUsesFakeLaunchctl() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let realBefore = fileFingerprint(realLaunchAgentPlist)
        let realLaunchctlBefore = SystemLaunchctlRunner.invocationCount
        let launchctl = RecordingLaunchctlRunner()
        let appURL = root.appendingPathComponent("AgentSignalLight.app", isDirectory: true)
        let manager = LaunchAtLoginManager(
            appURL: appURL,
            launchAgentDirectory: root.appendingPathComponent("LaunchAgents", isDirectory: true),
            stateDirectoryURL: root.appendingPathComponent("state", isDirectory: true),
            launchctl: launchctl,
            userID: 501
        )

        try manager.setEnabled(true)

        let data = try Data(contentsOf: manager.plistURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        XCTAssertEqual(plist["Label"] as? String, LaunchAtLoginManager.defaultLabel)
        XCTAssertEqual(plist["ProgramArguments"] as? [String], ["/usr/bin/open", appURL.path])
        XCTAssertEqual(launchctl.calls, [
            ["bootout", "gui/501", manager.plistURL.path],
            ["bootstrap", "gui/501", manager.plistURL.path]
        ])

        launchctl.statusForPrint = 0
        XCTAssertTrue(manager.isEnabled)
        XCTAssertEqual(launchctl.calls.last, ["print", "gui/501/\(LaunchAtLoginManager.defaultLabel)"])

        try manager.setEnabled(false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: manager.plistURL.path))
        XCTAssertEqual(launchctl.calls.last, ["bootout", "gui/501", manager.plistURL.path])

        XCTAssertEqual(SystemLaunchctlRunner.invocationCount, realLaunchctlBefore)
        XCTAssertEqual(fileFingerprint(realLaunchAgentPlist), realBefore)
    }

    func testInstallFailsWithoutAppBundleAndWritesNothing() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let launchctl = RecordingLaunchctlRunner()
        let manager = LaunchAtLoginManager(
            appURL: nil,
            launchAgentDirectory: root.appendingPathComponent("LaunchAgents", isDirectory: true),
            stateDirectoryURL: root.appendingPathComponent("state", isDirectory: true),
            launchctl: launchctl
        )

        XCTAssertThrowsError(try manager.setEnabled(true)) { error in
            XCTAssertEqual(error as? LaunchAtLoginError, .notRunningFromAppBundle)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: manager.plistURL.path))
        XCTAssertTrue(launchctl.calls.isEmpty)
    }

    func testFailedBootstrapRemovesPlist() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let launchctl = RecordingLaunchctlRunner()
        launchctl.statusForBootstrap = 5
        let manager = LaunchAtLoginManager(
            appURL: root.appendingPathComponent("AgentSignalLight.app", isDirectory: true),
            launchAgentDirectory: root.appendingPathComponent("LaunchAgents", isDirectory: true),
            stateDirectoryURL: root.appendingPathComponent("state", isDirectory: true),
            launchctl: launchctl
        )

        XCTAssertThrowsError(try manager.setEnabled(true)) { error in
            XCTAssertEqual(error as? LaunchAtLoginError, .launchctlFailed("bootstrap failed"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: manager.plistURL.path))
    }

    func testSystemLaunchctlRunnerRefusesInsideTestProcess() {
        let before = SystemLaunchctlRunner.invocationCount

        XCTAssertThrowsError(try SystemLaunchctlRunner().run(arguments: ["print", "gui/0/none"])) { error in
            XCTAssertEqual(error as? LaunchAtLoginError, .launchctlUnavailableInTests)
        }
        XCTAssertEqual(SystemLaunchctlRunner.invocationCount, before)
    }

    @MainActor
    func testModelWithDefaultManagerNeverTouchesRealLoginItemOrLaunchctl() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "launch-at-login-isolation-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let realBefore = fileFingerprint(realLaunchAgentPlist)
        let realLaunchctlBefore = SystemLaunchctlRunner.invocationCount

        let model = MenuBarStatusModel(
            store: SignalStateStore(stateFileURL: root.appendingPathComponent("status.json")),
            userDefaults: defaults,
            startsMonitoring: false,
            codexTokenActivityScanner: CodexTokenActivityScanner(
                sessionRootURLs: [],
                cacheURL: root.appendingPathComponent("tokens.json"),
                costUsageCacheRootURL: root.appendingPathComponent("cost")
            ),
            performsAccountSwitchBackgroundRefreshes: false
        )

        model.setLaunchAtLoginEnabled(true)
        try await waitForLaunchAtLoginChange(model)

        XCTAssertFalse(model.isLaunchAtLoginEnabled)
        XCTAssertEqual(SystemLaunchctlRunner.invocationCount, realLaunchctlBefore)
        XCTAssertEqual(fileFingerprint(realLaunchAgentPlist), realBefore)
    }

    @MainActor
    func testModelUsesInjectedLaunchctlRunner() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "launch-at-login-injected-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let launchctl = RecordingLaunchctlRunner()
        launchctl.statusForPrint = 0
        let manager = LaunchAtLoginManager(
            appURL: root.appendingPathComponent("AgentSignalLight.app", isDirectory: true),
            launchAgentDirectory: root.appendingPathComponent("LaunchAgents", isDirectory: true),
            stateDirectoryURL: root.appendingPathComponent("state", isDirectory: true),
            launchctl: launchctl,
            userID: 501
        )
        let realLaunchctlBefore = SystemLaunchctlRunner.invocationCount

        let model = MenuBarStatusModel(
            store: SignalStateStore(stateFileURL: root.appendingPathComponent("status.json")),
            userDefaults: defaults,
            startsMonitoring: false,
            launchAtLoginManager: manager,
            codexTokenActivityScanner: CodexTokenActivityScanner(
                sessionRootURLs: [],
                cacheURL: root.appendingPathComponent("tokens.json"),
                costUsageCacheRootURL: root.appendingPathComponent("cost")
            ),
            performsAccountSwitchBackgroundRefreshes: false
        )

        model.setLaunchAtLoginEnabled(true)
        try await waitForLaunchAtLoginChange(model)

        XCTAssertTrue(model.isLaunchAtLoginEnabled)
        XCTAssertTrue(launchctl.calls.contains(["bootstrap", "gui/501", manager.plistURL.path]))
        XCTAssertEqual(SystemLaunchctlRunner.invocationCount, realLaunchctlBefore)
    }

    @MainActor
    private func waitForLaunchAtLoginChange(_ model: MenuBarStatusModel) async throws {
        let deadline = Date().addingTimeInterval(5)
        while model.isLaunchAtLoginChangeRunning {
            guard Date() < deadline else {
                return XCTFail("launch-at-login change did not finish")
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private struct FileFingerprint: Equatable {
        var exists: Bool
        var modificationDate: Date?
        var contents: Data?
    }

    private func fileFingerprint(_ url: URL) -> FileFingerprint {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return FileFingerprint(
            exists: attributes != nil,
            modificationDate: attributes?[.modificationDate] as? Date,
            contents: try? Data(contentsOf: url)
        )
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "agent-signal-launch-isolation-\(UUID().uuidString)",
            isDirectory: true
        )
    }
}

/// Fake `launchctl` that records every call and never launches a process.
final class RecordingLaunchctlRunner: LaunchctlRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCalls: [[String]] = []
    private var printStatus: Int32 = 1
    private var bootstrapStatus: Int32 = 0

    var calls: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return recordedCalls
    }

    var statusForPrint: Int32 {
        get { lock.lock(); defer { lock.unlock() }; return printStatus }
        set { lock.lock(); printStatus = newValue; lock.unlock() }
    }

    var statusForBootstrap: Int32 {
        get { lock.lock(); defer { lock.unlock() }; return bootstrapStatus }
        set { lock.lock(); bootstrapStatus = newValue; lock.unlock() }
    }

    func run(arguments: [String]) throws -> LaunchctlResult {
        lock.lock()
        defer { lock.unlock() }
        recordedCalls.append(arguments)
        switch arguments.first {
        case "print":
            return LaunchctlResult(terminationStatus: printStatus)
        case "bootstrap":
            return LaunchctlResult(
                terminationStatus: bootstrapStatus,
                standardError: bootstrapStatus == 0 ? "" : "bootstrap failed"
            )
        default:
            return LaunchctlResult(terminationStatus: 0)
        }
    }
}

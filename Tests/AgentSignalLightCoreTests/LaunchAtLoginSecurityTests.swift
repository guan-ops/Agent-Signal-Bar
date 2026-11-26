import Darwin
import Foundation
import XCTest
@testable import AgentSignalLight
@testable import AgentSignalLightCore

final class LaunchAtLoginSecurityTests: XCTestCase {
    func testLaunchLogsArePrivateRegularFiles() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let stateDirectory = root.appendingPathComponent("state", isDirectory: true)
        let manager = LaunchAtLoginManager(
            appURL: root.appendingPathComponent("AgentSignalLight.app"),
            launchAgentDirectory: root.appendingPathComponent("LaunchAgents", isDirectory: true),
            stateDirectoryURL: stateDirectory
        )

        try manager.prepareStateDirectoryAndLogs()

        XCTAssertEqual(try permissions(of: stateDirectory), 0o700)
        for name in ["app.out.log", "app.err.log"] {
            let logURL = stateDirectory.appendingPathComponent(name)
            XCTAssertEqual(try permissions(of: logURL), 0o600)
            var info = stat()
            XCTAssertEqual(Darwin.lstat(logURL.path, &info), 0)
            XCTAssertEqual(info.st_mode & mode_t(S_IFMT), mode_t(S_IFREG))
            XCTAssertEqual(info.st_nlink, 1)
        }
    }

    func testLaunchLogSymlinkIsRejectedWithoutTouchingTarget() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let stateDirectory = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(
            at: stateDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        let target = root.appendingPathComponent("target.txt")
        try Data("do-not-touch".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: stateDirectory.appendingPathComponent("app.out.log"),
            withDestinationURL: target
        )
        let manager = LaunchAtLoginManager(
            appURL: root.appendingPathComponent("AgentSignalLight.app"),
            launchAgentDirectory: root.appendingPathComponent("LaunchAgents", isDirectory: true),
            stateDirectoryURL: stateDirectory
        )

        XCTAssertThrowsError(try manager.prepareStateDirectoryAndLogs()) { error in
            guard case SignalStateStoreError.unsafeStateFile = error else {
                return XCTFail("Expected unsafeStateFile, got \(error)")
            }
        }
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "do-not-touch")
    }

    func testLaunchManagerRejectsExplicitDirectoryWithExtendedACL() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let stateDirectory = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(
            at: stateDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["+a", "everyone allow write", stateDirectory.path]
        try chmod.run()
        chmod.waitUntilExit()
        XCTAssertEqual(chmod.terminationStatus, 0)
        let manager = LaunchAtLoginManager(
            appURL: root.appendingPathComponent("AgentSignalLight.app"),
            launchAgentDirectory: root.appendingPathComponent("LaunchAgents", isDirectory: true),
            stateDirectoryURL: stateDirectory
        )

        XCTAssertThrowsError(try manager.prepareStateDirectoryAndLogs()) { error in
            guard case SignalStateStoreError.unsafeStateDirectory = error else {
                return XCTFail("Expected unsafeStateDirectory, got \(error)")
            }
        }
    }

    func testOnlyAnAppBundleCanBeRegistered() {
        // `Bundle.main.bundleURL` of the shipped app: a directory URL ending in ".app/".
        let app = URL(fileURLWithPath: "/Applications/AgentSignalLight.app", isDirectory: true)
        XCTAssertTrue(LaunchAtLoginManager(appURL: app).canRegister)
        XCTAssertTrue(LaunchAtLoginManager(appURL: URL(fileURLWithPath: "/tmp/Agent Signal.APP/")).canRegister)

        // What a test runner or `swift run` reports: the folder that holds the executable.
        let folder = URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer/usr/bin", isDirectory: true)
        XCTAssertFalse(LaunchAtLoginManager(appURL: folder).canRegister)
        XCTAssertFalse(LaunchAtLoginManager().canRegister, "The test runner is not an app bundle")
    }

    func testEnablingWithoutAnAppBundleThrowsAndWritesNothing() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let launchAgents = root.appendingPathComponent("LaunchAgents", isDirectory: true)
        let stateDirectory = root.appendingPathComponent("state", isDirectory: true)
        let manager = LaunchAtLoginManager(
            appURL: root.appendingPathComponent("bin", isDirectory: true),
            launchAgentDirectory: launchAgents,
            stateDirectoryURL: stateDirectory
        )

        for enabled in [true, false] {
            XCTAssertThrowsError(try manager.setEnabled(enabled)) { error in
                guard case LaunchAtLoginError.notAnAppBundle = error else {
                    return XCTFail("Expected notAnAppBundle, got \(error)")
                }
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: launchAgents.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "agent-signal-launch-security-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
    }
}

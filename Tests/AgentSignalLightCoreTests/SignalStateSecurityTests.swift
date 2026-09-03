import Darwin
import Foundation
import XCTest
@testable import AgentSignalLightCore

final class SignalStateSecurityTests: XCTestCase {
    func testDefaultStateLocationIsPerUserApplicationSupportAndOverridesKeepPriority() {
        let applicationSupport = URL(
            fileURLWithPath: "/Users/tester/Library/Application Support",
            isDirectory: true
        )
        let defaultURL = SignalStateStore.defaultStateFileURL(
            environment: [:],
            applicationSupportDirectory: applicationSupport
        )
        XCTAssertEqual(
            defaultURL.path,
            "/Users/tester/Library/Application Support/Agent Signal Bar/SignalState/status.json"
        )

        let directoryOverride = SignalStateStore.defaultStateFileURL(
            environment: [
                "AGENT_SIGNAL_LIGHT_STATE_DIR": "/tmp/primary-dir",
                "SIGNAL_LIGHT_STATE_DIR": "/tmp/legacy-dir"
            ],
            applicationSupportDirectory: applicationSupport
        )
        XCTAssertEqual(directoryOverride.path, "/tmp/primary-dir/status.json")

        let fileOverride = SignalStateStore.defaultStateFileURL(
            environment: [
                "AGENT_SIGNAL_LIGHT_STATE_FILE": "/tmp/explicit.json",
                "AGENT_SIGNAL_LIGHT_STATE_DIR": "/tmp/primary-dir",
                "SIGNAL_LIGHT_STATE_DIR": "/tmp/legacy-dir"
            ],
            applicationSupportDirectory: applicationSupport
        )
        XCTAssertEqual(fileOverride.path, "/tmp/explicit.json")
    }

    func testNewStateDirectoryAndLeafFilesUsePrivatePermissions() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let stateDirectory = root.appendingPathComponent("private-state", isDirectory: true)
        let stateFile = stateDirectory.appendingPathComponent("status.json")
        let store = SignalStateStore(stateFileURL: stateFile)

        _ = try store.setManualSignal(.working)

        XCTAssertEqual(try permissions(of: stateDirectory), 0o700)
        XCTAssertEqual(try permissions(of: stateFile), 0o600)
        XCTAssertEqual(try permissions(of: stateDirectory.appendingPathComponent("state.lock")), 0o600)
    }

    func testStateFileSymlinkIsRejectedWithoutTouchingTarget() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let stateDirectory = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("target.txt")
        try Data("do-not-change".utf8).write(to: target)
        let stateFile = stateDirectory.appendingPathComponent("status.json")
        try FileManager.default.createSymbolicLink(at: stateFile, withDestinationURL: target)
        let store = SignalStateStore(stateFileURL: stateFile)

        XCTAssertThrowsError(try store.setManualSignal(.working)) { error in
            guard case SignalStateStoreError.unsafeStateFile = error else {
                return XCTFail("Expected unsafeStateFile, got \(error)")
            }
        }
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "do-not-change")
        XCTAssertEqual(store.readSnapshot().aggregate, .stale)
    }

    func testLockSymlinkIsRejectedAndLockFailureDoesNotReadStateUnlocked() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let stateDirectory = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("lock-target.txt")
        try Data("lock-target".utf8).write(to: target)
        let lockFile = stateDirectory.appendingPathComponent("state.lock")
        try FileManager.default.createSymbolicLink(at: lockFile, withDestinationURL: target)
        let store = SignalStateStore(stateFileURL: stateDirectory.appendingPathComponent("status.json"))

        XCTAssertThrowsError(try store.setManualSignal(.working)) { error in
            guard case SignalStateStoreError.cannotOpenLock = error else {
                return XCTFail("Expected cannotOpenLock, got \(error)")
            }
        }
        XCTAssertEqual(store.readSnapshot().aggregate, .stale)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "lock-target")
    }

    func testExplicitStateDirectoryWithExtendedACLIsRejected() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let stateDirectory = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(
            at: stateDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        try addEveryoneWriteACL(to: stateDirectory)
        XCTAssertTrue(try hasExtendedACL(at: stateDirectory))

        let store = SignalStateStore(stateFileURL: stateDirectory.appendingPathComponent("status.json"))
        XCTAssertThrowsError(try store.setManualSignal(.working)) { error in
            guard case SignalStateStoreError.unsafeStateDirectory = error else {
                return XCTFail("Expected unsafeStateDirectory, got \(error)")
            }
        }
    }

    func testStateAndLockExtendedACLsAreRemovedBeforeUse() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let stateDirectory = root.appendingPathComponent("state", isDirectory: true)
        let stateFile = stateDirectory.appendingPathComponent("status.json")
        let lockFile = stateDirectory.appendingPathComponent("state.lock")
        let store = SignalStateStore(stateFileURL: stateFile)
        _ = try store.setManualSignal(.working)

        try addEveryoneWriteACL(to: stateFile)
        try addEveryoneWriteACL(to: lockFile)
        XCTAssertTrue(try hasExtendedACL(at: stateFile))
        XCTAssertTrue(try hasExtendedACL(at: lockFile))

        _ = try store.setManualSignal(.thinking)

        XCTAssertFalse(try hasExtendedACL(at: stateFile))
        XCTAssertFalse(try hasExtendedACL(at: lockFile))
        XCTAssertEqual(try permissions(of: stateFile), 0o600)
        XCTAssertEqual(try permissions(of: lockFile), 0o600)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "agent-signal-state-security-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
    }

    private func addEveryoneWriteACL(to url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = ["+a", "everyone allow write", url.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "Could not add test ACL to \(url.path)")
    }

    private func hasExtendedACL(at url: URL) throws -> Bool {
        let fileDescriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fileDescriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { Darwin.close(fileDescriptor) }

        errno = 0
        guard let acl = acl_get_fd_np(fileDescriptor, ACL_TYPE_EXTENDED) else {
            if errno == ENOENT { return false }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        acl_free(UnsafeMutableRawPointer(acl))
        return true
    }
}

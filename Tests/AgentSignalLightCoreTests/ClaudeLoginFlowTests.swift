import Foundation
import XCTest
@testable import AgentSignalLight

final class ClaudeLoginFlowTests: XCTestCase {
    func testLoginUsesTTYAndAnswersBrowserPrompt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("claude-login-fixture-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fake claude")
        let script = "#!/bin/sh\n[ \"$1\" = auth ] && [ \"$2\" = login ] && [ \"$3\" = --claudeai ] || exit 7\n[ -t 0 ] && [ -t 1 ] || exit 8\nprintf 'press \\033[1mENTER\\033[0m to open in browser'\nread answer\nexit 0\n"
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try await ClaudeLoginRunner.run(executable, timeout: 2)
    }

    func testTimeoutAndCancellationStopWaitingForBrowser() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("claude-login-wait-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fixture")
        try "#!/bin/sh\nread answer\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        do { try await ClaudeLoginRunner.run(executable, timeout: 0.15); XCTFail("Expected timeout") }
        catch { XCTAssertEqual(error as? ClaudeSupportError, .timedOut) }
        let work = Task { try await ClaudeLoginRunner.run(executable, timeout: 30) }
        try await Task.sleep(for: .milliseconds(100))
        work.cancel()
        do { try await work.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    @MainActor
    func testSuccessfulLoginAutomaticallyReadsCredentialsAndRefreshesQuota() async throws {
        let suite = "claude-login-model-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("/usr/bin/true", forKey: "claude.executablePath")
        defaults.set("web", forKey: "claude.usageSource")
        defaults.set("chrome", forKey: "claude.webBrowser")
        let service = ClaudeUsageService { request in
            let text = request.url!.lastPathComponent == "profile" ? #"{"account":{"email":"fixture@example.invalid"}}"# : #"{"five_hour":{"utilization":17}}"#
            return (Data(text.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let model = ClaudeSupportModel(defaults: defaults, service: service,
            readCredentials: { _ in .init(accessToken: "fixture", expiresAt: nil, plan: "pro") },
            loginRunner: { _ in }, historyLoader: { _ in .init(data: [], summary: nil) })
        XCTAssertNil(defaults.object(forKey: "claude.usageSource"))
        XCTAssertNil(defaults.object(forKey: "claude.webBrowser"))
        model.login()
        for _ in 0..<300 where model.isLoggingIn || model.isRefreshing { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(model.credentialConsent)
        XCTAssertEqual(model.snapshot?.email, "fixture@example.invalid")
        XCTAssertEqual(model.snapshot?.windows.first?.usedPercent, 17)
    }

    @MainActor
    func testMissingCLIShowsInstallGuidanceWithoutStartingAnything() async throws {
        let suite = "claude-missing-cli-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("/missing/claude-fixture", forKey: "claude.executablePath")
        let model = ClaudeSupportModel(defaults: defaults, readCredentials: { _ in
            XCTFail("A missing CLI must not read credentials"); throw ClaudeSupportError.loginRequired
        }, loginRunner: { _ in XCTFail("A missing CLI must not start sign-in") },
            historyLoader: { _ in .init(data: [], summary: nil) })
        XCTAssertFalse(model.hasClaudeCLI)
        model.login()
        XCTAssertFalse(model.isLoggingIn)
        XCTAssertFalse(model.accountActionInProgress)
        XCTAssertEqual(model.loginMessage, ClaudeSupportModel.missingCLIMessage)
        XCTAssertTrue(ClaudeSupportModel.missingCLIMessage.contains(ClaudeSupportModel.installCommand))
        XCTAssertFalse(model.credentialConsent)
    }

    @MainActor
    func testFailedLoginDoesNotEnableCredentialRead() async throws {
        let suite = "claude-login-failure-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("/usr/bin/false", forKey: "claude.executablePath")
        let model = ClaudeSupportModel(defaults: defaults, readCredentials: { _ in
            XCTFail("Failed login must not read credentials"); throw ClaudeSupportError.loginRequired
        }, loginRunner: { _ in throw ClaudeSupportError.commandFailed }, historyLoader: { _ in .init(data: [], summary: nil) })
        model.login()
        for _ in 0..<300 where model.isLoggingIn { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.credentialConsent)
        XCTAssertNil(model.snapshot)
        XCTAssertNotNil(model.loginMessage)
    }
}

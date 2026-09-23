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

    func testInstallerExecutesDownloadedScriptAndRequiresUsableBinary() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("claude-install-fixture-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent(".local/bin/claude")
        let binPath = ClaudeCommandRunner.shellQuote(binary.path)
        let binFolder = ClaudeCommandRunner.shellQuote(binary.deletingLastPathComponent().path)
        let script = "#!/bin/bash\n[ \"$1\" = stable ] || exit 9\nmkdir -p " + binFolder + "\nprintf '#!/bin/sh\\n[ \"$1\" = --version ] || exit 3\\n' > " + binPath + "\nchmod 700 " + binPath + "\n"
        let installed = try await ClaudeCLIInstaller.install(homeDirectory: root, download: { Data(script.utf8) })
        XCTAssertEqual(installed, binary)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: binary.path))
        let reused = try await ClaudeCLIInstaller.install(homeDirectory: root, download: { XCTFail("Existing CLI downloaded again"); return Data() })
        XCTAssertEqual(reused, binary)
    }

    func testInstallerRejectsHTMLAndSuccessfulExitWithoutInstalledCLI() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("claude-install-invalid-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        do { _ = try await ClaudeCLIInstaller.install(homeDirectory: root, download: { Data("<html>error</html>".utf8) }); XCTFail("HTML was executed") }
        catch { XCTAssertEqual(error as? ClaudeSupportError, .invalidResponse) }
        do { _ = try await ClaudeCLIInstaller.install(homeDirectory: root, download: { Data("#!/bin/bash\nexit 0\n".utf8) }); XCTFail("Missing executable accepted") }
        catch { XCTAssertEqual(error as? ClaudeSupportError, .missingCLI) }
    }

    @MainActor
    func testInstallSuccessContinuesIntoLoginAndFailureDoesNot() async throws {
        for fails in [false, true] {
            let suite = "claude-install-flow-\(UUID())"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set("/missing/claude-fixture", forKey: "claude.executablePath")
            let service = ClaudeUsageService { request in
                let text = request.url!.lastPathComponent == "profile" ? #"{"account":{"email":"installed@example.invalid"}}"# : #"{"five_hour":{"utilization":12}}"#
                return (Data(text.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            let model = ClaudeSupportModel(defaults: defaults, service: service,
                readCredentials: { _ in .init(accessToken: "fixture", expiresAt: nil, plan: nil) },
                loginRunner: { _ in if fails { XCTFail("Failed installation started login") } },
                installRunner: {
                    if fails { throw ClaudeSupportError.commandFailed }
                    return URL(fileURLWithPath: "/usr/bin/true")
                }, historyLoader: { _ in .init(data: [], summary: nil) })
            model.installAndLogin()
            for _ in 0..<300 where model.isInstallingCLI || model.isLoggingIn || model.isRefreshing {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertFalse(model.isInstallingCLI)
            if fails {
                XCTAssertNil(model.snapshot)
                XCTAssertFalse(model.credentialConsent)
                XCTAssertNotNil(model.loginMessage)
            } else {
                XCTAssertEqual(model.snapshot?.email, "installed@example.invalid")
                XCTAssertEqual(model.claudePath, "/usr/bin/true")
            }
        }
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

import Foundation
import Security
import LocalAuthentication
import XCTest
@testable import AgentSignalLight

final class ClaudeSilentCredentialTests: XCTestCase {
    func testLegacyInteractionFlagIsDisabledAndRestoredIncludingNestedCalls() throws {
        let before = try XCTUnwrap(KeychainInteractionPolicy.isInteractionAllowed)
        let result = KeychainInteractionPolicy.perform(allowInteraction: false) {
            XCTAssertEqual(KeychainInteractionPolicy.isInteractionAllowed, false)
            return KeychainInteractionPolicy.perform(allowInteraction: false) {
                XCTAssertEqual(KeychainInteractionPolicy.isInteractionAllowed, false)
                return errSecAuthFailed
            }
        }
        XCTAssertEqual(result, errSecAuthFailed)
        XCTAssertEqual(KeychainInteractionPolicy.isInteractionAllowed, before, "Never leave a process-wide setting changed")
    }

    func testAllowedInteractionLeavesTheLegacyFlagUntouched() throws {
        let before = try XCTUnwrap(KeychainInteractionPolicy.isInteractionAllowed)
        let result = KeychainInteractionPolicy.perform(allowInteraction: true) {
            XCTAssertEqual(KeychainInteractionPolicy.isInteractionAllowed, before)
            return errSecSuccess
        }
        XCTAssertEqual(result, errSecSuccess)
        XCTAssertEqual(KeychainInteractionPolicy.isInteractionAllowed, before)
    }

    func testSilentReadFailsClosedInsteadOfUsingAnAmbientCredentialFile() throws {
        let root = URL(fileURLWithPath: "/private/tmp/claude-silent-reader-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent(".claude/.credentials.json")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data(#"{"claudeAiOauth":{"accessToken":"synthetic-file-owner"}}"#.utf8)
        try data.write(to: path)
        for status in [errSecInteractionNotAllowed, errSecInteractionRequired, errSecAuthFailed, errSecUserCanceled] {
            XCTAssertThrowsError(try ClaudeCredentialReader.read(allowPrompt: false, environment: [:], home: root, keychainRead: { query in
                XCTAssertEqual(query[kSecAttrService as String] as? String, "Claude Code-credentials")
                XCTAssertEqual((query[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed, true)
                XCTAssertEqual(KeychainInteractionPolicy.isInteractionAllowed, false)
                return (status, nil)
            })) { XCTAssertEqual($0 as? ClaudeSupportError, .keychainDenied) }
        }
        let missing = try ClaudeCredentialReader.read(allowPrompt: false, environment: [:], home: root, keychainRead: { _ in (errSecItemNotFound, nil) })
        XCTAssertEqual(missing.accessToken, "synthetic-file-owner", "File fallback is only for a missing keychain item")
        let profile = try ClaudeCredentialReader.read(allowPrompt: false, environment: ["CLAUDE_CONFIG_DIR": path.deletingLastPathComponent().path], home: root, keychainRead: { _ in
            XCTFail("A custom profile must never query an ambient keychain"); return (errSecAuthFailed, nil)
        })
        XCTAssertEqual(profile.identity, missing.identity)
    }

    @MainActor
    func testDeniedReadsStopRepeatingAndOnlyExplicitAuthorizationCanPrompt() async throws {
        let suite = "claude-silent-model-\(UUID())", trace = SilentReadTrace()
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "claude.credentialConsent")
        let model = ClaudeSupportModel(defaults: defaults, readCredentials: { allow in
            trace.append(allow); throw ClaudeSupportError.keychainDenied
        }, historyLoader: { _ in .init(data: [], summary: nil) })
        for _ in 0..<3 { model.refresh(force: true); try await wait(model) }
        XCTAssertEqual(trace.values, [false])
        XCTAssertTrue(model.credentialReadBlocked)
        XCTAssertNotNil(model.historyUpdatedAt)
        model.allowCredentialRead(); try await wait(model)
        XCTAssertEqual(trace.values, [false, false], "Read existing login is a silent retry")
        model.authorizeCredentialRead(); try await wait(model)
        XCTAssertEqual(trace.values, [false, false, true])
        model.refresh(force: true); try await wait(model)
        XCTAssertEqual(trace.values.count, 3)
        model.resetIdentity()
    }

    @MainActor
    func testCLIOptionNeverReadsClaudeCredentialsAndKeepsLocalHistory() async throws {
        let suite = "claude-no-keychain-cli-\(UUID())", trace = SilentReadTrace()
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "claude.credentialConsent")
        defaults.set("/bin/echo", forKey: "claude.executablePath")
        let model = ClaudeSupportModel(defaults: defaults, readCredentials: { allow in
            trace.append(allow); throw ClaudeSupportError.keychainDenied
        }, historyLoader: { _ in .init(data: [], summary: nil) }, cliProbe: { _, owner in
            try ClaudeCLIUsageProbe.parse("Current session\n20% used\nResets in 2h", owner: owner)
        })
        model.useCLIWithoutCredentialRead(); try await wait(model)
        XCTAssertTrue(trace.values.isEmpty)
        XCTAssertFalse(model.credentialConsent)
        XCTAssertEqual(model.usageSource, .cli)
        XCTAssertEqual(model.snapshot?.source, "Claude CLI")
        XCTAssertEqual(model.snapshot?.windows.first?.usedPercent, 20)
        XCTAssertTrue(model.quotaSamples(windowID: "five_hour").isEmpty, "No account history for an unverified owner")
        XCTAssertEqual(model.historySummary().today.tokens, 0)
        XCTAssertFalse(model.cliBackgroundEnabled, "Choosing a source does not silently enable background subprocesses")
        model.resetIdentity()
    }

    @MainActor
    func testLoginCompletionDoesNotOpenASecondKeychainDialog() async throws {
        for source in [ClaudeUsageSource.oauth, .cli] {
            let suite = "claude-silent-login-\(UUID())", trace = SilentReadTrace()
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set("/bin/echo", forKey: "claude.executablePath")
            defaults.set(source.rawValue, forKey: "claude.providerSource")
            let model = ClaudeSupportModel(defaults: defaults, readCredentials: { allow in
                trace.append(allow); throw ClaudeSupportError.keychainDenied
            }, loginRunner: { _ in }, historyLoader: { _ in .init(data: [], summary: nil) }, cliProbe: { _, owner in
                try ClaudeCLIUsageProbe.parse("Current session\n20% used", owner: owner)
            })
            model.login()
            for _ in 0..<300 where model.isLoggingIn || model.isRefreshing { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertFalse(trace.values.contains(true))
            if source == .cli { XCTAssertTrue(trace.values.isEmpty); XCTAssertFalse(model.credentialConsent) }
            else { XCTAssertEqual(trace.values, [false]); XCTAssertTrue(model.credentialReadBlocked) }
            model.resetIdentity()
        }
    }

    @MainActor private func wait(_ model: ClaudeSupportModel) async throws {
        for _ in 0..<300 where model.isRefreshing { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.isRefreshing)
    }
}

private final class SilentReadTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Bool] = []
    var values: [Bool] { lock.lock(); defer { lock.unlock() }; return stored }
    func append(_ value: Bool) { lock.lock(); stored.append(value); lock.unlock() }
}

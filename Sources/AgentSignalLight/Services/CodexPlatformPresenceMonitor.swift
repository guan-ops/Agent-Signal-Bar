import AgentSignalLightCore
import AppKit
import Foundation

final class CodexPlatformPresenceMonitor: @unchecked Sendable {
    struct RunningApplicationInfo: Equatable, Sendable {
        let bundleIdentifier: String?
        let localizedName: String?
    }

    struct RunningProcessInfo: Equatable, Sendable {
        let pid: Int?
        let command: String
        let arguments: String
    }

    private struct PlatformDefinition: Sendable {
        let sessionID: String
        let agent: String
        let event: String
        let appBundleIdentifiers: Set<String>
        let appNameTokens: Set<String>
        let processMatch: @Sendable (RunningProcessInfo) -> Bool
    }

    private static let processScanTimeoutSeconds: TimeInterval = 0.7

    func detectSessions(now: Date = Date()) -> [SessionStatus] {
        Self.detectSessions(
            applications: NSWorkspace.shared.runningApplications.map {
                RunningApplicationInfo(
                    bundleIdentifier: $0.bundleIdentifier,
                    localizedName: $0.localizedName
                )
            },
            processes: Self.runningProcesses(),
            now: now
        )
    }

    static func detectSessions(
        applications: [RunningApplicationInfo],
        processes: [RunningProcessInfo],
        now: Date = Date()
    ) -> [SessionStatus] {
        definitions.compactMap { definition in
            let isRunning =
                appIsRunning(definition, applications: applications)
                || processes.contains(where: definition.processMatch)

            guard isRunning else { return nil }
            return SessionStatus(
                sessionID: definition.sessionID,
                signal: .idle,
                updatedAt: now,
                agent: definition.agent,
                lastEvent: definition.event
            )
        }
    }

    private static let definitions: [PlatformDefinition] = [
        PlatformDefinition(
            sessionID: "platform-presence:codex-desktop",
            agent: "codex-desktop",
            event: "PlatformPresence:Desktop",
            appBundleIdentifiers: ["com.openai.codex"],
            appNameTokens: ["codex"],
            processMatch: { process in
                let commandLine = process.commandLine
                return commandLine.contains("/applications/codex.app/")
                    && commandLine.contains("/contents/macos/codex")
            }
        ),
        PlatformDefinition(
            sessionID: "platform-presence:codex-cli",
            agent: "codex-cli",
            event: "PlatformPresence:CLI",
            appBundleIdentifiers: [],
            appNameTokens: [],
            processMatch: { process in
                process.looksLikeCodexCLI
            }
        ),
        PlatformDefinition(
            sessionID: "platform-presence:codex-vscode",
            agent: "codex-vscode",
            event: "PlatformPresence:VSCode",
            appBundleIdentifiers: [],
            appNameTokens: [],
            processMatch: { process in
                let commandLine = process.commandLine
                return commandLine.contains("/openai.chatgpt/")
                    || (
                        commandLine.contains("/.vscode/extensions/")
                        && commandLine.contains("codex")
                    )
            }
        ),
        PlatformDefinition(
            sessionID: "platform-presence:codex-xcode",
            agent: "codex-xcode",
            event: "PlatformPresence:Xcode",
            appBundleIdentifiers: [],
            appNameTokens: [],
            processMatch: { process in
                let commandLine = process.commandLine
                return commandLine.contains("/library/developer/xcode/codingassistant/")
                    || commandLine.contains("/codingassistant/agents/")
            }
        ),
        PlatformDefinition(
            sessionID: "platform-presence:codex-idea",
            agent: "codex-idea",
            event: "PlatformPresence:IDEA",
            appBundleIdentifiers: [],
            appNameTokens: [],
            processMatch: { process in
                let commandLine = process.commandLine
                return commandLine.contains("/library/caches/jetbrains/")
                    && commandLine.contains("/aia/codex/")
            }
        ),
        PlatformDefinition(
            sessionID: "platform-presence:claude-desktop",
            agent: "claude-desktop",
            event: "PlatformPresence:Desktop",
            appBundleIdentifiers: [
                "com.anthropic.claudefordesktop",
                "com.anthropic.claude"
            ],
            appNameTokens: ["claude"],
            processMatch: { process in
                let commandLine = process.commandLine
                return commandLine.contains("/applications/claude.app/")
                    && commandLine.contains("/contents/macos/claude")
            }
        )
    ]

    private static func appIsRunning(
        _ definition: PlatformDefinition,
        applications: [RunningApplicationInfo]
    ) -> Bool {
        applications.contains { application in
            if let bundleIdentifier = normalized(application.bundleIdentifier),
               definition.appBundleIdentifiers.contains(bundleIdentifier) {
                return true
            }

            guard let localizedName = normalized(application.localizedName) else {
                return false
            }

            return definition.appNameTokens.contains(localizedName)
        }
    }

    private static func runningProcesses() -> [RunningProcessInfo] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,comm=,args="]

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-signal-ps-\(UUID().uuidString).txt")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil),
              let outputHandle = try? FileHandle(forWritingTo: outputURL)
        else {
            return []
        }
        defer {
            try? outputHandle.close()
            try? FileManager.default.removeItem(at: outputURL)
        }

        let errorPipe = Pipe()
        process.standardOutput = outputHandle
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            return []
        }

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            semaphore.signal()
        }

        if semaphore.wait(timeout: .now() + processScanTimeoutSeconds) == .timedOut {
            process.terminate()
            _ = semaphore.wait(timeout: .now() + 0.2)
            return []
        }

        guard process.terminationStatus == 0 else {
            return []
        }

        let data = (try? Data(contentsOf: outputURL)) ?? Data()
        _ = errorPipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else {
            return []
        }

        return parseProcesses(from: output)
    }

    static func parseProcesses(from output: String) -> [RunningProcessInfo] {
        output
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> RunningProcessInfo? in
                let parts = line.split(
                    separator: " ",
                    maxSplits: 2,
                    omittingEmptySubsequences: true
                )
                guard parts.count >= 2 else { return nil }

                return RunningProcessInfo(
                    pid: Int(parts[0]),
                    command: String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines),
                    arguments: parts.count >= 3
                        ? String(parts[2]).trimmingCharacters(in: .whitespacesAndNewlines)
                        : ""
                )
            }
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized.isEmpty ? nil : normalized
    }
}

private extension CodexPlatformPresenceMonitor.RunningProcessInfo {
    var commandLine: String {
        "\(command) \(arguments)"
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    var looksLikeCodexCLI: Bool {
        let commandName = URL(fileURLWithPath: command).lastPathComponent.lowercased()
        let commandLine = commandLine
        let firstArgumentName = arguments
            .split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map { URL(fileURLWithPath: String($0)).lastPathComponent.lowercased() }

        let looksLikeCodexExecutable =
            commandName == "codex"
            || firstArgumentName == "codex"
            || commandLine == "codex"
            || commandLine.hasPrefix("codex ")
            || commandLine.contains("/bin/codex ")
            || commandLine.contains("/node_modules/.bin/codex")
            || commandLine.contains("/@openai/codex/")

        guard looksLikeCodexExecutable else {
            return false
        }

        guard !commandLine.contains("app-server"),
              !commandLine.contains("/applications/codex.app/"),
              !commandLine.contains("codex computer use.app"),
              !commandLine.contains("skycomputeruseclient"),
              !commandLine.contains("codexbar"),
              !commandLine.contains("/library/developer/xcode/codingassistant/"),
              !commandLine.contains("/library/caches/jetbrains/"),
              !commandLine.contains("/.vscode/extensions/"),
              !commandLine.contains("/openai.chatgpt/")
        else {
            return false
        }

        return true
    }
}

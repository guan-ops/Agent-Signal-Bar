import Foundation

enum CodexExecutableResolver {
    static func effectiveEnvironment(
        from environment: [String: String],
        fileManager: FileManager = .default
    ) -> [String: String] {
        var scoped = environment
        scoped["PATH"] = effectivePATH(from: environment, fileManager: fileManager)
        return scoped
    }

    static func effectivePATH(
        from environment: [String: String],
        fileManager: FileManager = .default
    ) -> String {
        let home = fileManager.homeDirectoryForCurrentUser.path
        let staticCandidates: [String?] = [
            environment["PATH"],
            environment["NVM_BIN"],
            environment["PNPM_HOME"],
            environment["npm_config_prefix"].map { "\($0)/bin" },
            environment["VOLTA_HOME"].map { "\($0)/bin" },
            environment["ASDF_DATA_DIR"].map { "\($0)/shims" },
            environment["BUN_INSTALL"].map { "\($0)/bin" },
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.local/bin",
            "\(home)/.npm-global/bin",
            "\(home)/.npm-packages/bin",
            "\(home)/.volta/bin",
            "\(home)/.asdf/shims",
            "\(home)/.bun/bin"
        ]
        let candidates = staticCandidates
            + nvmVersionBinDirectories(homePath: home, fileManager: fileManager).map(Optional.some)
            + [
                "/usr/bin",
                "/bin",
                "/usr/sbin",
                "/sbin"
            ]

        var seen = Set<String>()
        return candidates
            .flatMap { ($0 ?? "").split(separator: ":").map(String.init) }
            .compactMap { rawPath in
                let trimmed = (rawPath as NSString)
                    .expandingTildeInPath
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !seen.contains(trimmed) else { return nil }
                seen.insert(trimmed)
                return trimmed
            }
            .joined(separator: ":")
    }

    static func resolve(
        environment: [String: String],
        fileManager: FileManager = .default,
        includeLoginShellLookup: Bool = false
    ) -> String? {
        for key in ["CODEX_BINARY", "CODEX_CLI_PATH"] {
            if let explicit = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !explicit.isEmpty {
                let expanded = (explicit as NSString).expandingTildeInPath
                if fileManager.isExecutableFile(atPath: expanded) {
                    return expanded
                }
            }
        }

        if includeLoginShellLookup,
           let executable = loginShellCodexExecutable(environment: environment, fileManager: fileManager) {
            return executable
        }

        for directory in effectivePATH(from: environment, fileManager: fileManager).split(separator: ":").map(String.init) {
            let executable = URL(fileURLWithPath: directory)
                .appendingPathComponent("codex", isDirectory: false)
                .path
            if fileManager.isExecutableFile(atPath: executable) {
                return executable
            }
        }

        for executable in codexDesktopAppCLICandidates(fileManager: fileManager) where fileManager.isExecutableFile(atPath: executable) {
            return executable
        }

        return nil
    }

    private static func loginShellCodexExecutable(
        environment: [String: String],
        fileManager: FileManager
    ) -> String? {
        let commandOutput = runLoginShellCommand(
            #"command -v codex 2>/dev/null || true"#,
            environment: environment,
            fileManager: fileManager
        )
        if let executable = firstExecutablePath(in: commandOutput, fileManager: fileManager) {
            return executable
        }

        let aliasOutput = runLoginShellCommand(
            #"alias codex 2>/dev/null || type codex 2>/dev/null || true"#,
            environment: environment,
            fileManager: fileManager
        )
        return firstExecutablePath(in: aliasOutput, fileManager: fileManager)
    }

    private static func runLoginShellCommand(
        _ command: String,
        environment: [String: String],
        fileManager: FileManager,
        timeout: TimeInterval = 2
    ) -> String {
        let shell = environment["SHELL"]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "/bin/zsh"
        let marker = "__AGENT_SIGNAL_CODEX_LOOKUP__"
        let wrappedCommand = "printf '\(marker)'; \(command); printf '\(marker)'"
        let stdoutURL = temporaryCaptureURL(suffix: "out")
        let stderrURL = temporaryCaptureURL(suffix: "err")

        do {
            try Data().write(to: stdoutURL)
            try Data().write(to: stderrURL)
            let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
            let stderrHandle = try FileHandle(forWritingTo: stderrURL)
            defer {
                try? stdoutHandle.close()
                try? stderrHandle.close()
                try? fileManager.removeItem(at: stdoutURL)
                try? fileManager.removeItem(at: stderrURL)
            }

            var scopedEnvironment = effectiveEnvironment(from: environment, fileManager: fileManager)
            scopedEnvironment["SHELL"] = shell

            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = ["-l", "-i", "-c", wrappedCommand]
            process.environment = scopedEnvironment
            process.standardOutput = stdoutHandle
            process.standardError = stderrHandle

            try process.run()
            waitForProcess(process, timeout: timeout)

            let stdout = String(
                data: (try? Data(contentsOf: stdoutURL)) ?? Data(),
                encoding: .utf8
            ) ?? ""
            guard let first = stdout.range(of: marker),
                  let last = stdout.range(of: marker, options: .backwards),
                  first.upperBound <= last.lowerBound else {
                return stdout
            }
            return String(stdout[first.upperBound..<last.lowerBound])
        } catch {
            try? fileManager.removeItem(at: stdoutURL)
            try? fileManager.removeItem(at: stderrURL)
            return ""
        }
    }

    private static func waitForProcess(_ process: Process, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard process.isRunning else { return }
        process.terminate()
        let killDeadline = Date().addingTimeInterval(0.5)
        while process.isRunning && Date() < killDeadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }

    private static func firstExecutablePath(in output: String, fileManager: FileManager) -> String? {
        let tokens = output
            .split(whereSeparator: { $0.isWhitespace || $0 == "\"" || $0 == "'" || $0 == "`" || $0 == "=" })
            .map(String.init)
        for token in tokens {
            let expanded = (token as NSString)
                .expandingTildeInPath
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:()[]{}"))
            guard expanded.hasPrefix("/") else { continue }
            guard URL(fileURLWithPath: expanded).lastPathComponent == "codex" else { continue }
            if fileManager.isExecutableFile(atPath: expanded) {
                return expanded
            }
        }
        return nil
    }

    private static func temporaryCaptureURL(suffix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-signal-codex-lookup-\(UUID().uuidString).\(suffix)")
    }

    private static func codexDesktopAppCLICandidates(fileManager: FileManager) -> [String] {
        let home = fileManager.homeDirectoryForCurrentUser.path
        return [
            "\(home)/Applications/Codex.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex"
        ]
    }

    private static func nvmVersionBinDirectories(
        homePath: String,
        fileManager: FileManager
    ) -> [String] {
        let versionsRoot = URL(fileURLWithPath: homePath, isDirectory: true)
            .appendingPathComponent(".nvm/versions/node", isDirectory: true)
        guard let versions = try? fileManager.contentsOfDirectory(
            at: versionsRoot,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        return versions
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }
            .map { $0.appendingPathComponent("bin", isDirectory: true).path }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

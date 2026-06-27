import Foundation

struct CodexCLIStatus: Equatable, Sendable {
    let versionText: String?
    let checkedAt: Date
}

final class CodexCLIStatusProbe: @unchecked Sendable {
    private let environment: [String: String]
    private let fileManager: FileManager

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) {
        self.environment = environment
        self.fileManager = fileManager
    }

    func probe(timeout: TimeInterval = 3) -> CodexCLIStatus {
        let checkedAt = Date()
        guard let executable = resolveCodexExecutable() else {
            return CodexCLIStatus(versionText: nil, checkedAt: checkedAt)
        }

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

            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["--version"]
            process.environment = effectiveEnvironment()
            process.standardOutput = stdoutHandle
            process.standardError = stderrHandle

            try process.run()
            let timedOut = waitForProcess(process, timeout: timeout)
            guard !timedOut, process.terminationStatus == 0 else {
                return CodexCLIStatus(versionText: nil, checkedAt: checkedAt)
            }

            let output = combinedOutput(stdoutURL: stdoutURL, stderrURL: stderrURL)
            return CodexCLIStatus(
                versionText: output.isEmpty ? nil : output,
                checkedAt: checkedAt
            )
        } catch {
            try? fileManager.removeItem(at: stdoutURL)
            try? fileManager.removeItem(at: stderrURL)
            return CodexCLIStatus(versionText: nil, checkedAt: checkedAt)
        }
    }

    private func effectiveEnvironment() -> [String: String] {
        var scoped = environment
        scoped["PATH"] = effectivePATH()
        return scoped
    }

    private func effectivePATH() -> String {
        let home = fileManager.homeDirectoryForCurrentUser.path
        let candidates = [
            environment["PATH"],
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.local/bin",
            "\(home)/.npm-global/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        var seen = Set<String>()
        return candidates
            .flatMap { ($0 ?? "").split(separator: ":").map(String.init) }
            .compactMap { rawPath in
                let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !seen.contains(trimmed) else { return nil }
                seen.insert(trimmed)
                return trimmed
            }
            .joined(separator: ":")
    }

    private func resolveCodexExecutable() -> String? {
        if let explicit = environment["CODEX_BINARY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            let expanded = (explicit as NSString).expandingTildeInPath
            if fileManager.isExecutableFile(atPath: expanded) {
                return expanded
            }
        }

        for directory in effectivePATH().split(separator: ":").map(String.init) {
            let executable = URL(fileURLWithPath: directory)
                .appendingPathComponent("codex", isDirectory: false)
                .path
            if fileManager.isExecutableFile(atPath: executable) {
                return executable
            }
        }

        return nil
    }

    private func waitForProcess(_ process: Process, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard process.isRunning else { return false }
        process.terminate()
        process.waitUntilExit()
        return true
    }

    private func combinedOutput(stdoutURL: URL, stderrURL: URL) -> String {
        let stdout = String(
            data: (try? Data(contentsOf: stdoutURL)) ?? Data(),
            encoding: .utf8
        ) ?? ""
        let stderr = String(
            data: (try? Data(contentsOf: stderrURL)) ?? Data(),
            encoding: .utf8
        ) ?? ""
        return [stdout, stderr]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private func temporaryCaptureURL(suffix: String) -> URL {
        fileManager.temporaryDirectory
            .appendingPathComponent("agent-signal-codex-version-\(UUID().uuidString).\(suffix)")
    }
}

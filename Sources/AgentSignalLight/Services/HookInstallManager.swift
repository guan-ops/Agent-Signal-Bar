import Foundation

struct HookInstallManager: Sendable {
    private static let commandTimeout: TimeInterval = 30

    func preview() throws -> HookInstallResult {
        let root = try hookRoot()
        return try runInstallHooks(
            hookRoot: root,
            arguments: ["--target", "all", "--codex-scope", root.codexScope, "--dry-run"]
        )
    }

    func previewCodex() throws -> HookInstallResult {
        let root = try hookRoot()
        return try runInstallHooks(
            hookRoot: root,
            arguments: ["--target", "codex", "--codex-scope", root.codexScope, "--dry-run"]
        )
    }

    func previewClaude() throws -> HookInstallResult {
        let root = try hookRoot()
        return try runInstallHooks(
            hookRoot: root,
            arguments: ["--target", "claude", "--dry-run"]
        )
    }

    func install() throws -> HookInstallResult {
        let root = try hookRoot()
        return try runInstallHooks(
            hookRoot: root,
            arguments: ["--target", "all", "--codex-scope", root.codexScope, "--install"]
        )
    }

    func installCodex() throws -> HookInstallResult {
        let root = try hookRoot()
        return try runInstallHooks(
            hookRoot: root,
            arguments: ["--target", "codex", "--codex-scope", root.codexScope, "--install"]
        )
    }

    func installClaude() throws -> HookInstallResult {
        let root = try hookRoot()
        return try runInstallHooks(
            hookRoot: root,
            arguments: ["--target", "claude", "--install"]
        )
    }

    private func runInstallHooks(hookRoot: HookRoot, arguments: [String]) throws -> HookInstallResult {
        let hookRootURL = hookRoot.url
        let scriptURL = hookRootURL.appendingPathComponent("script/install_hooks.py")
        guard FileManager.default.isExecutableFile(atPath: scriptURL.path) else {
            throw HookInstallError.missingInstallScript(scriptURL.path)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", scriptURL.path] + arguments
        process.currentDirectoryURL = hookRootURL

        let outputURL = temporaryCaptureURL(suffix: "out")
        let errorURL = temporaryCaptureURL(suffix: "err")
        try Data().write(to: outputURL)
        try Data().write(to: errorURL)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        let errorHandle = try FileHandle(forWritingTo: errorURL)
        defer {
            try? outputHandle.close()
            try? errorHandle.close()
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: errorURL)
        }
        process.standardOutput = outputHandle
        process.standardError = errorHandle

        try process.run()
        try waitForProcess(process, timeout: Self.commandTimeout)

        let output = String(
            data: (try? Data(contentsOf: outputURL)) ?? Data(),
            encoding: .utf8
        ) ?? ""
        let error = String(
            data: (try? Data(contentsOf: errorURL)) ?? Data(),
            encoding: .utf8
        ) ?? ""

        let result = HookInstallResult(
            exitCode: process.terminationStatus,
            output: output.trimmingCharacters(in: .whitespacesAndNewlines),
            error: error.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        guard process.terminationStatus == 0 else {
            throw HookInstallError.commandFailed(result)
        }

        return result
    }

    private func temporaryCaptureURL(suffix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-signal-hook-\(UUID().uuidString).\(suffix)")
    }

    private func waitForProcess(_ process: Process, timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            throw HookInstallError.commandTimedOut(timeout)
        }
    }

    private func hookRoot() throws -> HookRoot {
        let bundleURL = Bundle.main.bundleURL.standardizedFileURL
        let distParent = bundleURL.deletingLastPathComponent()
        if distParent.lastPathComponent == "dist" {
            let rootURL = distParent.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("script/install_hooks.py").path) {
                return HookRoot(url: rootURL, codexScope: "project")
            }
        }

        if let resourceURL = Bundle.main.resourceURL?.standardizedFileURL,
           FileManager.default.fileExists(atPath: resourceURL.appendingPathComponent("script/install_hooks.py").path) {
            return HookRoot(url: resourceURL, codexScope: "user")
        }

        let currentURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL
        if FileManager.default.fileExists(atPath: currentURL.appendingPathComponent("script/install_hooks.py").path) {
            return HookRoot(url: currentURL, codexScope: "project")
        }

        throw HookInstallError.cannotLocateProjectRoot(bundleURL.path)
    }
}

private struct HookRoot: Sendable {
    let url: URL
    let codexScope: String
}

struct HookInstallResult: Sendable {
    let exitCode: Int32
    let output: String
    let error: String

    var displayText: String {
        if output.isEmpty {
            return error.isEmpty ? "hook command completed" : error
        }
        if error.isEmpty {
            return output
        }
        return "\(output)\n\(error)"
    }
}

enum HookInstallError: Error, LocalizedError {
    case cannotLocateProjectRoot(String)
    case missingInstallScript(String)
    case commandFailed(HookInstallResult)
    case commandTimedOut(TimeInterval)

    var errorDescription: String? {
        switch self {
        case .cannotLocateProjectRoot(let appPath):
            return "无法从当前 app 位置找到项目根目录或内置 hook 资源：\(appPath)"
        case .missingInstallScript(let path):
            return "没有找到可执行的 hook 安装脚本：\(path)"
        case .commandFailed(let result):
            let detail = result.displayText
            return detail.isEmpty ? "hook 安装命令失败，退出码 \(result.exitCode)" : detail
        case .commandTimedOut(let timeout):
            return "hook 安装命令超过 \(Int(timeout)) 秒仍未结束，已停止。"
        }
    }
}

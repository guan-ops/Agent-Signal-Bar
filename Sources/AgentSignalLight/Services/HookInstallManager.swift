import Foundation
import AgentSignalLightCore

struct HookInstallManager: Sendable {
    var selectedCodexPath: String? = nil

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

    func uninstallCodex() throws -> HookInstallResult {
        let root = try hookRoot()
        return try runInstallHooks(
            hookRoot: root,
            arguments: ["--target", "codex", "--codex-scope", root.codexScope, "--remove", "--install"]
        )
    }

    func installClaude() throws -> HookInstallResult {
        let root = try hookRoot()
        return try runInstallHooks(
            hookRoot: root,
            arguments: ["--target", "claude", "--install"]
        )
    }

    func uninstallClaude() throws -> HookInstallResult {
        let root = try hookRoot()
        return try runInstallHooks(
            hookRoot: root,
            arguments: ["--target", "claude", "--remove", "--install"]
        )
    }

    private func runInstallHooks(hookRoot: HookRoot, arguments: [String]) throws -> HookInstallResult {
        let targetIndex = arguments.firstIndex(of: "--target")
        let target = targetIndex.map { arguments[$0 + 1] } ?? "all"
        let installer = NativeHookInstaller(resources: hookRoot.url, selectedCodexPath: selectedCodexPath)
        let output = try installer.run(target: target, install: arguments.contains("--install"),
            remove: arguments.contains("--remove"), projectRoot: hookRoot.codexScope == "project" ? hookRoot.url : nil)
        return HookInstallResult(exitCode: 0, output: output, error: "")
    }

    private func hookRoot() throws -> HookRoot {
        let bundleURL = Bundle.main.bundleURL.standardizedFileURL
        if let resourceURL = Bundle.main.resourceURL?.standardizedFileURL,
           FileManager.default.isExecutableFile(atPath: resourceURL.appendingPathComponent("scripts/codex-signal-hook").path) {
            return HookRoot(url: resourceURL, codexScope: "user")
        }

        let currentURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL
        if FileManager.default.fileExists(atPath: currentURL.appendingPathComponent("scripts/codex-signal-hook").path) {
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

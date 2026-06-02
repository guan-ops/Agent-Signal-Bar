import Foundation

struct DiagnosticsExportManager: Sendable {
    private static let commandTimeout: TimeInterval = 60

    func export(full: Bool = false) throws -> DiagnosticsExportResult {
        let rootURL = try diagnosticsRootURL()
        let scriptURL = rootURL.appendingPathComponent("script/export_diagnostics.sh")
        guard FileManager.default.isExecutableFile(atPath: scriptURL.path) else {
            throw DiagnosticsExportError.missingScript(scriptURL.path)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["bash", scriptURL.path] + (full ? ["--full"] : [])
        process.currentDirectoryURL = rootURL

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

        let result = DiagnosticsExportResult(
            exitCode: process.terminationStatus,
            output: output.trimmingCharacters(in: .whitespacesAndNewlines),
            error: error.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        guard process.terminationStatus == 0 else {
            throw DiagnosticsExportError.commandFailed(result)
        }

        return result
    }

    private func temporaryCaptureURL(suffix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-signal-diagnostics-\(UUID().uuidString).\(suffix)")
    }

    private func waitForProcess(_ process: Process, timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            throw DiagnosticsExportError.commandTimedOut(timeout)
        }
    }

    private func diagnosticsRootURL() throws -> URL {
        let bundleURL = Bundle.main.bundleURL.standardizedFileURL
        let distParent = bundleURL.deletingLastPathComponent()
        if distParent.lastPathComponent == "dist" {
            let rootURL = distParent.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("script/export_diagnostics.sh").path) {
                return rootURL
            }
        }

        if let resourceURL = Bundle.main.resourceURL?.standardizedFileURL,
           FileManager.default.fileExists(atPath: resourceURL.appendingPathComponent("script/export_diagnostics.sh").path) {
            return resourceURL
        }

        let currentURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL
        if FileManager.default.fileExists(atPath: currentURL.appendingPathComponent("script/export_diagnostics.sh").path) {
            return currentURL
        }

        throw DiagnosticsExportError.cannotLocateDiagnosticsRoot(bundleURL.path)
    }
}

struct DiagnosticsExportResult: Sendable {
    let exitCode: Int32
    let output: String
    let error: String

    var archiveURL: URL? {
        for line in displayText.components(separatedBy: .newlines) {
            let prefix = "Diagnostics archive: "
            if line.hasPrefix(prefix) {
                let path = String(line.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !path.isEmpty {
                    return URL(fileURLWithPath: path)
                }
            }
        }
        return nil
    }

    var displayText: String {
        if output.isEmpty {
            return error.isEmpty ? "diagnostics export completed" : error
        }
        if error.isEmpty {
            return output
        }
        return "\(output)\n\(error)"
    }
}

enum DiagnosticsExportError: Error, LocalizedError {
    case cannotLocateDiagnosticsRoot(String)
    case missingScript(String)
    case commandFailed(DiagnosticsExportResult)
    case commandTimedOut(TimeInterval)

    var errorDescription: String? {
        switch self {
        case .cannotLocateDiagnosticsRoot(let appPath):
            return "无法从当前 app 位置找到项目根目录或内置诊断资源：\(appPath)"
        case .missingScript(let path):
            return "没有找到可执行的诊断导出脚本：\(path)"
        case .commandFailed(let result):
            let detail = result.displayText
            return detail.isEmpty ? "诊断导出失败，退出码 \(result.exitCode)" : detail
        case .commandTimedOut(let timeout):
            return "诊断导出超过 \(Int(timeout)) 秒仍未结束，已停止。"
        }
    }
}

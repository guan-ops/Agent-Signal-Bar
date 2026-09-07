import Foundation

/// Argument-array execution. No session logs, stdout, or credentials are persisted by the adapter.
enum ClaudeCommandRunner {
    static func executable(_ name: String, custom: String = "", environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let files = FileManager.default
        if !custom.isEmpty { return files.isExecutableFile(atPath: custom) ? URL(fileURLWithPath: custom) : nil }
        let home = files.homeDirectoryForCurrentUser.path
        let directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + [home + "/.local/bin", home + "/.npm-global/bin", home + "/.bun/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        return directories.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
            .first { files.isExecutableFile(atPath: $0.path) }
    }

    static func run(_ binary: URL, arguments: [String], timeout: TimeInterval? = 30) throws -> Data {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("claude-command-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("output")
        guard FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw ClaudeSupportError.commandFailed }
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        try process.run()
        let start = ProcessInfo.processInfo.systemUptime
        while process.isRunning {
            if let timeout, ProcessInfo.processInfo.systemUptime - start > timeout {
                BoundedProcessTermination.terminate(process)
                throw ClaudeSupportError.timedOut
            }
            // Switching is an external credential transaction: let it exit naturally.
            if timeout != nil, (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0 > 1_048_576 {
                BoundedProcessTermination.terminate(process)
                throw ClaudeSupportError.outputTooLarge
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard process.terminationStatus == 0 else { throw ClaudeSupportError.commandFailed }
        let size = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 1_048_576 else { throw ClaudeSupportError.outputTooLarge }
        return try Data(contentsOf: output)
    }

    static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

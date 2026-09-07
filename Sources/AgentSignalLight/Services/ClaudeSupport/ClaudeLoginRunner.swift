import Darwin
import Foundation

// Matches CodexBar's ClaudeLoginRunner flow (4f760cfc9b5e): interactive CLI auth,
// ENTER at the browser prompt, then wait for completion. MIT attribution is in
// Resources/ClaudeSupport-LICENSE.txt. CLI output stays in bounded memory only.
enum ClaudeLoginRunner {
    static func run(_ binary: URL, timeout: TimeInterval = 300) async throws {
        let work = Task.detached(priority: .userInitiated) { try runSynchronously(binary, timeout: timeout) }
        try await withTaskCancellationHandler {
            try await work.value
        } onCancel: { work.cancel() }
    }

    private static func runSynchronously(_ binary: URL, timeout: TimeInterval) throws {
        try Task.checkCancellation()
        var master: Int32 = -1
        var slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else { throw ClaudeSupportError.commandFailed }
        let terminal = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        defer { try? terminal.close(); Darwin.close(master) }
        guard fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK) != -1 else { throw ClaudeSupportError.commandFailed }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("claude-auth-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let process = Process()
        process.executableURL = binary
        process.arguments = ["auth", "login", "--claudeai"]
        process.currentDirectoryURL = directory
        process.standardInput = terminal
        process.standardOutput = terminal
        process.standardError = terminal
        try process.run()
        defer { if process.isRunning { BoundedProcessTermination.terminate(process) } }
        try terminal.close()
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var output = Data()
        var totalBytes = 0
        var sentEnter = false
        var buffer = [UInt8](repeating: 0, count: 4096)
        while process.isRunning {
            try Task.checkCancellation()
            if ProcessInfo.processInfo.systemUptime >= deadline { throw ClaudeSupportError.timedOut }
            let count = Darwin.read(master, &buffer, buffer.count)
            if count > 0 {
                totalBytes += count
                guard totalBytes <= 1_048_576 else { throw ClaudeSupportError.outputTooLarge }
                output.append(contentsOf: buffer.prefix(count))
                if output.count > 16_384 { output = Data(output.suffix(16_384)) }
                let text = String(decoding: output, as: UTF8.self)
                    .replacingOccurrences(of: "\u{1B}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
                    .lowercased()
                if !sentEnter && text.contains("press enter to open in browser") {
                    var enter: UInt8 = 13
                    guard Darwin.write(master, &enter, 1) == 1 else { throw ClaudeSupportError.commandFailed }
                    sentEnter = true
                }
            } else if count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EIO {
                throw ClaudeSupportError.commandFailed
            }
            Thread.sleep(forTimeInterval: 0.03)
        }
        try Task.checkCancellation()
        guard process.terminationStatus == 0 else { throw ClaudeSupportError.commandFailed }
    }
}

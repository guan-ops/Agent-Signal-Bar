import Foundation
import Darwin

/// Bounded passive /usage probe. Launch policy follows CodexBar ClaudeCLISession (MIT).
/// No tool grants, user hooks or ambient MCP servers; output remains in memory.
enum ClaudeCLIUsageProbe {
    static func parse(_ raw: String, owner: String, now: Date = Date()) throws -> ClaudeUsageSnapshot {
        guard raw.utf8.count <= 2_097_152 else { throw ClaudeSupportError.outputTooLarge }
        let rendered = ClaudeCLIScreen.render(raw, preservePlainReports: true)
        let text = rendered.components(separatedBy: "What's contributing to your limits usage?")[0]
        let lower = text.lowercased()
        if ["not logged in", "please run /login", "token expired", "invalid access token"].contains(where: lower.contains) {
            throw ClaudeSupportError.loginRequired
        }
        guard !lower.contains("refreshing…"), !lower.contains("refreshing..."), !lower.contains("loading usage") else {
            throw ClaudeSupportError.invalidResponse
        }
        let lines = text.components(separatedBy: .newlines)
        let heading = try NSRegularExpression(pattern: #"(?i)^\s*Current\s+(session|week(?:\s*\(([^)]+)\))?)\s*$"#)
        let percent = try NSRegularExpression(pattern: #"(?i)(\d+(?:\.\d+)?)\s*%\s*(used|left|remaining)"#)
        var windows: [ClaudeQuotaWindow] = []
        var seen = Set<String>()
        for (index, line) in lines.enumerated() {
            guard let match = heading.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let range = Range(match.range(at: 1), in: line) else { continue }
            let label = String(line[range])
            let model = Range(match.range(at: 2), in: line).map { String(line[$0]) }
            let isSession = label.lowercased() == "session"
            let allModels = model == nil || model?.lowercased() == "all models"
            let id = isSession ? "five_hour" : (allModels ? "seven_day" : "scoped-" + (model ?? "").lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: "-"))
            guard seen.insert(id).inserted else { continue }
            var used: Double?; var reset: String?
            for next in lines.dropFirst(index + 1).prefix(12) {
                if heading.firstMatch(in: next, range: NSRange(next.startIndex..., in: next)) != nil { break }
                if let m = percent.firstMatch(in: next, range: NSRange(next.startIndex..., in: next)),
                   let numberRange = Range(m.range(at: 1), in: next), let kindRange = Range(m.range(at: 2), in: next),
                   let value = Double(next[numberRange]), (0...100).contains(value) {
                    used = next[kindRange].lowercased() == "used" ? value : 100 - value
                }
                let trimmed = next.trimmingCharacters(in: .whitespaces)
                if trimmed.lowercased().hasPrefix("reset") { reset = String(trimmed.prefix(160)) }
            }
            // A visible but unfinished quota row must not be published as an absent window.
            guard let used else { throw ClaudeSupportError.invalidResponse }
            let title = isSession ? "5 小时 / 5 hours" : (allModels ? "7 天 / 7 days" : "\(model ?? "Model") · 7 天 / \(model ?? "Model") · 7 days")
            windows.append(.init(id: id, title: title, usedPercent: used, resetsAt: reset.flatMap { resetDate($0, now: now) }, resetDescription: reset))
        }
        guard !windows.isEmpty else { throw ClaudeSupportError.invalidResponse }
        let email = lines.first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("Account:") })?
            .components(separatedBy: "Account:").last?.trimmingCharacters(in: .whitespaces)
        return .init(credentialID: owner, email: email, organization: nil, plan: nil, windows: windows,
                     extraUsed: nil, extraLimit: nil, extraCurrency: "USD", updatedAt: now,
                     source: "Claude CLI", freshnessInterval: 900)
    }

    static func resetDate(_ text: String, now: Date) -> Date? {
        let raw = text.replacingOccurrences(of: #"(?i)^resets?\s*"#, with: "", options: .regularExpression)
        if let iso = ClaudeUsageSnapshot.date(raw) { return iso }
        if raw.lowercased().hasPrefix("in "), let regex = try? NSRegularExpression(pattern: #"(?i)(\d+)\s*(days?|d|hours?|h|minutes?|m)"#) {
            let matches = regex.matches(in: raw, range: NSRange(raw.startIndex..., in: raw))
            var seconds = 0.0
            for match in matches {
                guard let n = Range(match.range(at: 1), in: raw), let unit = Range(match.range(at: 2), in: raw), let value = Double(raw[n]) else { continue }
                seconds += value * (raw[unit].lowercased().hasPrefix("d") ? 86400 : raw[unit].lowercased().hasPrefix("h") ? 3600 : 60)
            }
            return seconds > 0 && seconds <= 14 * 86400 ? now.addingTimeInterval(seconds) : nil
        }
        // Unknown timezone/date descriptions stay visible verbatim; never invent a reset timestamp.
        return nil
    }

    static func run(_ binary: URL, owner: String, timeout: TimeInterval = 25, directory: URL? = nil) async throws -> ClaudeUsageSnapshot {
        let task = Task.detached(priority: .utility) { try runSynchronously(binary, owner: owner, timeout: timeout, directory: directory) }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private static func runSynchronously(_ binary: URL, owner: String, timeout: TimeInterval, directory: URL?) throws -> ClaudeUsageSnapshot {
        try Task.checkCancellation()
        let work = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentSignalLight/ClaudeProbe", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard work.standardizedFileURL == work.resolvingSymlinksInPath().standardizedFileURL else { throw ClaudeSupportError.commandFailed }
        let sessionID = UUID().uuidString.lowercased()
        var master: Int32 = -1, slave: Int32 = -1
        var size = winsize(ws_row: 200, ws_col: 160, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else { throw ClaudeSupportError.commandFailed }
        let terminal = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        defer { try? terminal.close(); Darwin.close(master) }
        guard fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK) != -1 else { throw ClaudeSupportError.commandFailed }
        let process = Process(); process.executableURL = binary
        process.arguments = ["--allowed-tools", "", "--strict-mcp-config", "--settings",
            #"{"remoteControlAtStartup":false,"disableAllHooks":true}"#, "--session-id", sessionID]
        process.currentDirectoryURL = work
        process.standardInput = terminal; process.standardOutput = terminal; process.standardError = terminal
        try process.run(); try terminal.close()
        defer {
            if process.isRunning { BoundedProcessTermination.terminate(process) }
            cleanupOwnedTranscript(sessionID: sessionID, directory: work)
        }
        let start = ProcessInfo.processInfo.systemUptime
        var lastOutput = start, sent = false, trusted = false
        var output = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        func send(_ text: String) throws {
            let data = Data(text.utf8)
            let count = data.withUnsafeBytes { Darwin.write(master, $0.baseAddress, $0.count) }
            guard count == data.count else { throw ClaudeSupportError.commandFailed }
        }
        while ProcessInfo.processInfo.systemUptime - start < timeout {
            try Task.checkCancellation()
            let count = Darwin.read(master, &buffer, buffer.count)
            if count > 0 {
                output.append(contentsOf: buffer.prefix(count)); lastOutput = ProcessInfo.processInfo.systemUptime
                guard output.count <= 2_097_152 else { throw ClaudeSupportError.outputTooLarge }
            }
            let text = String(decoding: output, as: UTF8.self)
            if !trusted, text.lowercased().contains("yes, i trust this folder") {
                let clean = ClaudeCLIScreen.render(text).replacingOccurrences(of: "~", with: NSHomeDirectory())
                let compact = clean.filter { !$0.isWhitespace }
                guard compact.contains(work.path.filter { !$0.isWhitespace }) else { throw ClaudeSupportError.commandFailed }
                let lines = clean.components(separatedBy: .newlines)
                if let yes = lines.firstIndex(where: { $0.lowercased().contains("yes, i trust this folder") }),
                   let cursor = lines.firstIndex(where: { $0.contains("❯") }) {
                    if cursor < yes { try send("\u{1b}[B") }
                    if cursor > yes { try send("\u{1b}[A") }
                    try send("\r"); trusted = true
                    // A slow start can show this prompt after /usage was already typed into
                    // it; that input is lost, so ask again once the prompt is dismissed.
                    sent = false; lastOutput = ProcessInfo.processInfo.systemUptime
                }
            }
            // Wait for the startup screen to settle instead of trusting a fixed delay;
            // the six-second cap keeps a continuously repainting screen from stalling.
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            let settled = ProcessInfo.processInfo.systemUptime - lastOutput > 0.4 || elapsed > 6
            if !sent, elapsed > 2, settled,
               !text.lowercased().contains("trust this folder") || trusted {
                try send("/usage\r"); sent = true
            }
            if sent, ProcessInfo.processInfo.systemUptime - lastOutput > 0.7 {
                do { return try parse(text, owner: owner) }
                catch ClaudeSupportError.loginRequired { throw ClaudeSupportError.loginRequired }
                catch { if !process.isRunning { throw error } }
            }
            if !process.isRunning, count <= 0 { return try parse(text, owner: owner) }
            Thread.sleep(forTimeInterval: 0.03)
        }
        throw ClaudeSupportError.timedOut
    }

    private static func cleanupOwnedTranscript(sessionID: String, directory: URL) {
        let config = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        let project = directory.path.replacingOccurrences(of: "[^a-zA-Z0-9]", with: "-", options: .regularExpression)
        let file = config.appendingPathComponent("projects/\(project)/\(sessionID).jsonl")
        guard file.standardizedFileURL == file.resolvingSymlinksInPath().standardizedFileURL,
              let handle = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 65_536) else { return }
        let ownsFile = String(decoding: data, as: UTF8.self).split(separator: "\n").contains { line in
            guard let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return false }
            return row["cwd"] as? String == directory.path
        }
        if ownsFile { try? FileManager.default.removeItem(at: file) }
    }
}

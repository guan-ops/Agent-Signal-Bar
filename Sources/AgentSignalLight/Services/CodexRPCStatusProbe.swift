import Foundation

struct CodexRPCStatus: Equatable, Sendable {
    let accountEmail: String?
    let accountPlanName: String?
    let rateLimitPlanName: String?
    let checkedAt: Date

    var displayPlanName: String? {
        rateLimitPlanName ?? accountPlanName
    }
}

final class CodexRPCStatusProbe: @unchecked Sendable {
    private let environment: [String: String]
    private let fileManager: FileManager

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) {
        self.environment = environment
        self.fileManager = fileManager
    }

    func probe(initializeTimeout: TimeInterval = 8, requestTimeout: TimeInterval = 4) async -> CodexRPCStatus {
        let checkedAt = Date()
        guard let executable = resolveCodexExecutable() else {
            return CodexRPCStatus(accountEmail: nil, accountPlanName: nil, rateLimitPlanName: nil, checkedAt: checkedAt)
        }

        do {
            let client = try CodexRPCStatusClient(
                executable: executable,
                environment: effectiveEnvironment(),
                initializeTimeout: initializeTimeout,
                requestTimeout: requestTimeout
            )
            defer { client.shutdown() }

            try await client.initialize()
            // Codex app-server replies on one stdout stream; keep RPC requests serialized.
            let resolvedRateLimits = try? await client.fetchRateLimits()
            let resolvedAccount = try? await client.fetchAccount()
            return CodexRPCStatus(
                accountEmail: resolvedAccount?.email,
                accountPlanName: CodexPlanFormatting.displayName(resolvedAccount?.planType),
                rateLimitPlanName: CodexPlanFormatting.displayName(resolvedRateLimits?.planType),
                checkedAt: checkedAt
            )
        } catch {
            return CodexRPCStatus(accountEmail: nil, accountPlanName: nil, rateLimitPlanName: nil, checkedAt: checkedAt)
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
}

private final class CodexRPCStatusClient: @unchecked Sendable {
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let stdoutLineStream: AsyncStream<Data>
    private let stdoutLineContinuation: AsyncStream<Data>.Continuation
    private let initializeTimeout: TimeInterval
    private let requestTimeout: TimeInterval
    private var nextID = 1

    init(
        executable: String,
        environment: [String: String],
        initializeTimeout: TimeInterval,
        requestTimeout: TimeInterval
    ) throws {
        self.initializeTimeout = initializeTimeout
        self.requestTimeout = requestTimeout

        var stdoutContinuation: AsyncStream<Data>.Continuation!
        stdoutLineStream = AsyncStream<Data> { continuation in
            stdoutContinuation = continuation
        }
        stdoutLineContinuation = stdoutContinuation

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-s", "read-only", "-a", "untrusted", "app-server"]
        process.environment = environment
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        let stdoutBuffer = LineBuffer()
        stdoutPipe.fileHandleForReading.readabilityHandler = { [stdoutLineContinuation] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                stdoutLineContinuation.finish()
                return
            }
            for line in stdoutBuffer.appendAndDrainLines(data) {
                stdoutLineContinuation.yield(line)
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty {
                handle.readabilityHandler = nil
            }
        }
    }

    func initialize() async throws {
        _ = try await request(
            method: "initialize",
            params: ["clientInfo": ["name": "agent-signal-light", "version": "dev"]],
            timeout: initializeTimeout
        )
        try sendPayload(["method": "initialized", "params": [:]])
    }

    func fetchAccount() async throws -> RPCAccountSnapshot? {
        let message = try await request(method: "account/read")
        guard let result = message["result"] else { return nil }
        let data = try JSONSerialization.data(withJSONObject: result)
        let response = try JSONDecoder().decode(RPCAccountResponse.self, from: data)
        switch response.account {
        case let .chatgpt(email, planType):
            return RPCAccountSnapshot(email: email, planType: planType)
        case .apiKey, .none:
            return nil
        }
    }

    func fetchRateLimits() async throws -> RPCRateLimitSnapshot? {
        let message = try await request(method: "account/rateLimits/read")
        guard let result = message["result"] else { return nil }
        let data = try JSONSerialization.data(withJSONObject: result)
        return try JSONDecoder().decode(RPCRateLimitsResponse.self, from: data).rateLimits
    }

    func shutdown() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            process.terminate()
        }
    }

    private struct SendableJSONMessage: @unchecked Sendable {
        let value: [String: Any]
    }

    private func request(method: String, params: [String: Any] = [:], timeout: TimeInterval? = nil) async throws -> [String: Any] {
        let id = nextID
        nextID += 1
        try sendPayload(["id": id, "method": method, "params": params])

        let wrapped = try await withThrowingTaskGroup(of: SendableJSONMessage.self) { group in
            group.addTask {
                while true {
                    let message = try await self.readNextMessage()
                    if message["id"] == nil {
                        continue
                    }
                    guard let messageID = self.jsonID(message["id"]), messageID == id else {
                        continue
                    }
                    if let error = message["error"] as? [String: Any],
                       let message = error["message"] as? String {
                        throw CodexRPCStatusError.requestFailed(message)
                    }
                    return SendableJSONMessage(value: message)
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout ?? self.requestTimeout))
                self.shutdown()
                throw CodexRPCStatusError.timeout
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw CodexRPCStatusError.timeout
            }
            return result
        }
        return wrapped.value
    }

    private func sendPayload(_ payload: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: payload)
        stdinPipe.fileHandleForWriting.write(data)
        stdinPipe.fileHandleForWriting.write(Data([0x0A]))
    }

    private func readNextMessage() async throws -> [String: Any] {
        for await line in stdoutLineStream {
            if line.isEmpty { continue }
            if let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                return message
            }
        }
        throw CodexRPCStatusError.closed
    }

    private func jsonID(_ value: Any?) -> Int? {
        switch value {
        case let int as Int:
            return int
        case let number as NSNumber:
            return number.intValue
        default:
            return nil
        }
    }
}

private struct RPCAccountSnapshot: Sendable {
    let email: String?
    let planType: String?
}

private struct RPCAccountResponse: Decodable {
    let account: RPCAccountDetails?
}

private enum RPCAccountDetails: Decodable {
    case apiKey
    case chatgpt(email: String?, planType: String?)

    private enum CodingKeys: String, CodingKey {
        case type
        case email
        case planType
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type).lowercased()
        switch type {
        case "apikey":
            self = .apiKey
        case "chatgpt":
            self = .chatgpt(
                email: try container.decodeIfPresent(String.self, forKey: .email),
                planType: try container.decodeIfPresent(String.self, forKey: .planType)
            )
        default:
            self = .chatgpt(email: nil, planType: nil)
        }
    }
}

private struct RPCRateLimitsResponse: Decodable {
    let rateLimits: RPCRateLimitSnapshot

    private enum CodingKeys: String, CodingKey {
        case rateLimits
    }
}

private struct RPCRateLimitSnapshot: Decodable {
    let planType: String?

    private enum CodingKeys: String, CodingKey {
        case planType
        case planTypeSnake = "plan_type"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        planType = (try? container.decodeIfPresent(String.self, forKey: .planType))
            ?? (try? container.decodeIfPresent(String.self, forKey: .planTypeSnake))
    }
}

private final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    func appendAndDrainLines(_ data: Data) -> [Data] {
        lock.lock()
        defer { lock.unlock() }

        buffer.append(data)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if !line.isEmpty {
                lines.append(line)
            }
        }
        return lines
    }
}

private enum CodexRPCStatusError: Error {
    case closed
    case requestFailed(String)
    case timeout
}

import Foundation

// Streams JSONL files while keeping only a bounded prefix of each line.
// Codex session logs can contain huge tool-output records, but token_count
// records and session metadata live near the front of small JSON objects.
enum BoundedJSONLLineScanner {
    struct Line {
        let data: Data
        let isTruncated: Bool
    }

    @discardableResult
    static func scan(
        fileURL: URL,
        offset: Int64 = 0,
        maximumLineBytes: Int,
        retainedPrefixBytes: Int,
        shouldStop: (() throws -> Void)? = nil,
        onLine: (Line) -> Void
    ) throws -> Int64 {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        let startOffset = max(0, offset)
        if startOffset > 0 {
            try handle.seek(toOffset: UInt64(startOffset))
        }

        var retainedLine = Data()
        retainedLine.reserveCapacity(min(retainedPrefixBytes, 4 * 1024))
        var currentLineBytes = 0
        var currentLineTruncated = false
        var consumedBytes: Int64 = 0

        func appendBytes(_ pointer: UnsafePointer<UInt8>, count: Int) {
            guard count > 0 else { return }

            currentLineBytes += count
            if retainedLine.count < retainedPrefixBytes {
                let remainingCapacity = retainedPrefixBytes - retainedLine.count
                let bytesToRetain = min(remainingCapacity, count)
                retainedLine.append(pointer, count: bytesToRetain)
            }

            if currentLineBytes > maximumLineBytes || currentLineBytes > retainedPrefixBytes {
                currentLineTruncated = true
            }
        }

        func emitLineIfNeeded() {
            guard currentLineBytes > 0 else { return }

            onLine(Line(data: retainedLine, isTruncated: currentLineTruncated))
            retainedLine.removeAll(keepingCapacity: true)
            currentLineBytes = 0
            currentLineTruncated = false
        }

        while true {
            try shouldStop?()
            let chunk = try autoreleasepool {
                try handle.read(upToCount: 256 * 1024) ?? Data()
            }

            guard chunk.isEmpty == false else {
                emitLineIfNeeded()
                break
            }

            consumedBytes += Int64(chunk.count)
            try shouldStop?()

            chunk.withUnsafeBytes { rawBytes in
                guard let baseAddress = rawBytes.bindMemory(to: UInt8.self).baseAddress else {
                    return
                }

                var lineStart = 0
                for index in 0..<rawBytes.count {
                    guard baseAddress[index] == 0x0A else { continue }

                    appendBytes(baseAddress.advanced(by: lineStart), count: index - lineStart)
                    emitLineIfNeeded()
                    lineStart = index + 1
                }

                if lineStart < rawBytes.count {
                    appendBytes(
                        baseAddress.advanced(by: lineStart),
                        count: rawBytes.count - lineStart
                    )
                }
            }
        }

        return startOffset + consumedBytes
    }
}

// Scans very large JSONL files by searching for a small set of marker strings
// first, then extracts only the matching lines. This avoids walking every byte
// of huge tool-output lines when token usage rows are sparse.
enum RelevantJSONLLineScanner {
    @discardableResult
    static func scan(
        fileURL: URL,
        offset: Int64 = 0,
        chunkBytes: Int = 4 * 1024 * 1024,
        maximumLineBytes: Int,
        retainedTailBytes: Int = 256 * 1024,
        needles: [Data],
        onLine: (Data) -> Void
    ) throws -> Int64 {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        let startOffset = max(0, offset)
        if startOffset > 0 {
            try handle.seek(toOffset: UInt64(startOffset))
        }

        let needleTailBytes = max((needles.map(\.count).max() ?? 1) - 1, 0)
        var consumedBytes: Int64 = 0
        var carry = Data()
        var emittedLineOffsets = Set<Int64>()

        while true {
            let chunk = try autoreleasepool {
                try handle.read(upToCount: chunkBytes) ?? Data()
            }
            guard chunk.isEmpty == false else { break }

            let bufferOffset = startOffset + consumedBytes - Int64(carry.count)
            var buffer = Data()
            buffer.reserveCapacity(carry.count + chunk.count)
            buffer.append(carry)
            buffer.append(chunk)
            consumedBytes += Int64(chunk.count)

            for needle in needles where needle.isEmpty == false {
                var searchStart = buffer.startIndex
                while searchStart < buffer.endIndex,
                      let match = buffer[searchStart...].range(of: needle) {
                    defer {
                        searchStart = match.upperBound
                    }

                    guard let lineStartIndex = lineStart(in: buffer, before: match.lowerBound),
                          let lineEndIndex = lineEnd(in: buffer, after: match.upperBound)
                    else {
                        continue
                    }

                    let lineLength = lineEndIndex - lineStartIndex
                    guard lineLength > 0,
                          lineLength <= maximumLineBytes
                    else {
                        continue
                    }

                    let absoluteLineStart = bufferOffset + Int64(lineStartIndex)
                    guard absoluteLineStart >= startOffset,
                          emittedLineOffsets.insert(absoluteLineStart).inserted
                    else {
                        continue
                    }

                    onLine(buffer[lineStartIndex..<lineEndIndex])
                }
            }

            carry = trailingCarry(from: buffer, maxBytes: max(retainedTailBytes, needleTailBytes))
        }

        if carry.isEmpty == false,
           carry.count <= maximumLineBytes,
           needles.contains(where: { needle in
               needle.isEmpty == false && carry.range(of: needle) != nil
           }) {
            onLine(carry)
        }

        return startOffset + consumedBytes
    }

    private static func lineStart(in data: Data, before index: Data.Index) -> Data.Index? {
        if index == data.startIndex {
            return data.startIndex
        }

        var cursor = index
        while cursor > data.startIndex {
            data.formIndex(before: &cursor)
            if data[cursor] == 0x0A {
                return data.index(after: cursor)
            }
        }

        return data.startIndex
    }

    private static func lineEnd(in data: Data, after index: Data.Index) -> Data.Index? {
        if index >= data.endIndex {
            return nil
        }

        var cursor = index
        while cursor < data.endIndex {
            if data[cursor] == 0x0A {
                return cursor
            }
            data.formIndex(after: &cursor)
        }

        return nil
    }

    private static func trailingCarry(from data: Data, maxBytes: Int) -> Data {
        guard data.isEmpty == false else { return Data() }

        if let lastNewline = data.lastIndex(of: 0x0A) {
            let suffixStart = data.index(after: lastNewline)
            if suffixStart < data.endIndex {
                let suffix = data[suffixStart...]
                return Data(suffix.suffix(maxBytes))
            }
            return Data()
        }

        return Data(data.suffix(maxBytes))
    }
}

enum RipgrepRelevantJSONLLineScanner {
    typealias NumberedLineHandler = (URL, Int, Data) -> Void

    @discardableResult
    static func scan(
        fileURL: URL,
        needles: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        onLine: (Data) -> Void
    ) -> Int64? {
        guard let rgURL = ripgrepURL(environment: environment),
              FileManager.default.isExecutableFile(atPath: rgURL.path)
        else {
            return nil
        }

        guard let fileSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        else {
            return nil
        }

        let process = Process()
        process.executableURL = rgURL
        process.arguments = [
            "--fixed-strings",
            "--no-heading",
            "--color",
            "never",
            "--text",
            "--mmap",
            "--no-messages"
        ] + needles.flatMap { ["-e", $0] } + [fileURL.path]

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            guard process.terminationStatus == 0 || process.terminationStatus == 1 else {
                return nil
            }

            for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
                onLine(Data(line))
            }
            return Int64(fileSize)
        } catch {
            return nil
        }
    }

    @discardableResult
    static func scan(
        fileURLs: [URL],
        needles: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        onLine: (URL, Data) -> Void
    ) -> [String: Int64]? {
        guard fileURLs.isEmpty == false,
              let rgURL = ripgrepURL(environment: environment),
              FileManager.default.isExecutableFile(atPath: rgURL.path)
        else {
            return nil
        }

        var fileSizes: [String: Int64] = [:]
        for url in fileURLs {
            guard let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            else {
                continue
            }
            fileSizes[url.path] = Int64(fileSize)
        }
        guard fileSizes.isEmpty == false else {
            return nil
        }

        let process = Process()
        process.executableURL = rgURL
        process.arguments = [
            "--fixed-strings",
            "--no-heading",
            "--color",
            "never",
            "--text",
            "--mmap",
            "--no-messages",
            "--with-filename",
            "--null"
        ] + needles.flatMap { ["-e", $0] } + fileURLs.map(\.path)

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            try parseNullSeparatedRipgrepOutput(from: stdout.fileHandleForReading, onLine: onLine)
            process.waitUntilExit()

            guard process.terminationStatus == 0 || process.terminationStatus == 1 else {
                return nil
            }

            return fileSizes
        } catch {
            return nil
        }
    }

    @discardableResult
    static func scanNumbered(
        fileURLs: [URL],
        needles: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        onLine: NumberedLineHandler
    ) -> [String: Int64]? {
        guard fileURLs.isEmpty == false,
              let rgURL = ripgrepURL(environment: environment),
              FileManager.default.isExecutableFile(atPath: rgURL.path)
        else {
            return nil
        }

        var fileSizes: [String: Int64] = [:]
        for url in fileURLs {
            guard let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            else {
                continue
            }
            fileSizes[url.path] = Int64(fileSize)
        }
        guard fileSizes.isEmpty == false else {
            return nil
        }

        let process = Process()
        process.executableURL = rgURL
        process.arguments = [
            "--fixed-strings",
            "--no-heading",
            "--color",
            "never",
            "--text",
            "--mmap",
            "--no-messages",
            "--with-filename",
            "--null",
            "--line-number"
        ] + needles.flatMap { ["-e", $0] } + fileURLs.map(\.path)

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            try parseNumberedNullSeparatedRipgrepOutput(
                from: stdout.fileHandleForReading,
                onLine: onLine
            )
            process.waitUntilExit()

            guard process.terminationStatus == 0 || process.terminationStatus == 1 else {
                return nil
            }

            return fileSizes
        } catch {
            return nil
        }
    }

    static func scanTurnContextModels(
        fileURLs: [URL],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: [(lineNumber: Int, model: String, turnID: String?)]]? {
        guard fileURLs.isEmpty == false,
              let rgURL = ripgrepURL(environment: environment),
              FileManager.default.isExecutableFile(atPath: rgURL.path)
        else {
            return nil
        }

        let process = Process()
        process.executableURL = rgURL
        process.arguments = [
            "--no-heading",
            "--color",
            "never",
            "--text",
            "--mmap",
            "--no-messages",
            "--with-filename",
            "--null",
            "--line-number",
            "--only-matching",
            "--replace",
            "$1\t$2",
            "-e",
            #""type":"turn_context".*?"model":"([^"]+)"(?:.*?"turn_id":"([^"]+)")?"#
        ] + fileURLs.map(\.path)

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        var results: [String: [(lineNumber: Int, model: String, turnID: String?)]] = [:]

        do {
            try process.run()
            try parseNumberedNullSeparatedRipgrepOutput(
                from: stdout.fileHandleForReading
            ) { url, lineNumber, data in
                guard let raw = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                    raw.isEmpty == false
                else {
                    return
                }
                let parts = raw.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                let model = parts.first.map(String.init)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let turnID = parts.dropFirst().first.map(String.init)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard model.isEmpty == false else { return }
                results[url.path, default: []].append((
                    lineNumber: lineNumber,
                    model: model,
                    turnID: turnID?.isEmpty == false ? turnID : nil
                ))
            }
            process.waitUntilExit()

            guard process.terminationStatus == 0 || process.terminationStatus == 1 else {
                return nil
            }

            for path in results.keys {
                results[path]?.sort { $0.lineNumber < $1.lineNumber }
            }
            return results
        } catch {
            return nil
        }
    }

    private static func parseNullSeparatedRipgrepOutput(
        from handle: FileHandle,
        onLine: (URL, Data) -> Void
    ) throws {
        var buffer = Data()
        buffer.reserveCapacity(4 * 1024 * 1024)
        var lastPathData = Data()
        var lastURL: URL?

        func drainBuffer(final: Bool = false) {
            var consumed = buffer.startIndex
            var cursor = buffer.startIndex

            while cursor < buffer.endIndex,
                  let pathEnd = buffer[cursor...].firstIndex(of: 0x00) {
                let lineStart = buffer.index(after: pathEnd)
                guard lineStart <= buffer.endIndex else { break }

                let lineEnd: Data.Index?
                if let newline = buffer[lineStart...].firstIndex(of: 0x0A) {
                    lineEnd = newline
                } else if final {
                    lineEnd = buffer.endIndex
                } else {
                    break
                }

                guard let lineEnd else { break }
                if lineEnd > lineStart {
                    let pathSlice = buffer[cursor..<pathEnd]
                    let url: URL?
                    if lastURL != nil,
                       pathSlice.elementsEqual(lastPathData) {
                        url = lastURL
                    } else if let path = String(data: pathSlice, encoding: .utf8),
                              path.isEmpty == false {
                        let nextURL = URL(fileURLWithPath: path)
                        lastPathData = Data(pathSlice)
                        lastURL = nextURL
                        url = nextURL
                    } else {
                        url = nil
                    }

                    if let url {
                        onLine(url, Data(buffer[lineStart..<lineEnd]))
                    }
                }

                consumed = lineEnd < buffer.endIndex ? buffer.index(after: lineEnd) : buffer.endIndex
                cursor = consumed
            }

            if consumed > buffer.startIndex {
                buffer.removeSubrange(buffer.startIndex..<consumed)
            }
        }

        while true {
            let chunk = try autoreleasepool {
                try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
            }
            guard chunk.isEmpty == false else {
                drainBuffer(final: true)
                break
            }
            buffer.append(chunk)
            drainBuffer()
        }
    }

    private static func parseNumberedNullSeparatedRipgrepOutput(
        from handle: FileHandle,
        onLine: NumberedLineHandler
    ) throws {
        try parseNullSeparatedRipgrepOutput(from: handle) { url, data in
            guard let separator = data.firstIndex(of: 0x3A),
                  separator > data.startIndex,
                  let lineNumber = Int(String(decoding: data[data.startIndex..<separator], as: UTF8.self))
            else {
                return
            }
            let lineStart = data.index(after: separator)
            guard lineStart <= data.endIndex else { return }
            onLine(url, lineNumber, Data(data[lineStart..<data.endIndex]))
        }
    }

    private static func ripgrepURL(environment: [String: String]) -> URL? {
        let candidates = [
            "/opt/homebrew/bin/rg",
            "/usr/local/bin/rg",
            "/usr/bin/rg"
        ]

        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        let pathValue = environment["PATH"] ?? ""
        for directory in pathValue.split(separator: ":") {
            let path = "\(directory)/rg"
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }

        return nil
    }
}

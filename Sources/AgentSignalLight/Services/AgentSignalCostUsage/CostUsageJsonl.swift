import Foundation

enum CostUsageJsonl {
    struct Line {
        let bytes: Data
        let wasTruncated: Bool
        let startOffset: Int64
        let endOffset: Int64
    }

    @discardableResult
    static func scan(
        fileURL: URL,
        offset: Int64 = 0,
        maxLineBytes: Int,
        prefixBytes: Int,
        stopBeforeLine: ((Line) -> Bool)? = nil,
        onLine: (Line) -> Void) throws
        -> Int64
    {
        try self.scan(
            fileURL: fileURL,
            offset: offset,
            maxLineBytes: maxLineBytes,
            prefixBytes: prefixBytes,
            checkCancellation: nil,
            stopBeforeLine: stopBeforeLine,
            onLine: onLine)
    }

    @discardableResult
    static func scan(
        fileURL: URL,
        offset: Int64 = 0,
        maxLineBytes: Int,
        prefixBytes: Int,
        checkCancellation: (() throws -> Void)? = nil,
        stopBeforeLine: ((Line) -> Bool)? = nil,
        onLine: (Line) -> Void) throws
        -> Int64
    {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        let startOffset = max(0, offset)
        if startOffset > 0 {
            try handle.seek(toOffset: UInt64(startOffset))
        }

        var current = Data()
        current.reserveCapacity(4 * 1024)
        var lineBytes = 0
        var truncated = false
        var bytesRead: Int64 = 0
        var lineStartOffset: Int64 = 0
        var stoppedOffset: Int64?

        func appendSegment(_ bytes: UnsafePointer<UInt8>, count: Int) {
            guard count > 0 else { return }
            lineBytes += count
            if current.count < prefixBytes {
                let appendCount = min(prefixBytes - current.count, count)
                if appendCount > 0 {
                    current.append(bytes, count: appendCount)
                }
            }
            if lineBytes > maxLineBytes || lineBytes > prefixBytes {
                truncated = true
            }
        }

        func flushLine(contentEndOffset: Int64) -> Bool {
            guard lineBytes > 0 else { return false }
            let line = Line(
                bytes: current,
                wasTruncated: truncated,
                startOffset: startOffset + lineStartOffset,
                endOffset: startOffset + contentEndOffset
            )
            if stopBeforeLine?(line) == true {
                stoppedOffset = startOffset + lineStartOffset
                return true
            }
            onLine(line)
            current.removeAll(keepingCapacity: true)
            lineBytes = 0
            truncated = false
            return false
        }

        while true {
            try checkCancellation?()
            let reachedEOF = try autoreleasepool {
                let chunk = try handle.read(upToCount: 256 * 1024) ?? Data()
                if chunk.isEmpty {
                    // Some existing Codex fixtures/files contain a complete
                    // final JSON object without a trailing newline. Consume it
                    // only when it is demonstrably complete; otherwise retain
                    // the line-start cursor for a later writer append.
                    if lineBytes > 0,
                       !truncated,
                       (try? JSONSerialization.jsonObject(with: current)) != nil {
                        _ = flushLine(contentEndOffset: bytesRead)
                    }
                    return true
                }

                try checkCancellation?()
                let chunkStartOffset = bytesRead
                bytesRead += Int64(chunk.count)
                chunk.withUnsafeBytes { rawBuffer in
                    guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
                    var segmentStart = 0
                    var index = 0
                    while index < rawBuffer.count {
                        if base[index] == 0x0A {
                            appendSegment(base.advanced(by: segmentStart), count: index - segmentStart)
                            if flushLine(contentEndOffset: chunkStartOffset + Int64(index)) {
                                return
                            }
                            lineStartOffset = chunkStartOffset + Int64(index + 1)
                            segmentStart = index + 1
                        }
                        index += 1
                    }
                    if stoppedOffset == nil, segmentStart < rawBuffer.count {
                        appendSegment(base.advanced(by: segmentStart), count: rawBuffer.count - segmentStart)
                    }
                }
                return stoppedOffset != nil
            }
            if reachedEOF { break }
            try checkCancellation?()
        }

        if let stoppedOffset {
            return stoppedOffset
        }
        // JSONL writers commonly append a record in more than one write. Keep
        // the cursor at the beginning of an unterminated line so the next scan
        // re-reads the complete record instead of starting in its middle.
        if lineBytes > 0 {
            return startOffset + lineStartOffset
        }
        return startOffset + bytesRead
    }
}

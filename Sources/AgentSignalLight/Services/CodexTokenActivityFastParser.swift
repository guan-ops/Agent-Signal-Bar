import Foundation

// Fast JSONL parsing adapted from CodexBar's CostUsageScanner. We keep the
// implementation local and write only Agent Signal Bar's own token cache.
enum CodexTokenActivityFastParser {
    struct SessionMetadata {
        let sessionID: String?
        let forkedFromID: String?
        let forkTimestamp: String?
    }

    struct TokenCountRecord {
        let timestamp: String
        let model: String?
        let last: TokenTotals?
        let total: TokenTotals?
    }

    struct TurnContextRecord {
        let model: String?
        let turnID: String?
    }

    enum Line {
        case sessionMeta(SessionMetadata)
        case turnContext(TurnContextRecord)
        case tokenCount(TokenCountRecord)
    }

    private static let fieldCachedInputTokens = Array("cached_input_tokens".utf8)
    private static let fieldCacheReadInputTokens = Array("cache_read_input_tokens".utf8)
    private static let fieldForkedFromID = Array("forked_from_id".utf8)
    private static let fieldForkedFromIDCamel = Array("forkedFromId".utf8)
    private static let fieldID = Array("id".utf8)
    private static let fieldInfo = Array("info".utf8)
    private static let fieldInputTokens = Array("input_tokens".utf8)
    private static let fieldLastTokenUsage = Array("last_token_usage".utf8)
    private static let fieldModel = Array("model".utf8)
    private static let fieldModelName = Array("model_name".utf8)
    private static let fieldOutputTokens = Array("output_tokens".utf8)
    private static let fieldParentSessionID = Array("parent_session_id".utf8)
    private static let fieldParentSessionIDCamel = Array("parentSessionId".utf8)
    private static let fieldPayload = Array("payload".utf8)
    private static let fieldSessionID = Array("session_id".utf8)
    private static let fieldSessionIDCamel = Array("sessionId".utf8)
    private static let fieldTimestamp = Array("timestamp".utf8)
    private static let fieldTotalTokenUsage = Array("total_token_usage".utf8)
    private static let fieldTurnID = Array("turn_id".utf8)
    private static let fieldTurnIDCamel = Array("turnId".utf8)
    private static let fieldType = Array("type".utf8)
    private static let quotedTimestampPrefix = Array("\"timestamp\":\"".utf8)
    private static let quotedTotalTokenUsagePrefix = Array(#""total_token_usage":{"#.utf8)
    private static let quotedLastTokenUsagePrefix = Array(#""last_token_usage":{"#.utf8)
    private static let quotedInputTokensPrefix = Array(#""input_tokens":"#.utf8)
    private static let quotedCachedInputTokensPrefix = Array(#""cached_input_tokens":"#.utf8)
    private static let quotedCacheReadInputTokensPrefix = Array(#""cache_read_input_tokens":"#.utf8)
    private static let quotedOutputTokensPrefix = Array(#""output_tokens":"#.utf8)

    static func parseLine(_ data: Data) -> Line? {
        data.withUnsafeBytes { (rawBytes: UnsafeRawBufferPointer) -> Line? in
            let bytes = rawBytes.bindMemory(to: UInt8.self)
            guard !bytes.isEmpty else { return nil }
            let objectRange = 0..<bytes.count
            guard let type = extractJSONByteStringField(
                fieldType,
                from: bytes,
                in: objectRange,
                atDepth: 1
            ) else {
                return nil
            }

            switch type {
            case "session_meta":
                let payloadRange = extractJSONByteObjectField(
                    fieldPayload,
                    from: bytes,
                    in: objectRange,
                    atDepth: 1
                )
                return .sessionMeta(SessionMetadata(
                    sessionID: sessionID(from: bytes, in: objectRange, payloadRange: payloadRange),
                    forkedFromID: payloadRange.flatMap { forkParentID(from: bytes, in: $0) },
                    forkTimestamp: payloadRange.flatMap {
                        extractJSONByteStringField(fieldTimestamp, from: bytes, in: $0, atDepth: 1)
                    } ?? extractJSONByteStringField(fieldTimestamp, from: bytes, in: objectRange, atDepth: 1)
                ))

            case "turn_context":
                let payloadRange = extractJSONByteObjectField(
                    fieldPayload,
                    from: bytes,
                    in: objectRange,
                    atDepth: 1
                )
                let infoRange = payloadRange.flatMap {
                    extractJSONByteObjectField(fieldInfo, from: bytes, in: $0, atDepth: 1)
                }
                let model = payloadRange.flatMap { modelName(from: bytes, in: $0) }
                    ?? infoRange.flatMap { modelName(from: bytes, in: $0) }
                    ?? modelName(from: bytes, in: objectRange)
                let turnID = payloadRange.flatMap { turnIdentifier(from: bytes, in: $0) }
                    ?? infoRange.flatMap { turnIdentifier(from: bytes, in: $0) }
                    ?? turnIdentifier(from: bytes, in: objectRange)
                return .turnContext(TurnContextRecord(model: model, turnID: turnID))

            case "event_msg":
                guard let payloadRange = extractJSONByteObjectField(
                    fieldPayload,
                    from: bytes,
                    in: objectRange,
                    atDepth: 1
                ),
                    extractJSONByteStringField(fieldType, from: bytes, in: payloadRange, atDepth: 1) == "token_count",
                    let timestamp = extractJSONByteStringField(
                        fieldTimestamp,
                        from: bytes,
                        in: objectRange,
                        atDepth: 1
                    ),
                    let infoRange = extractJSONByteObjectField(
                        fieldInfo,
                        from: bytes,
                        in: payloadRange,
                        atDepth: 1
                    )
                else {
                    return nil
                }
                let model = modelName(from: bytes, in: infoRange)
                    ?? modelName(from: bytes, in: payloadRange)
                    ?? modelName(from: bytes, in: objectRange)

                let total = tokenTotals(
                    from: bytes,
                    in: extractJSONByteObjectField(
                        fieldTotalTokenUsage,
                        from: bytes,
                        in: infoRange,
                        atDepth: 1
                    )
                )
                let last = tokenTotals(
                    from: bytes,
                    in: extractJSONByteObjectField(
                        fieldLastTokenUsage,
                        from: bytes,
                        in: infoRange,
                        atDepth: 1
                    )
                )
                return .tokenCount(TokenCountRecord(timestamp: timestamp, model: model, last: last, total: total))

            default:
                return nil
            }
        }
    }

    static func parseTokenCountLine(_ data: Data) -> TokenCountRecord? {
        data.withUnsafeBytes { rawBytes in
            let bytes = rawBytes.bindMemory(to: UInt8.self)
            guard !bytes.isEmpty else { return nil }
            let range = 0..<bytes.count
            guard let timestamp = extractJSONStringAfterPrefix(
                quotedTimestampPrefix,
                from: bytes,
                in: range
            ) else {
                return nil
            }

            let total = tokenTotalsAfterPrefix(
                quotedTotalTokenUsagePrefix,
                from: bytes,
                in: range
            )
            let last = tokenTotalsAfterPrefix(
                quotedLastTokenUsagePrefix,
                from: bytes,
                in: range
            )
            guard total != nil || last != nil else {
                return nil
            }
            return TokenCountRecord(timestamp: timestamp, model: nil, last: last, total: total)
        }
    }

    private static func sessionID(
        from bytes: UnsafeBufferPointer<UInt8>,
        in rootRange: Range<Int>,
        payloadRange: Range<Int>?
    ) -> String? {
        if let payloadRange {
            for key in [fieldSessionID, fieldSessionIDCamel, fieldID] {
                if let value = extractJSONByteStringField(key, from: bytes, in: payloadRange, atDepth: 1),
                   !value.isEmpty {
                    return value
                }
            }
        }
        for key in [fieldSessionID, fieldSessionIDCamel, fieldID] {
            if let value = extractJSONByteStringField(key, from: bytes, in: rootRange, atDepth: 1),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func forkParentID(
        from bytes: UnsafeBufferPointer<UInt8>,
        in payloadRange: Range<Int>
    ) -> String? {
        for key in [fieldForkedFromID, fieldForkedFromIDCamel, fieldParentSessionID, fieldParentSessionIDCamel] {
            guard let value = extractJSONByteStringField(key, from: bytes, in: payloadRange, atDepth: 1)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !value.isEmpty
            else {
                continue
            }
            return value
        }
        return nil
    }

    private static func tokenTotals(
        from bytes: UnsafeBufferPointer<UInt8>,
        in objectRange: Range<Int>?
    ) -> TokenTotals? {
        guard let objectRange else { return nil }
        let input = max(0, extractJSONByteIntField(fieldInputTokens, from: bytes, in: objectRange, atDepth: 1) ?? 0)
        let cached = max(
            0,
            extractJSONByteIntField(fieldCachedInputTokens, from: bytes, in: objectRange, atDepth: 1)
                ?? extractJSONByteIntField(fieldCacheReadInputTokens, from: bytes, in: objectRange, atDepth: 1)
                ?? 0
        )
        let output = max(0, extractJSONByteIntField(fieldOutputTokens, from: bytes, in: objectRange, atDepth: 1) ?? 0)
        return TokenTotals(
            inputTokens: input,
            cachedInputTokens: cached,
            outputTokens: output,
            reasoningOutputTokens: 0,
            totalTokens: input + output
        ).positive
    }

    private static func tokenTotalsAfterPrefix(
        _ prefix: [UInt8],
        from bytes: UnsafeBufferPointer<UInt8>,
        in range: Range<Int>
    ) -> TokenTotals? {
        guard let objectStart = findBytes(prefix, in: bytes, range: range).map({ $0.upperBound - 1 }),
              let objectEnd = findByte(0x7D, in: bytes, range: objectStart..<range.upperBound)
        else {
            return nil
        }
        let objectRange = objectStart..<(objectEnd + 1)
        let input = max(0, extractIntAfterPrefix(quotedInputTokensPrefix, from: bytes, in: objectRange) ?? 0)
        let cached = max(
            0,
            extractIntAfterPrefix(quotedCachedInputTokensPrefix, from: bytes, in: objectRange)
                ?? extractIntAfterPrefix(quotedCacheReadInputTokensPrefix, from: bytes, in: objectRange)
                ?? 0
        )
        let output = max(0, extractIntAfterPrefix(quotedOutputTokensPrefix, from: bytes, in: objectRange) ?? 0)
        return TokenTotals(
            inputTokens: input,
            cachedInputTokens: cached,
            outputTokens: output,
            reasoningOutputTokens: 0,
            totalTokens: input + output
        ).positive
    }

    private static func extractJSONStringAfterPrefix(
        _ prefix: [UInt8],
        from bytes: UnsafeBufferPointer<UInt8>,
        in range: Range<Int>
    ) -> String? {
        guard let match = findBytes(prefix, in: bytes, range: range) else {
            return nil
        }
        var index = match.upperBound
        let start = index
        var hasEscapes = false
        while index < range.upperBound {
            switch bytes[index] {
            case 0x5C:
                hasEscapes = true
                index += 2
            case 0x22:
                let valueRange = start..<index
                if hasEscapes {
                    return decodeEscapedJSONByteString(from: bytes, in: valueRange)
                }
                return String(bytes: bytes[valueRange], encoding: .utf8)
            default:
                index += 1
            }
        }
        return nil
    }

    private static func extractIntAfterPrefix(
        _ prefix: [UInt8],
        from bytes: UnsafeBufferPointer<UInt8>,
        in range: Range<Int>
    ) -> Int? {
        guard let match = findBytes(prefix, in: bytes, range: range) else {
            return nil
        }
        var index = match.upperBound
        return parseJSONByteInt(in: bytes, index: &index, limit: range.upperBound)
    }

    private static func modelName(
        from bytes: UnsafeBufferPointer<UInt8>,
        in range: Range<Int>
    ) -> String? {
        for key in [fieldModel, fieldModelName] {
            guard let value = extractJSONByteStringField(key, from: bytes, in: range, atDepth: 1)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !value.isEmpty
            else {
                continue
            }
            return value
        }
        return nil
    }

    private static func turnIdentifier(
        from bytes: UnsafeBufferPointer<UInt8>,
        in range: Range<Int>
    ) -> String? {
        for key in [fieldTurnID, fieldTurnIDCamel, fieldID] {
            guard let value = extractJSONByteStringField(key, from: bytes, in: range, atDepth: 1)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !value.isEmpty
            else {
                continue
            }
            return value
        }
        return nil
    }

    private static func extractJSONByteStringField(
        _ field: [UInt8],
        from bytes: UnsafeBufferPointer<UInt8>,
        in range: Range<Int>,
        atDepth targetDepth: Int
    ) -> String? {
        extractJSONByteField(field, from: bytes, in: range, atDepth: targetDepth) { valueIndex in
            guard let parsed = parseJSONByteStringRange(in: bytes, index: &valueIndex, limit: range.upperBound),
                  parsed.range.lowerBound < parsed.range.upperBound
            else {
                return nil
            }
            if parsed.hasEscapes {
                return decodeEscapedJSONByteString(from: bytes, in: parsed.range)
            }
            return String(bytes: bytes[parsed.range], encoding: .utf8)
        }
    }

    private static func extractJSONByteObjectField(
        _ field: [UInt8],
        from bytes: UnsafeBufferPointer<UInt8>,
        in range: Range<Int>,
        atDepth targetDepth: Int
    ) -> Range<Int>? {
        extractJSONByteField(field, from: bytes, in: range, atDepth: targetDepth) { valueIndex in
            parseJSONByteObjectRange(in: bytes, index: &valueIndex, limit: range.upperBound)
        }
    }

    private static func extractJSONByteIntField(
        _ field: [UInt8],
        from bytes: UnsafeBufferPointer<UInt8>,
        in range: Range<Int>,
        atDepth targetDepth: Int
    ) -> Int? {
        extractJSONByteField(field, from: bytes, in: range, atDepth: targetDepth) { valueIndex in
            parseJSONByteInt(in: bytes, index: &valueIndex, limit: range.upperBound)
        }
    }

    private static func extractJSONByteField<T>(
        _ field: [UInt8],
        from bytes: UnsafeBufferPointer<UInt8>,
        in range: Range<Int>,
        atDepth targetDepth: Int,
        parseValue: (inout Int) -> T?
    ) -> T? {
        var index = range.lowerBound
        var depth = 0

        while index < range.upperBound {
            switch bytes[index] {
            case 0x7B:
                depth += 1
                index += 1
            case 0x7D:
                depth -= 1
                index += 1
            case 0x22:
                var valueIndex = index
                guard let key = parseJSONByteStringRange(in: bytes, index: &valueIndex, limit: range.upperBound)
                else {
                    return nil
                }
                index = valueIndex
                guard depth == targetDepth,
                      !key.hasEscapes,
                      byteRange(bytes, key.range, equals: field)
                else {
                    continue
                }

                skipJSONByteWhitespace(in: bytes, index: &valueIndex, limit: range.upperBound)
                guard valueIndex < range.upperBound, bytes[valueIndex] == 0x3A else { continue }

                valueIndex += 1
                skipJSONByteWhitespace(in: bytes, index: &valueIndex, limit: range.upperBound)
                if let value = parseValue(&valueIndex) {
                    return value
                }
            default:
                index += 1
            }
        }

        return nil
    }

    private static func parseJSONByteStringRange(
        in bytes: UnsafeBufferPointer<UInt8>,
        index: inout Int,
        limit: Int
    ) -> (range: Range<Int>, hasEscapes: Bool)? {
        guard index < limit, bytes[index] == 0x22 else { return nil }
        index += 1
        let start = index
        var hasEscapes = false

        while index < limit {
            switch bytes[index] {
            case 0x5C:
                hasEscapes = true
                index += 2
            case 0x22:
                let end = index
                index += 1
                return (start..<end, hasEscapes)
            default:
                index += 1
            }
        }

        return nil
    }

    private static func parseJSONByteObjectRange(
        in bytes: UnsafeBufferPointer<UInt8>,
        index: inout Int,
        limit: Int
    ) -> Range<Int>? {
        guard index < limit, bytes[index] == 0x7B else { return nil }
        let start = index
        var depth = 0

        while index < limit {
            switch bytes[index] {
            case 0x22:
                guard parseJSONByteStringRange(in: bytes, index: &index, limit: limit) != nil else {
                    return nil
                }
            case 0x7B:
                depth += 1
                index += 1
            case 0x7D:
                depth -= 1
                index += 1
                if depth == 0 {
                    return start..<index
                }
            default:
                index += 1
            }
        }

        return nil
    }

    private static func parseJSONByteInt(
        in bytes: UnsafeBufferPointer<UInt8>,
        index: inout Int,
        limit: Int
    ) -> Int? {
        var sign = 1
        if index < limit, bytes[index] == 0x2D {
            sign = -1
            index += 1
        }

        var value = 0
        var sawDigit = false
        while index < limit {
            let byte = bytes[index]
            guard byte >= 0x30, byte <= 0x39 else { break }
            sawDigit = true
            let digit = Int(byte - 0x30)
            let multiplied = value.multipliedReportingOverflow(by: 10)
            if multiplied.overflow { return nil }
            let added = multiplied.partialValue.addingReportingOverflow(digit)
            if added.overflow { return nil }
            value = added.partialValue
            index += 1
        }
        return sawDigit ? (sign == -1 ? -value : value) : nil
    }

    private static func skipJSONByteWhitespace(
        in bytes: UnsafeBufferPointer<UInt8>,
        index: inout Int,
        limit: Int
    ) {
        while index < limit {
            switch bytes[index] {
            case 0x20, 0x09, 0x0A, 0x0D:
                index += 1
            default:
                return
            }
        }
    }

    private static func decodeEscapedJSONByteString(
        from bytes: UnsafeBufferPointer<UInt8>,
        in range: Range<Int>
    ) -> String? {
        var output: [UInt8] = []
        output.reserveCapacity(range.count)
        var index = range.lowerBound
        while index < range.upperBound {
            let byte = bytes[index]
            guard byte == 0x5C else {
                output.append(byte)
                index += 1
                continue
            }

            index += 1
            guard index < range.upperBound else { return nil }
            switch bytes[index] {
            case 0x22, 0x5C, 0x2F:
                output.append(bytes[index])
            case 0x62:
                output.append(0x08)
            case 0x66:
                output.append(0x0C)
            case 0x6E:
                output.append(0x0A)
            case 0x72:
                output.append(0x0D)
            case 0x74:
                output.append(0x09)
            case 0x75:
                return decodeJSONStringViaFoundation(from: bytes, in: range)
            default:
                return nil
            }
            index += 1
        }

        return String(bytes: output, encoding: .utf8)
    }

    private static func decodeJSONStringViaFoundation(
        from bytes: UnsafeBufferPointer<UInt8>,
        in range: Range<Int>
    ) -> String? {
        var data = Data([0x22])
        data.append(UnsafeBufferPointer(rebasing: bytes[range]))
        data.append(0x22)
        return (try? JSONSerialization.jsonObject(with: data)) as? String
    }

    private static func byteRange(
        _ bytes: UnsafeBufferPointer<UInt8>,
        _ range: Range<Int>,
        equals field: [UInt8]
    ) -> Bool {
        guard range.count == field.count else { return false }
        var index = range.lowerBound
        var fieldIndex = 0
        while index < range.upperBound {
            guard bytes[index] == field[fieldIndex] else { return false }
            index += 1
            fieldIndex += 1
        }
        return true
    }

    private static func findByte(
        _ byte: UInt8,
        in bytes: UnsafeBufferPointer<UInt8>,
        range: Range<Int>
    ) -> Int? {
        var index = range.lowerBound
        while index < range.upperBound {
            if bytes[index] == byte {
                return index
            }
            index += 1
        }
        return nil
    }

    private static func findBytes(
        _ needle: [UInt8],
        in bytes: UnsafeBufferPointer<UInt8>,
        range: Range<Int>
    ) -> Range<Int>? {
        guard !needle.isEmpty,
              range.count >= needle.count
        else {
            return nil
        }

        var index = range.lowerBound
        let lastStart = range.upperBound - needle.count
        while index <= lastStart {
            if bytes[index] == needle[0] {
                var needleIndex = 1
                var matches = true
                while needleIndex < needle.count {
                    if bytes[index + needleIndex] != needle[needleIndex] {
                        matches = false
                        break
                    }
                    needleIndex += 1
                }
                if matches {
                    return index..<(index + needle.count)
                }
            }
            index += 1
        }
        return nil
    }
}

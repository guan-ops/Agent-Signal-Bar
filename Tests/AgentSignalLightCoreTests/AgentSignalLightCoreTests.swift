import Foundation
import XCTest
#if canImport(SQLite3)
import SQLite3
#endif
@testable import AgentSignalLight
@testable import AgentSignalLightCore
@testable import AgentSignalLightUI

final class AgentSignalLightCoreTests: XCTestCase {
    func testReleaseInfoPrefersCurrentManifestOverBundledReleaseInfo() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("release-info-\(UUID().uuidString)", isDirectory: true)
        let distURL = root.appendingPathComponent("dist", isDirectory: true)
        let resourceURL = distURL
            .appendingPathComponent("AgentSignalLight.app", isDirectory: true)
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: distURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resourceURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let manifestURL = distURL.appendingPathComponent("AgentSignalBar-release-manifest.json")
        try releaseMetadataJSON(version: "9.9.9", build: "42", signingMode: "developer_id")
            .write(to: manifestURL, atomically: true, encoding: .utf8)
        let releaseInfoURL = resourceURL.appendingPathComponent("AgentSignalLight-release-info.json")
        try releaseMetadataJSON(version: "1.0.0", build: "1", signingMode: "ad_hoc")
            .write(to: releaseInfoURL, atomically: true, encoding: .utf8)

        let previousDirectory = FileManager.default.currentDirectoryPath
        XCTAssertTrue(FileManager.default.changeCurrentDirectoryPath(root.path))
        defer { FileManager.default.changeCurrentDirectoryPath(previousDirectory) }

        let releaseInfo = ReleaseInfo.current()
        XCTAssertEqual(releaseInfo.version, "9.9.9")
        XCTAssertEqual(releaseInfo.build, "42")
        XCTAssertEqual(releaseInfo.signingMode, "developer_id")
        XCTAssertEqual(releaseInfo.manifestURL?.standardizedFileURL, manifestURL.standardizedFileURL)
        XCTAssertEqual(releaseInfo.releaseInfoURL?.standardizedFileURL, releaseInfoURL.standardizedFileURL)
        XCTAssertEqual(releaseInfo.releaseFileURL?.standardizedFileURL, manifestURL.standardizedFileURL)
    }

    func testFloatingSignalGeometryTracksLayout() {
        let scale = FloatingSignalScale.standard
        let verticalLamp = scale.panelSize(
            layout: .vertical,
            trafficLightVerticalUsesMacOSSize: false
        )
        let horizontalLamp = scale.panelSize(
            layout: .horizontal,
            trafficLightVerticalUsesMacOSSize: false
        )
        let horizontalBacking = scale.housingBackingSize(
            layout: .horizontal,
            trafficLightVerticalUsesMacOSSize: false
        )

        XCTAssertEqual(verticalLamp.width, 34 * scale.visualScale, accuracy: 0.01)
        XCTAssertEqual(verticalLamp.height, 74 * scale.visualScale, accuracy: 0.01)
        XCTAssertGreaterThan(horizontalLamp.width, verticalLamp.width)
        XCTAssertLessThan(horizontalLamp.height, verticalLamp.height)
        XCTAssertEqual(horizontalBacking.height, (16 + 12) * scale.visualScale, accuracy: 0.01)
    }

    func testSignalNormalizationAcceptsHumanInputVariants() {
        XCTAssert(AgentSignal.normalized("tool-done") == .toolDone)
        XCTAssert(AgentSignal.normalized(" session start ") == .sessionStart)
        XCTAssert(AgentSignal.normalized("PERMISSION") == .permission)
        XCTAssert(AgentSignal.normalized("PermissionRequest") == .permissionRequest)
        XCTAssert(AgentSignal.normalized("notification") == .notification)
        XCTAssert(AgentSignal.normalized("max-tokens") == .maxTokens)
    }

    func testJSONPayloadThrowsForInvalidHookPayload() {
        XCTAssertThrowsError(
            try JSONPayload.requiredObject(from: Data(#"{"event":"PreToolUse""#.utf8))
        )
        XCTAssertThrowsError(
            try JSONPayload.requiredObject(from: Data(#"["PreToolUse"]"#.utf8))
        )
        XCTAssertNoThrow(try JSONPayload.requiredObject(from: Data()))
    }

    func testCodexDesktopSessionParserMapsFunctionCallsToWorking() {
        let line = """
        {"timestamp":"2026-05-29T02:20:43.081Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","call_id":"call_1"}}
        """

        let activity = CodexDesktopSessionParser.activity(
            from: line,
            defaultSessionID: "codex-desktop:thread"
        )

        XCTAssert(activity?.signal == .working)
        XCTAssert(activity?.sessionID == "codex-desktop:thread")
        XCTAssert(activity?.event == "DesktopToolCall:exec_command")
        XCTAssert(activity?.timestamp != nil)
    }

    func testCodexDesktopSessionParserMapsTaskCompleteToDone() {
        let line = """
        {"timestamp":"2026-05-29T02:17:58.732Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1"}}
        """

        let activity = CodexDesktopSessionParser.activity(
            from: line,
            defaultSessionID: "codex-desktop:thread"
        )

        XCTAssert(activity?.signal == .done)
        XCTAssert(activity?.event == "DesktopTaskComplete")
    }

    func testCodexDesktopSessionParserMapsUserInputRequestsToAttention() {
        let line = """
        {"timestamp":"2026-05-29T02:20:43.081Z","type":"response_item","payload":{"type":"function_call","name":"request_user_input","call_id":"call_1"}}
        """

        let activity = CodexDesktopSessionParser.activity(
            from: line,
            defaultSessionID: "codex-desktop:thread"
        )

        XCTAssert(activity?.signal == .attention)
        XCTAssert(activity?.event == "DesktopToolCall:request_user_input")
    }

    func testCodexDesktopSessionParserDoesNotTreatPermissionProfileAsPermissionRequest() {
        let line = """
        {"timestamp":"2026-05-29T02:20:43.081Z","type":"turn_context","payload":{"approval_policy":"on-request","permission_profile":{"type":"managed","network":"restricted"}}}
        """

        XCTAssertNil(
            CodexDesktopSessionParser.activity(
                from: line,
                defaultSessionID: "codex-desktop:thread"
            )
        )
    }

    func testCodexDesktopSessionParserIgnoresTokenCountAndMapsCompactionToThinking() {
        let heartbeatLine = """
        {"timestamp":"2026-06-01T15:37:11.108Z","type":"event_msg","payload":{"type":"token_count","info":{"model_context_window":258400}}}
        """
        let compactedLine = """
        {"timestamp":"2026-06-01T15:34:42.602Z","type":"compacted","payload":{"message":"","replacement_history":[]}}
        """

        let heartbeatActivity = CodexDesktopSessionParser.activity(
            from: heartbeatLine,
            defaultSessionID: "codex-desktop:thread"
        )
        let compactedActivity = CodexDesktopSessionParser.activity(
            from: compactedLine,
            defaultSessionID: "codex-desktop:thread"
        )

        XCTAssertNil(heartbeatActivity)
        XCTAssert(compactedActivity?.signal == .thinking)
        XCTAssert(compactedActivity?.event == "DesktopContextCompacted")
    }

    func testCodexDesktopSessionParserMapsTokenCountToQuotaStatus() {
        let line = """
        {"timestamp":"2026-06-18T08:10:20.000Z","type":"event_msg","payload":{"type":"token_count","info":{"model_context_window":258400,"last_token_usage":{"input_tokens":34567,"cached_input_tokens":12000,"output_tokens":2345,"reasoning_output_tokens":567,"total_tokens":36912}},"rate_limits":{"limit_id":"codex_bengalfox","limit_name":"GPT-5.3-Codex-Spark","primary":{"used_percent":42.5,"window_minutes":300,"resets_at":1781788782},"secondary":{"used_percent":12.0,"window_minutes":10080,"resets_at":1782375582}}}}
        """

        let quotaUpdate = CodexDesktopSessionParser.quotaUpdate(
            from: line,
            defaultSessionID: "codex-desktop:thread"
        )

        XCTAssertEqual(quotaUpdate?.sessionID, "codex-desktop:thread")
        XCTAssertEqual(quotaUpdate?.agent, "codex-desktop")
        XCTAssertEqual(quotaUpdate?.quota.remainingPercent ?? -1, 57.5, accuracy: 0.01)
        XCTAssertEqual(quotaUpdate?.quota.usedPercent ?? -1, 42.5, accuracy: 0.01)
        XCTAssertEqual(quotaUpdate?.quota.limitName, "GPT-5.3-Codex-Spark")
        XCTAssertEqual(quotaUpdate?.quota.windowMinutes, 300)
        XCTAssertEqual(quotaUpdate?.quota.resetsAt, Date(timeIntervalSince1970: 1_781_788_782))
        XCTAssertEqual(quotaUpdate?.quota.primaryWindow?.remainingPercent ?? -1, 57.5, accuracy: 0.01)
        XCTAssertEqual(quotaUpdate?.quota.secondaryWindow?.remainingPercent ?? -1, 88.0, accuracy: 0.01)
        XCTAssertEqual(quotaUpdate?.quota.secondaryWindow?.windowMinutes, 10_080)
        XCTAssertEqual(quotaUpdate?.quota.secondaryWindow?.resetsAt, Date(timeIntervalSince1970: 1_782_375_582))
        XCTAssertEqual(quotaUpdate?.quota.tokenUsage?.inputTokens, 34_567)
        XCTAssertEqual(quotaUpdate?.quota.tokenUsage?.cachedInputTokens, 12_000)
        XCTAssertEqual(quotaUpdate?.quota.tokenUsage?.outputTokens, 2_345)
        XCTAssertEqual(quotaUpdate?.quota.tokenUsage?.reasoningOutputTokens, 567)
        XCTAssertEqual(quotaUpdate?.quota.tokenUsage?.effectiveTotalTokens, 36_912)
        XCTAssertEqual(quotaUpdate?.quota.tokenUsage?.contextWindowTokens, 258_400)
    }

    func testCodexDesktopSessionParserMapsTokenCountToActivityPoint() {
        let line = """
        {"timestamp":"2026-06-18T08:10:20.000Z","type":"event_msg","payload":{"type":"token_count","info":{"model_context_window":258400,"total_token_usage":{"input_tokens":50000,"cached_input_tokens":18000,"output_tokens":4000,"reasoning_output_tokens":900,"total_tokens":54000},"last_token_usage":{"input_tokens":34567,"cached_input_tokens":12000,"output_tokens":2345,"reasoning_output_tokens":567,"total_tokens":36912}}}}
        """

        let point = CodexDesktopSessionParser.tokenActivityPoint(from: line)
        let record = CodexDesktopSessionParser.tokenActivityRecord(from: line)

        XCTAssertEqual(point?.timestamp, Date(timeIntervalSince1970: 1_781_770_220))
        XCTAssertEqual(point?.usage.inputTokens, 34_567)
        XCTAssertEqual(point?.usage.cachedInputTokens, 12_000)
        XCTAssertEqual(point?.usage.outputTokens, 2_345)
        XCTAssertEqual(point?.usage.reasoningOutputTokens, 567)
        XCTAssertEqual(point?.usage.effectiveTotalTokens, 36_912)
        XCTAssertEqual(point?.usage.contextWindowTokens, 258_400)
        XCTAssertEqual(record?.totalUsage?.inputTokens, 50_000)
        XCTAssertEqual(record?.totalUsage?.cachedInputTokens, 18_000)
        XCTAssertEqual(record?.totalUsage?.outputTokens, 4_000)
        XCTAssertEqual(record?.totalUsage?.reasoningOutputTokens, 900)
        XCTAssertEqual(record?.totalUsage?.effectiveTotalTokens, 54_000)
        XCTAssertEqual(record?.totalUsage?.contextWindowTokens, 258_400)
    }

    func testCodexTokenActivityScannerUsesTotalDeltasAndIncludesCachedInput() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let lines = [
            #"{"timestamp":"2026-06-18T08:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":100,"output_tokens":100,"total_tokens":1100},"last_token_usage":{"input_tokens":1000,"cached_input_tokens":100,"output_tokens":100,"total_tokens":1100}}}}"#,
            #"{"timestamp":"2026-06-18T08:01:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":100,"output_tokens":100,"total_tokens":1100},"last_token_usage":{"input_tokens":1000,"cached_input_tokens":100,"output_tokens":100,"total_tokens":1100}}}}"#,
            #"{"timestamp":"2026-06-18T08:02:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1500,"cached_input_tokens":150,"output_tokens":150,"total_tokens":1650},"last_token_usage":{"input_tokens":500,"cached_input_tokens":50,"output_tokens":50,"total_tokens":550}}}}"#
        ].joined(separator: "\n")
        let sessionURL = root.appendingPathComponent("rollout-test.jsonl")
        try lines.write(to: sessionURL, atomically: true, encoding: .utf8)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let cacheURL = root.appendingPathComponent("token-cache.json")
        let scanner = CodexTokenActivityScanner(
            sessionRootURLs: [root],
            calendar: calendar,
            cacheURL: cacheURL
        )

        let days = scanner.scanDailyActivity(
            now: Date(timeIntervalSince1970: 1_781_784_000),
            days: 1
        )

        XCTAssertEqual(days.count, 1)
        XCTAssertEqual(days.first?.totalTokens, 1_650)
        XCTAssertNil(days.first?.modelTokenTotals["gpt-5.5"])
        XCTAssertNil(days.first?.modelTokenTotals["gpt-5"])
    }

    func testCodexTokenActivityScannerIgnoresEmbeddedTokenCountInToolOutput() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let embeddedOutput = #"""
        {"timestamp":"2026-06-18T08:01:00.000Z","type":"response_item","payload":{"type":"function_call_output","output":"12:{\"timestamp\":\"2026-06-18T08:00:30.000Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":999999999,\"cached_input_tokens\":0,\"output_tokens\":1,\"total_tokens\":1000000000},\"last_token_usage\":{\"input_tokens\":999999999,\"cached_input_tokens\":0,\"output_tokens\":1,\"total_tokens\":1000000000}}}}"}}
        """#
        let lines = [
            #"{"timestamp":"2026-06-18T08:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":100,"output_tokens":100,"total_tokens":1100},"last_token_usage":{"input_tokens":1000,"cached_input_tokens":100,"output_tokens":100,"total_tokens":1100}}}}"#,
            embeddedOutput,
            #"{"timestamp":"2026-06-18T08:02:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1500,"cached_input_tokens":150,"output_tokens":150,"total_tokens":1650},"last_token_usage":{"input_tokens":500,"cached_input_tokens":50,"output_tokens":50,"total_tokens":550}}}}"#
        ].joined(separator: "\n")
        let sessionURL = root.appendingPathComponent("rollout-embedded-token-count.jsonl")
        try lines.write(to: sessionURL, atomically: true, encoding: .utf8)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let scanner = CodexTokenActivityScanner(
            sessionRootURLs: [root],
            calendar: calendar,
            cacheURL: root.appendingPathComponent("token-cache.json")
        )

        let days = scanner.scanDailyActivity(
            now: Date(timeIntervalSince1970: 1_781_784_000),
            days: 1
        )

        XCTAssertEqual(days.count, 1)
        XCTAssertEqual(days.first?.totalTokens, 1_650)
    }

    func testCodexTokenActivityScannerSeparatesExactModelsFromTurnContext() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let lines = [
            #"{"timestamp":"2026-06-18T08:00:00.000Z","type":"turn_context","payload":{"model":"gpt-5.4"}}"#,
            #"{"timestamp":"2026-06-18T08:01:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":100,"output_tokens":100,"total_tokens":1100},"last_token_usage":{"input_tokens":1000,"cached_input_tokens":100,"output_tokens":100,"total_tokens":1100}}}}"#,
            #"{"timestamp":"2026-06-18T08:02:00.000Z","type":"turn_context","payload":{"model":"gpt-5.5"}}"#,
            #"{"timestamp":"2026-06-18T08:03:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1500,"cached_input_tokens":150,"output_tokens":150,"total_tokens":1650},"last_token_usage":{"input_tokens":500,"cached_input_tokens":50,"output_tokens":50,"total_tokens":550}}}}"#,
            #"{"timestamp":"2026-06-18T08:04:00.000Z","type":"turn_context","payload":{"model":"codex-auto-review"}}"#,
            #"{"timestamp":"2026-06-18T08:05:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1800,"cached_input_tokens":180,"output_tokens":200,"total_tokens":2000},"last_token_usage":{"input_tokens":300,"cached_input_tokens":30,"output_tokens":50,"total_tokens":350}}}}"#
        ].joined(separator: "\n")
        let sessionURL = root.appendingPathComponent("rollout-models.jsonl")
        try lines.write(to: sessionURL, atomically: true, encoding: .utf8)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let scanner = CodexTokenActivityScanner(
            sessionRootURLs: [root],
            calendar: calendar,
            cacheURL: root.appendingPathComponent("token-cache.json")
        )

        let days = scanner.scanDailyActivity(
            now: Date(timeIntervalSince1970: 1_781_784_000),
            days: 1
        )

        XCTAssertEqual(days.count, 1)
        XCTAssertEqual(days.first?.totalTokens, 2_000)
        XCTAssertEqual(days.first?.modelTokenTotals["gpt-5.4"], 1_100)
        XCTAssertEqual(days.first?.modelTokenTotals["gpt-5.5"], 550)
        XCTAssertEqual(days.first?.modelTokenTotals["codex-auto-review"], 350)
        XCTAssertNil(days.first?.modelEstimatedCostTotals["codex-auto-review"])
    }

    func testCodexTokenActivityScannerSeparatesPriorityAndStandardModelUsage() throws {
#if canImport(SQLite3)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let lines = [
            #"{"timestamp":"2026-06-18T08:00:00.000Z","type":"turn_context","payload":{"model":"gpt-5.5","turn_id":"turn-fast"}}"#,
            #"{"timestamp":"2026-06-18T08:01:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":100,"output_tokens":100,"total_tokens":1100},"last_token_usage":{"input_tokens":1000,"cached_input_tokens":100,"output_tokens":100,"total_tokens":1100}}}}"#,
            #"{"timestamp":"2026-06-18T08:02:00.000Z","type":"turn_context","payload":{"model":"gpt-5.5","turn_id":"turn-standard"}}"#,
            #"{"timestamp":"2026-06-18T08:03:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1500,"cached_input_tokens":150,"output_tokens":150,"total_tokens":1650},"last_token_usage":{"input_tokens":500,"cached_input_tokens":50,"output_tokens":50,"total_tokens":550}}}}"#
        ].joined(separator: "\n")
        let sessionURL = root.appendingPathComponent("rollout-priority-models.jsonl")
        try (lines + "\n").write(to: sessionURL, atomically: true, encoding: .utf8)

        let traceURL = root.appendingPathComponent("logs_2.sqlite")
        try createPriorityTraceDatabase(at: traceURL, turnID: "turn-fast", model: "gpt-5.5")

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let scanner = CodexTokenActivityScanner(
            sessionRootURLs: [root],
            calendar: calendar,
            cacheURL: root.appendingPathComponent("token-cache.json"),
            priorityDatabaseURL: traceURL
        )

        let days = scanner.scanDailyActivity(
            now: Date(timeIntervalSince1970: 1_781_784_000),
            days: 1
        )

        XCTAssertEqual(days.count, 1)
        XCTAssertEqual(days.first?.totalTokens, 1_650)
        XCTAssertEqual(days.first?.modelTokenTotals["gpt-5.5"], 1_650)
        XCTAssertEqual(days.first?.modelPriorityTokenTotals["gpt-5.5"], 1_100)
        XCTAssertEqual(days.first?.modelStandardTokenTotals["gpt-5.5"], 550)
        XCTAssertNotNil(days.first?.modelPriorityEstimatedCostTotals["gpt-5.5"])
        XCTAssertNotNil(days.first?.modelStandardEstimatedCostTotals["gpt-5.5"])
#else
        throw XCTSkip("SQLite3 is unavailable")
#endif
    }

    func testCodexTokenActivityScannerTreatsFastServiceTierAsFastUsage() throws {
#if canImport(SQLite3)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let lines = [
            #"{"timestamp":"2026-06-18T08:00:00.000Z","type":"turn_context","payload":{"model":"gpt-5.5","turn_id":"turn-fast"}}"#,
            #"{"timestamp":"2026-06-18T08:01:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":100,"output_tokens":100,"total_tokens":1100},"last_token_usage":{"input_tokens":1000,"cached_input_tokens":100,"output_tokens":100,"total_tokens":1100}}}}"#
        ].joined(separator: "\n")
        let sessionURL = root.appendingPathComponent("rollout-fast-tier.jsonl")
        try (lines + "\n").write(to: sessionURL, atomically: true, encoding: .utf8)

        let traceURL = root.appendingPathComponent("logs_2.sqlite")
        try createPriorityTraceDatabase(
            at: traceURL,
            turnID: "turn-fast",
            model: "gpt-5.5",
            serviceTier: "fast"
        )

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let scanner = CodexTokenActivityScanner(
            sessionRootURLs: [root],
            calendar: calendar,
            cacheURL: root.appendingPathComponent("token-cache.json"),
            priorityDatabaseURL: traceURL
        )

        let days = scanner.scanDailyActivity(
            now: Date(timeIntervalSince1970: 1_781_784_000),
            days: 1
        )

        XCTAssertEqual(days.first?.modelPriorityTokenTotals["gpt-5.5"], 1_100)
        XCTAssertNil(days.first?.modelStandardTokenTotals["gpt-5.5"])
#else
        throw XCTSkip("SQLite3 is unavailable")
#endif
    }

    func testCodexTokenActivityScannerKeepsCachedModelForIncrementalScan() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionURL = root.appendingPathComponent("rollout-incremental-model.jsonl")
        let initialLines = [
            #"{"timestamp":"2026-06-18T08:00:00.000Z","type":"turn_context","payload":{"model":"gpt-5.4"}}"#,
            #"{"timestamp":"2026-06-18T08:01:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":100,"output_tokens":100,"total_tokens":1100},"last_token_usage":{"input_tokens":1000,"cached_input_tokens":100,"output_tokens":100,"total_tokens":1100}}}}"#
        ].joined(separator: "\n")
        try (initialLines + "\n").write(to: sessionURL, atomically: true, encoding: .utf8)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let cacheURL = root.appendingPathComponent("token-cache.json")
        let now = Date(timeIntervalSince1970: 1_781_784_000)
        let firstScanner = CodexTokenActivityScanner(
            sessionRootURLs: [root],
            calendar: calendar,
            cacheURL: cacheURL
        )
        _ = firstScanner.scanDailyActivity(now: now, days: 1)

        let appendedLine =
            #"{"timestamp":"2026-06-18T08:02:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1500,"cached_input_tokens":150,"output_tokens":150,"total_tokens":1650},"last_token_usage":{"input_tokens":500,"cached_input_tokens":50,"output_tokens":50,"total_tokens":550}}}}"#
        let handle = try FileHandle(forWritingTo: sessionURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((appendedLine + "\n").utf8))
        try handle.close()

        let secondScanner = CodexTokenActivityScanner(
            sessionRootURLs: [root],
            calendar: calendar,
            cacheURL: cacheURL
        )
        let days = secondScanner.scanDailyActivity(now: now, days: 1)

        XCTAssertEqual(days.count, 1)
        XCTAssertEqual(days.first?.totalTokens, 1_650)
        XCTAssertEqual(days.first?.modelTokenTotals["gpt-5.4"], 1_650)
        XCTAssertNil(days.first?.modelTokenTotals["gpt-5.5"])
    }

    func testCodexTokenActivityScannerReadsModelFromLargeTurnContextLine() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionURL = root.appendingPathComponent("rollout-large-turn-context.jsonl")
        let largeContext = String(repeating: "x", count: 96 * 1024)
        let lines = [
            #"{"timestamp":"2026-06-18T08:00:00.000Z","type":"turn_context","payload":{"context":""# + largeContext + #"","model":"codex-auto-review"}}"#,
            #"{"timestamp":"2026-06-18T08:01:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":100,"output_tokens":100,"total_tokens":1100},"last_token_usage":{"input_tokens":1000,"cached_input_tokens":100,"output_tokens":100,"total_tokens":1100}}}}"#
        ].joined(separator: "\n")
        try (lines + "\n").write(to: sessionURL, atomically: true, encoding: .utf8)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let scanner = CodexTokenActivityScanner(
            sessionRootURLs: [root],
            calendar: calendar,
            cacheURL: root.appendingPathComponent("token-cache.json")
        )

        let days = scanner.scanDailyActivity(
            now: Date(timeIntervalSince1970: 1_781_784_000),
            days: 1
        )

        XCTAssertEqual(days.count, 1)
        XCTAssertEqual(days.first?.totalTokens, 1_100)
        XCTAssertEqual(days.first?.modelTokenTotals["codex-auto-review"], 1_100)
        XCTAssertNil(days.first?.modelEstimatedCostTotals["codex-auto-review"])
    }

    func testCodexTokenActivityFastParserReadsTurnContextModel() throws {
        let line = #"{"timestamp":"2026-06-18T08:00:00.000Z","type":"turn_context","payload":{"model":"gpt-5.4","turn_id":"turn-123"}}"#
        let parsed = CodexTokenActivityFastParser.parseLine(Data(line.utf8))

        switch parsed {
        case let .turnContext(record):
            XCTAssertEqual(record.model, "gpt-5.4")
            XCTAssertEqual(record.turnID, "turn-123")
        default:
            XCTFail("Expected turn context model")
        }
    }

    func testCodexTokenActivityScannerCountsOnlyNewForkedSessionUsageInThirtyDayTotals() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let parentURL = root.appendingPathComponent("rollout-parent.jsonl")
        let parentLines = [
            #"{"timestamp":"2026-06-18T07:50:00.000Z","type":"session_meta","payload":{"id":"parent-session","timestamp":"2026-06-18T07:50:00.000Z"}}"#,
            #"{"timestamp":"2026-06-18T07:55:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":100,"output_tokens":100,"total_tokens":1100}}}}"#
        ].joined(separator: "\n")
        try (parentLines + "\n").write(to: parentURL, atomically: true, encoding: .utf8)

        let childURL = root.appendingPathComponent("rollout-child.jsonl")
        let childLines = [
            #"{"timestamp":"2026-06-18T08:00:00.000Z","type":"session_meta","payload":{"id":"child-session","forked_from_id":"parent-session","timestamp":"2026-06-18T08:00:00.000Z"}}"#,
            #"{"timestamp":"2026-06-18T08:00:10.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":100,"output_tokens":100,"total_tokens":1100}}}}"#,
            #"{"timestamp":"2026-06-18T08:01:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1500,"cached_input_tokens":150,"output_tokens":150,"total_tokens":1650}}}}"#
        ].joined(separator: "\n")
        try (childLines + "\n").write(to: childURL, atomically: true, encoding: .utf8)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let scanner = CodexTokenActivityScanner(
            sessionRootURLs: [root],
            calendar: calendar,
            cacheURL: root.appendingPathComponent("token-cache.json")
        )

        let days = scanner.scanDailyActivity(
            now: Date(timeIntervalSince1970: 1_781_784_000),
            days: 1
        )

        XCTAssertEqual(days.count, 1)
        XCTAssertEqual(days.first?.totalTokens, 1_650)
    }

    func testCodexTokenActivityScannerUsesCachedOffsetForAppendedSessionFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionURL = root.appendingPathComponent("rollout-incremental.jsonl")
        let firstLine = #"{"timestamp":"2026-06-18T08:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":100,"output_tokens":100,"total_tokens":1100},"last_token_usage":{"input_tokens":1000,"cached_input_tokens":100,"output_tokens":100,"total_tokens":1100}}}}"#
        try (firstLine + "\n").write(to: sessionURL, atomically: true, encoding: .utf8)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let cacheURL = root.appendingPathComponent("token-cache.json")
        let firstScanner = CodexTokenActivityScanner(
            sessionRootURLs: [root],
            calendar: calendar,
            cacheURL: cacheURL
        )
        let firstDays = firstScanner.scanDailyActivity(
            now: Date(timeIntervalSince1970: 1_781_784_000),
            days: 1
        )
        XCTAssertEqual(firstDays.first?.totalTokens, 1_100)

        let appendedLines = [
            #"{"timestamp":"2026-06-18T08:01:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":100,"output_tokens":100,"total_tokens":1100},"last_token_usage":{"input_tokens":1000,"cached_input_tokens":100,"output_tokens":100,"total_tokens":1100}}}}"#,
            #"{"timestamp":"2026-06-18T08:02:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1500,"cached_input_tokens":150,"output_tokens":150,"total_tokens":1650},"last_token_usage":{"input_tokens":500,"cached_input_tokens":50,"output_tokens":50,"total_tokens":550}}}}"#
        ].joined(separator: "\n")
        let handle = try FileHandle(forWritingTo: sessionURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((appendedLines + "\n").utf8))
        try handle.close()

        let secondScanner = CodexTokenActivityScanner(
            sessionRootURLs: [root],
            calendar: calendar,
            cacheURL: cacheURL
        )
        let secondDays = secondScanner.scanDailyActivity(
            now: Date(timeIntervalSince1970: 1_781_784_000),
            days: 1
        )

        XCTAssertEqual(secondDays.count, 1)
        XCTAssertEqual(secondDays.first?.totalTokens, 1_650)
        XCTAssertTrue(try String(contentsOf: cacheURL, encoding: .utf8).contains("parsedBytes"))
    }

    func testCodexTokenActivityScannerReadsLargeSessionFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionURL = root.appendingPathComponent("rollout-large.jsonl")
        FileManager.default.createFile(atPath: sessionURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: sessionURL)
        defer { try? handle.close() }

        let fillerLine = """
        {"timestamp":"2026-06-18T07:59:00.000Z","type":"response_item","payload":{"type":"message","content":"\(String(repeating: "x", count: 1024))"}}
        """
        let fillerData = Data((fillerLine + "\n").utf8)
        for _ in 0..<(17 * 1024) {
            try handle.write(contentsOf: fillerData)
        }

        let tokenLine = """
        {"timestamp":"2026-06-18T08:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":100,"output_tokens":100,"total_tokens":1100},"last_token_usage":{"input_tokens":1000,"cached_input_tokens":100,"output_tokens":100,"total_tokens":1100}}}}
        """
        try handle.write(contentsOf: Data((tokenLine + "\n").utf8))

        let values = try sessionURL.resourceValues(forKeys: [.fileSizeKey])
        XCTAssertGreaterThan(values.fileSize ?? 0, 16 * 1024 * 1024)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let cacheURL = root.appendingPathComponent("token-cache.json")
        let scanner = CodexTokenActivityScanner(
            sessionRootURLs: [root],
            calendar: calendar,
            cacheURL: cacheURL
        )

        let days = scanner.scanDailyActivity(
            now: Date(timeIntervalSince1970: 1_781_784_000),
            days: 1
        )

        XCTAssertEqual(days.count, 1)
        XCTAssertEqual(days.first?.totalTokens, 1_100)
    }

    func testCodexTokenActivityScannerLoadsCachedDailyActivityWithoutSessionFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let cacheVersion = CodexTokenActivityScanner.currentCacheVersion
        let cacheURL = root.appendingPathComponent("codex-token-activity-v\(cacheVersion).json")
        try writeTokenActivityCache(
            version: cacheVersion,
            root: root,
            cacheURL: cacheURL,
            calendar: calendar,
            days: ["2026-06-18": 12_345]
        )

        let scanner = CodexTokenActivityScanner(
            sessionRootURLs: [root],
            calendar: calendar,
            cacheURL: cacheURL
        )

        let days = scanner.cachedDailyActivity(
            now: Date(timeIntervalSince1970: 1_781_784_000),
            days: 30
        )

        XCTAssertEqual(days?.count, 1)
        XCTAssertEqual(days?.first?.totalTokens, 12_345)
    }

    func testCodexTokenActivityScannerReturnsNilWhenCachedDailyActivityIsMissing() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let currentCacheURL = root.appendingPathComponent("codex-token-activity-v18.json")

        let scanner = CodexTokenActivityScanner(
            sessionRootURLs: [root],
            calendar: calendar,
            cacheURL: currentCacheURL
        )

        let days = scanner.cachedDailyActivity(
            now: Date(timeIntervalSince1970: 1_781_784_000),
            days: 30
        )

        XCTAssertNil(days)
    }

    func testCodexTokenActivityScannerDoesNotDisplayIncompleteCache() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let cacheURL = root.appendingPathComponent("codex-token-activity-v18.json")
        try writeTokenActivityCache(
            version: 18,
            root: root,
            cacheURL: cacheURL,
            calendar: calendar,
            days: ["2026-06-18": 12_345],
            isComplete: false
        )

        let scanner = CodexTokenActivityScanner(
            sessionRootURLs: [root],
            calendar: calendar,
            cacheURL: cacheURL
        )

        let days = scanner.cachedDailyActivity(
            now: Date(timeIntervalSince1970: 1_781_784_000),
            days: 30
        )

        XCTAssertNil(days)
    }

    func testCodexToolActivityScannerAggregatesAndCachesAppendedSessionFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionURL = root.appendingPathComponent("rollout-tools.jsonl")
        let initialLines = [
            #"{"timestamp":"2026-06-17T08:00:00.000Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","call_id":"call_1"}}"#,
            #"{"timestamp":"2026-06-18T08:01:00.000Z","type":"response_item","payload":{"type":"function_call","name":"apply_patch","call_id":"call_2"}}"#,
            #"{"timestamp":"2026-06-18T08:02:00.000Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","call_id":"call_3"}}"#,
            #"{"timestamp":"2026-06-18T08:03:00.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call_3","output":"done"}}"#
        ].joined(separator: "\n")
        try (initialLines + "\n").write(to: sessionURL, atomically: true, encoding: .utf8)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let cacheURL = root.appendingPathComponent("tool-cache.json")
        let firstScanner = CodexToolActivityScanner(
            sessionRootURLs: [root],
            calendar: calendar,
            cacheURL: cacheURL
        )
        let now = Date(timeIntervalSince1970: 1_781_798_400)
        let firstSummary = firstScanner.scanSummary(now: now)

        XCTAssertEqual(firstSummary.totalCalls, 3)
        XCTAssertEqual(firstSummary.todayCalls, 2)
        XCTAssertEqual(firstSummary.last30DaysCalls, 3)
        XCTAssertEqual(firstSummary.topTools.first?.name, "exec_command")
        XCTAssertEqual(firstSummary.topTools.first?.count, 2)

        let appendedLines = [
            #"{"timestamp":"2026-06-18T08:04:00.000Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","call_id":"call_4"}}"#,
            #"{"timestamp":"2026-06-18T08:05:00.000Z","type":"response_item","payload":{"type":"custom_tool_call","name":"request_user_input","call_id":"call_5"}}"#
        ].joined(separator: "\n")
        let handle = try FileHandle(forWritingTo: sessionURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((appendedLines + "\n").utf8))
        try handle.close()

        let secondScanner = CodexToolActivityScanner(
            sessionRootURLs: [root],
            calendar: calendar,
            cacheURL: cacheURL
        )
        let secondSummary = secondScanner.scanSummary(now: now)

        XCTAssertEqual(secondSummary.totalCalls, 5)
        XCTAssertEqual(secondSummary.todayCalls, 4)
        XCTAssertEqual(secondSummary.last30DaysCalls, 5)
        XCTAssertEqual(secondSummary.topTools.first?.name, "exec_command")
        XCTAssertEqual(secondSummary.topTools.first?.count, 3)
        XCTAssertTrue(try String(contentsOf: cacheURL, encoding: .utf8).contains("parsedBytes"))
    }

    func testCodexToolActivitySummaryAddsLiveToolCallsImmediately() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 6,
            day: 18,
            hour: 12
        )))
        let old = try XCTUnwrap(calendar.date(byAdding: .day, value: -31, to: now))

        let summary = CodexToolActivitySummary(
            totalCalls: 10,
            todayCalls: 2,
            last30DaysCalls: 9,
            topTools: [
                CodexToolActivityItem(name: "exec_command", count: 4),
                CodexToolActivityItem(name: "apply_patch", count: 3)
            ]
        )

        let next = summary
            .addingLiveToolCall(
                name: " exec_command ",
                timestamp: now,
                now: now,
                calendar: calendar
            )
            .addingLiveToolCall(
                name: "request_user_input",
                timestamp: old,
                now: now,
                calendar: calendar
            )

        XCTAssertEqual(next.totalCalls, 12)
        XCTAssertEqual(next.todayCalls, 3)
        XCTAssertEqual(next.last30DaysCalls, 10)
        XCTAssertEqual(next.topTools.first, CodexToolActivityItem(name: "exec_command", count: 5))
        XCTAssertTrue(next.topTools.contains(CodexToolActivityItem(name: "request_user_input", count: 1)))
    }

    private func writeTokenActivityCache(
        version: Int,
        root: URL,
        cacheURL: URL,
        calendar: Calendar,
        days: [String: Int],
        isComplete: Bool = true
    ) throws {
        let sessionPath = root.appendingPathComponent("missing-rollout.jsonl").path
        let payload: [String: Any] = [
            "version": version,
            "historyDays": 30,
            "calendarIdentifier": String(describing: calendar.identifier),
            "timeZoneIdentifier": calendar.timeZone.identifier,
            "roots": [root.path],
            "isComplete": isComplete,
            "files": [
                sessionPath: [
                    "size": 100,
                    "mtimeUnixMs": 1_781_784_000_000,
                    "parsedBytes": 100,
                    "baseline": NSNull(),
                    "days": days.mapValues {
                        [
                            "totalTokens": $0,
                            "modelTokenTotals": [
                                "gpt-5": $0
                            ],
                            "modelEstimatedCostTotals": [
                                "gpt-5": 0
                            ],
                            "modelStandardTokenTotals": [
                                "gpt-5": $0
                            ],
                            "modelPriorityTokenTotals": [:],
                            "modelStandardEstimatedCostTotals": [
                                "gpt-5": 0
                            ],
                            "modelPriorityEstimatedCostTotals": [:]
                        ]
                    }
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try data.write(to: cacheURL)
    }

#if canImport(SQLite3)
    private func createPriorityTraceDatabase(
        at url: URL,
        turnID: String,
        model: String,
        serviceTier: String = "priority"
    ) throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        guard let database else {
            throw NSError(domain: "AgentSignalLightTests", code: 1)
        }
        defer { sqlite3_close(database) }

        let createSQL = """
        CREATE TABLE logs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ts INTEGER NOT NULL,
            ts_nanos INTEGER NOT NULL,
            level TEXT NOT NULL,
            target TEXT NOT NULL,
            feedback_log_body TEXT,
            module_path TEXT,
            file TEXT,
            line INTEGER,
            thread_id TEXT,
            process_uuid TEXT,
            estimated_bytes INTEGER NOT NULL DEFAULT 0
        );
        """
        XCTAssertEqual(sqlite3_exec(database, createSQL, nil, nil, nil), SQLITE_OK)

        let body = """
        session_loop:turn{turn.id=\(turnID) model=\(model)}:run_sampling_request websocket request:{"type":"response.create","service_tier":"\(serviceTier)","model":"\(model)","turn_id":"\(turnID)"}
        """
        var statement: OpaquePointer?
        let insertSQL = """
        INSERT INTO logs (ts, ts_nanos, level, target, feedback_log_body, estimated_bytes)
        VALUES (?, 0, 'INFO', 'codex', ?, 0)
        """
        XCTAssertEqual(sqlite3_prepare_v2(database, insertSQL, -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, 1_781_755_200)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 2, body, -1, transient)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
    }
#endif

    func testCodexRateLimitFetcherMapsWhamUsageResponseToQuotaStatus() throws {
        let data = Data("""
        {
          "rate_limit": {
            "primary_window": {
              "used_percent": 2.5,
              "reset_at": 1781788782,
              "limit_window_seconds": 18000
            },
            "secondary_window": {
              "used_percent": 5.25,
              "reset_at": 1782375582,
              "limit_window_seconds": 604800
            },
            "individual_limit": {
              "limit": "20",
              "used": "20",
              "remaining_percent": "0",
              "resets_at": 1782375582
            }
          }
        }
        """.utf8)

        let response = try JSONDecoder().decode(CodexUsageResponse.self, from: data)
        let updatedAt = Date(timeIntervalSince1970: 1_781_700_000)
        let usageStatus = try CodexRateLimitFetcher.usageStatus(from: response, updatedAt: updatedAt)
        let quota = usageStatus.quota

        XCTAssertEqual(quota.remainingPercent, 97.5, accuracy: 0.01)
        XCTAssertEqual(quota.usedPercent ?? -1, 2.5, accuracy: 0.01)
        XCTAssertEqual(quota.windowMinutes, 300)
        XCTAssertEqual(quota.resetsAt, Date(timeIntervalSince1970: 1_781_788_782))
        XCTAssertEqual(quota.updatedAt, updatedAt)
        XCTAssertEqual(quota.primaryWindow?.remainingPercent ?? -1, 97.5, accuracy: 0.01)
        XCTAssertEqual(quota.primaryWindow?.windowMinutes, 300)
        XCTAssertEqual(quota.secondaryWindow?.remainingPercent ?? -1, 94.75, accuracy: 0.01)
        XCTAssertEqual(quota.secondaryWindow?.windowMinutes, 10_080)
        XCTAssertEqual(quota.secondaryWindow?.resetsAt, Date(timeIntervalSince1970: 1_782_375_582))
        XCTAssertEqual(usageStatus.credits?.limit ?? -1, 20, accuracy: 0.01)
        XCTAssertEqual(usageStatus.credits?.used ?? -1, 20, accuracy: 0.01)
        XCTAssertEqual(usageStatus.credits?.remaining ?? -1, 0, accuracy: 0.01)
        XCTAssertEqual(usageStatus.credits?.remainingPercent ?? -1, 0, accuracy: 0.01)
        XCTAssertEqual(usageStatus.credits?.resetsAt, Date(timeIntervalSince1970: 1_782_375_582))
    }

    func testCodexRateLimitFetcherDoesNotInventCreditQuotaWhenBalanceIsMissing() throws {
        let data = Data("""
        {
          "plan_type": "free",
          "rate_limit": {
            "primary_window": {
              "used_percent": 5,
              "reset_at": 1785075230,
              "limit_window_seconds": 2592000
            }
          },
          "spend_control": {
            "reached": false,
            "individual_limit": null
          },
          "credits": null
        }
        """.utf8)

        let response = try JSONDecoder().decode(CodexUsageResponse.self, from: data)
        let updatedAt = Date(timeIntervalSince1970: 1_782_483_230)
        let usageStatus = try CodexRateLimitFetcher.usageStatus(from: response, updatedAt: updatedAt)

        XCTAssertEqual(usageStatus.quota.remainingPercent, 95, accuracy: 0.01)
        XCTAssertEqual(usageStatus.quota.primaryWindow?.windowMinutes, 43_200)
        XCTAssertNil(usageStatus.credits)
    }

    func testCodexPlanFormattingMatchesProviderDisplayNames() {
        XCTAssertEqual(CodexPlanFormatting.displayName("pro"), "Pro 20x")
        XCTAssertEqual(CodexPlanFormatting.displayName("prolite"), "Pro 5x")
        XCTAssertEqual(CodexPlanFormatting.displayName("pro_lite"), "Pro 5x")
        XCTAssertEqual(CodexPlanFormatting.displayName("team_plan"), "Team Plan")
    }

    func testCodexServiceStatusFetcherParsesOpenAIStatusPage() throws {
        let data = Data("""
        {
          "page": {
            "updated_at": "2026-06-27T03:29:00.123Z"
          },
          "status": {
            "indicator": "minor",
            "description": "Partial System Degradation"
          }
        }
        """.utf8)

        let status = try CodexServiceStatusFetcher.parse(data)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        XCTAssertEqual(status.indicator, .minor)
        XCTAssertEqual(status.displayText, "Partial System Degradation")
        XCTAssertEqual(status.updatedAt, formatter.date(from: "2026-06-27T03:29:00.123Z"))
    }

    func testCodexRateLimitFetcherDoesNotRewriteAPIKeyAuthFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let authURL = root.appendingPathComponent("auth.json")
        let originalAuth = Data("""
        {
          "OPENAI_API_KEY": "sk-test-api-key",
          "tokens": {
            "access_token": "existing-oauth-token",
            "refresh_token": "existing-refresh-token"
          },
          "last_refresh": "2026-06-01T00:00:00Z"
        }
        """.utf8)
        try originalAuth.write(to: authURL)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CodexRateLimitFetcherURLProtocol.self]
        let session = URLSession(configuration: configuration)
        CodexRateLimitFetcherURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test-api-key")
            let data = Data("""
            {
              "rate_limit": {
                "primary_window": {
                  "used_percent": 10,
                  "reset_at": 1781788782,
                  "limit_window_seconds": 18000
                }
              }
            }
            """.utf8)
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, data)
        }
        defer { CodexRateLimitFetcherURLProtocol.handler = nil }

        let fetcher = CodexRateLimitFetcher(
            environment: ["CODEX_HOME": root.path],
            fileManager: .default,
            session: session
        )

        let quota = try await fetcher.fetchQuota(now: Date(timeIntervalSince1970: 1_781_700_000))

        XCTAssertEqual(quota.usedPercent ?? -1, 10, accuracy: 0.01)
        XCTAssertEqual(try Data(contentsOf: authURL), originalAuth)
    }

    func testCodexRateLimitFetcherUsesManualCookieHeader() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CodexRateLimitFetcherURLProtocol.self]
        let session = URLSession(configuration: configuration)
        CodexRateLimitFetcherURLProtocol.handler = { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "foo=bar; baz=qux")
            let data = Data("""
            {
              "rate_limit": {
                "primary_window": {
                  "used_percent": 25,
                  "reset_at": 1781788782,
                  "limit_window_seconds": 18000
                }
              }
            }
            """.utf8)
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, data)
        }
        defer { CodexRateLimitFetcherURLProtocol.handler = nil }

        let fetcher = CodexRateLimitFetcher(session: session)
        let usage = try await fetcher.fetchUsageStatus(
            route: .manualCookie("-H 'Cookie: foo=bar; baz=qux'")
        )

        XCTAssertEqual(usage.quota.usedPercent ?? -1, 25, accuracy: 0.01)
    }

    func testCodexRateLimitFetcherOAuthRouteDoesNotSendCookieHeader() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("""
        {
          "tokens": {
            "access_token": "oauth-token",
            "refresh_token": ""
          }
        }
        """.utf8).write(to: root.appendingPathComponent("auth.json"))

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CodexRateLimitFetcherURLProtocol.self]
        let session = URLSession(configuration: configuration)
        CodexRateLimitFetcherURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer oauth-token")
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            let data = Data("""
            {
              "rate_limit": {
                "primary_window": {
                  "used_percent": 15,
                  "reset_at": 1781788782,
                  "limit_window_seconds": 18000
                }
              }
            }
            """.utf8)
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, data)
        }
        defer { CodexRateLimitFetcherURLProtocol.handler = nil }

        let fetcher = CodexRateLimitFetcher(
            environment: ["CODEX_HOME": root.path],
            fileManager: .default,
            session: session
        )
        let usage = try await fetcher.fetchUsageStatus(route: .oauthAPI)

        XCTAssertEqual(usage.quota.usedPercent ?? -1, 15, accuracy: 0.01)
    }

    func testCodexRateLimitFetcherAutomaticRouteUsesImportedBrowserCookie() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CodexRateLimitFetcherURLProtocol.self]
        let session = URLSession(configuration: configuration)
        CodexRateLimitFetcherURLProtocol.handler = { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "auto_cookie=1")
            let data = Data("""
            {
              "rate_limit": {
                "primary_window": {
                  "used_percent": 35,
                  "reset_at": 1781788782,
                  "limit_window_seconds": 18000
                }
              }
            }
            """.utf8)
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, data)
        }
        defer { CodexRateLimitFetcherURLProtocol.handler = nil }

        let fetcher = CodexRateLimitFetcher(
            session: session,
            browserCookieImporter: FakeOpenAIBrowserCookieImporter(cookieHeader: "auto_cookie=1")
        )
        let usage = try await fetcher.fetchUsageStatus(
            route: .automatic(cookieHeader: nil, importsBrowserCookies: true)
        )

        XCTAssertEqual(usage.quota.usedPercent ?? -1, 35, accuracy: 0.01)
    }

    func testCodexAccountManagerSavesAndSwitchesAccounts() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storeURL = root.appendingPathComponent("accounts.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let authURL = root.appendingPathComponent("auth.json")
        let personalAuth = codexOAuthAuthJSON(
            email: "personal@example.com",
            accountID: "acct_personal",
            accessToken: "personal-access-token"
        )
        try personalAuth.write(to: authURL)

        let manager = CodexAccountManager(
            environment: ["CODEX_HOME": root.path],
            fileManager: .default,
            storeURL: storeURL
        )
        let personal = try manager.saveCurrentAccount()

        let workAuth = codexOAuthAuthJSON(
            email: "work@example.com",
            accountID: "acct_work",
            accessToken: "work-access-token"
        )
        try workAuth.write(to: authURL)
        let work = try manager.saveCurrentAccount()

        let savedState = try manager.loadState()
        XCTAssertEqual(savedState.savedAccounts.count, 2)
        XCTAssertEqual(savedState.activeSavedAccountID, work.id)

        let switched = try manager.switchToAccount(id: personal.id)
        XCTAssertEqual(switched.id, personal.id)
        XCTAssertEqual(try Data(contentsOf: authURL), personalAuth)

        let switchedState = try manager.loadState()
        XCTAssertEqual(switchedState.currentAccount?.email, "personal@example.com")
        XCTAssertEqual(switchedState.currentAccount?.accountID, "acct_personal")
        XCTAssertEqual(switchedState.activeSavedAccountID, personal.id)
    }

    func testCodexAccountManagerUpdatesExistingAccountAndRemovesSavedMetadataOnly() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storeURL = root.appendingPathComponent("accounts.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let authURL = root.appendingPathComponent("auth.json")
        let firstAuth = codexOAuthAuthJSON(
            email: "user@example.com",
            accountID: "acct_same",
            accessToken: "first-access-token"
        )
        try firstAuth.write(to: authURL)

        let manager = CodexAccountManager(
            environment: ["CODEX_HOME": root.path],
            fileManager: .default,
            storeURL: storeURL
        )
        let first = try manager.saveCurrentAccount()

        let refreshedAuth = codexOAuthAuthJSON(
            email: "user@example.com",
            accountID: "acct_same",
            accessToken: "refreshed-access-token"
        )
        try refreshedAuth.write(to: authURL)
        let refreshed = try manager.saveCurrentAccount()

        XCTAssertEqual(refreshed.id, first.id)
        XCTAssertEqual(try manager.loadState().savedAccounts.count, 1)

        try manager.removeAccount(id: refreshed.id)

        let removedState = try manager.loadState()
        XCTAssertEqual(removedState.savedAccounts.count, 0)
        XCTAssertNil(removedState.activeSavedAccountID)
        XCTAssertEqual(try Data(contentsOf: authURL), refreshedAuth)
    }

    func testCodexAccountManagerPreservesUnsavedCurrentAccountBeforeSwitching() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storeURL = root.appendingPathComponent("accounts.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let authURL = root.appendingPathComponent("auth.json")
        let savedAuth = codexOAuthAuthJSON(
            email: "saved@example.com",
            accountID: "acct_saved",
            accessToken: "saved-access-token"
        )
        try savedAuth.write(to: authURL)

        let manager = CodexAccountManager(
            environment: ["CODEX_HOME": root.path],
            fileManager: .default,
            storeURL: storeURL
        )
        let saved = try manager.saveCurrentAccount()

        let unsavedAuth = codexOAuthAuthJSON(
            email: "unsaved@example.com",
            accountID: "acct_unsaved",
            accessToken: "unsaved-access-token"
        )
        try unsavedAuth.write(to: authURL)

        _ = try manager.switchToAccount(id: saved.id)

        let state = try manager.loadState()
        XCTAssertEqual(try Data(contentsOf: authURL), savedAuth)
        XCTAssertEqual(state.activeSavedAccountID, saved.id)
        XCTAssertTrue(state.savedAccounts.contains { $0.email == "unsaved@example.com" })
    }

    func testCodexAccountManagerAddsManagedAccountThroughScopedLogin() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storeURL = root.appendingPathComponent("accounts.json")
        let managedHomeRootURL = root.appendingPathComponent("managed-homes", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let managedAuth = codexOAuthAuthJSON(
            email: "managed@example.com",
            accountID: "acct_managed",
            accessToken: "managed-access-token"
        )
        let loginRunner = FakeCodexAccountLoginRunner(authData: managedAuth)
        let manager = CodexAccountManager(
            environment: ["CODEX_HOME": root.path],
            fileManager: .default,
            storeURL: storeURL,
            managedHomeRootURL: managedHomeRootURL,
            loginRunner: loginRunner
        )

        let account = try await manager.authenticateManagedAccount()

        XCTAssertEqual(account.email, "managed@example.com")
        XCTAssertEqual(account.accountID, "acct_managed")
        let observedHomePath = try XCTUnwrap(loginRunner.observedHomePath)
        XCTAssertTrue(observedHomePath.hasPrefix(managedHomeRootURL.path))
        XCTAssertNil(account.managedHomePath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: observedHomePath))
        XCTAssertEqual(try manager.loadState().savedAccounts.count, 1)

        let switched = try manager.switchToAccount(id: account.id)
        XCTAssertEqual(switched.id, account.id)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("auth.json")), managedAuth)
        XCTAssertEqual(try manager.loadState().activeSavedAccountID, account.id)
    }

    func testCodexAccountUsageSnapshotsStayScopedToAccountIDWhenEmailsMatch() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let accountStoreURL = root.appendingPathComponent("accounts.json")
        let usageStoreURL = root.appendingPathComponent("usage-snapshots.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let authURL = root.appendingPathComponent("auth.json")
        let alphaAuth = codexOAuthAuthJSON(
            email: "shared@example.com",
            accountID: "acct_alpha",
            accessToken: "alpha-access-token"
        )
        try alphaAuth.write(to: authURL)

        let manager = CodexAccountManager(
            environment: ["CODEX_HOME": root.path],
            fileManager: .default,
            storeURL: accountStoreURL
        )
        let alpha = try manager.saveCurrentAccount()
        let alphaCurrent = try XCTUnwrap(try manager.loadState().currentAccount)

        let betaAuth = codexOAuthAuthJSON(
            email: "shared@example.com",
            accountID: "acct_beta",
            accessToken: "beta-access-token"
        )
        try betaAuth.write(to: authURL)
        let beta = try manager.saveCurrentAccount()
        let betaCurrent = try XCTUnwrap(try manager.loadState().currentAccount)

        let usageStore = CodexAccountUsageSnapshotStore(fileURL: usageStoreURL)
        let alphaQuota = codexQuotaFixture(remainingPercent: 84, updatedAt: 1_782_500_100)
        let betaQuota = codexQuotaFixture(remainingPercent: 42, updatedAt: 1_782_500_200)
        usageStore.store(
            account: alphaCurrent,
            quota: alphaQuota,
            credits: nil,
            tokenUsage: AgentTokenUsage(totalTokens: 1_000),
            tokenActivityCacheVersion: CodexTokenActivityScanner.currentCacheVersion,
            tokenActivityDays: [CodexTokenActivityDay(day: Date(timeIntervalSince1970: 1_782_432_000), totalTokens: 1_000)]
        )
        usageStore.store(
            account: betaCurrent,
            quota: betaQuota,
            credits: nil,
            tokenUsage: AgentTokenUsage(totalTokens: 2_000),
            tokenActivityCacheVersion: CodexTokenActivityScanner.currentCacheVersion,
            tokenActivityDays: [CodexTokenActivityDay(day: Date(timeIntervalSince1970: 1_782_432_000), totalTokens: 2_000)]
        )

        _ = try manager.switchToAccount(id: alpha.id)
        let loadedAlpha = try XCTUnwrap(try manager.loadState().currentAccount)
        XCTAssertEqual(usageStore.snapshot(for: loadedAlpha)?.quota?.remainingPercent, 84)
        XCTAssertEqual(usageStore.snapshot(for: loadedAlpha)?.tokenUsage?.totalTokens, 1_000)
        XCTAssertEqual(usageStore.snapshot(for: loadedAlpha)?.tokenActivityDays.first?.totalTokens, 1_000)

        _ = try manager.switchToAccount(id: beta.id)
        let loadedBeta = try XCTUnwrap(try manager.loadState().currentAccount)
        XCTAssertEqual(usageStore.snapshot(for: loadedBeta)?.quota?.remainingPercent, 42)
        XCTAssertEqual(usageStore.snapshot(for: loadedBeta)?.tokenUsage?.totalTokens, 2_000)
        XCTAssertEqual(usageStore.snapshot(for: loadedBeta)?.tokenActivityDays.first?.totalTokens, 2_000)
    }

    @MainActor
    func testLongQuotaWindowResetTextIncludesDateAndDynamicTitle() {
        let model = MenuBarStatusModel()
        model.appLanguage = .zhHans
        let window = AgentQuotaWindowStatus(
            remainingPercent: 84,
            usedPercent: 16,
            windowMinutes: 10_080,
            resetsAt: Date(timeIntervalSince1970: 1_782_375_582)
        )

        let fiveHourText = model.quotaResetText(for: window, badgeWindow: .fiveHours)
        let weeklyText = model.quotaResetText(for: window, badgeWindow: .weekly)

        XCTAssertTrue(fiveHourText.hasPrefix("重置 "))
        XCTAssertTrue(weeklyText.hasPrefix("重置 "))
        XCTAssertEqual(fiveHourText, weeklyText)
        XCTAssertFalse(weeklyText.contains("2026"))
        XCTAssertEqual(model.displayName(for: window, fallback: .fiveHours), "一周")

        let monthlyWindow = AgentQuotaWindowStatus(
            remainingPercent: 95,
            usedPercent: 5,
            windowMinutes: 43_200,
            resetsAt: Date(timeIntervalSince1970: 1_785_075_230)
        )
        let quota = AgentQuotaStatus(
            remainingPercent: 95,
            usedPercent: 5,
            windowMinutes: monthlyWindow.windowMinutes,
            resetsAt: monthlyWindow.resetsAt,
            updatedAt: Date(timeIntervalSince1970: 1_782_483_230),
            primary: monthlyWindow,
            secondary: nil
        )

        XCTAssertEqual(model.displayName(for: monthlyWindow, fallback: .fiveHours), "30 天")
        XCTAssertEqual(model.quotaTitleLine(for: .fiveHours, quota: quota), "30 天 · 剩余 95%")
    }

    @MainActor
    func testCompactTokenUsageTextUsesTwoDecimalPlaces() {
        let model = MenuBarStatusModel()
        model.appLanguage = .zhHans

        XCTAssertEqual(model.compactTokenCountText(6_500_000_000), "65.00亿")
        XCTAssertEqual(model.compactTokenCountText(12_345), "1.23万")

        model.appLanguage = .english
        XCTAssertEqual(model.compactTokenCountText(1_234_567_890), "1.23B")
        XCTAssertEqual(model.compactTokenCountText(1_234), "1.23K")
    }

    @MainActor
    func testFloatingSignalDebugLightUsesLiveTickForTargetedOverride() {
        let model = MenuBarStatusModel()

        model.setDebugLight(signal: .working, targets: [.floatingSignal])
        XCTAssertEqual(model.floatingSignalLightSnapshot.aggregate, .working)
        XCTAssertNil(model.statusBarStatusLightOverride)
        XCTAssertNotNil(model.floatingSignalStatusLightOverride)
        XCTAssertEqual(model.floatingSignalLightTick, 0)

        model.animationClock.advance(by: 3)

        XCTAssertEqual(model.floatingSignalLightTick, 3)
        XCTAssertEqual(model.statusBarLightTick, 3)
    }

    func testCodexDesktopSessionParserMapsExecSourceToCliAgent() {
        let metaLine = """
        {"timestamp":"2026-06-04T10:44:32.263Z","type":"session_meta","payload":{"id":"thread","originator":"Codex Desktop","source":"exec"}}
        """
        let activityLine = """
        {"timestamp":"2026-06-04T10:44:38.891Z","type":"response_item","payload":{"type":"reasoning"}}
        """

        let agent = CodexDesktopSessionParser.agentName(fromSessionMetaLine: metaLine)
        let activity = CodexDesktopSessionParser.activity(
            from: activityLine,
            defaultSessionID: "codex-cli:thread",
            defaultAgent: agent ?? "codex-desktop"
        )

        XCTAssertEqual(agent, "codex-cli")
        XCTAssertEqual(activity?.agent, "codex-cli")
        XCTAssertEqual(activity?.sessionID, "codex-cli:thread")
    }

    func testCodexDesktopSessionParserMapsIDEASourceToIDEAgent() {
        let metaLine = """
        {"timestamp":"2026-06-04T10:44:32.263Z","type":"session_meta","payload":{"id":"thread","originator":"IntelliJ IDEA","source":"ide"}}
        """

        XCTAssertEqual(CodexDesktopSessionParser.agentName(fromSessionMetaLine: metaLine), "codex-idea")
    }

    func testCodexDesktopSessionParserMapsEditorSourcesToSpecificIDEAgents() {
        let vscodeMetaLine = """
        {"timestamp":"2026-06-04T10:44:32.263Z","type":"session_meta","payload":{"id":"thread","originator":"VS Code","source":"vscode"}}
        """
        let xcodeMetaLine = """
        {"timestamp":"2026-06-04T10:44:32.263Z","type":"session_meta","payload":{"id":"thread","originator":"Xcode","source":"xcode"}}
        """
        let realXcodeMetaLine = """
        {"timestamp":"2026-06-04T12:12:15.954Z","type":"session_meta","payload":{"id":"thread","originator":"Xcode","source":"vscode"}}
        """

        XCTAssertEqual(CodexDesktopSessionParser.agentName(fromSessionMetaLine: vscodeMetaLine), "codex-vscode")
        XCTAssertEqual(CodexDesktopSessionParser.agentName(fromSessionMetaLine: xcodeMetaLine), "codex-xcode")
        XCTAssertEqual(CodexDesktopSessionParser.agentName(fromSessionMetaLine: realXcodeMetaLine), "codex-xcode")
    }

    func testCodexDesktopSessionParserKeepsCodexDesktopWhenSourceLooksLikeEditor() {
        let metaLine = """
        {"timestamp":"2026-06-04T10:44:32.263Z","type":"session_meta","payload":{"id":"thread","originator":"Codex Desktop","source":"vscode"}}
        """

        XCTAssertEqual(CodexDesktopSessionParser.agentName(fromSessionMetaLine: metaLine), "codex-desktop")
    }

    func testCodexDesktopActivityMonitorReturnsAllNewActivitiesInOrder() throws {
        let fixture = try makeTemporaryCodexSessionsRoot()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let now = Date()
        let reasoningTimestamp = isoTimestamp(now.addingTimeInterval(-2))
        let toolTimestamp = isoTimestamp(now.addingTimeInterval(-1))

        let sessionFile = fixture.sessionsRoot
            .appendingPathComponent("2026/06/02", isDirectory: true)
            .appendingPathComponent("rollout-2026-06-02T00-00-00-019e83ed-3f20-7000-9000-000000000001.jsonl")
        try FileManager.default.createDirectory(
            at: sessionFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try [
            #"{"timestamp":"\#(reasoningTimestamp)","type":"response_item","payload":{"type":"reasoning"}}"#,
            #"{"timestamp":"\#(toolTimestamp)","type":"response_item","payload":{"type":"function_call","name":"exec_command"}}"#
        ].joined(separator: "\n")
            .appending("\n")
            .write(to: sessionFile, atomically: true, encoding: .utf8)

        let monitor = CodexDesktopActivityMonitor(
            sessionsRootURL: fixture.sessionsRoot,
            replaysInitialHistory: true
        )
        let activities = monitor.poll(now: now)

        XCTAssertEqual(activities.map(\.signal), [.thinking, .working])
        XCTAssertEqual(activities.map(\.event), ["DesktopThinking", "DesktopToolCall:exec_command"])
    }

    func testCodexDesktopActivityMonitorKeepsSessionMetaSourceForFileActivities() throws {
        let fixture = try makeTemporaryCodexSessionsRoot()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let now = Date()
        let timestamp = isoTimestamp(now.addingTimeInterval(-1))

        let sessionFile = fixture.sessionsRoot
            .appendingPathComponent("2026/06/04", isDirectory: true)
            .appendingPathComponent("rollout-2026-06-04T22-44-31-019e923c-1358-77e3-b5d2-d9ab0a9d4036.jsonl")
        try FileManager.default.createDirectory(
            at: sessionFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try [
            #"{"timestamp":"\#(timestamp)","type":"session_meta","payload":{"id":"019e923c-1358-77e3-b5d2-d9ab0a9d4036","originator":"Codex Desktop","source":"exec"}}"#,
            #"{"timestamp":"\#(timestamp)","type":"response_item","payload":{"type":"reasoning"}}"#
        ].joined(separator: "\n")
            .appending("\n")
            .write(to: sessionFile, atomically: true, encoding: .utf8)

        let monitor = CodexDesktopActivityMonitor(
            sessionsRootURL: fixture.sessionsRoot,
            replaysInitialHistory: true
        )
        let activities = monitor.poll(now: now)

        XCTAssertEqual(activities.map(\.agent), ["codex-cli"])
        XCTAssertEqual(activities.map(\.sessionID), ["codex-cli:019e923c-1358-77e3-b5d2-d9ab0a9d4036"])
    }

    func testCodexDesktopActivityMonitorLetsTaskCompleteOverrideCLIHeartbeat() throws {
        let fixture = try makeTemporaryCodexSessionsRoot()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let now = Date()
        let messageTimestamp = isoTimestamp(now.addingTimeInterval(-3))
        let heartbeatTimestamp = isoTimestamp(now.addingTimeInterval(-2))
        let completeTimestamp = isoTimestamp(now.addingTimeInterval(-1))

        let sessionFile = fixture.sessionsRoot
            .appendingPathComponent("2026/06/05", isDirectory: true)
            .appendingPathComponent("rollout-2026-06-05T01-13-52-019e92c4-d204-7ce2-b7c2-63b01e7789b9.jsonl")
        try FileManager.default.createDirectory(
            at: sessionFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try [
            #"{"timestamp":"\#(messageTimestamp)","type":"session_meta","payload":{"id":"019e92c4-d204-7ce2-b7c2-63b01e7789b9","originator":"codex-tui","source":"cli"}}"#,
            #"{"timestamp":"\#(messageTimestamp)","type":"event_msg","payload":{"type":"agent_message","message":"DONE"}}"#,
            #"{"timestamp":"\#(heartbeatTimestamp)","type":"event_msg","payload":{"type":"token_count","info":{"model_context_window":258400}}}"#,
            #"{"timestamp":"\#(completeTimestamp)","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1"}}"#
        ].joined(separator: "\n")
            .appending("\n")
            .write(to: sessionFile, atomically: true, encoding: .utf8)

        let monitor = CodexDesktopActivityMonitor(
            sessionsRootURL: fixture.sessionsRoot,
            replaysInitialHistory: true
        )
        let activities = monitor.poll(now: now)

        XCTAssertEqual(activities.map(\.agent), ["codex-cli"])
        XCTAssertEqual(activities.map(\.signal), [.done])
        XCTAssertEqual(activities.map(\.event), ["DesktopTaskComplete"])
    }

    func testCodexDesktopActivityMonitorDoesNotReviveCompletedCLIWithOldHeartbeat() throws {
        let fixture = try makeTemporaryCodexSessionsRoot()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let now = Date()
        let messageTimestamp = isoTimestamp(now.addingTimeInterval(-33))
        let heartbeatTimestamp = isoTimestamp(now.addingTimeInterval(-32))
        let completeTimestamp = isoTimestamp(now.addingTimeInterval(-31))

        let sessionFile = fixture.sessionsRoot
            .appendingPathComponent("2026/06/05", isDirectory: true)
            .appendingPathComponent("rollout-2026-06-05T01-13-52-019e92c4-d204-7ce2-b7c2-63b01e7789b9.jsonl")
        try FileManager.default.createDirectory(
            at: sessionFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try [
            #"{"timestamp":"\#(messageTimestamp)","type":"session_meta","payload":{"id":"019e92c4-d204-7ce2-b7c2-63b01e7789b9","originator":"codex-tui","source":"cli"}}"#,
            #"{"timestamp":"\#(messageTimestamp)","type":"event_msg","payload":{"type":"agent_message","message":"DONE"}}"#,
            #"{"timestamp":"\#(heartbeatTimestamp)","type":"event_msg","payload":{"type":"token_count","info":{"model_context_window":258400}}}"#,
            #"{"timestamp":"\#(completeTimestamp)","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1"}}"#
        ].joined(separator: "\n")
            .appending("\n")
            .write(to: sessionFile, atomically: true, encoding: .utf8)

        let monitor = CodexDesktopActivityMonitor(
            sessionsRootURL: fixture.sessionsRoot,
            replaysInitialHistory: true
        )

        XCTAssertEqual(monitor.poll(now: now), [])
    }

    func testCodexDesktopActivityMonitorTreatsJetBrainsSessionRootAsIDEActivity() throws {
        let fixture = try makeTemporaryCodexSessionsRoot()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let now = Date()
        let timestamp = isoTimestamp(now.addingTimeInterval(-1))
        let jetBrainsRoot = fixture.directory
            .appendingPathComponent("Library/Caches/JetBrains/IntelliJIdea2026.1/aia/codex/sessions", isDirectory: true)
        let sessionFile = jetBrainsRoot
            .appendingPathComponent("2026/06/04", isDirectory: true)
            .appendingPathComponent("rollout-2026-06-04T23-24-43-019e9260-e08e-78f2-9153-71bdec75e968.jsonl")
        try FileManager.default.createDirectory(
            at: sessionFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try [
            #"{"timestamp":"\#(timestamp)","type":"session_meta","payload":{"id":"019e9260-e08e-78f2-9153-71bdec75e968","originator":"Codex Desktop","source":"vscode"}}"#,
            #"{"timestamp":"\#(timestamp)","type":"response_item","payload":{"type":"function_call","name":"exec_command"}}"#
        ].joined(separator: "\n")
            .appending("\n")
            .write(to: sessionFile, atomically: true, encoding: .utf8)

        let monitor = CodexDesktopActivityMonitor(
            sessionRootURLs: [jetBrainsRoot],
            forcedAgentsByRootPath: [jetBrainsRoot.path: "codex-idea"],
            replaysInitialHistory: true
        )
        let activities = monitor.poll(now: now)

        XCTAssertEqual(activities.map(\.agent), ["codex-idea"])
        XCTAssertEqual(activities.map(\.sessionID), ["codex-idea:019e9260-e08e-78f2-9153-71bdec75e968"])
        XCTAssertEqual(activities.map(\.event), ["DesktopToolCall:exec_command"])
    }

    func testCodexDesktopActivityMonitorUsesVSCodeLogHintsForGlobalSessions() throws {
        let fixture = try makeTemporaryCodexSessionsRoot()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let now = Date()
        let timestamp = isoTimestamp(now.addingTimeInterval(-1))
        let sessionID = "019c846a-b85e-7bd3-924b-cc33e3f180d9"
        let sessionFile = fixture.sessionsRoot
            .appendingPathComponent("2026/02/22", isDirectory: true)
            .appendingPathComponent("rollout-2026-02-22T21-15-12-\(sessionID).jsonl")
        try FileManager.default.createDirectory(
            at: sessionFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try [
            #"{"timestamp":"\#(timestamp)","type":"session_meta","payload":{"id":"\#(sessionID)","originator":"Codex Desktop","source":"vscode"}}"#,
            #"{"timestamp":"\#(timestamp)","type":"response_item","payload":{"type":"function_call","name":"exec_command"}}"#
        ].joined(separator: "\n")
            .appending("\n")
            .write(to: sessionFile, atomically: true, encoding: .utf8)

        let logRoot = fixture.directory
            .appendingPathComponent("Library/Application Support/Code/logs/20260604T234236/window1/exthost/openai.chatgpt", isDirectory: true)
        try FileManager.default.createDirectory(at: logRoot, withIntermediateDirectories: true)
        try """
        2026-06-04 23:42:48.663 [info] maybe_resume_success conversationId=\(sessionID) latestTurnStatus=completed
        """.write(
            to: logRoot.appendingPathComponent("Codex.log"),
            atomically: true,
            encoding: .utf8
        )

        let monitor = CodexDesktopActivityMonitor(
            sessionRootURLs: [fixture.sessionsRoot],
            vsCodeLogRootURL: fixture.directory.appendingPathComponent("Library/Application Support/Code/logs", isDirectory: true),
            replaysInitialHistory: true
        )
        let activities = monitor.poll(now: now)

        XCTAssertEqual(activities.map(\.agent), ["codex-vscode"])
        XCTAssertEqual(activities.map(\.sessionID), ["codex-vscode:\(sessionID)"])
        XCTAssertEqual(activities.map(\.event), ["DesktopToolCall:exec_command"])
    }

    func testCodexDesktopActivityMonitorKeepsPartialJSONLUntilComplete() throws {
        let fixture = try makeTemporaryCodexSessionsRoot()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let now = Date()
        let reasoningTimestamp = isoTimestamp(now.addingTimeInterval(-3))
        let toolTimestamp = isoTimestamp(now.addingTimeInterval(-1))

        let sessionFile = fixture.sessionsRoot
            .appendingPathComponent("rollout-2026-06-02T00-00-00-019e83ed-3f20-7000-9000-000000000002.jsonl")
        try #"{"timestamp":"\#(reasoningTimestamp)","type":"response_item","payload":{"type":"reasoning"}}"#
            .appending("\n")
            .write(to: sessionFile, atomically: true, encoding: .utf8)

        let monitor = CodexDesktopActivityMonitor(
            sessionsRootURL: fixture.sessionsRoot,
            replaysInitialHistory: true
        )
        _ = monitor.poll(now: now)

        let partialLine = #"{"timestamp":"\#(toolTimestamp)","type":"response_item","payload":{"type":"function_call","name":"apply_patch"}"#
        try FileHandle(forWritingTo: sessionFile).appendString(partialLine)
        XCTAssertEqual(monitor.poll(now: now.addingTimeInterval(1)), [])

        try FileHandle(forWritingTo: sessionFile).appendString("}\n")
        let completedActivities = monitor.poll(now: now.addingTimeInterval(2))

        XCTAssertEqual(completedActivities.count, 1)
        XCTAssertEqual(completedActivities.first?.signal, .working)
        XCTAssertEqual(completedActivities.first?.event, "DesktopToolCall:apply_patch")
    }

    func testCodexDesktopActivityMonitorDoesNotReplayHistoryByDefault() throws {
        let fixture = try makeTemporaryCodexSessionsRoot()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let now = Date()
        let oldTimestamp = isoTimestamp(now.addingTimeInterval(-10))
        let newTimestamp = isoTimestamp(now.addingTimeInterval(1))

        let sessionFile = fixture.sessionsRoot
            .appendingPathComponent("rollout-2026-06-02T00-00-00-019e83ed-3f20-7000-9000-000000000003.jsonl")
        try #"{"timestamp":"\#(oldTimestamp)","type":"response_item","payload":{"type":"reasoning"}}"#
            .appending("\n")
            .write(to: sessionFile, atomically: true, encoding: .utf8)

        let monitor = CodexDesktopActivityMonitor(sessionsRootURL: fixture.sessionsRoot)
        XCTAssert(monitor.poll(now: now).isEmpty)

        try FileHandle(forWritingTo: sessionFile)
            .appendString(#"{"timestamp":"\#(newTimestamp)","type":"response_item","payload":{"type":"function_call","name":"exec_command"}}"# + "\n")
        let activities = monitor.poll(now: now.addingTimeInterval(2))

        XCTAssertEqual(activities.map(\.signal), [.working])
        XCTAssertEqual(activities.map(\.event), ["DesktopToolCall:exec_command"])
    }

    func testCodexDesktopActivityMonitorPrimesCompletionStateWithoutReplayingHistory() throws {
        let fixture = try makeTemporaryCodexSessionsRoot()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let now = Date(timeIntervalSince1970: 1_000)
        let sessionID = "019e92c4-d204-7ce2-b7c2-63b01e7789b9"
        let sessionFile = fixture.sessionsRoot
            .appendingPathComponent("rollout-2026-06-05T01-13-52-\(sessionID).jsonl")
        let metaTimestamp = isoTimestamp(now.addingTimeInterval(-4))
        let completeTimestamp = isoTimestamp(now.addingTimeInterval(-3))
        try [
            #"{"timestamp":"\#(metaTimestamp)","type":"session_meta","payload":{"id":"\#(sessionID)","originator":"codex-tui","source":"cli"}}"#,
            #"{"timestamp":"\#(completeTimestamp)","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1"}}"#
        ].joined(separator: "\n")
            .appending("\n")
            .write(to: sessionFile, atomically: true, encoding: .utf8)

        let monitor = CodexDesktopActivityMonitor(sessionsRootURL: fixture.sessionsRoot)
        XCTAssertEqual(monitor.poll(now: now), [])

        let staleThinkingTimestamp = isoTimestamp(now.addingTimeInterval(1))
        try FileHandle(forWritingTo: sessionFile).appendString(
            #"{"timestamp":"\#(staleThinkingTimestamp)","type":"response_item","payload":{"type":"reasoning"}}"# + "\n"
        )

        XCTAssertEqual(monitor.poll(now: now.addingTimeInterval(2)), [])

        let newTurnTimestamp = isoTimestamp(now.addingTimeInterval(3))
        try FileHandle(forWritingTo: sessionFile).appendString(
            #"{"timestamp":"\#(newTurnTimestamp)","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-2"}}"# + "\n"
        )
        let newTurnActivities = monitor.poll(now: now.addingTimeInterval(4))

        XCTAssertEqual(newTurnActivities.map(\.signal), [.thinking])
        XCTAssertEqual(newTurnActivities.map(\.event), ["DesktopTaskStarted"])
        XCTAssertEqual(newTurnActivities.map(\.agent), ["codex-cli"])
    }

    func testCodexDesktopActivityMonitorDoesNotReviveCompletedSessionWithHeartbeat() throws {
        let fixture = try makeTemporaryCodexSessionsRoot()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let now = Date(timeIntervalSince1970: 1_000)
        let sessionFile = fixture.sessionsRoot
            .appendingPathComponent("rollout-2026-06-02T00-00-00-019e83ed-3f20-7000-9000-000000000004.jsonl")
        let completedTimestamp = isoTimestamp(now)
        try #"{"timestamp":"\#(completedTimestamp)","type":"event_msg","payload":{"type":"task_complete"}}"#
            .appending("\n")
            .write(to: sessionFile, atomically: true, encoding: .utf8)

        let monitor = CodexDesktopActivityMonitor(
            sessionsRootURL: fixture.sessionsRoot,
            replaysInitialHistory: true
        )
        let completedActivities = monitor.poll(now: now)

        XCTAssertEqual(completedActivities.map(\.signal), [.done])
        XCTAssertEqual(completedActivities.map(\.event), ["DesktopTaskComplete"])

        let heartbeatTimestamp = isoTimestamp(now.addingTimeInterval(2))
        try FileHandle(forWritingTo: sessionFile).appendString(
            #"{"timestamp":"\#(heartbeatTimestamp)","type":"event_msg","payload":{"type":"token_count"}}"# + "\n"
        )
        try FileHandle(forWritingTo: sessionFile).appendString(
            #"{"timestamp":"\#(heartbeatTimestamp)","type":"response_item","payload":{"type":"reasoning"}}"# + "\n"
        )

        XCTAssertEqual(monitor.poll(now: now.addingTimeInterval(3)), [])

        let newTurnTimestamp = isoTimestamp(now.addingTimeInterval(4))
        try FileHandle(forWritingTo: sessionFile).appendString(
            #"{"timestamp":"\#(newTurnTimestamp)","type":"event_msg","payload":{"type":"task_started"}}"# + "\n"
        )
        let newTurnActivities = monitor.poll(now: now.addingTimeInterval(5))

        XCTAssertEqual(newTurnActivities.map(\.signal), [.thinking])
        XCTAssertEqual(newTurnActivities.map(\.event), ["DesktopTaskStarted"])
    }

    func testCodexDesktopSessionParserIgnoresUserMessagesAndStartsNewTasks() {
        let userLine = """
        {"timestamp":"2026-05-29T02:18:00.000Z","type":"response_item","payload":{"type":"message","role":"user"}}
        """
        let startedLine = """
        {"timestamp":"2026-05-29T02:18:01.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-2"}}
        """
        let abortedLine = """
        {"timestamp":"2026-05-29T02:18:02.000Z","type":"event_msg","payload":{"type":"turn_aborted","turn_id":"turn-2"}}
        """

        XCTAssertNil(
            CodexDesktopSessionParser.activity(
                from: userLine,
                defaultSessionID: "codex-desktop:thread"
            )
        )

        let startedActivity = CodexDesktopSessionParser.activity(
            from: startedLine,
            defaultSessionID: "codex-desktop:thread"
        )
        XCTAssert(startedActivity?.signal == .thinking)
        XCTAssert(startedActivity?.event == "DesktopTaskStarted")

        let abortedActivity = CodexDesktopSessionParser.activity(
            from: abortedLine,
            defaultSessionID: "codex-desktop:thread"
        )
        XCTAssert(abortedActivity?.signal == .done)
        XCTAssert(abortedActivity?.event == "DesktopTurnAborted")
    }

    func testDisplayStateMappingMatchesV2Language() {
        XCTAssert(AgentSignal.idle.displayState == .ready)
        XCTAssert(AgentSignal.thinking.displayState == .active)
        XCTAssert(AgentSignal.working.displayState == .active)
        XCTAssert(AgentSignal.toolDone.displayState == .active)
        XCTAssert(AgentSignal.subagentStart.displayState == .active)
        XCTAssert(AgentSignal.done.displayState == .completed)
        XCTAssert(AgentSignal.attention.displayState == .needsReview)
        XCTAssert(AgentSignal.notification.displayState == .needsReview)
        XCTAssert(AgentSignal.permission.displayState == .permission)
        XCTAssert(AgentSignal.permissionRequest.displayState == .permission)
        XCTAssert(AgentSignal.blocked.displayState == .blocked)
        XCTAssert(AgentSignal.failure.displayState == .blocked)
        XCTAssert(AgentSignal.maxTokens.displayState == .blocked)
        XCTAssert(AgentSignal.stale.displayState == .stale)
        XCTAssert(AgentSignal.off.displayState == .paused)
    }

    func testAggregateKeepsPermissionAboveActiveAndReviewStates() {
        let now = Date()
        let document = SignalStateDocument(
            sessions: [
                "worker": SessionRecord(agent: "codex", signal: .working, updatedAt: now),
                "done": SessionRecord(agent: "claude-code", signal: .done, updatedAt: now),
                "permission": SessionRecord(agent: "codex", signal: .permission, updatedAt: now)
            ]
        )

        XCTAssert(document.aggregateSignal() == .permission)
    }

    func testBlockedWinsOverPermission() {
        let now = Date()
        let document = SignalStateDocument(
            sessions: [
                "permission": SessionRecord(agent: "codex", signal: .permission, updatedAt: now),
                "blocked": SessionRecord(agent: "claude-code", signal: .blocked, updatedAt: now)
            ]
        )

        XCTAssert(document.aggregateSignal() == .blocked)
    }

    func testV2AggregatePriorityCoversPausedStaleActiveAndCompleted() {
        let now = Date()

        XCTAssert(
            SignalStateDocument(
                sessions: [
                    "paused": SessionRecord(signal: .off, updatedAt: now),
                    "active": SessionRecord(signal: .working, updatedAt: now)
                ]
            ).aggregateSignal() == .off
        )
        XCTAssert(
            SignalStateDocument(
                aggregate: .off,
                sessions: [
                    "active": SessionRecord(signal: .working, updatedAt: now)
                ]
            ).aggregateSignal() == .working
        )
        XCTAssert(
            SignalStateDocument(
                aggregate: .stale,
                sessions: [
                    "active": SessionRecord(signal: .working, updatedAt: now)
                ]
            ).aggregateSignal() == .working
        )
        XCTAssert(
            SignalStateDocument(
                sessions: [
                    "completed": SessionRecord(signal: .done, updatedAt: now),
                    "active": SessionRecord(signal: .working, updatedAt: now)
                ]
            ).aggregateSignal() == .working
        )
        XCTAssert(
            SignalStateDocument(
                sessions: [
                    "completed": SessionRecord(signal: .done, updatedAt: now),
                    "ready": SessionRecord(signal: .idle, updatedAt: now)
                ]
            ).aggregateSignal() == .done
        )
        XCTAssert(
            SignalStateDocument(
                sessions: [
                    "stale": SessionRecord(signal: .stale, updatedAt: now),
                    "active": SessionRecord(signal: .working, updatedAt: now)
                ]
            ).aggregateSignal() == .stale
        )
        XCTAssert(
            SignalStateDocument(
                sessions: [
                    "stale": SessionRecord(signal: .stale, updatedAt: now),
                    "review": SessionRecord(signal: .attention, updatedAt: now)
                ]
            ).aggregateSignal() == .attention
        )
    }

    func testTurnEndDoesNotClearPermissionAlert() throws {
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        _ = try fixture.store.applySessionSignal(
            .permission,
            sessionID: "codex-main",
            agent: "codex",
            lastEvent: "PermissionRequest"
        )
        let snapshot = try fixture.store.applySessionSignal(
            .turnEnd,
            sessionID: "codex-main",
            agent: "codex",
            lastEvent: "Stop"
        )

        XCTAssert(snapshot.aggregate == .permission)
        XCTAssert(snapshot.sessions.map(\.sessionID) == ["codex-main"])
    }

    func testSuccessfulStopCompletesActiveSessionWithoutClearingAlerts() throws {
        let activeFixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: activeFixture.directory) }

        _ = try activeFixture.store.applySessionSignal(
            .working,
            sessionID: "codex-main",
            agent: "codex",
            lastEvent: "PreToolUse"
        )
        let completedSnapshot = try activeFixture.store.applySessionSignal(
            .done,
            sessionID: "codex-main",
            agent: "codex",
            lastEvent: "Stop"
        )

        XCTAssert(completedSnapshot.aggregate == .done)
        XCTAssert(completedSnapshot.sessions.first?.signal == .done)

        let replaySnapshot = try activeFixture.store.applySessionSignal(
            .thinking,
            sessionID: "codex-main",
            agent: "codex",
            lastEvent: "DesktopActivityHeartbeat",
            updatedAt: Date().addingTimeInterval(1)
        )

        XCTAssert(replaySnapshot.aggregate == .done)
        XCTAssert(replaySnapshot.sessions.first?.signal == .done)

        let alertFixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: alertFixture.directory) }

        _ = try alertFixture.store.applySessionSignal(
            .permission,
            sessionID: "codex-main",
            agent: "codex",
            lastEvent: "PermissionRequest"
        )
        let alertSnapshot = try alertFixture.store.applySessionSignal(
            .done,
            sessionID: "codex-main",
            agent: "codex",
            lastEvent: "Stop"
        )

        XCTAssert(alertSnapshot.aggregate == .permission)
        XCTAssert(alertSnapshot.sessions.first?.signal == .permission)
        XCTAssert(alertSnapshot.recentEvents.first?.signal == .done)
    }

    func testSessionEndPreservesCompletedAndAlertSessions() throws {
        let completedFixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: completedFixture.directory) }

        _ = try completedFixture.store.applySessionSignal(.done, sessionID: "codex-main")
        let completedSnapshot = try completedFixture.store.applySessionSignal(
            .sessionEnd,
            sessionID: "codex-main",
            lastEvent: "SessionEnd"
        )

        XCTAssert(completedSnapshot.aggregate == .done)
        XCTAssert(completedSnapshot.sessions.first?.signal == .done)
        XCTAssert(completedSnapshot.recentEvents.first?.signal == .sessionEnd)

        let alertFixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: alertFixture.directory) }

        _ = try alertFixture.store.applySessionSignal(.blocked, sessionID: "codex-main")
        let alertSnapshot = try alertFixture.store.applySessionSignal(
            .sessionEnd,
            sessionID: "codex-main",
            lastEvent: "SessionEnd"
        )

        XCTAssert(alertSnapshot.aggregate == .blocked)
        XCTAssert(alertSnapshot.sessions.first?.signal == .blocked)
        XCTAssert(alertSnapshot.recentEvents.first?.signal == .sessionEnd)
    }

    func testSessionEndDoesNotClearPausedAggregate() throws {
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        _ = try fixture.store.applySessionSignal(.off, sessionID: "manual", agent: "manual")
        let snapshot = try fixture.store.applySessionSignal(
            .sessionEnd,
            sessionID: "codex-main",
            agent: "codex",
            lastEvent: "SessionEnd"
        )

        XCTAssertEqual(snapshot.aggregate, .off)
        XCTAssert(snapshot.sessions.isEmpty)
    }

    func testManualSignalsParticipateInSessionAggregation() throws {
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        _ = try fixture.store.applySessionSignal(
            .permission,
            sessionID: "codex-main",
            agent: "codex",
            lastEvent: "PermissionRequest"
        )
        let snapshot = try fixture.store.setManualSignal(.working)

        XCTAssert(snapshot.aggregate == .permission)
        XCTAssert(snapshot.sessions.map(\.sessionID) == ["codex-main", "manual"])
        XCTAssert(snapshot.sessions.first { $0.sessionID == "manual" }?.signal == .working)
        XCTAssert(snapshot.sessions.first { $0.sessionID == "manual" }?.agent == "manual")
        XCTAssert(snapshot.sessions.first { $0.sessionID == "manual" }?.lastEvent == "ManualSet")
    }

    func testManualIdleStillClearsSessions() throws {
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        _ = try fixture.store.applySessionSignal(.working, sessionID: "worker")
        let snapshot = try fixture.store.setManualSignal(.idle)

        XCTAssert(snapshot.aggregate == .idle)
        XCTAssert(snapshot.sessions.isEmpty)
        XCTAssert(snapshot.recentEvents.first?.event == "ManualSet")
    }

    func testNonPausedSignalsResumeFromPausedAggregate() throws {
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        _ = try fixture.store.applySessionSignal(.off, sessionID: "manual")
        let snapshot = try fixture.store.applySessionSignal(
            .working,
            sessionID: "worker",
            agent: "codex",
            lastEvent: "PreToolUse"
        )

        XCTAssert(snapshot.aggregate == .working)
        XCTAssert(snapshot.sessions.map(\.sessionID) == ["worker"])
    }

    func testNonStaleSignalsResumeFromStaleAggregate() throws {
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        try FileManager.default.createDirectory(
            at: fixture.store.stateFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let staleJSON = """
        {
          "schema_version": 1,
          "aggregate": "stale",
          "updated_at": "2026-05-28T00:00:00Z",
          "sessions": {},
          "events": []
        }
        """
        try staleJSON.write(to: fixture.store.stateFileURL, atomically: true, encoding: .utf8)

        let snapshot = try fixture.store.applySessionSignal(
            .working,
            sessionID: "worker",
            agent: "codex",
            lastEvent: "PreToolUse"
        )

        XCTAssert(snapshot.aggregate == .working)
        XCTAssert(snapshot.sessions.map(\.sessionID) == ["worker"])
    }

    func testEventLimitKeepsNewestEvents() throws {
        let fixture = try makeTemporaryStore(eventLimit: 2)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        _ = try fixture.store.applySessionSignal(.working, sessionID: "one", lastEvent: "one")
        _ = try fixture.store.applySessionSignal(.working, sessionID: "two", lastEvent: "two")
        let snapshot = try fixture.store.applySessionSignal(.working, sessionID: "three", lastEvent: "three")

        XCTAssert(snapshot.recentEvents.map(\.event) == ["three", "two"])
    }

    func testDefaultEventLimitSupportsFiftyRecentEvents() {
        XCTAssertEqual(SignalStateStore.defaultEventLimit(environment: [:]), 50)
        XCTAssertEqual(
            SignalStateStore.defaultEventLimit(environment: ["AGENT_SIGNAL_LIGHT_EVENT_LIMIT": "12"]),
            12
        )
    }

    func testApplySessionSignalPreservesProvidedEventTimestamp() throws {
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let eventDate = Date(timeIntervalSince1970: 1_780_358_402)

        let snapshot = try fixture.store.applySessionSignal(
            .working,
            sessionID: "codex-main",
            agent: "codex",
            lastEvent: "DesktopToolCall:exec_command",
            updatedAt: eventDate
        )

        XCTAssertEqual(snapshot.sessions.first?.updatedAt, eventDate)
        XCTAssertEqual(snapshot.recentEvents.first?.updatedAt, eventDate)
        XCTAssertEqual(snapshot.updatedAt, eventDate)
    }

    func testApplySessionQuotaPersistsWithLaterSessionSignals() throws {
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let quotaDate = Date(timeIntervalSince1970: 1_780_358_402)
        let signalDate = quotaDate.addingTimeInterval(5)
        let quota = AgentQuotaStatus(
            remainingPercent: 23.5,
            usedPercent: 76.5,
            limitName: "GPT-5.3-Codex-Spark",
            windowMinutes: 300,
            resetsAt: quotaDate.addingTimeInterval(1_800),
            updatedAt: quotaDate
        )

        _ = try fixture.store.applySessionQuota(
            quota,
            sessionID: "codex-desktop:thread",
            agent: "codex-desktop",
            updatedAt: quotaDate
        )
        let snapshot = try fixture.store.applySessionSignal(
            .working,
            sessionID: "codex-desktop:thread",
            agent: "codex-desktop",
            lastEvent: "DesktopToolCall:exec_command",
            updatedAt: signalDate
        )

        XCTAssertEqual(snapshot.aggregate, .working)
        XCTAssertEqual(snapshot.sessions.first?.quota, quota)
        XCTAssertEqual(snapshot.sessions.first?.updatedAt, signalDate)
        XCTAssertEqual(snapshot.recentEvents.first?.event, "DesktopToolCall:exec_command")
    }

    func testApplySessionSignalIgnoresOlderEventsForSameSession() throws {
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let newerDate = Date(timeIntervalSince1970: 1_780_358_420)
        let olderDate = Date(timeIntervalSince1970: 1_780_358_400)

        _ = try fixture.store.applySessionSignal(
            .permission,
            sessionID: "codex-main",
            agent: "codex",
            lastEvent: "PermissionRequest",
            updatedAt: newerDate
        )
        let snapshot = try fixture.store.applySessionSignal(
            .working,
            sessionID: "codex-main",
            agent: "codex",
            lastEvent: "PreToolUse",
            updatedAt: olderDate
        )

        XCTAssertEqual(snapshot.aggregate, .permission)
        XCTAssertEqual(snapshot.sessions.first?.signal, .permission)
        XCTAssertEqual(snapshot.sessions.first?.updatedAt, newerDate)
        XCTAssertEqual(snapshot.recentEvents.map(\.event), ["PermissionRequest"])
    }

    func testDuplicateRecentEventsAreCollapsedBeforeCapping() throws {
        let fixture = try makeTemporaryStore(eventLimit: 4)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        _ = try fixture.store.applySessionSignal(.working, sessionID: "codex-main", agent: "codex", lastEvent: "PreToolUse")
        _ = try fixture.store.applySessionSignal(.working, sessionID: "codex-main", agent: "codex", lastEvent: "PreToolUse")
        _ = try fixture.store.applySessionSignal(.working, sessionID: "codex-main", agent: "codex", lastEvent: "PreToolUse")
        _ = try fixture.store.applySessionSignal(.toolDone, sessionID: "codex-main", agent: "codex", lastEvent: "PostToolUse")
        let snapshot = try fixture.store.applySessionSignal(.done, sessionID: "codex-main", agent: "codex", lastEvent: "Stop")

        XCTAssert(snapshot.recentEvents.map(\.event) == ["Stop", "PostToolUse", "PreToolUse"])
    }

    func testCodexHookMappingCoversCoreEventsAndFailures() {
        XCTAssert(CodexHookAdapter.chooseSignal(eventName: "PreToolUse", payload: [:]) == .working)
        XCTAssert(CodexHookAdapter.chooseSignal(eventName: "Stop", payload: [:]) == .done)
        XCTAssert(CodexHookAdapter.chooseSignal(eventName: " pre_tool_use ", payload: [:]) == .working)
        XCTAssert(CodexHookAdapter.chooseSignal(eventName: "permission-request", payload: [:]) == .permissionRequest)
        XCTAssert(
            CodexHookAdapter.chooseSignal(
                eventName: nil,
                payload: ["hookEventName": "post tool use"]
            ) == .toolDone
        )
        XCTAssert(
            CodexHookAdapter.chooseSignal(
                eventName: "PreToolUse",
                payload: ["signal": "attention"]
            ) == .attention
        )
        XCTAssert(
            CodexHookAdapter.chooseSignal(
                eventName: "PostToolUse",
                payload: ["exitStatus": 1]
            ).displayState == .blocked
        )
        XCTAssert(
            CodexHookAdapter.chooseSignal(
                eventName: nil,
                payload: ["Status": "failed"]
            ).displayState == .blocked
        )
    }

    func testCodexSessionKeyUsesNestedPayloadBeforeEnvironment() {
        let payload: [String: Any] = [
            "tool": [
                "context": [
                    "threadId": "nested-thread"
                ]
            ]
        ]

        XCTAssert(
            CodexHookAdapter.sessionKey(
                payload: payload,
                environment: ["CODEX_SESSION_ID": "env-session"]
            ) == "nested-thread"
        )
        XCTAssert(
            CodexHookAdapter.sessionKey(
                payload: ["sessionId": "camel-session"],
                environment: ["CODEX_SESSION_ID": "env-session"]
            ) == "camel-session"
        )
    }

    func testHookAdaptersIgnoreToolPayloadMetadataLookalikes() {
        let payload: [String: Any] = [
            "toolInput": [
                "sessionId": "user-supplied-session",
                "source": "xcode",
                "error": "example text from a tool argument"
            ]
        ]

        XCTAssertEqual(
            CodexHookAdapter.sessionKey(
                payload: payload,
                environment: ["CODEX_SESSION_ID": "real-session"]
            ),
            "real-session"
        )
        XCTAssertEqual(
            CodexHookAdapter.agentName(
                payload: payload,
                environment: ["TERM_PROGRAM": "Apple_Terminal"]
            ),
            "codex-cli"
        )
        XCTAssertEqual(
            CodexHookAdapter.chooseSignal(eventName: "PreToolUse", payload: payload),
            .working
        )
    }

    func testHookAdaptersStillReadTrustedNestedMetadata() {
        let payload: [String: Any] = [
            "payload": [
                "metadata": [
                    "sessionId": "trusted-session",
                    "source": "VS Code"
                ],
                "result": [
                    "error": true
                ]
            ]
        ]

        XCTAssertEqual(
            CodexHookAdapter.sessionKey(payload: payload, environment: [:]),
            "trusted-session"
        )
        XCTAssertEqual(
            CodexHookAdapter.agentName(payload: payload, environment: [:]),
            "codex-vscode"
        )
        XCTAssertEqual(
            CodexHookAdapter.chooseSignal(eventName: "PostToolUse", payload: payload),
            .blocked
        )
    }

    func testCodexHookAgentNameRecognizesJetBrainsTerminalEnvironment() {
        XCTAssertEqual(
            CodexHookAdapter.agentName(
                payload: [:],
                environment: ["TERMINAL_EMULATOR": "JetBrains-JediTerm"]
            ),
            "codex-jetbrains"
        )
    }

    func testHookSessionKeysAcceptNumericPayloadValues() {
        XCTAssertEqual(
            CodexHookAdapter.sessionKey(payload: ["session_id": 12_345], environment: [:]),
            "12345"
        )
        XCTAssertEqual(
            ClaudeHookAdapter.sessionKey(payload: ["conversation_id": 67_890], environment: [:]),
            "67890"
        )
        XCTAssertEqual(
            GenericHookAdapter.sessionKey(payload: ["run_id": 42], environment: [:], agent: "local"),
            "42"
        )
    }

    func testClaudeHookMappingCoversAttentionAndStopFailures() {
        XCTAssert(ClaudeHookAdapter.chooseSignal(eventName: "UserPromptExpansion", payload: [:]) == .thinking)
        XCTAssert(ClaudeHookAdapter.chooseSignal(eventName: "Notification", payload: [:]).displayState == .needsReview)
        XCTAssert(ClaudeHookAdapter.chooseSignal(eventName: "Stop", payload: [:]) == .done)
        XCTAssert(ClaudeHookAdapter.chooseSignal(eventName: "StopFailure", payload: [:]) == .blocked)
        XCTAssert(ClaudeHookAdapter.chooseSignal(eventName: "PermissionDenied", payload: [:]) == .blocked)
        XCTAssert(ClaudeHookAdapter.chooseSignal(eventName: "TaskCreated", payload: [:]) == .subagentStart)
        XCTAssert(ClaudeHookAdapter.chooseSignal(eventName: "TaskCompleted", payload: [:]) == .subagentStop)
        XCTAssert(ClaudeHookAdapter.chooseSignal(eventName: "PostToolBatch", payload: [:]) == .toolDone)
        XCTAssert(ClaudeHookAdapter.chooseSignal(eventName: "PostCompact", payload: [:]) == .toolDone)
        XCTAssert(ClaudeHookAdapter.chooseSignal(eventName: "WorktreeCreate", payload: [:]) == .working)
        XCTAssert(ClaudeHookAdapter.chooseSignal(eventName: "WorktreeRemove", payload: [:]).displayState == .needsReview)
        XCTAssert(ClaudeHookAdapter.chooseSignal(eventName: "post_tool_use_failure", payload: [:]) == .blocked)
        XCTAssert(
            ClaudeHookAdapter.chooseSignal(
                eventName: nil,
                payload: ["event": "subagent stop"]
            ) == .subagentStop
        )
        XCTAssert(
            ClaudeHookAdapter.chooseSignal(
                eventName: " stop ",
                payload: ["stopReason": " max-tokens "]
            ) == .maxTokens
        )
        XCTAssert(
            ClaudeHookAdapter.chooseSignal(
                eventName: "Stop",
                payload: ["stopReason": "max_tokens"]
            ).displayState == .blocked
        )
        XCTAssert(
            ClaudeHookAdapter.chooseSignal(
                eventName: "Stop",
                payload: ["stopReason": " tool error "]
            ) == .error
        )
        XCTAssert(
            ClaudeHookAdapter.chooseSignal(
                eventName: "PreToolUse",
                payload: ["lampSignal": "permission"]
            ) == .permission
        )
        XCTAssert(
            ClaudeHookAdapter.chooseSignal(
                eventName: "PostToolUse",
                payload: ["exitStatus": 1]
            ).displayState == .blocked
        )
        XCTAssert(
            ClaudeHookAdapter.chooseSignal(
                eventName: nil,
                payload: ["Status": "failed"]
            ).displayState == .blocked
        )
        XCTAssert(
            ClaudeHookAdapter.sessionKey(
                payload: ["sessionId": "claude-camel"],
                environment: ["CLAUDE_SESSION_ID": "env-session"]
            ) == "claude-camel"
        )
        XCTAssert(
            ClaudeHookAdapter.eventName(payload: ["hookEventName": "PostToolBatch"]) == "PostToolBatch"
        )
        XCTAssert(
            ClaudeHookAdapter.displayEventName(
                eventName: "PreToolUse",
                payload: ["toolName": "Bash"]
            ) == "PreToolUse:Bash"
        )
        XCTAssert(
            ClaudeHookAdapter.sessionKey(
                payload: ["transcriptPath": "/tmp/claude/transcript-1.jsonl"],
                environment: [:]
            ) == "transcript:transcript-1.jsonl"
        )
    }

    func testSharedLampAnimationCoversIdleAndOff() {
        XCTAssert(SignalLampAnimation.isLit(.green, signal: .idle, tick: 0))
        XCTAssert(!SignalLampAnimation.isLit(.yellow, signal: .idle, tick: 0))
        XCTAssert(!SignalLampAnimation.isLit(.red, signal: .idle, tick: 0))
        XCTAssert(!SignalLampAnimation.isLit(.green, signal: .off, tick: 0))
        XCTAssert(SignalLampAnimation.isLit(.red, signal: .off, tick: 0, allLightsOn: true))
        XCTAssert(SignalLampAnimation.isLit(.yellow, signal: .off, tick: 0, allLightsOn: true))
        XCTAssert(SignalLampAnimation.isLit(.green, signal: .off, tick: 0, allLightsOn: true))
    }

    func testSharedLampAnimationKeepsActiveGreenOnly() {
        XCTAssert(SignalLampAnimation.intensity(.green, signal: .working, tick: 0) == 1)
        XCTAssert(SignalLampAnimation.intensity(.green, signal: .working, tick: 3) == 0)
        XCTAssert(!SignalLampAnimation.isLit(.yellow, signal: .working, tick: 0))
        XCTAssert(!SignalLampAnimation.isLit(.red, signal: .working, tick: 0))

        XCTAssert(SignalLampAnimation.intensity(.green, signal: .thinking, tick: 0) == 1)
        XCTAssert(SignalLampAnimation.intensity(.green, signal: .thinking, tick: 1) == 0)
        XCTAssert(!SignalLampAnimation.isLit(.yellow, signal: .thinking, tick: 0))
        XCTAssert(!SignalLampAnimation.isLit(.red, signal: .thinking, tick: 0))

        XCTAssert(SignalLampAnimation.intensity(.green, signal: .toolDone, tick: 0) == 1)
        XCTAssert(!SignalLampAnimation.isLit(.yellow, signal: .toolDone, tick: 4))
        XCTAssert(!SignalLampAnimation.isLit(.red, signal: .toolDone, tick: 4))
    }

    func testDefaultActiveAndCompletedAnimationsMatchProductDefaults() {
        XCTAssert(SignalLampAnimation.intensity(.green, signal: .thinking, tick: 0) == 1)
        XCTAssert(SignalLampAnimation.intensity(.green, signal: .thinking, tick: 1) == 0)
        XCTAssert(SignalLampAnimation.intensity(.green, signal: .working, tick: 0) == 1)
        XCTAssert(SignalLampAnimation.intensity(.green, signal: .working, tick: 3) == 0)
        XCTAssert(SignalLampAnimation.intensity(.green, signal: .done, tick: 0) == 1)
        XCTAssert(SignalLampAnimation.intensity(.green, signal: .done, tick: 3) == 1)
        XCTAssert(SignalLampAnimation.intensity(.yellow, signal: .done, tick: 0) == 0)
        XCTAssert(SignalLampAnimation.intensity(.red, signal: .done, tick: 0) == 0)
    }

    func testCustomLampAnimationCanCycleAndChangeDoneColor() {
        let trafficCycle = SignalEffectCustomization(activeEffect: .trafficCycle)
        XCTAssert(SignalLampAnimation.intensity(.red, signal: .working, tick: 0, customization: trafficCycle) == 1)
        XCTAssert(SignalLampAnimation.intensity(.yellow, signal: .working, tick: 0, customization: trafficCycle) == 0)
        XCTAssert(SignalLampAnimation.intensity(.yellow, signal: .working, tick: 4, customization: trafficCycle) == 1)
        XCTAssert(SignalLampAnimation.intensity(.red, signal: .working, tick: 4, customization: trafficCycle) == 0)
        XCTAssert(SignalLampAnimation.intensity(.green, signal: .working, tick: 8, customization: trafficCycle) == 1)
        XCTAssert(SignalLampAnimation.intensity(.yellow, signal: .working, tick: 8, customization: trafficCycle) == 0)
        XCTAssert(!SignalLampAnimation.isLit(.green, signal: .working, tick: 0, customization: trafficCycle))

        let greenSteady = SignalEffectCustomization(activeEffect: .greenSteady)
        XCTAssert(SignalLampAnimation.intensity(.green, signal: .working, tick: 3, customization: greenSteady) == 1)
        XCTAssert(!SignalLampAnimation.isLit(.yellow, signal: .working, tick: 3, customization: greenSteady))

        let greenSlowFlash = SignalEffectCustomization(activeEffect: .greenSlowFlash)
        XCTAssert(SignalLampAnimation.intensity(.green, signal: .working, tick: 0, customization: greenSlowFlash) == 1)
        XCTAssert(SignalLampAnimation.intensity(.green, signal: .working, tick: 3, customization: greenSlowFlash) == 0)

        let greenFastFlash = SignalEffectCustomization(activeEffect: .greenFastFlash)
        XCTAssert(SignalLampAnimation.intensity(.green, signal: .working, tick: 0, customization: greenFastFlash) == 1)
        XCTAssert(SignalLampAnimation.intensity(.green, signal: .working, tick: 1, customization: greenFastFlash) == 0)

        let thinkingBreathing = SignalEffectCustomization(thinkingEffect: .greenBreathing)
        XCTAssert(SignalLampAnimation.intensity(.green, signal: .thinking, tick: 0, customization: thinkingBreathing) < SignalLampAnimation.intensity(.green, signal: .thinking, tick: 5, customization: thinkingBreathing))

        let yellowDone = SignalEffectCustomization(completedEffect: .yellowSteady)
        XCTAssert(SignalLampAnimation.intensity(.yellow, signal: .done, tick: 0, customization: yellowDone) == 1)
        XCTAssert(!SignalLampAnimation.isLit(.green, signal: .done, tick: 0, customization: yellowDone))

        let allDone = SignalEffectCustomization(completedEffect: .allSteady)
        XCTAssert(SignalLampAnimation.intensity(.red, signal: .done, tick: 0, customization: allDone) == 1)
        XCTAssert(SignalLampAnimation.intensity(.yellow, signal: .done, tick: 0, customization: allDone) == 1)
        XCTAssert(SignalLampAnimation.intensity(.green, signal: .done, tick: 0, customization: allDone) == 1)

        let allFlash = SignalEffectCustomization(completedEffect: .allPulse)
        XCTAssert(SignalLampAnimation.intensity(.red, signal: .done, tick: 0, customization: allFlash) == 1)
        XCTAssert(SignalLampAnimation.intensity(.yellow, signal: .done, tick: 0, customization: allFlash) == 1)
        XCTAssert(SignalLampAnimation.intensity(.green, signal: .done, tick: 0, customization: allFlash) == 1)
        XCTAssert(SignalLampAnimation.intensity(.red, signal: .done, tick: 2, customization: allFlash) == 0)
        XCTAssert(SignalLampAnimation.intensity(.yellow, signal: .done, tick: 2, customization: allFlash) == 0)
        XCTAssert(SignalLampAnimation.intensity(.green, signal: .done, tick: 2, customization: allFlash) == 0)
    }

    func testMacOSVisualScaleStrengthsAreMeaningfullySeparated() {
        let breathing = SignalEffectCustomization(activeEffect: .greenBreathing)
        let baseScale = SignalLampAnimation.scale(.green, signal: .working, tick: 0, customization: breathing)
        let intensity = SignalLampAnimation.intensity(.green, signal: .working, tick: 0, customization: breathing)

        let standard = SignalVisualScale.lampScale(
            baseScale: baseScale,
            intensity: intensity,
            style: .macOS,
            macOSStrength: .standard
        )
        let pronounced = SignalVisualScale.lampScale(
            baseScale: baseScale,
            intensity: intensity,
            style: .macOS,
            macOSStrength: .pronounced
        )
        let maximum = SignalVisualScale.lampScale(
            baseScale: baseScale,
            intensity: intensity,
            style: .macOS,
            macOSStrength: .maximum
        )
        let maximumMid = SignalVisualScale.lampScale(
            baseScale: SignalLampAnimation.scale(.green, signal: .working, tick: 2, customization: breathing),
            intensity: SignalLampAnimation.intensity(.green, signal: .working, tick: 2, customization: breathing),
            style: .macOS,
            macOSStrength: .maximum
        )
        let maximumHigh = SignalVisualScale.lampScale(
            baseScale: SignalLampAnimation.scale(.green, signal: .working, tick: 4, customization: breathing),
            intensity: SignalLampAnimation.intensity(.green, signal: .working, tick: 4, customization: breathing),
            style: .macOS,
            macOSStrength: .maximum
        )

        XCTAssert(maximum < pronounced)
        XCTAssert(pronounced < standard)
        XCTAssert(maximum == baseScale)
        XCTAssert(maximumMid >= 0.74)
        XCTAssert(maximumMid <= 0.76)
        XCTAssert(maximumHigh >= 0.90)
        XCTAssert(maximumHigh <= 0.92)
        XCTAssert(standard - maximum >= 0.15)
        XCTAssert(
            SignalVisualScale.lampScale(
                baseScale: baseScale,
                intensity: intensity,
                style: .trafficLight,
                macOSStrength: .maximum
            ) == baseScale
        )
    }

    func testSharedLampAnimationUsesV2BlinkCadences() {
        XCTAssert(SignalLampAnimation.isLit(.green, signal: .done, tick: 0))
        XCTAssert(!SignalLampAnimation.isLit(.yellow, signal: .done, tick: 0))
        XCTAssert(!SignalLampAnimation.isLit(.red, signal: .done, tick: 0))

        XCTAssert(SignalLampAnimation.isLit(.yellow, signal: .attention, tick: 0))
        XCTAssert(!SignalLampAnimation.isLit(.yellow, signal: .attention, tick: 4))
        XCTAssert(SignalLampAnimation.scale(.yellow, signal: .attention, tick: 0) < SignalLampAnimation.scale(.yellow, signal: .attention, tick: 2))

        XCTAssert(SignalLampAnimation.isLit(.red, signal: .permission, tick: 0))
        XCTAssert(!SignalLampAnimation.isLit(.red, signal: .permission, tick: 4))

        XCTAssert(SignalLampAnimation.isLit(.red, signal: .blocked, tick: 0))
        XCTAssert(!SignalLampAnimation.isLit(.red, signal: .blocked, tick: 1))

        XCTAssert(SignalLampAnimation.intensity(.yellow, signal: .stale, tick: 0) > 0)
        XCTAssert(!SignalLampAnimation.isLit(.yellow, signal: .stale, tick: 4))
    }

    func testStaleIsProducedWhenStatusFileIsCorruptOrSessionExpires() throws {
        let corruptFixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: corruptFixture.directory) }

        try FileManager.default.createDirectory(
            at: corruptFixture.store.stateFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "{".write(to: corruptFixture.store.stateFileURL, atomically: true, encoding: .utf8)

        XCTAssert(corruptFixture.store.readSnapshot().aggregate == .stale)

        let ttlFixture = try makeTemporaryStore(sessionTTLSeconds: 0.01)
        defer { try? FileManager.default.removeItem(at: ttlFixture.directory) }
        let oldDate = Date(timeIntervalSince1970: 100)

        try writeDocument(
            SignalStateDocument(
                aggregate: .working,
                updatedAt: oldDate,
                sessions: ["worker": SessionRecord(signal: .working, updatedAt: oldDate)]
            ),
            in: ttlFixture.store
        )
        let snapshot = ttlFixture.store.readSnapshot()
        let storedDocument = try storedDocument(in: ttlFixture.store)

        XCTAssert(snapshot.aggregate == .stale)
        XCTAssert(snapshot.sessions.isEmpty)
        XCTAssert(storedDocument.aggregate == .stale)
        XCTAssert(storedDocument.sessions.isEmpty)
        XCTAssert((snapshot.updatedAt ?? .distantPast) > oldDate)
        XCTAssert((storedDocument.updatedAt ?? .distantPast) > oldDate)
    }

    func testStateStoreReadsFractionalSecondDatesFromExternalJSON() throws {
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let now = Date()
        let timestamp = isoTimestamp(now)
        let json = """
        {
          "schema_version": 1,
          "aggregate": "working",
          "updated_at": "\(timestamp)",
          "sessions": {
            "external": {
              "agent": "external",
              "signal": "working",
              "last_event": "ExternalWrite",
              "updated_at": "\(timestamp)"
            }
          },
          "events": [
            {
              "id": "external-event",
              "session_id": "external",
              "agent": "external",
              "signal": "working",
              "event": "ExternalWrite",
              "updated_at": "\(timestamp)"
            }
          ]
        }
        """

        try FileManager.default.createDirectory(
            at: fixture.store.stateFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try json.write(to: fixture.store.stateFileURL, atomically: true, encoding: .utf8)

        let snapshot = fixture.store.readSnapshot()

        XCTAssertEqual(snapshot.aggregate, .working)
        XCTAssertEqual(snapshot.sessions.first?.sessionID, "external")
        XCTAssertEqual(snapshot.sessions.first?.lastEvent, "ExternalWrite")
    }

    func testDefaultStateFileURLTrimsBlankEnvironmentValues() {
        let explicitFallback = SignalStateStore.defaultStateFileURL(
            environment: [
                "AGENT_SIGNAL_LIGHT_STATE_FILE": "   ",
                "AGENT_SIGNAL_LIGHT_STATE_DIR": "  /tmp/trimmed-agent-signal  "
            ]
        )
        XCTAssertEqual(explicitFallback.path, "/tmp/trimmed-agent-signal/status.json")

        let defaultFallback = SignalStateStore.defaultStateFileURL(
            environment: [
                "AGENT_SIGNAL_LIGHT_STATE_FILE": "\n\t",
                "AGENT_SIGNAL_LIGHT_STATE_DIR": "  ",
                "SIGNAL_LIGHT_STATE_DIR": "\n"
            ]
        )
        XCTAssertEqual(defaultFallback.path, "/tmp/agent-signal/status.json")
    }

    func testCompletedSessionExpiresBackToIdle() throws {
        let fixture = try makeTemporaryStore(completedTTLSeconds: 0.01)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let oldDate = Date(timeIntervalSince1970: 100)

        try writeDocument(
            SignalStateDocument(
                aggregate: .done,
                updatedAt: oldDate,
                sessions: ["worker": SessionRecord(signal: .done, updatedAt: oldDate)]
            ),
            in: fixture.store
        )
        let snapshot = fixture.store.readSnapshot()
        let storedDocument = try storedDocument(in: fixture.store)

        XCTAssert(snapshot.aggregate == .idle)
        XCTAssert(snapshot.sessions.isEmpty)
        XCTAssert(storedDocument.aggregate == .idle)
        XCTAssert(storedDocument.sessions.isEmpty)
        XCTAssert((snapshot.updatedAt ?? .distantPast) > oldDate)
        XCTAssert((storedDocument.updatedAt ?? .distantPast) > oldDate)
    }

    func testExpiredCompletedSessionIgnoresLateActiveReplay() throws {
        let fixture = try makeTemporaryStore(completedTTLSeconds: 0.01)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let completedDate = Date(timeIntervalSince1970: 100)
        let replayDate = Date(timeIntervalSince1970: 101)

        try writeDocument(
            SignalStateDocument(
                aggregate: .done,
                updatedAt: completedDate,
                sessions: [
                    "codex-desk": SessionRecord(
                        agent: "codex-desktop",
                        signal: .done,
                        lastEvent: "DesktopStop",
                        updatedAt: completedDate
                    )
                ]
            ),
            in: fixture.store
        )

        let snapshot = try fixture.store.applySessionSignal(
            .thinking,
            sessionID: "codex-desk",
            agent: "codex-desktop",
            lastEvent: "DesktopThinking",
            updatedAt: replayDate
        )

        XCTAssertEqual(snapshot.aggregate, .idle)
        XCTAssertTrue(snapshot.sessions.isEmpty)
    }

    func testToolDoneSessionExpiresBackToIdle() throws {
        let fixture = try makeTemporaryStore(completedTTLSeconds: 0.01)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let oldDate = Date(timeIntervalSince1970: 100)

        try writeDocument(
            SignalStateDocument(
                aggregate: .toolDone,
                updatedAt: oldDate,
                sessions: ["worker": SessionRecord(signal: .toolDone, updatedAt: oldDate)]
            ),
            in: fixture.store
        )
        let snapshot = fixture.store.readSnapshot()
        let storedDocument = try storedDocument(in: fixture.store)

        XCTAssert(snapshot.aggregate == .idle)
        XCTAssert(snapshot.sessions.isEmpty)
        XCTAssert(storedDocument.aggregate == .idle)
        XCTAssert(storedDocument.sessions.isEmpty)
    }

    func testGitHubReleaseUpdateCheckerComparesSemanticVersions() {
        XCTAssertEqual(GitHubReleaseUpdateChecker.displayVersion(from: "v1.1.0"), "1.1.0")
        XCTAssertEqual(GitHubReleaseUpdateChecker.compareVersions("1.1.1", "1.1.0"), .orderedDescending)
        XCTAssertEqual(GitHubReleaseUpdateChecker.compareVersions("v1.1.0", "1.1"), .orderedSame)
        XCTAssertEqual(GitHubReleaseUpdateChecker.compareVersions("1.0.9", "1.1.0"), .orderedAscending)
    }

    func testGitHubReleaseUpdateCheckerDecodesLatestRelease() throws {
        let data = Data(
            """
            {
              "tag_name": "v1.2.0",
              "html_url": "https://github.com/guan-ops/Agent-Signal-Bar/releases/tag/v1.2.0",
              "assets": [
                {
                  "name": "AgentSignalLight-local.dmg",
                  "browser_download_url": "https://github.com/guan-ops/Agent-Signal-Bar/releases/download/v1.2.0/AgentSignalLight-local.dmg"
                }
              ]
            }
            """.utf8
        )

        let release = try GitHubReleaseUpdateChecker.decodeLatestRelease(from: data)

        XCTAssertEqual(release.tagName, "v1.2.0")
        XCTAssertEqual(release.preferredDownloadURL?.lastPathComponent, "AgentSignalLight-local.dmg")
    }

    func testGitHubReleaseUpdateCheckerFallsBackToReleasePageWhenAPIRateLimited() async throws {
        let apiResponse = HTTPURLResponse(
            url: GitHubReleaseUpdateChecker.latestReleaseAPIURL,
            statusCode: 403,
            httpVersion: nil,
            headerFields: nil
        )!
        let releasePageURL = URL(string: "https://github.com/guan-ops/Agent-Signal-Bar/releases/tag/v1.2.0")!
        let pageResponse = HTTPURLResponse(
            url: releasePageURL,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        let checker = GitHubReleaseUpdateChecker(
            session: QueuedURLSession([
                .init(data: Data("rate limited".utf8), response: apiResponse),
                .init(data: Data("<html></html>".utf8), response: pageResponse)
            ])
        )

        let result = try await checker.check(currentVersion: "1.1.0")

        XCTAssertEqual(result.latestVersion, "1.2.0")
        XCTAssertEqual(result.releasePageURL, releasePageURL)
        XCTAssertNil(result.downloadURL)
        XCTAssertTrue(result.isUpdateAvailable)
    }

    func testActivityPresentationKeepsCodexEntrypointsSeparate() {
        let now = Date()
        let snapshot = SignalSnapshot(
            aggregate: .working,
            sessions: [
                SessionStatus(
                    sessionID: "codex-desktop:desktop-thread",
                    signal: .working,
                    updatedAt: now,
                    agent: "codex-desktop",
                    lastEvent: "DesktopToolCall:exec_command"
                ),
                SessionStatus(
                    sessionID: "codex-cli:terminal-session",
                    signal: .thinking,
                    updatedAt: now.addingTimeInterval(-1),
                    agent: "codex-cli",
                    lastEvent: "UserPromptSubmit"
                ),
                SessionStatus(
                    sessionID: "codex-ide:idea-session",
                    signal: .working,
                    updatedAt: now.addingTimeInterval(-2),
                    agent: "codex-ide",
                    lastEvent: "PreToolUse"
                )
            ],
            recentEvents: [],
            stateFileURL: URL(fileURLWithPath: "/tmp/agent-signal/status.json"),
            updatedAt: now
        )

        let visible = ActivityPresentation.visibleSessions(from: snapshot, now: now)

        XCTAssertEqual(Set(visible.map(ActivityPresentation.activitySourceKey(for:))), [
            "codex:desktop",
            "codex:terminal",
            "codex:ide:idea"
        ])
    }

    func testFloatingInfoSessionsFollowCurrentSessionsButExcludeIdleAndPaused() {
        let now = Date()
        let snapshot = SignalSnapshot(
            aggregate: .working,
            sessions: [
                SessionStatus(
                    sessionID: "platform-presence:codex-desktop",
                    signal: .idle,
                    updatedAt: now,
                    agent: "codex-desktop",
                    lastEvent: "PlatformPresence:Desktop"
                ),
                SessionStatus(
                    sessionID: "platform-presence:claude-desktop",
                    signal: .paused,
                    updatedAt: now,
                    agent: "claude-desktop",
                    lastEvent: "PlatformPresence:Desktop"
                ),
                SessionStatus(
                    sessionID: "codex-cli:active-thread",
                    signal: .working,
                    updatedAt: now,
                    agent: "codex-cli",
                    lastEvent: "PreToolUse"
                ),
                SessionStatus(
                    sessionID: "codex-vscode:review-thread",
                    signal: .notification,
                    updatedAt: now,
                    agent: "codex-vscode",
                    lastEvent: "Notification"
                )
            ],
            recentEvents: [],
            stateFileURL: URL(fileURLWithPath: "/tmp/agent-signal/status.json"),
            updatedAt: now
        )

        let currentSessions = ActivityPresentation.visibleSessions(
            from: snapshot,
            now: now,
            limit: ActivityPresentation.currentSessionLimit
        )
        let floatingSessions = ActivityPresentation.visibleRunningSessions(from: snapshot, now: now)

        XCTAssertTrue(currentSessions.contains { $0.sessionID == "platform-presence:codex-desktop" })
        XCTAssertTrue(currentSessions.contains { $0.sessionID == "platform-presence:claude-desktop" })
        XCTAssertEqual(Set(floatingSessions.map(\.sessionID)), [
            "codex-cli:active-thread",
            "codex-vscode:review-thread"
        ])
    }

    func testActivityPresentationRuntimeKindRecognizesIDEA() {
        let session = SessionStatus(
            sessionID: "codex-idea:project",
            signal: .working,
            updatedAt: Date(),
            agent: "JetBrains Codex",
            lastEvent: "PreToolUse"
        )

        guard case .ide = ActivityPresentation.runtimeKind(for: session) else {
            XCTFail("Expected JetBrains Codex sessions to be displayed as IDE activity.")
            return
        }

        XCTAssertEqual(ActivityPresentation.sourceDetail(for: session), "IDEA")
    }

    func testActivityPresentationPrefersNewerCompletedCLIOverOlderThinking() {
        let now = Date(timeIntervalSince1970: 1_000)
        let visible = ActivityPresentation.visibleSessions(
            from: [
                SessionStatus(
                    sessionID: "codex-cli:old-thread",
                    signal: .thinking,
                    updatedAt: now.addingTimeInterval(-60),
                    agent: "codex-cli",
                    lastEvent: "DesktopActivityHeartbeat"
                ),
                SessionStatus(
                    sessionID: "recent-activity:codex:terminal",
                    signal: .done,
                    updatedAt: now,
                    agent: "codex-cli",
                    lastEvent: "DesktopTaskComplete"
                )
            ],
            now: now
        )

        XCTAssertEqual(visible.count, 1)
        XCTAssertEqual(visible.first?.signal, .done)
        XCTAssertEqual(visible.first?.lastEvent, "DesktopTaskComplete")
    }

    func testActivityPresentationRecentEventsExcludeCurrentFallbackSourceEvent() {
        let now = Date(timeIntervalSince1970: 1_000)
        let current = SessionStatus(
            sessionID: "recent-activity:codex:terminal",
            signal: .done,
            updatedAt: now,
            agent: "codex-cli",
            lastEvent: "DesktopTaskComplete"
        )
        let snapshot = SignalSnapshot(
            aggregate: .done,
            sessions: [],
            recentEvents: [
                RecentSignalEvent(
                    id: "terminal-done",
                    sessionID: "codex-cli:original-session",
                    signal: .done,
                    updatedAt: now,
                    agent: "codex-cli",
                    event: "DesktopTaskComplete"
                ),
                RecentSignalEvent(
                    id: "desktop-done",
                    sessionID: "codex-desktop:session",
                    signal: .done,
                    updatedAt: now.addingTimeInterval(-1),
                    agent: "codex-desktop",
                    event: "DesktopTaskComplete"
                )
            ],
            stateFileURL: URL(fileURLWithPath: "/tmp/agent-signal/status.json"),
            updatedAt: now
        )

        let recent = ActivityPresentation.recentEvents(from: snapshot, excluding: [current])

        XCTAssertEqual(recent.map(\.id), ["desktop-done"])
    }

    func testActivityPresentationPrefersCompletedCLIOverPresenceAndOlderThinking() {
        let now = Date(timeIntervalSince1970: 1_000)
        let visible = ActivityPresentation.visibleSessions(
            from: [
                SessionStatus(
                    sessionID: "codex-cli:old-thread",
                    signal: .thinking,
                    updatedAt: now.addingTimeInterval(-60),
                    agent: "codex-cli",
                    lastEvent: "DesktopActivityHeartbeat"
                ),
                SessionStatus(
                    sessionID: "platform-presence:codex-cli",
                    signal: .idle,
                    updatedAt: now,
                    agent: "codex-cli",
                    lastEvent: "PlatformPresence:CLI"
                ),
                SessionStatus(
                    sessionID: "codex-cli:finished-thread",
                    signal: .done,
                    updatedAt: now.addingTimeInterval(-1),
                    agent: "codex-cli",
                    lastEvent: "DesktopTaskComplete"
                )
            ],
            now: now
        )

        XCTAssertEqual(visible.count, 1)
        XCTAssertEqual(visible.first?.signal, .done)
        XCTAssertEqual(visible.first?.lastEvent, "DesktopTaskComplete")
    }

    func testActivityPresentationLetsFreshPresenceReplaceStaleTerminalThinking() {
        let now = Date(timeIntervalSince1970: 1_000)
        let visible = ActivityPresentation.visibleSessions(
            from: [
                SessionStatus(
                    sessionID: "codex-cli:old-thread",
                    signal: .thinking,
                    updatedAt: now.addingTimeInterval(-60),
                    agent: "codex-cli",
                    lastEvent: "DesktopThinking"
                ),
                SessionStatus(
                    sessionID: "platform-presence:codex-cli",
                    signal: .idle,
                    updatedAt: now,
                    agent: "codex-cli",
                    lastEvent: "PlatformPresence:CLI"
                )
            ],
            now: now
        )

        XCTAssertEqual(visible.count, 1)
        XCTAssertEqual(visible.first?.sessionID, "platform-presence:codex-cli")
        XCTAssertEqual(visible.first?.signal, .idle)
    }

    @MainActor
    func testRecentDesktopActivityOverridesPresenceOnlySession() throws {
        let savedDefaults = clearSignalLightSelectionDefaults()
        defer { restoreSignalLightSelectionDefaults(savedDefaults) }
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let now = Date()

        try writeDocument(
            SignalStateDocument(
                aggregate: .idle,
                updatedAt: now,
                sessions: [
                    "platform-presence:codex-desktop": SessionRecord(
                        agent: "codex-desktop",
                        signal: .idle,
                        lastEvent: "PlatformPresence:Desktop",
                        updatedAt: now
                    )
                ],
                events: [
                    SignalEventRecord(
                        id: "desktop-tool-call",
                        sessionID: "codex-desktop:thread",
                        agent: "codex-desktop",
                        signal: .working,
                        event: "DesktopToolCall:exec_command",
                        updatedAt: now.addingTimeInterval(-3)
                    )
                ]
            ),
            in: fixture.store
        )

        let model = MenuBarStatusModel(store: fixture.store)
        model.setSignalLightAgentScopes([.codexDesktop])

        let visible = ActivityPresentation.visibleSessions(from: model.activitySnapshot, now: now, limit: nil)
        let desktopSession = try XCTUnwrap(
            visible.first { ActivityPresentation.activitySourceKey(for: $0) == "codex:desktop" }
        )

        XCTAssertEqual(desktopSession.signal, .working)
        XCTAssertEqual(desktopSession.lastEvent, "DesktopToolCall:exec_command")
        XCTAssertEqual(model.displaySnapshot.aggregate, .working)
    }

    @MainActor
    func testSignalLightAutomaticallyFollowsHighestPriorityActiveSource() throws {
        let savedDefaults = clearSignalLightSelectionDefaults()
        defer { restoreSignalLightSelectionDefaults(savedDefaults) }
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let now = Date()

        try writeDocument(
            SignalStateDocument(
                aggregate: .permission,
                updatedAt: now,
                sessions: [
                    "codex-desktop:thread": SessionRecord(
                        agent: "codex-desktop",
                        signal: .working,
                        lastEvent: "DesktopToolCall:exec_command",
                        updatedAt: now.addingTimeInterval(-2)
                    ),
                    "claude-code:thread": SessionRecord(
                        agent: "claude-code",
                        signal: .permission,
                        lastEvent: "PermissionRequest",
                        updatedAt: now.addingTimeInterval(-1)
                    )
                ]
            ),
            in: fixture.store
        )

        let model = MenuBarStatusModel(store: fixture.store)

        XCTAssertEqual(model.signalLightAgentSelectionMode, .following)
        XCTAssertEqual(model.displaySignalLightAgentScopes, [.claudeCode])
        XCTAssertEqual(model.displaySnapshot.aggregate, .permission)
        XCTAssertEqual(model.displaySnapshot.sessions.map(\.sessionID), ["claude-code:thread"])
    }

    @MainActor
    func testManualSignalLightSelectionAggregatesMultipleSelectedSourcesOnly() throws {
        let savedDefaults = clearSignalLightSelectionDefaults()
        defer { restoreSignalLightSelectionDefaults(savedDefaults) }
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let now = Date()

        try writeDocument(
            SignalStateDocument(
                aggregate: .blocked,
                updatedAt: now,
                sessions: [
                    "codex-desktop:thread": SessionRecord(
                        agent: "codex-desktop",
                        signal: .done,
                        lastEvent: "DesktopTaskComplete",
                        updatedAt: now.addingTimeInterval(-3)
                    ),
                    "codex-cli:thread": SessionRecord(
                        agent: "codex-cli",
                        signal: .working,
                        lastEvent: "DesktopToolCall:exec_command",
                        updatedAt: now.addingTimeInterval(-2)
                    ),
                    "claude-code:thread": SessionRecord(
                        agent: "claude-code",
                        signal: .blocked,
                        lastEvent: "Stop:Error",
                        updatedAt: now.addingTimeInterval(-1)
                    )
                ]
            ),
            in: fixture.store
        )

        let model = MenuBarStatusModel(store: fixture.store)
        model.setSignalLightAgentScopes([.codexDesktop, .codexCLI])

        XCTAssertEqual(model.signalLightAgentSelectionMode, .manual)
        XCTAssertEqual(model.displaySignalLightAgentScopes, [.codexDesktop, .codexCLI])
        XCTAssertEqual(model.displaySnapshot.aggregate, .working)
        XCTAssertEqual(
            Set(model.displaySnapshot.sessions.map(\.sessionID)),
            ["codex-desktop:thread", "codex-cli:thread"]
        )
    }

    @MainActor
    func testHiddenLocalScriptSelectionDoesNotDriveVisibleSignalLight() throws {
        let savedDefaults = clearSignalLightSelectionDefaults()
        defer { restoreSignalLightSelectionDefaults(savedDefaults) }
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let now = Date()

        try writeDocument(
            SignalStateDocument(
                aggregate: .working,
                updatedAt: now,
                sessions: [
                    "claude-code:thread": SessionRecord(
                        agent: "claude-code",
                        signal: .working,
                        lastEvent: "PreToolUse",
                        updatedAt: now
                    )
                ]
            ),
            in: fixture.store
        )

        let model = MenuBarStatusModel(store: fixture.store)
        model.setSignalLightAgentScopes([.localScript])

        XCTAssertEqual(model.signalLightAgentSelectionMode, .manual)
        XCTAssertEqual(model.displaySignalLightAgentScopes, [])
        XCTAssertEqual(model.displaySnapshot.aggregate, .idle)
        XCTAssertEqual(model.displaySnapshot.sessions, [])
        XCTAssertNil(model.signalLightAgentUnavailableHint)
    }

    @MainActor
    func testRecentPassiveThinkingDoesNotRemainFallbackSessionForFiveMinutes() {
        let now = Date(timeIntervalSince1970: 1_000)
        let freshThinking = RecentSignalEvent(
            id: "fresh-thinking",
            sessionID: "codex-cli:thread",
            signal: .thinking,
            updatedAt: now.addingTimeInterval(-30),
            agent: "codex-cli",
            event: "DesktopThinking"
        )
        let staleThinking = RecentSignalEvent(
            id: "stale-thinking",
            sessionID: "codex-cli:thread",
            signal: .thinking,
            updatedAt: now.addingTimeInterval(-60),
            agent: "codex-cli",
            event: "DesktopThinking"
        )
        let activeToolCall = RecentSignalEvent(
            id: "tool-call",
            sessionID: "codex-cli:thread",
            signal: .working,
            updatedAt: now.addingTimeInterval(-60),
            agent: "codex-cli",
            event: "DesktopToolCall:exec_command"
        )

        XCTAssertTrue(MenuBarStatusModel.shouldUseRecentEventAsFallbackSession(freshThinking, now: now))
        XCTAssertFalse(MenuBarStatusModel.shouldUseRecentEventAsFallbackSession(staleThinking, now: now))
        XCTAssertTrue(MenuBarStatusModel.shouldUseRecentEventAsFallbackSession(activeToolCall, now: now))

        let freshCompleted = RecentSignalEvent(
            id: "fresh-completed",
            sessionID: "codex-cli:thread",
            signal: .done,
            updatedAt: now.addingTimeInterval(-29),
            agent: "codex-cli",
            event: "DesktopTaskComplete"
        )
        let staleCompleted = RecentSignalEvent(
            id: "stale-completed",
            sessionID: "codex-cli:thread",
            signal: .done,
            updatedAt: now.addingTimeInterval(-31),
            agent: "codex-cli",
            event: "DesktopTaskComplete"
        )

        XCTAssertTrue(MenuBarStatusModel.shouldUseRecentEventAsFallbackSession(freshCompleted, now: now))
        XCTAssertFalse(MenuBarStatusModel.shouldUseRecentEventAsFallbackSession(staleCompleted, now: now))

        let manualIdleEvent = RecentSignalEvent(
            id: "manual-idle",
            sessionID: "manual",
            signal: .idle,
            updatedAt: now,
            agent: "manual",
            event: "ManualSet"
        )
        XCTAssertFalse(MenuBarStatusModel.shouldUseRecentEventAsFallbackSession(manualIdleEvent, now: now))
    }

    @MainActor
    func testRecentCompletedEventPreventsOlderActiveFallbackAcrossSourcesAfterDoneExpires() throws {
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let now = Date()
        let cases = [
            (
                id: "desktop",
                sessionID: "codex-desktop:finished-thread",
                agent: "codex-desktop",
                activeEvent: "DesktopTaskStarted",
                completedEvent: "DesktopTaskComplete"
            ),
            (
                id: "cli",
                sessionID: "codex-cli:finished-thread",
                agent: "codex-cli",
                activeEvent: "DesktopTaskStarted",
                completedEvent: "DesktopTaskComplete"
            ),
            (
                id: "vscode",
                sessionID: "codex-vscode:finished-thread",
                agent: "codex-vscode",
                activeEvent: "DesktopTaskStarted",
                completedEvent: "DesktopTaskComplete"
            ),
            (
                id: "xcode",
                sessionID: "codex-xcode:finished-thread",
                agent: "codex-xcode",
                activeEvent: "DesktopTaskStarted",
                completedEvent: "DesktopTaskComplete"
            ),
            (
                id: "idea",
                sessionID: "codex-idea:finished-thread",
                agent: "codex-idea",
                activeEvent: "DesktopTaskStarted",
                completedEvent: "DesktopTaskComplete"
            ),
            (
                id: "claude",
                sessionID: "claude-code:finished-thread",
                agent: "claude-code",
                activeEvent: "PreToolUse",
                completedEvent: "Stop"
            )
        ]
        let records = cases.flatMap { item in
            [
                SignalEventRecord(
                    id: "\(item.id)-started",
                    sessionID: item.sessionID,
                    agent: item.agent,
                    signal: .thinking,
                    event: item.activeEvent,
                    updatedAt: now.addingTimeInterval(-150)
                ),
                SignalEventRecord(
                    id: "\(item.id)-complete",
                    sessionID: item.sessionID,
                    agent: item.agent,
                    signal: .done,
                    event: item.completedEvent,
                    updatedAt: now.addingTimeInterval(-120)
                )
            ]
        }

        try writeDocument(
            SignalStateDocument(
                aggregate: .idle,
                updatedAt: now,
                sessions: [:],
                events: records
            ),
            in: fixture.store
        )

        let model = MenuBarStatusModel(store: fixture.store)
        let snapshot = model.activitySnapshot

        for item in cases {
            let sourceKey = ActivityPresentation.activitySourceKey(
                for: RecentSignalEvent(
                    id: "\(item.id)-source",
                    sessionID: item.sessionID,
                    signal: .thinking,
                    updatedAt: now,
                    agent: item.agent,
                    event: item.activeEvent
                )
            )
            XCTAssertFalse(
                snapshot.sessions.contains { session in
                    session.sessionID == "recent-activity:\(sourceKey)"
                        && session.signal.displayState == .active
                },
                "Older active fallback should not revive after completion for \(item.agent)."
            )
        }
    }

    func testCodexPlatformPresenceMonitorRecognizesCodexEntrypoints() {
        let now = Date(timeIntervalSince1970: 1_000)
        let sessions = CodexPlatformPresenceMonitor.detectSessions(
            applications: [
                CodexPlatformPresenceMonitor.RunningApplicationInfo(
                    bundleIdentifier: "com.openai.codex",
                    localizedName: "Codex"
                )
            ],
            processes: [
                CodexPlatformPresenceMonitor.RunningProcessInfo(
                    pid: 1,
                    command: "/opt/homebrew/bin/codex",
                    arguments: "codex"
                ),
                CodexPlatformPresenceMonitor.RunningProcessInfo(
                    pid: 2,
                    command: "/Users/me/.vscode/extensions/openai.chatgpt/codex",
                    arguments: "codex app-server"
                ),
                CodexPlatformPresenceMonitor.RunningProcessInfo(
                    pid: 3,
                    command: "/Users/me/Library/Developer/Xcode/CodingAssistant/Agents/XcodeVersions/17F42/codex/codex",
                    arguments: "codex app-server"
                ),
                CodexPlatformPresenceMonitor.RunningProcessInfo(
                    pid: 4,
                    command: "/Users/me/Library/Caches/JetBrains/IntelliJIdea2026.1/aia/codex/bin/codex",
                    arguments: "codex app-server"
                )
            ],
            now: now
        )

        XCTAssertEqual(
            Set(sessions.map(\.sessionID)),
            [
                "platform-presence:codex-desktop",
                "platform-presence:codex-cli",
                "platform-presence:codex-vscode",
                "platform-presence:codex-xcode",
                "platform-presence:codex-idea"
            ]
        )
    }

    func testCodexPlatformPresenceMonitorParsesRealHomebrewCLIProcessLine() {
        let now = Date(timeIntervalSince1970: 1_000)
        let processes = CodexPlatformPresenceMonitor.parseProcesses(
            from: "15577 codex            codex\n"
        )
        let sessions = CodexPlatformPresenceMonitor.detectSessions(
            applications: [],
            processes: processes,
            now: now
        )

        XCTAssertEqual(processes.first?.command, "codex")
        XCTAssertEqual(processes.first?.arguments, "codex")
        XCTAssertTrue(sessions.contains { $0.sessionID == "platform-presence:codex-cli" })
    }

    func testCodexPlatformPresenceMonitorIgnoresComputerUseClientAsCLI() {
        let now = Date(timeIntervalSince1970: 1_000)
        let processes = CodexPlatformPresenceMonitor.parseProcesses(
            from: """
            60393 ./Codex Computer ./Codex Computer Use.app/Contents/SharedSupport/SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient mcp
            """
        )
        let sessions = CodexPlatformPresenceMonitor.detectSessions(
            applications: [],
            processes: processes,
            now: now
        )

        XCTAssertFalse(sessions.contains { $0.sessionID == "platform-presence:codex-cli" })
    }

    func testCodexPlatformPresenceMonitorIgnoresCodexLoginProcessAsCLI() {
        let sessions = CodexPlatformPresenceMonitor.detectSessions(
            applications: [],
            processes: CodexPlatformPresenceMonitor.parseProcesses(
                from: "54957 /opt/homebrew/bin/codex /opt/homebrew/bin/codex login\n"
            ),
            now: Date(timeIntervalSince1970: 1_000)
        )

        XCTAssertFalse(sessions.contains { $0.sessionID == "platform-presence:codex-cli" })
    }

    func testCodexPlatformPresenceMonitorDoesNotShowIDEEntrypointsFromHostAppsOnly() {
        let now = Date(timeIntervalSince1970: 1_000)
        let sessions = CodexPlatformPresenceMonitor.detectSessions(
            applications: [
                CodexPlatformPresenceMonitor.RunningApplicationInfo(
                    bundleIdentifier: "com.microsoft.VSCode",
                    localizedName: "Visual Studio Code"
                ),
                CodexPlatformPresenceMonitor.RunningApplicationInfo(
                    bundleIdentifier: "com.apple.dt.Xcode",
                    localizedName: "Xcode"
                ),
                CodexPlatformPresenceMonitor.RunningApplicationInfo(
                    bundleIdentifier: "com.jetbrains.intellij",
                    localizedName: "IntelliJ IDEA"
                )
            ],
            processes: [],
            now: now
        )

        XCTAssertFalse(sessions.contains { $0.sessionID == "platform-presence:codex-vscode" })
        XCTAssertFalse(sessions.contains { $0.sessionID == "platform-presence:codex-xcode" })
        XCTAssertFalse(sessions.contains { $0.sessionID == "platform-presence:codex-idea" })
    }

    func testCodexPlatformPresenceMonitorShowsIDEEntrypointsFromCodexPluginProcesses() {
        let sessions = CodexPlatformPresenceMonitor.detectSessions(
            applications: [],
            processes: [
                CodexPlatformPresenceMonitor.RunningProcessInfo(
                    pid: 1,
                    command: "/Users/me/.vscode/extensions/openai.chatgpt/codex",
                    arguments: "codex app-server"
                ),
                CodexPlatformPresenceMonitor.RunningProcessInfo(
                    pid: 2,
                    command: "/Users/me/Library/Developer/Xcode/CodingAssistant/Agents/XcodeVersions/17F42/codex/codex",
                    arguments: "codex app-server"
                ),
                CodexPlatformPresenceMonitor.RunningProcessInfo(
                    pid: 3,
                    command: "/Users/me/Library/Caches/JetBrains/IntelliJIdea2026.1/aia/codex/bin/codex",
                    arguments: "codex app-server"
                )
            ],
            now: Date(timeIntervalSince1970: 1_000)
        )

        XCTAssertEqual(
            Set(sessions.map(\.sessionID)),
            [
                "platform-presence:codex-vscode",
                "platform-presence:codex-xcode",
                "platform-presence:codex-idea"
            ]
        )
        XCTAssertTrue(sessions.allSatisfy { $0.signal == .idle })
    }

    func testCodexPlatformPresenceMonitorIgnoresCodexAppServerAsCLI() {
        let sessions = CodexPlatformPresenceMonitor.detectSessions(
            applications: [],
            processes: [
                CodexPlatformPresenceMonitor.RunningProcessInfo(
                    pid: 42,
                    command: "/Applications/Codex.app/Contents/Resources/codex",
                    arguments: "codex app-server --listen stdio://"
                ),
                CodexPlatformPresenceMonitor.RunningProcessInfo(
                    pid: 43,
                    command: "/Users/me/Library/Developer/Xcode/CodingAssistant/Agents/XcodeVersions/17F42/codex/codex",
                    arguments: "codex app-server"
                )
            ],
            now: Date()
        )

        XCTAssertFalse(sessions.contains { $0.sessionID == "platform-presence:codex-cli" })
        XCTAssertTrue(sessions.contains { $0.sessionID == "platform-presence:codex-xcode" })
    }

    @MainActor
    func testActivityPresentationCurrentLimitIncludesAllSupportedEntrypoints() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let snapshot = SignalSnapshot(
            aggregate: .idle,
            sessions: [
                SessionStatus(
                    sessionID: "platform-presence:codex-desktop",
                    signal: .idle,
                    updatedAt: now,
                    agent: "codex-desktop",
                    lastEvent: "PlatformPresence:Desktop"
                ),
                SessionStatus(
                    sessionID: "platform-presence:codex-vscode",
                    signal: .idle,
                    updatedAt: now,
                    agent: "codex-vscode",
                    lastEvent: "PlatformPresence:VSCode"
                ),
                SessionStatus(
                    sessionID: "platform-presence:codex-xcode",
                    signal: .idle,
                    updatedAt: now,
                    agent: "codex-xcode",
                    lastEvent: "PlatformPresence:Xcode"
                ),
                SessionStatus(
                    sessionID: "platform-presence:codex-idea",
                    signal: .idle,
                    updatedAt: now,
                    agent: "codex-idea",
                    lastEvent: "PlatformPresence:IDEA"
                ),
                SessionStatus(
                    sessionID: "platform-presence:claude-desktop",
                    signal: .idle,
                    updatedAt: now,
                    agent: "claude-desktop",
                    lastEvent: "PlatformPresence:Desktop"
                ),
                SessionStatus(
                    sessionID: "platform-presence:codex-cli",
                    signal: .idle,
                    updatedAt: now,
                    agent: "codex-cli",
                    lastEvent: "PlatformPresence:CLI"
                )
            ],
            recentEvents: [],
            stateFileURL: URL(fileURLWithPath: "/tmp/agent-signal/status.json"),
            updatedAt: now
        )

        let visible = ActivityPresentation.visibleSessions(
            from: snapshot,
            limit: ActivityPresentation.currentSessionLimit
        )

        XCTAssertEqual(visible.count, 6)
        XCTAssertTrue(visible.contains { $0.sessionID == "platform-presence:codex-cli" })

        let cliSession = try XCTUnwrap(visible.first { $0.sessionID == "platform-presence:codex-cli" })
        let model = MenuBarStatusModel()
        model.appLanguage = .zhHans
        XCTAssertEqual(model.activitySessionTitle(for: cliSession), "Codex · 终端运行中")
        XCTAssertEqual(model.activitySessionStatusSubtitle(for: cliSession), "空闲")
    }

    @MainActor
    func testActivityPresentationEventTitleIncludesCodexEntrypoint() {
        let model = MenuBarStatusModel()
        model.appLanguage = .zhHans
        let xcodeEvent = RecentSignalEvent(
            id: "xcode-event",
            sessionID: "codex-xcode:thread",
            signal: .working,
            updatedAt: Date(),
            agent: "codex-xcode",
            event: "DesktopToolCall:exec_command"
        )
        let vscodeEvent = RecentSignalEvent(
            id: "vscode-event",
            sessionID: "codex-vscode:thread",
            signal: .thinking,
            updatedAt: Date(),
            agent: "codex-vscode",
            event: "DesktopThinking"
        )

        XCTAssertEqual(model.activityEventTitle(for: xcodeEvent), "Codex Xcode")
        XCTAssertEqual(model.activityEventSubtitle(for: xcodeEvent), "正在执行步骤 exec_command")
        XCTAssertEqual(model.activityEventTitle(for: vscodeEvent), "Codex VS Code")
        XCTAssertEqual(model.activityEventSubtitle(for: vscodeEvent), "思考中")
    }

    @MainActor
    func testActivityPresenceSubtitleDoesNotExposeInternalEventName() {
        let model = MenuBarStatusModel()
        model.appLanguage = .zhHans
        let session = SessionStatus(
            sessionID: "platform-presence:codex-vscode",
            signal: .idle,
            updatedAt: Date(),
            agent: "codex-vscode",
            lastEvent: "PlatformPresence:VSCode"
        )

        XCTAssertEqual(model.activitySessionTitle(for: session), "Codex · VS Code 运行中")
        XCTAssertEqual(model.activitySessionStatusSubtitle(for: session), "空闲")
    }

    @MainActor
    func testPlatformPresenceFilteringRespectsCodexAndClaudeToggles() {
        let now = Date(timeIntervalSince1970: 1_000)
        let model = MenuBarStatusModel()
        let codexSession = SessionStatus(
            sessionID: "platform-presence:codex-desktop",
            signal: .idle,
            updatedAt: now,
            agent: "codex-desktop",
            lastEvent: "PlatformPresence:Desktop"
        )
        let claudeSession = SessionStatus(
            sessionID: "platform-presence:claude-desktop",
            signal: .idle,
            updatedAt: now,
            agent: "claude-desktop",
            lastEvent: "PlatformPresence:Desktop"
        )

        model.isCodexDesktopMonitoringEnabled = false
        model.isClaudeDesktopMonitoringEnabled = true
        XCTAssertEqual(model.filteredPlatformPresenceSessions([codexSession, claudeSession]).map(\.sessionID), [
            "platform-presence:claude-desktop"
        ])

        model.isCodexDesktopMonitoringEnabled = true
        model.isClaudeDesktopMonitoringEnabled = false
        XCTAssertEqual(model.filteredPlatformPresenceSessions([codexSession, claudeSession]).map(\.sessionID), [
            "platform-presence:codex-desktop"
        ])
    }

    @MainActor
    func testFreshInstallEnablesAutomaticMonitoringByDefault() {
        let defaults = UserDefaults.standard
        let keys = [
            "isCodexDesktopMonitoringEnabled",
            "isClaudeDesktopMonitoringEnabled"
        ]
        let previousValues = keys.map { defaults.object(forKey: $0) }
        for key in keys {
            defaults.removeObject(forKey: key)
        }
        defer {
            for (key, value) in zip(keys, previousValues) {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        let model = MenuBarStatusModel()

        XCTAssertTrue(model.isCodexDesktopMonitoringEnabled)
        XCTAssertTrue(model.isClaudeDesktopMonitoringEnabled)
    }

    @MainActor
    func testFloatingSignalBadgeSettingsDefaultOnAndPersist() {
        let defaults = UserDefaults.standard
        let keys = [
            "isFloatingSignalInfoBadgeEnabled",
            "isFloatingSignalQuotaBadgeEnabled",
            "isFloatingSignalTokenBadgeEnabled",
            "floatingSignalInfoBadgeCorner",
            "floatingSignalQuotaBadgeCorner",
            "floatingSignalTokenBadgeCorner",
            "floatingSignalQuotaBadgeWindow",
            "floatingSignalTokenBadgeWindow"
        ]
        let previousValues = keys.map { ($0, defaults.object(forKey: $0)) }
        keys.forEach(defaults.removeObject(forKey:))
        defer {
            for (key, value) in previousValues {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        let model = MenuBarStatusModel()
        XCTAssertTrue(model.isFloatingSignalInfoBadgeEnabled)
        XCTAssertTrue(model.isFloatingSignalQuotaBadgeEnabled)
        XCTAssertTrue(model.isFloatingSignalTokenBadgeEnabled)
        XCTAssertEqual(model.floatingSignalInfoBadgeCorner, .topRight)
        XCTAssertEqual(model.floatingSignalQuotaBadgeCorner, .topLeft)
        XCTAssertEqual(model.floatingSignalTokenBadgeCorner, .bottomLeft)
        XCTAssertEqual(model.floatingSignalQuotaBadgeWindow, .fiveHours)
        XCTAssertEqual(model.floatingSignalTokenBadgeWindow, .today)
        XCTAssertTrue(defaults.bool(forKey: "isFloatingSignalInfoBadgeEnabled"))
        XCTAssertTrue(defaults.bool(forKey: "isFloatingSignalQuotaBadgeEnabled"))
        XCTAssertTrue(defaults.bool(forKey: "isFloatingSignalTokenBadgeEnabled"))
        XCTAssertEqual(defaults.string(forKey: "floatingSignalInfoBadgeCorner"), FloatingSignalInfoBadgeCorner.topRight.rawValue)
        XCTAssertEqual(defaults.string(forKey: "floatingSignalQuotaBadgeCorner"), FloatingSignalInfoBadgeCorner.topLeft.rawValue)
        XCTAssertEqual(defaults.string(forKey: "floatingSignalTokenBadgeCorner"), FloatingSignalInfoBadgeCorner.bottomLeft.rawValue)
        XCTAssertEqual(defaults.string(forKey: "floatingSignalQuotaBadgeWindow"), FloatingSignalQuotaBadgeWindow.fiveHours.rawValue)
        XCTAssertEqual(defaults.string(forKey: "floatingSignalTokenBadgeWindow"), FloatingSignalTokenBadgeWindow.today.rawValue)

        model.setFloatingSignalInfoBadgeEnabled(false)
        model.setFloatingSignalQuotaBadgeEnabled(false)
        model.setFloatingSignalTokenBadgeEnabled(false)
        model.setFloatingSignalInfoBadgeCorner(.bottomLeft)
        model.setFloatingSignalQuotaBadgeCorner(.topRight)
        model.setFloatingSignalTokenBadgeCorner(.topLeft)
        model.setFloatingSignalQuotaBadgeWindow(.weekly)
        model.setFloatingSignalTokenBadgeWindow(.last30Days)
        XCTAssertFalse(model.isFloatingSignalInfoBadgeEnabled)
        XCTAssertFalse(model.isFloatingSignalQuotaBadgeEnabled)
        XCTAssertFalse(model.isFloatingSignalTokenBadgeEnabled)
        XCTAssertEqual(model.floatingSignalInfoBadgeCorner, .bottomLeft)
        XCTAssertEqual(model.floatingSignalQuotaBadgeCorner, .topRight)
        XCTAssertEqual(model.floatingSignalTokenBadgeCorner, .topLeft)
        XCTAssertEqual(model.floatingSignalQuotaBadgeWindow, .weekly)
        XCTAssertEqual(model.floatingSignalTokenBadgeWindow, .last30Days)
        XCTAssertFalse(defaults.bool(forKey: "isFloatingSignalInfoBadgeEnabled"))
        XCTAssertFalse(defaults.bool(forKey: "isFloatingSignalQuotaBadgeEnabled"))
        XCTAssertFalse(defaults.bool(forKey: "isFloatingSignalTokenBadgeEnabled"))
        XCTAssertEqual(defaults.string(forKey: "floatingSignalInfoBadgeCorner"), FloatingSignalInfoBadgeCorner.bottomLeft.rawValue)
        XCTAssertEqual(defaults.string(forKey: "floatingSignalQuotaBadgeCorner"), FloatingSignalInfoBadgeCorner.topRight.rawValue)
        XCTAssertEqual(defaults.string(forKey: "floatingSignalTokenBadgeCorner"), FloatingSignalInfoBadgeCorner.topLeft.rawValue)
        XCTAssertEqual(defaults.string(forKey: "floatingSignalQuotaBadgeWindow"), FloatingSignalQuotaBadgeWindow.weekly.rawValue)
        XCTAssertEqual(defaults.string(forKey: "floatingSignalTokenBadgeWindow"), FloatingSignalTokenBadgeWindow.last30Days.rawValue)

        let restoredModel = MenuBarStatusModel()
        XCTAssertFalse(restoredModel.isFloatingSignalInfoBadgeEnabled)
        XCTAssertFalse(restoredModel.isFloatingSignalQuotaBadgeEnabled)
        XCTAssertFalse(restoredModel.isFloatingSignalTokenBadgeEnabled)
        XCTAssertEqual(restoredModel.floatingSignalInfoBadgeCorner, .bottomLeft)
        XCTAssertEqual(restoredModel.floatingSignalQuotaBadgeCorner, .topRight)
        XCTAssertEqual(restoredModel.floatingSignalTokenBadgeCorner, .topLeft)
        XCTAssertEqual(restoredModel.floatingSignalQuotaBadgeWindow, .weekly)
        XCTAssertEqual(restoredModel.floatingSignalTokenBadgeWindow, .last30Days)
    }

    @MainActor
    func testNewZealandTrafficLightModeDefaultsOnAndPersists() {
        let defaults = UserDefaults.standard
        let keys = [
            "isNewZealandTrafficLightModeEnabled",
            "isLowPowerModeEnabled",
            "floatingSignalCompletionSound",
            "isFloatingSignalCompletionSoundEnabled",
            "floatingSignalWaitingSound",
            "isFloatingSignalWaitingSoundEnabled"
        ]
        let previousValues = keys.map { defaults.object(forKey: $0) }
        keys.forEach(defaults.removeObject(forKey:))
        defer {
            for (key, value) in zip(keys, previousValues) {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        let model = MenuBarStatusModel()
        XCTAssertTrue(model.isNewZealandTrafficLightModeEnabled)
        XCTAssertTrue(defaults.bool(forKey: "isNewZealandTrafficLightModeEnabled"))
        XCTAssertNil(defaults.object(forKey: "isLowPowerModeEnabled"))

        model.setNewZealandTrafficLightModeEnabled(false)
        XCTAssertFalse(model.isNewZealandTrafficLightModeEnabled)
        XCTAssertFalse(defaults.bool(forKey: "isNewZealandTrafficLightModeEnabled"))

        model.setFloatingSignalCompletionSound(.aiGlow)
        model.setFloatingSignalWaitingSound(.aiTick)

        model.setNewZealandTrafficLightModeEnabled(true)
        XCTAssertTrue(model.isNewZealandTrafficLightModeEnabled)
        XCTAssertTrue(defaults.bool(forKey: "isNewZealandTrafficLightModeEnabled"))
        XCTAssertNil(defaults.object(forKey: "isLowPowerModeEnabled"))
        XCTAssertFalse(model.isLowPowerModeEnabled)
        XCTAssertEqual(model.floatingSignalCompletionSound, .newZealandCrossing)
        XCTAssertEqual(model.floatingSignalWaitingSound, .newZealandCrossing)
        XCTAssertEqual(defaults.string(forKey: "floatingSignalCompletionSound"), FloatingSignalCompletionSound.newZealandCrossing.rawValue)
        XCTAssertEqual(defaults.string(forKey: "floatingSignalWaitingSound"), FloatingSignalWaitingSound.newZealandCrossing.rawValue)

        model.setNewZealandTrafficLightModeEnabled(false)
        XCTAssertFalse(model.isNewZealandTrafficLightModeEnabled)
        XCTAssertFalse(defaults.bool(forKey: "isNewZealandTrafficLightModeEnabled"))
    }

    @MainActor
    func testLowPowerModeDefaultsOffPersistsAndKeepsNewZealandModeIndependent() {
        let defaults = UserDefaults.standard
        let keys = [
            "isLowPowerModeEnabled",
            "isNewZealandTrafficLightModeEnabled",
            "floatingSignalCompletionSound",
            "isFloatingSignalCompletionSoundEnabled",
            "floatingSignalWaitingSound",
            "isFloatingSignalWaitingSoundEnabled"
        ]
        let previousValues = keys.map { defaults.object(forKey: $0) }
        keys.forEach(defaults.removeObject(forKey:))
        defer {
            for (key, value) in zip(keys, previousValues) {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        let model = MenuBarStatusModel()
        model.setFloatingSignalCompletionSound(.aiGlow)
        model.setFloatingSignalWaitingSound(.aiTick)

        XCTAssertFalse(model.isLowPowerModeEnabled)
        XCTAssertEqual(model.runtimeTimingProfile, .standard)

        model.setLowPowerModeEnabled(true)

        XCTAssertTrue(model.isLowPowerModeEnabled)
        XCTAssertTrue(defaults.bool(forKey: "isLowPowerModeEnabled"))
        XCTAssertTrue(model.isNewZealandTrafficLightModeEnabled)
        XCTAssertTrue(defaults.bool(forKey: "isNewZealandTrafficLightModeEnabled"))
        XCTAssertEqual(model.runtimeTimingProfile, .lowPower)
        XCTAssertEqual(model.floatingSignalCompletionSound, .aiGlow)
        XCTAssertEqual(model.floatingSignalWaitingSound, .aiTick)

        model.setNewZealandTrafficLightModeEnabled(false)

        XCTAssertTrue(model.isLowPowerModeEnabled)
        XCTAssertFalse(model.isNewZealandTrafficLightModeEnabled)
        XCTAssertEqual(model.floatingSignalCompletionSound, .aiGlow)
        XCTAssertEqual(model.floatingSignalWaitingSound, .aiTick)

        model.setNewZealandTrafficLightModeEnabled(true)

        XCTAssertTrue(model.isLowPowerModeEnabled)
        XCTAssertTrue(model.isNewZealandTrafficLightModeEnabled)
        XCTAssertEqual(model.floatingSignalCompletionSound, .newZealandCrossing)
        XCTAssertEqual(model.floatingSignalWaitingSound, .newZealandCrossing)

        model.setLowPowerModeEnabled(false)

        XCTAssertFalse(model.isLowPowerModeEnabled)
        XCTAssertTrue(model.isNewZealandTrafficLightModeEnabled)
        XCTAssertEqual(model.runtimeTimingProfile, .standard)
    }

    @MainActor
    func testSignalSoundSurfaceFollowsStatusBarOrFloatingSignal() {
        let defaults = UserDefaults.standard
        let keys = [
            "isStatusBarIconEnabled",
            "isFloatingSignalEnabled"
        ]
        let previousValues = keys.map { defaults.object(forKey: $0) }
        keys.forEach(defaults.removeObject(forKey:))
        defer {
            for (key, value) in zip(keys, previousValues) {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        let model = MenuBarStatusModel()

        model.setStatusBarIconEnabled(false)
        model.setFloatingSignalEnabled(false)
        XCTAssertFalse(model.isSignalSoundSurfaceEnabled)

        model.setStatusBarIconEnabled(true)
        model.setFloatingSignalEnabled(false)
        XCTAssertTrue(model.isSignalSoundSurfaceEnabled)

        model.setStatusBarIconEnabled(false)
        model.setFloatingSignalEnabled(true)
        XCTAssertTrue(model.isSignalSoundSurfaceEnabled)
    }

    func testFloatingSignalSoundResolverFindsWAVWhenM4AIsMissing() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("agent-signal-light-sound-resources-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let wavURL = directory.appendingPathComponent("completion-ai-glow.wav")
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: wavURL)

        let resolver = FloatingSignalSoundResourceResolver(candidateDirectories: [directory])

        XCTAssertEqual(resolver.url(named: "completion-ai-glow"), wavURL)
    }

    func testFloatingSignalSoundResolverPrefersM4AWhenBothFormatsExist() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("agent-signal-light-sound-resources-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let m4aURL = directory.appendingPathComponent("waiting-signal-nz.m4a")
        let wavURL = directory.appendingPathComponent("waiting-signal-nz.wav")
        try Data([0x00]).write(to: m4aURL)
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: wavURL)

        let resolver = FloatingSignalSoundResourceResolver(candidateDirectories: [directory])

        XCTAssertEqual(resolver.url(named: "waiting-signal-nz"), m4aURL)
    }

    @MainActor
    func testActivitySessionSubtitleUsesSameRealEventTextAsRecentEvents() {
        let model = MenuBarStatusModel()
        model.appLanguage = .zhHans
        let session = SessionStatus(
            sessionID: "codex-xcode:thread",
            signal: .working,
            updatedAt: Date(),
            agent: "codex-xcode",
            lastEvent: "DesktopToolCall:exec_command"
        )
        let event = RecentSignalEvent(
            id: "xcode-event",
            sessionID: session.sessionID,
            signal: session.signal,
            updatedAt: session.updatedAt,
            agent: session.agent,
            event: session.lastEvent
        )

        XCTAssertEqual(model.activitySessionStatusSubtitle(for: session), "正在执行步骤 exec_command")
        XCTAssertEqual(model.activitySessionStatusSubtitle(for: session), model.activityEventSubtitle(for: event))
    }

    func testSignalLightAgentScopesMatchSupportedSources() throws {
        let now = Date()
        let sessions: [(SignalLightAgentScope, SessionStatus)] = [
            (
                .codexDesktop,
                SessionStatus(
                    sessionID: "codex-desktop:thread",
                    signal: .working,
                    updatedAt: now,
                    agent: "codex-desktop",
                    lastEvent: "DesktopToolCall:exec_command"
                )
            ),
            (
                .codexCLI,
                SessionStatus(
                    sessionID: "codex-cli:terminal-thread",
                    signal: .thinking,
                    updatedAt: now,
                    agent: "codex-cli",
                    lastEvent: "DesktopActivityHeartbeat"
                )
            ),
            (
                .codexVSCode,
                SessionStatus(
                    sessionID: "codex-vscode:thread",
                    signal: .working,
                    updatedAt: now,
                    agent: "codex-vscode",
                    lastEvent: "DesktopToolCall:apply_patch"
                )
            ),
            (
                .codexXcode,
                SessionStatus(
                    sessionID: "codex-xcode:thread",
                    signal: .working,
                    updatedAt: now,
                    agent: "codex-xcode",
                    lastEvent: "DesktopToolCall:swift_test"
                )
            ),
            (
                .codexIDEA,
                SessionStatus(
                    sessionID: "codex-idea:thread",
                    signal: .working,
                    updatedAt: now,
                    agent: "codex-idea",
                    lastEvent: "PreToolUse"
                )
            ),
            (
                .claudeCode,
                SessionStatus(
                    sessionID: "claude-code:thread",
                    signal: .working,
                    updatedAt: now,
                    agent: "claude-code",
                    lastEvent: "PreToolUse"
                )
            ),
            (
                .localScript,
                SessionStatus(
                    sessionID: "local:script",
                    signal: .attention,
                    updatedAt: now,
                    agent: "local-script",
                    lastEvent: "ManualEvent"
                )
            )
        ]

        for (scope, session) in sessions {
            XCTAssertTrue(scope.matches(session: session), "\(scope.rawValue) should match \(session.sessionID)")
        }

        let cliSession = try XCTUnwrap(sessions.first { $0.0 == .codexCLI }?.1)
        XCTAssertFalse(SignalLightAgentScope.codexDesktop.matches(session: cliSession))
        XCTAssertFalse(SignalLightAgentScope.codexVSCode.matches(session: cliSession))
    }

    @MainActor
    func testSignalLightAgentScopesExposeSingleClaudeDesktopChoice() {
        XCTAssertFalse(SignalLightAgentScope.selectableCases.contains(.claudeDesktop))
        XCTAssertTrue(SignalLightAgentScope.selectableCases.contains(.claudeCode))

        let claudeDesktopSession = SessionStatus(
            sessionID: "claude-desktop:presence",
            signal: .idle,
            updatedAt: Date(),
            agent: "claude-desktop",
            lastEvent: "PlatformPresence:Desktop"
        )

        XCTAssertTrue(SignalLightAgentScope.claudeCode.matches(session: claudeDesktopSession))

        let model = MenuBarStatusModel()
        model.setAppLanguage(.zhHans)
        XCTAssertEqual(model.displayName(for: SignalLightAgentScope.claudeCode), "Claude 桌面版")
    }

    @MainActor
    func testCodexCLISessionKeepsTerminalRuntimeForDesktopNamedEvents() {
        let model = MenuBarStatusModel()
        model.appLanguage = .zhHans
        let session = SessionStatus(
            sessionID: "codex-cli:terminal-thread",
            signal: .thinking,
            updatedAt: Date(),
            agent: "codex-cli",
            lastEvent: "DesktopActivityHeartbeat"
        )
        let event = RecentSignalEvent(
            id: "cli-heartbeat",
            sessionID: "codex-cli:terminal-thread",
            signal: .thinking,
            updatedAt: Date(),
            agent: "codex-cli",
            event: "DesktopActivityHeartbeat"
        )

        guard case .terminal = ActivityPresentation.runtimeKind(for: session) else {
            XCTFail("Expected codex-cli sessions to stay terminal even when Codex logs use Desktop-prefixed event names.")
            return
        }

        XCTAssertEqual(model.activitySessionTitle(for: session), "Codex · 终端运行中")
        XCTAssertEqual(model.activityEventTitle(for: event), "Codex CLI")
        XCTAssertEqual(model.activityEventSubtitle(for: event), "活动中")
    }

    private func makeTemporaryStore(
        sessionTTLSeconds: Double = 86_400,
        completedTTLSeconds: Double = 30,
        eventLimit: Int = 50
    ) throws -> (store: SignalStateStore, directory: URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("agent-signal-light-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let store = SignalStateStore(
            stateFileURL: directory.appendingPathComponent("status.json"),
            sessionTTLSeconds: sessionTTLSeconds,
            completedTTLSeconds: completedTTLSeconds,
            eventLimit: eventLimit
        )
        return (store, directory)
    }

    private func makeTemporaryCodexSessionsRoot() throws -> (sessionsRoot: URL, directory: URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("agent-signal-light-codex-sessions-\(UUID().uuidString)", isDirectory: true)
        let sessionsRoot = directory.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        return (sessionsRoot, directory)
    }

    private func clearSignalLightSelectionDefaults() -> [(String, Any?)] {
        let defaults = UserDefaults.standard
        let keys = [
            "signalLightAgentScope",
            "signalLightAgentScopes",
            "signalLightAgentSelectionMode"
        ]
        let savedValues = keys.map { ($0, defaults.object(forKey: $0)) }
        keys.forEach(defaults.removeObject(forKey:))
        return savedValues
    }

    private func restoreSignalLightSelectionDefaults(_ savedValues: [(String, Any?)]) {
        let defaults = UserDefaults.standard
        for (key, value) in savedValues {
            if let value {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }

    private func isoTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func releaseMetadataJSON(version: String, build: String, signingMode: String) -> String {
        """
        {
          "version": "\(version)",
          "build": "\(build)",
          "signing": {
            "mode": "\(signingMode)"
          },
          "notarization": {
            "ready_to_submit": true
          }
        }
        """
    }

    private func codexOAuthAuthJSON(
        email: String,
        accountID: String,
        accessToken: String
    ) -> Data {
        let idToken = [
            base64URLEncodedJSON(["alg": "none", "typ": "JWT"]),
            base64URLEncodedJSON([
                "email": email,
                "chatgpt_account_id": accountID,
                "https://api.openai.com/auth": [
                    "chatgpt_account_id": accountID
                ]
            ]),
            "signature"
        ].joined(separator: ".")

        return Data("""
        {
          "tokens": {
            "access_token": "\(accessToken)",
            "refresh_token": "refresh-\(accessToken)",
            "id_token": "\(idToken)",
            "account_id": "\(accountID)"
          },
          "last_refresh": "2026-06-01T00:00:00Z"
        }
        """.utf8)
    }

    private func codexQuotaFixture(
        remainingPercent: Double,
        updatedAt: TimeInterval
    ) -> AgentQuotaStatus {
        let updatedAtDate = Date(timeIntervalSince1970: updatedAt)
        return AgentQuotaStatus(
            remainingPercent: remainingPercent,
            usedPercent: 100 - remainingPercent,
            windowMinutes: 300,
            resetsAt: updatedAtDate.addingTimeInterval(1_800),
            updatedAt: updatedAtDate,
            primary: AgentQuotaWindowStatus(
                remainingPercent: remainingPercent,
                usedPercent: 100 - remainingPercent,
                windowMinutes: 300,
                resetsAt: updatedAtDate.addingTimeInterval(1_800)
            ),
            secondary: AgentQuotaWindowStatus(
                remainingPercent: max(0, remainingPercent - 5),
                usedPercent: min(100, 105 - remainingPercent),
                windowMinutes: 10_080,
                resetsAt: updatedAtDate.addingTimeInterval(86_400)
            )
        )
    }

    private func base64URLEncodedJSON(_ object: Any) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func storedDocument(in store: SignalStateStore) throws -> SignalStateDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(contentsOf: store.stateFileURL)
        return try decoder.decode(SignalStateDocument.self, from: data)
    }

    private func writeDocument(_ document: SignalStateDocument, in store: SignalStateStore) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(
            at: store.stateFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(document).write(to: store.stateFileURL)
    }
}

private final class CodexRateLimitFetcherURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private struct FakeOpenAIBrowserCookieImporter: OpenAIBrowserCookieImporting {
    let cookieHeader: String?

    func importCookieHeader() async -> OpenAIBrowserCookieImportResult? {
        guard let cookieHeader else { return nil }
        return OpenAIBrowserCookieImportResult(
            cookieHeader: cookieHeader,
            sourceLabel: "Test",
            debugLog: "test"
        )
    }
}

private final class FakeCodexAccountLoginRunner: CodexAccountLoginRunning, @unchecked Sendable {
    private let authData: Data?
    private let result: CodexAccountLoginResult
    private(set) var observedHomePath: String?

    init(
        authData: Data?,
        result: CodexAccountLoginResult = CodexAccountLoginResult(outcome: .success, output: "")
    ) {
        self.authData = authData
        self.result = result
    }

    func run(
        homePath: String,
        timeout _: TimeInterval,
        environment _: [String: String]
    ) async -> CodexAccountLoginResult {
        observedHomePath = homePath
        if let authData {
            let authURL = URL(fileURLWithPath: homePath, isDirectory: true)
                .appendingPathComponent("auth.json", isDirectory: false)
            try? FileManager.default.createDirectory(
                at: authURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? authData.write(to: authURL)
        }
        return result
    }
}

private extension FileHandle {
    func appendString(_ value: String) throws {
        defer {
            try? close()
        }
        try seekToEnd()
        if let data = value.data(using: .utf8) {
            try write(contentsOf: data)
        }
    }
}

private actor QueuedURLSession: URLSessionProtocol {
    struct QueuedResponse {
        let data: Data
        let response: URLResponse
    }

    private var responses: [QueuedResponse]

    init(_ responses: [QueuedResponse]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard !responses.isEmpty else {
            throw URLError(.badServerResponse)
        }
        let response = responses.removeFirst()
        return (response.data, response.response)
    }
}

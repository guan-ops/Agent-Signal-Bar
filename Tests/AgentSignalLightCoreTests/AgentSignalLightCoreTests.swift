import Foundation
import XCTest
#if canImport(SQLite3)
import SQLite3
#endif
@testable import AgentSignalLight
@testable import AgentSignalLightCore
@testable import AgentSignalLightUI

final class AgentSignalLightCoreTests: XCTestCase {
    func testCodex56BuiltInPricingCoversAllVariantsAndDatedAliases() throws {
        let emptyCatalog = ModelsDevCatalog(providers: [:])

        let sol = try XCTUnwrap(CostUsagePricing.codexCostUSD(
            model: "gpt-5.6-sol",
            inputTokens: 1_000_000,
            cachedInputTokens: 200_000,
            outputTokens: 100_000,
            modelsDevCatalog: emptyCatalog
        ))
        let terra = try XCTUnwrap(CostUsagePricing.codexCostUSD(
            model: "gpt-5.6-terra",
            inputTokens: 1_000_000,
            cachedInputTokens: 200_000,
            outputTokens: 100_000,
            modelsDevCatalog: emptyCatalog
        ))
        let luna = try XCTUnwrap(CostUsagePricing.codexCostUSD(
            model: "openai/gpt-5.6-luna-2026-07-11",
            inputTokens: 1_000_000,
            cachedInputTokens: 200_000,
            outputTokens: 100_000,
            modelsDevCatalog: emptyCatalog
        ))

        XCTAssertEqual(sol, 7.1, accuracy: 0.000_001)
        XCTAssertEqual(terra, 3.55, accuracy: 0.000_001)
        XCTAssertEqual(luna, 1.42, accuracy: 0.000_001)
    }

    func testCodex56PriorityPricingCoversAllVariants() throws {
        let sol = try XCTUnwrap(CostUsagePricing.codexPriorityCostUSD(
            model: "gpt-5.6-sol",
            inputTokens: 100_000,
            cachedInputTokens: 20_000,
            outputTokens: 10_000
        ))
        let terra = try XCTUnwrap(CostUsagePricing.codexPriorityCostUSD(
            model: "gpt-5.6-terra",
            inputTokens: 100_000,
            cachedInputTokens: 20_000,
            outputTokens: 10_000
        ))
        let luna = try XCTUnwrap(CostUsagePricing.codexPriorityCostUSD(
            model: "gpt-5.6-luna",
            inputTokens: 100_000,
            cachedInputTokens: 20_000,
            outputTokens: 10_000
        ))

        XCTAssertEqual(sol, 1.42, accuracy: 0.000_001)
        XCTAssertEqual(terra, 0.71, accuracy: 0.000_001)
        XCTAssertEqual(luna, 0.284, accuracy: 0.000_001)
    }

    func testCodex56SessionScanProducesDollarCost() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-56-cost-\(UUID().uuidString)", isDirectory: true)
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let lines = [
            #"{"timestamp":"2026-07-11T01:59:59.000Z","type":"session_meta","payload":{"id":"codex-56-cost-session","originator":"Codex Desktop"}}"#,
            #"{"timestamp":"2026-07-11T02:00:00.000Z","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"#,
            #"{"timestamp":"2026-07-11T02:01:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000000,"cached_input_tokens":200000,"output_tokens":100000,"total_tokens":1100000},"last_token_usage":{"input_tokens":1000000,"cached_input_tokens":200000,"output_tokens":100000,"total_tokens":1100000}}}}"#,
        ].joined(separator: "\n")
        try lines.write(
            to: sessionsRoot.appendingPathComponent("rollout-gpt-5.6-sol.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let calendar = Calendar(identifier: .gregorian)
        let since = try XCTUnwrap(calendar.date(from: DateComponents(
            timeZone: TimeZone(secondsFromGMT: 0),
            year: 2026,
            month: 7,
            day: 11
        )))
        let until = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: since))
        let now = try XCTUnwrap(calendar.date(byAdding: .hour, value: 12, to: since))
        let report = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: since,
            until: until,
            now: now,
            options: CostUsageScanner.Options(
                codexSessionsRoot: sessionsRoot,
                cacheRoot: cacheRoot,
                forceRescan: true
            )
        )

        let totalCost = try XCTUnwrap(report.summary?.totalCostUSD)
        let modelCost = try XCTUnwrap(report.data.first?.modelBreakdowns?.first?.costUSD)
        XCTAssertEqual(totalCost, 7.1, accuracy: 0.000_001)
        XCTAssertEqual(report.data.first?.modelBreakdowns?.first?.modelName, "gpt-5.6-sol")
        XCTAssertEqual(modelCost, 7.1, accuracy: 0.000_001)
    }

    func testClaudeScanReturnsFreshReportWhenCacheSaveFails() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-cache-save-failure-\(UUID().uuidString)", isDirectory: true)
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        let invalidCacheRoot = root.appendingPathComponent("cache-root-file", isDirectory: false)
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: invalidCacheRoot)
        defer { try? FileManager.default.removeItem(at: root) }

        let line = #"{"type":"assistant","timestamp":"2026-07-11T02:00:00.000Z","requestId":"request-1","sessionId":"session-1","message":{"id":"message-1","model":"claude-sonnet-4-5-20250929","usage":{"input_tokens":100,"output_tokens":50}}}"#
        try line.write(
            to: sessionsRoot.appendingPathComponent("session.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let calendar = Calendar(identifier: .gregorian)
        let since = try XCTUnwrap(calendar.date(from: DateComponents(
            timeZone: TimeZone(secondsFromGMT: 0),
            year: 2026,
            month: 7,
            day: 11
        )))
        let until = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: since))
        let now = try XCTUnwrap(calendar.date(byAdding: .hour, value: 12, to: since))

        let report = CostUsageScanner.loadDailyReport(
            provider: .claude,
            since: since,
            until: until,
            now: now,
            options: CostUsageScanner.Options(
                claudeProjectsRoots: [sessionsRoot],
                cacheRoot: invalidCacheRoot,
                forceRescan: true
            )
        )

        XCTAssertEqual(report.data.count, 1)
        XCTAssertEqual(report.data.first?.totalTokens, 150)
        XCTAssertEqual(report.summary?.totalTokens, 150)
    }

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
        let verticalLamp = scale.panelSize(layout: .vertical)
        let horizontalLamp = scale.panelSize(layout: .horizontal)
        let horizontalBacking = scale.housingBackingSize(layout: .horizontal)

        XCTAssertEqual(verticalLamp.width, 34 * scale.visualScale, accuracy: 0.01)
        XCTAssertEqual(verticalLamp.height, 74 * scale.visualScale, accuracy: 0.01)
        XCTAssertGreaterThan(horizontalLamp.width, verticalLamp.width)
        XCTAssertLessThan(horizontalLamp.height, verticalLamp.height)
        XCTAssertEqual(horizontalBacking.height, (16 + 12) * scale.visualScale, accuracy: 0.01)
    }

    func testFloatingSignalPresetSizesGrowInBothLayouts() {
        for layout in TrafficSignalLayout.allCases {
            let compact = FloatingSignalScale.compact.panelSize(layout: layout)
            let standard = FloatingSignalScale.standard.panelSize(layout: layout)
            let large = FloatingSignalScale.large.panelSize(layout: layout)

            XCTAssertLessThan(compact.width, standard.width)
            XCTAssertLessThan(compact.height, standard.height)
            XCTAssertLessThan(standard.width, large.width)
            XCTAssertLessThan(standard.height, large.height)
        }
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

    func testCodexDesktopSessionParserMapsEscalatedSandboxApprovalToPermission() {
        let line = """
        {"timestamp":"2026-06-29T02:00:33.647Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\\"cmd\\":\\"swift test\\",\\"sandbox_permissions\\":\\"require_escalated\\",\\"justification\\":\\"Run outside sandbox?\\"}","call_id":"call_1"}}
        """

        let activity = CodexDesktopSessionParser.activity(
            from: line,
            defaultSessionID: "codex-desktop:thread"
        )

        XCTAssert(activity?.signal == .permissionRequest)
        XCTAssert(activity?.event == "DesktopToolCall:exec_command")
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
        {"timestamp":"2026-06-18T08:10:20.000Z","type":"event_msg","payload":{"type":"token_count","info":{"model_context_window":258400,"total_token_usage":{"input_tokens":50000,"cached_input_tokens":18000,"output_tokens":4000,"reasoning_output_tokens":900,"total_tokens":54000},"last_token_usage":{"input_tokens":34567,"cached_input_tokens":12000,"output_tokens":2345,"reasoning_output_tokens":567,"total_tokens":36912}},"rate_limits":{"limit_id":"codex_bengalfox","limit_name":"GPT-5.3-Codex-Spark","primary":{"used_percent":42.5,"window_minutes":300,"resets_at":1781788782},"secondary":{"used_percent":12.0,"window_minutes":10080,"resets_at":1782375582}}}}
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
        XCTAssertEqual(quotaUpdate?.tokenActivityUsage?.effectiveTotalTokens, 54_000)
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

    func testCostUsageScannerDefersEventsAfterStrictScanCutoff() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cost-cutoff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let lines = [
            #"{"timestamp":"2026-06-18T07:59:59.000Z","type":"session_meta","payload":{"id":"019c846a-b85e-7bd3-924b-cc33e3f180d9","originator":"Codex Desktop"}}"#,
            #"{"timestamp":"2026-06-18T08:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":100,"output_tokens":100},"last_token_usage":{"input_tokens":1000,"cached_input_tokens":100,"output_tokens":100}}}}"#,
            #"{"timestamp":"2026-06-18T08:02:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1500,"cached_input_tokens":150,"output_tokens":150},"last_token_usage":{"input_tokens":500,"cached_input_tokens":50,"output_tokens":50}}}}"#
        ].joined(separator: "\n")
        let sessionURL = root.appendingPathComponent("rollout-cutoff.jsonl")
        try lines.write(to: sessionURL, atomically: true, encoding: .utf8)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let firstTimestamp = try XCTUnwrap(formatter.date(from: "2026-06-18T08:00:00.000Z"))
        let cutoff = try XCTUnwrap(formatter.date(from: "2026-06-18T08:01:00.000Z"))
        let finalCutoff = try XCTUnwrap(formatter.date(from: "2026-06-18T08:03:00.000Z"))
        let range = CostUsageScanner.CostUsageDayRange(since: firstTimestamp, until: finalCutoff)

        let first = CostUsageScanner.parseCodexFile(
            fileURL: sessionURL,
            range: range,
            through: cutoff
        )
        let firstTokens = first.days.values
            .flatMap(\.values)
            .reduce(0) { $0 + ($1[safe: 0] ?? 0) + ($1[safe: 2] ?? 0) }
        XCTAssertEqual(firstTokens, 1_100)
        XCTAssertLessThan(first.parsedBytes, Int64(lines.utf8.count))

        let deferred = CostUsageScanner.parseCodexFile(
            fileURL: sessionURL,
            range: range,
            through: finalCutoff,
            startOffset: first.parsedBytes,
            initialModel: first.lastModel,
            initialTotals: first.lastCountedTotals,
            initialRawTotalsBaseline: first.lastRawTotalsBaseline,
            initialHasDivergentTotals: first.hasDivergentTotals,
            initialCodexTurnID: first.lastCodexTurnID
        )
        let deferredTokens = deferred.days.values
            .flatMap(\.values)
            .reduce(0) { $0 + ($1[safe: 0] ?? 0) + ($1[safe: 2] ?? 0) }
        XCTAssertEqual(deferredTokens, 550)
        XCTAssertEqual(deferred.parsedBytes, Int64(lines.utf8.count))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: root,
            cacheRoot: root.appendingPathComponent("cost-cache", isDirectory: true)
        )
        options.refreshMinIntervalSeconds = 0
        let firstReport = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: firstTimestamp,
            until: cutoff,
            now: cutoff,
            options: options
        )
        XCTAssertEqual(firstReport.data.compactMap(\.totalTokens).reduce(0, +), 1_100)

        // The file is unchanged; the cache must remember the unread byte offset
        // and consume the deferred line when the strict cutoff advances.
        let finalReport = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: firstTimestamp,
            until: finalCutoff,
            now: finalCutoff,
            options: options
        )
        XCTAssertEqual(finalReport.data.compactMap(\.totalTokens).reduce(0, +), 1_650)
    }

    func testProductionTokenScannerMarksCacheCommitFailureIncomplete() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cost-commit-failure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionURL = root.appendingPathComponent("rollout-2026-06-18T08-00-00.jsonl")
        try [
            #"{"timestamp":"2026-06-18T07:59:59.000Z","type":"session_meta","payload":{"id":"commit-failure-session","originator":"Codex Desktop"}}"#,
            #"{"timestamp":"2026-06-18T08:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100},"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100}}}}"#,
        ].joined(separator: "\n").appending("\n")
            .write(to: sessionURL, atomically: true, encoding: .utf8)

        let cacheRootBlocker = root.appendingPathComponent("cache-root-is-a-file")
        try Data("not a directory".utf8).write(to: cacheRootBlocker)
        let scanner = CodexTokenActivityScanner(
            sessionRootURLs: [root],
            costUsageCacheRootURL: cacheRootBlocker,
            usesAgentSignalCostUsageScanner: true
        )
        let cutoff = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-06-18T08:01:00Z"))

        let result = scanner.scanDailyActivityResult(now: cutoff, days: 1, progress: nil)

        XCTAssertFalse(result.isComplete)
        XCTAssertTrue(result.watermarks.isEmpty)
        XCTAssertTrue(result.days.isEmpty)
    }

    func testPiSessionScannerDefersUnchangedFutureLinesUntilCutoffAdvances() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-cutoff-\(UUID().uuidString)", isDirectory: true)
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionURL = sessionsRoot.appendingPathComponent(
            "2026-06-18T07-59-59-000Z_pi-cutoff.jsonl"
        )
        try [
            #"{"type":"model_change","timestamp":"2026-06-18T07:59:59.000Z","provider":"openai-codex","modelId":"gpt-5"}"#,
            #"{"type":"message","timestamp":"2026-06-18T08:00:00.000Z","message":{"role":"assistant","provider":"openai-codex","model":"gpt-5","usage":{"input":100,"output":0,"totalTokens":100}}}"#,
            #"{"type":"message","timestamp":"2026-06-18T08:02:00.000Z","message":{"role":"assistant","provider":"openai-codex","model":"gpt-5","usage":{"input":50,"output":0,"totalTokens":50}}}"#,
        ].joined(separator: "\n").appending("\n")
            .write(to: sessionURL, atomically: true, encoding: .utf8)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let since = try XCTUnwrap(formatter.date(from: "2026-06-18T00:00:00.000Z"))
        let firstCutoff = try XCTUnwrap(formatter.date(from: "2026-06-18T08:01:00.000Z"))
        let finalCutoff = try XCTUnwrap(formatter.date(from: "2026-06-18T08:03:00.000Z"))
        let options = PiSessionCostScanner.Options(
            piSessionsRoot: sessionsRoot,
            cacheRoot: cacheRoot,
            refreshMinIntervalSeconds: 0
        )

        let first = try PiSessionCostScanner.loadDailyReportCancellable(
            provider: .codex,
            since: since,
            until: firstCutoff,
            now: firstCutoff,
            options: options,
            checkCancellation: nil
        )
        XCTAssertEqual(first.data.compactMap(\.totalTokens).reduce(0, +), 100)
        let partialCache = PiSessionCostCacheIO.load(cacheRoot: cacheRoot)
        let partialUsage = try XCTUnwrap(partialCache.files.values.first)
        XCTAssertLessThan(partialUsage.parsedBytes, partialUsage.size)

        let final = try PiSessionCostScanner.loadDailyReportCancellable(
            provider: .codex,
            since: since,
            until: finalCutoff,
            now: finalCutoff,
            options: options,
            checkCancellation: nil
        )
        XCTAssertEqual(final.data.compactMap(\.totalTokens).reduce(0, +), 150)
        let finalCache = PiSessionCostCacheIO.load(cacheRoot: cacheRoot)
        let finalUsage = try XCTUnwrap(finalCache.files.values.first)
        XCTAssertEqual(finalUsage.parsedBytes, finalUsage.size)
    }

    func testForceRescanPreservesDormantSessionForAppendDiscoveryAfterThirtyDayWindow() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dormant-session-inventory-\(UUID().uuidString)", isDirectory: true)
        let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let oldAt = try XCTUnwrap(formatter.date(from: "2026-01-01T08:00:00.000Z"))
        let firstNow = try XCTUnwrap(formatter.date(from: "2026-06-01T09:00:00.000Z"))
        let finalNow = try XCTUnwrap(formatter.date(from: "2026-08-23T09:00:00.000Z"))
        let oldURL = root.appendingPathComponent("rollout-2026-01-01T08-00-00-dormant.jsonl")
        try [
            #"{"timestamp":"2026-01-01T07:59:59.000Z","type":"session_meta","payload":{"id":"dormant-session","originator":"Codex Desktop"}}"#,
            #"{"timestamp":"2026-01-01T08:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100},"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100}}}}"#,
        ].joined(separator: "\n").appending("\n")
            .write(to: oldURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: oldAt], ofItemAtPath: oldURL.path)

        let currentURL = root.appendingPathComponent("rollout-2026-06-01T08-00-00-current.jsonl")
        try [
            #"{"timestamp":"2026-06-01T07:59:59.000Z","type":"session_meta","payload":{"id":"current-session","originator":"Codex Desktop"}}"#,
            #"{"timestamp":"2026-06-01T08:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":20,"cached_input_tokens":0,"output_tokens":0,"total_tokens":20},"last_token_usage":{"input_tokens":20,"cached_input_tokens":0,"output_tokens":0,"total_tokens":20}}}}"#,
        ].joined(separator: "\n").appending("\n")
            .write(to: currentURL, atomically: true, encoding: .utf8)

        var options = CostUsageScanner.Options(codexSessionsRoot: root, cacheRoot: cacheRoot)
        options.refreshMinIntervalSeconds = 0
        options.forceRescan = true
        let firstSince = Calendar.current.date(byAdding: .day, value: -29, to: firstNow) ?? firstNow
        let first = try CostUsageScanner.loadDailyReportCancellable(
            provider: .codex,
            since: firstSince,
            until: firstNow,
            now: firstNow,
            options: options,
            checkCancellation: nil
        )
        XCTAssertEqual(first.data.compactMap(\.totalTokens).reduce(0, +), 20)
        let inventoryCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        let dormantStub = try XCTUnwrap(
            inventoryCache.files.values.first(where: { $0.sessionId == "dormant-session" })
        )
        XCTAssertTrue(dormantStub.days.isEmpty)
        XCTAssertEqual(dormantStub.parsedBytes, dormantStub.size)

        options.forceRescan = false
        try FileHandle(forWritingTo: oldURL).appendString(
            #"{"timestamp":"2026-08-23T08:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":150,"cached_input_tokens":0,"output_tokens":0,"total_tokens":150},"last_token_usage":{"input_tokens":50,"cached_input_tokens":0,"output_tokens":0,"total_tokens":50}}}}"# + "\n"
        )
        let finalSince = Calendar.current.startOfDay(for: finalNow)
        let final = try CostUsageScanner.loadDailyReportCancellable(
            provider: .codex,
            since: finalSince,
            until: finalNow,
            now: finalNow,
            options: options,
            checkCancellation: nil
        )
        XCTAssertEqual(final.data.compactMap(\.totalTokens).reduce(0, +), 50)
    }

    func testDormantOwnerStubCanPromoteToLongerDuplicateAndResumeScanning() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dormant-owner-promotion-\(UUID().uuidString)", isDirectory: true)
        let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let oldAt = try XCTUnwrap(formatter.date(from: "2026-01-01T08:00:00.000Z"))
        let firstNow = try XCTUnwrap(formatter.date(from: "2026-06-01T09:00:00.000Z"))
        let finalNow = try XCTUnwrap(formatter.date(from: "2026-08-23T09:00:00.000Z"))
        let meta = #"{"timestamp":"2026-01-01T07:59:59.000Z","type":"session_meta","payload":{"id":"dormant-promotion","originator":"Codex Desktop"}}"#
        let oldToken = #"{"timestamp":"2026-01-01T08:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100},"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100}}}}"#
        let oldDirectory = root
            .appendingPathComponent("2026", isDirectory: true)
            .appendingPathComponent("01", isDirectory: true)
            .appendingPathComponent("01", isDirectory: true)
        try FileManager.default.createDirectory(at: oldDirectory, withIntermediateDirectories: true)
        let oldURL = oldDirectory.appendingPathComponent(
            "rollout-2026-01-01T08-00-00-dormant.jsonl"
        )
        try [meta, oldToken].joined(separator: "\n").appending("\n")
            .write(to: oldURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: oldAt], ofItemAtPath: oldURL.path)

        let currentURL = root.appendingPathComponent("rollout-2026-06-01T08-00-00-current.jsonl")
        try [
            #"{"timestamp":"2026-06-01T07:59:59.000Z","type":"session_meta","payload":{"id":"current-for-dormant-promotion","originator":"Codex Desktop"}}"#,
            #"{"timestamp":"2026-06-01T08:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":20,"cached_input_tokens":0,"output_tokens":0,"total_tokens":20},"last_token_usage":{"input_tokens":20,"cached_input_tokens":0,"output_tokens":0,"total_tokens":20}}}}"#,
        ].joined(separator: "\n").appending("\n")
            .write(to: currentURL, atomically: true, encoding: .utf8)

        var options = CostUsageScanner.Options(codexSessionsRoot: root, cacheRoot: cacheRoot)
        options.refreshMinIntervalSeconds = 0
        let firstSince = Calendar.current.date(byAdding: .day, value: -29, to: firstNow) ?? firstNow
        _ = try CostUsageScanner.loadDailyReportCancellable(
            provider: .codex,
            since: firstSince,
            until: firstNow,
            now: firstNow,
            options: options,
            checkCancellation: nil
        )
        let stubCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        let stub = try XCTUnwrap(stubCache.files.values.first(where: {
            $0.sessionId == "dormant-promotion" && $0.codexInventoryOnly != true
        }))
        XCTAssertTrue(stub.days.isEmpty)
        XCTAssertNil(stub.committedPrefixFingerprint)

        let longerURL = root.appendingPathComponent("rollout-2026-08-23T08-00-00-dormant-copy.jsonl")
        let todayToken = #"{"timestamp":"2026-08-23T08:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":150,"cached_input_tokens":0,"output_tokens":0,"total_tokens":150},"last_token_usage":{"input_tokens":50,"cached_input_tokens":0,"output_tokens":0,"total_tokens":50}}}}"#
        try [meta, oldToken, todayToken].joined(separator: "\n").appending("\n")
            .write(to: longerURL, atomically: true, encoding: .utf8)

        let finalSince = Calendar.current.startOfDay(for: finalNow)
        let promoted = try CostUsageScanner.loadDailyReportCancellable(
            provider: .codex,
            since: finalSince,
            until: finalNow,
            now: finalNow,
            options: options,
            checkCancellation: nil
        )
        XCTAssertEqual(promoted.data.compactMap(\.totalTokens).reduce(0, +), 50)
        let stable = try CostUsageScanner.loadDailyReportCancellable(
            provider: .codex,
            since: finalSince,
            until: finalNow,
            now: finalNow,
            options: options,
            checkCancellation: nil
        )
        XCTAssertEqual(stable.data.compactMap(\.totalTokens).reduce(0, +), 50)
        let finalCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        XCTAssertEqual(finalCache.files.values.filter {
            $0.sessionId == "dormant-promotion" && $0.codexInventoryOnly != true
        }.count, 1)
        XCTAssertNotNil(finalCache.files.values.first(where: {
            $0.sessionId == "dormant-promotion" && $0.codexInventoryOnly != true
        })?.committedPrefixFingerprint)
    }

    func testSessionInventoryQuarantinesNoMetaFileAndDetectsLaterRepair() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-meta-inventory-\(UUID().uuidString)", isDirectory: true)
        let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let malformedURL = root.appendingPathComponent("rollout-2026-08-23T07-00-00-malformed.jsonl")
        try #"{"timestamp":"2026-08-23T07:00:00.000Z","type":"event_msg","payload":{"type":"notice"}}"#
            .appending("\n")
            .write(to: malformedURL, atomically: true, encoding: .utf8)
        let validURL = root.appendingPathComponent("rollout-2026-08-23T07-30-00-valid.jsonl")
        try [
            #"{"timestamp":"2026-08-23T07:29:59.000Z","type":"session_meta","payload":{"id":"valid-session","originator":"Codex Desktop"}}"#,
            #"{"timestamp":"2026-08-23T07:30:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":20,"cached_input_tokens":0,"output_tokens":0,"total_tokens":20},"last_token_usage":{"input_tokens":20,"cached_input_tokens":0,"output_tokens":0,"total_tokens":20}}}}"#,
        ].joined(separator: "\n").appending("\n")
            .write(to: validURL, atomically: true, encoding: .utf8)

        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-23T09:00:00Z"))
        let since = Calendar.current.startOfDay(for: now)
        var options = CostUsageScanner.Options(codexSessionsRoot: root, cacheRoot: cacheRoot)
        options.refreshMinIntervalSeconds = 0

        let first = try CostUsageScanner.loadDailyReportCancellable(
            provider: .codex,
            since: since,
            until: now,
            now: now,
            options: options,
            checkCancellation: nil
        )
        XCTAssertEqual(first.data.compactMap(\.totalTokens).reduce(0, +), 20)
        let firstCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        let malformedPath = malformedURL.standardizedFileURL.resolvingSymlinksInPath().path
        let quarantined = try XCTUnwrap(
            firstCache.files.first(where: {
                URL(fileURLWithPath: $0.key).standardizedFileURL.resolvingSymlinksInPath().path
                    == malformedPath
            })?.value,
            "cached paths: \(firstCache.files.keys.sorted())"
        )
        XCTAssertNil(quarantined.sessionId)
        XCTAssertEqual(quarantined.codexInventoryOnly, true)
        XCTAssertTrue(quarantined.days.isEmpty)
        XCTAssertEqual(quarantined.parsedBytes, 0)

        try FileHandle(forWritingTo: malformedURL).appendString([
            #"{"timestamp":"2026-08-23T07:59:59.000Z","type":"session_meta","payload":{"id":"repaired-session","originator":"Codex Desktop"}}"#,
            #"{"timestamp":"2026-08-23T08:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":30,"cached_input_tokens":0,"output_tokens":0,"total_tokens":30},"last_token_usage":{"input_tokens":30,"cached_input_tokens":0,"output_tokens":0,"total_tokens":30}}}}"#,
        ].joined(separator: "\n").appending("\n"))

        let repaired = try CostUsageScanner.loadDailyReportCancellable(
            provider: .codex,
            since: since,
            until: now,
            now: now,
            options: options,
            checkCancellation: nil
        )
        XCTAssertEqual(repaired.data.compactMap(\.totalTokens).reduce(0, +), 50)
        let repairedCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        let repairedUsage = try XCTUnwrap(
            repairedCache.files.first(where: {
                URL(fileURLWithPath: $0.key).standardizedFileURL.resolvingSymlinksInPath().path
                    == malformedPath
            })?.value
        )
        XCTAssertEqual(repairedUsage.sessionId, "repaired-session")
        XCTAssertNotEqual(repairedUsage.codexInventoryOnly, true)
    }

    func testDuplicateSessionPathExtensionPromotesOwnerWithoutDoubleCounting() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("duplicate-session-inventory-\(UUID().uuidString)", isDirectory: true)
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = "duplicate-session"
        let meta = #"{"timestamp":"2026-08-23T07:59:59.000Z","type":"session_meta","payload":{"id":"duplicate-session","originator":"Codex Desktop"}}"#
        let initial = #"{"timestamp":"2026-08-23T08:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100},"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100}}}}"#
        let firstURL = sessionsRoot.appendingPathComponent("rollout-2026-08-23T08-00-00-a.jsonl")
        let secondURL = sessionsRoot.appendingPathComponent("rollout-2026-08-23T08-00-00-b.jsonl")
        for url in [firstURL, secondURL] {
            try [meta, initial].joined(separator: "\n").appending("\n")
                .write(to: url, atomically: true, encoding: .utf8)
        }

        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-23T09:00:00Z"))
        let scanner = CodexTokenActivityScanner(
            sessionRootURLs: [sessionsRoot],
            costUsageCacheRootURL: cacheRoot,
            usesAgentSignalCostUsageScanner: true
        )
        let first = scanner.scanDailyActivityResult(now: now, days: 1, progress: nil)
        XCTAssertTrue(first.isComplete)
        XCTAssertEqual(first.days.compactMap(\.totalTokens).reduce(0, +), 100)

        let firstCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        let duplicates = firstCache.files.filter { $0.value.sessionId == sessionID }
        XCTAssertEqual(duplicates.count, 2)
        let sentinelPath = try XCTUnwrap(
            duplicates.first(where: { $0.value.codexInventoryOnly == true })?.key
        )
        try FileHandle(forWritingTo: URL(fileURLWithPath: sentinelPath)).appendString(
            #"{"timestamp":"2026-08-23T08:30:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":150,"cached_input_tokens":0,"output_tokens":0,"total_tokens":150},"last_token_usage":{"input_tokens":50,"cached_input_tokens":0,"output_tokens":0,"total_tokens":50}}}}"# + "\n"
        )

        let recovered = scanner.scanDailyActivityResult(now: now, days: 1, progress: nil)
        XCTAssertTrue(recovered.isComplete)
        XCTAssertEqual(recovered.days.compactMap(\.totalTokens).reduce(0, +), 150)
        let recoveredCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        XCTAssertNotEqual(recoveredCache.files[sentinelPath]?.codexInventoryOnly, true)
        XCTAssertEqual(
            recoveredCache.files.values.filter { $0.sessionId == sessionID }.count,
            2
        )
        XCTAssertEqual(
            recoveredCache.files.values.filter {
                $0.sessionId == sessionID && $0.codexInventoryOnly == true
            }.count,
            1
        )

        let stable = scanner.scanDailyActivityResult(now: now, days: 1, progress: nil)
        XCTAssertTrue(stable.isComplete)
        XCTAssertEqual(stable.days.compactMap(\.totalTokens).reduce(0, +), 150)
    }

    func testInitialDuplicateSessionChoosesTheCopyWithTheGreatestProvenFrontier() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("duplicate-session-frontier-\(UUID().uuidString)", isDirectory: true)
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = "frontier-session"
        let meta = #"{"timestamp":"2026-08-23T07:59:59.000Z","type":"session_meta","payload":{"id":"frontier-session","originator":"Codex Desktop"}}"#
        let first = #"{"timestamp":"2026-08-23T08:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100},"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100}}}}"#
        let extensionLine = #"{"timestamp":"2026-08-23T08:30:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":150,"cached_input_tokens":0,"output_tokens":0,"total_tokens":150},"last_token_usage":{"input_tokens":50,"cached_input_tokens":0,"output_tokens":0,"total_tokens":50}}}}"#
        let shorterURL = sessionsRoot.appendingPathComponent("rollout-2026-08-23T08-00-00-a.jsonl")
        let longerURL = sessionsRoot.appendingPathComponent("rollout-2026-08-23T08-00-00-b.jsonl")
        try [meta, first].joined(separator: "\n").appending("\n")
            .write(to: shorterURL, atomically: true, encoding: .utf8)
        try [meta, first, extensionLine].joined(separator: "\n").appending("\n")
            .write(to: longerURL, atomically: true, encoding: .utf8)

        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-23T09:00:00Z"))
        let scanner = CodexTokenActivityScanner(
            sessionRootURLs: [sessionsRoot],
            costUsageCacheRootURL: cacheRoot,
            usesAgentSignalCostUsageScanner: true
        )
        let result = scanner.scanDailyActivityResult(now: now, days: 1, progress: nil)
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.days.compactMap(\.totalTokens).reduce(0, +), 150)

        let cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        let longerPath = longerURL.standardizedFileURL.resolvingSymlinksInPath().path
        let shorterPath = shorterURL.standardizedFileURL.resolvingSymlinksInPath().path
        let longerUsage = cache.files.first {
            URL(fileURLWithPath: $0.key).standardizedFileURL.resolvingSymlinksInPath().path == longerPath
        }?.value
        let shorterUsage = cache.files.first {
            URL(fileURLWithPath: $0.key).standardizedFileURL.resolvingSymlinksInPath().path == shorterPath
        }?.value
        XCTAssertNotEqual(longerUsage?.codexInventoryOnly, true)
        XCTAssertEqual(shorterUsage?.codexInventoryOnly, true)
        XCTAssertEqual(cache.files.values.filter { $0.sessionId == sessionID }.count, 2)
    }

    func testInitialDivergentDuplicateSessionPreservesConsistencyInsteadOfChoosingByPath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("divergent-session-frontier-\(UUID().uuidString)", isDirectory: true)
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let meta = #"{"timestamp":"2026-08-23T07:59:59.000Z","type":"session_meta","payload":{"id":"divergent-session","originator":"Codex Desktop"}}"#
        let first = #"{"timestamp":"2026-08-23T08:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100},"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100}}}}"#
        let divergent = #"{"timestamp":"2026-08-23T08:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":200,"cached_input_tokens":0,"output_tokens":0,"total_tokens":200},"last_token_usage":{"input_tokens":200,"cached_input_tokens":0,"output_tokens":0,"total_tokens":200}}}}"#
        try [meta, first].joined(separator: "\n").appending("\n")
            .write(
                to: sessionsRoot.appendingPathComponent("rollout-2026-08-23T08-00-00-a.jsonl"),
                atomically: true,
                encoding: .utf8
            )
        try [meta, divergent].joined(separator: "\n").appending("\n")
            .write(
                to: sessionsRoot.appendingPathComponent("rollout-2026-08-23T08-00-00-b.jsonl"),
                atomically: true,
                encoding: .utf8
            )

        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-23T09:00:00Z"))
        let scanner = CodexTokenActivityScanner(
            sessionRootURLs: [sessionsRoot],
            costUsageCacheRootURL: cacheRoot,
            usesAgentSignalCostUsageScanner: true
        )
        let result = scanner.scanDailyActivityResult(now: now, days: 1, progress: nil)
        XCTAssertFalse(result.isComplete)
        XCTAssertTrue(result.days.isEmpty)
    }

    func testHardLinkedDuplicateSentinelOrderingCannotDropOwnerAggregate() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hardlink-session-order-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-23T09:00:00Z"))
        for sentinelSortsFirst in [true, false] {
            let caseRoot = root.appendingPathComponent(
                sentinelSortsFirst ? "sentinel-first" : "owner-first",
                isDirectory: true
            )
            let sessionsRoot = caseRoot.appendingPathComponent("sessions", isDirectory: true)
            let cacheRoot = caseRoot.appendingPathComponent("cache", isDirectory: true)
            try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)

            let ownerName = sentinelSortsFirst ? "b-owner.jsonl" : "a-owner.jsonl"
            let sentinelName = sentinelSortsFirst ? "a-sentinel.jsonl" : "b-sentinel.jsonl"
            let ownerURL = sessionsRoot.appendingPathComponent(ownerName)
            let sentinelURL = sessionsRoot.appendingPathComponent(sentinelName)
            let sessionID = sentinelSortsFirst ? "hardlink-first" : "hardlink-last"
            try [
                #"{"timestamp":"2026-08-23T07:59:59.000Z","type":"session_meta","payload":{"id":"\#(sessionID)","originator":"Codex Desktop"}}"#,
                #"{"timestamp":"2026-08-23T08:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100},"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100}}}}"#,
            ].joined(separator: "\n").appending("\n")
                .write(to: ownerURL, atomically: true, encoding: .utf8)

            let scanner = CodexTokenActivityScanner(
                sessionRootURLs: [sessionsRoot],
                costUsageCacheRootURL: cacheRoot,
                usesAgentSignalCostUsageScanner: true
            )
            let initial = scanner.scanDailyActivityResult(now: now, days: 1, progress: nil)
            XCTAssertTrue(initial.isComplete)
            XCTAssertEqual(initial.days.compactMap(\.totalTokens).reduce(0, +), 100)

            try FileManager.default.linkItem(at: ownerURL, to: sentinelURL)
            let inventoried = scanner.scanDailyActivityResult(now: now, days: 1, progress: nil)
            XCTAssertTrue(inventoried.isComplete)
            XCTAssertEqual(inventoried.days.compactMap(\.totalTokens).reduce(0, +), 100)

            try FileHandle(forWritingTo: ownerURL).appendString(
                #"{"timestamp":"2026-08-23T08:30:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":150,"cached_input_tokens":0,"output_tokens":0,"total_tokens":150},"last_token_usage":{"input_tokens":50,"cached_input_tokens":0,"output_tokens":0,"total_tokens":50}}}}"# + "\n"
            )
            let appended = scanner.scanDailyActivityResult(now: now, days: 1, progress: nil)
            XCTAssertTrue(appended.isComplete, "sentinelSortsFirst=\(sentinelSortsFirst)")
            XCTAssertEqual(
                appended.days.compactMap(\.totalTokens).reduce(0, +),
                150,
                "sentinelSortsFirst=\(sentinelSortsFirst)"
            )

            let cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
            let copies = cache.files.values.filter { $0.sessionId == sessionID }
            XCTAssertEqual(copies.count, 2)
            XCTAssertEqual(copies.filter { $0.codexInventoryOnly != true }.count, 1)
            XCTAssertEqual(copies.filter { $0.codexInventoryOnly == true }.count, 1)
        }
    }

    func testDuplicateSentinelRewrittenAsNewSessionBecomesIndependentOwner() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("duplicate-new-session-\(UUID().uuidString)", isDirectory: true)
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let ownerURL = sessionsRoot.appendingPathComponent("a-owner.jsonl")
        let sentinelURL = sessionsRoot.appendingPathComponent("b-sentinel.jsonl")
        let sessionA = [
            #"{"timestamp":"2026-08-23T07:59:59.000Z","type":"session_meta","payload":{"id":"session-a","originator":"Codex Desktop"}}"#,
            #"{"timestamp":"2026-08-23T08:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100},"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100}}}}"#,
        ].joined(separator: "\n").appending("\n")
        try sessionA.write(to: ownerURL, atomically: true, encoding: .utf8)
        try sessionA.write(to: sentinelURL, atomically: true, encoding: .utf8)

        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-23T09:00:00Z"))
        let scanner = CodexTokenActivityScanner(
            sessionRootURLs: [sessionsRoot],
            costUsageCacheRootURL: cacheRoot,
            usesAgentSignalCostUsageScanner: true
        )
        XCTAssertEqual(
            scanner.scanDailyActivityResult(now: now, days: 1, progress: nil)
                .days.compactMap(\.totalTokens).reduce(0, +),
            100
        )

        let sessionB = [
            #"{"timestamp":"2026-08-23T08:29:59.000Z","type":"session_meta","payload":{"id":"session-b","originator":"Codex Desktop"}}"#,
            #"{"timestamp":"2026-08-23T08:30:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":50,"cached_input_tokens":0,"output_tokens":0,"total_tokens":50},"last_token_usage":{"input_tokens":50,"cached_input_tokens":0,"output_tokens":0,"total_tokens":50}}}}"#,
        ].joined(separator: "\n").appending("\n")
        let handle = try FileHandle(forWritingTo: sentinelURL)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(sessionB.utf8))
        try handle.close()

        let separated = scanner.scanDailyActivityResult(now: now, days: 1, progress: nil)
        XCTAssertTrue(separated.isComplete)
        XCTAssertEqual(separated.days.compactMap(\.totalTokens).reduce(0, +), 150)
        let cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        let owners = cache.files.values.filter { $0.codexInventoryOnly != true }
        XCTAssertEqual(Set(owners.compactMap(\.sessionId)), ["session-a", "session-b"])
    }

    func testDuplicateRewrittenToExistingSessionReconcilesAgainstGlobalOwner() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("duplicate-existing-session-\(UUID().uuidString)", isDirectory: true)
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionA = [
            #"{"timestamp":"2026-08-23T07:59:59.000Z","type":"session_meta","payload":{"id":"session-a","originator":"Codex Desktop"}}"#,
            #"{"timestamp":"2026-08-23T08:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100},"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100}}}}"#,
        ].joined(separator: "\n").appending("\n")
        let sessionB = [
            #"{"timestamp":"2026-08-23T08:09:59.000Z","type":"session_meta","payload":{"id":"session-b","originator":"Codex Desktop"}}"#,
            #"{"timestamp":"2026-08-23T08:10:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":200,"cached_input_tokens":0,"output_tokens":0,"total_tokens":200},"last_token_usage":{"input_tokens":200,"cached_input_tokens":0,"output_tokens":0,"total_tokens":200}}}}"#,
        ].joined(separator: "\n").appending("\n")
        let ownerAURL = sessionsRoot.appendingPathComponent("a-owner-a.jsonl")
        let sentinelAURL = sessionsRoot.appendingPathComponent("b-sentinel-a.jsonl")
        let ownerBURL = sessionsRoot.appendingPathComponent("c-owner-b.jsonl")
        try sessionA.write(to: ownerAURL, atomically: true, encoding: .utf8)
        try sessionA.write(to: sentinelAURL, atomically: true, encoding: .utf8)
        try sessionB.write(to: ownerBURL, atomically: true, encoding: .utf8)

        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-23T09:00:00Z"))
        let scanner = CodexTokenActivityScanner(
            sessionRootURLs: [sessionsRoot],
            costUsageCacheRootURL: cacheRoot,
            usesAgentSignalCostUsageScanner: true
        )
        XCTAssertEqual(
            scanner.scanDailyActivityResult(now: now, days: 1, progress: nil)
                .days.compactMap(\.totalTokens).reduce(0, +),
            300
        )

        let handle = try FileHandle(forWritingTo: sentinelAURL)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(sessionB.utf8))
        try handle.close()

        let reconciled = scanner.scanDailyActivityResult(now: now, days: 1, progress: nil)
        XCTAssertTrue(reconciled.isComplete)
        XCTAssertEqual(reconciled.days.compactMap(\.totalTokens).reduce(0, +), 300)
        let cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        XCTAssertEqual(
            cache.files.values.filter {
                $0.sessionId == "session-b" && $0.codexInventoryOnly != true
            }.count,
            1
        )
        XCTAssertEqual(cache.files.values.filter { $0.sessionId == "session-b" }.count, 2)
    }

    func testSimultaneousDuplicateSessionMovesUseOneGlobalReconciliationPlan() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("duplicate-global-plan-\(UUID().uuidString)", isDirectory: true)
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let metaA = #"{"timestamp":"2026-08-23T07:59:59.000Z","type":"session_meta","payload":{"id":"global-a","originator":"Codex Desktop"}}"#
        let tokenA100 = #"{"timestamp":"2026-08-23T08:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100},"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100}}}}"#
        let metaB = #"{"timestamp":"2026-08-23T08:09:59.000Z","type":"session_meta","payload":{"id":"global-b","originator":"Codex Desktop"}}"#
        let tokenB200 = #"{"timestamp":"2026-08-23T08:10:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":200,"cached_input_tokens":0,"output_tokens":0,"total_tokens":200},"last_token_usage":{"input_tokens":200,"cached_input_tokens":0,"output_tokens":0,"total_tokens":200}}}}"#
        let tokenB250 = #"{"timestamp":"2026-08-23T08:20:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":250,"cached_input_tokens":0,"output_tokens":0,"total_tokens":250},"last_token_usage":{"input_tokens":50,"cached_input_tokens":0,"output_tokens":0,"total_tokens":50}}}}"#
        let tokenB300 = #"{"timestamp":"2026-08-23T08:30:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":300,"cached_input_tokens":0,"output_tokens":0,"total_tokens":300},"last_token_usage":{"input_tokens":50,"cached_input_tokens":0,"output_tokens":0,"total_tokens":50}}}}"#

        let ownerAURL = sessionsRoot.appendingPathComponent("a-owner-a.jsonl")
        let sentinelAURL = sessionsRoot.appendingPathComponent("b-sentinel-a.jsonl")
        let ownerBURL = sessionsRoot.appendingPathComponent("c-owner-b.jsonl")
        let sentinelBURL = sessionsRoot.appendingPathComponent("d-sentinel-b.jsonl")
        let sessionA = [metaA, tokenA100].joined(separator: "\n").appending("\n")
        let sessionB = [metaB, tokenB200].joined(separator: "\n").appending("\n")
        try sessionA.write(to: ownerAURL, atomically: true, encoding: .utf8)
        try sessionA.write(to: sentinelAURL, atomically: true, encoding: .utf8)
        try sessionB.write(to: ownerBURL, atomically: true, encoding: .utf8)
        try sessionB.write(to: sentinelBURL, atomically: true, encoding: .utf8)

        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-23T09:00:00Z"))
        let scanner = CodexTokenActivityScanner(
            sessionRootURLs: [sessionsRoot],
            costUsageCacheRootURL: cacheRoot,
            usesAgentSignalCostUsageScanner: true
        )
        let initial = scanner.scanDailyActivityResult(now: now, days: 1, progress: nil)
        XCTAssertTrue(initial.isComplete)
        XCTAssertEqual(initial.days.compactMap(\.totalTokens).reduce(0, +), 300)

        let movedA = [metaB, tokenB200, tokenB250].joined(separator: "\n").appending("\n")
        let movedHandle = try FileHandle(forWritingTo: sentinelAURL)
        try movedHandle.truncate(atOffset: 0)
        try movedHandle.write(contentsOf: Data(movedA.utf8))
        try movedHandle.close()
        try FileHandle(forWritingTo: sentinelBURL).appendString(tokenB250 + "\n" + tokenB300 + "\n")

        let reconciled = scanner.scanDailyActivityResult(now: now, days: 1, progress: nil)
        XCTAssertTrue(reconciled.isComplete)
        XCTAssertEqual(reconciled.days.compactMap(\.totalTokens).reduce(0, +), 400)
        let stable = scanner.scanDailyActivityResult(now: now, days: 1, progress: nil)
        XCTAssertTrue(stable.isComplete)
        XCTAssertEqual(stable.days.compactMap(\.totalTokens).reduce(0, +), 400)

        let cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        XCTAssertEqual(
            cache.files.values.filter {
                $0.sessionId == "global-b" && $0.codexInventoryOnly != true
            }.count,
            1
        )
        XCTAssertEqual(cache.files.values.filter { $0.sessionId == "global-b" }.count, 3)
        let ownerBPath = try XCTUnwrap(
            cache.files.first(where: {
                $0.value.sessionId == "global-b" && $0.value.codexInventoryOnly != true
            })?.key
        )
        XCTAssertEqual(
            URL(fileURLWithPath: ownerBPath).standardizedFileURL.resolvingSymlinksInPath().path,
            sentinelBURL.standardizedFileURL.resolvingSymlinksInPath().path,
            "the longest globally consistent B copy must become the sole owner"
        )
    }

    func testGlobalReconciliationRecoversOldSessionWhenItsOwnerMovesAgain() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("duplicate-owner-chain-\(UUID().uuidString)", isDirectory: true)
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func tokenLine(sessionTotal: Int, delta: Int, timestamp: String) -> String {
            #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(sessionTotal),"cached_input_tokens":0,"output_tokens":0,"total_tokens":\#(sessionTotal)},"last_token_usage":{"input_tokens":\#(delta),"cached_input_tokens":0,"output_tokens":0,"total_tokens":\#(delta)}}}}"#
        }
        let metaA = #"{"timestamp":"2026-08-23T07:59:59.000Z","type":"session_meta","payload":{"id":"chain-a","originator":"Codex Desktop"}}"#
        let metaB = #"{"timestamp":"2026-08-23T08:09:59.000Z","type":"session_meta","payload":{"id":"chain-b","originator":"Codex Desktop"}}"#
        let metaC = #"{"timestamp":"2026-08-23T08:39:59.000Z","type":"session_meta","payload":{"id":"chain-c","originator":"Codex Desktop"}}"#
        let sessionA = [metaA, tokenLine(sessionTotal: 100, delta: 100, timestamp: "2026-08-23T08:00:00.000Z")]
            .joined(separator: "\n").appending("\n")
        let sessionB = [metaB, tokenLine(sessionTotal: 200, delta: 200, timestamp: "2026-08-23T08:10:00.000Z")]
            .joined(separator: "\n").appending("\n")
        let extendedB = [
            metaB,
            tokenLine(sessionTotal: 200, delta: 200, timestamp: "2026-08-23T08:10:00.000Z"),
            tokenLine(sessionTotal: 250, delta: 50, timestamp: "2026-08-23T08:20:00.000Z"),
        ].joined(separator: "\n").appending("\n")
        let sessionC = [metaC, tokenLine(sessionTotal: 50, delta: 50, timestamp: "2026-08-23T08:40:00.000Z")]
            .joined(separator: "\n").appending("\n")

        let ownerAURL = sessionsRoot.appendingPathComponent("a-owner-a.jsonl")
        let sentinelAURL = sessionsRoot.appendingPathComponent("b-sentinel-a.jsonl")
        let ownerBURL = sessionsRoot.appendingPathComponent("c-owner-b.jsonl")
        let sentinelBURL = sessionsRoot.appendingPathComponent("d-sentinel-b.jsonl")
        try sessionA.write(to: ownerAURL, atomically: true, encoding: .utf8)
        try sessionA.write(to: sentinelAURL, atomically: true, encoding: .utf8)
        try sessionB.write(to: ownerBURL, atomically: true, encoding: .utf8)
        try sessionB.write(to: sentinelBURL, atomically: true, encoding: .utf8)

        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-23T09:00:00Z"))
        let scanner = CodexTokenActivityScanner(
            sessionRootURLs: [sessionsRoot],
            costUsageCacheRootURL: cacheRoot,
            usesAgentSignalCostUsageScanner: true
        )
        let initial = scanner.scanDailyActivityResult(now: now, days: 1, progress: nil)
        XCTAssertTrue(initial.isComplete)
        XCTAssertEqual(initial.days.compactMap(\.totalTokens).reduce(0, +), 300)

        let movedSentinel = try FileHandle(forWritingTo: sentinelAURL)
        try movedSentinel.truncate(atOffset: 0)
        try movedSentinel.write(contentsOf: Data(extendedB.utf8))
        try movedSentinel.close()
        let movedOwner = try FileHandle(forWritingTo: ownerBURL)
        try movedOwner.truncate(atOffset: 0)
        try movedOwner.write(contentsOf: Data(sessionC.utf8))
        try movedOwner.close()

        let reconciled = scanner.scanDailyActivityResult(now: now, days: 1, progress: nil)
        XCTAssertTrue(reconciled.isComplete)
        XCTAssertEqual(reconciled.days.compactMap(\.totalTokens).reduce(0, +), 400)
        let stable = scanner.scanDailyActivityResult(now: now, days: 1, progress: nil)
        XCTAssertTrue(stable.isComplete)
        XCTAssertEqual(stable.days.compactMap(\.totalTokens).reduce(0, +), 400)

        let cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        for sessionId in ["chain-a", "chain-b", "chain-c"] {
            XCTAssertEqual(
                cache.files.values.filter {
                    $0.sessionId == sessionId && $0.codexInventoryOnly != true
                }.count,
                1,
                "\(sessionId) must have exactly one aggregate owner"
            )
        }
    }

    func testRepairedNoMetadataSentinelCanSafelyExtendExistingSessionOwner() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("repaired-duplicate-sentinel-\(UUID().uuidString)", isDirectory: true)
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let meta = #"{"timestamp":"2026-08-23T07:59:59.000Z","type":"session_meta","payload":{"id":"repair-session","originator":"Codex Desktop"}}"#
        let first = #"{"timestamp":"2026-08-23T08:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100},"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100}}}}"#
        let extensionLine = #"{"timestamp":"2026-08-23T08:30:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":150,"cached_input_tokens":0,"output_tokens":0,"total_tokens":150},"last_token_usage":{"input_tokens":50,"cached_input_tokens":0,"output_tokens":0,"total_tokens":50}}}}"#
        let ownerURL = sessionsRoot.appendingPathComponent("a-owner.jsonl")
        let deferredURL = sessionsRoot.appendingPathComponent("b-deferred.jsonl")
        try [meta, first].joined(separator: "\n").appending("\n")
            .write(to: ownerURL, atomically: true, encoding: .utf8)
        try (#"{"timestamp":"2026-08-23T08:10:00.000Z","type":"event_msg","payload":{"type":"notice"}}"# + "\n")
            .write(to: deferredURL, atomically: true, encoding: .utf8)

        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-23T09:00:00Z"))
        let scanner = CodexTokenActivityScanner(
            sessionRootURLs: [sessionsRoot],
            costUsageCacheRootURL: cacheRoot,
            usesAgentSignalCostUsageScanner: true
        )
        XCTAssertEqual(
            scanner.scanDailyActivityResult(now: now, days: 1, progress: nil)
                .days.compactMap(\.totalTokens).reduce(0, +),
            100
        )

        let repaired = [meta, first, extensionLine].joined(separator: "\n").appending("\n")
        let handle = try FileHandle(forWritingTo: deferredURL)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(repaired.utf8))
        try handle.close()

        let promoted = scanner.scanDailyActivityResult(now: now, days: 1, progress: nil)
        XCTAssertTrue(promoted.isComplete)
        XCTAssertEqual(promoted.days.compactMap(\.totalTokens).reduce(0, +), 150)
        let cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        XCTAssertEqual(
            cache.files.values.filter {
                $0.sessionId == "repair-session" && $0.codexInventoryOnly != true
            }.count,
            1
        )
    }

    func testTwoNoMetadataSentinelsRepairThroughOneGlobalPlan() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("repaired-sentinel-chain-\(UUID().uuidString)", isDirectory: true)
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let meta = #"{"timestamp":"2026-08-23T07:59:59.000Z","type":"session_meta","payload":{"id":"repair-chain","originator":"Codex Desktop"}}"#
        let token100 = #"{"timestamp":"2026-08-23T08:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100},"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100}}}}"#
        let token150 = #"{"timestamp":"2026-08-23T08:20:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":150,"cached_input_tokens":0,"output_tokens":0,"total_tokens":150},"last_token_usage":{"input_tokens":50,"cached_input_tokens":0,"output_tokens":0,"total_tokens":50}}}}"#
        let token200 = #"{"timestamp":"2026-08-23T08:30:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":200,"cached_input_tokens":0,"output_tokens":0,"total_tokens":200},"last_token_usage":{"input_tokens":50,"cached_input_tokens":0,"output_tokens":0,"total_tokens":50}}}}"#
        let ownerURL = sessionsRoot.appendingPathComponent("a-owner.jsonl")
        let shorterURL = sessionsRoot.appendingPathComponent("b-shorter-deferred.jsonl")
        let longerURL = sessionsRoot.appendingPathComponent("c-longer-deferred.jsonl")
        try [meta, token100].joined(separator: "\n").appending("\n")
            .write(to: ownerURL, atomically: true, encoding: .utf8)
        let noMetadata = #"{"timestamp":"2026-08-23T08:10:00.000Z","type":"event_msg","payload":{"type":"notice"}}"# + "\n"
        try noMetadata.write(to: shorterURL, atomically: true, encoding: .utf8)
        try noMetadata.write(to: longerURL, atomically: true, encoding: .utf8)

        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-23T09:00:00Z"))
        let scanner = CodexTokenActivityScanner(
            sessionRootURLs: [sessionsRoot],
            costUsageCacheRootURL: cacheRoot,
            usesAgentSignalCostUsageScanner: true
        )
        let initial = scanner.scanDailyActivityResult(now: now, days: 1, progress: nil)
        XCTAssertTrue(initial.isComplete)
        XCTAssertEqual(initial.days.compactMap(\.totalTokens).reduce(0, +), 100)

        let shorter = [meta, token100, token150].joined(separator: "\n").appending("\n")
        let longer = [meta, token100, token150, token200].joined(separator: "\n").appending("\n")
        for (url, contents) in [(shorterURL, shorter), (longerURL, longer)] {
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: Data(contents.utf8))
            try handle.close()
        }

        let repaired = scanner.scanDailyActivityResult(now: now, days: 1, progress: nil)
        XCTAssertTrue(repaired.isComplete)
        XCTAssertEqual(repaired.days.compactMap(\.totalTokens).reduce(0, +), 200)
        let stable = scanner.scanDailyActivityResult(now: now, days: 1, progress: nil)
        XCTAssertTrue(stable.isComplete)
        XCTAssertEqual(stable.days.compactMap(\.totalTokens).reduce(0, +), 200)
        let cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        XCTAssertEqual(
            cache.files.values.filter {
                $0.sessionId == "repair-chain" && $0.codexInventoryOnly != true
            }.count,
            1
        )
    }

    func testUnchangedSentinelPromotesWhenFormerOwnerMovesToNewSession() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("stable-sentinel-promotion-\(UUID().uuidString)", isDirectory: true)
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionB = [
            #"{"timestamp":"2026-08-23T07:59:59.000Z","type":"session_meta","payload":{"id":"stable-b","originator":"Codex Desktop"}}"#,
            #"{"timestamp":"2026-08-23T08:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":200,"cached_input_tokens":0,"output_tokens":0,"total_tokens":200},"last_token_usage":{"input_tokens":200,"cached_input_tokens":0,"output_tokens":0,"total_tokens":200}}}}"#,
        ].joined(separator: "\n").appending("\n")
        let sessionC = [
            #"{"timestamp":"2026-08-23T08:29:59.000Z","type":"session_meta","payload":{"id":"moved-c","originator":"Codex Desktop"}}"#,
            #"{"timestamp":"2026-08-23T08:30:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":50,"cached_input_tokens":0,"output_tokens":0,"total_tokens":50},"last_token_usage":{"input_tokens":50,"cached_input_tokens":0,"output_tokens":0,"total_tokens":50}}}}"#,
        ].joined(separator: "\n").appending("\n")
        let ownerURL = sessionsRoot.appendingPathComponent("a-former-owner.jsonl")
        let sentinelURL = sessionsRoot.appendingPathComponent("b-stable-sentinel.jsonl")
        try sessionB.write(to: ownerURL, atomically: true, encoding: .utf8)
        try sessionB.write(to: sentinelURL, atomically: true, encoding: .utf8)

        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-23T09:00:00Z"))
        let scanner = CodexTokenActivityScanner(
            sessionRootURLs: [sessionsRoot],
            costUsageCacheRootURL: cacheRoot,
            usesAgentSignalCostUsageScanner: true
        )
        let initial = scanner.scanDailyActivityResult(now: now, days: 1, progress: nil)
        XCTAssertTrue(initial.isComplete)
        XCTAssertEqual(initial.days.compactMap(\.totalTokens).reduce(0, +), 200)

        let handle = try FileHandle(forWritingTo: ownerURL)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(sessionC.utf8))
        try handle.close()

        let reconciled = scanner.scanDailyActivityResult(now: now, days: 1, progress: nil)
        XCTAssertTrue(reconciled.isComplete)
        XCTAssertEqual(reconciled.days.compactMap(\.totalTokens).reduce(0, +), 250)
        let stable = scanner.scanDailyActivityResult(now: now, days: 1, progress: nil)
        XCTAssertTrue(stable.isComplete)
        XCTAssertEqual(stable.days.compactMap(\.totalTokens).reduce(0, +), 250)
        let cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        XCTAssertEqual(
            Set(cache.files.values.filter { $0.codexInventoryOnly != true }.compactMap(\.sessionId)),
            ["stable-b", "moved-c"]
        )
    }

    func testDuplicateOwnerPromotionPreservesRetainedHistoryOutsideCurrentWindow() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("duplicate-retained-history-\(UUID().uuidString)", isDirectory: true)
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let lines = [
            #"{"timestamp":"2025-09-01T07:59:59.000Z","type":"session_meta","payload":{"id":"retained-history","originator":"Codex Desktop"}}"#,
            #"{"timestamp":"2025-09-01T08:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100},"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100}}}}"#,
            #"{"timestamp":"2026-08-23T08:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":150,"cached_input_tokens":0,"output_tokens":0,"total_tokens":150},"last_token_usage":{"input_tokens":50,"cached_input_tokens":0,"output_tokens":0,"total_tokens":50}}}}"#,
        ]
        let extensionLine = #"{"timestamp":"2026-08-23T08:30:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":200,"cached_input_tokens":0,"output_tokens":0,"total_tokens":200},"last_token_usage":{"input_tokens":50,"cached_input_tokens":0,"output_tokens":0,"total_tokens":50}}}}"#
        let ownerURL = sessionsRoot.appendingPathComponent("a-owner.jsonl")
        let sentinelURL = sessionsRoot.appendingPathComponent("b-sentinel.jsonl")
        let original = lines.joined(separator: "\n").appending("\n")
        try original.write(to: ownerURL, atomically: true, encoding: .utf8)
        try original.write(to: sentinelURL, atomically: true, encoding: .utf8)

        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-23T09:00:00Z"))
        let scanner = CodexTokenActivityScanner(
            sessionRootURLs: [sessionsRoot],
            costUsageCacheRootURL: cacheRoot,
            usesAgentSignalCostUsageScanner: true
        )
        let historical = scanner.scanDailyActivityResult(now: now, days: 365, progress: nil)
        XCTAssertTrue(historical.isComplete)
        XCTAssertEqual(historical.days.compactMap(\.totalTokens).reduce(0, +), 150)

        try FileHandle(forWritingTo: sentinelURL).appendString(extensionLine + "\n")
        let today = scanner.scanDailyActivityResult(now: now, days: 1, progress: nil)
        XCTAssertTrue(today.isComplete)
        XCTAssertEqual(today.days.compactMap(\.totalTokens).reduce(0, +), 100)

        let historicalAgain = scanner.scanDailyActivityResult(now: now, days: 365, progress: nil)
        XCTAssertTrue(historicalAgain.isComplete)
        XCTAssertEqual(historicalAgain.days.compactMap(\.totalTokens).reduce(0, +), 200)
    }

    func testSamePathGenerationReplacementPreservesRetainedHistory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("replacement-retained-history-\(UUID().uuidString)", isDirectory: true)
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let originalLines = [
            #"{"timestamp":"2025-09-01T07:59:59.000Z","type":"session_meta","payload":{"id":"same-path-history","originator":"Codex Desktop"}}"#,
            #"{"timestamp":"2025-09-01T08:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100},"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100}}}}"#,
            #"{"timestamp":"2026-08-23T08:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":150,"cached_input_tokens":0,"output_tokens":0,"total_tokens":150},"last_token_usage":{"input_tokens":50,"cached_input_tokens":0,"output_tokens":0,"total_tokens":50}}}}"#,
        ]
        let replacementLine = #"{"timestamp":"2026-08-23T08:30:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":200,"cached_input_tokens":0,"output_tokens":0,"total_tokens":200},"last_token_usage":{"input_tokens":50,"cached_input_tokens":0,"output_tokens":0,"total_tokens":50}}}}"#
        let sessionURL = sessionsRoot.appendingPathComponent("rollout.jsonl")
        try originalLines.joined(separator: "\n").appending("\n")
            .write(to: sessionURL, atomically: true, encoding: .utf8)

        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-23T09:00:00Z"))
        let scanner = CodexTokenActivityScanner(
            sessionRootURLs: [sessionsRoot],
            costUsageCacheRootURL: cacheRoot,
            usesAgentSignalCostUsageScanner: true
        )
        let historical = scanner.scanDailyActivityResult(now: now, days: 365, progress: nil)
        XCTAssertTrue(historical.isComplete)
        XCTAssertEqual(historical.days.compactMap(\.totalTokens).reduce(0, +), 150)
        let oldGeneration = CostUsageScanner.codexFileMetadata(fileURL: sessionURL).fileId

        try (originalLines + [replacementLine]).joined(separator: "\n").appending("\n")
            .write(to: sessionURL, atomically: true, encoding: .utf8)
        let newGeneration = CostUsageScanner.codexFileMetadata(fileURL: sessionURL).fileId
        XCTAssertNotEqual(oldGeneration, newGeneration)

        let today = scanner.scanDailyActivityResult(now: now, days: 1, progress: nil)
        XCTAssertTrue(today.isComplete)
        XCTAssertEqual(today.days.compactMap(\.totalTokens).reduce(0, +), 100)
        let historicalAgain = scanner.scanDailyActivityResult(now: now, days: 365, progress: nil)
        XCTAssertTrue(historicalAgain.isComplete)
        XCTAssertEqual(historicalAgain.days.compactMap(\.totalTokens).reduce(0, +), 200)
    }

    func testHardLinkOwnerRenameAndDuplicatePromotionPreserveRetainedHistory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hardlink-rename-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let originalLines = [
            #"{"timestamp":"2025-09-01T07:59:59.000Z","type":"session_meta","payload":{"id":"hardlink-history","originator":"Codex Desktop"}}"#,
            #"{"timestamp":"2025-09-01T08:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100},"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100}}}}"#,
            #"{"timestamp":"2026-08-23T08:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":150,"cached_input_tokens":0,"output_tokens":0,"total_tokens":150},"last_token_usage":{"input_tokens":50,"cached_input_tokens":0,"output_tokens":0,"total_tokens":50}}}}"#,
        ]
        let extensionLine = #"{"timestamp":"2026-08-23T08:30:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":200,"cached_input_tokens":0,"output_tokens":0,"total_tokens":200},"last_token_usage":{"input_tokens":50,"cached_input_tokens":0,"output_tokens":0,"total_tokens":50}}}}"#
        let original = originalLines.joined(separator: "\n").appending("\n")
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-23T09:00:00Z"))

        for sentinelSortsFirst in [false, true] {
            let caseRoot = root.appendingPathComponent(
                sentinelSortsFirst ? "sentinel-first" : "owner-first",
                isDirectory: true
            )
            let sessionsRoot = caseRoot.appendingPathComponent("sessions", isDirectory: true)
            let cacheRoot = caseRoot.appendingPathComponent("cache", isDirectory: true)
            try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
            let ownerURL = sessionsRoot.appendingPathComponent(
                sentinelSortsFirst ? "b-owner.jsonl" : "a-owner.jsonl"
            )
            let hardlinkURL = sessionsRoot.appendingPathComponent(
                sentinelSortsFirst ? "a-sentinel.jsonl" : "b-sentinel.jsonl"
            )
            let extendableURL = sessionsRoot.appendingPathComponent("c-extendable.jsonl")
            try original.write(to: ownerURL, atomically: true, encoding: .utf8)

            let scanner = CodexTokenActivityScanner(
                sessionRootURLs: [sessionsRoot],
                costUsageCacheRootURL: cacheRoot,
                usesAgentSignalCostUsageScanner: true
            )
            let initial = scanner.scanDailyActivityResult(now: now, days: 365, progress: nil)
            XCTAssertTrue(initial.isComplete, "sentinelSortsFirst=\(sentinelSortsFirst)")
            XCTAssertEqual(
                initial.days.compactMap(\.totalTokens).reduce(0, +),
                150,
                "sentinelSortsFirst=\(sentinelSortsFirst)"
            )

            try FileManager.default.linkItem(at: ownerURL, to: hardlinkURL)
            try original.write(to: extendableURL, atomically: true, encoding: .utf8)
            let inventoried = scanner.scanDailyActivityResult(now: now, days: 365, progress: nil)
            XCTAssertTrue(inventoried.isComplete, "sentinelSortsFirst=\(sentinelSortsFirst)")
            XCTAssertEqual(inventoried.days.compactMap(\.totalTokens).reduce(0, +), 150)

            let renamedOwnerURL = sessionsRoot.appendingPathComponent("z-renamed-owner.jsonl")
            try FileManager.default.moveItem(at: ownerURL, to: renamedOwnerURL)
            try FileHandle(forWritingTo: extendableURL).appendString(extensionLine + "\n")

            let today = scanner.scanDailyActivityResult(now: now, days: 1, progress: nil)
            XCTAssertTrue(today.isComplete, "sentinelSortsFirst=\(sentinelSortsFirst)")
            XCTAssertEqual(
                today.days.compactMap(\.totalTokens).reduce(0, +),
                100,
                "sentinelSortsFirst=\(sentinelSortsFirst)"
            )
            let historical = scanner.scanDailyActivityResult(now: now, days: 365, progress: nil)
            XCTAssertTrue(historical.isComplete, "sentinelSortsFirst=\(sentinelSortsFirst)")
            XCTAssertEqual(
                historical.days.compactMap(\.totalTokens).reduce(0, +),
                200,
                "sentinelSortsFirst=\(sentinelSortsFirst)"
            )
        }
    }

    func testOwnerRenameOverStaleSentinelPreservesRetainedHistory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rename-over-stale-sentinel-\(UUID().uuidString)", isDirectory: true)
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let ownerURL = sessionsRoot.appendingPathComponent("a-owner.jsonl")
        let staleSentinelURL = sessionsRoot.appendingPathComponent("z-stale-sentinel.jsonl")
        let ownerContents = [
            #"{"timestamp":"2025-09-01T07:59:59.000Z","type":"session_meta","payload":{"id":"rename-over-sentinel","originator":"Codex Desktop"}}"#,
            #"{"timestamp":"2025-09-01T08:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100},"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100}}}}"#,
            #"{"timestamp":"2026-08-23T08:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":150,"cached_input_tokens":0,"output_tokens":0,"total_tokens":150},"last_token_usage":{"input_tokens":50,"cached_input_tokens":0,"output_tokens":0,"total_tokens":50}}}}"#,
        ].joined(separator: "\n").appending("\n")
        try ownerContents.write(to: ownerURL, atomically: true, encoding: .utf8)
        try (#"{"timestamp":"2026-08-23T08:10:00.000Z","type":"event_msg","payload":{"type":"notice"}}"# + "\n")
            .write(to: staleSentinelURL, atomically: true, encoding: .utf8)

        let ownerGeneration = CostUsageScanner.codexFileMetadata(fileURL: ownerURL).fileId
        let staleGeneration = CostUsageScanner.codexFileMetadata(fileURL: staleSentinelURL).fileId
        XCTAssertNotEqual(ownerGeneration, staleGeneration)

        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-23T09:00:00Z"))
        let scanner = CodexTokenActivityScanner(
            sessionRootURLs: [sessionsRoot],
            costUsageCacheRootURL: cacheRoot,
            usesAgentSignalCostUsageScanner: true
        )
        let historical = scanner.scanDailyActivityResult(now: now, days: 365, progress: nil)
        XCTAssertTrue(historical.isComplete)
        XCTAssertEqual(historical.days.compactMap(\.totalTokens).reduce(0, +), 150)
        let initialCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        XCTAssertEqual(
            initialCache.files.first(where: {
                URL(fileURLWithPath: $0.key).lastPathComponent == staleSentinelURL.lastPathComponent
            })?.value.codexInventoryOnly,
            true
        )

        try FileManager.default.removeItem(at: staleSentinelURL)
        try FileManager.default.moveItem(at: ownerURL, to: staleSentinelURL)
        XCTAssertEqual(
            CostUsageScanner.codexFileMetadata(fileURL: staleSentinelURL).fileId,
            ownerGeneration
        )

        let today = scanner.scanDailyActivityResult(now: now, days: 1, progress: nil)
        XCTAssertTrue(today.isComplete)
        XCTAssertEqual(today.days.compactMap(\.totalTokens).reduce(0, +), 50)
        let historicalAgain = scanner.scanDailyActivityResult(now: now, days: 365, progress: nil)
        XCTAssertTrue(historicalAgain.isComplete)
        XCTAssertEqual(historicalAgain.days.compactMap(\.totalTokens).reduce(0, +), 150)

        let finalCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        XCTAssertFalse(finalCache.files.keys.contains(where: {
            URL(fileURLWithPath: $0).lastPathComponent == ownerURL.lastPathComponent
        }))
        let finalOwner = finalCache.files.first(where: {
            URL(fileURLWithPath: $0.key).lastPathComponent == staleSentinelURL.lastPathComponent
        })?.value
        XCTAssertEqual(finalOwner?.sessionId, "rename-over-sentinel")
        XCTAssertNotEqual(finalOwner?.codexInventoryOnly, true)
    }

    func testHardLinkSentinelInheritsDeletedOwnerLedger() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hardlink-sentinel-ledger-\(UUID().uuidString)", isDirectory: true)
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let ownerURL = sessionsRoot.appendingPathComponent("a-owner.jsonl")
        let sentinelURL = sessionsRoot.appendingPathComponent("b-hardlink-sentinel.jsonl")
        try [
            #"{"timestamp":"2025-09-01T07:59:59.000Z","type":"session_meta","payload":{"id":"hardlink-ledger","originator":"Codex Desktop"}}"#,
            #"{"timestamp":"2025-09-01T08:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100},"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100}}}}"#,
            #"{"timestamp":"2026-08-23T08:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":150,"cached_input_tokens":0,"output_tokens":0,"total_tokens":150},"last_token_usage":{"input_tokens":50,"cached_input_tokens":0,"output_tokens":0,"total_tokens":50}}}}"#,
        ].joined(separator: "\n").appending("\n")
            .write(to: ownerURL, atomically: true, encoding: .utf8)
        try FileManager.default.linkItem(at: ownerURL, to: sentinelURL)

        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-23T09:00:00Z"))
        let scanner = CodexTokenActivityScanner(
            sessionRootURLs: [sessionsRoot],
            costUsageCacheRootURL: cacheRoot,
            usesAgentSignalCostUsageScanner: true
        )
        let historical = scanner.scanDailyActivityResult(now: now, days: 365, progress: nil)
        XCTAssertTrue(historical.isComplete)
        XCTAssertEqual(historical.days.compactMap(\.totalTokens).reduce(0, +), 150)

        let initialCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        let initialOwner = initialCache.files.first(where: {
            URL(fileURLWithPath: $0.key).lastPathComponent == ownerURL.lastPathComponent
        })?.value
        let initialSentinel = initialCache.files.first(where: {
            URL(fileURLWithPath: $0.key).lastPathComponent == sentinelURL.lastPathComponent
        })?.value
        XCTAssertNotEqual(initialOwner?.codexInventoryOnly, true)
        XCTAssertEqual(initialSentinel?.codexInventoryOnly, true)

        try FileManager.default.removeItem(at: ownerURL)
        let today = scanner.scanDailyActivityResult(now: now, days: 1, progress: nil)
        XCTAssertTrue(today.isComplete)
        XCTAssertEqual(today.days.compactMap(\.totalTokens).reduce(0, +), 50)
        let historicalAgain = scanner.scanDailyActivityResult(now: now, days: 365, progress: nil)
        XCTAssertTrue(historicalAgain.isComplete)
        XCTAssertEqual(historicalAgain.days.compactMap(\.totalTokens).reduce(0, +), 150)

        let finalCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        XCTAssertFalse(finalCache.files.keys.contains(where: {
            URL(fileURLWithPath: $0).lastPathComponent == ownerURL.lastPathComponent
        }))
        let finalOwner = finalCache.files.first(where: {
            URL(fileURLWithPath: $0.key).lastPathComponent == sentinelURL.lastPathComponent
        })?.value
        XCTAssertEqual(finalOwner?.sessionId, "hardlink-ledger")
        XCTAssertNotEqual(finalOwner?.codexInventoryOnly, true)
    }

    func testSwappedOwnerPathsKeepBothRetainedLedgers() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("swapped-owner-ledgers-\(UUID().uuidString)", isDirectory: true)
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let firstURL = sessionsRoot.appendingPathComponent("a-first.jsonl")
        let secondURL = sessionsRoot.appendingPathComponent("b-second.jsonl")
        try [
            #"{"timestamp":"2025-09-01T07:59:59.000Z","type":"session_meta","payload":{"id":"swap-session-a","originator":"Codex Desktop"}}"#,
            #"{"timestamp":"2025-09-01T08:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100},"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100}}}}"#,
            #"{"timestamp":"2026-08-23T08:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":150,"cached_input_tokens":0,"output_tokens":0,"total_tokens":150},"last_token_usage":{"input_tokens":50,"cached_input_tokens":0,"output_tokens":0,"total_tokens":50}}}}"#,
        ].joined(separator: "\n").appending("\n")
            .write(to: firstURL, atomically: true, encoding: .utf8)
        try [
            #"{"timestamp":"2025-09-01T07:59:59.000Z","type":"session_meta","payload":{"id":"swap-session-b","originator":"Codex Desktop"}}"#,
            #"{"timestamp":"2025-09-01T08:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":200,"cached_input_tokens":0,"output_tokens":0,"total_tokens":200},"last_token_usage":{"input_tokens":200,"cached_input_tokens":0,"output_tokens":0,"total_tokens":200}}}}"#,
            #"{"timestamp":"2026-08-23T08:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":250,"cached_input_tokens":0,"output_tokens":0,"total_tokens":250},"last_token_usage":{"input_tokens":50,"cached_input_tokens":0,"output_tokens":0,"total_tokens":50}}}}"#,
        ].joined(separator: "\n").appending("\n")
            .write(to: secondURL, atomically: true, encoding: .utf8)

        let firstGeneration = CostUsageScanner.codexFileMetadata(fileURL: firstURL).fileId
        let secondGeneration = CostUsageScanner.codexFileMetadata(fileURL: secondURL).fileId
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-23T09:00:00Z"))
        let scanner = CodexTokenActivityScanner(
            sessionRootURLs: [sessionsRoot],
            costUsageCacheRootURL: cacheRoot,
            usesAgentSignalCostUsageScanner: true
        )
        let historical = scanner.scanDailyActivityResult(now: now, days: 365, progress: nil)
        XCTAssertTrue(historical.isComplete)
        XCTAssertEqual(historical.days.compactMap(\.totalTokens).reduce(0, +), 400)

        let temporaryURL = sessionsRoot.appendingPathComponent("swap.tmp")
        try FileManager.default.moveItem(at: firstURL, to: temporaryURL)
        try FileManager.default.moveItem(at: secondURL, to: firstURL)
        try FileManager.default.moveItem(at: temporaryURL, to: secondURL)
        XCTAssertEqual(CostUsageScanner.codexFileMetadata(fileURL: firstURL).fileId, secondGeneration)
        XCTAssertEqual(CostUsageScanner.codexFileMetadata(fileURL: secondURL).fileId, firstGeneration)

        let today = scanner.scanDailyActivityResult(now: now, days: 1, progress: nil)
        XCTAssertTrue(today.isComplete)
        XCTAssertEqual(today.days.compactMap(\.totalTokens).reduce(0, +), 100)
        let historicalAgain = scanner.scanDailyActivityResult(now: now, days: 365, progress: nil)
        XCTAssertTrue(historicalAgain.isComplete)
        XCTAssertEqual(historicalAgain.days.compactMap(\.totalTokens).reduce(0, +), 400)

        let cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        XCTAssertEqual(
            cache.files.values.filter {
                $0.sessionId == "swap-session-a" && $0.codexInventoryOnly != true
            }.count,
            1
        )
        XCTAssertEqual(
            cache.files.values.filter {
                $0.sessionId == "swap-session-b" && $0.codexInventoryOnly != true
            }.count,
            1
        )
    }

    func testDeletedOwnerUsesPriorFrontierToChooseExactSentinel() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("deleted-owner-frontier-\(UUID().uuidString)", isDirectory: true)
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let meta = #"{"timestamp":"2025-09-01T07:59:59.000Z","type":"session_meta","payload":{"id":"deleted-owner-session","originator":"Codex Desktop"}}"#
        let oldToken = #"{"timestamp":"2025-09-01T08:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100},"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100}}}}"#
        let todayToken = #"{"timestamp":"2026-08-23T08:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":150,"cached_input_tokens":0,"output_tokens":0,"total_tokens":150},"last_token_usage":{"input_tokens":50,"cached_input_tokens":0,"output_tokens":0,"total_tokens":50}}}}"#
        let original = [meta, oldToken, todayToken].joined(separator: "\n").appending("\n")
        let ownerURL = sessionsRoot.appendingPathComponent("a-owner.jsonl")
        let exactURL = sessionsRoot.appendingPathComponent("b-exact.jsonl")
        let divergentURL = sessionsRoot.appendingPathComponent("c-divergent.jsonl")
        for url in [ownerURL, exactURL, divergentURL] {
            try original.write(to: url, atomically: true, encoding: .utf8)
        }

        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-23T09:00:00Z"))
        let scanner = CodexTokenActivityScanner(
            sessionRootURLs: [sessionsRoot],
            costUsageCacheRootURL: cacheRoot,
            usesAgentSignalCostUsageScanner: true
        )
        let initial = scanner.scanDailyActivityResult(now: now, days: 365, progress: nil)
        XCTAssertTrue(initial.isComplete)
        XCTAssertEqual(initial.days.compactMap(\.totalTokens).reduce(0, +), 150)

        let divergentGeneration = CostUsageScanner.codexFileMetadata(fileURL: divergentURL).fileId
        try FileManager.default.removeItem(at: ownerURL)
        let divergent = [
            meta,
            #"{"timestamp":"2026-08-23T08:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":50,"cached_input_tokens":0,"output_tokens":0,"total_tokens":50},"last_token_usage":{"input_tokens":50,"cached_input_tokens":0,"output_tokens":0,"total_tokens":50}}}}"#,
        ].joined(separator: "\n").appending("\n")
        let divergentHandle = try FileHandle(forWritingTo: divergentURL)
        try divergentHandle.truncate(atOffset: 0)
        try divergentHandle.write(contentsOf: Data(divergent.utf8))
        try divergentHandle.close()
        XCTAssertEqual(
            CostUsageScanner.codexFileMetadata(fileURL: divergentURL).fileId,
            divergentGeneration
        )

        let today = scanner.scanDailyActivityResult(now: now, days: 1, progress: nil)
        XCTAssertTrue(today.isComplete)
        XCTAssertEqual(today.days.compactMap(\.totalTokens).reduce(0, +), 50)
        let historical = scanner.scanDailyActivityResult(now: now, days: 365, progress: nil)
        XCTAssertTrue(historical.isComplete)
        XCTAssertEqual(historical.days.compactMap(\.totalTokens).reduce(0, +), 150)

        let cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        let exactUsage = cache.files.first(where: {
            URL(fileURLWithPath: $0.key).lastPathComponent == exactURL.lastPathComponent
        })?.value
        let divergentUsage = cache.files.first(where: {
            URL(fileURLWithPath: $0.key).lastPathComponent == divergentURL.lastPathComponent
        })?.value
        XCTAssertNotEqual(exactUsage?.codexInventoryOnly, true)
        XCTAssertEqual(divergentUsage?.codexInventoryOnly, true)
        XCTAssertEqual(divergentUsage?.codexDuplicateQuarantined, true)
    }

    func testNewlyDivergentSameGenerationSentinelStaysQuarantined() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("same-generation-quarantine-\(UUID().uuidString)", isDirectory: true)
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let meta = #"{"timestamp":"2025-09-01T07:59:59.000Z","type":"session_meta","payload":{"id":"same-generation-session","originator":"Codex Desktop"}}"#
        let oldToken = #"{"timestamp":"2025-09-01T08:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100},"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100}}}}"#
        let todayToken = #"{"timestamp":"2026-08-23T08:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":150,"cached_input_tokens":0,"output_tokens":0,"total_tokens":150},"last_token_usage":{"input_tokens":50,"cached_input_tokens":0,"output_tokens":0,"total_tokens":50}}}}"#
        let original = [meta, oldToken, todayToken].joined(separator: "\n").appending("\n")
        let ownerURL = sessionsRoot.appendingPathComponent("a-owner.jsonl")
        let exactURL = sessionsRoot.appendingPathComponent("b-exact.jsonl")
        let divergentURL = sessionsRoot.appendingPathComponent("c-divergent.jsonl")
        for url in [ownerURL, exactURL, divergentURL] {
            try original.write(to: url, atomically: true, encoding: .utf8)
        }

        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-23T09:00:00Z"))
        let scanner = CodexTokenActivityScanner(
            sessionRootURLs: [sessionsRoot],
            costUsageCacheRootURL: cacheRoot,
            usesAgentSignalCostUsageScanner: true
        )
        let initial = scanner.scanDailyActivityResult(now: now, days: 365, progress: nil)
        XCTAssertTrue(initial.isComplete)
        XCTAssertEqual(initial.days.compactMap(\.totalTokens).reduce(0, +), 150)

        let divergentGeneration = CostUsageScanner.codexFileMetadata(fileURL: divergentURL).fileId
        let divergent = [
            meta,
            #"{"timestamp":"2026-08-23T08:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":50,"cached_input_tokens":0,"output_tokens":0,"total_tokens":50},"last_token_usage":{"input_tokens":50,"cached_input_tokens":0,"output_tokens":0,"total_tokens":50}}}}"#,
        ].joined(separator: "\n").appending("\n")
        let divergentHandle = try FileHandle(forWritingTo: divergentURL)
        try divergentHandle.truncate(atOffset: 0)
        try divergentHandle.write(contentsOf: Data(divergent.utf8))
        try divergentHandle.close()
        XCTAssertEqual(
            CostUsageScanner.codexFileMetadata(fileURL: divergentURL).fileId,
            divergentGeneration
        )
        try [
            #"{"timestamp":"2026-08-23T08:29:59.000Z","type":"session_meta","payload":{"id":"unrelated-session","originator":"Codex Desktop"}}"#,
            #"{"timestamp":"2026-08-23T08:30:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":20,"cached_input_tokens":0,"output_tokens":0,"total_tokens":20},"last_token_usage":{"input_tokens":20,"cached_input_tokens":0,"output_tokens":0,"total_tokens":20}}}}"#,
        ].joined(separator: "\n").appending("\n")
            .write(
                to: sessionsRoot.appendingPathComponent("d-unrelated.jsonl"),
                atomically: true,
                encoding: .utf8
            )

        let today = scanner.scanDailyActivityResult(now: now, days: 1, progress: nil)
        XCTAssertTrue(today.isComplete)
        XCTAssertEqual(today.days.compactMap(\.totalTokens).reduce(0, +), 70)
        let historical = scanner.scanDailyActivityResult(now: now, days: 365, progress: nil)
        XCTAssertTrue(historical.isComplete)
        XCTAssertEqual(historical.days.compactMap(\.totalTokens).reduce(0, +), 170)

        let cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        let divergentUsage = cache.files.first(where: {
            URL(fileURLWithPath: $0.key).lastPathComponent == divergentURL.lastPathComponent
        })?.value
        XCTAssertEqual(divergentUsage?.codexInventoryOnly, true)
        XCTAssertEqual(divergentUsage?.codexDuplicateQuarantined, true)
        let stable = scanner.scanDailyActivityResult(now: now, days: 365, progress: nil)
        XCTAssertTrue(stable.isComplete)
        XCTAssertEqual(stable.days.compactMap(\.totalTokens).reduce(0, +), 170)
    }

    func testShortDuplicateCannotReplaceCorruptedOwnerWithoutCoveringCommittedFrontier() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("short-duplicate-frontier-\(UUID().uuidString)", isDirectory: true)
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let meta = #"{"timestamp":"2026-08-23T07:59:59.000Z","type":"session_meta","payload":{"id":"frontier-guard","originator":"Codex Desktop"}}"#
        let first = #"{"timestamp":"2026-08-23T08:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100},"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100}}}}"#
        let second = #"{"timestamp":"2026-08-23T08:20:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":150,"cached_input_tokens":0,"output_tokens":0,"total_tokens":150},"last_token_usage":{"input_tokens":50,"cached_input_tokens":0,"output_tokens":0,"total_tokens":50}}}}"#
        let ownerURL = sessionsRoot.appendingPathComponent("a-owner.jsonl")
        let shortURL = sessionsRoot.appendingPathComponent("b-short.jsonl")
        try [meta, first, second].joined(separator: "\n").appending("\n")
            .write(to: ownerURL, atomically: true, encoding: .utf8)
        try [meta, first].joined(separator: "\n").appending("\n")
            .write(to: shortURL, atomically: true, encoding: .utf8)

        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-23T09:00:00Z"))
        let scanner = CodexTokenActivityScanner(
            sessionRootURLs: [sessionsRoot],
            costUsageCacheRootURL: cacheRoot,
            usesAgentSignalCostUsageScanner: true
        )
        let initial = scanner.scanDailyActivityResult(now: now, days: 1, progress: nil)
        XCTAssertTrue(initial.isComplete)
        XCTAssertEqual(initial.days.compactMap(\.totalTokens).reduce(0, +), 150)

        let handle = try FileHandle(forWritingTo: ownerURL)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(
            (#"{"timestamp":"2026-08-23T08:40:00.000Z","type":"event_msg","payload":{"type":"notice"}}"# + "\n").utf8
        ))
        try handle.close()
        try [
            #"{"timestamp":"2026-08-23T08:44:59.000Z","type":"session_meta","payload":{"id":"unrelated-session","originator":"Codex Desktop"}}"#,
            #"{"timestamp":"2026-08-23T08:45:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":20,"cached_input_tokens":0,"output_tokens":0,"total_tokens":20},"last_token_usage":{"input_tokens":20,"cached_input_tokens":0,"output_tokens":0,"total_tokens":20}}}}"#,
        ].joined(separator: "\n").appending("\n")
            .write(
                to: sessionsRoot.appendingPathComponent("c-unrelated.jsonl"),
                atomically: true,
                encoding: .utf8
            )

        let incomplete = scanner.scanDailyActivityResult(now: now, days: 1, progress: nil)
        XCTAssertFalse(incomplete.isComplete)
        XCTAssertEqual(incomplete.days.compactMap(\.totalTokens).reduce(0, +), 150)
    }

    func testFullDuplicateCanReplaceAndQuarantineDivergentFormerOwner() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("full-duplicate-quarantine-\(UUID().uuidString)", isDirectory: true)
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let meta = #"{"timestamp":"2026-08-23T07:59:59.000Z","type":"session_meta","payload":{"id":"quarantine-session","originator":"Codex Desktop"}}"#
        let token100 = #"{"timestamp":"2026-08-23T08:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100},"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100}}}}"#
        let original = [meta, token100].joined(separator: "\n").appending("\n")
        let formerOwnerURL = sessionsRoot.appendingPathComponent("a-former-owner.jsonl")
        let replacementURL = sessionsRoot.appendingPathComponent("b-full-copy.jsonl")
        try original.write(to: formerOwnerURL, atomically: true, encoding: .utf8)
        try original.write(to: replacementURL, atomically: true, encoding: .utf8)

        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-23T09:00:00Z"))
        let scanner = CodexTokenActivityScanner(
            sessionRootURLs: [sessionsRoot],
            costUsageCacheRootURL: cacheRoot,
            usesAgentSignalCostUsageScanner: true
        )
        XCTAssertEqual(
            scanner.scanDailyActivityResult(now: now, days: 1, progress: nil)
                .days.compactMap(\.totalTokens).reduce(0, +),
            100
        )

        let divergent = [
            meta,
            #"{"timestamp":"2026-08-23T08:20:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":50,"cached_input_tokens":0,"output_tokens":0,"total_tokens":50},"last_token_usage":{"input_tokens":50,"cached_input_tokens":0,"output_tokens":0,"total_tokens":50}}}}"#,
        ].joined(separator: "\n").appending("\n")
        let oldGeneration = CostUsageScanner.codexFileMetadata(fileURL: formerOwnerURL).fileId
        try divergent.write(to: formerOwnerURL, atomically: true, encoding: .utf8)
        XCTAssertNotEqual(
            oldGeneration,
            CostUsageScanner.codexFileMetadata(fileURL: formerOwnerURL).fileId
        )

        let quarantined = scanner.scanDailyActivityResult(now: now, days: 1, progress: nil)
        XCTAssertTrue(quarantined.isComplete)
        XCTAssertEqual(quarantined.days.compactMap(\.totalTokens).reduce(0, +), 100)

        try [
            #"{"timestamp":"2026-08-23T08:39:59.000Z","type":"session_meta","payload":{"id":"post-quarantine-session","originator":"Codex Desktop"}}"#,
            #"{"timestamp":"2026-08-23T08:40:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":20,"cached_input_tokens":0,"output_tokens":0,"total_tokens":20},"last_token_usage":{"input_tokens":20,"cached_input_tokens":0,"output_tokens":0,"total_tokens":20}}}}"#,
        ].joined(separator: "\n").appending("\n")
            .write(
                to: sessionsRoot.appendingPathComponent("c-post-quarantine.jsonl"),
                atomically: true,
                encoding: .utf8
            )
        let stable = scanner.scanDailyActivityResult(now: now, days: 1, progress: nil)
        XCTAssertTrue(stable.isComplete)
        XCTAssertEqual(stable.days.compactMap(\.totalTokens).reduce(0, +), 120)
        let cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        let ownerPath = try XCTUnwrap(
            cache.files.first(where: {
                $0.value.sessionId == "quarantine-session"
                    && $0.value.codexInventoryOnly != true
            })?.key
        )
        XCTAssertEqual(
            URL(fileURLWithPath: ownerPath).standardizedFileURL.resolvingSymlinksInPath().path,
            replacementURL.standardizedFileURL.resolvingSymlinksInPath().path
        )
        let quarantinedUsage = try XCTUnwrap(
            cache.files.first(where: {
                URL(fileURLWithPath: $0.key).standardizedFileURL.resolvingSymlinksInPath().path
                    == formerOwnerURL.standardizedFileURL.resolvingSymlinksInPath().path
            })?.value
        )
        XCTAssertEqual(quarantinedUsage.codexInventoryOnly, true)
        XCTAssertEqual(quarantinedUsage.codexDuplicateQuarantined, true)
    }

    func testValidExtendedDuplicateWinsOverDivergentFormerOwner() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("duplicate-valid-extension-\(UUID().uuidString)", isDirectory: true)
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let meta = #"{"timestamp":"2026-08-23T07:59:59.000Z","type":"session_meta","payload":{"id":"trusted-chain","originator":"Codex Desktop"}}"#
        let token100 = #"{"timestamp":"2026-08-23T08:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100},"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100}}}}"#
        let token150 = #"{"timestamp":"2026-08-23T08:20:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":150,"cached_input_tokens":0,"output_tokens":0,"total_tokens":150},"last_token_usage":{"input_tokens":50,"cached_input_tokens":0,"output_tokens":0,"total_tokens":50}}}}"#
        let original = [meta, token100].joined(separator: "\n").appending("\n")
        let ownerURL = sessionsRoot.appendingPathComponent("a-owner.jsonl")
        let stableURL = sessionsRoot.appendingPathComponent("b-stable.jsonl")
        let extendedURL = sessionsRoot.appendingPathComponent("c-extended.jsonl")
        try original.write(to: ownerURL, atomically: true, encoding: .utf8)
        try original.write(to: stableURL, atomically: true, encoding: .utf8)
        try original.write(to: extendedURL, atomically: true, encoding: .utf8)

        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-23T09:00:00Z"))
        let scanner = CodexTokenActivityScanner(
            sessionRootURLs: [sessionsRoot],
            costUsageCacheRootURL: cacheRoot,
            usesAgentSignalCostUsageScanner: true
        )
        XCTAssertEqual(
            scanner.scanDailyActivityResult(now: now, days: 1, progress: nil)
                .days.compactMap(\.totalTokens).reduce(0, +),
            100
        )

        let divergent = [
            meta,
            #"{"timestamp":"2026-08-23T08:10:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":40,"cached_input_tokens":0,"output_tokens":0,"total_tokens":40},"last_token_usage":{"input_tokens":40,"cached_input_tokens":0,"output_tokens":0,"total_tokens":40}}}}"#,
        ].joined(separator: "\n").appending("\n")
        let ownerHandle = try FileHandle(forWritingTo: ownerURL)
        try ownerHandle.truncate(atOffset: 0)
        try ownerHandle.write(contentsOf: Data(divergent.utf8))
        try ownerHandle.close()
        try FileHandle(forWritingTo: extendedURL).appendString(token150 + "\n")

        let reconciled = scanner.scanDailyActivityResult(now: now, days: 1, progress: nil)
        XCTAssertTrue(reconciled.isComplete)
        XCTAssertEqual(reconciled.days.compactMap(\.totalTokens).reduce(0, +), 150)
        let cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        let ownerPath = try XCTUnwrap(
            cache.files.first(where: {
                $0.value.sessionId == "trusted-chain" && $0.value.codexInventoryOnly != true
            })?.key
        )
        XCTAssertEqual(
            URL(fileURLWithPath: ownerPath).standardizedFileURL.resolvingSymlinksInPath().path,
            extendedURL.standardizedFileURL.resolvingSymlinksInPath().path
        )
    }

    func testIncrementalScanRejectsSameInodeRewriteWhenCommittedPrefixChanged() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("same-inode-prefix-rewrite-\(UUID().uuidString)", isDirectory: true)
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionURL = sessionsRoot.appendingPathComponent("rollout-rewrite.jsonl")
        let oldPrefix = [
            #"{"timestamp":"2026-08-23T07:59:59.000Z","type":"session_meta","payload":{"id":"session-a","originator":"Codex Desktop"}}"#,
            #"{"timestamp":"2026-08-23T08:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100},"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100}}}}"#,
        ].joined(separator: "\n").appending("\n")
        try oldPrefix.write(to: sessionURL, atomically: true, encoding: .utf8)

        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-23T09:00:00Z"))
        let scanner = CodexTokenActivityScanner(
            sessionRootURLs: [sessionsRoot],
            costUsageCacheRootURL: cacheRoot,
            usesAgentSignalCostUsageScanner: true
        )
        XCTAssertEqual(
            scanner.scanDailyActivityResult(now: now, days: 1, progress: nil)
                .days.compactMap(\.totalTokens).reduce(0, +),
            100
        )

        let rewrittenPrefix = [
            #"{"timestamp":"2026-08-23T07:59:59.000Z","type":"session_meta","payload":{"id":"session-b","originator":"Codex Desktop"}}"#,
            #"{"timestamp":"2026-08-23T08:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens": 50,"cached_input_tokens":0,"output_tokens":0,"total_tokens": 50},"last_token_usage":{"input_tokens": 50,"cached_input_tokens":0,"output_tokens":0,"total_tokens": 50}}}}"#,
        ].joined(separator: "\n").appending("\n")
        XCTAssertEqual(rewrittenPrefix.utf8.count, oldPrefix.utf8.count)
        let appended = #"{"timestamp":"2026-08-23T08:30:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":80,"cached_input_tokens":0,"output_tokens":0,"total_tokens":80},"last_token_usage":{"input_tokens":30,"cached_input_tokens":0,"output_tokens":0,"total_tokens":30}}}}"# + "\n"
        let handle = try FileHandle(forWritingTo: sessionURL)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data((rewrittenPrefix + appended).utf8))
        try handle.close()

        let rescanned = scanner.scanDailyActivityResult(now: now, days: 1, progress: nil)
        XCTAssertTrue(rescanned.isComplete)
        XCTAssertEqual(rescanned.days.compactMap(\.totalTokens).reduce(0, +), 80)
        let cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        XCTAssertEqual(cache.files.values.first(where: { $0.codexInventoryOnly != true })?.sessionId, "session-b")
    }

    func testStatFingerprintDetectsSameInodeSameSizeRewriteWithRestoredMtime() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("same-stat-millisecond-rewrite-\(UUID().uuidString)", isDirectory: true)
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionURL = sessionsRoot.appendingPathComponent("rollout-same-stat.jsonl")
        let initialContents = [
            #"{"timestamp":"2026-08-23T07:59:59.000Z","type":"session_meta","payload":{"id":"stat-session-a","originator":"Codex Desktop"}}"#,
            #"{"timestamp":"2026-08-23T08:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100},"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100}}}}"#,
        ].joined(separator: "\n").appending("\n")
        let rewrittenContents = [
            #"{"timestamp":"2026-08-23T07:59:59.000Z","type":"session_meta","payload":{"id":"stat-session-b","originator":"Codex Desktop"}}"#,
            #"{"timestamp":"2026-08-23T08:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens": 50,"cached_input_tokens":0,"output_tokens":0,"total_tokens": 50},"last_token_usage":{"input_tokens": 50,"cached_input_tokens":0,"output_tokens":0,"total_tokens": 50}}}}"#,
        ].joined(separator: "\n").appending("\n")
        XCTAssertEqual(initialContents.utf8.count, rewrittenContents.utf8.count)
        try initialContents.write(to: sessionURL, atomically: true, encoding: .utf8)

        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-23T09:00:00Z"))
        let scanner = CodexTokenActivityScanner(
            sessionRootURLs: [sessionsRoot],
            costUsageCacheRootURL: cacheRoot,
            usesAgentSignalCostUsageScanner: true
        )
        let initial = scanner.scanDailyActivityResult(now: now, days: 1, progress: nil)
        XCTAssertTrue(initial.isComplete)
        XCTAssertEqual(initial.days.compactMap(\.totalTokens).reduce(0, +), 100)

        let originalMetadata = CostUsageScanner.codexFileMetadata(fileURL: sessionURL)
        let originalModificationDate = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: sessionURL.path)[.modificationDate] as? Date
        )
        let handle = try FileHandle(forWritingTo: sessionURL)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(rewrittenContents.utf8))
        try handle.close()
        try FileManager.default.setAttributes(
            [.modificationDate: originalModificationDate],
            ofItemAtPath: sessionURL.path
        )

        let rewrittenMetadata = CostUsageScanner.codexFileMetadata(fileURL: sessionURL)
        XCTAssertEqual(rewrittenMetadata.fileId, originalMetadata.fileId)
        XCTAssertEqual(rewrittenMetadata.size, originalMetadata.size)
        XCTAssertEqual(rewrittenMetadata.mtimeUnixMs, originalMetadata.mtimeUnixMs)
        XCTAssertNotEqual(rewrittenMetadata.statFingerprint, originalMetadata.statFingerprint)

        let rescanned = scanner.scanDailyActivityResult(now: now, days: 1, progress: nil)
        XCTAssertTrue(rescanned.isComplete)
        XCTAssertEqual(rescanned.days.compactMap(\.totalTokens).reduce(0, +), 50)
        let cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        let rewrittenUsage = cache.files.first(where: {
            URL(fileURLWithPath: $0.key).lastPathComponent == sessionURL.lastPathComponent
        })?.value
        XCTAssertEqual(rewrittenUsage?.sessionId, "stat-session-b")
        XCTAssertEqual(rewrittenUsage?.sourceStatFingerprint, rewrittenMetadata.statFingerprint)
    }

    func testCommittedPrefixDigestDetectsRewriteBeforeUnchangedLastTokenLine() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("prefix-digest-earlier-rewrite-\(UUID().uuidString)", isDirectory: true)
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let metaA = #"{"timestamp":"2026-08-23T07:59:59.000Z","type":"session_meta","payload":{"id":"session-a","originator":"Codex Desktop"}}"#
        let metaB = #"{"timestamp":"2026-08-23T07:59:59.000Z","type":"session_meta","payload":{"id":"session-b","originator":"Codex Desktop"}}"#
        let unchangedToken = #"{"timestamp":"2026-08-23T08:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100},"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100}}}}"#
        let sessionURL = sessionsRoot.appendingPathComponent("rollout-anchor-rewrite.jsonl")
        let initialPrefix = [metaA, unchangedToken].joined(separator: "\n").appending("\n")
        try initialPrefix.write(to: sessionURL, atomically: true, encoding: .utf8)

        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-23T09:00:00Z"))
        let scanner = CodexTokenActivityScanner(
            sessionRootURLs: [sessionsRoot],
            costUsageCacheRootURL: cacheRoot,
            usesAgentSignalCostUsageScanner: true
        )
        XCTAssertEqual(
            scanner.scanDailyActivityResult(now: now, days: 1, progress: nil)
                .days.compactMap(\.totalTokens).reduce(0, +),
            100
        )

        let rewrittenPrefix = [metaB, unchangedToken].joined(separator: "\n").appending("\n")
        XCTAssertEqual(rewrittenPrefix.utf8.count, initialPrefix.utf8.count)
        let appended = #"{"timestamp":"2026-08-23T08:30:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":150,"cached_input_tokens":0,"output_tokens":0,"total_tokens":150},"last_token_usage":{"input_tokens":50,"cached_input_tokens":0,"output_tokens":0,"total_tokens":50}}}}"# + "\n"
        let handle = try FileHandle(forWritingTo: sessionURL)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data((rewrittenPrefix + appended).utf8))
        try handle.close()

        let rescanned = scanner.scanDailyActivityResult(now: now, days: 1, progress: nil)
        XCTAssertTrue(rescanned.isComplete)
        XCTAssertEqual(rescanned.days.compactMap(\.totalTokens).reduce(0, +), 150)
        let cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        XCTAssertEqual(cache.files.values.first(where: { $0.codexInventoryOnly != true })?.sessionId, "session-b")
    }

    func testCommittedPrefixFingerprintRejectsPathSwapBetweenStatAndOpen() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("prefix-fd-swap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let targetURL = root.appendingPathComponent("target.jsonl")
        let originalBackupURL = root.appendingPathComponent("original.jsonl")
        let replacementURL = root.appendingPathComponent("replacement.jsonl")
        try "AAAA\n".write(to: targetURL, atomically: true, encoding: .utf8)
        try "BBBB\n".write(to: replacementURL, atomically: true, encoding: .utf8)

        var checkpoint = 0
        let fingerprint = try CostUsageScanner.codexCommittedPrefixFingerprint(
            fileURL: targetURL,
            throughOffset: 5,
            checkCancellation: {
                checkpoint += 1
                switch checkpoint {
                case 1:
                    try FileManager.default.moveItem(at: targetURL, to: originalBackupURL)
                    try FileManager.default.moveItem(at: replacementURL, to: targetURL)
                case 2:
                    try FileManager.default.moveItem(at: targetURL, to: replacementURL)
                    try FileManager.default.moveItem(at: originalBackupURL, to: targetURL)
                default:
                    XCTFail("descriptor mismatch must be rejected before hashing")
                }
            }
        )

        XCTAssertNil(fingerprint)
        XCTAssertEqual(checkpoint, 2)
        XCTAssertEqual(try String(contentsOf: targetURL, encoding: .utf8), "AAAA\n")
    }

    func testPrefixRelationshipRejectsPathSwapBetweenStatAndOpen() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("relationship-fd-swap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let lhsURL = root.appendingPathComponent("lhs.jsonl")
        let lhsBackupURL = root.appendingPathComponent("lhs-original.jsonl")
        let replacementURL = root.appendingPathComponent("lhs-replacement.jsonl")
        let rhsURL = root.appendingPathComponent("rhs.jsonl")
        try "AAAA\n".write(to: lhsURL, atomically: true, encoding: .utf8)
        try "BBBB\n".write(to: replacementURL, atomically: true, encoding: .utf8)
        try "AAAA\n".write(to: rhsURL, atomically: true, encoding: .utf8)

        var checkpoint = 0
        XCTAssertThrowsError(try CostUsageScanner.codexFilePrefixRelationship(
            lhsURL: lhsURL,
            rhsURL: rhsURL,
            checkCancellation: {
                checkpoint += 1
                switch checkpoint {
                case 1:
                    try FileManager.default.moveItem(at: lhsURL, to: lhsBackupURL)
                    try FileManager.default.moveItem(at: replacementURL, to: lhsURL)
                case 2:
                    try FileManager.default.moveItem(at: lhsURL, to: replacementURL)
                    try FileManager.default.moveItem(at: lhsBackupURL, to: lhsURL)
                default:
                    XCTFail("descriptor mismatch must be rejected before comparison")
                }
            }
        ))
        XCTAssertEqual(checkpoint, 2)
        XCTAssertEqual(try String(contentsOf: lhsURL, encoding: .utf8), "AAAA\n")
    }

    func testParentDuplicatePromotionPrecedesChildForkBaselineResolution() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fork-parent-promotion-order-\(UUID().uuidString)", isDirectory: true)
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let parentMeta = #"{"timestamp":"2026-08-23T07:59:59.000Z","type":"session_meta","payload":{"id":"parent-session","originator":"Codex Desktop"}}"#
        let parent100 = #"{"timestamp":"2026-08-23T08:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100},"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100}}}}"#
        let parent150 = #"{"timestamp":"2026-08-23T08:20:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":150,"cached_input_tokens":0,"output_tokens":0,"total_tokens":150},"last_token_usage":{"input_tokens":50,"cached_input_tokens":0,"output_tokens":0,"total_tokens":50}}}}"#
        let parentOwnerURL = sessionsRoot.appendingPathComponent("m-parent-owner.jsonl")
        let parentSentinelURL = sessionsRoot.appendingPathComponent("z-parent-sentinel.jsonl")
        let parentInitial = [parentMeta, parent100].joined(separator: "\n").appending("\n")
        try parentInitial.write(to: parentOwnerURL, atomically: true, encoding: .utf8)
        try parentInitial.write(to: parentSentinelURL, atomically: true, encoding: .utf8)

        let childMeta = #"{"timestamp":"2026-08-23T08:30:00.000Z","type":"session_meta","payload":{"id":"child-session","forked_from_id":"parent-session","timestamp":"2026-08-23T08:30:00.000Z","originator":"Codex Desktop"}}"#
        let child100 = #"{"timestamp":"2026-08-23T08:31:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100},"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100}}}}"#
        let childURL = sessionsRoot.appendingPathComponent("a-child.jsonl")
        try [childMeta, child100].joined(separator: "\n").appending("\n")
            .write(to: childURL, atomically: true, encoding: .utf8)

        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-23T09:00:00Z"))
        let scanner = CodexTokenActivityScanner(
            sessionRootURLs: [sessionsRoot],
            costUsageCacheRootURL: cacheRoot,
            usesAgentSignalCostUsageScanner: true
        )
        let initial = scanner.scanDailyActivityResult(now: now, days: 1, progress: nil)
        XCTAssertTrue(initial.isComplete)
        XCTAssertEqual(initial.days.compactMap(\.totalTokens).reduce(0, +), 100)

        try FileHandle(forWritingTo: parentSentinelURL).appendString(parent150 + "\n")
        let child150 = #"{"timestamp":"2026-08-23T08:31:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":150,"cached_input_tokens":0,"output_tokens":0,"total_tokens":150},"last_token_usage":{"input_tokens":150,"cached_input_tokens":0,"output_tokens":0,"total_tokens":150}}}}"#
        let child170 = #"{"timestamp":"2026-08-23T08:40:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":170,"cached_input_tokens":0,"output_tokens":0,"total_tokens":170},"last_token_usage":{"input_tokens":20,"cached_input_tokens":0,"output_tokens":0,"total_tokens":20}}}}"#
        let childHandle = try FileHandle(forWritingTo: childURL)
        try childHandle.truncate(atOffset: 0)
        try childHandle.write(contentsOf: Data(
            [childMeta, child150, child170].joined(separator: "\n").appending("\n").utf8
        ))
        try childHandle.close()

        let reconciled = scanner.scanDailyActivityResult(now: now, days: 1, progress: nil)
        XCTAssertTrue(reconciled.isComplete)
        XCTAssertEqual(reconciled.days.compactMap(\.totalTokens).reduce(0, +), 170)
    }

    func testCachedOwnerWithoutSessionMetadataCannotEraseLastKnownGoodAggregate() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("owner-metadata-loss-\(UUID().uuidString)", isDirectory: true)
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionURL = sessionsRoot.appendingPathComponent("rollout-2026-08-23T08-00-00-owner.jsonl")
        let meta = #"{"timestamp":"2026-08-23T07:59:59.000Z","type":"session_meta","payload":{"id":"owner-session","originator":"Codex Desktop"}}"#
        let first = #"{"timestamp":"2026-08-23T08:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100},"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100}}}}"#
        try [meta, first].joined(separator: "\n").appending("\n")
            .write(to: sessionURL, atomically: true, encoding: .utf8)

        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-23T09:00:00Z"))
        let scanner = CodexTokenActivityScanner(
            sessionRootURLs: [sessionsRoot],
            costUsageCacheRootURL: cacheRoot,
            usesAgentSignalCostUsageScanner: true
        )
        let initial = scanner.scanDailyActivityResult(now: now, days: 1, progress: nil)
        XCTAssertTrue(initial.isComplete)
        XCTAssertEqual(initial.days.compactMap(\.totalTokens).reduce(0, +), 100)

        let handle = try FileHandle(forWritingTo: sessionURL)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(
            (#"{"timestamp":"2026-08-23T08:30:00.000Z","type":"event_msg","payload":{"type":"notice"}}"# + "\n").utf8
        ))
        try handle.close()

        let incomplete = scanner.scanDailyActivityResult(now: now, days: 1, progress: nil)
        XCTAssertFalse(incomplete.isComplete)
        XCTAssertEqual(incomplete.days.compactMap(\.totalTokens).reduce(0, +), 100)
        let retained = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        let retainedOwner = try XCTUnwrap(
            retained.files.values.first(where: { $0.sessionId == "owner-session" })
        )
        XCTAssertNotEqual(retainedOwner.codexInventoryOnly, true)

        let repaired = #"{"timestamp":"2026-08-23T08:45:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":50,"cached_input_tokens":0,"output_tokens":0,"total_tokens":50},"last_token_usage":{"input_tokens":50,"cached_input_tokens":0,"output_tokens":0,"total_tokens":50}}}}"#
        try [meta, repaired].joined(separator: "\n").appending("\n")
            .write(to: sessionURL, atomically: true, encoding: .utf8)
        let recovered = scanner.scanDailyActivityResult(now: now, days: 1, progress: nil)
        XCTAssertTrue(recovered.isComplete)
        XCTAssertEqual(recovered.days.compactMap(\.totalTokens).reduce(0, +), 50)
    }

    func testSymlinkSessionRootRetargetRebuildsCanonicalInventory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("symlink-session-root-\(UUID().uuidString)", isDirectory: true)
        let firstTarget = root.appendingPathComponent("first-target", isDirectory: true)
        let secondTarget = root.appendingPathComponent("second-target", isDirectory: true)
        let link = root.appendingPathComponent("sessions-link", isDirectory: true)
        let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: firstTarget, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondTarget, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: firstTarget)
        defer { try? FileManager.default.removeItem(at: root) }

        func writeSession(to directory: URL, id: String, total: Int) throws {
            let url = directory.appendingPathComponent("rollout-2026-08-23T08-00-00-\(id).jsonl")
            try [
                #"{"timestamp":"2026-08-23T07:59:59.000Z","type":"session_meta","payload":{"id":"\#(id)","originator":"Codex Desktop"}}"#,
                #"{"timestamp":"2026-08-23T08:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(total),"cached_input_tokens":0,"output_tokens":0,"total_tokens":\#(total)},"last_token_usage":{"input_tokens":\#(total),"cached_input_tokens":0,"output_tokens":0,"total_tokens":\#(total)}}}}"#,
            ].joined(separator: "\n").appending("\n")
                .write(to: url, atomically: true, encoding: .utf8)
        }
        try writeSession(to: firstTarget, id: "first-session", total: 10)
        try writeSession(to: secondTarget, id: "second-session", total: 20)

        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-23T09:00:00Z"))
        let since = Calendar.current.startOfDay(for: now)
        var options = CostUsageScanner.Options(codexSessionsRoot: link, cacheRoot: cacheRoot)
        options.refreshMinIntervalSeconds = 0
        let first = try CostUsageScanner.loadDailyReportCancellable(
            provider: .codex,
            since: since,
            until: now,
            now: now,
            options: options,
            checkCancellation: nil
        )
        XCTAssertEqual(first.data.compactMap(\.totalTokens).reduce(0, +), 10)

        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secondTarget)
        let second = try CostUsageScanner.loadDailyReportCancellable(
            provider: .codex,
            since: since,
            until: now,
            now: now,
            options: options,
            checkCancellation: nil
        )
        XCTAssertEqual(second.data.compactMap(\.totalTokens).reduce(0, +), 20)
        let cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        XCTAssertTrue(
            cache.files.keys.allSatisfy {
                URL(fileURLWithPath: $0).pathComponents.contains("second-target")
            },
            "cached paths: \(cache.files.keys.sorted())"
        )
        XCTAssertFalse(cache.files.keys.contains {
            URL(fileURLWithPath: $0).pathComponents.contains("first-target")
        })
    }

    func testInventoryDirectoryMutationBeforeCommitPreservesLastGoodCache() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("inventory-commit-race-\(UUID().uuidString)", isDirectory: true)
        let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let firstURL = root.appendingPathComponent("rollout-2026-08-23T08-00-00-first.jsonl")
        try [
            #"{"timestamp":"2026-08-23T07:59:59.000Z","type":"session_meta","payload":{"id":"first-session","originator":"Codex Desktop"}}"#,
            #"{"timestamp":"2026-08-23T08:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":0,"total_tokens":10},"last_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":0,"total_tokens":10}}}}"#,
        ].joined(separator: "\n").appending("\n")
            .write(to: firstURL, atomically: true, encoding: .utf8)

        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-23T09:00:00Z"))
        let since = Calendar.current.startOfDay(for: now)
        var options = CostUsageScanner.Options(codexSessionsRoot: root, cacheRoot: cacheRoot)
        options.refreshMinIntervalSeconds = 0
        let initial = try CostUsageScanner.loadDailyReportCancellable(
            provider: .codex,
            since: since,
            until: now,
            now: now,
            options: options,
            checkCancellation: nil
        )
        XCTAssertEqual(initial.data.compactMap(\.totalTokens).reduce(0, +), 10)

        let racedURL = root.appendingPathComponent("rollout-2026-08-23T08-30-00-raced.jsonl")
        options.forceRescan = true
        options.codexInventoryBeforeCommitHook = {
            try? [
                #"{"timestamp":"2026-08-23T08:29:59.000Z","type":"session_meta","payload":{"id":"raced-session","originator":"Codex Desktop"}}"#,
                #"{"timestamp":"2026-08-23T08:30:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":20,"cached_input_tokens":0,"output_tokens":0,"total_tokens":20},"last_token_usage":{"input_tokens":20,"cached_input_tokens":0,"output_tokens":0,"total_tokens":20}}}}"#,
            ].joined(separator: "\n").appending("\n")
                .write(to: racedURL, atomically: true, encoding: .utf8)
        }
        XCTAssertThrowsError(try CostUsageScanner.loadDailyReportCancellable(
            provider: .codex,
            since: since,
            until: now,
            now: now,
            options: options,
            checkCancellation: nil
        ))

        let retainedCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        let retained = CostUsageScanner.buildCodexReportFromCache(
            cache: retainedCache,
            range: CostUsageScanner.CostUsageDayRange(since: since, until: now),
            modelsDevCacheRoot: cacheRoot
        )
        XCTAssertEqual(retained.data.compactMap(\.totalTokens).reduce(0, +), 10)
        XCTAssertNil(retainedCache.files[racedURL.path])
    }

    func testInventoryAllowsAppendToAnExistingGenerationAndConsumesTheNewFrontier() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("inventory-existing-file-append-\(UUID().uuidString)", isDirectory: true)
        let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionURL = root.appendingPathComponent("rollout-2026-08-23T08-00-00-active.jsonl")
        try [
            #"{"timestamp":"2026-08-23T07:59:59.000Z","type":"session_meta","payload":{"id":"active-session","originator":"Codex Desktop"}}"#,
            #"{"timestamp":"2026-08-23T08:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":0,"total_tokens":10},"last_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":0,"total_tokens":10}}}}"#,
        ].joined(separator: "\n").appending("\n")
            .write(to: sessionURL, atomically: true, encoding: .utf8)

        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-23T09:00:00Z"))
        let since = Calendar.current.startOfDay(for: now)
        var options = CostUsageScanner.Options(codexSessionsRoot: root, cacheRoot: cacheRoot)
        options.refreshMinIntervalSeconds = 0
        var didAppend = false
        options.codexInventoryAfterMetadataHook = {
            guard !didAppend else { return }
            didAppend = true
            try? FileHandle(forWritingTo: sessionURL).appendString(
                #"{"timestamp":"2026-08-23T08:30:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":30,"cached_input_tokens":0,"output_tokens":0,"total_tokens":30},"last_token_usage":{"input_tokens":20,"cached_input_tokens":0,"output_tokens":0,"total_tokens":20}}}}"# + "\n"
            )
        }

        let report = try CostUsageScanner.loadDailyReportCancellable(
            provider: .codex,
            since: since,
            until: now,
            now: now,
            options: options,
            checkCancellation: nil
        )
        XCTAssertTrue(didAppend)
        XCTAssertEqual(report.data.compactMap(\.totalTokens).reduce(0, +), 30)
        let cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        XCTAssertEqual(cache.codexSessionInventoryComplete, true)
        XCTAssertEqual(cache.files[sessionURL.path]?.parsedBytes, cache.files[sessionURL.path]?.size)
    }

    func testCostUsageScannerRetriesAnUnterminatedTokenLineFromItsBeginning() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cost-partial-line-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = "019c846a-b85e-7bd3-924b-cc33e3f180d9"
        let meta = #"{"timestamp":"2026-06-18T07:59:59.000Z","type":"session_meta","payload":{"id":"\#(sessionID)","originator":"Codex Desktop"}}"#
        let first = #"{"timestamp":"2026-06-18T08:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":100,"output_tokens":100},"last_token_usage":{"input_tokens":1000,"cached_input_tokens":100,"output_tokens":100}}}}"#
        let second = #"{"timestamp":"2026-06-18T08:02:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1500,"cached_input_tokens":150,"output_tokens":150},"last_token_usage":{"input_tokens":500,"cached_input_tokens":50,"output_tokens":50}}}}"#
        let splitIndex = second.index(second.endIndex, offsetBy: -19)
        let sessionURL = root.appendingPathComponent("rollout-partial-\(sessionID).jsonl")
        try "\(meta)\n\(first)\n\(second[..<splitIndex])"
            .write(to: sessionURL, atomically: true, encoding: .utf8)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let since = try XCTUnwrap(formatter.date(from: "2026-06-18T00:00:00.000Z"))
        let through = try XCTUnwrap(formatter.date(from: "2026-06-18T09:00:00.000Z"))
        var options = CostUsageScanner.Options(
            codexSessionsRoot: root,
            cacheRoot: root.appendingPathComponent("cost-cache", isDirectory: true)
        )
        options.refreshMinIntervalSeconds = 0

        let partialReport = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: since,
            until: through,
            now: through,
            options: options
        )
        XCTAssertEqual(partialReport.data.compactMap(\.totalTokens).reduce(0, +), 1_100)
        let partialCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: options.cacheRoot)
        let partialUsage = try XCTUnwrap(partialCache.files.values.first)
        XCTAssertLessThan(try XCTUnwrap(partialUsage.parsedBytes), partialUsage.size)

        try FileHandle(forWritingTo: sessionURL).appendString(String(second[splitIndex...]) + "\n")
        let completeReport = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: since,
            until: through,
            now: through,
            options: options
        )
        XCTAssertEqual(completeReport.data.compactMap(\.totalTokens).reduce(0, +), 1_650)
    }

    @MainActor
    func testDuplicateSentinelWatermarkAbsorbsLiveCursorWithoutDoubleCounting() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("duplicate-sentinel-watermark-\(UUID().uuidString)", isDirectory: true)
        let firstRoot = root.appendingPathComponent("first", isDirectory: true)
        let secondRoot = root.appendingPathComponent("second", isDirectory: true)
        let cacheRoot = root.appendingPathComponent("cost-cache", isDirectory: true)
        try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date()
        let eventAt = now.addingTimeInterval(-1)
        let sessionID = "019c846a-b85e-7bd3-924b-cc33e3f180d9"
        let filenameDay = ISO8601DateFormatter().string(from: now).prefix(10)
        let filename = "rollout-\(filenameDay)T12-00-00-\(sessionID).jsonl"
        let lines = [
            #"{"timestamp":"\#(isoTimestamp(eventAt))","type":"session_meta","payload":{"id":"\#(sessionID)","originator":"Codex Desktop"}}"#,
            #"{"timestamp":"\#(isoTimestamp(eventAt))","type":"event_msg","payload":{"type":"token_count","info":{"model_context_window":258400,"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100},"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100}}}}"#,
        ]
        for sessionsRoot in [firstRoot, secondRoot] {
            try lines.joined(separator: "\n").appending("\n")
                .write(
                    to: sessionsRoot.appendingPathComponent(filename),
                    atomically: true,
                    encoding: .utf8
                )
        }

        let productionScanner = CodexTokenActivityScanner(
            sessionRootURLs: [firstRoot, secondRoot],
            costUsageCacheRootURL: cacheRoot,
            usesAgentSignalCostUsageScanner: true
        )
        let scanResult = productionScanner.scanDailyActivityResult(
            now: now,
            days: 1,
            progress: nil
        )
        XCTAssertTrue(scanResult.isComplete)
        XCTAssertEqual(scanResult.days.compactMap(\.totalTokens).reduce(0, +), 100)

        let cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        let duplicateEntries = cache.files.filter { $0.value.sessionId == sessionID }
        XCTAssertEqual(duplicateEntries.count, 2)
        let sentinelEntry = try XCTUnwrap(
            duplicateEntries.first(where: { $0.value.codexInventoryOnly == true })
        )
        let ownerEntry = try XCTUnwrap(
            duplicateEntries.first(where: { $0.value.codexInventoryOnly != true })
        )
        let sentinelGeneration = try XCTUnwrap(sentinelEntry.value.sourceGeneration)
        XCTAssertNotEqual(sentinelGeneration, ownerEntry.value.sourceGeneration)

        let sentinelSourceID = URL(fileURLWithPath: sentinelEntry.key)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        let monitor = CodexDesktopActivityMonitor(
            sessionRootURLs: [firstRoot, secondRoot],
            replaysInitialHistory: true
        )
        let liveUpdate = try XCTUnwrap(
            monitor.pollResult(now: now).quotaUpdates.first(where: {
                $0.tokenObservationCursor?.sourceID == sentinelSourceID
            })
        )
        let liveCursor = try XCTUnwrap(liveUpdate.tokenObservationCursor)
        let aliasWatermark = try XCTUnwrap(
            scanResult.watermarks.first(where: {
                $0.sourceID == sentinelSourceID
                    && $0.sourceGeneration == sentinelGeneration
            })
        )
        XCTAssertEqual(aliasWatermark.endOffset, liveCursor.endOffset)
        XCTAssertEqual(aliasWatermark.lineFingerprint, liveCursor.lineFingerprint)

        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let applied = expectation(description: "duplicate sentinel cursor absorbed")
        let controlledScanner = ControlledCodexTokenActivityScanner(
            cachedDays: { _ in nil },
            scannedResultsByCall: { _, _ in scanResult }
        )
        defer { controlledScanner.finishScan() }
        let model = MenuBarStatusModel(
            store: fixture.store,
            codexDesktopActivityMonitor: CodexDesktopActivityMonitor(replaysInitialHistory: false),
            codexAccountManager: EmptyCodexAccountManager(),
            codexTokenActivityScanner: controlledScanner,
            tokenActivityScanObserver: { disposition in
                if disposition == .applied { applied.fulfill() }
            },
            nowProvider: { now }
        )
        model.isCodexDesktopMonitoringEnabled = true
        model.isMonitoringPaused = false
        model.updateLatestAgentTokenUsage(
            try XCTUnwrap(liveUpdate.tokenActivityUsage),
            sessionID: liveUpdate.sessionID,
            updatedAt: eventAt,
            observationCursor: liveCursor
        )
        XCTAssertEqual(model.tokenActivityTotal(for: .today, now: now), 100)

        model.refreshTokenActivityIfNeeded(force: true)
        XCTAssertTrue(controlledScanner.waitUntilScanStarts(seconds: 1))
        controlledScanner.finishScan()
        await fulfillment(of: [applied], timeout: 2)

        XCTAssertEqual(controlledScanner.scanCallCount, 1)
        XCTAssertEqual(model.tokenActivityTotal(for: .today, now: now), 100)
    }

    @MainActor
    func testQuarantinedDuplicateCursorIsRejectedWithoutPermanentRetry() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quarantined-cursor-watermark-\(UUID().uuidString)", isDirectory: true)
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        let cacheRoot = root.appendingPathComponent("cost-cache", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date()
        let initialEventAt = now.addingTimeInterval(-2)
        let divergentEventAt = now.addingTimeInterval(-1)
        let sessionID = "019c846a-b85e-7bd3-924b-cc33e3f180d9"
        let liveSessionID = "codex-desktop:\(sessionID)"
        let filenameDay = ISO8601DateFormatter().string(from: now).prefix(10)
        let meta = #"{"timestamp":"\#(isoTimestamp(initialEventAt))","type":"session_meta","payload":{"id":"\#(sessionID)","originator":"Codex Desktop"}}"#
        let token100 = #"{"timestamp":"\#(isoTimestamp(initialEventAt))","type":"event_msg","payload":{"type":"token_count","info":{"model_context_window":258400,"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100},"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100}}}}"#
        let firstURL = sessionsRoot.appendingPathComponent(
            "rollout-\(filenameDay)T12-00-00-\(sessionID).jsonl"
        )
        let secondURL = sessionsRoot.appendingPathComponent(
            "rollout-\(filenameDay)T12-00-01-\(sessionID).jsonl"
        )
        for url in [firstURL, secondURL] {
            try [meta, token100].joined(separator: "\n").appending("\n")
                .write(to: url, atomically: true, encoding: .utf8)
        }

        let productionScanner = CodexTokenActivityScanner(
            sessionRootURLs: [sessionsRoot],
            costUsageCacheRootURL: cacheRoot,
            usesAgentSignalCostUsageScanner: true
        )
        let initialResult = productionScanner.scanDailyActivityResult(
            now: now,
            days: 1,
            progress: nil
        )
        XCTAssertTrue(initialResult.isComplete)
        XCTAssertEqual(initialResult.days.compactMap(\.totalTokens).reduce(0, +), 100)

        let initialCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        let formerOwnerEntry = try XCTUnwrap(initialCache.files.first(where: {
            $0.value.sessionId == sessionID && $0.value.codexInventoryOnly != true
        }))
        let formerOwnerSourceID = URL(fileURLWithPath: formerOwnerEntry.key)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        let formerOwnerGeneration = try XCTUnwrap(formerOwnerEntry.value.sourceGeneration)
        let initialOwnerWatermark = try XCTUnwrap(initialResult.watermarks.first(where: {
            $0.sourceID == formerOwnerSourceID
                && $0.sourceGeneration == formerOwnerGeneration
        }))
        let initialCursor = CodexTokenObservationCursor(
            sourceID: initialOwnerWatermark.sourceID,
            sourceGeneration: initialOwnerWatermark.sourceGeneration,
            endOffset: initialOwnerWatermark.endOffset,
            lineFingerprint: initialOwnerWatermark.lineFingerprint
        )

        let padding = String(repeating: "x", count: 512)
        let token50 = """
        {"timestamp":"\(isoTimestamp(divergentEventAt))","type":"event_msg","payload":{"type":"token_count","padding":"\(padding)","info":{"model_context_window":258400,"total_token_usage":{"input_tokens":50,"cached_input_tokens":0,"output_tokens":0,"total_tokens":50},"last_token_usage":{"input_tokens":50,"cached_input_tokens":0,"output_tokens":0,"total_tokens":50}}}}
        """
        let formerOwnerURL = URL(fileURLWithPath: formerOwnerEntry.key)
        let handle = try FileHandle(forWritingTo: formerOwnerURL)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data([meta, token50].joined(separator: "\n").appending("\n").utf8))
        try handle.close()

        let quarantinedResult = productionScanner.scanDailyActivityResult(
            now: now,
            days: 1,
            progress: nil
        )
        XCTAssertTrue(quarantinedResult.isComplete)
        XCTAssertEqual(quarantinedResult.days.compactMap(\.totalTokens).reduce(0, +), 100)
        let quarantineWatermark = try XCTUnwrap(quarantinedResult.watermarks.first(where: {
            $0.sourceID == formerOwnerSourceID
                && $0.sourceGeneration == formerOwnerGeneration
                && $0.endOffset == .max
        }))
        XCTAssertEqual(quarantineWatermark.sessionID, sessionID)

        let divergentPoll = CodexDesktopActivityMonitor(
            sessionsRootURL: sessionsRoot,
            replaysInitialHistory: true
        ).pollResult(now: now)
        let divergentUpdate = try XCTUnwrap(
            divergentPoll.quotaUpdates.first(where: {
                $0.tokenObservationCursor?.sourceID == formerOwnerSourceID
            }),
            "expected source \(formerOwnerSourceID); observed \(divergentPoll.quotaUpdates.compactMap { $0.tokenObservationCursor?.sourceID })"
        )
        let divergentCursor = try XCTUnwrap(divergentUpdate.tokenObservationCursor)
        XCTAssertGreaterThan(divergentCursor.endOffset, initialCursor.endOffset)
        XCTAssertEqual(divergentUpdate.tokenActivityUsage?.effectiveTotalTokens, 50)

        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let firstApplied = expectation(description: "initial duplicate owner applied")
        let quarantineApplied = expectation(description: "quarantined cursor disposed")
        var appliedCount = 0
        let controlledScanner = ControlledCodexTokenActivityScanner(
            cachedDays: { _ in nil },
            scannedResultsByCall: { _, callIndex in
                callIndex == 1 ? initialResult : quarantinedResult
            }
        )
        defer { controlledScanner.finishScan() }
        let model = MenuBarStatusModel(
            store: fixture.store,
            codexDesktopActivityMonitor: CodexDesktopActivityMonitor(replaysInitialHistory: false),
            codexAccountManager: EmptyCodexAccountManager(),
            codexTokenActivityScanner: controlledScanner,
            tokenActivityScanObserver: { disposition in
                guard disposition == .applied else { return }
                appliedCount += 1
                if appliedCount == 1 {
                    firstApplied.fulfill()
                } else {
                    quarantineApplied.fulfill()
                }
            },
            nowProvider: { now }
        )
        model.isCodexDesktopMonitoringEnabled = true
        model.isMonitoringPaused = false
        model.updateLatestAgentTokenUsage(
            AgentTokenUsage(totalTokens: 100),
            sessionID: liveSessionID,
            updatedAt: initialEventAt,
            observationCursor: initialCursor
        )
        model.refreshTokenActivityIfNeeded(force: true)
        XCTAssertTrue(controlledScanner.waitUntilScanStarts(seconds: 1))
        controlledScanner.finishScan()
        await fulfillment(of: [firstApplied], timeout: 2)
        XCTAssertEqual(model.tokenActivityTotal(for: .today, now: now), 100)

        model.updateLatestAgentTokenUsage(
            try XCTUnwrap(divergentUpdate.tokenActivityUsage),
            sessionID: divergentUpdate.sessionID,
            updatedAt: divergentEventAt,
            observationCursor: divergentCursor
        )
        XCTAssertEqual(model.tokenActivityTotal(for: .today, now: now), 150)

        model.refreshTokenActivityIfNeeded(force: true)
        XCTAssertTrue(controlledScanner.waitUntilScanStarts(seconds: 1))
        controlledScanner.finishScan()
        await fulfillment(of: [quarantineApplied], timeout: 2)

        XCTAssertEqual(controlledScanner.scanCallCount, 2)
        XCTAssertEqual(model.tokenActivityTotal(for: .today, now: now), 100)

        // The poll writes an exact observation before the scanner's quarantine
        // can reject its cursor. Its cursor-less, whole-second state-file copy
        // must not bypass that tombstone and recreate a divergent counter.
        let rejectedEventAt = divergentEventAt.addingTimeInterval(0.456)
        model.updateLatestAgentTokenUsage(
            AgentTokenUsage(totalTokens: 600),
            sessionID: liveSessionID,
            updatedAt: rejectedEventAt,
            observationCursor: divergentCursor,
            stateShadowUsage: AgentTokenUsage(totalTokens: 60)
        )
        XCTAssertEqual(model.tokenActivityTotal(for: .today, now: now), 100)
        model.updateLatestAgentTokenUsage(
            AgentTokenUsage(totalTokens: 60),
            sessionID: liveSessionID,
            updatedAt: Date(
                timeIntervalSince1970: rejectedEventAt.timeIntervalSince1970.rounded(.down)
            )
        )
        XCTAssertEqual(model.tokenActivityTotal(for: .today, now: now), 100)

        let survivingOwnerWatermark = try XCTUnwrap(
            quarantinedResult.watermarks.first(where: {
                $0.sessionID == sessionID
                    && $0.endOffset != .max
                    && $0.totalTokens == 100
            })
        )
        let ownerGrowthCursor = CodexTokenObservationCursor(
            sourceID: survivingOwnerWatermark.sourceID,
            sourceGeneration: survivingOwnerWatermark.sourceGeneration,
            endOffset: survivingOwnerWatermark.endOffset + 100,
            lineFingerprint: "owner-growth-150"
        )
        model.updateLatestAgentTokenUsage(
            AgentTokenUsage(totalTokens: 150),
            sessionID: liveSessionID,
            updatedAt: now,
            observationCursor: ownerGrowthCursor
        )
        XCTAssertEqual(model.tokenActivityTotal(for: .today, now: now), 150)

        model.updateLatestAgentTokenUsage(
            try XCTUnwrap(divergentUpdate.tokenActivityUsage),
            sessionID: divergentUpdate.sessionID,
            updatedAt: now.addingTimeInterval(1),
            observationCursor: divergentCursor
        )
        XCTAssertEqual(model.tokenActivityTotal(for: .today, now: now), 150)
    }

    @MainActor
    func testFirstLiveCursorAfterScannedFrontierUsesNumericBaseline() async throws {
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 60 * 60)
        let scannedAt = now.addingTimeInterval(-2)
        let liveAt = now.addingTimeInterval(-1)
        let sessionID = "scan-first-session"
        let liveSessionID = "codex-desktop:\(sessionID)"
        let sourceID = "/tmp/scan-first-session.jsonl"
        let generation = "device:scan-first-inode"
        let scanResult = CodexTokenActivityScanResult(
            days: [CodexTokenActivityDay(
                day: Calendar.current.startOfDay(for: now),
                totalTokens: 100
            )],
            watermarks: [CodexTokenActivityScanWatermark(
                sessionID: sessionID,
                sourceID: sourceID,
                sourceGeneration: generation,
                endOffset: 100,
                lineFingerprint: "frontier-100",
                eventTimestamp: scannedAt,
                totalTokens: 100
            )]
        )
        let applied = expectation(description: "scan-first frontier applied")
        let scanner = ControlledCodexTokenActivityScanner(
            cachedDays: { _ in nil },
            scannedResultsByCall: { _, _ in scanResult }
        )
        defer { scanner.finishScan() }
        let model = MenuBarStatusModel(
            store: fixture.store,
            codexDesktopActivityMonitor: CodexDesktopActivityMonitor(replaysInitialHistory: false),
            codexAccountManager: EmptyCodexAccountManager(),
            codexTokenActivityScanner: scanner,
            tokenActivityScanObserver: { disposition in
                if disposition == .applied { applied.fulfill() }
            },
            nowProvider: { now }
        )
        model.isCodexDesktopMonitoringEnabled = true
        model.isMonitoringPaused = false

        model.refreshTokenActivityIfNeeded(force: true)
        XCTAssertTrue(scanner.waitUntilScanStarts(seconds: 1))
        scanner.finishScan()
        await fulfillment(of: [applied], timeout: 2)
        XCTAssertEqual(model.tokenActivityTotal(for: .today, now: now), 100)

        model.updateLatestAgentTokenUsage(
            AgentTokenUsage(totalTokens: 150),
            sessionID: liveSessionID,
            updatedAt: liveAt,
            observationCursor: CodexTokenObservationCursor(
                sourceID: sourceID,
                sourceGeneration: generation,
                endOffset: 200,
                lineFingerprint: "frontier-150"
            )
        )
        XCTAssertEqual(model.tokenActivityTotal(for: .today, now: now), 150)
    }

    @MainActor
    func testNoSessionMetadataTokenLineCannotCreatePendingRetry() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-meta-live-token-\(UUID().uuidString)", isDirectory: true)
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        let cacheRoot = root.appendingPathComponent("cost-cache", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date()
        let eventAt = now.addingTimeInterval(-1)
        let sessionID = "019c846a-b85e-7bd3-924b-cc33e3f180d9"
        let filenameDay = ISO8601DateFormatter().string(from: now).prefix(10)
        let tokenLine = #"{"timestamp":"\#(isoTimestamp(eventAt))","type":"event_msg","payload":{"type":"token_count","info":{"model_context_window":258400,"total_token_usage":{"input_tokens":40,"cached_input_tokens":0,"output_tokens":0,"total_tokens":40},"last_token_usage":{"input_tokens":40,"cached_input_tokens":0,"output_tokens":0,"total_tokens":40}}}}"#
        try tokenLine.appending("\n").write(
            to: sessionsRoot.appendingPathComponent(
                "rollout-\(filenameDay)T12-00-00-\(sessionID).jsonl"
            ),
            atomically: true,
            encoding: .utf8
        )

        let monitor = CodexDesktopActivityMonitor(
            sessionsRootURL: sessionsRoot,
            replaysInitialHistory: true
        )
        XCTAssertTrue(monitor.pollResult(now: now).quotaUpdates.isEmpty)

        let productionScanner = CodexTokenActivityScanner(
            sessionRootURLs: [sessionsRoot],
            costUsageCacheRootURL: cacheRoot,
            usesAgentSignalCostUsageScanner: true
        )
        let scanResult = productionScanner.scanDailyActivityResult(
            now: now,
            days: 1,
            progress: nil
        )
        XCTAssertTrue(scanResult.isComplete)
        XCTAssertTrue(scanResult.days.isEmpty)

        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let applied = expectation(description: "no-meta scan applied without retry")
        let scanner = ControlledCodexTokenActivityScanner(
            cachedDays: { _ in nil },
            scannedResultsByCall: { _, _ in scanResult }
        )
        defer { scanner.finishScan() }
        let model = MenuBarStatusModel(
            store: fixture.store,
            codexDesktopActivityMonitor: monitor,
            codexAccountManager: EmptyCodexAccountManager(),
            codexTokenActivityScanner: scanner,
            tokenActivityScanObserver: { disposition in
                if disposition == .applied { applied.fulfill() }
            },
            nowProvider: { now }
        )
        model.isCodexDesktopMonitoringEnabled = true
        model.isMonitoringPaused = false
        model.refreshTokenActivityIfNeeded(force: true)
        XCTAssertTrue(scanner.waitUntilScanStarts(seconds: 1))
        scanner.finishScan()
        await fulfillment(of: [applied], timeout: 2)

        XCTAssertEqual(scanner.scanCallCount, 1)
        XCTAssertEqual(model.tokenActivityTotal(for: .today, now: now), 0)
    }

    func testLongInitialTailUsesBoundedHeaderProbeToConfirmTokenSession() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("long-tail-session-meta-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date()
        let eventAt = now.addingTimeInterval(-1)
        let sessionID = "019c846a-b85e-7bd3-924b-cc33e3f180d9"
        let filenameDay = ISO8601DateFormatter().string(from: now).prefix(10)
        let meta = #"{"timestamp":"\#(isoTimestamp(eventAt))","type":"session_meta","payload":{"id":"\#(sessionID)","originator":"Codex Desktop"}}"#
        let padding = #"{"timestamp":"2026-08-23T00:00:00.000Z","type":"event_msg","payload":{"type":"notice","text":"\#(String(repeating: "x", count: 2_048))"}}"#
        let tokenLine = #"{"timestamp":"\#(isoTimestamp(eventAt))","type":"event_msg","payload":{"type":"token_count","info":{"model_context_window":258400,"total_token_usage":{"input_tokens":75,"cached_input_tokens":0,"output_tokens":0,"total_tokens":75},"last_token_usage":{"input_tokens":75,"cached_input_tokens":0,"output_tokens":0,"total_tokens":75}}}}"#
        try [meta, padding, tokenLine].joined(separator: "\n").appending("\n").write(
            to: root.appendingPathComponent(
                "rollout-\(filenameDay)T12-00-00-\(sessionID).jsonl"
            ),
            atomically: true,
            encoding: .utf8
        )

        let monitor = CodexDesktopActivityMonitor(
            sessionsRootURL: root,
            maxInitialTailBytes: 512,
            maxSessionMetadataProbeBytes: 1_024,
            replaysInitialHistory: true
        )
        let update = try XCTUnwrap(monitor.pollResult(now: now).quotaUpdates.first)

        XCTAssertEqual(update.sessionID, "codex-desktop:\(sessionID)")
        XCTAssertEqual(update.tokenActivityUsage?.effectiveTotalTokens, 75)
        XCTAssertNotNil(update.tokenObservationCursor)
    }

    func testLiveMonitorCursorMatchesAuthoritativeScannerWatermark() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cursor-watermark-\(UUID().uuidString)", isDirectory: true)
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date()
        let eventAt = now.addingTimeInterval(-1)
        let timestamp = isoTimestamp(eventAt)
        let sessionID = "019c846a-b85e-7bd3-924b-cc33e3f180d9"
        let filenameDay = ISO8601DateFormatter().string(from: now).prefix(10)
        let sessionURL = sessionsRoot.appendingPathComponent(
            "rollout-\(filenameDay)T23-00-00-\(sessionID).jsonl"
        )
        let tokenLine = #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"model_context_window":258400,"total_token_usage":{"input_tokens":1150,"cached_input_tokens":200,"output_tokens":100,"total_tokens":1250},"last_token_usage":{"input_tokens":200,"cached_input_tokens":25,"output_tokens":50,"total_tokens":250}}}}"#
        let splitIndex = tokenLine.index(tokenLine.endIndex, offsetBy: -23)
        let metaLine = #"{"timestamp":"\#(timestamp)","type":"session_meta","payload":{"id":"\#(sessionID)","originator":"Codex Desktop"}}"#
        try "\(metaLine)\n\(tokenLine[..<splitIndex])"
            .write(to: sessionURL, atomically: true, encoding: .utf8)

        let monitor = CodexDesktopActivityMonitor(
            sessionsRootURL: sessionsRoot,
            replaysInitialHistory: true
        )
        let scanner = CodexTokenActivityScanner(
            sessionRootURLs: [sessionsRoot],
            costUsageCacheRootURL: root.appendingPathComponent("cost-cache", isDirectory: true)
        )
        XCTAssertTrue(monitor.pollResult(now: now).quotaUpdates.isEmpty)
        XCTAssertTrue(scanner.scanDailyActivityResult(now: now, days: 1, progress: nil).watermarks.isEmpty)

        try FileHandle(forWritingTo: sessionURL)
            .appendString(String(tokenLine[splitIndex...]) + "\n")
        let liveUpdate = try XCTUnwrap(monitor.pollResult(now: now).quotaUpdates.first)
        let cursor = try XCTUnwrap(liveUpdate.tokenObservationCursor)
        XCTAssertEqual(liveUpdate.tokenActivityUsage?.effectiveTotalTokens, 1_250)
        XCTAssertEqual(liveUpdate.quota.tokenUsage?.effectiveTotalTokens, 250)

        let result = scanner.scanDailyActivityResult(now: now, days: 1, progress: nil)
        // The daily report counts the observed last-turn delta, while the exact
        // watermark retains the raw cumulative total used to reconcile live state.
        XCTAssertEqual(result.days.compactMap(\.totalTokens).reduce(0, +), 250)
        XCTAssertTrue(result.watermarks.contains { watermark in
            watermark.sourceID == cursor.sourceID
                && watermark.sourceGeneration == cursor.sourceGeneration
                && watermark.sourceStatFingerprint == cursor.sourceStatFingerprint
                && watermark.sourceChangeTimeNanoseconds
                    == cursor.sourceChangeTimeNanoseconds
                && watermark.sourceStatFingerprint != nil
                && watermark.sourceChangeTimeNanoseconds != nil
                && watermark.endOffset == cursor.endOffset
                && watermark.lineFingerprint == cursor.lineFingerprint
                && watermark.totalTokens == 1_250
        })
    }

    func testUnresolvedForkScannerCountsChildLastTurnsBeforePublishingWatermarks() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("unresolved-fork-watermark-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date()
        let firstAt = now.addingTimeInterval(-2)
        let secondAt = now.addingTimeInterval(-1)
        let childSessionID = "019c846a-b85e-7bd3-924b-cc33e3f180e0"
        let missingParentID = "019c846a-b85e-7bd3-924b-cc33e3f180d9"
        let filenameDay = ISO8601DateFormatter().string(from: now).prefix(10)
        let sessionURL = root.appendingPathComponent(
            "rollout-\(filenameDay)T12-00-00-\(childSessionID).jsonl"
        )
        let lines = [
            #"{"timestamp":"\#(isoTimestamp(firstAt))","type":"session_meta","payload":{"id":"\#(childSessionID)","forked_from_id":"\#(missingParentID)","originator":"Codex Desktop"}}"#,
            #"{"timestamp":"\#(isoTimestamp(firstAt))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":900,"cached_input_tokens":0,"output_tokens":0,"total_tokens":900},"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100}}}}"#,
            #"{"timestamp":"\#(isoTimestamp(secondAt))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":950,"cached_input_tokens":0,"output_tokens":0,"total_tokens":950},"last_token_usage":{"input_tokens":50,"cached_input_tokens":0,"output_tokens":0,"total_tokens":50}}}}"#,
        ]
        try lines.joined(separator: "\n").appending("\n")
            .write(to: sessionURL, atomically: true, encoding: .utf8)
        let scanner = CodexTokenActivityScanner(
            sessionRootURLs: [root],
            costUsageCacheRootURL: root.appendingPathComponent("cost-cache", isDirectory: true)
        )

        let result = scanner.scanDailyActivityResult(now: now, days: 1, progress: nil)

        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.days.compactMap(\.totalTokens).reduce(0, +), 150)
        XCTAssertEqual(result.watermarks.count, 1)
        XCTAssertEqual(result.watermarks.map(\.totalTokens), [950])
    }

    func testProductionTokenScannerPreservesWatermarksFromMultipleSessionRoots() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("multi-token-roots-\(UUID().uuidString)", isDirectory: true)
        let firstRoot = root.appendingPathComponent("first", isDirectory: true)
        let secondRoot = root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date()
        let timestamp = isoTimestamp(now.addingTimeInterval(-1))
        let sharedFilename = "rollout-shared-name.jsonl"
        let sessions = [
            (firstRoot, "019c846a-b85e-7bd3-924b-cc33e3f180d9", 100),
            (secondRoot, "019c846a-b85e-7bd3-924b-cc33e3f180e0", 200),
        ]
        for (sessionRoot, sessionID, total) in sessions {
            let lines = [
                #"{"timestamp":"\#(timestamp)","type":"session_meta","payload":{"id":"\#(sessionID)","originator":"Codex Desktop"}}"#,
                #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"model_context_window":258400,"total_token_usage":{"input_tokens":\#(total),"cached_input_tokens":0,"output_tokens":0,"total_tokens":\#(total)},"last_token_usage":{"input_tokens":\#(total),"cached_input_tokens":0,"output_tokens":0,"total_tokens":\#(total)}}}}"#,
            ]
            try lines.joined(separator: "\n").appending("\n")
                .write(
                    to: sessionRoot.appendingPathComponent(sharedFilename),
                    atomically: true,
                    encoding: .utf8
                )
        }

        let scanner = CodexTokenActivityScanner(
            sessionRootURLs: [firstRoot, secondRoot],
            costUsageCacheRootURL: root.appendingPathComponent("cost-cache", isDirectory: true)
        )
        let result = scanner.scanDailyActivityResult(now: now, days: 1, progress: nil)

        XCTAssertEqual(result.days.compactMap(\.totalTokens).reduce(0, +), 300)
        XCTAssertEqual(result.watermarks.count, 2)
        XCTAssertEqual(Set(result.watermarks.compactMap(\.sessionID)), Set(sessions.map(\.1)))
        XCTAssertEqual(Set(result.watermarks.map(\.sourceID)).count, 2)
    }

    func testProductionScannerKeepsExactCursorAcrossSessionArchiveRename() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-rename-watermark-\(UUID().uuidString)", isDirectory: true)
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        let archivedRoot = root.appendingPathComponent("archived_sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archivedRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date()
        let timestamp = isoTimestamp(now.addingTimeInterval(-1))
        let sessionID = "019c846a-b85e-7bd3-924b-cc33e3f180d9"
        let filenameDay = ISO8601DateFormatter().string(from: now).prefix(10)
        let filename = "rollout-\(filenameDay)T12-00-00-\(sessionID).jsonl"
        let activeURL = sessionsRoot.appendingPathComponent(filename)
        let archivedURL = archivedRoot.appendingPathComponent(filename)
        let lines = [
            #"{"timestamp":"\#(timestamp)","type":"session_meta","payload":{"id":"\#(sessionID)","originator":"Codex Desktop"}}"#,
            #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100},"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100}}}}"#,
        ]
        try lines.joined(separator: "\n").appending("\n")
            .write(to: activeURL, atomically: true, encoding: .utf8)
        let scanner = CodexTokenActivityScanner(
            sessionRootURLs: [sessionsRoot, archivedRoot],
            costUsageCacheRootURL: root.appendingPathComponent("cost-cache", isDirectory: true)
        )
        let activeResult = scanner.scanDailyActivityResult(now: now, days: 1, progress: nil)
        let activeWatermark = try XCTUnwrap(activeResult.watermarks.first)

        try FileManager.default.moveItem(at: activeURL, to: archivedURL)
        let archivedResult = scanner.scanDailyActivityResult(now: now, days: 1, progress: nil)
        let archivedWatermark = try XCTUnwrap(archivedResult.watermarks.first)

        XCTAssertEqual(archivedResult.days.compactMap(\.totalTokens).reduce(0, +), 100)
        XCTAssertNotEqual(activeWatermark.sourceID, archivedWatermark.sourceID)
        XCTAssertEqual(activeWatermark.sessionID, archivedWatermark.sessionID)
        XCTAssertEqual(activeWatermark.sourceGeneration, archivedWatermark.sourceGeneration)
        XCTAssertEqual(activeWatermark.endOffset, archivedWatermark.endOffset)
        XCTAssertEqual(activeWatermark.lineFingerprint, archivedWatermark.lineFingerprint)
    }

    func testWatermarkExportRejectsSameInodeRewriteAfterCacheCommit() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("watermark-owner-rewrite-\(UUID().uuidString)", isDirectory: true)
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-23T09:00:00Z"))
        let sessionURL = sessionsRoot.appendingPathComponent(
            "rollout-2026-08-23T08-00-00-watermark-rewrite.jsonl"
        )
        let initialContents = [
            #"{"timestamp":"2026-08-23T07:59:59.000Z","type":"session_meta","payload":{"id":"watermark-rewrite","originator":"Codex Desktop"}}"#,
            #"{"timestamp":"2026-08-23T08:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100},"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100}}}}"#,
        ].joined(separator: "\n").appending("\n")
        let rewrittenContents = initialContents.replacingOccurrences(of: "100", with: "900")
        XCTAssertEqual(initialContents.utf8.count, rewrittenContents.utf8.count)
        try initialContents.write(to: sessionURL, atomically: true, encoding: .utf8)

        let scanner = CodexTokenActivityScanner(
            sessionRootURLs: [sessionsRoot],
            costUsageCacheRootURL: cacheRoot,
            usesAgentSignalCostUsageScanner: true
        )
        let initial = scanner.scanDailyActivityResult(now: now, days: 1, progress: nil)
        XCTAssertTrue(initial.isComplete)
        XCTAssertEqual(initial.watermarks.count, 1)
        let originalGeneration = CostUsageScanner.codexFileMetadata(fileURL: sessionURL).fileId

        let handle = try FileHandle(forWritingTo: sessionURL)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(rewrittenContents.utf8))
        try handle.close()
        XCTAssertEqual(
            CostUsageScanner.codexFileMetadata(fileURL: sessionURL).fileId,
            originalGeneration
        )

        XCTAssertThrowsError(try scanner.agentSignalCostUsageScanWatermarks(through: now))
    }

    func testWatermarkExportRejectsByteIdenticalNewGeneration() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("watermark-owner-replacement-\(UUID().uuidString)", isDirectory: true)
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-23T09:00:00Z"))
        let sessionURL = sessionsRoot.appendingPathComponent(
            "rollout-2026-08-23T08-00-00-watermark-replacement.jsonl"
        )
        let displacedURL = sessionsRoot.appendingPathComponent("displaced.jsonl")
        let contents = [
            #"{"timestamp":"2026-08-23T07:59:59.000Z","type":"session_meta","payload":{"id":"watermark-replacement","originator":"Codex Desktop"}}"#,
            #"{"timestamp":"2026-08-23T08:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100},"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100}}}}"#,
        ].joined(separator: "\n").appending("\n")
        try contents.write(to: sessionURL, atomically: true, encoding: .utf8)

        let scanner = CodexTokenActivityScanner(
            sessionRootURLs: [sessionsRoot],
            costUsageCacheRootURL: cacheRoot,
            usesAgentSignalCostUsageScanner: true
        )
        XCTAssertTrue(scanner.scanDailyActivityResult(now: now, days: 1, progress: nil).isComplete)
        let originalGeneration = CostUsageScanner.codexFileMetadata(fileURL: sessionURL).fileId

        try FileManager.default.moveItem(at: sessionURL, to: displacedURL)
        try FileManager.default.copyItem(at: displacedURL, to: sessionURL)
        XCTAssertNotEqual(
            CostUsageScanner.codexFileMetadata(fileURL: sessionURL).fileId,
            originalGeneration
        )

        XCTAssertThrowsError(try scanner.agentSignalCostUsageScanWatermarks(through: now))
    }

    func testWatermarkExportAllowsStableAppendWithoutCoveringNewBytes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("watermark-owner-append-\(UUID().uuidString)", isDirectory: true)
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-23T09:00:00Z"))
        let sessionURL = sessionsRoot.appendingPathComponent(
            "rollout-2026-08-23T08-00-00-watermark-append.jsonl"
        )
        let initialContents = [
            #"{"timestamp":"2026-08-23T07:59:59.000Z","type":"session_meta","payload":{"id":"watermark-append","originator":"Codex Desktop"}}"#,
            #"{"timestamp":"2026-08-23T08:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100},"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100}}}}"#,
        ].joined(separator: "\n").appending("\n")
        try initialContents.write(to: sessionURL, atomically: true, encoding: .utf8)

        let scanner = CodexTokenActivityScanner(
            sessionRootURLs: [sessionsRoot],
            costUsageCacheRootURL: cacheRoot,
            usesAgentSignalCostUsageScanner: true
        )
        let initialResult = scanner.scanDailyActivityResult(now: now, days: 1, progress: nil)
        let initialWatermark = try XCTUnwrap(initialResult.watermarks.first)

        try FileHandle(forWritingTo: sessionURL).appendString(
            #"{"timestamp":"2026-08-23T08:30:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":150,"cached_input_tokens":0,"output_tokens":0,"total_tokens":150},"last_token_usage":{"input_tokens":50,"cached_input_tokens":0,"output_tokens":0,"total_tokens":50}}}}"# + "\n"
        )
        let preRescanWatermark = try XCTUnwrap(
            scanner.agentSignalCostUsageScanWatermarks(through: now).first
        )
        XCTAssertEqual(preRescanWatermark.sourceGeneration, initialWatermark.sourceGeneration)
        XCTAssertEqual(preRescanWatermark.endOffset, initialWatermark.endOffset)
        XCTAssertEqual(preRescanWatermark.lineFingerprint, initialWatermark.lineFingerprint)
        XCTAssertEqual(preRescanWatermark.totalTokens, 100)

        let rescanned = scanner.scanDailyActivityResult(now: now, days: 1, progress: nil)
        let rescannedWatermark = try XCTUnwrap(rescanned.watermarks.first)
        XCTAssertTrue(rescanned.isComplete)
        XCTAssertEqual(rescanned.days.compactMap(\.totalTokens).reduce(0, +), 150)
        XCTAssertGreaterThan(rescannedWatermark.endOffset, initialWatermark.endOffset)
        XCTAssertEqual(rescannedWatermark.totalTokens, 150)
    }

    func testCostUsageCacheRetainsLatestExactFrontierBeyond4096Events() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("watermark-retention-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date()
        let timestamp = isoTimestamp(now.addingTimeInterval(-1))
        let sessionID = "019c846a-b85e-7bd3-924b-cc33e3f180d9"
        var lines = [
            #"{"timestamp":"\#(timestamp)","type":"session_meta","payload":{"id":"\#(sessionID)","originator":"Codex Desktop"}}"#,
        ]
        for total in 1...4_097 {
            lines.append(
                #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"model_context_window":258400,"total_token_usage":{"input_tokens":\#(total),"cached_input_tokens":0,"output_tokens":0,"total_tokens":\#(total)},"last_token_usage":{"input_tokens":1,"cached_input_tokens":0,"output_tokens":0,"total_tokens":1}}}}"#
            )
        }
        let sessionURL = root.appendingPathComponent("rollout-many-token-events.jsonl")
        try lines.joined(separator: "\n").appending("\n")
            .write(to: sessionURL, atomically: true, encoding: .utf8)

        var options = CostUsageScanner.Options(
            codexSessionsRoot: root,
            cacheRoot: root.appendingPathComponent("cost-cache", isDirectory: true)
        )
        options.refreshMinIntervalSeconds = 0
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: Calendar.current.startOfDay(for: now),
            until: now,
            now: now,
            options: options
        )
        let cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: options.cacheRoot)
        let usage = try XCTUnwrap(cache.files.values.first)

        XCTAssertEqual(usage.tokenEventWatermarks?.count, 1)
        XCTAssertEqual(usage.tokenEventWatermarks?.last?.totalTokens, 4_097)
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
        let usageStatus = try CodexRateLimitFetcher.usageStatus(
            from: response,
            updatedAt: updatedAt,
            source: .unknown
        )
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
        XCTAssertEqual(usageStatus.source, .unknown)
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
        let usageStatus = try CodexRateLimitFetcher.usageStatus(
            from: response,
            updatedAt: updatedAt,
            source: .unknown
        )

        XCTAssertEqual(usageStatus.quota.remainingPercent, 95, accuracy: 0.01)
        XCTAssertEqual(usageStatus.quota.primaryWindow?.windowMinutes, 43_200)
        XCTAssertNil(usageStatus.credits)
    }

    func testCodexRateLimitResetCreditsFetcherScopesRequestAndFiltersInventory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("""
        {
          "tokens": {
            "access_token": "oauth-token",
            "refresh_token": "",
            "account_id": "account-123"
          }
        }
        """.utf8).write(to: root.appendingPathComponent("auth.json"))
        try "chatgpt_base_url = \"https://chatgpt.com/backend-api/\"\n"
            .write(to: root.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CodexRateLimitFetcherURLProtocol.self]
        let session = URLSession(configuration: configuration)
        CodexRateLimitFetcherURLProtocol.handler = { request in
            XCTAssertEqual(
                request.url?.absoluteString,
                "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits"
            )
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.timeoutInterval, 4)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer oauth-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-ID"), "account-123")
            XCTAssertEqual(request.value(forHTTPHeaderField: "OpenAI-Beta"), "codex-1")
            XCTAssertEqual(request.value(forHTTPHeaderField: "originator"), "Codex Desktop")
            let data = Data("""
            {
              "credits": [
                {
                  "id": "expired",
                  "reset_type": "codex_rate_limits",
                  "status": "available",
                  "granted_at": "2026-06-01T00:00:00Z",
                  "expires_at": "2026-06-30T00:00:00Z"
                },
                {
                  "id": "later",
                  "reset_type": "codex_rate_limits",
                  "status": "available",
                  "granted_at": "2026-06-18T00:39:53.731630Z",
                  "expires_at": "2026-07-18T00:39:53.731630Z"
                },
                {
                  "id": "earlier",
                  "reset_type": "codex_rate_limits",
                  "status": "available",
                  "granted_at": "2026-06-12T04:03:43Z",
                  "expires_at": "2026-07-12T04:03:43Z"
                },
                {
                  "id": "redeemed",
                  "reset_type": "codex_rate_limits",
                  "status": "redeemed",
                  "granted_at": "2026-06-10T00:00:00Z",
                  "expires_at": null
                },
                {
                  "id": "no-expiry",
                  "reset_type": "codex_rate_limits",
                  "status": "available",
                  "granted_at": "2026-06-20T00:00:00Z",
                  "expires_at": null
                }
              ],
              "available_count": 3
            }
            """.utf8)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, data)
        }
        defer { CodexRateLimitFetcherURLProtocol.handler = nil }

        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-01T00:00:00Z"))
        let fetcher = CodexRateLimitFetcher(
            environment: ["CODEX_HOME": root.path],
            fileManager: .default,
            session: session
        )
        let snapshot = try await fetcher.fetchRateLimitResetCredits(now: now)
        let inventory = snapshot.availableCredits(at: now)

        XCTAssertEqual(snapshot.availableCount, 3)
        XCTAssertEqual(snapshot.credits.count, 5)
        XCTAssertEqual(inventory.count, 3)
        XCTAssertEqual(inventory[0].expiresAt, ISO8601DateFormatter().date(from: "2026-07-12T04:03:43Z"))
        XCTAssertLessThan(try XCTUnwrap(inventory[0].expiresAt), try XCTUnwrap(inventory[1].expiresAt))
        XCTAssertNil(inventory[2].expiresAt)
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

        let usage = try await fetcher.fetchUsageStatus(
            now: Date(timeIntervalSince1970: 1_781_700_000),
            route: .oauthAPI
        )
        let quota = usage.quota

        XCTAssertEqual(quota.usedPercent ?? -1, 10, accuracy: 0.01)
        XCTAssertEqual(usage.source, .apiKey)
        XCTAssertEqual(try Data(contentsOf: authURL), originalAuth)
    }

    func testCodexRateLimitFetcherUsesManualCookieHeader() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

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

        let fetcher = CodexRateLimitFetcher(
            environment: ["CODEX_HOME": root.path],
            session: session
        )
        let usage = try await fetcher.fetchUsageStatus(
            route: .manualCookie("-H 'Cookie: foo=bar; baz=qux'")
        )

        XCTAssertEqual(usage.quota.usedPercent ?? -1, 25, accuracy: 0.01)
        XCTAssertEqual(usage.source, .manualCookie)
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

        let importer = RecordingOpenAIBrowserCookieImporter(cookieHeader: "unused_cookie=1")
        let fetcher = CodexRateLimitFetcher(
            environment: ["CODEX_HOME": root.path],
            fileManager: .default,
            session: session,
            browserCookieImporter: importer
        )
        let usage = try await fetcher.fetchUsageStatus(route: .oauthAPI)

        XCTAssertEqual(usage.quota.usedPercent ?? -1, 15, accuracy: 0.01)
        XCTAssertEqual(usage.source, .oauth)
        XCTAssertEqual(importer.callCount, 0)
    }

    func testCodexRateLimitFetcherAutomaticRouteUsesImportedBrowserCookie() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

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
            environment: ["CODEX_HOME": root.path],
            session: session,
            browserCookieImporter: FakeOpenAIBrowserCookieImporter(cookieHeader: "auto_cookie=1")
        )
        let usage = try await fetcher.fetchUsageStatus(
            route: .automatic(cookieHeader: nil, importsBrowserCookies: true)
        )

        XCTAssertEqual(usage.quota.usedPercent ?? -1, 35, accuracy: 0.01)
        XCTAssertEqual(usage.source, .browserCookie)
    }

    func testCodexRateLimitFetcherAutomaticCookieFailureFallsBackToOAuthSource() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-07-18T00:00:00Z")
        )

        let auth = try XCTUnwrap(String(data: codexOAuthAuthJSON(
            email: "fallback@example.com",
            accountID: "acct_fallback",
            accessToken: "oauth-fallback-token"
        ), encoding: .utf8))
            .replacingOccurrences(of: "2026-06-01T00:00:00Z", with: "2026-07-11T00:00:00Z")
        try Data(auth.utf8).write(to: root.appendingPathComponent("auth.json"))

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CodexRateLimitFetcherURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let recorder = URLRequestRecorder()
        CodexRateLimitFetcherURLProtocol.handler = { request in
            recorder.append(request)
            if request.url?.path == "/backend-api/me" {
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (response, Data("{\"email\":\"fallback@example.com\"}".utf8))
            }
            if request.value(forHTTPHeaderField: "Cookie") != nil {
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 401,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (response, Data())
            }

            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer oauth-fallback-token"
            )
            let data = Data("""
            {
              "rate_limit": {
                "primary_window": {
                  "used_percent": 45,
                  "reset_at": 1781788782,
                  "limit_window_seconds": 18000
                }
              }
            }
            """.utf8)
            let response = HTTPURLResponse(
                url: request.url!,
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
            session: session,
            clock: { now }
        )
        let usage = try await fetcher.fetchUsageStatus(
            route: .automatic(cookieHeader: "session=expired", importsBrowserCookies: false)
        )

        XCTAssertEqual(usage.quota.usedPercent ?? -1, 45, accuracy: 0.01)
        XCTAssertEqual(usage.source, .oauth)
        XCTAssertEqual(recorder.requests.count, 3)
        XCTAssertEqual(recorder.requests.first?.url?.path, "/backend-api/me")
        XCTAssertEqual(recorder.requests.first?.value(forHTTPHeaderField: "Cookie"), "session=expired")
        XCTAssertEqual(
            recorder.requests.last?.value(forHTTPHeaderField: "Authorization"),
            "Bearer oauth-fallback-token"
        )
    }

    func testCodexRateLimitFetcherRejectsCookieFromDifferentAccountBeforeUsageRequest() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-07-18T00:00:00Z")
        )

        let auth = try XCTUnwrap(String(data: codexOAuthAuthJSON(
            email: "selected@example.com",
            accountID: "acct_selected",
            accessToken: "selected-oauth-token"
        ), encoding: .utf8))
            .replacingOccurrences(of: "2026-06-01T00:00:00Z", with: "2026-07-11T00:00:00Z")
        try Data(auth.utf8).write(to: root.appendingPathComponent("auth.json"))

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CodexRateLimitFetcherURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let recorder = URLRequestRecorder()
        CodexRateLimitFetcherURLProtocol.handler = { request in
            recorder.append(request)
            if request.url?.path == "/backend-api/me" {
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (response, Data("{\"email\":\"other@example.com\"}".utf8))
            }

            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer selected-oauth-token"
            )
            let data = Data("""
            {
              "rate_limit": {
                "primary_window": {
                  "used_percent": 33,
                  "reset_at": 1781788782,
                  "limit_window_seconds": 18000
                }
              }
            }
            """.utf8)
            let response = HTTPURLResponse(
                url: request.url!,
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
            session: session,
            clock: { now }
        )
        let usage = try await fetcher.fetchUsageStatus(
            route: .automatic(cookieHeader: "session=other-account", importsBrowserCookies: false)
        )

        XCTAssertEqual(usage.quota.usedPercent ?? -1, 33, accuracy: 0.01)
        XCTAssertEqual(usage.source, .oauth)
        XCTAssertEqual(recorder.requests.count, 2)
        XCTAssertEqual(recorder.requests.first?.url?.path, "/backend-api/me")
        XCTAssertEqual(recorder.requests.last?.url?.path, "/backend-api/wham/usage")
    }

    func testOpenAIBrowserCookieImporterFiltersCookiesToOfficialSharedScope() throws {
        func cookie(
            name: String,
            domain: String,
            path: String = "/",
            secure: Bool = true,
            expires: Date? = Date().addingTimeInterval(3_600)
        ) throws -> HTTPCookie {
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: name,
                .value: "1",
                .domain: domain,
                .path: path,
            ]
            if secure {
                properties[.secure] = "TRUE"
            }
            if let expires {
                properties[.expires] = expires
            }
            return try XCTUnwrap(HTTPCookie(properties: properties))
        }

        let cookies = try [
            cookie(name: "valid", domain: ".chatgpt.com"),
            cookie(name: "openai", domain: ".openai.com"),
            cookie(name: "subdomain", domain: "auth.chatgpt.com"),
            cookie(name: "pathScoped", domain: ".chatgpt.com", path: "/backend-api"),
            cookie(
                name: "expired",
                domain: ".chatgpt.com",
                expires: Date().addingTimeInterval(-60)
            ),
        ]

        let header = try XCTUnwrap(OpenAIBrowserCookieImporter.cookieHeader(
            from: cookies,
            for: OpenAIBrowserCookieImporter.officialCookieScopeURL
        ))

        XCTAssertTrue(header.contains("valid=1"))
        XCTAssertFalse(header.contains("openai=1"))
        XCTAssertFalse(header.contains("subdomain=1"))
        XCTAssertFalse(header.contains("pathScoped=1"))
        XCTAssertFalse(header.contains("expired=1"))
        XCTAssertNil(OpenAIBrowserCookieImporter.cookieHeader(
            from: [cookies[0]],
            for: URL(string: "http://chatgpt.com/")!
        ))
        XCTAssertNil(OpenAIBrowserCookieImporter.cookieHeader(
            from: [cookies[0]],
            for: URL(string: "https://example.com/")!
        ))
    }

    func testCodexCookieRoutesIgnoreConfiguredBaseURL() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "chatgpt_base_url = \"https://attacker.example/proxy\"\n"
            .write(to: root.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CodexRateLimitFetcherURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let recorder = URLRequestRecorder()
        CodexRateLimitFetcherURLProtocol.handler = { request in
            recorder.append(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data("""
            {
              "rate_limit": {
                "primary_window": {
                  "used_percent": 21,
                  "reset_at": 1781788782,
                  "limit_window_seconds": 18000
                }
              }
            }
            """.utf8))
        }
        defer { CodexRateLimitFetcherURLProtocol.handler = nil }

        let fetcher = CodexRateLimitFetcher(
            environment: ["CODEX_HOME": root.path],
            session: session,
            browserCookieImporter: FakeOpenAIBrowserCookieImporter(cookieHeader: "browser=1")
        )
        _ = try await fetcher.fetchUsageStatus(route: .manualCookie("manual=1"))
        _ = try await fetcher.fetchUsageStatus(
            route: .automatic(cookieHeader: nil, importsBrowserCookies: true)
        )

        XCTAssertEqual(recorder.requests.count, 2)
        XCTAssertTrue(recorder.requests.allSatisfy {
            $0.url?.absoluteString == "https://chatgpt.com/backend-api/wham/usage"
        })
    }

    func testCodexCookieRoutingRejectsCorruptAuthBeforeImportOrRequest() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("{not-json".utf8).write(to: root.appendingPathComponent("auth.json"))

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CodexRateLimitFetcherURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let recorder = URLRequestRecorder()
        CodexRateLimitFetcherURLProtocol.handler = { request in
            recorder.append(request)
            throw URLError(.badServerResponse)
        }
        defer { CodexRateLimitFetcherURLProtocol.handler = nil }

        let importer = RecordingOpenAIBrowserCookieImporter(cookieHeader: "browser=1")
        let fetcher = CodexRateLimitFetcher(
            environment: ["CODEX_HOME": root.path],
            session: session,
            browserCookieImporter: importer
        )
        let routes: [CodexRateLimitFetchRoute] = [
            .automatic(cookieHeader: nil, importsBrowserCookies: true),
            .manualCookie("manual=1"),
        ]
        for route in routes {
            do {
                _ = try await fetcher.fetchUsageStatus(route: route)
                XCTFail("Corrupt auth.json must stop Cookie routing")
            } catch {
                // Expected: invalid or unreadable credentials must not become an unbound Cookie route.
            }
        }

        XCTAssertEqual(importer.callCount, 0)
        XCTAssertTrue(recorder.requests.isEmpty)
    }

    func testCodexUsageRejectsAuthFileChangedBehindSelectedAccount() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try codexOAuthAuthJSON(
            email: "other@example.com",
            accountID: "acct_other",
            accessToken: "other-access"
        ).write(to: root.appendingPathComponent("auth.json"))

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CodexRateLimitFetcherURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let recorder = URLRequestRecorder()
        CodexRateLimitFetcherURLProtocol.handler = { request in
            recorder.append(request)
            throw URLError(.badServerResponse)
        }
        defer { CodexRateLimitFetcherURLProtocol.handler = nil }

        let importer = RecordingOpenAIBrowserCookieImporter(cookieHeader: "browser=1")
        let fetcher = CodexRateLimitFetcher(
            environment: ["CODEX_HOME": root.path],
            session: session,
            browserCookieImporter: importer
        )
        do {
            _ = try await fetcher.fetchUsageStatus(
                route: .automatic(cookieHeader: nil, importsBrowserCookies: true),
                expectedAuthFingerprint: "selected-account-fingerprint"
            )
            XCTFail("A changed auth.json must not be attributed to the selected account")
        } catch CodexRateLimitFetchError.credentialsChanged {
            // Expected before browser import or network access.
        }

        XCTAssertEqual(importer.callCount, 0)
        XCTAssertTrue(recorder.requests.isEmpty)
    }

    func testCodexOAuthRefreshPersistsOriginalAccountWithoutOverwritingSwitchedAccount() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storeURL = root.appendingPathComponent("accounts.json")
        let authURL = root.appendingPathComponent("auth.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let credentialStore = RecordingSecretStore()
        let manager = CodexAccountManager(
            environment: ["CODEX_HOME": root.path],
            fileManager: .default,
            storeURL: storeURL,
            credentialStore: credentialStore
        )
        try codexOAuthAuthJSON(
            email: "alpha@example.com",
            accountID: "acct_alpha",
            accessToken: "alpha-old-access"
        ).write(to: authURL)
        let alpha = try manager.saveCurrentAccount()

        let freshTimestamp = ISO8601DateFormatter().string(from: Date())
        let betaData = try XCTUnwrap(String(data: codexOAuthAuthJSON(
            email: "beta@example.com",
            accountID: "acct_beta",
            accessToken: "beta-access"
        ), encoding: .utf8))
            .replacingOccurrences(of: "2026-06-01T00:00:00Z", with: freshTimestamp)
        try Data(betaData.utf8).write(to: authURL)
        let beta = try manager.saveCurrentAccount()
        _ = try manager.switchToAccount(id: alpha.id)

        let refreshStarted = TestSemaphoreGate()
        let releaseRefresh = TestSemaphoreGate()
        let recorder = URLRequestRecorder()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CodexRateLimitFetcherURLProtocol.self]
        let session = URLSession(configuration: configuration)
        CodexRateLimitFetcherURLProtocol.handler = { request in
            recorder.append(request)
            if request.url?.host == "auth.openai.com" {
                refreshStarted.signal()
                guard releaseRefresh.wait(seconds: 5) else {
                    throw URLError(.timedOut)
                }
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (response, Data("""
                {
                  "access_token": "alpha-refreshed-access",
                  "refresh_token": "alpha-refreshed-refresh"
                }
                """.utf8))
            }
            XCTFail("A stale account refresh must not continue to the usage endpoint")
            throw URLError(.cancelled)
        }
        defer { CodexRateLimitFetcherURLProtocol.handler = nil }

        let fetcher = CodexRateLimitFetcher(
            environment: ["CODEX_HOME": root.path],
            session: session,
            credentialPersistence: manager
        )
        let fetchTask = Task {
            try await fetcher.fetchUsageStatus(route: .oauthAPI)
        }

        var didStartRefresh = false
        for _ in 0..<100 {
            if refreshStarted.tryConsumeSignal() {
                didStartRefresh = true
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(didStartRefresh)

        _ = try manager.switchToAccount(id: beta.id)
        XCTAssertTrue(try String(contentsOf: authURL).contains("beta-access"))
        releaseRefresh.signal()

        do {
            _ = try await fetchTask.value
            XCTFail("The stale alpha refresh must not write into beta auth.json")
        } catch CodexRateLimitFetchError.credentialsChanged {
            // Expected: the refreshed alpha credentials were saved to alpha's slot instead.
        }

        XCTAssertEqual(try manager.currentAccount().accountID, "acct_beta")
        XCTAssertTrue(try String(contentsOf: authURL).contains("beta-access"))
        XCTAssertEqual(
            recorder.requests.filter { $0.url?.host == "auth.openai.com" }.count,
            1
        )

        _ = try manager.switchToAccount(id: alpha.id)
        let restoredAlpha = try String(contentsOf: authURL)
        XCTAssertTrue(restoredAlpha.contains("alpha-refreshed-access"))
        XCTAssertTrue(restoredAlpha.contains("alpha-refreshed-refresh"))
    }

    func testDeletingAccountDuringOAuthRefreshDoesNotResurrectPendingCredentials() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storeURL = root.appendingPathComponent("accounts.json")
        let authURL = root.appendingPathComponent("auth.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = CodexAccountManager(
            environment: ["CODEX_HOME": root.path],
            fileManager: .default,
            storeURL: storeURL,
            credentialStore: RecordingSecretStore()
        )
        try codexOAuthAuthJSON(
            email: "delete@example.com",
            accountID: "acct_delete",
            accessToken: "delete-old-access"
        ).write(to: authURL)
        let deletedAccount = try manager.saveCurrentAccount()
        let betaData = try XCTUnwrap(String(data: codexOAuthAuthJSON(
            email: "keep@example.com",
            accountID: "acct_keep",
            accessToken: "keep-access"
        ), encoding: .utf8))
            .replacingOccurrences(
                of: "2026-06-01T00:00:00Z",
                with: ISO8601DateFormatter().string(from: Date())
            )
        try Data(betaData.utf8).write(to: authURL)
        let keptAccount = try manager.saveCurrentAccount()
        _ = try manager.switchToAccount(id: deletedAccount.id)

        let refreshStarted = TestSemaphoreGate()
        let releaseRefresh = TestSemaphoreGate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CodexRateLimitFetcherURLProtocol.self]
        let session = URLSession(configuration: configuration)
        CodexRateLimitFetcherURLProtocol.handler = { request in
            guard request.url?.host == "auth.openai.com" else {
                throw URLError(.cancelled)
            }
            refreshStarted.signal()
            guard releaseRefresh.wait(seconds: 5) else {
                throw URLError(.timedOut)
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data("""
            {
              "access_token": "deleted-refreshed-access",
              "refresh_token": "deleted-refreshed-refresh"
            }
            """.utf8))
        }
        defer { CodexRateLimitFetcherURLProtocol.handler = nil }

        let fetchTask = Task {
            try await CodexRateLimitFetcher(
                environment: ["CODEX_HOME": root.path],
                session: session,
                credentialPersistence: manager
            ).fetchUsageStatus(route: .oauthAPI)
        }
        var didStartRefresh = false
        for _ in 0..<100 {
            if refreshStarted.tryConsumeSignal() {
                didStartRefresh = true
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(didStartRefresh)

        try manager.removeAccount(id: deletedAccount.id)
        releaseRefresh.signal()
        do {
            _ = try await fetchTask.value
            XCTFail("A removed account refresh must not continue")
        } catch CodexRateLimitFetchError.credentialsChanged {
            // Expected: the remaining account owns active auth.json.
        }

        let state = try manager.loadState()
        XCTAssertEqual(state.savedAccounts.map(\.id), [keptAccount.id])
        XCTAssertEqual(state.activeSavedAccountID, keptAccount.id)
        XCTAssertNil(CodexActiveAuthFileCoordinator.refreshedAuthData(
            replacingAuthFingerprint: deletedAccount.authFingerprint
        ))
        let pendingDirectory = storeURL.deletingLastPathComponent()
            .appendingPathComponent("PendingCodexCredentialRefreshes", isDirectory: true)
        let pendingFiles = (try? FileManager.default.contentsOfDirectory(
            at: pendingDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        XCTAssertTrue(pendingFiles.isEmpty)
    }

    func testCodexOAuthRefreshKeepsActiveRotatedTokenWhenSavedCredentialWriteFails() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let authURL = root.appendingPathComponent("auth.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let credentialStore = RecordingSecretStore()
        let manager = CodexAccountManager(
            environment: ["CODEX_HOME": root.path],
            fileManager: .default,
            storeURL: root.appendingPathComponent("accounts.json"),
            credentialStore: credentialStore
        )
        try codexOAuthAuthJSON(
            email: "active@example.com",
            accountID: "acct_active",
            accessToken: "active-old-access"
        ).write(to: authURL)
        let account = try manager.saveCurrentAccount()
        let betaData = try XCTUnwrap(String(data: codexOAuthAuthJSON(
            email: "beta@example.com",
            accountID: "acct_beta",
            accessToken: "beta-access"
        ), encoding: .utf8))
            .replacingOccurrences(
                of: "2026-06-01T00:00:00Z",
                with: ISO8601DateFormatter().string(from: Date())
            )
        try Data(betaData.utf8).write(to: authURL)
        let beta = try manager.saveCurrentAccount()
        _ = try manager.switchToAccount(id: account.id)
        defer {
            CodexActiveAuthFileCoordinator.clearRefreshedAuthData(
                replacingAuthFingerprint: account.authFingerprint
            )
        }
        credentialStore.setFailsSetOperations(true)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CodexRateLimitFetcherURLProtocol.self]
        let session = URLSession(configuration: configuration)
        CodexRateLimitFetcherURLProtocol.handler = { request in
            if request.url?.host == "auth.openai.com" {
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (response, Data("""
                {
                  "access_token": "active-refreshed-access",
                  "refresh_token": "active-refreshed-refresh"
                }
                """.utf8))
            }
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer active-refreshed-access"
            )
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data("""
            {
              "rate_limit": {
                "primary_window": {
                  "used_percent": 19,
                  "reset_at": 1781788782,
                  "limit_window_seconds": 18000
                }
              }
            }
            """.utf8))
        }
        defer { CodexRateLimitFetcherURLProtocol.handler = nil }

        let usage = try await CodexRateLimitFetcher(
            environment: ["CODEX_HOME": root.path],
            session: session,
            credentialPersistence: manager
        ).fetchUsageStatus(route: .oauthAPI)

        XCTAssertEqual(usage.quota.usedPercent ?? -1, 19, accuracy: 0.01)
        let activeAuth = try String(contentsOf: authURL)
        XCTAssertTrue(activeAuth.contains("active-refreshed-access"))
        XCTAssertTrue(activeAuth.contains("active-refreshed-refresh"))

        // Simulate an app restart by discarding the in-memory rescue copy.
        CodexActiveAuthFileCoordinator.clearRefreshedAuthData(
            replacingAuthFingerprint: account.authFingerprint
        )
        _ = try manager.switchToAccount(id: beta.id)
        XCTAssertTrue(try String(contentsOf: authURL).contains("beta-access"))
        let restartedManager = CodexAccountManager(
            environment: ["CODEX_HOME": root.path],
            fileManager: .default,
            storeURL: root.appendingPathComponent("accounts.json"),
            credentialStore: credentialStore
        )
        _ = try restartedManager.switchToAccount(id: account.id)
        let restoredActiveAuth = try String(contentsOf: authURL)
        XCTAssertTrue(restoredActiveAuth.contains("active-refreshed-access"))
        XCTAssertTrue(restoredActiveAuth.contains("active-refreshed-refresh"))
    }

    func testExternalSameAccountAuthChangeSurvivesKeychainFailureSwitchAndRestart() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storeURL = root.appendingPathComponent("accounts.json")
        let authURL = root.appendingPathComponent("auth.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let credentialStore = RecordingSecretStore()
        let manager = CodexAccountManager(
            environment: ["CODEX_HOME": root.path],
            fileManager: .default,
            storeURL: storeURL,
            credentialStore: credentialStore
        )
        try codexOAuthAuthJSON(
            email: "external-save@example.com",
            accountID: "acct_external_save",
            accessToken: "external-save-old"
        ).write(to: authURL)
        let alpha = try manager.saveCurrentAccount()
        defer {
            CodexActiveAuthFileCoordinator.clearRefreshedAuthData(
                replacingAuthFingerprint: alpha.authFingerprint
            )
        }
        try codexOAuthAuthJSON(
            email: "external-beta@example.com",
            accountID: "acct_external_beta",
            accessToken: "external-beta-access"
        ).write(to: authURL)
        let beta = try manager.saveCurrentAccount()
        _ = try manager.switchToAccount(id: alpha.id)

        let externalAuth = codexOAuthAuthJSON(
            email: "external-save@example.com",
            accountID: "acct_external_save",
            accessToken: "external-save-new"
        )
        try externalAuth.write(to: authURL, options: .atomic)
        credentialStore.setFailsSetOperations(true)

        _ = try manager.switchToAccount(id: beta.id)
        XCTAssertTrue(try String(contentsOf: authURL).contains("external-beta-access"))
        CodexActiveAuthFileCoordinator.clearRefreshedAuthData(
            replacingAuthFingerprint: alpha.authFingerprint
        )

        let restartedManager = CodexAccountManager(
            environment: ["CODEX_HOME": root.path],
            fileManager: .default,
            storeURL: storeURL,
            credentialStore: credentialStore
        )
        _ = try restartedManager.switchToAccount(id: alpha.id)
        XCTAssertEqual(try Data(contentsOf: authURL), externalAuth)
    }

    @MainActor
    func testModelAccountSwitchDuringOAuthRefreshPreservesRotatedOriginalToken() async throws {
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let storeURL = fixture.directory.appendingPathComponent("accounts.json")
        let authURL = fixture.directory.appendingPathComponent("auth.json")
        let credentialStore = RecordingSecretStore()
        let manager = CodexAccountManager(
            environment: ["CODEX_HOME": fixture.directory.path],
            fileManager: .default,
            storeURL: storeURL,
            credentialStore: credentialStore
        )

        try codexOAuthAuthJSON(
            email: "alpha@example.com",
            accountID: "acct_alpha",
            accessToken: "alpha-old-access"
        ).write(to: authURL)
        let alpha = try manager.saveCurrentAccount()
        let betaData = try XCTUnwrap(String(data: codexOAuthAuthJSON(
            email: "beta@example.com",
            accountID: "acct_beta",
            accessToken: "beta-access"
        ), encoding: .utf8))
            .replacingOccurrences(
                of: "2026-06-01T00:00:00Z",
                with: ISO8601DateFormatter().string(from: Date())
            )
        try Data(betaData.utf8).write(to: authURL)
        let beta = try manager.saveCurrentAccount()
        _ = try manager.switchToAccount(id: alpha.id)

        let refreshStarted = TestSemaphoreGate()
        let releaseRefresh = TestSemaphoreGate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CodexRateLimitFetcherURLProtocol.self]
        let session = URLSession(configuration: configuration)
        CodexRateLimitFetcherURLProtocol.handler = { request in
            if request.url?.host == "auth.openai.com" {
                refreshStarted.signal()
                guard releaseRefresh.wait(seconds: 5) else {
                    throw URLError(.timedOut)
                }
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (response, Data("""
                {
                  "access_token": "alpha-refreshed-access",
                  "refresh_token": "alpha-refreshed-refresh"
                }
                """.utf8))
            }
            if request.url?.path.contains("rate-limit-reset-credits") == true {
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (response, Data("{\"credits\":[],\"available_count\":0}".utf8))
            }

            let authorization = request.value(forHTTPHeaderField: "Authorization")
            let usedPercent = authorization == "Bearer beta-access" ? 72 : 33
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data("""
            {
              "rate_limit": {
                "primary_window": {
                  "used_percent": \(usedPercent),
                  "reset_at": 1781788782,
                  "limit_window_seconds": 18000
                }
              }
            }
            """.utf8))
        }
        defer { CodexRateLimitFetcherURLProtocol.handler = nil }

        let model = MenuBarStatusModel(
            store: fixture.store,
            codexDesktopActivityMonitor: CodexDesktopActivityMonitor(replaysInitialHistory: false),
            codexAccountManager: manager,
            codexUsageSnapshotStore: CodexAccountUsageSnapshotStore(
                fileURL: fixture.directory.appendingPathComponent("usage.json")
            ),
            codexRateLimitFetcher: CodexRateLimitFetcher(
                environment: ["CODEX_HOME": fixture.directory.path],
                session: session,
                credentialPersistence: manager
            )
        )
        model.codexUsageDataSource = .oauthAPI
        model.isCodexDesktopMonitoringEnabled = true
        model.isMonitoringPaused = false
        model.pollCodexRateLimitsIfNeeded(force: true)

        var didStartRefresh = false
        for _ in 0..<100 {
            if refreshStarted.tryConsumeSignal() {
                didStartRefresh = true
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(didStartRefresh)

        model.switchCodexAccount(beta)
        releaseRefresh.signal()
        for _ in 0..<200 {
            if !model.isCodexRateLimitFetchInFlight,
               model.codexActiveSavedAccountID == beta.id,
               model.latestAgentQuota?.usedPercent == 72 {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertFalse(model.isCodexRateLimitFetchInFlight)
        XCTAssertEqual(model.codexActiveSavedAccountID, beta.id)
        XCTAssertEqual(model.latestAgentQuota?.usedPercent ?? -1, 72, accuracy: 0.01)
        XCTAssertTrue(try String(contentsOf: authURL).contains("beta-access"))

        model.switchCodexAccount(alpha)
        for _ in 0..<200 {
            if !model.isCodexRateLimitFetchInFlight,
               model.codexActiveSavedAccountID == alpha.id,
               model.latestAgentQuota?.usedPercent == 33 {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let restoredAlpha = try String(contentsOf: authURL)
        XCTAssertTrue(restoredAlpha.contains("alpha-refreshed-access"))
        XCTAssertTrue(restoredAlpha.contains("alpha-refreshed-refresh"))
    }

    func testCodexOAuthRefreshDistinguishesTransientServerFailureFromRejectedToken() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try codexOAuthAuthJSON(
            email: "refresh@example.com",
            accountID: "acct_refresh",
            accessToken: "old-access"
        ).write(to: root.appendingPathComponent("auth.json"))

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CodexRateLimitFetcherURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let fetcher = CodexRateLimitFetcher(
            environment: ["CODEX_HOME": root.path],
            session: session
        )
        defer { CodexRateLimitFetcherURLProtocol.handler = nil }

        CodexRateLimitFetcherURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 503,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }
        do {
            _ = try await fetcher.fetchUsageStatus(route: .oauthAPI)
            XCTFail("A refresh service outage must fail")
        } catch CodexRateLimitFetchError.serverError(let statusCode) {
            XCTAssertEqual(statusCode, 503)
        }

        CodexRateLimitFetcherURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }
        do {
            _ = try await fetcher.fetchUsageStatus(route: .oauthAPI)
            XCTFail("A rejected refresh token must fail")
        } catch CodexRateLimitFetchError.refreshRejected {
            // Expected permanent authentication failure.
        }
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

    func testCodexAccountManagerLoadingMigratedStateDoesNotReadCredentials() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storeURL = root.appendingPathComponent("accounts.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let authURL = root.appendingPathComponent("auth.json")
        let credentialStore = RecordingSecretStore()
        let manager = CodexAccountManager(
            environment: ["CODEX_HOME": root.path],
            fileManager: .default,
            storeURL: storeURL,
            credentialStore: credentialStore
        )

        try codexOAuthAuthJSON(
            email: "personal@example.com",
            accountID: "acct_personal",
            accessToken: "personal-access-token"
        ).write(to: authURL)
        _ = try manager.saveCurrentAccount()

        try codexOAuthAuthJSON(
            email: "work@example.com",
            accountID: "acct_work",
            accessToken: "work-access-token"
        ).write(to: authURL)
        _ = try manager.saveCurrentAccount()

        credentialStore.resetRecordedCalls()
        let state = try manager.loadState()

        XCTAssertEqual(state.savedAccounts.count, 2)
        XCTAssertEqual(credentialStore.dataReadKeys, [])
        XCTAssertEqual(credentialStore.setKeys, [])
    }

    func testCodexAccountManagerRefreshSkipsKeychainWhenSavedCredentialIsCurrent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storeURL = root.appendingPathComponent("accounts.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let authURL = root.appendingPathComponent("auth.json")
        let credentialStore = RecordingSecretStore()
        let manager = CodexAccountManager(
            environment: ["CODEX_HOME": root.path],
            fileManager: .default,
            storeURL: storeURL,
            credentialStore: credentialStore
        )
        try codexOAuthAuthJSON(
            email: "current@example.com",
            accountID: "acct_current",
            accessToken: "current-access-token"
        ).write(to: authURL)
        let saved = try manager.saveCurrentAccount()

        credentialStore.resetRecordedCalls()
        let refreshed = try manager.refreshSavedCurrentAccountIfPossible()

        XCTAssertEqual(refreshed?.id, saved.id)
        XCTAssertEqual(credentialStore.dataReadKeys, [])
        XCTAssertEqual(credentialStore.setKeys, [])
    }

    func testCodexAccountManagerSwitchReadsOnlyTargetCredentialWhenCurrentCredentialIsUnchanged() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storeURL = root.appendingPathComponent("accounts.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let authURL = root.appendingPathComponent("auth.json")
        let credentialStore = RecordingSecretStore()
        let manager = CodexAccountManager(
            environment: ["CODEX_HOME": root.path],
            fileManager: .default,
            storeURL: storeURL,
            credentialStore: credentialStore
        )

        let personalAuth = codexOAuthAuthJSON(
            email: "personal@example.com",
            accountID: "acct_personal",
            accessToken: "personal-access-token"
        )
        try personalAuth.write(to: authURL)
        let personal = try manager.saveCurrentAccount()

        try codexOAuthAuthJSON(
            email: "work@example.com",
            accountID: "acct_work",
            accessToken: "work-access-token"
        ).write(to: authURL)
        _ = try manager.saveCurrentAccount()

        credentialStore.resetRecordedCalls()
        _ = try manager.switchToAccount(id: personal.id)

        XCTAssertEqual(credentialStore.dataReadKeys, [try XCTUnwrap(personal.credentialReference)])
        XCTAssertEqual(credentialStore.setKeys, [])
        XCTAssertEqual(try Data(contentsOf: authURL), personalAuth)
    }

    func testCodexAccountManagerSwitchPersistsCurrentCredentialOnlyWhenItChanged() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storeURL = root.appendingPathComponent("accounts.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let authURL = root.appendingPathComponent("auth.json")
        let credentialStore = RecordingSecretStore()
        let manager = CodexAccountManager(
            environment: ["CODEX_HOME": root.path],
            fileManager: .default,
            storeURL: storeURL,
            credentialStore: credentialStore
        )

        let personalAuth = codexOAuthAuthJSON(
            email: "personal@example.com",
            accountID: "acct_personal",
            accessToken: "personal-access-token"
        )
        try personalAuth.write(to: authURL)
        let personal = try manager.saveCurrentAccount()

        try codexOAuthAuthJSON(
            email: "work@example.com",
            accountID: "acct_work",
            accessToken: "original-work-access-token"
        ).write(to: authURL)
        let work = try manager.saveCurrentAccount()

        let refreshedWorkAuth = codexOAuthAuthJSON(
            email: "work@example.com",
            accountID: "acct_work",
            accessToken: "refreshed-work-access-token"
        )
        try refreshedWorkAuth.write(to: authURL)

        credentialStore.resetRecordedCalls()
        _ = try manager.switchToAccount(id: personal.id)

        XCTAssertEqual(credentialStore.dataReadKeys, [try XCTUnwrap(personal.credentialReference)])
        XCTAssertEqual(credentialStore.setKeys, [try XCTUnwrap(work.credentialReference)])

        _ = try manager.switchToAccount(id: work.id)
        XCTAssertEqual(try Data(contentsOf: authURL), refreshedWorkAuth)
    }

    func testCodexAccountManagerReauthenticatingExistingAccountDoesNotScanSavedCredentials() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storeURL = root.appendingPathComponent("accounts.json")
        let managedHomeRootURL = root.appendingPathComponent("managed-homes", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let authURL = root.appendingPathComponent("auth.json")
        let originalAuth = codexOAuthAuthJSON(
            email: "user@example.com",
            accountID: "acct_user",
            accessToken: "original-access-token"
        )
        try originalAuth.write(to: authURL)

        let credentialStore = RecordingSecretStore()
        let initialManager = CodexAccountManager(
            environment: ["CODEX_HOME": root.path],
            fileManager: .default,
            storeURL: storeURL,
            managedHomeRootURL: managedHomeRootURL,
            credentialStore: credentialStore
        )
        let originalAccount = try initialManager.saveCurrentAccount()

        let refreshedAuth = codexOAuthAuthJSON(
            email: "user@example.com",
            accountID: "acct_user",
            accessToken: "refreshed-access-token"
        )
        credentialStore.setFailsSetOperations(true)
        try initialManager.persistRefreshedAuthData(
            refreshedAuth,
            replacingAuthFingerprint: originalAccount.authFingerprint
        )
        credentialStore.setFailsSetOperations(false)
        XCTAssertNotNil(CodexActiveAuthFileCoordinator.refreshedAuthData(
            replacingAuthFingerprint: originalAccount.authFingerprint
        ))
        let loginRunner = FakeCodexAccountLoginRunner(authData: refreshedAuth)
        let manager = CodexAccountManager(
            environment: ["CODEX_HOME": root.path],
            fileManager: .default,
            storeURL: storeURL,
            managedHomeRootURL: managedHomeRootURL,
            loginRunner: loginRunner,
            credentialStore: credentialStore
        )

        credentialStore.resetRecordedCalls()
        let refreshedAccount = try await manager.authenticateManagedAccount()

        XCTAssertEqual(refreshedAccount.id, originalAccount.id)
        XCTAssertEqual(credentialStore.dataReadKeys, [])
        XCTAssertEqual(credentialStore.setKeys, [try XCTUnwrap(originalAccount.credentialReference)])
        XCTAssertNil(CodexActiveAuthFileCoordinator.refreshedAuthData(
            replacingAuthFingerprint: originalAccount.authFingerprint
        ))
        let pendingDirectory = storeURL.deletingLastPathComponent()
            .appendingPathComponent("PendingCodexCredentialRefreshes", isDirectory: true)
        XCTAssertTrue(((try? FileManager.default.contentsOfDirectory(
            at: pendingDirectory,
            includingPropertiesForKeys: nil
        )) ?? []).isEmpty)
    }

    func testCodexAccountManagerUpdatesExistingAccountAndRemovesActiveAuthWhenLastSavedAccountIsDeleted() throws {
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
        XCTAssertNil(removedState.currentAccount)
        XCTAssertNil(removedState.activeSavedAccountID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: authURL.path))
    }

    func testCodexAccountManagerRemovingActiveAccountSwitchesToNextSavedAccount() throws {
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

        XCTAssertEqual(try manager.loadState().activeSavedAccountID, work.id)

        try manager.removeAccount(id: work.id)

        let state = try manager.loadState()
        XCTAssertEqual(state.savedAccounts.map(\.id), [personal.id])
        XCTAssertEqual(state.currentAccount?.email, "personal@example.com")
        XCTAssertEqual(state.activeSavedAccountID, personal.id)
        XCTAssertEqual(try Data(contentsOf: authURL), personalAuth)
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

    func testCodexAccountManagerTimeoutErrorIncludesLoginOutput() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storeURL = root.appendingPathComponent("accounts.json")
        let managedHomeRootURL = root.appendingPathComponent("managed-homes", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let loginOutput = """
        Starting local login server on http://localhost:1455.
        If your browser did not open, navigate to this URL to authenticate:

        https://auth.openai.com/oauth/authorize?client_id=test
        """
        let loginRunner = FakeCodexAccountLoginRunner(
            authData: nil,
            result: CodexAccountLoginResult(outcome: .timedOut, output: loginOutput)
        )
        let manager = CodexAccountManager(
            environment: ["CODEX_HOME": root.path],
            fileManager: .default,
            storeURL: storeURL,
            managedHomeRootURL: managedHomeRootURL,
            loginRunner: loginRunner
        )

        do {
            _ = try await manager.authenticateManagedAccount()
            XCTFail("Expected Codex login timeout")
        } catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("Codex login timed out"))
            XCTAssertTrue(message.contains("https://auth.openai.com/oauth/authorize?client_id=test"))
            XCTAssertTrue(message.contains("Save Current"))
        }
    }

    func testCodexAccountLoginRunnerExtractsAuthenticationURL() {
        let output = """
        Starting local login server on http://localhost:1455.
        If your browser did not open, navigate to this URL to authenticate:

        https://auth.openai.com/oauth/authorize?client_id=test&state=abc123.
        """

        XCTAssertEqual(
            CodexAccountLoginRunner.authenticationURL(in: output)?.absoluteString,
            "https://auth.openai.com/oauth/authorize?client_id=test&state=abc123"
        )
        XCTAssertNil(CodexAccountLoginRunner.authenticationURL(in: "Open https://example.com instead."))
    }

    func testCodexExecutableResolverAcceptsCodexCLIPathAlias() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let binURL = root.appendingPathComponent("codex", isDirectory: false)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "#!/bin/sh\nexit 0\n".write(to: binURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binURL.path)

        XCTAssertEqual(
            CodexExecutableResolver.resolve(environment: ["CODEX_CLI_PATH": binURL.path]),
            binURL.path
        )
    }

    func testCodexExecutableResolverCanUseLoginShellPathWhenRequested() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        let codexURL = binDir.appendingPathComponent("codex", isDirectory: false)
        let shellURL = root.appendingPathComponent("fake-shell", isDirectory: false)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "#!/bin/sh\nexit 0\n".write(to: codexURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codexURL.path)

        let shellScript = """
        #!/bin/sh
        last=""
        for arg in "$@"; do
          last="$arg"
        done
        PATH="$CODEX_TEST_LOGIN_BIN:/usr/bin:/bin" /bin/sh -c "$last"
        """
        try shellScript.write(to: shellURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shellURL.path)

        XCTAssertEqual(
            CodexExecutableResolver.resolve(
                environment: [
                    "SHELL": shellURL.path,
                    "PATH": "/usr/bin:/bin",
                    "CODEX_TEST_LOGIN_BIN": binDir.path
                ],
                includeLoginShellLookup: true
            ),
            codexURL.path
        )
    }

    func testCodexExecutableResolverFindsChatGPTAndLegacyAppBundles() {
        let homeURL = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        let candidates = [
            "/Users/tester/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Users/tester/Applications/Codex.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex"
        ]

        for candidate in candidates {
            let fileManager = ExecutablePathFileManager(
                homeDirectory: homeURL,
                executablePaths: [candidate]
            )
            XCTAssertEqual(
                CodexExecutableResolver.resolve(
                    environment: ["PATH": "/test-empty"],
                    fileManager: fileManager
                ),
                candidate
            )
        }

        let allBundlesFileManager = ExecutablePathFileManager(
            homeDirectory: homeURL,
            executablePaths: Set(candidates)
        )
        XCTAssertEqual(
            CodexExecutableResolver.resolve(
                environment: ["PATH": "/test-empty"],
                fileManager: allBundlesFileManager
            ),
            candidates[0]
        )
    }

    func testCodexExecutableResolverKeepsExplicitAndPATHAheadOfAppBundles() {
        let explicit = "/test-explicit/codex"
        let pathBinary = "/test-path/codex"
        let bundled = "/Applications/ChatGPT.app/Contents/Resources/codex"
        let fileManager = ExecutablePathFileManager(
            homeDirectory: URL(fileURLWithPath: "/Users/tester", isDirectory: true),
            executablePaths: [explicit, pathBinary, bundled]
        )

        XCTAssertEqual(
            CodexExecutableResolver.resolve(
                environment: [
                    "CODEX_BINARY": explicit,
                    "PATH": "/test-path"
                ],
                fileManager: fileManager
            ),
            explicit
        )
        XCTAssertEqual(
            CodexExecutableResolver.resolve(
                environment: ["PATH": "/test-path"],
                fileManager: fileManager
            ),
            pathBinary
        )
    }

    @MainActor
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

        let gammaAuth = codexOAuthAuthJSON(
            email: "shared@example.com",
            accountID: "acct_gamma",
            accessToken: "gamma-access-token"
        )
        try gammaAuth.write(to: authURL)
        let gamma = try manager.saveCurrentAccount()

        let usageStore = CodexAccountUsageSnapshotStore(fileURL: usageStoreURL)
        let alphaQuota = codexQuotaFixture(remainingPercent: 84, updatedAt: 1_782_500_100)
        let betaQuota = codexQuotaFixture(remainingPercent: 42, updatedAt: 1_782_500_200)
        let alphaResetCredits = codexResetCreditsFixture(
            count: 1,
            updatedAt: 1_782_500_100,
            lifetimeDays: 365
        )
        let betaResetCredits = codexResetCreditsFixture(
            count: 2,
            updatedAt: 1_782_500_200,
            lifetimeDays: 365
        )
        let alphaUsageFetchState = CodexUsageFetchState(
            source: .browserCookie,
            lastSuccessfulAt: Date(timeIntervalSince1970: 1_782_500_100),
            lastAttemptedAt: Date(timeIntervalSince1970: 1_782_500_100),
            errorMessage: nil,
            isStale: false
        )
        let betaUsageFetchState = CodexUsageFetchState(
            source: .oauth,
            lastSuccessfulAt: Date(timeIntervalSince1970: 1_782_500_200),
            lastAttemptedAt: Date(timeIntervalSince1970: 1_782_500_250),
            errorMessage: "Timed out",
            isStale: true
        )
        let alphaResetFetchState = CodexResetCreditsFetchState(
            lastSuccessfulAt: Date(timeIntervalSince1970: 1_782_500_100),
            lastAttemptedAt: Date(timeIntervalSince1970: 1_782_500_100),
            errorMessage: nil,
            isStale: false
        )
        let betaResetFetchState = CodexResetCreditsFetchState(
            lastSuccessfulAt: Date(timeIntervalSince1970: 1_782_500_200),
            lastAttemptedAt: Date(timeIntervalSince1970: 1_782_500_250),
            errorMessage: "Server error",
            isStale: true
        )
        usageStore.store(
            account: alphaCurrent,
            quota: alphaQuota,
            credits: nil,
            resetCredits: alphaResetCredits,
            usageFetchState: alphaUsageFetchState,
            resetCreditsFetchState: alphaResetFetchState,
            tokenUsage: AgentTokenUsage(totalTokens: 1_000),
            tokenActivityCacheVersion: CodexTokenActivityScanner.currentCacheVersion,
            tokenActivityDays: [CodexTokenActivityDay(day: Date(timeIntervalSince1970: 1_782_432_000), totalTokens: 1_000)]
        )
        usageStore.store(
            account: betaCurrent,
            quota: betaQuota,
            credits: nil,
            resetCredits: betaResetCredits,
            usageFetchState: betaUsageFetchState,
            resetCreditsFetchState: betaResetFetchState,
            tokenUsage: AgentTokenUsage(totalTokens: 2_000),
            tokenActivityCacheVersion: CodexTokenActivityScanner.currentCacheVersion,
            tokenActivityDays: [CodexTokenActivityDay(day: Date(timeIntervalSince1970: 1_782_432_000), totalTokens: 2_000)]
        )

        _ = try manager.switchToAccount(id: alpha.id)
        let loadedAlpha = try XCTUnwrap(try manager.loadState().currentAccount)
        XCTAssertEqual(usageStore.snapshot(for: loadedAlpha)?.quota?.remainingPercent, 84)
        XCTAssertEqual(usageStore.snapshot(for: loadedAlpha)?.resetCredits?.availableCount, 1)
        XCTAssertEqual(usageStore.snapshot(for: loadedAlpha)?.tokenUsage?.totalTokens, 1_000)
        XCTAssertEqual(usageStore.snapshot(for: loadedAlpha)?.tokenActivityDays.first?.totalTokens, 1_000)

        _ = try manager.switchToAccount(id: beta.id)
        let loadedBeta = try XCTUnwrap(try manager.loadState().currentAccount)
        XCTAssertEqual(usageStore.snapshot(for: loadedBeta)?.quota?.remainingPercent, 42)
        XCTAssertEqual(usageStore.snapshot(for: loadedBeta)?.resetCredits?.availableCount, 2)
        XCTAssertEqual(usageStore.snapshot(for: loadedBeta)?.tokenUsage?.totalTokens, 2_000)
        XCTAssertEqual(usageStore.snapshot(for: loadedBeta)?.tokenActivityDays.first?.totalTokens, 2_000)

        let defaults = UserDefaults.standard
        let originalMonitoring = defaults.object(forKey: "isCodexDesktopMonitoringEnabled")
        defaults.set(false, forKey: "isCodexDesktopMonitoringEnabled")
        defer {
            if let originalMonitoring {
                defaults.set(originalMonitoring, forKey: "isCodexDesktopMonitoringEnabled")
            } else {
                defaults.removeObject(forKey: "isCodexDesktopMonitoringEnabled")
            }
        }

        let signalStore = SignalStateStore(stateFileURL: root.appendingPathComponent("status.json"))
        let model = MenuBarStatusModel(
            store: signalStore,
            codexAccountManager: manager,
            codexUsageSnapshotStore: usageStore
        )
        model.appLanguage = .english

        XCTAssertEqual(model.codexActiveSavedAccountID, beta.id)
        XCTAssertEqual(model.latestAgentQuota?.remainingPercent, 42)
        XCTAssertEqual(model.latestCodexResetCredits?.availableCount, 2)
        XCTAssertEqual(model.codexResetCreditsPresentation()?.availableText, "2 available")
        XCTAssertEqual(model.codexUsageFetchState, betaUsageFetchState)
        XCTAssertEqual(model.codexResetCreditsFetchState, betaResetFetchState)

        model.switchCodexAccount(alpha)
        XCTAssertEqual(model.codexActiveSavedAccountID, alpha.id)
        XCTAssertEqual(model.latestAgentQuota?.remainingPercent, 84)
        XCTAssertEqual(model.latestCodexResetCredits?.availableCount, 1)
        XCTAssertEqual(model.codexResetCreditsPresentation()?.availableText, "1 available")
        XCTAssertEqual(model.codexUsageFetchState?.source, alphaUsageFetchState.source)
        XCTAssertEqual(model.codexUsageFetchState?.lastSuccessfulAt, alphaUsageFetchState.lastSuccessfulAt)
        XCTAssertTrue(model.codexUsageFetchState?.isStale ?? false)
        XCTAssertEqual(
            model.codexResetCreditsFetchState?.lastSuccessfulAt,
            alphaResetFetchState.lastSuccessfulAt
        )
        XCTAssertTrue(model.codexResetCreditsFetchState?.isStale ?? false)

        model.switchCodexAccount(gamma)
        XCTAssertEqual(model.codexActiveSavedAccountID, gamma.id)
        XCTAssertNil(model.latestAgentQuota)
        XCTAssertNil(model.latestCodexResetCredits)
        XCTAssertNil(model.codexResetCreditsPresentation())
        XCTAssertNil(model.codexUsageFetchState)
        XCTAssertNil(model.codexResetCreditsFetchState)

        model.switchCodexAccount(beta)
        XCTAssertEqual(model.codexActiveSavedAccountID, beta.id)
        XCTAssertEqual(model.latestAgentQuota?.remainingPercent, 42)
        XCTAssertEqual(model.latestCodexResetCredits?.availableCount, 2)
        XCTAssertEqual(model.codexResetCreditsPresentation()?.availableText, "2 available")
        XCTAssertEqual(model.codexUsageFetchState, betaUsageFetchState)
        XCTAssertEqual(model.codexResetCreditsFetchState, betaResetFetchState)
    }

    @MainActor
    func testAccountSnapshotWithoutTodayKeepsPersistedLiveTokensVisible() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("token-snapshot-yesterday-\(UUID().uuidString)", isDirectory: true)
        let authURL = root.appendingPathComponent("auth.json")
        let accountStoreURL = root.appendingPathComponent("accounts.json")
        let usageStoreURL = root.appendingPathComponent("usage.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try codexOAuthAuthJSON(
            email: "snapshot@example.com",
            accountID: "acct_snapshot",
            accessToken: "snapshot-access"
        ).write(to: authURL)
        let manager = CodexAccountManager(
            environment: ["CODEX_HOME": root.path],
            fileManager: .default,
            storeURL: accountStoreURL
        )
        _ = try manager.saveCurrentAccount()
        let account = try XCTUnwrap(try manager.loadState().currentAccount)
        let today = Calendar.current.startOfDay(for: Date())
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today) ?? today
        let usageStore = CodexAccountUsageSnapshotStore(fileURL: usageStoreURL)
        usageStore.store(
            account: account,
            quota: nil,
            credits: nil,
            tokenUsage: AgentTokenUsage(totalTokens: 900),
            tokenActivityCacheVersion: CodexTokenActivityScanner.currentCacheVersion,
            tokenActivityDays: [CodexTokenActivityDay(day: yesterday, totalTokens: 5_000)]
        )

        let model = MenuBarStatusModel(
            store: SignalStateStore(stateFileURL: root.appendingPathComponent("status.json")),
            codexDesktopActivityMonitor: CodexDesktopActivityMonitor(replaysInitialHistory: false),
            codexAccountManager: manager,
            codexUsageSnapshotStore: usageStore
        )

        XCTAssertEqual(model.tokenActivityTotal(for: .today), 900)
        XCTAssertEqual(model.tokenActivityTotal(for: .last30Days), 5_900)

        model.updateLatestAgentTokenUsage(
            AgentTokenUsage(totalTokens: 950),
            sessionID: "identified-session",
            updatedAt: Date()
        )
        XCTAssertEqual(model.tokenActivityTotal(for: .today), 950)
        XCTAssertEqual(model.tokenActivityTotal(for: .last30Days), 5_950)
    }

    @MainActor
    func testLegacyUnscopedScalarDoesNotDoubleCountMultipleIdentifiedSessions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-multi-session-\(UUID().uuidString)", isDirectory: true)
        let authURL = root.appendingPathComponent("auth.json")
        let usageStoreURL = root.appendingPathComponent("usage.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try codexOAuthAuthJSON(
            email: "legacy-multi@example.com",
            accountID: "acct_legacy_multi",
            accessToken: "legacy-multi-access"
        ).write(to: authURL)
        let manager = CodexAccountManager(
            environment: ["CODEX_HOME": root.path],
            fileManager: .default,
            storeURL: root.appendingPathComponent("accounts.json")
        )
        _ = try manager.saveCurrentAccount()
        let account = try XCTUnwrap(try manager.loadState().currentAccount)
        let usageStore = CodexAccountUsageSnapshotStore(fileURL: usageStoreURL)
        usageStore.store(
            account: account,
            quota: nil,
            credits: nil,
            tokenUsage: AgentTokenUsage(totalTokens: 900),
            tokenActivityCacheVersion: CodexTokenActivityScanner.currentCacheVersion,
            tokenActivityDays: []
        )

        let model = MenuBarStatusModel(
            store: SignalStateStore(stateFileURL: root.appendingPathComponent("status.json")),
            codexDesktopActivityMonitor: CodexDesktopActivityMonitor(replaysInitialHistory: false),
            codexAccountManager: manager,
            codexUsageSnapshotStore: usageStore
        )
        XCTAssertEqual(model.tokenActivityTotal(for: .today), 900)

        let firstEventAt = Date().addingTimeInterval(-1)
        model.updateLatestAgentTokenUsage(
            AgentTokenUsage(totalTokens: 100),
            sessionID: "older-session-a",
            updatedAt: firstEventAt
        )
        XCTAssertEqual(model.tokenActivityTotal(for: .today), 900)
        model.updateLatestAgentTokenUsage(
            AgentTokenUsage(totalTokens: 900),
            sessionID: "newer-session-b",
            updatedAt: firstEventAt.addingTimeInterval(0.5)
        )

        XCTAssertEqual(model.tokenActivityTotal(for: .today), 1_000)
    }

    @MainActor
    func testStateReloadDoesNotImportHistoricalTokensFromBeforeAccountActivation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("account-history-filter-\(UUID().uuidString)", isDirectory: true)
        let authURL = root.appendingPathComponent("auth.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try codexOAuthAuthJSON(
            email: "history-filter@example.com",
            accountID: "acct_history_filter",
            accessToken: "history-filter-access"
        ).write(to: authURL)
        let manager = CodexAccountManager(
            environment: ["CODEX_HOME": root.path],
            fileManager: .default,
            storeURL: root.appendingPathComponent("accounts.json")
        )
        _ = try manager.saveCurrentAccount()

        let stateStore = SignalStateStore(stateFileURL: root.appendingPathComponent("status.json"))
        let oldEventAt = Date().addingTimeInterval(-60)

        let defaults = UserDefaults.standard
        let previousMonitoring = defaults.object(forKey: "isCodexDesktopMonitoringEnabled")
        defaults.set(false, forKey: "isCodexDesktopMonitoringEnabled")
        defer {
            if let previousMonitoring {
                defaults.set(previousMonitoring, forKey: "isCodexDesktopMonitoringEnabled")
            } else {
                defaults.removeObject(forKey: "isCodexDesktopMonitoringEnabled")
            }
        }

        let model = MenuBarStatusModel(
            store: stateStore,
            codexDesktopActivityMonitor: CodexDesktopActivityMonitor(
                sessionsRootURL: root.appendingPathComponent("sessions", isDirectory: true),
                replaysInitialHistory: false
            ),
            codexAccountManager: manager,
            codexUsageSnapshotStore: CodexAccountUsageSnapshotStore(
                fileURL: root.appendingPathComponent("usage.json")
            )
        )
        model.isCodexDesktopMonitoringEnabled = true
        model.isMonitoringPaused = false

        _ = try stateStore.applySessionQuota(
            AgentQuotaStatus(
                remainingPercent: 80,
                usedPercent: 20,
                limitName: "Context",
                windowMinutes: nil,
                resetsAt: nil,
                updatedAt: oldEventAt,
                tokenUsage: AgentTokenUsage(totalTokens: 9_000)
            ),
            sessionID: "old-account-session",
            agent: "codex-desktop",
            updatedAt: oldEventAt
        )
        model.reload()
        for _ in 0..<100 where !model.snapshot.sessions.contains(where: {
            $0.sessionID == "old-account-session"
        }) {
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertTrue(model.snapshot.sessions.contains { $0.sessionID == "old-account-session" })
        XCTAssertEqual(model.tokenActivityTotal(for: .today), 0)
    }

    @MainActor
    func testAccountSnapshotRestoresUnscannedLiveSupplement() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("token-snapshot-supplement-\(UUID().uuidString)", isDirectory: true)
        let authURL = root.appendingPathComponent("auth.json")
        let accountStoreURL = root.appendingPathComponent("accounts.json")
        let usageStoreURL = root.appendingPathComponent("usage.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try codexOAuthAuthJSON(
            email: "supplement@example.com",
            accountID: "acct_supplement",
            accessToken: "supplement-access"
        ).write(to: authURL)
        let manager = CodexAccountManager(
            environment: ["CODEX_HOME": root.path],
            fileManager: .default,
            storeURL: accountStoreURL
        )
        _ = try manager.saveCurrentAccount()
        let account = try XCTUnwrap(try manager.loadState().currentAccount)
        let today = Calendar.current.startOfDay(for: Date())
        let usageStore = CodexAccountUsageSnapshotStore(fileURL: usageStoreURL)
        usageStore.store(
            account: account,
            quota: nil,
            credits: nil,
            tokenUsage: AgentTokenUsage(totalTokens: 1_250),
            liveTokenUsageScanBaseline: 1_000,
            unscannedLiveTokenCarry: 0,
            tokenActivityCacheVersion: CodexTokenActivityScanner.currentCacheVersion,
            tokenActivityDays: [CodexTokenActivityDay(day: today, totalTokens: 1_000)]
        )

        let model = MenuBarStatusModel(
            store: SignalStateStore(stateFileURL: root.appendingPathComponent("status.json")),
            codexDesktopActivityMonitor: CodexDesktopActivityMonitor(replaysInitialHistory: false),
            codexAccountManager: manager,
            codexUsageSnapshotStore: usageStore
        )

        XCTAssertEqual(model.tokenActivityTotal(for: .today), 1_250)

        usageStore.store(
            account: account,
            quota: nil,
            credits: nil,
            tokenUsage: AgentTokenUsage(totalTokens: 100),
            liveTokenUsageScanBaseline: 0,
            unscannedLiveTokenCarry: 400,
            tokenActivityCacheVersion: CodexTokenActivityScanner.currentCacheVersion,
            tokenActivityDays: [CodexTokenActivityDay(day: today, totalTokens: 1_000)]
        )
        let carryModel = MenuBarStatusModel(
            store: SignalStateStore(stateFileURL: root.appendingPathComponent("carry-status.json")),
            codexDesktopActivityMonitor: CodexDesktopActivityMonitor(replaysInitialHistory: false),
            codexAccountManager: manager,
            codexUsageSnapshotStore: usageStore
        )
        XCTAssertEqual(carryModel.tokenActivityTotal(for: .today), 1_500)
    }

    @MainActor
    func testIncompatibleActivityCacheDropsLegacyFloorBeforeAuthoritativeScan() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("token-snapshot-incompatible-floor-\(UUID().uuidString)", isDirectory: true)
        let authURL = root.appendingPathComponent("auth.json")
        let usageStoreURL = root.appendingPathComponent("usage.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try codexOAuthAuthJSON(
            email: "incompatible-floor@example.com",
            accountID: "acct_incompatible_floor",
            accessToken: "incompatible-floor-access"
        ).write(to: authURL)
        let manager = CodexAccountManager(
            environment: ["CODEX_HOME": root.path],
            fileManager: .default,
            storeURL: root.appendingPathComponent("accounts.json")
        )
        _ = try manager.saveCurrentAccount()
        let account = try XCTUnwrap(try manager.loadState().currentAccount)
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 60 * 60)
        let today = Calendar.current.startOfDay(for: now)
        let usageStore = CodexAccountUsageSnapshotStore(fileURL: usageStoreURL)
        usageStore.store(
            account: account,
            quota: nil,
            credits: nil,
            tokenUsage: AgentTokenUsage(totalTokens: 1_250),
            legacyUnscopedTokenFloor: CodexLegacyUnscopedTokenFloorSnapshot(
                totalTokens: 1_250,
                day: today
            ),
            tokenActivityCacheVersion: CodexTokenActivityScanner.currentCacheVersion - 1,
            tokenActivityDays: [CodexTokenActivityDay(day: today, totalTokens: 1_000)]
        )

        let applied = expectation(description: "authoritative scan replaces incompatible legacy floor")
        let scanner = ControlledCodexTokenActivityScanner(
            cachedDays: { _ in nil },
            scannedResultsByCall: { _, _ in
                CodexTokenActivityScanResult(
                    days: [CodexTokenActivityDay(day: today, totalTokens: 900)],
                    watermarks: []
                )
            }
        )
        defer { scanner.finishScan() }
        let model = MenuBarStatusModel(
            store: SignalStateStore(stateFileURL: root.appendingPathComponent("status.json")),
            codexDesktopActivityMonitor: CodexDesktopActivityMonitor(replaysInitialHistory: false),
            codexAccountManager: manager,
            codexUsageSnapshotStore: usageStore,
            codexTokenActivityScanner: scanner,
            tokenActivityScanObserver: { disposition in
                if disposition == .applied { applied.fulfill() }
            },
            nowProvider: { now }
        )
        model.isCodexDesktopMonitoringEnabled = true
        model.isMonitoringPaused = false

        XCTAssertEqual(model.tokenActivityTotal(for: .today, now: now), 0)
        model.refreshTokenActivityIfNeeded(force: true)
        XCTAssertTrue(scanner.waitUntilScanStarts(seconds: 1))
        scanner.finishScan()
        await fulfillment(of: [applied], timeout: 2)

        XCTAssertEqual(scanner.scanCallCount, 1)
        XCTAssertEqual(model.tokenActivityTotal(for: .today, now: now), 900)
    }

    @MainActor
    func testIncompatibleActivityCacheDropsLegacyCursorBeforeNewSnapshotPoll() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("token-snapshot-incompatible-cursor-\(UUID().uuidString)", isDirectory: true)
        let authURL = root.appendingPathComponent("auth.json")
        let usageStoreURL = root.appendingPathComponent("usage.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try codexOAuthAuthJSON(
            email: "incompatible-cursor@example.com",
            accountID: "acct_incompatible_cursor",
            accessToken: "incompatible-cursor-access"
        ).write(to: authURL)
        let manager = CodexAccountManager(
            environment: ["CODEX_HOME": root.path],
            fileManager: .default,
            storeURL: root.appendingPathComponent("accounts.json")
        )
        _ = try manager.saveCurrentAccount()
        let account = try XCTUnwrap(try manager.loadState().currentAccount)
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 60 * 60)
        let usageStore = CodexAccountUsageSnapshotStore(fileURL: usageStoreURL)
        usageStore.store(
            account: account,
            quota: nil,
            credits: nil,
            tokenUsage: AgentTokenUsage(totalTokens: 100),
            liveTokenCounters: [CodexLiveTokenCounterSnapshot(
                key: "legacy-key",
                sessionID: "same-inode-session",
                totalTokens: 100,
                scannedBaseline: 100,
                day: Calendar.current.startOfDay(for: now),
                updatedAt: now,
                observationCursor: CodexTokenObservationCursor(
                    sourceID: "/test/same-inode.jsonl",
                    sourceGeneration: "same-device-inode",
                    endOffset: 100,
                    lineFingerprint: "legacy-line-100"
                )
            )],
            tokenActivityCacheVersion: CodexTokenActivityScanner.currentCacheVersion - 1,
            tokenActivityDays: []
        )

        let model = MenuBarStatusModel(
            store: SignalStateStore(stateFileURL: root.appendingPathComponent("status.json")),
            codexDesktopActivityMonitor: CodexDesktopActivityMonitor(replaysInitialHistory: false),
            codexAccountManager: manager,
            codexUsageSnapshotStore: usageStore,
            nowProvider: { now }
        )
        model.isCodexDesktopMonitoringEnabled = true
        model.isMonitoringPaused = false
        XCTAssertEqual(model.tokenActivityTotal(for: .today, now: now), 100)

        model.updateLatestAgentTokenUsage(
            AgentTokenUsage(totalTokens: 900),
            sessionID: "same-inode-session",
            updatedAt: now,
            observationCursor: CodexTokenObservationCursor(
                sourceID: "/test/same-inode.jsonl",
                sourceGeneration: "same-device-inode",
                sourceStatFingerprint: 200,
                sourceChangeTimeNanoseconds: 2_000,
                endOffset: 100,
                lineFingerprint: "new-line-900"
            )
        )

        XCTAssertEqual(model.tokenActivityTotal(for: .today, now: now), 900)
    }

    @MainActor
    func testCoveredNewerSnapshotFrontierWinsDespiteEarlierEventTimestamp() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("covered-newer-snapshot-\(UUID().uuidString)", isDirectory: true)
        let authURL = root.appendingPathComponent("auth.json")
        let usageStoreURL = root.appendingPathComponent("usage.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try codexOAuthAuthJSON(
            email: "covered-snapshot@example.com",
            accountID: "acct_covered_snapshot",
            accessToken: "covered-snapshot-access"
        ).write(to: authURL)
        let manager = CodexAccountManager(
            environment: ["CODEX_HOME": root.path],
            fileManager: .default,
            storeURL: root.appendingPathComponent("accounts.json")
        )
        _ = try manager.saveCurrentAccount()
        let account = try XCTUnwrap(try manager.loadState().currentAccount)
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 60 * 60)
        let sourceID = "/test/covered-newer-snapshot.jsonl"
        let sourceGeneration = "same-device-inode"
        let sessionID = "covered-newer-snapshot-session"
        func cursor(
            statFingerprint: Int64,
            changeTimeNanoseconds: Int64,
            offset: UInt64,
            lineFingerprint: String
        ) -> CodexTokenObservationCursor {
            CodexTokenObservationCursor(
                sourceID: sourceID,
                sourceGeneration: sourceGeneration,
                sourceStatFingerprint: statFingerprint,
                sourceChangeTimeNanoseconds: changeTimeNanoseconds,
                endOffset: offset,
                lineFingerprint: lineFingerprint
            )
        }
        let oldCursor = cursor(
            statFingerprint: 100,
            changeTimeNanoseconds: 1_000,
            offset: 100,
            lineFingerprint: "old-snapshot-line-100"
        )
        let frontierCursor = cursor(
            statFingerprint: 200,
            changeTimeNanoseconds: 2_000,
            offset: 200,
            lineFingerprint: "new-snapshot-line-150"
        )
        let usageStore = CodexAccountUsageSnapshotStore(fileURL: usageStoreURL)
        usageStore.store(
            account: account,
            quota: nil,
            credits: nil,
            tokenUsage: AgentTokenUsage(totalTokens: 100),
            liveTokenCounters: [CodexLiveTokenCounterSnapshot(
                key: "persisted-key",
                sessionID: sessionID,
                totalTokens: 100,
                scannedBaseline: 100,
                day: Calendar.current.startOfDay(for: now),
                updatedAt: now.addingTimeInterval(10),
                observationCursor: oldCursor
            )],
            liveTokenUsageScanCutoff: now,
            liveTokenScanWatermarks: [CodexLiveTokenScanWatermarkSnapshot(
                sessionID: sessionID,
                sourceID: frontierCursor.sourceID,
                sourceGeneration: frontierCursor.sourceGeneration,
                sourceStatFingerprint: frontierCursor.sourceStatFingerprint,
                sourceChangeTimeNanoseconds: frontierCursor.sourceChangeTimeNanoseconds,
                endOffset: frontierCursor.endOffset,
                lineFingerprint: frontierCursor.lineFingerprint,
                eventTimestamp: now.addingTimeInterval(5),
                totalTokens: 150
            )],
            tokenActivityCacheVersion: CodexTokenActivityScanner.currentCacheVersion,
            tokenActivityDays: [CodexTokenActivityDay(
                day: Calendar.current.startOfDay(for: now),
                totalTokens: 150
            )],
            updatedAt: now
        )

        let model = MenuBarStatusModel(
            store: SignalStateStore(stateFileURL: root.appendingPathComponent("status.json")),
            codexDesktopActivityMonitor: CodexDesktopActivityMonitor(replaysInitialHistory: false),
            codexAccountManager: manager,
            codexUsageSnapshotStore: usageStore,
            nowProvider: { now }
        )
        model.isCodexDesktopMonitoringEnabled = true
        model.isMonitoringPaused = false
        XCTAssertEqual(model.tokenActivityTotal(for: .today, now: now), 150)

        model.updateLatestAgentTokenUsage(
            AgentTokenUsage(totalTokens: 150),
            sessionID: sessionID,
            updatedAt: now.addingTimeInterval(5),
            observationCursor: frontierCursor
        )
        XCTAssertEqual(model.tokenActivityTotal(for: .today, now: now), 150)
        XCTAssertEqual(model.latestAgentTokenUsage?.effectiveTotalTokens, 150)

        model.updateLatestAgentTokenUsage(
            AgentTokenUsage(totalTokens: 175),
            sessionID: sessionID,
            updatedAt: now.addingTimeInterval(4),
            observationCursor: cursor(
                statFingerprint: 200,
                changeTimeNanoseconds: 2_000,
                offset: 250,
                lineFingerprint: "new-snapshot-line-175"
            )
        )

        XCTAssertEqual(model.tokenActivityTotal(for: .today, now: now), 175)
        XCTAssertEqual(model.latestAgentTokenUsage?.effectiveTotalTokens, 175)
    }

    @MainActor
    func testExactLiveObservationAlignsLatestAfterScannerAdvancesSnapshot() async throws {
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 60 * 60)
        let sessionID = "scanner-advanced-snapshot-session"
        let sourceID = "/test/scanner-advanced-snapshot.jsonl"
        let sourceGeneration = "same-device-inode"
        let oldCursor = CodexTokenObservationCursor(
            sourceID: sourceID,
            sourceGeneration: sourceGeneration,
            sourceStatFingerprint: 100,
            sourceChangeTimeNanoseconds: 1_000,
            endOffset: 100,
            lineFingerprint: "old-snapshot-line-100"
        )
        let frontierCursor = CodexTokenObservationCursor(
            sourceID: sourceID,
            sourceGeneration: sourceGeneration,
            sourceStatFingerprint: 200,
            sourceChangeTimeNanoseconds: 2_000,
            endOffset: 200,
            lineFingerprint: "new-snapshot-line-150"
        )
        let applied = expectation(description: "newer scanner snapshot applied")
        let scanner = ControlledCodexTokenActivityScanner(
            cachedDays: { _ in nil },
            scannedResultsByCall: { scanNow, _ in
                CodexTokenActivityScanResult(
                    days: [CodexTokenActivityDay(
                        day: Calendar.current.startOfDay(for: scanNow),
                        totalTokens: 150
                    )],
                    watermarks: [CodexTokenActivityScanWatermark(
                        sessionID: sessionID,
                        sourceID: frontierCursor.sourceID,
                        sourceGeneration: frontierCursor.sourceGeneration,
                        endOffset: frontierCursor.endOffset,
                        lineFingerprint: frontierCursor.lineFingerprint,
                        eventTimestamp: now.addingTimeInterval(-10),
                        totalTokens: 150,
                        sourceStatFingerprint: frontierCursor.sourceStatFingerprint,
                        sourceChangeTimeNanoseconds: frontierCursor.sourceChangeTimeNanoseconds
                    )]
                )
            }
        )
        defer { scanner.finishScan() }
        let model = MenuBarStatusModel(
            store: fixture.store,
            codexDesktopActivityMonitor: CodexDesktopActivityMonitor(replaysInitialHistory: false),
            codexAccountManager: EmptyCodexAccountManager(),
            codexTokenActivityScanner: scanner,
            tokenActivityScanObserver: { disposition in
                if disposition == .applied { applied.fulfill() }
            },
            nowProvider: { now }
        )
        model.isCodexDesktopMonitoringEnabled = true
        model.isMonitoringPaused = false
        model.updateLatestAgentTokenUsage(
            AgentTokenUsage(totalTokens: 100),
            sessionID: sessionID,
            updatedAt: now.addingTimeInterval(-5),
            observationCursor: oldCursor
        )

        model.refreshTokenActivityIfNeeded(force: true)
        XCTAssertTrue(scanner.waitUntilScanStarts(seconds: 1))
        scanner.finishScan()
        await fulfillment(of: [applied], timeout: 2)
        XCTAssertEqual(model.tokenActivityTotal(for: .today, now: now), 150)
        XCTAssertEqual(model.latestAgentTokenUsage?.effectiveTotalTokens, 100)

        // The scan can move the ledger frontier before the desktop poll arrives.
        // The exact delayed line must still align the published usage.
        model.updateLatestAgentTokenUsage(
            AgentTokenUsage(totalTokens: 150),
            sessionID: sessionID,
            updatedAt: now.addingTimeInterval(-10),
            observationCursor: frontierCursor
        )

        XCTAssertEqual(model.tokenActivityTotal(for: .today, now: now), 150)
        XCTAssertEqual(model.latestAgentTokenUsage?.effectiveTotalTokens, 150)
    }

    @MainActor
    func testLiveTokenCountersRemainCorrectAcrossInterleavedSessions() throws {
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let model = MenuBarStatusModel(
            store: fixture.store,
            codexDesktopActivityMonitor: CodexDesktopActivityMonitor(replaysInitialHistory: false),
            codexAccountManager: EmptyCodexAccountManager()
        )
        let eventBase = Calendar.current.startOfDay(for: Date()).addingTimeInterval(60)

        model.updateLatestAgentTokenUsage(
            AgentTokenUsage(totalTokens: 1_000),
            sessionID: "session-a",
            updatedAt: eventBase
        )
        XCTAssertEqual(model.tokenActivityTotal(for: .today), 1_000)

        model.updateLatestAgentTokenUsage(
            AgentTokenUsage(totalTokens: 500),
            sessionID: "session-b",
            updatedAt: eventBase.addingTimeInterval(1)
        )
        XCTAssertEqual(model.tokenActivityTotal(for: .today), 1_500)

        model.updateLatestAgentTokenUsage(
            AgentTokenUsage(totalTokens: 1_100),
            sessionID: "session-a",
            updatedAt: eventBase.addingTimeInterval(2)
        )
        XCTAssertEqual(model.tokenActivityTotal(for: .today), 1_600)

        model.updateLatestAgentTokenUsage(
            AgentTokenUsage(totalTokens: 550),
            sessionID: "session-b",
            updatedAt: eventBase.addingTimeInterval(3)
        )
        XCTAssertEqual(model.tokenActivityTotal(for: .today), 1_650)
    }

    @MainActor
    func testInitialSessionSnapshotPreservesFirstCounterReset() throws {
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let initialAt = Date().addingTimeInterval(-10)
        let quota = AgentQuotaStatus(
            remainingPercent: 80,
            updatedAt: initialAt,
            tokenUsage: AgentTokenUsage(totalTokens: 1_000)
        )
        _ = try fixture.store.applySessionQuota(
            quota,
            sessionID: "session-a",
            agent: "codex-desktop",
            updatedAt: initialAt
        )

        let model = MenuBarStatusModel(
            store: fixture.store,
            codexDesktopActivityMonitor: CodexDesktopActivityMonitor(replaysInitialHistory: false),
            codexAccountManager: EmptyCodexAccountManager()
        )
        XCTAssertEqual(model.tokenActivityTotal(for: .today), 1_000)

        model.updateLatestAgentTokenUsage(
            AgentTokenUsage(totalTokens: 100),
            sessionID: "session-a",
            updatedAt: Date()
        )
        XCTAssertEqual(model.tokenActivityTotal(for: .today), 1_100)
    }

    @MainActor
    func testPersistedPendingUsageKeepsItsOriginalDayAcrossMidnight() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("token-snapshot-midnight-\(UUID().uuidString)", isDirectory: true)
        let authURL = root.appendingPathComponent("auth.json")
        let accountStoreURL = root.appendingPathComponent("accounts.json")
        let usageStoreURL = root.appendingPathComponent("usage.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try codexOAuthAuthJSON(
            email: "midnight@example.com",
            accountID: "acct_midnight",
            accessToken: "midnight-access"
        ).write(to: authURL)
        let manager = CodexAccountManager(
            environment: ["CODEX_HOME": root.path],
            fileManager: .default,
            storeURL: accountStoreURL
        )
        _ = try manager.saveCurrentAccount()
        let account = try XCTUnwrap(try manager.loadState().currentAccount)
        let today = Calendar.current.startOfDay(for: Date())
        let yesterday = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -1, to: today))
        let yesterdayEventAt = yesterday.addingTimeInterval(12 * 60 * 60)
        let usageStore = CodexAccountUsageSnapshotStore(fileURL: usageStoreURL)
        usageStore.store(
            account: account,
            quota: nil,
            credits: nil,
            tokenUsage: AgentTokenUsage(totalTokens: 1_250),
            liveTokenCounters: [
                CodexLiveTokenCounterSnapshot(
                    key: "session-a",
                    sessionID: "session-a",
                    totalTokens: 1_250,
                    scannedBaseline: 1_000,
                    day: yesterday,
                    updatedAt: yesterdayEventAt
                )
            ],
            unscannedLiveTokenCarryByDay: [],
            liveTokenUsageScanCutoff: yesterdayEventAt.addingTimeInterval(-1),
            tokenActivityCacheVersion: CodexTokenActivityScanner.currentCacheVersion,
            tokenActivityDays: [CodexTokenActivityDay(day: yesterday, totalTokens: 1_000)],
            updatedAt: yesterdayEventAt
        )

        let applied = expectation(description: "yesterday pending scan applied")
        let scanner = ControlledCodexTokenActivityScanner(
            cachedDays: { _ in nil },
            scannedResultsByCall: { _, _ in
                CodexTokenActivityScanResult(
                    days: [CodexTokenActivityDay(day: yesterday, totalTokens: 1_250)],
                    watermarks: [testTokenScanWatermark(
                        sessionID: "session-a",
                        eventAt: yesterdayEventAt,
                        totalTokens: 1_250
                    )]
                )
            }
        )
        defer { scanner.finishScan() }
        let model = MenuBarStatusModel(
            store: SignalStateStore(stateFileURL: root.appendingPathComponent("status.json")),
            codexDesktopActivityMonitor: CodexDesktopActivityMonitor(replaysInitialHistory: false),
            codexAccountManager: manager,
            codexUsageSnapshotStore: usageStore,
            codexTokenActivityScanner: scanner,
            tokenActivityScanObserver: { disposition in
                if disposition == .applied {
                    applied.fulfill()
                }
            }
        )
        model.isCodexDesktopMonitoringEnabled = true
        model.isMonitoringPaused = false

        XCTAssertEqual(model.tokenActivityTotal(for: .today), 0)
        XCTAssertEqual(model.tokenActivityTotal(for: .last30Days), 1_250)

        model.refreshTokenActivityIfNeeded(force: true)
        XCTAssertTrue(scanner.waitUntilScanStarts(seconds: 1))
        scanner.finishScan()
        await fulfillment(of: [applied], timeout: 2)

        XCTAssertEqual(model.tokenActivityTotal(for: .today), 0)
        XCTAssertEqual(model.tokenActivityTotal(for: .last30Days), 1_250)

        model.updateLatestAgentTokenUsage(
            AgentTokenUsage(totalTokens: 100),
            sessionID: "session-b",
            updatedAt: Date()
        )
        XCTAssertEqual(model.tokenActivityTotal(for: .today), 100)
        XCTAssertEqual(model.tokenActivityTotal(for: .last30Days), 1_350)
    }

    @MainActor
    func testSameSessionCumulativeCounterCrossingMidnightCountsOnlyNewDayDelta() throws {
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let firstDay = Calendar.current.startOfDay(for: Date())
        let nextDay = try XCTUnwrap(
            Calendar.current.date(byAdding: .day, value: 1, to: firstDay)
        )
        let beforeMidnight = nextDay.addingTimeInterval(-10)
        let afterMidnight = nextDay.addingTimeInterval(10)
        let model = MenuBarStatusModel(
            store: fixture.store,
            codexDesktopActivityMonitor: CodexDesktopActivityMonitor(replaysInitialHistory: false),
            codexAccountManager: EmptyCodexAccountManager(),
            nowProvider: { afterMidnight }
        )

        model.updateLatestAgentTokenUsage(
            AgentTokenUsage(totalTokens: 1_000),
            sessionID: "overnight-session",
            updatedAt: beforeMidnight
        )
        model.updateLatestAgentTokenUsage(
            AgentTokenUsage(totalTokens: 1_100),
            sessionID: "overnight-session",
            updatedAt: afterMidnight
        )

        XCTAssertEqual(model.tokenActivityTotal(for: .today, now: afterMidnight), 100)
        XCTAssertEqual(model.tokenActivityTotal(for: .last30Days, now: afterMidnight), 1_100)
    }

    @MainActor
    func testInFlightScanCrossingMidnightRetriesWithoutMovingPendingUsage() async throws {
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let day = Calendar.current.startOfDay(for: Date())
        let nextDay = try XCTUnwrap(
            Calendar.current.date(byAdding: .day, value: 1, to: day)
        )
        let beforeMidnight = nextDay.addingTimeInterval(-30)
        let eventAt = beforeMidnight.addingTimeInterval(-1)
        let clock = TestDateClock(beforeMidnight)
        let retrying = expectation(description: "midnight scan retried")
        let applied = expectation(description: "post-midnight replacement applied")
        let scanner = ControlledCodexTokenActivityScanner(
            cachedDays: { _ in nil },
            scannedResultsByCall: { _, _ in
                CodexTokenActivityScanResult(
                    days: [CodexTokenActivityDay(day: day, totalTokens: 100)],
                    watermarks: [testTokenScanWatermark(
                        sessionID: "session-a",
                        eventAt: eventAt,
                        totalTokens: 100
                    )]
                )
            }
        )
        defer { scanner.finishScan() }
        let model = MenuBarStatusModel(
            store: fixture.store,
            codexDesktopActivityMonitor: CodexDesktopActivityMonitor(replaysInitialHistory: false),
            codexAccountManager: EmptyCodexAccountManager(),
            codexTokenActivityScanner: scanner,
            tokenActivityScanObserver: { disposition in
                if disposition == .retryingAfterUnabsorbedUsage {
                    retrying.fulfill()
                } else if disposition == .applied {
                    applied.fulfill()
                }
            },
            nowProvider: { clock.now() }
        )
        model.isCodexDesktopMonitoringEnabled = true
        model.isMonitoringPaused = false
        model.updateLatestAgentTokenUsage(
            AgentTokenUsage(totalTokens: 100),
            sessionID: "session-a",
            updatedAt: eventAt
        )

        model.refreshTokenActivityIfNeeded(force: true)
        XCTAssertTrue(scanner.waitUntilScanStarts(seconds: 1))
        clock.advance(by: 60)
        scanner.finishScan()
        await fulfillment(of: [retrying], timeout: 2)
        XCTAssertTrue(scanner.waitUntilScanStarts(seconds: 2))
        scanner.finishScan()
        await fulfillment(of: [applied], timeout: 2)

        XCTAssertEqual(model.tokenActivityTotal(for: .today, now: clock.now()), 0)
        XCTAssertEqual(model.tokenActivityTotal(for: .last30Days, now: clock.now()), 100)
    }

    @MainActor
    func testPendingUsageOutsideThirtyDayWindowDoesNotCausePermanentRetry() async throws {
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 60 * 60)
        let oldEventAt = try XCTUnwrap(
            Calendar.current.date(byAdding: .day, value: -30, to: now)
        )
        let applied = expectation(description: "scan ignores expired pending usage")
        let scanner = ControlledCodexTokenActivityScanner(
            cachedDays: { _ in nil },
            scannedResultsByCall: { _, _ in
                CodexTokenActivityScanResult(days: [], watermarks: [])
            }
        )
        defer { scanner.finishScan() }
        let model = MenuBarStatusModel(
            store: fixture.store,
            codexDesktopActivityMonitor: CodexDesktopActivityMonitor(replaysInitialHistory: false),
            codexAccountManager: EmptyCodexAccountManager(),
            codexTokenActivityScanner: scanner,
            tokenActivityScanObserver: { disposition in
                if disposition == .applied { applied.fulfill() }
            },
            nowProvider: { now }
        )
        model.isCodexDesktopMonitoringEnabled = true
        model.isMonitoringPaused = false
        model.updateLatestAgentTokenUsage(
            AgentTokenUsage(totalTokens: 750),
            sessionID: "expired-session",
            updatedAt: oldEventAt,
            observationCursor: CodexTokenObservationCursor(
                sourceID: "/test/expired-session.jsonl",
                sourceGeneration: "expired-generation",
                endOffset: 42,
                lineFingerprint: "expired-line"
            )
        )

        model.refreshTokenActivityIfNeeded(force: true)
        XCTAssertTrue(scanner.waitUntilScanStarts(seconds: 1))
        scanner.finishScan()
        await fulfillment(of: [applied], timeout: 2)

        XCTAssertEqual(scanner.scanCallCount, 1)
        XCTAssertEqual(model.tokenActivityTotal(for: .last30Days, now: now), 0)
    }

    @MainActor
    func testTokenActivityThirtyDayWindowIncludesDay29AndExcludesDay30() throws {
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 60 * 60)
        let includedAt = try XCTUnwrap(
            Calendar.current.date(byAdding: .day, value: -29, to: now)
        )
        let excludedAt = try XCTUnwrap(
            Calendar.current.date(byAdding: .day, value: -30, to: now)
        )
        let model = MenuBarStatusModel(
            store: fixture.store,
            codexDesktopActivityMonitor: CodexDesktopActivityMonitor(replaysInitialHistory: false),
            codexAccountManager: EmptyCodexAccountManager(),
            nowProvider: { now }
        )

        model.updateLatestAgentTokenUsage(
            AgentTokenUsage(totalTokens: 290),
            sessionID: "day-29",
            updatedAt: includedAt
        )
        model.updateLatestAgentTokenUsage(
            AgentTokenUsage(totalTokens: 300),
            sessionID: "day-30",
            updatedAt: excludedAt
        )

        XCTAssertEqual(model.tokenActivityTotal(for: .last30Days, now: now), 290)
    }

    @MainActor
    func testClearUsageCacheWaitsForInFlightScanBeforeRemovingScannerCaches() async throws {
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let scanner = ControlledCodexTokenActivityScanner(
            cachedDays: { _ in nil },
            scannedDays: { now in
                [CodexTokenActivityDay(
                    day: Calendar.current.startOfDay(for: now),
                    totalTokens: 9_999
                )]
            }
        )
        defer { scanner.finishScan() }
        let discarded = expectation(description: "cleared scan completion discarded")
        let model = MenuBarStatusModel(
            store: fixture.store,
            codexDesktopActivityMonitor: CodexDesktopActivityMonitor(replaysInitialHistory: false),
            codexAccountManager: EmptyCodexAccountManager(),
            codexTokenActivityScanner: scanner,
            tokenActivityScanObserver: { disposition in
                if disposition == .discardedStaleContext { discarded.fulfill() }
            }
        )
        model.isCodexDesktopMonitoringEnabled = true
        model.isMonitoringPaused = false

        model.refreshTokenActivityIfNeeded(force: true)
        XCTAssertTrue(scanner.waitUntilScanStarts(seconds: 1))
        model.clearDebugUsageCache()
        XCTAssertFalse(scanner.waitUntilCacheClears(seconds: 0.1))

        scanner.finishScan()
        XCTAssertTrue(scanner.waitUntilCacheClears(seconds: 2))
        await fulfillment(of: [discarded], timeout: 2)
        XCTAssertEqual(scanner.clearCacheCallCount, 1)
        XCTAssertTrue(model.tokenActivityDays.isEmpty)
        XCTAssertEqual(model.tokenActivityTotal(for: .today), 0)
    }

    func testProductionTokenActivityScannerClearCacheRemovesAllDiskCaches() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("token-clear-cache-\(UUID().uuidString)", isDirectory: true)
        let legacyCacheURL = root.appendingPathComponent("legacy-token-cache.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let costCacheURL = CostUsageCacheIO.cacheFileURL(provider: .codex, cacheRoot: root)
        let piCacheURL = PiSessionCostCacheIO.cacheFileURL(cacheRoot: root)
        let costCacheDirectory = costCacheURL.deletingLastPathComponent()
        let legacyCostCacheURLs = ["codex-v8.json", "codex-v9.json", "codex-v10.json"].map {
            costCacheDirectory.appendingPathComponent($0)
        }
        let legacyPiCacheURL = costCacheDirectory.appendingPathComponent("pi-sessions-v3.json")
        let unrelatedCacheURL = costCacheDirectory.appendingPathComponent("claude-v4.json")
        for url in [legacyCacheURL, costCacheURL, piCacheURL, legacyPiCacheURL, unrelatedCacheURL]
            + legacyCostCacheURLs
        {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("cache".utf8).write(to: url)
        }
        let scanner = CodexTokenActivityScanner(
            sessionRootURLs: [],
            cacheURL: legacyCacheURL,
            costUsageCacheRootURL: root,
            usesAgentSignalCostUsageScanner: true
        )

        scanner.clearCache()

        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyCacheURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: costCacheURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: piCacheURL.path))
        for url in legacyCostCacheURLs + [legacyPiCacheURL] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedCacheURL.path))
    }

    @MainActor
    func testProductionYesterdayCacheContinuesIntoTodayIncrementalScan() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("production-cache-bootstrap-\(UUID().uuidString)", isDirectory: true)
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        let authURL = root.appendingPathComponent("auth.json")
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let today = Calendar.current.startOfDay(for: Date())
        let now = today.addingTimeInterval(12 * 60 * 60)
        let yesterday = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -1, to: today))
        let yesterdayEventAt = yesterday.addingTimeInterval(12 * 60 * 60)
        let todayEventAt = now.addingTimeInterval(-1)
        let sessionID = "019c846a-b85e-7bd3-924b-cc33e3f180d9"
        let filenameDay = ISO8601DateFormatter().string(from: now).prefix(10)
        let sessionURL = sessionsRoot.appendingPathComponent(
            "rollout-\(filenameDay)T12-00-00-\(sessionID).jsonl"
        )
        let meta = #"{"timestamp":"\#(isoTimestamp(yesterdayEventAt))","type":"session_meta","payload":{"id":"\#(sessionID)","originator":"Codex Desktop"}}"#
        let yesterdayLine = #"{"timestamp":"\#(isoTimestamp(yesterdayEventAt))","type":"event_msg","payload":{"type":"token_count","info":{"model_context_window":258400,"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100},"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100}}}}"#
        let todayLine = #"{"timestamp":"\#(isoTimestamp(todayEventAt))","type":"event_msg","payload":{"type":"token_count","info":{"model_context_window":258400,"total_token_usage":{"input_tokens":150,"cached_input_tokens":0,"output_tokens":0,"total_tokens":150},"last_token_usage":{"input_tokens":50,"cached_input_tokens":0,"output_tokens":0,"total_tokens":50}}}}"#
        try [meta, yesterdayLine].joined(separator: "\n").appending("\n")
            .write(to: sessionURL, atomically: true, encoding: .utf8)

        let productionScanner = CodexTokenActivityScanner(
            sessionRootURLs: [sessionsRoot],
            costUsageCacheRootURL: root.appendingPathComponent("cost-cache", isDirectory: true)
        )
        let seeded = productionScanner.scanDailyActivityResult(now: now, days: 30, progress: nil)
        XCTAssertEqual(seeded.days.filter { Calendar.current.isDate($0.day, inSameDayAs: today) }.count, 0)
        XCTAssertEqual(seeded.days.compactMap(\.totalTokens).reduce(0, +), 100)
        try FileHandle(forWritingTo: sessionURL).appendString(todayLine + "\n")

        try codexOAuthAuthJSON(
            email: "bootstrap@example.com",
            accountID: "acct_bootstrap",
            accessToken: "bootstrap-access"
        ).write(to: authURL)
        let manager = CodexAccountManager(
            environment: ["CODEX_HOME": root.path],
            fileManager: .default,
            storeURL: root.appendingPathComponent("accounts.json")
        )
        _ = try manager.saveCurrentAccount()
        let account = try XCTUnwrap(try manager.loadState().currentAccount)
        let usageStore = CodexAccountUsageSnapshotStore(
            fileURL: root.appendingPathComponent("usage.json")
        )
        usageStore.store(
            account: account,
            quota: nil,
            credits: nil,
            tokenUsage: AgentTokenUsage(totalTokens: 150),
            liveTokenCounters: [CodexLiveTokenCounterSnapshot(
                key: sessionID,
                sessionID: sessionID,
                totalTokens: 150,
                scannedBaseline: 100,
                day: today,
                updatedAt: todayEventAt
            )],
            unscannedLiveTokenCarryByDay: [],
            tokenActivityCacheVersion: CodexTokenActivityScanner.currentCacheVersion,
            tokenActivityDays: [CodexTokenActivityDay(day: yesterday, totalTokens: 100)]
        )

        let scanner = ControlledCodexTokenActivityScanner(
            cachedDays: { scanNow in
                productionScanner.cachedDailyActivity(now: scanNow, days: 30)
            },
            scannedResultsByCall: { scanNow, _ in
                productionScanner.scanDailyActivityResult(now: scanNow, days: 30, progress: nil)
            }
        )
        defer { scanner.finishScan() }
        let applied = expectation(description: "production incremental scan applied")
        let model = MenuBarStatusModel(
            store: SignalStateStore(stateFileURL: root.appendingPathComponent("status.json")),
            codexDesktopActivityMonitor: CodexDesktopActivityMonitor(replaysInitialHistory: false),
            codexAccountManager: manager,
            codexUsageSnapshotStore: usageStore,
            codexTokenActivityScanner: scanner,
            tokenActivityScanObserver: { disposition in
                if disposition == .applied { applied.fulfill() }
            },
            nowProvider: { now }
        )
        model.isCodexDesktopMonitoringEnabled = true
        model.isMonitoringPaused = false
        XCTAssertEqual(model.tokenActivityTotal(for: .today, now: now), 50)

        model.refreshTokenActivityIfNeeded()
        let didStartScan = await Task.detached {
            scanner.waitUntilScanStarts(seconds: 2)
        }.value
        XCTAssertTrue(didStartScan)
        XCTAssertTrue(model.isTokenActivityLoading)
        XCTAssertEqual(model.tokenActivityTotal(for: .today, now: now), 50)
        XCTAssertNil(model.tokenActivityEstimatedCost(for: .today, now: now))

        scanner.finishScan()
        await fulfillment(of: [applied], timeout: 3)

        XCTAssertEqual(model.tokenActivityTotal(for: .today, now: now), 50)
        XCTAssertGreaterThan(model.tokenActivityEstimatedCost(for: .today, now: now) ?? 0, 0)
    }

    @MainActor
    func testOrdinaryTokenRefreshKeepsLiveUsageWhileCachedHistoryIsDisplayed() async throws {
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let applied = expectation(description: "token activity scan applied")

        let scanner = ControlledCodexTokenActivityScanner(
            cachedDays: { now in
                let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now) ?? now
                return [CodexTokenActivityDay(day: yesterday, totalTokens: 5_000, estimatedCostUSD: 0.02)]
            },
            scannedDays: { now in
                let today = Calendar.current.startOfDay(for: now)
                let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today) ?? today
                return [
                    CodexTokenActivityDay(day: yesterday, totalTokens: 5_000, estimatedCostUSD: 0.02),
                    CodexTokenActivityDay(day: today, totalTokens: 1_000, estimatedCostUSD: 0.01)
                ]
            }
        )
        defer { scanner.finishScan() }
        let model = MenuBarStatusModel(
            store: fixture.store,
            codexDesktopActivityMonitor: CodexDesktopActivityMonitor(replaysInitialHistory: false),
            codexAccountManager: EmptyCodexAccountManager(),
            codexTokenActivityScanner: scanner,
            tokenActivityScanObserver: { disposition in
                if disposition == .applied {
                    applied.fulfill()
                }
            }
        )
        model.isCodexDesktopMonitoringEnabled = true
        model.isMonitoringPaused = false
        model.appLanguage = .english
        model.updateLatestAgentTokenUsage(AgentTokenUsage(totalTokens: 1_000))

        XCTAssertEqual(model.tokenActivityTotal(for: .today), 1_000)
        model.refreshTokenActivityIfNeeded()
        XCTAssertTrue(scanner.waitUntilScanStarts(seconds: 1))
        for _ in 0..<100 {
            if model.tokenActivityTotal(for: .last30Days) == 6_000 {
                break
            }
            await Task.yield()
        }

        XCTAssertTrue(model.isTokenActivityLoading)
        XCTAssertEqual(model.tokenActivityTotal(for: .today), 1_000)
        XCTAssertEqual(model.tokenActivityTotal(for: .last30Days), 6_000)
        XCTAssertEqual(model.tokenUsageCostText(nil, isLoading: true), "calculating…")

        scanner.finishScan()
        await fulfillment(of: [applied], timeout: 2)

        XCTAssertFalse(model.isTokenActivityLoading)
        XCTAssertEqual(scanner.scanCallCount, 1)
        XCTAssertEqual(model.tokenActivityTotal(for: .today), 1_000)
        XCTAssertEqual(model.tokenActivityTotal(for: .last30Days), 6_000)
        XCTAssertEqual(try XCTUnwrap(model.tokenActivityEstimatedCost(for: .today)), 0.01, accuracy: 0.000_001)
    }

    @MainActor
    func testTokenRefreshPreservesLiveTokensArrivingDuringScan() async throws {
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let retrying = expectation(description: "stale token scan triggers a retry")
        let applied = expectation(description: "retry token scan applied")

        let scanner = ControlledCodexTokenActivityScanner(
            cachedDays: { _ in nil },
            scannedResultsByCall: { now, callIndex in
                let totalTokens = callIndex == 1 ? 1_000 : 1_250
                return CodexTokenActivityScanResult(
                    days: [CodexTokenActivityDay(
                        day: Calendar.current.startOfDay(for: now),
                        totalTokens: totalTokens
                    )],
                    watermarks: [testTokenScanWatermark(
                        sessionID: "session-a",
                        eventAt: now,
                        totalTokens: totalTokens,
                        ordinal: UInt64(callIndex)
                    )]
                )
            }
        )
        defer { scanner.finishScan() }
        let model = MenuBarStatusModel(
            store: fixture.store,
            codexDesktopActivityMonitor: CodexDesktopActivityMonitor(replaysInitialHistory: false),
            codexAccountManager: EmptyCodexAccountManager(),
            codexTokenActivityScanner: scanner,
            tokenActivityScanObserver: { disposition in
                switch disposition {
                case .retryingAfterUnabsorbedUsage:
                    retrying.fulfill()
                case .applied:
                    applied.fulfill()
                case .deferredWithRetryPending, .discardedStaleContext, .discardedInactive:
                    break
                }
            }
        )
        model.isCodexDesktopMonitoringEnabled = true
        model.isMonitoringPaused = false
        let firstEventAt = Date().addingTimeInterval(-10)
        model.updateLatestAgentTokenUsage(
            AgentTokenUsage(totalTokens: 1_000),
            sessionID: "session-a",
            updatedAt: firstEventAt
        )

        model.refreshTokenActivityIfNeeded()
        XCTAssertTrue(scanner.waitUntilScanStarts(seconds: 1))
        model.updateLatestAgentTokenUsage(
            AgentTokenUsage(totalTokens: 1_250),
            sessionID: "session-a",
            updatedAt: firstEventAt.addingTimeInterval(1)
        )

        let secondScanStarted = Task.detached {
            scanner.waitUntilScanStarts(seconds: 2)
        }
        scanner.finishScan()
        await fulfillment(of: [retrying], timeout: 2)
        let didStartSecondScan = await secondScanStarted.value
        XCTAssertTrue(didStartSecondScan)

        XCTAssertTrue(model.isTokenActivityLoading)
        XCTAssertEqual(model.tokenActivityTotal(for: .today), 1_250)
        scanner.finishScan()
        await fulfillment(of: [applied], timeout: 2)

        XCTAssertFalse(model.isTokenActivityLoading)
        XCTAssertEqual(scanner.scanCallCount, 2)
        XCTAssertEqual(model.tokenActivityTotal(for: .today), 1_250)
        model.updateLatestAgentTokenUsage(
            AgentTokenUsage(totalTokens: 1_300),
            sessionID: "session-a",
            updatedAt: Date()
        )
        XCTAssertEqual(model.tokenActivityTotal(for: .today), 1_300)
    }

    @MainActor
    func testTokenRefreshDoesNotDoubleCountWhenFirstScanIncludesConcurrentLiveGrowth() async throws {
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let retrying = expectation(description: "concurrent live growth invalidates first scan")
        let applied = expectation(description: "stable retry containing live growth applied")

        let scanner = ControlledCodexTokenActivityScanner(
            cachedDays: { _ in nil },
            scannedResultsByCall: { now, callIndex in
                CodexTokenActivityScanResult(
                    days: [CodexTokenActivityDay(
                        day: Calendar.current.startOfDay(for: now),
                        totalTokens: 1_250
                    )],
                    watermarks: [testTokenScanWatermark(
                        sessionID: "session-a",
                        eventAt: now,
                        totalTokens: 1_250,
                        ordinal: UInt64(callIndex)
                    )]
                )
            }
        )
        defer { scanner.finishScan() }
        let model = MenuBarStatusModel(
            store: fixture.store,
            codexDesktopActivityMonitor: CodexDesktopActivityMonitor(replaysInitialHistory: false),
            codexAccountManager: EmptyCodexAccountManager(),
            codexTokenActivityScanner: scanner,
            tokenActivityScanObserver: { disposition in
                if disposition == .retryingAfterUnabsorbedUsage {
                    retrying.fulfill()
                } else if disposition == .applied {
                    applied.fulfill()
                }
            }
        )
        model.isCodexDesktopMonitoringEnabled = true
        model.isMonitoringPaused = false
        model.updateLatestAgentTokenUsage(AgentTokenUsage(totalTokens: 1_000))

        model.refreshTokenActivityIfNeeded()
        XCTAssertTrue(scanner.waitUntilScanStarts(seconds: 1))
        model.updateLatestAgentTokenUsage(AgentTokenUsage(totalTokens: 1_250))

        let secondScanStarted = Task.detached {
            scanner.waitUntilScanStarts(seconds: 2)
        }
        scanner.finishScan()
        await fulfillment(of: [retrying], timeout: 2)
        let didStartSecondScan = await secondScanStarted.value
        XCTAssertTrue(didStartSecondScan)
        XCTAssertEqual(model.tokenActivityTotal(for: .today), 1_250)

        scanner.finishScan()
        await fulfillment(of: [applied], timeout: 2)

        XCTAssertEqual(scanner.scanCallCount, 2)
        XCTAssertEqual(model.tokenActivityTotal(for: .today), 1_250)
        model.updateLatestAgentTokenUsage(AgentTokenUsage(totalTokens: 1_300))
        XCTAssertEqual(model.tokenActivityTotal(for: .today), 1_300)
    }

    @MainActor
    func testTokenRefreshDoesNotDoubleCountWhenScanLeadsLivePoll() async throws {
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let firstApplied = expectation(description: "ahead-of-live scan applied")
        let reconciled = expectation(description: "later live poll reconciled")
        var appliedCount = 0

        let scanner = ControlledCodexTokenActivityScanner(
            cachedDays: { _ in nil },
            scannedResultsByCall: { now, callIndex in
                CodexTokenActivityScanResult(
                    days: [CodexTokenActivityDay(
                        day: Calendar.current.startOfDay(for: now),
                        totalTokens: 1_250
                    )],
                    watermarks: [testTokenScanWatermark(
                        sessionID: "session-a",
                        eventAt: now,
                        totalTokens: 1_250,
                        ordinal: UInt64(callIndex)
                    )]
                )
            }
        )
        defer { scanner.finishScan() }
        let model = MenuBarStatusModel(
            store: fixture.store,
            codexDesktopActivityMonitor: CodexDesktopActivityMonitor(replaysInitialHistory: false),
            codexAccountManager: EmptyCodexAccountManager(),
            codexTokenActivityScanner: scanner,
            tokenActivityScanObserver: { disposition in
                guard disposition == .applied else { return }
                appliedCount += 1
                if appliedCount == 1 {
                    firstApplied.fulfill()
                } else {
                    reconciled.fulfill()
                }
            }
        )
        model.isCodexDesktopMonitoringEnabled = true
        model.isMonitoringPaused = false
        let firstEventAt = Date().addingTimeInterval(-10)
        model.updateLatestAgentTokenUsage(
            AgentTokenUsage(totalTokens: 1_000),
            sessionID: "session-a",
            updatedAt: firstEventAt
        )

        model.refreshTokenActivityIfNeeded()
        XCTAssertTrue(scanner.waitUntilScanStarts(seconds: 1))
        scanner.finishScan()
        await fulfillment(of: [firstApplied], timeout: 2)
        XCTAssertEqual(model.tokenActivityTotal(for: .today), 1_250)

        // The JSONL scan already contained this growth. A later live poll must
        // consume the scanner lead instead of adding the same 250 again.
        model.updateLatestAgentTokenUsage(
            AgentTokenUsage(totalTokens: 1_250),
            sessionID: "session-a",
            updatedAt: firstEventAt.addingTimeInterval(1)
        )
        XCTAssertEqual(model.tokenActivityTotal(for: .today), 1_250)

        model.refreshTokenActivityIfNeeded(force: true)
        XCTAssertTrue(scanner.waitUntilScanStarts(seconds: 1))
        scanner.finishScan()
        await fulfillment(of: [reconciled], timeout: 2)
        XCTAssertEqual(scanner.scanCallCount, 2)
        XCTAssertEqual(model.tokenActivityTotal(for: .today), 1_250)

        model.updateLatestAgentTokenUsage(
            AgentTokenUsage(totalTokens: 1_300),
            sessionID: "session-a",
            updatedAt: Date()
        )
        XCTAssertEqual(model.tokenActivityTotal(for: .today), 1_300)
    }

    @MainActor
    func testExactCursorScannerFrontierAbsorbsMultipleDelayedLivePolls() async throws {
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let firstEventAt = Date().addingTimeInterval(-10)
        let sourceID = "/test/scanner-ahead.jsonl"
        let sourceGeneration = "scanner-ahead-generation"
        func cursor(offset: UInt64, fingerprint: String) -> CodexTokenObservationCursor {
            CodexTokenObservationCursor(
                sourceID: sourceID,
                sourceGeneration: sourceGeneration,
                endOffset: offset,
                lineFingerprint: fingerprint
            )
        }
        let firstCursor = cursor(offset: 100, fingerprint: "line-1000")
        let middleCursor = cursor(offset: 200, fingerprint: "line-1250")
        let scannedFrontier = cursor(offset: 300, fingerprint: "line-1300")
        let postScanCursor = cursor(offset: 400, fingerprint: "line-1350")
        let applied = expectation(description: "exact scanner frontier applied")
        let scanner = ControlledCodexTokenActivityScanner(
            cachedDays: { _ in nil },
            scannedResultsByCall: { now, _ in
                CodexTokenActivityScanResult(
                    days: [CodexTokenActivityDay(
                        day: Calendar.current.startOfDay(for: now),
                        totalTokens: 1_300
                    )],
                    watermarks: [CodexTokenActivityScanWatermark(
                        sessionID: "session-a",
                        sourceID: scannedFrontier.sourceID,
                        sourceGeneration: scannedFrontier.sourceGeneration,
                        endOffset: scannedFrontier.endOffset,
                        lineFingerprint: scannedFrontier.lineFingerprint,
                        eventTimestamp: firstEventAt.addingTimeInterval(3),
                        totalTokens: 1_300
                    )]
                )
            }
        )
        defer { scanner.finishScan() }
        let model = MenuBarStatusModel(
            store: fixture.store,
            codexDesktopActivityMonitor: CodexDesktopActivityMonitor(replaysInitialHistory: false),
            codexAccountManager: EmptyCodexAccountManager(),
            codexTokenActivityScanner: scanner,
            tokenActivityScanObserver: { disposition in
                if disposition == .applied { applied.fulfill() }
            }
        )
        model.isCodexDesktopMonitoringEnabled = true
        model.isMonitoringPaused = false
        model.updateLatestAgentTokenUsage(
            AgentTokenUsage(totalTokens: 1_000),
            sessionID: "session-a",
            updatedAt: firstEventAt,
            observationCursor: firstCursor
        )

        model.refreshTokenActivityIfNeeded(force: true)
        XCTAssertTrue(scanner.waitUntilScanStarts(seconds: 1))
        scanner.finishScan()
        await fulfillment(of: [applied], timeout: 2)
        XCTAssertEqual(model.tokenActivityTotal(for: .today), 1_300)

        // A reused device/inode generation must not let another session consume
        // this frontier merely because its offset is lower.
        model.updateLatestAgentTokenUsage(
            AgentTokenUsage(totalTokens: 100),
            sessionID: "session-b",
            updatedAt: firstEventAt.addingTimeInterval(1),
            observationCursor: CodexTokenObservationCursor(
                sourceID: "/test/reused-inode.jsonl",
                sourceGeneration: sourceGeneration,
                endOffset: 50,
                lineFingerprint: "session-b-line-100"
            )
        )
        XCTAssertEqual(model.tokenActivityTotal(for: .today), 1_400)

        model.updateLatestAgentTokenUsage(
            AgentTokenUsage(totalTokens: 1_250),
            sessionID: "session-a",
            updatedAt: firstEventAt.addingTimeInterval(2),
            observationCursor: middleCursor
        )
        XCTAssertEqual(model.tokenActivityTotal(for: .today), 1_400)

        model.updateLatestAgentTokenUsage(
            AgentTokenUsage(totalTokens: 1_300),
            sessionID: "session-a",
            updatedAt: firstEventAt.addingTimeInterval(3),
            observationCursor: scannedFrontier
        )
        XCTAssertEqual(model.tokenActivityTotal(for: .today), 1_400)

        model.updateLatestAgentTokenUsage(
            AgentTokenUsage(totalTokens: 1_350),
            sessionID: "session-a",
            updatedAt: Date(),
            observationCursor: postScanCursor
        )
        XCTAssertEqual(model.tokenActivityTotal(for: .today), 1_450)
    }

    @MainActor
    func testQuarantineTombstoneDoesNotRejectNewerSameInodeSnapshot() async throws {
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let now = Date()
        let sessionID = "same-inode-quarantine-session"
        let sourceID = "/test/same-inode-quarantine.jsonl"
        let sourceGeneration = "same-device-inode"
        let applied = expectation(description: "old snapshot quarantine applied")
        let scanner = ControlledCodexTokenActivityScanner(
            cachedDays: { _ in nil },
            scannedResultsByCall: { _, _ in
                CodexTokenActivityScanResult(
                    days: [],
                    watermarks: [CodexTokenActivityScanWatermark(
                        sessionID: sessionID,
                        sourceID: sourceID,
                        sourceGeneration: sourceGeneration,
                        endOffset: .max,
                        lineFingerprint: "quarantined-old-snapshot",
                        eventTimestamp: nil,
                        totalTokens: nil,
                        sourceStatFingerprint: 100,
                        sourceChangeTimeNanoseconds: 1_000
                    )]
                )
            }
        )
        defer { scanner.finishScan() }
        let model = MenuBarStatusModel(
            store: fixture.store,
            codexDesktopActivityMonitor: CodexDesktopActivityMonitor(replaysInitialHistory: false),
            codexAccountManager: EmptyCodexAccountManager(),
            codexTokenActivityScanner: scanner,
            tokenActivityScanObserver: { disposition in
                if disposition == .applied { applied.fulfill() }
            },
            nowProvider: { now }
        )
        model.isCodexDesktopMonitoringEnabled = true
        model.isMonitoringPaused = false

        model.refreshTokenActivityIfNeeded(force: true)
        XCTAssertTrue(scanner.waitUntilScanStarts(seconds: 1))
        scanner.finishScan()
        await fulfillment(of: [applied], timeout: 2)

        model.updateLatestAgentTokenUsage(
            AgentTokenUsage(totalTokens: 50),
            sessionID: sessionID,
            updatedAt: now,
            observationCursor: CodexTokenObservationCursor(
                sourceID: sourceID,
                sourceGeneration: sourceGeneration,
                sourceStatFingerprint: 200,
                sourceChangeTimeNanoseconds: 2_000,
                endOffset: 100,
                lineFingerprint: "new-snapshot-line-50"
            )
        )

        XCTAssertEqual(model.tokenActivityTotal(for: .today, now: now), 50)
    }

    @MainActor
    func testOlderSnapshotWatermarkCannotCoverNewerSameInodeCursor() async throws {
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let now = Date()
        let sessionID = "same-inode-rewrite-session"
        let sourceID = "/test/same-inode-rewrite.jsonl"
        let sourceGeneration = "same-device-inode"
        let applied = expectation(description: "old snapshot frontier applied")
        let scanner = ControlledCodexTokenActivityScanner(
            cachedDays: { _ in nil },
            scannedResultsByCall: { scanNow, _ in
                CodexTokenActivityScanResult(
                    days: [CodexTokenActivityDay(
                        day: Calendar.current.startOfDay(for: scanNow),
                        totalTokens: 100
                    )],
                    watermarks: [CodexTokenActivityScanWatermark(
                        sessionID: sessionID,
                        sourceID: sourceID,
                        sourceGeneration: sourceGeneration,
                        endOffset: 1_000,
                        lineFingerprint: "old-snapshot-line-100",
                        eventTimestamp: now.addingTimeInterval(-1),
                        totalTokens: 100,
                        sourceStatFingerprint: 100,
                        sourceChangeTimeNanoseconds: 1_000
                    )]
                )
            }
        )
        defer { scanner.finishScan() }
        let model = MenuBarStatusModel(
            store: fixture.store,
            codexDesktopActivityMonitor: CodexDesktopActivityMonitor(replaysInitialHistory: false),
            codexAccountManager: EmptyCodexAccountManager(),
            codexTokenActivityScanner: scanner,
            tokenActivityScanObserver: { disposition in
                if disposition == .applied { applied.fulfill() }
            },
            nowProvider: { now }
        )
        model.isCodexDesktopMonitoringEnabled = true
        model.isMonitoringPaused = false

        model.refreshTokenActivityIfNeeded(force: true)
        XCTAssertTrue(scanner.waitUntilScanStarts(seconds: 1))
        scanner.finishScan()
        await fulfillment(of: [applied], timeout: 2)
        XCTAssertEqual(model.tokenActivityTotal(for: .today, now: now), 100)

        model.updateLatestAgentTokenUsage(
            AgentTokenUsage(totalTokens: 50),
            sessionID: sessionID,
            updatedAt: now,
            observationCursor: CodexTokenObservationCursor(
                sourceID: sourceID,
                sourceGeneration: sourceGeneration,
                sourceStatFingerprint: 200,
                sourceChangeTimeNanoseconds: 2_000,
                endOffset: 100,
                lineFingerprint: "new-snapshot-line-50"
            )
        )

        XCTAssertEqual(model.tokenActivityTotal(for: .today, now: now), 150)
    }

    @MainActor
    func testEqualTimestampOlderCursorCannotCreateResetCarry() throws {
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let model = MenuBarStatusModel(
            store: fixture.store,
            codexDesktopActivityMonitor: CodexDesktopActivityMonitor(replaysInitialHistory: false),
            codexAccountManager: EmptyCodexAccountManager()
        )
        model.isCodexDesktopMonitoringEnabled = true
        model.isMonitoringPaused = false

        let eventAt = Date()
        func cursor(_ offset: UInt64, _ fingerprint: String) -> CodexTokenObservationCursor {
            CodexTokenObservationCursor(
                sourceID: "/test/equal-timestamp.jsonl",
                sourceGeneration: "equal-timestamp-generation",
                endOffset: offset,
                lineFingerprint: fingerprint
            )
        }
        model.updateLatestAgentTokenUsage(
            AgentTokenUsage(totalTokens: 150),
            sessionID: "session-a",
            updatedAt: eventAt,
            observationCursor: cursor(200, "line-150")
        )
        XCTAssertEqual(model.tokenActivityTotal(for: .today, now: eventAt), 150)

        // Delivery order is allowed to differ from JSONL byte order. The older
        // cumulative value must be ignored, not preserved as a 150-token carry
        // followed by a new 100-token counter.
        model.updateLatestAgentTokenUsage(
            AgentTokenUsage(totalTokens: 100),
            sessionID: "session-a",
            updatedAt: eventAt,
            observationCursor: cursor(100, "line-100")
        )
        XCTAssertEqual(model.tokenActivityTotal(for: .today, now: eventAt), 150)

        model.updateLatestAgentTokenUsage(
            AgentTokenUsage(totalTokens: 175),
            sessionID: "session-a",
            updatedAt: eventAt,
            observationCursor: cursor(250, "line-175")
        )
        XCTAssertEqual(model.tokenActivityTotal(for: .today, now: eventAt), 175)
    }

    @MainActor
    func testNewerSameInodeSnapshotWinsDespiteEarlierEventTimestamp() throws {
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let now = try XCTUnwrap(
            Calendar.current.date(
                byAdding: .hour,
                value: 12,
                to: Calendar.current.startOfDay(for: Date())
            )
        )
        let model = MenuBarStatusModel(
            store: fixture.store,
            codexDesktopActivityMonitor: CodexDesktopActivityMonitor(replaysInitialHistory: false),
            codexAccountManager: EmptyCodexAccountManager(),
            nowProvider: { now }
        )
        model.isCodexDesktopMonitoringEnabled = true
        model.isMonitoringPaused = false

        func cursor(
            statFingerprint: Int64,
            changeTimeNanoseconds: Int64,
            offset: UInt64,
            lineFingerprint: String
        ) -> CodexTokenObservationCursor {
            CodexTokenObservationCursor(
                sourceID: "/test/snapshot-timestamp-rollback.jsonl",
                sourceGeneration: "same-device-inode",
                sourceStatFingerprint: statFingerprint,
                sourceChangeTimeNanoseconds: changeTimeNanoseconds,
                endOffset: offset,
                lineFingerprint: lineFingerprint
            )
        }

        model.updateLatestAgentTokenUsage(
            AgentTokenUsage(totalTokens: 100),
            sessionID: "snapshot-timestamp-session",
            updatedAt: now.addingTimeInterval(10),
            observationCursor: cursor(
                statFingerprint: 100,
                changeTimeNanoseconds: 1_000,
                offset: 100,
                lineFingerprint: "old-snapshot-line-100"
            )
        )
        model.updateLatestAgentTokenUsage(
            AgentTokenUsage(totalTokens: 150),
            sessionID: "snapshot-timestamp-session",
            updatedAt: now.addingTimeInterval(5),
            observationCursor: cursor(
                statFingerprint: 200,
                changeTimeNanoseconds: 2_000,
                offset: 200,
                lineFingerprint: "new-snapshot-line-150"
            )
        )

        XCTAssertEqual(model.tokenActivityTotal(for: .today, now: now), 150)
        XCTAssertEqual(model.latestAgentTokenUsage?.effectiveTotalTokens, 150)
    }

    @MainActor
    func testLaterCursorInSameSnapshotWinsDespiteEarlierEventTimestamp() throws {
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 60 * 60)
        let model = MenuBarStatusModel(
            store: fixture.store,
            codexDesktopActivityMonitor: CodexDesktopActivityMonitor(replaysInitialHistory: false),
            codexAccountManager: EmptyCodexAccountManager(),
            nowProvider: { now }
        )
        model.isCodexDesktopMonitoringEnabled = true
        model.isMonitoringPaused = false

        func cursor(offset: UInt64, lineFingerprint: String) -> CodexTokenObservationCursor {
            CodexTokenObservationCursor(
                sourceID: "/test/same-snapshot-byte-order.jsonl",
                sourceGeneration: "same-device-inode",
                sourceStatFingerprint: 300,
                sourceChangeTimeNanoseconds: 3_000,
                endOffset: offset,
                lineFingerprint: lineFingerprint
            )
        }
        model.updateLatestAgentTokenUsage(
            AgentTokenUsage(totalTokens: 100),
            sessionID: "same-snapshot-session",
            updatedAt: now.addingTimeInterval(10),
            observationCursor: cursor(offset: 100, lineFingerprint: "line-100")
        )
        model.updateLatestAgentTokenUsage(
            AgentTokenUsage(totalTokens: 150),
            sessionID: "same-snapshot-session",
            updatedAt: now.addingTimeInterval(5),
            observationCursor: cursor(offset: 200, lineFingerprint: "line-150")
        )

        XCTAssertEqual(model.tokenActivityTotal(for: .today, now: now), 150)
        XCTAssertEqual(model.latestAgentTokenUsage?.effectiveTotalTokens, 150)
    }

    @MainActor
    func testEarlierCursorInSameSnapshotCannotWinWithLaterEventTimestamp() throws {
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 60 * 60)
        let model = MenuBarStatusModel(
            store: fixture.store,
            codexDesktopActivityMonitor: CodexDesktopActivityMonitor(replaysInitialHistory: false),
            codexAccountManager: EmptyCodexAccountManager(),
            nowProvider: { now }
        )
        model.isCodexDesktopMonitoringEnabled = true
        model.isMonitoringPaused = false

        func cursor(offset: UInt64, lineFingerprint: String) -> CodexTokenObservationCursor {
            CodexTokenObservationCursor(
                sourceID: "/test/same-snapshot-byte-order.jsonl",
                sourceGeneration: "same-device-inode",
                sourceStatFingerprint: 300,
                sourceChangeTimeNanoseconds: 3_000,
                endOffset: offset,
                lineFingerprint: lineFingerprint
            )
        }
        model.updateLatestAgentTokenUsage(
            AgentTokenUsage(totalTokens: 150),
            sessionID: "same-snapshot-session",
            updatedAt: now.addingTimeInterval(5),
            observationCursor: cursor(offset: 200, lineFingerprint: "line-150")
        )
        model.updateLatestAgentTokenUsage(
            AgentTokenUsage(totalTokens: 900),
            sessionID: "same-snapshot-session",
            updatedAt: now.addingTimeInterval(10),
            observationCursor: cursor(offset: 100, lineFingerprint: "line-900")
        )

        XCTAssertEqual(model.tokenActivityTotal(for: .today, now: now), 150)
        XCTAssertEqual(model.latestAgentTokenUsage?.effectiveTotalTokens, 150)
    }

    @MainActor
    func testNewerSnapshotCannotMoveLiveCounterToEarlierAccountingDay() throws {
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let today = Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 60 * 60)
        let yesterday = try XCTUnwrap(
            Calendar.current.date(byAdding: .day, value: -1, to: today)
        )
        let model = MenuBarStatusModel(
            store: fixture.store,
            codexDesktopActivityMonitor: CodexDesktopActivityMonitor(replaysInitialHistory: false),
            codexAccountManager: EmptyCodexAccountManager(),
            nowProvider: { today }
        )
        model.isCodexDesktopMonitoringEnabled = true
        model.isMonitoringPaused = false

        func cursor(
            statFingerprint: Int64,
            changeTimeNanoseconds: Int64,
            lineFingerprint: String
        ) -> CodexTokenObservationCursor {
            CodexTokenObservationCursor(
                sourceID: "/test/snapshot-accounting-day.jsonl",
                sourceGeneration: "same-device-inode",
                sourceStatFingerprint: statFingerprint,
                sourceChangeTimeNanoseconds: changeTimeNanoseconds,
                endOffset: 100,
                lineFingerprint: lineFingerprint
            )
        }
        model.updateLatestAgentTokenUsage(
            AgentTokenUsage(totalTokens: 150),
            sessionID: "accounting-day-session",
            updatedAt: today,
            observationCursor: cursor(
                statFingerprint: 100,
                changeTimeNanoseconds: 1_000,
                lineFingerprint: "today-line-150"
            )
        )
        model.updateLatestAgentTokenUsage(
            AgentTokenUsage(totalTokens: 900),
            sessionID: "accounting-day-session",
            updatedAt: yesterday,
            observationCursor: cursor(
                statFingerprint: 200,
                changeTimeNanoseconds: 2_000,
                lineFingerprint: "yesterday-line-900"
            )
        )

        XCTAssertEqual(model.tokenActivityTotal(for: .today, now: today), 150)
        XCTAssertEqual(model.latestAgentTokenUsage?.effectiveTotalTokens, 150)
    }

    @MainActor
    func testCursorlessReplayCannotOverwriteNewerCursorSnapshot() throws {
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 60 * 60)
        let oldExactAt = now.addingTimeInterval(10.789)
        let newerExactAt = now.addingTimeInterval(5.123)
        let sessionID = "cursorless-watcher-race-session"

        func cursor(
            statFingerprint: Int64,
            changeTimeNanoseconds: Int64,
            lineFingerprint: String
        ) -> CodexTokenObservationCursor {
            CodexTokenObservationCursor(
                sourceID: "/test/cursorless-watcher-race.jsonl",
                sourceGeneration: "same-device-inode",
                sourceStatFingerprint: statFingerprint,
                sourceChangeTimeNanoseconds: changeTimeNanoseconds,
                endOffset: 100,
                lineFingerprint: lineFingerprint
            )
        }

        func tokenLine(at timestamp: Date, cumulative: Int, lastTurn: Int) -> String {
            """
            {"timestamp":"\(isoTimestamp(timestamp))","type":"event_msg","payload":{"type":"token_count","info":{"model_context_window":258400,"total_token_usage":{"input_tokens":\(cumulative),"cached_input_tokens":0,"output_tokens":0,"total_tokens":\(cumulative)},"last_token_usage":{"input_tokens":\(lastTurn),"cached_input_tokens":0,"output_tokens":0,"total_tokens":\(lastTurn)}}}}
            """
        }

        let oldCursor = cursor(
            statFingerprint: 100,
            changeTimeNanoseconds: 1_000,
            lineFingerprint: "old-snapshot-line-1000"
        )
        let newerCursor = cursor(
            statFingerprint: 200,
            changeTimeNanoseconds: 2_000,
            lineFingerprint: "new-snapshot-line-1500"
        )
        let oldUpdate = try XCTUnwrap(CodexDesktopSessionParser.quotaUpdate(
            from: tokenLine(at: oldExactAt, cumulative: 1_000, lastTurn: 100),
            defaultSessionID: sessionID,
            tokenObservationCursor: oldCursor
        ))
        let newerUpdate = try XCTUnwrap(CodexDesktopSessionParser.quotaUpdate(
            from: tokenLine(at: newerExactAt, cumulative: 1_500, lastTurn: 150),
            defaultSessionID: sessionID,
            tokenObservationCursor: newerCursor
        ))
        XCTAssertEqual(oldUpdate.tokenActivityUsage?.effectiveTotalTokens, 1_000)
        XCTAssertEqual(oldUpdate.quota.tokenUsage?.effectiveTotalTokens, 100)

        let roundTripStore = SignalStateStore(
            stateFileURL: fixture.directory.appendingPathComponent("roundtrip-status.json")
        )
        _ = try roundTripStore.applySessionQuota(
            oldUpdate.quota,
            sessionID: oldUpdate.sessionID,
            agent: oldUpdate.agent,
            updatedAt: oldUpdate.quota.updatedAt
        )
        let roundTrippedShadow = try XCTUnwrap(
            roundTripStore.readSnapshot().sessions.first(where: {
                $0.sessionID == sessionID
            })?.quota
        )
        XCTAssertNotEqual(roundTrippedShadow.updatedAt, oldExactAt)
        XCTAssertEqual(roundTrippedShadow.tokenUsage?.effectiveTotalTokens, 100)

        let model = MenuBarStatusModel(
            store: fixture.store,
            codexDesktopActivityMonitor: CodexDesktopActivityMonitor(replaysInitialHistory: false),
            codexAccountManager: EmptyCodexAccountManager(),
            nowProvider: { now }
        )
        model.isCodexDesktopMonitoringEnabled = true
        model.isMonitoringPaused = false

        // The watcher can capture the first cursor-less SignalState value,
        // deliver the newer file snapshot, and only then apply the old copy.
        model.updateLatestAgentTokenUsage(
            try XCTUnwrap(oldUpdate.tokenActivityUsage),
            sessionID: sessionID,
            updatedAt: oldExactAt,
            observationCursor: oldCursor,
            stateShadowUsage: oldUpdate.quota.tokenUsage
        )
        model.updateLatestAgentTokenUsage(
            try XCTUnwrap(newerUpdate.tokenActivityUsage),
            sessionID: sessionID,
            updatedAt: newerExactAt,
            observationCursor: newerCursor,
            stateShadowUsage: newerUpdate.quota.tokenUsage
        )
        model.updateLatestAgentTokenUsage(
            try XCTUnwrap(roundTrippedShadow.tokenUsage),
            sessionID: sessionID,
            updatedAt: roundTrippedShadow.updatedAt
        )

        XCTAssertEqual(model.tokenActivityTotal(for: .today, now: now), 1_500)
        XCTAssertEqual(model.latestAgentTokenUsage?.effectiveTotalTokens, 1_500)
    }

    @MainActor
    func testNewCursorlessResetAfterExactObservationRemainsAccepted() throws {
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 60 * 60)
        let sessionID = "cursorless-reset-after-exact-session"
        let model = MenuBarStatusModel(
            store: fixture.store,
            codexDesktopActivityMonitor: CodexDesktopActivityMonitor(replaysInitialHistory: false),
            codexAccountManager: EmptyCodexAccountManager(),
            nowProvider: { now }
        )
        model.isCodexDesktopMonitoringEnabled = true
        model.isMonitoringPaused = false

        model.updateLatestAgentTokenUsage(
            AgentTokenUsage(totalTokens: 1_000),
            sessionID: sessionID,
            updatedAt: now,
            observationCursor: CodexTokenObservationCursor(
                sourceID: "/test/cursorless-reset-after-exact.jsonl",
                sourceGeneration: "exact-generation",
                sourceStatFingerprint: 100,
                sourceChangeTimeNanoseconds: 1_000,
                endOffset: 100,
                lineFingerprint: "exact-line-1000"
            ),
            stateShadowUsage: AgentTokenUsage(totalTokens: 1_000)
        )

        // This is not the cursor-less shadow of the exact observation above:
        // it is a later counter reset and must remain part of the live ledger.
        model.updateLatestAgentTokenUsage(
            AgentTokenUsage(totalTokens: 100),
            sessionID: sessionID,
            updatedAt: now.addingTimeInterval(1)
        )

        XCTAssertEqual(model.tokenActivityTotal(for: .today, now: now), 1_100)
        XCTAssertEqual(model.latestAgentTokenUsage?.effectiveTotalTokens, 100)
    }

    @MainActor
    func testOlderSameInodeSnapshotCannotWinWithLaterEventTimestamp() throws {
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let now = try XCTUnwrap(
            Calendar.current.date(
                byAdding: .hour,
                value: 12,
                to: Calendar.current.startOfDay(for: Date())
            )
        )
        let model = MenuBarStatusModel(
            store: fixture.store,
            codexDesktopActivityMonitor: CodexDesktopActivityMonitor(replaysInitialHistory: false),
            codexAccountManager: EmptyCodexAccountManager(),
            nowProvider: { now }
        )
        model.isCodexDesktopMonitoringEnabled = true
        model.isMonitoringPaused = false

        func cursor(
            statFingerprint: Int64,
            changeTimeNanoseconds: Int64,
            offset: UInt64,
            lineFingerprint: String
        ) -> CodexTokenObservationCursor {
            CodexTokenObservationCursor(
                sourceID: "/test/snapshot-timestamp-reorder.jsonl",
                sourceGeneration: "same-device-inode",
                sourceStatFingerprint: statFingerprint,
                sourceChangeTimeNanoseconds: changeTimeNanoseconds,
                endOffset: offset,
                lineFingerprint: lineFingerprint
            )
        }

        model.updateLatestAgentTokenUsage(
            AgentTokenUsage(totalTokens: 150),
            sessionID: "snapshot-timestamp-session",
            updatedAt: now.addingTimeInterval(5),
            observationCursor: cursor(
                statFingerprint: 200,
                changeTimeNanoseconds: 2_000,
                offset: 200,
                lineFingerprint: "new-snapshot-line-150"
            )
        )
        model.updateLatestAgentTokenUsage(
            AgentTokenUsage(totalTokens: 900),
            sessionID: "snapshot-timestamp-session",
            updatedAt: now.addingTimeInterval(10),
            observationCursor: cursor(
                statFingerprint: 100,
                changeTimeNanoseconds: 1_000,
                offset: 100,
                lineFingerprint: "old-snapshot-line-900"
            )
        )

        XCTAssertEqual(model.tokenActivityTotal(for: .today, now: now), 150)
        XCTAssertEqual(model.latestAgentTokenUsage?.effectiveTotalTokens, 150)
    }

    @MainActor
    func testNewGenerationScannerFrontierRetainsDelayedPreCutoffPoll() async throws {
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let baseNow = Date().addingTimeInterval(-60)
        let clock = TestDateClock(baseNow)
        let delayedEventAt = baseNow.addingTimeInterval(-10)
        let cursor = CodexTokenObservationCursor(
            sourceID: "/test/new-delayed-generation.jsonl",
            sourceGeneration: "new-delayed-generation",
            endOffset: 200,
            lineFingerprint: "new-delayed-line"
        )
        let firstApplied = expectation(description: "initial frontier scan applied")
        let secondApplied = expectation(description: "new generation scan applied")
        let scanner = ControlledCodexTokenActivityScanner(
            cachedDays: { _ in nil },
            scannedResultsByCall: { now, callIndex in
                if callIndex == 1 {
                    return CodexTokenActivityScanResult(
                        days: [CodexTokenActivityDay(
                            day: Calendar.current.startOfDay(for: now),
                            totalTokens: 1_000
                        )],
                        watermarks: []
                    )
                }
                return CodexTokenActivityScanResult(
                    days: [CodexTokenActivityDay(
                        day: Calendar.current.startOfDay(for: now),
                        totalTokens: 1_100
                    )],
                    watermarks: [CodexTokenActivityScanWatermark(
                        sessionID: "delayed-session",
                        sourceID: cursor.sourceID,
                        sourceGeneration: cursor.sourceGeneration,
                        endOffset: cursor.endOffset,
                        lineFingerprint: cursor.lineFingerprint,
                        eventTimestamp: delayedEventAt,
                        totalTokens: 100
                    )]
                )
            }
        )
        defer { scanner.finishScan() }
        var appliedCount = 0
        let model = MenuBarStatusModel(
            store: fixture.store,
            codexDesktopActivityMonitor: CodexDesktopActivityMonitor(replaysInitialHistory: false),
            codexAccountManager: EmptyCodexAccountManager(),
            codexTokenActivityScanner: scanner,
            tokenActivityScanObserver: { disposition in
                guard disposition == .applied else { return }
                appliedCount += 1
                if appliedCount == 1 {
                    firstApplied.fulfill()
                } else if appliedCount == 2 {
                    secondApplied.fulfill()
                }
            },
            nowProvider: { clock.now() }
        )
        model.isCodexDesktopMonitoringEnabled = true
        model.isMonitoringPaused = false

        model.refreshTokenActivityIfNeeded(force: true)
        XCTAssertTrue(scanner.waitUntilScanStarts(seconds: 1))
        scanner.finishScan()
        await fulfillment(of: [firstApplied], timeout: 2)

        clock.advance(by: 10)
        model.refreshTokenActivityIfNeeded(force: true)
        XCTAssertTrue(scanner.waitUntilScanStarts(seconds: 1))
        scanner.finishScan()
        await fulfillment(of: [secondApplied], timeout: 2)
        XCTAssertEqual(model.tokenActivityTotal(for: .today), 1_100)

        model.updateLatestAgentTokenUsage(
            AgentTokenUsage(totalTokens: 100),
            sessionID: "delayed-session",
            updatedAt: delayedEventAt,
            observationCursor: cursor
        )
        XCTAssertEqual(model.tokenActivityTotal(for: .today), 1_100)
    }

    @MainActor
    func testLatePreCutoffLineRemainsPendingUntilItsExactCursorIsScanned() async throws {
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let firstEventAt = Date().addingTimeInterval(-20)
        let lateEventAt = firstEventAt.addingTimeInterval(1)
        let firstCursor = CodexTokenObservationCursor(
            sourceID: "/test/session-a.jsonl",
            sourceGeneration: "generation-a",
            endOffset: 100,
            lineFingerprint: "line-1000"
        )
        let lateCursor = CodexTokenObservationCursor(
            sourceID: firstCursor.sourceID,
            sourceGeneration: firstCursor.sourceGeneration,
            endOffset: 200,
            lineFingerprint: "line-1250"
        )
        let firstApplied = expectation(description: "first cursor-backed scan applied")
        let secondApplied = expectation(description: "late cursor-backed scan applied")
        var appliedCount = 0
        let scanner = ControlledCodexTokenActivityScanner(
            cachedDays: { _ in nil },
            scannedResultsByCall: { now, callIndex in
                let total = callIndex == 1 ? 1_000 : 1_250
                let cursor = callIndex == 1 ? firstCursor : lateCursor
                let eventAt = callIndex == 1 ? firstEventAt : lateEventAt
                return CodexTokenActivityScanResult(
                    days: [CodexTokenActivityDay(
                        day: Calendar.current.startOfDay(for: now),
                        totalTokens: total
                    )],
                    watermarks: [CodexTokenActivityScanWatermark(
                        sessionID: "session-a",
                        sourceID: cursor.sourceID,
                        sourceGeneration: cursor.sourceGeneration,
                        endOffset: cursor.endOffset,
                        lineFingerprint: cursor.lineFingerprint,
                        eventTimestamp: eventAt,
                        totalTokens: total
                    )]
                )
            }
        )
        defer { scanner.finishScan() }
        let model = MenuBarStatusModel(
            store: fixture.store,
            codexDesktopActivityMonitor: CodexDesktopActivityMonitor(replaysInitialHistory: false),
            codexAccountManager: EmptyCodexAccountManager(),
            codexTokenActivityScanner: scanner,
            tokenActivityScanObserver: { disposition in
                guard disposition == .applied else { return }
                appliedCount += 1
                if appliedCount == 1 {
                    firstApplied.fulfill()
                } else if appliedCount == 2 {
                    secondApplied.fulfill()
                }
            }
        )
        model.isCodexDesktopMonitoringEnabled = true
        model.isMonitoringPaused = false
        model.updateLatestAgentTokenUsage(
            AgentTokenUsage(totalTokens: 1_000),
            sessionID: "session-a",
            updatedAt: firstEventAt,
            observationCursor: firstCursor
        )

        model.refreshTokenActivityIfNeeded(force: true)
        XCTAssertTrue(scanner.waitUntilScanStarts(seconds: 1))
        scanner.finishScan()
        await fulfillment(of: [firstApplied], timeout: 2)

        // The event timestamp predates the committed scan, but its line was
        // appended after EOF. A wall-clock cutoff would lose these 250 tokens.
        model.updateLatestAgentTokenUsage(
            AgentTokenUsage(totalTokens: 1_250),
            sessionID: "session-a",
            updatedAt: lateEventAt,
            observationCursor: lateCursor
        )
        XCTAssertEqual(model.tokenActivityTotal(for: .today), 1_250)

        model.refreshTokenActivityIfNeeded(force: true)
        XCTAssertTrue(scanner.waitUntilScanStarts(seconds: 1))
        scanner.finishScan()
        await fulfillment(of: [secondApplied], timeout: 2)
        XCTAssertEqual(scanner.scanCallCount, 2)
        XCTAssertEqual(model.tokenActivityTotal(for: .today), 1_250)
    }

    @MainActor
    func testArchivedSessionRenameStillAbsorbsExactCursor() async throws {
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let eventAt = Date().addingTimeInterval(-1)
        let liveCursor = CodexTokenObservationCursor(
            sourceID: "/test/sessions/session-a.jsonl",
            sourceGeneration: "device-inode-a",
            endOffset: 420,
            lineFingerprint: "exact-line-a"
        )
        let applied = expectation(description: "renamed archive cursor absorbed")
        let scanner = ControlledCodexTokenActivityScanner(
            cachedDays: { _ in nil },
            scannedResultsByCall: { now, _ in
                CodexTokenActivityScanResult(
                    days: [CodexTokenActivityDay(
                        day: Calendar.current.startOfDay(for: now),
                        totalTokens: 100
                    )],
                    watermarks: [CodexTokenActivityScanWatermark(
                        sessionID: "session-a",
                        sourceID: "/test/archived_sessions/session-a.jsonl",
                        sourceGeneration: liveCursor.sourceGeneration,
                        endOffset: liveCursor.endOffset,
                        lineFingerprint: liveCursor.lineFingerprint,
                        eventTimestamp: eventAt,
                        totalTokens: 100
                    )]
                )
            }
        )
        defer { scanner.finishScan() }
        let model = MenuBarStatusModel(
            store: fixture.store,
            codexDesktopActivityMonitor: CodexDesktopActivityMonitor(replaysInitialHistory: false),
            codexAccountManager: EmptyCodexAccountManager(),
            codexTokenActivityScanner: scanner,
            tokenActivityScanObserver: { disposition in
                if disposition == .applied { applied.fulfill() }
            }
        )
        model.isCodexDesktopMonitoringEnabled = true
        model.isMonitoringPaused = false
        model.updateLatestAgentTokenUsage(
            AgentTokenUsage(totalTokens: 100),
            sessionID: "session-a",
            updatedAt: eventAt,
            observationCursor: liveCursor
        )

        model.refreshTokenActivityIfNeeded(force: true)
        XCTAssertTrue(scanner.waitUntilScanStarts(seconds: 1))
        scanner.finishScan()
        await fulfillment(of: [applied], timeout: 2)

        XCTAssertEqual(model.tokenActivityTotal(for: .today), 100)
    }

    @MainActor
    func testScannerAheadThenCounterResetDoesNotDoubleCountLateUsage() async throws {
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let applied = expectation(description: "scanner-ahead reset scan applied")
        let firstEventAt = Date().addingTimeInterval(-20)
        let scanner = ControlledCodexTokenActivityScanner(
            cachedDays: { _ in nil },
            scannedResultsByCall: { now, _ in
                CodexTokenActivityScanResult(
                    days: [CodexTokenActivityDay(
                        day: Calendar.current.startOfDay(for: now),
                        totalTokens: 1_100
                    )],
                    watermarks: [testTokenScanWatermark(
                        sessionID: "session-a",
                        eventAt: now,
                        totalTokens: 100
                    )]
                )
            }
        )
        defer { scanner.finishScan() }
        let model = MenuBarStatusModel(
            store: fixture.store,
            codexDesktopActivityMonitor: CodexDesktopActivityMonitor(replaysInitialHistory: false),
            codexAccountManager: EmptyCodexAccountManager(),
            codexTokenActivityScanner: scanner,
            tokenActivityScanObserver: { disposition in
                if disposition == .applied {
                    applied.fulfill()
                }
            }
        )
        model.isCodexDesktopMonitoringEnabled = true
        model.isMonitoringPaused = false
        model.updateLatestAgentTokenUsage(
            AgentTokenUsage(totalTokens: 1_000),
            sessionID: "session-a",
            updatedAt: firstEventAt
        )

        model.refreshTokenActivityIfNeeded()
        XCTAssertTrue(scanner.waitUntilScanStarts(seconds: 1))
        scanner.finishScan()
        await fulfillment(of: [applied], timeout: 2)
        XCTAssertEqual(model.tokenActivityTotal(for: .today), 1_100)

        // This reset was already present before the strict scan cutoff but its
        // desktop poll arrived later. It must be absorbed, not added again.
        model.updateLatestAgentTokenUsage(
            AgentTokenUsage(totalTokens: 100),
            sessionID: "session-a",
            updatedAt: firstEventAt.addingTimeInterval(1)
        )
        XCTAssertEqual(model.tokenActivityTotal(for: .today), 1_100)

        let postScanEventAt = Date()
        model.updateLatestAgentTokenUsage(
            AgentTokenUsage(totalTokens: 150),
            sessionID: "session-a",
            updatedAt: postScanEventAt
        )
        XCTAssertEqual(model.tokenActivityTotal(for: .today), 1_150)

        // An older pre-cutoff event arriving out of order cannot resurrect the
        // previous counter generation.
        model.updateLatestAgentTokenUsage(
            AgentTokenUsage(totalTokens: 1_250),
            sessionID: "session-a",
            updatedAt: firstEventAt.addingTimeInterval(2)
        )
        XCTAssertEqual(model.tokenActivityTotal(for: .today), 1_150)
    }

    @MainActor
    func testTokenRefreshDoesNotAdvanceBaselineWhenScanHasNoTodayData() async throws {
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let clock = TestDateClock(
            Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 60 * 60)
        )
        let retrying = expectation(description: "missing today triggers one immediate retry")
        let deferred = expectation(description: "missing today remains pending after retry")
        let applied = expectation(description: "pending refresh applies once today is available")

        let scanner = ControlledCodexTokenActivityScanner(
            cachedDays: { _ in nil },
            scannedDaysByCall: { now, callIndex in
                if callIndex >= 3 {
                    return [
                        CodexTokenActivityDay(
                            day: Calendar.current.startOfDay(for: now),
                            totalTokens: 900,
                            estimatedCostUSD: 0.01
                        )
                    ]
                }
                let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now) ?? now
                return [CodexTokenActivityDay(day: yesterday, totalTokens: 5_000)]
            }
        )
        defer { scanner.finishScan() }
        let model = MenuBarStatusModel(
            store: fixture.store,
            codexDesktopActivityMonitor: CodexDesktopActivityMonitor(
                sessionRootURLs: [],
                vsCodeLogRootURL: fixture.directory,
                replaysInitialHistory: false
            ),
            codexAccountManager: EmptyCodexAccountManager(),
            codexTokenActivityScanner: scanner,
            tokenActivityScanObserver: { disposition in
                switch disposition {
                case .retryingAfterUnabsorbedUsage:
                    retrying.fulfill()
                case .deferredWithRetryPending:
                    deferred.fulfill()
                case .applied:
                    applied.fulfill()
                case .discardedStaleContext, .discardedInactive:
                    break
                }
            },
            nowProvider: { clock.now() }
        )
        model.isCodexDesktopMonitoringEnabled = true
        model.isMonitoringPaused = false
        model.updateLatestAgentTokenUsage(AgentTokenUsage(totalTokens: 900))

        model.refreshTokenActivityIfNeeded()
        XCTAssertTrue(scanner.waitUntilScanStarts(seconds: 1))

        let secondScanStarted = Task.detached {
            scanner.waitUntilScanStarts(seconds: 2)
        }
        scanner.finishScan()
        await fulfillment(of: [retrying], timeout: 2)
        let didStartSecondScan = await secondScanStarted.value
        XCTAssertTrue(didStartSecondScan)

        XCTAssertTrue(model.isTokenActivityLoading)
        XCTAssertEqual(model.tokenActivityTotal(for: .today), 900)
        // Make the scan appear 30 seconds long, then fail it. Backoff must begin
        // at failure completion, not at the original scan start.
        clock.advance(by: 30)
        scanner.finishScan()
        await fulfillment(of: [deferred], timeout: 2)

        XCTAssertFalse(model.isTokenActivityLoading)
        XCTAssertEqual(scanner.scanCallCount, 2)
        XCTAssertTrue(model.tokenActivityDays.isEmpty)
        XCTAssertEqual(model.tokenActivityTotal(for: .today), 900)

        // A parser failure must not trigger a full disk scan every two seconds.
        model.refreshTokenActivityIfNeeded()
        XCTAssertFalse(scanner.waitUntilScanStarts(seconds: 0.1))

        clock.advance(by: 4.9)
        model.refreshTokenActivityIfNeeded()
        XCTAssertFalse(scanner.waitUntilScanStarts(seconds: 0.1))

        clock.advance(by: 0.1)
        model.refreshTokenActivityIfNeeded()
        XCTAssertTrue(scanner.waitUntilScanStarts(seconds: 1))
        scanner.finishScan()
        await fulfillment(of: [applied], timeout: 2)

        XCTAssertFalse(model.isTokenActivityLoading)
        XCTAssertEqual(scanner.scanCallCount, 3)
        XCTAssertEqual(model.tokenActivityTotal(for: .today), 900)
        XCTAssertEqual(try XCTUnwrap(model.tokenActivityEstimatedCost(for: .today)), 0.01, accuracy: 0.000_001)
    }

    @MainActor
    func testAuthoritativeScanCanCorrectCachedAggregateDownwardWithoutRetryLoop() async throws {
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let applied = expectation(description: "lower authoritative aggregate applied")
        let scanner = ControlledCodexTokenActivityScanner(
            cachedDays: { now in
                [CodexTokenActivityDay(
                    day: Calendar.current.startOfDay(for: now),
                    totalTokens: 1_000
                )]
            },
            scannedDays: { now in
                [CodexTokenActivityDay(
                    day: Calendar.current.startOfDay(for: now),
                    totalTokens: 750
                )]
            }
        )
        defer { scanner.finishScan() }
        let model = MenuBarStatusModel(
            store: fixture.store,
            codexDesktopActivityMonitor: CodexDesktopActivityMonitor(replaysInitialHistory: false),
            codexAccountManager: EmptyCodexAccountManager(),
            codexTokenActivityScanner: scanner,
            tokenActivityScanObserver: { disposition in
                if disposition == .applied { applied.fulfill() }
            }
        )
        model.isCodexDesktopMonitoringEnabled = true
        model.isMonitoringPaused = false
        model.refreshTokenActivityIfNeeded(force: true)
        XCTAssertTrue(scanner.waitUntilScanStarts(seconds: 1))
        for _ in 0..<100 where model.tokenActivityTotal(for: .today) != 1_000 {
            await Task.yield()
        }
        XCTAssertEqual(model.tokenActivityTotal(for: .today), 1_000)
        scanner.finishScan()
        await fulfillment(of: [applied], timeout: 2)

        XCTAssertEqual(scanner.scanCallCount, 1)
        XCTAssertEqual(model.tokenActivityTotal(for: .today), 750)
    }

    @MainActor
    func testIncompleteScanCannotEraseLastKnownGoodAggregate() async throws {
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let retrying = expectation(description: "incomplete scan retries once")
        let deferred = expectation(description: "repeated incomplete scan defers")
        let scanner = ControlledCodexTokenActivityScanner(
            cachedDays: { now in
                [CodexTokenActivityDay(
                    day: Calendar.current.startOfDay(for: now),
                    totalTokens: 1_000
                )]
            },
            scannedResultsByCall: { _, _ in
                CodexTokenActivityScanResult(
                    days: [],
                    watermarks: [],
                    isComplete: false
                )
            }
        )
        defer { scanner.finishScan() }
        let model = MenuBarStatusModel(
            store: fixture.store,
            codexDesktopActivityMonitor: CodexDesktopActivityMonitor(replaysInitialHistory: false),
            codexAccountManager: EmptyCodexAccountManager(),
            codexTokenActivityScanner: scanner,
            tokenActivityScanObserver: { disposition in
                if disposition == .retryingAfterUnabsorbedUsage {
                    retrying.fulfill()
                } else if disposition == .deferredWithRetryPending {
                    deferred.fulfill()
                }
            }
        )
        model.isCodexDesktopMonitoringEnabled = true
        model.isMonitoringPaused = false
        model.refreshTokenActivityIfNeeded(force: true)
        XCTAssertTrue(scanner.waitUntilScanStarts(seconds: 1))
        for _ in 0..<100 where model.tokenActivityTotal(for: .today) != 1_000 {
            await Task.yield()
        }
        XCTAssertEqual(model.tokenActivityTotal(for: .today), 1_000)
        let replacementStarted = Task.detached {
            scanner.waitUntilScanStarts(seconds: 2)
        }
        scanner.finishScan()
        await fulfillment(of: [retrying], timeout: 2)
        let didStartReplacement = await replacementStarted.value
        XCTAssertTrue(didStartReplacement)
        scanner.finishScan()
        await fulfillment(of: [deferred], timeout: 2)

        XCTAssertEqual(scanner.scanCallCount, 2)
        XCTAssertEqual(model.tokenActivityTotal(for: .today), 1_000)
        XCTAssertEqual(model.tokenActivityDays, [
            CodexTokenActivityDay(
                day: Calendar.current.startOfDay(for: Date()),
                totalTokens: 1_000
            ),
        ])
    }

    @MainActor
    func testTokenRefreshReconcilesCounterResetWithoutDroppingOrDoubleCounting() async throws {
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let firstApplied = expectation(description: "initial token baseline applied")
        let retrying = expectation(description: "reset-time stale scan retries")
        let resetApplied = expectation(description: "reset-aware retry applied")
        var appliedCount = 0

        let scanner = ControlledCodexTokenActivityScanner(
            cachedDays: { _ in nil },
            scannedDaysByCall: { now, callIndex in
                let totalTokens: Int
                switch callIndex {
                case 1, 2:
                    totalTokens = 1_000
                default:
                    totalTokens = 1_550
                }
                return [
                    CodexTokenActivityDay(
                        day: Calendar.current.startOfDay(for: now),
                        totalTokens: totalTokens
                    )
                ]
            }
        )
        defer { scanner.finishScan() }
        let model = MenuBarStatusModel(
            store: fixture.store,
            codexDesktopActivityMonitor: CodexDesktopActivityMonitor(replaysInitialHistory: false),
            codexAccountManager: EmptyCodexAccountManager(),
            codexTokenActivityScanner: scanner,
            tokenActivityScanObserver: { disposition in
                switch disposition {
                case .applied:
                    appliedCount += 1
                    if appliedCount == 1 {
                        firstApplied.fulfill()
                    } else {
                        resetApplied.fulfill()
                    }
                case .retryingAfterUnabsorbedUsage:
                    retrying.fulfill()
                case .deferredWithRetryPending, .discardedStaleContext, .discardedInactive:
                    break
                }
            }
        )
        model.isCodexDesktopMonitoringEnabled = true
        model.isMonitoringPaused = false
        model.updateLatestAgentTokenUsage(AgentTokenUsage(totalTokens: 1_000))

        model.refreshTokenActivityIfNeeded()
        XCTAssertTrue(scanner.waitUntilScanStarts(seconds: 1))
        scanner.finishScan()
        await fulfillment(of: [firstApplied], timeout: 2)
        XCTAssertEqual(model.tokenActivityTotal(for: .today), 1_000)

        model.refreshTokenActivityIfNeeded(force: true)
        XCTAssertTrue(scanner.waitUntilScanStarts(seconds: 1))
        model.updateLatestAgentTokenUsage(AgentTokenUsage(totalTokens: 250))
        model.updateLatestAgentTokenUsage(AgentTokenUsage(totalTokens: 400))
        XCTAssertEqual(model.tokenActivityTotal(for: .today), 1_400)
        model.updateLatestAgentTokenUsage(AgentTokenUsage(totalTokens: 100))
        XCTAssertEqual(model.tokenActivityTotal(for: .today), 1_500)
        model.updateLatestAgentTokenUsage(AgentTokenUsage(totalTokens: 150))
        XCTAssertEqual(model.tokenActivityTotal(for: .today), 1_550)

        let thirdScanStarted = Task.detached {
            scanner.waitUntilScanStarts(seconds: 2)
        }
        scanner.finishScan()
        await fulfillment(of: [retrying], timeout: 2)
        let didStartThirdScan = await thirdScanStarted.value
        XCTAssertTrue(didStartThirdScan)
        XCTAssertEqual(model.tokenActivityTotal(for: .today), 1_550)

        scanner.finishScan()
        await fulfillment(of: [resetApplied], timeout: 2)
        XCTAssertEqual(scanner.scanCallCount, 3)
        XCTAssertEqual(model.tokenActivityTotal(for: .today), 1_550)

        model.updateLatestAgentTokenUsage(AgentTokenUsage(totalTokens: 200))
        XCTAssertEqual(model.tokenActivityTotal(for: .today), 1_600)
    }

    @MainActor
    func testForkedLiveCounterDoesNotCountInheritedParentTokensTwice() throws {
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let model = MenuBarStatusModel(
            store: fixture.store,
            codexDesktopActivityMonitor: CodexDesktopActivityMonitor(replaysInitialHistory: false),
            codexAccountManager: EmptyCodexAccountManager()
        )

        model.updateLatestAgentTokenUsage(
            AgentTokenUsage(totalTokens: 1_000),
            sessionID: "parent-session",
            updatedAt: Date().addingTimeInterval(-2)
        )
        model.updateLatestAgentTokenUsage(
            AgentTokenUsage(totalTokens: 1_100),
            sessionID: "fork-session",
            updatedAt: Date().addingTimeInterval(-1),
            initialScannedBaseline: 1_000
        )
        XCTAssertEqual(model.tokenActivityTotal(for: .today), 1_100)

        model.updateLatestAgentTokenUsage(
            AgentTokenUsage(totalTokens: 1_200),
            sessionID: "fork-session",
            updatedAt: Date()
        )
        XCTAssertEqual(model.tokenActivityTotal(for: .today), 1_200)
    }

    @MainActor
    func testForkedLivePollUsesChildTurnDeltaWhenParentGrowsAfterFork() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fork-live-poll-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let parentSessionID = "019c846a-b85e-7bd3-924b-cc33e3f180d9"
        let childSessionID = "019c846a-b85e-7bd3-924b-cc33e3f180e0"
        let now = Date()
        let parentForkTotalAt = isoTimestamp(now.addingTimeInterval(-4))
        let forkedAt = isoTimestamp(now.addingTimeInterval(-3))
        let parentAfterForkAt = isoTimestamp(now.addingTimeInterval(-2))
        let childTurnAt = isoTimestamp(now.addingTimeInterval(-1))
        let filenameDay = ISO8601DateFormatter().string(from: now).prefix(10)

        func tokenLine(timestamp: String, total: Int, last: Int) -> String {
            """
            {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"model_context_window":258400,"total_token_usage":{"input_tokens":\(total),"cached_input_tokens":0,"output_tokens":0,"total_tokens":\(total)},"last_token_usage":{"input_tokens":\(last),"cached_input_tokens":0,"output_tokens":0,"total_tokens":\(last)}}}}
            """
        }

        let parentURL = root.appendingPathComponent(
            "rollout-\(filenameDay)T23-00-00-\(parentSessionID).jsonl"
        )
        try [
            """
            {"timestamp":"\(parentForkTotalAt)","type":"session_meta","payload":{"id":"\(parentSessionID)","originator":"Codex Desktop"}}
            """,
            tokenLine(timestamp: parentForkTotalAt, total: 800, last: 800),
            tokenLine(timestamp: parentAfterForkAt, total: 1_000, last: 200),
        ].joined(separator: "\n").appending("\n")
            .write(to: parentURL, atomically: true, encoding: .utf8)

        let childURL = root.appendingPathComponent(
            "rollout-\(filenameDay)T23-00-01-\(childSessionID).jsonl"
        )
        try [
            """
            {"timestamp":"\(forkedAt)","type":"session_meta","payload":{"id":"\(childSessionID)","forked_from_id":"\(parentSessionID)","originator":"Codex Desktop"}}
            """,
            tokenLine(timestamp: childTurnAt, total: 900, last: 100),
        ].joined(separator: "\n").appending("\n")
            .write(to: childURL, atomically: true, encoding: .utf8)

        let scanner = ControlledCodexTokenActivityScanner(
            cachedDays: { _ in nil },
            scannedDays: { _ in [] }
        )
        defer { scanner.finishScan() }
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let model = MenuBarStatusModel(
            store: fixture.store,
            codexDesktopActivityMonitor: CodexDesktopActivityMonitor(
                sessionsRootURL: root,
                replaysInitialHistory: true
            ),
            codexAccountManager: EmptyCodexAccountManager(),
            codexTokenActivityScanner: scanner
        )
        model.isCodexDesktopMonitoringEnabled = true
        model.isMonitoringPaused = false

        model.pollCodexDesktopActivity()
        for _ in 0..<100 where model.tokenActivityTotal(for: .today) != 1_100 {
            try await Task.sleep(for: .milliseconds(20))
        }

        // Parent contributed 1,000. The child's 900 cumulative total inherited
        // only the parent's 800-at-fork value, so its own live contribution is 100.
        XCTAssertEqual(model.tokenActivityTotal(for: .today), 1_100)
    }

    @MainActor
    func testTokenRefreshPreservesPreviousCounterDuringBootstrapReset() async throws {
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let retrying = expectation(description: "bootstrap reset invalidates old scan")
        let applied = expectation(description: "bootstrap reset retry applied")

        let scanner = ControlledCodexTokenActivityScanner(
            cachedDays: { _ in nil },
            scannedDaysByCall: { now, callIndex in
                let totalTokens = callIndex == 1 ? 1_000 : 1_100
                return [
                    CodexTokenActivityDay(
                        day: Calendar.current.startOfDay(for: now),
                        totalTokens: totalTokens
                    )
                ]
            }
        )
        defer { scanner.finishScan() }
        let model = MenuBarStatusModel(
            store: fixture.store,
            codexDesktopActivityMonitor: CodexDesktopActivityMonitor(replaysInitialHistory: false),
            codexAccountManager: EmptyCodexAccountManager(),
            codexTokenActivityScanner: scanner,
            tokenActivityScanObserver: { disposition in
                if disposition == .retryingAfterUnabsorbedUsage {
                    retrying.fulfill()
                } else if disposition == .applied {
                    applied.fulfill()
                }
            }
        )
        model.isCodexDesktopMonitoringEnabled = true
        model.isMonitoringPaused = false
        model.updateLatestAgentTokenUsage(AgentTokenUsage(totalTokens: 1_000))

        model.refreshTokenActivityIfNeeded()
        XCTAssertTrue(scanner.waitUntilScanStarts(seconds: 1))
        model.updateLatestAgentTokenUsage(AgentTokenUsage(totalTokens: 100))
        XCTAssertEqual(model.tokenActivityTotal(for: .today), 1_100)

        let secondScanStarted = Task.detached {
            scanner.waitUntilScanStarts(seconds: 2)
        }
        scanner.finishScan()
        await fulfillment(of: [retrying], timeout: 2)
        let didStartSecondScan = await secondScanStarted.value
        XCTAssertTrue(didStartSecondScan)
        XCTAssertEqual(model.tokenActivityTotal(for: .today), 1_100)

        scanner.finishScan()
        await fulfillment(of: [applied], timeout: 2)
        XCTAssertEqual(scanner.scanCallCount, 2)
        XCTAssertEqual(model.tokenActivityTotal(for: .today), 1_100)

        model.updateLatestAgentTokenUsage(AgentTokenUsage(totalTokens: 150))
        XCTAssertEqual(model.tokenActivityTotal(for: .today), 1_150)
    }

    @MainActor
    func testPauseResumeRejectsOldTokenScanWithoutClearingReplacement() async throws {
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let discarded = expectation(description: "pre-pause scan discarded")
        let applied = expectation(description: "post-resume scan applied")

        let scanner = ControlledCodexTokenActivityScanner(
            cachedDays: { _ in nil },
            scannedDaysByCall: { now, callIndex in
                let totalTokens = callIndex == 1 ? 9_999 : 1_000
                return [
                    CodexTokenActivityDay(
                        day: Calendar.current.startOfDay(for: now),
                        totalTokens: totalTokens
                    )
                ]
            }
        )
        defer { scanner.finishScan() }
        let model = MenuBarStatusModel(
            store: fixture.store,
            codexDesktopActivityMonitor: CodexDesktopActivityMonitor(replaysInitialHistory: false),
            codexAccountManager: EmptyCodexAccountManager(),
            codexTokenActivityScanner: scanner,
            tokenActivityScanObserver: { disposition in
                if disposition == .discardedStaleContext {
                    discarded.fulfill()
                } else if disposition == .applied {
                    applied.fulfill()
                }
            }
        )
        model.isCodexDesktopMonitoringEnabled = true
        model.isMonitoringPaused = false
        model.updateLatestAgentTokenUsage(AgentTokenUsage(totalTokens: 1_000))

        model.refreshTokenActivityIfNeeded()
        XCTAssertTrue(scanner.waitUntilScanStarts(seconds: 1))
        model.setMonitoringPaused(true)
        XCTAssertFalse(model.isTokenActivityLoading)
        model.setMonitoringPaused(false)

        scanner.finishScan()
        await fulfillment(of: [discarded], timeout: 2)
        XCTAssertTrue(scanner.waitUntilScanStarts(seconds: 2))
        XCTAssertTrue(model.isTokenActivityLoading)
        XCTAssertEqual(model.tokenActivityTotal(for: .today), 1_000)

        scanner.finishScan()
        await fulfillment(of: [applied], timeout: 2)
        XCTAssertFalse(model.isTokenActivityLoading)
        XCTAssertEqual(scanner.scanCallCount, 2)
        XCTAssertEqual(model.tokenActivityTotal(for: .today), 1_000)
    }

    @MainActor
    func testAccountSwitchRejectsTokenScanCompletionFromPreviousAccount() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("token-account-switch-\(UUID().uuidString)", isDirectory: true)
        let authURL = root.appendingPathComponent("auth.json")
        let accountStoreURL = root.appendingPathComponent("accounts.json")
        let usageStoreURL = root.appendingPathComponent("usage.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try codexOAuthAuthJSON(
            email: "alpha@example.com",
            accountID: "acct_alpha",
            accessToken: "alpha-access"
        ).write(to: authURL)
        let manager = CodexAccountManager(
            environment: ["CODEX_HOME": root.path],
            fileManager: .default,
            storeURL: accountStoreURL
        )
        let alpha = try manager.saveCurrentAccount()
        let alphaCurrent = try XCTUnwrap(try manager.loadState().currentAccount)

        try codexOAuthAuthJSON(
            email: "beta@example.com",
            accountID: "acct_beta",
            accessToken: "beta-access"
        ).write(to: authURL)
        let beta = try manager.saveCurrentAccount()
        let betaCurrent = try XCTUnwrap(try manager.loadState().currentAccount)

        let today = Calendar.current.startOfDay(for: Date())
        let usageStore = CodexAccountUsageSnapshotStore(fileURL: usageStoreURL)
        usageStore.store(
            account: alphaCurrent,
            quota: nil,
            credits: nil,
            resetCredits: nil,
            usageFetchState: nil,
            resetCreditsFetchState: nil,
            tokenUsage: AgentTokenUsage(totalTokens: 1_000),
            tokenActivityCacheVersion: CodexTokenActivityScanner.currentCacheVersion,
            tokenActivityDays: [CodexTokenActivityDay(day: today, totalTokens: 1_000)]
        )
        usageStore.store(
            account: betaCurrent,
            quota: nil,
            credits: nil,
            resetCredits: nil,
            usageFetchState: nil,
            resetCreditsFetchState: nil,
            tokenUsage: AgentTokenUsage(totalTokens: 2_000),
            tokenActivityCacheVersion: CodexTokenActivityScanner.currentCacheVersion,
            tokenActivityDays: [CodexTokenActivityDay(day: today, totalTokens: 2_000)]
        )
        _ = try manager.switchToAccount(id: alpha.id)

        let scanner = ControlledCodexTokenActivityScanner(
            cachedDays: { _ in nil },
            scannedDaysByCall: { now, callIndex in
                let totalTokens = callIndex == 1 ? 9_999 : 2_000
                return [
                    CodexTokenActivityDay(
                        day: Calendar.current.startOfDay(for: now),
                        totalTokens: totalTokens
                    )
                ]
            }
        )
        defer { scanner.finishScan() }
        let discarded = expectation(description: "previous account scan discarded")
        let betaApplied = expectation(description: "new account scan applied")
        let model = MenuBarStatusModel(
            store: SignalStateStore(stateFileURL: root.appendingPathComponent("status.json")),
            codexDesktopActivityMonitor: CodexDesktopActivityMonitor(replaysInitialHistory: false),
            codexAccountManager: manager,
            codexUsageSnapshotStore: usageStore,
            codexTokenActivityScanner: scanner,
            tokenActivityScanObserver: { disposition in
                if disposition == .discardedStaleContext {
                    discarded.fulfill()
                } else if disposition == .applied {
                    betaApplied.fulfill()
                }
            },
            performsAccountSwitchBackgroundRefreshes: false
        )
        model.isCodexDesktopMonitoringEnabled = true
        model.isMonitoringPaused = false

        XCTAssertEqual(model.tokenActivityTotal(for: .today), 1_000)
        model.refreshTokenActivityIfNeeded()
        XCTAssertTrue(scanner.waitUntilScanStarts(seconds: 1))

        model.switchCodexAccount(beta)
        XCTAssertEqual(model.codexActiveSavedAccountID, beta.id)
        XCTAssertEqual(model.tokenActivityTotal(for: .today), 2_000)

        let betaScanStarted = Task.detached {
            scanner.waitUntilScanStarts(seconds: 2)
        }
        scanner.finishScan()
        await fulfillment(of: [discarded], timeout: 2)
        let didStartBetaScan = await betaScanStarted.value
        XCTAssertTrue(didStartBetaScan)
        XCTAssertTrue(model.isTokenActivityLoading)
        XCTAssertEqual(model.tokenActivityTotal(for: .today), 2_000)

        scanner.finishScan()
        await fulfillment(of: [betaApplied], timeout: 2)

        XCTAssertEqual(model.codexActiveSavedAccountID, beta.id)
        XCTAssertFalse(model.isTokenActivityLoading)
        XCTAssertEqual(scanner.scanCallCount, 2)
        XCTAssertEqual(model.tokenActivityDays, [CodexTokenActivityDay(day: today, totalTokens: 2_000)])
        XCTAssertEqual(model.tokenActivityTotal(for: .today), 2_000)
    }

    @MainActor
    func testStaleDesktopPollCannotPersistIntoReplacementAccount() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("stale-desktop-poll-account-\(UUID().uuidString)", isDirectory: true)
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        let authURL = root.appendingPathComponent("auth.json")
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try codexOAuthAuthJSON(
            email: "alpha-stale-poll@example.com",
            accountID: "acct_alpha_stale_poll",
            accessToken: "alpha-stale-poll-access"
        ).write(to: authURL)
        let manager = CodexAccountManager(
            environment: ["CODEX_HOME": root.path],
            fileManager: .default,
            storeURL: root.appendingPathComponent("accounts.json")
        )
        let alpha = try manager.saveCurrentAccount()
        let alphaCurrent = try XCTUnwrap(try manager.loadState().currentAccount)

        try codexOAuthAuthJSON(
            email: "beta-stale-poll@example.com",
            accountID: "acct_beta_stale_poll",
            accessToken: "beta-stale-poll-access"
        ).write(to: authURL)
        let beta = try manager.saveCurrentAccount()
        let betaCurrent = try XCTUnwrap(try manager.loadState().currentAccount)
        _ = try manager.switchToAccount(id: alpha.id)

        let now = Date()
        let eventAt = now.addingTimeInterval(-10)
        let today = Calendar.current.startOfDay(for: now)
        let rawSessionID = "019c846a-b85e-7bd3-924b-cc33e3f180d9"
        let liveSessionID = "codex-desktop:\(rawSessionID)"
        let usageStore = CodexAccountUsageSnapshotStore(
            fileURL: root.appendingPathComponent("usage.json")
        )
        for (account, total) in [(alphaCurrent, 100), (betaCurrent, 200)] {
            usageStore.store(
                account: account,
                quota: nil,
                credits: nil,
                tokenUsage: AgentTokenUsage(totalTokens: total),
                liveTokenCounters: [CodexLiveTokenCounterSnapshot(
                    key: liveSessionID,
                    sessionID: liveSessionID,
                    totalTokens: total,
                    scannedBaseline: 0,
                    day: today,
                    updatedAt: eventAt
                )],
                unscannedLiveTokenCarryByDay: [],
                tokenActivityCacheVersion: CodexTokenActivityScanner.currentCacheVersion,
                tokenActivityDays: []
            )
        }

        let filenameDay = ISO8601DateFormatter().string(from: now).prefix(10)
        let sessionURL = sessionsRoot.appendingPathComponent(
            "rollout-\(filenameDay)T12-00-00-\(rawSessionID).jsonl"
        )
        try [
            #"{"timestamp":"\#(isoTimestamp(eventAt))","type":"session_meta","payload":{"id":"\#(rawSessionID)","originator":"Codex Desktop"}}"#,
            #"{"timestamp":"\#(isoTimestamp(eventAt))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100},"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100}}}}"#,
        ].joined(separator: "\n").appending("\n")
            .write(to: sessionURL, atomically: true, encoding: .utf8)

        let pollQueue = DispatchQueue(label: "test.stale-desktop-poll")
        let releasePollQueue = DispatchSemaphore(value: 0)
        let pollQueueBlocked = DispatchSemaphore(value: 0)
        pollQueue.async {
            pollQueueBlocked.signal()
            releasePollQueue.wait()
        }
        XCTAssertEqual(pollQueueBlocked.wait(timeout: .now() + 1), .success)

        let stateStore = SignalStateStore(
            stateFileURL: root.appendingPathComponent("status.json")
        )
        let scanner = ControlledCodexTokenActivityScanner(
            cachedDays: { _ in nil },
            scannedDays: { _ in [] }
        )
        defer { scanner.finishScan() }
        let model = MenuBarStatusModel(
            store: stateStore,
            codexDesktopActivityMonitor: CodexDesktopActivityMonitor(
                sessionsRootURL: sessionsRoot,
                replaysInitialHistory: true
            ),
            codexDesktopPollQueue: pollQueue,
            codexAccountManager: manager,
            codexUsageSnapshotStore: usageStore,
            codexTokenActivityScanner: scanner,
            performsAccountSwitchBackgroundRefreshes: false,
            nowProvider: { now }
        )
        model.isCodexDesktopMonitoringEnabled = true
        model.isMonitoringPaused = false
        XCTAssertEqual(model.tokenActivityTotal(for: .today, now: now), 100)

        model.pollCodexDesktopActivity()
        model.switchCodexAccount(beta)
        XCTAssertEqual(model.tokenActivityTotal(for: .today, now: now), 200)

        let pollFinished = DispatchSemaphore(value: 0)
        pollQueue.async { pollFinished.signal() }
        releasePollQueue.signal()
        let didFinishPoll = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(
                    returning: pollFinished.wait(timeout: .now() + 2) == .success
                )
            }
        }
        XCTAssertTrue(didFinishPoll)
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertNil(stateStore.readSnapshot().sessions.first(where: {
            $0.sessionID == liveSessionID
        }))
        XCTAssertEqual(model.tokenActivityTotal(for: .today, now: now), 200)

        // A quota already present in the process-wide SignalState file is also
        // untrusted after activation, even when the replacement account has a
        // counter with the same session key.
        _ = try stateStore.applySessionQuota(
            AgentQuotaStatus(
                remainingPercent: 50,
                updatedAt: eventAt,
                tokenUsage: AgentTokenUsage(totalTokens: 100)
            ),
            sessionID: liveSessionID,
            agent: "codex-desktop",
            updatedAt: eventAt
        )
        model.reload()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(model.tokenActivityTotal(for: .today, now: now), 200)
        let persistedBeta = try XCTUnwrap(usageStore.snapshot(for: betaCurrent))
        XCTAssertEqual(
            persistedBeta.liveTokenCounters?.first(where: { $0.sessionID == liveSessionID })?.totalTokens,
            200
        )
    }

    @MainActor
    func testAccountSwitchAwayAndBackStillRejectsOriginalScanGeneration() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("token-account-switch-aba-\(UUID().uuidString)", isDirectory: true)
        let authURL = root.appendingPathComponent("auth.json")
        let accountStoreURL = root.appendingPathComponent("accounts.json")
        let usageStoreURL = root.appendingPathComponent("usage.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try codexOAuthAuthJSON(
            email: "alpha-aba@example.com",
            accountID: "acct_alpha_aba",
            accessToken: "alpha-aba-access"
        ).write(to: authURL)
        let manager = CodexAccountManager(
            environment: ["CODEX_HOME": root.path],
            fileManager: .default,
            storeURL: accountStoreURL
        )
        let alpha = try manager.saveCurrentAccount()
        let alphaCurrent = try XCTUnwrap(try manager.loadState().currentAccount)

        try codexOAuthAuthJSON(
            email: "beta-aba@example.com",
            accountID: "acct_beta_aba",
            accessToken: "beta-aba-access"
        ).write(to: authURL)
        let beta = try manager.saveCurrentAccount()
        let betaCurrent = try XCTUnwrap(try manager.loadState().currentAccount)
        let today = Calendar.current.startOfDay(for: Date())
        let usageStore = CodexAccountUsageSnapshotStore(fileURL: usageStoreURL)
        usageStore.store(
            account: alphaCurrent,
            quota: nil,
            credits: nil,
            tokenUsage: AgentTokenUsage(totalTokens: 1_000),
            tokenActivityCacheVersion: CodexTokenActivityScanner.currentCacheVersion,
            tokenActivityDays: [CodexTokenActivityDay(day: today, totalTokens: 1_000)]
        )
        usageStore.store(
            account: betaCurrent,
            quota: nil,
            credits: nil,
            tokenUsage: AgentTokenUsage(totalTokens: 2_000),
            tokenActivityCacheVersion: CodexTokenActivityScanner.currentCacheVersion,
            tokenActivityDays: [CodexTokenActivityDay(day: today, totalTokens: 2_000)]
        )
        _ = try manager.switchToAccount(id: alpha.id)

        let scanner = ControlledCodexTokenActivityScanner(
            cachedDays: { _ in nil },
            scannedDaysByCall: { now, callIndex in
                [CodexTokenActivityDay(
                    day: Calendar.current.startOfDay(for: now),
                    totalTokens: callIndex == 1 ? 9_999 : 1_000
                )]
            }
        )
        defer { scanner.finishScan() }
        let discarded = expectation(description: "original Alpha generation discarded")
        let replacementApplied = expectation(description: "new Alpha generation applied")
        let model = MenuBarStatusModel(
            store: SignalStateStore(stateFileURL: root.appendingPathComponent("status.json")),
            codexDesktopActivityMonitor: CodexDesktopActivityMonitor(replaysInitialHistory: false),
            codexAccountManager: manager,
            codexUsageSnapshotStore: usageStore,
            codexTokenActivityScanner: scanner,
            tokenActivityScanObserver: { disposition in
                if disposition == .discardedStaleContext {
                    discarded.fulfill()
                } else if disposition == .applied {
                    replacementApplied.fulfill()
                }
            },
            performsAccountSwitchBackgroundRefreshes: false
        )
        model.isCodexDesktopMonitoringEnabled = true
        model.isMonitoringPaused = false

        model.refreshTokenActivityIfNeeded(force: true)
        XCTAssertTrue(scanner.waitUntilScanStarts(seconds: 1))
        // Keep the original scan blocked while cycling A -> B -> A, but do not
        // start an unrelated scan for the intermediate account. The stale A
        // result must still be rejected by generation, not account identity.
        model.isMonitoringPaused = true
        model.switchCodexAccount(beta)
        XCTAssertEqual(model.tokenActivityTotal(for: .today), 2_000)
        model.switchCodexAccount(alpha)
        XCTAssertEqual(model.tokenActivityTotal(for: .today), 1_000)

        scanner.finishScan()
        await fulfillment(of: [discarded], timeout: 2)
        model.isMonitoringPaused = false
        model.refreshTokenActivityIfNeeded(force: true)
        XCTAssertTrue(scanner.waitUntilScanStarts(seconds: 2))
        scanner.finishScan()
        await fulfillment(of: [replacementApplied], timeout: 2)

        XCTAssertEqual(model.codexActiveSavedAccountID, alpha.id)
        XCTAssertEqual(scanner.scanCallCount, 2)
        XCTAssertEqual(model.tokenActivityTotal(for: .today), 1_000)
    }

    @MainActor
    func testLongQuotaWindowResetTextIncludesDateAndDynamicTitle() {
        let model = makeMenuBarStatusModel()
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
    func testWeeklyOnlyQuotaUsesOneWeeklyBadgeWindow() {
        let model = makeMenuBarStatusModel()
        model.appLanguage = .zhHans
        let weeklyWindow = AgentQuotaWindowStatus(
            remainingPercent: 84,
            usedPercent: 16,
            windowMinutes: 10_080,
            resetsAt: Date(timeIntervalSince1970: 1_782_375_582)
        )
        let quota = AgentQuotaStatus(
            remainingPercent: weeklyWindow.remainingPercent,
            usedPercent: weeklyWindow.usedPercent,
            windowMinutes: weeklyWindow.windowMinutes,
            resetsAt: weeklyWindow.resetsAt,
            updatedAt: Date(timeIntervalSince1970: 1_782_000_000),
            primary: weeklyWindow,
            secondary: nil
        )

        XCTAssertEqual(model.quotaBadgeWindows(for: quota), [.weekly])
        XCTAssertEqual(model.quotaTitleLine(for: .weekly, quota: quota), "一周 · 剩余 84%")
    }

    @MainActor
    func testFiveHourAndWeeklyQuotaUseTwoBadgeWindows() {
        let model = makeMenuBarStatusModel()
        let fiveHourWindow = AgentQuotaWindowStatus(
            remainingPercent: 70,
            usedPercent: 30,
            windowMinutes: 300,
            resetsAt: Date(timeIntervalSince1970: 1_782_000_000)
        )
        let weeklyWindow = AgentQuotaWindowStatus(
            remainingPercent: 80,
            usedPercent: 20,
            windowMinutes: 10_080,
            resetsAt: Date(timeIntervalSince1970: 1_782_500_000)
        )
        let quota = AgentQuotaStatus(
            remainingPercent: fiveHourWindow.remainingPercent,
            usedPercent: fiveHourWindow.usedPercent,
            windowMinutes: fiveHourWindow.windowMinutes,
            resetsAt: fiveHourWindow.resetsAt,
            updatedAt: Date(timeIntervalSince1970: 1_781_900_000),
            primary: fiveHourWindow,
            secondary: weeklyWindow
        )

        XCTAssertEqual(model.quotaBadgeWindows(for: quota), [.fiveHours, .weekly])
    }

    @MainActor
    func testCodexResetCreditsPresentationUsesCompactLayout() throws {
        let model = makeMenuBarStatusModel()
        model.appLanguage = .zhHans
        let now = Date(timeIntervalSince1970: 1_781_726_400)
        let snapshot = CodexRateLimitResetCreditsSnapshot(
            credits: (1...5).map { day in
                CodexRateLimitResetCredit(
                    status: .available,
                    grantedAt: now.addingTimeInterval(-3_600),
                    expiresAt: now.addingTimeInterval(Double(day * 86_400))
                )
            },
            availableCount: 5,
            updatedAt: now
        )

        let presentation = try XCTUnwrap(model.codexResetCreditsPresentation(for: snapshot, now: now))

        XCTAssertEqual(presentation.title, "限额重置额度")
        XCTAssertEqual(presentation.availableText, "5 次可用")
        XCTAssertEqual(presentation.expirySummaryText, "1d · 2d · 3d · 4d · +1")
        XCTAssertEqual(presentation.helpText.split(separator: "\n").count, 5)
    }

    @MainActor
    func testCompactTokenUsageTextUsesTwoDecimalPlaces() {
        let model = makeMenuBarStatusModel()
        model.appLanguage = .zhHans

        XCTAssertEqual(model.compactTokenCountText(6_500_000_000), "65.00亿")
        XCTAssertEqual(model.compactTokenCountText(12_345), "1.23万")

        model.appLanguage = .english
        XCTAssertEqual(model.compactTokenCountText(1_234_567_890), "1.23B")
        XCTAssertEqual(model.compactTokenCountText(1_234), "1.23K")
    }

    @MainActor
    func testFloatingSignalDebugLightUsesLiveTickForTargetedOverride() {
        let model = makeMenuBarStatusModel()

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

    func testCodexDesktopActivityMonitorReadsReplacementGenerationFromStartWithoutLeakingPathState() throws {
        let now = Date()

        for replacementExtraBytes in [0, 64] {
            let fixture = try makeTemporaryCodexSessionsRoot()
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let sessionID = "019e83ed-3f20-7000-9000-000000000010"
            let sessionFile = fixture.sessionsRoot
                .appendingPathComponent("rollout-2026-06-02T00-00-00-\(sessionID).jsonl")
            let oldMeta = #"{"timestamp":"\#(isoTimestamp(now.addingTimeInterval(-2)))","type":"session_meta","payload":{"id":"\#(sessionID)","forked_from_id":"old-parent-session","originator":"codex-tui","source":"cli"}}"#
            let oldBase = Data((oldMeta + "\n").utf8)

            let newMeta = #"{"timestamp":"\#(isoTimestamp(now))","type":"session_meta","payload":{"id":"\#(sessionID)","originator":"Codex Desktop","source":"vscode"}}"#
            let tokenLine = #"{"timestamp":"\#(isoTimestamp(now.addingTimeInterval(1)))","type":"event_msg","payload":{"type":"token_count","info":{"model_context_window":258400,"total_token_usage":{"input_tokens":120,"cached_input_tokens":20,"output_tokens":30,"total_tokens":150},"last_token_usage":{"input_tokens":120,"cached_input_tokens":20,"output_tokens":30,"total_tokens":150}}}}"#
            let activityLine = #"{"timestamp":"\#(isoTimestamp(now.addingTimeInterval(1)))","type":"response_item","payload":{"type":"function_call","name":"apply_patch"}}"#
            let replacementBase = Data(([newMeta, tokenLine, activityLine].joined(separator: "\n") + "\n").utf8)
            let commonSize = max(oldBase.count, replacementBase.count) + 256

            func padded(_ data: Data, to size: Int) -> Data {
                var result = data
                let paddingCount = size - result.count
                if paddingCount > 0 {
                    if paddingCount > 1 {
                        result.append(Data(repeating: 0x20, count: paddingCount - 1))
                    }
                    result.append(0x0A)
                }
                return result
            }

            let initialData = padded(oldBase, to: commonSize)
            try initialData.write(to: sessionFile)
            let oldAttributes = try FileManager.default.attributesOfItem(atPath: sessionFile.path)
            let oldInode = try XCTUnwrap(oldAttributes[.systemFileNumber] as? NSNumber)

            let monitor = CodexDesktopActivityMonitor(sessionsRootURL: fixture.sessionsRoot)
            XCTAssertEqual(monitor.poll(now: now), [])

            let replacementData = padded(
                replacementBase,
                to: commonSize + replacementExtraBytes
            )
            let replacementURL = fixture.sessionsRoot.appendingPathComponent("replacement-\(UUID().uuidString).jsonl")
            try replacementData.write(to: replacementURL)
            _ = try FileManager.default.replaceItemAt(sessionFile, withItemAt: replacementURL)

            let newAttributes = try FileManager.default.attributesOfItem(atPath: sessionFile.path)
            let newDevice = try XCTUnwrap(newAttributes[.systemNumber] as? NSNumber)
            let newInode = try XCTUnwrap(newAttributes[.systemFileNumber] as? NSNumber)
            XCTAssertNotEqual(newInode, oldInode)

            let pollResult = monitor.pollResult(now: now.addingTimeInterval(2))
            XCTAssertEqual(pollResult.activities.map(\.event), ["DesktopToolCall:apply_patch"])
            XCTAssertEqual(pollResult.activities.map(\.agent), ["codex-desktop"])
            XCTAssertEqual(pollResult.quotaUpdates.count, 1)
            XCTAssertEqual(pollResult.quotaUpdates.first?.agent, "codex-desktop")
            XCTAssertNil(pollResult.quotaUpdates.first?.forkedFromSessionID)
            XCTAssertEqual(
                pollResult.quotaUpdates.first?.tokenObservationCursor?.sourceGeneration,
                "\(newDevice.uint64Value):\(newInode.uint64Value)"
            )
            XCTAssertEqual(
                pollResult.quotaUpdates.first?.tokenObservationCursor?.endOffset,
                UInt64(Data((newMeta + "\n" + tokenLine).utf8).count)
            )
        }
    }

    func testCodexDesktopActivityMonitorRejectsPathReplacementBetweenSnapshotAndOpen() throws {
        let fixture = try makeTemporaryCodexSessionsRoot()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let now = Date()
        let sessionID = "019e83ed-3f20-7000-9000-000000000011"
        let sessionFile = fixture.sessionsRoot.appendingPathComponent(
            "rollout-2026-06-02T00-00-00-\(sessionID).jsonl"
        )
        let replacementURL = fixture.directory.appendingPathComponent("replacement.jsonl")
        let meta = #"{"timestamp":"\#(isoTimestamp(now.addingTimeInterval(-2)))","type":"session_meta","payload":{"id":"\#(sessionID)","originator":"Codex Desktop"}}"#
        let initialToken = #"{"timestamp":"\#(isoTimestamp(now.addingTimeInterval(-2)))","type":"event_msg","payload":{"type":"token_count","info":{"model_context_window":258400,"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100},"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100}}}}"#
        let replacementToken = #"{"timestamp":"\#(isoTimestamp(now))","type":"event_msg","payload":{"type":"token_count","info":{"model_context_window":258400,"total_token_usage":{"input_tokens":900,"cached_input_tokens":0,"output_tokens":0,"total_tokens":900},"last_token_usage":{"input_tokens":900,"cached_input_tokens":0,"output_tokens":0,"total_tokens":900}}}}"#
        try [meta, initialToken].joined(separator: "\n").appending("\n")
            .write(to: sessionFile, atomically: true, encoding: .utf8)
        try [meta, replacementToken].joined(separator: "\n").appending("\n")
            .write(to: replacementURL, atomically: true, encoding: .utf8)

        var shouldSwap = false
        var swapError: Error?
        let normalizedSessionPath = sessionFile.standardizedFileURL
            .resolvingSymlinksInPath().path
        let monitor = CodexDesktopActivityMonitor(
            sessionsRootURL: fixture.sessionsRoot,
            beforeFileReadHook: { url in
                guard shouldSwap,
                      url.standardizedFileURL.resolvingSymlinksInPath().path
                        == normalizedSessionPath
                else { return }
                shouldSwap = false
                do {
                    _ = try FileManager.default.replaceItemAt(
                        sessionFile,
                        withItemAt: replacementURL
                    )
                } catch {
                    swapError = error
                }
            }
        )
        XCTAssertTrue(monitor.pollResult(now: now).quotaUpdates.isEmpty)
        try FileHandle(forWritingTo: sessionFile).appendString("\n")

        shouldSwap = true
        let raced = monitor.pollResult(now: now.addingTimeInterval(1))
        XCTAssertNil(swapError)
        XCTAssertFalse(shouldSwap)
        XCTAssertTrue(raced.quotaUpdates.isEmpty)
        XCTAssertTrue(
            try String(contentsOf: sessionFile, encoding: .utf8)
                .contains("\"total_tokens\":900")
        )

        let replacementMetadata = CostUsageScanner.codexFileMetadata(fileURL: sessionFile)
        let retried = monitor.pollResult(now: now.addingTimeInterval(2))
        let update = try XCTUnwrap(retried.quotaUpdates.first)
        XCTAssertEqual(update.tokenActivityUsage?.effectiveTotalTokens, 900)
        XCTAssertEqual(
            update.tokenObservationCursor?.sourceGeneration,
            replacementMetadata.fileId
        )
        XCTAssertEqual(
            update.tokenObservationCursor?.sourceStatFingerprint,
            replacementMetadata.statFingerprint
        )
        XCTAssertEqual(
            update.tokenObservationCursor?.sourceChangeTimeNanoseconds,
            replacementMetadata.changeTimeNanoseconds
        )
    }

    func testCodexDesktopActivityMonitorRetainsCachedPathAfterTransientSnapshotChange() throws {
        let fixture = try makeTemporaryCodexSessionsRoot()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let now = Date()
        let sessionID = "019e83ed-3f20-7000-9000-000000000013"
        let sessionFile = fixture.sessionsRoot.appendingPathComponent(
            "rollout-2026-06-02T00-00-00-\(sessionID).jsonl"
        )
        let meta = #"{"timestamp":"\#(isoTimestamp(now.addingTimeInterval(-1)))","type":"session_meta","payload":{"id":"\#(sessionID)","originator":"Codex Desktop"}}"#
        let token100 = #"{"timestamp":"\#(isoTimestamp(now))","type":"event_msg","payload":{"type":"token_count","info":{"model_context_window":258400,"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100},"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100}}}}"#
        let token200 = #"{"timestamp":"\#(isoTimestamp(now.addingTimeInterval(1)))","type":"event_msg","payload":{"type":"token_count","info":{"model_context_window":258400,"total_token_usage":{"input_tokens":200,"cached_input_tokens":0,"output_tokens":0,"total_tokens":200},"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100}}}}"#
        try [meta, token100].joined(separator: "\n").appending("\n")
            .write(to: sessionFile, atomically: true, encoding: .utf8)

        var shouldMutateSnapshot = false
        var mutationError: Error?
        let normalizedSessionPath = sessionFile.standardizedFileURL
            .resolvingSymlinksInPath().path
        let monitor = CodexDesktopActivityMonitor(
            sessionsRootURL: fixture.sessionsRoot,
            fullScanInterval: 60,
            beforeSessionSnapshotReadHook: { url in
                guard shouldMutateSnapshot,
                      url.standardizedFileURL.resolvingSymlinksInPath().path
                        == normalizedSessionPath
                else { return }
                shouldMutateSnapshot = false
                do {
                    try FileHandle(forWritingTo: sessionFile).appendString("\n")
                } catch {
                    mutationError = error
                }
            }
        )
        XCTAssertTrue(monitor.pollResult(now: now).quotaUpdates.isEmpty)
        try FileHandle(forWritingTo: sessionFile).appendString(token200 + "\n")

        shouldMutateSnapshot = true
        let transient = monitor.pollResult(now: now.addingTimeInterval(1))
        XCTAssertNil(mutationError)
        XCTAssertFalse(shouldMutateSnapshot)
        XCTAssertTrue(transient.quotaUpdates.isEmpty)

        let retried = monitor.pollResult(now: now.addingTimeInterval(2))
        let update = try XCTUnwrap(retried.quotaUpdates.first)
        XCTAssertEqual(update.tokenActivityUsage?.effectiveTotalTokens, 200)
    }

    func testCodexDesktopActivityMonitorSkipsIdleReadsBetweenPeriodicSnapshotValidation() throws {
        let fixture = try makeTemporaryCodexSessionsRoot()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let now = Date()
        let sessionID = "019e83ed-3f20-7000-9000-000000000014"
        let sessionFile = fixture.sessionsRoot.appendingPathComponent(
            "rollout-2026-06-02T00-00-00-\(sessionID).jsonl"
        )
        let meta = #"{"timestamp":"\#(isoTimestamp(now))","type":"session_meta","payload":{"id":"\#(sessionID)","originator":"Codex Desktop"}}"#
        try meta.appending("\n").write(to: sessionFile, atomically: true, encoding: .utf8)

        var stableSnapshotReadCount = 0
        var fileContentReadCount = 0
        let monitor = CodexDesktopActivityMonitor(
            sessionsRootURL: fixture.sessionsRoot,
            fullScanInterval: 60,
            beforeSessionSnapshotReadHook: { _ in
                stableSnapshotReadCount += 1
            },
            beforeFileReadHook: { _ in
                fileContentReadCount += 1
            }
        )
        _ = monitor.pollResult(now: now)
        XCTAssertGreaterThan(stableSnapshotReadCount, 0)
        XCTAssertGreaterThan(fileContentReadCount, 0)

        stableSnapshotReadCount = 0
        fileContentReadCount = 0
        _ = monitor.pollResult(now: now.addingTimeInterval(1))
        XCTAssertEqual(stableSnapshotReadCount, 0)
        XCTAssertEqual(fileContentReadCount, 0)

        // The short-poll fast path is bounded. Periodic discovery still
        // revalidates the descriptor/content snapshot to catch rare metadata
        // collisions without returning to continuous two-second anchor reads.
        _ = monitor.pollResult(now: now.addingTimeInterval(61))
        XCTAssertGreaterThan(stableSnapshotReadCount, 0)
        XCTAssertEqual(fileContentReadCount, 0)
    }

    func testCodexDesktopActivityMonitorSnapshotsOnlyRecentLimitDuringFullScan() throws {
        let fixture = try makeTemporaryCodexSessionsRoot()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let now = Date()
        for index in 0..<12 {
            let sessionID = String(format: "019e83ed-3f20-7000-9000-%012d", index)
            let sessionFile = fixture.sessionsRoot.appendingPathComponent(
                "rollout-2026-06-02T00-00-00-\(sessionID).jsonl"
            )
            let meta = #"{"timestamp":"\#(isoTimestamp(now.addingTimeInterval(Double(index))))","type":"session_meta","payload":{"id":"\#(sessionID)","originator":"Codex Desktop"}}"#
            try meta.appending("\n").write(
                to: sessionFile,
                atomically: true,
                encoding: .utf8
            )
            try FileManager.default.setAttributes(
                [.modificationDate: now.addingTimeInterval(Double(index))],
                ofItemAtPath: sessionFile.path
            )
        }

        var stableSnapshotReadCount = 0
        let monitor = CodexDesktopActivityMonitor(
            sessionsRootURL: fixture.sessionsRoot,
            recentFileLimit: 3,
            beforeSessionSnapshotReadHook: { _ in
                stableSnapshotReadCount += 1
            }
        )

        _ = monitor.pollResult(now: now.addingTimeInterval(20))
        XCTAssertEqual(stableSnapshotReadCount, 3)
    }

    func testCodexDesktopActivityMonitorPureAppendKeepsConfirmedIdentity() throws {
        let fixture = try makeTemporaryCodexSessionsRoot()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let now = Date()
        let sessionID = "019e83ed-3f20-7000-9000-000000000016"
        let sessionFile = fixture.sessionsRoot.appendingPathComponent(
            "rollout-2026-06-02T00-00-00-\(sessionID).jsonl"
        )
        let meta = #"{"timestamp":"\#(isoTimestamp(now.addingTimeInterval(-1)))","type":"session_meta","payload":{"id":"\#(sessionID)","originator":"codex-tui","source":"cli"}}"#
        let token100 = #"{"timestamp":"\#(isoTimestamp(now))","type":"event_msg","payload":{"type":"token_count","info":{"model_context_window":258400,"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100},"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100}}}}"#
        let token200 = #"{"timestamp":"\#(isoTimestamp(now.addingTimeInterval(1)))","type":"event_msg","payload":{"type":"token_count","info":{"model_context_window":258400,"total_token_usage":{"input_tokens":200,"cached_input_tokens":0,"output_tokens":0,"total_tokens":200},"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100}}}}"#
        try [meta, token100].joined(separator: "\n").appending("\n")
            .write(to: sessionFile, atomically: true, encoding: .utf8)

        // The tiny probe cannot rediscover the metadata after it is cleared;
        // priming still learns it from the complete initial tail. A pure append
        // must therefore preserve the already-confirmed CLI identity.
        let monitor = CodexDesktopActivityMonitor(
            sessionsRootURL: fixture.sessionsRoot,
            maxSessionMetadataProbeBytes: 1,
            replaysInitialHistory: true
        )
        let initialUpdate = try XCTUnwrap(monitor.pollResult(now: now).quotaUpdates.first)
        XCTAssertEqual(initialUpdate.agent, "codex-cli")

        try FileHandle(forWritingTo: sessionFile).appendString(token200 + "\n")
        let appendedUpdate = try XCTUnwrap(
            monitor.pollResult(now: now.addingTimeInterval(2)).quotaUpdates.first
        )
        XCTAssertEqual(appendedUpdate.agent, "codex-cli")
        XCTAssertEqual(appendedUpdate.sessionID, "codex-cli:\(sessionID)")
        XCTAssertEqual(appendedUpdate.tokenActivityUsage?.effectiveTotalTokens, 200)
    }

    func testCodexDesktopActivityMonitorTreatsSameInodeRewriteAsNewContentSnapshot() throws {
        let fixture = try makeTemporaryCodexSessionsRoot()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let now = Date()
        let sessionID = "019e83ed-3f20-7000-9000-000000000012"
        let sessionFile = fixture.sessionsRoot.appendingPathComponent(
            "rollout-2026-06-02T00-00-00-\(sessionID).jsonl"
        )
        let meta = #"{"timestamp":"\#(isoTimestamp(now.addingTimeInterval(-1)))","type":"session_meta","payload":{"id":"\#(sessionID)","originator":"Codex Desktop"}}"#
        let token100 = #"{"timestamp":"\#(isoTimestamp(now))","type":"event_msg","payload":{"type":"token_count","info":{"model_context_window":258400,"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100},"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100}}}}"#
        let token900 = token100.replacingOccurrences(of: "100", with: "900")
        let initialContents = [meta, token100].joined(separator: "\n").appending("\n")
        let rewrittenContents = [meta, token900].joined(separator: "\n").appending("\n")
        XCTAssertEqual(initialContents.utf8.count, rewrittenContents.utf8.count)
        try initialContents.write(to: sessionFile, atomically: true, encoding: .utf8)

        let monitor = CodexDesktopActivityMonitor(
            sessionsRootURL: fixture.sessionsRoot,
            replaysInitialHistory: true
        )
        let initialUpdate = try XCTUnwrap(monitor.pollResult(now: now).quotaUpdates.first)
        let initialCursor = try XCTUnwrap(initialUpdate.tokenObservationCursor)

        let handle = try FileHandle(forWritingTo: sessionFile)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(rewrittenContents.utf8))
        try handle.close()
        let rewrittenMetadata = CostUsageScanner.codexFileMetadata(fileURL: sessionFile)

        let rewrittenUpdate = try XCTUnwrap(
            monitor.pollResult(now: now.addingTimeInterval(1)).quotaUpdates.first
        )
        let rewrittenCursor = try XCTUnwrap(rewrittenUpdate.tokenObservationCursor)
        XCTAssertEqual(rewrittenUpdate.tokenActivityUsage?.effectiveTotalTokens, 900)
        XCTAssertEqual(rewrittenCursor.sourceGeneration, initialCursor.sourceGeneration)
        XCTAssertEqual(rewrittenCursor.sourceGeneration, rewrittenMetadata.fileId)
        XCTAssertTrue(
            rewrittenCursor.sourceStatFingerprint != initialCursor.sourceStatFingerprint
                || rewrittenCursor.sourceChangeTimeNanoseconds
                    != initialCursor.sourceChangeTimeNanoseconds
        )
        XCTAssertEqual(rewrittenCursor.sourceStatFingerprint, rewrittenMetadata.statFingerprint)
        XCTAssertEqual(
            rewrittenCursor.sourceChangeTimeNanoseconds,
            rewrittenMetadata.changeTimeNanoseconds
        )
    }

    func testCodexDesktopActivityMonitorDetectsLargeSameInodeMiddleRewrite() throws {
        let fixture = try makeTemporaryCodexSessionsRoot()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let now = Date()
        let sessionID = "019e83ed-3f20-7000-9000-000000000015"
        let sessionFile = fixture.sessionsRoot.appendingPathComponent(
            "rollout-2026-06-02T00-00-00-\(sessionID).jsonl"
        )
        let meta = #"{"timestamp":"\#(isoTimestamp(now.addingTimeInterval(-1)))","type":"session_meta","payload":{"id":"\#(sessionID)","originator":"Codex Desktop"}}"#
        let token100 = #"{"timestamp":"\#(isoTimestamp(now))","type":"event_msg","payload":{"type":"token_count","info":{"model_context_window":258400,"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100},"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100}}}}"#
        let token900 = token100.replacingOccurrences(of: "100", with: "900")
        let unchangedPrefix = String(repeating: "p", count: 5_000)
        let unchangedSuffix = String(repeating: "s", count: 5_000)
        let initialContents = [unchangedPrefix, meta, token100, unchangedSuffix]
            .joined(separator: "\n").appending("\n")
        let rewrittenContents = [unchangedPrefix, meta, token900, unchangedSuffix]
            .joined(separator: "\n").appending("\n")
        XCTAssertGreaterThan(initialContents.utf8.count, 8 * 1_024)
        XCTAssertEqual(initialContents.utf8.count, rewrittenContents.utf8.count)
        try initialContents.write(to: sessionFile, atomically: true, encoding: .utf8)

        let initialAttributes = try FileManager.default.attributesOfItem(atPath: sessionFile.path)
        let initialInode = try XCTUnwrap(initialAttributes[.systemFileNumber] as? NSNumber)
        let monitor = CodexDesktopActivityMonitor(
            sessionsRootURL: fixture.sessionsRoot,
            replaysInitialHistory: true
        )
        let initialUpdate = try XCTUnwrap(monitor.pollResult(now: now).quotaUpdates.first)
        XCTAssertEqual(initialUpdate.tokenActivityUsage?.effectiveTotalTokens, 100)

        let handle = try FileHandle(forWritingTo: sessionFile)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(rewrittenContents.utf8))
        try handle.close()
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(5)],
            ofItemAtPath: sessionFile.path
        )
        let rewrittenAttributes = try FileManager.default.attributesOfItem(atPath: sessionFile.path)
        let rewrittenInode = try XCTUnwrap(rewrittenAttributes[.systemFileNumber] as? NSNumber)
        XCTAssertEqual(rewrittenInode, initialInode)

        let rewrittenUpdate = try XCTUnwrap(
            monitor.pollResult(now: now.addingTimeInterval(1)).quotaUpdates.first
        )
        XCTAssertEqual(rewrittenUpdate.tokenActivityUsage?.effectiveTotalTokens, 900)
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

    func testTurnEndClearsPermissionAlert() throws {
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

        XCTAssert(snapshot.aggregate == .idle)
        XCTAssert(snapshot.sessions.isEmpty)
        XCTAssert(snapshot.recentEvents.first?.signal == .turnEnd)
    }

    func testSuccessfulStopCompletesActiveSessionAndClearsPermissionAlert() throws {
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

        XCTAssert(alertSnapshot.aggregate == .done)
        XCTAssert(alertSnapshot.sessions.first?.signal == .done)
        XCTAssert(alertSnapshot.recentEvents.first?.signal == .done)
    }

    func testDoneClearsNeedsReviewAlertWithoutHidingActiveSessions() throws {
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        _ = try fixture.store.applySessionSignal(
            .thinking,
            sessionID: "codex-desktop:active",
            agent: "codex-desktop",
            lastEvent: "DesktopThinking"
        )
        _ = try fixture.store.applySessionSignal(
            .attention,
            sessionID: "codex-xcode:needs-review",
            agent: "codex-xcode",
            lastEvent: "Elicitation"
        )
        let snapshot = try fixture.store.applySessionSignal(
            .done,
            sessionID: "codex-xcode:needs-review",
            agent: "codex-xcode",
            lastEvent: "ManualTestDone"
        )

        XCTAssertEqual(snapshot.aggregate, .thinking)
        XCTAssertEqual(snapshot.sessions.first { $0.sessionID == "codex-xcode:needs-review" }?.signal, .done)
        XCTAssertEqual(snapshot.sessions.first { $0.sessionID == "codex-desktop:active" }?.signal, .thinking)
        XCTAssertFalse(snapshot.sessions.contains { $0.signal.displayState == .needsReview })
        XCTAssertEqual(snapshot.recentEvents.first?.signal, .done)
    }

    func testSessionEndPreservesCompletedAndClearsPermissionAlertSessions() throws {
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

        let permissionFixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: permissionFixture.directory) }

        _ = try permissionFixture.store.applySessionSignal(
            .permission,
            sessionID: "codex-main",
            lastEvent: "PermissionRequest"
        )
        let permissionSnapshot = try permissionFixture.store.applySessionSignal(
            .sessionEnd,
            sessionID: "codex-main",
            lastEvent: "SessionEnd"
        )

        XCTAssert(permissionSnapshot.aggregate == .idle)
        XCTAssert(permissionSnapshot.sessions.isEmpty)
        XCTAssert(permissionSnapshot.recentEvents.first?.signal == .sessionEnd)
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

    func testApplySessionQuotaRefreshesExistingSessionTimestampWithoutRegressing() throws {
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let signalDate = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let freshQuotaDate = signalDate.addingTimeInterval(5)
        let olderQuotaDate = signalDate.addingTimeInterval(1)

        _ = try fixture.store.applySessionSignal(
            .working,
            sessionID: "codex-desktop:thread",
            agent: "codex-desktop",
            lastEvent: "DesktopToolCall:exec_command",
            updatedAt: signalDate
        )

        let freshQuota = AgentQuotaStatus(
            remainingPercent: 72,
            usedPercent: 28,
            limitName: "Codex",
            windowMinutes: 300,
            resetsAt: freshQuotaDate.addingTimeInterval(1_800),
            updatedAt: freshQuotaDate
        )
        var snapshot = try fixture.store.applySessionQuota(
            freshQuota,
            sessionID: "codex-desktop:thread",
            agent: "codex-desktop",
            updatedAt: freshQuotaDate
        )
        XCTAssertEqual(snapshot.sessions.first?.updatedAt, freshQuotaDate)
        XCTAssertEqual(snapshot.updatedAt, freshQuotaDate)

        let olderQuota = AgentQuotaStatus(
            remainingPercent: 80,
            usedPercent: 20,
            limitName: "Codex",
            windowMinutes: 300,
            resetsAt: olderQuotaDate.addingTimeInterval(1_800),
            updatedAt: olderQuotaDate
        )
        snapshot = try fixture.store.applySessionQuota(
            olderQuota,
            sessionID: "codex-desktop:thread",
            agent: "codex-desktop",
            updatedAt: olderQuotaDate
        )

        XCTAssertEqual(snapshot.sessions.first?.updatedAt, freshQuotaDate)
        XCTAssertEqual(snapshot.updatedAt, freshQuotaDate)
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

    func testPermissionRequestIsNotDowngradedByImmediateToolEvent() throws {
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let permissionDate = Date()
        let toolDate = permissionDate.addingTimeInterval(1)

        _ = try fixture.store.applySessionSignal(
            .permissionRequest,
            sessionID: "codex-cli:thread",
            agent: "codex-cli",
            lastEvent: "PermissionRequest",
            updatedAt: permissionDate
        )
        let snapshot = try fixture.store.applySessionSignal(
            .attention,
            sessionID: "codex-cli:thread",
            agent: "codex-cli",
            lastEvent: "DesktopToolCall:exec_command",
            updatedAt: toolDate
        )

        XCTAssertEqual(snapshot.aggregate, .permission)
        XCTAssertEqual(snapshot.sessions.first?.signal, .permissionRequest)
        XCTAssertEqual(snapshot.sessions.first?.lastEvent, "PermissionRequest")
        XCTAssertEqual(snapshot.recentEvents.first?.event, "DesktopToolCall:exec_command")
    }

    func testPermissionRequestResolvesToLaterToolProgress() throws {
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let permissionDate = Date()
        let toolDate = permissionDate.addingTimeInterval(10)

        _ = try fixture.store.applySessionSignal(
            .permissionRequest,
            sessionID: "codex-cli:thread",
            agent: "codex-cli",
            lastEvent: "PermissionRequest",
            updatedAt: permissionDate
        )
        let snapshot = try fixture.store.applySessionSignal(
            .working,
            sessionID: "codex-cli:thread",
            agent: "codex-cli",
            lastEvent: "PreToolUse",
            updatedAt: toolDate
        )

        XCTAssertEqual(snapshot.aggregate, .working)
        XCTAssertEqual(snapshot.sessions.first?.signal, .working)
        XCTAssertEqual(snapshot.sessions.first?.lastEvent, "PreToolUse")
    }

    func testPermissionRequestResolvesToLaterToolDone() throws {
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let permissionDate = Date()
        let toolDoneDate = permissionDate.addingTimeInterval(10)

        _ = try fixture.store.applySessionSignal(
            .permissionRequest,
            sessionID: "codex-cli:thread",
            agent: "codex-cli",
            lastEvent: "PermissionRequest",
            updatedAt: permissionDate
        )
        let snapshot = try fixture.store.applySessionSignal(
            .toolDone,
            sessionID: "codex-cli:thread",
            agent: "codex-cli",
            lastEvent: "DesktopToolDone",
            updatedAt: toolDoneDate
        )

        XCTAssertEqual(snapshot.aggregate, .toolDone)
        XCTAssertEqual(snapshot.sessions.first?.signal, .toolDone)
        XCTAssertEqual(snapshot.sessions.first?.lastEvent, "DesktopToolDone")
    }

    func testDoneClearsUnresolvedAttentionSession() throws {
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let attentionDate = Date()
        let doneDate = attentionDate.addingTimeInterval(30)

        _ = try fixture.store.applySessionSignal(
            .attention,
            sessionID: "codex-cli:thread",
            agent: "codex-cli",
            lastEvent: "ManualYellowTest",
            updatedAt: attentionDate
        )
        let snapshot = try fixture.store.applySessionSignal(
            .done,
            sessionID: "codex-cli:thread",
            agent: "codex-cli",
            lastEvent: "ManualYellowDone",
            updatedAt: doneDate
        )

        XCTAssertEqual(snapshot.aggregate, .done)
        XCTAssertEqual(snapshot.sessions.first?.signal, .done)
        XCTAssertEqual(snapshot.sessions.first?.lastEvent, "ManualYellowDone")
        let storedTimestamp = snapshot.sessions.first?.updatedAt.timeIntervalSince1970 ?? 0
        XCTAssertEqual(storedTimestamp, doneDate.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(snapshot.recentEvents.first?.signal, .done)
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

    func testAlertLampEffectsCustomizeRedAndYellowStates() {
        XCTAssertFalse(AlertSignalEffect.allCases.contains(.pulse))
        XCTAssertTrue(AlertSignalEffect.allCases.contains(.trafficCycle))

        let slowAlert = SignalEffectCustomization(
            activeEffect: .greenSlowFlash,
            needsReviewEffect: .slowFlash,
            permissionEffect: .slowFlash,
            blockedEffect: .slowFlash
        )
        for tick in 0..<6 {
            let greenSlow = SignalLampAnimation.intensity(
                .green,
                signal: .working,
                tick: tick,
                customization: slowAlert
            )
            XCTAssertEqual(
                SignalLampAnimation.intensity(.yellow, signal: .attention, tick: tick, customization: slowAlert),
                greenSlow
            )
            XCTAssertEqual(
                SignalLampAnimation.intensity(.red, signal: .permission, tick: tick, customization: slowAlert),
                greenSlow
            )
            XCTAssertEqual(
                SignalLampAnimation.intensity(.red, signal: .blocked, tick: tick, customization: slowAlert),
                greenSlow
            )
        }

        let fastAlert = SignalEffectCustomization(
            activeEffect: .greenFastFlash,
            needsReviewEffect: .fastFlash,
            permissionEffect: .fastFlash,
            blockedEffect: .fastFlash
        )
        for tick in 0..<4 {
            let greenFast = SignalLampAnimation.intensity(
                .green,
                signal: .working,
                tick: tick,
                customization: fastAlert
            )
            XCTAssertEqual(
                SignalLampAnimation.intensity(.yellow, signal: .attention, tick: tick, customization: fastAlert),
                greenFast
            )
            XCTAssertEqual(
                SignalLampAnimation.intensity(.red, signal: .permission, tick: tick, customization: fastAlert),
                greenFast
            )
            XCTAssertEqual(
                SignalLampAnimation.intensity(.red, signal: .blocked, tick: tick, customization: fastAlert),
                greenFast
            )
        }

        let steadyPermission = SignalEffectCustomization(permissionEffect: .steady)
        XCTAssertEqual(SignalLampAnimation.intensity(.red, signal: .permission, tick: 0, customization: steadyPermission), 1)
        XCTAssertEqual(SignalLampAnimation.intensity(.red, signal: .permission, tick: 8, customization: steadyPermission), 1)
        XCTAssertEqual(SignalLampAnimation.intensity(.yellow, signal: .permission, tick: 0, customization: steadyPermission), 0)

        let breathingBlocked = SignalEffectCustomization(blockedEffect: .breathing)
        XCTAssertLessThan(
            SignalLampAnimation.intensity(.red, signal: .blocked, tick: 0, customization: breathingBlocked),
            SignalLampAnimation.intensity(.red, signal: .blocked, tick: 5, customization: breathingBlocked)
        )

        let trafficCycleAlert = SignalEffectCustomization(
            needsReviewEffect: .trafficCycle,
            permissionEffect: .trafficCycle,
            blockedEffect: .trafficCycle
        )
        XCTAssertEqual(SignalLampAnimation.intensity(.red, signal: .attention, tick: 0, customization: trafficCycleAlert), 1)
        XCTAssertEqual(SignalLampAnimation.intensity(.yellow, signal: .attention, tick: 4, customization: trafficCycleAlert), 1)
        XCTAssertEqual(SignalLampAnimation.intensity(.green, signal: .attention, tick: 8, customization: trafficCycleAlert), 1)
        XCTAssertEqual(SignalLampAnimation.intensity(.red, signal: .permission, tick: 0, customization: trafficCycleAlert), 1)
        XCTAssertEqual(SignalLampAnimation.intensity(.yellow, signal: .blocked, tick: 4, customization: trafficCycleAlert), 1)
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
        XCTAssertEqual(SignalLampAnimation.scale(.yellow, signal: .attention, tick: 0), 1)

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

    func testGitHubReleaseUpdateCheckerPrefersUniversalMacOSAsset() throws {
        let data = Data(
            """
            {
              "tag_name": "v1.5.2",
              "html_url": "https://github.com/guan-ops/Agent-Signal-Bar/releases/tag/v1.5.2",
              "assets": [
                {
                  "name": "AgentSignalBar-v1.5.2-macos-universal.zip",
                  "browser_download_url": "https://github.com/guan-ops/Agent-Signal-Bar/releases/download/v1.5.2/AgentSignalBar-v1.5.2-macos-universal.zip"
                },
                {
                  "name": "AgentSignalBar-v1.5.2-macos-universal.dmg",
                  "browser_download_url": "https://github.com/guan-ops/Agent-Signal-Bar/releases/download/v1.5.2/AgentSignalBar-v1.5.2-macos-universal.dmg"
                },
                {
                  "name": "AgentSignalBar.dmg",
                  "browser_download_url": "https://github.com/guan-ops/Agent-Signal-Bar/releases/download/v1.5.2/AgentSignalBar.dmg"
                }
              ]
            }
            """.utf8
        )

        let release = try GitHubReleaseUpdateChecker.decodeLatestRelease(from: data)

        XCTAssertEqual(
            release.preferredDownloadURL?.lastPathComponent,
            "AgentSignalBar-v1.5.2-macos-universal.dmg"
        )
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
        let presenceSessions = ActivityPresentation.visiblePresenceSessions(from: snapshot, now: now)
        let floatingSessions = ActivityPresentation.visibleRunningSessions(from: snapshot, now: now)

        XCTAssertFalse(currentSessions.contains { $0.sessionID == "platform-presence:codex-desktop" })
        XCTAssertFalse(currentSessions.contains { $0.sessionID == "platform-presence:claude-desktop" })
        XCTAssertEqual(Set(presenceSessions.map(\.sessionID)), [
            "platform-presence:codex-desktop",
            "platform-presence:claude-desktop"
        ])
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

    func testActivityPresentationSeparatesFreshPresenceFromStaleTerminalThinking() {
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
        let presence = ActivityPresentation.visiblePresenceSessions(
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

        XCTAssertTrue(visible.isEmpty)
        XCTAssertEqual(presence.count, 1)
        XCTAssertEqual(presence.first?.sessionID, "platform-presence:codex-cli")
        XCTAssertEqual(presence.first?.signal, .idle)
    }

    func testActivityPresentationKeepsUnresolvedPermissionRequestOverPresence() {
        let now = Date(timeIntervalSince1970: 1_000)
        let visible = ActivityPresentation.visibleSessions(
            from: [
                SessionStatus(
                    sessionID: "codex-cli:old-permission",
                    signal: .permission,
                    updatedAt: now.addingTimeInterval(-10 * 60),
                    agent: "codex-cli",
                    lastEvent: "PermissionRequest"
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
        XCTAssertEqual(visible.first?.sessionID, "codex-cli:old-permission")
        XCTAssertEqual(visible.first?.signal, .permission)
    }

    func testActivityPresentationPrefersNewerCompletedSessionOverPermissionRequest() {
        let now = Date(timeIntervalSince1970: 1_000)
        let visible = ActivityPresentation.visibleSessions(
            from: [
                SessionStatus(
                    sessionID: "codex-cli:old-permission",
                    signal: .permission,
                    updatedAt: now.addingTimeInterval(-5),
                    agent: "codex-cli",
                    lastEvent: "PermissionRequest"
                ),
                SessionStatus(
                    sessionID: "codex-cli:done",
                    signal: .done,
                    updatedAt: now,
                    agent: "codex-cli",
                    lastEvent: "Stop"
                )
            ],
            now: now
        )

        XCTAssertEqual(visible.count, 1)
        XCTAssertEqual(visible.first?.signal, .done)
        XCTAssertEqual(visible.first?.lastEvent, "Stop")
    }

    func testActivityPresentationPrefersNewerProgressOverPermissionRequest() {
        let now = Date(timeIntervalSince1970: 1_000)
        let visible = ActivityPresentation.visibleSessions(
            from: [
                SessionStatus(
                    sessionID: "codex-cli:old-permission",
                    signal: .permission,
                    updatedAt: now.addingTimeInterval(-5),
                    agent: "codex-cli",
                    lastEvent: "PermissionRequest"
                ),
                SessionStatus(
                    sessionID: "codex-cli:tool",
                    signal: .toolDone,
                    updatedAt: now,
                    agent: "codex-cli",
                    lastEvent: "PostToolUse"
                )
            ],
            now: now
        )

        XCTAssertEqual(visible.count, 1)
        XCTAssertEqual(visible.first?.signal, .toolDone)
        XCTAssertEqual(visible.first?.lastEvent, "PostToolUse")
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

        let model = makeMenuBarStatusModel(store: fixture.store)
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
    func testCompletedRecentEventClearsPermissionDisplayForSameSource() throws {
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
                    "codex-cli:thread": SessionRecord(
                        agent: "codex-cli",
                        signal: .permission,
                        lastEvent: "PermissionRequest",
                        updatedAt: now.addingTimeInterval(-20)
                    )
                ],
                events: [
                    SignalEventRecord(
                        id: "codex-done",
                        sessionID: "codex-cli:thread",
                        agent: "codex-cli",
                        signal: .done,
                        event: "Stop",
                        updatedAt: now.addingTimeInterval(-1)
                    ),
                    SignalEventRecord(
                        id: "codex-permission",
                        sessionID: "codex-cli:thread",
                        agent: "codex-cli",
                        signal: .permission,
                        event: "PermissionRequest",
                        updatedAt: now.addingTimeInterval(-20)
                    )
                ]
            ),
            in: fixture.store
        )

        let model = makeMenuBarStatusModel(store: fixture.store)

        XCTAssertEqual(model.activitySnapshot.aggregate, .done)
        XCTAssertEqual(model.displaySnapshot.aggregate, .done)
        XCTAssertEqual(model.displaySnapshot.sessions.map(\.signal), [.done])
    }

    @MainActor
    func testToolDoneRecentEventClearsCurrentPermissionDisplayForSameSource() throws {
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
                    "codex-cli:thread": SessionRecord(
                        agent: "codex-cli",
                        signal: .permission,
                        lastEvent: "PermissionRequest",
                        updatedAt: now.addingTimeInterval(-20)
                    )
                ],
                events: [
                    SignalEventRecord(
                        id: "codex-tool-done",
                        sessionID: "codex-cli:thread",
                        agent: "codex-cli",
                        signal: .toolDone,
                        event: "PostToolUse",
                        updatedAt: now.addingTimeInterval(-1)
                    ),
                    SignalEventRecord(
                        id: "codex-permission",
                        sessionID: "codex-cli:thread",
                        agent: "codex-cli",
                        signal: .permission,
                        event: "PermissionRequest",
                        updatedAt: now.addingTimeInterval(-20)
                    )
                ]
            ),
            in: fixture.store
        )

        let model = makeMenuBarStatusModel(store: fixture.store)

        XCTAssertEqual(model.activitySnapshot.aggregate, .toolDone)
        XCTAssertEqual(model.displaySnapshot.aggregate, .toolDone)
        XCTAssertEqual(model.displaySnapshot.sessions.map(\.signal), [.toolDone])
    }

    @MainActor
    func testOlderCompletedRecentEventStillPreventsPermissionFallback() throws {
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
                    "codex-cli:thread": SessionRecord(
                        agent: "codex-cli",
                        signal: .permission,
                        lastEvent: "PermissionRequest",
                        updatedAt: now.addingTimeInterval(-120)
                    )
                ],
                events: [
                    SignalEventRecord(
                        id: "codex-done",
                        sessionID: "codex-cli:thread",
                        agent: "codex-cli",
                        signal: .done,
                        event: "Stop",
                        updatedAt: now.addingTimeInterval(-60)
                    ),
                    SignalEventRecord(
                        id: "codex-permission",
                        sessionID: "codex-cli:thread",
                        agent: "codex-cli",
                        signal: .permission,
                        event: "PermissionRequest",
                        updatedAt: now.addingTimeInterval(-120)
                    )
                ]
            ),
            in: fixture.store
        )

        let model = makeMenuBarStatusModel(store: fixture.store)

        XCTAssertEqual(model.activitySnapshot.aggregate, .idle)
        XCTAssertEqual(model.displaySnapshot.aggregate, .idle)
        XCTAssertFalse(
            model.displaySnapshot.sessions.contains { $0.signal.displayState == .permission }
        )
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

        let model = makeMenuBarStatusModel(store: fixture.store)

        XCTAssertEqual(model.signalLightAgentSelectionMode, .following)
        XCTAssertEqual(model.displaySignalLightAgentScopes, [.claudeCode])
        XCTAssertEqual(model.displaySnapshot.aggregate, .permission)
        XCTAssertEqual(model.displaySnapshot.sessions.map(\.sessionID), ["claude-code:thread"])
    }

    @MainActor
    func testSignalLightFollowingIgnoresPresenceOnlySessions() throws {
        let savedSelectionDefaults = clearSignalLightSelectionDefaults()
        let savedMonitoringDefaults = [
            "isCodexDesktopMonitoringEnabled",
            "isClaudeDesktopMonitoringEnabled"
        ].map { ($0, UserDefaults.standard.object(forKey: $0)) }
        defer {
            restoreSignalLightSelectionDefaults(savedSelectionDefaults)
            restoreSignalLightSelectionDefaults(savedMonitoringDefaults)
        }
        UserDefaults.standard.set(false, forKey: "isCodexDesktopMonitoringEnabled")
        UserDefaults.standard.set(false, forKey: "isClaudeDesktopMonitoringEnabled")

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
                ]
            ),
            in: fixture.store
        )

        let model = makeMenuBarStatusModel(store: fixture.store)

        XCTAssertEqual(model.signalLightAgentSelectionMode, .following)
        XCTAssertEqual(model.displaySignalLightAgentScopes, [])
        XCTAssertEqual(model.displaySnapshot.aggregate, .idle)
        XCTAssertEqual(model.displaySnapshot.sessions, [])
        XCTAssertTrue(ActivityPresentation.visibleSessions(from: model.activitySnapshot, now: now).isEmpty)
        XCTAssertEqual(
            ActivityPresentation.visiblePresenceSessions(from: model.activitySnapshot, now: now).map(\.sessionID),
            []
        )
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

        let model = makeMenuBarStatusModel(store: fixture.store)
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
    func testManualSignalLightSelectionKeepsCLIPermissionAboveDesktopWork() throws {
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
                        updatedAt: now
                    ),
                    "codex-cli:approval": SessionRecord(
                        agent: "codex-cli",
                        signal: .permissionRequest,
                        lastEvent: "PermissionRequest",
                        updatedAt: now.addingTimeInterval(-1)
                    )
                ]
            ),
            in: fixture.store
        )

        let model = makeMenuBarStatusModel(store: fixture.store)
        model.setSignalLightAgentScopes([.codexDesktop, .codexCLI])

        XCTAssertEqual(model.displaySnapshot.aggregate, .permission)
        XCTAssertEqual(
            Set(model.displaySnapshot.sessions.map(\.sessionID)),
            ["codex-desktop:thread", "codex-cli:approval"]
        )
    }

    @MainActor
    func testManualSignalLightSelectionKeepsCodexIDEEntrypointsDistinct() throws {
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
                    "codex-vscode:notice": SessionRecord(
                        agent: "codex-vscode",
                        signal: .attention,
                        lastEvent: "Notification",
                        updatedAt: now
                    ),
                    "codex-xcode:block": SessionRecord(
                        agent: "codex-xcode",
                        signal: .blocked,
                        lastEvent: "StopFailure",
                        updatedAt: now.addingTimeInterval(-1)
                    ),
                    "codex-idea:work": SessionRecord(
                        agent: "codex-idea",
                        signal: .working,
                        lastEvent: "PreToolUse",
                        updatedAt: now.addingTimeInterval(-2)
                    )
                ]
            ),
            in: fixture.store
        )

        let model = makeMenuBarStatusModel(store: fixture.store)
        model.setSignalLightAgentScopes([.codexVSCode, .codexXcode, .codexIDEA])

        XCTAssertEqual(model.displaySnapshot.aggregate, .blocked)
        XCTAssertEqual(
            Set(model.displaySnapshot.sessions.map(ActivityPresentation.activitySourceKey(for:))),
            ["codex:ide:vs-code", "codex:ide:xcode", "codex:ide:idea"]
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

        let model = makeMenuBarStatusModel(store: fixture.store)
        model.setSignalLightAgentScopes([.localScript])

        XCTAssertEqual(model.signalLightAgentSelectionMode, .manual)
        XCTAssertEqual(model.displaySignalLightAgentScopes, [])
        XCTAssertEqual(model.displaySnapshot.aggregate, .idle)
        XCTAssertEqual(model.displaySnapshot.sessions, [])
        XCTAssertNil(model.signalLightAgentUnavailableHint)
    }

    @MainActor
    func testRecentPassiveDesktopEventsDoNotRemainFallbackSessionForFiveMinutes() {
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
        let freshMessage = RecentSignalEvent(
            id: "fresh-message",
            sessionID: "codex-cli:thread",
            signal: .working,
            updatedAt: now.addingTimeInterval(-30),
            agent: "codex-cli",
            event: "DesktopMessage"
        )
        let staleMessage = RecentSignalEvent(
            id: "stale-message",
            sessionID: "codex-cli:thread",
            signal: .working,
            updatedAt: now.addingTimeInterval(-60),
            agent: "codex-cli",
            event: "DesktopMessage"
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
        XCTAssertTrue(MenuBarStatusModel.shouldUseRecentEventAsFallbackSession(freshMessage, now: now))
        XCTAssertFalse(MenuBarStatusModel.shouldUseRecentEventAsFallbackSession(staleMessage, now: now))
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
    func testStaleDesktopMessageDoesNotDriveStatusBarOrFloatingLight() throws {
        let savedSelectionDefaults = clearSignalLightSelectionDefaults()
        let savedMonitoringDefaults = [
            "isCodexDesktopMonitoringEnabled",
            "isClaudeDesktopMonitoringEnabled"
        ].map { ($0, UserDefaults.standard.object(forKey: $0)) }
        defer {
            restoreSignalLightSelectionDefaults(savedSelectionDefaults)
            restoreSignalLightSelectionDefaults(savedMonitoringDefaults)
        }
        UserDefaults.standard.set(false, forKey: "isCodexDesktopMonitoringEnabled")
        UserDefaults.standard.set(false, forKey: "isClaudeDesktopMonitoringEnabled")

        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let now = Date()
        let staleUpdatedAt = now.addingTimeInterval(-60)

        try writeDocument(
            SignalStateDocument(
                aggregate: .working,
                updatedAt: staleUpdatedAt,
                sessions: [
                    "codex-desktop:thread": SessionRecord(
                        agent: "codex-desktop",
                        signal: .working,
                        lastEvent: "DesktopMessage",
                        updatedAt: staleUpdatedAt
                    )
                ],
                events: [
                    SignalEventRecord(
                        id: "codex-output",
                        sessionID: "codex-desktop:thread",
                        agent: "codex-desktop",
                        signal: .working,
                        event: "DesktopMessage",
                        updatedAt: staleUpdatedAt
                    )
                ]
            ),
            in: fixture.store
        )

        let model = makeMenuBarStatusModel(store: fixture.store)

        XCTAssertEqual(model.activitySnapshot.aggregate, .idle)
        XCTAssertEqual(model.displaySnapshot.aggregate, .idle)
        XCTAssertEqual(model.statusBarLightSnapshot.aggregate, .idle)
        XCTAssertEqual(model.floatingSignalLightSnapshot.aggregate, .idle)
        XCTAssertEqual(model.activitySnapshot.sessions, [])
    }

    @MainActor
    func testStaleDesktopThinkingDoesNotDriveStatusBarOrFloatingLight() throws {
        let savedSelectionDefaults = clearSignalLightSelectionDefaults()
        let savedMonitoringDefaults = [
            "isCodexDesktopMonitoringEnabled",
            "isClaudeDesktopMonitoringEnabled"
        ].map { ($0, UserDefaults.standard.object(forKey: $0)) }
        defer {
            restoreSignalLightSelectionDefaults(savedSelectionDefaults)
            restoreSignalLightSelectionDefaults(savedMonitoringDefaults)
        }
        UserDefaults.standard.set(false, forKey: "isCodexDesktopMonitoringEnabled")
        UserDefaults.standard.set(false, forKey: "isClaudeDesktopMonitoringEnabled")

        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let now = Date()
        let staleUpdatedAt = now.addingTimeInterval(-60)

        try writeDocument(
            SignalStateDocument(
                aggregate: .thinking,
                updatedAt: staleUpdatedAt,
                sessions: [
                    "codex-desktop:thread": SessionRecord(
                        agent: "codex-desktop",
                        signal: .thinking,
                        lastEvent: "DesktopThinking",
                        updatedAt: staleUpdatedAt
                    )
                ],
                events: [
                    SignalEventRecord(
                        id: "codex-thinking",
                        sessionID: "codex-desktop:thread",
                        agent: "codex-desktop",
                        signal: .thinking,
                        event: "DesktopThinking",
                        updatedAt: staleUpdatedAt
                    )
                ]
            ),
            in: fixture.store
        )

        let model = makeMenuBarStatusModel(store: fixture.store)

        XCTAssertEqual(model.activitySnapshot.aggregate, .idle)
        XCTAssertEqual(model.displaySnapshot.aggregate, .idle)
        XCTAssertEqual(model.statusBarLightSnapshot.aggregate, .idle)
        XCTAssertEqual(model.floatingSignalLightSnapshot.aggregate, .idle)
        XCTAssertEqual(model.activitySnapshot.sessions, [])
    }

    @MainActor
    func testOldDesktopToolCallDoesNotDriveStatusBarOrFloatingLightAfterLiveWindow() throws {
        let savedSelectionDefaults = clearSignalLightSelectionDefaults()
        let savedMonitoringDefaults = [
            "isCodexDesktopMonitoringEnabled",
            "isClaudeDesktopMonitoringEnabled"
        ].map { ($0, UserDefaults.standard.object(forKey: $0)) }
        defer {
            restoreSignalLightSelectionDefaults(savedSelectionDefaults)
            restoreSignalLightSelectionDefaults(savedMonitoringDefaults)
        }
        UserDefaults.standard.set(false, forKey: "isCodexDesktopMonitoringEnabled")
        UserDefaults.standard.set(false, forKey: "isClaudeDesktopMonitoringEnabled")

        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let now = Date()
        let staleUpdatedAt = now.addingTimeInterval(-6 * 60)

        try writeDocument(
            SignalStateDocument(
                aggregate: .working,
                updatedAt: staleUpdatedAt,
                sessions: [
                    "codex-desktop:thread": SessionRecord(
                        agent: "codex-desktop",
                        signal: .working,
                        lastEvent: "DesktopToolCall:exec_command",
                        updatedAt: staleUpdatedAt
                    )
                ],
                events: [
                    SignalEventRecord(
                        id: "codex-tool-call",
                        sessionID: "codex-desktop:thread",
                        agent: "codex-desktop",
                        signal: .working,
                        event: "DesktopToolCall:exec_command",
                        updatedAt: staleUpdatedAt
                    )
                ]
            ),
            in: fixture.store
        )

        let model = makeMenuBarStatusModel(store: fixture.store)

        XCTAssertEqual(model.activitySnapshot.aggregate, .idle)
        XCTAssertEqual(model.displaySnapshot.aggregate, .idle)
        XCTAssertEqual(model.statusBarLightSnapshot.aggregate, .idle)
        XCTAssertEqual(model.floatingSignalLightSnapshot.aggregate, .idle)
        XCTAssertEqual(model.activitySnapshot.sessions, [])
    }

    @MainActor
    func testExpiredStaleAggregateWithoutVisibleSessionsDoesNotDriveLights() throws {
        let savedSelectionDefaults = clearSignalLightSelectionDefaults()
        let savedMonitoringDefaults = [
            "isCodexDesktopMonitoringEnabled",
            "isClaudeDesktopMonitoringEnabled"
        ].map { ($0, UserDefaults.standard.object(forKey: $0)) }
        defer {
            restoreSignalLightSelectionDefaults(savedSelectionDefaults)
            restoreSignalLightSelectionDefaults(savedMonitoringDefaults)
        }
        UserDefaults.standard.set(false, forKey: "isCodexDesktopMonitoringEnabled")
        UserDefaults.standard.set(false, forKey: "isClaudeDesktopMonitoringEnabled")

        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let now = Date()
        let staleUpdatedAt = now.addingTimeInterval(-1_800)

        try writeDocument(
            SignalStateDocument(
                aggregate: .stale,
                updatedAt: staleUpdatedAt,
                sessions: [:],
                events: [
                    SignalEventRecord(
                        id: "old-tool-call",
                        sessionID: "codex-desktop:thread",
                        agent: "codex-desktop",
                        signal: .working,
                        event: "DesktopToolCall:exec_command",
                        updatedAt: staleUpdatedAt
                    )
                ]
            ),
            in: fixture.store
        )

        let model = makeMenuBarStatusModel(store: fixture.store)

        XCTAssertEqual(model.activitySnapshot.aggregate, .idle)
        XCTAssertEqual(model.displaySnapshot.aggregate, .idle)
        XCTAssertEqual(model.statusBarLightSnapshot.aggregate, .idle)
        XCTAssertEqual(model.floatingSignalLightSnapshot.aggregate, .idle)
        XCTAssertEqual(model.activitySnapshot.sessions, [])
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

        let model = makeMenuBarStatusModel(store: fixture.store)
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

    @MainActor
    func testActivitySnapshotKeepsCurrentCLIPermissionOverLaterToolEvent() throws {
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let now = Date()
        let permissionAt = now.addingTimeInterval(-10 * 60)
        let sessionID = "codex-cli:permission-thread"

        try writeDocument(
            SignalStateDocument(
                aggregate: .permission,
                updatedAt: now,
                sessions: [
                    sessionID: SessionRecord(
                        agent: "codex-cli",
                        signal: .permission,
                        lastEvent: "PermissionRequest",
                        updatedAt: permissionAt
                    )
                ],
                events: [
                    SignalEventRecord(
                        id: "permission",
                        sessionID: sessionID,
                        agent: "codex-cli",
                        signal: .permission,
                        event: "PermissionRequest",
                        updatedAt: permissionAt
                    ),
                    SignalEventRecord(
                        id: "tool-call",
                        sessionID: sessionID,
                        agent: "codex-cli",
                        signal: .attention,
                        event: "DesktopToolCall:exec_command",
                        updatedAt: permissionAt.addingTimeInterval(1)
                    )
                ]
            ),
            in: fixture.store
        )

        let model = makeMenuBarStatusModel(store: fixture.store)
        let snapshot = model.activitySnapshot

        XCTAssertEqual(snapshot.aggregate, .permission)
        XCTAssertEqual(
            snapshot.sessions.first { $0.sessionID == sessionID }?.lastEvent,
            "PermissionRequest"
        )
        XCTAssertFalse(
            snapshot.sessions.contains { session in
                session.sessionID.hasPrefix("recent-activity:")
                    && session.lastEvent == "DesktopToolCall:exec_command"
            }
        )
    }

    @MainActor
    func testActivitySnapshotSuppressesResolvedDesktopPermissionAfterLaterWork() throws {
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let now = Date()
        let permissionAt = now.addingTimeInterval(-6 * 60)
        let newerWorkAt = now.addingTimeInterval(-30)
        let permissionSessionID = "codex-desktop:old-permission"
        let currentSessionID = "codex-desktop:current-work"

        try writeDocument(
            SignalStateDocument(
                aggregate: .permission,
                updatedAt: now,
                sessions: [
                    permissionSessionID: SessionRecord(
                        agent: "codex-desktop",
                        signal: .permissionRequest,
                        lastEvent: "DesktopToolCall:exec_command",
                        updatedAt: permissionAt
                    ),
                    currentSessionID: SessionRecord(
                        agent: "codex-desktop",
                        signal: .thinking,
                        lastEvent: "DesktopThinking",
                        updatedAt: newerWorkAt
                    )
                ],
                events: [
                    SignalEventRecord(
                        id: "permission",
                        sessionID: permissionSessionID,
                        agent: "codex-desktop",
                        signal: .permissionRequest,
                        event: "DesktopToolCall:exec_command",
                        updatedAt: permissionAt
                    ),
                    SignalEventRecord(
                        id: "work",
                        sessionID: currentSessionID,
                        agent: "codex-desktop",
                        signal: .thinking,
                        event: "DesktopThinking",
                        updatedAt: newerWorkAt
                    )
                ]
            ),
            in: fixture.store
        )

        let model = makeMenuBarStatusModel(store: fixture.store)
        let snapshot = model.activitySnapshot

        XCTAssertNotEqual(snapshot.aggregate.displayState, .permission)
        XCTAssertFalse(snapshot.sessions.contains { $0.signal.displayState == .permission })
        XCTAssertEqual(snapshot.sessions.first?.sessionID, currentSessionID)
        XCTAssertEqual(snapshot.sessions.first?.signal, .thinking)
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

    func testCodexPlatformPresenceMonitorIgnoresDesktopAppWithoutVisibleWindow() {
        let sessions = CodexPlatformPresenceMonitor.detectSessions(
            applications: [
                CodexPlatformPresenceMonitor.RunningApplicationInfo(
                    bundleIdentifier: "com.openai.codex",
                    localizedName: "Codex",
                    processIdentifier: 42,
                    hasVisibleWindow: false
                )
            ],
            processes: [],
            now: Date(timeIntervalSince1970: 1_000)
        )

        XCTAssertFalse(sessions.contains { $0.sessionID == "platform-presence:codex-desktop" })
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
    func testActivityPresentationPresenceLimitIncludesAllSupportedEntrypoints() throws {
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

        let visible = ActivityPresentation.visiblePresenceSessions(
            from: snapshot,
            limit: ActivityPresentation.currentSessionLimit
        )

        XCTAssertEqual(visible.count, 6)
        XCTAssertTrue(visible.contains { $0.sessionID == "platform-presence:codex-cli" })

        let visibleDesktop = ActivityPresentation.visibleDesktopPresenceSessions(
            from: snapshot,
            limit: ActivityPresentation.currentSessionLimit
        )
        XCTAssertEqual(Set(visibleDesktop.map(\.sessionID)), [
            "platform-presence:codex-desktop",
            "platform-presence:claude-desktop"
        ])

        let desktopSession = try XCTUnwrap(visibleDesktop.first { $0.sessionID == "platform-presence:codex-desktop" })
        let desktopModel = makeMenuBarStatusModel()
        desktopModel.appLanguage = .zhHans
        XCTAssertEqual(desktopModel.activitySessionTitle(for: desktopSession), "Codex · 桌面版已开启")

        let cliSession = try XCTUnwrap(visible.first { $0.sessionID == "platform-presence:codex-cli" })
        let model = makeMenuBarStatusModel()
        model.appLanguage = .zhHans
        XCTAssertEqual(model.activitySessionTitle(for: cliSession), "Codex · 终端已检测到")
        XCTAssertEqual(model.activitySessionStatusSubtitle(for: cliSession), "空闲")
    }

    @MainActor
    func testActivityPresentationEventTitleIncludesCodexEntrypoint() {
        let model = makeMenuBarStatusModel()
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
        let model = makeMenuBarStatusModel()
        model.appLanguage = .zhHans
        let session = SessionStatus(
            sessionID: "platform-presence:codex-vscode",
            signal: .idle,
            updatedAt: Date(),
            agent: "codex-vscode",
            lastEvent: "PlatformPresence:VSCode"
        )

        XCTAssertEqual(model.activitySessionTitle(for: session), "Codex · VS Code 已检测到")
        XCTAssertEqual(model.activitySessionStatusSubtitle(for: session), "空闲")
    }

    @MainActor
    func testPlatformPresenceFilteringRespectsCodexAndClaudeToggles() {
        let now = Date(timeIntervalSince1970: 1_000)
        let model = makeMenuBarStatusModel()
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

        let model = makeMenuBarStatusModel()

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

        let model = makeMenuBarStatusModel()
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

        let restoredModel = makeMenuBarStatusModel()
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
    func testAlertSignalEffectSettingsDefaultAndPersist() {
        let defaults = UserDefaults.standard
        let keys = [
            "needsReviewSignalEffect",
            "permissionSignalEffect",
            "blockedSignalEffect"
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

        let model = makeMenuBarStatusModel()
        XCTAssertEqual(model.needsReviewSignalEffect, .slowFlash)
        XCTAssertEqual(model.permissionSignalEffect, .slowFlash)
        XCTAssertEqual(model.blockedSignalEffect, .fastFlash)
        XCTAssertEqual(defaults.string(forKey: "needsReviewSignalEffect"), AlertSignalEffect.slowFlash.rawValue)
        XCTAssertEqual(defaults.string(forKey: "permissionSignalEffect"), AlertSignalEffect.slowFlash.rawValue)
        XCTAssertEqual(defaults.string(forKey: "blockedSignalEffect"), AlertSignalEffect.fastFlash.rawValue)

        model.setNeedsReviewSignalEffect(.slowFlash)
        model.setPermissionSignalEffect(.steady)
        model.setBlockedSignalEffect(.breathing)

        XCTAssertEqual(defaults.string(forKey: "needsReviewSignalEffect"), AlertSignalEffect.slowFlash.rawValue)
        XCTAssertEqual(defaults.string(forKey: "permissionSignalEffect"), AlertSignalEffect.steady.rawValue)
        XCTAssertEqual(defaults.string(forKey: "blockedSignalEffect"), AlertSignalEffect.breathing.rawValue)

        let restoredModel = makeMenuBarStatusModel()
        XCTAssertEqual(restoredModel.needsReviewSignalEffect, .slowFlash)
        XCTAssertEqual(restoredModel.permissionSignalEffect, .steady)
        XCTAssertEqual(restoredModel.blockedSignalEffect, .breathing)
        XCTAssertEqual(restoredModel.signalEffectCustomization.needsReviewEffect, .slowFlash)
        XCTAssertEqual(restoredModel.signalEffectCustomization.permissionEffect, .steady)
        XCTAssertEqual(restoredModel.signalEffectCustomization.blockedEffect, .breathing)
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

        let model = makeMenuBarStatusModel()
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

        let model = makeMenuBarStatusModel()
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

        let model = makeMenuBarStatusModel()

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

    @MainActor
    func testMenuBarStatusModelLaunchLoadsCodexAccountMetadataOnly() {
        let manager = CountingCodexAccountManager()
        _ = MenuBarStatusModel(codexAccountManager: manager)

        XCTAssertEqual(manager.metadataLoadCount, 1)
        XCTAssertEqual(manager.fullLoadCount, 0)
    }

    @MainActor
    func testMenuBarStatusModelCodexAddFailureStaysVisibleInAccountMessage() async throws {
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let model = MenuBarStatusModel(
            store: fixture.store,
            codexDesktopActivityMonitor: CodexDesktopActivityMonitor(replaysInitialHistory: false),
            codexAccountManager: FailingCodexAccountManager(.missingCodexBinary)
        )

        model.addCodexAccount()

        for _ in 0..<50 {
            if !model.isCodexAccountActionRunning {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertFalse(model.isCodexAccountActionRunning)
        let message = try XCTUnwrap(model.codexAccountMessage)
        XCTAssertTrue(message.localizedCaseInsensitiveContains("codex"))
        XCTAssertTrue(message.contains("Save Current") || message.contains("保存当前"))
        XCTAssertEqual(model.lastError, message)
        XCTAssertTrue(model.isCodexAccountMessageError)
    }

    @MainActor
    func testMenuBarStatusModelExplainsKeychainAuthenticationFailure() async throws {
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let model = MenuBarStatusModel(
            store: fixture.store,
            codexDesktopActivityMonitor: CodexDesktopActivityMonitor(replaysInitialHistory: false),
            codexAccountManager: FailingCodexAccountManager(
                .keychainFailure("Keychain operation failed with status -25293")
            )
        )

        model.addCodexAccount()

        for _ in 0..<50 {
            if !model.isCodexAccountActionRunning {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        let message = try XCTUnwrap(model.codexAccountMessage)
        XCTAssertTrue(message.contains("钥匙串") || message.localizedCaseInsensitiveContains("keychain"))
        XCTAssertTrue(message.contains("不是 Codex 密码") || message.contains("not your Codex password"))
        XCTAssertFalse(message.contains("-25293"))
    }

    @MainActor
    func testCodexUsageRefreshDoesNotRefreshSavedAccountCredentials() async throws {
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CodexRateLimitFetcherURLProtocol.self]
        let session = URLSession(configuration: configuration)
        CodexRateLimitFetcherURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "session=manual")
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

        let manager = CountingCodexAccountManager()
        let model = MenuBarStatusModel(
            store: fixture.store,
            codexDesktopActivityMonitor: CodexDesktopActivityMonitor(replaysInitialHistory: false),
            codexAccountManager: manager,
            codexRateLimitFetcher: CodexRateLimitFetcher(
                environment: ["CODEX_HOME": fixture.directory.path],
                session: session
            )
        )
        model.codexUsageDataSource = .automatic
        model.codexOpenAICookieMode = .manual
        model.codexManualOpenAICookieHeader = "session=manual"
        model.isCodexDesktopMonitoringEnabled = true
        model.isMonitoringPaused = false

        model.pollCodexRateLimitsIfNeeded(force: true)

        for _ in 0..<50 {
            if !model.isCodexRateLimitFetchInFlight,
               model.latestAgentQuota != nil {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertEqual(model.latestAgentQuota?.usedPercent ?? -1, 15, accuracy: 0.01)
        XCTAssertEqual(manager.refreshSavedCurrentAccountCount, 0)
        XCTAssertEqual(manager.fullLoadCount, 0)
        XCTAssertGreaterThanOrEqual(manager.metadataLoadCount, 2)
    }

    @MainActor
    func testCodexUsageSourceChangeDuringInFlightQueuesLatestRoute() async throws {
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let auth = try XCTUnwrap(String(data: codexOAuthAuthJSON(
            email: "selected@example.com",
            accountID: "acct_selected",
            accessToken: "selected-oauth-token"
        ), encoding: .utf8))
            .replacingOccurrences(
                of: "2026-06-01T00:00:00Z",
                with: ISO8601DateFormatter().string(from: Date())
            )
        try Data(auth.utf8).write(to: fixture.directory.appendingPathComponent("auth.json"))

        let oldUsageStarted = TestSemaphoreGate()
        let releaseOldUsage = TestSemaphoreGate()
        let recorder = URLRequestRecorder()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CodexRateLimitFetcherURLProtocol.self]
        let session = URLSession(configuration: configuration)
        CodexRateLimitFetcherURLProtocol.handler = { request in
            recorder.append(request)
            if request.url?.path == "/backend-api/me" {
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (response, Data("{\"email\":\"selected@example.com\"}".utf8))
            }
            if request.value(forHTTPHeaderField: "Cookie") == "session=old-route" {
                oldUsageStarted.signal()
                guard releaseOldUsage.wait(seconds: 5) else {
                    throw URLError(.timedOut)
                }
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (response, Data("""
                {
                  "rate_limit": {
                    "primary_window": {
                      "used_percent": 11,
                      "reset_at": 1781788782,
                      "limit_window_seconds": 18000
                    }
                  }
                }
                """.utf8))
            }
            if request.url?.path.contains("rate-limit-reset-credits") == true {
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (response, Data("{\"credits\":[],\"available_count\":0}".utf8))
            }

            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer selected-oauth-token"
            )
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data("""
            {
              "rate_limit": {
                "primary_window": {
                  "used_percent": 72,
                  "reset_at": 1781788782,
                  "limit_window_seconds": 18000
                }
              }
            }
            """.utf8))
        }
        defer { CodexRateLimitFetcherURLProtocol.handler = nil }

        let defaults = UserDefaults.standard
        let originalSource = defaults.object(forKey: "codexUsageDataSource")
        defer {
            if let originalSource {
                defaults.set(originalSource, forKey: "codexUsageDataSource")
            } else {
                defaults.removeObject(forKey: "codexUsageDataSource")
            }
        }

        let manager = CodexAccountManager(
            environment: ["CODEX_HOME": fixture.directory.path],
            fileManager: .default,
            storeURL: fixture.directory.appendingPathComponent("accounts.json"),
            credentialStore: RecordingSecretStore()
        )
        _ = try manager.saveCurrentAccount()
        let model = MenuBarStatusModel(
            store: fixture.store,
            codexDesktopActivityMonitor: CodexDesktopActivityMonitor(replaysInitialHistory: false),
            codexAccountManager: manager,
            codexRateLimitFetcher: CodexRateLimitFetcher(
                environment: ["CODEX_HOME": fixture.directory.path],
                session: session
            )
        )
        model.codexUsageDataSource = .automatic
        model.codexOpenAICookieMode = .manual
        model.codexManualOpenAICookieHeader = "session=old-route"
        model.isCodexDesktopMonitoringEnabled = true
        model.isMonitoringPaused = false

        model.pollCodexRateLimitsIfNeeded(force: true)
        var didStartOldUsage = false
        for _ in 0..<100 {
            if oldUsageStarted.tryConsumeSignal() {
                didStartOldUsage = true
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(didStartOldUsage)

        model.setCodexUsageDataSource(.oauthAPI)
        releaseOldUsage.signal()

        for _ in 0..<200 {
            if !model.isCodexRateLimitFetchInFlight,
               model.codexUsageFetchState?.source == .oauth,
               model.latestAgentQuota?.usedPercent == 72 {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertFalse(model.isCodexRateLimitFetchInFlight)
        XCTAssertEqual(model.codexUsageFetchState?.source, .oauth)
        XCTAssertEqual(model.latestAgentQuota?.usedPercent ?? -1, 72, accuracy: 0.01)
        XCTAssertNotEqual(model.latestAgentQuota?.usedPercent, 11)
        XCTAssertEqual(
            recorder.requests.filter {
                $0.url?.path == "/backend-api/wham/usage"
                    && $0.value(forHTTPHeaderField: "Cookie") == "session=old-route"
            }.count,
            1
        )
        XCTAssertEqual(
            recorder.requests.filter {
                $0.url?.path == "/backend-api/wham/usage"
                    && $0.value(forHTTPHeaderField: "Authorization") == "Bearer selected-oauth-token"
            }.count,
            1,
            recorder.requests.map {
                "\($0.url?.absoluteString ?? "--") cookie=\($0.value(forHTTPHeaderField: "Cookie") ?? "--") auth=\($0.value(forHTTPHeaderField: "Authorization") ?? "--")"
            }.joined(separator: "\n")
        )
    }

    @MainActor
    func testCodexUsageAutomaticallyRecoversAfterExternalSameAccountAuthRefresh() async throws {
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let authURL = fixture.directory.appendingPathComponent("auth.json")
        let freshTimestamp = ISO8601DateFormatter().string(from: Date())
        let originalAuth = try XCTUnwrap(String(data: codexOAuthAuthJSON(
            email: "external@example.com",
            accountID: "acct_external",
            accessToken: "external-old-access"
        ), encoding: .utf8))
            .replacingOccurrences(of: "2026-06-01T00:00:00Z", with: freshTimestamp)
        try Data(originalAuth.utf8).write(to: authURL)

        let manager = CodexAccountManager(
            environment: ["CODEX_HOME": fixture.directory.path],
            fileManager: .default,
            storeURL: fixture.directory.appendingPathComponent("accounts.json"),
            credentialStore: RecordingSecretStore()
        )
        _ = try manager.saveCurrentAccount()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CodexRateLimitFetcherURLProtocol.self]
        let session = URLSession(configuration: configuration)
        func response(for request: URLRequest, usedPercent: Int) -> (HTTPURLResponse, Data) {
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            if request.url?.path.contains("rate-limit-reset-credits") == true {
                return (response, Data("{\"credits\":[],\"available_count\":0}".utf8))
            }
            return (response, Data("""
            {
              "rate_limit": {
                "primary_window": {
                  "used_percent": \(usedPercent),
                  "reset_at": 1781788782,
                  "limit_window_seconds": 18000
                }
              }
            }
            """.utf8))
        }
        CodexRateLimitFetcherURLProtocol.handler = { request in
            response(for: request, usedPercent: 20)
        }
        defer { CodexRateLimitFetcherURLProtocol.handler = nil }

        let model = MenuBarStatusModel(
            store: fixture.store,
            codexDesktopActivityMonitor: CodexDesktopActivityMonitor(replaysInitialHistory: false),
            codexAccountManager: manager,
            codexUsageSnapshotStore: CodexAccountUsageSnapshotStore(
                fileURL: fixture.directory.appendingPathComponent("usage.json")
            ),
            codexRateLimitFetcher: CodexRateLimitFetcher(
                environment: ["CODEX_HOME": fixture.directory.path],
                session: session,
                credentialPersistence: manager
            )
        )
        model.codexUsageDataSource = .oauthAPI
        model.isCodexDesktopMonitoringEnabled = true
        model.isMonitoringPaused = false
        model.pollCodexRateLimitsIfNeeded(force: true)
        for _ in 0..<100 {
            if !model.isCodexRateLimitFetchInFlight,
               model.latestAgentQuota?.usedPercent == 20 {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(model.latestAgentQuota?.usedPercent ?? -1, 20, accuracy: 0.01)

        let externallyRefreshedAuth = try XCTUnwrap(String(data: codexOAuthAuthJSON(
            email: "external@example.com",
            accountID: "acct_external",
            accessToken: "external-new-access"
        ), encoding: .utf8))
            .replacingOccurrences(of: "2026-06-01T00:00:00Z", with: freshTimestamp)
        try Data(externallyRefreshedAuth.utf8).write(to: authURL, options: .atomic)

        let recorder = URLRequestRecorder()
        CodexRateLimitFetcherURLProtocol.handler = { request in
            recorder.append(request)
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer external-new-access"
            )
            return response(for: request, usedPercent: 80)
        }
        model.pollCodexRateLimitsIfNeeded(force: true)
        for _ in 0..<200 {
            if !model.isCodexRateLimitFetchInFlight,
               model.latestAgentQuota?.usedPercent == 80,
               model.codexUsageFetchState?.errorMessage == nil {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertFalse(model.isCodexRateLimitFetchInFlight)
        XCTAssertEqual(model.latestAgentQuota?.usedPercent ?? -1, 80, accuracy: 0.01)
        XCTAssertEqual(model.codexUsageFetchState?.source, .oauth)
        XCTAssertNil(model.codexUsageFetchState?.errorMessage)
        XCTAssertEqual(
            recorder.requests.filter { $0.url?.path == "/backend-api/wham/usage" }.count,
            1
        )
    }

    @MainActor
    func testExternalAccountSwitchDuringUsageCannotMixQuotaAndResetCredits() async throws {
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let authURL = fixture.directory.appendingPathComponent("auth.json")
        let freshTimestamp = ISO8601DateFormatter().string(from: Date())
        let alphaAuth = try XCTUnwrap(String(data: codexOAuthAuthJSON(
            email: "alpha-live@example.com",
            accountID: "acct_alpha_live",
            accessToken: "alpha-live-access"
        ), encoding: .utf8))
            .replacingOccurrences(of: "2026-06-01T00:00:00Z", with: freshTimestamp)
        try Data(alphaAuth.utf8).write(to: authURL)

        let manager = CodexAccountManager(
            environment: ["CODEX_HOME": fixture.directory.path],
            fileManager: .default,
            storeURL: fixture.directory.appendingPathComponent("accounts.json"),
            credentialStore: RecordingSecretStore()
        )
        _ = try manager.saveCurrentAccount()

        let alphaUsageStarted = TestSemaphoreGate()
        let releaseAlphaUsage = TestSemaphoreGate()
        let recorder = URLRequestRecorder()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CodexRateLimitFetcherURLProtocol.self]
        let session = URLSession(configuration: configuration)
        CodexRateLimitFetcherURLProtocol.handler = { request in
            recorder.append(request)
            let authorization = request.value(forHTTPHeaderField: "Authorization")
            if request.url?.path == "/backend-api/wham/usage",
               authorization == "Bearer alpha-live-access" {
                alphaUsageStarted.signal()
                guard releaseAlphaUsage.wait(seconds: 5) else {
                    throw URLError(.timedOut)
                }
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (response, Data("""
                {
                  "rate_limit": {
                    "primary_window": {
                      "used_percent": 21,
                      "reset_at": 1781788782,
                      "limit_window_seconds": 18000
                    }
                  }
                }
                """.utf8))
            }
            if request.url?.path.contains("rate-limit-reset-credits") == true {
                XCTAssertEqual(authorization, "Bearer beta-live-access")
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (response, Data("""
                {
                  "credits": [
                    {"status":"available","granted_at":"2026-07-01T00:00:00Z","expires_at":"2026-08-01T00:00:00Z"},
                    {"status":"available","granted_at":"2026-07-02T00:00:00Z","expires_at":"2026-08-02T00:00:00Z"}
                  ],
                  "available_count": 2
                }
                """.utf8))
            }

            XCTAssertEqual(authorization, "Bearer beta-live-access")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data("""
            {
              "rate_limit": {
                "primary_window": {
                  "used_percent": 80,
                  "reset_at": 1781788782,
                  "limit_window_seconds": 18000
                }
              }
            }
            """.utf8))
        }
        defer { CodexRateLimitFetcherURLProtocol.handler = nil }

        let model = MenuBarStatusModel(
            store: fixture.store,
            codexDesktopActivityMonitor: CodexDesktopActivityMonitor(replaysInitialHistory: false),
            codexAccountManager: manager,
            codexUsageSnapshotStore: CodexAccountUsageSnapshotStore(
                fileURL: fixture.directory.appendingPathComponent("usage.json")
            ),
            codexRateLimitFetcher: CodexRateLimitFetcher(
                environment: ["CODEX_HOME": fixture.directory.path],
                session: session,
                credentialPersistence: manager
            )
        )
        model.codexUsageDataSource = .oauthAPI
        model.isCodexDesktopMonitoringEnabled = true
        model.isMonitoringPaused = false
        model.pollCodexRateLimitsIfNeeded(force: true)

        var didStartAlphaUsage = false
        for _ in 0..<100 {
            if alphaUsageStarted.tryConsumeSignal() {
                didStartAlphaUsage = true
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(didStartAlphaUsage)

        let betaAuth = try XCTUnwrap(String(data: codexOAuthAuthJSON(
            email: "beta-live@example.com",
            accountID: "acct_beta_live",
            accessToken: "beta-live-access"
        ), encoding: .utf8))
            .replacingOccurrences(of: "2026-06-01T00:00:00Z", with: freshTimestamp)
        try Data(betaAuth.utf8).write(to: authURL, options: .atomic)
        releaseAlphaUsage.signal()

        for _ in 0..<200 {
            if !model.isCodexRateLimitFetchInFlight,
               model.codexCurrentAccount?.accountID == "acct_beta_live",
               model.latestAgentQuota?.usedPercent == 80,
               model.latestCodexResetCredits?.availableCount == 2 {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertFalse(model.isCodexRateLimitFetchInFlight)
        XCTAssertEqual(model.codexCurrentAccount?.accountID, "acct_beta_live")
        XCTAssertEqual(model.latestAgentQuota?.usedPercent ?? -1, 80, accuracy: 0.01)
        XCTAssertEqual(model.latestCodexResetCredits?.availableCount, 2)
        XCTAssertNotEqual(model.latestAgentQuota?.usedPercent, 21)
        XCTAssertFalse(recorder.requests.contains {
            $0.url?.path.contains("rate-limit-reset-credits") == true
                && $0.value(forHTTPHeaderField: "Authorization") == "Bearer alpha-live-access"
        })
    }

    @MainActor
    func testPausingMonitoringRejectsInFlightUsageFailureWithoutClearingCache() async throws {
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CodexRateLimitFetcherURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let successData = Data("""
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
        CodexRateLimitFetcherURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, successData)
        }
        defer { CodexRateLimitFetcherURLProtocol.handler = nil }

        let model = MenuBarStatusModel(
            store: fixture.store,
            codexDesktopActivityMonitor: CodexDesktopActivityMonitor(replaysInitialHistory: false),
            codexAccountManager: CountingCodexAccountManager(),
            codexRateLimitFetcher: CodexRateLimitFetcher(
                environment: ["CODEX_HOME": fixture.directory.path],
                session: session
            )
        )
        model.codexUsageDataSource = .automatic
        model.codexOpenAICookieMode = .manual
        model.codexManualOpenAICookieHeader = "session=pause-test"
        model.isCodexDesktopMonitoringEnabled = true
        model.isMonitoringPaused = false

        model.pollCodexRateLimitsIfNeeded(force: true)
        for _ in 0..<100 {
            if !model.isCodexRateLimitFetchInFlight,
               model.latestAgentQuota?.usedPercent == 25 {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let successfulAt = try XCTUnwrap(model.codexUsageFetchState?.lastSuccessfulAt)

        let failedRequestStarted = TestSemaphoreGate()
        let releaseFailedRequest = TestSemaphoreGate()
        CodexRateLimitFetcherURLProtocol.handler = { request in
            failedRequestStarted.signal()
            guard releaseFailedRequest.wait(seconds: 5) else {
                throw URLError(.timedOut)
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }
        model.pollCodexRateLimitsIfNeeded(force: true)
        var didStartFailedRequest = false
        for _ in 0..<100 {
            if failedRequestStarted.tryConsumeSignal() {
                didStartFailedRequest = true
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(didStartFailedRequest)

        model.setMonitoringPaused(true)
        releaseFailedRequest.signal()
        for _ in 0..<100 {
            if !model.isCodexRateLimitFetchInFlight {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertFalse(model.isCodexRateLimitFetchInFlight)
        XCTAssertEqual(model.latestAgentQuota?.usedPercent ?? -1, 25, accuracy: 0.01)
        XCTAssertEqual(model.codexUsageFetchState?.lastSuccessfulAt, successfulAt)
        XCTAssertNil(model.codexUsageFetchState?.errorMessage)
    }

    @MainActor
    func testCodexUsageRefreshFailureKeepsCachedQuotaAndMarksStateStale() async throws {
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CodexRateLimitFetcherURLProtocol.self]
        let session = URLSession(configuration: configuration)
        CodexRateLimitFetcherURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "session=manual")
            let data = Data("""
            {
              "rate_limit": {
                "primary_window": {
                  "used_percent": 18,
                  "reset_at": 1781788782,
                  "limit_window_seconds": 18000
                }
              }
            }
            """.utf8)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, data)
        }
        defer { CodexRateLimitFetcherURLProtocol.handler = nil }

        let model = MenuBarStatusModel(
            store: fixture.store,
            codexDesktopActivityMonitor: CodexDesktopActivityMonitor(replaysInitialHistory: false),
            codexAccountManager: CountingCodexAccountManager(),
            codexRateLimitFetcher: CodexRateLimitFetcher(
                environment: ["CODEX_HOME": fixture.directory.path],
                session: session
            )
        )
        model.codexUsageDataSource = .automatic
        model.codexOpenAICookieMode = .manual
        model.codexManualOpenAICookieHeader = "session=manual"
        model.isCodexDesktopMonitoringEnabled = true
        model.isMonitoringPaused = false

        XCTAssertTrue(model.isCodexCookieControlEnabled)
        model.pollCodexRateLimitsIfNeeded(force: true)
        for _ in 0..<100 {
            if !model.isCodexRateLimitFetchInFlight,
               model.codexUsageFetchState?.lastSuccessfulAt != nil {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        let successfulAt = try XCTUnwrap(model.codexUsageFetchState?.lastSuccessfulAt)
        XCTAssertEqual(model.latestAgentQuota?.usedPercent ?? -1, 18, accuracy: 0.01)
        XCTAssertEqual(model.codexUsageFetchState?.source, .manualCookie)
        XCTAssertNil(model.codexUsageFetchState?.errorMessage)
        XCTAssertFalse(model.codexUsageFetchState?.isStale ?? true)

        CodexRateLimitFetcherURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "session=manual")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 500,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }
        model.pollCodexRateLimitsIfNeeded(force: true)
        for _ in 0..<100 {
            if !model.isCodexRateLimitFetchInFlight,
               model.codexUsageFetchState?.errorMessage != nil {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertEqual(model.latestAgentQuota?.usedPercent ?? -1, 18, accuracy: 0.01)
        XCTAssertEqual(model.codexUsageFetchState?.source, .manualCookie)
        XCTAssertEqual(model.codexUsageFetchState?.lastSuccessfulAt, successfulAt)
        XCTAssertNotNil(model.codexUsageFetchState?.errorMessage)
        XCTAssertTrue(model.codexUsageFetchState?.isStale ?? false)

        model.codexUsageDataSource = .oauthAPI
        XCTAssertFalse(model.isCodexCookieControlEnabled)
    }

    @MainActor
    func testCodexUnauthorizedRefreshClearsCachedQuotaInsteadOfShowingStaleData() async throws {
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        try Data("""
        {
          "tokens": {
            "access_token": "expired-oauth-token",
            "refresh_token": "",
            "account_id": "acct_expired"
          }
        }
        """.utf8).write(to: fixture.directory.appendingPathComponent("auth.json"))

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CodexRateLimitFetcherURLProtocol.self]
        let session = URLSession(configuration: configuration)
        CodexRateLimitFetcherURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            if request.url?.path.contains("rate-limit-reset-credits") == true {
                return (response, Data("{\"credits\":[],\"available_count\":0}".utf8))
            }
            let usage = Data("""
            {
              "rate_limit": {
                "primary_window": {
                  "used_percent": 27,
                  "reset_at": 1781788782,
                  "limit_window_seconds": 18000
                }
              }
            }
            """.utf8)
            return (response, usage)
        }
        defer { CodexRateLimitFetcherURLProtocol.handler = nil }

        let manager = CodexAccountManager(
            environment: ["CODEX_HOME": fixture.directory.path],
            fileManager: .default,
            storeURL: fixture.directory.appendingPathComponent("accounts.json"),
            credentialStore: RecordingSecretStore()
        )
        _ = try manager.saveCurrentAccount()
        let model = MenuBarStatusModel(
            store: fixture.store,
            codexDesktopActivityMonitor: CodexDesktopActivityMonitor(replaysInitialHistory: false),
            codexAccountManager: manager,
            codexRateLimitFetcher: CodexRateLimitFetcher(
                environment: ["CODEX_HOME": fixture.directory.path],
                session: session
            )
        )
        model.codexUsageDataSource = .oauthAPI
        model.isCodexDesktopMonitoringEnabled = true
        model.isMonitoringPaused = false

        model.pollCodexRateLimitsIfNeeded(force: true)
        for _ in 0..<100 {
            if !model.isCodexRateLimitFetchInFlight,
               model.latestAgentQuota?.usedPercent == 27 {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(model.latestAgentQuota?.usedPercent ?? -1, 27, accuracy: 0.01)

        CodexRateLimitFetcherURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }
        model.pollCodexRateLimitsIfNeeded(force: true)
        for _ in 0..<100 {
            if !model.isCodexRateLimitFetchInFlight,
               model.codexUsageFetchState?.errorMessage != nil {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertNil(model.latestAgentQuota)
        XCTAssertNil(model.latestCodexCredits)
        XCTAssertNil(model.latestCodexResetCredits)
        XCTAssertNil(model.codexUsageFetchState?.source)
        XCTAssertNil(model.codexUsageFetchState?.lastSuccessfulAt)
        XCTAssertNotNil(model.codexUsageFetchState?.errorMessage)
        XCTAssertFalse(model.codexUsageFetchState?.isStale ?? true)
    }

    @MainActor
    func testCodexAccountSwitchRejectsLateUsageFromPreviousAccount() async throws {
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let now = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-07-18T00:00:00Z")
        )

        let accountStoreURL = fixture.directory.appendingPathComponent("accounts.json")
        let usageStoreURL = fixture.directory.appendingPathComponent("usage-snapshots.json")
        let authURL = fixture.directory.appendingPathComponent("auth.json")
        let credentialStore = RecordingSecretStore()
        let manager = CodexAccountManager(
            environment: ["CODEX_HOME": fixture.directory.path],
            fileManager: .default,
            storeURL: accountStoreURL,
            credentialStore: credentialStore
        )

        let alphaAuth = try XCTUnwrap(String(data: codexOAuthAuthJSON(
            email: "alpha@example.com",
            accountID: "acct_alpha",
            accessToken: "alpha-access-token"
        ), encoding: .utf8))
            .replacingOccurrences(of: "2026-06-01T00:00:00Z", with: "2026-07-11T00:00:00Z")
        try Data(alphaAuth.utf8).write(to: authURL)
        let alpha = try manager.saveCurrentAccount()

        let betaAuth = try XCTUnwrap(String(data: codexOAuthAuthJSON(
            email: "beta@example.com",
            accountID: "acct_beta",
            accessToken: "beta-access-token"
        ), encoding: .utf8))
            .replacingOccurrences(of: "2026-06-01T00:00:00Z", with: "2026-07-11T00:00:00Z")
        try Data(betaAuth.utf8).write(to: authURL)
        let beta = try manager.saveCurrentAccount()
        _ = try manager.switchToAccount(id: alpha.id)

        let alphaRequestStarted = TestSemaphoreGate()
        let releaseAlphaResponse = TestSemaphoreGate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CodexRateLimitFetcherURLProtocol.self]
        let session = URLSession(configuration: configuration)
        CodexRateLimitFetcherURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            if request.url?.path.contains("rate-limit-reset-credits") == true {
                return (response, Data("{\"credits\":[],\"available_count\":0}".utf8))
            }

            let authorization = request.value(forHTTPHeaderField: "Authorization")
            let usedPercent: Int
            if authorization == "Bearer alpha-access-token" {
                alphaRequestStarted.signal()
                _ = releaseAlphaResponse.wait(seconds: 3)
                usedPercent = 11
            } else {
                XCTAssertEqual(authorization, "Bearer beta-access-token")
                usedPercent = 72
            }
            let data = Data("""
            {
              "rate_limit": {
                "primary_window": {
                  "used_percent": \(usedPercent),
                  "reset_at": 1781788782,
                  "limit_window_seconds": 18000
                }
              }
            }
            """.utf8)
            return (response, data)
        }
        defer {
            releaseAlphaResponse.signal()
            CodexRateLimitFetcherURLProtocol.handler = nil
        }

        let defaults = UserDefaults.standard
        let originalMonitoring = defaults.object(forKey: "isCodexDesktopMonitoringEnabled")
        defaults.set(false, forKey: "isCodexDesktopMonitoringEnabled")
        defer {
            if let originalMonitoring {
                defaults.set(originalMonitoring, forKey: "isCodexDesktopMonitoringEnabled")
            } else {
                defaults.removeObject(forKey: "isCodexDesktopMonitoringEnabled")
            }
        }

        let model = MenuBarStatusModel(
            store: fixture.store,
            codexDesktopActivityMonitor: CodexDesktopActivityMonitor(replaysInitialHistory: false),
            codexAccountManager: manager,
            codexUsageSnapshotStore: CodexAccountUsageSnapshotStore(fileURL: usageStoreURL),
            codexRateLimitFetcher: CodexRateLimitFetcher(
                environment: ["CODEX_HOME": fixture.directory.path],
                session: session,
                clock: { now }
            )
        )
        model.codexUsageDataSource = .oauthAPI
        model.isCodexDesktopMonitoringEnabled = true
        model.isMonitoringPaused = false

        model.pollCodexRateLimitsIfNeeded(force: true)
        var didStartAlphaRequest = false
        for _ in 0..<100 {
            if alphaRequestStarted.tryConsumeSignal() {
                didStartAlphaRequest = true
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(didStartAlphaRequest)

        model.switchCodexAccount(beta)
        releaseAlphaResponse.signal()

        for _ in 0..<200 {
            if !model.isCodexRateLimitFetchInFlight,
               model.codexActiveSavedAccountID == beta.id,
               model.latestAgentQuota?.usedPercent == 72 {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertEqual(model.codexActiveSavedAccountID, beta.id)
        XCTAssertEqual(model.latestAgentQuota?.usedPercent ?? -1, 72, accuracy: 0.01)
        XCTAssertEqual(model.codexUsageFetchState?.source, .oauth)
        XCTAssertNotEqual(model.latestAgentQuota?.usedPercent, 11)
    }

    @MainActor
    func testCodexResetCreditsFailureKeepsCachedInventoryAndNextSuccessClearsError() async throws {
        let fixture = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        try Data("""
        {
          "tokens": {
            "access_token": "oauth-reset-token",
            "refresh_token": ""
          }
        }
        """.utf8).write(to: fixture.directory.appendingPathComponent("auth.json"))

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CodexRateLimitFetcherURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let usageResponse = Data("""
        {
          "rate_limit": {
            "primary_window": {
              "used_percent": 22,
              "reset_at": 1781788782,
              "limit_window_seconds": 18000
            }
          }
        }
        """.utf8)
        let twoCreditsResponse = Data("""
        {
          "credits": [
            {
              "id": "one",
              "reset_type": "codex_rate_limits",
              "status": "available",
              "granted_at": "2026-07-01T00:00:00Z",
              "expires_at": "2026-07-30T00:00:00Z"
            },
            {
              "id": "two",
              "reset_type": "codex_rate_limits",
              "status": "available",
              "granted_at": "2026-07-02T00:00:00Z",
              "expires_at": "2026-07-31T00:00:00Z"
            }
          ],
          "available_count": 2
        }
        """.utf8)
        CodexRateLimitFetcherURLProtocol.handler = { request in
            let isResetCredits = request.url?.path.contains("rate-limit-reset-credits") == true
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, isResetCredits ? twoCreditsResponse : usageResponse)
        }
        defer { CodexRateLimitFetcherURLProtocol.handler = nil }

        let manager = CodexAccountManager(
            environment: ["CODEX_HOME": fixture.directory.path],
            fileManager: .default,
            storeURL: fixture.directory.appendingPathComponent("accounts.json"),
            credentialStore: RecordingSecretStore()
        )
        _ = try manager.saveCurrentAccount()
        let model = MenuBarStatusModel(
            store: fixture.store,
            codexDesktopActivityMonitor: CodexDesktopActivityMonitor(replaysInitialHistory: false),
            codexAccountManager: manager,
            codexRateLimitFetcher: CodexRateLimitFetcher(
                environment: ["CODEX_HOME": fixture.directory.path],
                session: session
            )
        )
        model.appLanguage = .english
        model.codexUsageDataSource = .oauthAPI
        model.codexOpenAICookieMode = .automatic
        model.isCodexDesktopMonitoringEnabled = true
        model.isMonitoringPaused = false

        model.pollCodexRateLimitsIfNeeded(force: true)
        for _ in 0..<100 {
            if !model.isCodexRateLimitFetchInFlight,
               model.latestCodexResetCredits?.availableCount == 2 {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertEqual(model.codexUsageFetchState?.source, .oauth)
        XCTAssertEqual(model.latestCodexResetCredits?.availableCount, 2)
        XCTAssertNil(model.codexResetCreditsFetchState?.errorMessage)
        XCTAssertFalse(model.codexResetCreditsFetchState?.isStale ?? true)

        CodexRateLimitFetcherURLProtocol.handler = { request in
            let isResetCredits = request.url?.path.contains("rate-limit-reset-credits") == true
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: isResetCredits ? 500 : 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, isResetCredits ? Data() : usageResponse)
        }
        model.pollCodexRateLimitsIfNeeded(force: true)
        for _ in 0..<100 {
            if !model.isCodexRateLimitFetchInFlight,
               model.codexResetCreditsFetchState?.errorMessage != nil {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertEqual(model.latestCodexResetCredits?.availableCount, 2)
        XCTAssertNotNil(model.codexResetCreditsFetchState?.errorMessage)
        XCTAssertTrue(model.codexResetCreditsFetchState?.isStale ?? false)
        XCTAssertNil(model.codexUsageFetchState?.errorMessage)

        let zeroCreditsResponse = Data("""
        {
          "credits": [],
          "available_count": 0
        }
        """.utf8)
        CodexRateLimitFetcherURLProtocol.handler = { request in
            let isResetCredits = request.url?.path.contains("rate-limit-reset-credits") == true
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, isResetCredits ? zeroCreditsResponse : usageResponse)
        }
        model.pollCodexRateLimitsIfNeeded(force: true)
        for _ in 0..<100 {
            if !model.isCodexRateLimitFetchInFlight,
               model.latestCodexResetCredits?.availableCount == 0,
               model.codexResetCreditsFetchState?.errorMessage == nil {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertEqual(model.latestCodexResetCredits?.availableCount, 0)
        XCTAssertNil(model.codexResetCreditsFetchState?.errorMessage)
        XCTAssertFalse(model.codexResetCreditsFetchState?.isStale ?? true)
        XCTAssertEqual(model.codexResetCreditsPresentation()?.availableText, "0 available")
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
        let model = makeMenuBarStatusModel()
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

    @MainActor
    func testPermissionToolCallSubtitleShowsStatusInsteadOfRunningStep() {
        let model = makeMenuBarStatusModel()
        model.appLanguage = .zhHans
        let session = SessionStatus(
            sessionID: "codex-desktop:thread",
            signal: .permissionRequest,
            updatedAt: Date(),
            agent: "codex-desktop",
            lastEvent: "DesktopToolCall:exec_command"
        )

        XCTAssertEqual(model.activitySessionStatusSubtitle(for: session), "等待授权 · exec_command")
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

        let model = makeMenuBarStatusModel()
        model.setAppLanguage(.zhHans)
        XCTAssertEqual(model.displayName(for: SignalLightAgentScope.claudeCode), "Claude 桌面版")
    }

    @MainActor
    func testCodexCLISessionKeepsTerminalRuntimeForDesktopNamedEvents() {
        let model = makeMenuBarStatusModel()
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

    private func codexResetCreditsFixture(
        count: Int,
        updatedAt: TimeInterval,
        lifetimeDays: Int = 1
    ) -> CodexRateLimitResetCreditsSnapshot {
        let updatedAtDate = Date(timeIntervalSince1970: updatedAt)
        return CodexRateLimitResetCreditsSnapshot(
            credits: (0..<count).map { index in
                CodexRateLimitResetCredit(
                    status: .available,
                    grantedAt: updatedAtDate,
                    expiresAt: updatedAtDate.addingTimeInterval(Double(index + lifetimeDays) * 86_400)
                )
            },
            availableCount: count,
            updatedAt: updatedAtDate
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

@MainActor
private func makeMenuBarStatusModel(
    store: SignalStateStore = SignalStateStore()
) -> MenuBarStatusModel {
    MenuBarStatusModel(
        store: store,
        codexAccountManager: EmptyCodexAccountManager()
    )
}

private final class ExecutablePathFileManager: FileManager, @unchecked Sendable {
    private let testHomeDirectory: URL
    private let executablePaths: Set<String>

    init(homeDirectory: URL, executablePaths: Set<String>) {
        self.testHomeDirectory = homeDirectory
        self.executablePaths = executablePaths
        super.init()
    }

    override var homeDirectoryForCurrentUser: URL {
        testHomeDirectory
    }

    override func isExecutableFile(atPath path: String) -> Bool {
        executablePaths.contains(path)
    }
}

private final class TestDateClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        value = value.addingTimeInterval(interval)
        lock.unlock()
    }
}

private func testTokenScanWatermark(
    sessionID: String,
    eventAt: Date,
    totalTokens: Int,
    ordinal: UInt64 = 1
) -> CodexTokenActivityScanWatermark {
    CodexTokenActivityScanWatermark(
        sessionID: sessionID,
        sourceID: "/test/\(sessionID).jsonl",
        sourceGeneration: "test-generation",
        endOffset: ordinal,
        lineFingerprint: "test-\(ordinal)",
        eventTimestamp: eventAt,
        totalTokens: totalTokens
    )
}

private final class ControlledCodexTokenActivityScanner: CodexTokenActivityScanning, @unchecked Sendable {
    typealias DaysProvider = (Date) -> [CodexTokenActivityDay]?
    typealias IndexedDaysProvider = (Date, Int) -> [CodexTokenActivityDay]?
    typealias IndexedResultProvider = (Date, Int) -> CodexTokenActivityScanResult?

    private let cachedDaysProvider: DaysProvider
    private let scannedResultProvider: IndexedResultProvider
    private let scanStarted = DispatchSemaphore(value: 0)
    private let scanFinished = DispatchSemaphore(value: 0)
    private let cacheCleared = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var recordedScanCallCount = 0
    private var recordedClearCacheCallCount = 0

    init(
        cachedDays: @escaping DaysProvider,
        scannedDays: @escaping DaysProvider
    ) {
        self.cachedDaysProvider = cachedDays
        self.scannedResultProvider = { now, _ in
            scannedDays(now).map { CodexTokenActivityScanResult(days: $0, watermarks: []) }
        }
    }

    init(
        cachedDays: @escaping DaysProvider,
        scannedDaysByCall: @escaping IndexedDaysProvider
    ) {
        self.cachedDaysProvider = cachedDays
        self.scannedResultProvider = { now, callIndex in
            scannedDaysByCall(now, callIndex).map {
                CodexTokenActivityScanResult(days: $0, watermarks: [])
            }
        }
    }

    init(
        cachedDays: @escaping DaysProvider,
        scannedResultsByCall: @escaping IndexedResultProvider
    ) {
        self.cachedDaysProvider = cachedDays
        self.scannedResultProvider = scannedResultsByCall
    }

    var scanCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedScanCallCount
    }

    var clearCacheCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedClearCacheCallCount
    }

    func clearCache() {
        lock.lock()
        recordedClearCacheCallCount += 1
        lock.unlock()
        cacheCleared.signal()
    }

    func cachedDailyActivity(now: Date, days _: Int) -> [CodexTokenActivityDay]? {
        cachedDaysProvider(now)
    }

    func scanDailyActivity(
        now: Date,
        days _: Int,
        progress: (([CodexTokenActivityDay]) -> Void)?
    ) -> [CodexTokenActivityDay] {
        let result = performScan(now: now)
        progress?(result.days)
        return result.days
    }

    func scanDailyActivityResult(
        now: Date,
        days _: Int,
        progress: (([CodexTokenActivityDay]) -> Void)?
    ) -> CodexTokenActivityScanResult {
        let result = performScan(now: now)
        progress?(result.days)
        return result
    }

    private func performScan(now: Date) -> CodexTokenActivityScanResult {
        lock.lock()
        recordedScanCallCount += 1
        let callIndex = recordedScanCallCount
        lock.unlock()
        scanStarted.signal()
        scanFinished.wait()
        return scannedResultProvider(now, callIndex)
            ?? CodexTokenActivityScanResult(days: [], watermarks: [])
    }

    func waitUntilScanStarts(seconds: TimeInterval) -> Bool {
        scanStarted.wait(timeout: .now() + seconds) == .success
    }

    func finishScan() {
        scanFinished.signal()
    }

    func waitUntilCacheClears(seconds: TimeInterval) -> Bool {
        cacheCleared.wait(timeout: .now() + seconds) == .success
    }
}

private final class EmptyCodexAccountManager: CodexAccountManaging, @unchecked Sendable {
    private let state = CodexAccountState(
        currentAccount: nil,
        savedAccounts: [],
        activeSavedAccountID: nil
    )

    func loadState() throws -> CodexAccountState {
        state
    }

    func loadMetadataState() throws -> CodexAccountState {
        state
    }

    func saveCurrentAccount(label _: String?) throws -> CodexAccountProfile {
        throw CodexAccountManagerError.accountNotFound
    }

    func switchToAccount(id _: UUID) throws -> CodexAccountProfile {
        throw CodexAccountManagerError.accountNotFound
    }

    func authenticateManagedAccount(timeout _: TimeInterval) async throws -> CodexAccountProfile {
        throw CodexAccountManagerError.accountNotFound
    }

    func removeAccount(id _: UUID) throws {}

    func refreshSavedCurrentAccountIfPossible() throws -> CodexAccountProfile? {
        nil
    }
}

private final class FailingCodexAccountManager: CodexAccountManaging, @unchecked Sendable {
    private let error: CodexAccountManagerError
    private let state = CodexAccountState(
        currentAccount: nil,
        savedAccounts: [],
        activeSavedAccountID: nil
    )

    init(_ error: CodexAccountManagerError) {
        self.error = error
    }

    func loadState() throws -> CodexAccountState {
        state
    }

    func loadMetadataState() throws -> CodexAccountState {
        state
    }

    func saveCurrentAccount(label _: String?) throws -> CodexAccountProfile {
        throw error
    }

    func switchToAccount(id _: UUID) throws -> CodexAccountProfile {
        throw error
    }

    func authenticateManagedAccount(timeout _: TimeInterval) async throws -> CodexAccountProfile {
        throw error
    }

    func removeAccount(id _: UUID) throws {
        throw error
    }

    func refreshSavedCurrentAccountIfPossible() throws -> CodexAccountProfile? {
        nil
    }
}

private final class CountingCodexAccountManager: CodexAccountManaging, @unchecked Sendable {
    var fullLoadCount = 0
    var metadataLoadCount = 0
    var refreshSavedCurrentAccountCount = 0

    func loadState() throws -> CodexAccountState {
        fullLoadCount += 1
        return emptyState
    }

    func loadMetadataState() throws -> CodexAccountState {
        metadataLoadCount += 1
        return emptyState
    }

    func saveCurrentAccount(label _: String?) throws -> CodexAccountProfile {
        throw CodexAccountManagerError.accountNotFound
    }

    func switchToAccount(id _: UUID) throws -> CodexAccountProfile {
        throw CodexAccountManagerError.accountNotFound
    }

    func authenticateManagedAccount(timeout _: TimeInterval) async throws -> CodexAccountProfile {
        throw CodexAccountManagerError.accountNotFound
    }

    func removeAccount(id _: UUID) throws {}

    func refreshSavedCurrentAccountIfPossible() throws -> CodexAccountProfile? {
        refreshSavedCurrentAccountCount += 1
        return nil
    }

    private var emptyState: CodexAccountState {
        CodexAccountState(
            currentAccount: nil,
            savedAccounts: [],
            activeSavedAccountID: nil
        )
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

private final class URLRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedRequests: [URLRequest] = []

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    func append(_ request: URLRequest) {
        lock.lock()
        recordedRequests.append(request)
        lock.unlock()
    }
}

private final class TestSemaphoreGate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)

    func signal() {
        semaphore.signal()
    }

    func tryConsumeSignal() -> Bool {
        semaphore.wait(timeout: .now()) == .success
    }

    func wait(seconds: TimeInterval) -> Bool {
        semaphore.wait(timeout: .now() + seconds) == .success
    }
}

private struct FakeOpenAIBrowserCookieImporter: OpenAIBrowserCookieImporting {
    let cookieHeader: String?

    func importCookieHeader(targetEmail _: String?) async -> OpenAIBrowserCookieImportResult? {
        guard let cookieHeader else { return nil }
        return OpenAIBrowserCookieImportResult(
            cookieHeader: cookieHeader,
            sourceLabel: "Test",
            debugLog: "test"
        )
    }
}

private final class RecordingOpenAIBrowserCookieImporter: OpenAIBrowserCookieImporting, @unchecked Sendable {
    private let lock = NSLock()
    private let cookieHeader: String?
    private var calls = 0

    init(cookieHeader: String?) {
        self.cookieHeader = cookieHeader
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func importCookieHeader(targetEmail _: String?) async -> OpenAIBrowserCookieImportResult? {
        recordCall()
        guard let cookieHeader else { return nil }
        return OpenAIBrowserCookieImportResult(
            cookieHeader: cookieHeader,
            sourceLabel: "Test",
            debugLog: "test"
        )
    }

    private func recordCall() {
        lock.lock()
        calls += 1
        lock.unlock()
    }
}

private final class RecordingSecretStore: SecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var failsSetOperations = false
    private(set) var dataReadKeys: [String] = []
    private(set) var setKeys: [String] = []
    private(set) var deletedKeys: [String] = []

    func data(for key: String) throws -> Data? {
        lock.withLock {
            dataReadKeys.append(key)
            return values[key]
        }
    }

    func string(for key: String) throws -> String? {
        guard let data = try data(for: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func set(_ data: Data, for key: String) throws {
        try lock.withLock {
            if failsSetOperations {
                throw RecordingSecretStoreError.forcedSetFailure
            }
            setKeys.append(key)
            values[key] = data
        }
    }

    func set(_ string: String, for key: String) throws {
        try set(Data(string.utf8), for: key)
    }

    func delete(key: String) throws {
        lock.withLock {
            deletedKeys.append(key)
            values.removeValue(forKey: key)
        }
    }

    func resetRecordedCalls() {
        lock.withLock {
            dataReadKeys.removeAll()
            setKeys.removeAll()
            deletedKeys.removeAll()
        }
    }

    func setFailsSetOperations(_ enabled: Bool) {
        lock.withLock {
            failsSetOperations = enabled
        }
    }
}

private enum RecordingSecretStoreError: Error {
    case forcedSetFailure
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

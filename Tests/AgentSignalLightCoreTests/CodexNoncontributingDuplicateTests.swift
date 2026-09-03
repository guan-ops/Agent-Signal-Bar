import Foundation
import XCTest
@testable import AgentSignalLight

final class CodexNoncontributingDuplicateTests: XCTestCase {
    func testInterruptedNullUsageCopyDoesNotHideTheContributingCopy() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let empty = try fixture.writeInterrupted("a-empty", id: "duplicate")
        let contributing = try fixture.writeUsage("z-usage", id: "duplicate", total: 300)
        let emptyBefore = try Data(contentsOf: empty)
        let contributingBefore = try Data(contentsOf: contributing)
        XCTAssertLessThan(emptyBefore.count, contributingBefore.count)

        let report = try fixture.scan()

        XCTAssertEqual(report.summary?.totalTokens, 300)
        XCTAssertTrue(report.warnings.isEmpty)
        let copies = try fixture.cache().files.values.filter { $0.sessionId == "duplicate" }
        XCTAssertEqual(copies.count, 2)
        XCTAssertEqual(copies.filter { $0.codexInventoryOnly != true }.count, 1)
        XCTAssertFalse(copies.contains { $0.codexIdentityConflict == true })
        XCTAssertEqual(try Data(contentsOf: empty), emptyBefore)
        XCTAssertEqual(try Data(contentsOf: contributing), contributingBefore)
    }

    func testRescansAndReloadedCacheKeepOnlyOneContribution() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.writeInterrupted("a-empty", id: "duplicate")
        _ = try fixture.writeUsage("z-usage", id: "duplicate", total: 300)

        for _ in 0..<3 {
            let report = try fixture.scan()
            XCTAssertEqual(report.summary?.totalTokens, 300)
            XCTAssertTrue(report.warnings.isEmpty)
            // Decode the on-disk cache each time, rather than relying on an
            // in-memory scan result to prove relaunch behavior.
            let reloaded = try fixture.cache()
            let cachedReport = CostUsageScanner.buildCodexReportFromCache(
                cache: reloaded,
                range: CostUsageScanner.CostUsageDayRange(
                    since: Calendar.current.startOfDay(for: fixture.now), until: fixture.now
                ),
                modelsDevCacheRoot: fixture.cacheRoot
            )
            XCTAssertEqual(cachedReport.summary?.totalTokens, 300)
            XCTAssertTrue(cachedReport.warnings.isEmpty)
            XCTAssertEqual(
                reloaded.files.values.filter {
                    $0.sessionId == "duplicate" && $0.codexInventoryOnly != true
                }.count,
                1
            )
        }
    }

    func testFormerlyEmptyCopyGainingUsageRevokesThePreviouslyCountedOwner() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let empty = try fixture.writeInterrupted("a-empty", id: "duplicate")
        let contributing = try fixture.writeUsage("z-usage", id: "duplicate", total: 300)
        _ = try fixture.writeUsage("healthy", id: "healthy", total: 100)
        XCTAssertEqual(try fixture.scan().summary?.totalTokens, 400)
        let contributingBefore = try Data(contentsOf: contributing)
        try fixture.append(
            Fixture.tokenEvent(total: 200, timestamp: "2026-09-02T08:20:00Z") + "\n",
            to: empty
        )
        let extendedCopy = try Data(contentsOf: empty)

        for _ in 0..<2 {
            let report = try fixture.scan()
            XCTAssertEqual(report.summary?.totalTokens, 100)
            assertConflict(report, sessionID: "duplicate", sources: [empty, contributing])
            let copies = try fixture.cache().files.values.filter { $0.sessionId == "duplicate" }
            XCTAssertEqual(copies.count, 2)
            XCTAssertTrue(copies.allSatisfy {
                $0.codexIdentityConflict == true && $0.codexInventoryOnly == true && $0.days.isEmpty
            })
            XCTAssertFalse(copies.contains { $0.codexDuplicateQuarantined == true })
            XCTAssertTrue(copies.allSatisfy { $0.lastTokenEventEndOffset == nil })
        }
        XCTAssertEqual(try Data(contentsOf: empty), extendedCopy)
        XCTAssertEqual(try Data(contentsOf: contributing), contributingBefore)
    }

    func testTwoInitiallyContributingDivergentCopiesRemainAConflict() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try fixture.writeUsage("first", id: "duplicate", total: 200)
        let second = try fixture.writeUsage("second", id: "duplicate", total: 300)
        _ = try fixture.writeUsage("healthy", id: "healthy", total: 100)

        let report = try fixture.scan()

        XCTAssertEqual(report.summary?.totalTokens, 100)
        assertConflict(report, sessionID: "duplicate", sources: [first, second])
        let copies = try fixture.cache().files.values.filter { $0.sessionId == "duplicate" }
        XCTAssertTrue(copies.allSatisfy { $0.codexIdentityConflict == true && $0.days.isEmpty })
    }

    func testMalformedOrIncompleteCopyCannotBeProvenNoncontributing() throws {
        let invalidTails = [
            "{this is not valid JSON}\n",
            #"{"type":"event_msg","payload":{"type":"token_count","info":"#,
        ]
        for invalidTail in invalidTails {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let invalid = try fixture.writeInterrupted("a-invalid", id: "duplicate")
            try fixture.append(invalidTail, to: invalid)
            let contributing = try fixture.writeUsage("z-usage", id: "duplicate", total: 300)
            _ = try fixture.writeUsage("healthy", id: "healthy", total: 100)
            let invalidBefore = try Data(contentsOf: invalid)

            let report = try fixture.scan()

            XCTAssertEqual(report.summary?.totalTokens, 100)
            assertConflict(report, sessionID: "duplicate", sources: [invalid, contributing])
            XCTAssertEqual(try Data(contentsOf: invalid), invalidBefore)
        }
    }

    func testDifferentForkParentsPreventNoncontributingDuplicateElision() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let empty = try fixture.writeInterrupted("a-empty", id: "duplicate", forkedFrom: "parent-a")
        let contributing = try fixture.writeUsage(
            "z-usage", id: "duplicate", total: 300, forkedFrom: "parent-b"
        )
        _ = try fixture.writeUsage("healthy", id: "healthy", total: 100)

        let report = try fixture.scan()

        XCTAssertEqual(report.summary?.totalTokens, 100)
        assertConflict(report, sessionID: "duplicate", sources: [empty, contributing])
    }

    func testForkBaselineUsesContributingParentInsteadOfEmptyDuplicate() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        // Put the empty copy first lexically so selecting the first matching
        // ID cannot accidentally satisfy the inherited-usage assertion.
        _ = try fixture.writeInterrupted("a-empty-parent", id: "parent")
        _ = try fixture.writeUsage("z-contributing-parent", id: "parent", total: 1_000)
        let child = try fixture.writeUsage(
            "b-child", id: "child", total: 1_000, forkedFrom: "parent",
            metadataTimestamp: "2026-09-02T08:10:00Z", eventTimestamp: "2026-09-02T08:11:00Z"
        )
        try fixture.append(
            Fixture.tokenEvent(total: 1_050, timestamp: "2026-09-02T08:12:00Z") + "\n",
            to: child
        )

        for _ in 0..<2 {
            let report = try fixture.scan()
            XCTAssertEqual(report.summary?.totalTokens, 1_050)
            XCTAssertTrue(report.warnings.isEmpty)
            let childUsage = try XCTUnwrap(fixture.cache().files.values.first { $0.sessionId == "child" })
            let childTokens = childUsage.days.values.reduce(0) { daySum, models in
                daySum + models.values.reduce(0) { modelSum, packed in
                    modelSum + (packed.first ?? 0) + (packed.count > 2 ? packed[2] : 0)
                }
            }
            XCTAssertEqual(childTokens, 50)
        }
    }

    func testContributingOwnerAppendCountsOnlyTheIncrementWithoutWarning() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let empty = try fixture.writeInterrupted("a-empty", id: "duplicate")
        let owner = try fixture.writeUsage("z-usage", id: "duplicate", total: 300)
        XCTAssertEqual(try fixture.scan().summary?.totalTokens, 300)
        let emptyBefore = try Data(contentsOf: empty)
        try fixture.append(
            Fixture.tokenEvent(total: 450, timestamp: "2026-09-02T08:20:00Z") + "\n",
            to: owner
        )

        for _ in 0..<2 {
            let report = try fixture.scan()
            XCTAssertEqual(report.summary?.totalTokens, 450)
            XCTAssertTrue(report.warnings.isEmpty)
        }
        XCTAssertEqual(try Data(contentsOf: empty), emptyBefore)
    }

    func testPreviouslyCommittedEmptyOwnerYieldsToANewContributingCopy() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let empty = try fixture.writeInterrupted("a-empty", id: "duplicate")
        let initial = try fixture.scan()
        XCTAssertEqual(initial.summary?.totalTokens ?? 0, 0)
        XCTAssertTrue(initial.warnings.isEmpty)
        let committedOwner = try XCTUnwrap(fixture.cache().files.values.first { $0.sessionId == "duplicate" })
        XCTAssertNotEqual(committedOwner.codexInventoryOnly, true)
        XCTAssertTrue(committedOwner.days.isEmpty)
        let emptyBefore = try Data(contentsOf: empty)
        _ = try fixture.writeUsage("z-new-usage", id: "duplicate", total: 300)

        for _ in 0..<2 {
            let report = try fixture.scan()
            XCTAssertEqual(report.summary?.totalTokens, 300)
            XCTAssertTrue(report.warnings.isEmpty)
            let owners = try fixture.cache().files.values.filter {
                $0.sessionId == "duplicate" && $0.codexInventoryOnly != true
            }
            XCTAssertEqual(owners.count, 1)
            XCTAssertFalse(try XCTUnwrap(owners.first).days.isEmpty)
        }
        XCTAssertEqual(try Data(contentsOf: empty), emptyBefore)
    }

    func testCompleteNonusageAppendReprovesTheEmptyCopy() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let empty = try fixture.writeInterrupted("a-empty", id: "duplicate")
        _ = try fixture.writeUsage("z-usage", id: "duplicate", total: 300)
        XCTAssertEqual(try fixture.scan().summary?.totalTokens, 300)
        try fixture.append(
            #"{"timestamp":"2026-09-02T08:20:00Z","type":"event_msg","payload":{"type":"agent_message","message":"Still no recorded token usage."}}"# + "\n",
            to: empty
        )
        let extendedCopy = try Data(contentsOf: empty)

        for _ in 0..<2 {
            let report = try fixture.scan()
            XCTAssertEqual(report.summary?.totalTokens, 300)
            XCTAssertTrue(report.warnings.isEmpty)
            let proof = try XCTUnwrap(fixture.cache().files.first {
                URL(fileURLWithPath: $0.key).standardizedFileURL.resolvingSymlinksInPath() == empty
            }?.value)
            XCTAssertEqual(proof.codexNoncontributingDuplicate, true)
            XCTAssertEqual(proof.parsedBytes, Int64(extendedCopy.count))
            XCTAssertEqual(proof.size, Int64(extendedCopy.count))
        }
        XCTAssertEqual(try Data(contentsOf: empty), extendedCopy)
    }

    func testUsageAppendBeforeCommitRejectsTheScanWithoutChangingCommittedCache() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let empty = try fixture.writeInterrupted("a-empty", id: "duplicate")
        let owner = try fixture.writeUsage("z-usage", id: "duplicate", total: 300)
        XCTAssertEqual(try fixture.scan().summary?.totalTokens, 300)
        let committedBytes = try Data(contentsOf: fixture.cacheURL)
        // This addition triggers a normal inventory. The hook then appends to
        // an existing file only, which does not invalidate directory mtimes.
        _ = try fixture.writeUsage("healthy", id: "healthy", total: 100)
        var didRunHook = false

        XCTAssertThrowsError(try fixture.scan(beforeCommit: {
            didRunHook = true
            try fixture.append(
                Fixture.tokenEvent(total: 200, timestamp: "2026-09-02T08:20:00Z") + "\n",
                to: empty
            )
        }))

        XCTAssertTrue(didRunHook)
        XCTAssertEqual(try Data(contentsOf: fixture.cacheURL), committedBytes)
        let recovered = try fixture.scan()
        XCTAssertEqual(recovered.summary?.totalTokens, 100)
        assertConflict(recovered, sessionID: "duplicate", sources: [empty, owner])
    }

    func testSameParentWithDifferentForkTimestampsRemainsAConflict() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let empty = try fixture.writeInterrupted("a-empty", id: "duplicate", forkedFrom: "parent")
        let owner = try fixture.writeUsage(
            "z-usage", id: "duplicate", total: 300, forkedFrom: "parent",
            metadataTimestamp: "2026-09-02T07:59:58Z"
        )
        _ = try fixture.writeUsage("healthy", id: "healthy", total: 100)

        let report = try fixture.scan()

        XCTAssertEqual(report.summary?.totalTokens, 100)
        assertConflict(report, sessionID: "duplicate", sources: [empty, owner])
    }

    func testLegacyConflictCacheWithoutPolicyMarkerReevaluatesUnchangedLogs() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let empty = try fixture.writeInterrupted("a-empty", id: "duplicate")
        let owner = try fixture.writeUsage("z-usage", id: "duplicate", total: 300)
        XCTAssertEqual(try fixture.scan().summary?.totalTokens, 300)
        let emptyBefore = try Data(contentsOf: empty)
        let ownerBefore = try Data(contentsOf: owner)
        var legacy = try fixture.cache()
        XCTAssertEqual(legacy.codexSessionInventoryComplete, true)
        // Recreate v16's conflict-only records while preserving the exact
        // current source and directory snapshots. Do not mutate either log.
        legacy.files = legacy.files.mapValues { usage in
            CostUsageScanner.makeFileUsage(
                mtimeUnixMs: usage.mtimeUnixMs, size: usage.size, days: [:], parsedBytes: 0,
                sessionId: usage.sessionId, forkedFromId: usage.forkedFromId,
                sourceGeneration: usage.sourceGeneration,
                sourceStatFingerprint: usage.sourceStatFingerprint,
                sourceChangeTimeNanoseconds: usage.sourceChangeTimeNanoseconds,
                codexInventoryOnly: true, codexIdentityConflict: true
            )
        }
        legacy.days = [:]
        legacy.codexIdentityPolicyVersion = nil
        legacy.codexNoncontributingSessionIDs = nil
        legacy.codexScanWarnings = [CostUsageScanWarning(
            reason: .ambiguousSessionIdentity, sessionID: "duplicate", sourcePaths: [empty.path, owner.path]
        )]
        try CostUsageCacheIO.save(provider: .codex, cache: legacy, cacheRoot: fixture.cacheRoot)
        XCTAssertNil(try fixture.cache().codexIdentityPolicyVersion)

        let report = try fixture.scan()

        XCTAssertEqual(report.summary?.totalTokens, 300)
        XCTAssertTrue(report.warnings.isEmpty)
        XCTAssertEqual(try fixture.cache().codexIdentityPolicyVersion, CostUsageScanner.codexIdentityPolicyVersion)
        XCTAssertEqual(try Data(contentsOf: empty), emptyBefore)
        XCTAssertEqual(try Data(contentsOf: owner), ownerBefore)
    }

    func testRecoveredParentRecalculatesAlreadyCachedChildForkBaseline() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let invalidParent = try fixture.writeInterrupted("a-empty-parent", id: "parent")
        try fixture.append("{broken JSON}\n", to: invalidParent)
        let owner = try fixture.writeUsage("z-contributing-parent", id: "parent", total: 1_000)
        let child = try fixture.writeUsage(
            "b-child", id: "child", total: 1_050, forkedFrom: "parent",
            metadataTimestamp: "2026-09-02T08:10:00Z", eventTimestamp: "2026-09-02T08:11:00Z"
        )
        _ = try fixture.writeUsage("healthy", id: "healthy", total: 100)
        let initial = try fixture.scan()
        XCTAssertEqual(initial.summary?.totalTokens, 100)
        assertConflict(initial, sessionID: "parent", sources: [invalidParent, owner])
        let cachedChild = try XCTUnwrap(fixture.cache().files.values.first { $0.sessionId == "child" })
        XCTAssertTrue(cachedChild.days.isEmpty)
        XCTAssertNotNil(cachedChild.lastTokenEventEndOffset)
        let childBefore = try Data(contentsOf: child)
        _ = try fixture.writeInterrupted("a-empty-parent", id: "parent")

        for _ in 0..<2 {
            let report = try fixture.scan()
            XCTAssertEqual(report.summary?.totalTokens, 1_150)
            XCTAssertTrue(report.warnings.isEmpty)
            let recalculated = try XCTUnwrap(fixture.cache().files.values.first { $0.sessionId == "child" })
            let childTokens = recalculated.days.values.reduce(0) { daySum, models in
                daySum + models.values.reduce(0) { modelSum, packed in
                    modelSum + (packed.first ?? 0) + (packed.count > 2 ? packed[2] : 0)
                }
            }
            XCTAssertEqual(childTokens, 50)
        }
        XCTAssertEqual(try Data(contentsOf: child), childBefore)
    }

    func testNewContributingParentRecalculatesChildEvenWithoutWarningTransition() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.writeInterrupted("a-empty-parent", id: "parent")
        let child = try fixture.writeUsage(
            "b-child", id: "child", total: 1_050, forkedFrom: "parent",
            metadataTimestamp: "2026-09-02T08:10:00Z", eventTimestamp: "2026-09-02T08:11:00Z"
        )
        let initial = try fixture.scan()
        XCTAssertEqual(initial.summary?.totalTokens, 1_050)
        XCTAssertTrue(initial.warnings.isEmpty)
        let initialChild = try XCTUnwrap(fixture.cache().files.values.first { $0.sessionId == "child" })
        let initialChildTokens = initialChild.days.values.reduce(0) { daySum, models in
            daySum + models.values.reduce(0) { modelSum, packed in
                modelSum + (packed.first ?? 0) + (packed.count > 2 ? packed[2] : 0)
            }
        }
        XCTAssertEqual(initialChildTokens, 1_050)
        let childBefore = try Data(contentsOf: child)
        _ = try fixture.writeUsage("z-contributing-parent", id: "parent", total: 1_000)

        // Both inventories are warning-free. Replacing a previously empty
        // parent still changes the baseline used by the untouched child.
        for _ in 0..<2 {
            let report = try fixture.scan()
            XCTAssertEqual(report.summary?.totalTokens, 1_050)
            XCTAssertTrue(report.warnings.isEmpty)
            let recalculated = try XCTUnwrap(fixture.cache().files.values.first { $0.sessionId == "child" })
            let childTokens = recalculated.days.values.reduce(0) { daySum, models in
                daySum + models.values.reduce(0) { modelSum, packed in
                    modelSum + (packed.first ?? 0) + (packed.count > 2 ? packed[2] : 0)
                }
            }
            XCTAssertEqual(childTokens, 50)
        }
        XCTAssertEqual(try Data(contentsOf: child), childBefore)
    }

    private func assertConflict(
        _ report: CostUsageDailyReport,
        sessionID: String,
        sources: [URL],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let normalizedWarnings = report.warnings.map { warning in
            CostUsageScanWarning(
                reason: warning.reason, sessionID: warning.sessionID,
                sourcePaths: warning.sourcePaths.map {
                    URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path
                }
            )
        }
        XCTAssertEqual(
            normalizedWarnings,
            [CostUsageScanWarning(
                reason: .ambiguousSessionIdentity, sessionID: sessionID,
                sourcePaths: sources.map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
            )],
            file: file, line: line
        )
    }

    private struct Fixture {
        let root: URL
        let sessions: URL
        let cacheRoot: URL
        let now = ISO8601DateFormatter().date(from: "2026-09-02T09:00:00Z")!
        var cacheURL: URL { CostUsageCacheIO.cacheFileURL(provider: .codex, cacheRoot: cacheRoot) }

        init() throws {
            root = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
                .appendingPathComponent("codex-noncontributing-duplicate-\(UUID().uuidString)", isDirectory: true)
            sessions = root.appendingPathComponent("sessions", isDirectory: true)
            cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
            try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }

        func writeInterrupted(_ name: String, id: String, forkedFrom: String? = nil) throws -> URL {
            try write(name, lines: [
                metadata(id: id, originator: name, forkedFrom: forkedFrom),
                #"{"timestamp":"2026-09-02T08:00:00Z","type":"event_msg","payload":{"type":"token_count","info":null}}"#,
                #"{"timestamp":"2026-09-02T08:01:00Z","type":"event_msg","payload":{"type":"turn_aborted","reason":"interrupted"}}"#,
            ])
        }

        func writeUsage(
            _ name: String, id: String, total: Int, forkedFrom: String? = nil,
            metadataTimestamp: String = "2026-09-02T07:59:59Z",
            eventTimestamp: String = "2026-09-02T08:00:00Z"
        ) throws -> URL {
            try write(name, lines: [
                metadata(id: id, originator: name, forkedFrom: forkedFrom, timestamp: metadataTimestamp),
                #"{"timestamp":"\#(metadataTimestamp)","type":"turn_context","payload":{"model":"gpt-5","turn_id":"fixture-turn"}}"#,
                Self.tokenEvent(total: total, timestamp: eventTimestamp),
            ])
        }

        private func write(_ name: String, lines: [String]) throws -> URL {
            let url = sessions.appendingPathComponent("rollout-2026-09-02T08-00-00-\(name).jsonl")
            try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            return url.standardizedFileURL.resolvingSymlinksInPath()
        }

        private func metadata(
            id: String, originator: String, forkedFrom: String?, timestamp: String = "2026-09-02T07:59:59Z"
        ) throws -> String {
            var payload: [String: Any] = ["id": id, "originator": originator, "timestamp": timestamp]
            if let forkedFrom { payload["forked_from_id"] = forkedFrom }
            let object: [String: Any] = ["type": "session_meta", "timestamp": timestamp, "payload": payload]
            return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
        }

        static func tokenEvent(total: Int, timestamp: String) -> String {
            // No last_token_usage: the fork case must find the actual parent's
            // totals rather than pass through the explicit-turn fallback.
            #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(total),"output_tokens":0,"total_tokens":\#(total)}}}}"#
        }

        func append(_ text: String, to url: URL) throws {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
        }

        func scan(beforeCommit: (() throws -> Void)? = nil) throws -> CostUsageDailyReport {
            var options = CostUsageScanner.Options(
                codexSessionsRoots: [sessions], cacheRoot: cacheRoot,
                codexTraceDatabaseURL: root.appendingPathComponent("missing-priority.sqlite")
            )
            options.refreshMinIntervalSeconds = 0
            if let beforeCommit {
                options.codexInventoryBeforeCommitHook = {
                    do {
                        try beforeCommit()
                    } catch {
                        XCTFail("Noncontributing duplicate fixture mutation failed: \(error)")
                    }
                }
            }
            return try CostUsageScanner.loadDailyReportCancellable(
                provider: .codex, since: Calendar.current.startOfDay(for: now),
                until: now, now: now, options: options, checkCancellation: nil
            )
        }

        func cache() throws -> CostUsageCache {
            try CostUsageCacheIO.loadRequired(provider: .codex, cacheRoot: cacheRoot)
        }
    }
}

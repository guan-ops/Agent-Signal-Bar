import Foundation
import XCTest
@testable import AgentSignalLight
@testable import AgentSignalLightCore

final class NoncontributingDuplicateWatermarkTests: XCTestCase {
    func testProvenNoncontributingSentinelNeedsNoTokenOwnerAndExportsNoWatermark() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        XCTAssertTrue(try fixture.watermarks().isEmpty)
        let cache = try fixture.cache()
        XCTAssertEqual(cache.files[fixture.source.path]?.codexNoncontributingDuplicate, true)
        XCTAssertTrue(cache.days.isEmpty)
    }

    func testDivergentMetadataSentinelDoesNotExportOwnerAliasOrTombstone() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let owner = try fixture.addTokenOwner()

        let watermarks = try fixture.watermarks()
        XCTAssertEqual(watermarks.count, 1)
        XCTAssertEqual(watermarks.first?.sourceID, owner.path)
        XCTAssertEqual(watermarks.first?.totalTokens, 100)
        XCTAssertFalse(watermarks.contains { $0.sourceID == fixture.source.path })
        XCTAssertFalse(watermarks.contains { $0.endOffset == .max })
    }

    func testAppendAfterProofRejectsExportWithoutChangingCommittedCache() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let committedCache = try Data(contentsOf: fixture.cacheFile)
        let handle = try FileHandle(forWritingTo: fixture.source)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((Fixture.tokenEvent + "\n").utf8))
        try handle.close()

        XCTAssertThrowsError(try fixture.watermarks())
        XCTAssertEqual(try Data(contentsOf: fixture.cacheFile), committedCache)
    }

    func testMatchingMetadataCannotReplaceFullContentProof() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let contents = try String(contentsOf: fixture.source, encoding: .utf8)
        let rewritten = contents.replacingOccurrences(of: "metadata-only", with: "metadata-edit")
        XCTAssertEqual(contents.utf8.count, rewritten.utf8.count)
        XCTAssertNotEqual(contents, rewritten)
        let handle = try FileHandle(forWritingTo: fixture.source)
        try handle.write(contentsOf: Data(rewritten.utf8))
        try handle.close()
        let currentMetadata = CostUsageScanner.codexFileMetadata(fileURL: fixture.source)
        try fixture.updateSentinel { usage in
            usage.mtimeUnixMs = currentMetadata.mtimeUnixMs
            usage.sourceStatFingerprint = currentMetadata.statFingerprint
            usage.sourceChangeTimeNanoseconds = currentMetadata.changeTimeNanoseconds
        }

        // Even if metadata agrees, the original whole-file SHA is no longer a
        // proof of the current source's noncontributing content.
        XCTAssertThrowsError(try fixture.watermarks())
    }

    func testByteIdenticalReplacementRequiresARescan() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let oldGeneration = CostUsageScanner.codexFileMetadata(fileURL: fixture.source).fileId
        let displaced = fixture.root.appendingPathComponent("displaced.jsonl")
        try FileManager.default.moveItem(at: fixture.source, to: displaced)
        try FileManager.default.copyItem(at: displaced, to: fixture.source)
        XCTAssertNotEqual(CostUsageScanner.codexFileMetadata(fileURL: fixture.source).fileId, oldGeneration)

        XCTAssertThrowsError(try fixture.watermarks())
    }

    func testMissingNoncontributingSourceRequiresARescan() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.source)

        XCTAssertThrowsError(try fixture.watermarks())
    }

    func testIncompleteNoncontributingProofCannotBePublishedAsComplete() throws {
        let mutations: [(inout CostUsageFileUsage) -> Void] = [
            { $0.parsedBytes = nil },
            { $0.parsedBytes = $0.size - 1 },
            { $0.committedPrefixFingerprint = nil },
            { $0.sourceGeneration = nil },
            { $0.sourceStatFingerprint = nil },
            { $0.sourceChangeTimeNanoseconds = nil },
        ]
        for mutate in mutations {
            let fixture = try Fixture()
            defer { fixture.remove() }
            try fixture.updateSentinel(mutate)

            XCTAssertThrowsError(try fixture.watermarks())
        }
    }

    func testContradictorySentinelCannotBecomeAnAbsorbingWatermark() throws {
        let mutations: [(inout CostUsageFileUsage) -> Void] = [
            { $0.codexInventoryOnly = false },
            { $0.codexDuplicateQuarantined = true },
            { $0.codexIdentityConflict = true },
            { $0.days = ["2026-09-03": ["fixture-model": [100, 0, 0]]] },
            { $0.lastTokenEventEndOffset = 1 },
            { $0.tokenEventWatermarks = [CostUsageTokenEventWatermark(
                endOffset: 1, lineFingerprint: "unexpected", eventTimestamp: nil, totalTokens: 100
            )] },
        ]
        for mutate in mutations {
            let fixture = try Fixture()
            defer { fixture.remove() }
            try fixture.updateSentinel(mutate)

            XCTAssertThrowsError(try fixture.watermarks())
        }
    }

    private struct Fixture {
        static let tokenEvent = #"{"timestamp":"2026-09-03T08:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"output_tokens":0,"total_tokens":100},"last_token_usage":{"input_tokens":100,"output_tokens":0,"total_tokens":100}}}}"#
        let root: URL
        let source: URL
        let cacheRoot: URL
        let scanner: CodexTokenActivityScanner
        let now = ISO8601DateFormatter().date(from: "2026-09-03T09:00:00Z")!

        var cacheFile: URL {
            CostUsageCacheIO.cacheFileURL(provider: .codex, cacheRoot: cacheRoot)
        }

        init() throws {
            root = FileManager.default.temporaryDirectory
                .standardizedFileURL.resolvingSymlinksInPath()
                .appendingPathComponent("noncontributing-watermark-\(UUID().uuidString)", isDirectory: true)
            let sessions = root.appendingPathComponent("sessions", isDirectory: true)
            source = sessions.appendingPathComponent("metadata-only.jsonl")
            cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
            try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
            let contents = [
                #"{"timestamp":"2026-09-03T07:59:59Z","type":"session_meta","payload":{"id":"shared-session","originator":"metadata-only"}}"#,
                #"{"timestamp":"2026-09-03T08:00:00Z","type":"event_msg","payload":{"type":"token_count","info":null}}"#,
            ].joined(separator: "\n") + "\n"
            try Data(contents.utf8).write(to: source)
            var usage = try Self.provenUsage(for: source)
            usage.codexInventoryOnly = true
            usage.codexNoncontributingDuplicate = true
            var cache = CostUsageCache()
            cache.files[source.path] = usage
            try CostUsageCacheIO.save(provider: .codex, cache: cache, cacheRoot: cacheRoot)
            scanner = CodexTokenActivityScanner(
                sessionRootURLs: [sessions], cacheURL: root.appendingPathComponent("unused-legacy.json"),
                costUsageCacheRootURL: cacheRoot, usesAgentSignalCostUsageScanner: true,
                priorityDatabaseURL: root.appendingPathComponent("unused-priority.sqlite")
            )
        }

        func remove() { try? FileManager.default.removeItem(at: root) }

        func cache() throws -> CostUsageCache {
            try CostUsageCacheIO.loadRequired(provider: .codex, cacheRoot: cacheRoot)
        }

        func watermarks() throws -> [CodexTokenActivityScanWatermark] {
            try scanner.agentSignalCostUsageScanWatermarks(through: now)
        }

        func updateSentinel(_ mutate: (inout CostUsageFileUsage) -> Void) throws {
            var cache = try cache()
            var usage = try XCTUnwrap(cache.files[source.path])
            mutate(&usage)
            cache.files[source.path] = usage
            try CostUsageCacheIO.save(provider: .codex, cache: cache, cacheRoot: cacheRoot)
        }

        func addTokenOwner() throws -> URL {
            let owner = source.deletingLastPathComponent().appendingPathComponent("owner.jsonl")
            let contents = #"{"timestamp":"2026-09-03T07:59:59Z","type":"session_meta","payload":{"id":"shared-session","originator":"token-owner"}}"#
                + "\n" + Self.tokenEvent + "\n"
            try Data(contents.utf8).write(to: owner)
            var usage = try Self.provenUsage(for: owner)
            usage.days = ["2026-09-03": ["fixture-model": [100, 0, 0]]]
            usage.tokenEventWatermarks = [CostUsageTokenEventWatermark(
                endOffset: usage.size - 1,
                lineFingerprint: CodexTokenObservationCursor.fingerprint(for: Data(Self.tokenEvent.utf8)),
                eventTimestamp: now.addingTimeInterval(-60 * 60), totalTokens: 100
            )]
            var cache = try cache()
            cache.files[owner.path] = usage
            cache.days = usage.days
            try CostUsageCacheIO.save(provider: .codex, cache: cache, cacheRoot: cacheRoot)
            return owner
        }

        private static func provenUsage(for url: URL) throws -> CostUsageFileUsage {
            let metadata = CostUsageScanner.codexFileMetadata(fileURL: url)
            var usage = CostUsageFileUsage(mtimeUnixMs: metadata.mtimeUnixMs, size: metadata.size, days: [:])
            usage.sessionId = "shared-session"
            usage.parsedBytes = metadata.size
            usage.sourceGeneration = try XCTUnwrap(metadata.fileId)
            usage.sourceStatFingerprint = metadata.statFingerprint
            usage.sourceChangeTimeNanoseconds = metadata.changeTimeNanoseconds
            usage.committedPrefixFingerprint = try XCTUnwrap(CostUsageScanner.codexCommittedPrefixFingerprint(
                fileURL: url, throughOffset: metadata.size, checkCancellation: nil
            ))
            return usage
        }
    }
}

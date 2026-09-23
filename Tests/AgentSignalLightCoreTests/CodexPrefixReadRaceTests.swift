import Foundation
import XCTest
@testable import AgentSignalLight

final class CodexPrefixReadRaceTests: XCTestCase {
    func testRewriteAndAppendDuringHashCannotVerifyOldPrefix() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var checks = 0
        let matches = try CostUsageScanner.codexFileMatchesCommittedFrontier(
            fileURL: fixture.source, cached: fixture.cached, checkCancellation: {
                checks += 1
                // The first 256 KiB has already been hashed. A later append
                // must not disguise a rewrite of those previously read bytes.
                if checks == 4 { try fixture.rewriteFirstByteAndAppend() }
            })
        XCTAssertFalse(matches)
    }

    func testSingleAppendDuringHashCanStillVerifyCommittedPrefix() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var checks = 0
        let matches = try CostUsageScanner.codexFileMatchesCommittedFrontier(
            fileURL: fixture.source, cached: fixture.cached, checkCancellation: {
                checks += 1
                if checks == 4 { try fixture.append() }
            })
        XCTAssertTrue(matches)
    }

    func testContinuouslyAppendingSourceStopsWithSourceChangingError() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var checks = 0
        XCTAssertThrowsError(try CostUsageScanner.codexFileMatchesCommittedFrontier(
            fileURL: fixture.source, cached: fixture.cached, checkCancellation: {
                checks += 1
                // Keep changing each attempted read. The guard also makes a
                // accidentally unbounded retry fail instead of hanging tests.
                guard checks <= 30 else { throw CancellationError() }
                try fixture.append()
            })) { error in
                let error = error as NSError
                XCTAssertEqual(error.domain, "AgentSignalCostUsage.CodexConsistency")
                XCTAssertEqual(error.code, 3)
            }
        XCTAssertLessThanOrEqual(checks, 30)
    }

    func testCancellationPropagatesWhenRetryingChangedPrefixRead() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var checks = 0
        XCTAssertThrowsError(try CostUsageScanner.codexFileMatchesCommittedFrontier(
            fileURL: fixture.source, cached: fixture.cached, checkCancellation: {
                checks += 1
                if checks == 4 { try fixture.append() }
                if checks == 6 { throw CancellationError() }
            })) { error in
                XCTAssertTrue(error is CancellationError)
            }
    }

    private struct Fixture {
        let root: URL
        let source: URL
        let cached: CostUsageFileUsage

        init() throws {
            root = URL(fileURLWithPath: "/private/tmp/asb-prefix-race-\(UUID().uuidString)")
            source = root.appendingPathComponent("prefix.bin")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            let prefix = Data(repeating: 65, count: 512 * 1024)
            try prefix.write(to: source)
            let fingerprint = try XCTUnwrap(CostUsageScanner.codexCommittedPrefixFingerprint(
                fileURL: source, throughOffset: Int64(prefix.count), checkCancellation: nil))
            cached = CostUsageFileUsage(mtimeUnixMs: 0, size: Int64(prefix.count), days: [:],
                parsedBytes: Int64(prefix.count), committedPrefixFingerprint: fingerprint)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }

        func append() throws {
            let handle = try FileHandle(forWritingTo: source)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data([67]))
        }

        func rewriteFirstByteAndAppend() throws {
            let handle = try FileHandle(forWritingTo: source)
            defer { try? handle.close() }
            try handle.write(contentsOf: Data([66]))
            try handle.seekToEnd()
            try handle.write(contentsOf: Data([67]))
        }
    }
}

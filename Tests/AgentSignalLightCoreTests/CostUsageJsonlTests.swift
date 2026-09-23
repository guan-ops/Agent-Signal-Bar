import Foundation
import XCTest
@testable import AgentSignalLight

final class CostUsageJsonlTests: XCTestCase {
    private func withFile(_ data: Data, _ body: (URL) throws -> Void) throws {
        let root = URL(fileURLWithPath: "/private/tmp")
            .appendingPathComponent("asb-jsonl-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("fixture.jsonl")
        try data.write(to: url)
        try body(url)
    }

    func testNewlinesAcrossChunkBoundariesKeepExactOffsetsAndPrefixes() throws {
        // First newline ends a chunk; second line crosses the next chunk boundary.
        var data = Data(repeating: 65, count: 262_143)
        data.append(10)
        data.append(Data(repeating: 66, count: 262_145))
        data.append(contentsOf: [10, 10, 123, 125, 10])
        try withFile(data) { url in
            var lines: [CostUsageJsonl.Line] = []
            let end = try CostUsageJsonl.scan(fileURL: url, maxLineBytes: 16, prefixBytes: 8) {
                lines.append($0)
            }
            XCTAssertEqual(end, 524_294)
            XCTAssertEqual(lines.map(\.startOffset), [0, 262_144, 524_291])
            XCTAssertEqual(lines.map(\.endOffset), [262_143, 524_289, 524_293])
            XCTAssertEqual(lines.map(\.wasTruncated), [true, true, false])
            XCTAssertEqual(lines.map(\.bytes), [Data(repeating: 65, count: 8),
                                              Data(repeating: 66, count: 8), Data("{}".utf8)])
        }
    }

    func testStopBeforeLineReturnsItsStartAndResumeDoesNotSkipIt() throws {
        try withFile(Data("{}\n\n{\"n\":1}\n{\"n\":2}\n".utf8)) { url in
            var lines: [Data] = []
            let end = try CostUsageJsonl.scan(fileURL: url, maxLineBytes: 64, prefixBytes: 64,
                stopBeforeLine: { $0.bytes == Data("{\"n\":1}".utf8) }) { lines.append($0.bytes) }
            XCTAssertEqual(end, 4)
            XCTAssertEqual(lines, [Data("{}".utf8)])
            var resumed: [Int64] = []
            XCTAssertEqual(try CostUsageJsonl.scan(fileURL: url, offset: end,
                maxLineBytes: 64, prefixBytes: 64) { resumed.append($0.startOffset) }, 20)
            XCTAssertEqual(resumed, [4, 12])
        }
    }

    func testPartialTailIsReadAgainAfterAppendExactlyOnce() throws {
        try withFile(Data("{}\n{\"n\":".utf8)) { url in
            var lines: [Data] = []
            let end = try CostUsageJsonl.scan(fileURL: url, maxLineBytes: 64, prefixBytes: 64) {
                lines.append($0.bytes)
            }
            XCTAssertEqual(end, 3)
            XCTAssertEqual(lines, [Data("{}".utf8)])
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("1}\n".utf8))
            try handle.close()
            lines = []
            XCTAssertEqual(try CostUsageJsonl.scan(fileURL: url, offset: end,
                maxLineBytes: 64, prefixBytes: 64) { lines.append($0.bytes) }, 11)
            XCTAssertEqual(lines, [Data("{\"n\":1}".utf8)])
        }
    }

    func testCompleteJSONTailWithoutNewlineIsCommitted() throws {
        try withFile(Data("{}\n{\"n\":1}".utf8)) { url in
            var ends: [Int64] = []
            XCTAssertEqual(try CostUsageJsonl.scan(fileURL: url,
                maxLineBytes: 64, prefixBytes: 64) { ends.append($0.endOffset) }, 10)
            XCTAssertEqual(ends, [2, 10])
        }
    }

    func testLongUnterminatedTailRemainsDeferred() throws {
        try withFile(Data(repeating: 65, count: 300_000)) { url in
            var count = 0
            XCTAssertEqual(try CostUsageJsonl.scan(fileURL: url,
                maxLineBytes: 64, prefixBytes: 64) { _ in count += 1 }, 0)
            XCTAssertEqual(count, 0)
        }
    }

    func testCancellationInterruptsLongLineBetweenChunks() throws {
        try withFile(Data(repeating: 65, count: 1_048_576)) { url in
            var checks = 0
            XCTAssertThrowsError(try CostUsageJsonl.scan(fileURL: url,
                maxLineBytes: 64, prefixBytes: 64, checkCancellation: {
                    checks += 1
                    if checks == 4 { throw CancellationError() }
                }, onLine: { _ in XCTFail("An unfinished line must not be delivered") })) {
                    XCTAssertTrue($0 is CancellationError)
                }
        }
    }

    func testLargePayloadScanThroughput() throws {
        // Opt in on a local SSD; keep machine-dependent timing out of ordinary CI.
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ASB_RUN_SCAN_BENCHMARK"] == "1")
        try withFile(Data()) { url in
            let handle = try FileHandle(forWritingTo: url)
            let chunk = Data(repeating: 65, count: 1_048_576)
            for _ in 0..<256 { try handle.write(contentsOf: chunk) }
            try handle.write(contentsOf: Data("\n{}\n".utf8))
            try handle.close()
            let start = ContinuousClock.now
            var lineCount = 0
            let end = try CostUsageJsonl.scan(fileURL: url, maxLineBytes: 4096, prefixBytes: 4096) { _ in
                lineCount += 1
            }
            let elapsed = start.duration(to: .now)
            print("JSONL 256 MiB scan elapsed: \(elapsed)")
            XCTAssertEqual(end, 268_435_460)
            XCTAssertEqual(lineCount, 2)
            XCTAssertLessThan(elapsed, .seconds(2), "Large payloads must not be scanned byte-by-byte in Swift")
        }
    }
}

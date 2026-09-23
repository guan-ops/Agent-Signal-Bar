import Foundation
import XCTest
@testable import AgentSignalLight

@MainActor
final class ClaudeHistoryCancellationTests: XCTestCase {
    func testResetCancelsTheRunningHistoryLoader() async throws {
        let suite = "claude-history-cancellation-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let started = expectation(description: "scan started")
        let cancelled = expectation(description: "loader received cancellation")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let model = ClaudeSupportModel(defaults: defaults, historyLoader: { checkCancellation in
            started.fulfill()
            guard release.wait(timeout: .now() + 5) == .success else {
                throw ClaudeSupportError.timedOut
            }
            do {
                try checkCancellation()
            } catch is CancellationError {
                cancelled.fulfill()
                throw CancellationError()
            }
            return .init(data: [], summary: nil)
        })
        model.refresh(force: true)
        await fulfillment(of: [started], timeout: 2)
        model.resetIdentity()
        release.signal()
        await fulfillment(of: [cancelled], timeout: 1)
        XCTAssertFalse(model.isRefreshing)
        XCTAssertFalse(model.isHistoryScanning)
        XCTAssertNil(model.historyUpdatedAt)
        XCTAssertNil(model.historyIssue)
    }

    func testResetBeforeRefreshStartsDoesNotRestartHistoryProgress() async throws {
        let suite = "claude-history-pre-cancelled-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let unexpectedScan = expectation(description: "cancelled refresh must not scan")
        unexpectedScan.isInverted = true
        let model = ClaudeSupportModel(defaults: defaults, historyLoader: { _ in
            unexpectedScan.fulfill()
            return .init(data: [], summary: nil)
        })
        model.refresh(force: true)
        model.resetIdentity()
        await fulfillment(of: [unexpectedScan], timeout: 0.15)
        XCTAssertFalse(model.isRefreshing)
        XCTAssertFalse(model.isHistoryScanning)
        XCTAssertNil(model.historyUpdatedAt)
    }

    func testResetAndRefreshNeverOverlapHistoryLoaders() async throws {
        let suite = "claude-history-serialization-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let firstStarted = expectation(description: "first scan started")
        let overlap = expectation(description: "new scan must wait for old scan")
        overlap.isInverted = true
        let finished = expectation(description: "both scans finished")
        finished.expectedFulfillmentCount = 2
        let releaseFirst = DispatchSemaphore(value: 0)
        defer { releaseFirst.signal() }
        let tracker = HistoryLoadTracker()
        let model = ClaudeSupportModel(defaults: defaults, historyLoader: { _ in
            let (index, active) = tracker.begin()
            defer { tracker.end(); finished.fulfill() }
            if active > 1 { overlap.fulfill() }
            if index == 1 {
                firstStarted.fulfill()
                guard releaseFirst.wait(timeout: .now() + 5) == .success else {
                    throw ClaudeSupportError.timedOut
                }
            }
            return .init(data: [], summary: nil)
        })

        model.refresh(force: true)
        await fulfillment(of: [firstStarted], timeout: 2)
        model.resetIdentity()
        model.refresh(force: true)
        await fulfillment(of: [overlap], timeout: 0.15)
        releaseFirst.signal()
        await fulfillment(of: [finished], timeout: 2)
        for _ in 0..<100 where model.isRefreshing { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(tracker.maximumActive, 1)
        XCTAssertFalse(model.isRefreshing)
        XCTAssertNotNil(model.historyUpdatedAt)
        XCTAssertNil(model.historyIssue)
    }
}

private final class HistoryLoadTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var active = 0
    private var peak = 0

    func begin() -> (Int, Int) {
        lock.lock(); defer { lock.unlock() }
        calls += 1
        active += 1
        peak = max(peak, active)
        return (calls, active)
    }

    func end() {
        lock.lock(); defer { lock.unlock() }
        active -= 1
    }

    var maximumActive: Int {
        lock.lock(); defer { lock.unlock() }
        return peak
    }
}

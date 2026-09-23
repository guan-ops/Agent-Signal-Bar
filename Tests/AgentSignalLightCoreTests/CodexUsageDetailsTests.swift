import AppKit
import SwiftUI
import XCTest
@testable import AgentSignalLight

final class CodexUsageDetailsTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-09-08T12:00:00Z")!
    private var today: String { CostUsageScanner.CostUsageDayRange.dayKey(from: now) }
    private let catalog = ModelsDevCatalog(providers: [:])

    private func usage(_ id: String, tokens: Int = 100) -> CostUsageFileUsage {
        .init(mtimeUnixMs: 0, size: 0, days: [today: ["gpt-5": [tokens, tokens / 2, 20]]],
              sessionId: id, lastTokenEventTimestamp: now,
              codexCostNanos: [today: ["gpt-5": 2_000_000_000]])
    }

    func testDetailsReconcileWithConfirmedReportAndKeepSameNamedProjectsSeparate() throws {
        var cache = CostUsageCache()
        cache.files = ["/a/one": usage("one"), "/a/two": usage("two"), "/b/three": usage("three")]
        for file in cache.files.values { CostUsageScanner.applyFileDays(cache: &cache, fileDays: file.days, sign: 1) }
        let result = CodexUsageDetails.build(cache: cache, now: now, modelsDevCatalog: catalog) { path, _ in
            path.hasPrefix("/a/") ? "/a/Project" : "/b/Project"
        }
        let range = CostUsageScanner.CostUsageDayRange(since: Calendar.current.date(byAdding: .day, value: -29, to: now)!, until: now)
        let report = CostUsageScanner.buildCodexReportFromCache(cache: cache, range: range, modelsDevCatalog: catalog)
        XCTAssertEqual(result.sessions.count, 3)
        XCTAssertEqual(result.projects.count, 2)
        XCTAssertEqual(result.projects.first?.sessionCount, 2)
        XCTAssertEqual(result.projects.reduce(0) { $0 + $1.totalTokens }, report.summary?.totalTokens)
        XCTAssertEqual(result.projects.compactMap(\.costUSD).reduce(0, +), report.summary?.totalCostUSD)
        let first = try XCTUnwrap(result.sessions.first)
        XCTAssertEqual(first.inputTokens, 100)
        XCTAssertEqual(first.cachedTokens, 50)
        XCTAssertEqual(first.outputTokens, 20)
        XCTAssertEqual(first.totalTokens, 120, "Cached input must not be added twice")
    }

    func testInventoryCopiesConflictsAndOldDaysDoNotContribute() {
        var cache = CostUsageCache()
        var owner = usage("owner")
        let old = Calendar.current.date(byAdding: .day, value: -30, to: now)!
        owner.days[CostUsageScanner.CostUsageDayRange.dayKey(from: old)] = ["gpt-5": [9999, 0, 0]]
        var copy = owner
        copy.codexInventoryOnly = true
        var conflict = usage("conflict")
        conflict.codexIdentityConflict = true
        var stale = usage("stale")
        stale.days = [CostUsageScanner.CostUsageDayRange.dayKey(from: old): ["gpt-5": [9999, 0, 0]]]
        cache.files = ["owner": owner, "copy": copy, "conflict": conflict, "old": stale,
                       "ambiguous1": usage("ambiguous"), "ambiguous2": usage("ambiguous")]
        let result = CodexUsageDetails.build(cache: cache, now: now, modelsDevCatalog: catalog) { _, _ in nil }
        XCTAssertEqual(result.sessions.map(\.id), ["owner"])
        XCTAssertEqual(result.projects.first?.totalTokens, 120)
        XCTAssertNil(result.projects.first?.path)
    }

    func testUnknownPricingRemainsMissingAndMixedProjectIsPartial() throws {
        var cache = CostUsageCache()
        let unknown = CostUsageFileUsage(mtimeUnixMs: 0, size: 0,
            days: [today: ["unknown-fixture-model": [100, 0, 20]]], sessionId: "unknown")
        cache.files = ["known": usage("known"), "unknown": unknown]
        let result = CodexUsageDetails.build(cache: cache, now: now, modelsDevCatalog: catalog) { _, _ in "/Project" }
        XCTAssertNil(result.sessions.first { $0.id == "unknown" }?.costUSD)
        XCTAssertEqual(result.projects.first?.costUSD, 2)
        XCTAssertEqual(result.projects.first?.hasUnpricedUsage, true)
    }

    func testHeaderRequiresMatchingIdentityAndAnAbsoluteProjectPath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session.jsonl")
        let data = Data(#"{"type":"session_meta","payload":{"id":"fixture","cwd":"/Projects/Shared Name"}}"#.utf8) + Data("\nnot parsed body".utf8)
        try data.write(to: file)
        XCTAssertEqual(CodexUsageDetails.readProjectPath(file.path, "fixture"), "/Projects/Shared Name")
        XCTAssertNil(CodexUsageDetails.readProjectPath(file.path, "another"))
        XCTAssertEqual(try Data(contentsOf: file), data)
        try Data(#"{"type":"session_meta","payload":{"id":"fixture","cwd":"relative/path"}}"#.utf8).write(to: file)
        XCTAssertNil(CodexUsageDetails.readProjectPath(file.path, "fixture"))
    }

    @MainActor
    func testSettingsDetailsRenderWithIsolatedData() async throws {
        var cache = CostUsageCache()
        cache.files = ["one": usage("019a0000-0000-0000-0000-000000000001", tokens: 1200000),
                       "two": usage("019a0000-0000-0000-0000-000000000002", tokens: 300000)]
        let details = CodexUsageDetails.build(cache: cache, now: now, modelsDevCatalog: catalog) { path, _ in
            path == "one" ? "/Projects/示例应用" : "/Projects/工具"
        }
        _ = NSApplication.shared
        let host = NSHostingView(rootView: CodexUsageDetailsView(details: details, isLoading: false,
            text: { zh, _ in zh }, tokens: { $0.formatted() },
            formatCost: { value, partial in value.map { (partial ? "≥ " : "") + $0.formatted(.currency(code: "USD")) } ?? "—" })
            .frame(width: 600))
        let size = host.fittingSize
        XCTAssertEqual(size.width, 600, accuracy: 1)
        XCTAssertGreaterThan(size.height, 150)
        XCTAssertLessThan(size.height, 360, "Project and session lists should be collapsed initially")
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor(white: 0.16, alpha: 1).cgColor
        window.appearance = NSAppearance(named: .darkAqua)
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        if let directory = ProcessInfo.processInfo.environment["ASB_DETAILS_PREVIEW"],
           let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(
                to: URL(fileURLWithPath: directory).appendingPathComponent("settings-details.png"))
        }
    }
}

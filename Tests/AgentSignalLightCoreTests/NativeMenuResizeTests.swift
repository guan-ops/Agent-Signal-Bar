import AppKit
import SwiftUI
import XCTest
@testable import AgentSignalLight

final class NativeMenuResizeTests: XCTestCase {
    @MainActor
    func testTrackedMenuBackgroundFollowsGrowingAndShrinkingUsageContent() throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.main else { throw XCTSkip("Requires a WindowServer display") }
        let probe = NativeMenuResizeProbe()
        let timer = Timer(timeInterval: 0.02, repeats: true) { _ in
            MainActor.assumeIsolated { probe.advance() }
        }
        RunLoop.main.add(timer, forMode: .common)
        defer { timer.invalidate(); probe.menu.cancelTracking() }
        probe.menu.popUp(positioning: nil,
                         at: NSPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.maxY - 30), in: nil)
        XCTAssertEqual(probe.completedChanges, 3, "All growth/shrink updates must run while the menu is tracking")
        XCTAssertFalse(probe.timedOut, "A main-queue-only resize stalls in the menu's tracking loop")
        XCTAssertEqual(probe.backgroundOffsets.count, 4)
        if let baseline = probe.backgroundOffsets.first {
            for offset in probe.backgroundOffsets.dropFirst() {
                XCTAssertEqual(offset, baseline, accuracy: 1,
                               "The menu background must remain aligned with the window after a content resize")
            }
        }
    }
}

@MainActor
private final class NativeMenuResizeState: ObservableObject {
    @Published var rows = 0
}

private struct NativeMenuResizeContent: View {
    @ObservedObject var state: NativeMenuResizeState
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Fixture token usage").font(.headline)
            ForEach(0..<state.rows, id: \.self) { row in Text("Quota window \(row): 50% remaining") }
            Text("USD 12.50 · 1,000 tokens")
        }
        .padding(10).frame(width: 300).fixedSize(horizontal: false, vertical: true)
    }
}

@MainActor
private final class NativeMenuResizeProbe {
    let menu = NSMenu()
    private let state = NativeMenuResizeState()
    private let host: MenuUsageHostingView<NativeMenuResizeContent>
    private var previousHeight: CGFloat = 0
    private var initialHeight: CGFloat = 0
    private var phase = 0
    private var stableSince: Date?
    private let deadline = Date().addingTimeInterval(5)
    private(set) var completedChanges = 0
    private(set) var backgroundOffsets: [CGFloat] = []
    private(set) var timedOut = false

    init() {
        host = MenuUsageHostingView(rootView: NativeMenuResizeContent(state: state))
        host.setFrameSize(host.fittingSize)
        menu.autoenablesItems = false
        menu.addItem(NSMenuItem(title: "Agent Signal Bar", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Working", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        let item = NSMenuItem()
        item.view = host
        menu.addItem(item)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Settings", action: nil, keyEquivalent: ""))
    }

    func advance() {
        guard phase <= 3 else { return }
        if Date() > deadline { timedOut = true; menu.cancelTracking(); return }
        guard let window = host.window, let background = window.contentView else { return }
        let height = host.frame.height
        guard abs(height - host.fittingSize.height) < 1 else { stableSince = nil; return }
        let reachedSize = switch phase {
        case 0: true
        case 1: height > previousHeight + 50
        case 2: height < previousHeight - 20 && height > initialHeight + 10
        default: abs(height - initialHeight) < 1
        }
        guard reachedSize else { stableSince = nil; return }
        guard let stableSince else { stableSince = Date(); return }
        guard Date().timeIntervalSince(stableSince) >= 0.08 else { return }
        backgroundOffsets.append(background.frame.height - window.contentRect(forFrameRect: window.frame).height)
        previousHeight = height
        self.stableSince = nil
        switch phase {
        case 0: initialHeight = height; state.rows = 8
        case 1: completedChanges += 1; state.rows = 2
        case 2: completedChanges += 1; state.rows = 0
        default: completedChanges += 1; menu.cancelTracking()
        }
        phase += 1
    }
}

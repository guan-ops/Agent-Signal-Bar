import AppKit
import XCTest
@testable import AgentSignalLight

final class FloatingPopoverPlacementTests: XCTestCase {
    private let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
    private let size = NSSize(width: 250, height: 110)

    private func badge(in window: NSRect, left: Bool, bottom: Bool = true) -> NSRect {
        NSRect(x: left ? window.minX : window.maxX - 22, y: bottom ? window.minY : window.maxY - 22, width: 22, height: 22)
    }

    func testPanelOpensBesideTheLightOnTheBadgesSideWithoutCoveringIt() {
        let window = NSRect(x: 900, y: 400, width: 70, height: 170)
        for left in [true, false] {
            let anchor = badge(in: window, left: left)
            let frame = FloatingPopoverPlacement.frame(size: size, anchor: anchor, avoiding: window, visibleFrame: screen)
            XCTAssertFalse(frame.intersects(window), "The panel must not cover the light or its controls")
            if left {
                XCTAssertEqual(frame.maxX, window.minX - FloatingPopoverPlacement.gap)
            } else {
                XCTAssertEqual(frame.minX, window.maxX + FloatingPopoverPlacement.gap)
            }
            XCTAssertEqual(frame.midY, anchor.midY, accuracy: 0.5, "Level with the badge that opened it")
            XCTAssertTrue(screen.contains(frame))
        }
    }

    func testPanelMovesToTheOtherSideNearAScreenEdge() {
        let nearLeftEdge = NSRect(x: 12, y: 400, width: 70, height: 170)
        let leftFrame = FloatingPopoverPlacement.frame(size: size, anchor: badge(in: nearLeftEdge, left: true),
                                                       avoiding: nearLeftEdge, visibleFrame: screen)
        XCTAssertEqual(leftFrame.minX, nearLeftEdge.maxX + FloatingPopoverPlacement.gap)
        XCTAssertFalse(leftFrame.intersects(nearLeftEdge))

        let nearRightEdge = NSRect(x: 1360, y: 400, width: 70, height: 170)
        let rightFrame = FloatingPopoverPlacement.frame(size: size, anchor: badge(in: nearRightEdge, left: false),
                                                        avoiding: nearRightEdge, visibleFrame: screen)
        XCTAssertEqual(rightFrame.maxX, nearRightEdge.minX - FloatingPopoverPlacement.gap)
        XCTAssertFalse(rightFrame.intersects(nearRightEdge))
    }

    func testPanelStaysOnScreenNearTheTopAndBottom() {
        for y in [4.0, 900 - 174.0] {
            let window = NSRect(x: 900, y: y, width: 70, height: 170)
            for bottom in [true, false] {
                let frame = FloatingPopoverPlacement.frame(size: size, anchor: badge(in: window, left: true, bottom: bottom),
                                                           avoiding: window, visibleFrame: screen)
                XCTAssertTrue(screen.insetBy(dx: 7, dy: 7).contains(frame), "\(frame)")
                XCTAssertFalse(frame.intersects(window))
            }
        }
    }
}

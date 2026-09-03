import AppKit
import XCTest
@testable import AgentSignalLight

@MainActor
final class FloatingSignalDragTests: XCTestCase {
    func testLampHitTestingUsesSuperviewCoordinatesForBothLayouts() {
        for parent in parents() {
            for size in [NSSize(width: 240, height: 60), NSSize(width: 60, height: 180)] {
                let view = FloatingSignalDragCursorView(frame: NSRect(x: 100, y: 80, width: size.width, height: size.height))
                parent.addSubview(view)
                let point = view.convert(NSPoint(x: size.width / 2, y: size.height / 2), to: parent)

                XCTAssertTrue(view.hitTest(point) === view)
                XCTAssertTrue(parent.hitTest(parent.convert(point, to: parent.superview)) === view)
                XCTAssertNil(view.hitTest(NSPoint(x: 10, y: 10)))
                view.removeFromSuperview()
            }
        }
    }

    func testBadgeHitTestingUsesSuperviewCoordinatesAndKeepsItsHotspot() {
        for parent in parents() {
            let view = FloatingSignalInfoBadgeDragView(frame: NSRect(x: 100, y: 80, width: 40, height: 40))
            view.badgeSize = 24
            parent.addSubview(view)

            let point = view.convert(NSPoint(x: 20, y: 20), to: parent)
            XCTAssertTrue(view.hitTest(point) === view)
            XCTAssertTrue(parent.hitTest(parent.convert(point, to: parent.superview)) === view)
            XCTAssertNil(view.hitTest(view.convert(NSPoint(x: 1, y: 1), to: parent)))
            view.removeFromSuperview()
        }
    }

    func testResizeHitTestingUsesSuperviewCoordinatesAcrossFlippedParents() {
        for parent in parents() {
            let view = FloatingSignalResizeHandleView(frame: NSRect(x: 100, y: 80, width: 50, height: 50))
            parent.addSubview(view)
            view.layout()

            let point = view.convert(NSPoint(x: 40, y: 10), to: parent)
            XCTAssertTrue(view.hitTest(point) === view)
            XCTAssertTrue(parent.hitTest(parent.convert(point, to: parent.superview)) === view)
            XCTAssertNil(view.hitTest(view.convert(NSPoint(x: 1, y: 40), to: parent)))
            view.removeFromSuperview()
        }
    }

    func testHiddenControlsAndHiddenAncestorsDoNotCaptureInput() {
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 500))
        let views: [NSView] = [
            FloatingSignalDragCursorView(frame: NSRect(x: 100, y: 80, width: 40, height: 40)),
            FloatingSignalInfoBadgeDragView(frame: NSRect(x: 100, y: 80, width: 40, height: 40)),
            FloatingSignalResizeHandleView(frame: NSRect(x: 100, y: 80, width: 40, height: 40))
        ]
        for view in views {
            parent.addSubview(view)
            view.layout()
            let point = view.convert(NSPoint(x: 20, y: 20), to: parent)
            view.isHidden = true
            XCTAssertNil(view.hitTest(point))
            view.isHidden = false
            parent.isHidden = true
            XCTAssertNil(view.hitTest(point))
            parent.isHidden = false
            view.removeFromSuperview()
        }
    }

    func testLampHandsOriginalMouseDownToNativeWindowDrag() throws {
        let (panel, view) = fixture()
        let event = try mouseEvent(panel: panel, view: view)

        XCTAssertFalse(view.mouseDownCanMoveWindow)
        XCTAssertTrue(view.acceptsFirstMouse(for: event))
        view.mouseDown(with: event)

        XCTAssertEqual(panel.dragEvents.count, 1)
        XCTAssertTrue(panel.dragEvents.first === event)
    }

    func testControlClickAndOtherMouseButtonsDoNotStartWindowDrag() throws {
        let (panel, view) = fixture()
        for type in [NSEvent.EventType.rightMouseDown, .otherMouseDown] {
            view.mouseDown(with: try mouseEvent(panel: panel, view: view, type: type))
        }
        view.mouseDown(with: try mouseEvent(panel: panel, view: view, modifiers: .control))

        XCTAssertTrue(panel.dragEvents.isEmpty)
    }

    func testEventsOutsideLampOrFromAnotherWindowDoNotStartDrag() throws {
        let (panel, view) = fixture()
        let (otherPanel, otherView) = fixture()
        view.mouseDown(with: try mouseEvent(panel: panel, view: view, localPoint: NSPoint(x: -5, y: -5)))
        view.mouseDown(with: try mouseEvent(panel: otherPanel, view: otherView))

        XCTAssertTrue(panel.dragEvents.isEmpty)
        XCTAssertTrue(otherPanel.dragEvents.isEmpty)
    }

    func testAnotherDragDoesNotDependOnReceivingPreviousMouseUp() throws {
        let (panel, view) = fixture()
        let first = try mouseEvent(panel: panel, view: view)
        let second = try mouseEvent(panel: panel, view: view)
        view.mouseDown(with: first)
        view.mouseDown(with: second)

        XCTAssertEqual(panel.dragEvents.count, 2)
        XCTAssertTrue(panel.dragEvents.last === second)
    }

    func testBadgeAndResizeControlsKeepPriorityAboveLampDragRegion() {
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 500))
        let lamp = FloatingSignalDragCursorView(frame: NSRect(x: 80, y: 80, width: 240, height: 160))
        let badge = FloatingSignalInfoBadgeDragView(frame: NSRect(x: 100, y: 100, width: 40, height: 40))
        let resize = FloatingSignalResizeHandleView(frame: NSRect(x: 260, y: 90, width: 50, height: 50))
        parent.addSubview(lamp)
        parent.addSubview(badge)
        parent.addSubview(resize)
        resize.layout()

        XCTAssertTrue(parent.hitTest(badge.convert(NSPoint(x: 20, y: 20), to: parent)) === badge)
        XCTAssertTrue(parent.hitTest(resize.convert(NSPoint(x: 40, y: 10), to: parent)) === resize)
        XCTAssertFalse(badge.mouseDownCanMoveWindow)
        XCTAssertFalse(resize.mouseDownCanMoveWindow)
    }

    func testDetachedDragViewAcceptsLocalHitTestCoordinates() {
        let view = FloatingSignalDragCursorView(frame: NSRect(x: 100, y: 80, width: 60, height: 40))
        XCTAssertTrue(view.hitTest(NSPoint(x: 30, y: 20)) === view)
        XCTAssertNil(view.hitTest(NSPoint(x: 110, y: 90)))
    }

    private func parents() -> [NSView] {
        [
            NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 500)),
            FlippedParentView(frame: NSRect(x: 0, y: 0, width: 500, height: 500))
        ]
    }

    private func fixture() -> (RecordingDragPanel, FloatingSignalDragCursorView) {
        _ = NSApplication.shared
        let panel = RecordingDragPanel(
            contentRect: NSRect(x: 100, y: 100, width: 400, height: 300),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        panel.contentView = content
        let view = FloatingSignalDragCursorView(frame: NSRect(x: 100, y: 80, width: 100, height: 60))
        content.addSubview(view)
        return (panel, view)
    }

    private func mouseEvent(
        panel: NSPanel,
        view: NSView,
        type: NSEvent.EventType = .leftMouseDown,
        modifiers: NSEvent.ModifierFlags = [],
        localPoint: NSPoint = NSPoint(x: 30, y: 20)
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type,
            location: view.convert(localPoint, to: nil),
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: panel.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
    }
}

@MainActor
private final class RecordingDragPanel: NSPanel {
    var dragEvents: [NSEvent] = []

    override func performDrag(with event: NSEvent) {
        dragEvents.append(event)
    }
}

@MainActor
private final class FlippedParentView: NSView {
    override var isFlipped: Bool { true }
}

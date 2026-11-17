import AppKit
import XCTest
@testable import AgentSignalLight

@MainActor
final class PlaceholderSettingsWindowGuardTests: XCTestCase {
    private func makeWindow(identifier: String?, autosaveName: String = "") -> NSWindow {
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.identifier = identifier.map { NSUserInterfaceItemIdentifier(rawValue: $0) }
        if !autosaveName.isEmpty { window.setFrameAutosaveName(autosaveName) }
        return window
    }

    func testClosesOnlyTheEmptySwiftUISettingsPlaceholder() {
        _ = NSApplication.shared
        let placeholder = makeWindow(identifier: "com_apple_SwiftUI_Settings_window")
        placeholder.isRestorable = true
        let autosaved = makeWindow(identifier: nil, autosaveName: "com_apple_SwiftUI_Settings_window-fixture")
        let mainWindow = makeWindow(identifier: nil)
        let floatingLight = makeWindow(identifier: "fixture-floating-light")
        var closed: [NSWindow] = []
        let guardian = PlaceholderSettingsWindowGuard(
            windows: { [placeholder, autosaved, mainWindow, floatingLight] },
            isVisible: { _ in true },
            closeWindow: { closed.append($0) }
        )

        XCTAssertEqual(guardian.sweep(), 2)
        XCTAssertTrue(closed.contains { $0 === placeholder })
        XCTAssertTrue(closed.contains { $0 === autosaved })
        XCTAssertFalse(closed.contains { $0 === mainWindow }, "The app's own settings window stays open")
        XCTAssertFalse(closed.contains { $0 === floatingLight })
        XCTAssertFalse(placeholder.isRestorable, "Window restoration must not bring it back")
    }

    func testWaitsForPresentationToFinishAndClosesItAgainIfShownLater() async {
        _ = NSApplication.shared
        let placeholder = makeWindow(identifier: "com_apple_SwiftUI_Settings_window")
        var windows: [NSWindow] = []
        var isVisible = false
        var closeCount = 0
        let guardian = PlaceholderSettingsWindowGuard(
            windows: { windows },
            isVisible: { _ in isVisible },
            closeWindow: { _ in closeCount += 1; isVisible = false }
        )
        guardian.start()
        windows = [placeholder]

        // makeKeyAndOrderFront posts an update before the window is visible; nothing closes synchronously.
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: placeholder)
        XCTAssertEqual(closeCount, 0)
        isVisible = true
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: placeholder)
        await drainMainQueue()
        XCTAssertEqual(closeCount, 1)
        XCTAssertFalse(isVisible)

        for _ in 0..<20 { NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: placeholder) }
        await drainMainQueue()
        XCTAssertEqual(closeCount, 1, "An already closed, hidden placeholder is left alone")

        isVisible = true
        NotificationCenter.default.post(name: NSWindow.didBecomeMainNotification, object: placeholder)
        await drainMainQueue()
        XCTAssertEqual(closeCount, 2)
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}

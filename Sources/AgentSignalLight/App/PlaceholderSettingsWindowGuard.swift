import AppKit

// Follows CodexBar PlaceholderSettingsWindowGuard (#3053, #4407). MIT; see Resources/ClaudeSupport-LICENSE.txt.
//
// The app's settings live in the AppKit window from `StatusBarController.showDebugWindow()`. The SwiftUI
// `Settings { EmptyView() }` scene only carries the app-menu commands, but because it is the app's only
// scene, macOS presents it during launch as an empty "Agent Signal Bar Settings" window.
enum PlaceholderSettingsWindowDecision {
    /// SwiftUI names the window of a `Settings` scene with this fragment (identifier and frame autosave name).
    static let swiftUISettingsNameFragment = "com_apple_SwiftUI_Settings"

    static func shouldClose(identifier: String?, frameAutosaveName: String) -> Bool {
        if let identifier, identifier.contains(swiftUISettingsNameFragment) { return true }
        return frameAutosaveName.contains(swiftUISettingsNameFragment)
    }
}

/// Closes the empty SwiftUI `Settings` placeholder whenever macOS presents it.
@MainActor
final class PlaceholderSettingsWindowGuard: NSObject {
    typealias WindowsProvider = @MainActor () -> [NSWindow]
    typealias WindowPredicate = @MainActor (NSWindow) -> Bool
    typealias WindowAction = @MainActor (NSWindow) -> Void

    private let windows: WindowsProvider
    private let isVisible: WindowPredicate
    private let closeWindow: WindowAction
    private let closedWindows = NSHashTable<NSWindow>(options: [.weakMemory, .objectPointerPersonality])
    private var closingWindows: Set<ObjectIdentifier> = []
    private var isStarted = false

    init(
        windows: @escaping WindowsProvider = { NSApp?.windows ?? [] },
        isVisible: @escaping WindowPredicate = { $0.isVisible },
        closeWindow: @escaping WindowAction = { $0.close() }
    ) {
        self.windows = windows
        self.isVisible = isVisible
        self.closeWindow = closeWindow
    }

    /// Sweeps now and whenever window state changes: SwiftUI presents the placeholder after launch
    /// finishes, and window restoration can bring it back later.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        for name in [
            NSApplication.didFinishLaunchingNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.didUpdateNotification
        ] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowStateDidChange(_:)), name: name, object: nil
            )
        }
        sweep()
    }

    @discardableResult
    func sweep() -> Int {
        var closedCount = 0
        for window in windows() {
            guard PlaceholderSettingsWindowDecision.shouldClose(
                identifier: window.identifier?.rawValue,
                frameAutosaveName: window.frameAutosaveName
            ) else { continue }
            guard isVisible(window) || !closedWindows.contains(window) else { continue }
            let identity = ObjectIdentifier(window)
            guard closingWindows.insert(identity).inserted else { continue }
            defer { closingWindows.remove(identity) }
            // Record before closing: close can synchronously post another window notification.
            closedWindows.add(window)
            window.isRestorable = false
            closeWindow(window)
            closedCount += 1
        }
        return closedCount
    }

    @objc private func windowStateDidChange(_ notification: Notification) {
        // AppKit posts these inside makeKeyAndOrderFront; closing there leaves the window stuck.
        DispatchQueue.main.async { [weak self] in
            self?.sweep()
        }
    }
}

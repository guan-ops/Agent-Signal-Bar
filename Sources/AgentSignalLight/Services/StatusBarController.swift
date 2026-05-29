import AppKit
import Combine
import AgentSignalLightCore
import AgentSignalLightUI
import SwiftUI

@MainActor
final class StatusBarController: NSObject, NSWindowDelegate {
    private let model: MenuBarStatusModel
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var recoveryWindow: NSWindow?
    private var didPresentRecoveryWindowForCurrentDisable = false
    private var lastRenderKey: StatusRenderKey?
    private var popoverOpenedAt = Date.distantPast
    private var cancellables = Set<AnyCancellable>()
    private let settingsOpenClickDebounce: TimeInterval = 0.25

    private struct StatusRenderKey: Equatable {
        let length: CGFloat
        let layout: TrafficSignalLayout
        let style: TrafficSignalStyle
        let macOSBreathingStrength: MacOSBreathingStrength
        let macOSHorizontalUsesTrafficLightSize: Bool
        let trafficLightVerticalUsesMacOSSize: Bool
        let allLightsOn: Bool
        let effectCustomization: SignalEffectCustomization
        let tooltip: String
        let visualFrame: [Int]
    }

    init(model: MenuBarStatusModel) {
        self.model = model
        super.init()
        bind()
        updateStatusItem()
    }

    private func bind() {
        model.$snapshot.sink { [weak self] _ in
            Task { @MainActor in self?.updateStatusItem() }
        }
        .store(in: &cancellables)

        model.$desktopAppSessions.sink { [weak self] _ in
            Task { @MainActor in self?.updateStatusItem() }
        }
        .store(in: &cancellables)

        model.animationClock.$tick.sink { [weak self] _ in
            Task { @MainActor in self?.updateStatusItem() }
        }
        .store(in: &cancellables)

        model.$displayLayout.sink { [weak self] _ in
            Task { @MainActor in self?.updateStatusItem() }
        }
        .store(in: &cancellables)

        model.$statusBarStyle.sink { [weak self] _ in
            Task { @MainActor in self?.updateStatusItem() }
        }
        .store(in: &cancellables)

        model.$macOSBreathingStrength.sink { [weak self] _ in
            Task { @MainActor in self?.updateStatusItem() }
        }
        .store(in: &cancellables)

        model.$thinkingSignalEffect.sink { [weak self] _ in
            Task { @MainActor in self?.updateStatusItem() }
        }
        .store(in: &cancellables)

        model.$activeSignalEffect.sink { [weak self] _ in
            Task { @MainActor in self?.updateStatusItem() }
        }
        .store(in: &cancellables)

        model.$activeEffectSpeed.sink { [weak self] _ in
            Task { @MainActor in self?.updateStatusItem() }
        }
        .store(in: &cancellables)

        model.$alertEffectSpeed.sink { [weak self] _ in
            Task { @MainActor in self?.updateStatusItem() }
        }
        .store(in: &cancellables)

        model.$completedSignalEffect.sink { [weak self] _ in
            Task { @MainActor in self?.updateStatusItem() }
        }
        .store(in: &cancellables)

        model.$macOSHorizontalUsesTrafficLightSize.sink { [weak self] _ in
            Task { @MainActor in self?.updateStatusItem() }
        }
        .store(in: &cancellables)

        model.$trafficLightVerticalUsesMacOSSize.sink { [weak self] _ in
            Task { @MainActor in self?.updateStatusItem() }
        }
        .store(in: &cancellables)

        model.$isStatusBarIconEnabled.sink { [weak self] _ in
            Task { @MainActor in self?.updateStatusItem() }
        }
        .store(in: &cancellables)

        model.$isStatusBarAllLightsOn.sink { [weak self] _ in
            Task { @MainActor in self?.updateStatusItem() }
        }
        .store(in: &cancellables)

        model.$signalLightAgentScope.sink { [weak self] _ in
            Task { @MainActor in self?.updateStatusItem() }
        }
        .store(in: &cancellables)

        model.$appLanguage.sink { [weak self] _ in
            Task { @MainActor in self?.updateStatusItem() }
        }
        .store(in: &cancellables)

        model.$appTheme.sink { [weak self] _ in
            Task { @MainActor in self?.applyAppAppearance() }
        }
        .store(in: &cancellables)
    }

    private func applyAppAppearance() {
        let appearance = model.appTheme.nsAppearance
        NSApp.appearance = appearance
        recoveryWindow?.appearance = appearance
        popover?.contentViewController?.view.appearance = appearance
        popover?.contentViewController?.view.window?.appearance = appearance
    }

    private func updateStatusItem() {
        guard model.isStatusBarIconEnabled else {
            if !didPresentRecoveryWindowForCurrentDisable {
                showRecoveryWindow()
                didPresentRecoveryWindowForCurrentDisable = true
            }
            lastRenderKey = nil
            removeStatusItem()
            writeStatusItemHealth()
            return
        }

        didPresentRecoveryWindowForCurrentDisable = false
        let displaySnapshot = model.displaySnapshot
        let length = StatusBarIconRenderer.statusItemLength(
            layout: model.displayLayout,
            style: model.statusBarStyle,
            macOSHorizontalUsesTrafficLightSize: model.macOSHorizontalUsesTrafficLightSize,
            trafficLightVerticalUsesMacOSSize: model.trafficLightVerticalUsesMacOSSize
        )
        let tooltip = model.statusBarTooltip
        let effectCustomization = model.signalEffectCustomization
        let renderKey = StatusRenderKey(
            length: length,
            layout: model.displayLayout,
            style: model.statusBarStyle,
            macOSBreathingStrength: model.macOSBreathingStrength,
            macOSHorizontalUsesTrafficLightSize: model.macOSHorizontalUsesTrafficLightSize,
            trafficLightVerticalUsesMacOSSize: model.trafficLightVerticalUsesMacOSSize,
            allLightsOn: model.isStatusBarAllLightsOn,
            effectCustomization: effectCustomization,
            tooltip: tooltip,
            visualFrame: Self.visualFrameSignature(
                snapshot: displaySnapshot,
                tick: model.tick,
                style: model.statusBarStyle,
                macOSBreathingStrength: model.macOSBreathingStrength,
                allLightsOn: model.isStatusBarAllLightsOn,
                effectCustomization: effectCustomization
            )
        )

        if renderKey == lastRenderKey, statusItem?.button?.image != nil {
            return
        }
        lastRenderKey = renderKey

        let item = ensureStatusItem()
        item.length = length
        item.button?.image = StatusBarIconRenderer.image(
            snapshot: displaySnapshot,
            tick: model.tick,
            layout: model.displayLayout,
            style: model.statusBarStyle,
            macOSBreathingStrength: model.macOSBreathingStrength,
            macOSHorizontalUsesTrafficLightSize: model.macOSHorizontalUsesTrafficLightSize,
            trafficLightVerticalUsesMacOSSize: model.trafficLightVerticalUsesMacOSSize,
            allLightsOn: model.isStatusBarAllLightsOn,
            effectCustomization: effectCustomization
        )
        item.button?.imagePosition = .imageOnly
        item.button?.toolTip = tooltip
        writeStatusItemHealth()
    }

    private static func visualFrameSignature(
        snapshot: SignalSnapshot,
        tick: Int,
        style: TrafficSignalStyle,
        macOSBreathingStrength: MacOSBreathingStrength,
        allLightsOn: Bool,
        effectCustomization: SignalEffectCustomization
    ) -> [Int] {
        SignalLampColor.allCases.flatMap { color in
            let intensity = SignalLampAnimation.intensity(
                color,
                signal: snapshot.aggregate,
                tick: tick,
                allLightsOn: allLightsOn,
                customization: effectCustomization
            )
            let scale = SignalVisualScale.lampScale(
                baseScale: SignalLampAnimation.scale(
                    color,
                    signal: snapshot.aggregate,
                    tick: tick,
                    allLightsOn: allLightsOn,
                    customization: effectCustomization
                ),
                intensity: intensity,
                style: style.visualStyle,
                macOSStrength: macOSBreathingStrength
            )
            return [
                Int((intensity * 1_000).rounded()),
                Int((scale * 1_000).rounded())
            ]
        }
    }

    private func ensureStatusItem() -> NSStatusItem {
        if let statusItem {
            return statusItem
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.behavior = []
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        statusItem = item
        return item
    }

    private func removeStatusItem() {
        guard let statusItem else { return }
        closePopover()
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
        lastRenderKey = nil
    }

    private func writeStatusItemHealth() {
        guard let healthFileURL = DebugLaunchOptions.statusItemHealthFileURL else {
            return
        }

        let button = statusItem?.button
        let payload: [String: Any] = [
            "schema_version": 1,
            "status_bar_icon_enabled": model.isStatusBarIconEnabled,
            "status_item_exists": statusItem != nil,
            "button_exists": button != nil,
            "image_exists": button?.image != nil,
            "action_exists": button?.action != nil,
            "autosave_name": statusItem?.autosaveName ?? "",
            "length": statusItem?.length ?? 0,
            "layout": model.displayLayout.rawValue,
            "style": model.statusBarStyle.rawValue,
            "aggregate": model.displaySnapshot.aggregate.rawValue,
            "tooltip_exists": !(button?.toolTip ?? "").isEmpty,
            "updated_at": ISO8601DateFormatter().string(from: Date())
        ]

        do {
            try FileManager.default.createDirectory(
                at: healthFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: healthFileURL, options: .atomic)
        } catch {
            model.lastError = "Status item health export failed: \(error.localizedDescription)"
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover?.isShown == true {
            closePopover()
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem?.button else { return }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentSize = NSSize(width: MenuBarPanelView.panelWidth, height: MenuBarPanelView.panelHeight)
        popoverOpenedAt = Date()
        popover.contentViewController = NSHostingController(
            rootView: MenuBarPanelView(model: model) { [weak self] in
                guard let self else { return }
                guard Date().timeIntervalSince(self.popoverOpenedAt) >= self.settingsOpenClickDebounce else {
                    return
                }
                self.closePopover()
                self.showDebugWindow()
            }
        )
        popover.contentViewController?.view.appearance = model.appTheme.nsAppearance
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        self.popover = popover

        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let window = self.popover?.contentViewController?.view.window
            else {
                return
            }

            window.appearance = self.model.appTheme.nsAppearance
            window.backgroundColor = .clear
            window.isOpaque = false
        }
    }

    private func closePopover() {
        popover?.performClose(nil)
        popover = nil
        popoverOpenedAt = .distantPast
    }

    func showDebugWindow() {
        showRecoveryWindow()
    }

    private func showRecoveryWindow() {
        if let recoveryWindow {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            recoveryWindow.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 768, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Agent Signal Bar"
        window.appearance = model.appTheme.nsAppearance
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentViewController = NSHostingController(
            rootView: DebugWindowView(model: model)
        )
        window.delegate = self
        window.center()
        recoveryWindow = window

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === recoveryWindow else {
            return true
        }

        sender.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
        return false
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === recoveryWindow
        else {
            return
        }

        DispatchQueue.main.async { [weak self, weak window] in
            guard let self,
                  let window,
                  self.recoveryWindow === window
            else {
                return
            }

            self.recoveryWindow = nil
            NSApp.setActivationPolicy(.regular)
        }
    }
}

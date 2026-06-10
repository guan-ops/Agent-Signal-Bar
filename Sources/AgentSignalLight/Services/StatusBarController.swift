import AppKit
import Combine
import AgentSignalLightCore
import AgentSignalLightUI
import SwiftUI

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate, NSPopoverDelegate, NSWindowDelegate {
    private let model: MenuBarStatusModel
    private var statusItem: NSStatusItem?
    private lazy var nativeStatusMenu: NSMenu = {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        return menu
    }()
    private var popover: NSPopover?
    private var recoveryWindow: NSWindow?
    private var didPresentRecoveryWindowForCurrentDisable = false
    private var lastRenderKey: StatusRenderKey?
    private var popoverOpenedAt = Date.distantPast
    private var cancellables = Set<AnyCancellable>()
    private let settingsOpenClickDebounce: TimeInterval = 0.25
    private lazy var floatingSignalController = FloatingSignalWindowController(model: model) { [weak self] in
        self?.showDebugWindow()
    }

    private struct StatusRenderKey: Equatable {
        let length: CGFloat
        let layout: TrafficSignalLayout
        let style: TrafficSignalStyle
        let macOSBreathingStrength: MacOSBreathingStrength
        let macOSHorizontalUsesTrafficLightSize: Bool
        let trafficLightVerticalUsesMacOSSize: Bool
        let allLightsOn: Bool
        let usesSystemGrayLights: Bool
        let effectCustomization: SignalEffectCustomization
        let statusMenuMode: StatusMenuMode
        let tooltip: String
        let visualFrame: [Int]
    }

    init(model: MenuBarStatusModel) {
        self.model = model
        super.init()
        bind()
        floatingSignalController.start()
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

        model.$presentationRefreshTick.sink { [weak self] _ in
            Task { @MainActor in self?.updateStatusItem() }
        }
        .store(in: &cancellables)

        model.$statusLightOverride.sink { [weak self] _ in
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

        model.$signalLightAgentScopes.sink { [weak self] _ in
            Task { @MainActor in self?.updateStatusItem() }
        }
        .store(in: &cancellables)

        model.$signalLightAgentSelectionMode.sink { [weak self] _ in
            Task { @MainActor in self?.updateStatusItem() }
        }
        .store(in: &cancellables)

        model.$statusMenuMode.sink { [weak self] _ in
            Task { @MainActor in self?.updateStatusItem() }
        }
        .store(in: &cancellables)

        model.$isMonitoringPaused.sink { [weak self] _ in
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
        floatingSignalController.applyAppearance()
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
        let lightSnapshot = model.lightSnapshot
        let lightTick = model.lightTick
        let lightAllLightsOn = model.lightAllLightsOn
        let lightUsesSystemGrayLights = model.lightUsesSystemGrayLights
        let lightEffectCustomization = model.lightEffectCustomization
        let length = StatusBarIconRenderer.statusItemLength(
            layout: model.displayLayout,
            style: model.statusBarStyle,
            macOSHorizontalUsesTrafficLightSize: model.macOSHorizontalUsesTrafficLightSize,
            trafficLightVerticalUsesMacOSSize: model.trafficLightVerticalUsesMacOSSize
        )
        let tooltip = model.statusBarTooltip
        let renderKey = StatusRenderKey(
            length: length,
            layout: model.displayLayout,
            style: model.statusBarStyle,
            macOSBreathingStrength: model.macOSBreathingStrength,
            macOSHorizontalUsesTrafficLightSize: model.macOSHorizontalUsesTrafficLightSize,
            trafficLightVerticalUsesMacOSSize: model.trafficLightVerticalUsesMacOSSize,
            allLightsOn: lightAllLightsOn,
            usesSystemGrayLights: lightUsesSystemGrayLights,
            effectCustomization: lightEffectCustomization,
            statusMenuMode: model.statusMenuMode,
            tooltip: tooltip,
            visualFrame: Self.visualFrameSignature(
                snapshot: lightSnapshot,
                tick: lightTick,
                style: model.statusBarStyle,
                macOSBreathingStrength: model.macOSBreathingStrength,
                allLightsOn: lightAllLightsOn,
                effectCustomization: lightEffectCustomization
            )
        )

        if renderKey == lastRenderKey, statusItem?.button?.image != nil {
            return
        }
        lastRenderKey = renderKey

        let item = ensureStatusItem()
        configureStatusItemMode(item)
        item.length = length
        item.button?.image = StatusBarIconRenderer.image(
            snapshot: lightSnapshot,
            tick: lightTick,
            layout: model.displayLayout,
            style: model.statusBarStyle,
            macOSBreathingStrength: model.macOSBreathingStrength,
            macOSHorizontalUsesTrafficLightSize: model.macOSHorizontalUsesTrafficLightSize,
            trafficLightVerticalUsesMacOSSize: model.trafficLightVerticalUsesMacOSSize,
            allLightsOn: lightAllLightsOn,
            usesSystemGrayLights: lightUsesSystemGrayLights,
            effectCustomization: lightEffectCustomization
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
        configureStatusItemMode(item)
        statusItem = item
        return item
    }

    private func configureStatusItemMode(_ item: NSStatusItem) {
        switch model.statusMenuMode {
        case .simple:
            closePopover()
            item.menu = nativeStatusMenu
            item.button?.target = nil
            item.button?.action = nil
        case .detailed:
            item.menu = nil
            item.button?.target = self
            item.button?.action = #selector(togglePopover(_:))
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        model.reload()
        rebuildNativeStatusMenu(menu)
    }

    private func rebuildNativeStatusMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let snapshot = model.lightSnapshot
        let activitySnapshot = model.activitySnapshot
        menu.addItem(infoMenuItem(title: "Agent Signal Bar", image: nativeStatusDotImage(for: model.lightSnapshot)))
        menu.addItem(infoMenuItem(title: "\(model.displayName(for: snapshot.aggregate)) · \(model.humanAction(for: snapshot.aggregate))"))

        if let updatedAt = snapshot.updatedAt {
            menu.addItem(infoMenuItem(title: "\(model.text("实时", "Live")) \(updatedAt.formatted(date: .omitted, time: .shortened))"))
        } else {
            menu.addItem(infoMenuItem(title: model.text("等待状态", "Waiting for status")))
        }

        let currentEvents = nativeCurrentEvents(from: activitySnapshot)
        if !currentEvents.isEmpty {
            menu.addItem(.separator())
            menu.addItem(infoMenuItem(title: model.text("当前", "Current")))
            for event in currentEvents {
                menu.addItem(infoMenuItem(title: nativeSessionMenuTitle(event)))
            }
        }

        menu.addItem(.separator())
        addOpenAgentMenuItems(to: menu, snapshot: activitySnapshot)
        menu.addItem(actionMenuItem(
            model.isMonitoringPaused ? model.text("继续监控", "Resume Monitoring") : model.text("暂停监控", "Pause Monitoring"),
            imageName: model.isMonitoringPaused ? "play.fill" : "pause.fill",
            action: #selector(toggleMonitoringFromMenu)
        ))
        menu.addItem(actionMenuItem(
            model.isFloatingSignalEnabled ? model.text("隐藏悬浮灯", "Hide Floating Signal") : model.text("显示悬浮灯", "Show Floating Signal"),
            imageName: model.isFloatingSignalEnabled ? "eye.slash" : "eye",
            action: #selector(toggleFloatingSignalFromMenu)
        ))
        menu.addItem(actionMenuItem(
            model.isFloatingSignalSoundEnabled ? model.text("关闭声音提醒", "Turn Sound Off") : model.text("开启声音提醒", "Turn Sound On"),
            imageName: model.isFloatingSignalSoundEnabled ? "speaker.slash" : "speaker.wave.2",
            action: #selector(toggleFloatingSignalSoundFromMenu)
        ))
        menu.addItem(.separator())
        menu.addItem(actionMenuItem(model.text("设置", "Settings"), imageName: "gearshape", action: #selector(openSettingsFromMenu)))
        menu.addItem(actionMenuItem(model.text("退出", "Quit"), imageName: "power", action: #selector(quitFromMenu)))
    }

    private func infoMenuItem(
        title: String,
        image: NSImage? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.image = image
        return item
    }

    private func actionMenuItem(_ title: String, imageName: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: imageName, accessibilityDescription: title)
        return item
    }

    private func addOpenAgentMenuItems(to menu: NSMenu, snapshot: SignalSnapshot) {
        let agents = nativeRunningAgentKeys(from: snapshot)
        if agents.isEmpty {
            menu.addItem(actionMenuItem(model.text("打开 Codex", "Open Codex"), imageName: "terminal", action: #selector(openCodexFromMenu)))
            menu.addItem(actionMenuItem(model.text("打开 Claude", "Open Claude"), imageName: "sparkles", action: #selector(openClaudeFromMenu)))
            return
        }

        if agents.contains("codex") {
            menu.addItem(actionMenuItem(model.text("打开 Codex", "Open Codex"), imageName: "terminal", action: #selector(openCodexFromMenu)))
        }

        if agents.contains("claude") {
            menu.addItem(actionMenuItem(model.text("打开 Claude", "Open Claude"), imageName: "sparkles", action: #selector(openClaudeFromMenu)))
        }
    }

    private func nativeRunningAgentKeys(from snapshot: SignalSnapshot) -> Set<String> {
        Set(
            nativeVisibleAgentSessions(from: snapshot)
                .map { normalizedNativeAgentKey($0.agent, fallback: $0.sessionID) }
                .filter { $0 == "codex" || $0 == "claude" }
        )
    }

    private func nativeCurrentEvents(from snapshot: SignalSnapshot) -> [SessionStatus] {
        nativeVisibleAgentSessions(from: snapshot)
    }

    private func nativeVisibleAgentSessions(from snapshot: SignalSnapshot) -> [SessionStatus] {
        var seenSources = Set<String>()
        var sessions: [SessionStatus] = []

        for session in snapshot.sessions {
            guard isVisibleNativeAgentSession(session) else { continue }
            let sourceKey = ActivityPresentation.activitySourceKey(for: session)
            guard !seenSources.contains(sourceKey) else { continue }
            seenSources.insert(sourceKey)
            sessions.append(session)
        }

        return sessions
    }

    private func isVisibleNativeAgentSession(_ session: SessionStatus) -> Bool {
        if session.sessionID.hasPrefix("desktop-app:")
            || session.sessionID.hasPrefix("platform-presence:")
            || session.lastEvent == "DesktopAppRunning"
            || session.lastEvent?.hasPrefix("PlatformPresence:") == true {
            return true
        }

        switch session.signal.displayState {
        case .active:
            return Date().timeIntervalSince(session.updatedAt) <= 5 * 60
        case .completed, .needsReview, .permission, .blocked, .stale:
            return true
        case .ready, .paused:
            return false
        }
    }

    private func normalizedNativeAgentKey(_ agent: String?, fallback: String) -> String {
        guard let agent, !agent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return fallback
        }

        let normalized = agent
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")

        switch normalized {
        case "codex", "codex-desktop", "codex-cli", "codex-ide", "codex-xcode",
             "codex-terminal", "terminal-codex", "codex-tui", "codex-shell",
             "idea-codex", "intellij-codex", "jetbrains-codex", "codex-idea",
             "codex-intellij", "codex-jetbrains", "codex-vscode", "vscode-codex",
             "xcode-codex":
            return "codex"
        case "claude", "claude-code", "claude-desktop", "claude-cli",
             "claude-terminal", "terminal-claude", "claude-ide",
             "idea-claude", "intellij-claude", "jetbrains-claude":
            return "claude"
        default:
            return normalized
        }
    }

    private func nativeSessionMenuTitle(_ session: SessionStatus) -> String {
        let agent = model.activitySessionTitle(for: session)
        let eventName = nativeShortEventName(rawEvent: session.lastEvent, signal: session.signal)

        return "\(agent) · \(eventName)"
    }

    private func nativeShortEventName(rawEvent: String?, signal: AgentSignal) -> String {
        guard let rawEvent, !rawEvent.isEmpty else {
            return nativeShortSignalName(signal)
        }

        if rawEvent.hasPrefix("DesktopToolCall:") || rawEvent.hasPrefix("PreToolUse:") {
            return model.text("正在执行", "Running")
        }

        if rawEvent.hasPrefix("PostToolUse:") {
            return model.text("步骤完成", "Step Done")
        }

        if rawEvent.hasPrefix("PostToolUseFailure:") {
            return model.text("失败", "Failed")
        }

        switch rawEvent {
        case "PreToolUse":
            return model.text("正在执行", "Running")
        case "PostToolUse", "DesktopToolDone":
            return model.text("步骤完成", "Step Done")
        case "PostToolUseFailure", "StopFailure":
            return model.text("失败", "Failed")
        case "DesktopMessage":
            return model.text("输出中", "Responding")
        case "DesktopThinking", "DesktopTaskStarted", "UserPromptSubmit":
            return model.text("思考中", "Thinking")
        case "DesktopActivityHeartbeat":
            return model.text("活动中", "Active")
        case "DesktopContextCompacted":
            return model.text("整理上下文", "Compacting")
        case "DesktopTaskComplete", "TaskCompleted", "Stop":
            return model.text("完成", "Done")
        case "DesktopTurnAborted":
            return model.text("已取消", "Canceled")
        case "DesktopAppRunning":
            return model.text("桌面版运行中", "Desktop app running")
        case let event where event.hasPrefix("PlatformPresence:"):
            return nativeShortSignalName(signal)
        case "PermissionRequest":
            return model.text("等待授权", "Waiting for Permission")
        case "Notification":
            return model.text("通知", "Notification")
        case "SessionStart":
            return model.text("开始", "Started")
        case "SessionEnd":
            return model.text("会话结束", "Session Ended")
        default:
            return nativeShortSignalName(signal)
        }
    }

    private func nativeShortSignalName(_ signal: AgentSignal) -> String {
        switch signal.displayState {
        case .ready:
            return model.text("空闲", "Idle")
        case .active:
            return model.text("运行中", "Running")
        case .completed:
            return model.text("完成", "Done")
        case .needsReview:
            return model.text("需要查看", "Needs Review")
        case .permission:
            return model.text("等待授权", "Waiting for Permission")
        case .blocked:
            return model.text("阻塞", "Blocked")
        case .stale:
            return model.text("状态过期", "Stale")
        case .paused:
            return model.text("已暂停", "Paused")
        }
    }

    private func nativeStatusDotImage(for snapshot: SignalSnapshot) -> NSImage {
        let color = nativeStatusDotColor(for: snapshot)
        let size = NSSize(width: 14, height: 14)
        let image = NSImage(size: size, flipped: false) { rect in
            let diameter: CGFloat = 10
            let dotRect = NSRect(
                x: (rect.width - diameter) / 2,
                y: (rect.height - diameter) / 2,
                width: diameter,
                height: diameter
            )
            color.setFill()
            NSBezierPath(ovalIn: dotRect).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    private func nativeStatusDotColor(for snapshot: SignalSnapshot) -> NSColor {
        if model.lightUsesSystemGrayLights {
            return .systemGray
        }

        return nativeNSColor(for: preferredNativeStatusLampColor(for: snapshot.aggregate))
    }

    private func preferredNativeStatusLampColor(for signal: AgentSignal) -> SignalLampColor {
        switch signal.displayState {
        case .ready:
            return .green
        case .active:
            return preferredActiveLampColor(for: signal)
        case .completed:
            return preferredCompletedLampColor()
        case .needsReview, .stale, .paused:
            return .yellow
        case .permission, .blocked:
            return .red
        }
    }

    private func preferredActiveLampColor(for signal: AgentSignal) -> SignalLampColor {
        let effect = signal == .thinking ? model.thinkingSignalEffect : model.activeSignalEffect
        switch effect {
        case .trafficCycle:
            let activeTick = max(model.tick, 0)
            let ticksPerColor = 4
            let phaseColors: [SignalLampColor] = [.red, .yellow, .green]
            return phaseColors[(activeTick / ticksPerColor) % phaseColors.count]
        case .greenBreathing, .greenSteady, .greenSlowFlash, .greenFastFlash:
            return .green
        }
    }

    private func preferredCompletedLampColor() -> SignalLampColor {
        switch model.completedSignalEffect {
        case .yellowPulse, .yellowSteady:
            return .yellow
        case .greenPulse, .greenSteady, .allSteady, .allPulse:
            return .green
        }
    }

    private func nativeNSColor(for color: SignalLampColor) -> NSColor {
        switch color {
        case .red:
            return NSColor(calibratedRed: 1.0, green: 0.27, blue: 0.23, alpha: 1)
        case .yellow:
            return NSColor(calibratedRed: 1.0, green: 0.78, blue: 0.12, alpha: 1)
        case .green:
            return NSColor(calibratedRed: 0.18, green: 0.80, blue: 0.36, alpha: 1)
        }
    }

    @objc private func openCodexFromMenu() {
        model.openCodex()
    }

    @objc private func openClaudeFromMenu() {
        model.openClaude()
    }

    @objc private func toggleMonitoringFromMenu() {
        model.toggleMonitoring()
    }

    @objc private func toggleFloatingSignalFromMenu() {
        model.setFloatingSignalEnabled(!model.isFloatingSignalEnabled)
    }

    @objc private func toggleFloatingSignalSoundFromMenu() {
        model.setFloatingSignalSoundEnabled(!model.isFloatingSignalSoundEnabled)
    }

    @objc private func openSettingsFromMenu() {
        showDebugWindow()
    }

    @objc private func quitFromMenu() {
        NSApplication.shared.terminate(nil)
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
            "menu_exists": statusItem?.menu != nil,
            "status_menu_mode": model.statusMenuMode.rawValue,
            "autosave_name": statusItem?.autosaveName ?? "",
            "length": statusItem?.length ?? 0,
            "layout": model.displayLayout.rawValue,
            "style": model.statusBarStyle.rawValue,
            "aggregate": model.lightSnapshot.aggregate.rawValue,
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

        model.reload()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
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

    func popoverDidClose(_ notification: Notification) {
        guard let closedPopover = notification.object as? NSPopover,
              closedPopover === popover
        else {
            return
        }

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
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 840),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Agent Signal Bar"
        configureRecoveryWindowChrome(window)
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

    private func configureRecoveryWindowChrome(_ window: NSWindow) {
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.backgroundColor = .clear
        window.isOpaque = false
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === recoveryWindow else {
            return true
        }

        guard model.isStatusBarIconEnabled else {
            model.lastError = model.text(
                "请先开启状态栏信号，否则关闭此窗口后将无法从状态栏重新打开设置。",
                "Turn on the status bar signal before closing this window, otherwise Settings cannot be reopened from the status bar."
            )
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            sender.makeKeyAndOrderFront(nil)
            return false
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

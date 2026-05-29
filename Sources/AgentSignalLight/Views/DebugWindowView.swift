import AgentSignalLightCore
import AgentSignalLightUI
import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct DebugWindowView: View {
    @ObservedObject var model: MenuBarStatusModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedSettingsTab: SettingsTab = .activity
    @State private var settingsTabOrder: [SettingsTab] = SettingsTab.savedOrder
    @State private var draggedSettingsTab: SettingsTab?
    @State private var showsAdvancedSignals = false
    @State private var expandedSettingsDropdown: SettingsDropdownID?
    private let activityRecentEventLimit = 15

    var body: some View {
        ZStack {
            settingsWindowBackground
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 22)
                    .padding(.top, 20)
                    .padding(.bottom, 16)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(2)

                Divider()

                settingsMenu
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(2)

                Divider()

                settingsContentArea
            }
        }
        .frame(width: 768, height: 900)
        .preferredColorScheme(model.appTheme.colorScheme)
    }

    private var settingsMenu: some View {
        HStack(spacing: 4) {
            ForEach(settingsTabOrder) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.14)) {
                        closeSettingsDropdown()
                        selectedSettingsTab = tab
                    }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.systemImage)
                            .font(settingsTabIconFont)
                            .frame(width: 18, height: 18)
                        Text(menuTitle(for: tab))
                            .font(settingsTabTitleFont)
                            .lineLimit(1)
                            .allowsTightening(true)
                            .minimumScaleFactor(0.85)
                            .frame(height: 14)
                    }
                    .foregroundStyle(selectedSettingsTab == tab ? Color.accentColor : Color.primary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .contentShape(Rectangle())
                    .background {
                        if selectedSettingsTab == tab {
                            glassControlBackground(cornerRadius: 7)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(selectedMenuItemTint)
                                }
                        }
                    }
                }
                .buttonStyle(.plain)
                .opacity(draggedSettingsTab == tab ? 0.55 : 1)
                .onDrag {
                    draggedSettingsTab = tab
                    return NSItemProvider(object: tab.rawValue as NSString)
                }
                .onDrop(
                    of: [.plainText],
                    delegate: SettingsTabDropDelegate(
                        destination: tab,
                        order: $settingsTabOrder,
                        draggedTab: $draggedSettingsTab
                    )
                )
                .help("\(menuTitle(for: tab)) · \(model.text("按住并拖动可调整位置", "Hold and drag to reorder"))")
            }
        }
        .frame(height: 48)
    }

    private var settingsContentArea: some View {
        GeometryReader { proxy in
            ScrollView {
                ZStack(alignment: .topLeading) {
                    if expandedSettingsDropdown != nil {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture {
                                closeSettingsDropdown()
                            }
                            .zIndex(0)
                    }

                    VStack(alignment: .leading, spacing: 16) {
                        selectedSettingsContent

                        if let lastError = model.lastError {
                            Divider()

                            Text(lastError)
                                .font(settingsBodyFont)
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .zIndex(1)
                }
                .padding(22)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .topLeading)
            }
            .scrollIndicators(.hidden)
            .scrollContentBackground(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var selectedSettingsContent: some View {
        switch selectedSettingsTab {
        case .general:
            generalSettings
        case .activity:
            activitySettings
        case .appearance:
            appearanceSettings
        case .signals:
            manualSignalSettings
        case .connections:
            connectionSettings
        case .about:
            developerInfoSettings
        }
    }

    private func menuTitle(for tab: SettingsTab) -> String {
        switch tab {
        case .general:
            return model.text("通用", "General")
        case .activity:
            return model.text("运行", "Activity")
        case .appearance:
            return model.text("样式", "Style")
        case .signals:
            return model.text("灯效", "Effects")
        case .connections:
            return model.text("连接", "Connect")
        case .about:
            return model.text("关于", "About")
        }
    }

    fileprivate enum SettingsTab: String, CaseIterable, Identifiable {
        case activity
        case general
        case appearance
        case signals
        case connections
        case about

        var id: String { rawValue }

        static var savedOrder: [SettingsTab] {
            guard let rawValues = UserDefaults.standard.stringArray(forKey: orderDefaultsKey) else {
                return defaultOrder
            }

            let restored = rawValues.compactMap(SettingsTab.init(rawValue:))
            guard Set(restored) == Set(allCases), restored.count == allCases.count else {
                return defaultOrder
            }

            return restored
        }

        static func saveOrder(_ tabs: [SettingsTab]) {
            UserDefaults.standard.set(tabs.map(\.rawValue), forKey: orderDefaultsKey)
        }

        private static let orderDefaultsKey = "settingsTabOrder"

        private static let defaultOrder: [SettingsTab] = [
            .activity,
            .appearance,
            .signals,
            .connections,
            .general,
            .about
        ]

        var systemImage: String {
            switch self {
            case .general:
                return "gearshape"
            case .activity:
                return "waveform.path.ecg"
            case .appearance:
                return "paintpalette"
            case .signals:
                return "lightbulb"
            case .connections:
                return "link"
            case .about:
                return "info.circle"
            }
        }
    }

    private enum DotHorizontalSizeOption: Hashable {
        case standard
        case small
    }

    private enum LampVerticalSizeOption: Hashable {
        case standard
        case large
    }

    private enum SettingsDropdownID: Hashable {
        case openAgent
        case language
        case theme
        case signalLightAgentScope
        case thinkingEffect
        case workingEffect
        case doneEffect
    }

    private var settingsHeaderTitleFont: Font {
        .system(size: usesCompactLatinLayout ? 16 : 17, weight: .semibold)
    }

    private var settingsTabIconFont: Font {
        .system(size: 14, weight: .medium)
    }

    private var settingsTabTitleFont: Font {
        .system(size: usesCompactLatinLayout ? 11 : 11.5, weight: .medium)
    }

    private var settingsSectionTitleFont: Font {
        .system(size: usesCompactLatinLayout ? 15 : 16, weight: .semibold)
    }

    private var settingsSubsectionTitleFont: Font {
        .system(size: usesCompactLatinLayout ? 13 : 14, weight: .semibold)
    }

    private var settingsRowTitleFont: Font {
        .system(size: usesCompactLatinLayout ? 13 : 13.5, weight: .semibold)
    }

    private var settingsControlFont: Font {
        .system(size: usesCompactLatinLayout ? 12 : 13, weight: .semibold)
    }

    private var settingsBodyFont: Font {
        .system(size: usesCompactLatinLayout ? 12 : 13, weight: .regular)
    }

    private var settingsBodyStrongFont: Font {
        .system(size: usesCompactLatinLayout ? 12 : 13, weight: .semibold)
    }

    private var settingsDetailFont: Font {
        .system(size: usesCompactLatinLayout ? 11.5 : 12, weight: .regular)
    }

    private var settingsDetailStrongFont: Font {
        .system(size: usesCompactLatinLayout ? 11.5 : 12, weight: .semibold)
    }

    private var settingsTinyIconFont: Font {
        .system(size: 11, weight: .bold)
    }

    private var settingsIconFont: Font {
        .system(size: usesCompactLatinLayout ? 12 : 13, weight: .semibold)
    }

    private var usesCompactLatinLayout: Bool {
        model.appLanguage.usesCompactLatinLayout
    }

    private var header: some View {
        ZStack {
            HStack(spacing: 16) {
                TrafficSignalView(
                    snapshot: model.displaySnapshot,
                    tick: 0,
                    size: .panel,
                    layout: .horizontal,
                    style: .trafficLight,
                    macOSBreathingStrength: model.macOSBreathingStrength,
                    macOSHorizontalUsesTrafficLightSize: model.macOSHorizontalUsesTrafficLightSize,
                    trafficLightVerticalUsesMacOSSize: model.trafficLightVerticalUsesMacOSSize,
                    allLightsOn: true,
                    effectCustomization: model.signalEffectCustomization
                )
                .scaleEffect(1.14)
                .frame(width: 90, height: 34)

                Text("Agent Signal Bar")
                    .font(settingsHeaderTitleFont)
            }
            .frame(maxWidth: .infinity)

            HStack {
                Spacer()

                Button {
                    model.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help(model.text("刷新", "Refresh"))
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsSection(model.text("通用", "General")) {
                settingRow(model.text("语言", "Language")) {
                    languageMenu
                }
                .zIndex(expandedSettingsDropdown == .language ? 1000 : 0)

                settingRow(model.text("主题", "Theme")) {
                    themeMenu
                }
                .zIndex(expandedSettingsDropdown == .theme ? 1000 : 0)

                Toggle(model.text("设置毛玻璃", "Settings glass"), isOn: settingsGlassEnabledBinding)
                    .font(settingsRowTitleFont)
                    .toggleStyle(.switch)

                if model.isSettingsGlassEnabled {
                    settingRow(model.text("毛玻璃效果", "Glass style")) {
                        compactSegmentedControl(
                            options: SettingsGlassEffect.allCases,
                            selection: settingsGlassEffectBinding
                        ) { effect in
                            model.displayName(for: effect)
                        }
                    }
                }

                Toggle(model.text("开机自启动", "Start at login"), isOn: launchAtLoginBinding)
                    .font(settingsRowTitleFont)
                    .toggleStyle(.switch)
                    .disabled(model.isLaunchAtLoginChangeRunning)
                    .help(model.text("登录 macOS 后自动打开 Agent Signal Bar", "Open Agent Signal Bar automatically after macOS login"))

                HStack(alignment: .top, spacing: 8) {
                    settingsOpenAgentDropdown

                    Button {
                        model.clearWarnings()
                    } label: {
                        settingsActionSurface(
                            model.text("清除提醒", "Clear Warning"),
                            systemImage: "xmark.circle"
                        )
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .zIndex(expandedSettingsDropdown == .openAgent ? 1000 : 0)
            }
            .zIndex(isGeneralDropdownExpanded ? 10 : 1)

            Divider()
                .zIndex(0)

            statusBarSettings
                .zIndex(0)
        }
    }

    private var isGeneralDropdownExpanded: Bool {
        switch expandedSettingsDropdown {
        case .language, .theme, .openAgent, .signalLightAgentScope:
            return true
        default:
            return false
        }
    }

    private var settingsOpenAgentDropdown: some View {
        inlineDropdown(
            id: .openAgent,
            title: model.text("打开 Agent", "Open Agent"),
            systemImage: "app",
            width: settingsActionButtonWidth
        ) {
            dropdownOptions(width: settingsActionButtonWidth) {
                dropdownOption("Codex", systemImage: "terminal", width: settingsActionButtonWidth) {
                    model.openCodex()
                }

                dropdownOption("Claude", systemImage: "sparkles", width: settingsActionButtonWidth) {
                    model.openClaude()
                }
            }
        }
    }

    private var languageMenu: some View {
        inlineDropdown(
            id: .language,
            title: model.displayName(for: model.appLanguage),
            width: settingsPickerWidth
        ) {
            dropdownOptions(width: settingsPickerWidth) {
                ForEach(AppLanguage.allCases, id: \.self) { language in
                    dropdownOption(
                        model.displayName(for: language),
                        isSelected: model.appLanguage == language,
                        width: settingsPickerWidth
                    ) {
                        model.setAppLanguage(language)
                    }
                }
            }
        }
    }

    private var themeMenu: some View {
        inlineDropdown(
            id: .theme,
            title: model.displayName(for: model.appTheme),
            width: settingsPickerWidth
        ) {
            dropdownOptions(width: settingsPickerWidth) {
                ForEach(AppTheme.allCases, id: \.self) { theme in
                    dropdownOption(
                        model.displayName(for: theme),
                        isSelected: model.appTheme == theme,
                        width: settingsPickerWidth
                    ) {
                        model.setAppTheme(theme)
                    }
                }
            }
        }
    }

    private var signalLightAgentScopeMenu: some View {
        inlineDropdown(
            id: .signalLightAgentScope,
            title: model.displayName(for: model.signalLightAgentScope),
            width: settingsPickerWidth
        ) {
            dropdownOptions(width: settingsPickerWidth) {
                ForEach(SignalLightAgentScope.allCases, id: \.self) { scope in
                    dropdownOption(
                        model.displayName(for: scope),
                        isSelected: model.signalLightAgentScope == scope,
                        width: settingsPickerWidth
                    ) {
                        model.setSignalLightAgentScope(scope)
                    }
                }
            }
        }
    }

    private var thinkingEffectMenu: some View {
        inlineDropdown(
            id: .thinkingEffect,
            title: model.displayName(for: model.thinkingSignalEffect),
            width: effectMenuWidth
        ) {
            dropdownOptions(width: effectMenuWidth) {
                ForEach(ActiveSignalEffect.allCases, id: \.self) { effect in
                    dropdownOption(
                        model.displayName(for: effect),
                        isSelected: model.thinkingSignalEffect == effect,
                        width: effectMenuWidth
                    ) {
                        model.setThinkingSignalEffect(effect)
                    }
                }
            }
        }
    }

    private var workingEffectMenu: some View {
        inlineDropdown(
            id: .workingEffect,
            title: model.displayName(for: model.activeSignalEffect),
            width: effectMenuWidth
        ) {
            dropdownOptions(width: effectMenuWidth) {
                ForEach(ActiveSignalEffect.allCases, id: \.self) { effect in
                    dropdownOption(
                        model.displayName(for: effect),
                        isSelected: model.activeSignalEffect == effect,
                        width: effectMenuWidth
                    ) {
                        model.setActiveSignalEffect(effect)
                    }
                }
            }
        }
    }

    private var doneEffectMenu: some View {
        inlineDropdown(
            id: .doneEffect,
            title: model.displayName(for: model.completedSignalEffect),
            width: effectMenuWidth
        ) {
            dropdownOptions(width: effectMenuWidth) {
                ForEach(CompletedSignalEffect.allCases, id: \.self) { effect in
                    dropdownOption(
                        model.displayName(for: effect),
                        isSelected: model.completedSignalEffect == effect,
                        width: effectMenuWidth
                    ) {
                        model.setCompletedSignalEffect(effect)
                    }
                }
            }
        }
    }

    private var activitySettings: some View {
        settingsSection(model.text("运行详情", "Agent Activity")) {
            VStack(alignment: .leading, spacing: 14) {
                settingRow(model.text("灯效 Agent", "Light Agent")) {
                    compactSegmentedControl(
                        options: SignalLightAgentScope.allCases,
                        selection: signalLightAgentScopeBinding
                    ) { scope in
                        model.displayName(for: scope)
                    }
                }

                activitySummaryCard

                Divider()

                activitySessions

                Divider()

                activityEvents
            }
        }
    }

    private var activitySummaryCard: some View {
        HStack(alignment: .top, spacing: 12) {
            ActivitySignalLampView(model: model)

            VStack(alignment: .leading, spacing: 4) {
                Text(model.displayName(for: model.displaySnapshot.aggregate))
                    .font(settingsSubsectionTitleFont)
                Text(model.summary(for: model.displaySnapshot.aggregate))
                    .font(settingsBodyFont)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(activityUpdatedText(model.displaySnapshot.updatedAt))
                    .font(settingsDetailFont)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 16)

            VStack(alignment: .trailing, spacing: 4) {
                Label(
                    model.isMonitoringPaused ? model.text("监控已暂停", "Monitoring paused") : model.text("实时监控", "Live monitoring"),
                    systemImage: model.isMonitoringPaused ? "pause.circle" : "dot.radiowaves.left.and.right"
                )
                .font(settingsDetailStrongFont)
                .foregroundStyle(model.isMonitoringPaused ? .orange : .secondary)

                Text("\(model.displaySnapshot.sessions.count) \(model.text("个会话", "sessions"))")
                    .font(settingsDetailFont)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background(.tertiary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var activitySessions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.text("当前会话", "Active Sessions"))
                .font(settingsBodyStrongFont)
                .foregroundStyle(.secondary)

            if visibleActivitySessions.isEmpty {
                emptyActivityRow(
                    icon: "checkmark.circle",
                    title: model.text("暂无运行中的 Agent", "No active agent sessions"),
                    subtitle: model.text("状态栏会在收到 Agent 事件后自动更新。", "The status bar updates automatically when an agent reports activity.")
                )
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(visibleActivitySessions) { session in
                        activitySessionRow(session)
                    }
                }
            }
        }
    }

    private var visibleActivitySessions: [SessionStatus] {
        var seenAgents: Set<String> = []
        var sessions: [SessionStatus] = []

        for session in model.displaySnapshot.sessions {
            guard isVisibleActivitySession(session) else { continue }
            let agentKey = normalizedActivityAgentKey(session.agent, fallback: session.sessionID)
            guard !seenAgents.contains(agentKey) else { continue }
            seenAgents.insert(agentKey)
            sessions.append(session)
            if sessions.count == 4 {
                break
            }
        }

        return sessions
    }

    private func isVisibleActivitySession(_ session: SessionStatus) -> Bool {
        if isDesktopPresenceSession(session) {
            return true
        }

        guard session.signal.displayState == .active else { return false }
        return Date().timeIntervalSince(session.updatedAt) <= liveActivitySessionWindow
    }

    private func isDesktopPresenceSession(_ session: SessionStatus) -> Bool {
        session.sessionID.hasPrefix("desktop-app:") || session.lastEvent == "DesktopAppRunning"
    }

    private var liveActivitySessionWindow: TimeInterval {
        5 * 60
    }

    private func normalizedActivityAgentKey(_ agent: String?, fallback: String) -> String {
        guard let agent, !agent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return fallback
        }

        let normalized = agent
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")

        switch normalized {
        case "codex", "codex-desktop", "codex-cli", "codex-ide":
            return "codex"
        case "claude", "claude-code", "claude-desktop":
            return "claude"
        default:
            return normalized
        }
    }

    private var activityEvents: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.text("最近事件", "Recent Events"))
                .font(settingsBodyStrongFont)
                .foregroundStyle(.secondary)

            if model.displaySnapshot.recentEvents.isEmpty {
                emptyActivityRow(
                    icon: "clock",
                    title: model.text("还没有最近事件", "No recent events yet"),
                    subtitle: model.text("安装连接后，Codex、Claude Code 或其他 Agent 的事件会显示在这里。", "After connection, events from Codex, Claude Code, or other agents appear here.")
                )
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(model.displaySnapshot.recentEvents.prefix(activityRecentEventLimit)) { event in
                        activityEventRow(event)
                    }
                }
            }
        }
    }

    private var statusBarSettings: some View {
        settingsSection(model.text("状态栏", "Status Bar")) {
            Toggle(model.text("显示状态栏信号", "Show status bar signal"), isOn: statusBarEnabledBinding)
                .font(settingsRowTitleFont)
                .toggleStyle(.switch)

            settingRow(model.text("灯效 Agent", "Light Agent")) {
                signalLightAgentScopeMenu
            }
            .zIndex(expandedSettingsDropdown == .signalLightAgentScope ? 1000 : 0)

            Label {
                Text(model.text(
                    "按住 ⌘ 并拖动状态栏信号灯，可以调整它在状态栏中的位置。",
                    "Hold Command and drag the status bar signal to move its position."
                ))
            } icon: {
                Image(systemName: "command")
            }
            .font(settingsBodyFont)
            .foregroundStyle(.secondary)
        }
    }

    private var appearanceSettings: some View {
        settingsSection(model.text("样式", "Style")) {
            settingRow(model.text("状态栏风格", "Status bar style")) {
                compactSegmentedControl(
                    options: TrafficSignalStyle.allCases,
                    selection: statusBarStyleBinding
                ) { style in
                    model.displayName(for: style)
                }
            }

            settingRow(model.text("方向", "Direction")) {
                compactSegmentedControl(
                    options: TrafficSignalLayout.allCases,
                    selection: displayLayoutBinding
                ) { layout in
                    model.displayName(for: layout)
                }
            }

            settingRow(model.text("圆点横向尺寸", "Horizontal dot size")) {
                compactSegmentedControl(
                    options: [DotHorizontalSizeOption.standard, .small],
                    selection: macOSHorizontalSizeBinding
                ) { option in
                    switch option {
                    case .standard:
                        model.text("默认", "Default")
                    case .small:
                        model.text("小", "Small")
                    }
                }
            }

            settingRow(model.text("灯牌竖向尺寸", "Vertical lamp size")) {
                compactSegmentedControl(
                    options: [LampVerticalSizeOption.standard, .large],
                    selection: lampVerticalSizeBinding
                ) { option in
                    switch option {
                    case .standard:
                        model.text("默认", "Default")
                    case .large:
                        model.text("大", "Large")
                    }
                }
            }
        }
    }

    private var manualSignalSettings: some View {
        settingsSection(model.text("灯效", "Effects")) {
            VStack(alignment: .leading, spacing: 14) {
                settingsSubsection(model.text("灯效自定义", "Effect Customization")) {
                    settingRow(model.text("思考灯效", "Thinking effect")) {
                        thinkingEffectMenu
                    }
                    .zIndex(expandedSettingsDropdown == .thinkingEffect ? 1000 : 0)

                    settingRow(model.text("工作灯效", "Working effect")) {
                        workingEffectMenu
                    }
                    .zIndex(expandedSettingsDropdown == .workingEffect ? 1000 : 0)

                    settingRow(model.text("工作灯效速度", "Work effect speed")) {
                        compactSegmentedControl(
                            options: SignalEffectSpeed.allCases,
                            selection: activeEffectSpeedBinding
                        ) { speed in
                            model.displayName(for: speed)
                        }
                    }

                    settingRow(model.text("提醒闪烁速度", "Alert flash speed")) {
                        compactSegmentedControl(
                            options: SignalEffectSpeed.allCases,
                            selection: alertEffectSpeedBinding
                        ) { speed in
                            model.displayName(for: speed)
                        }
                    }

                    settingRow(model.text("完成灯效", "Done effect")) {
                        doneEffectMenu
                    }
                    .zIndex(expandedSettingsDropdown == .doneEffect ? 1000 : 0)

                    settingRow(model.text("呼吸强度", "Breathing strength")) {
                        compactSegmentedControl(
                            options: MacOSBreathingStrength.allCases,
                            selection: macOSBreathingStrengthBinding
                        ) { strength in
                            model.displayName(for: strength)
                        }
                    }
                }

                Divider()

                settingsSubsection(model.text("灯效测试", "Signal Test")) {
                    Toggle(model.text("启用灯效测试", "Enable signal test"), isOn: signalTestModeBinding)
                        .font(settingsRowTitleFont)
                        .toggleStyle(.switch)
                        .help(model.text("关闭后会退出手动测试，并恢复真实 Agent 状态。", "Turn this off to leave manual testing and return to live agent status."))

                    Toggle(model.text("状态栏全亮", "All lights preview"), isOn: statusBarAllLightsBinding)
                        .font(settingsRowTitleFont)
                        .toggleStyle(.switch)
                        .disabled(!model.isSignalTestModeEnabled)

                    Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                        GridRow {
                            actionButton(model.text("空闲", "Idle"), systemImage: "checkmark.circle", signal: .idle)
                            actionButton(model.text("工作中", "Working"), systemImage: "hammer", signal: .working)
                        }
                        GridRow {
                            actionButton(model.text("需要查看", "Needs Review"), systemImage: "exclamationmark.bubble", signal: .attention)
                            actionButton(model.text("已完成", "Done"), systemImage: "checkmark.seal", signal: .done)
                        }
                        GridRow {
                            actionButton(model.text("请求授权", "Permission"), systemImage: "hand.raised", signal: .permission)
                            actionButton(model.text("阻塞", "Blocked"), systemImage: "exclamationmark.octagon", signal: .blocked)
                        }
                        GridRow {
                            actionButton(model.text("关闭灯", "Off"), systemImage: "power", signal: .off)
                            Button {
                                model.clearSignalTestState()
                            } label: {
                                Label(model.text("重置", "Reset"), systemImage: "arrow.counterclockwise")
                                    .font(settingsControlFont)
                                    .frame(width: signalTestButtonWidth, alignment: .leading)
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(!model.isSignalTestModeEnabled)
                    .opacity(model.isSignalTestModeEnabled ? 1 : 0.45)

                    expandableSection(model.text("高级信号", "Advanced Signals"), isExpanded: $showsAdvancedSignals) {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                            advancedSignalButton("thinking", .thinking)
                            advancedSignalButton("tool_done", .toolDone)
                            advancedSignalButton("subagent_start", .subagentStart)
                            advancedSignalButton("subagent_stop", .subagentStop)
                            advancedSignalButton("notification", .notification)
                            advancedSignalButton("permission_request", .permissionRequest)
                            advancedSignalButton("stale", .stale)
                            advancedSignalButton("pause", .pause)
                            advancedSignalButton("session_start", .sessionStart)
                            advancedSignalButton("session_end", .sessionEnd)
                            advancedSignalButton("turn_end", .turnEnd)
                        }
                    }
                    .disabled(!model.isSignalTestModeEnabled)
                    .opacity(model.isSignalTestModeEnabled ? 1 : 0.45)
                }
            }
        }
    }

    private var connectionSettings: some View {
        settingsSection(model.text("连接", "Connections")) {
            VStack(alignment: .leading, spacing: 14) {
                connectionItem(
                    title: model.text("自动接入", "Automatic setup"),
                    subtitle: model.text("Codex Desktop 自动识别；Claude 运行状态来自 Claude Code Hook", "Codex Desktop is detected automatically; Claude running state comes from Claude Code hooks"),
                    systemImage: "link.badge.plus"
                ) {
                    VStack(alignment: .trailing, spacing: 7) {
                        Toggle(model.text("监控 Codex Desktop", "Monitor Codex Desktop"), isOn: codexDesktopMonitoringBinding)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .help(model.text("自动识别本机 Codex Desktop 活动", "Automatically detect local Codex Desktop activity"))

                        HStack(spacing: 8) {
                            connectionActionButton(
                                model.text("检查", "Check"),
                                systemImage: "checkmark.circle",
                                disabled: model.isHookInstallRunning
                            ) {
                                model.previewHookInstall()
                            }

                            connectionActionButton(
                                model.text("安装", "Install"),
                                systemImage: "wrench.and.screwdriver",
                                disabled: model.isHookInstallRunning
                            ) {
                                model.installHooks()
                            }

                            if model.isHookInstallRunning {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                    }
                }

                Divider()

                connectionItem(
                    title: model.text("其他 Agent", "Other agents"),
                    subtitle: model.text("本地脚本、通用 JSON 事件", "Local scripts, generic JSON events"),
                    systemImage: "point.3.connected.trianglepath.dotted"
                ) {
                    connectionActionButton(
                        model.text("复制接入命令", "Copy command"),
                        systemImage: "doc.on.doc",
                        width: settingsActionButtonWidth
                    ) {
                        model.copyGenericAgentHookCommand()
                    }
                }

                Divider()

                connectionItem(
                    title: model.text("诊断与版本", "Diagnostics"),
                    subtitle: model.text("导出诊断包、查看状态文件和版本", "Export diagnostics, state file, and version"),
                    systemImage: "lifepreserver"
                ) {
                    VStack(alignment: .trailing, spacing: 6) {
                        HStack(spacing: 8) {
                            diagnosticActionButton(
                                model.text("导出诊断", "Export Diagnostics"),
                                systemImage: "archivebox",
                                disabled: model.isDiagnosticsExportRunning
                            ) {
                                model.exportDiagnostics()
                            }

                            diagnosticActionButton(model.text("状态文件", "State File"), systemImage: "folder") {
                                model.showStateFile()
                            }
                        }

                        HStack(spacing: 8) {
                            diagnosticActionButton(model.text("复制路径", "Copy Path"), systemImage: "doc.on.doc") {
                                model.copyStateFilePath()
                            }

                            diagnosticActionButton(
                                model.text("版本", "Release"),
                                systemImage: "shippingbox",
                                disabled: model.releaseInfo.releaseFileURL == nil
                            ) {
                                model.showReleaseInfoFile()
                            }
                        }

                        if model.isDiagnosticsExportRunning {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }

                if let hookInstallMessage = model.hookInstallMessage {
                    connectionResult(message: hookInstallMessage)
                }

                if let diagnosticsExportMessage = model.diagnosticsExportMessage {
                    connectionMessage(
                        title: model.text("诊断结果", "Diagnostics result"),
                        message: diagnosticsExportMessage,
                        lineLimit: 3
                    )
                }

                HStack(spacing: 8) {
                    Text(model.releaseInfo.releaseLine)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer()

                    Button {
                        model.copyReleaseInfo()
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help(model.text("复制版本信息", "Copy release info"))
                }
            }
            .buttonStyle(.bordered)
        }
    }

    private var developerInfoSettings: some View {
        settingsSection(model.text("关于", "About")) {
            settingRow(model.text("版本", "Version")) {
                Text(model.releaseInfo.version)
                    .font(settingsBodyFont)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            settingRow(model.text("更新", "Updates")) {
                Button {
                    model.checkForUpdates()
                } label: {
                    settingsActionSurface(
                        model.text("检查更新", "Check for Updates"),
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                }
                .buttonStyle(.plain)
            }

            if let updateCheckMessage = model.updateCheckMessage {
                Text(updateCheckMessage)
                    .font(settingsBodyFont)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            settingRow(model.text("开发者", "Developer")) {
                Text("Hemi Guan")
                    .font(settingsBodyFont)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(settingsSectionTitleFont)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func settingsSubsection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(settingsSubsectionTitleFont)
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func settingRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top) {
            Text(title)
                .font(settingsRowTitleFont)
                .lineLimit(2)
                .allowsTightening(true)
                .minimumScaleFactor(0.88)
                .padding(.top, 5)
            Spacer()
            content()
        }
    }

    private func closeSettingsDropdown() {
        guard expandedSettingsDropdown != nil else { return }
        withAnimation(.easeInOut(duration: 0.12)) {
            expandedSettingsDropdown = nil
        }
    }

    private func inlineDropdown<Options: View>(
        id: SettingsDropdownID,
        title: String,
        systemImage: String? = nil,
        width: CGFloat,
        @ViewBuilder options: () -> Options
    ) -> some View {
        let isExpanded = expandedSettingsDropdown == id

        return Button {
            withAnimation(.easeInOut(duration: 0.12)) {
                expandedSettingsDropdown = isExpanded ? nil : id
            }
        } label: {
            dropdownSurface(
                title,
                systemImage: systemImage,
                isExpanded: isExpanded,
                width: width
            )
        }
        .buttonStyle(.plain)
        .frame(width: width, height: dropdownControlHeight, alignment: .leading)
        .background(
            glassControlBackground(cornerRadius: 7)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(solidControlStroke, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(alignment: .topLeading) {
            if isExpanded {
                options()
                    .offset(y: dropdownControlHeight + 4)
                    .shadow(color: .black.opacity(0.16), radius: 10, y: 5)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .zIndex(1)
            }
        }
        .zIndex(isExpanded ? 1000 : 0)
    }

    private var dropdownControlHeight: CGFloat {
        28
    }

    private func dropdownSurface(
        _ title: String,
        systemImage: String? = nil,
        isExpanded: Bool,
        width: CGFloat
    ) -> some View {
        HStack(spacing: 7) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(settingsIconFont)
                    .frame(width: 16)
            }

            Text(title)
                .lineLimit(1)
                .allowsTightening(true)
                .minimumScaleFactor(0.72)

            Spacer(minLength: 6)

            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 10)
        }
        .font(settingsControlFont)
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .frame(width: width, height: dropdownControlHeight)
        .background(
            glassControlBackground(cornerRadius: 7)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(solidControlStroke, lineWidth: 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func dropdownOptions<Content: View>(
        width: CGFloat,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .padding(.vertical, 3)
        .frame(width: width)
        .background(
            glassDropdownBackground(cornerRadius: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(solidControlStroke, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func dropdownOption(
        _ title: String,
        systemImage: String? = nil,
        isSelected: Bool = false,
        width: CGFloat,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.12)) {
                expandedSettingsDropdown = nil
            }
            action()
        } label: {
            HStack(spacing: 7) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(settingsIconFont)
                        .frame(width: 16)
                } else {
                    Image(systemName: "checkmark")
                        .font(settingsTinyIconFont)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 16)
                        .opacity(isSelected ? 1 : 0)
                }

                Text(title)
                    .lineLimit(1)
                    .allowsTightening(true)
                    .minimumScaleFactor(0.70)

                Spacer(minLength: 4)
            }
            .font(settingsControlFont)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, 9)
            .frame(width: width, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isSelected ? Color.accentColor : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func diagnosticActionButton(
        _ title: String,
        systemImage: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            settingsActionSurface(title, systemImage: systemImage, width: diagnosticActionButtonWidth)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private func connectionActionButton(
        _ title: String,
        systemImage: String,
        width: CGFloat? = nil,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            settingsActionSurface(title, systemImage: systemImage, width: width ?? diagnosticActionButtonWidth)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private func settingsActionSurface(
        _ title: String,
        systemImage: String,
        width: CGFloat? = nil
    ) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(settingsIconFont)
                .frame(width: 16)

            Text(title)
                .lineLimit(1)
                .allowsTightening(true)
                .minimumScaleFactor(0.72)
        }
        .font(settingsControlFont)
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .frame(width: width ?? settingsActionButtonWidth, height: dropdownControlHeight)
        .background(
            glassControlBackground(cornerRadius: 7)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(solidControlStroke, lineWidth: 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func compactSegmentedControl<Option: Hashable>(
        options: [Option],
        selection: Binding<Option>,
        title: @escaping (Option) -> String
    ) -> some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                let isSelected = selection.wrappedValue == option

                Button {
                    withAnimation(.easeInOut(duration: 0.12)) {
                        selection.wrappedValue = option
                    }
                } label: {
                    Text(title(option))
                        .lineLimit(1)
                        .allowsTightening(true)
                        .minimumScaleFactor(0.72)
                        .font(settingsControlFont)
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                        .frame(maxWidth: .infinity, minHeight: dropdownControlHeight - 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(isSelected ? Color.accentColor : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .frame(width: effectSegmentWidth, height: dropdownControlHeight)
        .background(
            glassControlBackground(cornerRadius: 7)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(solidControlStroke, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func glassControlBackground(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(model.isSettingsGlassEnabled ? glassControlTint : solidControlFill)
    }

    private func glassDropdownBackground(cornerRadius: CGFloat) -> some View {
        ZStack {
            if model.isSettingsGlassEnabled {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(glassDropdownTint)
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(solidDropdownFill)
            }
        }
    }

    private var settingsWindowBackground: some View {
        ZStack {
            if model.isSettingsGlassEnabled {
                SettingsGlassBackdropView(effect: model.settingsGlassEffect, colorScheme: colorScheme)
                Rectangle()
                    .fill(glassWindowTint)
            } else {
                Color(nsColor: NSColor.windowBackgroundColor)
            }
        }
    }

    private var glassControlTint: Color {
        if colorScheme == .dark {
            return Color.white.opacity(model.settingsGlassEffect == .enhanced ? 0.055 : 0.075)
        }
        return Color.white.opacity(model.settingsGlassEffect == .enhanced ? 0.18 : 0.30)
    }

    private var glassDropdownTint: Color {
        if colorScheme == .dark {
            return Color.white.opacity(0.055)
        }
        return Color.white.opacity(0.16)
    }

    private var glassWindowTint: Color {
        if colorScheme == .dark {
            return Color.black.opacity(model.settingsGlassEffect == .enhanced ? 0.08 : 0.18)
        }
        return Color.white.opacity(model.settingsGlassEffect == .enhanced ? 0.05 : 0.18)
    }

    private var selectedMenuItemTint: Color {
        Color.accentColor.opacity(colorScheme == .dark ? 0.24 : 0.16)
    }

    private var solidControlFill: Color {
        colorScheme == .dark
            ? Color(nsColor: NSColor(calibratedWhite: 0.22, alpha: 1))
            : Color(nsColor: NSColor(calibratedWhite: 0.92, alpha: 1))
    }

    private var solidDropdownFill: Color {
        colorScheme == .dark
            ? Color(nsColor: NSColor(calibratedWhite: 0.18, alpha: 1))
            : Color(nsColor: NSColor(calibratedWhite: 0.97, alpha: 1))
    }

    private var solidControlStroke: Color {
        colorScheme == .dark
            ? Color(nsColor: NSColor(calibratedWhite: 0.34, alpha: 1))
            : Color(nsColor: NSColor(calibratedWhite: 0.78, alpha: 1))
    }

    private var settingsPickerWidth: CGFloat {
        settingsControlWidth
    }

    private var settingsActionButtonWidth: CGFloat {
        settingsControlWidth
    }

    private var diagnosticActionButtonWidth: CGFloat {
        settingsControlWidth
    }

    private var effectMenuWidth: CGFloat {
        settingsControlWidth
    }

    private var effectSegmentWidth: CGFloat {
        settingsControlWidth
    }

    private var settingsControlWidth: CGFloat {
        usesCompactLatinLayout ? 162 : 150
    }

    private var signalTestButtonWidth: CGFloat {
        150
    }

    private func activitySessionRow(_ session: SessionStatus) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(debugSignalColor(session.signal))
                .frame(width: 8, height: 8)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(model.friendlyAgentName(session.agent))
                        .font(settingsSubsectionTitleFont)
                        .lineLimit(1)

                    Text(model.displayName(for: session.signal))
                        .font(settingsDetailStrongFont)
                        .foregroundStyle(debugSignalColor(session.signal))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(debugSignalColor(session.signal).opacity(0.12), in: Capsule())
                }

                Text(activitySessionSubtitle(session))
                    .font(settingsBodyFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text("\(model.text("会话", "Session")) \(debugCompactIdentifier(session.sessionID))")
                    .font(settingsDetailFont)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 10)

            Text(session.updatedAt.formatted(date: .omitted, time: .shortened))
                .font(settingsDetailFont)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func activityEventRow(_ event: RecentSignalEvent) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(debugSignalColor(event.signal))
                .frame(width: 7, height: 7)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 2) {
                Text(activityEventTitle(event))
                    .font(settingsBodyStrongFont)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text("\(model.displayName(for: event.signal)) · \(model.text("会话", "Session")) \(debugCompactIdentifier(event.sessionID))")
                    .font(settingsDetailFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 10)

            Text(event.updatedAt.formatted(date: .omitted, time: .shortened))
                .font(settingsDetailFont)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func emptyActivityRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(settingsTabIconFont)
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(settingsBodyStrongFont)
                Text(subtitle)
                    .font(settingsBodyFont)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func activitySessionSubtitle(_ session: SessionStatus) -> String {
        if let lastEvent = session.lastEvent, !lastEvent.isEmpty {
            return "\(model.text("最近事件", "Recent Event")) \(model.friendlyEventName(lastEvent))"
        }

        return model.humanAction(for: session.signal)
    }

    private func activityEventTitle(_ event: RecentSignalEvent) -> String {
        let agent = model.friendlyAgentName(event.agent)
        if let eventName = event.event, !eventName.isEmpty {
            return "\(agent) · \(model.friendlyEventName(eventName))"
        }

        return "\(agent) · \(model.displayName(for: event.signal))"
    }

    private func activityUpdatedText(_ updatedAt: Date?) -> String {
        guard let updatedAt else {
            return model.text("等待状态", "Waiting for status")
        }

        return "\(model.text("更新", "Updated")) \(updatedAt.formatted(date: .omitted, time: .shortened))"
    }

    private func connectionItem<Actions: View>(
        title: String,
        subtitle: String,
        systemImage: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(settingsSubsectionTitleFont)
                Text(subtitle)
                    .font(settingsBodyFont)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)

            actions()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func connectionResult(message: String) -> some View {
        if let summary = HookConnectionSummary.parse(message) {
            connectionSummary(summary)
        } else {
            connectionMessage(
                title: model.text("连接结果", "Connection result"),
                message: message,
                lineLimit: 3
            )
        }
    }

    private func connectionSummary(_ summary: HookConnectionSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: summary.isReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(summary.isReady ? .green : .orange)
                Text(model.text("连接结果", "Connection result"))
                    .font(settingsBodyStrongFont)
                Spacer()
                Text(summary.mode == .dryRun ? model.text("检查完成", "Check complete") : model.text("安装完成", "Install complete"))
                    .font(settingsDetailStrongFont)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(summary.items) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: connectionStatusIcon(item.status))
                            .font(settingsBodyStrongFont)
                            .foregroundStyle(connectionStatusColor(item.status))
                            .frame(width: 14, height: 14)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name)
                                .font(settingsBodyStrongFont)
                            Text(connectionStatusText(item.status, mode: summary.mode))
                                .font(settingsBodyFont)
                                .foregroundStyle(.secondary)
                            if let file = item.file {
                                Text("\(model.text("配置文件", "Config file")) \(compactPath(file))")
                                    .font(settingsDetailFont)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }

                        Spacer(minLength: 10)
                    }
                }
            }

            if !summary.diagnostics.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(summary.diagnostics, id: \.self) { diagnostic in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(settingsDetailStrongFont)
                                .foregroundStyle(.orange)
                                .frame(width: 14, height: 14)

                            Text(diagnostic)
                                .font(settingsDetailFont)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                }
            }

            if let note = connectionSummaryNote(summary) {
                Text(note)
                    .font(settingsDetailFont)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.tertiary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func connectionMessage(title: String, message: String, lineLimit: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(settingsBodyStrongFont)
                .foregroundStyle(.secondary)
            Text(message)
                .font(settingsBodyFont)
                .foregroundStyle(.secondary)
                .lineLimit(lineLimit)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .padding(.top, 2)
    }

    private func connectionStatusIcon(_ status: HookConnectionStatus) -> String {
        switch status {
        case .ready, .installed:
            return "checkmark.circle.fill"
        case .needsInstall:
            return "arrow.down.circle.fill"
        case .unknown:
            return "info.circle.fill"
        }
    }

    private func connectionStatusColor(_ status: HookConnectionStatus) -> Color {
        switch status {
        case .ready, .installed:
            return .green
        case .needsInstall:
            return .orange
        case .unknown:
            return .secondary
        }
    }

    private func connectionStatusText(_ status: HookConnectionStatus, mode: HookConnectionMode) -> String {
        switch status {
        case .ready:
            return model.text("已连接", "Connected")
        case .installed:
            return mode == .dryRun ? model.text("需要安装", "Needs install") : model.text("已更新", "Hook updated")
        case .needsInstall:
            return model.text("需要安装", "Needs install")
        case .unknown:
            return model.text("已完成", "Completed")
        }
    }

    private func connectionSummaryNote(_ summary: HookConnectionSummary) -> String? {
        if summary.mode == .dryRun && summary.items.contains(where: { $0.status == .needsInstall }) {
            return model.text("未写入文件，点击安装连接应用更改。", "No files were written. Click Install to apply changes.")
        }
        if summary.mode == .dryRun {
            return model.text("连接已准备好。", "Connections are ready.")
        }
        return model.text("Hook 已更新。", "Hooks are up to date.")
    }

    private func compactPath(_ path: String) -> String {
        path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private func expandableSection<Content: View>(
        _ title: String,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    isExpanded.wrappedValue.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(settingsBodyStrongFont)
                        .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
                    Text(title)
                        .font(settingsBodyStrongFont)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded.wrappedValue {
                content()
                    .padding(.top, 8)
            }
        }
    }

    private func actionButton(_ title: String, systemImage: String, signal: AgentSignal) -> some View {
        Button {
            model.setSignalTestSignal(signal)
        } label: {
            Label(title, systemImage: systemImage)
                .font(settingsControlFont)
                .frame(width: signalTestButtonWidth, alignment: .leading)
        }
    }

    private func advancedSignalButton(_ title: String, _ signal: AgentSignal) -> some View {
        Button(title) {
            model.setSignalTestSignal(signal)
        }
        .font(settingsControlFont)
        .frame(width: signalTestButtonWidth, alignment: .leading)
    }

    private var statusBarEnabledBinding: Binding<Bool> {
        Binding(
            get: { model.isStatusBarIconEnabled },
            set: { model.setStatusBarIconEnabled($0) }
        )
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { model.isLaunchAtLoginEnabled },
            set: { model.setLaunchAtLoginEnabled($0) }
        )
    }

    private var statusBarAllLightsBinding: Binding<Bool> {
        Binding(
            get: { model.isStatusBarAllLightsOn },
            set: { model.setStatusBarAllLightsOn($0) }
        )
    }

    private var signalTestModeBinding: Binding<Bool> {
        Binding(
            get: { model.isSignalTestModeEnabled },
            set: { model.setSignalTestModeEnabled($0) }
        )
    }

    private var signalLightAgentScopeBinding: Binding<SignalLightAgentScope> {
        Binding(
            get: { model.signalLightAgentScope },
            set: { model.setSignalLightAgentScope($0) }
        )
    }

    private var codexDesktopMonitoringBinding: Binding<Bool> {
        Binding(
            get: { model.isCodexDesktopMonitoringEnabled },
            set: { model.setCodexDesktopMonitoringEnabled($0) }
        )
    }

    private var appLanguageBinding: Binding<AppLanguage> {
        Binding(
            get: { model.appLanguage },
            set: { model.setAppLanguage($0) }
        )
    }

    private var appThemeBinding: Binding<AppTheme> {
        Binding(
            get: { model.appTheme },
            set: { model.setAppTheme($0) }
        )
    }

    private var settingsGlassEnabledBinding: Binding<Bool> {
        Binding(
            get: { model.isSettingsGlassEnabled },
            set: { model.setSettingsGlassEnabled($0) }
        )
    }

    private var settingsGlassEffectBinding: Binding<SettingsGlassEffect> {
        Binding(
            get: { model.settingsGlassEffect },
            set: { model.setSettingsGlassEffect($0) }
        )
    }

    private var statusBarStyleBinding: Binding<TrafficSignalStyle> {
        Binding(
            get: { model.statusBarStyle },
            set: { model.setStatusBarStyle($0) }
        )
    }

    private var displayLayoutBinding: Binding<TrafficSignalLayout> {
        Binding(
            get: { model.displayLayout },
            set: { model.setDisplayLayout($0) }
        )
    }

    private var macOSBreathingStrengthBinding: Binding<MacOSBreathingStrength> {
        Binding(
            get: { model.macOSBreathingStrength },
            set: { model.setMacOSBreathingStrength($0) }
        )
    }

    private var activeSignalEffectBinding: Binding<ActiveSignalEffect> {
        Binding(
            get: { model.activeSignalEffect },
            set: { model.setActiveSignalEffect($0) }
        )
    }

    private var thinkingSignalEffectBinding: Binding<ActiveSignalEffect> {
        Binding(
            get: { model.thinkingSignalEffect },
            set: { model.setThinkingSignalEffect($0) }
        )
    }

    private var activeEffectSpeedBinding: Binding<SignalEffectSpeed> {
        Binding(
            get: { model.activeEffectSpeed },
            set: { model.setActiveEffectSpeed($0) }
        )
    }

    private var alertEffectSpeedBinding: Binding<SignalEffectSpeed> {
        Binding(
            get: { model.alertEffectSpeed },
            set: { model.setAlertEffectSpeed($0) }
        )
    }

    private var completedSignalEffectBinding: Binding<CompletedSignalEffect> {
        Binding(
            get: { model.completedSignalEffect },
            set: { model.setCompletedSignalEffect($0) }
        )
    }

    private var macOSHorizontalSizeBinding: Binding<DotHorizontalSizeOption> {
        Binding(
            get: { model.macOSHorizontalUsesTrafficLightSize ? .standard : .small },
            set: { model.setMacOSHorizontalUsesTrafficLightSize($0 == .standard) }
        )
    }

    private var lampVerticalSizeBinding: Binding<LampVerticalSizeOption> {
        Binding(
            get: { model.trafficLightVerticalUsesMacOSSize ? .large : .standard },
            set: { model.setTrafficLightVerticalUsesMacOSSize($0 == .large) }
        )
    }
}

private struct SettingsGlassBackdropView: NSViewRepresentable {
    let effect: SettingsGlassEffect
    let colorScheme: ColorScheme

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        configure(view)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        configure(view)
    }

    private func configure(_ view: NSVisualEffectView) {
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = true
        view.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
    }

    private var material: NSVisualEffectView.Material {
        switch effect {
        case .standard:
            return .popover
        case .enhanced:
            return .hudWindow
        }
    }
}

private struct SettingsTabDropDelegate: DropDelegate {
    let destination: DebugWindowView.SettingsTab
    @Binding var order: [DebugWindowView.SettingsTab]
    @Binding var draggedTab: DebugWindowView.SettingsTab?

    func dropEntered(info: DropInfo) {
        guard let draggedTab, draggedTab != destination else { return }
        guard let fromIndex = order.firstIndex(of: draggedTab),
              let toIndex = order.firstIndex(of: destination)
        else {
            return
        }

        withAnimation(.easeInOut(duration: 0.16)) {
            order.move(
                fromOffsets: IndexSet(integer: fromIndex),
                toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex
            )
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        DebugWindowView.SettingsTab.saveOrder(order)
        draggedTab = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        DebugWindowView.SettingsTab.saveOrder(order)
    }
}

private enum HookConnectionMode {
    case dryRun
    case installed
}

private enum HookConnectionStatus {
    case ready
    case needsInstall
    case installed
    case unknown
}

private struct HookConnectionItem: Identifiable {
    var id: String { name }
    let name: String
    let status: HookConnectionStatus
    let file: String?
}

private struct HookConnectionSummary {
    let mode: HookConnectionMode
    let items: [HookConnectionItem]
    let diagnostics: [String]

    var isReady: Bool {
        items.allSatisfy { $0.status == .ready || $0.status == .installed } && diagnostics.isEmpty
    }

    static func parse(_ message: String) -> HookConnectionSummary? {
        var mode: HookConnectionMode?
        var items: [HookConnectionItem] = []
        var diagnostics: [String] = []
        var activeDiagnosticIndex: Int?
        var currentName: String?
        var currentStatus = HookConnectionStatus.unknown
        var currentFile: String?

        func flushCurrent() {
            guard let currentName else { return }
            items.append(
                HookConnectionItem(
                    name: currentName,
                    status: currentStatus,
                    file: currentFile
                )
            )
        }

        for rawLine in message.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("[") {
                flushCurrent()
                currentName = nil
                currentStatus = .unknown
                currentFile = nil
                activeDiagnosticIndex = nil

                guard let modeEnd = line.firstIndex(of: "]") else { continue }
                let modeText = String(line[line.index(after: line.startIndex)..<modeEnd])
                if modeText == "diagnostic" {
                    let diagnostic = line[line.index(after: modeEnd)...]
                        .trimmingCharacters(in: .whitespaces)
                    if !diagnostic.isEmpty {
                        diagnostics.append(diagnostic)
                        activeDiagnosticIndex = diagnostics.count - 1
                    }
                    continue
                }

                if modeText == "dry-run" {
                    mode = .dryRun
                } else if modeText == "installed" {
                    mode = .installed
                }

                let rest = line[line.index(after: modeEnd)...]
                    .trimmingCharacters(in: .whitespaces)
                let parts = rest.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)
                guard parts.count == 2 else { continue }
                currentName = String(parts[0]).trimmingCharacters(in: .whitespaces)

                let statusText = parts[1].trimmingCharacters(in: .whitespaces)
                if statusText == "already configured" {
                    currentStatus = .ready
                } else if statusText == "updated" {
                    currentStatus = mode == .installed ? .installed : .needsInstall
                } else {
                    currentStatus = .unknown
                }
            } else if line.hasPrefix("file:") {
                activeDiagnosticIndex = nil
                currentFile = line
                    .dropFirst("file:".count)
                    .trimmingCharacters(in: .whitespaces)
            } else if let index = activeDiagnosticIndex,
                      line.hasPrefix("reason:") || line.hasPrefix("effect:") || line.hasPrefix("note:") || line.hasPrefix("log:") {
                diagnostics[index].append("\n\(line)")
            } else {
                activeDiagnosticIndex = nil
            }
        }

        flushCurrent()

        guard let mode, !items.isEmpty else { return nil }
        return HookConnectionSummary(mode: mode, items: items, diagnostics: diagnostics)
    }
}

private struct ActivitySignalLampView: View {
    @ObservedObject var model: MenuBarStatusModel
    @ObservedObject private var animationClock: SignalAnimationClock

    init(model: MenuBarStatusModel) {
        self.model = model
        _animationClock = ObservedObject(wrappedValue: model.animationClock)
    }

    var body: some View {
        PureActivitySignalLampView(
            signal: model.displaySnapshot.aggregate,
            tick: animationClock.tick,
            allLightsOn: model.isStatusBarAllLightsOn,
            effectCustomization: model.signalEffectCustomization
        )
    }
}

private struct PureActivitySignalLampView: View {
    let signal: AgentSignal
    let tick: Int
    let allLightsOn: Bool
    let effectCustomization: SignalEffectCustomization

    var body: some View {
        Circle()
            .fill(lampColor)
            .opacity(opacity)
            .frame(width: 12, height: 12)
            .scaleEffect(scale)
            .shadow(color: lampColor.opacity(shadowOpacity), radius: 3)
            .frame(width: 20, height: 20)
            .accessibilityLabel(signal.displayName)
    }

    private var lampColor: Color {
        if signal.displayState == .paused {
            return .secondary
        }

        return color(for: lampType)
    }

    private func color(for lampType: SignalLampColor) -> Color {
        switch lampType {
        case .green:
            return Color(red: 0.16, green: 0.78, blue: 0.34)
        case .yellow:
            return Color(red: 0.97, green: 0.72, blue: 0.16)
        case .red:
            return Color(red: 0.94, green: 0.20, blue: 0.18)
        }
    }

    private var lampType: SignalLampColor {
        switch signal.displayState {
        case .ready:
            return .green
        case .active:
            return activeLampType
        case .completed:
            return completedLampType
        case .needsReview, .stale:
            return .yellow
        case .permission, .blocked:
            return .red
        case .paused:
            return .green
        }
    }

    private var activeLampType: SignalLampColor {
        let activeEffect = signal == .thinking ? effectCustomization.thinkingEffect : effectCustomization.activeEffect
        guard activeEffect == .trafficCycle else {
            return .green
        }

        let litColor = SignalLampColor.allCases.first {
            SignalLampAnimation.intensity(
                $0,
                signal: signal,
                tick: tick,
                allLightsOn: allLightsOn,
                customization: effectCustomization
            ) > 0
        }
        return litColor ?? .green
    }

    private var completedLampType: SignalLampColor {
        switch effectCustomization.completedEffect {
        case .yellowPulse, .yellowSteady:
            return .yellow
        case .greenPulse, .greenSteady, .allSteady, .allPulse:
            return .green
        }
    }

    private var intensity: Double {
        if signal.displayState == .paused {
            return 0.38
        }

        return SignalLampAnimation.intensity(
            lampType,
            signal: signal,
            tick: tick,
            allLightsOn: allLightsOn,
            customization: effectCustomization
        )
    }

    private var opacity: Double {
        intensity
    }

    private var scale: Double {
        if signal.displayState == .paused {
            return 1
        }

        return SignalLampAnimation.scale(
            lampType,
            signal: signal,
            tick: tick,
            allLightsOn: allLightsOn,
            customization: effectCustomization
        )
    }

    private var shadowOpacity: Double {
        signal.displayState == .paused ? 0 : intensity * 0.35
    }
}

private func debugCompactIdentifier(_ value: String) -> String {
    guard value.count > 12 else { return value }
    return String(value.prefix(10))
}

private func debugSignalColor(_ signal: AgentSignal) -> Color {
    switch signal.displayState {
    case .ready, .active, .completed:
        return Color(red: 0.16, green: 0.78, blue: 0.34)
    case .needsReview:
        return Color(red: 0.97, green: 0.72, blue: 0.16)
    case .permission, .blocked:
        return Color(red: 0.94, green: 0.20, blue: 0.18)
    case .stale, .paused:
        return .secondary
    }
}

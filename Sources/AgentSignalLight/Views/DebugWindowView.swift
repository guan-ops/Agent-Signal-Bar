import AgentSignalLightCore
import AgentSignalLightUI
import AppKit
import Foundation
import SwiftUI

struct DebugWindowView: View {
    @ObservedObject var model: MenuBarStatusModel
    @ObservedObject var updater: SparkleUpdaterService
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedSettingsTab: SettingsTab = .activity
    @State private var expandedSettingsDropdown: SettingsDropdownID?
    private let activityRecentEventLimit = 50

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
                    .overlay {
                        SettingsWindowDragRegionView()
                    }

                Divider()

                settingsMenu
                    .padding(.horizontal, 22)
                    .padding(.vertical, 10)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(2)

                Divider()

                settingsContentArea
            }
        }
        .frame(width: 600, height: 840)
        .preferredColorScheme(model.appTheme.colorScheme)
    }

    private var settingsMenu: some View {
        HStack(spacing: 4) {
            ForEach(SettingsTab.displayOrder) { tab in
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
                    .foregroundStyle(selectedSettingsTab == tab ? Color.accentColor : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .contentShape(Rectangle())
                    .background {
                        if selectedSettingsTab == tab {
                            glassSelectedMenuItemBackground(cornerRadius: 7)
                        }
                    }
                }
                .buttonStyle(.plain)
                .help(menuTitle(for: tab))
            }
        }
        .padding(4)
        .frame(height: 56)
        .background {
            glassMenuBarBackground(cornerRadius: 12)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(glassMenuBarStroke, lineWidth: 0.6)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var settingsContentArea: some View {
        GeometryReader { proxy in
            if selectedSettingsTab == .activity {
                fixedSettingsContentArea(proxy: proxy)
            } else {
                scrollingSettingsContentArea(proxy: proxy)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func fixedSettingsContentArea(proxy: GeometryProxy) -> some View {
        ZStack(alignment: .topLeading) {
            dropdownDismissLayer

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
        .frame(maxWidth: .infinity, maxHeight: proxy.size.height, alignment: .topLeading)
    }

    private func scrollingSettingsContentArea(proxy: GeometryProxy) -> some View {
        ScrollView {
            ZStack(alignment: .topLeading) {
                dropdownDismissLayer

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

    @ViewBuilder
    private var dropdownDismissLayer: some View {
        if expandedSettingsDropdown != nil {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    closeSettingsDropdown()
                }
                .zIndex(0)
        }
    }

    @ViewBuilder
    private var selectedSettingsContent: some View {
        switch selectedSettingsTab {
        case .general:
            generalSettings
        case .activity:
            activitySettings
        case .connections:
            connectionSettings
        case .advanced:
            advancedSettings
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
        case .connections:
            return model.text("连接", "Connect")
        case .advanced:
            return model.text("高级", "Advanced")
        case .about:
            return model.text("关于", "About")
        }
    }

    fileprivate enum SettingsTab: String, CaseIterable, Identifiable {
        case activity
        case general
        case connections
        case advanced
        case about

        var id: String { rawValue }

        static let displayOrder: [SettingsTab] = [
            .activity,
            .general,
            .connections,
            .advanced,
            .about
        ]

        var systemImage: String {
            switch self {
            case .general:
                return "gearshape"
            case .activity:
                return "waveform.path.ecg"
            case .connections:
                return "link"
            case .advanced:
                return "slider.horizontal.3"
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
        case language
        case theme
        case signalLightAgents
        case thinkingEffect
        case workingEffect
        case doneEffect
        case completionSound
        case waitingSound
        case alertSound
    }

    private struct SignalLightAgentDropdownSection: Identifiable {
        let id: String
        let title: String
        let scopes: [SignalLightAgentScope]
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

    private var agentScopeSectionFont: Font {
        .system(size: usesCompactLatinLayout ? 10 : 10.5, weight: .semibold)
    }

    private var agentScopeOptionFont: Font {
        .system(size: usesCompactLatinLayout ? 10.5 : 11, weight: .semibold)
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

                settingRow(model.text("液态玻璃效果", "Liquid glass")) {
                    settingsSwitch(settingsGlassEnabledBinding)
                }

                if model.isSettingsGlassEnabled {
                    settingRow(model.text("液态玻璃强度", "Liquid glass strength")) {
                        compactSegmentedControl(
                            options: SettingsGlassEffect.allCases,
                            selection: settingsGlassEffectBinding
                        ) { effect in
                            model.displayName(for: effect)
                        }
                    }
                }

                settingRow(model.text("新西兰原版模式", "New Zealand original mode")) {
                    settingsSwitch(newZealandTrafficLightModeBinding)
                        .help(model.text(
                            "按新西兰行人红绿灯节奏慢闪，并将完成音和闪烁音切换为新西兰。",
                            "Use the original New Zealand pedestrian crossing cadence and switch completion and blink sounds to New Zealand."
                        ))
                }

                soundAlertSettings
            }
            .zIndex(isGeneralDropdownExpanded ? 10 : 1)

            Divider()
                .zIndex(0)

            signalVisibilitySettings

            Divider()
                .zIndex(0)

            runtimeBehaviorSettings
        }
    }

    private var isGeneralDropdownExpanded: Bool {
        switch expandedSettingsDropdown {
        case .language, .theme, .completionSound, .waitingSound, .alertSound:
            return true
        default:
            return false
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

    private var completionSoundMenu: some View {
        inlineDropdown(
            id: .completionSound,
            title: model.displayName(for: model.floatingSignalCompletionSound),
            width: settingsPickerWidth
        ) {
            dropdownOptions(width: settingsPickerWidth) {
                ForEach(FloatingSignalCompletionSound.allCases, id: \.self) { sound in
                    dropdownOption(
                        model.displayName(for: sound),
                        isSelected: model.floatingSignalCompletionSound == sound,
                        width: settingsPickerWidth
                    ) {
                        model.setFloatingSignalCompletionSound(sound)
                    }
                }
            }
        }
    }

    private var waitingSoundMenu: some View {
        inlineDropdown(
            id: .waitingSound,
            title: model.displayName(for: model.floatingSignalWaitingSound),
            width: settingsPickerWidth
        ) {
            dropdownOptions(width: settingsPickerWidth) {
                ForEach(FloatingSignalWaitingSound.allCases, id: \.self) { sound in
                    dropdownOption(
                        model.displayName(for: sound),
                        isSelected: model.floatingSignalWaitingSound == sound,
                        width: settingsPickerWidth
                    ) {
                        model.setFloatingSignalWaitingSound(sound)
                    }
                }
            }
        }
    }

    private var alertSoundMenu: some View {
        inlineDropdown(
            id: .alertSound,
            title: model.displayName(for: model.floatingSignalAlertSound),
            width: settingsPickerWidth
        ) {
            dropdownOptions(width: settingsPickerWidth) {
                ForEach(FloatingSignalAlertSound.allCases, id: \.self) { sound in
                    dropdownOption(
                        model.displayName(for: sound),
                        isSelected: model.floatingSignalAlertSound == sound,
                        width: settingsPickerWidth
                    ) {
                        model.setFloatingSignalAlertSound(sound)
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
            width: effectMenuWidth,
            opensUpward: true,
            optionsHeight: dropdownOptionsHeight(optionCount: CompletedSignalEffect.allCases.count)
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

    private var signalLightAgentMenu: some View {
        let selectedScopes = model.displaySignalLightAgentScopes

        return inlineDropdown(
            id: .signalLightAgents,
            title: model.signalLightAgentMenuTitle,
            width: agentScopeMenuWidth
        ) {
            dropdownOptions(width: agentScopeMenuWidth) {
                ForEach(signalLightAgentDropdownSections) { section in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(section.title)
                            .font(agentScopeSectionFont)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.top, 5)
                            .padding(.bottom, 2)

                        ForEach(section.scopes, id: \.self) { scope in
                            signalLightAgentOption(
                                scope,
                                isSelected: selectedScopes.contains(scope),
                                isRunning: model.activeSignalLightAgentScopes.contains(scope),
                                width: agentScopeMenuWidth
                            )
                        }
                    }
                }
            }
        }
    }

    private var signalLightAgentDropdownSections: [SignalLightAgentDropdownSection] {
        let runningScopes = model.activeSignalLightAgentScopes
        var sections: [SignalLightAgentDropdownSection] = []

        for group in SignalLightAgentScopeGroup.allCases {
            let groupOptions = SignalLightAgentScope.selectableCases
                .filter { $0.group == group }
                .sorted { lhs, rhs in
                    let lhsIsRunning = runningScopes.contains(lhs)
                    let rhsIsRunning = runningScopes.contains(rhs)
                    if lhsIsRunning != rhsIsRunning {
                        return lhsIsRunning
                    }
                    return lhs.sortOrder < rhs.sortOrder
                }

            guard !groupOptions.isEmpty else { continue }
            sections.append(
                SignalLightAgentDropdownSection(
                    id: "group-\(group.rawValue)",
                    title: model.displayName(for: group),
                    scopes: groupOptions
                )
            )
        }

        return sections
    }

    private var activitySettings: some View {
        settingsSection(model.text("运行详情", "Agent Activity")) {
            VStack(alignment: .leading, spacing: 14) {
                settingRow(model.text("灯效 Agent", "Light Agent")) {
                    signalLightAgentMenu
                }
                .zIndex(expandedSettingsDropdown == .signalLightAgents ? 1000 : 0)

                if let hint = model.signalLightAgentUnavailableHint {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "info.circle")
                            .font(settingsTinyIconFont)
                        Text(hint)
                            .font(settingsDetailFont)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(.secondary)
                }

                activitySummaryCard

                Divider()

                activitySessions

                Divider()

                activityEvents
                    .layoutPriority(1)
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private var monitoringPauseSetting: some View {
        settingRow(model.text("暂停监控", "Pause Monitoring")) {
            settingsSwitch(monitoringPausedBinding, tint: .red)
                .help(model.text(
                    "暂停后状态栏灯会熄灭，Agent 事件暂不刷新。",
                    "When paused, the status bar light turns off and agent events stop refreshing."
                ))
        }
    }

    private var runtimeBehaviorSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingRow(model.text("开机自启动", "Start at login")) {
                settingsSwitch(launchAtLoginBinding)
                    .disabled(model.isLaunchAtLoginChangeRunning)
                    .help(model.text("登录 macOS 后自动打开 Agent Signal Bar", "Open Agent Signal Bar automatically after macOS login"))
            }

            settingRow(model.text("低功耗模式", "Low power mode")) {
                settingsSwitch(lowPowerModeBinding)
                    .help(model.text(
                        "降低后台轮询和动画刷新频率，适合长时间常驻。",
                        "Reduce background polling and animation refresh while the app stays running."
                    ))
            }

            monitoringPauseSetting
        }
    }

    private var activitySummaryCard: some View {
        let lightSnapshot = model.lightSnapshot
        let selectedSignal = lightSnapshot.aggregate

        return HStack(alignment: .top, spacing: 12) {
            ActivitySignalLampView(
                model: model,
                signalOverride: selectedSignal
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(model.displayName(for: selectedSignal))
                    .font(settingsSubsectionTitleFont)
                Text(model.summary(for: selectedSignal))
                    .font(settingsBodyFont)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(lightSnapshot.updatedAt.map(activityUpdatedText) ?? model.text("等待运行", "Waiting to launch"))
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

                Text("\(lightSnapshot.sessions.count) \(model.text("个会话", "sessions"))")
                    .font(settingsDetailFont)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
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
                    subtitle: model.text("启动 Agent 后，这里会显示所有 Agent 的实时状态。", "Launch an agent to show live status from all agents here.")
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
        ActivityPresentation.visibleSessions(
            from: model.activitySnapshot,
            limit: ActivityPresentation.currentSessionLimit
        )
    }

    private var activityEvents: some View {
        let recentEvents = activityRecentEvents

        return VStack(alignment: .leading, spacing: 8) {
            Text(model.text("最近事件", "Recent Events"))
                .font(settingsBodyStrongFont)
                .foregroundStyle(.secondary)

            if recentEvents.isEmpty {
                emptyActivityRow(
                    icon: "clock",
                    title: model.text("还没有最近事件", "No recent events yet")
                )
            } else {
                GeometryReader { proxy in
                    let horizontalInset: CGFloat = 10
                    let rowWidth = max(0, proxy.size.width - horizontalInset * 2)

                    ScrollView(.vertical, showsIndicators: false) {
                        RecentEventsScrollConfigurator()
                            .frame(width: 0, height: 0)

                        LazyVStack(alignment: .leading, spacing: 7) {
                            ForEach(recentEvents.prefix(activityRecentEventLimit)) { event in
                                activityEventRow(event, width: rowWidth)
                            }
                        }
                        .frame(width: rowWidth, alignment: .topLeading)
                        .padding(.horizontal, horizontalInset)
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .scrollContentBackground(.hidden)
                    .clipped()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var activityRecentEvents: [RecentSignalEvent] {
        ActivityPresentation.recentEvents(
            from: model.activitySnapshot,
            excluding: visibleActivitySessions
        )
    }

    private var signalVisibilitySettings: some View {
        settingsSection(model.text("信号灯", "Signals")) {
            settingRow(model.text("显示状态栏信号", "Show status bar signal")) {
                settingsSwitch(statusBarEnabledBinding)
            }

            settingRow(model.text("显示悬浮信号灯", "Show floating signal")) {
                settingsSwitch(floatingSignalEnabledBinding)
                    .help(model.text("在桌面上显示可拖动、可缩放的悬浮信号灯", "Show the draggable, resizable floating signal on the desktop"))
            }
        }
    }

    private var statusBarSettings: some View {
        settingsSection(model.text("状态栏", "Status Bar")) {
            Text(model.text(
                "按住 ⌘ 并拖动状态栏信号灯，可以调整它在状态栏中的位置。",
                "Hold Command and drag the status bar signal to move its position."
            ))
            .font(settingsDetailFont)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            settingRow(model.text("状态栏菜单", "Status bar menu")) {
                compactSegmentedControl(
                    options: StatusMenuMode.allCases,
                    selection: statusMenuModeBinding
                ) { mode in
                    model.displayName(for: mode)
                }
            }

            settingRow(model.text("状态栏风格", "Status bar style")) {
                compactSegmentedControl(
                    options: statusBarStyleOptions,
                    selection: statusBarStyleBinding
                ) { style in
                    model.displayName(for: style)
                }
            }

            settingRow(model.text("状态栏方向", "Status bar direction")) {
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

    private var floatingSignalSettings: some View {
        settingsSection(model.text("悬浮灯", "Floating Signal")) {
            settingRow(model.text("悬浮灯方向", "Floating signal direction")) {
                compactSegmentedControl(
                    options: TrafficSignalLayout.allCases,
                    selection: floatingSignalLayoutBinding
                ) { layout in
                    model.displayName(for: layout)
                }
            }

            settingRow(model.text("悬浮灯大小", "Floating signal size")) {
                Button {
                    model.setFloatingSignalScale(.standard)
                } label: {
                    settingsActionSurface(
                        model.text("恢复默认大小", "Restore Default Size"),
                        systemImage: "arrow.counterclockwise"
                    )
                }
                .buttonStyle(.plain)
                .disabled(abs(model.floatingSignalVisualScale - FloatingSignalScale.defaultVisualScale) < 0.01)
                .help(model.text(
                    "恢复为中号（默认）的悬浮灯大小。",
                    "Restore the medium (default) floating signal size."
                ))
            }
        }
    }

    private var soundAlertSettings: some View {
        Group {
            settingRow(model.text("声音提醒", "Sound alert")) {
                settingsSwitch(floatingSignalSoundEnabledBinding)
            }

            if model.isFloatingSignalSoundEnabled {
                settingRow(model.text("完成提示音", "Completion sound")) {
                    completionSoundMenu
                }
                .zIndex(expandedSettingsDropdown == .completionSound ? 1000 : 0)

                settingControlRow {
                    soundPreviewButton(disabled: !model.isFloatingSignalCompletionSoundEnabled) {
                        model.previewFloatingSignalSound()
                    }
                }

                settingRow(model.text("绿灯闪烁音", "Green flash sound")) {
                    waitingSoundMenu
                }
                .zIndex(expandedSettingsDropdown == .waitingSound ? 1000 : 0)

                settingControlRow {
                    soundPreviewButton(disabled: !model.isFloatingSignalWaitingSoundEnabled) {
                        model.previewFloatingSignalWaitingSound()
                    }
                }

                settingRow(model.text("告警提示音", "Alert sound")) {
                    alertSoundMenu
                }
                .zIndex(expandedSettingsDropdown == .alertSound ? 1000 : 0)

                settingControlRow {
                    soundPreviewButton(disabled: !model.isFloatingSignalAlertSoundEnabled) {
                        model.previewFloatingSignalAlertSound()
                    }
                }

                settingRow(model.text("提醒音量", "Alert volume")) {
                    compactSegmentedControl(
                        options: FloatingSignalSoundLevel.allCases,
                        selection: floatingSignalSoundLevelBinding
                    ) { level in
                        model.displayName(for: level)
                    }
                }
            }
        }
    }

    private var advancedSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.text("高级设置", "Advanced Settings"))
                .font(settingsSectionTitleFont)

            statusBarSettings

            Divider()

            floatingSignalSettings

            Divider()

            manualSignalSettings
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

            }
        }
    }

    private var connectionSettings: some View {
        settingsSection(model.text("连接", "Connections")) {
            VStack(alignment: .leading, spacing: 14) {
                automaticConnectionSettings

                Divider()

                connectionItem(
                    title: model.text("其他 Agent", "Other agents"),
                    subtitle: model.text("本地脚本、通用 JSON 事件", "Local scripts, generic JSON events"),
                    systemImage: "point.3.connected.trianglepath.dotted"
                ) {
                    connectionActionButton(
                        model.text("复制接入命令", "Copy command"),
                        systemImage: "doc.on.doc",
                        width: connectionActionButtonWidth
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
        }
    }

    private var automaticConnectionSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            connectionItem(
                title: model.text("Codex", "Codex"),
                subtitle: model.text(
                    "支持 Codex Desktop、CLI、VS Code、Xcode、IDEA",
                    "Supports Codex Desktop, CLI, VS Code, Xcode, and IDEA"
                ),
                systemImage: "desktopcomputer"
            ) {
                HStack(spacing: 8) {
                    Text(model.text("自动监控", "Auto monitor"))
                        .font(settingsDetailStrongFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    settingsSwitch(codexDesktopMonitoringBinding)
                        .help(model.text(
                            "自动识别 Codex Desktop、CLI、VS Code、Xcode、IDEA 活动",
                            "Automatically detect Codex Desktop, CLI, VS Code, Xcode, and IDEA activity"
                        ))
                }
            }

            Divider()

            connectionItem(
                title: model.text("Codex Hook（可选）", "Codex Hook (Optional)"),
                subtitle: model.text(
                    "可选增强：用于权限请求、低延迟和兼容旧版本",
                    "Optional enhancement for permission requests, lower latency, and compatibility"
                ),
                systemImage: "terminal"
            ) {
                hookActionButtons(
                    preview: { model.previewCodexHookInstall() },
                    install: { model.installCodexHooks() },
                    uninstall: { model.uninstallCodexHooks() }
                )
            }

            Divider()

            connectionItem(
                title: model.text("Claude（尚未测试）", "Claude (Untested)"),
                subtitle: model.text(
                    "支持 Claude Desktop",
                    "Supports Claude Desktop"
                ),
                systemImage: "sparkles"
            ) {
                HStack(spacing: 8) {
                    Text(model.text("自动监控", "Auto monitor"))
                        .font(settingsDetailStrongFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    settingsSwitch(claudeDesktopMonitoringBinding)
                        .help(model.text(
                            "自动识别 Claude Desktop 活动",
                            "Automatically detect Claude Desktop activity"
                        ))
                }
            }

            Divider()

            connectionItem(
                title: model.text("Claude Hook（可选）", "Claude Hook (Optional)"),
                subtitle: model.text(
                    "Claude Code 全局 Hook 可单独检查或安装",
                    "Claude Code global hooks can be checked or installed separately"
                ),
                systemImage: "terminal"
            ) {
                hookActionButtons(
                    preview: { model.previewClaudeHookInstall() },
                    install: { model.installClaudeHooks() },
                    uninstall: { model.uninstallClaudeHooks() }
                )
            }

            if model.isHookInstallRunning {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
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

            settingRow(model.text("自动检查更新", "Automatically check for updates")) {
                settingsSwitch(automaticUpdateCheckBinding)
                    .help(model.text(
                        "由 Sparkle 定期检查更新，可直接下载并重启安装。",
                        "Sparkle checks periodically and can download the update, then relaunch to install."
                    ))
            }

            settingRow(model.text("更新", "Updates")) {
                VStack(alignment: .trailing, spacing: 8) {
                    Button {
                        updater.checkForUpdates()
                    } label: {
                        settingsActionSurface(
                            model.text("检查更新", "Check for Updates"),
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(updater.isConfigured && !updater.canCheckForUpdates)

                    Button {
                        model.openLatestReleasePage()
                    } label: {
                        settingsActionSurface(
                            model.text("打开下载页面", "Open Download Page"),
                            systemImage: "arrow.up.forward.app"
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()

            Text(model.text("© 2026 XiongYang Guan · Apache License 2.0", "© 2026 XiongYang Guan · Apache License 2.0"))
                .font(settingsBodyFont)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .center)
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

    private func settingControlRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top) {
            Spacer()
            content()
        }
    }

    private func settingsSwitch(_ isOn: Binding<Bool>, tint: Color? = nil) -> some View {
        Toggle("", isOn: isOn)
            .toggleStyle(.switch)
            .labelsHidden()
            .tint(tint)
            .fixedSize()
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
        opensUpward: Bool = false,
        optionsHeight: CGFloat? = nil,
        @ViewBuilder options: () -> Options
    ) -> some View {
        let isExpanded = expandedSettingsDropdown == id
        let expandedOffset = opensUpward
            ? -((optionsHeight ?? dropdownControlHeight) + 4)
            : dropdownControlHeight + 4
        let transitionEdge: Edge = opensUpward ? .bottom : .top

        return Button {
            withAnimation(.easeInOut(duration: 0.12)) {
                expandedSettingsDropdown = isExpanded ? nil : id
            }
        } label: {
            dropdownSurface(
                title,
                systemImage: systemImage,
                isExpanded: isExpanded,
                opensUpward: opensUpward,
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
                    .offset(y: expandedOffset)
                    .shadow(color: .black.opacity(0.16), radius: 10, y: 5)
                    .transition(.opacity.combined(with: .move(edge: transitionEdge)))
                    .zIndex(1)
            }
        }
        .zIndex(isExpanded ? 1000 : 0)
    }

    private var dropdownControlHeight: CGFloat {
        28
    }

    private func dropdownOptionsHeight(optionCount: Int) -> CGFloat {
        CGFloat(optionCount) * dropdownOptionHeight + 6
    }

    private var dropdownOptionHeight: CGFloat {
        28
    }

    private func dropdownSurface(
        _ title: String,
        systemImage: String? = nil,
        isExpanded: Bool,
        opensUpward: Bool = false,
        width: CGFloat
    ) -> some View {
        let chevronName = opensUpward
            ? (isExpanded ? "chevron.down" : "chevron.up")
            : (isExpanded ? "chevron.up" : "chevron.down")

        return HStack(spacing: 7) {
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

            Image(systemName: chevronName)
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
            .frame(width: width, height: dropdownOptionHeight)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isSelected ? Color.accentColor : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func signalLightAgentOption(
        _ scope: SignalLightAgentScope,
        isSelected: Bool,
        isRunning: Bool,
        width: CGFloat
    ) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.12)) {
                model.toggleSignalLightAgentScope(scope)
            }
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(isRunning ? Color.green : Color.clear)
                    .frame(width: 6, height: 6)
                    .frame(width: 12)

                Text(model.displayName(for: scope))
                    .lineLimit(1)
                    .allowsTightening(true)
                    .truncationMode(.tail)

                Spacer(minLength: 4)
            }
            .font(agentScopeOptionFont)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, 7)
            .frame(width: width, height: 26)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.92) : Color.clear)
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
            settingsActionSurface(title, systemImage: systemImage, width: width ?? connectionActionButtonWidth)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private func hookActionButtons(
        preview: @escaping () -> Void,
        install: @escaping () -> Void,
        uninstall: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .trailing, spacing: 8) {
            HStack(spacing: 8) {
                connectionActionButton(
                    model.text("检查", "Check"),
                    systemImage: "checkmark.circle",
                    disabled: model.isHookInstallRunning,
                    action: preview
                )

                connectionActionButton(
                    model.text("安装", "Install"),
                    systemImage: "wrench.and.screwdriver",
                    disabled: model.isHookInstallRunning,
                    action: install
                )
            }

            HStack(spacing: 8) {
                Color.clear
                    .frame(width: connectionActionButtonWidth, height: 1)

                connectionActionButton(
                    model.text("卸载", "Uninstall"),
                    systemImage: "trash",
                    disabled: model.isHookInstallRunning,
                    action: uninstall
                )
            }
        }
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

    private func soundPreviewButton(disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            settingsActionSurface(
                model.text("试听", "Preview"),
                systemImage: "speaker.wave.2.fill",
                width: soundPreviewButtonWidth
            )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private func compactSegmentedControl<Option: Hashable>(
        options: [Option],
        selection: Binding<Option>,
        width: CGFloat? = nil,
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
        .frame(width: width ?? effectSegmentWidth, height: dropdownControlHeight)
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

    private func glassMenuBarBackground(cornerRadius: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(settingsPanelFill)
        }
    }

    private func glassSelectedMenuItemBackground(cornerRadius: CGFloat) -> some View {
        ZStack {
            if model.isSettingsGlassEnabled {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.clear)
            }

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(selectedMenuItemStroke, lineWidth: 0.7)
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
        switch (colorScheme, model.settingsGlassEffect) {
        case (.dark, .reduced):
            return Color.white.opacity(0.10)
        case (.dark, .standard):
            return Color.white.opacity(0.075)
        case (_, .reduced):
            return Color.white.opacity(0.34)
        case (_, .standard):
            return Color.white.opacity(0.24)
        }
    }

    private var glassDropdownTint: Color {
        switch (colorScheme, model.settingsGlassEffect) {
        case (.dark, .reduced):
            return Color.white.opacity(0.09)
        case (.dark, .standard):
            return Color.white.opacity(0.065)
        case (_, .reduced):
            return Color.white.opacity(0.26)
        case (_, .standard):
            return Color.white.opacity(0.18)
        }
    }

    private var glassWindowTint: Color {
        switch (colorScheme, model.settingsGlassEffect) {
        case (.dark, .reduced):
            return Color.black.opacity(0.24)
        case (.dark, .standard):
            return Color.black.opacity(0.14)
        case (_, .reduced):
            return Color.white.opacity(0.28)
        case (_, .standard):
            return Color.white.opacity(0.14)
        }
    }

    private var glassMenuBarStroke: Color {
        model.isSettingsGlassEnabled
            ? Color.white.opacity(colorScheme == .dark ? 0.12 : 0.42)
            : solidControlStroke
    }

    private var settingsPanelFill: some ShapeStyle {
        .tertiary.opacity(0.08)
    }

    private var selectedMenuItemStroke: Color {
        model.isSettingsGlassEnabled
            ? Color.white.opacity(colorScheme == .dark ? 0.18 : 0.46)
            : solidControlStroke
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

    private var soundPreviewButtonWidth: CGFloat {
        settingsControlWidth / 2
    }

    private var diagnosticActionButtonWidth: CGFloat {
        compactConnectionActionButtonWidth
    }

    private var connectionActionButtonWidth: CGFloat {
        compactConnectionActionButtonWidth
    }

    private var compactConnectionActionButtonWidth: CGFloat {
        usesCompactLatinLayout ? 146 : 126
    }

    private var effectMenuWidth: CGFloat {
        settingsControlWidth
    }

    private var effectSegmentWidth: CGFloat {
        settingsControlWidth
    }

    private var agentScopeMenuWidth: CGFloat {
        settingsControlWidth
    }

    private var settingsControlWidth: CGFloat {
        usesCompactLatinLayout ? 162 : 150
    }

    private var statusBarStyleOptions: [TrafficSignalStyle] {
        [.macOS, .trafficLight]
    }

    private func activitySessionRow(_ session: SessionStatus) -> some View {
        HStack(alignment: .top, spacing: 12) {
            activityIndicatorDot(
                color: debugSignalColor(session.signal),
                size: 8,
                topPadding: 6
            )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(model.friendlyAgentName(session.agent))
                        .font(settingsSubsectionTitleFont)
                        .lineLimit(1)

                    Text(model.activitySessionRuntimeLabel(for: session))
                        .font(settingsDetailStrongFont)
                        .foregroundStyle(debugSignalColor(session.signal))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(debugSignalColor(session.signal).opacity(0.12), in: Capsule())
                }

                Text(model.activitySessionStatusSubtitle(for: session))
                    .font(settingsDetailFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 10)
        }
        .padding(.leading, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func activityEventRow(_ event: RecentSignalEvent, width: CGFloat) -> some View {
        let recentEventDotSize: CGFloat = 7
        let indicatorColumnWidth: CGFloat = 20
        let timeTrailingInset = (indicatorColumnWidth - recentEventDotSize) / 2

        return HStack(alignment: .top, spacing: 12) {
            activityIndicatorDot(
                color: debugSignalColor(event.signal),
                size: recentEventDotSize,
                topPadding: 5
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(model.activityEventTitle(for: event))
                    .font(settingsBodyStrongFont)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(model.activityEventSubtitle(for: event))
                    .font(settingsDetailFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(event.updatedAt.formatted(date: .omitted, time: .shortened))
                .font(settingsDetailFont)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .frame(width: 72, alignment: .trailing)
                .padding(.trailing, timeTrailingInset)
        }
        .frame(width: width, alignment: .leading)
    }

    private func activityIndicatorDot(color: Color, size: CGFloat, topPadding: CGFloat) -> some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .padding(.top, topPadding)
            .frame(width: 20, alignment: .center)
    }

    private func emptyActivityRow(icon: String, title: String, subtitle: String? = nil) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(settingsTabIconFont)
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(settingsBodyStrongFont)
                if let subtitle {
                    Text(subtitle)
                        .font(settingsBodyFont)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        HStack(alignment: .center, spacing: 12) {
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
            connectionSummary(summary, operation: model.hookInstallOperation)
        } else {
            connectionMessage(
                title: model.text("连接结果", "Connection result"),
                message: message,
                lineLimit: 3
            )
        }
    }

    private func connectionSummary(_ summary: HookConnectionSummary, operation: HookInstallOperation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: summary.isReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(summary.isReady ? .green : .orange)
                Text(model.text("连接结果", "Connection result"))
                    .font(settingsBodyStrongFont)
                Spacer()
                Text(connectionCompletionText(summary: summary, operation: operation))
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
                            Text(connectionStatusText(item.status, mode: summary.mode, operation: operation))
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

            if let note = connectionSummaryNote(summary, operation: operation) {
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

    private func connectionCompletionText(summary: HookConnectionSummary, operation: HookInstallOperation) -> String {
        if operation == .uninstall {
            return model.text("卸载完成", "Uninstall complete")
        }
        return summary.mode == .dryRun
            ? model.text("检查完成", "Check complete")
            : model.text("安装完成", "Install complete")
    }

    private func connectionStatusText(
        _ status: HookConnectionStatus,
        mode: HookConnectionMode,
        operation: HookInstallOperation
    ) -> String {
        if operation == .uninstall {
            switch status {
            case .ready:
                return model.text("无需卸载", "Nothing to remove")
            case .installed:
                return model.text("已移除", "Removed")
            case .needsInstall, .unknown:
                return model.text("已完成", "Completed")
            }
        }

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

    private func connectionSummaryNote(_ summary: HookConnectionSummary, operation: HookInstallOperation) -> String? {
        if operation == .uninstall {
            return model.text("Hook 已移除。", "Hooks removed.")
        }
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

    private var statusBarEnabledBinding: Binding<Bool> {
        Binding(
            get: { model.isStatusBarIconEnabled },
            set: { model.setStatusBarIconEnabled($0) }
        )
    }

    private var statusMenuModeBinding: Binding<StatusMenuMode> {
        Binding(
            get: { model.statusMenuMode },
            set: { model.setStatusMenuMode($0) }
        )
    }

    private var floatingSignalEnabledBinding: Binding<Bool> {
        Binding(
            get: { model.isFloatingSignalEnabled },
            set: { model.setFloatingSignalEnabled($0) }
        )
    }

    private var floatingSignalLayoutBinding: Binding<TrafficSignalLayout> {
        Binding(
            get: { model.floatingSignalLayout },
            set: { model.setFloatingSignalLayout($0) }
        )
    }

    private var floatingSignalSoundEnabledBinding: Binding<Bool> {
        Binding(
            get: { model.isFloatingSignalSoundEnabled },
            set: { model.setFloatingSignalSoundEnabled($0) }
        )
    }

    private var floatingSignalSoundLevelBinding: Binding<FloatingSignalSoundLevel> {
        Binding(
            get: { model.floatingSignalSoundLevel },
            set: { model.setFloatingSignalSoundLevel($0) }
        )
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { model.isLaunchAtLoginEnabled },
            set: { model.setLaunchAtLoginEnabled($0) }
        )
    }

    private var monitoringPausedBinding: Binding<Bool> {
        Binding(
            get: { model.isMonitoringPaused },
            set: { model.setMonitoringPaused($0) }
        )
    }

    private var lowPowerModeBinding: Binding<Bool> {
        Binding(
            get: { model.isLowPowerModeEnabled },
            set: { model.setLowPowerModeEnabled($0) }
        )
    }

    private var newZealandTrafficLightModeBinding: Binding<Bool> {
        Binding(
            get: { model.isNewZealandTrafficLightModeEnabled },
            set: { model.setNewZealandTrafficLightModeEnabled($0) }
        )
    }

    private var automaticUpdateCheckBinding: Binding<Bool> {
        Binding(
            get: { updater.automaticallyChecksForUpdates },
            set: { updater.setAutomaticallyChecksForUpdates($0) }
        )
    }

    private var codexDesktopMonitoringBinding: Binding<Bool> {
        Binding(
            get: { model.isCodexDesktopMonitoringEnabled },
            set: { model.setCodexDesktopMonitoringEnabled($0) }
        )
    }

    private var claudeDesktopMonitoringBinding: Binding<Bool> {
        Binding(
            get: { model.isClaudeDesktopMonitoringEnabled },
            set: { model.setClaudeDesktopMonitoringEnabled($0) }
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
        case .reduced:
            return .sidebar
        case .standard:
            return .popover
        }
    }
}

private struct SettingsWindowDragRegionView: NSViewRepresentable {
    func makeNSView(context: Context) -> DragRegionView {
        DragRegionView()
    }

    func updateNSView(_ nsView: DragRegionView, context: Context) {}

    final class DragRegionView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}

private struct RecentEventsScrollConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> ConfiguratorView {
        ConfiguratorView()
    }

    func updateNSView(_ nsView: ConfiguratorView, context: Context) {
        nsView.scheduleConfiguration()
    }

    final class ConfiguratorView: NSView {
        private var hasConfiguredScrollView = false

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            scheduleConfiguration()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleConfiguration()
        }

        func scheduleConfiguration() {
            guard !hasConfiguredScrollView else { return }
            for delay in [0.0, 0.05, 0.15, 0.35, 0.75] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.configureScrollView()
                }
            }
        }

        private func configureScrollView() {
            guard !hasConfiguredScrollView else { return }
            guard let scrollView = nearestScrollView() else { return }
            scrollView.hasVerticalScroller = false
            scrollView.hasHorizontalScroller = false
            scrollView.autohidesScrollers = true
            scrollView.scrollerStyle = .overlay
            scrollView.verticalScroller = nil
            scrollView.horizontalScroller = nil
            scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
            scrollView.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
            scrollView.contentView.postsBoundsChangedNotifications = true
            hasConfiguredScrollView = true
        }

        private func nearestScrollView() -> NSScrollView? {
            var view: NSView? = self

            while let current = view {
                if let scrollView = current as? NSScrollView {
                    return scrollView
                }

                if let scrollView = current.enclosingScrollView {
                    return scrollView
                }

                view = current.superview
            }

            return nil
        }
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
    private let signalOverride: AgentSignal?

    init(model: MenuBarStatusModel, signalOverride: AgentSignal? = nil) {
        self.model = model
        self.signalOverride = signalOverride
        _animationClock = ObservedObject(wrappedValue: model.animationClock)
    }

    var body: some View {
        PureActivitySignalLampView(
            signal: signalOverride ?? model.lightSnapshot.aggregate,
            tick: model.lightTick,
            allLightsOn: model.lightAllLightsOn,
            effectCustomization: model.lightEffectCustomization
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

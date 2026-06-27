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
    @State private var hoveredTokenActivityDayID: TimeInterval?
    @State private var selectedUsagePlatform: UsagePlatform = .codex
    @State private var selectedDebugProvider: DebugProvider = .codex
    @State private var selectedDebugFetchProvider: DebugProvider = .codex
    @State private var debugProbeLogText: String = ""
    @State private var isStatusBarLightDebugTargetEnabled = true
    @State private var isFloatingLightDebugTargetEnabled = true
    @State private var selectedLightDebugTest: LightDebugTest?
    @State private var isUsageAccountDetailsExpanded = false
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
        .onChange(of: model.isDebugSettingsVisible) { _, isVisible in
            if !isVisible && selectedSettingsTab == .debug {
                selectedSettingsTab = .advanced
            }
        }
    }

    private var settingsMenu: some View {
        HStack(spacing: 4) {
            ForEach(visibleSettingsTabs) { tab in
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

    private var visibleSettingsTabs: [SettingsTab] {
        SettingsTab.displayOrder(showDebug: model.isDebugSettingsVisible)
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
        case .usage:
            usageSettings
        case .connections:
            connectionSettings
        case .advanced:
            advancedSettings
        case .debug:
            debugSettings
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
        case .usage:
            return model.text("用量", "Usage")
        case .connections:
            return model.text("连接", "Connect")
        case .advanced:
            return model.text("高级", "Advanced")
        case .debug:
            return model.text("调试", "Debug")
        case .about:
            return model.text("关于", "About")
        }
    }

    fileprivate enum SettingsTab: String, CaseIterable, Identifiable {
        case activity
        case usage
        case general
        case connections
        case advanced
        case debug
        case about

        var id: String { rawValue }

        static func displayOrder(showDebug: Bool) -> [SettingsTab] {
            var tabs: [SettingsTab] = [
                .activity,
                .usage,
                .general,
                .connections,
                .advanced
            ]
            if showDebug {
                tabs.append(.debug)
            }
            tabs.append(.about)
            return tabs
        }

        var systemImage: String {
            switch self {
            case .general:
                return "gearshape"
            case .activity:
                return "waveform.path.ecg"
            case .usage:
                return "chart.bar.xaxis"
            case .connections:
                return "link"
            case .advanced:
                return "slider.horizontal.3"
            case .debug:
                return "stethoscope"
            case .about:
                return "info.circle"
            }
        }
    }

    private enum UsagePlatform: String, CaseIterable, Identifiable {
        case codex
        case claude

        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .codex:
                return "terminal"
            case .claude:
                return "sparkles"
            }
        }

        var supportsManagedAccounts: Bool {
            self == .codex
        }

        var supportsQuotaRefresh: Bool {
            self == .codex
        }

        var supportsTokenActivity: Bool {
            self == .codex
        }

        func matches(session: SessionStatus) -> Bool {
            let haystack = [
                session.sessionID,
                session.agent ?? "",
                session.lastEvent ?? ""
            ]
                .joined(separator: " ")
                .lowercased()

            switch self {
            case .codex:
                return haystack.contains("codex")
            case .claude:
                return haystack.contains("claude")
            }
        }
    }

    private enum DebugProvider: String, CaseIterable, Identifiable {
        case codex = "Codex"
        case claude = "Claude"

        var id: String { rawValue }
    }

    private enum LightDebugTest: Hashable {
        case signal(AgentSignal)
        case activeEffect(ActiveSignalEffect)
        case completedEffect(CompletedSignalEffect)
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
        case usagePlatform
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

    private var usageAccountStatusTitleFont: Font {
        .system(size: 13, weight: .semibold)
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
        let visibleScopeSet = visibleSignalLightAgentScopeSet
        let selectedScopes = model.displaySignalLightAgentScopes.intersection(visibleScopeSet)
        let fallbackScopes = model.signalLightAgentScopes.intersection(visibleScopeSet)
        let titleScopes = selectedScopes.isEmpty ? fallbackScopes : selectedScopes

        return inlineDropdown(
            id: .signalLightAgents,
            title: model.displayName(for: titleScopes),
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
            let groupOptions = visibleSignalLightAgentScopes
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

                if shouldShowSignalLightAgentUnavailableHint,
                   let hint = model.signalLightAgentUnavailableHint {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "info.circle")
                            .font(settingsTinyIconFont)
                        Text(hint)
                            .font(settingsDetailFont)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(.secondary)
                }

                if model.isLightDebugModeEnabled {
                    lightDebugModeBanner
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

    private var visibleSignalLightAgentScopes: [SignalLightAgentScope] {
        SignalLightAgentScope.visibleCases
    }

    private var visibleSignalLightAgentScopeSet: Set<SignalLightAgentScope> {
        Set(visibleSignalLightAgentScopes)
    }

    private var shouldShowSignalLightAgentUnavailableHint: Bool {
        let selectedScopes = model.signalLightAgentScopes.intersection(visibleSignalLightAgentScopeSet)
        let visibleOtherRunningScopes = model.activeSignalLightAgentScopes
            .intersection(visibleSignalLightAgentScopeSet)
            .subtracting(selectedScopes)
        return !visibleOtherRunningScopes.isEmpty
    }

    private var lightDebugModeBanner: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "ladybug")
                .font(settingsTinyIconFont)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.text("灯光调试模式", "Light debug mode"))
                    .font(settingsBodyStrongFont)
                Text(model.text(
                    "正常 Agent 灯效已暂停，当前状态栏和悬浮灯由调试按钮驱动。",
                    "Normal agent lighting is paused; the status bar and floating light are driven by debug controls."
                ))
                .font(settingsDetailFont)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var usageSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Text(model.text("用量", "Usage"))
                    .font(settingsSectionTitleFont)

                Spacer(minLength: 12)

                usagePlatformMenu
            }
            .zIndex(expandedSettingsDropdown == .usagePlatform ? 1000 : 0)

            VStack(alignment: .leading, spacing: 14) {
                usageAccountCard

                agentQuotaSummaryCard

                usageTokenSummaryCard
            }
        }
        .onAppear {
            refreshSelectedUsagePlatform()
        }
        .onChange(of: selectedUsagePlatform) { _, _ in
            refreshSelectedUsagePlatform()
        }
    }

    private var usagePlatformMenu: some View {
        inlineDropdown(
            id: .usagePlatform,
            title: usagePlatformName(selectedUsagePlatform),
            systemImage: selectedUsagePlatform.systemImage,
            width: 138,
            optionsHeight: dropdownOptionsHeight(optionCount: UsagePlatform.allCases.count)
        ) {
            dropdownOptions(width: 138) {
                ForEach(UsagePlatform.allCases) { platform in
                    dropdownOption(
                        usagePlatformName(platform),
                        systemImage: platform.systemImage,
                        isSelected: selectedUsagePlatform == platform,
                        width: 138
                    ) {
                        selectedUsagePlatform = platform
                    }
                }
            }
        }
        .help(model.text("切换用量平台", "Switch usage platform"))
    }

    private func usagePlatformName(_ platform: UsagePlatform) -> String {
        switch platform {
        case .codex:
            return "Codex"
        case .claude:
            return "Claude"
        }
    }

    private func refreshSelectedUsagePlatform() {
        guard selectedUsagePlatform == .codex else { return }
        model.refreshCodexAccounts()
        model.pollCodexRateLimitsIfNeeded(force: model.latestAgentQuota == nil)
        model.refreshTokenActivityIfNeeded()
        model.refreshCodexProviderDetails()
    }

    private func refreshSelectedUsagePlatform(force: Bool) {
        guard selectedUsagePlatform == .codex else { return }
        model.refreshCodexAccounts()
        model.pollCodexRateLimitsIfNeeded(force: force)
        model.refreshTokenActivityIfNeeded(force: force)
        model.refreshCodexProviderDetails(force: force)
    }

    private var isSelectedUsagePlatformRefreshing: Bool {
        switch selectedUsagePlatform {
        case .codex:
            return model.isCodexAccountActionRunning
                || model.isCodexRateLimitFetchInFlight
                || model.isCodexProviderDetailsLoading
        case .claude:
            return false
        }
    }

    @ViewBuilder
    private var usageAccountCard: some View {
        switch selectedUsagePlatform {
        case .codex:
            codexAccountSwitcherCard
        case .claude:
            claudeAccountStatusCard
        }
    }

    private var codexUsageSourceControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            codexSettingsControlRow(
                title: model.text("用量来源", "Usage Source"),
                subtitle: model.text(
                    "如果首选来源失败，自动模式会回退到可用来源。",
                    "Automatic mode falls back to an available source if the preferred source fails."
                ),
                trailingValue: codexResolvedUsageSourceText
            ) {
                codexUsageDataSourceMenu
            }

            Divider().opacity(0.35)

            codexSettingsControlRow(
                title: "OpenAI Cookie",
                subtitle: codexOpenAICookieSubtitle
            ) {
                codexOpenAICookieModeMenu
            }

            if model.codexOpenAICookieMode == .manual {
                codexManualOpenAICookieInput
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var codexProviderDetailsDisclosure: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().opacity(0.35)

            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    isUsageAccountDetailsExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Text(model.text("详情", "Details"))
                        .font(settingsBodyStrongFont)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer(minLength: 10)

                    Image(systemName: "chevron.down")
                        .font(settingsTinyIconFont.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isUsageAccountDetailsExpanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(model.text("展开 Codex 状态详情", "Expand Codex status details"))

            if isUsageAccountDetailsExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    codexUsageSourceControls

                    Divider().opacity(0.35)

                    codexProviderDetailsContent
                }
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var codexProviderDetailsContent: some View {
        VStack(alignment: .leading, spacing: 7) {
            codexDetailRow(model.text("状态", "Status"), codexProviderEnabledText)
            codexDetailRow(model.text("来源", "Source"), codexResolvedUsageSourceText)
            codexDetailRow(model.text("版本", "Version"), codexProviderVersionText)
            codexDetailRow(model.text("已更新", "Updated"), codexProviderUpdatedText)
            codexDetailRow(model.text("服务状态", "Service Status"), codexProviderServiceStatusText)
        }
    }

    private var codexProviderDetailsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Codex")
                        .font(settingsSubsectionTitleFont)
                        .lineLimit(1)

                    Text(codexProviderSubtitle)
                        .font(settingsDetailFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 12)

            }

            codexProviderDetailsContent
        }
        .padding(10)
        .background(.tertiary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onAppear {
            model.refreshCodexProviderDetails()
        }
    }

    private func codexSettingsControlRow<Control: View>(
        title: String,
        subtitle: String,
        trailingValue: String? = nil,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(settingsBodyStrongFont)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                Text(subtitle)
                    .font(settingsDetailFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 10)

            control()

            if let trailingValue {
                Text(trailingValue)
                    .font(settingsDetailStrongFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(minWidth: 42, alignment: .leading)
            }
        }
    }

    private var codexUsageDataSourceMenu: some View {
        Menu {
            ForEach(CodexUsageDataSource.selectableCases) { source in
                Button {
                    model.setCodexUsageDataSource(source)
                } label: {
                    if model.codexUsageDataSource == source {
                        Label(codexUsageDataSourceName(source), systemImage: "checkmark")
                    } else {
                        Text(codexUsageDataSourceName(source))
                    }
                }
            }
        } label: {
            settingsActionSurface(
                codexUsageDataSourceName(model.codexUsageDataSource),
                systemImage: nil,
                width: 138
            )
        }
        .menuStyle(.borderlessButton)
        .help(model.text("选择 Codex 用量读取来源", "Choose Codex usage data source"))
    }

    private var codexOpenAICookieModeMenu: some View {
        Menu {
            ForEach(CodexOpenAICookieMode.selectableCases) { mode in
                Button {
                    model.setCodexOpenAICookieMode(mode)
                } label: {
                    if model.codexOpenAICookieMode == mode {
                        Label(codexOpenAICookieModeName(mode), systemImage: "checkmark")
                    } else {
                        Text(codexOpenAICookieModeName(mode))
                    }
                }
            }
        } label: {
            settingsActionSurface(
                codexOpenAICookieModeName(model.codexOpenAICookieMode),
                systemImage: nil,
                width: 118
            )
        }
        .menuStyle(.borderlessButton)
        .help(model.text("选择 OpenAI Cookie 模式", "Choose OpenAI cookie mode"))
    }

    private var codexOpenAICookieSubtitle: String {
        switch model.codexOpenAICookieMode {
        case .manual:
            return model.text(
                "粘贴来自 chatgpt.com request 的 Cookie 标头。",
                "Paste the Cookie header from a chatgpt.com request."
            )
        case .automatic:
            return model.text(
                "自动读取浏览器 Cookie；不可用时回退 OAuth API。",
                "Automatically reads browser cookies; falls back to the OAuth API when unavailable."
            )
        case .off:
            return model.text(
                "不使用浏览器 Cookie；用量会走 OAuth API。",
                "Browser cookies are disabled; usage uses the OAuth API."
            )
        }
    }

    private var codexManualOpenAICookieInput: some View {
        SecureField(
            model.text("Cookie: ...", "Cookie: ..."),
            text: codexManualOpenAICookieBinding
        )
        .textFieldStyle(.plain)
        .font(.system(size: 12, weight: .regular, design: .monospaced))
        .foregroundStyle(.primary)
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
        .background(Color.black.opacity(colorScheme == .dark ? 0.22 : 0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(solidControlStroke, lineWidth: 0.7)
        )
        .help(model.text(
            "粘贴完整 Cookie 标头，例如 Cookie: key=value; ...",
            "Paste the full Cookie header, for example Cookie: key=value; ..."
        ))
    }

    private var codexManualOpenAICookieBinding: Binding<String> {
        Binding(
            get: { model.codexManualOpenAICookieHeader },
            set: { model.setCodexManualOpenAICookieHeader($0) }
        )
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
        let visibleSessions = visibleActivitySessions
        let liveSelectedSignal = visibleSessions
            .map(\.signal)
            .max { lhs, rhs in
                lhs.displayState.priority < rhs.displayState.priority
            } ?? .idle
        let selectedSignal: AgentSignal = model.isLightDebugModeEnabled ? .idle : liveSelectedSignal
        let updatedAt = visibleSessions.map(\.updatedAt).max()

        return HStack(alignment: .top, spacing: 12) {
            ActivitySignalLampView(
                model: model,
                signalOverride: model.isLightDebugModeEnabled ? nil : selectedSignal
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(model.isLightDebugModeEnabled ? model.text("调试模式", "Debug mode") : model.displayName(for: selectedSignal))
                    .font(settingsSubsectionTitleFont)
                Text(model.isLightDebugModeEnabled
                    ? model.text("正常 Agent 灯效已暂停。", "Normal agent lighting is paused.")
                    : model.summary(for: selectedSignal)
                )
                    .font(settingsBodyFont)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(model.isLightDebugModeEnabled
                    ? model.text("由灯光调试按钮驱动", "Driven by light debug controls")
                    : (updatedAt.map(activityUpdatedText) ?? model.text("等待运行", "Waiting to launch"))
                )
                    .font(settingsDetailFont)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 16)

            VStack(alignment: .trailing, spacing: 4) {
                Label(
                    activitySummaryModeLabel,
                    systemImage: activitySummaryModeIcon
                )
                .font(settingsDetailStrongFont)
                .foregroundStyle(activitySummaryModeColor)

                Text("\(visibleSessions.count) \(model.text("个会话", "sessions"))")
                    .font(settingsDetailFont)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
    }

    private var activitySummaryModeLabel: String {
        if model.isLightDebugModeEnabled {
            return model.text("调试模式", "Debug mode")
        }
        return model.isMonitoringPaused ? model.text("监控已暂停", "Monitoring paused") : model.text("实时监控", "Live monitoring")
    }

    private var activitySummaryModeIcon: String {
        if model.isLightDebugModeEnabled {
            return "ladybug"
        }
        return model.isMonitoringPaused ? "pause.circle" : "dot.radiowaves.left.and.right"
    }

    private var activitySummaryModeColor: Color {
        if model.isLightDebugModeEnabled {
            return .orange
        }
        return model.isMonitoringPaused ? .orange : .secondary
    }

    private var agentQuotaSummaryCard: some View {
        let quota = selectedUsageQuota

        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text(model.text("会话", "Session"))
                    .font(settingsSubsectionTitleFont)

                Spacer(minLength: 12)

                if let quota {
                    Text(model.quotaUpdatedText(for: quota))
                        .font(settingsDetailFont)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

            }

            if selectedUsagePlatform == .codex {
                VStack(alignment: .leading, spacing: 8) {
                    if let quota {
                        quotaWindowTiles(for: quota)
                    } else {
                        HStack(alignment: .top, spacing: 8) {
                            quotaWindowPlaceholderTile(.fiveHours)
                            quotaWindowPlaceholderTile(.weekly)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if let quota {
                quotaWindowTiles(for: quota)
            } else if selectedUsagePlatform == .claude {
                usageUnavailableRow(
                    icon: "chart.bar.xaxis",
                    title: model.text("暂无 Claude 会话数据", "No Claude session data"),
                    subtitle: model.text(
                        "当前版本还没有接入 Claude 会话用量 API。",
                        "Claude session usage API is not connected in this version."
                    )
                )
            } else {
                HStack(alignment: .top, spacing: 8) {
                    quotaWindowPlaceholderTile(.fiveHours)
                    quotaWindowPlaceholderTile(.weekly)
                }
            }
        }
        .padding(10)
        .background(.tertiary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onAppear {
            if selectedUsagePlatform.supportsQuotaRefresh {
                model.pollCodexRateLimitsIfNeeded()
            }
        }
    }

    private var selectedUsageQuota: AgentQuotaStatus? {
        switch selectedUsagePlatform {
        case .codex:
            return model.latestAgentQuota
        case .claude:
            return latestUsageQuota(for: .claude)
        }
    }

    private func latestUsageQuota(for platform: UsagePlatform) -> AgentQuotaStatus? {
        model.activitySnapshot.sessions
            .filter { platform.matches(session: $0) }
            .compactMap(\.quota)
            .max { lhs, rhs in lhs.updatedAt < rhs.updatedAt }
    }

    private var codexAccountSwitcherCard: some View {
        let activeSavedAccount = model.codexSavedAccounts.first { model.isActiveCodexAccount($0) }
        let currentAccount = model.codexCurrentAccount
        let shouldShowSaveCurrent = currentAccount != nil && activeSavedAccount == nil

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(model.text("账户", "Account"))
                    .font(settingsSubsectionTitleFont)

                Spacer(minLength: 12)

                if isSelectedUsagePlatformRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.65)
                }

                Button {
                    refreshSelectedUsagePlatform(force: true)
                } label: {
                    settingsIconActionSurface(systemImage: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .disabled(isSelectedUsagePlatformRefreshing)
                .help(model.text("刷新 Codex 账户、会话和 Token 使用", "Refresh Codex account, session, and token usage"))
            }

            VStack(alignment: .leading, spacing: 10) {
                usageAccountIdentityRow(
                    title: model.codexCurrentAccount?.displayName ?? model.text("未找到 Codex 登录", "No Codex login found"),
                    detail: codexAccountPlanDetail,
                    isActive: model.codexCurrentAccount != nil,
                    badge: currentAccount == nil ? nil : model.text("默认", "Default")
                )

                HStack(alignment: .center, spacing: 8) {
                    connectionActionButton(
                        model.text("添加账号", "Add"),
                        systemImage: "person.crop.circle.badge.plus",
                        width: 92,
                        disabled: model.isCodexAccountActionRunning,
                        action: { model.addCodexAccount() }
                    )

                    if shouldShowSaveCurrent {
                        connectionActionButton(
                            model.text("保存当前", "Save Current"),
                            systemImage: "tray.and.arrow.down",
                            width: 96,
                            disabled: model.isCodexAccountActionRunning,
                            action: { model.saveCurrentCodexAccount() }
                        )
                    }

                    codexAccountSwitchMenu
                    codexAccountMoreMenu(activeSavedAccount: activeSavedAccount)

                    Spacer(minLength: 0)
                }

                codexProviderDetailsDisclosure
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            if let message = model.codexAccountMessage {
                Text(message)
                    .font(settingsDetailFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(.tertiary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onAppear {
            model.refreshCodexProviderDetails()
        }
    }

    private var codexAccountSwitchMenu: some View {
        Menu {
            if model.codexSavedAccounts.isEmpty {
                Text(model.text("暂无保存账户", "No saved accounts"))
            } else {
                ForEach(model.codexSavedAccounts) { account in
                    Button {
                        model.switchCodexAccount(account)
                    } label: {
                        Label(
                            account.displayName,
                            systemImage: model.isActiveCodexAccount(account) ? "checkmark.circle.fill" : "person"
                        )
                    }
                    .disabled(model.isActiveCodexAccount(account) || model.isCodexAccountActionRunning)
                }
            }
        } label: {
            settingsTextMenuSurface(model.text("切换", "Switch"), width: 72)
        }
        .menuStyle(.borderlessButton)
        .disabled(model.codexSavedAccounts.isEmpty || model.isCodexAccountActionRunning)
        .help(model.text("切换保存的 Codex 账户", "Switch saved Codex account"))
    }

    private func codexAccountMoreMenu(activeSavedAccount: CodexAccountProfile?) -> some View {
        Menu {
            Button {
                model.addCodexAccount()
            } label: {
                Label(model.text("重新认证", "Reauthenticate"), systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(model.codexCurrentAccount == nil || model.isCodexAccountActionRunning)

            if let activeSavedAccount {
                Divider()

                Button(role: .destructive) {
                    model.removeCodexAccount(activeSavedAccount)
                } label: {
                    Label(model.text("删除保存账户", "Remove saved account"), systemImage: "trash")
                }
                .disabled(model.isCodexAccountActionRunning)
            }
        } label: {
            settingsIconActionSurface(systemImage: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .disabled(model.isCodexAccountActionRunning)
        .help(model.text("更多账户操作", "More account actions"))
    }

    private func codexAccountBadge(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.secondary.opacity(0.12), in: Capsule())
            .lineLimit(1)
    }

    private func usageAccountIdentityRow(
        title: String,
        detail: String?,
        isActive: Bool,
        badge: String?
    ) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: isActive ? "person.crop.circle.fill" : "person.crop.circle.badge.questionmark")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(title)
                        .font(usageAccountStatusTitleFont)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .minimumScaleFactor(0.82)
                        .frame(height: 17, alignment: .leading)

                    if let badge {
                        codexAccountBadge(badge)
                    }
                }

                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(settingsDetailFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 10)
        }
    }

    private var codexProviderSubtitle: String {
        "\(codexProviderVersionText) · \(codexProviderUpdatedText)"
    }

    private var codexProviderEnabledText: String {
        model.isCodexDesktopMonitoringEnabled
            ? model.text("已启用", "Enabled")
            : model.text("已停用", "Disabled")
    }

    private var codexProviderVersionText: String {
        model.codexCLIVersionText ?? "codex-cli --"
    }

    private var codexProviderUpdatedText: String {
        guard let checkedAt = model.codexProviderDetailsCheckedAt else {
            return model.text("等待刷新", "Waiting to refresh")
        }
        return "\(model.text("更新于", "Updated")) \(checkedAt.formatted(date: .omitted, time: .shortened))"
    }

    private var codexProviderAccountText: String {
        model.codexProviderAccountEmail ?? model.codexCurrentAccount?.displayName ?? "--"
    }

    private var codexProviderPlanText: String {
        model.codexProviderPlanName ?? "--"
    }

    private var codexAccountPlanDetail: String? {
        guard let planName = model.codexProviderPlanName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !planName.isEmpty,
              planName != "--"
        else {
            return nil
        }
        return planName
    }

    private var codexProviderServiceStatusText: String {
        model.codexProviderServiceStatusText ?? model.text("未知", "Unknown")
    }

    private var codexResolvedUsageSourceText: String {
        switch model.codexUsageDataSource {
        case .automatic:
            switch model.codexCurrentAccount?.credentialKind {
            case .oauth:
                return "oauth"
            case .apiKey:
                return "api-key"
            case .unknown:
                return "unknown"
            case nil:
                return "auto"
            }
        case .oauthAPI:
            return "oauth"
        case .cliRPCPTY:
            return "cli"
        }
    }

    private func codexUsageDataSourceName(_ source: CodexUsageDataSource) -> String {
        switch source {
        case .automatic:
            return model.text("自动", "Auto")
        case .oauthAPI:
            return "OAuth API"
        case .cliRPCPTY:
            return "CLI (RPC/PTY)"
        }
    }

    private func codexOpenAICookieModeName(_ mode: CodexOpenAICookieMode) -> String {
        switch mode {
        case .automatic:
            return model.text("自动", "Auto")
        case .manual:
            return model.text("手动", "Manual")
        case .off:
            return model.text("关闭", "Off")
        }
    }

    private func codexDetailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(settingsDetailStrongFont)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
                .lineLimit(1)
                .minimumScaleFactor(0.82)

            Text(value)
                .font(settingsDetailStrongFont)
                .foregroundStyle(.primary.opacity(0.82))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)
        }
    }

    private var claudeAccountStatusCard: some View {
        let sessions = claudeUsageSessions
        let isActive = model.isClaudeDesktopMonitoringEnabled || !sessions.isEmpty
        let latestSession = sessions.max { lhs, rhs in lhs.updatedAt < rhs.updatedAt }
        let title = if !sessions.isEmpty {
            model.text("Claude 已检测到", "Claude detected")
        } else if model.isClaudeDesktopMonitoringEnabled {
            model.text("Claude 监控已开启", "Claude monitoring enabled")
        } else {
            model.text("Claude 未连接", "Claude not connected")
        }
        let detail = latestSession
            .map { activityUpdatedText($0.updatedAt) }
            ?? model.text(
                "启用 Claude Desktop 或 Claude Code Hook 后显示活动。",
                "Enable Claude Desktop or Claude Code hooks to show activity."
            )

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(model.text("账户", "Account"))
                    .font(settingsSubsectionTitleFont)

                if !sessions.isEmpty {
                    Text("\(sessions.count) \(model.text("个会话", "sessions"))")
                        .font(settingsDetailFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 12)
            }

            VStack(alignment: .leading, spacing: 10) {
                usageAccountIdentityRow(
                    title: title,
                    detail: detail,
                    isActive: isActive,
                    badge: nil
                )

                HStack(spacing: 8) {
                    connectionActionButton(
                        model.text("连接", "Connect"),
                        systemImage: "link",
                        width: 78,
                        action: {
                            closeSettingsDropdown()
                            selectedSettingsTab = .connections
                        }
                    )

                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(10)
        .background(.tertiary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func quotaWindowTiles(for quota: AgentQuotaStatus) -> some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(uniqueQuotaBadgeWindows(for: quota), id: \.self) { badgeWindow in
                quotaWindowTile(badgeWindow, quota: quota)
            }
        }
    }

    private func uniqueQuotaBadgeWindows(for quota: AgentQuotaStatus) -> [FloatingSignalQuotaBadgeWindow] {
        var result: [FloatingSignalQuotaBadgeWindow] = []
        var seen: [AgentQuotaWindowStatus] = []

        for badgeWindow in FloatingSignalQuotaBadgeWindow.allCases {
            guard let window = model.quotaWindow(for: badgeWindow, quota: quota) else { continue }
            guard !seen.contains(where: { quotaWindow($0, matches: window) }) else { continue }
            result.append(badgeWindow)
            seen.append(window)
        }

        return result.isEmpty ? [.fiveHours] : result
    }

    private func quotaWindow(_ lhs: AgentQuotaWindowStatus, matches rhs: AgentQuotaWindowStatus) -> Bool {
        lhs.windowMinutes == rhs.windowMinutes
            && abs(lhs.remainingPercent - rhs.remainingPercent) < 0.001
            && abs(lhs.usedPercent - rhs.usedPercent) < 0.001
            && lhs.resetsAt == rhs.resetsAt
    }

    private var claudeUsageSessions: [SessionStatus] {
        model.activitySnapshot.sessions.filter { UsagePlatform.claude.matches(session: $0) }
    }

    private func quotaWindowTile(_ badgeWindow: FloatingSignalQuotaBadgeWindow, quota: AgentQuotaStatus) -> some View {
        let window = model.quotaWindow(for: badgeWindow, quota: quota)

        return VStack(alignment: .leading, spacing: 3) {
            Text(model.quotaTitleLine(for: badgeWindow, quota: quota))
                .font(settingsBodyStrongFont)
                .lineLimit(1)
                .truncationMode(.tail)

            Text(model.quotaResetText(for: window, badgeWindow: badgeWindow))
                .font(settingsDetailFont)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func quotaWindowPlaceholderTile(_ badgeWindow: FloatingSignalQuotaBadgeWindow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(model.text(
                "\(model.displayName(for: badgeWindow)) · 剩余 --",
                "\(model.displayName(for: badgeWindow)) · -- remaining"
            ))
            .font(settingsBodyStrongFont)
            .lineLimit(1)
            .truncationMode(.tail)

            Text(model.text("等待刷新", "Waiting to refresh"))
                .font(settingsDetailFont)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var usageTokenSummaryCard: some View {
        let chartDays = selectedUsageTokenActivityChartDays
        let peakTokens = chartDays.map(\.totalTokens).max() ?? 0

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(model.text("Token 使用", "Token Usage"))
                    .font(settingsSubsectionTitleFont)

                Spacer(minLength: 12)

                if model.isTokenActivityLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.72)
                }
            }

            if selectedUsagePlatform.supportsTokenActivity {
                VStack(alignment: .leading, spacing: 10) {
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(minimum: 120), alignment: .leading),
                            GridItem(.flexible(minimum: 120), alignment: .leading),
                        ],
                        alignment: .leading,
                        spacing: 8
                    ) {
                        tokenUsageDashboardMetric(
                            title: model.text("今日", "Today"),
                            value: tokenActivityCurrencyText(selectedTokenActivityTodayEstimatedCostUSD)
                        )

                        tokenUsageDashboardMetric(
                            title: model.text("近 30 天费用", "Last 30 days cost"),
                            value: tokenActivityCurrencyText(selectedTokenActivityLast30EstimatedCostUSD)
                        )

                        tokenUsageDashboardMetric(
                            title: model.text("今日 token 用量", "Today token usage"),
                            value: "\(model.compactTokenCountText(selectedTokenActivityTodayTokens)) token"
                        )

                        tokenUsageDashboardMetric(
                            title: model.text("近 30 天 token 用量", "Last 30 days token usage"),
                            value: "\(model.compactTokenCountText(selectedTokenActivityLast30DaysTokens)) token"
                        )
                    }

                    tokenUsageBarChart(days: chartDays, peakTokens: peakTokens)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                usageUnavailableRow(
                    icon: "number",
                    title: model.text("暂无 Claude Token 数据", "No Claude token data"),
                    subtitle: model.text(
                        "当前版本还没有接入 Claude 本地 Token 用量扫描。",
                        "Claude local token usage scanning is not connected in this version."
                    )
                )
            }
        }
        .padding(10)
        .background(.tertiary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var selectedUsageTokenActivityChartDays: [CodexTokenActivityDay] {
        switch selectedUsagePlatform {
        case .codex:
            return tokenActivityChartDays
        case .claude:
            return emptyTokenActivityChartDays
        }
    }

    private var selectedTokenActivityTodayEstimatedCostUSD: Double? {
        guard selectedUsagePlatform == .codex else { return nil }
        return tokenActivityTodayEstimatedCostUSD
    }

    private var selectedTokenActivityLast30EstimatedCostUSD: Double? {
        guard selectedUsagePlatform == .codex else { return nil }
        return tokenActivityLast30EstimatedCostUSD
    }

    private var selectedTokenActivityTodayTokens: Int {
        guard selectedUsagePlatform == .codex else { return 0 }
        return tokenActivityTodayTokens
    }

    private var selectedTokenActivityLast30DaysTokens: Int {
        guard selectedUsagePlatform == .codex else { return 0 }
        return tokenActivityLast30DaysTokens
    }

    private func tokenUsageDashboardMetric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(settingsDetailStrongFont)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.82)

            Text(value)
                .font(settingsBodyStrongFont)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
        .help("\(title): \(value)")
    }

    private func tokenUsageBarChart(
        days: [CodexTokenActivityDay],
        peakTokens: Int,
        prominent: Bool = false
    ) -> some View {
        let hoveredDay = hoveredTokenActivityDay(in: days)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(days) { day in
                    tokenUsageBar(
                        day: day,
                        peakTokens: peakTokens,
                        prominent: prominent,
                        isSelected: hoveredTokenActivityDayID == day.id
                    )
                }
            }
            .frame(maxWidth: .infinity, minHeight: 62, maxHeight: 62, alignment: .bottom)
            .padding(.top, 4)

            HStack(alignment: .firstTextBaseline) {
                if let firstDay = days.first {
                    Text(tokenActivityShortDateText(firstDay.day))
                        .font(settingsDetailFont)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                if let lastDay = days.last {
                    Text(tokenActivityShortDateText(lastDay.day))
                        .font(settingsDetailFont)
                        .foregroundStyle(.tertiary)
                }
            }

            if let hoveredDay {
                tokenUsageDayDetail(for: hoveredDay)
            } else {
                tokenUsageHoverHint()
            }
        }
        .frame(maxWidth: .infinity, minHeight: 154, alignment: .topLeading)
    }

    private struct TokenUsageBarSegment: Identifiable {
        let model: String
        let tokens: Int

        var id: String { model }
    }

    private struct TokenUsageBarSlice: Identifiable {
        let segment: TokenUsageBarSegment
        let height: CGFloat

        var id: String { segment.id }
    }

    private func tokenUsageBar(
        day: CodexTokenActivityDay,
        peakTokens: Int,
        prominent: Bool = false,
        isSelected: Bool = false
    ) -> some View {
        let normalized = peakTokens > 0 ? CGFloat(day.totalTokens) / CGFloat(peakTokens) : 0
        let barHeight = day.totalTokens > 0 ? max(5, normalized * 58) : 4
        let opacity = day.totalTokens > 0 ? 0.35 + (normalized * 0.55) : 0.12
        let segments = tokenUsageBarSegments(for: day)
        let slices = tokenUsageBarSlices(segments: segments, barHeight: barHeight)

        return ZStack(alignment: .bottom) {
            if isSelected {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(Color.secondary.opacity(colorScheme == .dark ? 0.18 : 0.14))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            VStack(spacing: 0) {
                Spacer(minLength: 0)

                ZStack(alignment: .top) {
                    if day.totalTokens > 0 {
                        VStack(spacing: 0) {
                            ForEach(slices) { slice in
                                Rectangle()
                                    .fill(tokenUsageModelColor(
                                        slice.segment.model,
                                        normalized: normalized,
                                        prominent: prominent,
                                        isSelected: isSelected
                                    ))
                                    .frame(height: slice.height)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                    } else {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Color.secondary.opacity(opacity))
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: barHeight)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 62, maxHeight: 62, alignment: .bottom)
        .contentShape(Rectangle())
            .onHover { isHovering in
                if isHovering {
                    hoveredTokenActivityDayID = day.id
                } else if hoveredTokenActivityDayID == day.id {
                    hoveredTokenActivityDayID = nil
                }
            }
            .help(tokenUsageHelpText(for: day))
    }

    private func tokenUsageBarSlices(
        segments: [TokenUsageBarSegment],
        barHeight: CGFloat
    ) -> [TokenUsageBarSlice] {
        guard segments.isEmpty == false else { return [] }

        let segmentTotal = max(segments.map(\.tokens).reduce(0, +), 1)
        var slices = segments
            .reversed()
            .map { segment in
                let rawHeight = barHeight * CGFloat(segment.tokens) / CGFloat(segmentTotal)
                return TokenUsageBarSlice(
                    segment: segment,
                    height: max(rawHeight, tokenUsageMinimumVisibleSegmentHeight(
                        rawHeight: rawHeight,
                        barHeight: barHeight,
                        segmentCount: segments.count
                    ))
                )
            }

        let totalHeight = slices.map(\.height).reduce(0, +)
        guard totalHeight > barHeight,
              let tallestIndex = slices.indices.max(by: { slices[$0].height < slices[$1].height })
        else {
            return slices
        }

        let overflow = totalHeight - barHeight
        let tallest = slices[tallestIndex]
        slices[tallestIndex] = TokenUsageBarSlice(
            segment: tallest.segment,
            height: max(1, tallest.height - overflow)
        )
        return slices
    }

    private func tokenUsageMinimumVisibleSegmentHeight(
        rawHeight: CGFloat,
        barHeight: CGFloat,
        segmentCount: Int
    ) -> CGFloat {
        guard segmentCount > 1,
              rawHeight > 0,
              barHeight >= 12
        else {
            return rawHeight
        }
        return min(3, max(1.5, barHeight * 0.055))
    }

    private func tokenUsageBarSegments(for day: CodexTokenActivityDay) -> [TokenUsageBarSegment] {
        guard day.totalTokens > 0 else {
            return []
        }

        var totals = day.modelTokenTotals.filter { _, tokens in tokens > 0 }
        let knownTotal = totals.values.reduce(0, +)
        if day.totalTokens > knownTotal {
            totals["__other__"] = day.totalTokens - knownTotal
        }
        if totals.isEmpty {
            totals["__other__"] = day.totalTokens
        }

        return totals
            .sorted { lhs, rhs in
                let leftRank = tokenUsageModelSortRank(lhs.key)
                let rightRank = tokenUsageModelSortRank(rhs.key)
                if leftRank != rightRank {
                    return leftRank < rightRank
                }
                return lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending
            }
            .map { TokenUsageBarSegment(model: $0.key, tokens: $0.value) }
    }

    private func tokenUsageModelSortRank(_ modelName: String) -> Int {
        let modelName = modelName.lowercased()
        if modelName == "__other__" { return 900 }
        if modelName.contains("5.5") { return 10 }
        if modelName.contains("5.4") { return 20 }
        if modelName.contains("5.3") { return 30 }
        if modelName.contains("5.2") { return 40 }
        if modelName.contains("5.1") { return 50 }
        if modelName.contains("gpt-5") { return 60 }
        if modelName.contains("auto-review") { return 70 }
        return 800
    }

    private func tokenUsageModelColor(
        _ modelName: String,
        normalized: CGFloat,
        prominent: Bool,
        isSelected: Bool
    ) -> Color {
        let modelName = modelName.lowercased()
        let baseColor: Color
        if modelName.contains("5.5") {
            baseColor = Color(red: 0.10, green: 0.48, blue: 0.95)
        } else if modelName.contains("5.4") {
            baseColor = Color(red: 0.95, green: 0.52, blue: 0.18)
        } else if modelName.contains("5.3") {
            baseColor = Color(red: 0.62, green: 0.42, blue: 0.95)
        } else if modelName.contains("5.2") {
            baseColor = Color(red: 0.18, green: 0.68, blue: 0.84)
        } else if modelName.contains("5.1") {
            baseColor = Color(red: 0.22, green: 0.72, blue: 0.42)
        } else if modelName.contains("gpt-5") {
            baseColor = Color(red: 0.22, green: 0.58, blue: 0.76)
        } else if modelName.contains("auto-review") {
            baseColor = Color(red: 0.30, green: 0.72, blue: 0.76)
        } else {
            baseColor = Color.secondary
        }

        let baseOpacity = prominent
            ? 0.48 + (normalized * 0.42)
            : 0.42 + (normalized * 0.48)
        return baseColor.opacity(isSelected ? min(baseOpacity + 0.18, 1) : baseOpacity)
    }

    private func tokenUsageHelpText(for day: CodexTokenActivityDay) -> String {
        let summary = model.text(
            "\(tokenActivityDateText(day.day))：\(model.compactTokenCountText(day.totalTokens)) 个 Token",
            "\(tokenActivityDateText(day.day)): \(model.compactTokenCountText(day.totalTokens)) tokens"
        )
        let breakdown = tokenUsageBarSegments(for: day)
            .filter { $0.model != "__other__" }
            .map { "\(tokenUsageModelDisplayName($0.model)): \(model.compactTokenCountText($0.tokens))" }
            .joined(separator: " / ")

        return breakdown.isEmpty ? summary : "\(summary)\n\(breakdown)"
    }

    private func tokenUsageModelDisplayName(_ modelName: String) -> String {
        modelName == "__other__" ? model.text("其他", "Other") : modelName
    }

    private func tokenUsageDaySummaryText(for day: CodexTokenActivityDay) -> String {
        let cost = tokenActivityCurrencyText(day.estimatedCostUSD)
        return model.text(
            "\(tokenActivityShortDateText(day.day))：\(cost) · \(model.compactTokenCountText(day.totalTokens)) token",
            "\(tokenActivityShortDateText(day.day)): \(cost) · \(model.compactTokenCountText(day.totalTokens)) tokens"
        )
    }

    private func tokenUsageSegmentCostText(
        _ segment: TokenUsageBarSegment,
        day: CodexTokenActivityDay
    ) -> String? {
        if let cost = day.modelEstimatedCostTotals[segment.model] {
            return tokenActivityCurrencyText(cost)
        }
        return nil
    }

    private func tokenUsageDayDetail(for day: CodexTokenActivityDay) -> some View {
        let segments = tokenUsageBarSegments(for: day)
        let visibleSegments = segments.filter { $0.tokens > 0 }

        return VStack(alignment: .leading, spacing: 7) {
            Text(tokenUsageDaySummaryText(for: day))
                .font(settingsBodyStrongFont)
                .foregroundStyle(.primary.opacity(0.9))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.78)

            if visibleSegments.isEmpty {
                Text(model.text("暂无模型明细", "No model details"))
                    .font(settingsDetailFont)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(visibleSegments) { segment in
                        tokenUsageModelDetailRow(segment, day: day)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
    }

    private func tokenUsageHoverHint() -> some View {
        Text(model.text("悬停在柱形图上查看详情", "Hover over a bar to view details"))
            .font(settingsDetailFont)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
    }

    private func tokenUsageModelDetailRow(
        _ segment: TokenUsageBarSegment,
        day: CodexTokenActivityDay
    ) -> some View {
        let percent = day.totalTokens > 0
            ? Int((Double(segment.tokens) / Double(day.totalTokens) * 100).rounded())
            : 0
        let cost = tokenUsageSegmentCostText(segment, day: day)
        let detailText = [
            cost,
            "\(model.compactTokenCountText(segment.tokens)) token",
            "\(percent)%"
        ]
            .compactMap { $0 }
            .joined(separator: " · ")
        let modeDetailText = tokenUsageModelModeDetailText(segment.model, day: day)

        return HStack(alignment: .top, spacing: 7) {
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(tokenUsageModelColor(
                    segment.model,
                    normalized: 1,
                    prominent: false,
                    isSelected: true
                ))
                .frame(width: 3, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(tokenUsageModelDisplayName(segment.model))
                    .font(settingsDetailStrongFont)
                    .lineLimit(1)

                Text(detailText)
                    .font(settingsDetailFont)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)

                if let modeDetailText {
                    Text(modeDetailText)
                        .font(settingsDetailFont)
                        .foregroundStyle(.secondary.opacity(0.92))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
            }
        }
    }

    private func tokenUsageModelModeDetailText(
        _ modelName: String,
        day: CodexTokenActivityDay
    ) -> String? {
        guard modelName != "__other__" else { return nil }
        let standardTokens = day.modelStandardTokenTotals[modelName] ?? 0
        let priorityTokens = day.modelPriorityTokenTotals[modelName] ?? 0
        guard standardTokens > 0 || priorityTokens > 0 else { return nil }

        let standard = tokenUsageModePiece(
            label: model.text("标准", "Std"),
            tokens: standardTokens,
            cost: day.modelStandardEstimatedCostTotals[modelName]
        )
        let priority = tokenUsageModePiece(
            label: model.text("快速", "Fast"),
            tokens: priorityTokens,
            cost: day.modelPriorityEstimatedCostTotals[modelName]
        )
        return [standard, priority]
            .compactMap { $0 }
            .joined(separator: " / ")
    }

    private func tokenUsageModePiece(
        label: String,
        tokens: Int,
        cost: Double?
    ) -> String? {
        guard tokens > 0 else { return nil }
        var parts: [String] = [label]
        if let cost {
            parts.append(tokenActivityCurrencyText(cost))
        }
        parts.append("\(model.compactTokenCountText(tokens)) token")
        return parts.joined(separator: " ")
    }

    private func hoveredTokenActivityDay(in days: [CodexTokenActivityDay]) -> CodexTokenActivityDay? {
        guard let hoveredTokenActivityDayID else { return nil }
        return days.first { $0.id == hoveredTokenActivityDayID }
    }

    private var tokenActivityChartDays: [CodexTokenActivityDay] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let startDay = calendar.date(byAdding: .day, value: -29, to: today) ?? today
        let totalsByDay = Dictionary(grouping: model.tokenActivityDays) {
            calendar.startOfDay(for: $0.day)
        }.mapValues { days -> CodexTokenActivityDay in
            let totalTokens = days.map(\.totalTokens).reduce(0, +)
            let costs = days.compactMap(\.estimatedCostUSD)
            var modelTotals: [String: Int] = [:]
            var modelCostTotals: [String: Double] = [:]
            var modelStandardTotals: [String: Int] = [:]
            var modelPriorityTotals: [String: Int] = [:]
            var modelStandardCostTotals: [String: Double] = [:]
            var modelPriorityCostTotals: [String: Double] = [:]
            for day in days {
                for (model, tokens) in day.modelTokenTotals where tokens > 0 {
                    modelTotals[model, default: 0] += tokens
                }
                for (model, cost) in day.modelEstimatedCostTotals where cost > 0 {
                    modelCostTotals[model, default: 0] += cost
                }
                for (model, tokens) in day.modelStandardTokenTotals where tokens > 0 {
                    modelStandardTotals[model, default: 0] += tokens
                }
                for (model, tokens) in day.modelPriorityTokenTotals where tokens > 0 {
                    modelPriorityTotals[model, default: 0] += tokens
                }
                for (model, cost) in day.modelStandardEstimatedCostTotals where cost > 0 {
                    modelStandardCostTotals[model, default: 0] += cost
                }
                for (model, cost) in day.modelPriorityEstimatedCostTotals where cost > 0 {
                    modelPriorityCostTotals[model, default: 0] += cost
                }
            }
            return CodexTokenActivityDay(
                day: calendar.startOfDay(for: days.first?.day ?? today),
                totalTokens: totalTokens,
                estimatedCostUSD: costs.isEmpty ? nil : costs.reduce(0, +),
                modelTokenTotals: modelTotals,
                modelEstimatedCostTotals: modelCostTotals,
                modelStandardTokenTotals: modelStandardTotals,
                modelPriorityTokenTotals: modelPriorityTotals,
                modelStandardEstimatedCostTotals: modelStandardCostTotals,
                modelPriorityEstimatedCostTotals: modelPriorityCostTotals
            )
        }

        return (0..<30).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: startDay) else {
                return nil
            }

            return totalsByDay[day] ?? CodexTokenActivityDay(day: day, totalTokens: 0)
        }
    }

    private var emptyTokenActivityChartDays: [CodexTokenActivityDay] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let startDay = calendar.date(byAdding: .day, value: -29, to: today) ?? today

        return (0..<30).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: startDay) else {
                return nil
            }
            return CodexTokenActivityDay(day: day, totalTokens: 0)
        }
    }

    private var tokenActivityActiveDayCount: Int {
        tokenActivityChartDays.filter { $0.totalTokens > 0 }.count
    }

    private var tokenActivityLatestTokens: Int {
        tokenActivityChartDays.last(where: { $0.totalTokens > 0 })?.totalTokens ?? 0
    }

    private var tokenActivityTodayEstimatedCostUSD: Double? {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let costs = tokenActivityChartDays
            .filter { calendar.isDate($0.day, inSameDayAs: today) }
            .compactMap(\.estimatedCostUSD)
        return costs.isEmpty ? nil : costs.reduce(0, +)
    }

    private var tokenActivityLast30EstimatedCostUSD: Double? {
        let costs = tokenActivityChartDays.compactMap(\.estimatedCostUSD)
        return costs.isEmpty ? nil : costs.reduce(0, +)
    }

    private func tokenActivityCurrencyText(_ value: Double?) -> String {
        guard let value else { return "$--" }
        return String(format: "$%.2f", max(0, value))
    }

    private func tokenActivityShortDateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: model.appLanguage.localeIdentifier)
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter.string(from: date)
    }

    private func tokenActivityDateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: model.appLanguage.localeIdentifier)
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private var tokenActivityTodayTokens: Int {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return model.tokenActivityDays
            .filter { calendar.isDate($0.day, inSameDayAs: today) }
            .map(\.totalTokens)
            .reduce(0, +)
    }

    private var tokenActivityLast30DaysTokens: Int {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let startDay = calendar.date(byAdding: .day, value: -29, to: today) ?? today
        return model.tokenActivityDays
            .filter {
                let day = calendar.startOfDay(for: $0.day)
                return day >= startDay && day <= today
            }
            .map(\.totalTokens)
            .reduce(0, +)
    }

    private func quotaUsageTile(_ badgeWindow: FloatingSignalQuotaBadgeWindow, quota: AgentQuotaStatus) -> some View {
        let window = model.quotaWindow(for: badgeWindow, quota: quota)
        let usedText = window.map { "\(Int($0.usedPercent.rounded()))%" } ?? "--"

        return VStack(alignment: .leading, spacing: 3) {
            Text(model.displayName(for: badgeWindow))
                .font(settingsDetailStrongFont)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text(model.text("已用 \(usedText)", "\(usedText) used"))
                .font(settingsBodyStrongFont)
                .lineLimit(1)

            Text(model.quotaResetText(for: window, badgeWindow: badgeWindow))
                .font(settingsDetailFont)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
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
        .filter(isVisibleActivitySession)
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
        .filter(isVisibleActivityEvent)
    }

    private func isVisibleActivitySession(_ session: SessionStatus) -> Bool {
        visibleSignalLightAgentScopes.contains { $0.matches(session: session) }
    }

    private func isVisibleActivityEvent(_ event: RecentSignalEvent) -> Bool {
        visibleSignalLightAgentScopes.contains { $0.matches(event: event) }
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
                    options: [.vertical, .horizontal],
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

            settingsSubsection(model.text("角标", "Badges")) {
                settingRow(model.text("运行数量角标", "Running count badge")) {
                    settingsSwitch(floatingSignalInfoBadgeEnabledBinding)
                        .help(model.text(
                            "显示当前运行中的 Agent 数量，并可点击查看运行中的 Agent。",
                            "Show the number of active agents and click to view active agents."
                        ))
                }

                settingRow(model.text("额度角标", "Quota badge")) {
                    settingsSwitch(floatingSignalQuotaBadgeEnabledBinding)
                        .help(model.text(
                            "显示 Agent 剩余额度百分比，点击可查看 5 小时和一周额度。",
                            "Show remaining agent quota percentage; click to view 5-hour and weekly quotas."
                        ))
                }

                settingRow(model.text("Token 角标", "Token badge")) {
                    settingsSwitch(floatingSignalTokenBadgeEnabledBinding)
                        .help(model.text(
                            "显示今日或近 30 天 Token 使用量，并自动切换 K/M/B 单位。",
                            "Show today or last-30-days token usage, with automatic K/M/B units."
                        ))
                }
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

            debugVisibilitySettings

            Divider()

            cliInstallSettings

            Divider()

            statusBarSettings

            Divider()

            floatingSignalSettings

            Divider()

            manualSignalSettings
        }
    }

    private var cliInstallSettings: some View {
        settingsSection(model.text("命令行工具", "Command Line Tool")) {
            VStack(alignment: .leading, spacing: 8) {
                connectionActionButton(
                    model.text("安装 CLI", "Install CLI"),
                    systemImage: "terminal",
                    width: 92,
                    disabled: model.isCLIInstallRunning,
                    action: { model.installBundledCLI() }
                )

                Text(model.text(
                    "将 agent-signal-light 命令安装到 /opt/homebrew/bin 或 /usr/local/bin。",
                    "Installs the agent-signal-light command into /opt/homebrew/bin or /usr/local/bin."
                ))
                .font(settingsDetailFont)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                if let message = model.cliInstallMessage {
                    Text(message)
                        .font(settingsDetailFont)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var debugVisibilitySettings: some View {
        settingsSection(model.text("调试", "Debug")) {
            settingRow(model.text("显示调试设置", "Show debug settings")) {
                settingsSwitch(debugSettingsVisibleBinding)
                    .help(model.text(
                        "打开后会在顶部菜单中显示调试页面。",
                        "Shows a Debug page in the top settings menu."
                    ))
            }
        }
    }

    private var debugSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.text("调试", "Debug"))
                .font(settingsSectionTitleFont)

            debugLoggingSection

            Divider()

            debugLightSection

            Divider()

            debugProbeLogSection

            Divider()

            debugFetchStrategySection

            Divider()

            debugOpenAICookieSection

            Divider()

            debugCacheSection
        }
    }

    private var debugLoggingSection: some View {
        settingsSection(model.text("日志", "Logs")) {
            VStack(alignment: .leading, spacing: 12) {
                settingRow(model.text("启用文件日志", "Enable file logging")) {
                    settingsSwitch(debugFileLoggingEnabledBinding)
                }

                Text(model.text(
                    "将日志写入 \(compactPath(model.debugLogFileURL.path)) 以进行调试。",
                    "Writes logs to \(compactPath(model.debugLogFileURL.path)) for debugging."
                ))
                .font(settingsDetailFont)
                .foregroundStyle(.secondary)

                settingRow(model.text("详细程度", "Verbosity")) {
                    compactSegmentedControl(
                        options: DebugLogLevel.allCases,
                        selection: debugLogLevelBinding
                    ) { level in
                        level.displayName
                    }
                }

                HStack(spacing: 8) {
                    diagnosticActionButton(model.text("打开日志文件", "Open Log File"), systemImage: "doc.text.magnifyingglass") {
                        model.openDebugLogFile()
                    }

                    diagnosticActionButton(model.text("复制", "Copy"), systemImage: "doc.on.doc") {
                        model.copyDebugLog()
                    }
                }
            }
        }
    }

    private var debugLightSection: some View {
        settingsSection(model.text("灯光调试", "Light Debug")) {
            VStack(alignment: .leading, spacing: 12) {
                settingRow(model.text("启用灯光调试", "Enable light debug")) {
                    settingsSwitch(lightDebugEnabledBinding)
                }

                Text(model.text(
                    "临时触发状态栏和悬浮信号灯，方便检查红、黄、绿灯效。",
                    "Temporarily trigger the status bar and floating signal to inspect red, yellow, and green light effects."
                ))
                .font(settingsDetailFont)
                .foregroundStyle(.secondary)

                HStack(spacing: 16) {
                    debugLightTargetToggle(
                        title: model.text("状态栏", "Status Bar"),
                        isOn: statusBarLightDebugTargetBinding
                    )

                    debugLightTargetToggle(
                        title: model.text("悬浮红绿灯", "Floating Light"),
                        isOn: floatingLightDebugTargetBinding
                    )
                }
                .disabled(!isLightDebugEnabled)
                .opacity(isLightDebugEnabled ? 1 : 0.48)

                debugLightButtonGrid {
                    debugLightTestButton(.activeEffect(.greenBreathing), title: model.text("绿灯呼吸", "Green breathe"), systemImage: "waveform.path")
                    debugLightTestButton(.activeEffect(.greenSteady), title: model.text("绿灯常亮", "Green steady"), systemImage: "circle.fill")
                    debugLightTestButton(.activeEffect(.greenSlowFlash), title: model.text("绿灯慢闪", "Green slow"), systemImage: "slowmo")
                    debugLightTestButton(.activeEffect(.greenFastFlash), title: model.text("绿灯快闪", "Green fast"), systemImage: "bolt.fill")
                    debugLightTestButton(.signal(.permission), title: model.text("红灯慢闪", "Red slow"), systemImage: "circle.dotted")
                    debugLightTestButton(.signal(.blocked), title: model.text("红灯快闪", "Red fast"), systemImage: "circle.dotted")
                    debugLightTestButton(.completedEffect(.greenPulse), title: model.text("绿灯脉冲", "Green pulse"), systemImage: "circle.dotted")
                    debugLightTestButton(.completedEffect(.yellowPulse), title: model.text("黄灯慢闪", "Yellow slow"), systemImage: "circle.dotted")
                    debugLightTestButton(.completedEffect(.yellowSteady), title: model.text("黄灯常亮", "Yellow steady"), systemImage: "circle.fill")
                    debugLightTestButton(.activeEffect(.trafficCycle), title: model.text("红黄绿依次亮灯", "R/Y/G sequence"), systemImage: "circle.grid.3x1.fill")
                    debugLightTestButton(.completedEffect(.allSteady), title: model.text("三灯全亮", "All steady"), systemImage: "circle.grid.3x1.fill")
                    debugLightTestButton(.completedEffect(.allPulse), title: model.text("三灯同步闪", "All flash"), systemImage: "lightspectrum.horizontal")
                }
                .disabled(!canApplyLightDebugTest)
                .opacity(isLightDebugEnabled ? 1 : 0.48)
            }
        }
    }

    private var debugProbeLogSection: some View {
        settingsSection(model.text("探测日志", "Probe Logs")) {
            VStack(alignment: .leading, spacing: 12) {
                compactSegmentedControl(
                    options: DebugProvider.allCases,
                    selection: debugProviderBinding
                ) { provider in
                    provider.rawValue
                }

                HStack(spacing: 8) {
                    diagnosticActionButton(model.text("获取日志", "Fetch Log"), systemImage: "arrow.clockwise") {
                        debugProbeLogText = model.debugProbeLog(provider: selectedDebugProvider.rawValue)
                    }

                    diagnosticActionButton(
                        model.text("复制", "Copy"),
                        systemImage: "doc.on.doc",
                        disabled: debugProbeLogText.isEmpty
                    ) {
                        model.copyDebugText(debugProbeLogText)
                    }

                    diagnosticActionButton(model.text("重新运行检测", "Rerun Detection"), systemImage: "dot.radiowaves.left.and.right") {
                        model.refreshCodexProviderDetails(force: true)
                        model.refreshCodexAccounts()
                        debugProbeLogText = model.debugProbeLog(provider: selectedDebugProvider.rawValue)
                    }
                }

                debugTextBox(debugProbeLogText.isEmpty ? model.text("尚无日志。获取后加载。", "No log yet. Fetch to load.") : debugProbeLogText, minHeight: 150)
            }
        }
    }

    private var debugFetchStrategySection: some View {
        settingsSection(model.text("获取策略调试", "Fetch Strategy Debug")) {
            VStack(alignment: .leading, spacing: 12) {
                settingRow(model.text("提供商", "Provider")) {
                    compactSegmentedControl(
                        options: DebugProvider.allCases,
                        selection: debugFetchProviderBinding
                    ) { provider in
                        provider.rawValue
                    }
                }

                debugTextBox(model.debugFetchStrategyLog(provider: selectedDebugFetchProvider.rawValue), minHeight: 120)
            }
        }
    }

    private var debugOpenAICookieSection: some View {
        settingsSection("OpenAI Cookie") {
            VStack(alignment: .leading, spacing: 12) {
                Text(model.text(
                    "上次 OpenAI Cookie 尝试中的 Cookie 导入和 WebKit 抓取日志。",
                    "Cookie import and WebKit capture logs from the last OpenAI Cookie attempt."
                ))
                .font(settingsDetailFont)
                .foregroundStyle(.secondary)

                diagnosticActionButton(model.text("复制", "Copy"), systemImage: "doc.on.doc") {
                    model.copyDebugText(model.debugOpenAICookieLog())
                }

                debugTextBox(model.debugOpenAICookieLog(), minHeight: 120)
            }
        }
    }

    private var debugCacheSection: some View {
        settingsSection(model.text("缓存", "Caches")) {
            VStack(alignment: .leading, spacing: 12) {
                Text(model.text(
                    "清除缓存的费用扫描结果或浏览器 Cookie 缓存。",
                    "Clear cached cost scan results or browser cookie cache."
                ))
                .font(settingsDetailFont)
                .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    diagnosticActionButton(model.text("清除费用缓存", "Clear Usage Cache"), systemImage: "trash") {
                        model.clearDebugUsageCache()
                    }

                    diagnosticActionButton(model.text("清除 Cookie 缓存", "Clear Cookie Cache"), systemImage: "trash") {
                        model.clearDebugCookieCache()
                    }
                }

                if let message = model.debugCacheMessage {
                    Text(message)
                        .font(settingsDetailFont)
                        .foregroundStyle(.secondary)
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

            }
        }
    }

    private var connectionSettings: some View {
        settingsSection(model.text("连接", "Connections")) {
            VStack(alignment: .leading, spacing: 14) {
                automaticConnectionSettings

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
        expandedSettingsDropdown = nil
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
            expandedSettingsDropdown = isExpanded ? nil : id
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
            expandedSettingsDropdown = nil
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

    private func debugLightButtonGroup<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(settingsDetailStrongFont)
                .foregroundStyle(.secondary)

            content()
        }
        .disabled(!canApplyLightDebugTest)
        .opacity(isLightDebugEnabled ? 1 : 0.48)
    }

    private func debugLightButtonGrid<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.fixed(diagnosticActionButtonWidth), spacing: 8), count: 3),
            alignment: .leading,
            spacing: 8,
            content: content
        )
    }

    private func debugLightTestButton(_ test: LightDebugTest, title: String, systemImage: String) -> some View {
        let isSelected = selectedLightDebugTest == test

        return Button {
            selectedLightDebugTest = test
            applyLightDebugTest(test)
        } label: {
            Text(title)
                .lineLimit(1)
                .allowsTightening(true)
                .minimumScaleFactor(0.72)
            .font(settingsControlFont)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, 10)
            .frame(width: diagnosticActionButtonWidth, height: dropdownControlHeight)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Color.accentColor : (model.isSettingsGlassEnabled ? glassControlTint : solidControlFill))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(isSelected ? Color.accentColor.opacity(0.7) : solidControlStroke, lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func debugLightSystemImage(for effect: ActiveSignalEffect) -> String {
        switch effect {
        case .greenBreathing:
            return "waveform.path"
        case .greenSteady:
            return "circle.fill"
        case .greenSlowFlash:
            return "slowmo"
        case .greenFastFlash:
            return "bolt.fill"
        case .trafficCycle:
            return "circle.grid.3x1.fill"
        }
    }

    private func debugLightSystemImage(for effect: CompletedSignalEffect) -> String {
        switch effect {
        case .greenPulse:
            return "circle.dotted"
        case .greenSteady:
            return "circle.fill"
        case .yellowPulse:
            return "circle.dotted"
        case .yellowSteady:
            return "circle.fill"
        case .allSteady:
            return "circle.grid.3x1.fill"
        case .allPulse:
            return "lightspectrum.horizontal"
        }
    }

    private func debugLightTargetToggle(title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
                .font(settingsBodyStrongFont)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .toggleStyle(.checkbox)
    }

    private func applyLightDebugTest(_ test: LightDebugTest) {
        guard canApplyLightDebugTest else { return }

        switch test {
        case .signal(let signal):
            model.setDebugLight(signal: signal, targets: selectedLightDebugTargets)
        case .activeEffect(let effect):
            var customization = model.signalEffectCustomization
            customization.thinkingEffect = effect
            customization.activeEffect = effect
            model.previewDebugLight(
                signal: .working,
                effectCustomization: customization,
                targets: selectedLightDebugTargets
            )
        case .completedEffect(let effect):
            var customization = model.signalEffectCustomization
            customization.completedEffect = effect
            model.previewDebugLight(
                signal: .done,
                effectCustomization: customization,
                targets: selectedLightDebugTargets
            )
        }
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
        systemImage: String?,
        width: CGFloat? = nil
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

    private func settingsIconActionSurface(systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(settingsIconFont)
            .foregroundStyle(.primary)
            .frame(width: dropdownControlHeight, height: dropdownControlHeight)
            .background(
                glassControlBackground(cornerRadius: 7)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(solidControlStroke, lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func settingsTextMenuSurface(_ title: String, width: CGFloat? = nil) -> some View {
        HStack(spacing: 5) {
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

    private func usageUnavailableRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon)
                .font(settingsTinyIconFont)
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(settingsBodyStrongFont)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                Text(subtitle)
                    .font(settingsDetailFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func debugTextBox(_ text: String, minHeight: CGFloat) -> some View {
        ScrollView {
            Text(text)
                .font(.system(size: 11.5, weight: .regular, design: .monospaced))
                .foregroundStyle(.primary.opacity(0.9))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(minHeight: minHeight, maxHeight: minHeight + 80)
        .background(Color.black.opacity(colorScheme == .dark ? 0.24 : 0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
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

    private var floatingSignalInfoBadgeEnabledBinding: Binding<Bool> {
        Binding(
            get: { model.isFloatingSignalInfoBadgeEnabled },
            set: { model.setFloatingSignalInfoBadgeEnabled($0) }
        )
    }

    private var floatingSignalQuotaBadgeEnabledBinding: Binding<Bool> {
        Binding(
            get: { model.isFloatingSignalQuotaBadgeEnabled },
            set: { model.setFloatingSignalQuotaBadgeEnabled($0) }
        )
    }

    private var floatingSignalTokenBadgeEnabledBinding: Binding<Bool> {
        Binding(
            get: { model.isFloatingSignalTokenBadgeEnabled },
            set: { model.setFloatingSignalTokenBadgeEnabled($0) }
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

    private var debugSettingsVisibleBinding: Binding<Bool> {
        Binding(
            get: { model.isDebugSettingsVisible },
            set: { model.setDebugSettingsVisible($0) }
        )
    }

    private var debugFileLoggingEnabledBinding: Binding<Bool> {
        Binding(
            get: { model.isDebugFileLoggingEnabled },
            set: { model.setDebugFileLoggingEnabled($0) }
        )
    }

    private var debugLogLevelBinding: Binding<DebugLogLevel> {
        Binding(
            get: { model.debugLogLevel },
            set: { model.setDebugLogLevel($0) }
        )
    }

    private var debugProviderBinding: Binding<DebugProvider> {
        Binding(
            get: { selectedDebugProvider },
            set: {
                selectedDebugProvider = $0
                debugProbeLogText = ""
            }
        )
    }

    private var debugFetchProviderBinding: Binding<DebugProvider> {
        Binding(
            get: { selectedDebugFetchProvider },
            set: { selectedDebugFetchProvider = $0 }
        )
    }

    private var isLightDebugEnabled: Bool {
        model.isLightDebugModeEnabled
    }

    private var lightDebugEnabledBinding: Binding<Bool> {
        Binding(
            get: { model.isLightDebugModeEnabled },
            set: { enabled in
                if enabled {
                    if let selectedLightDebugTest {
                        applyLightDebugTest(selectedLightDebugTest)
                    } else {
                        model.setLightDebugModeEnabled(true, targets: selectedLightDebugTargets)
                    }
                } else {
                    selectedLightDebugTest = nil
                    model.setLightDebugModeEnabled(false, targets: selectedLightDebugTargets)
                }
            }
        )
    }

    private var statusBarLightDebugTargetBinding: Binding<Bool> {
        Binding(
            get: { isStatusBarLightDebugTargetEnabled },
            set: { enabled in
                if !enabled && !isFloatingLightDebugTargetEnabled {
                    isStatusBarLightDebugTargetEnabled = true
                    return
                }
                isStatusBarLightDebugTargetEnabled = enabled
                reapplySelectedLightDebugTest()
            }
        )
    }

    private var floatingLightDebugTargetBinding: Binding<Bool> {
        Binding(
            get: { isFloatingLightDebugTargetEnabled },
            set: { enabled in
                if !enabled && !isStatusBarLightDebugTargetEnabled {
                    isFloatingLightDebugTargetEnabled = true
                    return
                }
                isFloatingLightDebugTargetEnabled = enabled
                reapplySelectedLightDebugTest()
            }
        )
    }

    private var selectedLightDebugTargets: Set<StatusLightOverrideTarget> {
        var targets: Set<StatusLightOverrideTarget> = []
        if isStatusBarLightDebugTargetEnabled {
            targets.insert(.statusBar)
        }
        if isFloatingLightDebugTargetEnabled {
            targets.insert(.floatingSignal)
        }
        return targets
    }

    private var canApplyLightDebugTest: Bool {
        isLightDebugEnabled && !selectedLightDebugTargets.isEmpty
    }

    private func reapplySelectedLightDebugTest() {
        guard let selectedLightDebugTest else {
            if model.isLightDebugModeEnabled {
                model.setLightDebugModeEnabled(true, targets: selectedLightDebugTargets)
            } else {
                model.clearDebugLight()
            }
            return
        }
        guard canApplyLightDebugTest else {
            model.clearDebugLight()
            return
        }
        applyLightDebugTest(selectedLightDebugTest)
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

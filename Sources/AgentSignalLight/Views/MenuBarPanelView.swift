import AgentSignalLightCore
import AgentSignalLightUI
import AppKit
import Combine
import SwiftUI

struct MenuBarPanelView: View {
    static let panelWidth: CGFloat = 320
    static let panelHeight: CGFloat = 372

    let model: MenuBarStatusModel
    var onOpenSettings: (() -> Void)?
    @StateObject private var viewState: MenuBarPanelViewState
    @Environment(\.colorScheme) private var colorScheme
    @State private var isOpenAgentDropdownExpanded = false

    init(model: MenuBarStatusModel, onOpenSettings: (() -> Void)? = nil) {
        self.model = model
        self.onOpenSettings = onOpenSettings
        _viewState = StateObject(wrappedValue: MenuBarPanelViewState(model: model))
    }

    var body: some View {
        ZStack {
            PopoverBackdropView()
                .ignoresSafeArea()
                .zIndex(0)

            if isOpenAgentDropdownExpanded {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        closeOpenAgentDropdown()
                    }
                    .zIndex(5)
            }

            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        header
                        statusSummary

                        if let lastError = viewState.lastError {
                            Text(lastError)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 12)
                    .frame(width: Self.panelWidth, alignment: .leading)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    closeOpenAgentDropdown()
                }
                .scrollIndicators(.hidden)
                .frame(maxHeight: .infinity)
                .zIndex(0)

                Divider()
                    .padding(.horizontal, 16)
                    .zIndex(0)

                mainActions
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 10)
                    .frame(width: Self.panelWidth, alignment: .leading)
                    .zIndex(isOpenAgentDropdownExpanded ? 10 : 1)
            }
        }
        .frame(width: Self.panelWidth, height: Self.panelHeight)
        .preferredColorScheme(viewState.appTheme.colorScheme)
    }

    private var header: some View {
        HStack(spacing: 12) {
            PanelTrafficSignalView(model: model)

            VStack(alignment: .leading, spacing: 2) {
                Text("Agent Signal Bar")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(model.displayName(for: viewState.snapshot.aggregate))
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                    .allowsTightening(true)
                    .minimumScaleFactor(0.80)
                Text(model.humanAction(for: viewState.snapshot.aggregate))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .allowsTightening(true)
                    .minimumScaleFactor(0.80)
            }

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

    private var statusSummary: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(model.summary(for: viewState.snapshot.aggregate))
                .font(.subheadline)
                .lineLimit(2)
                .allowsTightening(true)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                if let updatedAt = viewState.snapshot.updatedAt {
                    Text("\(model.text("实时", "Live")) \(updatedAt.formatted(date: .omitted, time: .shortened))")
                } else {
                    Text(model.text("等待状态", "Waiting for status"))
                }

                if viewState.isMonitoringPaused {
                    Text(model.text("已暂停", "Paused"))
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if visibleAgentSessions.isEmpty {
                Text(model.text("暂无运行中的 Agent", "No active agent sessions"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(visibleAgentSessions) { session in
                        SessionRowView(model: model, session: session)
                    }
                }
            }

            if !menuRecentEvents.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.text("最近", "Recent"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ForEach(menuRecentEvents) { event in
                        EventRowView(model: model, event: event)
                    }
                }
            }
        }
    }

    private var visibleAgentSessions: [SessionStatus] {
        var seenAgents: Set<String> = []
        var sessions: [SessionStatus] = []

        for session in viewState.snapshot.sessions {
            guard isVisibleAgentSession(session) else { continue }
            let agentKey = normalizedAgentKey(session.agent, fallback: session.sessionID)
            guard !seenAgents.contains(agentKey) else { continue }
            seenAgents.insert(agentKey)
            sessions.append(session)
            if sessions.count == 3 {
                break
            }
        }

        return sessions
    }

    private var visibleOpenAgentSessions: [SessionStatus] {
        visibleAgentSessions.filter { session in
            switch normalizedAgentKey(session.agent, fallback: session.sessionID) {
            case "codex", "claude":
                return true
            default:
                return false
            }
        }
    }

    private func isLiveAgentSession(_ session: SessionStatus) -> Bool {
        Date().timeIntervalSince(session.updatedAt) <= liveAgentSessionWindow
    }

    private func isVisibleAgentSession(_ session: SessionStatus) -> Bool {
        if isDesktopPresenceSession(session) {
            return true
        }

        guard session.signal.displayState == .active else { return false }
        return isLiveAgentSession(session)
    }

    private func isDesktopPresenceSession(_ session: SessionStatus) -> Bool {
        session.sessionID.hasPrefix("desktop-app:") || session.lastEvent == "DesktopAppRunning"
    }

    private var liveAgentSessionWindow: TimeInterval {
        5 * 60
    }

    private var menuRecentEvents: [RecentSignalEvent] {
        let currentSessionKeys = Set(
            visibleAgentSessions.map { session in
                "\(session.sessionID)|\(session.signal.rawValue)|\(session.lastEvent ?? "")"
            }
        )

        return Array(viewState.snapshot.recentEvents.lazy.filter { event in
            let eventKey = "\(event.sessionID)|\(event.signal.rawValue)|\(event.event ?? "")"
            return !currentSessionKeys.contains(eventKey)
        }.prefix(menuRecentEventLimit))
    }

    private var menuRecentEventLimit: Int {
        visibleAgentSessions.count == 1 ? 2 : 1
    }

    private func normalizedAgentKey(_ agent: String?, fallback: String) -> String {
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

    private var mainActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                openAgentAction

                Button {
                    closeOpenAgentDropdown()
                    model.clearWarnings()
                } label: {
                    actionSurface(model.text("清除提醒", "Clear Warning"), systemImage: "xmark.circle")
                }
                .buttonStyle(.plain)
                .frame(width: actionButtonWidth, height: actionButtonHeight)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .zIndex(isOpenAgentDropdownExpanded ? 1000 : 0)

            HStack(alignment: .top, spacing: 8) {
                Button {
                    closeOpenAgentDropdown()
                    model.toggleMonitoring()
                } label: {
                    actionSurface(
                        viewState.isMonitoringPaused ? model.text("继续监控", "Resume") : model.text("暂停监控", "Pause"),
                        systemImage: viewState.isMonitoringPaused ? "play.fill" : "pause.fill"
                    )
                }
                .buttonStyle(.plain)
                .frame(width: actionButtonWidth, height: actionButtonHeight)

                Button {
                    closeOpenAgentDropdown()
                    onOpenSettings?()
                } label: {
                    actionSurface(model.text("设置", "Settings"), systemImage: "gearshape")
                }
                .buttonStyle(.plain)
                .frame(width: actionButtonWidth, height: actionButtonHeight)
            }
            .frame(maxWidth: .infinity, alignment: .center)

            HStack {
                Spacer()
                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Label(model.text("退出", "Quit"), systemImage: "power")
                }
            }
            .buttonStyle(.borderless)
        }
    }

    private var openAgentAction: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.12)) {
                isOpenAgentDropdownExpanded.toggle()
            }
        } label: {
            actionSurface(
                model.text("打开 Agent", "Open Agent"),
                systemImage: "app",
                showsChevron: true,
                isExpanded: isOpenAgentDropdownExpanded
            )
        }
        .buttonStyle(.plain)
        .frame(width: actionButtonWidth, height: actionButtonHeight, alignment: .leading)
        .overlay(alignment: .bottomLeading) {
            if isOpenAgentDropdownExpanded {
                openAgentDropdown
                    .offset(y: -(actionButtonHeight + 4))
                    .shadow(color: .black.opacity(0.16), radius: 10, y: 5)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .zIndex(1)
            }
        }
        .zIndex(isOpenAgentDropdownExpanded ? 1000 : 0)
    }

    private var openAgentDropdown: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(model.text("正在运行", "Running Now"))
                .font(.system(size: usesCompactLatinLayout ? 10.5 : 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .allowsTightening(true)
                .padding(.horizontal, 9)
                .frame(width: openAgentDropdownWidth, height: 22, alignment: .leading)

            if visibleOpenAgentSessions.isEmpty {
                Text(model.text("暂无运行中的 Agent", "No running agents"))
                    .font(panelActionFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .allowsTightening(true)
                    .minimumScaleFactor(0.72)
                    .padding(.horizontal, 9)
                    .frame(width: openAgentDropdownWidth, height: openAgentEmptyRowHeight, alignment: .leading)
            } else {
                ForEach(visibleOpenAgentSessions) { session in
                    runningAgentOption(session)
                }
            }
        }
        .padding(.vertical, 2)
        .frame(width: openAgentDropdownWidth)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(solidDropdownFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(solidControlStroke, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var actionButtonWidth: CGFloat {
        usesCompactLatinLayout ? 136 : 132
    }

    private var openAgentDropdownWidth: CGFloat { actionButtonWidth }

    private var actionButtonHeight: CGFloat {
        28
    }

    private var openAgentRunningRowHeight: CGFloat {
        28
    }

    private var openAgentEmptyRowHeight: CGFloat {
        28
    }

    private var panelActionFont: Font {
        .system(size: usesCompactLatinLayout ? 12 : 13, weight: .semibold)
    }

    private var usesCompactLatinLayout: Bool {
        viewState.appLanguage.usesCompactLatinLayout
    }

    private func actionSurface(
        _ title: String,
        systemImage: String,
        showsChevron: Bool = false,
        isExpanded: Bool = false
    ) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 16)

            Text(title)
                .lineLimit(1)
                .allowsTightening(true)
                .minimumScaleFactor(0.72)

            if showsChevron {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 10)
            }
        }
        .font(panelActionFont)
        .foregroundStyle(.primary)
        .frame(width: actionButtonWidth, height: actionButtonHeight, alignment: .center)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(solidControlFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(solidControlStroke, lineWidth: 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func openAgentOption(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.12)) {
                isOpenAgentDropdownExpanded = false
            }
            action()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 16)
                Text(title)
                    .lineLimit(1)
                    .allowsTightening(true)
                    .minimumScaleFactor(0.72)
                Spacer(minLength: 4)
            }
            .font(panelActionFont)
            .foregroundStyle(.primary)
            .padding(.horizontal, 9)
            .frame(width: openAgentDropdownWidth, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func runningAgentOption(_ session: SessionStatus) -> some View {
        Button {
            closeOpenAgentDropdown()
            openAgent(for: session)
        } label: {
            HStack(alignment: .center, spacing: 7) {
                Circle()
                    .fill(signalColor(session.signal))
                    .frame(width: 6, height: 6)

                Text(shortAgentName(for: session))
                    .font(panelActionFont)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .allowsTightening(true)
                    .minimumScaleFactor(0.78)

                Spacer(minLength: 4)
            }
            .padding(.horizontal, 9)
            .frame(width: openAgentDropdownWidth, height: openAgentRunningRowHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canOpenAgent(for: session))
    }

    private func shortAgentName(for session: SessionStatus) -> String {
        switch normalizedAgentKey(session.agent, fallback: session.sessionID) {
        case "codex":
            return "Codex"
        case "claude":
            return "Claude"
        default:
            return model.friendlyAgentName(session.agent)
        }
    }

    private func openAgent(for session: SessionStatus) {
        switch normalizedAgentKey(session.agent, fallback: session.sessionID) {
        case "codex":
            model.openCodex()
        case "claude":
            model.openClaude()
        default:
            break
        }
    }

    private func canOpenAgent(for session: SessionStatus) -> Bool {
        switch normalizedAgentKey(session.agent, fallback: session.sessionID) {
        case "codex", "claude":
            return true
        default:
            return false
        }
    }

    private func closeOpenAgentDropdown() {
        guard isOpenAgentDropdownExpanded else { return }
        withAnimation(.easeInOut(duration: 0.12)) {
            isOpenAgentDropdownExpanded = false
        }
    }

    private var solidControlFill: Color {
        colorScheme == .dark
            ? Color(nsColor: NSColor(calibratedWhite: 0.24, alpha: 1))
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

}

@MainActor
private final class MenuBarPanelViewState: ObservableObject {
    @Published var snapshot: SignalSnapshot
    @Published var appTheme: AppTheme
    @Published var isMonitoringPaused: Bool
    @Published var lastError: String?
    @Published var appLanguage: AppLanguage

    private var cancellables = Set<AnyCancellable>()

    init(model: MenuBarStatusModel) {
        snapshot = model.displaySnapshot
        appTheme = model.appTheme
        isMonitoringPaused = model.isMonitoringPaused
        lastError = model.lastError
        appLanguage = model.appLanguage

        model.$snapshot
            .sink { [weak self, weak model] _ in
                guard let model else { return }
                self?.snapshot = model.displaySnapshot
            }
            .store(in: &cancellables)

        model.$desktopAppSessions
            .sink { [weak self, weak model] _ in
                guard let model else { return }
                self?.snapshot = model.displaySnapshot
            }
            .store(in: &cancellables)

        model.$signalLightAgentScope
            .sink { [weak self, weak model] _ in
                guard let model else { return }
                self?.snapshot = model.displaySnapshot
            }
            .store(in: &cancellables)

        model.$appTheme
            .removeDuplicates()
            .sink { [weak self] appTheme in
                self?.appTheme = appTheme
            }
            .store(in: &cancellables)

        model.$isMonitoringPaused
            .removeDuplicates()
            .sink { [weak self] isMonitoringPaused in
                self?.isMonitoringPaused = isMonitoringPaused
            }
            .store(in: &cancellables)

        model.$lastError
            .removeDuplicates()
            .sink { [weak self] lastError in
                self?.lastError = lastError
            }
            .store(in: &cancellables)

        model.$appLanguage
            .removeDuplicates()
            .sink { [weak self] appLanguage in
                self?.appLanguage = appLanguage
            }
            .store(in: &cancellables)
    }
}

private struct PanelTrafficSignalView: View {
    @ObservedObject var model: MenuBarStatusModel
    @ObservedObject private var animationClock: SignalAnimationClock

    init(model: MenuBarStatusModel) {
        self.model = model
        _animationClock = ObservedObject(wrappedValue: model.animationClock)
    }

    var body: some View {
        TrafficSignalView(
            snapshot: model.displaySnapshot,
            tick: animationClock.tick,
            size: .panel,
            layout: .horizontal,
            style: .trafficLight,
            macOSBreathingStrength: model.macOSBreathingStrength,
            macOSHorizontalUsesTrafficLightSize: model.macOSHorizontalUsesTrafficLightSize,
            trafficLightVerticalUsesMacOSSize: model.trafficLightVerticalUsesMacOSSize,
            allLightsOn: model.isStatusBarAllLightsOn,
            effectCustomization: model.signalEffectCustomization
        )
    }
}

private struct PopoverBackdropView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        configure(view)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        configure(view)
    }

    private func configure(_ view: NSVisualEffectView) {
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = true
    }
}

private struct SessionRowView: View {
    let model: MenuBarStatusModel
    let session: SessionStatus

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(signalColor(session.signal))
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 2) {
                Text(displayTitle)
                    .font(.caption)
                    .lineLimit(1)
                Text("\(model.displayName(for: session.signal)) · \(session.updatedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    private var displayTitle: String {
        let agent = model.friendlyAgentName(session.agent)
        if let event = session.lastEvent, !event.isEmpty {
            return "\(agent) · \(model.friendlyEventName(event))"
        }
        return "\(agent) · \(compactIdentifier(session.sessionID))"
    }

}

private struct EventRowView: View {
    let model: MenuBarStatusModel
    let event: RecentSignalEvent

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(signalColor(event.signal))
                .frame(width: 6, height: 6)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2)
                    .lineLimit(1)
                Text("\(model.displayName(for: event.signal)) · \(event.updatedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .frame(minHeight: 30, alignment: .leading)
    }

    private var title: String {
        let agent = model.friendlyAgentName(event.agent)
        if let eventName = event.event, !eventName.isEmpty {
            return "\(agent) · \(model.friendlyEventName(eventName))"
        }
        return "\(agent) · \(model.displayName(for: event.signal))"
    }
}

private func compactIdentifier(_ value: String) -> String {
    guard value.count > 10 else { return value }
    return String(value.prefix(8))
}

private func signalColor(_ signal: AgentSignal) -> Color {
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

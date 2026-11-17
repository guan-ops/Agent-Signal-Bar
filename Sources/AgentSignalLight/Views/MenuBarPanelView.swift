import AgentSignalLightCore
import AgentSignalLightUI
import AppKit
import Combine
import SwiftUI

struct MenuBarPanelView: View {
    static let panelWidth: CGFloat = 360
    static let panelHeight: CGFloat = 560
    private static let contentInset: CGFloat = 16
    private static let actionColumnSpacing: CGFloat = 8

    let model: MenuBarStatusModel
    var onOpenSettings: (() -> Void)?
    let claudeSupport: ClaudeSupportModel
    let usageNavigation: UsageMenuNavigation
    var onOpenUsage: (UsageMenuNavigation.Provider) -> Void
    @StateObject private var viewState: MenuBarPanelViewState
    @Environment(\.colorScheme) private var colorScheme

    init(model: MenuBarStatusModel, claudeSupport: ClaudeSupportModel? = nil,
         usageNavigation: UsageMenuNavigation? = nil,
         onOpenUsage: @escaping (UsageMenuNavigation.Provider) -> Void = { _ in },
         onOpenSettings: (() -> Void)? = nil) {
        self.claudeSupport = claudeSupport ?? model.claudeSupport
        self.usageNavigation = usageNavigation ?? UsageMenuNavigation()
        self.onOpenUsage = onOpenUsage
        self.model = model
        self.onOpenSettings = onOpenSettings
        _viewState = StateObject(wrappedValue: MenuBarPanelViewState(model: model))
    }

    var body: some View {
        ZStack {
            PopoverBackdropView()
                .ignoresSafeArea()
                .zIndex(0)

            // UI 2.0: state first (what is happening, who needs you), then usage, then
            // menu-style actions that match the native status menu.
            VStack(alignment: .leading, spacing: ASB.Space.m) {
                header

                if !visibleAgentSessions.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(visibleAgentSessions.prefix(3)) { session in
                            SessionRowView(model: model, session: session)
                        }
                    }
                }

                Divider()

                MenuUsageSummaryView(model: model, claude: claudeSupport,
                                     navigation: usageNavigation, onOpenSettings: onOpenUsage)

                if let lastError = viewState.lastError {
                    Text(lastError)
                        .font(ASB.Typeface.caption)
                        .foregroundStyle(ASBTone.critical.foreground)
                        .lineLimit(2)
                }

                Divider()

                VStack(spacing: 0) {
                    ASBMenuRow(title: model.text("设置…", "Settings…"), shortcut: "⌘,") {
                        onOpenSettings?()
                    }
                    .keyboardShortcut(",", modifiers: .command)
                    ASBMenuRow(title: model.text("退出 Agent Signal Bar", "Quit Agent Signal Bar"), shortcut: "⌘Q") {
                        NSApplication.shared.terminate(nil)
                    }
                    .keyboardShortcut("q", modifiers: .command)
                }
                .padding(.horizontal, -ASB.Space.s)
            }
            .padding(Self.contentInset)
            .frame(width: Self.panelWidth, alignment: .leading)
            .zIndex(1)
        }
        .frame(width: Self.panelWidth)
        .fixedSize(horizontal: false, vertical: true)
        .preferredColorScheme(viewState.appTheme.colorScheme)
    }

    private var header: some View {
        HStack(spacing: 10) {
            PanelTrafficSignalView(model: model)
                .fixedSize()
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.displayName(for: viewState.lightSnapshot.aggregate))
                    .font(ASB.Typeface.bodyStrong)
                    .lineLimit(1)
                Text(headerSubtitle)
                    .font(ASB.Typeface.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: ASB.Space.s)
            Button {
                model.toggleMonitoring()
            } label: {
                Image(systemName: viewState.isMonitoringPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: ASB.Radius.control, style: .continuous))
            }
            .buttonStyle(.plain)
            .help(viewState.isMonitoringPaused ? model.text("继续监控", "Resume") : model.text("暂停监控", "Pause"))
            .accessibilityLabel(viewState.isMonitoringPaused ? model.text("继续监控", "Resume") : model.text("暂停监控", "Pause"))
        }
        .accessibilityElement(children: .contain)
    }

    private var headerSubtitle: String {
        if viewState.isMonitoringPaused { return model.text("监控已暂停", "Monitoring paused") }
        return model.signalLightFollowingText ?? "Agent Signal Bar"
    }

    private var visibleAgentSessions: [SessionStatus] {
        ActivityPresentation.visibleSessions(
            from: viewState.activitySnapshot,
            limit: ActivityPresentation.currentSessionLimit
        )
    }

    private var usesCompactLatinLayout: Bool {
        viewState.appLanguage.usesCompactLatinLayout
    }
}

@MainActor
private final class MenuBarPanelViewState: ObservableObject {
    @Published var snapshot: SignalSnapshot
    @Published var lightSnapshot: SignalSnapshot
    @Published var activitySnapshot: SignalSnapshot
    @Published var appTheme: AppTheme
    @Published var isMonitoringPaused: Bool
    @Published var lastError: String?
    @Published var appLanguage: AppLanguage
    @Published var latestCodexResetCredits: CodexRateLimitResetCreditsSnapshot?

    private var cancellables = Set<AnyCancellable>()

    init(model: MenuBarStatusModel) {
        snapshot = model.displaySnapshot
        lightSnapshot = model.statusBarLightSnapshot
        activitySnapshot = model.activitySnapshot
        appTheme = model.appTheme
        isMonitoringPaused = model.isMonitoringPaused
        lastError = model.lastError
        appLanguage = model.appLanguage
        latestCodexResetCredits = model.latestCodexResetCredits

        model.$snapshot
            .sink { [weak self, weak model] _ in
                guard let model else { return }
                self?.refreshSnapshots(from: model)
            }
            .store(in: &cancellables)

        model.$desktopAppSessions
            .sink { [weak self, weak model] _ in
                guard let model else { return }
                self?.refreshSnapshots(from: model)
            }
            .store(in: &cancellables)

        Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self, weak model] _ in
                guard let model else { return }
                self?.refreshSnapshots(from: model)
            }
            .store(in: &cancellables)

        model.$signalLightAgentScopes
            .sink { [weak self, weak model] _ in
                guard let model else { return }
                self?.refreshSnapshots(from: model)
            }
            .store(in: &cancellables)

        model.$signalLightAgentSelectionMode
            .sink { [weak self, weak model] _ in
                guard let model else { return }
                self?.refreshSnapshots(from: model)
            }
            .store(in: &cancellables)

        model.$statusLightOverride
            .sink { [weak self, weak model] _ in
                guard let model else { return }
                self?.refreshSnapshots(from: model)
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
            .sink { [weak self, weak model] isMonitoringPaused in
                self?.isMonitoringPaused = isMonitoringPaused
                guard let model else { return }
                self?.refreshSnapshots(from: model)
            }
            .store(in: &cancellables)

        model.$lastError
            .removeDuplicates()
            .sink { [weak self] lastError in
                self?.lastError = lastError
            }
            .store(in: &cancellables)

        model.$latestCodexResetCredits
            .removeDuplicates()
            .sink { [weak self] resetCredits in
                self?.latestCodexResetCredits = resetCredits
            }
            .store(in: &cancellables)

        model.$appLanguage
            .removeDuplicates()
            .sink { [weak self] appLanguage in
                self?.appLanguage = appLanguage
            }
            .store(in: &cancellables)
    }

    private func refreshSnapshots(from model: MenuBarStatusModel) {
        snapshot = model.displaySnapshot
        lightSnapshot = model.statusBarLightSnapshot
        activitySnapshot = model.activitySnapshot
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
            snapshot: model.statusBarLightSnapshot,
            tick: model.statusBarLightTick,
            size: .panel,
            layout: .horizontal,
            style: model.statusBarStyle,
            macOSBreathingStrength: model.macOSBreathingStrength,
            macOSHorizontalUsesTrafficLightSize: model.macOSHorizontalUsesTrafficLightSize,
            trafficLightVerticalUsesMacOSSize: model.trafficLightVerticalUsesMacOSSize,
            allLightsOn: model.statusBarLightAllLightsOn,
            usesSystemGrayLights: model.statusBarLightUsesSystemGrayLights,
            effectCustomization: model.statusBarLightEffectCustomization
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
        view.material = .menu
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = false
    }
}

private struct SessionRowView: View {
    let model: MenuBarStatusModel
    let session: SessionStatus

    var body: some View {
        let tone = ASBTone.forDisplayState(session.signal.displayState)
        let needsYou = tone == .critical || tone == .caution
        HStack(spacing: ASB.Space.s) {
            Circle()
                .fill(tone.lamp)
                .frame(width: 8, height: 8)
            (Text(model.activitySessionTitle(for: session)).fontWeight(.semibold)
                + Text(" · " + model.activitySessionStatusSubtitle(for: session)))
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: ASB.Space.xs)
            Text(session.updatedAt.formatted(date: .omitted, time: .shortened))
                .font(ASB.Typeface.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, ASB.Space.s)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(needsYou ? tone.lamp.opacity(0.12) : Color.clear)
        )
        .accessibilityElement(children: .combine)
    }
}

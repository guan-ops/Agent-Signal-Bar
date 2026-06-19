import AgentSignalLightCore
import AgentSignalLightUI
import AppKit
import AVFoundation
import Combine
import SwiftUI

private enum FloatingSignalPanelLayout {
    static func outerSize(contentSize: CGSize, scale: CGFloat) -> NSSize {
        return NSSize(
            width: leadingOutset(for: scale) + contentSize.width + trailingOutset(for: scale),
            height: contentSize.height + topOutset(for: scale) + bottomOutset(for: scale)
        )
    }

    static func contentOrigin(scale: CGFloat) -> CGPoint {
        CGPoint(x: leadingOutset(for: scale), y: topOutset(for: scale))
    }

    static func badgeSize(for _: CGFloat) -> CGFloat {
        24
    }

    static func resizeHandleSize(for _: CGFloat) -> CGFloat {
        20
    }

    static func controlGap(for _: CGFloat) -> CGFloat {
        2
    }

    static func infoBadgeOverlap(for _: CGFloat) -> CGFloat {
        4
    }

    static func resizeHandleHotspotInset(for _: CGFloat) -> CGFloat {
        20
    }

    private static func topOutset(for scale: CGFloat) -> CGFloat {
        badgeSize(for: scale) + controlGap(for: scale)
    }

    private static func leadingOutset(for scale: CGFloat) -> CGFloat {
        badgeSize(for: scale) + controlGap(for: scale)
    }

    private static func trailingOutset(for scale: CGFloat) -> CGFloat {
        max(badgeSize(for: scale), resizeHandleSize(for: scale)) + controlGap(for: scale)
    }

    private static func bottomOutset(for scale: CGFloat) -> CGFloat {
        resizeHandleSize(for: scale) + controlGap(for: scale)
    }
}

@MainActor
final class FloatingSignalWindowController: NSObject, NSWindowDelegate {
    private let model: MenuBarStatusModel
    private let openSettings: () -> Void
    private var panel: NSPanel?
    private var hostingController: NSHostingController<FloatingSignalPanelView>?
    private var cancellables = Set<AnyCancellable>()
    private let soundPlayer = FloatingSignalSoundPlayer()
    private var lastSoundSignature: String?
    private var lastAlertSoundAt = Date.distantPast
    private var didPrimeSoundState = false
    private var isApplyingFrame = false
    private var nextScaleResizeAnchor: ResizeAnchor?
    private var wasActiveGreenLitForSound = false

    init(model: MenuBarStatusModel, openSettings: @escaping () -> Void) {
        self.model = model
        self.openSettings = openSettings
        super.init()
        bind()
    }

    func start() {
        updateVisibility()
        evaluateAlertSound()
    }

    func applyAppearance() {
        let appearance = model.appTheme.nsAppearance
        panel?.appearance = appearance
        hostingController?.view.appearance = appearance
    }

    private func bind() {
        model.$isFloatingSignalEnabled.sink { [weak self] _ in
            Task { @MainActor in self?.updateVisibility() }
        }
        .store(in: &cancellables)

        model.$floatingSignalVisualScale.sink { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let anchor = self.nextScaleResizeAnchor ?? .center
                self.nextScaleResizeAnchor = nil
                self.resizePanelForCurrentScale(anchor: anchor)
            }
        }
        .store(in: &cancellables)

        model.$floatingSignalLayout.sink { [weak self] _ in
            Task { @MainActor in self?.resizePanelForCurrentScale(keepingCenter: true) }
        }
        .store(in: &cancellables)

        model.$isFloatingSignalInfoBadgeEnabled.sink { [weak self] _ in
            Task { @MainActor in self?.resizePanelForCurrentScale(keepingCenter: true) }
        }
        .store(in: &cancellables)

        model.$isFloatingSignalQuotaBadgeEnabled.sink { [weak self] _ in
            Task { @MainActor in self?.resizePanelForCurrentScale(keepingCenter: true) }
        }
        .store(in: &cancellables)

        model.$isFloatingSignalTokenBadgeEnabled.sink { [weak self] _ in
            Task { @MainActor in self?.resizePanelForCurrentScale(keepingCenter: true) }
        }
        .store(in: &cancellables)

        model.$floatingSignalInfoBadgeCorner.sink { [weak self] _ in
            Task { @MainActor in self?.resizePanelForCurrentScale(keepingCenter: true) }
        }
        .store(in: &cancellables)

        model.$floatingSignalQuotaBadgeCorner.sink { [weak self] _ in
            Task { @MainActor in self?.resizePanelForCurrentScale(keepingCenter: true) }
        }
        .store(in: &cancellables)

        model.$floatingSignalTokenBadgeCorner.sink { [weak self] _ in
            Task { @MainActor in self?.resizePanelForCurrentScale(keepingCenter: true) }
        }
        .store(in: &cancellables)

        model.$floatingSignalQuotaBadgeWindow.sink { [weak self] _ in
            Task { @MainActor in self?.resizePanelForCurrentScale(keepingCenter: true) }
        }
        .store(in: &cancellables)

        model.$latestAgentQuota.sink { [weak self] _ in
            Task { @MainActor in self?.resizePanelForCurrentScale(keepingCenter: true) }
        }
        .store(in: &cancellables)

        model.$latestAgentTokenUsage.sink { [weak self] _ in
            Task { @MainActor in self?.resizePanelForCurrentScale(keepingCenter: true) }
        }
        .store(in: &cancellables)

        model.$trafficLightVerticalUsesMacOSSize.sink { [weak self] _ in
            Task { @MainActor in self?.resizePanelForCurrentScale(keepingCenter: true) }
        }
        .store(in: &cancellables)

        model.$appTheme.sink { [weak self] _ in
            Task { @MainActor in self?.applyAppearance() }
        }
        .store(in: &cancellables)

        model.$floatingSignalSoundTestTick.dropFirst().sink { [weak self] _ in
            Task { @MainActor in self?.previewAlertSound(cue: .completion) }
        }
        .store(in: &cancellables)

        model.$floatingSignalWaitingSoundTestTick.dropFirst().sink { [weak self] _ in
            Task { @MainActor in self?.previewAlertSound(cue: .waiting) }
        }
        .store(in: &cancellables)

        model.$floatingSignalAlertSoundTestTick.dropFirst().sink { [weak self] _ in
            Task { @MainActor in self?.previewAlertSound(cue: .alert) }
        }
        .store(in: &cancellables)

        let soundStatePublishers: [AnyPublisher<Void, Never>] = [
            model.$snapshot.map { _ in () }.eraseToAnyPublisher(),
            model.$desktopAppSessions.map { _ in () }.eraseToAnyPublisher(),
            model.$statusLightOverride.map { _ in () }.eraseToAnyPublisher(),
            model.$isMonitoringPaused.map { _ in () }.eraseToAnyPublisher(),
            model.$isStatusBarIconEnabled.map { _ in () }.eraseToAnyPublisher(),
            model.$isFloatingSignalEnabled.map { _ in () }.eraseToAnyPublisher(),
            model.$isFloatingSignalSoundEnabled.map { _ in () }.eraseToAnyPublisher()
        ]

        for publisher in soundStatePublishers {
            publisher.sink { [weak self] _ in
                Task { @MainActor in
                    self?.evaluateAlertSound()
                    self?.evaluateActiveGreenPulseSound()
                }
            }
            .store(in: &cancellables)
        }

        model.animationClock.$tick.sink { [weak self] tick in
            Task { @MainActor in
                self?.evaluateAlertSound()
                self?.evaluateActiveGreenPulseSound(tickOverride: tick)
            }
        }
        .store(in: &cancellables)
    }

    private func updateVisibility() {
        if model.isFloatingSignalEnabled {
            showPanel()
        } else {
            releasePanel()
        }
    }

    private func releasePanel() {
        panel?.orderOut(nil)
        panel?.delegate = nil
        panel?.contentViewController = nil
        hostingController = nil
        panel = nil
    }

    private func showPanel() {
        let panel = ensurePanel()
        resizePanelForCurrentScale(keepingCenter: false)
        panel.orderFrontRegardless()
    }

    private func ensurePanel() -> NSPanel {
        if let panel {
            return panel
        }

        let contentView = FloatingSignalPanelView(
            model: model,
            animationClock: model.animationClock,
            hide: { [weak self] in self?.model.setFloatingSignalEnabled(false) },
            smaller: { [weak self] in self?.model.makeFloatingSignalSmaller() },
            larger: { [weak self] in self?.model.makeFloatingSignalLarger() },
            toggleLayout: { [weak self] in
                guard let self else { return }
                self.model.setFloatingSignalLayout(
                    self.model.floatingSignalLayout == .horizontal ? .vertical : .horizontal
                )
            },
            toggleSound: { [weak self] in
                guard let self else { return }
                self.model.setFloatingSignalSoundEnabled(!self.model.isFloatingSignalSoundEnabled)
            },
            previewCompletionSound: { [weak self] in self?.model.previewFloatingSignalSound() },
            previewWaitingSound: { [weak self] in self?.model.previewFloatingSignalWaitingSound() },
            resizeFromHandle: { [weak self] visualScale, persist in
                self?.setFloatingSignalVisualScaleFromResizeHandle(visualScale, persist: persist)
            },
            openSettings: { [weak self] in self?.openSettings() }
        )
        let hostingController = NSHostingController(rootView: contentView)
        let panel = NSPanel(
            contentRect: defaultPanelFrame(for: currentPanelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Floating Signal Light"
        panel.contentViewController = hostingController
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.acceptsMouseMovedEvents = true
        panel.delegate = self

        self.panel = panel
        self.hostingController = hostingController
        applyAppearance()
        return panel
    }

    private func resizePanelForCurrentScale(keepingCenter: Bool) {
        resizePanelForCurrentScale(anchor: keepingCenter ? .center : .savedOrDefault)
    }

    private enum ResizeAnchor {
        case savedOrDefault
        case center
        case topLeading
    }

    private func resizePanelForCurrentScale(anchor: ResizeAnchor) {
        resizePanel(
            visualScale: model.floatingSignalVisualScale,
            anchor: anchor,
            persistsOrigin: true
        )
    }

    private func resizePanel(
        visualScale: CGFloat,
        anchor: ResizeAnchor,
        persistsOrigin: Bool
    ) {
        guard let panel else { return }

        let size = panelSize(forVisualScale: visualScale)
        let origin: NSPoint
        switch anchor {
        case .savedOrDefault:
            if let savedOrigin = model.savedFloatingSignalOrigin() {
                origin = savedOrigin
            } else {
                origin = defaultPanelFrame(for: size).origin
            }
        case .center:
            origin = NSPoint(
                x: panel.frame.midX - size.width / 2,
                y: panel.frame.midY - size.height / 2
            )
        case .topLeading:
            origin = NSPoint(
                x: panel.frame.minX,
                y: panel.frame.maxY - size.height
            )
        }

        let frame = NSRect(origin: clampedOrigin(origin, for: size), size: size)
        isApplyingFrame = true
        if !panel.frame.isNearlyEqual(to: frame) {
            panel.setFrame(frame, display: true, animate: false)
        }
        isApplyingFrame = false
        if persistsOrigin {
            model.setFloatingSignalOrigin(frame.origin)
        }
    }

    private func setFloatingSignalVisualScaleFromResizeHandle(_ visualScale: CGFloat, persist: Bool) {
        let clampedScale = FloatingSignalScale.clampedVisualScale(visualScale)
        guard abs(clampedScale - model.floatingSignalVisualScale) > 0.001 || persist else {
            return
        }
        resizePanel(
            visualScale: clampedScale,
            anchor: .topLeading,
            persistsOrigin: persist
        )
        guard persist else { return }
        nextScaleResizeAnchor = .topLeading
        model.setFloatingSignalVisualScale(clampedScale, persist: persist)
    }

    private func defaultPanelFrame(for size: NSSize) -> NSRect {
        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(
            x: visibleFrame.maxX - size.width - 28,
            y: visibleFrame.maxY - size.height - 74
        )
        return NSRect(origin: clampedOrigin(origin, for: size), size: size)
    }

    private func clampedOrigin(_ origin: NSPoint, for size: NSSize) -> NSPoint {
        let screens = NSScreen.screens.map(\.visibleFrame)
        let targetFrame = NSRect(origin: origin, size: size)
        if screens.contains(where: { $0.insetBy(dx: -8, dy: -8).contains(targetFrame) }) {
            return origin
        }

        let visibleFrame = NSScreen.main?.visibleFrame ?? screens.first ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(
            x: min(max(origin.x, visibleFrame.minX + 12), visibleFrame.maxX - size.width - 12),
            y: min(max(origin.y, visibleFrame.minY + 12), visibleFrame.maxY - size.height - 12)
        )
    }

    private var currentPanelSize: NSSize {
        panelSize(forVisualScale: model.floatingSignalVisualScale)
    }

    private func panelSize(forVisualScale visualScale: CGFloat) -> NSSize {
        let contentSize = model.floatingSignalScale.panelSize(
            layout: model.floatingSignalLayout,
            trafficLightVerticalUsesMacOSSize: model.trafficLightVerticalUsesMacOSSize,
            visualScale: visualScale
        )
        return FloatingSignalPanelLayout.outerSize(
            contentSize: contentSize,
            scale: visualScale
        )
    }

    func windowDidMove(_ notification: Notification) {
        guard !isApplyingFrame,
              let movedPanel = notification.object as? NSPanel,
              movedPanel === panel
        else {
            return
        }

        model.setFloatingSignalOrigin(movedPanel.frame.origin)
    }

    private enum AlertSoundMode {
        case none
        case once
        case repeating
    }

    private func evaluateAlertSound() {
        guard model.isSignalSoundSurfaceEnabled, model.isFloatingSignalSoundEnabled else {
            return
        }

        let mode = alertSoundMode(for: model.lightSnapshot.aggregate)
        guard mode != .none else {
            didPrimeSoundState = true
            lastSoundSignature = nil
            return
        }

        let signature = soundSignature()
        if !didPrimeSoundState {
            didPrimeSoundState = true
            lastSoundSignature = signature
            lastAlertSoundAt = Date()
            return
        }

        let now = Date()
        switch mode {
        case .none:
            return
        case .once:
            guard signature != lastSoundSignature else { return }
        case .repeating:
            guard signature != lastSoundSignature || now.timeIntervalSince(lastAlertSoundAt) >= 12 else {
                return
            }
        }

        lastSoundSignature = signature
        lastAlertSoundAt = now
        playAlertSound(force: false, cue: soundCue(for: model.lightSnapshot.aggregate))
    }

    private func playAlertSound(force: Bool, cue: FloatingSignalSoundCue) {
        guard force || isSoundEnabled(for: cue) else { return }
        guard let asset = soundAsset(for: cue) else { return }
        soundPlayer.play(asset: asset, level: model.floatingSignalSoundLevel)
    }

    private func previewAlertSound(cue: FloatingSignalSoundCue) {
        guard let asset = soundAsset(for: cue) else { return }
        soundPlayer.preview(asset: asset, level: model.floatingSignalSoundLevel)
    }

    private func evaluateActiveGreenPulseSound(tickOverride: Int? = nil) {
        guard model.isSignalSoundSurfaceEnabled, isSoundEnabled(for: .waiting) else {
            wasActiveGreenLitForSound = false
            return
        }

        let signal = model.lightSnapshot.aggregate
        guard signal.displayState == .active, !model.lightAllLightsOn else {
            wasActiveGreenLitForSound = false
            return
        }

        let tick = model.statusLightOverride == nil ? (tickOverride ?? model.lightTick) : model.lightTick
        let isGreenLit = SignalLampAnimation.isLit(
            .green,
            signal: signal,
            tick: tick,
            allLightsOn: model.lightAllLightsOn,
            customization: model.lightEffectCustomization
        )
        defer {
            wasActiveGreenLitForSound = isGreenLit
        }

        guard isGreenLit, !wasActiveGreenLitForSound else {
            return
        }
        playAlertSound(force: false, cue: .waiting)
    }

    private func isSoundEnabled(for cue: FloatingSignalSoundCue) -> Bool {
        guard model.isFloatingSignalSoundEnabled else {
            return false
        }

        switch cue {
        case .completion:
            return model.isFloatingSignalCompletionSoundEnabled
        case .waiting:
            return model.isFloatingSignalWaitingSoundEnabled
        case .alert:
            return model.isFloatingSignalAlertSoundEnabled
        }
    }

    private func soundAsset(for cue: FloatingSignalSoundCue) -> FloatingSignalSoundAsset? {
        switch cue {
        case .completion:
            guard let resourceName = model.floatingSignalCompletionSound.resourceName else {
                return nil
            }
            return .resource(resourceName)
        case .waiting:
            guard let resourceName = model.floatingSignalWaitingSound.resourceName else {
                return nil
            }
            return .resource(resourceName)
        case .alert:
            switch model.floatingSignalAlertSound {
            case .off:
                return nil
            case .defaultPulse:
                return .defaultPulse
            case .aiBeacon, .aiUrgent:
                guard let resourceName = model.floatingSignalAlertSound.resourceName else {
                    return nil
                }
                return .resource(resourceName)
            }
        }
    }

    private func alertSoundMode(for signal: AgentSignal) -> AlertSoundMode {
        switch signal.displayState {
        case .completed, .stale:
            return .once
        case .needsReview, .permission, .blocked:
            return .repeating
        case .ready, .active, .paused:
            return .none
        }
    }

    private func soundCue(for signal: AgentSignal) -> FloatingSignalSoundCue {
        signal.displayState == .completed ? .completion : .alert
    }

    private func soundSignature() -> String {
        let snapshot = model.lightSnapshot
        let updatedAt = snapshot.updatedAt?.timeIntervalSince1970 ?? 0
        return "\(snapshot.aggregate.rawValue)|\(Int(updatedAt))|\(snapshot.sessions.count)"
    }
}

private extension NSRect {
    func isNearlyEqual(to other: NSRect, tolerance: CGFloat = 0.5) -> Bool {
        abs(origin.x - other.origin.x) <= tolerance
            && abs(origin.y - other.origin.y) <= tolerance
            && abs(size.width - other.size.width) <= tolerance
            && abs(size.height - other.size.height) <= tolerance
    }
}

private final class FloatingSignalCursorPush {
    private var didPush = false

    deinit {
        pop()
    }

    func push(_ cursor: NSCursor) {
        if !didPush {
            cursor.push()
            didPush = true
        }
        cursor.set()
    }

    func pop() {
        guard didPush else { return }
        NSCursor.pop()
        didPush = false
    }
}

private struct FloatingSignalPanelView: View {
    private enum BadgeKind {
        case info
        case quota
        case token
    }

    @ObservedObject var model: MenuBarStatusModel
    let animationClock: SignalAnimationClock
    let hide: () -> Void
    let smaller: () -> Void
    let larger: () -> Void
    let toggleLayout: () -> Void
    let toggleSound: () -> Void
    let previewCompletionSound: () -> Void
    let previewWaitingSound: () -> Void
    let resizeFromHandle: (CGFloat, Bool) -> Void
    let openSettings: () -> Void
    @State private var isHoveringResizeHandle = false
    @State private var isDraggingResizeHandle = false
    @State private var isDraggingInfoBadge = false
    @State private var isDraggingQuotaBadge = false
    @State private var isDraggingTokenBadge = false
    @State private var infoBadgeDragTranslation = CGSize.zero
    @State private var quotaBadgeDragTranslation = CGSize.zero
    @State private var tokenBadgeDragTranslation = CGSize.zero
    @State private var isShowingInfoPanel = false
    @State private var isShowingQuotaPanel = false
    @State private var isShowingTokenPanel = false
    @State private var resizeStartVisualScale: CGFloat?
    @State private var resizeTargetVisualScale: CGFloat?
    @State private var resizeStartTick: Int?
    @State private var cachedLightSnapshot: SignalSnapshot
    @State private var cachedFloatingInfoSessions: [SessionStatus]
    @State private var lastPersistedVisibleBadgeCornerSignature: String?

    init(
        model: MenuBarStatusModel,
        animationClock: SignalAnimationClock,
        hide: @escaping () -> Void,
        smaller: @escaping () -> Void,
        larger: @escaping () -> Void,
        toggleLayout: @escaping () -> Void,
        toggleSound: @escaping () -> Void,
        previewCompletionSound: @escaping () -> Void,
        previewWaitingSound: @escaping () -> Void,
        resizeFromHandle: @escaping (CGFloat, Bool) -> Void,
        openSettings: @escaping () -> Void
    ) {
        self.model = model
        self.animationClock = animationClock
        self.hide = hide
        self.smaller = smaller
        self.larger = larger
        self.toggleLayout = toggleLayout
        self.toggleSound = toggleSound
        self.previewCompletionSound = previewCompletionSound
        self.previewWaitingSound = previewWaitingSound
        self.resizeFromHandle = resizeFromHandle
        self.openSettings = openSettings
        _cachedLightSnapshot = State(initialValue: model.lightSnapshot)
        _cachedFloatingInfoSessions = State(
            initialValue: ActivityPresentation.visibleRunningSessions(from: model.activitySnapshot)
        )
    }

    var body: some View {
        let scale = effectiveVisualScale
        let contentSize = model.floatingSignalScale.panelSize(
            layout: model.floatingSignalLayout,
            trafficLightVerticalUsesMacOSSize: model.trafficLightVerticalUsesMacOSSize,
            visualScale: scale
        )
        let signalSize = model.floatingSignalScale.signalFrameSize(
            layout: model.floatingSignalLayout,
            trafficLightVerticalUsesMacOSSize: model.trafficLightVerticalUsesMacOSSize,
            visualScale: scale
        )
        let backingSize = model.floatingSignalScale.housingBackingSize(
            layout: model.floatingSignalLayout,
            trafficLightVerticalUsesMacOSSize: model.trafficLightVerticalUsesMacOSSize,
            visualScale: scale
        )
        let contentOrigin = FloatingSignalPanelLayout.contentOrigin(scale: scale)
        let handleHotspotInset = FloatingSignalPanelLayout.resizeHandleHotspotInset(for: scale)
        let panelSize = FloatingSignalPanelLayout.outerSize(contentSize: contentSize, scale: scale)

        ZStack(alignment: .topLeading) {
            signalBody(
                backingSize: backingSize,
                signalSize: signalSize,
                scale: scale
            )
            .frame(width: contentSize.width, height: contentSize.height, alignment: .topLeading)
            .overlay {
                FloatingSignalDragCursorRegion()
            }
            .offset(x: contentOrigin.x, y: contentOrigin.y)

            if shouldShowInfoBadge {
                let badgeOffset = infoBadgeOffset(
                    for: model.floatingSignalInfoBadgeCorner,
                    contentOrigin: contentOrigin,
                    contentSize: contentSize,
                    scale: scale
                )
                infoBadge(scale: scale, contentOrigin: contentOrigin, contentSize: contentSize)
                    .offset(
                        x: badgeOffset.width + infoBadgeDragTranslation.width,
                        y: badgeOffset.height + infoBadgeDragTranslation.height
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.88, anchor: .topLeading)))
            }

            if let quotaStatus = floatingQuotaStatus {
                let corner = resolvedQuotaBadgeCorner
                let badgeOffset = infoBadgeOffset(
                    for: corner,
                    contentOrigin: contentOrigin,
                    contentSize: contentSize,
                    scale: scale
                )
                quotaBadge(
                    quotaStatus,
                    corner: corner,
                    contentOrigin: contentOrigin,
                    contentSize: contentSize,
                    scale: scale
                )
                    .offset(
                        x: badgeOffset.width + quotaBadgeDragTranslation.width,
                        y: badgeOffset.height + quotaBadgeDragTranslation.height
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.88, anchor: .topLeading)))
            }

            if shouldShowTokenBadge {
                let corner = resolvedTokenBadgeCorner
                let badgeOffset = infoBadgeOffset(
                    for: corner,
                    contentOrigin: contentOrigin,
                    contentSize: contentSize,
                    scale: scale
                )
                tokenBadge(
                    corner: corner,
                    contentOrigin: contentOrigin,
                    contentSize: contentSize,
                    scale: scale
                )
                    .offset(
                        x: badgeOffset.width + tokenBadgeDragTranslation.width,
                        y: badgeOffset.height + tokenBadgeDragTranslation.height
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.88, anchor: .topLeading)))
            }

            resizeHandleTarget(scale: scale, hotspotInset: handleHotspotInset)
                .offset(
                    x: contentOrigin.x + contentSize.width - handleHotspotInset,
                    y: contentOrigin.y + contentSize.height - handleHotspotInset
                )
        }
        .frame(width: panelSize.width, height: panelSize.height, alignment: .topLeading)
        .background(Color.clear)
        .contentShape(Rectangle())
        .transaction { transaction in
            if isDraggingResizeHandle || isDraggingInfoBadge || isDraggingQuotaBadge || isDraggingTokenBadge {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
        .animation(.easeInOut(duration: 0.12), value: showsResizeHandle)
        .animation(.easeInOut(duration: 0.12), value: shouldShowInfoBadge)
        .animation(.easeInOut(duration: 0.12), value: shouldShowTokenBadge)
        .animation(.easeInOut(duration: 0.12), value: model.floatingSignalInfoBadgeCorner)
        .animation(.easeInOut(duration: 0.12), value: model.floatingSignalQuotaBadgeCorner)
        .animation(.easeInOut(duration: 0.12), value: model.floatingSignalTokenBadgeCorner)
        .animation(.easeInOut(duration: 0.12), value: model.floatingSignalTokenBadgeWindow)
        .animation(.easeInOut(duration: 0.12), value: floatingQuotaStatus)
        .animation(.easeInOut(duration: 0.12), value: model.latestAgentTokenUsage)
        .contextMenu {
            Button(model.text("隐藏悬浮灯", "Hide Floating Signal"), action: hide)
            Button(model.text("设置...", "Settings..."), action: openSettings)
            Divider()
            Button(model.text("缩小", "Smaller"), action: smaller)
                .disabled(model.floatingSignalVisualScale <= FloatingSignalScale.minimumVisualScale + 0.01)
            Button(model.text("放大", "Larger"), action: larger)
                .disabled(model.floatingSignalVisualScale >= FloatingSignalScale.maximumVisualScale - 0.01)
            Divider()
            Button(
                model.floatingSignalLayout == .horizontal
                    ? model.text("切换为竖向", "Switch to Vertical")
                    : model.text("切换为横向", "Switch to Horizontal"),
                action: toggleLayout
            )
            Divider()
            Button(
                model.isFloatingSignalSoundEnabled
                    ? model.text("关闭声音提醒", "Turn Sound Off")
                    : model.text("开启声音提醒", "Turn Sound On"),
                action: toggleSound
            )
            Button(model.text("试听完成音", "Preview Completion Sound"), action: previewCompletionSound)
            Button(model.text("试听闪烁音", "Preview Flash Sound"), action: previewWaitingSound)
        }
        .preferredColorScheme(model.appTheme.colorScheme)
        .accessibilityLabel(model.text("悬浮信号灯", "Floating Signal Light"))
        .accessibilityValue(model.displayName(for: cachedLightSnapshot.aggregate))
        .onReceive(model.$snapshot) { _ in
            refreshCachedSnapshots()
            persistVisibleBadgeCornersSoon()
        }
        .onReceive(model.$desktopAppSessions) { _ in
            refreshCachedSnapshots()
            persistVisibleBadgeCornersSoon()
        }
        .onReceive(model.$statusLightOverride) { _ in
            refreshCachedSnapshots()
        }
        .onReceive(model.$isMonitoringPaused) { _ in
            refreshCachedSnapshots()
            persistVisibleBadgeCornersSoon()
        }
        .onReceive(model.$latestAgentQuota) { _ in
            refreshCachedSnapshots()
            persistVisibleBadgeCornersSoon()
        }
        .onReceive(model.$isFloatingSignalInfoBadgeEnabled) { _ in
            refreshCachedSnapshots()
            persistVisibleBadgeCornersSoon()
        }
        .onReceive(model.$isFloatingSignalQuotaBadgeEnabled) { _ in
            refreshCachedSnapshots()
            persistVisibleBadgeCornersSoon()
        }
        .onReceive(model.$isFloatingSignalTokenBadgeEnabled) { _ in
            refreshCachedSnapshots()
            persistVisibleBadgeCornersSoon()
        }
        .onReceive(model.$latestAgentTokenUsage) { _ in
            refreshCachedSnapshots()
            persistVisibleBadgeCornersSoon()
        }
        .onReceive(model.$signalLightAgentScopes) { _ in
            refreshCachedSnapshots()
            persistVisibleBadgeCornersSoon()
        }
        .onReceive(model.$signalLightAgentSelectionMode) { _ in
            refreshCachedSnapshots()
            persistVisibleBadgeCornersSoon()
        }
        .task {
            persistVisibleBadgeCornersSoon()
        }
    }

    private var showsResizeHandle: Bool {
        isHoveringResizeHandle || isDraggingResizeHandle
    }

    private var effectiveVisualScale: CGFloat {
        resizeTargetVisualScale ?? model.floatingSignalVisualScale
    }

    private var shouldShowInfoBadge: Bool {
        model.isFloatingSignalInfoBadgeEnabled && infoBadgeCount > 0
    }

    private var shouldShowTokenBadge: Bool {
        model.isFloatingSignalTokenBadgeEnabled
            && !model.isMonitoringPaused
            && floatingTokenUsageTokens > 0
    }

    private var floatingQuotaStatus: AgentQuotaStatus? {
        guard model.isFloatingSignalQuotaBadgeEnabled,
              !model.isMonitoringPaused,
              let quota = model.latestAgentQuota
        else {
            return nil
        }

        return quota
    }

    private var resolvedQuotaBadgeCorner: FloatingSignalInfoBadgeCorner {
        var occupied: [FloatingSignalInfoBadgeCorner] = []
        if shouldShowInfoBadge {
            occupied.append(model.floatingSignalInfoBadgeCorner)
        }
        return firstAvailableBadgeCorner(
            preferred: model.floatingSignalQuotaBadgeCorner,
            avoiding: occupied
        )
    }

    private var resolvedTokenBadgeCorner: FloatingSignalInfoBadgeCorner {
        var occupied: [FloatingSignalInfoBadgeCorner] = []
        if shouldShowInfoBadge {
            occupied.append(model.floatingSignalInfoBadgeCorner)
        }
        if floatingQuotaStatus != nil {
            occupied.append(resolvedQuotaBadgeCorner)
        }
        return firstAvailableBadgeCorner(
            preferred: model.floatingSignalTokenBadgeCorner,
            avoiding: occupied
        )
    }

    private func infoBadge(scale: CGFloat, contentOrigin: CGPoint, contentSize: CGSize) -> some View {
        let badgeSize = FloatingSignalPanelLayout.badgeSize(for: scale)
        let fontSize = badgeFontSize(for: infoBadgeText)

        return ZStack {
            Text(infoBadgeText)
                .font(.system(size: fontSize, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .monospacedDigit()
                .minimumScaleFactor(0.75)
                .frame(width: badgeSize, height: badgeSize)
                .background(
                    Circle()
                        .fill(Color.black)
                )
                .clipShape(Circle())
                .contentShape(Circle())
                .accessibilityHidden(true)

            FloatingSignalInfoBadgeDragControl(
                badgeSize: badgeSize,
                onClick: {
                    isShowingQuotaPanel = false
                    isShowingTokenPanel = false
                    isShowingInfoPanel.toggle()
                },
                onDragChanged: { translation in
                    isShowingInfoPanel = false
                    isShowingQuotaPanel = false
                    isShowingTokenPanel = false
                    isDraggingInfoBadge = true
                    infoBadgeDragTranslation = translation
                },
                onDragEnded: { translation in
                    let currentInfoCorner = model.floatingSignalInfoBadgeCorner
                    let nextCorner = nearestInfoBadgeCorner(
                        from: currentInfoCorner,
                        translation: translation,
                        contentOrigin: contentOrigin,
                        contentSize: contentSize,
                        scale: scale
                    )
                    moveBadge(.info, from: currentInfoCorner, to: nextCorner)
                    infoBadgeDragTranslation = .zero
                    isDraggingInfoBadge = false
                },
                onDragCancelled: {
                    infoBadgeDragTranslation = .zero
                    isDraggingInfoBadge = false
                }
            )
            .frame(width: badgeSize, height: badgeSize)
        }
        .background(
            FloatingSignalInfoPanelAnchor(isPresented: $isShowingInfoPanel, model: model)
        )
        .help(model.text("点击查看悬浮灯状态，拖动可移动角标", "Click to show floating signal status; drag to move the badge"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.text("查看悬浮灯状态", "Show floating signal status"))
    }

    private func quotaBadge(
        _ quota: AgentQuotaStatus,
        corner: FloatingSignalInfoBadgeCorner,
        contentOrigin: CGPoint,
        contentSize: CGSize,
        scale: CGFloat
    ) -> some View {
        let badgeSize = FloatingSignalPanelLayout.badgeSize(for: scale)
        let text = quotaBadgeText(for: quota)
        let fontSize = badgeFontSize(for: text)

        return ZStack {
            Text(text)
                .font(.system(size: fontSize, weight: .bold, design: .rounded))
                .foregroundStyle(quotaBadgeForeground(for: quota))
                .monospacedDigit()
                .minimumScaleFactor(0.55)
                .lineLimit(1)
                .frame(width: badgeSize, height: badgeSize)
                .background(Circle().fill(Color.black))
                .clipShape(Circle())
                .contentShape(Circle())
                .accessibilityHidden(true)

            FloatingSignalInfoBadgeDragControl(
                badgeSize: badgeSize,
                onClick: {
                    isShowingInfoPanel = false
                    isShowingTokenPanel = false
                    isShowingQuotaPanel.toggle()
                },
                onDragChanged: { translation in
                    isShowingInfoPanel = false
                    isShowingQuotaPanel = false
                    isShowingTokenPanel = false
                    isDraggingQuotaBadge = true
                    quotaBadgeDragTranslation = translation
                },
                onDragEnded: { translation in
                    let nextCorner = nearestInfoBadgeCorner(
                        from: corner,
                        translation: translation,
                        contentOrigin: contentOrigin,
                        contentSize: contentSize,
                        scale: scale
                    )
                    moveBadge(.quota, from: corner, to: nextCorner)
                    quotaBadgeDragTranslation = .zero
                    isDraggingQuotaBadge = false
                },
                onDragCancelled: {
                    quotaBadgeDragTranslation = .zero
                    isDraggingQuotaBadge = false
                }
            )
            .frame(width: badgeSize, height: badgeSize)
        }
        .background(
            FloatingSignalQuotaPanelAnchor(
                isPresented: $isShowingQuotaPanel,
                model: model,
                quota: quota
            )
        )
        .help(model.text("点击查看 Agent 剩余额度，拖动可移动角标", "Click to show agent quota; drag to move the badge"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(quotaBadgeHelp(for: quota))
    }

    private func tokenBadge(
        corner: FloatingSignalInfoBadgeCorner,
        contentOrigin: CGPoint,
        contentSize: CGSize,
        scale: CGFloat
    ) -> some View {
        let badgeSize = FloatingSignalPanelLayout.badgeSize(for: scale)
        let text = tokenBadgeText
        let fontSize = badgeFontSize(for: text)

        return ZStack {
            Text(text)
                .font(.system(size: fontSize, weight: .bold, design: .rounded))
                .foregroundStyle(Color(red: 0.42, green: 0.78, blue: 1.0))
                .monospacedDigit()
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .frame(width: badgeSize, height: badgeSize)
                .background(Circle().fill(Color.black))
                .clipShape(Circle())
                .contentShape(Circle())
                .accessibilityHidden(true)

            FloatingSignalInfoBadgeDragControl(
                badgeSize: badgeSize,
                onClick: {
                    isShowingInfoPanel = false
                    isShowingQuotaPanel = false
                    model.refreshTokenActivityIfNeeded(force: model.tokenActivityDays.isEmpty)
                    isShowingTokenPanel.toggle()
                },
                onDragChanged: { translation in
                    isShowingInfoPanel = false
                    isShowingQuotaPanel = false
                    isShowingTokenPanel = false
                    isDraggingTokenBadge = true
                    tokenBadgeDragTranslation = translation
                },
                onDragEnded: { translation in
                    let nextCorner = nearestInfoBadgeCorner(
                        from: corner,
                        translation: translation,
                        contentOrigin: contentOrigin,
                        contentSize: contentSize,
                        scale: scale
                    )
                    moveBadge(.token, from: corner, to: nextCorner)
                    tokenBadgeDragTranslation = .zero
                    isDraggingTokenBadge = false
                },
                onDragCancelled: {
                    tokenBadgeDragTranslation = .zero
                    isDraggingTokenBadge = false
                }
            )
            .frame(width: badgeSize, height: badgeSize)
        }
        .background(
            FloatingSignalTokenPanelAnchor(isPresented: $isShowingTokenPanel, model: model)
        )
        .help(tokenBadgeHelp)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tokenBadgeHelp)
    }

    private func badgeFontSize(for text: String) -> CGFloat {
        if text.count > 3 { return 7 }
        if text.count > 2 { return 9 }
        if text.count > 1 { return 11 }
        return 13
    }

    private func quotaBadgeText(for quota: AgentQuotaStatus) -> String {
        model.quotaPercentText(for: model.quotaWindow(for: model.floatingSignalQuotaBadgeWindow, quota: quota))
    }

    private func quotaBadgeForeground(for quota: AgentQuotaStatus) -> Color {
        let remainingPercent = model.quotaWindow(
            for: model.floatingSignalQuotaBadgeWindow,
            quota: quota
        )?.remainingPercent ?? quota.remainingPercent

        if remainingPercent <= 15 {
            return Color(red: 1.0, green: 0.26, blue: 0.22)
        }
        if remainingPercent <= 35 {
            return Color(red: 1.0, green: 0.75, blue: 0.22)
        }
        return Color(red: 0.28, green: 0.92, blue: 0.46)
    }

    private func quotaBadgeHelp(for quota: AgentQuotaStatus) -> String {
        let percent = quotaBadgeText(for: quota)
        if let limitName = quota.limitName, !limitName.isEmpty {
            return model.text(
                "Agent 剩余额度 \(percent) · \(limitName)",
                "Agent quota remaining \(percent) · \(limitName)"
            )
        }
        return model.text(
            "Agent 剩余额度 \(percent)",
            "Agent quota remaining \(percent)"
        )
    }

    private func infoBadgeOffset(
        for corner: FloatingSignalInfoBadgeCorner,
        contentOrigin: CGPoint,
        contentSize: CGSize,
        scale: CGFloat
    ) -> CGSize {
        let badgeSize = FloatingSignalPanelLayout.badgeSize(for: scale)
        let overlap = FloatingSignalPanelLayout.infoBadgeOverlap(for: scale)
        let leadingX = contentOrigin.x - badgeSize + overlap
        let bottomY = contentOrigin.y + contentSize.height - FloatingSignalPanelLayout.controlGap(for: scale)

        switch corner {
        case .topLeft:
            return CGSize(width: leadingX, height: 0)
        case .topRight:
            return CGSize(width: contentOrigin.x + contentSize.width - overlap, height: 0)
        case .bottomLeft:
            return CGSize(width: leadingX, height: bottomY)
        }
    }

    private func nearestInfoBadgeCorner(
        from corner: FloatingSignalInfoBadgeCorner,
        translation: CGSize,
        contentOrigin: CGPoint,
        contentSize: CGSize,
        scale: CGFloat
    ) -> FloatingSignalInfoBadgeCorner {
        let badgeSize = FloatingSignalPanelLayout.badgeSize(for: scale)
        let startingOffset = infoBadgeOffset(
            for: corner,
            contentOrigin: contentOrigin,
            contentSize: contentSize,
            scale: scale
        )
        let targetCenter = CGPoint(
            x: startingOffset.width + translation.width + badgeSize / 2,
            y: startingOffset.height + translation.height + badgeSize / 2
        )

        return FloatingSignalInfoBadgeCorner.allCases.min { lhs, rhs in
            let lhsCenter = infoBadgeCenter(
                for: lhs,
                contentOrigin: contentOrigin,
                contentSize: contentSize,
                scale: scale
            )
            let rhsCenter = infoBadgeCenter(
                for: rhs,
                contentOrigin: contentOrigin,
                contentSize: contentSize,
                scale: scale
            )
            return squaredDistance(lhsCenter, targetCenter) < squaredDistance(rhsCenter, targetCenter)
        } ?? corner
    }

    private func firstAvailableBadgeCorner(
        preferred: FloatingSignalInfoBadgeCorner,
        avoiding occupiedCorners: [FloatingSignalInfoBadgeCorner]
    ) -> FloatingSignalInfoBadgeCorner {
        if !occupiedCorners.contains(preferred) {
            return preferred
        }
        return FloatingSignalInfoBadgeCorner.allCases.first { !occupiedCorners.contains($0) } ?? preferred
    }

    private func moveBadge(
        _ badge: BadgeKind,
        from currentCorner: FloatingSignalInfoBadgeCorner,
        to nextCorner: FloatingSignalInfoBadgeCorner
    ) {
        guard currentCorner != nextCorner else {
            setBadgeCorner(badge, nextCorner)
            return
        }

        if let occupyingBadge = visibleBadgeKinds(excluding: badge).first(where: {
            resolvedBadgeCorner(for: $0) == nextCorner
        }) {
            setBadgeCorner(occupyingBadge, currentCorner)
        }
        setBadgeCorner(badge, nextCorner)
        lastPersistedVisibleBadgeCornerSignature = nil
        persistVisibleBadgeCornersSoon()
    }

    private func persistVisibleBadgeCornersSoon() {
        Task { @MainActor in
            persistVisibleBadgeCornersIfNeeded()
        }
    }

    private func persistVisibleBadgeCornersIfNeeded() {
        guard !isDraggingInfoBadge,
              !isDraggingQuotaBadge,
              !isDraggingTokenBadge
        else {
            return
        }

        var visibleCorners: [(BadgeKind, FloatingSignalInfoBadgeCorner)] = []
        if shouldShowInfoBadge {
            visibleCorners.append((.info, model.floatingSignalInfoBadgeCorner))
        }
        if floatingQuotaStatus != nil {
            visibleCorners.append((.quota, resolvedQuotaBadgeCorner))
        }
        if shouldShowTokenBadge {
            visibleCorners.append((.token, resolvedTokenBadgeCorner))
        }

        let signature = visibleCorners
            .map { "\($0.0):\($0.1.rawValue)" }
            .joined(separator: "|")
        guard signature != lastPersistedVisibleBadgeCornerSignature else {
            return
        }
        lastPersistedVisibleBadgeCornerSignature = signature

        for (badge, corner) in visibleCorners {
            setBadgeCorner(badge, corner)
        }
    }

    private func visibleBadgeKinds(excluding excludedBadge: BadgeKind) -> [BadgeKind] {
        var badges: [BadgeKind] = []
        if shouldShowInfoBadge && excludedBadge != .info {
            badges.append(.info)
        }
        if floatingQuotaStatus != nil && excludedBadge != .quota {
            badges.append(.quota)
        }
        if shouldShowTokenBadge && excludedBadge != .token {
            badges.append(.token)
        }
        return badges
    }

    private func resolvedBadgeCorner(for badge: BadgeKind) -> FloatingSignalInfoBadgeCorner {
        switch badge {
        case .info:
            return model.floatingSignalInfoBadgeCorner
        case .quota:
            return resolvedQuotaBadgeCorner
        case .token:
            return resolvedTokenBadgeCorner
        }
    }

    private func setBadgeCorner(_ badge: BadgeKind, _ corner: FloatingSignalInfoBadgeCorner) {
        switch badge {
        case .info:
            model.setFloatingSignalInfoBadgeCorner(corner)
        case .quota:
            model.setFloatingSignalQuotaBadgeCorner(corner)
        case .token:
            model.setFloatingSignalTokenBadgeCorner(corner)
        }
    }

    private func infoBadgeCenter(
        for corner: FloatingSignalInfoBadgeCorner,
        contentOrigin: CGPoint,
        contentSize: CGSize,
        scale: CGFloat
    ) -> CGPoint {
        let badgeSize = FloatingSignalPanelLayout.badgeSize(for: scale)
        let offset = infoBadgeOffset(
            for: corner,
            contentOrigin: contentOrigin,
            contentSize: contentSize,
            scale: scale
        )
        return CGPoint(x: offset.width + badgeSize / 2, y: offset.height + badgeSize / 2)
    }

    private func squaredDistance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return dx * dx + dy * dy
    }

    private var infoBadgeText: String {
        let count = max(infoBadgeCount, 0)
        return count > 99 ? "99+" : "\(count)"
    }

    private var infoBadgeCount: Int {
        cachedFloatingInfoSessions.count
    }

    private var tokenBadgeText: String {
        model.compactTokenBadgeText(floatingTokenUsageTokens)
    }

    private var tokenBadgeHelp: String {
        let tokenText = model.tokenUsageTitleLine(
            for: model.floatingSignalTokenBadgeWindow,
            tokens: floatingTokenUsageTokens
        )
        return model.text(
            "Token 使用量 \(tokenText)",
            "Token usage \(tokenText)"
        )
    }

    private var floatingTokenUsageTokens: Int {
        model.tokenActivityTotal(for: model.floatingSignalTokenBadgeWindow)
    }

    private func signalBody(
        backingSize: CGSize,
        signalSize: CGSize,
        scale: CGFloat
    ) -> some View {
        FloatingSignalLightsView(
            animationClock: animationClock,
            snapshot: cachedLightSnapshot,
            statusLightOverride: model.statusLightOverride,
            isDraggingResizeHandle: isDraggingResizeHandle,
            resizeStartTick: resizeStartTick,
            backingSize: backingSize,
            signalSize: signalSize,
            scale: scale,
            layout: model.floatingSignalLayout,
            macOSBreathingStrength: model.macOSBreathingStrength,
            trafficLightVerticalUsesMacOSSize: model.trafficLightVerticalUsesMacOSSize,
            allLightsOn: model.lightAllLightsOn,
            usesSystemGrayLights: model.lightUsesSystemGrayLights,
            effectCustomization: model.lightEffectCustomization
        )
    }

    private func refreshCachedSnapshots() {
        cachedLightSnapshot = model.lightSnapshot
        cachedFloatingInfoSessions = ActivityPresentation.visibleRunningSessions(from: model.activitySnapshot)
    }

    private func resizeHandleTarget(scale: CGFloat, hotspotInset: CGFloat) -> some View {
        let handleSize = FloatingSignalPanelLayout.resizeHandleSize(for: scale)
        let targetSize = hotspotInset + FloatingSignalPanelLayout.controlGap(for: scale) + handleSize

        return FloatingSignalResizeHandleControl(
            handleSize: handleSize,
            onHoverChanged: { isHoveringResizeHandle = $0 },
            onDragChanged: handleResizeDragChanged,
            onDragEnded: handleResizeDragEnded
        )
        .frame(width: targetSize, height: targetSize, alignment: .bottomTrailing)
        .help(model.text("拖动调整悬浮灯大小", "Drag to resize the floating signal"))
        .accessibilityLabel(model.text("调整悬浮灯大小", "Resize floating signal"))
    }

    private func handleResizeDragChanged(_ translation: CGSize) {
        if resizeStartVisualScale == nil {
            withoutResizeAnimation {
                resizeStartVisualScale = model.floatingSignalVisualScale
                resizeTargetVisualScale = model.floatingSignalVisualScale
                resizeStartTick = model.statusLightOverride?.tick ?? animationClock.tick
            }
        }
        if !isDraggingResizeHandle {
            withoutResizeAnimation {
                isDraggingResizeHandle = true
            }
        }

        let baseScale = resizeStartVisualScale ?? model.floatingSignalVisualScale
        let nextScale = visualScale(from: baseScale, translation: translation)
        guard abs(nextScale - (resizeTargetVisualScale ?? model.floatingSignalVisualScale)) > 0.006 else { return }

        withoutResizeAnimation {
            resizeTargetVisualScale = nextScale
        }
        resizeFromHandle(nextScale, false)
    }

    private func handleResizeDragEnded() {
        if let resizeTargetVisualScale {
            resizeFromHandle(resizeTargetVisualScale, true)
        }
        withoutResizeAnimation {
            resizeStartVisualScale = nil
            resizeTargetVisualScale = nil
            resizeStartTick = nil
            isDraggingResizeHandle = false
        }
    }

    private func withoutResizeAnimation(_ updates: () -> Void) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction, updates)
    }

    private func visualScale(
        from baseScale: CGFloat,
        translation: CGSize
    ) -> CGFloat {
        let resizeDistance = (translation.width + translation.height) / sqrt(2)
        return FloatingSignalScale.clampedVisualScale(baseScale + resizeDistance / 82)
    }
}

private struct FloatingSignalLightsView: View {
    @ObservedObject var animationClock: SignalAnimationClock
    let snapshot: SignalSnapshot
    let statusLightOverride: StatusLightOverrideFrame?
    let isDraggingResizeHandle: Bool
    let resizeStartTick: Int?
    let backingSize: CGSize
    let signalSize: CGSize
    let scale: CGFloat
    let layout: TrafficSignalLayout
    let macOSBreathingStrength: MacOSBreathingStrength
    let trafficLightVerticalUsesMacOSSize: Bool
    let allLightsOn: Bool
    let usesSystemGrayLights: Bool
    let effectCustomization: SignalEffectCustomization

    var body: some View {
        let currentTick = statusLightOverride?.tick ?? animationClock.tick
        let syncedTick = isDraggingResizeHandle ? (resizeStartTick ?? currentTick) : currentTick

        ZStack {
            RoundedRectangle(cornerRadius: 8 * scale, style: .continuous)
                .fill(Color.black.opacity(0.96))
                .frame(width: backingSize.width, height: backingSize.height)

            TrafficSignalView(
                snapshot: snapshot,
                tick: syncedTick,
                size: .panel,
                layout: layout,
                style: .trafficLight,
                macOSBreathingStrength: macOSBreathingStrength,
                macOSHorizontalUsesTrafficLightSize: false,
                trafficLightVerticalUsesMacOSSize: trafficLightVerticalUsesMacOSSize,
                allLightsOn: allLightsOn,
                usesSystemGrayLights: usesSystemGrayLights,
                effectCustomization: effectCustomization
            )
            .scaleEffect(scale)
            .frame(width: signalSize.width, height: signalSize.height)
            .accessibilityHidden(true)
        }
    }
}

private struct FloatingSignalResizeHandleControl: NSViewRepresentable {
    let handleSize: CGFloat
    let onHoverChanged: (Bool) -> Void
    let onDragChanged: (CGSize) -> Void
    let onDragEnded: () -> Void

    func makeNSView(context: Context) -> FloatingSignalResizeHandleView {
        let view = FloatingSignalResizeHandleView()
        view.handleSize = handleSize
        view.onHoverChanged = onHoverChanged
        view.onDragChanged = onDragChanged
        view.onDragEnded = onDragEnded
        return view
    }

    func updateNSView(_ nsView: FloatingSignalResizeHandleView, context: Context) {
        nsView.handleSize = handleSize
        nsView.onHoverChanged = onHoverChanged
        nsView.onDragChanged = onDragChanged
        nsView.onDragEnded = onDragEnded
    }
}

private struct FloatingSignalInfoBadgeDragControl: NSViewRepresentable {
    let badgeSize: CGFloat
    let onClick: () -> Void
    let onDragChanged: (CGSize) -> Void
    let onDragEnded: (CGSize) -> Void
    let onDragCancelled: () -> Void

    func makeNSView(context: Context) -> FloatingSignalInfoBadgeDragView {
        let view = FloatingSignalInfoBadgeDragView()
        view.badgeSize = badgeSize
        view.onClick = onClick
        view.onDragChanged = onDragChanged
        view.onDragEnded = onDragEnded
        view.onDragCancelled = onDragCancelled
        return view
    }

    func updateNSView(_ nsView: FloatingSignalInfoBadgeDragView, context: Context) {
        nsView.badgeSize = badgeSize
        nsView.onClick = onClick
        nsView.onDragChanged = onDragChanged
        nsView.onDragEnded = onDragEnded
        nsView.onDragCancelled = onDragCancelled
    }
}

private struct FloatingSignalDragCursorRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> FloatingSignalDragCursorView {
        FloatingSignalDragCursorView()
    }

    func updateNSView(_ nsView: FloatingSignalDragCursorView, context: Context) {}
}

@MainActor
private final class FloatingSignalInfoBadgeDragView: NSView {
    var badgeSize: CGFloat = 24 {
        didSet {
            needsLayout = true
            invalidateCursorRects()
        }
    }
    var onClick: (() -> Void)?
    var onDragChanged: ((CGSize) -> Void)?
    var onDragEnded: ((CGSize) -> Void)?
    var onDragCancelled: (() -> Void)?

    private var trackingArea: NSTrackingArea?
    private var dragStartScreenPoint: NSPoint?
    private var lastTranslation = CGSize.zero
    private var isDragging = false
    private let cursorPush = FloatingSignalCursorPush()
    private let dragThreshold: CGFloat = 3

    override var isFlipped: Bool {
        true
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            cancelDrag()
        } else {
            invalidateCursorRects()
        }
    }

    override func layout() {
        super.layout()
        invalidateCursorRects()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        badgeHitRect.contains(point) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let nextTrackingArea = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .enabledDuringMouseDrag],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(nextTrackingArea)
        trackingArea = nextTrackingArea
        invalidateCursorRects()
    }

    override func mouseExited(with event: NSEvent) {
        guard !isDragging else { return }
        cursorPush.pop()
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(badgeHitRect, cursor: isDragging ? NSCursor.closedHand : NSCursor.pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        guard badgeHitRect.contains(convert(event.locationInWindow, from: nil)) else { return }
        window?.makeFirstResponder(self)
        dragStartScreenPoint = NSEvent.mouseLocation
        lastTranslation = .zero
        isDragging = false
        updateCursor()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStartScreenPoint else { return }

        let currentPoint = NSEvent.mouseLocation
        let translation = CGSize(
            width: currentPoint.x - dragStartScreenPoint.x,
            height: dragStartScreenPoint.y - currentPoint.y
        )
        lastTranslation = translation
        if !isDragging, hypot(translation.width, translation.height) < dragThreshold {
            return
        }

        isDragging = true
        updateCursor()
        onDragChanged?(translation)
    }

    override func mouseUp(with event: NSEvent) {
        let didDrag = isDragging
        let translation = lastTranslation
        dragStartScreenPoint = nil
        lastTranslation = .zero
        isDragging = false
        cursorPush.pop()
        invalidateCursorRects()

        if didDrag {
            onDragEnded?(translation)
        } else {
            onClick?()
        }
        updateCursor()
    }

    private var badgeHitRect: NSRect {
        let inset = max(0, (min(bounds.width, bounds.height) - badgeSize) / 2)
        return bounds.insetBy(dx: inset, dy: inset)
    }

    private func cancelDrag() {
        dragStartScreenPoint = nil
        lastTranslation = .zero
        isDragging = false
        cursorPush.pop()
        onDragCancelled?()
    }

    private func updateCursor() {
        guard window != nil else {
            cursorPush.pop()
            return
        }

        if isDragging {
            cursorPush.push(NSCursor.closedHand)
        } else if isMouseInsideBadge() {
            cursorPush.push(NSCursor.pointingHand)
        } else {
            cursorPush.pop()
        }
        invalidateCursorRects()
    }

    private func isMouseInsideBadge() -> Bool {
        guard let window else { return false }
        let localPoint = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return badgeHitRect.contains(localPoint)
    }

    private func invalidateCursorRects() {
        window?.invalidateCursorRects(for: self)
    }
}

@MainActor
private final class FloatingSignalDragCursorView: NSView {
    private var trackingArea: NSTrackingArea?
    private var isHovering = false
    private var isPointerDownInside = false
    private var isDragging = false
    private let cursorPush = FloatingSignalCursorPush()
    nonisolated(unsafe) private var mouseMonitor: Any?

    override var isFlipped: Bool {
        true
    }

    override var mouseDownCanMoveWindow: Bool {
        true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUpMonitor()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUpMonitor()
    }

    deinit {
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            isHovering = false
            isPointerDownInside = false
            isDragging = false
            cursorPush.pop()
        }
        invalidateCursorRects()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let nextTrackingArea = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .enabledDuringMouseDrag],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(nextTrackingArea)
        trackingArea = nextTrackingArea
        invalidateCursorRects()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        invalidateCursorRects()
        updateCursor()
    }

    override func mouseExited(with event: NSEvent) {
        guard !isDragging else { return }
        isHovering = false
        invalidateCursorRects()
        cursorPush.pop()
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if isDragging {
            addCursorRect(bounds, cursor: NSCursor.closedHand)
        }
    }

    private func setUpMonitor() {
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self else { return event }
            let eventTargetsDragView = self.eventTargetsDragView(event)
            guard eventTargetsDragView || self.isPointerDownInside || self.isDragging else { return event }

            switch event.type {
            case .leftMouseDown:
                self.isHovering = eventTargetsDragView
                self.isPointerDownInside = eventTargetsDragView
                self.isDragging = false
            case .leftMouseDragged:
                guard self.isPointerDownInside || self.isDragging else { return event }
                self.isDragging = true
            case .leftMouseUp:
                self.isPointerDownInside = false
                self.isDragging = false
                self.isHovering = self.contains(event)
            default:
                break
            }
            self.invalidateCursorRects()
            self.updateCursor()
            return event
        }
    }

    private func contains(_ event: NSEvent) -> Bool {
        guard event.window === window else { return false }
        let localPoint = convert(event.locationInWindow, from: nil)
        return bounds.contains(localPoint)
    }

    private func eventTargetsDragView(_ event: NSEvent) -> Bool {
        guard let window,
              event.window === window,
              let contentView = window.contentView
        else {
            return false
        }

        let contentPoint = contentView.convert(event.locationInWindow, from: nil)
        guard let hitView = contentView.hitTest(contentPoint) else {
            return false
        }
        return hitView === self || hitView.isDescendant(of: self)
    }

    private func updateCursor() {
        guard isDragging else {
            cursorPush.pop()
            return
        }
        cursorPush.push(NSCursor.closedHand)
    }

    private func invalidateCursorRects() {
        window?.invalidateCursorRects(for: self)
    }
}

private final class FloatingSignalResizeHandleView: NSView {
    var handleSize: CGFloat = 18 {
        didSet {
            needsLayout = true
            invalidateCursorRects()
        }
    }
    var onHoverChanged: ((Bool) -> Void)?
    var onDragChanged: ((CGSize) -> Void)?
    var onDragEnded: (() -> Void)?

    private var trackingArea: NSTrackingArea?
    private var dragStartScreenPoint: NSPoint?
    private var isHovering = false
    private var isDragging = false
    private let cursorPush = FloatingSignalCursorPush()
    private let handleContainer = NSView()
    private let imageView = NSImageView()

    override var isFlipped: Bool {
        false
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUpHandle()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUpHandle()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            dragStartScreenPoint = nil
            isDragging = false
            isHovering = false
            cursorPush.pop()
            updateHandleVisibility()
            onHoverChanged?(false)
        } else {
            invalidateCursorRects()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        resizeHandleHitRect.contains(point) ? self : nil
    }

    override func layout() {
        super.layout()

        handleContainer.frame = NSRect(
            x: bounds.maxX - handleSize,
            y: 0,
            width: handleSize,
            height: handleSize
        )
        imageView.frame = handleContainer.bounds.insetBy(dx: 3.5, dy: 3.5)
        invalidateCursorRects()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let nextTrackingArea = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .enabledDuringMouseDrag],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(nextTrackingArea)
        trackingArea = nextTrackingArea
        invalidateCursorRects()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        updateHandleVisibility()
        setResizeCursor()
        invalidateCursorRects()
        onHoverChanged?(isHovering)
    }

    override func mouseMoved(with event: NSEvent) {
        updateHoverAndCursor()
    }

    override func mouseExited(with event: NSEvent) {
        guard dragStartScreenPoint == nil else { return }
        isHovering = false
        updateHandleVisibility()
        invalidateCursorRects()
        cursorPush.pop()
        onHoverChanged?(false)
    }

    override func cursorUpdate(with event: NSEvent) {
        updateHoverAndCursor()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(resizeHandleHitRect, cursor: FloatingSignalCursor.diagonalResize())
    }

    override func mouseDown(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)
        guard resizeHandleHitRect.contains(localPoint) else { return }
        window?.makeFirstResponder(self)
        dragStartScreenPoint = NSEvent.mouseLocation
        isDragging = true
        isHovering = true
        updateHandleVisibility()
        setResizeCursor()
        invalidateCursorRects()
        onHoverChanged?(true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStartScreenPoint else { return }

        let currentPoint = NSEvent.mouseLocation
        let translation = CGSize(
            width: currentPoint.x - dragStartScreenPoint.x,
            height: dragStartScreenPoint.y - currentPoint.y
        )
        setResizeCursor()
        onDragChanged?(translation)
    }

    override func mouseUp(with event: NSEvent) {
        dragStartScreenPoint = nil
        isDragging = false
        cursorPush.pop()
        onDragEnded?()
        let currentPoint = convert(event.locationInWindow, from: nil)
        isHovering = resizeHandleHitRect.contains(currentPoint)
        updateHandleVisibility()
        invalidateCursorRects()
        if isMouseInsideResizeHandle() {
            setResizeCursor()
        }
        onHoverChanged?(isHovering)
    }

    private func setUpHandle() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        handleContainer.wantsLayer = true
        handleContainer.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.86).cgColor
        handleContainer.layer?.cornerRadius = 5
        handleContainer.layer?.shadowColor = NSColor.black.withAlphaComponent(0.28).cgColor
        handleContainer.layer?.shadowRadius = 3
        handleContainer.layer?.shadowOffset = CGSize(width: 0, height: -1)
        handleContainer.layer?.shadowOpacity = 1

        let image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .bold))
        imageView.image = image
        imageView.contentTintColor = .white
        imageView.imageScaling = .scaleProportionallyDown

        handleContainer.addSubview(imageView)
        addSubview(handleContainer)
        updateHandleVisibility()
    }

    private func updateHandleVisibility() {
        handleContainer.isHidden = !(isHovering || isDragging)
    }

    private var resizeHandleHitRect: NSRect {
        handleContainer.frame.insetBy(dx: -5, dy: -5)
    }

    private func updateHoverAndCursor() {
        let nextIsHovering = isMouseInsideTarget()
        if isHovering != nextIsHovering {
            isHovering = nextIsHovering
            updateHandleVisibility()
            invalidateCursorRects()
            onHoverChanged?(nextIsHovering)
        }
        setResizeCursor()
    }

    private func isMouseInsideTarget() -> Bool {
        guard let window else { return false }
        let localPoint = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return resizeHandleHitRect.contains(localPoint)
    }

    private func isMouseInsideResizeHandle() -> Bool {
        guard let window else { return false }
        let localPoint = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return resizeHandleHitRect.contains(localPoint)
    }

    private func setResizeCursor() {
        let cursor = FloatingSignalCursor.diagonalResize()
        if isDragging || isMouseInsideResizeHandle() {
            cursorPush.push(cursor)
        } else {
            cursorPush.pop()
        }
    }

    private func invalidateCursorRects() {
        window?.invalidateCursorRects(for: self)
    }
}

private enum FloatingSignalCursor {
    static func diagonalResize() -> NSCursor {
        nativeCursor(named: "_windowResizeNorthWestSouthEastCursor") ?? NSCursor.resizeLeftRight
    }

    private static func nativeCursor(named selectorName: String) -> NSCursor? {
        let selector = NSSelectorFromString(selectorName)
        guard NSCursor.responds(to: selector),
              let cursor = NSCursor.perform(selector)?.takeUnretainedValue() as? NSCursor
        else {
            return nil
        }
        return cursor
    }
}

private struct FloatingSignalInfoPanelAnchor: NSViewRepresentable {
    @Binding var isPresented: Bool
    @ObservedObject var model: MenuBarStatusModel

    func makeCoordinator() -> Coordinator {
        Coordinator(isPresented: $isPresented)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.postsFrameChangedNotifications = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.isPresented = $isPresented
        context.coordinator.update(isPresented: isPresented, model: model, anchorView: nsView)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.close()
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        var isPresented: Binding<Bool>
        private var panel: NSPanel?
        private var hostingController: NSHostingController<FloatingSignalInfoPopoverView>?
        private var mouseMonitor: Any?
        private weak var anchorView: NSView?

        init(isPresented: Binding<Bool>) {
            self.isPresented = isPresented
        }

        func update(isPresented: Bool, model: MenuBarStatusModel, anchorView: NSView) {
            self.anchorView = anchorView

            guard isPresented, anchorView.window != nil else {
                close()
                return
            }

            let contentView = FloatingSignalInfoPopoverView(model: model)
            if let hostingController {
                hostingController.rootView = contentView
            } else {
                let hostingController = NSHostingController(rootView: contentView)
                hostingController.view.wantsLayer = true
                hostingController.view.layer?.backgroundColor = NSColor.clear.cgColor
                self.hostingController = hostingController
            }

            let panel = ensurePanel()
            if panel.contentViewController == nil {
                panel.contentViewController = hostingController
            }
            position(panel, relativeTo: anchorView)
            installMouseMonitorIfNeeded()
            panel.orderFrontRegardless()
        }

        func close() {
            panel?.orderOut(nil)
            panel?.contentViewController = nil
            panel = nil
            hostingController = nil
            removeMouseMonitor()
        }

        func windowWillClose(_ notification: Notification) {
            isPresented.wrappedValue = false
            close()
        }

        private func ensurePanel() -> NSPanel {
            if let panel {
                return panel
            }

            let panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: NSSize(width: 250, height: 64)),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.title = "Floating Signal Info"
            panel.isReleasedWhenClosed = false
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.delegate = self
            self.panel = panel
            return panel
        }

        private func position(_ panel: NSPanel, relativeTo anchorView: NSView) {
            guard let anchorWindow = anchorView.window,
                  let hostingView = hostingController?.view
            else {
                return
            }

            hostingView.layoutSubtreeIfNeeded()
            let fittingSize = hostingView.fittingSize
            let size = NSSize(
                width: max(250, fittingSize.width),
                height: max(44, fittingSize.height)
            )
            panel.setContentSize(size)

            let anchorBounds = anchorView.bounds.isEmpty
                ? NSRect(origin: .zero, size: NSSize(width: FloatingSignalPanelLayout.badgeSize(for: 1), height: FloatingSignalPanelLayout.badgeSize(for: 1)))
                : anchorView.bounds
            let anchorInWindow = anchorView.convert(anchorBounds, to: nil)
            let anchorOnScreen = anchorWindow.convertToScreen(anchorInWindow)
            let desiredOrigin = NSPoint(
                x: anchorOnScreen.maxX - size.width + 4,
                y: anchorOnScreen.maxY - 2
            )

            panel.setFrame(NSRect(origin: clamped(desiredOrigin, size: size), size: size), display: true, animate: false)
        }

        private func clamped(_ origin: NSPoint, size: NSSize) -> NSPoint {
            let visibleFrame = NSScreen.screens
                .map(\.visibleFrame)
                .first { $0.insetBy(dx: -8, dy: -8).contains(NSRect(origin: origin, size: size)) }
                ?? NSScreen.main?.visibleFrame
                ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

            return NSPoint(
                x: min(max(origin.x, visibleFrame.minX + 8), visibleFrame.maxX - size.width - 8),
                y: min(max(origin.y, visibleFrame.minY + 8), visibleFrame.maxY - size.height - 8)
            )
        }

        private func installMouseMonitorIfNeeded() {
            guard mouseMonitor == nil else { return }

            mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self else { return event }
                guard !self.contains(event, in: self.panel?.contentView),
                      !self.contains(event, in: self.anchorView)
                else {
                    return event
                }

                self.isPresented.wrappedValue = false
                self.close()
                return event
            }
        }

        private func removeMouseMonitor() {
            if let mouseMonitor {
                NSEvent.removeMonitor(mouseMonitor)
            }
            mouseMonitor = nil
        }

        private func contains(_ event: NSEvent, in view: NSView?) -> Bool {
            guard let view, event.window === view.window else { return false }
            return view.bounds.contains(view.convert(event.locationInWindow, from: nil))
        }
    }
}

private struct FloatingSignalQuotaPanelAnchor: NSViewRepresentable {
    @Binding var isPresented: Bool
    @ObservedObject var model: MenuBarStatusModel
    let quota: AgentQuotaStatus

    func makeCoordinator() -> Coordinator {
        Coordinator(isPresented: $isPresented)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.postsFrameChangedNotifications = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.isPresented = $isPresented
        context.coordinator.update(isPresented: isPresented, model: model, quota: quota, anchorView: nsView)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.close()
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        var isPresented: Binding<Bool>
        private var panel: NSPanel?
        private var hostingController: NSHostingController<FloatingSignalQuotaPopoverView>?
        private var mouseMonitor: Any?
        private weak var anchorView: NSView?

        init(isPresented: Binding<Bool>) {
            self.isPresented = isPresented
        }

        func update(isPresented: Bool, model: MenuBarStatusModel, quota: AgentQuotaStatus, anchorView: NSView) {
            self.anchorView = anchorView

            guard isPresented, anchorView.window != nil else {
                close()
                return
            }

            let contentView = FloatingSignalQuotaPopoverView(model: model, quota: quota)
            if let hostingController {
                hostingController.rootView = contentView
            } else {
                let hostingController = NSHostingController(rootView: contentView)
                hostingController.view.wantsLayer = true
                hostingController.view.layer?.backgroundColor = NSColor.clear.cgColor
                self.hostingController = hostingController
            }

            let panel = ensurePanel()
            if panel.contentViewController == nil {
                panel.contentViewController = hostingController
            }
            position(panel, relativeTo: anchorView)
            installMouseMonitorIfNeeded()
            panel.orderFrontRegardless()
        }

        func close() {
            panel?.orderOut(nil)
            panel?.contentViewController = nil
            panel = nil
            hostingController = nil
            removeMouseMonitor()
        }

        func windowWillClose(_ notification: Notification) {
            isPresented.wrappedValue = false
            close()
        }

        private func ensurePanel() -> NSPanel {
            if let panel {
                return panel
            }

            let panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: NSSize(width: 250, height: 96)),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.title = "Floating Signal Quota"
            panel.isReleasedWhenClosed = false
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.delegate = self
            self.panel = panel
            return panel
        }

        private func position(_ panel: NSPanel, relativeTo anchorView: NSView) {
            guard let anchorWindow = anchorView.window,
                  let hostingView = hostingController?.view
            else {
                return
            }

            hostingView.layoutSubtreeIfNeeded()
            let fittingSize = hostingView.fittingSize
            let size = NSSize(
                width: max(250, fittingSize.width),
                height: max(44, fittingSize.height)
            )
            panel.setContentSize(size)

            let anchorBounds = anchorView.bounds.isEmpty
                ? NSRect(origin: .zero, size: NSSize(width: FloatingSignalPanelLayout.badgeSize(for: 1), height: FloatingSignalPanelLayout.badgeSize(for: 1)))
                : anchorView.bounds
            let anchorInWindow = anchorView.convert(anchorBounds, to: nil)
            let anchorOnScreen = anchorWindow.convertToScreen(anchorInWindow)
            let desiredOrigin = NSPoint(
                x: anchorOnScreen.maxX - size.width + 4,
                y: anchorOnScreen.maxY - 2
            )

            panel.setFrame(NSRect(origin: clamped(desiredOrigin, size: size), size: size), display: true, animate: false)
        }

        private func clamped(_ origin: NSPoint, size: NSSize) -> NSPoint {
            let visibleFrame = NSScreen.screens
                .map(\.visibleFrame)
                .first { $0.insetBy(dx: -8, dy: -8).contains(NSRect(origin: origin, size: size)) }
                ?? NSScreen.main?.visibleFrame
                ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

            return NSPoint(
                x: min(max(origin.x, visibleFrame.minX + 8), visibleFrame.maxX - size.width - 8),
                y: min(max(origin.y, visibleFrame.minY + 8), visibleFrame.maxY - size.height - 8)
            )
        }

        private func installMouseMonitorIfNeeded() {
            guard mouseMonitor == nil else { return }

            mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self else { return event }
                guard !self.contains(event, in: self.panel?.contentView),
                      !self.contains(event, in: self.anchorView)
                else {
                    return event
                }

                self.isPresented.wrappedValue = false
                self.close()
                return event
            }
        }

        private func removeMouseMonitor() {
            if let mouseMonitor {
                NSEvent.removeMonitor(mouseMonitor)
            }
            mouseMonitor = nil
        }

        private func contains(_ event: NSEvent, in view: NSView?) -> Bool {
            guard let view, event.window === view.window else { return false }
            return view.bounds.contains(view.convert(event.locationInWindow, from: nil))
        }
    }
}

private struct FloatingSignalTokenPanelAnchor: NSViewRepresentable {
    @Binding var isPresented: Bool
    @ObservedObject var model: MenuBarStatusModel

    func makeCoordinator() -> Coordinator {
        Coordinator(isPresented: $isPresented)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.postsFrameChangedNotifications = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.isPresented = $isPresented
        context.coordinator.update(isPresented: isPresented, model: model, anchorView: nsView)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.close()
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        var isPresented: Binding<Bool>
        private var panel: NSPanel?
        private var hostingController: NSHostingController<FloatingSignalTokenPopoverView>?
        private var mouseMonitor: Any?
        private weak var anchorView: NSView?

        init(isPresented: Binding<Bool>) {
            self.isPresented = isPresented
        }

        func update(isPresented: Bool, model: MenuBarStatusModel, anchorView: NSView) {
            self.anchorView = anchorView

            guard isPresented, anchorView.window != nil else {
                close()
                return
            }

            let contentView = FloatingSignalTokenPopoverView(model: model)
            if let hostingController {
                hostingController.rootView = contentView
            } else {
                let hostingController = NSHostingController(rootView: contentView)
                hostingController.view.wantsLayer = true
                hostingController.view.layer?.backgroundColor = NSColor.clear.cgColor
                self.hostingController = hostingController
            }

            let panel = ensurePanel()
            if panel.contentViewController == nil {
                panel.contentViewController = hostingController
            }
            position(panel, relativeTo: anchorView)
            installMouseMonitorIfNeeded()
            panel.orderFrontRegardless()
        }

        func close() {
            panel?.orderOut(nil)
            panel?.contentViewController = nil
            panel = nil
            hostingController = nil
            removeMouseMonitor()
        }

        func windowWillClose(_ notification: Notification) {
            isPresented.wrappedValue = false
            close()
        }

        private func ensurePanel() -> NSPanel {
            if let panel {
                return panel
            }

            let panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: NSSize(width: 250, height: 96)),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.title = "Floating Signal Token Usage"
            panel.isReleasedWhenClosed = false
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.delegate = self
            self.panel = panel
            return panel
        }

        private func position(_ panel: NSPanel, relativeTo anchorView: NSView) {
            guard let anchorWindow = anchorView.window,
                  let hostingView = hostingController?.view
            else {
                return
            }

            hostingView.layoutSubtreeIfNeeded()
            let fittingSize = hostingView.fittingSize
            let size = NSSize(
                width: max(250, fittingSize.width),
                height: max(44, fittingSize.height)
            )
            panel.setContentSize(size)

            let anchorBounds = anchorView.bounds.isEmpty
                ? NSRect(origin: .zero, size: NSSize(width: FloatingSignalPanelLayout.badgeSize(for: 1), height: FloatingSignalPanelLayout.badgeSize(for: 1)))
                : anchorView.bounds
            let anchorInWindow = anchorView.convert(anchorBounds, to: nil)
            let anchorOnScreen = anchorWindow.convertToScreen(anchorInWindow)
            let desiredOrigin = NSPoint(
                x: anchorOnScreen.maxX - size.width + 4,
                y: anchorOnScreen.maxY - 2
            )

            panel.setFrame(NSRect(origin: clamped(desiredOrigin, size: size), size: size), display: true, animate: false)
        }

        private func clamped(_ origin: NSPoint, size: NSSize) -> NSPoint {
            let visibleFrame = NSScreen.screens
                .map(\.visibleFrame)
                .first { $0.insetBy(dx: -8, dy: -8).contains(NSRect(origin: origin, size: size)) }
                ?? NSScreen.main?.visibleFrame
                ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

            return NSPoint(
                x: min(max(origin.x, visibleFrame.minX + 8), visibleFrame.maxX - size.width - 8),
                y: min(max(origin.y, visibleFrame.minY + 8), visibleFrame.maxY - size.height - 8)
            )
        }

        private func installMouseMonitorIfNeeded() {
            guard mouseMonitor == nil else { return }

            mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self else { return event }
                guard !self.contains(event, in: self.panel?.contentView),
                      !self.contains(event, in: self.anchorView)
                else {
                    return event
                }

                self.isPresented.wrappedValue = false
                self.close()
                return event
            }
        }

        private func removeMouseMonitor() {
            if let mouseMonitor {
                NSEvent.removeMonitor(mouseMonitor)
            }
            mouseMonitor = nil
        }

        private func contains(_ event: NSEvent, in view: NSView?) -> Bool {
            guard let view, event.window === view.window else { return false }
            return view.bounds.contains(view.convert(event.locationInWindow, from: nil))
        }
    }
}

private struct FloatingSignalQuotaPopoverView: View {
    @ObservedObject var model: MenuBarStatusModel
    let quota: AgentQuotaStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Codex")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)

            quotaRow(
                quota: quota,
                badgeWindow: .fiveHours
            )

            Divider()
                .overlay(Color.white.opacity(0.12))

            quotaRow(
                quota: quota,
                badgeWindow: .weekly
            )
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(width: 250, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.black.opacity(0.92))
        )
        .padding(8)
    }

    private func quotaRow(
        quota: AgentQuotaStatus,
        badgeWindow: FloatingSignalQuotaBadgeWindow
    ) -> some View {
        let window = model.quotaWindow(for: badgeWindow, quota: quota)

        return Button {
            model.setFloatingSignalQuotaBadgeWindow(badgeWindow)
        } label: {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.quotaTitleLine(for: badgeWindow, quota: quota))
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Text(model.quotaResetText(for: window, badgeWindow: badgeWindow))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 8)

                selectionCircle(isSelected: model.floatingSignalQuotaBadgeWindow == badgeWindow)
            }
            .frame(maxWidth: .infinity, minHeight: 31, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
    }

    private func selectionCircle(isSelected: Bool) -> some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(isSelected ? 0.95 : 0.48), lineWidth: 1.4)

            if isSelected {
                Circle()
                    .fill(Color.white)
                    .frame(width: 6, height: 6)
            }
        }
        .frame(width: 14, height: 14)
        .accessibilityHidden(true)
    }

}

private struct FloatingSignalTokenPopoverView: View {
    @ObservedObject var model: MenuBarStatusModel

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text("Codex")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if model.isTokenActivityLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.58)
                        .tint(.white.opacity(0.8))
                }
            }

            tokenRow(.today)

            Divider()
                .overlay(Color.white.opacity(0.12))

            tokenRow(.last30Days)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(width: 250, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.black.opacity(0.92))
        )
        .padding(8)
        .onAppear {
            model.refreshTokenActivityIfNeeded(force: model.tokenActivityDays.isEmpty)
        }
    }

    private func tokenRow(_ tokenWindow: FloatingSignalTokenBadgeWindow) -> some View {
        let tokens = model.tokenActivityTotal(for: tokenWindow)
        let cost = model.tokenActivityEstimatedCost(for: tokenWindow)

        return Button {
            model.setFloatingSignalTokenBadgeWindow(tokenWindow)
        } label: {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.tokenUsageTitleLine(for: tokenWindow, tokens: tokens))
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Text(model.tokenUsageCostText(cost))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 8)

                selectionCircle(isSelected: model.floatingSignalTokenBadgeWindow == tokenWindow)
            }
            .frame(maxWidth: .infinity, minHeight: 31, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
    }

    private func selectionCircle(isSelected: Bool) -> some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(isSelected ? 0.95 : 0.48), lineWidth: 1.4)

            if isSelected {
                Circle()
                    .fill(Color.white)
                    .frame(width: 6, height: 6)
            }
        }
        .frame(width: 14, height: 14)
        .accessibilityHidden(true)
    }
}

private struct FloatingSignalInfoPopoverView: View {
    @ObservedObject var model: MenuBarStatusModel

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if visibleSessions.isEmpty {
                infoCard(
                    title: model.text("暂无运行中的 Agent", "No active agent sessions"),
                    subtitle: model.summary(for: model.lightSnapshot.aggregate),
                    signal: model.lightSnapshot.aggregate,
                    timestamp: model.lightSnapshot.updatedAt
                )
            } else {
                ForEach(visibleSessions) { session in
                    infoCard(
                        title: model.activitySessionTitle(for: session),
                        subtitle: model.activitySessionStatusSubtitle(for: session),
                        signal: session.signal,
                        timestamp: session.updatedAt
                    )
                }
            }
        }
        .padding(8)
        .frame(width: 250, alignment: .leading)
    }

    private var visibleSessions: [SessionStatus] {
        ActivityPresentation.visibleRunningSessions(from: model.activitySnapshot)
    }

    private func infoCard(
        title: String,
        subtitle: String,
        signal: AgentSignal,
        timestamp: Date?
    ) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Circle()
                .fill(floatingInfoColor(for: signal))
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(subtitleLine(subtitle: subtitle, timestamp: timestamp))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 4)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.black.opacity(0.92))
        )
    }

    private func subtitleLine(subtitle: String, timestamp: Date?) -> String {
        guard let timestamp else { return subtitle }
        return "\(subtitle) · \(timestamp.formatted(date: .omitted, time: .shortened))"
    }
}

private func floatingInfoColor(for signal: AgentSignal) -> Color {
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

private enum FloatingSignalSoundCue {
    case completion
    case waiting
    case alert
}

private enum FloatingSignalSoundAsset {
    case resource(String)
    case defaultPulse
}

struct FloatingSignalSoundResourceResolver {
    static let supportedExtensions = ["m4a", "wav"]

    private let candidateDirectories: [URL]
    private let fileManager: FileManager

    init(
        candidateDirectories: [URL] = Self.defaultCandidateDirectories(),
        fileManager: FileManager = .default
    ) {
        self.candidateDirectories = Self.uniqueExistingDirectories(candidateDirectories, fileManager: fileManager)
        self.fileManager = fileManager
    }

    func url(named name: String) -> URL? {
        for ext in Self.supportedExtensions {
            let fileName = "\(name).\(ext)"
            for directory in candidateDirectories {
                let url = directory.appendingPathComponent(fileName)
                if fileManager.isReadableFile(atPath: url.path) {
                    return url
                }
            }
        }
        return nil
    }

    private static func defaultCandidateDirectories(
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> [URL] {
        var directories: [URL] = []

        append(bundle.resourceURL, to: &directories)
        append(bundle.bundleURL.appendingPathComponent("Contents").appendingPathComponent("Resources"), to: &directories)

        if let executableDirectory = bundle.executableURL?.deletingLastPathComponent() {
            append(executableDirectory, to: &directories)
            append(executableDirectory.deletingLastPathComponent().appendingPathComponent("Resources"), to: &directories)
            appendResourceBundle(named: "AgentSignalLight_AgentSignalLight", parent: executableDirectory, to: &directories)
        }

        appendResourceBundle(named: "AgentSignalLight_AgentSignalLight", parent: bundle.bundleURL, to: &directories)
        if let resourceURL = bundle.resourceURL {
            appendResourceBundle(named: "AgentSignalLight_AgentSignalLight", parent: resourceURL, to: &directories)
        }

        return uniqueExistingDirectories(directories, fileManager: fileManager)
    }

    private static func appendResourceBundle(named name: String, parent: URL, to directories: inout [URL]) {
        let bundleURL = parent.appendingPathComponent("\(name).bundle")
        append(Bundle(url: bundleURL)?.resourceURL ?? bundleURL, to: &directories)
    }

    private static func append(_ url: URL?, to directories: inout [URL]) {
        guard let url else { return }
        directories.append(url.standardizedFileURL)
    }

    private static func uniqueExistingDirectories(_ directories: [URL], fileManager: FileManager) -> [URL] {
        var seen = Set<String>()
        return directories.filter { url in
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return false
            }
            return seen.insert(url.standardizedFileURL.path).inserted
        }
    }
}

@MainActor
private final class FloatingSignalSoundPlayer: NSObject, AVAudioPlayerDelegate {
    private var players: [UUID: AVAudioPlayer] = [:]
    private var previewToken: UUID?
    private let resourceResolver = FloatingSignalSoundResourceResolver()
    private static let wavData = makeCrossingPulseWAV()

    func play(asset: FloatingSignalSoundAsset, level: FloatingSignalSoundLevel) {
        do {
            let player = try makePlayer(asset: asset)
            player.delegate = self
            player.volume = level.volume
            player.prepareToPlay()
            let token = retain(player)
            let playerID = ObjectIdentifier(player)
            if !player.play() {
                release(token, matching: playerID)
            }
        } catch {
            NSSound.beep()
        }
    }

    func preview(asset: FloatingSignalSoundAsset, level: FloatingSignalSoundLevel) {
        stopPreview()

        do {
            let player = try makePlayer(asset: asset)
            player.delegate = self
            player.volume = level.volume
            player.prepareToPlay()
            let token = retain(player)
            let playerID = ObjectIdentifier(player)
            previewToken = token
            if !player.play() {
                release(token, matching: playerID)
            }
        } catch {
            NSSound.beep()
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        releaseOnMain(ObjectIdentifier(player))
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        releaseOnMain(ObjectIdentifier(player))
    }

    private func retain(_ player: AVAudioPlayer) -> UUID {
        let token = UUID()
        let playerID = ObjectIdentifier(player)
        players[token] = player

        let releaseDelay = max(player.duration + 2.0, 3.0)
        let releaseNanoseconds = UInt64(releaseDelay * 1_000_000_000)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: releaseNanoseconds)
            self?.release(token, matching: playerID)
        }
        return token
    }

    nonisolated private func releaseOnMain(_ playerID: ObjectIdentifier) {
        Task { @MainActor [weak self] in
            self?.release(playerID)
        }
    }

    private func release(_ playerID: ObjectIdentifier) {
        guard let token = players.first(where: { ObjectIdentifier($0.value) == playerID })?.key else {
            return
        }
        release(token, matching: playerID)
    }

    private func release(_ token: UUID, matching playerID: ObjectIdentifier) {
        guard let player = players[token], ObjectIdentifier(player) == playerID else {
            return
        }
        if previewToken == token {
            previewToken = nil
        }
        player.delegate = nil
        players.removeValue(forKey: token)
    }

    private func stopPreview() {
        guard let token = previewToken, let player = players[token] else {
            previewToken = nil
            return
        }

        player.stop()
        player.delegate = nil
        players.removeValue(forKey: token)
        previewToken = nil
    }

    private func makePlayer(asset: FloatingSignalSoundAsset) throws -> AVAudioPlayer {
        switch asset {
        case .resource(let resourceName):
            if let url = resourceResolver.url(named: resourceName) {
                return try AVAudioPlayer(contentsOf: url)
            }
            return try AVAudioPlayer(data: Self.wavData)
        case .defaultPulse:
            return try AVAudioPlayer(data: Self.wavData)
        }
    }

    private static func makeCrossingPulseWAV() -> Data {
        let sampleRate = 44_100
        let duration = 0.72
        let totalSamples = Int(Double(sampleRate) * duration)
        let pulseInterval = 0.095
        let pulseDuration = 0.036
        var samples = [Int16]()
        samples.reserveCapacity(totalSamples)

        for sampleIndex in 0..<totalSamples {
            let time = Double(sampleIndex) / Double(sampleRate)
            let pulsePhase = time.truncatingRemainder(dividingBy: pulseInterval)
            guard pulsePhase < pulseDuration else {
                samples.append(0)
                continue
            }

            let pulseIndex = Int(time / pulseInterval)
            let frequency = pulseIndex.isMultiple(of: 2) ? 1_760.0 : 1_185.0
            let attack = min(pulsePhase / 0.004, 1)
            let release = min((pulseDuration - pulsePhase) / 0.007, 1)
            let envelope = max(0, min(attack, release))
            let fundamental = sin(2 * Double.pi * frequency * time)
            let click = sin(2 * Double.pi * frequency * 2.15 * time) * 0.24
            let value = (fundamental + click) * envelope * 0.66
            samples.append(Int16(max(-1, min(1, value)) * Double(Int16.max)))
        }

        return wavData(samples: samples, sampleRate: sampleRate)
    }

    private static func wavData(samples: [Int16], sampleRate: Int) -> Data {
        var data = Data()
        let byteRate = UInt32(sampleRate * 2)
        let dataSize = UInt32(samples.count * 2)

        appendASCII("RIFF", to: &data)
        appendLittleEndian(UInt32(36) + dataSize, to: &data)
        appendASCII("WAVE", to: &data)
        appendASCII("fmt ", to: &data)
        appendLittleEndian(UInt32(16), to: &data)
        appendLittleEndian(UInt16(1), to: &data)
        appendLittleEndian(UInt16(1), to: &data)
        appendLittleEndian(UInt32(sampleRate), to: &data)
        appendLittleEndian(byteRate, to: &data)
        appendLittleEndian(UInt16(2), to: &data)
        appendLittleEndian(UInt16(16), to: &data)
        appendASCII("data", to: &data)
        appendLittleEndian(dataSize, to: &data)

        for sample in samples {
            appendLittleEndian(UInt16(bitPattern: sample), to: &data)
        }

        return data
    }

    private static func appendASCII(_ value: String, to data: inout Data) {
        data.append(contentsOf: value.utf8)
    }

    private static func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndianValue = value.littleEndian
        withUnsafeBytes(of: &littleEndianValue) { bytes in
            data.append(contentsOf: bytes)
        }
    }
}

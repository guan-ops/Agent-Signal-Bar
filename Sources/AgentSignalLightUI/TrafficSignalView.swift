import AgentSignalLightCore
import SwiftUI

public enum TrafficSignalLayout: String, CaseIterable {
    case horizontal
    case vertical

    public var displayName: String {
        switch self {
        case .horizontal:
            return "横向"
        case .vertical:
            return "竖向"
        }
    }
}

public enum TrafficSignalStyle: String, CaseIterable {
    case trafficLight
    case macOS

    public var displayName: String {
        switch self {
        case .trafficLight:
            return "经典灯牌"
        case .macOS:
            return "极简圆点"
        }
    }
}

public enum TrafficSignalSize {
    case menuBar
    case panel

    func diameter(
        for layout: TrafficSignalLayout,
        style: TrafficSignalStyle,
        macOSHorizontalUsesTrafficLightSize: Bool,
        trafficLightVerticalUsesMacOSSize: Bool
    ) -> CGFloat {
        switch self {
        case .menuBar:
            return SignalIconGeometry.metrics(
                layout: layout,
                style: style,
                macOSHorizontalUsesTrafficLightSize: macOSHorizontalUsesTrafficLightSize,
                trafficLightVerticalUsesMacOSSize: trafficLightVerticalUsesMacOSSize
            ).lampDiameter
        case .panel:
            if style == .macOS && layout == .horizontal && macOSHorizontalUsesTrafficLightSize {
                return 16
            }
            if style == .trafficLight && layout == .vertical && trafficLightVerticalUsesMacOSSize {
                return 16
            }
            switch style {
            case .trafficLight:
                return 16
            case .macOS:
                return 12
            }
        }
    }

    func spacing(
        for layout: TrafficSignalLayout,
        style: TrafficSignalStyle,
        macOSHorizontalUsesTrafficLightSize: Bool,
        trafficLightVerticalUsesMacOSSize: Bool
    ) -> CGFloat {
        switch self {
        case .menuBar:
            return SignalIconGeometry.metrics(
                layout: layout,
                style: style,
                macOSHorizontalUsesTrafficLightSize: macOSHorizontalUsesTrafficLightSize,
                trafficLightVerticalUsesMacOSSize: trafficLightVerticalUsesMacOSSize
            ).lampSpacing
        case .panel:
            if style == .macOS && layout == .horizontal && macOSHorizontalUsesTrafficLightSize {
                return 8
            }
            if style == .trafficLight && layout == .vertical && trafficLightVerticalUsesMacOSSize {
                return 3
            }
            switch style {
            case .trafficLight:
                return layout == .vertical ? 5 : 8
            case .macOS:
                return layout == .vertical ? 4 : 6
            }
        }
    }

    func padding(
        for layout: TrafficSignalLayout,
        style: TrafficSignalStyle,
        macOSHorizontalUsesTrafficLightSize: Bool,
        trafficLightVerticalUsesMacOSSize: Bool
    ) -> EdgeInsets {
        switch (self, layout, style) {
        case (.menuBar, .horizontal, _):
            let metrics = SignalIconGeometry.metrics(
                layout: layout,
                style: style,
                macOSHorizontalUsesTrafficLightSize: macOSHorizontalUsesTrafficLightSize,
                trafficLightVerticalUsesMacOSSize: trafficLightVerticalUsesMacOSSize
            )
            let horizontalInset = (metrics.iconSize.width - metrics.horizontalLampSpan) / 2
            let verticalInset = (metrics.iconSize.height - metrics.lampDiameter) / 2
            return EdgeInsets(
                top: verticalInset,
                leading: horizontalInset,
                bottom: verticalInset,
                trailing: horizontalInset
            )
        case (.menuBar, .vertical, _):
            let metrics = SignalIconGeometry.metrics(
                layout: layout,
                style: style,
                macOSHorizontalUsesTrafficLightSize: macOSHorizontalUsesTrafficLightSize,
                trafficLightVerticalUsesMacOSSize: trafficLightVerticalUsesMacOSSize
            )
            let horizontalInset = (metrics.iconSize.width - metrics.lampDiameter) / 2
            let verticalInset = (metrics.iconSize.height - metrics.verticalLampSpan) / 2
            return EdgeInsets(
                top: verticalInset,
                leading: horizontalInset,
                bottom: verticalInset,
                trailing: horizontalInset
            )
        case (.panel, .horizontal, .macOS) where macOSHorizontalUsesTrafficLightSize:
            return EdgeInsets(top: 6, leading: 7, bottom: 6, trailing: 7)
        case (.panel, .vertical, .trafficLight) where trafficLightVerticalUsesMacOSSize:
            return EdgeInsets(top: 5, leading: 5, bottom: 5, trailing: 5)
        case (.panel, .horizontal, .macOS):
            return EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4)
        case (.panel, .vertical, .macOS):
            return EdgeInsets(top: 3, leading: 4, bottom: 3, trailing: 4)
        case (.panel, .horizontal, _):
            return EdgeInsets(top: 6, leading: 7, bottom: 6, trailing: 7)
        case (.panel, .vertical, _):
            return EdgeInsets(top: 8, leading: 6, bottom: 8, trailing: 6)
        }
    }
}

public struct TrafficSignalView: View {
    let snapshot: SignalSnapshot
    let tick: Int
    let size: TrafficSignalSize
    var layout: TrafficSignalLayout
    var style: TrafficSignalStyle
    var macOSBreathingStrength: MacOSBreathingStrength
    var macOSHorizontalUsesTrafficLightSize: Bool
    var trafficLightVerticalUsesMacOSSize: Bool
    var allLightsOn: Bool
    var usesSystemGrayLights: Bool
    var effectCustomization: SignalEffectCustomization

    public init(
        snapshot: SignalSnapshot,
        tick: Int,
        size: TrafficSignalSize,
        layout: TrafficSignalLayout = .horizontal,
        style: TrafficSignalStyle = .trafficLight,
        macOSBreathingStrength: MacOSBreathingStrength = .maximum,
        macOSHorizontalUsesTrafficLightSize: Bool = false,
        trafficLightVerticalUsesMacOSSize: Bool = false,
        allLightsOn: Bool = false,
        usesSystemGrayLights: Bool = false,
        effectCustomization: SignalEffectCustomization = .default
    ) {
        self.snapshot = snapshot
        self.tick = tick
        self.size = size
        self.layout = layout
        self.style = style
        self.macOSBreathingStrength = macOSBreathingStrength
        self.macOSHorizontalUsesTrafficLightSize = macOSHorizontalUsesTrafficLightSize
        self.trafficLightVerticalUsesMacOSSize = trafficLightVerticalUsesMacOSSize
        self.allLightsOn = allLightsOn
        self.usesSystemGrayLights = usesSystemGrayLights
        self.effectCustomization = effectCustomization
    }

    public var body: some View {
        Group {
            switch layout {
            case .horizontal:
                HStack(spacing: size.spacing(
                    for: layout,
                    style: style,
                    macOSHorizontalUsesTrafficLightSize: macOSHorizontalUsesTrafficLightSize,
                    trafficLightVerticalUsesMacOSSize: trafficLightVerticalUsesMacOSSize
                )) {
                    lamp(.red)
                    lamp(.yellow)
                    lamp(.green)
                }
            case .vertical:
                VStack(spacing: size.spacing(
                    for: layout,
                    style: style,
                    macOSHorizontalUsesTrafficLightSize: macOSHorizontalUsesTrafficLightSize,
                    trafficLightVerticalUsesMacOSSize: trafficLightVerticalUsesMacOSSize
                )) {
                    lamp(.red)
                    lamp(.yellow)
                    lamp(.green)
                }
            }
        }
        .padding(size.padding(
            for: layout,
            style: style,
            macOSHorizontalUsesTrafficLightSize: macOSHorizontalUsesTrafficLightSize,
            trafficLightVerticalUsesMacOSSize: trafficLightVerticalUsesMacOSSize
        ))
        .modifier(TrafficSignalChrome(style: style))
        .frame(
            width: size == .menuBar ? fixedMenuBarWidth(for: layout, style: style) : nil,
            height: size == .menuBar ? fixedMenuBarHeight(for: layout, style: style) : nil
        )
        .fixedSize()
        .accessibilityLabel(snapshot.aggregate.displayName)
    }

    private func lamp(_ color: SignalLampColor) -> some View {
        SignalLampDot(
            color: color,
            signal: snapshot.aggregate,
            tick: tick,
            size: size,
            layout: layout,
            style: style,
            macOSBreathingStrength: macOSBreathingStrength,
            macOSHorizontalUsesTrafficLightSize: macOSHorizontalUsesTrafficLightSize,
            trafficLightVerticalUsesMacOSSize: trafficLightVerticalUsesMacOSSize,
            allLightsOn: allLightsOn,
            usesSystemGrayLights: usesSystemGrayLights,
            effectCustomization: effectCustomization
        )
    }

    private func fixedMenuBarWidth(for layout: TrafficSignalLayout, style: TrafficSignalStyle) -> CGFloat {
        SignalIconGeometry.metrics(
            layout: layout,
            style: style,
            macOSHorizontalUsesTrafficLightSize: macOSHorizontalUsesTrafficLightSize,
            trafficLightVerticalUsesMacOSSize: trafficLightVerticalUsesMacOSSize
        ).iconSize.width
    }

    private func fixedMenuBarHeight(for layout: TrafficSignalLayout, style: TrafficSignalStyle) -> CGFloat {
        SignalIconGeometry.metrics(
            layout: layout,
            style: style,
            macOSHorizontalUsesTrafficLightSize: macOSHorizontalUsesTrafficLightSize,
            trafficLightVerticalUsesMacOSSize: trafficLightVerticalUsesMacOSSize
        ).iconSize.height
    }
}

private struct SignalLampDot: View {
    let color: SignalLampColor
    let signal: AgentSignal
    let tick: Int
    let size: TrafficSignalSize
    let layout: TrafficSignalLayout
    let style: TrafficSignalStyle
    let macOSBreathingStrength: MacOSBreathingStrength
    let macOSHorizontalUsesTrafficLightSize: Bool
    let trafficLightVerticalUsesMacOSSize: Bool
    let allLightsOn: Bool
    let usesSystemGrayLights: Bool
    let effectCustomization: SignalEffectCustomization

    var body: some View {
        let intensity = lampIntensity(for: color)
        let scale = visualLampScale(for: color, intensity: intensity)
        return ZStack {
            Circle()
                .fill(inactiveFill)
                .overlay(
                    Circle()
                        .stroke(baseStrokeColor, lineWidth: size == .menuBar ? 0.8 : 0.5)
                )

            if intensity > 0 {
                Circle()
                    .fill(activeFillColor(for: color))
                    .overlay(
                        Circle()
                            .stroke(activeStrokeColor(for: color), lineWidth: size == .menuBar ? 0.8 : 0.5)
                    )
                    .overlay(alignment: .topLeading) {
                        if intensity > 0.7, style != .macOS {
                            Circle()
                                .fill(.white.opacity(0.38))
                                .frame(width: highlightDiameter, height: highlightDiameter)
                                .offset(x: highlightOffset, y: highlightOffset)
                        }
                    }
                    .scaleEffect(scale)
            }
        }
        .frame(
            width: size.diameter(
                for: layout,
                style: style,
                macOSHorizontalUsesTrafficLightSize: macOSHorizontalUsesTrafficLightSize,
                trafficLightVerticalUsesMacOSSize: trafficLightVerticalUsesMacOSSize
            ),
            height: size.diameter(
                for: layout,
                style: style,
                macOSHorizontalUsesTrafficLightSize: macOSHorizontalUsesTrafficLightSize,
                trafficLightVerticalUsesMacOSSize: trafficLightVerticalUsesMacOSSize
            )
        )
        .shadow(
            color: lampBaseColor(for: color).opacity(shadowOpacity(for: intensity)),
            radius: style == .macOS ? (size == .menuBar ? 1.8 : 3) : (size == .menuBar ? 1.5 : 4)
        )
    }

    private var highlightDiameter: CGFloat {
        max(size.diameter(
            for: layout,
            style: style,
            macOSHorizontalUsesTrafficLightSize: macOSHorizontalUsesTrafficLightSize,
            trafficLightVerticalUsesMacOSSize: trafficLightVerticalUsesMacOSSize
        ) * 0.34, 1.5)
    }

    private var highlightOffset: CGFloat {
        size.diameter(
            for: layout,
            style: style,
            macOSHorizontalUsesTrafficLightSize: macOSHorizontalUsesTrafficLightSize,
            trafficLightVerticalUsesMacOSSize: trafficLightVerticalUsesMacOSSize
        ) * 0.18
    }

    private func lampIntensity(for color: SignalLampColor) -> Double {
        SignalLampAnimation.intensity(
            color,
            signal: signal,
            tick: tick,
            allLightsOn: allLightsOn,
            customization: effectCustomization
        )
    }

    private func lampScale(for color: SignalLampColor) -> Double {
        SignalLampAnimation.scale(
            color,
            signal: signal,
            tick: tick,
            allLightsOn: allLightsOn,
            customization: effectCustomization
        )
    }

    private func visualLampScale(for color: SignalLampColor, intensity: Double) -> Double {
        SignalVisualScale.lampScale(
            baseScale: lampScale(for: color),
            intensity: intensity,
            style: style.visualStyle,
            macOSStrength: macOSBreathingStrength
        )
    }

    private var displayState: DisplayState {
        signal.displayState
    }

    private func activeFillColor(for color: SignalLampColor) -> Color {
        let intensity = lampIntensity(for: color)
        return lampBaseColor(for: color).opacity(intensity)
    }

    private func lampBaseColor(for color: SignalLampColor) -> Color {
        if usesSystemGrayLights {
            return .secondary
        }

        switch color {
        case .green:
            return Color(red: 0.16, green: 0.78, blue: 0.34)
        case .yellow:
            return Color(red: 0.97, green: 0.72, blue: 0.16)
        case .red:
            return Color(red: 0.94, green: 0.20, blue: 0.18)
        }
    }

    private func shadowOpacity(for intensity: Double) -> Double {
        if usesSystemGrayLights {
            return 0
        }

        return intensity * 0.35
    }

    private var inactiveFill: Color {
        if displayState == .paused {
            return .secondary.opacity(style == .macOS ? 0.72 : 0.36)
        }
        if displayState == .stale {
            return .secondary.opacity(style == .macOS ? 0.50 : 0.28)
        }
        return style == .macOS ? Color.clear : Color.secondary.opacity(0.22)
    }

    private var baseStrokeColor: Color {
        if displayState == .paused || displayState == .stale {
            return style == .macOS ? .white.opacity(0.92) : .secondary.opacity(0.14)
        }
        switch style {
        case .trafficLight:
            return .secondary.opacity(0.10)
        case .macOS:
            return .white.opacity(0.92)
        }
    }

    private func activeStrokeColor(for color: SignalLampColor) -> Color {
        if style != .macOS {
            return .white.opacity(0.20)
        }
        return activeFillColor(for: color)
    }
}

private struct TrafficSignalChrome: ViewModifier {
    let style: TrafficSignalStyle

    func body(content: Content) -> some View {
        if style == .macOS {
            content
                .background(.clear)
        } else {
            content
                .background(.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(.white.opacity(0.12), lineWidth: 1)
                )
        }
    }
}

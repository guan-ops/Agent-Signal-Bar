import AgentSignalLightCore
import AppKit

public enum StatusBarIconRenderer {
    public static func image(
        snapshot: SignalSnapshot,
        tick: Int,
        layout: TrafficSignalLayout,
        style: TrafficSignalStyle,
        macOSBreathingStrength: MacOSBreathingStrength,
        macOSHorizontalUsesTrafficLightSize: Bool = false,
        trafficLightVerticalUsesMacOSSize: Bool = false,
        allLightsOn: Bool,
        usesSystemGrayLights: Bool = false,
        effectCustomization: SignalEffectCustomization = .default
    ) -> NSImage {
        let metrics = SignalIconGeometry.metrics(
            layout: layout,
            style: style,
            macOSHorizontalUsesTrafficLightSize: macOSHorizontalUsesTrafficLightSize,
            trafficLightVerticalUsesMacOSSize: trafficLightVerticalUsesMacOSSize
        )
        let size = NSSize(width: metrics.iconSize.width, height: metrics.iconSize.height)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()

        if style == .trafficLight {
            drawTrafficLightBackground(in: NSRect(origin: .zero, size: size))
        }

        let displayState = snapshot.aggregate.displayState
        for (color, rect) in lampRects(in: size, layout: layout, metrics: metrics) {
            let intensity = SignalLampAnimation.intensity(
                color,
                signal: snapshot.aggregate,
                tick: tick,
                allLightsOn: allLightsOn,
                customization: effectCustomization
            )
            drawLamp(
                color,
                in: rect,
                intensity: intensity,
                scale: visualScale(
                    color: color,
                    signal: snapshot.aggregate,
                    tick: tick,
                    intensity: intensity,
                    allLightsOn: allLightsOn,
                    style: style,
                    macOSBreathingStrength: macOSBreathingStrength,
                    effectCustomization: effectCustomization
                ),
                displayState: displayState,
                style: style,
                usesSystemGrayLights: usesSystemGrayLights
            )
        }

        image.isTemplate = false
        return image
    }

    public static func statusItemLength(
        layout: TrafficSignalLayout,
        style: TrafficSignalStyle,
        macOSHorizontalUsesTrafficLightSize: Bool = false,
        trafficLightVerticalUsesMacOSSize: Bool = false
    ) -> CGFloat {
        SignalIconGeometry.metrics(
            layout: layout,
            style: style,
            macOSHorizontalUsesTrafficLightSize: macOSHorizontalUsesTrafficLightSize,
            trafficLightVerticalUsesMacOSSize: trafficLightVerticalUsesMacOSSize
        ).iconSize.width
    }

    private static func visualScale(
        color: SignalLampColor,
        signal: AgentSignal,
        tick: Int,
        intensity: Double,
        allLightsOn: Bool,
        style: TrafficSignalStyle,
        macOSBreathingStrength: MacOSBreathingStrength,
        effectCustomization: SignalEffectCustomization
    ) -> Double {
        SignalVisualScale.lampScale(
            baseScale: SignalLampAnimation.scale(
                color,
                signal: signal,
                tick: tick,
                allLightsOn: allLightsOn,
                customization: effectCustomization
            ),
            intensity: intensity,
            style: style.visualStyle,
            macOSStrength: macOSBreathingStrength
        )
    }

    static func lampRects(
        in size: NSSize,
        layout: TrafficSignalLayout,
        metrics: SignalIconMetrics
    ) -> [(SignalLampColor, NSRect)] {
        let diameter = metrics.lampDiameter
        let colors: [SignalLampColor] = [.red, .yellow, .green]

        switch layout {
        case .horizontal:
            let origins = lampAxisOrigins(totalLength: size.width, metrics: metrics)
            let y = aligned((size.height - diameter) / 2)
            return colors.enumerated().map { index, color in
                (color, NSRect(x: origins[index], y: y, width: diameter, height: diameter))
            }
        case .vertical:
            let origins = lampAxisOrigins(totalLength: size.height, metrics: metrics)
            let x = aligned((size.width - diameter) / 2)
            return colors.enumerated().map { index, color in
                (color, NSRect(x: x, y: origins[2 - index], width: diameter, height: diameter))
            }
        }
    }

    private static func lampAxisOrigins(totalLength: CGFloat, metrics: SignalIconMetrics) -> [CGFloat] {
        let start = aligned((totalLength - metrics.horizontalLampSpan) / 2)
        return (0..<3).map { index in
            aligned(start + CGFloat(index) * metrics.lampStep)
        }
    }

    private static func drawTrafficLightBackground(in rect: NSRect) {
        let insetRect = rect.insetBy(dx: 1, dy: 1)
        let radius = min(8, min(insetRect.width, insetRect.height) * 0.42)
        let background = NSBezierPath(roundedRect: insetRect, xRadius: radius, yRadius: radius)
        NSColor.black.withAlphaComponent(0.88).setFill()
        background.fill()
        NSColor.white.withAlphaComponent(0.16).setStroke()
        background.lineWidth = 0.75
        background.stroke()
    }

    private static func drawLamp(
        _ color: SignalLampColor,
        in rect: NSRect,
        intensity: Double,
        scale: Double,
        displayState: DisplayState,
        style: TrafficSignalStyle,
        usesSystemGrayLights: Bool
    ) {
        let path = NSBezierPath(ovalIn: pixelAligned(rect))
        inactiveFillColor(displayState: displayState, style: style).setFill()
        path.fill()

        baseStrokeColor(displayState: displayState, style: style).setStroke()
        path.lineWidth = style == .macOS ? 0.85 : 0.55
        path.stroke()

        guard intensity > 0 else { return }

        let activeRect = pixelAligned(scaled(rect, by: scale))
        let activePath = NSBezierPath(ovalIn: activeRect)
        let lampColor = activeFillColor(
            color,
            intensity: intensity,
            style: style,
            usesSystemGrayLights: usesSystemGrayLights
        )
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = baseLampColor(
            color,
            usesSystemGrayLights: usesSystemGrayLights
        ).withAlphaComponent(usesSystemGrayLights ? 0 : intensity * 0.35)
        shadow.shadowBlurRadius = style == .macOS ? 1.8 : 1.5
        shadow.set()
        lampColor.setFill()
        activePath.fill()
        NSGraphicsContext.restoreGraphicsState()

        activeStrokeColor(
            lampColor: lampColor,
            style: style
        ).setStroke()
        activePath.lineWidth = style == .macOS ? 0.85 : 0.55
        activePath.stroke()

        guard intensity > 0.7, style != .macOS else { return }

        let highlight = NSBezierPath(
            ovalIn: NSRect(
                x: activeRect.minX + activeRect.width * 0.18,
                y: activeRect.maxY - activeRect.height * 0.48,
                width: max(activeRect.width * 0.34, 1.5),
                height: max(activeRect.height * 0.34, 1.5)
            )
        )
        NSColor.white.withAlphaComponent(0.34).setFill()
        highlight.fill()
    }

    private static func aligned(_ value: CGFloat) -> CGFloat {
        (value * 2).rounded() / 2
    }

    private static func pixelAligned(_ rect: NSRect) -> NSRect {
        NSRect(
            x: aligned(rect.origin.x),
            y: aligned(rect.origin.y),
            width: aligned(rect.size.width),
            height: aligned(rect.size.height)
        )
    }

    private static func scaled(_ rect: NSRect, by scale: Double) -> NSRect {
        let scale = max(0, min(scale, 1))
        let width = rect.width * scale
        let height = rect.height * scale
        return NSRect(
            x: rect.midX - width / 2,
            y: rect.midY - height / 2,
            width: width,
            height: height
        )
    }

    private static func inactiveFillColor(
        displayState: DisplayState,
        style: TrafficSignalStyle
    ) -> NSColor {
        if displayState == .paused {
            return NSColor.secondaryLabelColor.withAlphaComponent(style == .macOS ? 0.72 : 0.36)
        }
        if displayState == .stale {
            return NSColor.secondaryLabelColor.withAlphaComponent(style == .macOS ? 0.50 : 0.28)
        }
        switch style {
        case .trafficLight:
            return NSColor.secondaryLabelColor.withAlphaComponent(0.28)
        case .macOS:
            return NSColor.clear
        }
    }

    private static func activeFillColor(
        _ color: SignalLampColor,
        intensity: Double,
        style: TrafficSignalStyle,
        usesSystemGrayLights: Bool
    ) -> NSColor {
        baseLampColor(color, usesSystemGrayLights: usesSystemGrayLights).withAlphaComponent(intensity)
    }

    private static func baseLampColor(_ color: SignalLampColor, usesSystemGrayLights: Bool = false) -> NSColor {
        if usesSystemGrayLights {
            return NSColor.systemGray
        }

        switch color {
        case .green:
            return NSColor(calibratedRed: 0.16, green: 0.78, blue: 0.34, alpha: 1)
        case .yellow:
            return NSColor(calibratedRed: 0.97, green: 0.72, blue: 0.16, alpha: 1)
        case .red:
            return NSColor(calibratedRed: 0.94, green: 0.20, blue: 0.18, alpha: 1)
        }
    }

    private static func baseStrokeColor(
        displayState: DisplayState,
        style: TrafficSignalStyle
    ) -> NSColor {
        if displayState == .paused || displayState == .stale {
            switch style {
            case .trafficLight:
                return NSColor.secondaryLabelColor.withAlphaComponent(0.14)
            case .macOS:
                return NSColor.white.withAlphaComponent(0.92)
            }
        }
        switch style {
        case .trafficLight:
            return NSColor.secondaryLabelColor.withAlphaComponent(0.12)
        case .macOS:
            return NSColor.white.withAlphaComponent(0.92)
        }
    }

    private static func activeStrokeColor(
        lampColor: NSColor,
        style: TrafficSignalStyle
    ) -> NSColor {
        switch style {
        case .trafficLight:
            return NSColor.white.withAlphaComponent(0.20)
        case .macOS:
            return lampColor
        }
    }
}

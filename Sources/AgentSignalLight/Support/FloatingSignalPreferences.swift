import AppKit
import AgentSignalLightUI
import Foundation
import SwiftUI

enum FloatingSignalScale: String, CaseIterable, Hashable {
    case compact
    case standard
    case large

    func panelSize(
        layout: TrafficSignalLayout,
        trafficLightVerticalUsesMacOSSize: Bool,
        visualScale: CGFloat? = nil
    ) -> NSSize {
        let frameSize = signalFrameSize(
            layout: layout,
            trafficLightVerticalUsesMacOSSize: trafficLightVerticalUsesMacOSSize,
            visualScale: visualScale
        )
        return NSSize(width: frameSize.width, height: frameSize.height)
    }

    var visualScale: CGFloat {
        switch self {
        case .compact:
            return 1.15
        case .standard:
            return 1.50
        case .large:
            return 1.95
        }
    }

    static let defaultVisualScale: CGFloat = FloatingSignalScale.standard.visualScale
    static let minimumVisualScale: CGFloat = 0.85
    static let maximumVisualScale: CGFloat = 2.60

    static func clampedVisualScale(_ visualScale: CGFloat) -> CGFloat {
        min(max(visualScale, minimumVisualScale), maximumVisualScale)
    }

    func signalFrameSize(
        layout: TrafficSignalLayout,
        trafficLightVerticalUsesMacOSSize: Bool,
        visualScale: CGFloat? = nil
    ) -> CGSize {
        let contentSize = signalContentSize(
            layout: layout,
            trafficLightVerticalUsesMacOSSize: trafficLightVerticalUsesMacOSSize
        )
        let baseSize: CGSize
        switch layout {
        case .horizontal:
            baseSize = CGSize(width: contentSize.width, height: contentSize.height + 6)
        case .vertical:
            baseSize = CGSize(
                width: max(contentSize.width + 6, 34),
                height: max(contentSize.height, 74)
            )
        }
        let resolvedScale = Self.clampedVisualScale(visualScale ?? self.visualScale)
        return CGSize(width: baseSize.width * resolvedScale, height: baseSize.height * resolvedScale)
    }

    func housingBackingSize(
        layout: TrafficSignalLayout,
        trafficLightVerticalUsesMacOSSize: Bool,
        visualScale: CGFloat? = nil
    ) -> CGSize {
        let contentSize = signalContentSize(
            layout: layout,
            trafficLightVerticalUsesMacOSSize: trafficLightVerticalUsesMacOSSize
        )
        let resolvedScale = Self.clampedVisualScale(visualScale ?? self.visualScale)
        return CGSize(width: contentSize.width * resolvedScale, height: contentSize.height * resolvedScale)
    }

    var smaller: FloatingSignalScale {
        switch self {
        case .compact:
            return .compact
        case .standard:
            return .compact
        case .large:
            return .standard
        }
    }

    var larger: FloatingSignalScale {
        switch self {
        case .compact:
            return .standard
        case .standard:
            return .large
        case .large:
            return .large
        }
    }

    private func signalContentSize(
        layout: TrafficSignalLayout,
        trafficLightVerticalUsesMacOSSize: Bool
    ) -> CGSize {
        let diameter: CGFloat = 16
        let spacing = lampSpacing(
            layout: layout,
            trafficLightVerticalUsesMacOSSize: trafficLightVerticalUsesMacOSSize
        )
        let padding = signalPadding(
            layout: layout,
            trafficLightVerticalUsesMacOSSize: trafficLightVerticalUsesMacOSSize
        )
        let lampSpan = diameter * 3 + spacing * 2
        switch layout {
        case .horizontal:
            return CGSize(
                width: lampSpan + padding.leading + padding.trailing,
                height: diameter + padding.top + padding.bottom
            )
        case .vertical:
            return CGSize(
                width: diameter + padding.leading + padding.trailing,
                height: lampSpan + padding.top + padding.bottom
            )
        }
    }

    private func lampSpacing(
        layout: TrafficSignalLayout,
        trafficLightVerticalUsesMacOSSize: Bool
    ) -> CGFloat {
        if layout == .vertical && trafficLightVerticalUsesMacOSSize {
            return 3
        }
        return layout == .vertical ? 5 : 8
    }

    private func signalPadding(
        layout: TrafficSignalLayout,
        trafficLightVerticalUsesMacOSSize: Bool
    ) -> EdgeInsets {
        switch layout {
        case .vertical where trafficLightVerticalUsesMacOSSize:
            return EdgeInsets(top: 5, leading: 5, bottom: 5, trailing: 5)
        case .horizontal:
            return EdgeInsets(top: 6, leading: 7, bottom: 6, trailing: 7)
        case .vertical:
            return EdgeInsets(top: 8, leading: 6, bottom: 8, trailing: 6)
        }
    }
}

enum FloatingSignalSoundLevel: String, CaseIterable, Hashable {
    case soft
    case standard
    case loud

    var volume: Float {
        switch self {
        case .soft:
            return 0.28
        case .standard:
            return 0.55
        case .loud:
            return 0.88
        }
    }
}

enum FloatingSignalCompletionSound: String, CaseIterable, Hashable {
    case off
    case newZealandCrossing
    case aiAurora
    case aiGlow

    var isEnabled: Bool {
        self != .off
    }

    var resourceName: String? {
        switch self {
        case .off:
            return nil
        case .newZealandCrossing:
            return "completion-signal-nz"
        case .aiAurora:
            return "completion-ai-aurora"
        case .aiGlow:
            return "completion-ai-glow"
        }
    }
}

enum FloatingSignalWaitingSound: String, CaseIterable, Hashable {
    case off
    case newZealandCrossing
    case aiTick
    case aiOrbit

    var isEnabled: Bool {
        self != .off
    }

    var resourceName: String? {
        switch self {
        case .off:
            return nil
        case .newZealandCrossing:
            return "waiting-signal-nz"
        case .aiTick:
            return "waiting-ai-tick"
        case .aiOrbit:
            return "waiting-ai-orbit"
        }
    }
}

import CoreGraphics

struct SignalIconMetrics {
    let iconSize: CGSize
    let lampDiameter: CGFloat
    let lampSpacing: CGFloat

    var lampStep: CGFloat {
        lampDiameter + lampSpacing
    }

    var horizontalLampSpan: CGFloat {
        lampDiameter * 3 + lampSpacing * 2
    }

    var verticalLampSpan: CGFloat {
        horizontalLampSpan
    }
}

enum SignalIconGeometry {
    static func metrics(
        layout: TrafficSignalLayout,
        style: TrafficSignalStyle,
        macOSHorizontalUsesTrafficLightSize: Bool = false,
        trafficLightVerticalUsesMacOSSize: Bool = false
    ) -> SignalIconMetrics {
        if style == .macOS && layout == .horizontal && macOSHorizontalUsesTrafficLightSize {
            return trafficLightMetrics(layout: .horizontal)
        }

        if style == .trafficLight && layout == .vertical && trafficLightVerticalUsesMacOSSize {
            return compactTrafficLightVerticalMetrics()
        }

        return metrics(layout: layout, style: style)
    }

    private static func metrics(layout: TrafficSignalLayout, style: TrafficSignalStyle) -> SignalIconMetrics {
        switch (layout, style) {
        case (.horizontal, .trafficLight):
            return trafficLightMetrics(layout: layout)
        case (.vertical, .trafficLight):
            return trafficLightMetrics(layout: layout)
        case (.horizontal, .macOS):
            return macOSMetrics(layout: layout)
        case (.vertical, .macOS):
            return macOSMetrics(layout: layout)
        }
    }

    private static func macOSMetrics(layout: TrafficSignalLayout) -> SignalIconMetrics {
        switch layout {
        case .horizontal:
            return SignalIconMetrics(
                iconSize: CGSize(width: 27, height: 18),
                lampDiameter: 5,
                lampSpacing: 2.5
            )
        case .vertical:
            return SignalIconMetrics(
                iconSize: CGSize(width: 10, height: 18),
                lampDiameter: 4,
                lampSpacing: 2
            )
        }
    }

    private static func trafficLightMetrics(layout: TrafficSignalLayout) -> SignalIconMetrics {
        switch layout {
        case .horizontal:
            return SignalIconMetrics(
                iconSize: CGSize(width: 40, height: 20),
                lampDiameter: 8,
                lampSpacing: 3.5
            )
        case .vertical:
            return SignalIconMetrics(
                iconSize: CGSize(width: 14, height: 22),
                lampDiameter: 4,
                lampSpacing: 1
            )
        }
    }

    private static func compactTrafficLightVerticalMetrics() -> SignalIconMetrics {
        SignalIconMetrics(
            iconSize: CGSize(width: 16, height: 24),
            lampDiameter: 6,
            lampSpacing: 1
        )
    }
}

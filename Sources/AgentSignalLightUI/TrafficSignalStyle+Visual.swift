import AgentSignalLightCore

extension TrafficSignalStyle {
    public var visualStyle: SignalVisualStyle {
        switch self {
        case .trafficLight:
            return .trafficLight
        case .macOS, .singleLamp:
            return .macOS
        }
    }
}

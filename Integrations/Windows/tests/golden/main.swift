// Golden generator: compiled together with Sources/AgentSignalLightCore/*.swift by
// tests/golden/generate.sh. Prints the Swift lamp tables as JSON lines that
// tst_signalmodel.cpp replays against the C++ port.
import Foundation

let signals = AgentSignal.allCases.map(\.rawValue) + ["tool-use", "PermissionRequest", "failed", "unknown_x"]
let colors: [(String, SignalLampColor)] = [("red", .red), ("yellow", .yellow), ("green", .green)]

var customizations: [(String, SignalEffectCustomization)] = [("default", .default)]
for active in ActiveSignalEffect.allCases {
    for speed in SignalEffectSpeed.allCases {
        customizations.append(("active=\(active.rawValue),thinking=\(active.rawValue),activeSpeed=\(speed.rawValue)",
            SignalEffectCustomization(thinkingEffect: active, activeEffect: active, activeSpeed: speed)))
    }
}
for alert in AlertSignalEffect.allCases {
    for speed in SignalEffectSpeed.allCases {
        customizations.append(("needsReview=\(alert.rawValue),permission=\(alert.rawValue),blocked=\(alert.rawValue),alertSpeed=\(speed.rawValue)",
            SignalEffectCustomization(alertSpeed: speed, needsReviewEffect: alert, permissionEffect: alert, blockedEffect: alert)))
    }
}
for completed in CompletedSignalEffect.allCases {
    customizations.append(("completed=\(completed.rawValue)", SignalEffectCustomization(completedEffect: completed)))
}

for (key, custom) in customizations {
    for raw in signals {
        let signal = AgentSignal.normalized(raw)
        for allOn in [false, true] {
            var row: [String: Any] = ["custom": key, "signal": raw, "allOn": allOn,
                                      "state": signal.map { $0.displayState.rawValue } ?? "unknown"]
            for (name, color) in colors {
                var intensities: [Double] = []
                var scales: [Double] = []
                for tick in 0..<24 {
                    if let signal {
                        intensities.append(SignalLampAnimation.intensity(color, signal: signal, tick: tick, allLightsOn: allOn, customization: custom))
                        scales.append(SignalLampAnimation.scale(color, signal: signal, tick: tick, allLightsOn: allOn, customization: custom))
                    }
                }
                row[name] = intensities
                row[name + "Scale"] = scales
            }
            let data = try! JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            print(String(data: data, encoding: .utf8)!)
        }
    }
}

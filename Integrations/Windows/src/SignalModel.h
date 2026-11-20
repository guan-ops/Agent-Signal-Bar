// Port of AgentSignalLightCore (AgentSignal.swift, SignalLampAnimation.swift,
// SignalEffectCustomization.swift, SignalVisualScale.swift). Keep the tables in
// lockstep with the Swift sources; tests/tst_signalmodel.cpp diffs this port
// against golden output generated from the Swift implementation.
#pragma once

#include <QString>
#include <optional>

namespace asb {

enum class DisplayState { Ready, Active, Completed, NeedsReview, Permission, Blocked, Stale, Paused };
enum class LampColor { Red, Yellow, Green };
enum class ActiveEffect { GreenBreathing, GreenSteady, GreenSlowFlash, GreenFastFlash, TrafficCycle };
enum class AlertEffect { Pulse, Steady, SlowFlash, FastFlash, Breathing, TrafficCycle };
enum class CompletedEffect { GreenPulse, GreenSteady, YellowPulse, YellowSteady, AllSteady, AllPulse };
enum class EffectSpeed { Slow, Standard, Fast };
enum class VisualStyle { TrafficLight, MacOS };
enum class BreathingStrength { Standard, Pronounced, Maximum };

struct EffectCustomization {
    ActiveEffect thinkingEffect = ActiveEffect::GreenFastFlash;
    ActiveEffect activeEffect = ActiveEffect::GreenSlowFlash;
    EffectSpeed activeSpeed = EffectSpeed::Standard;
    EffectSpeed alertSpeed = EffectSpeed::Standard;
    CompletedEffect completedEffect = CompletedEffect::GreenSteady;
    AlertEffect needsReviewEffect = AlertEffect::SlowFlash;
    AlertEffect permissionEffect = AlertEffect::SlowFlash;
    AlertEffect blockedEffect = AlertEffect::FastFlash;

    bool operator==(const EffectCustomization &) const = default;
};

// Canonical signal name ("working", "permission_request", ...) or nullopt for unknown input.
std::optional<QString> normalizedSignal(const QString &raw);
DisplayState displayState(const QString &signal);
QString displayStateKey(DisplayState state);
// DisplayState.priority: paused 100 > blocked 90 > permission 80 > needs review 70 > stale 60
// > active 50 > completed 40 > ready 0.
int priority(DisplayState state);
inline int priority(const QString &signal) { return priority(displayState(signal)); }
// AgentSignal.normalizedAggregateSignal: the one signal that stands for a display state.
QString normalizedAggregateSignal(const QString &signal);

double intensity(LampColor color, const QString &signal, int tick, bool allLightsOn = false,
                 const EffectCustomization &customization = {});
double scale(LampColor color, const QString &signal, int tick, bool allLightsOn = false,
             const EffectCustomization &customization = {});
double visualLampScale(double baseScale, double intensity, VisualStyle style, BreathingStrength strength);
std::optional<LampColor> dominantColor(const QString &signal, int tick, bool allLightsOn = false,
                                       const EffectCustomization &customization = {});

// How the shared animation clock advances (MenuBarStatusModel.AnimationTickCadence):
// every `framesPerAdvance` timer frames the tick grows by `tickAdvance`.
struct TickCadence {
    int framesPerAdvance = 1;
    int tickAdvance = 1;
    bool operator==(const TickCadence &) const = default;
};
TickCadence tickCadence(const QString &signal, const EffectCustomization &customization, bool lowPower,
                        bool newZealandMode);

// Raw values match the Swift enums' rawValue so preferences and golden files share keys.
std::optional<ActiveEffect> activeEffectFromKey(const QString &key);
std::optional<AlertEffect> alertEffectFromKey(const QString &key);
std::optional<CompletedEffect> completedEffectFromKey(const QString &key);
std::optional<EffectSpeed> effectSpeedFromKey(const QString &key);
std::optional<LampColor> lampColorFromKey(const QString &key);

} // namespace asb

#include "SignalModel.h"

#include <QHash>
#include <QSet>
#include <array>
#include <vector>

namespace asb {
namespace {

const QSet<QString> &knownSignals() {
    static const QSet<QString> names = {
        "idle", "thinking", "working", "tool_done", "subagent_start", "subagent_stop",
        "attention", "notification", "done", "permission", "permission_request", "blocked",
        "failure", "error", "exception", "max_tokens", "stale", "session_start", "session_end",
        "turn_end", "off", "pause", "paused"};
    return names;
}

int adjustedTick(int tick, EffectSpeed speed) {
    const int t = tick >= 0 ? tick : 0;
    switch (speed) {
    case EffectSpeed::Slow: return t / 2;
    case EffectSpeed::Standard: return t;
    case EffectSpeed::Fast: return t * 2;
    }
    return t;
}

double at(const std::vector<double> &values, int tick) { return values[static_cast<size_t>(tick) % values.size()]; }

const std::vector<double> kBreathing = {0.35, 0.42, 0.52, 0.66, 0.82, 1.0, 0.82, 0.66, 0.52, 0.42};
const std::vector<double> kSlowFlash = {1, 1, 1, 0, 0, 0};
const std::vector<double> kFastFlash = {1, 0};
const std::vector<double> kAlertPulse = {0.45, 0.72, 1.0, 0.72, 0, 0, 0, 0};
const std::vector<double> kStale = {0.35, 0.5, 0.65, 0.5, 0, 0, 0, 0};
const std::vector<double> kCompletedPulse = {1.0, 0.7, 0, 0};

double trafficCycle(LampColor color, int tick) {
    static const std::array<LampColor, 3> phases = {LampColor::Red, LampColor::Yellow, LampColor::Green};
    const int phase = (tick / 4) % 3;
    return color == phases[static_cast<size_t>(phase)] ? 1 : 0;
}

double activeIntensity(LampColor color, const QString &signal, int tick, const EffectCustomization &c) {
    const int t = adjustedTick(tick, c.activeSpeed);
    const ActiveEffect effect = signal == QLatin1String("thinking") ? c.thinkingEffect : c.activeEffect;
    switch (effect) {
    case ActiveEffect::GreenBreathing: return color == LampColor::Green ? at(kBreathing, t) : 0;
    case ActiveEffect::GreenSteady: return color == LampColor::Green ? 1 : 0;
    case ActiveEffect::GreenSlowFlash: return color == LampColor::Green ? at(kSlowFlash, t) : 0;
    case ActiveEffect::GreenFastFlash: return color == LampColor::Green ? at(kFastFlash, t) : 0;
    case ActiveEffect::TrafficCycle: return trafficCycle(color, t);
    }
    return 0;
}

double alertIntensity(LampColor color, LampColor expected, int tick, EffectSpeed speed, AlertEffect effect) {
    if (effect != AlertEffect::TrafficCycle && color != expected) return 0;
    const int t = adjustedTick(tick, speed);
    switch (effect) {
    case AlertEffect::Pulse: return at(kAlertPulse, t);
    case AlertEffect::Steady: return 1;
    case AlertEffect::SlowFlash: return at(kSlowFlash, t);
    case AlertEffect::FastFlash: return at(kFastFlash, t);
    case AlertEffect::Breathing: return at(kBreathing, t);
    case AlertEffect::TrafficCycle: return trafficCycle(color, t);
    }
    return 0;
}

double completedIntensity(LampColor color, int tick, const EffectCustomization &c) {
    const int t = adjustedTick(tick, c.alertSpeed);
    switch (c.completedEffect) {
    case CompletedEffect::GreenPulse: return color == LampColor::Green ? at(kCompletedPulse, t) : 0;
    case CompletedEffect::GreenSteady: return color == LampColor::Green ? 1 : 0;
    case CompletedEffect::YellowPulse: return color == LampColor::Yellow ? at(kCompletedPulse, t) : 0;
    case CompletedEffect::YellowSteady: return color == LampColor::Yellow ? 1 : 0;
    case CompletedEffect::AllSteady: return 1;
    case CompletedEffect::AllPulse: return at(kCompletedPulse, t);
    }
    return 0;
}

} // namespace

std::optional<QString> normalizedSignal(const QString &raw) {
    QString n = raw.trimmed().toLower();
    n.replace('-', '_');
    n.replace(' ', '_');
    static const QHash<QString, QString> aliases = {
        {"tooluse", "working"}, {"tool_use", "working"}, {"pre_tool_use", "working"},
        {"post_tool_use", "tool_done"}, {"subagentstart", "subagent_start"},
        {"subagentstop", "subagent_stop"}, {"permissionrequest", "permission_request"},
        {"failed", "failure"}, {"maxtokens", "max_tokens"}};
    if (aliases.contains(n)) return aliases.value(n);
    if (knownSignals().contains(n)) return n;
    return std::nullopt;
}

DisplayState displayState(const QString &signal) {
    static const QHash<QString, DisplayState> map = {
        {"idle", DisplayState::Ready}, {"session_start", DisplayState::Ready},
        {"session_end", DisplayState::Ready}, {"turn_end", DisplayState::Ready},
        {"thinking", DisplayState::Active}, {"working", DisplayState::Active},
        {"tool_done", DisplayState::Active}, {"subagent_start", DisplayState::Active},
        {"subagent_stop", DisplayState::Active}, {"done", DisplayState::Completed},
        {"attention", DisplayState::NeedsReview}, {"notification", DisplayState::NeedsReview},
        {"permission", DisplayState::Permission}, {"permission_request", DisplayState::Permission},
        {"blocked", DisplayState::Blocked}, {"failure", DisplayState::Blocked},
        {"error", DisplayState::Blocked}, {"exception", DisplayState::Blocked},
        {"max_tokens", DisplayState::Blocked}, {"stale", DisplayState::Stale},
        {"off", DisplayState::Paused}, {"pause", DisplayState::Paused}, {"paused", DisplayState::Paused}};
    const auto normalized = normalizedSignal(signal);
    return normalized ? map.value(*normalized, DisplayState::Ready) : DisplayState::Ready;
}

QString displayStateKey(DisplayState state) {
    switch (state) {
    case DisplayState::Ready: return "ready";
    case DisplayState::Active: return "active";
    case DisplayState::Completed: return "completed";
    case DisplayState::NeedsReview: return "needs_review";
    case DisplayState::Permission: return "permission";
    case DisplayState::Blocked: return "blocked";
    case DisplayState::Stale: return "stale";
    case DisplayState::Paused: return "paused";
    }
    return "ready";
}

int priority(DisplayState state) {
    switch (state) {
    case DisplayState::Paused: return 100;
    case DisplayState::Blocked: return 90;
    case DisplayState::Permission: return 80;
    case DisplayState::NeedsReview: return 70;
    case DisplayState::Stale: return 60;
    case DisplayState::Active: return 50;
    case DisplayState::Completed: return 40;
    case DisplayState::Ready: return 0;
    }
    return 0;
}

QString normalizedAggregateSignal(const QString &signal) {
    switch (displayState(signal)) {
    case DisplayState::Ready: return QStringLiteral("idle");
    case DisplayState::Active: return normalizedSignal(signal).value_or(QStringLiteral("working"));
    case DisplayState::Completed: return QStringLiteral("done");
    case DisplayState::NeedsReview: return QStringLiteral("attention");
    case DisplayState::Permission: return QStringLiteral("permission");
    case DisplayState::Blocked: return QStringLiteral("blocked");
    case DisplayState::Stale: return QStringLiteral("stale");
    case DisplayState::Paused: return QStringLiteral("off");
    }
    return QStringLiteral("idle");
}

double intensity(LampColor color, const QString &signalRaw, int tick, bool allLightsOn,
                 const EffectCustomization &c) {
    if (allLightsOn) return 1;
    const QString signal = normalizedSignal(signalRaw).value_or(QStringLiteral("idle"));
    switch (displayState(signal)) {
    case DisplayState::Ready: return color == LampColor::Green ? 1 : 0;
    case DisplayState::Active: return activeIntensity(color, signal, tick, c);
    case DisplayState::Completed: return completedIntensity(color, tick, c);
    case DisplayState::NeedsReview:
        return alertIntensity(color, LampColor::Yellow, tick, c.alertSpeed, c.needsReviewEffect);
    case DisplayState::Permission:
        return alertIntensity(color, LampColor::Red, tick, c.alertSpeed, c.permissionEffect);
    case DisplayState::Blocked:
        return alertIntensity(color, LampColor::Red, tick, c.alertSpeed, c.blockedEffect);
    case DisplayState::Stale:
        return color == LampColor::Yellow ? at(kStale, adjustedTick(tick, c.alertSpeed)) : 0;
    case DisplayState::Paused: return 0;
    }
    return 0;
}

double scale(LampColor color, const QString &signal, int tick, bool allLightsOn, const EffectCustomization &c) {
    const double i = intensity(color, signal, tick, allLightsOn, c);
    if (i <= 0) return 1;
    switch (displayState(signal)) {
    case DisplayState::Ready:
    case DisplayState::Paused: return 1;
    default: return 0.48 + i * 0.52;
    }
}

double visualLampScale(double baseScale, double intensityValue, VisualStyle style, BreathingStrength strength) {
    if (intensityValue <= 0) return 1;
    if (style == VisualStyle::TrafficLight) return baseScale;
    const double amount = strength == BreathingStrength::Standard ? 0.45
                          : strength == BreathingStrength::Pronounced ? 0.72 : 1.0;
    return 1 - (1 - baseScale) * amount;
}

std::optional<LampColor> dominantColor(const QString &signal, int tick, bool allLightsOn,
                                       const EffectCustomization &c) {
    // Equal brightness prefers green, then yellow, then red.
    std::optional<LampColor> best;
    double bestValue = 0;
    for (LampColor color : {LampColor::Green, LampColor::Yellow, LampColor::Red}) {
        const double value = intensity(color, signal, tick, allLightsOn, c);
        if (value > bestValue) {
            best = color;
            bestValue = value;
        }
    }
    return best;
}

namespace {
constexpr TickCadence kEveryFrame{1, 1};

AlertEffect alertEffectFor(DisplayState state, const EffectCustomization &c) {
    switch (state) {
    case DisplayState::NeedsReview: return c.needsReviewEffect;
    case DisplayState::Permission: return c.permissionEffect;
    case DisplayState::Blocked: return c.blockedEffect;
    default: return AlertEffect::SlowFlash;
    }
}

TickCadence lowPowerCadence(const QString &signal, const EffectCustomization &c) {
    const DisplayState state = displayState(signal);
    switch (state) {
    case DisplayState::Active: {
        const ActiveEffect effect = normalizedSignal(signal) == QStringLiteral("thinking") ? c.thinkingEffect : c.activeEffect;
        switch (effect) {
        case ActiveEffect::GreenBreathing:
        case ActiveEffect::GreenSlowFlash:
        case ActiveEffect::TrafficCycle: return {1, 2};
        default: return kEveryFrame;
        }
    }
    case DisplayState::Completed:
        switch (c.completedEffect) {
        case CompletedEffect::GreenPulse:
        case CompletedEffect::YellowPulse:
        case CompletedEffect::AllPulse: return {1, 2};
        default: return kEveryFrame;
        }
    case DisplayState::NeedsReview:
    case DisplayState::Permission:
    case DisplayState::Blocked:
        switch (alertEffectFor(state, c)) {
        case AlertEffect::Pulse:
        case AlertEffect::Breathing:
        case AlertEffect::SlowFlash: return {1, 2};
        case AlertEffect::FastFlash:
        case AlertEffect::Steady: return kEveryFrame;
        case AlertEffect::TrafficCycle: return {2, 4};
        }
        return kEveryFrame;
    case DisplayState::Stale: return {1, 2};
    case DisplayState::Ready:
    case DisplayState::Paused: return kEveryFrame;
    }
    return kEveryFrame;
}

TickCadence newZealandCadence(const QString &signal, const EffectCustomization &c, bool lowPower) {
    const DisplayState state = displayState(signal);
    switch (state) {
    case DisplayState::Active: {
        const ActiveEffect effect = normalizedSignal(signal) == QStringLiteral("thinking") ? c.thinkingEffect : c.activeEffect;
        switch (effect) {
        case ActiveEffect::GreenSlowFlash: return {lowPower ? 1 : 2, 3}; // 0.9 s on / 0.9 s off
        case ActiveEffect::TrafficCycle: return {lowPower ? 2 : 4, 4};
        case ActiveEffect::GreenBreathing: return lowPower ? TickCadence{1, 2} : kEveryFrame;
        default: return kEveryFrame;
        }
    }
    case DisplayState::Completed:
        switch (c.completedEffect) {
        case CompletedEffect::GreenPulse:
        case CompletedEffect::YellowPulse:
        case CompletedEffect::AllPulse: return {lowPower ? 1 : 2, 2};
        default: return kEveryFrame;
        }
    case DisplayState::NeedsReview:
    case DisplayState::Permission:
    case DisplayState::Blocked:
        switch (alertEffectFor(state, c)) {
        case AlertEffect::SlowFlash: return {lowPower ? 1 : 2, 3};
        case AlertEffect::Breathing:
        case AlertEffect::Pulse: return lowPower ? TickCadence{1, 2} : kEveryFrame;
        case AlertEffect::TrafficCycle: return {lowPower ? 2 : 4, 4};
        case AlertEffect::FastFlash:
        case AlertEffect::Steady: return kEveryFrame;
        }
        return kEveryFrame;
    default: return lowPower ? lowPowerCadence(signal, c) : kEveryFrame;
    }
}
} // namespace

TickCadence tickCadence(const QString &signal, const EffectCustomization &c, bool lowPower, bool newZealandMode) {
    if (newZealandMode) return newZealandCadence(signal, c, lowPower);
    return lowPower ? lowPowerCadence(signal, c) : kEveryFrame;
}

std::optional<ActiveEffect> activeEffectFromKey(const QString &key) {
    static const QHash<QString, ActiveEffect> map = {
        {"green_breathing", ActiveEffect::GreenBreathing}, {"green_steady", ActiveEffect::GreenSteady},
        {"green_slow_flash", ActiveEffect::GreenSlowFlash}, {"green_fast_flash", ActiveEffect::GreenFastFlash},
        {"traffic_cycle", ActiveEffect::TrafficCycle}};
    if (!map.contains(key)) return std::nullopt;
    return map.value(key);
}

std::optional<AlertEffect> alertEffectFromKey(const QString &key) {
    static const QHash<QString, AlertEffect> map = {
        {"pulse", AlertEffect::Pulse}, {"steady", AlertEffect::Steady}, {"slow_flash", AlertEffect::SlowFlash},
        {"fast_flash", AlertEffect::FastFlash}, {"breathing", AlertEffect::Breathing},
        {"traffic_cycle", AlertEffect::TrafficCycle}};
    if (!map.contains(key)) return std::nullopt;
    return map.value(key);
}

std::optional<CompletedEffect> completedEffectFromKey(const QString &key) {
    static const QHash<QString, CompletedEffect> map = {
        {"green_pulse", CompletedEffect::GreenPulse}, {"green_steady", CompletedEffect::GreenSteady},
        {"yellow_pulse", CompletedEffect::YellowPulse}, {"yellow_steady", CompletedEffect::YellowSteady},
        {"all_steady", CompletedEffect::AllSteady}, {"all_pulse", CompletedEffect::AllPulse}};
    if (!map.contains(key)) return std::nullopt;
    return map.value(key);
}

std::optional<EffectSpeed> effectSpeedFromKey(const QString &key) {
    if (key == QLatin1String("slow")) return EffectSpeed::Slow;
    if (key == QLatin1String("standard")) return EffectSpeed::Standard;
    if (key == QLatin1String("fast")) return EffectSpeed::Fast;
    return std::nullopt;
}

std::optional<LampColor> lampColorFromKey(const QString &key) {
    if (key == QLatin1String("red")) return LampColor::Red;
    if (key == QLatin1String("yellow")) return LampColor::Yellow;
    if (key == QLatin1String("green")) return LampColor::Green;
    return std::nullopt;
}

} // namespace asb

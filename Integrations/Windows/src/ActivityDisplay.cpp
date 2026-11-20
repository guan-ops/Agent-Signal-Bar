#include "ActivityDisplay.h"

#include "SignalModel.h"

#include <QHash>
#include <QSet>
#include <QStringList>
#include <QUuid>
#include <algorithm>
#include <cstdlib>

namespace asb::display {
namespace {

// MenuBarStatusModel
constexpr qint64 kRecentEventDeduplicationWindow = 4000;
constexpr qint64 kCompletedDisplayWindow = 30 * 1000;
constexpr qint64 kRecentActivityFallbackWindow = 5 * 60 * 1000;
constexpr qint64 kPassiveActiveDisplayWindow = 45 * 1000;
constexpr qint64 kActiveDisplayWindow = 5 * 60 * 1000;
// ActivityPresentation
constexpr qint64 kLiveSessionWindow = 5 * 60 * 1000;
constexpr qint64 kPassiveActiveSessionWindow = 45 * 1000;
constexpr qint64 kAlertResolutionGraceWindow = 5000;

QString normalizedAgentName(const QString &agent) {
    QString n = agent.trimmed().toLower();
    n.replace('_', '-');
    n.replace(' ', '-');
    return n;
}

bool containsAny(const QStringList &values, const QStringList &tokens) {
    for (const QString &value : values) {
        for (const QString &token : tokens) {
            if (value.contains(token)) return true;
        }
    }
    return false;
}

bool containsIDEIdentity(const QStringList &values) {
    return containsAny(values, {"codex-ide", "claude-ide", "-ide", ":ide", "idea", "intellij", "jetbrains", "vscode",
                                "vs-code", "visual-studio-code", "xcode"});
}

bool isSignalTestEvent(const QString &event) { return event == "SignalTest" || event == "SignalTestOff"; }

bool isPresenceSession(const SessionStatus &s) {
    return s.sessionID.startsWith("desktop-app:") || s.sessionID.startsWith("platform-presence:")
        || s.lastEvent == "DesktopAppRunning" || s.lastEvent.startsWith("PlatformPresence:");
}

bool isPassiveEvent(const QString &event) {
    return event == "DesktopActivityHeartbeat" || event == "DesktopThinking" || event == "DesktopMessage";
}

bool isPassiveActive(const QString &signal, const QString &event) {
    return displayState(signal) == DisplayState::Active && isPassiveEvent(event);
}

bool isPersistentAlert(DisplayState s) {
    return s == DisplayState::NeedsReview || s == DisplayState::Permission || s == DisplayState::Blocked
        || s == DisplayState::Stale || s == DisplayState::Paused;
}

bool isResolvingSignal(const QString &signal) {
    static const QSet<QString> resolving = {"thinking", "working", "tool_done", "subagent_start", "subagent_stop", "done"};
    return resolving.contains(signal);
}

bool resolvingSupersedes(DisplayState s) { return s == DisplayState::NeedsReview || s == DisplayState::Permission; }

bool completedSupersedes(DisplayState s) {
    return s == DisplayState::Active || s == DisplayState::NeedsReview || s == DisplayState::Permission;
}

QString sourceKey(const SessionStatus &s) { return activitySourceKey(s.agent, s.sessionID, s.lastEvent); }
QString sourceKey(const SignalEvent &e) { return activitySourceKey(e.agent, e.sessionID, e.event); }

qint64 activeDisplayWindow(const SessionStatus &s) {
    return isPassiveActive(s.signal, s.lastEvent) ? kPassiveActiveDisplayWindow : kActiveDisplayWindow;
}

bool shouldIncludeStoredSession(const SessionStatus &s, qint64 now) {
    if (isSignalTestEvent(s.lastEvent) || isPresenceSession(s)) return false;
    switch (displayState(s.signal)) {
    case DisplayState::Active: return now - s.updatedAt <= activeDisplayWindow(s);
    case DisplayState::Completed: return now - s.updatedAt <= kCompletedDisplayWindow;
    case DisplayState::NeedsReview:
    case DisplayState::Permission:
    case DisplayState::Blocked:
    case DisplayState::Stale: return true;
    case DisplayState::Ready:
    case DisplayState::Paused: return false;
    }
    return false;
}

struct CompletionCutoff {
    qint64 updatedAt = 0;
    QSet<QString> resumedSessionIDs;
    QSet<QString> resumedEventIDs;
};

// `events` is newest first.
QHash<QString, CompletionCutoff> completionCutoffs(const QList<SignalEvent> &events) {
    QHash<QString, CompletionCutoff> cutoffs;
    QHash<QString, QList<SignalEvent>> newerActive;
    for (const SignalEvent &event : events) {
        const QString key = sourceKey(event);
        if (displayState(event.signal) == DisplayState::Active && !isPassiveActive(event.signal, event.event)
            && event.event != "DesktopToolDone")
            newerActive[key].append(event);
        if (displayState(event.signal) != DisplayState::Completed) continue;
        if (cutoffs.contains(key) && cutoffs[key].updatedAt >= event.updatedAt) continue;
        CompletionCutoff cutoff{event.updatedAt, {}, {}};
        for (const SignalEvent &resumed : newerActive.value(key)) {
            if (resumed.updatedAt != event.updatedAt) continue;
            cutoff.resumedSessionIDs.insert(resumed.sessionID);
            cutoff.resumedEventIDs.insert(resumed.id);
        }
        cutoffs[key] = cutoff;
    }
    return cutoffs;
}

QHash<QString, qint64> resolvingCutoffs(const QList<SignalEvent> &events) {
    QHash<QString, qint64> cutoffs;
    for (const SignalEvent &event : events) {
        if (!isResolvingSignal(event.signal)) continue;
        const QString key = sourceKey(event);
        if (cutoffs.contains(key) && cutoffs[key] >= event.updatedAt) continue;
        cutoffs[key] = event.updatedAt;
    }
    return cutoffs;
}

bool supersededByCompleted(const SessionStatus &s, const QHash<QString, CompletionCutoff> &cutoffs) {
    if (isPresenceSession(s) || !completedSupersedes(displayState(s.signal))) return false;
    const auto it = cutoffs.constFind(sourceKey(s));
    if (it == cutoffs.cend()) return false;
    if (it->updatedAt == s.updatedAt && it->resumedSessionIDs.contains(s.sessionID)) return false;
    return it->updatedAt >= s.updatedAt;
}

bool supersededByCompleted(const SignalEvent &e, const QHash<QString, CompletionCutoff> &cutoffs) {
    if (displayState(e.signal) != DisplayState::Active) return false;
    const auto it = cutoffs.constFind(sourceKey(e));
    if (it == cutoffs.cend()) return false;
    if (it->updatedAt == e.updatedAt && it->resumedEventIDs.contains(e.id)) return false;
    return it->updatedAt >= e.updatedAt;
}

bool supersededByResolving(const SessionStatus &s, const QHash<QString, qint64> &cutoffs) {
    if (isPresenceSession(s) || !resolvingSupersedes(displayState(s.signal))) return false;
    const auto it = cutoffs.constFind(sourceKey(s));
    return it != cutoffs.cend() && *it >= s.updatedAt;
}

bool supersededByResolving(const SignalEvent &e, const QHash<QString, qint64> &cutoffs) {
    if (!resolvingSupersedes(displayState(e.signal))) return false;
    const auto it = cutoffs.constFind(sourceKey(e));
    return it != cutoffs.cend() && *it > e.updatedAt;
}

bool isManualIdleControlEvent(const SignalEvent &e) {
    return e.sessionID == "manual" && (e.agent.isEmpty() || e.agent == "manual")
        && displayState(e.signal) == DisplayState::Ready;
}

bool useRecentEventAsFallback(const SignalEvent &e, qint64 now) {
    if (isManualIdleControlEvent(e)) return false;
    const qint64 age = now - e.updatedAt;
    switch (displayState(e.signal)) {
    case DisplayState::Active:
        return age <= (isPassiveActive(e.signal, e.event) ? kPassiveActiveDisplayWindow : kRecentActivityFallbackWindow);
    case DisplayState::Completed: return age <= kCompletedDisplayWindow;
    case DisplayState::NeedsReview:
    case DisplayState::Permission:
    case DisplayState::Blocked:
    case DisplayState::Stale: return true;
    case DisplayState::Ready:
    case DisplayState::Paused: return false;
    }
    return false;
}

QList<SessionStatus> fallbackSessions(const QList<SignalEvent> &events, const QList<SessionStatus> &existing,
                                      const QHash<QString, CompletionCutoff> &completed,
                                      const QHash<QString, qint64> &resolving, qint64 now) {
    QHash<QString, SessionStatus> latestExisting;
    for (const SessionStatus &s : existing) {
        const QString key = sourceKey(s);
        if (!latestExisting.contains(key) || latestExisting[key].updatedAt < s.updatedAt) latestExisting[key] = s;
    }
    QList<SignalEvent> sorted = events;
    std::stable_sort(sorted.begin(), sorted.end(),
                     [](const SignalEvent &a, const SignalEvent &b) { return a.updatedAt > b.updatedAt; });

    QSet<QString> handled;
    QHash<QString, qint64> resumedAt;
    QList<SessionStatus> result;
    for (const SignalEvent &event : std::as_const(sorted)) {
        const QString key = sourceKey(event);
        if (handled.contains(key)) continue;
        // Newer real work from the same source means the agent got past an older failure.
        if (displayState(event.signal) == DisplayState::Active && !isPassiveActive(event.signal, event.event)) {
            resumedAt[key] = std::max(resumedAt.value(key, event.updatedAt), event.updatedAt);
        } else if (displayState(event.signal) == DisplayState::Blocked && resumedAt.contains(key)
                   && resumedAt[key] > event.updatedAt) {
            handled.insert(key);
            continue;
        }
        if (latestExisting.contains(key) && latestExisting[key].updatedAt >= event.updatedAt
            && !isPresenceSession(latestExisting[key]))
            continue;
        if (supersededByCompleted(event, completed) || supersededByResolving(event, resolving)) continue;
        if (!useRecentEventAsFallback(event, now)) continue;
        handled.insert(key);
        result.append(SessionStatus{"recent-activity:" + key, event.signal, event.updatedAt, event.agent, event.event});
    }
    return result;
}

bool displaySortPrecedes(const SessionStatus &a, const SessionStatus &b) {
    if (priority(a.signal) != priority(b.signal)) return priority(a.signal) > priority(b.signal);
    if (a.updatedAt != b.updatedAt) return a.updatedAt > b.updatedAt;
    return sourceKey(a) < sourceKey(b);
}

QList<SessionStatus> removingSupersededRuntimeAliases(const QList<SessionStatus> &sessions) {
    auto rolloutID = [](const SessionStatus &s) -> std::optional<QUuid> {
        const qsizetype colon = s.sessionID.indexOf(':');
        if (colon < 0) return std::nullopt;
        const QString prefix = s.sessionID.left(colon);
        const QString rest = s.sessionID.mid(colon + 1);
        if ((prefix != "codex-desktop" && prefix != "codex-vscode") || !s.lastEvent.startsWith("Desktop")
            || rest.size() != 36)
            return std::nullopt;
        const QUuid id = QUuid::fromString(rest);
        if (id.isNull()) return std::nullopt;
        return id;
    };
    QHash<QUuid, SessionStatus> newest;
    for (const SessionStatus &s : sessions) {
        const auto id = rolloutID(s);
        if (!id) continue;
        if (newest.contains(*id)) {
            const SessionStatus &prior = newest[*id];
            if (prior.updatedAt > s.updatedAt) continue;
            if (prior.updatedAt == s.updatedAt && prior.agent == "codex-desktop") continue;
        }
        newest[*id] = s;
    }
    QList<SessionStatus> result;
    for (const SessionStatus &s : sessions) {
        const auto id = rolloutID(s);
        if (!id || !newest.contains(*id) || newest[*id].sessionID == s.sessionID) result.append(s);
    }
    return result;
}

bool preferDisplaySession(const SessionStatus &candidate, const SessionStatus &current) {
    const auto resolvingOverride = [](const SessionStatus &a, const SessionStatus &b) {
        return isResolvingSignal(a.signal) && resolvingSupersedes(displayState(b.signal)) && a.updatedAt >= b.updatedAt;
    };
    if (resolvingOverride(candidate, current)) return true;
    if (resolvingOverride(current, candidate)) return false;
    if (isPersistentAlert(displayState(candidate.signal)) || isPersistentAlert(displayState(current.signal))) {
        if (priority(candidate.signal) != priority(current.signal)) return priority(candidate.signal) > priority(current.signal);
    }
    if (candidate.updatedAt != current.updatedAt) return candidate.updatedAt > current.updatedAt;
    return priority(candidate.signal) > priority(current.signal);
}

QString semanticEventKey(const QString &event, const QString &signal) {
    if (event.trimmed().isEmpty()) return normalizedAggregateSignal(signal);
    QString n = event.trimmed().toLower();
    n.replace('_', '-');
    n.replace(' ', '-');
    if (n.startsWith("desktoptoolcall:")) return "tool-call:" + n.mid(16);
    if (n.startsWith("pretooluse:")) return "tool-call:" + n.mid(11);
    if (n.startsWith("posttoolusefailure:")) return QStringLiteral("tool-failed");
    if (n.startsWith("posttooluse:")) return QStringLiteral("tool-done");
    if (n == "desktopthinking" || n == "desktoptaskstarted" || n == "userpromptsubmit") return QStringLiteral("thinking");
    if (n == "desktopmessage" || n == "pretooluse" || n == "tooluse" || n == "tool-use") return QStringLiteral("tool-call");
    if (n == "desktoptooldone" || n == "posttooluse" || n == "posttoolbatch" || n == "function-call-output")
        return QStringLiteral("tool-done");
    if (n == "desktoptaskcomplete" || n == "desktopturnaborted" || n == "stop" || n == "taskcompleted")
        return QStringLiteral("done");
    if (n == "permissionrequest" || n == "permission-request") return QStringLiteral("permission");
    return normalizedAggregateSignal(signal) + ':' + n;
}

QList<SignalEvent> deduplicatedRecentEvents(const QList<SignalEvent> &events) {
    QHash<QString, qint64> acceptedAt;
    QList<SignalEvent> result;
    for (const SignalEvent &event : events) {
        const QString key = sourceKey(event) + '|' + semanticEventKey(event.event, event.signal);
        if (acceptedAt.contains(key) && std::llabs(acceptedAt[key] - event.updatedAt) <= kRecentEventDeduplicationWindow)
            continue;
        acceptedAt[key] = event.updatedAt;
        result.append(event);
    }
    return result;
}

// ActivityPresentation (tray panel / Activity page) variants.
qint64 activeSessionWindow(const SessionStatus &s) {
    return isPassiveActive(s.signal, s.lastEvent) ? kPassiveActiveSessionWindow : kLiveSessionWindow;
}

bool isVisibleSession(const SessionStatus &s, qint64 now) {
    if (isPresenceSession(s) && (displayState(s.signal) == DisplayState::Ready || displayState(s.signal) == DisplayState::Paused))
        return false;
    switch (displayState(s.signal)) {
    case DisplayState::Active: return now - s.updatedAt <= activeSessionWindow(s);
    case DisplayState::Ready:
    case DisplayState::Paused: return false;
    default: return true;
    }
}

bool preferVisibleSession(const SessionStatus &candidate, const SessionStatus &current) {
    const auto resolvingOverride = [](const SessionStatus &a, const SessionStatus &b) {
        const DisplayState as = displayState(a.signal);
        if (!(as == DisplayState::Active || as == DisplayState::Completed) || displayState(b.signal) != DisplayState::Permission
            || a.updatedAt < b.updatedAt)
            return false;
        if (as == DisplayState::Active) return a.updatedAt - b.updatedAt >= kAlertResolutionGraceWindow;
        return true;
    };
    if (resolvingOverride(candidate, current)) return true;
    if (resolvingOverride(current, candidate)) return false;
    if (isPersistentAlert(displayState(candidate.signal)) || isPersistentAlert(displayState(current.signal))) {
        if (priority(candidate.signal) != priority(current.signal)) return priority(candidate.signal) > priority(current.signal);
    }
    if (candidate.updatedAt != current.updatedAt) return candidate.updatedAt > current.updatedAt;
    return priority(candidate.signal) > priority(current.signal);
}

} // namespace

QString normalizedAgentKey(const QString &agent, const QString &fallback) {
    if (agent.trimmed().isEmpty()) return fallback;
    const QString n = normalizedAgentName(agent);
    static const QSet<QString> codex = {"codex", "codex-desktop", "codex-cli", "codex-ide", "codex-xcode",
        "codex-terminal", "terminal-codex", "codex-tui", "codex-shell", "idea-codex", "intellij-codex",
        "jetbrains-codex", "codex-idea", "codex-intellij", "codex-jetbrains", "codex-vscode", "vscode-codex",
        "xcode-codex"};
    static const QSet<QString> claude = {"claude", "claude-code", "claude-desktop", "claude-cli", "claude-terminal",
        "terminal-claude", "claude-ide", "claude-vscode", "vscode-claude", "claude-xcode", "xcode-claude",
        "claude-idea", "claude-intellij", "claude-jetbrains", "idea-claude", "intellij-claude", "jetbrains-claude"};
    if (codex.contains(n)) return QStringLiteral("codex");
    if (claude.contains(n)) return QStringLiteral("claude");
    return n;
}

RuntimeKind runtimeKind(const QString &rawAgent, const QString &rawSessionID, const QString &rawEvent) {
    const QString agent = normalizedAgentName(rawAgent);
    const QString sessionID = rawSessionID.toLower();
    const QString event = rawEvent.toLower();
    if (containsIDEIdentity({agent, sessionID, event})) return RuntimeKind::Ide;
    static const QSet<QString> terminalAgents = {"claude-code", "claude", "claude-cli", "claude-terminal", "codex-cli",
                                                 "codex-terminal", "codex-tui", "codex-shell", "codex"};
    if (terminalAgents.contains(agent) || sessionID.startsWith("claude-cli:") || sessionID.startsWith("codex-cli:"))
        return RuntimeKind::Terminal;
    if (sessionID.startsWith("desktop-app:") || sessionID.startsWith("codex-desktop:") || agent == "codex-desktop"
        || agent == "claude-desktop" || event.startsWith("desktop"))
        return RuntimeKind::Desktop;
    return RuntimeKind::Local;
}

std::optional<QString> sourceDetail(const QString &rawAgent, const QString &rawSessionID, const QString &rawEvent) {
    const QStringList values = {normalizedAgentName(rawAgent), rawSessionID.toLower(), rawEvent.toLower()};
    if (!containsIDEIdentity(values)) return std::nullopt;
    if (containsAny(values, {"idea", "intellij"})) return QStringLiteral("IDEA");
    if (containsAny(values, {"jetbrains"})) return QStringLiteral("JetBrains");
    if (containsAny(values, {"vscode", "vs-code", "visual-studio-code"})) return QStringLiteral("VS Code");
    if (containsAny(values, {"xcode"})) return QStringLiteral("Xcode");
    return QStringLiteral("IDE");
}

QString activitySourceKey(const QString &agent, const QString &sessionID, const QString &event) {
    const QString agentKey = normalizedAgentKey(agent, sessionID);
    if (agentKey != "codex" && agentKey != "claude") return agentKey + ':' + sessionID;
    const RuntimeKind runtime = runtimeKind(agent, sessionID, event);
    if (runtime == RuntimeKind::Ide) {
        if (auto detail = sourceDetail(agent, sessionID, event))
            return agentKey + ":ide:" + detail->toLower().replace(' ', '-');
    }
    switch (runtime) {
    case RuntimeKind::Desktop: return agentKey + ":desktop";
    case RuntimeKind::Terminal: return agentKey + ":terminal";
    case RuntimeKind::Ide: return agentKey + ":ide";
    case RuntimeKind::Local: return agentKey + ":local";
    }
    return agentKey;
}

DisplaySnapshot displaySnapshot(const SignalSnapshot &snapshot, qint64 now) {
    QList<SignalEvent> visibleEvents;
    for (const SignalEvent &e : snapshot.recentEvents) {
        if (!isSignalTestEvent(e.event)) visibleEvents.append(e);
    }
    const auto completed = completionCutoffs(visibleEvents);
    const auto resolving = resolvingCutoffs(visibleEvents);

    QList<SessionStatus> sessions;
    for (const SessionStatus &s : snapshot.sessions) {
        if (shouldIncludeStoredSession(s, now) && !supersededByCompleted(s, completed) && !supersededByResolving(s, resolving))
            sessions.append(s);
    }
    sessions += fallbackSessions(visibleEvents, sessions, completed, resolving, now);
    sessions = removingSupersededRuntimeAliases(sessions);
    std::stable_sort(sessions.begin(), sessions.end(), displaySortPrecedes);

    // deduplicatedDisplaySessions
    QHash<QString, SessionStatus> bySource;
    for (const SessionStatus &s : std::as_const(sessions)) {
        const QString key = sourceKey(s);
        if (!bySource.contains(key) || preferDisplaySession(s, bySource[key])) bySource[key] = s;
    }
    DisplaySnapshot result;
    result.sessions = bySource.values();
    std::stable_sort(result.sessions.begin(), result.sessions.end(), displaySortPrecedes);

    if (!result.sessions.isEmpty()) {
        result.aggregate = normalizedAggregateSignal(result.sessions.first().signal);
    } else {
        const DisplayState fallback = displayState(snapshot.aggregate);
        result.aggregate = (fallback == DisplayState::Paused || fallback == DisplayState::Blocked)
            ? normalizedAggregateSignal(snapshot.aggregate) : QStringLiteral("idle");
    }
    result.recentEvents = deduplicatedRecentEvents(visibleEvents);
    return result;
}

QList<SessionStatus> visibleSessions(const QList<SessionStatus> &sessions, qint64 now, int limit) {
    QHash<QString, qsizetype> indexBySource;
    QList<SessionStatus> result;
    for (const SessionStatus &s : sessions) {
        if (!isVisibleSession(s, now)) continue;
        const QString key = sourceKey(s);
        if (indexBySource.contains(key)) {
            if (preferVisibleSession(s, result[indexBySource[key]])) result[indexBySource[key]] = s;
            continue;
        }
        indexBySource[key] = result.size();
        result.append(s);
    }
    if (limit >= 0 && result.size() > limit) result = result.mid(0, limit);
    return result;
}

QList<SignalEvent> recentEvents(const DisplaySnapshot &snapshot, const QList<SessionStatus> &current, int limit) {
    QSet<QString> sessionKeys;
    QSet<QString> sourceKeys;
    for (const SessionStatus &s : current) {
        sessionKeys.insert(s.sessionID + '|' + s.signal + '|' + s.lastEvent);
        sourceKeys.insert(sourceKey(s) + '|' + s.signal + '|' + s.lastEvent);
    }
    QList<SignalEvent> result;
    for (const SignalEvent &e : snapshot.recentEvents) {
        if (isManualIdleControlEvent(e)) continue;
        if (sessionKeys.contains(e.sessionID + '|' + e.signal + '|' + e.event)
            || sourceKeys.contains(sourceKey(e) + '|' + e.signal + '|' + e.event))
            continue;
        result.append(e);
        if (limit >= 0 && result.size() >= limit) break;
    }
    return result;
}

} // namespace asb::display

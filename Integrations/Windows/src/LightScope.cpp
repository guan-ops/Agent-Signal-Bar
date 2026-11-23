#include "LightScope.h"

#include "I18n.h"
#include "SignalModel.h"

#include <QHash>
#include <algorithm>

namespace asb::light {
namespace {

QString normalizedAgentName(const QString &agent) {
    QString n = agent.trimmed().toLower();
    n.replace('_', '-');
    n.replace(' ', '-');
    return n;
}

bool isSignalTestEvent(const QString &event) { return event == "SignalTest" || event == "SignalTestOff"; }

// ActivityPresentation.isPresenceOnlySession
bool isPresenceOnly(const SessionStatus &s) {
    const bool presence = s.sessionID.startsWith("desktop-app:") || s.sessionID.startsWith("platform-presence:")
        || s.lastEvent == "DesktopAppRunning" || s.lastEvent.startsWith("PlatformPresence:");
    const DisplayState state = displayState(s.signal);
    return presence && (state == DisplayState::Ready || state == DisplayState::Paused);
}

const QStringList &codexCases() {
    static const QStringList cases = {"codex-desktop", "codex-cli", "codex-vscode", "codex-xcode", "codex-idea"};
    return cases;
}

const QStringList &claudeCases() {
    static const QStringList cases = {"claude-code"};
    return cases;
}

const QStringList &selectableCases() {
    static const QStringList cases = {"codex-desktop", "codex-cli", "codex-vscode", "codex-xcode", "codex-idea",
                                      "claude-code", "local-script"};
    return cases;
}

int sortOrder(const QString &scope) {
    static const QStringList order = {"codex-desktop", "codex-cli", "codex-vscode", "codex-xcode", "codex-idea",
                                      "claude-code", "claude-desktop", "local-script"};
    if (scope == "codex") return 100;
    if (scope == "claude") return 101;
    const qsizetype index = order.indexOf(scope);
    return index < 0 ? 1000 : int(index);
}

bool sameSet(QStringList a, QStringList b) {
    a.removeDuplicates();
    b.removeDuplicates();
    std::sort(a.begin(), a.end());
    std::sort(b.begin(), b.end());
    return a == b;
}

bool matchesAny(const QStringList &scopes, const SessionStatus &s) {
    return std::any_of(scopes.cbegin(), scopes.cend(), [&](const QString &scope) { return matches(scope, s); });
}

// isFollowCandidateSession
bool isFollowCandidate(const SessionStatus &s) {
    return !isSignalTestEvent(s.lastEvent) && !isPresenceOnly(s) && displayState(s.signal) != DisplayState::Paused;
}

// followedSignalLightAgentScope: the scope whose most important session ranks highest, then the
// most recent, then the earlier scope.
std::optional<QString> followedScope(const QList<SessionStatus> &sessions, const QStringList &among) {
    std::optional<QString> best;
    int bestPriority = -1;
    qint64 bestUpdatedAt = 0;
    for (const QString &scope : among) {
        std::optional<SessionStatus> top;
        for (const SessionStatus &s : sessions) {
            if (!matches(scope, s) || !isFollowCandidate(s)) continue;
            if (!top || priority(s.signal) > priority(top->signal)
                || (priority(s.signal) == priority(top->signal) && s.updatedAt > top->updatedAt))
                top = s;
        }
        if (!top) continue;
        const int p = priority(top->signal);
        const bool better = !best || p > bestPriority || (p == bestPriority && top->updatedAt > bestUpdatedAt)
            || (p == bestPriority && top->updatedAt == bestUpdatedAt && sortOrder(scope) < sortOrder(*best));
        if (better) {
            best = scope;
            bestPriority = p;
            bestUpdatedAt = top->updatedAt;
        }
    }
    return best;
}

std::optional<DisplayState> topState(const QString &scope, const QList<SessionStatus> &sessions) {
    std::optional<DisplayState> top;
    for (const SessionStatus &s : sessions) {
        if (!matches(scope, s) || !isFollowCandidate(s)) continue;
        const DisplayState state = displayState(s.signal);
        if (!top || priority(state) > priority(*top)) top = state;
    }
    return top;
}

// stickySignalLightScope: keep the previous agent while it is still working and the candidate
// is no more urgent; anything waiting, failing or blocked takes over at once.
std::optional<QString> sticky(const std::optional<QString> &candidate, const std::optional<QString> &previous,
                              const QList<SessionStatus> &sessions) {
    if (!candidate) return std::nullopt;
    if (!previous || *previous == *candidate) return candidate;
    const auto previousState = topState(*previous, sessions);
    if (!previousState || *previousState != DisplayState::Active) return candidate;
    const auto candidateState = topState(*candidate, sessions);
    if (!candidateState || priority(*candidateState) != priority(*previousState)) return candidate;
    return previous;
}

} // namespace

bool matches(const QString &scope, const SessionStatus &session) {
    const QString sourceKey = display::activitySourceKey(session.agent, session.sessionID, session.lastEvent);
    const QString agent = normalizedAgentName(session.agent);
    const QString id = session.sessionID.toLower();
    if (scope == "codex") return sourceKey.startsWith("codex:");
    if (scope == "claude") return sourceKey.startsWith("claude:");
    if (scope == "codex-desktop")
        return sourceKey == "codex:desktop" || agent == "codex-desktop" || id.startsWith("codex-desktop:");
    if (scope == "codex-cli")
        return sourceKey == "codex:terminal" || agent == "codex-cli" || agent == "codex-terminal"
            || id.startsWith("codex-cli:");
    if (scope == "codex-vscode")
        return sourceKey == "codex:ide:vs-code" || agent == "codex-vscode" || agent == "vscode-codex"
            || id.startsWith("codex-vscode:");
    if (scope == "codex-xcode")
        return sourceKey == "codex:ide:xcode" || agent == "codex-xcode" || agent == "xcode-codex"
            || id.startsWith("codex-xcode:");
    if (scope == "codex-idea")
        return sourceKey == "codex:ide:idea" || sourceKey == "codex:ide:jetbrains" || agent == "codex-idea"
            || agent == "codex-intellij" || agent == "codex-jetbrains" || id.startsWith("codex-idea:");
    if (scope == "claude-code")
        return sourceKey.startsWith("claude:") || agent == "claude-code" || agent == "claude-cli"
            || agent == "claude-desktop" || id.startsWith("claude-code:") || id.startsWith("claude-cli:")
            || id.startsWith("claude-desktop:");
    if (scope == "claude-desktop")
        return sourceKey == "claude:desktop" || agent == "claude-desktop" || id.startsWith("claude-desktop:");
    if (scope == "local-script")
        return !sourceKey.startsWith("codex:") && !sourceKey.startsWith("claude:") && !agent.isEmpty();
    return false;
}

const QStringList &visibleScopes() {
    static const QStringList cases = {"codex-desktop", "codex-cli", "codex-vscode", "codex-xcode", "codex-idea",
                                      "claude-code"};
    return cases;
}

QStringList scopesForPreference(const QString &preference) {
    if (preference == "codex") return codexCases();
    if (preference == "claude") return claudeCases();
    static const QHash<QString, QString> single = {
        {"codexDesktop", "codex-desktop"}, {"codexCLI", "codex-cli"}, {"codexVSCode", "codex-vscode"},
        {"codexXcode", "codex-xcode"},     {"codexIDEA", "codex-idea"}, {"localScript", "local-script"}};
    if (single.contains(preference)) return {single.value(preference)};
    return {};
}

QString displayName(const QString &scope, bool zh) {
    const auto t = [zh](const char *c, const char *e) { return zh ? QString::fromUtf8(c) : i18n::translate(QString::fromUtf8(e)); };
    if (scope == "codex") return QStringLiteral("Codex");
    if (scope == "claude") return QStringLiteral("Claude");
    if (scope == "codex-desktop") return t("Codex 桌面版", "Codex Desktop");
    if (scope == "codex-cli") return t("Codex 终端", "Codex CLI");
    if (scope == "codex-vscode") return QStringLiteral("Codex VS Code");
    if (scope == "codex-xcode") return QStringLiteral("Codex Xcode");
    if (scope == "codex-idea") return QStringLiteral("Codex IDEA");
    if (scope == "claude-code") return t("Claude 桌面版", "Claude Desktop"); // as macOS names it
    if (scope == "claude-desktop") return QStringLiteral("Claude Desktop");
    if (scope == "local-script") return t("本地脚本", "Local Script");
    return scope;
}

QString displayName(const QStringList &scopes, bool zh) {
    QStringList normalized;
    for (const QString &s : scopes)
        if (selectableCases().contains(s) && !normalized.contains(s)) normalized.append(s);
    if (normalized.isEmpty()) return zh ? QStringLiteral("选择 Agent") : i18n::translate(QStringLiteral("Select Agent"));
    if (sameSet(normalized, selectableCases())) return zh ? QStringLiteral("全部 Agent") : i18n::translate(QStringLiteral("All Agents"));
    if (sameSet(normalized, codexCases())) return QStringLiteral("Codex");
    if (sameSet(normalized, claudeCases())) return QStringLiteral("Claude");
    if (normalized.size() == 1) return displayName(normalized.first(), zh);
    return zh ? QStringLiteral("已选 %1 个").arg(normalized.size()) : QStringLiteral("%1 selected").arg(normalized.size());
}

void Selector::reset() {
    m_followed.reset();
    m_borrowed.reset();
}

Selection Selector::select(const display::DisplaySnapshot &display, bool following, const QStringList &selected,
                           bool idleFallback) {
    const QList<SessionStatus> &sessions = display.sessions;
    Selection result;

    // signalLightAgentScopesForDisplay
    if (following) {
        m_followed = sticky(followedScope(sessions, visibleScopes()), m_followed, sessions);
        if (m_followed) result.scopes = {*m_followed};
    } else {
        for (const QString &scope : selected)
            if (visibleScopes().contains(scope)) result.scopes.append(scope);
    }

    // signalLightIdleFallbackScope: only in manual mode, and only while no chosen agent has
    // anything beyond an idle session.
    if (idleFallback && !following && !result.scopes.isEmpty()) {
        const auto hasActivity = [](const SessionStatus &s) {
            return isFollowCandidate(s) && displayState(s.signal) != DisplayState::Ready;
        };
        const bool selectedBusy = std::any_of(sessions.cbegin(), sessions.cend(), [&](const SessionStatus &s) {
            return matchesAny(result.scopes, s) && hasActivity(s);
        });
        if (!selectedBusy) {
            QStringList others;
            for (const QString &scope : visibleScopes())
                if (!result.scopes.contains(scope)) others.append(scope);
            QList<SessionStatus> otherSessions;
            for (const SessionStatus &s : sessions)
                if (hasActivity(s) && !matchesAny(result.scopes, s)) otherSessions.append(s);
            m_borrowed = sticky(followedScope(otherSessions, others), m_borrowed, otherSessions);
            result.borrowed = m_borrowed;
        }
    }

    // displaySnapshot scoped to the shown agents, then aggregateForSignalLightScopes.
    const QStringList shown = result.borrowed ? QStringList{*result.borrowed} : result.scopes;
    std::optional<QString> top;
    for (const SessionStatus &s : sessions) {
        if (!matchesAny(shown, s)) continue;
        ++result.sessionCount;
        result.updatedAt = std::max(result.updatedAt.value_or(s.updatedAt), s.updatedAt);
        if (!top || priority(s.signal) > priority(*top)) top = s.signal;
    }
    if (top) {
        result.aggregate = normalizedAggregateSignal(*top);
    } else {
        // fallbackForEmptySignalLightSessions / fallbackForEmptyDisplaySessions
        const DisplayState fallback = displayState(display.storedAggregate);
        const bool keep = (!following && !shown.isEmpty()) ? fallback == DisplayState::Paused
                                                           : (fallback == DisplayState::Paused || fallback == DisplayState::Blocked);
        result.aggregate = keep ? normalizedAggregateSignal(display.storedAggregate) : QStringLiteral("idle");
    }
    return result;
}

QString followingText(const Selection &selection, bool following, bool zh) {
    if (selection.borrowed) return (zh ? QStringLiteral("暂时显示 ") : QStringLiteral("Showing ")) + displayName(*selection.borrowed, zh);
    if (following) {
        if (selection.scopes.isEmpty()) return zh ? QStringLiteral("自动跟随") : i18n::translate(QStringLiteral("Auto Follow"));
        return (zh ? QStringLiteral("自动跟随 · ") : QStringLiteral("Following ")) + displayName(selection.scopes, zh);
    }
    return selection.scopes.isEmpty() ? QString() : displayName(selection.scopes, zh);
}

QString unavailableHint(const Selection &selection, const QStringList &selected, bool following,
                        const QList<SessionStatus> &visibleSessions, bool zh) {
    if (following) return {};
    if (selection.borrowed) {
        const QString name = displayName(*selection.borrowed, zh);
        return zh ? QStringLiteral("已选 Agent 空闲，灯效暂时显示 %1 的状态；已选 Agent 开始工作后自动切回。").arg(name)
                  : QStringLiteral("The selected agent is idle, so the light shows %1 until the selected agent starts working.").arg(name);
    }
    QStringList selectedVisible;
    for (const QString &scope : selected)
        if (visibleScopes().contains(scope)) selectedVisible.append(scope);
    if (selectedVisible.isEmpty()) return {};
    const bool selectedRunning = std::any_of(visibleSessions.cbegin(), visibleSessions.cend(),
                                             [&](const SessionStatus &s) { return matchesAny(selectedVisible, s); });
    if (selectedRunning) return {};
    const bool othersRunning = std::any_of(visibleScopes().cbegin(), visibleScopes().cend(), [&](const QString &scope) {
        return !selectedVisible.contains(scope)
            && std::any_of(visibleSessions.cbegin(), visibleSessions.cend(), [&](const SessionStatus &s) { return matches(scope, s); });
    });
    if (!othersRunning) return {};
    return zh ? QStringLiteral("已选 Agent 尚未运行。其他 Agent 正在运行，可在灯效 Agent 中切换。")
              : QStringLiteral("The selected agent is not running. Other agents are running; switch in Light Agent if needed.");
}

} // namespace asb::light

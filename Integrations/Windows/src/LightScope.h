// Which agents the lamp follows. Port of MenuBarStatusModel.swift: SignalLightAgentScope
// (matches, sortOrder, displayName), displaySnapshot's light scoping,
// signalLightAgentScopesForDisplay, signalLightIdleFallbackScope, stickySignalLightScope,
// followedSignalLightAgentScope and aggregateForSignalLightScopes.
//
// Automatic mode follows the agent that most needs attention and keeps following it while two
// agents are both just working; manual mode shows the chosen agents and, while all of them are
// idle, can borrow the busiest other agent.
#pragma once

#include "ActivityDisplay.h"

#include <QStringList>
#include <optional>

namespace asb::light {

// Scope raw values (SignalLightAgentScope): codex-desktop, codex-cli, codex-vscode,
// codex-xcode, codex-idea, claude-code, claude-desktop, local-script; groups codex, claude.
bool matches(const QString &scope, const SessionStatus &session);
// SignalLightAgentScope.visibleCases, in order.
const QStringList &visibleScopes();
// The scopes for one value of the Windows "Follow" dropdown (macOS stores a scope set):
// empty for "following".
QStringList scopesForPreference(const QString &preference);
QString displayName(const QString &scope, bool zh);
QString displayName(const QStringList &scopes, bool zh);

struct Selection {
    QString aggregate = QStringLiteral("idle"); // what the lamp shows, before pause/debug overrides
    QStringList scopes;                          // displaySignalLightAgentScopes
    std::optional<QString> borrowed;             // signalLightIdleFallbackScope
    int sessionCount = 0;                        // sessions in the shown scopes
    std::optional<qint64> updatedAt;             // newest of those sessions
};

class Selector {
public:
    Selection select(const display::DisplaySnapshot &display, bool following, const QStringList &selected,
                     bool idleFallback);
    // A new mode or selection starts without the sticky choices (followSignalLightAutomatically).
    void reset();

private:
    std::optional<QString> m_followed;
    std::optional<QString> m_borrowed;
};

// signalLightFollowingText: "自动跟随 · Codex 终端", "暂时显示 Claude 桌面版", or the selection.
QString followingText(const Selection &selection, bool following, bool zh);
// signalLightAgentUnavailableHint (manual mode only).
QString unavailableHint(const Selection &selection, const QStringList &selected, bool following,
                        const QList<SessionStatus> &visibleSessions, bool zh);

} // namespace asb::light

// What the lamp, the tray panel and the Activity page show for a store snapshot. Port of
// ActivityPresentation.swift and the display rules in MenuBarStatusModel.swift
// (combinedDisplaySessions, deduplicatedDisplaySessions, aggregateForSessions,
// deduplicatedRecentEvents). Desktop-app presence sessions and per-agent light scopes are
// not ported: Windows only monitors Codex so far, so every session is in scope.
#pragma once

#include "SignalStore.h"

#include <optional>

namespace asb::display {

enum class RuntimeKind { Desktop, Terminal, Ide, Local };

RuntimeKind runtimeKind(const QString &agent, const QString &sessionID, const QString &event);
std::optional<QString> sourceDetail(const QString &agent, const QString &sessionID, const QString &event);
QString activitySourceKey(const QString &agent, const QString &sessionID, const QString &event);
QString normalizedAgentKey(const QString &agent, const QString &fallback);

struct DisplaySnapshot {
    QString aggregate = QStringLiteral("idle"); // every agent, before light scopes and overrides
    QString storedAggregate = QStringLiteral("idle"); // status.json's own aggregate (the fallback)
    QList<SessionStatus> sessions;              // deduplicated per source, display order
    QList<SignalEvent> recentEvents;            // deduplicated, newest first
};

// MenuBarStatusModel.activitySnapshot (and displaySnapshot with every agent in scope).
// `presence` are the running apps (PresenceMonitor); each joins as an idle session unless a live
// session of the same source already shows it (combinedDisplaySessions).
DisplaySnapshot displaySnapshot(const SignalSnapshot &snapshot, qint64 now, const QList<SessionStatus> &presence = {});

// ActivityPresentation.visibleDesktopPresenceSessions: the open desktop apps, listed while no
// session is running.
QList<SessionStatus> visibleDesktopPresenceSessions(const QList<SessionStatus> &sessions, int limit = -1);

// ActivityPresentation.visibleSessions: what the tray panel and Activity page list.
QList<SessionStatus> visibleSessions(const QList<SessionStatus> &sessions, qint64 now, int limit = -1);
// ActivityPresentation.recentEvents(from:excluding:).
QList<SignalEvent> recentEvents(const DisplaySnapshot &snapshot, const QList<SessionStatus> &current, int limit = -1);

} // namespace asb::display

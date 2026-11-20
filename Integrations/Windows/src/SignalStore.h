// Port of AgentSignalLightCore SignalStateStore + SignalStateDocument: the rules engine.
// SignalStateFile loads it from and saves it to status.json (same keys as macOS), which the
// app and agent-signal.exe (Claude Code hooks) share. Times are Unix milliseconds and `now`
// is passed in so tests can drive the clock. tests/tst_codex.cpp replays sequences
// generated from the Swift store.
#pragma once

#include <QJsonObject>
#include <QList>
#include <QMap>
#include <QString>
#include <optional>

namespace asb {

struct SessionRecord {
    QString agent;
    QString signal; // canonical AgentSignal raw value
    QString lastEvent;
    qint64 updatedAt = 0;
};

struct SessionStatus {
    QString sessionID;
    QString signal;
    qint64 updatedAt = 0;
    QString agent;
    QString lastEvent;
};

struct SignalEvent {
    QString id;
    QString sessionID;
    QString agent;
    QString signal;
    QString event;
    qint64 updatedAt = 0;
};

struct SignalSnapshot {
    QString aggregate = QStringLiteral("idle");
    QList<SessionStatus> sessions;   // priority desc, then newest first
    QList<SignalEvent> recentEvents; // newest first
    std::optional<qint64> updatedAt;
};

class SignalStore {
public:
    static constexpr qint64 kDefaultSessionTTLms = 30 * 60 * 1000;
    static constexpr qint64 kDefaultCompletedTTLms = 30 * 1000;
    static constexpr int kDefaultEventLimit = 50;

    SignalStore(qint64 sessionTTLms = kDefaultSessionTTLms, qint64 completedTTLms = kDefaultCompletedTTLms,
                int eventLimit = kDefaultEventLimit);

    // SignalStateStore.applySessionSignal. `signal` must be a canonical raw value.
    SignalSnapshot applySessionSignal(const QString &signal, const QString &sessionID, const QString &agent,
                                      const QString &lastEvent, qint64 eventDate, qint64 now);
    // SignalStateStore.readSnapshot: prunes expired sessions first.
    SignalSnapshot readSnapshot(qint64 now);
    void clear();

    // SignalStateDocument coding: schema_version, aggregate, updated_at, sessions
    // {agent, signal, last_event, updated_at}, events [{id, session_id, agent, signal, event,
    // updated_at}]. Dates are ISO 8601 (written with milliseconds; read with or without them,
    // or as Unix seconds). A document that does not decode becomes {aggregate: stale}, as on
    // macOS.
    QJsonObject toJson() const;
    void loadJson(const QJsonObject &document, qint64 now);
    static SignalStore staleDocument(qint64 now);

private:
    struct PruneResult {
        bool hadSessionsBeforePrune = false;
        bool removedNonCompletedSession = false;
    };

    PruneResult prune(qint64 now);
    qint64 ttlFor(const QString &signal) const;
    void updateAggregateAfterPruning(const PruneResult &result);
    QString aggregateSignal() const;
    void appendEvent(const QString &sessionID, const QString &agent, const QString &signal, const QString &event,
                     qint64 updatedAt);
    void compactEvents();
    SignalSnapshot snapshot() const;

    qint64 m_sessionTTL;
    qint64 m_completedTTL;
    int m_eventLimit;
    std::optional<QString> m_aggregate;
    std::optional<qint64> m_updatedAt;
    QMap<QString, SessionRecord> m_sessions;
    QList<SignalEvent> m_events; // oldest first, like the Swift document
};

} // namespace asb

#include "SignalStore.h"

#include "SignalModel.h"

#include <QDateTime>
#include <QJsonArray>
#include <QTimeZone>
#include <QUuid>
#include <algorithm>
#include <cstdlib>

namespace asb {
namespace {

constexpr qint64 kDuplicateEventWindowMs = 4000;
constexpr qint64 kTransientAlertHoldWindowMs = 5000;

bool preserveAgainstSessionEnd(const QString &signal) {
    switch (displayState(signal)) {
    case DisplayState::Completed:
    case DisplayState::NeedsReview:
    case DisplayState::Blocked:
    case DisplayState::Stale:
    case DisplayState::Paused: return true;
    default: return false;
    }
}

bool preserveAgainstCompleted(const QString &signal) {
    const DisplayState s = displayState(signal);
    return s == DisplayState::Blocked || s == DisplayState::Stale || s == DisplayState::Paused;
}

bool isShortLivedSignal(const QString &signal) {
    return signal == "done" || signal == "tool_done" || signal == "subagent_stop";
}

bool expiredSessionMarksStale(const QString &signal) {
    if (isShortLivedSignal(signal) || signal == "idle" || signal == "session_start" || signal == "session_end"
        || signal == "turn_end")
        return false;
    return displayState(signal) != DisplayState::Completed;
}

bool isTransientAlert(DisplayState s) { return s == DisplayState::Permission || s == DisplayState::NeedsReview; }

bool isResolvingOrLowerPriorityAlert(DisplayState s) {
    return s == DisplayState::Active || s == DisplayState::Completed || s == DisplayState::NeedsReview;
}

QString normalizedKeyPart(const QString &value) {
    QString n = value.trimmed().toLower();
    n.replace('_', '-');
    n.replace(' ', '-');
    return n;
}

QString deduplicationKey(const SignalEvent &e) {
    const QString event = e.event.isEmpty() ? e.signal : normalizedKeyPart(e.event);
    return e.sessionID + '|' + normalizedKeyPart(e.agent) + '|' + e.signal + '|' + event;
}

// SignalStateStore.decodeDate: ISO 8601 (with or without fractional seconds) or Unix seconds.
std::optional<qint64> decodeDate(const QJsonValue &value) {
    if (value.isDouble()) return qint64(value.toDouble() * 1000);
    if (!value.isString()) return std::nullopt;
    const QDateTime parsed = QDateTime::fromString(value.toString(), Qt::ISODateWithMs);
    if (!parsed.isValid()) return std::nullopt;
    return parsed.toMSecsSinceEpoch();
}

QString encodeDate(qint64 ms) {
    return QDateTime::fromMSecsSinceEpoch(ms, QTimeZone::UTC).toString(Qt::ISODateWithMs);
}

// AgentSignal(rawValue:) is strict: aliases are not accepted when decoding a document.
bool isRawSignal(const QString &value) { return normalizedSignal(value) == value; }

void removeDuplicate(const SignalEvent &event, QList<SignalEvent> &events) {
    const QString key = deduplicationKey(event);
    for (qsizetype i = events.size() - 1; i >= 0; --i) {
        if (deduplicationKey(events[i]) == key && std::llabs(events[i].updatedAt - event.updatedAt) <= kDuplicateEventWindowMs) {
            events.removeAt(i);
            return;
        }
    }
}

} // namespace

SignalStore::SignalStore(qint64 sessionTTLms, qint64 completedTTLms, int eventLimit)
    : m_sessionTTL(sessionTTLms), m_completedTTL(completedTTLms), m_eventLimit(eventLimit) {}

void SignalStore::clear() {
    m_aggregate.reset();
    m_updatedAt.reset();
    m_sessions.clear();
    m_events.clear();
}

qint64 SignalStore::ttlFor(const QString &signal) const {
    return isShortLivedSignal(signal) ? m_completedTTL : m_sessionTTL;
}

SignalStore::PruneResult SignalStore::prune(qint64 now) {
    PruneResult result;
    result.hadSessionsBeforePrune = !m_sessions.isEmpty();
    for (auto it = m_sessions.begin(); it != m_sessions.end();) {
        if (now - it->updatedAt > ttlFor(it->signal)) {
            if (expiredSessionMarksStale(it->signal)) result.removedNonCompletedSession = true;
            it = m_sessions.erase(it);
        } else {
            ++it;
        }
    }
    return result;
}

void SignalStore::updateAggregateAfterPruning(const PruneResult &result) {
    const bool paused = m_aggregate && displayState(*m_aggregate) == DisplayState::Paused;
    if (result.hadSessionsBeforePrune && m_sessions.isEmpty() && !paused)
        m_aggregate = result.removedNonCompletedSession ? QStringLiteral("stale") : QStringLiteral("idle");
    else if (!m_sessions.isEmpty())
        m_aggregate = aggregateSignal();
}

QString SignalStore::aggregateSignal() const {
    // Swift takes the first maximum in dictionary order, which is unspecified. Prefer the
    // most recent session among equal priorities so the result is stable.
    const SessionRecord *best = nullptr;
    for (const SessionRecord &record : m_sessions) {
        if (!best || priority(record.signal) > priority(best->signal)
            || (priority(record.signal) == priority(best->signal) && record.updatedAt > best->updatedAt))
            best = &record;
    }
    if (best) return normalizedAggregateSignal(best->signal);
    if (m_aggregate) return normalizedAggregateSignal(*m_aggregate);
    return QStringLiteral("idle");
}

void SignalStore::compactEvents() {
    QList<SignalEvent> compacted;
    for (const SignalEvent &event : std::as_const(m_events)) {
        removeDuplicate(event, compacted);
        compacted.append(event);
    }
    if (compacted.size() > m_eventLimit) compacted = compacted.mid(compacted.size() - m_eventLimit);
    m_events = compacted;
}

void SignalStore::appendEvent(const QString &sessionID, const QString &agent, const QString &signal,
                              const QString &event, qint64 updatedAt) {
    // UUIDs, like the Swift store: the app and agent-signal.exe both append events.
    SignalEvent record{QUuid::createUuid().toString(QUuid::WithoutBraces).toUpper(), sessionID, agent, signal, event,
                       updatedAt};
    removeDuplicate(record, m_events);
    m_events.append(record);
    compactEvents();
}

SignalSnapshot SignalStore::applySessionSignal(const QString &signal, const QString &sessionID, const QString &agent,
                                               const QString &lastEvent, qint64 eventDate, qint64 now) {
    const std::optional<SessionRecord> existingBeforePrune =
        m_sessions.contains(sessionID) ? std::optional(m_sessions.value(sessionID)) : std::nullopt;
    if (existingBeforePrune && existingBeforePrune->updatedAt > eventDate) return snapshot();

    const PruneResult pruneResult = prune(now);
    const std::optional<SessionRecord> existing =
        m_sessions.contains(sessionID) ? std::optional(m_sessions.value(sessionID)) : existingBeforePrune;

    // A completed session ignores passive activity replayed after it finished.
    if (existing && displayState(existing->signal) == DisplayState::Completed
        && displayState(signal) == DisplayState::Active
        && (lastEvent == "DesktopActivityHeartbeat" || lastEvent == "DesktopThinking" || lastEvent == "DesktopMessage"
            || lastEvent == "DesktopToolDone")) {
        updateAggregateAfterPruning(pruneResult);
        return snapshot();
    }

    const bool holdCurrentAlert = existing && isTransientAlert(displayState(existing->signal))
        && isResolvingOrLowerPriorityAlert(displayState(signal))
        && eventDate - existing->updatedAt <= kTransientAlertHoldWindowMs;

    const QString keptAgent = !agent.isEmpty() ? agent : (existingBeforePrune ? existingBeforePrune->agent : QString());
    auto record = [&](const QString &recordSignal) {
        return SessionRecord{keptAgent, recordSignal, lastEvent, eventDate};
    };
    auto clearToIdleIfEmpty = [&] {
        if (m_sessions.isEmpty() && !(m_aggregate && displayState(*m_aggregate) == DisplayState::Paused))
            m_aggregate = QStringLiteral("idle");
    };

    if (signal == "off" || signal == "pause" || signal == "paused") {
        m_sessions.clear();
        m_aggregate = QStringLiteral("off");
    } else if (signal == "session_end") {
        if (!m_sessions.contains(sessionID) || !preserveAgainstSessionEnd(m_sessions.value(sessionID).signal))
            m_sessions.remove(sessionID);
        clearToIdleIfEmpty();
    } else if (signal == "turn_end") {
        if (!m_sessions.contains(sessionID) || displayState(m_sessions.value(sessionID).signal) != DisplayState::Blocked)
            m_sessions.remove(sessionID);
        clearToIdleIfEmpty();
    } else if (signal == "idle" || signal == "session_start") {
        m_sessions.insert(sessionID, record(QStringLiteral("idle")));
    } else if (signal == "done") {
        if (!m_sessions.contains(sessionID) || !preserveAgainstCompleted(m_sessions.value(sessionID).signal))
            m_sessions.insert(sessionID, record(signal));
    } else if (!holdCurrentAlert) {
        m_sessions.insert(sessionID, record(signal));
    }

    if (displayState(signal) != DisplayState::Paused) m_aggregate = aggregateSignal();
    appendEvent(sessionID, agent, signal, lastEvent, eventDate);
    m_updatedAt = eventDate;
    return snapshot();
}

SignalSnapshot SignalStore::readSnapshot(qint64 now) {
    const PruneResult result = prune(now);
    compactEvents();
    updateAggregateAfterPruning(result);
    return snapshot();
}

SignalSnapshot SignalStore::setManualSignal(const QString &signal, qint64 now) {
    QString resolved = signal;
    if (signal == "session_start" || signal == "session_end" || signal == "turn_end") resolved = QStringLiteral("idle");
    prune(now);
    switch (displayState(resolved)) {
    case DisplayState::Ready:
        m_sessions.clear();
        m_aggregate = QStringLiteral("idle");
        break;
    case DisplayState::Paused:
        m_sessions.clear();
        m_aggregate = normalizedAggregateSignal(resolved);
        break;
    default:
        m_sessions.insert(QStringLiteral("manual"), SessionRecord{QStringLiteral("manual"), resolved, QStringLiteral("ManualSet"), now});
        m_aggregate = aggregateSignal();
        break;
    }
    appendEvent(QStringLiteral("manual"), QStringLiteral("manual"), resolved, QStringLiteral("ManualSet"), now);
    m_updatedAt = now;
    return snapshot();
}

SignalStore SignalStore::staleDocument(qint64 now) {
    SignalStore store;
    store.m_aggregate = QStringLiteral("stale");
    store.m_updatedAt = now;
    return store;
}

QJsonObject SignalStore::toJson() const {
    QJsonObject document{{"schema_version", 1}};
    if (m_aggregate) document.insert("aggregate", *m_aggregate);
    if (m_updatedAt) document.insert("updated_at", encodeDate(*m_updatedAt));
    QJsonObject sessions;
    for (auto it = m_sessions.cbegin(); it != m_sessions.cend(); ++it) {
        QJsonObject record{{"signal", it->signal}, {"updated_at", encodeDate(it->updatedAt)}};
        if (!it->agent.isEmpty()) record.insert("agent", it->agent);
        if (!it->lastEvent.isEmpty()) record.insert("last_event", it->lastEvent);
        sessions.insert(it.key(), record);
    }
    document.insert("sessions", sessions);
    QJsonArray events;
    for (const SignalEvent &e : m_events) {
        QJsonObject record{{"id", e.id}, {"session_id", e.sessionID}, {"signal", e.signal},
                           {"updated_at", encodeDate(e.updatedAt)}};
        if (!e.agent.isEmpty()) record.insert("agent", e.agent);
        if (!e.event.isEmpty()) record.insert("event", e.event);
        events.append(record);
    }
    document.insert("events", events);
    return document;
}

void SignalStore::loadJson(const QJsonObject &document, qint64 now) {
    clear();
    const auto fail = [&] { *this = staleDocument(now); };
    if (document.contains("aggregate")) {
        const QJsonValue aggregate = document.value("aggregate");
        if (!aggregate.isString() || !isRawSignal(aggregate.toString())) return fail();
        m_aggregate = aggregate.toString();
    }
    if (document.contains("updated_at")) {
        const auto updated = decodeDate(document.value("updated_at"));
        if (!updated) return fail();
        m_updatedAt = *updated;
    }
    if (document.contains("sessions")) {
        if (!document.value("sessions").isObject()) return fail();
        const QJsonObject sessions = document.value("sessions").toObject();
        for (auto it = sessions.constBegin(); it != sessions.constEnd(); ++it) {
            const QJsonObject r = it.value().toObject();
            const QString signal = r.value("signal").toString();
            const auto updated = decodeDate(r.value("updated_at"));
            if (!it.value().isObject() || !isRawSignal(signal) || !updated) return fail();
            m_sessions.insert(it.key(), SessionRecord{r.value("agent").toString(), signal,
                                                      r.value("last_event").toString(), *updated});
        }
    }
    if (document.contains("events")) {
        if (!document.value("events").isArray()) return fail();
        for (const QJsonValue &value : document.value("events").toArray()) {
            const QJsonObject r = value.toObject();
            const QString signal = r.value("signal").toString();
            const auto updated = decodeDate(r.value("updated_at"));
            if (!value.isObject() || !r.value("id").isString() || !r.value("session_id").isString()
                || !isRawSignal(signal) || !updated)
                return fail();
            m_events.append(SignalEvent{r.value("id").toString(), r.value("session_id").toString(),
                                        r.value("agent").toString(), signal, r.value("event").toString(), *updated});
        }
    }
}

SignalSnapshot SignalStore::snapshot() const {
    SignalSnapshot s;
    s.updatedAt = m_updatedAt;
    for (auto it = m_sessions.cbegin(); it != m_sessions.cend(); ++it)
        s.sessions.append(SessionStatus{it.key(), it->signal, it->updatedAt, it->agent, it->lastEvent});
    std::stable_sort(s.sessions.begin(), s.sessions.end(), [](const SessionStatus &a, const SessionStatus &b) {
        if (priority(a.signal) != priority(b.signal)) return priority(a.signal) > priority(b.signal);
        return a.updatedAt > b.updatedAt;
    });
    for (auto it = m_events.crbegin(); it != m_events.crend(); ++it) s.recentEvents.append(*it);

    // SignalStateDocument.aggregateSignal() over the stored sessions, else the stored aggregate.
    const SessionStatus *best = nullptr;
    for (const SessionStatus &session : std::as_const(s.sessions)) {
        if (!best || priority(session.signal) > priority(best->signal)) best = &session;
    }
    if (best) s.aggregate = normalizedAggregateSignal(best->signal);
    else if (m_aggregate) s.aggregate = normalizedAggregateSignal(*m_aggregate);
    return s;
}

} // namespace asb

#include "SignalStore.h"

#include "SignalModel.h"

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
    SignalEvent record{QString::number(m_nextEventID++), sessionID, agent, signal, event, updatedAt};
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

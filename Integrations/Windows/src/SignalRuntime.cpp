#include "SignalRuntime.h"

#include <QDateTime>
#include <utility>

namespace {
qint64 nowMs() { return QDateTime::currentMSecsSinceEpoch(); }
constexpr int kCurrentSessionLimit = 6; // ActivityPresentation.currentSessionLimit
constexpr int kRecentEventLimit = 20;
} // namespace

SignalRuntime::SignalRuntime(QObject *parent) : QObject(parent) {
    m_thread.setObjectName("codex-monitor");
    m_worker = new QObject;
    m_worker->moveToThread(&m_thread);
    connect(&m_thread, &QThread::finished, m_worker, &QObject::deleteLater);
    connect(&m_pollTimer, &QTimer::timeout, this, &SignalRuntime::poll);
    connect(&m_refreshTimer, &QTimer::timeout, this, &SignalRuntime::refresh);
}

SignalRuntime::~SignalRuntime() {
    m_thread.quit();
    m_thread.wait();
}

void SignalRuntime::start(const QList<asb::codex::Root> &roots, bool lowPower, bool replayRecentHistory) {
    m_lowPower = lowPower;
    m_thread.start(QThread::LowPriority);
    setRoots(roots, replayRecentHistory);
    restartTimers();
}

void SignalRuntime::setRoots(const QList<asb::codex::Root> &roots, bool replayRecentHistory) {
    ++m_generation;
    asb::codex::ActivityMonitor::Options options;
    options.replaysInitialHistory = replayRecentHistory;
    m_monitor = std::make_shared<asb::codex::ActivityMonitor>(roots, options);
    m_hasPolled = false;
    m_lastActivityAt.reset();
    poll();
}

void SignalRuntime::setLowPower(bool lowPower) {
    if (m_lowPower == lowPower) return;
    m_lowPower = lowPower;
    restartTimers();
}

void SignalRuntime::setPaused(bool paused) {
    m_paused = paused;
    if (!paused) poll();
}

void SignalRuntime::pollNow() {
    m_forceRescan = true;
    poll();
}

void SignalRuntime::restartTimers() {
    m_pollTimer.start(m_lowPower ? 6000 : 2000);
    m_refreshTimer.start(m_lowPower ? 15000 : 5000);
}

void SignalRuntime::poll() {
    if (m_paused || m_inFlight || !m_monitor || !m_thread.isRunning()) return;
    m_inFlight = true;
    const quint64 generation = m_generation;
    const std::shared_ptr<asb::codex::ActivityMonitor> monitor = m_monitor;
    const bool rescan = std::exchange(m_forceRescan, false);
    QMetaObject::invokeMethod(m_worker, [this, monitor, generation, rescan] {
        if (rescan) monitor->forceRescan();
        const asb::codex::PollResult result = monitor->poll(nowMs());
        // Queued to `this`: dropped automatically if the runtime is gone.
        QMetaObject::invokeMethod(this, [this, result, generation] {
            m_inFlight = false;
            if (generation != m_generation) {
                poll(); // the roots changed while this poll ran
                return;
            }
            applyPoll(result);
        }, Qt::QueuedConnection);
    }, Qt::QueuedConnection);
}

void SignalRuntime::applyPoll(const asb::codex::PollResult &result) {
    const qint64 now = nowMs();
    m_connection = result.connection;
    m_files = result.files;
    m_hasPolled = true;
    for (const asb::codex::Activity &a : result.activities) {
        const qint64 at = a.timestampMs.value_or(now);
        m_store.applySessionSignal(a.signal, a.sessionID, a.agent, a.event, at, now);
        if (a.timestampMs) m_lastActivityAt = std::max(m_lastActivityAt.value_or(0), *a.timestampMs);
    }
    refresh();
}

void SignalRuntime::refresh() {
    const qint64 now = nowMs();
    m_display = asb::display::displaySnapshot(m_store.readSnapshot(now), now);
    m_visibleSessions = asb::display::visibleSessions(m_display.sessions, now, kCurrentSessionLimit);
    m_recentEvents = asb::display::recentEvents(m_display, m_visibleSessions, kRecentEventLimit);
    emit changed();
}

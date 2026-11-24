#include "SignalRuntime.h"

#include <QDateTime>
#include <QDir>
#include <QFileInfo>
#include <utility>

namespace {
qint64 nowMs() { return QDateTime::currentMSecsSinceEpoch(); }
constexpr int kCurrentSessionLimit = 6; // ActivityPresentation.currentSessionLimit
constexpr int kRecentEventLimit = 20;
constexpr int kLockTimeoutMs = 2000;
} // namespace

struct SignalRuntime::WorkerState {
    explicit WorkerState(const QString &path) : file(path) {}
    std::shared_ptr<asb::codex::ActivityMonitor> monitor;
    asb::SignalStateFile file;
    // Accepted activities not yet written (the state file was busy); retried on the next job.
    QList<asb::codex::Activity> pending;
};

SignalRuntime::SignalRuntime(QString stateFilePath, QObject *parent)
    : QObject(parent), m_stateFilePath(std::move(stateFilePath)), m_state(std::make_shared<WorkerState>(m_stateFilePath)) {
    m_thread.setObjectName("signal-runtime");
    m_worker = new QObject;
    m_worker->moveToThread(&m_thread);
    connect(&m_thread, &QThread::finished, m_worker, &QObject::deleteLater);
    connect(&m_pollTimer, &QTimer::timeout, this, [this] { schedule({true, false}); });
    connect(&m_refreshTimer, &QTimer::timeout, this, [this] { schedule({false, false}); });
    m_watchDebounce.setSingleShot(true);
    m_watchDebounce.setInterval(150);
    connect(&m_watchDebounce, &QTimer::timeout, this, [this] {
        // The folder also sees status.json.lock come and go on every read; react only when the
        // state file itself changed, or the watcher would keep re-triggering itself.
        if (const QString stamp = stateFileStamp(); stamp != m_stateStamp) {
            m_stateStamp = stamp;
            schedule({false, false});
        }
    });
    connect(&m_watcher, &QFileSystemWatcher::directoryChanged, &m_watchDebounce, qOverload<>(&QTimer::start));
}

SignalRuntime::~SignalRuntime() {
    m_thread.quit();
    m_thread.wait();
}

void SignalRuntime::start(const QList<asb::codex::Root> &roots, bool lowPower, bool replayRecentHistory) {
    m_lowPower = lowPower;
    m_thread.start(QThread::LowPriority);
    watchStateFolder();
    setRoots(roots, replayRecentHistory);
    restartTimers();
}

void SignalRuntime::watchStateFolder() {
    // Watch the folder: the file itself is replaced on every write.
    const QString dir = QFileInfo(m_stateFilePath).absolutePath();
    QDir().mkpath(dir);
    if (!m_watcher.directories().contains(dir)) m_watcher.addPath(dir);
}

void SignalRuntime::setRoots(const QList<asb::codex::Root> &roots, bool replayRecentHistory) {
    ++m_generation;
    asb::codex::ActivityMonitor::Options options;
    options.replaysInitialHistory = replayRecentHistory;
    auto monitor = std::make_shared<asb::codex::ActivityMonitor>(roots, options);
    const auto state = m_state;
    // Handed over on the worker thread, after any job that is still using the old monitor.
    QMetaObject::invokeMethod(m_worker, [state, monitor] { state->monitor = monitor; }, Qt::QueuedConnection);
    m_hasPolled = false;
    m_lastActivityAt.reset();
    schedule({true, false});
}

void SignalRuntime::setLowPower(bool lowPower) {
    if (m_lowPower == lowPower) return;
    m_lowPower = lowPower;
    restartTimers();
}

void SignalRuntime::setPaused(bool paused) {
    m_paused = paused;
    if (!paused) schedule({true, false});
}

void SignalRuntime::pollNow() { schedule({true, true}); }

void SignalRuntime::restartTimers() {
    m_pollTimer.start(m_lowPower ? 6000 : 2000);
    m_refreshTimer.start(m_lowPower ? 15000 : 5000);
}

void SignalRuntime::schedule(Job job) {
    if (m_paused || !m_thread.isRunning()) return;
    if (m_inFlight) {
        m_pollQueued |= job.poll;
        m_rescanQueued |= job.rescan;
        m_readQueued = true;
        return;
    }
    m_inFlight = true;
    const quint64 generation = m_generation;
    const auto state = m_state;
    QMetaObject::invokeMethod(m_worker, [this, state, job, generation] {
        const qint64 now = nowMs();
        asb::codex::PollResult result;
        if (job.poll && state->monitor) {
            if (job.rescan) state->monitor->forceRescan();
            result = state->monitor->poll(now);
            state->pending += result.activities;
        }
        if (!state->pending.isEmpty()) {
            const QList<asb::codex::Activity> activities = state->pending;
            const auto written = state->file.update(
                [&](asb::SignalStore &store) {
                    for (const asb::codex::Activity &a : activities)
                        store.applySessionSignal(a.signal, a.sessionID, a.agent, a.event, a.timestampMs.value_or(now), now);
                },
                now, kLockTimeoutMs);
            if (written) state->pending.clear();
        }
        const std::optional<asb::SignalSnapshot> snapshot = state->file.readSnapshot(now, kLockTimeoutMs);
        const bool polled = job.poll && state->monitor;
        // Queued to `this`: dropped automatically if the runtime is gone.
        QMetaObject::invokeMethod(this, [this, generation, polled, result, snapshot] {
            finish(generation, polled, result, snapshot);
        }, Qt::QueuedConnection);
    }, Qt::QueuedConnection);
}

void SignalRuntime::finish(quint64 generation, bool polled, const asb::codex::PollResult &result,
                           const std::optional<asb::SignalSnapshot> &snapshot) {
    m_inFlight = false;
    m_stateStamp = stateFileStamp(); // our own writes need no extra read
    static const bool trace = qEnvironmentVariableIsSet("ASB_TRACE_RUNTIME");
    if (trace) qInfo("runtime job: %s", polled ? "poll" : "read");
    if (polled && generation == m_generation) {
        m_connection = result.connection;
        m_files = result.files;
        m_hasPolled = true;
        for (const asb::codex::Activity &a : result.activities) {
            if (a.timestampMs) m_lastActivityAt = std::max(m_lastActivityAt.value_or(0), *a.timestampMs);
        }
    }
    m_stateReadable = snapshot.has_value();
    if (snapshot) m_snapshot = snapshot; // keep the last good one while the file is busy
    refreshDisplay();

    if (m_pollQueued || m_readQueued || generation != m_generation) {
        const Job next{m_pollQueued || generation != m_generation, m_rescanQueued};
        m_pollQueued = m_readQueued = m_rescanQueued = false;
        schedule(next);
    }
}

void SignalRuntime::setPresence(const QList<asb::SessionStatus> &presence) {
    // Apps open or closed change the display; a repeat of the same apps does not.
    const auto key = [](const QList<asb::SessionStatus> &list) {
        QStringList ids;
        for (const asb::SessionStatus &s : list) ids.append(s.sessionID);
        return ids;
    };
    const bool changedApps = key(presence) != key(m_presence);
    m_presence = presence;
    if (changedApps) refreshDisplay();
}

void SignalRuntime::refreshDisplay() {
    if (!m_snapshot) {
        emit changed();
        return;
    }
    const qint64 now = nowMs();
    m_display = asb::display::displaySnapshot(*m_snapshot, now, m_presence);
    m_visibleSessions = asb::display::visibleSessions(m_display.sessions, now, kCurrentSessionLimit);
    m_recentEvents = asb::display::recentEvents(m_display, m_visibleSessions, kRecentEventLimit);
    emit changed();
}

QString SignalRuntime::stateFileStamp() const {
    const QFileInfo info(m_stateFilePath);
    if (!info.exists()) return QString();
    return QString::number(info.size()) + ':' + QString::number(info.lastModified().toMSecsSinceEpoch());
}

std::optional<qint64> SignalRuntime::lastEventAt(const QString &agentPrefix) const {
    if (!m_snapshot) return std::nullopt;
    std::optional<qint64> latest;
    for (const asb::SignalEvent &e : m_snapshot->recentEvents) {
        if (e.agent.startsWith(agentPrefix)) latest = std::max(latest.value_or(0), e.updatedAt);
    }
    return latest;
}

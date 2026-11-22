#pragma once

#include "ActivityDisplay.h"
#include "CodexActivityMonitor.h"
#include "SignalStateFile.h"

#include <QFileSystemWatcher>
#include <QObject>
#include <QThread>
#include <QTimer>
#include <memory>
#include <optional>

// Live signal pipeline (MenuBarStatusModel.pollCodexDesktopActivity + reloadFromWatcher). On a
// worker thread: the rollout monitor polls every 2 s (6 s in low-power mode) and accepted
// activities go into status.json; the file is re-read every 5 s (15 s) and whenever its folder
// changes (agent-signal.exe writes Claude Code hook events there). The GUI thread turns each
// snapshot into the display snapshot, so finished and abandoned sessions age out on time.
class SignalRuntime : public QObject {
    Q_OBJECT
public:
    explicit SignalRuntime(QString stateFilePath, QObject *parent = nullptr);
    ~SignalRuntime() override;

    void start(const QList<asb::codex::Root> &roots, bool lowPower, bool replayRecentHistory = false);
    // A user-picked directory replays its recent history (setCodexDataDirectory on macOS).
    void setRoots(const QList<asb::codex::Root> &roots, bool replayRecentHistory);
    void setLowPower(bool lowPower);
    void setPaused(bool paused);
    // Rescan and poll now ("检查连接").
    void pollNow();
    // Running agent apps (PresenceMonitor), merged into the display as idle sessions.
    void setPresence(const QList<asb::SessionStatus> &presence);

    const QString &stateFilePath() const { return m_stateFilePath; }
    const asb::display::DisplaySnapshot &display() const { return m_display; }
    const QList<asb::SessionStatus> &visibleSessions() const { return m_visibleSessions; }
    const QList<asb::SignalEvent> &recentEvents() const { return m_recentEvents; }
    const asb::codex::ConnectionHealth &connection() const { return m_connection; }
    const QList<asb::codex::TrackedFile> &trackedFiles() const { return m_files; }
    std::optional<qint64> lastActivityAt() const { return m_lastActivityAt; }
    // Newest event from an agent whose name starts with `prefix` ("claude"), from status.json.
    std::optional<qint64> lastEventAt(const QString &agentPrefix) const;
    bool hasPolled() const { return m_hasPolled; }
    bool stateReadable() const { return m_stateReadable; }

signals:
    void changed();

private:
    struct Job {
        bool poll = false;
        bool rescan = false;
    };
    void schedule(Job job);
    void finish(quint64 generation, bool polled, const asb::codex::PollResult &result,
                const std::optional<asb::SignalSnapshot> &snapshot);
    void refreshDisplay();
    void restartTimers();
    void watchStateFolder();
    QString stateFileStamp() const;

    QString m_stateFilePath;
    QThread m_thread;
    QObject *m_worker = nullptr; // lives in m_thread
    struct WorkerState;
    std::shared_ptr<WorkerState> m_state; // touched only on m_thread after start
    quint64 m_generation = 0;
    bool m_inFlight = false;
    bool m_pollQueued = false;
    bool m_readQueued = false;
    bool m_rescanQueued = false;
    bool m_paused = false;
    bool m_lowPower = false;
    bool m_hasPolled = false;
    bool m_stateReadable = true;
    QTimer m_pollTimer;
    QTimer m_refreshTimer;
    QTimer m_watchDebounce;
    QFileSystemWatcher m_watcher;
    QString m_stateStamp; // size:mtime of status.json when last seen
    std::optional<asb::SignalSnapshot> m_snapshot;
    QList<asb::SessionStatus> m_presence;
    asb::display::DisplaySnapshot m_display;
    QList<asb::SessionStatus> m_visibleSessions;
    QList<asb::SignalEvent> m_recentEvents;
    asb::codex::ConnectionHealth m_connection;
    QList<asb::codex::TrackedFile> m_files;
    std::optional<qint64> m_lastActivityAt;
};

#pragma once

#include "ActivityDisplay.h"
#include "CodexActivityMonitor.h"
#include "SignalStore.h"

#include <QObject>
#include <QThread>
#include <QTimer>
#include <memory>
#include <optional>

// Live signal pipeline (MenuBarStatusModel.pollCodexDesktopActivity + reloadFromWatcher):
// the rollout monitor polls on a worker thread every 2 s (6 s in low-power mode), accepted
// activities go into the store on the GUI thread, and the display snapshot is rebuilt after
// each poll and every 5 s (15 s), so finished and abandoned sessions age out on time.
class SignalRuntime : public QObject {
    Q_OBJECT
public:
    explicit SignalRuntime(QObject *parent = nullptr);
    ~SignalRuntime() override;

    void start(const QList<asb::codex::Root> &roots, bool lowPower, bool replayRecentHistory = false);
    // A user-picked directory replays its recent history (setCodexDataDirectory on macOS).
    void setRoots(const QList<asb::codex::Root> &roots, bool replayRecentHistory);
    void setLowPower(bool lowPower);
    void setPaused(bool paused);
    // Rescan and poll now ("检查连接").
    void pollNow();

    const asb::display::DisplaySnapshot &display() const { return m_display; }
    const QList<asb::SessionStatus> &visibleSessions() const { return m_visibleSessions; }
    const QList<asb::SignalEvent> &recentEvents() const { return m_recentEvents; }
    const asb::codex::ConnectionHealth &connection() const { return m_connection; }
    const QList<asb::codex::TrackedFile> &trackedFiles() const { return m_files; }
    std::optional<qint64> lastActivityAt() const { return m_lastActivityAt; }
    bool hasPolled() const { return m_hasPolled; }

signals:
    void changed();

private:
    void poll();
    void applyPoll(const asb::codex::PollResult &result);
    void refresh();
    void restartTimers();

    QThread m_thread;
    QObject *m_worker = nullptr; // lives in m_thread
    std::shared_ptr<asb::codex::ActivityMonitor> m_monitor; // used only on m_thread
    quint64 m_generation = 0;
    bool m_inFlight = false;
    bool m_forceRescan = false;
    bool m_paused = false;
    bool m_lowPower = false;
    bool m_hasPolled = false;
    QTimer m_pollTimer;
    QTimer m_refreshTimer;
    asb::SignalStore m_store;
    asb::display::DisplaySnapshot m_display;
    QList<asb::SessionStatus> m_visibleSessions;
    QList<asb::SignalEvent> m_recentEvents;
    asb::codex::ConnectionHealth m_connection;
    QList<asb::codex::TrackedFile> m_files;
    std::optional<qint64> m_lastActivityAt;
};

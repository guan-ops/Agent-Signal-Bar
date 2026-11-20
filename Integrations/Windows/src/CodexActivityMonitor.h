// Port of CodexDesktopActivityMonitor.swift (activity part) using portable Qt file APIs.
// Tails the most recently written Codex rollout files (rollout-*.jsonl) and turns new
// complete lines into activities.
//
// Kept from the Swift monitor: no replay of existing history on the first poll (it only
// primes cursors and completion state), complete-line cursors, a 512 KiB initial tail,
// the 8-file limit, a full directory rescan every 10 s, the 30 min / 15 s acceptance
// windows and the completion-replay filters.
// Simplified: the inode/ctime/descriptor fingerprints are replaced by birth time + size +
// mtime and a check of the first 4 KiB already consumed; token observations and VS Code log
// hints are not ported.
#pragma once

#include "CodexSessionParser.h"

#include <QHash>
#include <QList>
#include <QString>
#include <QStringList>

namespace asb::codex {

struct Root {
    QString path;        // a "sessions" directory
    QString forcedAgent; // empty unless every file under it belongs to one client
};

// Selected directory -> CODEX_HOME -> <home>/.codex, plus its "sessions" folder. On macOS the
// Xcode and JetBrains locations the Mac app watches are added for development parity.
QString primaryCodexHome(const QString &home, const QString &codexHomeEnv, const QString &selectedPath);
QList<Root> activityRoots(const QString &home, const QString &codexHomeEnv, const QString &selectedPath);
// Only <dir>/sessions: fixture and probe runs must not pick up the extra per-IDE roots.
inline QList<Root> rootsForDirectory(const QString &home, const QString &dir) {
    return {{primaryCodexHome(home, QString(), dir) + "/sessions", QString()}};
}

struct ConnectionHealth {
    QStringList roots;
    QStringList unreadable;
    int existingRoots = 0;
    int recentFiles = 0;
};

// A tracked rollout file, for --probe diagnostics.
struct TrackedFile {
    QString path;
    qint64 size = 0;
    qint64 modifiedMs = 0;
    qint64 consumed = 0; // bytes read so far (cursor offset)
};

struct PollResult {
    ConnectionHealth connection;
    QList<Activity> activities; // accepted, oldest first
    QList<TrackedFile> files;
};

class ActivityMonitor {
public:
    struct Options {
        int recentFileLimit = 8;
        qint64 initialLookbackMs = 30 * 60 * 1000;
        qint64 completedLookbackMs = 15 * 1000;
        qint64 maxInitialTailBytes = 512 * 1024;
        qint64 maxSessionMetadataProbeBytes = 256 * 1024;
        qint64 fullScanIntervalMs = 10 * 1000;
        // True after the user picks another data directory (setCodexDataDirectory): the first
        // poll then returns the recent history instead of only priming.
        bool replaysInitialHistory = false;
    };

    explicit ActivityMonitor(QList<Root> roots);
    ActivityMonitor(QList<Root> roots, Options options);

    PollResult poll(qint64 now);
    void reset();
    // The next poll rescans the directories instead of reusing the cached file list.
    void forceRescan() { m_lastFullScan.reset(); }
    const QList<Root> &roots() const { return m_roots; }

private:
    struct SessionFile {
        QString path;
        QString forcedAgent;
        qint64 size = 0;
        qint64 modifiedMs = 0;
        qint64 bornMs = 0; // 0 when the file system does not report it
    };
    struct Cursor {
        qint64 bornMs = 0;
        qint64 modifiedMs = 0;
        qint64 offset = 0;
        QByteArray anchor; // first min(offset, 4 KiB) bytes
    };
    struct Line {
        QByteArray bytes;
    };

    PollResult pollFiles(qint64 now);
    QList<SessionFile> recentFiles(qint64 now);
    QList<SessionFile> scanFiles();
    std::optional<SessionFile> stat(const QString &path, const QString &forcedAgent) const;
    QList<Line> readNewLines(const SessionFile &file, qint64 now);
    QList<Line> readInitialTail(const SessionFile &file);
    QList<Line> completeLines(const QByteArray &data, qint64 startOffset, bool dropLeadingPartial, qint64 &nextOffset) const;
    QByteArray readAnchor(const QString &path, qint64 throughOffset) const;
    void confirmSessionMetadata(const SessionFile &file);
    void recordSessionMetadata(const QByteArray &line, const SessionFile &file);
    QList<Activity> parse(const QList<Line> &lines, const SessionFile &file);
    void clearPathState(const QString &path);
    QString defaultSessionID(const SessionFile &file, const QString &agent) const;

    QList<Activity> accepted(QList<Activity> activities, qint64 now);
    bool shouldAccept(const Activity &a, qint64 now) const;
    bool shouldAcceptAfterCompletion(const Activity &a) const;
    void rememberCompletion(const Activity &a, qint64 now);

    QList<Root> m_roots;
    Options m_options;
    QHash<QString, Cursor> m_cursors;
    QHash<QString, QString> m_agents;
    QHash<QString, QString> m_confirmedSessionIDs;
    QHash<QString, qint64> m_completedAt; // by session ID
    QList<SessionFile> m_cachedFiles;
    std::optional<qint64> m_lastFullScan;
    bool m_primed = false;
    QStringList m_scanErrors;
};

} // namespace asb::codex

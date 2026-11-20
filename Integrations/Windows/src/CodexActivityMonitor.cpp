#include "CodexActivityMonitor.h"

#include "SignalModel.h"

#include <QDateTime>
#include <QDir>
#include <QDirIterator>
#include <QFile>
#include <QFileInfo>
#include <QSet>
#include <QStringDecoder>
#include <algorithm>
#include <limits>

namespace asb::codex {
namespace {

constexpr qint64 kAnchorBytes = 4 * 1024;

QString expandHome(const QString &value, const QString &home) {
    if (value == "~") return home;
    if (value.startsWith("~/") || value.startsWith("~\\")) return home + '/' + value.mid(2);
    return value;
}

qint64 ms(const QDateTime &time) { return time.isValid() ? time.toMSecsSinceEpoch() : 0; }

bool isShortLivedReplaySignal(const QString &signal) {
    return signal == "done" || signal == "tool_done" || signal == "subagent_stop"
        || displayState(signal) == DisplayState::Completed;
}

bool startsNewTurn(const Activity &a) {
    return a.event == "DesktopTaskStarted" || a.event.startsWith("DesktopToolCall:");
}

bool isCompletionReplay(const Activity &a) {
    return a.event == "DesktopActivityHeartbeat" || a.event == "DesktopThinking" || a.event == "DesktopMessage"
        || a.event == "DesktopToolDone";
}

void sortByTimestamp(QList<Activity> &activities) {
    std::stable_sort(activities.begin(), activities.end(), [](const Activity &a, const Activity &b) {
        return a.timestampMs.value_or(std::numeric_limits<qint64>::min())
            < b.timestampMs.value_or(std::numeric_limits<qint64>::min());
    });
}

} // namespace

QString primaryCodexHome(const QString &home, const QString &codexHomeEnv, const QString &selectedPath) {
    for (const QString &candidate : {selectedPath, codexHomeEnv}) {
        const QString value = candidate.trimmed();
        if (value.isEmpty()) continue;
        return QDir::cleanPath(QDir(home).absoluteFilePath(expandHome(value, home)));
    }
    return QDir::cleanPath(home + "/.codex");
}

QList<Root> activityRoots(const QString &home, const QString &codexHomeEnv, const QString &selectedPath) {
    QList<Root> roots{{primaryCodexHome(home, codexHomeEnv, selectedPath) + "/sessions", QString()}};
#ifdef Q_OS_MACOS
    // Keep Xcode's path even when it is created after the app starts.
    roots.append({home + "/Library/Developer/Xcode/CodingAssistant/codex/sessions", "codex-xcode"});
    const QDir jetBrains(home + "/Library/Caches/JetBrains");
    for (const QString &product : jetBrains.entryList(QDir::Dirs | QDir::NoDotAndDotDot)) {
        const QString name = product.toLower();
        roots.append({jetBrains.filePath(product) + "/aia/codex/sessions",
                      name.contains("idea") || name.contains("intellij") ? "codex-idea" : "codex-jetbrains"});
    }
#endif
    QSet<QString> seen;
    QList<Root> unique;
    for (const Root &root : roots) {
        const QString key = QDir::cleanPath(root.path);
        if (seen.contains(key)) continue;
        seen.insert(key);
        unique.append({key, root.forcedAgent});
    }
    return unique;
}

ActivityMonitor::ActivityMonitor(QList<Root> roots) : ActivityMonitor(std::move(roots), Options{}) {}

ActivityMonitor::ActivityMonitor(QList<Root> roots, Options options) : m_roots(std::move(roots)), m_options(options) {}

void ActivityMonitor::reset() {
    m_cursors.clear();
    m_agents.clear();
    m_confirmedSessionIDs.clear();
    m_completedAt.clear();
    m_cachedFiles.clear();
    m_lastFullScan.reset();
    m_primed = false;
}

PollResult ActivityMonitor::poll(qint64 now) {
    PollResult result;
    const QList<SessionFile> files = recentFiles(now);
    result.connection.recentFiles = int(files.size());
    QSet<QString> unreadable(m_scanErrors.cbegin(), m_scanErrors.cend());
    for (const Root &root : std::as_const(m_roots)) {
        result.connection.roots.append(QDir::toNativeSeparators(root.path));
        const QFileInfo info(root.path);
        if (!info.exists()) continue;
        ++result.connection.existingRoots;
        if (!info.isDir() || !info.isReadable()) unreadable.insert(QDir::toNativeSeparators(root.path));
    }
    result.connection.unreadable = QStringList(unreadable.cbegin(), unreadable.cend());
    result.connection.unreadable.sort();

    if (!m_primed) {
        // The first poll learns where each file ends and which sessions already finished.
        m_primed = true;
        QList<Activity> replay;
        for (const SessionFile &file : files) {
            confirmSessionMetadata(file);
            QList<Activity> activities = parse(readInitialTail(file), file);
            if (m_options.replaysInitialHistory) {
                replay += activities;
                continue;
            }
            sortByTimestamp(activities);
            for (const Activity &a : std::as_const(activities)) rememberCompletion(a, now);
        }
        if (m_options.replaysInitialHistory) {
            // sortedAcceptedActivities: drop work that a later completion of its session superseded.
            const QList<Activity> all = replay;
            for (const Activity &a : accepted(std::move(replay), now)) {
                const bool superseded = displayState(a.signal) != DisplayState::Completed && a.timestampMs
                    && std::any_of(all.cbegin(), all.cend(), [&](const Activity &c) {
                           return c.sessionID == a.sessionID && displayState(c.signal) == DisplayState::Completed
                               && c.timestampMs && *c.timestampMs >= *a.timestampMs;
                       });
                if (!superseded) result.activities.append(a);
            }
        }
        return result;
    }

    QList<Activity> activities;
    for (const SessionFile &file : files) activities += parse(readNewLines(file, now), file);
    result.activities = accepted(std::move(activities), now);
    return result;
}

std::optional<ActivityMonitor::SessionFile> ActivityMonitor::stat(const QString &path, const QString &forcedAgent) const {
    const QFileInfo info(path);
    if (!info.isFile()) return std::nullopt;
#ifdef Q_OS_WIN
    // NTFS has no inode change time; Qt does not map metadataChangeTime() to one.
    const qint64 modified = ms(info.lastModified());
#else
    const qint64 modified = std::max(ms(info.lastModified()), ms(info.metadataChangeTime()));
#endif
    return SessionFile{path, forcedAgent, info.size(), modified, ms(info.birthTime())};
}

QList<ActivityMonitor::SessionFile> ActivityMonitor::scanFiles() {
    m_scanErrors.clear();
    QList<SessionFile> candidates;
    QSet<QString> seen;
    for (const Root &root : std::as_const(m_roots)) {
        if (!QFileInfo(root.path).isDir()) continue;
        QDirIterator it(root.path, {QStringLiteral("rollout-*.jsonl")}, QDir::Files, QDirIterator::Subdirectories);
        while (it.hasNext()) {
            const QString path = it.next();
            if (seen.contains(path)) continue;
            seen.insert(path);
            const QFileInfo info = it.fileInfo();
            if (!info.fileName().startsWith("rollout-") || info.suffix() != "jsonl") continue;
            if (!info.isReadable()) {
                m_scanErrors.append(QDir::toNativeSeparators(path));
                continue;
            }
            if (auto file = stat(path, root.forcedAgent)) candidates.append(*file);
        }
    }
    std::stable_sort(candidates.begin(), candidates.end(),
                     [](const SessionFile &a, const SessionFile &b) { return a.modifiedMs > b.modifiedMs; });
    if (candidates.size() > m_options.recentFileLimit) candidates = candidates.mid(0, m_options.recentFileLimit);
    return candidates;
}

QList<ActivityMonitor::SessionFile> ActivityMonitor::recentFiles(qint64 now) {
    QList<SessionFile> files;
    if (m_lastFullScan && now - *m_lastFullScan < m_options.fullScanIntervalMs) {
        for (const SessionFile &cached : std::as_const(m_cachedFiles)) {
            if (auto refreshed = stat(cached.path, cached.forcedAgent)) files.append(*refreshed);
        }
    } else {
        files = scanFiles();
        QSet<QString> scanned;
        for (const SessionFile &f : std::as_const(files)) scanned.insert(f.path);
        // Keep a file the scan briefly missed (atomic replace in progress) while it exists.
        for (const SessionFile &previous : std::as_const(m_cachedFiles)) {
            if (scanned.contains(previous.path)) continue;
            if (auto refreshed = stat(previous.path, previous.forcedAgent)) files.append(*refreshed);
        }
        m_lastFullScan = now;
    }
    std::stable_sort(files.begin(), files.end(),
                     [](const SessionFile &a, const SessionFile &b) { return a.modifiedMs > b.modifiedMs; });
    if (files.size() > m_options.recentFileLimit) files = files.mid(0, m_options.recentFileLimit);
    m_cachedFiles = files;
    return files;
}

QByteArray ActivityMonitor::readAnchor(const QString &path, qint64 throughOffset) const {
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly)) return {};
    return f.read(std::min(throughOffset, kAnchorBytes));
}

QList<ActivityMonitor::Line> ActivityMonitor::completeLines(const QByteArray &data, qint64 startOffset,
                                                            bool dropLeadingPartial, qint64 &nextOffset) const {
    QList<Line> lines;
    nextOffset = startOffset;
    qsizetype lineStart = 0;
    while (lineStart < data.size()) {
        const qsizetype newline = data.indexOf('\n', lineStart);
        if (newline < 0) break;
        if (newline > lineStart) lines.append(Line{data.mid(lineStart, newline - lineStart)});
        nextOffset = startOffset + newline + 1;
        lineStart = newline + 1;
    }
    if (dropLeadingPartial && !lines.isEmpty()) lines.removeFirst();
    // String(data:encoding:.utf8) drops lines that are not valid UTF-8.
    QList<Line> valid;
    for (const Line &line : std::as_const(lines)) {
        QStringDecoder decoder(QStringDecoder::Utf8);
        const QString decoded = decoder(line.bytes);
        if (!decoder.hasError()) valid.append(line);
    }
    return valid;
}

QList<ActivityMonitor::Line> ActivityMonitor::readInitialTail(const SessionFile &file) {
    const qint64 start = file.size > m_options.maxInitialTailBytes ? file.size - m_options.maxInitialTailBytes : 0;
    QFile f(file.path);
    if (!f.open(QIODevice::ReadOnly) || !f.seek(start)) return {};
    const QByteArray data = f.readAll();
    qint64 next = start;
    const QList<Line> lines = completeLines(data, start, start > 0, next);
    m_cursors.insert(file.path, Cursor{file.bornMs, file.modifiedMs, next, readAnchor(file.path, next)});
    return lines;
}

QList<ActivityMonitor::Line> ActivityMonitor::readNewLines(const SessionFile &file, qint64 now) {
    std::optional<qint64> previousOffset;
    if (m_cursors.contains(file.path)) {
        const Cursor cursor = m_cursors.value(file.path);
        if (cursor.bornMs == file.bornMs) {
            const bool modified = cursor.modifiedMs != file.modifiedMs;
            if (!modified && file.size == cursor.offset) return {};
            if (file.size < cursor.offset || (modified && file.size <= cursor.offset)) {
                // A changed file that did not grow cannot be an append.
                clearPathState(file.path);
            } else if (readAnchor(file.path, cursor.offset) != cursor.anchor) {
                // The bytes already consumed changed: the file was rewritten.
                clearPathState(file.path);
            } else {
                previousOffset = cursor.offset;
            }
        } else {
            // Replaced at the same path: state for the old file must not leak.
            clearPathState(file.path);
        }
    }
    confirmSessionMetadata(file);

    qint64 start = 0;
    bool dropLeadingPartial = false;
    if (previousOffset) {
        if (file.size <= *previousOffset) return {};
        start = *previousOffset;
    } else {
        if (now - file.modifiedMs > m_options.initialLookbackMs) {
            m_cursors.insert(file.path, Cursor{file.bornMs, file.modifiedMs, file.size, readAnchor(file.path, file.size)});
            return {};
        }
        start = file.size > m_options.maxInitialTailBytes ? file.size - m_options.maxInitialTailBytes : 0;
        dropLeadingPartial = start > 0;
    }

    QFile f(file.path);
    if (!f.open(QIODevice::ReadOnly) || !f.seek(start)) return {};
    const QByteArray data = f.readAll();
    if (data.isEmpty()) return {};
    qint64 next = start;
    const QList<Line> lines = completeLines(data, start, dropLeadingPartial, next);
    m_cursors.insert(file.path, Cursor{file.bornMs, file.modifiedMs, next, readAnchor(file.path, next)});
    return lines;
}

void ActivityMonitor::clearPathState(const QString &path) {
    m_cursors.remove(path);
    m_agents.remove(path);
    m_confirmedSessionIDs.remove(path);
}

void ActivityMonitor::confirmSessionMetadata(const SessionFile &file) {
    if (m_confirmedSessionIDs.contains(file.path)) return;
    QFile f(file.path);
    if (!f.open(QIODevice::ReadOnly)) return;
    const QByteArray data = f.read(m_options.maxSessionMetadataProbeBytes);
    qint64 next = 0;
    for (const Line &line : completeLines(data, 0, false, next)) {
        recordSessionMetadata(line.bytes, file);
        if (m_confirmedSessionIDs.contains(file.path)) return;
    }
}

void ActivityMonitor::recordSessionMetadata(const QByteArray &line, const SessionFile &file) {
    if (!line.contains("session_meta")) return; // cheap pre-filter; only session_meta lines match below
    if (auto id = sessionIDFromSessionMeta(line)) m_confirmedSessionIDs.insert(file.path, *id);
    if (auto agent = agentNameFromSessionMeta(line))
        m_agents.insert(file.path, file.forcedAgent.isEmpty() ? *agent : file.forcedAgent);
}

QString ActivityMonitor::defaultSessionID(const SessionFile &file, const QString &agent) const {
    const QString prefix = sessionPrefix(agent);
    if (m_confirmedSessionIDs.contains(file.path)) return prefix + ':' + m_confirmedSessionIDs.value(file.path);
    const QStringList parts = QFileInfo(file.path).completeBaseName().split('-', Qt::SkipEmptyParts);
    if (parts.size() < 5) return prefix;
    const QString candidate = parts.mid(parts.size() - 5).join('-');
    return candidate.size() == 36 ? prefix + ':' + candidate : prefix;
}

QList<Activity> ActivityMonitor::parse(const QList<Line> &lines, const SessionFile &file) {
    QList<Activity> activities;
    for (const Line &line : lines) {
        recordSessionMetadata(line.bytes, file);
        if (line.bytes.contains("session_meta") && agentNameFromSessionMeta(line.bytes)) continue;
        const QString agent = !file.forcedAgent.isEmpty() ? file.forcedAgent
                                                          : m_agents.value(file.path, QStringLiteral("codex-desktop"));
        if (!file.forcedAgent.isEmpty()) m_agents.insert(file.path, file.forcedAgent);
        if (auto a = activity(line.bytes, defaultSessionID(file, agent), agent)) activities.append(*a);
    }
    return activities;
}

bool ActivityMonitor::shouldAccept(const Activity &a, qint64 now) const {
    if (!a.timestampMs) return true;
    const qint64 age = now - *a.timestampMs;
    return age <= (isShortLivedReplaySignal(a.signal) ? m_options.completedLookbackMs : m_options.initialLookbackMs);
}

bool ActivityMonitor::shouldAcceptAfterCompletion(const Activity &a) const {
    if (!m_completedAt.contains(a.sessionID) || displayState(a.signal) != DisplayState::Active) return true;
    if (startsNewTurn(a) || !a.timestampMs) return true;
    if (*a.timestampMs <= m_completedAt.value(a.sessionID)) return false;
    return !isCompletionReplay(a);
}

void ActivityMonitor::rememberCompletion(const Activity &a, qint64 now) {
    if (displayState(a.signal) == DisplayState::Completed)
        m_completedAt.insert(a.sessionID, a.timestampMs.value_or(now));
    else if (startsNewTurn(a))
        m_completedAt.remove(a.sessionID);
}

QList<Activity> ActivityMonitor::accepted(QList<Activity> activities, qint64 now) {
    sortByTimestamp(activities);
    QList<Activity> result;
    for (const Activity &a : std::as_const(activities)) {
        if (!shouldAccept(a, now) || !shouldAcceptAfterCompletion(a)) continue;
        rememberCompletion(a, now);
        result.append(a);
    }
    return result;
}

} // namespace asb::codex

// Local token usage and cost, ported from AgentSignalCostUsage (CostUsageScanner,
// CostUsageScanner+Claude, CodexUsageDetails). Read-only: it reads session logs, never writes
// them, and keeps only token counts, model names, session ids and project paths.
//
// Codex (<Codex home>\sessions, archived_sessions and the other activity roots): each
// event_msg/token_count adds the growth of the cumulative `total_token_usage` (or its
// `last_token_usage`) to the current model on the event's local day, with the macOS rules for
// divergent totals and for forked sessions, whose inherited parent totals are subtracted.
// Every token event is priced on its own, so long-context rates apply per request. Copies of
// one session (an archived copy, a file that is a byte prefix of another) count once; copies
// that disagree are left out and reported, as on macOS.
//
// Claude (CLAUDE_CONFIG_DIR\projects, ~/.claude/projects, ~/.config/claude/projects and Claude
// desktop's session folders): assistant messages with usage; streaming chunks of one message
// keep the last; a message logged by both a parent and a subagent file counts once.
//
// Simplified from macOS: no incremental append parsing or on-disk cache (unchanged files are
// memoized in memory), no paginated-history recovery, no Codex priority pricing and no Pi
// sessions.
#pragma once

#include "UsagePricing.h"

#include <QHash>
#include <QList>
#include <QMap>
#include <QString>
#include <QStringList>
#include <functional>
#include <memory>
#include <optional>

namespace asb::usage {

// CostUsageDayRange: report days [since, until]; events are read one day further each way.
struct DayRange {
    QString sinceKey, untilKey, scanSinceKey, scanUntilKey;
    qint64 scanSinceMs = 0; // local midnight of scanSinceKey
    static DayRange lastDays(qint64 nowMs, int days);
    bool inScan(const QString &day) const { return day >= scanSinceKey && day <= scanUntilKey; }
    bool inReport(const QString &day) const { return day >= sinceKey && day <= untilKey; }
};

// The local day ("yyyy-MM-dd") of an ISO 8601 timestamp that carries a time zone; "" otherwise.
QString dayKeyFromTimestamp(const QString &timestamp);
std::optional<qint64> msFromTimestamp(const QString &timestamp);

struct ModelDay {
    qint64 input = 0;         // Codex: input including cached; Claude: uncached input
    qint64 cached = 0;        // Codex cached input; Claude cache reads
    qint64 cacheCreation = 0; // Claude only
    qint64 output = 0;
    qint64 totalTokens = 0;   // Codex input + output; Claude all four
    std::optional<double> cost;
    qint64 unpricedTokens = 0;
    int requests = 0;
    int incomplete = 0;       // Claude requests whose usage was cut off
};

struct Day {
    QString key;
    QMap<QString, ModelDay> models;
    qint64 totalTokens = 0;
    std::optional<double> cost;
    bool partial = false; // some usage has no price
    int incomplete = 0;
};

struct Session {
    QString id;
    QString projectPath;
    qint64 lastActivityMs = 0;
    qint64 totalTokens = 0;
    std::optional<double> cost;
    bool partial = false;
    QStringList models;
};

struct Report {
    QList<Day> days; // report range only, oldest first
    QList<Session> sessions; // newest activity first
    int files = 0;
    int excludedSessions = 0; // Codex copies that disagree
};

struct CodexTotals {
    qint64 input = 0, cached = 0, output = 0;
    bool operator==(const CodexTotals &) const = default;
};

class CodexScanner {
public:
    struct Row {
        QString day;
        QString model;
        qint64 input = 0, cached = 0, output = 0;
        qint64 timestampMs = 0;
    };
    struct FileResult {
        QString sessionId;
        QString forkedFromId;
        QList<Row> rows;
    };
    struct ForkBaseline {
        bool resolved = false;
        std::optional<CodexTotals> totals;
    };
    using Resolver = std::function<ForkBaseline(const QString &parentId, const QString &forkedAt)>;

    // `roots`: folders holding rollout-*.jsonl files (searched recursively).
    explicit CodexScanner(QStringList roots);
    Report scan(qint64 nowMs, int days, const ModelsDevCatalog *catalog);

    // parseCodexFileCancellable for one file (no resolver: forks are left unresolved). `readOk` is
    // false when the file could not be read in full; scan() does not cache such a result.
    static FileResult parseFile(const QString &path, const DayRange &range, const Resolver &resolver = {},
                                bool *readOk = nullptr);

private:
    struct Memo;
    QStringList m_roots;
    std::shared_ptr<Memo> m_memo;
};

class ClaudeScanner {
public:
    struct Row {
        QString day;
        QString model;
        QString sessionId, messageId, requestId;
        qint64 timestampMs = 0;
        bool sidechain = false;
        bool subagent = false;
        qint64 input = 0, cacheRead = 0, cacheCreate = 0, cacheCreate1h = 0, output = 0;
        qint64 costNanos = 0;
        bool costPriced = false;
        bool incomplete = false;
    };

    // `roots`: projects folders (searched recursively) or single .jsonl files.
    explicit ClaudeScanner(QStringList roots);
    Report scan(qint64 nowMs, int days, const ModelsDevCatalog *catalog);

    static QList<Row> parseFile(const QString &path, const DayRange &range, const ModelsDevCatalog *catalog,
                                bool *readOk = nullptr);
    // ClaudeHistoryRoots.projects for Windows (%APPDATA%\Claude stands in for Application Support).
    static QStringList defaultRoots(const QString &home, const QString &configDirEnv, const QString &appData);

private:
    struct Memo;
    QStringList m_roots;
    std::shared_ptr<Memo> m_memo;
};

} // namespace asb::usage

#include "UsageScanner.h"

#include <QDateTime>
#include <QDir>
#include <QDirIterator>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QRegularExpression>
#include <QSet>
#include <QTimeZone>
#include <algorithm>
#include <cmath>

namespace asb::usage {
namespace {

constexpr qint64 kCodexMaxLineBytes = 256 * 1024;  // longer lines only yield a turn_context model
constexpr qint64 kClaudeMaxLineBytes = 512 * 1024; // longer lines are skipped
constexpr double kCostScale = 1'000'000'000.0;

// CostUsageJsonl.scan: every line, with lines longer than `maxLineBytes` cut to that length and
// flagged. `onLine` returns false to stop. False when the file cannot be opened or a read fails
// part way (a file locked mid-write, say): the caller must not cache what it got.
bool forEachLine(const QString &path, qint64 maxLineBytes, const std::function<bool(const QByteArray &, bool)> &onLine) {
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly)) return false;
    QByteArray pending;
    bool truncated = false;
    const auto emitLine = [&]() {
        if (pending.endsWith('\r')) pending.chop(1);
        const bool go = onLine(pending, truncated);
        pending.clear();
        truncated = false;
        return go;
    };
    while (true) {
        const QByteArray chunk = file.read(1 << 20);
        if (chunk.isEmpty()) {
            if (file.error() != QFileDevice::NoError) return false;
            break;
        }
        qsizetype start = 0;
        while (start < chunk.size()) {
            const qsizetype newline = chunk.indexOf('\n', start);
            const qsizetype end = newline < 0 ? chunk.size() : newline;
            if (!truncated) {
                const qsizetype length = end - start;
                if (pending.size() + length > maxLineBytes) {
                    pending.append(chunk.constData() + start, maxLineBytes - pending.size());
                    truncated = true;
                } else {
                    pending.append(chunk.constData() + start, length);
                }
            }
            if (newline < 0) break;
            if (!emitLine()) return true;
            start = newline + 1;
        }
    }
    if (!pending.isEmpty() || truncated) emitLine();
    return true;
}

QJsonObject parseObject(const QByteArray &line) {
    QJsonParseError error;
    const QJsonDocument document = QJsonDocument::fromJson(line, &error);
    return error.error == QJsonParseError::NoError && document.isObject() ? document.object() : QJsonObject();
}

qint64 toInt(const QJsonValue &value) { return value.isDouble() ? qint64(value.toDouble()) : 0; }

QString trimmedString(const QJsonObject &object, std::initializer_list<const char *> keys) {
    for (const char *key : keys) {
        const QString value = object.value(QLatin1String(key)).toString().trimmed();
        if (!value.isEmpty()) return value;
    }
    return QString();
}

// codexSessionId(from:payload:): payload first, then the line itself.
QString codexSessionId(const QJsonObject &object, const QJsonObject &payload) {
    for (const QJsonObject *container : {&payload, &object}) {
        const QString id = trimmedString(*container, {"id", "session_id", "sessionId"});
        if (!id.isEmpty()) return id;
    }
    return QString();
}

QString codexForkParentId(const QJsonObject &payload) {
    return trimmedString(payload, {"forked_from_id", "forkedFromId", "parent_session_id", "parentSessionId"});
}

CodexTotals totalsFrom(const QJsonObject &usage, bool clamp) {
    const QJsonValue cached = usage.contains("cached_input_tokens") ? usage.value("cached_input_tokens")
                                                                    : usage.value("cache_read_input_tokens");
    CodexTotals t{toInt(usage.value("input_tokens")), toInt(cached), toInt(usage.value("output_tokens"))};
    if (clamp) {
        t.input = std::max<qint64>(0, t.input);
        t.cached = std::max<qint64>(0, t.cached);
        t.output = std::max<qint64>(0, t.output);
    }
    return t;
}

CodexTotals add(const CodexTotals &a, const CodexTotals &b) {
    return {a.input + b.input, a.cached + b.cached, a.output + b.output};
}
CodexTotals minTotals(const CodexTotals &a, const CodexTotals &b) {
    return {std::min(a.input, b.input), std::min(a.cached, b.cached), std::min(a.output, b.output)};
}
bool atLeast(const CodexTotals &a, const CodexTotals &b) {
    return a.input >= b.input && a.cached >= b.cached && a.output >= b.output;
}
bool atMost(const CodexTotals &a, const CodexTotals &b) {
    return a.input <= b.input && a.cached <= b.cached && a.output <= b.output;
}
bool totalsEqual(const std::optional<CodexTotals> &a, const std::optional<CodexTotals> &b) {
    return a.has_value() == b.has_value() && (!a || *a == *b);
}
CodexTotals totalDelta(const std::optional<CodexTotals> &baseline, const CodexTotals &current) {
    const CodexTotals b = baseline.value_or(CodexTotals{});
    return {std::max<qint64>(0, current.input - b.input), std::max<qint64>(0, current.cached - b.cached),
            std::max<qint64>(0, current.output - b.output)};
}
CodexTotals divergentTotalDelta(const std::optional<CodexTotals> &rawBaseline,
                                const std::optional<CodexTotals> &countedBaseline, const CodexTotals &current) {
    const CodexTotals raw = rawBaseline.value_or(CodexTotals{});
    const CodexTotals counted = countedBaseline.value_or(CodexTotals{});
    const auto delta = [](qint64 r, qint64 c, qint64 now) {
        return now >= r ? std::max<qint64>(0, now - r) : std::max<qint64>(0, now - c);
    };
    return {delta(raw.input, counted.input, current.input), delta(raw.cached, counted.cached, current.cached),
            delta(raw.output, counted.output, current.output)};
}
bool shouldPreferTotalDelta(const std::optional<CodexTotals> &rawBaseline, const CodexTotals &currentTotal,
                            const CodexTotals &totalDeltaValue, const CodexTotals &lastDelta, bool sawDivergent) {
    if (sawDivergent || !rawBaseline) return false;
    return atLeast(currentTotal, *rawBaseline) && atMost(totalDeltaValue, lastDelta);
}
CodexTotals subtractInherited(const CodexTotals &raw, const std::optional<CodexTotals> &inherited) {
    if (!inherited) return raw;
    return {std::max<qint64>(0, raw.input - inherited->input), std::max<qint64>(0, raw.cached - inherited->cached),
            std::max<qint64>(0, raw.output - inherited->output)};
}

bool contains(const QByteArray &line, const char *needle) { return line.contains(needle); }

// extractCodexTurnContextModel: the model of a turn_context line too long to decode.
QString truncatedTurnContextModel(const QByteArray &line) {
    if (!contains(line, "\"type\":\"turn_context\"")) return QString();
    static const QRegularExpression model("\"model\"\\s*:\\s*\"([^\"]+)\"");
    const auto match = model.match(QString::fromUtf8(line.left(64 * 1024)));
    return match.hasMatch() ? match.captured(1) : QString();
}

struct CodexMeta {
    QString sessionId;
    QString forkedFromId;
    QString forkTimestamp;
    QString cwd; // from the first line only, as CodexUsageDetails.readProjectPath
};

// parseCodexSessionMetadata: the first session_meta line anywhere in the file. `readOk` is false
// when the file could not be read.
CodexMeta readCodexMeta(const QString &path, bool *readOk = nullptr) {
    CodexMeta meta;
    bool firstLine = true;
    const bool ok = forEachLine(path, 1024 * 1024, [&](const QByteArray &line, bool truncated) {
        const bool isFirst = firstLine;
        firstLine = false;
        if (truncated || !contains(line, "session_meta")) return true;
        const QJsonObject object = parseObject(line);
        if (object.value("type").toString() != "session_meta") return true;
        const QJsonObject payload = object.value("payload").toObject();
        meta.sessionId = codexSessionId(object, payload);
        meta.forkedFromId = codexForkParentId(payload);
        meta.forkTimestamp = payload.value("timestamp").toString(object.value("timestamp").toString());
        const QString cwd = payload.value("cwd").toString();
        if (isFirst && QDir::isAbsolutePath(cwd) && !cwd.contains(QChar(0))
            && (meta.sessionId.isEmpty() || payload.value("id").toString() == meta.sessionId))
            meta.cwd = QDir::toNativeSeparators(QDir::cleanPath(cwd));
        return false;
    });
    if (readOk) *readOk = ok;
    return meta;
}

struct TimestampedTotals {
    QString timestamp;
    std::optional<qint64> ms;
    CodexTotals totals;
};

// parseCodexTokenSnapshots: the counted cumulative totals after each token event of a parent.
QList<TimestampedTotals> readCodexSnapshots(const QString &path, QString *sessionId) {
    QList<TimestampedTotals> snapshots;
    std::optional<CodexTotals> previous, rawBaseline;
    bool sawDivergent = false;
    forEachLine(path, 512 * 1024, [&](const QByteArray &line, bool truncated) {
        if (line.isEmpty() || truncated) return true;
        if (!contains(line, "session_meta") && !contains(line, "token_count")) return true;
        const QJsonObject object = parseObject(line);
        const QString type = object.value("type").toString();
        if (type == "session_meta") {
            if (sessionId->isEmpty()) *sessionId = codexSessionId(object, object.value("payload").toObject());
            return true;
        }
        if (type != "event_msg") return true;
        const QJsonObject payload = object.value("payload").toObject();
        if (payload.value("type").toString() != "token_count" || !payload.value("info").isObject()) return true;
        const QString timestamp = object.value("timestamp").toString();
        if (timestamp.isEmpty()) return true;
        const QJsonObject info = payload.value("info").toObject();
        std::optional<CodexTotals> total, last;
        if (info.value("total_token_usage").isObject()) total = totalsFrom(info.value("total_token_usage").toObject(), false);
        if (info.value("last_token_usage").isObject()) last = totalsFrom(info.value("last_token_usage").toObject(), true);
        if (last) {
            const CodexTotals base = previous.value_or(CodexTotals{});
            CodexTotals counted = *last;
            if (total) {
                const CodexTotals byTotal = totalDelta(rawBaseline, *total);
                if (shouldPreferTotalDelta(rawBaseline, *total, byTotal, *last, sawDivergent)) counted = byTotal;
                const CodexTotals next = add(base, counted);
                previous = next;
                rawBaseline = *total;
                if (!(*total == next)) sawDivergent = true;
            } else {
                previous = add(base, counted);
                rawBaseline = previous;
            }
            snapshots.append({timestamp, msFromTimestamp(timestamp), *previous});
        } else if (total) {
            const CodexTotals delta = sawDivergent ? divergentTotalDelta(rawBaseline, previous, *total)
                                                   : totalDelta(rawBaseline, *total);
            const CodexTotals counted = add(previous.value_or(CodexTotals{}), delta);
            previous = counted;
            rawBaseline = *total;
            if (!(*total == counted)) sawDivergent = true;
            snapshots.append({timestamp, msFromTimestamp(timestamp), counted});
        }
        return true;
    });
    return snapshots;
}

// Content of `shorter` is a byte prefix of `longer` (codexFilePrefixRelationship).
bool isBytePrefix(const QString &shorter, const QString &longer) {
    QFile a(shorter), b(longer);
    if (!a.open(QIODevice::ReadOnly) || !b.open(QIODevice::ReadOnly) || a.size() > b.size()) return false;
    while (!a.atEnd()) {
        const QByteArray x = a.read(1 << 20);
        if (b.read(x.size()) != x) return false;
    }
    return true;
}

QString projectFromClaudeHeader(const QString &path, const QString &sessionId) {
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly)) return QString();
    const QByteArray data = file.read(65'536);
    for (const QByteArray &line : data.split('\n')) {
        const QJsonObject object = parseObject(line);
        if (object.isEmpty()) continue;
        const QString lineSession = object.value("sessionId").toString(object.value("session_id").toString());
        if (!sessionId.isEmpty() && lineSession != sessionId) continue;
        const QString cwd = object.value("cwd").toString();
        if (QDir::isAbsolutePath(cwd) && !cwd.contains(QChar(0))) return QDir::toNativeSeparators(QDir::cleanPath(cwd));
    }
    return QString();
}

QList<QFileInfo> jsonlFiles(const QStringList &roots, qint64 modifiedSinceMs) {
    QList<QFileInfo> out;
    QSet<QString> seen;
    for (const QString &root : roots) {
        const QFileInfo rootInfo(root);
        if (rootInfo.isFile()) {
            if (rootInfo.lastModified().toMSecsSinceEpoch() >= modifiedSinceMs && !seen.contains(rootInfo.absoluteFilePath())) {
                seen.insert(rootInfo.absoluteFilePath());
                out.append(rootInfo);
            }
            continue;
        }
        if (!rootInfo.isDir()) continue;
        QDirIterator it(root, {"*.jsonl"}, QDir::Files, QDirIterator::Subdirectories);
        while (it.hasNext()) {
            it.next();
            const QFileInfo info = it.fileInfo();
            const QString key = QDir::cleanPath(info.absoluteFilePath());
            if (seen.contains(key) || info.lastModified().toMSecsSinceEpoch() < modifiedSinceMs) continue;
            seen.insert(key);
            out.append(info);
        }
    }
    std::sort(out.begin(), out.end(), [](const QFileInfo &a, const QFileInfo &b) { return a.filePath() < b.filePath(); });
    return out;
}

void finishDay(Day &day, bool claude) {
    day.totalTokens = 0;
    day.cost.reset();
    day.partial = false;
    day.incomplete = 0;
    for (const ModelDay &m : std::as_const(day.models)) {
        day.totalTokens += m.totalTokens;
        day.incomplete += m.incomplete;
        if (m.cost) day.cost = day.cost.value_or(0) + *m.cost;
        if (m.unpricedTokens > 0 || (m.totalTokens > 0 && !m.cost)) day.partial = true;
    }
    if (claude && day.incomplete > 0) day.partial = true;
}

} // namespace

// --- Days ------------------------------------------------------------------------------------

DayRange DayRange::lastDays(qint64 nowMs, int days) {
    const QDate today = QDateTime::fromMSecsSinceEpoch(nowMs).toLocalTime().date();
    const QDate since = today.addDays(-(std::max(1, days) - 1));
    const QDate scanSince = since.addDays(-1);
    DayRange range;
    range.sinceKey = since.toString("yyyy-MM-dd");
    range.untilKey = today.toString("yyyy-MM-dd");
    range.scanSinceKey = scanSince.toString("yyyy-MM-dd");
    range.scanUntilKey = today.addDays(1).toString("yyyy-MM-dd");
    range.scanSinceMs = QDateTime(scanSince, QTime(0, 0)).toMSecsSinceEpoch();
    return range;
}

namespace {
QDateTime parseTimestamp(const QString &text) {
    if (text.size() < 20) return QDateTime();
    QDateTime dt = QDateTime::fromString(text, Qt::ISODateWithMs);
    if (!dt.isValid()) dt = QDateTime::fromString(text, Qt::ISODate);
    // A zone is required (Z or an offset), as in dayKeyFromTimestamp.
    if (!dt.isValid() || dt.timeSpec() == Qt::LocalTime) return QDateTime();
    return dt;
}
} // namespace

QString dayKeyFromTimestamp(const QString &timestamp) {
    const QDateTime dt = parseTimestamp(timestamp);
    return dt.isValid() ? dt.toLocalTime().date().toString("yyyy-MM-dd") : QString();
}

std::optional<qint64> msFromTimestamp(const QString &timestamp) {
    const QDateTime dt = parseTimestamp(timestamp);
    return dt.isValid() ? std::optional<qint64>(dt.toMSecsSinceEpoch()) : std::nullopt;
}

// --- Codex -----------------------------------------------------------------------------------

struct CodexScanner::Memo {
    struct FileEntry {
        qint64 size = -1;
        qint64 mtime = 0;
        QString rangeKey;
        FileResult result;
    };
    struct MetaEntry {
        qint64 size = -1;
        qint64 mtime = 0;
        CodexMeta meta;
    };
    QHash<QString, FileEntry> files;
    QHash<QString, MetaEntry> meta;

    CodexMeta metaFor(const QFileInfo &info) {
        const QString path = info.absoluteFilePath();
        MetaEntry &entry = meta[path];
        const qint64 mtime = info.lastModified().toMSecsSinceEpoch();
        if (entry.size != info.size() || entry.mtime != mtime) {
            bool ok = true;
            CodexMeta read = readCodexMeta(path, &ok);
            if (ok) {
                entry = {info.size(), mtime, std::move(read)};
            } else {
                // A failed read is not cached: the last good metadata (else what was read) stands
                // in, and size -1 makes the next scan read the file again.
                if (entry.meta.sessionId.isEmpty()) entry.meta = std::move(read);
                entry.size = -1;
            }
        }
        return entry.meta;
    }
};

CodexScanner::CodexScanner(QStringList roots) : m_roots(std::move(roots)), m_memo(std::make_shared<Memo>()) {}

CodexScanner::FileResult CodexScanner::parseFile(const QString &path, const DayRange &range, const Resolver &resolver,
                                                 bool *readOk) {
    FileResult result;
    std::optional<QString> currentModel;
    std::optional<CodexTotals> previousTotals, rawTotalsBaseline, inheritedTotals, remainingInherited,
        unresolvedForkWatermark;
    bool forkBaselineResolved = false, hasUnresolvedForkBaseline = false, sawDivergent = false;

    const auto resolveForkBaseline = [&](const QString &parent, const QString &forkedAt) {
        if (forkBaselineResolved || !resolver) return;
        forkBaselineResolved = true;
        const ForkBaseline baseline = resolver(parent, forkedAt);
        if (baseline.resolved) {
            inheritedTotals = baseline.totals;
            remainingInherited = baseline.totals;
            hasUnresolvedForkBaseline = false;
        } else {
            hasUnresolvedForkBaseline = true;
        }
    };

    bool metaOk = true;
    const CodexMeta meta = readCodexMeta(path, &metaOk);
    result.sessionId = meta.sessionId;
    result.forkedFromId = meta.forkedFromId;
    if (!meta.forkedFromId.isEmpty() && !inheritedTotals) resolveForkBaseline(meta.forkedFromId, meta.forkTimestamp);

    const auto handleTokenCount = [&](const QString &timestamp, const QString &dayKey, const QString &recordModel,
                                      const std::optional<CodexTotals> &total, const std::optional<CodexTotals> &last) {
        const QString model = currentModel.value_or(recordModel.isEmpty() ? QStringLiteral("gpt-5") : recordModel);
        CodexTotals delta;
        const auto adjustedLastDelta = [&](const CodexTotals &raw) {
            if (!remainingInherited) return raw;
            CodexTotals remaining = *remainingInherited;
            const CodexTotals adjusted{std::max<qint64>(0, raw.input - remaining.input),
                                       std::max<qint64>(0, raw.cached - remaining.cached),
                                       std::max<qint64>(0, raw.output - remaining.output)};
            remaining.input = std::max<qint64>(0, remaining.input - raw.input);
            remaining.cached = std::max<qint64>(0, remaining.cached - raw.cached);
            remaining.output = std::max<qint64>(0, remaining.output - raw.output);
            if (remaining == CodexTotals{}) remainingInherited.reset();
            else remainingInherited = remaining;
            return adjusted;
        };

        const bool handledUnresolvedForkTotal = hasUnresolvedForkBaseline && total.has_value();
        if (handledUnresolvedForkTotal) {
            const CodexTotals currentRaw = *total;
            if (!last) {
                unresolvedForkWatermark = currentRaw;
                return;
            }
            // The parent is unavailable, but last_token_usage is still the child's own turn.
            const CodexTotals adjusted = unresolvedForkWatermark
                ? minTotals(*last, totalDelta(unresolvedForkWatermark, currentRaw)) : *last;
            delta = adjusted;
            previousTotals = add(previousTotals.value_or(CodexTotals{}), adjusted);
            rawTotalsBaseline = previousTotals;
            unresolvedForkWatermark = currentRaw;
        }

        if (!handledUnresolvedForkTotal && total && !result.forkedFromId.isEmpty() && !hasUnresolvedForkBaseline) {
            const CodexTotals current = subtractInherited(*total, inheritedTotals);
            delta = sawDivergent ? divergentTotalDelta(rawTotalsBaseline, previousTotals, current)
                                 : totalDelta(rawTotalsBaseline, current);
            previousTotals = add(previousTotals.value_or(CodexTotals{}), delta);
            rawTotalsBaseline = current;
            if (!totalsEqual(rawTotalsBaseline, previousTotals)) sawDivergent = true;
            remainingInherited.reset();
        } else if (!handledUnresolvedForkTotal && last) {
            const bool hadRemaining = remainingInherited.has_value();
            CodexTotals adjusted = adjustedLastDelta(*last);
            delta = adjusted;
            const CodexTotals prev = previousTotals.value_or(CodexTotals{});
            if (total && !hasUnresolvedForkBaseline) {
                const CodexTotals current = subtractInherited(*total, inheritedTotals);
                const CodexTotals byTotal = totalDelta(rawTotalsBaseline, current);
                if (!hadRemaining && shouldPreferTotalDelta(rawTotalsBaseline, current, byTotal, *last, sawDivergent)) {
                    adjusted = byTotal;
                    delta = adjusted;
                    remainingInherited.reset();
                }
                const CodexTotals counted = add(prev, adjusted);
                previousTotals = counted;
                rawTotalsBaseline = current;
                if (!(current == counted)) sawDivergent = true;
            } else {
                const CodexTotals counted = add(prev, adjusted);
                previousTotals = counted;
                rawTotalsBaseline = counted;
            }
        } else if (!handledUnresolvedForkTotal && total) {
            const CodexTotals current = subtractInherited(*total, inheritedTotals);
            delta = sawDivergent ? divergentTotalDelta(rawTotalsBaseline, previousTotals, current)
                                 : totalDelta(rawTotalsBaseline, current);
            previousTotals = add(previousTotals.value_or(CodexTotals{}), delta);
            rawTotalsBaseline = current;
            if (!totalsEqual(rawTotalsBaseline, previousTotals)) sawDivergent = true;
            remainingInherited.reset();
        } else if (!handledUnresolvedForkTotal) {
            return;
        }

        if (delta == CodexTotals{} || !range.inScan(dayKey)) return;
        Row row;
        row.day = dayKey;
        row.model = normalizeCodexModel(model);
        row.input = delta.input;
        row.cached = std::min(delta.cached, delta.input);
        row.output = delta.output;
        row.timestampMs = msFromTimestamp(timestamp).value_or(0);
        result.rows.append(row);
    };

    const bool linesOk = forEachLine(path, kCodexMaxLineBytes, [&](const QByteArray &line, bool truncated) {
        if (line.isEmpty()) return true;
        if (truncated) {
            // A turn_context can carry a huge prompt; its model sits near the start.
            const QString model = truncatedTurnContextModel(line);
            if (!model.isEmpty()) currentModel = model;
            return true;
        }
        const bool eventMsg = contains(line, "\"type\":\"event_msg\"");
        if (!eventMsg && !contains(line, "\"type\":\"turn_context\"") && !contains(line, "\"type\":\"session_meta\""))
            return true;
        if (eventMsg && !contains(line, "\"token_count\"") && !contains(line, "\"task_started\"")) return true;

        const QJsonObject object = parseObject(line);
        const QString type = object.value("type").toString();
        if (type == "session_meta") {
            const QJsonObject payload = object.value("payload").toObject();
            if (result.sessionId.isEmpty()) result.sessionId = codexSessionId(object, payload);
            if (result.forkedFromId.isEmpty()) result.forkedFromId = codexForkParentId(payload);
            if (!result.forkedFromId.isEmpty())
                resolveForkBaseline(result.forkedFromId,
                                    payload.value("timestamp").toString(object.value("timestamp").toString()));
            return true;
        }
        const QString timestamp = object.value("timestamp").toString();
        const QString dayKey = dayKeyFromTimestamp(timestamp);
        if (dayKey.isEmpty()) return true;
        const QJsonObject payload = object.value("payload").toObject();
        if (type == "turn_context") {
            QString model = payload.value("model").toString();
            if (model.isEmpty()) model = payload.value("info").toObject().value("model").toString();
            if (!model.isEmpty()) currentModel = model;
            return true;
        }
        if (type != "event_msg" || payload.value("type").toString() != "token_count") return true;
        const QJsonObject info = payload.value("info").toObject();
        QString recordModel = info.value("model").toString();
        if (recordModel.isEmpty()) recordModel = info.value("model_name").toString();
        if (recordModel.isEmpty()) recordModel = payload.value("model").toString();
        if (recordModel.isEmpty()) recordModel = object.value("model").toString();
        std::optional<CodexTotals> total, last;
        if (info.value("total_token_usage").isObject()) total = totalsFrom(info.value("total_token_usage").toObject(), true);
        if (info.value("last_token_usage").isObject()) last = totalsFrom(info.value("last_token_usage").toObject(), true);
        handleTokenCount(timestamp, dayKey, recordModel, total, last);
        return true;
    });
    if (readOk) *readOk = metaOk && linesOk;
    return result;
}

Report CodexScanner::scan(qint64 nowMs, int days, const ModelsDevCatalog *catalog) {
    const DayRange range = DayRange::lastDays(nowMs, days);
    const QString rangeKey = range.scanSinceKey + '|' + range.scanUntilKey;
    const QList<QFileInfo> files = jsonlFiles(m_roots, range.scanSinceMs);
    Memo &memo = *m_memo;

    // CodexSessionFileIndex: scanned files first, then every log under the roots.
    QHash<QString, QString> fileBySession;
    qsizetype nextIndexed = 0;
    bool indexedRoots = false;
    QHash<QString, QList<TimestampedTotals>> snapshotsBySession;
    QSet<QString> missingParents;
    const auto fileForSession = [&](const QString &id) -> QString {
        if (const auto it = fileBySession.constFind(id); it != fileBySession.constEnd()) return *it;
        while (nextIndexed < files.size()) {
            const QFileInfo &info = files.at(nextIndexed++);
            const QString sid = memo.metaFor(info).sessionId;
            if (sid.isEmpty()) continue;
            if (!fileBySession.contains(sid)) fileBySession.insert(sid, info.absoluteFilePath());
            if (sid == id) return info.absoluteFilePath();
        }
        if (!indexedRoots) {
            indexedRoots = true;
            for (const QFileInfo &info : jsonlFiles(m_roots, 0)) {
                const QString sid = memo.metaFor(info).sessionId;
                if (!sid.isEmpty() && !fileBySession.contains(sid)) fileBySession.insert(sid, info.absoluteFilePath());
            }
            return fileBySession.value(id);
        }
        return QString();
    };
    // CodexInheritedTotalsResolver.inheritedTotals(for:atOrBefore:)
    const Resolver resolver = [&](const QString &parent, const QString &forkedAt) -> ForkBaseline {
        if (forkedAt.isEmpty() || missingParents.contains(parent)) return {};
        if (!snapshotsBySession.contains(parent)) {
            const QString path = fileForSession(parent);
            QString parsedId;
            const QList<TimestampedTotals> snapshots = path.isEmpty() ? QList<TimestampedTotals>()
                                                                      : readCodexSnapshots(path, &parsedId);
            if (path.isEmpty() || parsedId != parent) {
                missingParents.insert(parent);
                return {};
            }
            snapshotsBySession.insert(parent, snapshots);
        }
        const std::optional<qint64> cutoff = msFromTimestamp(forkedAt);
        ForkBaseline baseline{true, std::nullopt};
        for (const TimestampedTotals &s : snapshotsBySession.value(parent)) {
            const bool atOrBefore = s.ms && cutoff ? *s.ms <= *cutoff : s.timestamp <= forkedAt;
            if (atOrBefore) baseline.totals = s.totals;
        }
        return baseline;
    };

    struct Owner {
        QFileInfo info;
        FileResult result;
    };
    QList<Owner> parsed;
    QSet<QString> live;
    for (const QFileInfo &info : files) {
        const QString path = info.absoluteFilePath();
        live.insert(path);
        Memo::FileEntry &entry = memo.files[path];
        const qint64 mtime = info.lastModified().toMSecsSinceEpoch();
        if (entry.size != info.size() || entry.mtime != mtime || entry.rangeKey != rangeKey) {
            bool ok = true;
            FileResult result = parseFile(path, range, resolver, &ok);
            if (ok) entry = {info.size(), mtime, rangeKey, std::move(result)};
            // A read failure is not cached: the last good parse of this range stands in (else what
            // was read), and size -1 makes the next scan read the file again.
            else if (entry.rangeKey == rangeKey) entry.size = -1;
            else entry = {-1, mtime, rangeKey, std::move(result)};
        }
        parsed.append({info, entry.result});
    }
    for (auto it = memo.files.begin(); it != memo.files.end();) {
        if (live.contains(it.key())) ++it;
        else it = memo.files.erase(it);
    }

    // One owner per session: the copy every other copy is a byte prefix of.
    Report report;
    report.files = int(files.size());
    QHash<QString, QList<int>> bySession;
    QList<int> owners;
    for (int i = 0; i < parsed.size(); ++i) {
        if (parsed[i].result.sessionId.isEmpty()) owners.append(i);
        else bySession[parsed[i].result.sessionId].append(i);
    }
    for (auto it = bySession.cbegin(); it != bySession.cend(); ++it) {
        QList<int> copies = it.value();
        if (copies.size() == 1) {
            owners.append(copies.first());
            continue;
        }
        std::sort(copies.begin(), copies.end(), [&](int a, int b) { return parsed[a].info.size() > parsed[b].info.size(); });
        const QString longest = parsed[copies.first()].info.absoluteFilePath();
        const bool covered = std::all_of(copies.begin() + 1, copies.end(), [&](int i) {
            return isBytePrefix(parsed[i].info.absoluteFilePath(), longest);
        });
        if (covered) owners.append(copies.first());
        else ++report.excludedSessions;
    }

    QMap<QString, Day> daysByKey;
    for (int index : owners) {
        const Owner &owner = parsed[index];
        Session session;
        session.id = owner.result.sessionId.isEmpty() ? owner.info.absoluteFilePath() : owner.result.sessionId;
        QSet<QString> models;
        for (const Row &row : owner.result.rows) {
            if (!range.inReport(row.day)) continue;
            const std::optional<double> cost = codexCostUSD(row.model, row.input, row.cached, row.output, catalog);
            Day &day = daysByKey[row.day];
            day.key = row.day;
            ModelDay &m = day.models[row.model];
            m.input += row.input;
            m.cached += row.cached;
            m.output += row.output;
            m.totalTokens += row.input + row.output;
            ++m.requests;
            if (cost) m.cost = m.cost.value_or(0) + *cost;
            else m.unpricedTokens += row.input + row.output;

            session.totalTokens += row.input + row.output;
            if (cost) session.cost = session.cost.value_or(0) + *cost;
            else session.partial = true;
            session.lastActivityMs = std::max(session.lastActivityMs, row.timestampMs);
            models.insert(row.model);
        }
        if (session.totalTokens <= 0) continue;
        session.models = QStringList(models.cbegin(), models.cend());
        session.models.sort();
        session.projectPath = memo.metaFor(owner.info).cwd;
        report.sessions.append(session);
    }
    for (Day &day : daysByKey) {
        finishDay(day, false);
        report.days.append(day);
    }
    std::sort(report.sessions.begin(), report.sessions.end(), [](const Session &a, const Session &b) {
        return a.lastActivityMs != b.lastActivityMs ? a.lastActivityMs > b.lastActivityMs : a.id < b.id;
    });
    return report;
}

// --- Claude ----------------------------------------------------------------------------------

namespace {

QString nonblank(const QString &value) { return value.trimmed().isEmpty() ? QString() : value; }

// claudeCanonicalRowKey: message + request, else message + session; length-prefixed.
QString claudeRowKey(const ClaudeScanner::Row &row) {
    const QString message = nonblank(row.messageId);
    if (message.isEmpty()) return QString();
    const QString utf8Length = QString::number(message.toUtf8().size());
    if (const QString request = nonblank(row.requestId); !request.isEmpty())
        return "r:" + utf8Length + ':' + message + request;
    if (const QString session = nonblank(row.sessionId); !session.isEmpty())
        return "s:" + utf8Length + ':' + message + session;
    return QString();
}

struct SourcedRow {
    QString path;
    ClaudeScanner::Row row;
};

// claudeRowWins(lhs: candidate, rhs: existing): complete beats incomplete, a main-chain row beats
// a sidechain one, a parent file beats a subagent file, then the smaller path.
bool claudeCandidateWins(const SourcedRow &candidate, const SourcedRow &existing) {
    if (candidate.row.incomplete != existing.row.incomplete) return existing.row.incomplete;
    if (candidate.row.sidechain != existing.row.sidechain) return existing.row.sidechain;
    if (candidate.row.subagent != existing.row.subagent) return existing.row.subagent;
    return candidate.path < existing.path;
}

struct ClaudeTotals {
    QList<Day> days;
    qint64 totalTokens = 0;
    std::optional<double> cost;
    bool partial = false;
};

// buildClaudeReportFromCache over reconciled rows: each model-day is repriced with the current
// prices; a model-day with any unpriced request has no cost.
ClaudeTotals claudeTotals(const QList<SourcedRow> &rows, const DayRange &range, const ModelsDevCatalog *catalog) {
    struct Repriced {
        double total = 0;
        int samples = 0;
        bool unresolved = false;
    };
    QMap<QString, Day> days;
    QHash<QString, Repriced> repriced;
    for (const SourcedRow &sourced : rows) {
        const ClaudeScanner::Row &row = sourced.row;
        if (!range.inReport(row.day)) continue;
        Day &day = days[row.day];
        day.key = row.day;
        ModelDay &m = day.models[row.model];
        if (row.incomplete) {
            ++m.incomplete;
            continue;
        }
        m.input += row.input;
        m.cached += row.cacheRead;
        m.cacheCreation += row.cacheCreate;
        m.output += row.output;
        ++m.requests;
        Repriced &r = repriced[row.day + '\n' + row.model];
        ++r.samples;
        const std::optional<double> current = claudeCostUSD(row.model, row.input, row.cacheRead, row.cacheCreate,
                                                            row.cacheCreate1h, row.output, row.timestampMs, catalog);
        std::optional<double> cost;
        if (row.costPriced && row.costNanos == 0) cost = 0;
        else if (current) cost = current;
        else if (row.costPriced) cost = double(row.costNanos) / kCostScale;
        if (cost) r.total += *cost;
        else r.unresolved = true;
    }
    ClaudeTotals totals;
    for (Day &day : days) {
        for (auto it = day.models.begin(); it != day.models.end(); ++it) {
            ModelDay &m = it.value();
            m.totalTokens = m.requests > 0 ? m.input + m.cached + m.cacheCreation + m.output : 0;
            const auto r = repriced.constFind(day.key + '\n' + it.key());
            if (r != repriced.constEnd() && r->samples == m.requests && !r->unresolved) m.cost = r->total;
            else if (m.requests > 0) m.unpricedTokens = m.totalTokens;
        }
        finishDay(day, true);
        totals.totalTokens += day.totalTokens;
        if (day.cost) totals.cost = totals.cost.value_or(0) + *day.cost;
        if (day.partial) totals.partial = true;
        totals.days.append(day);
    }
    return totals;
}

} // namespace

struct ClaudeScanner::Memo {
    struct FileEntry {
        qint64 size = -1;
        qint64 mtime = 0;
        QString rangeKey;
        QList<Row> rows;
    };
    QHash<QString, FileEntry> files;
};

ClaudeScanner::ClaudeScanner(QStringList roots) : m_roots(std::move(roots)), m_memo(std::make_shared<Memo>()) {}

ClaudeScanner::ClaudeScanner(std::function<QStringList()> roots)
    : m_rootsProvider(std::move(roots)), m_memo(std::make_shared<Memo>()) {}

QList<ClaudeScanner::Row> ClaudeScanner::parseFile(const QString &path, const DayRange &range,
                                                   const ModelsDevCatalog *catalog, bool *readOk) {
    const bool subagent = QDir::fromNativeSeparators(path).contains("/subagents/");
    QMap<QString, Row> keyed;
    QList<Row> unkeyed;
    const bool ok = forEachLine(path, kClaudeMaxLineBytes, [&](const QByteArray &line, bool truncated) {
        if (line.isEmpty() || truncated || !contains(line, "\"usage\"")) return true;
        const QJsonObject object = parseObject(line);
        if (object.value("type").toString() != "assistant") return true;
        const QString timestamp = object.value("timestamp").toString();
        const std::optional<qint64> ms = msFromTimestamp(timestamp);
        const QString dayKey = dayKeyFromTimestamp(timestamp);
        if (!ms || dayKey.isEmpty()) return true;
        const QJsonObject message = object.value("message").toObject();
        const QString model = message.value("model").toString();
        if (model.isEmpty() || !message.value("usage").isObject()) return true;
        const QJsonObject usage = message.value("usage").toObject();
        Row row;
        row.input = std::max<qint64>(0, toInt(usage.value("input_tokens")));
        row.cacheCreate = std::max<qint64>(0, toInt(usage.value("cache_creation_input_tokens")));
        const QJsonObject creation = usage.value("cache_creation").toObject();
        row.cacheCreate1h = std::min(row.cacheCreate, std::max<qint64>(0, toInt(creation.value("ephemeral_1h_input_tokens"))));
        row.cacheRead = std::max<qint64>(0, toInt(usage.value("cache_read_input_tokens")));
        row.output = std::max<qint64>(0, toInt(usage.value("output_tokens")));
        if (row.input == 0 && row.cacheCreate == 0 && row.cacheRead == 0 && row.output == 0) return true;
        row.incomplete = message.contains("stop_reason") && message.value("stop_reason").isNull() && row.input > 0
            && row.output == 0 && row.cacheCreate == 0 && row.cacheRead == 0;
        if (!row.incomplete) {
            const auto cost = claudeCostUSD(model, row.input, row.cacheRead, row.cacheCreate, row.cacheCreate1h,
                                            row.output, ms, catalog);
            row.costPriced = cost.has_value();
            row.costNanos = cost ? qint64(std::llround(*cost * kCostScale)) : 0;
        }
        if (!range.inScan(dayKey)) return true;
        row.day = dayKey;
        row.model = normalizeClaudeModel(model);
        row.messageId = message.value("id").toString();
        row.requestId = object.value("requestId").toString(object.value("request_id").toString());
        row.sessionId = object.value("sessionId").toString();
        if (row.sessionId.isEmpty()) row.sessionId = object.value("session_id").toString();
        if (row.sessionId.isEmpty()) row.sessionId = object.value("metadata").toObject().value("sessionId").toString();
        if (row.sessionId.isEmpty()) row.sessionId = message.value("metadata").toObject().value("sessionId").toString();
        row.timestampMs = *ms;
        row.sidechain = object.value("isSidechain").toBool() || object.value("isSidechain").toDouble() != 0;
        row.subagent = subagent;
        // Streaming chunks share message id + request id: the final cumulative chunk wins.
        const QString key = claudeRowKey(row);
        if (key.isEmpty()) {
            unkeyed.append(row); // older logs omit ids: every line counts
        } else {
            const auto existing = keyed.constFind(key);
            if (existing == keyed.constEnd() || existing->incomplete || !row.incomplete) keyed.insert(key, row);
        }
        return true;
    });
    QList<Row> rows = keyed.values(); // QMap: sorted by key, as on macOS
    rows.append(unkeyed);
    if (readOk) *readOk = ok;
    return rows;
}

QStringList ClaudeScanner::defaultRoots(const QString &home, const QString &configDirEnv, const QString &appData) {
    if (!configDirEnv.isEmpty()) return {QDir::cleanPath(configDirEnv + "/projects")};
    QStringList roots{QDir::cleanPath(home + "/.config/claude/projects"), QDir::cleanPath(home + "/.claude/projects")};
    if (appData.isEmpty()) return roots;
    // Claude desktop's Code and agent-mode sessions keep their own projects folders.
    static const QSet<QString> skipped = {".build", ".git", "build", "DerivedData", "node_modules", "outputs", "target",
                                          ".claude"};
    const QString desktop = appData + "/Claude";
    QList<QPair<QString, int>> queue{{desktop + "/local-agent-mode-sessions", 0}, {desktop + "/claude-code-sessions", 0}};
    for (qsizetype index = 0; index < queue.size() && index < 4096; ++index) {
        const auto [directory, depth] = queue.at(index);
        const QFileInfo audit(directory + "/audit.jsonl");
        if (audit.isFile() && !audit.isSymLink()) roots.append(QDir::cleanPath(audit.filePath()));
        const QFileInfo projects(directory + "/.claude/projects");
        if (projects.isDir()) roots.append(QDir::cleanPath(projects.filePath()));
        if (depth >= 4) continue;
        QFileInfoList children = QDir(directory).entryInfoList(QDir::Dirs | QDir::NoDotAndDotDot, QDir::Name);
        for (const QFileInfo &child : children) {
            if (skipped.contains(child.fileName()) || child.isSymLink() || queue.size() >= 4096) continue;
            queue.append({child.filePath(), depth + 1});
        }
    }
    return roots;
}

Report ClaudeScanner::scan(qint64 nowMs, int days, const ModelsDevCatalog *catalog) {
    const DayRange range = DayRange::lastDays(nowMs, days);
    const QString rangeKey = range.scanSinceKey + '|' + range.scanUntilKey;
    const QList<QFileInfo> files = jsonlFiles(m_rootsProvider ? m_rootsProvider() : m_roots, range.scanSinceMs);
    Memo &memo = *m_memo;
    QSet<QString> live;
    QList<SourcedRow> rows;
    QHash<QString, SourcedRow> winners;
    for (const QFileInfo &info : files) { // sorted by path, as cache.files.keys.sorted()
        const QString path = info.absoluteFilePath();
        live.insert(path);
        Memo::FileEntry &entry = memo.files[path];
        const qint64 mtime = info.lastModified().toMSecsSinceEpoch();
        if (entry.size != info.size() || entry.mtime != mtime || entry.rangeKey != rangeKey) {
            bool ok = true;
            QList<Row> parsedRows = parseFile(path, range, catalog, &ok);
            if (ok) entry = {info.size(), mtime, rangeKey, std::move(parsedRows)};
            // As for Codex: keep the last good rows (else what was read) and read the file again next scan.
            else if (entry.rangeKey == rangeKey) entry.size = -1;
            else entry = {-1, mtime, rangeKey, std::move(parsedRows)};
        }
        for (const Row &row : std::as_const(entry.rows)) {
            const SourcedRow candidate{path, row};
            const QString key = claudeRowKey(row);
            if (key.isEmpty()) {
                rows.append(candidate);
                continue;
            }
            const auto existing = winners.constFind(key);
            if (existing == winners.constEnd() || claudeCandidateWins(candidate, *existing)) winners.insert(key, candidate);
        }
    }
    for (auto it = memo.files.begin(); it != memo.files.end();) {
        if (live.contains(it.key())) ++it;
        else it = memo.files.erase(it);
    }
    QStringList keys = winners.keys();
    keys.sort();
    for (const QString &key : std::as_const(keys)) rows.append(winners.value(key));

    Report report;
    report.files = int(files.size());
    report.days = claudeTotals(rows, range, catalog).days;

    // buildClaudeUsageDetails: one session per session id (else per file).
    QMap<QString, QList<SourcedRow>> groups;
    for (const SourcedRow &row : std::as_const(rows)) {
        if (range.inReport(row.row.day)) groups[row.row.sessionId.isEmpty() ? row.path : row.row.sessionId].append(row);
    }
    for (auto it = groups.cbegin(); it != groups.cend(); ++it) {
        const ClaudeTotals totals = claudeTotals(it.value(), range, catalog);
        if (totals.totalTokens <= 0) continue;
        Session session;
        session.id = it.key();
        session.totalTokens = totals.totalTokens;
        session.cost = totals.cost;
        session.partial = totals.partial;
        QSet<QString> models, projects, paths;
        for (const SourcedRow &row : it.value()) {
            models.insert(row.row.model);
            session.lastActivityMs = std::max(session.lastActivityMs, row.row.timestampMs);
            if (!paths.contains(row.path)) {
                paths.insert(row.path);
                const QString project = projectFromClaudeHeader(row.path, row.row.sessionId);
                if (!project.isEmpty()) projects.insert(project);
            }
        }
        session.models = QStringList(models.cbegin(), models.cend());
        session.models.sort();
        if (projects.size() == 1) session.projectPath = *projects.cbegin();
        report.sessions.append(session);
    }
    std::sort(report.sessions.begin(), report.sessions.end(), [](const Session &a, const Session &b) {
        return a.lastActivityMs != b.lastActivityMs ? a.lastActivityMs > b.lastActivityMs : a.id < b.id;
    });
    return report;
}

} // namespace asb::usage

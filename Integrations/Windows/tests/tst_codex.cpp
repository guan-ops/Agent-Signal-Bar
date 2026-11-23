// Codex data layer: the parser and the store replay tests/golden/codex_golden.jsonl
// (generated from the Swift sources); the monitor and display rules are checked against
// hand-written scenarios in temporary directories. Nothing here reads the real ~/.codex.
#include "../src/ActivityDisplay.h"
#include "../src/ClaudeHookInstaller.h"
#include "../src/CodexActivityMonitor.h"
#include "../src/CodexSessionParser.h"
#include "../src/HookAdapters.h"
#include "../src/SignalStateFile.h"
#include "../src/SignalStore.h"
#include "../src/SoundFile.h"
#include "../src/LightScope.h"
#include "../src/PresenceMonitor.h"
#include "../src/SignalModel.h"
#include "../src/CliPath.h"
#include "../src/UsagePricing.h"
#include "../src/UsageScanner.h"
#include "../src/I18n.h"
#include "../src/ClaudeUiMonitor.h"
#include "../src/CodexAccounts.h"
#include "../src/QuotaFetcher.h"
#include "../src/Secrets.h"

#include <QLockFile>

#include <QDateTime>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QTemporaryDir>
#include <QtTest>

using namespace asb;

namespace {

QList<QJsonObject> goldenRows(const QString &kind) {
    QFile file(QStringLiteral(CODEX_GOLDEN_PATH));
    if (!file.open(QIODevice::ReadOnly)) qFatal("cannot open %s", CODEX_GOLDEN_PATH);
    QList<QJsonObject> rows;
    for (const QByteArray &line : file.readAll().split('\n')) {
        if (line.isEmpty()) continue;
        const QJsonObject row = QJsonDocument::fromJson(line).object();
        if (row.value("kind").toString() == kind) rows.append(row);
    }
    return rows;
}

QList<QByteArray> fixtureLines() {
    QFile file(QStringLiteral(CODEX_LINES_PATH));
    if (!file.open(QIODevice::ReadOnly)) qFatal("cannot open %s", CODEX_LINES_PATH);
    QList<QByteArray> lines;
    for (const QByteArray &line : file.readAll().split('\n')) {
        if (!line.isEmpty()) lines.append(line);
    }
    return lines;
}

QJsonValue orNull(const std::optional<QString> &value) { return value ? QJsonValue(*value) : QJsonValue(); }

QString iso(qint64 ms) { return QDateTime::fromMSecsSinceEpoch(ms, QTimeZone::UTC).toString(Qt::ISODateWithMs); }

QByteArray line(qint64 ms, const QString &type, const QString &payload) {
    return QStringLiteral(R"({"timestamp":"%1","type":"%2","payload":%3})").arg(iso(ms), type, payload).toUtf8() + '\n';
}

void append(const QString &path, const QByteArray &data) {
    QFile f(path);
    QVERIFY(f.open(QIODevice::Append));
    f.write(data);
}

const QString kRolloutName = QStringLiteral("rollout-2026-03-01T10-00-00-0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b.jsonl");
const QString kRolloutID = QStringLiteral("0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b");

codex::ActivityMonitor monitorFor(const QString &sessionsDir) {
    codex::ActivityMonitor::Options options;
    options.fullScanIntervalMs = 0; // rescan on every poll so new files show up at once
    return codex::ActivityMonitor({{sessionsDir, QString()}}, options);
}

SessionStatus session(const QString &id, const QString &signal, qint64 updatedAt, const QString &agent,
                      const QString &event) {
    return SessionStatus{id, signal, updatedAt, agent, event};
}

QJsonObject readJson(const QString &path) {
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly)) return {};
    return QJsonDocument::fromJson(f.readAll()).object();
}

void writeText(const QString &path, const QByteArray &data) {
    QFile f(path);
    QVERIFY(f.open(QIODevice::WriteOnly | QIODevice::Truncate));
    f.write(data);
}

int ownedCommands(const QJsonObject &settings) {
    int count = 0;
    const QJsonObject hooks = settings.value("hooks").toObject();
    for (const QString &event : hooks.keys()) {
        for (const QJsonValue &block : hooks.value(event).toArray()) {
            for (const QJsonValue &item : block.toObject().value("hooks").toArray()) {
                if (item.toObject().value("command").toString().contains("agent-signal")) ++count;
            }
        }
    }
    return count;
}

// Local time on a November 2026 day, as a UTC ISO timestamp (the form agents log).
QString isoAt(int day, int hour, int minute = 0) {
    return QDateTime(QDate(2026, 11, day), QTime(hour, minute)).toUTC().toString(Qt::ISODateWithMs);
}

QByteArray jsonLine(const QJsonObject &object) { return QJsonDocument(object).toJson(QJsonDocument::Compact) + '\n'; }

QByteArray codexLine(const QString &type, const QString &timestamp, const QJsonObject &payload) {
    return jsonLine({{"timestamp", timestamp}, {"type", type}, {"payload", payload}});
}

QJsonObject codexUsage(qint64 input, qint64 cached, qint64 output) {
    return {{"input_tokens", input}, {"cached_input_tokens", cached}, {"output_tokens", output},
            {"total_tokens", input + output}};
}

QByteArray tokenCount(const QString &timestamp, const QJsonObject &total, const QJsonObject &last) {
    QJsonObject info;
    if (!total.isEmpty()) info.insert("total_token_usage", total);
    if (!last.isEmpty()) info.insert("last_token_usage", last);
    return codexLine("event_msg", timestamp, {{"type", "token_count"}, {"info", info}});
}

void writeFile(const QString &path, const QByteArray &data) {
    QDir().mkpath(QFileInfo(path).absolutePath());
    QFile f(path);
    QVERIFY(f.open(QIODevice::WriteOnly | QIODevice::Truncate));
    f.write(data);
}

const usage::Day *findDay(const usage::Report &report, int day) {
    const QString key = QDate(2026, 11, day).toString("yyyy-MM-dd");
    for (const usage::Day &d : report.days) {
        if (d.key == key) return &d;
    }
    return nullptr;
}

} // namespace

class CodexTest : public QObject {
    Q_OBJECT
private slots:
    void parserMatchesSwiftGolden() {
        const QList<QByteArray> lines = fixtureLines();
        int checked = 0;
        for (const QJsonObject &row : goldenRows("activity")) {
            const QByteArray &input = lines.at(row.value("line").toInt());
            const auto a = codex::activity(input, "default-session", row.value("defaultAgent").toString());
            const QJsonValue expected = row.value("result");
            if (expected.isNull()) {
                QVERIFY2(!a, input.constData());
            } else {
                QVERIFY2(a.has_value(), input.constData());
                const QJsonObject e = expected.toObject();
                QCOMPARE(a->signal, e.value("signal").toString());
                QCOMPARE(a->sessionID, e.value("sessionID").toString());
                QCOMPARE(a->agent, e.value("agent").toString());
                QCOMPARE(a->event, e.value("event").toString());
                const QJsonValue ts = e.value("timestamp");
                QVERIFY2(ts.isNull() == !a->timestampMs.has_value(), input.constData());
                if (!ts.isNull()) QCOMPARE(*a->timestampMs, qint64(ts.toDouble()));
            }
            ++checked;
        }
        for (const QJsonObject &row : goldenRows("meta")) {
            const QByteArray &input = lines.at(row.value("line").toInt());
            QCOMPARE(orNull(codex::agentNameFromSessionMeta(input)), row.value("agent"));
            QCOMPARE(orNull(codex::sessionIDFromSessionMeta(input)), row.value("sessionID"));
            QCOMPARE(orNull(codex::forkedFromSessionIDFromSessionMeta(input)), row.value("forkedFrom"));
            ++checked;
        }
        QVERIFY(checked > 150);
    }

    void storeMatchesSwiftGolden() {
        const qint64 base = 1'800'000'000'000;
        QString scenario;
        SignalStore store;
        int checked = 0;
        for (const QJsonObject &row : goldenRows("store")) {
            if (row.value("scenario").toString() != scenario) {
                scenario = row.value("scenario").toString();
                store = SignalStore();
            }
            const QJsonObject input = row.value("input").toObject();
            const QString signal = input.value("signal").toString();
            const SignalSnapshot snapshot = signal.isEmpty()
                ? store.readSnapshot(base)
                : store.applySessionSignal(signal, input.value("session").toString(), input.value("agent").toString(),
                                           input.value("event").toString(), base + input.value("offset").toInt() * 1000, base);
            const QString where = scenario + " step " + QString::number(row.value("step").toInt());
            QVERIFY2(snapshot.aggregate == row.value("aggregate").toString(),
                     qPrintable(where + ": aggregate " + snapshot.aggregate));
            const QJsonArray sessions = row.value("sessions").toArray();
            QVERIFY2(snapshot.sessions.size() == sessions.size(), qPrintable(where + ": session count"));
            for (int i = 0; i < sessions.size(); ++i) {
                const QJsonObject e = sessions[i].toObject();
                QCOMPARE(snapshot.sessions[i].sessionID, e.value("id").toString());
                QCOMPARE(snapshot.sessions[i].signal, e.value("signal").toString());
                QCOMPARE(snapshot.sessions[i].lastEvent, e.value("event").toString());
                QCOMPARE((snapshot.sessions[i].updatedAt - base) / 1000, qint64(e.value("offset").toInt()));
            }
            const QJsonArray events = row.value("events").toArray();
            QVERIFY2(snapshot.recentEvents.size() == events.size(), qPrintable(where + ": event count"));
            for (int i = 0; i < events.size(); ++i) {
                const QJsonObject e = events[i].toObject();
                QCOMPARE(snapshot.recentEvents[i].sessionID, e.value("session").toString());
                QCOMPARE(snapshot.recentEvents[i].signal, e.value("signal").toString());
                QCOMPARE(snapshot.recentEvents[i].event, e.value("event").toString());
                QCOMPARE((snapshot.recentEvents[i].updatedAt - base) / 1000, qint64(e.value("offset").toInt()));
            }
            ++checked;
        }
        QVERIFY(checked > 30);
    }

    void rootsFollowSelectionThenEnvironment() {
        // Native absolute paths, so this holds on Windows too.
        QTemporaryDir tmp;
        const QString home = tmp.path() + "/home";
        const QString data = tmp.path() + "/data";
        QCOMPARE(codex::primaryCodexHome(home, "", ""), QDir::cleanPath(home + "/.codex"));
        QCOMPARE(codex::primaryCodexHome(home, " " + data + " ", ""), QDir::cleanPath(data));
        QCOMPARE(codex::primaryCodexHome(home, data, "~/picked"), QDir::cleanPath(home + "/picked"));
        QCOMPARE(codex::primaryCodexHome(home, data, "  "), QDir::cleanPath(data));
        QCOMPARE(codex::activityRoots(home, "", "").first().path, QDir::cleanPath(home + "/.codex/sessions"));
        QCOMPARE(codex::rootsForDirectory(home, data).size(), 1);
#ifdef Q_OS_WIN
        QCOMPARE(codex::primaryCodexHome(home, "", "C:\\Codex Data"), QString("C:/Codex Data"));
        QCOMPARE(codex::primaryCodexHome(home, "", "~\\.codex-alt"), QDir::cleanPath(home + "/.codex-alt"));
        QCOMPARE(codex::primaryCodexHome(home, "", "\\\\wsl.localhost\\Ubuntu\\home\\u\\.codex"),
                 QString("//wsl.localhost/Ubuntu/home/u/.codex"));
#endif
    }

    // A user-picked directory (and app start) replays recent history: a pending permission is
    // reported, while work that its session already completed is not.
    void monitorReplaysRecentHistoryWhenAsked() {
        QTemporaryDir dir;
        const qint64 now = QDateTime::currentMSecsSinceEpoch();
        // Session a runs in the terminal; b in the desktop app. (Two desktop sessions share one
        // display source, where b's later completion would also hide a's request, as on macOS.)
        append(dir.path() + "/rollout-2026-03-01T10-00-00-0199a1b2-0000-7000-8000-00000000000a.jsonl",
               QByteArray(R"({"type":"session_meta","payload":{"id":"0199a1b2-0000-7000-8000-00000000000a","source":"exec"}})") + '\n'
                   + line(now - 50000, "event_msg", R"({"type":"task_started"})")
                   + line(now - 20000, "response_item",
                          R"({"type":"function_call","name":"shell","arguments":{"sandbox_permissions":"require_escalated"}})"));
        append(dir.path() + "/rollout-2026-03-01T10-00-00-0199a1b2-0000-7000-8000-00000000000b.jsonl",
               line(now - 40000, "event_msg", R"({"type":"task_started"})")
                   + line(now - 30000, "response_item", R"({"type":"function_call","name":"apply_patch"})")
                   + line(now - 5000, "event_msg", R"({"type":"task_complete"})"));
        codex::ActivityMonitor::Options options;
        options.replaysInitialHistory = true;
        codex::ActivityMonitor monitor({{dir.path(), QString()}}, options);
        const codex::PollResult result = monitor.poll(now);

        QStringList seen;
        for (const codex::Activity &a : result.activities) seen << a.sessionID.right(1) + ':' + a.signal;
        QCOMPARE(seen, (QStringList{"a:thinking", "a:permission_request", "b:done"}));

        SignalStore store;
        for (const codex::Activity &a : result.activities)
            store.applySessionSignal(a.signal, a.sessionID, a.agent, a.event, *a.timestampMs, now);
        QCOMPARE(display::displaySnapshot(store.readSnapshot(now), now).aggregate, QString("permission"));
        QCOMPARE(monitor.poll(now).activities.size(), 0); // replayed once only
    }

    void monitorPrimesThenTailsAppends() {
        QTemporaryDir dir;
        const QString day = dir.path() + "/2026/03/01";
        QVERIFY(QDir().mkpath(day));
        const QString path = day + '/' + kRolloutName;
        const qint64 now = QDateTime::currentMSecsSinceEpoch();
        append(path, R"({"type":"session_meta","payload":{"id":")" + kRolloutID.toUtf8()
                         + R"(","source":"vscode","originator":"codex_vscode"}})" + '\n');
        append(path, line(now - 5000, "event_msg", R"({"type":"task_started"})"));

        auto monitor = monitorFor(dir.path());
        codex::PollResult first = monitor.poll(now);
        QCOMPARE(first.activities.size(), 0); // existing history is not replayed
        QCOMPARE(first.connection.recentFiles, 1);
        QCOMPARE(first.connection.existingRoots, 1);

        append(path, line(now - 1000, "response_item", R"({"type":"function_call","name":"shell","arguments":"{}"})"));
        append(path, R"({"timestamp":")" + iso(now).toUtf8() + R"(","type":"response_item","payload":{"type":"reas)");
        codex::PollResult second = monitor.poll(now);
        QCOMPARE(second.activities.size(), 1); // the partial line waits for its newline
        QCOMPARE(second.activities[0].event, QString("DesktopToolCall:shell"));
        QCOMPARE(second.activities[0].agent, QString("codex-vscode"));
        QCOMPARE(second.activities[0].sessionID, "codex-vscode:" + kRolloutID);

        append(path, R"(oning"}})" "\n");
        codex::PollResult third = monitor.poll(now);
        QCOMPARE(third.activities.size(), 1);
        QCOMPARE(third.activities[0].signal, QString("thinking"));
        QCOMPARE(monitor.poll(now).activities.size(), 0);
    }

    void monitorReadsNewFilesAndRewrites() {
        QTemporaryDir dir;
        const qint64 now = QDateTime::currentMSecsSinceEpoch();
        auto monitor = monitorFor(dir.path());
        QCOMPARE(monitor.poll(now).activities.size(), 0);

        // A file that appears after priming is read from its start (within the lookback).
        const QString path = dir.path() + '/' + kRolloutName;
        append(path, line(now - 3000, "event_msg", R"({"type":"task_started"})"));
        codex::PollResult created = monitor.poll(now);
        QCOMPARE(created.activities.size(), 1);
        QCOMPARE(created.activities[0].sessionID, "codex-desktop:" + kRolloutID); // from the file name

        // Rewritten in place (shorter): state is reset and the tail is read again.
        QFile f(path);
        QVERIFY(f.open(QIODevice::WriteOnly | QIODevice::Truncate));
        f.write(line(now - 1000, "event_msg", R"({"type":"agent_message","phase":"x"})"));
        f.close();
        codex::PollResult rewritten = monitor.poll(now);
        QCOMPARE(rewritten.activities.size(), 1);
        QCOMPARE(rewritten.activities[0].event, QString("DesktopMessage"));
    }

    void monitorSkipsStaleFilesAndCompletionReplays() {
        QTemporaryDir dir;
        const qint64 now = QDateTime::currentMSecsSinceEpoch();
        auto monitor = monitorFor(dir.path());
        monitor.poll(now);

        const QString old = dir.path() + "/rollout-old.jsonl";
        append(old, line(now - 40 * 60 * 1000, "event_msg", R"({"type":"task_started"})"));
        QFile oldFile(old);
        QVERIFY(oldFile.open(QIODevice::ReadWrite));
        QVERIFY(oldFile.setFileTime(QDateTime::fromMSecsSinceEpoch(now - 40 * 60 * 1000), QFileDevice::FileModificationTime));
        oldFile.close();
        QCOMPARE(monitor.poll(now).activities.size(), 0); // older than the 30 min lookback

        const QString path = dir.path() + '/' + kRolloutName;
        append(path, line(now - 4000, "event_msg", R"({"type":"task_complete"})")
                         + line(now - 3000, "event_msg", R"({"type":"agent_message","phase":"x"})")
                         + line(now - 60000, "event_msg", R"({"type":"task_complete"})"));
        codex::PollResult result = monitor.poll(now);
        // The message after the completion is a replay; the 60 s old "done" is past 15 s.
        QCOMPARE(result.activities.size(), 1);
        QCOMPARE(result.activities[0].signal, QString("done"));

        append(path, line(now - 1000, "event_msg", R"({"type":"task_started"})"));
        QCOMPARE(monitor.poll(now).activities.size(), 1); // a new turn is accepted
    }

    // A killed turn must not keep the lamp green: active sessions leave the display after
    // 5 minutes (45 s for passive events) even though the store keeps them for 30 minutes.
    void displayDropsAbandonedWork() {
        const qint64 t0 = 1'800'000'000'000;
        SignalStore store;
        store.applySessionSignal("working", "codex-cli:a", "codex-cli", "DesktopToolCall:shell", t0, t0);
        QCOMPARE(display::displaySnapshot(store.readSnapshot(t0), t0).aggregate, QString("working"));
        const qint64 later = t0 + 6 * 60 * 1000;
        QCOMPARE(store.readSnapshot(later).aggregate, QString("working"));
        QCOMPARE(display::displaySnapshot(store.readSnapshot(later), later).aggregate, QString("idle"));

        SignalStore passive;
        passive.applySessionSignal("working", "codex-desktop:b", "codex-desktop", "DesktopMessage", t0, t0);
        QCOMPARE(display::displaySnapshot(passive.readSnapshot(t0 + 40000), t0 + 40000).aggregate, QString("working"));
        QCOMPARE(display::displaySnapshot(passive.readSnapshot(t0 + 50000), t0 + 50000).aggregate, QString("idle"));
    }

    void displayShowsDoneBrieflyAndKeepsAlerts() {
        const qint64 t0 = 1'800'000'000'000;
        SignalStore store;
        store.applySessionSignal("done", "codex-cli:a", "codex-cli", "DesktopTaskComplete", t0, t0);
        QCOMPARE(display::displaySnapshot(store.readSnapshot(t0 + 20000), t0 + 20000).aggregate, QString("done"));
        QCOMPARE(display::displaySnapshot(store.readSnapshot(t0 + 40000), t0 + 40000).aggregate, QString("idle"));

        SignalStore alert;
        alert.applySessionSignal("permission_request", "codex-cli:a", "codex-cli", "DesktopToolCall:shell", t0, t0);
        const qint64 hour = t0 + 20 * 60 * 1000;
        QCOMPARE(display::displaySnapshot(alert.readSnapshot(hour), hour).aggregate, QString("permission"));
        // Later work from the same source resolves the request.
        alert.applySessionSignal("working", "codex-cli:other", "codex-cli", "DesktopToolCall:shell", hour, hour);
        QCOMPARE(display::displaySnapshot(alert.readSnapshot(hour), hour).aggregate, QString("working"));
    }

    void claudeAdapterMatchesSwiftGolden() {
        QFile file(QStringLiteral(CLAUDE_PAYLOADS_PATH));
        QVERIFY(file.open(QIODevice::ReadOnly));
        QList<QJsonObject> fixtures;
        for (const QByteArray &line : file.readAll().split('\n')) {
            if (!line.isEmpty()) fixtures.append(QJsonDocument::fromJson(line).object());
        }
        int checked = 0;
        for (const QJsonObject &row : goldenRows("claude")) {
            const QJsonObject fixture = fixtures.at(row.value("line").toInt());
            hooks::Environment env;
            const QJsonObject envObject = fixture.value("env").toObject();
            for (auto it = envObject.constBegin(); it != envObject.constEnd(); ++it) env.insert(it.key(), it.value().toString());
            const QJsonObject payload = fixture.value("payload").toObject();
            const std::optional<QString> event = fixture.value("event").isString()
                ? std::optional<QString>(fixture.value("event").toString())
                : hooks::claude::eventName(payload);
            const QByteArray where = QJsonDocument(fixture).toJson(QJsonDocument::Compact);
            QVERIFY2(hooks::claude::chooseSignal(event, payload) == row.value("signal").toString(), where.constData());
            QVERIFY2(hooks::claude::sessionKey(payload, env) == row.value("sessionID").toString(), where.constData());
            QVERIFY2(hooks::claude::agentName(env) == row.value("agent").toString(), where.constData());
            QCOMPARE(orNull(hooks::claude::displayEventName(event, payload)), row.value("event"));
            ++checked;
        }
        QVERIFY(checked >= 40);
    }

    void stateFileReadsSwiftDocumentAndRoundTrips() {
        const QJsonObject swift = readJson(QStringLiteral(SWIFT_STATUS_PATH));
        QVERIFY(!swift.isEmpty());
        const qint64 written = QDateTime::fromString(swift.value("updated_at").toString(), Qt::ISODate).toMSecsSinceEpoch();
        SignalStore store;
        store.loadJson(swift, written);
        const SignalSnapshot snapshot = store.readSnapshot(written);
        QCOMPARE(snapshot.aggregate, QString("thinking"));
        QCOMPARE(snapshot.sessions.size(), 1);
        QCOMPARE(snapshot.sessions[0].sessionID, QString("codex-desktop:s1"));
        QCOMPARE(snapshot.recentEvents.size(), swift.value("events").toArray().size());

        SignalStore copy;
        copy.loadJson(store.toJson(), written);
        QCOMPARE(copy.toJson(), store.toJson());

        // A document that does not decode is treated as stale, like SignalStateStore.readDocument.
        SignalStore broken;
        broken.loadJson(QJsonObject{{"sessions", QJsonObject{{"x", QJsonObject{{"signal", "Working"}}}}}}, written);
        QCOMPARE(broken.readSnapshot(written).aggregate, QString("stale"));
    }

    void stateFileSharesUpdatesUnderTheLock() {
        QTemporaryDir dir;
        const QString path = dir.path() + "/state/status.json";
        const qint64 now = QDateTime::currentMSecsSinceEpoch();
        SignalStateFile app(path), hook(path);
        QVERIFY(hook.update([&](SignalStore &s) { s.applySessionSignal("working", "c1", "claude-code", "PreToolUse:Bash", now, now); },
                            now, 500));
        const auto seen = app.readSnapshot(now, 500);
        QVERIFY(seen.has_value());
        QCOMPARE(seen->aggregate, QString("working"));
        QCOMPARE(readJson(path).value("sessions").toObject().value("c1").toObject().value("last_event").toString(),
                 QString("PreToolUse:Bash"));

        // Busy lock: the event is dropped and the file is left alone.
        const QByteArray before = [&] {
            QFile f(path);
            return f.open(QIODevice::ReadOnly) ? f.readAll() : QByteArray();
        }();
        QVERIFY(!before.isEmpty());
        QLockFile held(path + ".lock");
        QVERIFY(held.tryLock(0));
        QVERIFY(!hook.update([&](SignalStore &s) { s.applySessionSignal("done", "c1", "claude-code", "Stop", now, now); },
                             now, 50));
        held.unlock();
        QFile after(path);
        QVERIFY(after.open(QIODevice::ReadOnly));
        QCOMPARE(after.readAll(), before);

        // Corrupt content becomes stale (and is then replaced), as on macOS.
        writeText(path, "{not json");
        const auto stale = app.readSnapshot(now, 500);
        QVERIFY(stale.has_value());
        QCOMPARE(stale->aggregate, QString("stale"));
    }

    void presenceFindsAgentAppsByExecutablePath() {
        using asb::presence::ProcessInfo;
        const auto agents = [](const QList<ProcessInfo> &processes) {
            QStringList out;
            for (const asb::SessionStatus &s : asb::presence::detect(processes, 1000)) out.append(s.agent);
            return out;
        };
        const QString codexApp = R"(C:\Program Files\WindowsApps\OpenAI.Codex_26.1117.4957.0_x64__2p2nqsd0c76g0\app\)";
        const QString claudeApp = R"(C:\Program Files\WindowsApps\Claude_6.28899.6.0_x64__pzs8sxrjxfjjc\app\claude.exe)";
        // Desktop apps count only with a visible window.
        QCOMPARE(agents({{codexApp + "ChatGPT.exe", true}}), QStringList{"codex-desktop"});
        QCOMPARE(agents({{codexApp + "ChatGPT.exe", false}}), QStringList());
        QCOMPARE(agents({{claudeApp, true}}), QStringList{"claude-desktop"});
        QCOMPARE(agents({{claudeApp, false}}), QStringList());
        QCOMPARE(agents({{R"(C:\Users\u\AppData\Local\AnthropicClaude\app-1.2.3\claude.exe)", true}}), QStringList{"claude-desktop"});
        // The desktop apps' own helpers are not a CLI; the bundled Claude Code is not the desktop app.
        QCOMPARE(agents({{codexApp + R"(resources\codex.exe)", false}}), QStringList());
        QCOMPARE(agents({{R"(C:\Users\u\AppData\Local\Claude-Data\claude_x\claude-code\2.1.330\abc\claude.exe)", true}}), QStringList());
        // The ChatGPT desktop app is not Codex.
        QCOMPARE(agents({{R"(C:\Program Files\WindowsApps\OpenAI.ChatGPT-Desktop_1.0_x64__x\app\ChatGPT.exe)", true}}), QStringList());
        // CLI, VS Code and JetBrains binaries.
        QCOMPARE(agents({{R"(C:\Users\u\AppData\Roaming\npm\node_modules\@openai\codex\vendor\x86_64-pc-windows-msvc\codex\codex.exe)", false}}),
                 QStringList{"codex-cli"});
        QCOMPARE(agents({{R"(C:\Users\u\.vscode\extensions\openai.chatgpt-26.5-win32-x64\bin\windows-x86_64\codex.exe)", false}}),
                 QStringList{"codex-vscode"});
        QCOMPARE(agents({{R"(C:\Users\u\AppData\Local\JetBrains\IntelliJIdea2026.1\aia\codex\codex.exe)", false}}),
                 QStringList{"codex-idea"});

        // Merged into the display: an open app shows until a live session of that source does.
        asb::SignalSnapshot snapshot;
        const qint64 now = QDateTime::currentMSecsSinceEpoch();
        const QList<asb::SessionStatus> presence =
            asb::presence::detect({{codexApp + "ChatGPT.exe", true}, {claudeApp, true}}, now);
        auto display = asb::display::displaySnapshot(snapshot, now, presence);
        QCOMPARE(asb::display::visibleDesktopPresenceSessions(display.sessions).size(), 2);
        QCOMPARE(asb::displayState(display.aggregate), asb::DisplayState::Ready); // open apps are idle
        asb::SessionStatus working;
        working.sessionID = "claude-session";
        working.agent = "claude-desktop";
        working.signal = "working";
        working.updatedAt = now;
        working.lastEvent = "PreToolUse:Bash";
        snapshot.sessions = {working};
        display = asb::display::displaySnapshot(snapshot, now, presence);
        const auto open = asb::display::visibleDesktopPresenceSessions(display.sessions);
        QCOMPARE(open.size(), 1); // Claude's presence gives way to its live session
        QCOMPARE(open.first().agent, QStringLiteral("codex-desktop"));
    }

    void lightFollowsAndBorrowsAgentsLikeMacOS() {
        using asb::SessionStatus;
        const auto session = [](const QString &agent, const QString &id, const QString &signal, qint64 at) {
            SessionStatus s;
            s.agent = agent;
            s.sessionID = id;
            s.signal = signal;
            s.updatedAt = at;
            s.lastEvent = "PreToolUse";
            return s;
        };
        const auto snapshot = [](const QList<SessionStatus> &sessions, const QString &stored = "idle") {
            asb::display::DisplaySnapshot d;
            d.sessions = sessions;
            d.storedAggregate = stored;
            return d;
        };
        const auto state = [](const asb::light::Selection &s) { return asb::displayState(s.aggregate); };
        const SessionStatus codexWorking = session("codex-cli", "codex-cli:1", "working", 100);
        const SessionStatus claudeWorking = session("claude-code", "claude-code:2", "working", 200);
        const SessionStatus claudePermission = session("claude-code", "claude-code:2", "permission", 50);

        QVERIFY(asb::light::matches("codex-cli", codexWorking));
        QVERIFY(asb::light::matches("claude-code", session("claude-desktop", "x", "working", 1)));
        QVERIFY(!asb::light::matches("codex-cli", claudeWorking));

        // Automatic: the most urgent agent wins, whatever its age.
        asb::light::Selector follow;
        auto picked = follow.select(snapshot({codexWorking, claudePermission}), true, {}, true);
        QCOMPARE(picked.scopes, QStringList{"claude-code"});
        QCOMPARE(state(picked), asb::DisplayState::Permission);
        // displayName(for: scopes) names the whole Claude group "Claude" (a borrowed single scope,
        // below, uses the scope's own name).
        QCOMPARE(asb::light::followingText(picked, true, true), QStringLiteral("自动跟随 · Claude"));

        // Sticky: a newer agent that is also just working does not take the light over...
        asb::light::Selector sticky;
        QCOMPARE(sticky.select(snapshot({codexWorking}), true, {}, true).scopes, QStringList{"codex-cli"});
        QCOMPARE(sticky.select(snapshot({codexWorking, claudeWorking}), true, {}, true).scopes, QStringList{"codex-cli"});
        // ...but one waiting for permission does at once.
        QCOMPARE(sticky.select(snapshot({codexWorking, claudePermission}), true, {}, true).scopes, QStringList{"claude-code"});

        // Manual: an idle selection borrows the busy other agent, unless that is switched off.
        asb::light::Selector manual;
        auto borrowed = manual.select(snapshot({claudeWorking}), false, {"codex-cli"}, true);
        QCOMPARE(borrowed.borrowed, std::optional<QString>("claude-code"));
        QCOMPARE(state(borrowed), asb::DisplayState::Active);
        QCOMPARE(asb::light::followingText(borrowed, false, false), QStringLiteral("Showing Claude Desktop"));
        auto strict = asb::light::Selector().select(snapshot({claudeWorking}), false, {"codex-cli"}, false);
        QVERIFY(!strict.borrowed);
        QCOMPARE(state(strict), asb::DisplayState::Ready);
        QVERIFY(!asb::light::unavailableHint(strict, {"codex-cli"}, false, {claudeWorking}, true).isEmpty());
        // A busy selection keeps the light.
        auto own = asb::light::Selector().select(snapshot({codexWorking, claudePermission}), false, {"codex-cli"}, true);
        QVERIFY(!own.borrowed);
        QCOMPARE(state(own), asb::DisplayState::Active);

        // No sessions: automatic keeps a stored blocked state; a manual selection shows idle.
        QCOMPARE(state(asb::light::Selector().select(snapshot({}, "blocked"), true, {}, true)), asb::DisplayState::Blocked);
        QCOMPARE(state(asb::light::Selector().select(snapshot({}, "blocked"), false, {"codex-cli"}, false)), asb::DisplayState::Ready);

        // The dropdown values map to macOS scope sets.
        QCOMPARE(asb::light::scopesForPreference("following"), QStringList());
        QCOMPARE(asb::light::scopesForPreference("claude"), QStringList{"claude-code"});
        QCOMPARE(asb::light::scopesForPreference("codex").size(), 5);
        QCOMPARE(asb::light::displayName(asb::light::scopesForPreference("codex"), true), QStringLiteral("Codex"));
    }

    void soundVolumeScalesPcmSamplesOnly() {
        // A minimal 16-bit mono PCM WAV: RIFF header, fmt chunk, data chunk of four samples.
        const auto wav = [](quint16 format, quint16 bits, const QList<qint16> &samples) {
            QByteArray data;
            for (qint16 s : samples) data.append(reinterpret_cast<const char *>(&s), 2);
            QByteArray fmt(16, '\0');
            qToLittleEndian<quint16>(format, fmt.data());
            qToLittleEndian<quint16>(1, fmt.data() + 2);
            qToLittleEndian<quint32>(22050, fmt.data() + 4);
            qToLittleEndian<quint16>(bits, fmt.data() + 14);
            QByteArray out = "RIFF" + QByteArray(4, '\0') + "WAVE";
            out += "fmt " + QByteArray(4, '\0') + fmt;
            qToLittleEndian<quint32>(16, out.data() + 16);
            const qsizetype dataHeader = out.size();
            out += "data" + QByteArray(4, '\0') + data;
            qToLittleEndian<quint32>(quint32(data.size()), out.data() + dataHeader + 4);
            return out;
        };
        const auto samples = [](const QByteArray &file) {
            QList<qint16> out;
            for (qsizetype i = file.size() - 8; i < file.size(); i += 2) out.append(qFromLittleEndian<qint16>(file.constData() + i));
            return out;
        };
        const QByteArray original = wav(1, 16, {1000, -1000, 32767, -32768});
        const QByteArray half = asb::sound::scaledWav(original, 0.5);
        QCOMPARE(half.size(), original.size());
        QCOMPARE(half.left(original.size() - 8), original.left(original.size() - 8)); // headers untouched
        QCOMPARE(samples(half), (QList<qint16>{500, -500, 16384, -16384}));
        QCOMPARE(samples(asb::sound::scaledWav(original, 2.0)), (QList<qint16>{2000, -2000, 32767, -32768})); // clamped
        const QByteArray eightBit = wav(1, 8, {1000, -1000, 32767, -32768});
        QCOMPARE(asb::sound::scaledWav(eightBit, 0.5), eightBit);
        QCOMPARE(asb::sound::scaledWav(QByteArray("not a wav"), 0.5), QByteArray("not a wav"));
        QCOMPARE(asb::sound::volume("soft"), 0.28);
        QCOMPARE(asb::sound::volume("standard"), 0.55);
        QCOMPARE(asb::sound::volume("loud"), 0.88);
        QCOMPARE(asb::sound::volume("unknown"), 0.55);
    }

    void installerAddsKeepsAndRemovesOnlyItsHooks() {
        QTemporaryDir dir;
        const QString root = dir.path() + "/claude";
        const QString exe = dir.path() + "/Agent Signal Bar/agent-signal.exe";
        QVERIFY(QDir().mkpath(root));
        QVERIFY(QDir().mkpath(QFileInfo(exe).absolutePath()));
        writeText(exe, "fake");
        writeText(root + "/settings.json", R"({"model":"opus","hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"my-linter"}]}]}})");

        hooks::ClaudeHookInstaller installer(root, exe);
        QVERIFY(!installer.install().ok); // fake exe lives in a temporary folder
        installer.allowTemporaryLocationForTests();

        hooks::HookReport check = installer.check();
        QVERIFY(check.ok);
        QVERIFY(!check.configured);
        QCOMPARE(check.missing.size(), hooks::claude::installedEvents().size());

        hooks::HookReport report = installer.install();
        QVERIFY2(report.ok, qPrintable(report.error));
        QVERIFY(report.changed);
        QVERIFY(!report.backup.isEmpty());
        QJsonObject settings = readJson(root + "/settings.json");
        QCOMPARE(settings.value("model").toString(), QString("opus"));
        QCOMPARE(ownedCommands(settings), hooks::claude::installedEvents().size());
        const QJsonArray preToolUse = settings.value("hooks").toObject().value("PreToolUse").toArray();
        QCOMPARE(preToolUse.size(), 2); // the user's own Bash hook stays first
        QCOMPARE(preToolUse[0].toObject().value("hooks").toArray()[0].toObject().value("command").toString(), QString("my-linter"));
        const QJsonObject entry = preToolUse[1].toObject().value("hooks").toArray()[0].toObject();
        QCOMPARE(entry.value("args").toArray(), (QJsonArray{"claude-hook"}));
        QCOMPARE(entry.value("command").toString(), hooks::ClaudeHookInstaller::commandPath(exe));
        // A short (8.3) folder keeps the long file name, which marks the entry as ours.
        QVERIFY(entry.value("command").toString().endsWith("/agent-signal.exe"));
        QCOMPARE(settings.value("hooks").toObject().value("PermissionRequest").toArray()[0].toObject()
                     .value("hooks").toArray()[0].toObject().value("timeout").toInt(), 10);

        QVERIFY(installer.check().configured);
        QVERIFY(installer.check().missing.isEmpty());
        const hooks::HookReport again = installer.install();
        QVERIFY(again.ok && !again.changed); // idempotent

        // An entry for an old install location needs repair and is replaced.
        hooks::ClaudeHookInstaller moved(root, dir.path() + "/elsewhere/agent-signal.exe");
        moved.allowTemporaryLocationForTests();
        const hooks::HookReport stale = moved.check();
        QVERIFY(!stale.configured);
        QCOMPARE(stale.stale.size(), hooks::claude::installedEvents().size());

        const hooks::HookReport removed = installer.uninstall();
        QVERIFY(removed.ok && removed.changed);
        settings = readJson(root + "/settings.json");
        QCOMPARE(ownedCommands(settings), 0);
        QCOMPARE(settings.value("hooks").toObject().keys(), QStringList{"PreToolUse"});

        // Repeated changes keep at most five backups.
        for (int i = 0; i < 4; ++i) {
            installer.install();
            installer.uninstall();
        }
        QStringList backups = QDir(root).entryList({"settings.json.bak-*"}, QDir::Files | QDir::Hidden);
        QVERIFY(backups.size() <= hooks::ClaudeHookInstaller::kRetainedBackups);
    }

    // Cases from AgentSignalLightCoreTests (testCodexHookMapping..., testHookAdapters...).
    void codexAndGenericAdaptersMatchSwiftTests() {
        const auto obj = [](const char *json) { return QJsonDocument::fromJson(json).object(); };
        QCOMPARE(hooks::codex::chooseSignal(QString("PreToolUse"), {}), QString("working"));
        QCOMPARE(hooks::codex::chooseSignal(QString("Stop"), {}), QString("done"));
        QCOMPARE(hooks::codex::chooseSignal(QString(" pre_tool_use "), {}), QString("working"));
        QCOMPARE(hooks::codex::chooseSignal(QString("permission-request"), {}), QString("permission_request"));
        QCOMPARE(hooks::codex::chooseSignal(std::nullopt, obj(R"({"hookEventName":"post tool use"})")), QString("tool_done"));
        QCOMPARE(hooks::codex::chooseSignal(QString("PreToolUse"), obj(R"({"signal":"attention"})")), QString("attention"));
        QCOMPARE(hooks::codex::chooseSignal(QString("PostToolUse"), obj(R"({"exitStatus":1})")), QString("tool_done"));
        QCOMPARE(displayState(hooks::codex::chooseSignal(std::nullopt, obj(R"({"Status":"failed"})"))), DisplayState::Blocked);
        QCOMPARE(hooks::codex::chooseSignal(QString("PostToolUse"), obj(R"({"tool_response":{"error":"exit 2"},"status":"failed"})")),
                 QString("tool_done"));

        const hooks::Environment env{{"CODEX_SESSION_ID", "env-session"}};
        QCOMPARE(hooks::codex::sessionKey(obj(R"({"tool":{"context":{"threadId":"nested-thread"}}})"), env), QString("nested-thread"));
        QCOMPARE(hooks::codex::sessionKey(obj(R"({"sessionId":"camel-session"})"), env), QString("camel-session"));
        QCOMPARE(hooks::codex::sessionKey(obj(R"({"session_id":12345})"), {}), QString("12345"));

        // Tool arguments never count as metadata; trusted nested metadata does.
        const QJsonObject lookalike = obj(R"({"toolInput":{"sessionId":"user-supplied-session","source":"xcode","error":"example"}})");
        QCOMPARE(hooks::codex::sessionKey(lookalike, {{"CODEX_SESSION_ID", "real-session"}}), QString("real-session"));
        QCOMPARE(hooks::codex::agentName(lookalike, {{"TERM_PROGRAM", "Apple_Terminal"}}), QString("codex-cli"));
        QCOMPARE(hooks::codex::chooseSignal(QString("PreToolUse"), lookalike), QString("working"));
        const QJsonObject trusted = obj(R"({"payload":{"metadata":{"sessionId":"trusted-session","source":"VS Code"},"result":{"error":true}}})");
        QCOMPARE(hooks::codex::sessionKey(trusted, {}), QString("trusted-session"));
        QCOMPARE(hooks::codex::agentName(trusted, {}), QString("codex-vscode"));
        QCOMPARE(hooks::codex::chooseSignal(QString("Stop"), trusted), QString("blocked"));
        QCOMPARE(hooks::codex::agentName({}, {{"TERMINAL_EMULATOR", "JetBrains-JediTerm"}}), QString("codex-jetbrains"));

        QCOMPARE(hooks::codex::sourceScopedSessionKey("abc", "codex-vscode"), QString("codex-vscode:abc"));
        QCOMPARE(hooks::codex::sourceScopedSessionKey("codex-vscode:abc", "codex-vscode"), QString("codex-vscode:abc"));
        QCOMPARE(hooks::codex::sourceScopedSessionKey("abc", "codex-desktop"), QString("abc"));
        QCOMPARE(hooks::codex::installedEvents(), (QStringList{"SessionStart", "UserPromptSubmit", "PreToolUse",
                                                               "PostToolUse", "PermissionRequest", "Stop"}));

        QCOMPARE(hooks::generic::chooseSignal(QString("ToolFailed"), obj(R"({"error":"boom"})")), QString("tool_done"));
        QCOMPARE(hooks::generic::chooseSignal(QString("PreToolUse"), obj(R"({"signal":"permission"})")), QString("permission"));
        QCOMPARE(displayState(hooks::generic::chooseSignal(QString("RunFailed"), {})), DisplayState::Blocked);
        QCOMPARE(hooks::generic::sessionKey(obj(R"({"run_id":42})"), {}, QString("local")), QString("42"));
        const QJsonObject script = obj(R"({"event":"AgentStarted","agent":"local-script","session_id":"local-script-main"})");
        QCOMPARE(hooks::generic::eventName(script).value_or(QString()), QString("AgentStarted"));
        QCOMPARE(hooks::generic::agentName(script, {}), QString("local-script"));
        QCOMPARE(hooks::generic::sessionKey(script, {}), QString("local-script-main"));
    }

    // testManualSignalsParticipateInSessionAggregation, testManualIdleStillClearsSessions.
    void manualSignalJoinsSessionsAndIdleClears() {
        const qint64 t0 = 1'800'000'000'000;
        SignalStore store;
        store.applySessionSignal("permission", "codex-main", "codex", "PermissionRequest", t0, t0);
        SignalSnapshot snapshot = store.setManualSignal("working", t0 + 1000);
        QCOMPARE(snapshot.aggregate, QString("permission"));
        QCOMPARE(snapshot.sessions.size(), 2);
        QCOMPARE(snapshot.sessions[0].sessionID, QString("codex-main"));
        QCOMPARE(snapshot.sessions[1].sessionID, QString("manual"));
        QCOMPARE(snapshot.sessions[1].signal, QString("working"));
        QCOMPARE(snapshot.sessions[1].agent, QString("manual"));
        QCOMPARE(snapshot.sessions[1].lastEvent, QString("ManualSet"));

        snapshot = store.setManualSignal("idle", t0 + 2000);
        QCOMPARE(snapshot.aggregate, QString("idle"));
        QVERIFY(snapshot.sessions.isEmpty());
        QCOMPARE(snapshot.recentEvents.first().event, QString("ManualSet"));

        snapshot = store.setManualSignal("pause", t0 + 3000);
        QCOMPARE(displayState(snapshot.aggregate), DisplayState::Paused);
        QVERIFY(snapshot.sessions.isEmpty());
    }

    void installerWritesCodexHooksJson() {
        QTemporaryDir dir;
        const QString home = dir.path() + "/codex";
        const QString exe = dir.path() + "/Agent Signal Bar/agent-signal.exe";
        QVERIFY(QDir().mkpath(home));
        QVERIFY(QDir().mkpath(QFileInfo(exe).absolutePath()));
        writeText(exe, "fake");
        writeText(home + "/hooks.json", R"({"hooks":{"Stop":[{"matcher":"*","hooks":[{"type":"command","command":"notify-me"}]}]}})");
        hooks::ClaudeHookInstaller installer(home, exe, hooks::ClaudeHookInstaller::Target::Codex);
        installer.allowTemporaryLocationForTests();

        const hooks::HookReport preview = installer.preview(false);
        QVERIFY(preview.ok && preview.wouldChange && !preview.changed);
        QCOMPARE(preview.added, hooks::codex::installedEvents());
        QCOMPARE(ownedCommands(readJson(home + "/hooks.json")), 0); // a preview writes nothing

        const hooks::HookReport report = installer.install();
        QVERIFY2(report.ok, qPrintable(report.error));
        QVERIFY(report.changed);
        QVERIFY(report.settingsPath.endsWith("hooks.json"));
        const QJsonObject json = readJson(home + "/hooks.json");
        QCOMPARE(ownedCommands(json), hooks::codex::installedEvents().size());
        const QJsonArray stop = json.value("hooks").toObject().value("Stop").toArray();
        QCOMPARE(stop.size(), 2); // the user's own hook stays
        const QJsonObject block = stop[1].toObject();
        QCOMPARE(block.value("matcher").toString(), QString("*"));
        const QJsonObject entry = block.value("hooks").toArray()[0].toObject();
        QVERIFY(!entry.contains("args"));
        QCOMPARE(entry.value("command").toString(), hooks::ClaudeHookInstaller::commandPath(exe) + " codex-hook Stop");
        QCOMPARE(json.value("hooks").toObject().value("PermissionRequest").toArray()[0].toObject()
                     .value("hooks").toArray()[0].toObject().value("timeout").toInt(), 10);
        QVERIFY(installer.check().configured);
        QVERIFY(!installer.preview(false).wouldChange);
        // Each entry is recognised as current, not merely replaced by an identical one.
        QVERIFY(installer.check().missing.isEmpty());
        // The entry for another event is not current for this one.
        writeText(home + "/hooks.json", QString(QJsonDocument(json).toJson()).replace("codex-hook Stop", "codex-hook Other").toUtf8());
        QCOMPARE(installer.check().stale, QStringList{"Stop"});
        QVERIFY(installer.install().ok);

        const hooks::HookReport removal = installer.preview(true);
        QCOMPARE(removal.removed.size(), hooks::codex::installedEvents().size());
        QVERIFY(installer.uninstall().changed);
        QCOMPARE(ownedCommands(readJson(home + "/hooks.json")), 0);
        QCOMPARE(readJson(home + "/hooks.json").value("hooks").toObject().keys(), QStringList{"Stop"});
    }

    // CostUsagePricing / ModelsDevPricing: model names, long-context tiers, historical rates and
    // the models.dev fallback.
    void usagePricingMatchesMacOSRules() {
        QCOMPARE(usage::normalizeCodexModel("openai/gpt-5.2-2025-12-11"), QString("gpt-5.2"));
        QCOMPARE(usage::normalizeCodexModel(" gpt-9-experimental "), QString("gpt-9-experimental"));
        QCOMPARE(usage::normalizeClaudeModel("anthropic.claude-sonnet-4-5-20250929-v1:0"), QString("claude-sonnet-4-5"));
        QCOMPARE(usage::normalizeClaudeModel("us.anthropic.claude-opus-4-1"), QString("claude-opus-4-1"));

        // gpt-5.5: 800 uncached x 5e-6 + 200 cached x 5e-7 + 100 out x 3e-5.
        QVERIFY(qFuzzyCompare(*usage::codexCostUSD("gpt-5.5", 1000, 200, 100), 0.0071));
        // gpt-6-astra above 272K input uses the long-context rates (2e-5 in, 7.5e-5 out).
        QVERIFY(qFuzzyCompare(*usage::codexCostUSD("gpt-6-astra", 300'000, 0, 1000), 6.075));
        QVERIFY(!usage::codexCostUSD("gpt-9", 1000, 0, 1000));

        // claude-sonnet-4-5: 100 in, 5000 read, 800 5-minute + 200 1-hour writes (2x input), 50 out.
        QVERIFY(qFuzzyCompare(*usage::claudeCostUSD("claude-sonnet-4-5", 100, 5000, 1000, 200, 50), 0.00675));
        // opus-4-6 had long-context rates before 2026-03-13.
        const qint64 before = QDateTime(QDate(2026, 3, 1), QTime(12, 0), QTimeZone::UTC).toMSecsSinceEpoch();
        const qint64 after = QDateTime(QDate(2026, 4, 1), QTime(12, 0), QTimeZone::UTC).toMSecsSinceEpoch();
        QVERIFY(qFuzzyCompare(*usage::claudeCostUSD("claude-opus-4-6", 250'000, 0, 0, 0, 0, before), 2.5));
        QVERIFY(qFuzzyCompare(*usage::claudeCostUSD("claude-opus-4-6", 250'000, 0, 0, 0, 0, after), 1.25));
        QVERIFY(!usage::claudeCostUSD("claude-opus-5-5", 1000, 0, 0, 0, 1000));

        const QStringList candidates = usage::modelsDevCandidates("claude-opus-5-5@20261101");
        QVERIFY(candidates.contains("claude-opus-5-5-20261101"));
        QVERIFY(candidates.contains("claude-opus-5-5"));

        const auto catalog = usage::ModelsDevCatalog::fromJson(R"({
            "anthropic": {"id": "anthropic", "models": {"claude-opus-5-5": {"id": "claude-opus-5-5",
                "cost": {"input": 5, "output": 25, "cache_read": 0.5, "cache_write": 6.25}}}},
            "openai": {"id": "openai", "models": {"gpt-9": {"id": "gpt-9", "cost": {"input": 1, "output": 2}},
                "gpt-5.5": {"id": "gpt-5.5", "cost": {"input": 6, "output": 30, "cache_read": 0.6}}}},
            "other": {"id": "other", "models": {"x": {"id": "x"}}}})");
        QVERIFY(catalog.has_value());
        QVERIFY(catalog->isPlausible());
        QVERIFY(qFuzzyCompare(*usage::claudeCostUSD("claude-opus-5-5-20261101", 1000, 0, 0, 0, 1000, {}, &*catalog), 0.03));
        QVERIFY(qFuzzyCompare(*usage::codexCostUSD("gpt-9", 1000, 0, 1000, &*catalog), 0.003));
        // Non-official models prefer the catalog; the bundled 272K tier still applies.
        QVERIFY(qFuzzyCompare(*usage::codexCostUSD("gpt-5.5", 1000, 0, 0, &*catalog), 0.006));
        QVERIFY(qFuzzyCompare(*usage::codexCostUSD("gpt-5.5", 300'000, 0, 0, &*catalog), 300'000 * 1e-5));
        // Official rates win over the catalog for the newest models.
        QVERIFY(qFuzzyCompare(*usage::codexCostUSD("gpt-6-astra", 1000, 0, 0, &*catalog), 0.01));
        QVERIFY(!usage::ModelsDevCatalog::fromJson(R"({"openai": {"models": {}}})")->isPlausible());
    }

    // parseCodexFile + the daily report: growth of cumulative totals per event, per-event prices,
    // copies of one session counted once, forks without their inherited history.
    void codexUsageScanCountsEachTokenOnce() {
        QTemporaryDir dir;
        const QString sessions = dir.path() + "/codex/sessions";
        const QString archived = dir.path() + "/codex/archived_sessions";
        QByteArray a;
        a += codexLine("session_meta", isoAt(19, 8), {{"id", "A"}, {"cwd", "C:\\work\\alpha"}, {"timestamp", isoAt(19, 8)}});
        a += codexLine("turn_context", isoAt(19, 8), {{"model", "gpt-5.5"}});
        a += codexLine("event_msg", isoAt(19, 8), {{"type", "task_started"}, {"turn_id", "t1"}});
        a += tokenCount(isoAt(19, 9), codexUsage(1000, 200, 100), codexUsage(1000, 200, 100));
        a += tokenCount(isoAt(20, 9), codexUsage(3000, 1200, 300), codexUsage(2000, 1000, 200));
        a += tokenCount(isoAt(20, 9, 1), codexUsage(3000, 1200, 300), codexUsage(2000, 1000, 200)); // repeat, no growth
        a += codexLine("turn_context", isoAt(20, 10), {{"model", "gpt-6-astra"}});
        a += tokenCount(isoAt(20, 10), codexUsage(303'000, 1200, 1300), codexUsage(300'000, 0, 1000));
        writeFile(sessions + "/2026/11/19/rollout-a.jsonl", a);
        writeFile(archived + "/rollout-a.jsonl", a); // an archived copy counts once

        // Two copies of B that disagree: left out, as on macOS.
        QByteArray b = codexLine("session_meta", isoAt(20, 8), {{"id", "B"}})
            + codexLine("turn_context", isoAt(20, 8), {{"model", "gpt-5.5"}});
        writeFile(sessions + "/2026/11/20/rollout-b1.jsonl", b + tokenCount(isoAt(20, 9), codexUsage(10, 0, 1), {}));
        writeFile(sessions + "/2026/11/20/rollout-b2.jsonl", b + tokenCount(isoAt(20, 9), codexUsage(20, 0, 2), {}));

        // P is forked into C at 10:00 on the 18th: C's totals include P's 1100 tokens from 09:00.
        QByteArray p = codexLine("session_meta", isoAt(18, 8), {{"id", "P"}})
            + codexLine("turn_context", isoAt(18, 8), {{"model", "gpt-5.5"}})
            + tokenCount(isoAt(18, 9), codexUsage(1000, 0, 100), codexUsage(1000, 0, 100))
            + tokenCount(isoAt(18, 12), codexUsage(2000, 0, 200), codexUsage(1000, 0, 100));
        writeFile(sessions + "/2026/11/18/rollout-p.jsonl", p);
        QByteArray c = codexLine("session_meta", isoAt(18, 10), {{"id", "C"}, {"forked_from_id", "P"}, {"timestamp", isoAt(18, 10)}})
            + codexLine("turn_context", isoAt(18, 10), {{"model", "gpt-5.5"}})
            + tokenCount(isoAt(18, 11), codexUsage(1500, 0, 150), codexUsage(500, 0, 50));
        writeFile(sessions + "/2026/11/18/rollout-c.jsonl", c);
        // A fork whose parent is gone counts its own last_token_usage, capped by total growth.
        QByteArray d = codexLine("session_meta", isoAt(17, 8), {{"id", "D"}, {"forked_from_id", "gone"}, {"timestamp", isoAt(17, 8)}})
            + codexLine("turn_context", isoAt(17, 8), {{"model", "gpt-5.5"}})
            + tokenCount(isoAt(17, 9), codexUsage(5000, 0, 500), codexUsage(400, 0, 40))
            + tokenCount(isoAt(17, 10), codexUsage(5600, 0, 560), codexUsage(600, 0, 60));
        writeFile(sessions + "/2026/11/17/rollout-d.jsonl", d);

        usage::CodexScanner scanner({sessions, archived});
        const qint64 now = QDateTime(QDate(2026, 11, 20), QTime(23, 0)).toMSecsSinceEpoch();
        const usage::Report report = scanner.scan(now, 30, nullptr);
        QCOMPARE(report.excludedSessions, 1);

        const usage::Day *d19 = findDay(report, 19);
        QVERIFY(d19);
        QCOMPARE(d19->totalTokens, 1100);
        QVERIFY(qFuzzyCompare(*d19->cost, 0.0071));
        const usage::Day *d20 = findDay(report, 20);
        QVERIFY(d20);
        QCOMPARE(d20->models.value("gpt-5.5").totalTokens, 2200);
        QCOMPARE(d20->models.value("gpt-5.5").cached, 1000);
        QCOMPARE(d20->models.value("gpt-6-astra").totalTokens, 301'000);
        QCOMPARE(d20->totalTokens, 303'200);
        QVERIFY(qFuzzyCompare(*d20->cost, 0.0115 + 6.075));
        QVERIFY(!d20->partial);

        const usage::Day *d18 = findDay(report, 18);
        QVERIFY(d18);
        QCOMPARE(d18->totalTokens, 2200 + 550); // P's own 2200 + C's 550 after the fork
        const usage::Day *d17 = findDay(report, 17);
        QVERIFY(d17);
        QCOMPARE(d17->totalTokens, 440 + 660);

        QCOMPARE(report.sessions.size(), 4); // A, C, P, D (B is excluded)
        const auto sessionA = std::find_if(report.sessions.cbegin(), report.sessions.cend(),
                                           [](const usage::Session &s) { return s.id == "A"; });
        QVERIFY(sessionA != report.sessions.cend());
        QCOMPARE(sessionA->totalTokens, 304'300);
        QCOMPARE(sessionA->projectPath, QString("C:\\work\\alpha"));
        QCOMPARE(sessionA->models, (QStringList{"gpt-5.5", "gpt-6-astra"}));
        QCOMPARE(report.sessions.first().id, QString("A")); // newest activity first

        // An unpriced model makes the day partial, never zero-cost.
        writeFile(sessions + "/2026/11/20/rollout-e.jsonl",
                  codexLine("session_meta", isoAt(20, 8), {{"id", "E"}})
                      + codexLine("turn_context", isoAt(20, 8), {{"model", "gpt-9"}})
                      + tokenCount(isoAt(20, 9), codexUsage(100, 0, 10), {}));
        const usage::Report again = scanner.scan(now, 30, nullptr);
        QVERIFY(findDay(again, 20)->partial);
        QCOMPARE(findDay(again, 20)->models.value("gpt-9").unpricedTokens, 110);
        QVERIFY(qFuzzyCompare(*findDay(again, 20)->cost, 0.0115 + 6.075));
    }

    // parseClaudeFile + reconciledClaudeRows: the final streaming chunk wins, a message logged by a
    // parent and a subagent counts once, incomplete and unpriced requests mark the day partial.
    void claudeUsageScanReconcilesMessages() {
        QTemporaryDir dir;
        const QString projects = dir.path() + "/claude/projects";
        const auto assistant = [](const QString &ts, const QString &id, const QString &request, const QString &model,
                                  const QJsonObject &usageObject, bool stopNull = false) {
            QJsonObject message{{"id", id}, {"model", model}, {"usage", usageObject}};
            if (stopNull) message.insert("stop_reason", QJsonValue::Null);
            return jsonLine({{"type", "assistant"}, {"timestamp", ts}, {"sessionId", "S1"}, {"requestId", request},
                             {"message", message}});
        };
        const QJsonObject m1Partial{{"input_tokens", 100}, {"cache_creation_input_tokens", 1000},
                                    {"cache_creation", QJsonObject{{"ephemeral_1h_input_tokens", 200}}},
                                    {"cache_read_input_tokens", 5000}, {"output_tokens", 10}};
        QJsonObject m1Final = m1Partial;
        m1Final.insert("output_tokens", 50);
        QByteArray main = jsonLine({{"type", "user"}, {"sessionId", "S1"}, {"cwd", "C:\\work\\beta"}, {"timestamp", isoAt(20, 9)}});
        main += assistant(isoAt(20, 9, 1), "m1", "r1", "claude-sonnet-4-5", m1Partial);
        main += assistant(isoAt(20, 9, 2), "m1", "r1", "claude-sonnet-4-5", m1Final);
        main += assistant(isoAt(20, 9, 3), "m2", "r2", "claude-opus-4-1", {{"input_tokens", 10}, {"output_tokens", 5}});
        main += assistant(isoAt(20, 9, 4), "m3", "r3", "claude-opus-4-1", {{"input_tokens", 7}}, true);
        main += assistant(isoAt(20, 9, 5), "m4", "r4", "claude-unknown-9", {{"input_tokens", 100}, {"output_tokens", 100}});
        writeFile(projects + "/proj/s1.jsonl", main);
        writeFile(projects + "/proj/s1/subagents/agent-x.jsonl",
                  assistant(isoAt(20, 9, 2), "m1", "r1", "claude-sonnet-4-5", m1Final));

        usage::ClaudeScanner scanner({projects});
        const qint64 now = QDateTime(QDate(2026, 11, 20), QTime(23, 0)).toMSecsSinceEpoch();
        const usage::Report report = scanner.scan(now, 30, nullptr);
        const usage::Day *day = findDay(report, 20);
        QVERIFY(day);
        QCOMPARE(day->models.value("claude-sonnet-4-5").totalTokens, 6150); // counted once, final chunk
        QCOMPARE(day->models.value("claude-opus-4-1").totalTokens, 15);
        QCOMPARE(day->models.value("claude-opus-4-1").incomplete, 1);
        QCOMPARE(day->totalTokens, 6150 + 15 + 200);
        QVERIFY(qFuzzyCompare(*day->cost, 0.00675 + 0.000525));
        QVERIFY(!day->models.value("claude-unknown-9").cost);
        QVERIFY(day->partial);
        QCOMPARE(report.sessions.size(), 1);
        QCOMPARE(report.sessions.first().projectPath, QString("C:\\work\\beta"));
        QCOMPARE(report.sessions.first().totalTokens, 6365);

        const QStringList roots = usage::ClaudeScanner::defaultRoots("C:/Users/me", "", "");
        QCOMPARE(roots, (QStringList{"C:/Users/me/.config/claude/projects", "C:/Users/me/.claude/projects"}));
        QCOMPARE(usage::ClaudeScanner::defaultRoots("C:/Users/me", "D:/profile", ""), QStringList{"D:/profile/projects"});
    }

    // AppLanguage.systemPreferredLanguage and AppLocalization.text over the extracted table.
    void languagesResolveAndFallBackToEnglishLikeMacOS() {
        QCOMPARE(i18n::systemLanguage({"zh-Hant-TW"}), QString("zh-Hant"));
        QCOMPARE(i18n::systemLanguage({"zh_HK"}), QString("zh-Hant"));
        QCOMPARE(i18n::systemLanguage({"zh-CN"}), QString("zh-Hans"));
        QCOMPARE(i18n::systemLanguage({"it-IT", "de-DE"}), QString("de"));
        QCOMPARE(i18n::systemLanguage({"it-IT"}), QString("en"));
        QCOMPARE(i18n::resolve("ja", {"en-US"}), QString("ja"));
        QCOMPARE(i18n::resolve("system", {"ko-KR"}), QString("ko"));
        QCOMPARE(i18n::resolve("xx", {"ko-KR"}), QString("en"));

        i18n::loadTable(TRANSLATIONS_PATH);
        i18n::setLanguage("ja");
        QCOMPARE(i18n::text("通用", "General"), QString::fromUtf8("一般"));
        QCOMPARE(i18n::text("没有这条", "Not in the table"), QString("Not in the table")); // English fallback
        i18n::setLanguage("zh-Hant");
        QCOMPARE(i18n::text("空闲", "Idle"), QString::fromUtf8("空閒"));
        QVERIFY(i18n::usesChineseNumbers());
        i18n::setLanguage("de");
        QCOMPARE(i18n::translate("Refresh"), QString("Aktualisieren"));
        QVERIFY(!i18n::usesChineseNumbers());
        QVERIFY(i18n::table("fr").size() > 200);
        QVERIFY(i18n::table("en").isEmpty());
        i18n::setLanguage("zh-Hans");
        QCOMPARE(i18n::text("通用", "General"), QString::fromUtf8("通用"));
        i18n::setLanguage("en"); // the other tests expect English activity text
        QCOMPARE(i18n::text("通用", "General"), QString("General"));
    }

    // CodexUsageResponse / usageStatus and the reset-credit list.
    void codexQuotaResponseParsesLikeMacOS() {
        const auto usage = quota::parseCodexUsage(R"({"plan_type":"pro",
            "rate_limit":{"limit_name":"Codex","primary_window":{"used_percent":24,"reset_at":1800000000,"limit_window_seconds":18000},
                          "secondary_window":{"used_percent":138,"reset_at":1800500000,"limit_window_seconds":604800}},
            "credits":{"balance":"12.5"},
            "spend_control":{"individual_limit":{"limit":100,"remaining_percent":40,"resets_at":1801000000}}})");
        QVERIFY(usage.has_value());
        QCOMPARE(usage->plan, QString("pro"));
        QCOMPARE(usage->limitName, QString("Codex"));
        QCOMPARE(usage->primary->usedPercent, 24.0);
        QCOMPARE(*usage->primary->minutes, 300);
        QCOMPARE(*usage->primary->resetsAtMs, 1'800'000'000'000LL);
        QCOMPARE(usage->secondary->usedPercent, 100.0); // clamped
        QCOMPARE(usage->credits->title, QString("Monthly credit limit"));
        QCOMPARE(*usage->credits->used, 60.0);
        QCOMPARE(*usage->credits->balance, 12.5);
        // A secondary window alone becomes the primary; nothing at all is no quota.
        QCOMPARE(*quota::parseCodexUsage(R"({"rate_limit":{"secondary_window":{"used_percent":5,"reset_at":1,"limit_window_seconds":604800}}})")
                      ->primary->minutes, 10080);
        QVERIFY(!quota::parseCodexUsage(R"({"plan_type":"free"})"));

        const auto reset = quota::parseResetCredits(R"({"available_count":2,"credits":[
            {"status":"available","granted_at":"2026-11-01T00:00:00Z","expires_at":"2026-12-01T00:00:00Z"},
            {"status":"redeemed","granted_at":"2026-11-01T00:00:00Z"},
            {"status":"available","granted_at":"2026-11-01T00:00:00Z","expires_at":"2026-11-25T00:00:00Z"},
            {"status":"available","granted_at":"2026-11-01T00:00:00Z","expires_at":"2026-11-02T00:00:00Z"}]})");
        QVERIFY(reset.has_value());
        const qint64 now = QDateTime(QDate(2026, 11, 20), QTime(0, 0), QTimeZone::UTC).toMSecsSinceEpoch();
        const auto available = quota::availableResetCredits(*reset, now);
        QCOMPARE(available.size(), 2); // redeemed and expired ones drop out
        QVERIFY(*available[0].expiresAtMs < *available[1].expiresAtMs);

        QCOMPARE(quota::sanitizeCookieHeader("curl 'https://chatgpt.com/x' -H 'Cookie: a=1; b=2' -H 'x: y'"), QString("a=1; b=2"));
        QCOMPARE(quota::sanitizeCookieHeader("Cookie: a=1"), QString("a=1"));
        QCOMPARE(quota::sanitizeCookieHeader("no cookie here"), QString());
        QCOMPARE(quota::sanitizeClaudeSessionKey("Cookie: other=1; sessionKey=sk-ant-sid01-AbC; x=2"), QString("sessionKey=sk-ant-sid01-AbC"));
        QCOMPARE(quota::sanitizeClaudeSessionKey("sk-ant-sid01-AbC"), QString("sessionKey=sk-ant-sid01-AbC"));
        QCOMPARE(quota::sanitizeClaudeSessionKey("bad value\nx"), QString());
    }

    // CodexRateLimitFetcher with a fake transport: headers, the 8-day refresh written back only
    // over unchanged bytes, the retry after a 401, and the cookie route's identity check.
    void codexQuotaFetchRefreshesAndWritesBackSafely() {
        QTemporaryDir dir;
        const QString authPath = dir.path() + "/auth.json";
        const QByteArray payload = QByteArray(R"({"email":"me@example.com"})").toBase64(QByteArray::Base64UrlEncoding | QByteArray::OmitTrailingEquals);
        const auto authJson = [&](const QString &access, const QString &lastRefresh) {
            return QJsonDocument(QJsonObject{{"tokens", QJsonObject{{"access_token", access}, {"refresh_token", "r1"},
                                                                    {"id_token", "h." + QString::fromLatin1(payload) + ".s"},
                                                                    {"account_id", "acct-1"}}},
                                             {"last_refresh", lastRefresh}}).toJson();
        };
        const qint64 now = QDateTime(QDate(2026, 11, 20), QTime(12, 0), QTimeZone::UTC).toMSecsSinceEpoch();
        const QByteArray usageBody = R"({"rate_limit":{"primary_window":{"used_percent":30,"reset_at":1800000000,"limit_window_seconds":18000}}})";
        QStringList calls;
        QString persistedFrom;
        quota::CodexOptions options;
        options.authPath = authPath;
        options.configPath = dir.path() + "/config.toml";
        options.persistRefreshed = [&](const QString &oldFp, const QByteArray &) { persistedFrom = oldFp; };
        QString expectBearer = "Bearer a1";
        int usageStatus = 200;
        const quota::Http http = [&](const quota::HttpRequest &r) {
            const QString url = r.url.toString();
            calls.append(QString::fromLatin1(r.method) + ' ' + url);
            QHash<QByteArray, QByteArray> headers;
            for (const auto &[k, v] : r.headers) headers.insert(k.toLower(), v);
            quota::HttpResponse response;
            if (url == "https://auth.openai.com/oauth/token") {
                response.status = 200;
                response.body = R"({"access_token":"a2","refresh_token":"r2"})";
            } else if (url.endsWith("/wham/usage")) {
                if (headers.contains("cookie")) {
                    response.status = 200;
                    response.body = usageBody;
                } else {
                    response.status = headers.value("authorization") == expectBearer.toUtf8() ? usageStatus : 401;
                    response.body = usageBody;
                }
                if (!headers.contains("cookie")) {
                    if (headers.value("chatgpt-account-id") != "acct-1") response.status = 400;
                }
            } else if (url.endsWith("/wham/rate-limit-reset-credits")) {
                response.status = headers.value("openai-beta") == "codex-1" ? 200 : 400;
                response.body = R"({"available_count":1,"credits":[{"status":"available","granted_at":"2026-11-01T00:00:00Z"}]})";
            } else if (url == "https://chatgpt.com/backend-api/me") {
                response.status = 200;
                response.body = headers.value("cookie") == "good=1" ? R"({"user":{"email":"ME@example.com"}})" : R"({"email":"other@x.com"})";
            }
            return response;
        };

        // Fresh login: no refresh, Bearer + account id, then reset credits.
        writeText(authPath, authJson("a1", "2026-11-19T00:00:00Z"));
        quota::CodexResult result = quota::fetchCodex(options, http, now);
        QVERIFY2(result.ok, qPrintable(result.error));
        QCOMPARE(result.source, QString("OAuth"));
        QCOMPARE(result.usage.primary->usedPercent, 30.0);
        QCOMPARE(result.resetCredits->availableCount, 1);
        QVERIFY(!calls.join('\n').contains("oauth/token"));

        // Older than 8 days: refresh first, written back over the unchanged file.
        writeText(authPath, authJson("a1", "2026-11-01T00:00:00Z"));
        const QString before = codexauth::fingerprint(authJson("a1", "2026-11-01T00:00:00Z"));
        expectBearer = "Bearer a2";
        calls.clear();
        result = quota::fetchCodex(options, http, now);
        QVERIFY2(result.ok, qPrintable(result.error));
        QVERIFY(calls.first().contains("oauth/token"));
        QCOMPARE(persistedFrom, before);
        const auto saved = codexauth::parseCredentials(readJson(authPath).isEmpty() ? QByteArray() : [&] {
            QFile f(authPath);
            f.open(QIODevice::ReadOnly);
            return f.readAll();
        }());
        QCOMPARE(saved->accessToken, QString("a2"));
        QCOMPARE(saved->refreshToken, QString("r2"));
        QVERIFY(saved->lastRefreshMs.has_value());

        // A 401 triggers one refresh and one retry.
        writeText(authPath, authJson("a1", "2026-11-19T00:00:00Z"));
        calls.clear();
        result = quota::fetchCodex(options, http, now);
        QVERIFY2(result.ok, qPrintable(result.error));
        QCOMPARE(calls.size(), 4); // usage 401, refresh, usage, reset credits

        // The cookie route needs the same email; a stranger's cookie falls back to OAuth.
        writeText(authPath, authJson("a2", "2026-11-19T00:00:00Z"));
        options.cookieHeader = "good=1";
        result = quota::fetchCodex(options, http, now);
        QCOMPARE(result.source, QString("Cookie"));
        options.cookieHeader = "bad=1";
        result = quota::fetchCodex(options, http, now);
        QCOMPARE(result.source, QString("OAuth"));
        options.cookieHeader.clear();

        // A rejected refresh token, and no login at all.
        const quota::Http rejecting = [&](const quota::HttpRequest &r) {
            quota::HttpResponse response;
            response.status = r.url.toString().contains("oauth/token") ? 400 : 401;
            return response;
        };
        QCOMPARE(quota::fetchCodex(options, rejecting, now).error, QString("refreshRejected"));
        QFile::remove(authPath);
        QCOMPARE(quota::fetchCodex(options, http, now).error, QString("noCredentials"));
    }

    // CodexAccountManager: save, switch (never over a file that changed), remove, refreshed copies.
    void codexAccountsSaveSwitchAndRemove() {
        QTemporaryDir dir;
        const QString authPath = dir.path() + "/codex/auth.json";
        const auto login = [](const QString &email, const QString &account) {
            const QByteArray payload = QJsonDocument(QJsonObject{{"email", email},
                {"https://api.openai.com/auth", QJsonObject{{"chatgpt_plan_type", "plus"}}}}).toJson(QJsonDocument::Compact)
                .toBase64(QByteArray::Base64UrlEncoding | QByteArray::OmitTrailingEquals);
            return QJsonDocument(QJsonObject{{"tokens", QJsonObject{{"access_token", "t-" + account},
                {"id_token", "h." + QString::fromLatin1(payload) + ".s"}, {"account_id", account}}}}).toJson();
        };
        QVERIFY(QDir().mkpath(dir.path() + "/codex"));
        writeText(authPath, login("a@example.com", "acct-a"));
        codexauth::AccountStore store(dir.path() + "/data", authPath);
        QVERIFY(store.currentNeedsSaving());
        QString error;
        const auto idA = store.saveCurrent(&error);
        QVERIFY2(idA.has_value(), qPrintable(error));
        QCOMPARE(store.accounts().first().plan, QString("plus"));
        QVERIFY(!store.currentNeedsSaving());

        // A second login (codex login into a temporary home) is added and becomes active.
        writeText(dir.path() + "/new-auth.json", login("b@example.com", "acct-b"));
        const auto idB = store.addFromFile(dir.path() + "/new-auth.json", &error);
        QVERIFY2(idB.has_value(), qPrintable(error));
        QCOMPARE(store.active()->email, QString("b@example.com"));
        QCOMPARE(store.accounts().size(), 2);
        // The secret copies are encrypted on disk.
        {
            QFile raw(dir.path() + "/data/codex-accounts/" + *idA + ".bin");
            QVERIFY(raw.open(QIODevice::ReadOnly));
            QVERIFY(!raw.readAll().contains("acct-a"));
        }

        QVERIFY2(store.switchTo(*idA, &error), qPrintable(error));
        QCOMPARE(store.active()->id, *idA);
        // A refreshed token for A keeps A's saved copy current.
        const QByteArray refreshed = login("a@example.com", "acct-a") + " ";
        store.persistRefreshed(codexauth::fingerprint(login("a@example.com", "acct-a")), refreshed);
        QCOMPARE(*store.secret(*idA), refreshed);

        // Never overwrite a file that changed since it was read.
        QVERIFY(!codexauth::replaceIfUnchanged(authPath, "0000", "x", &error));

        QVERIFY2(store.remove(*idA, &error), qPrintable(error)); // active: B takes over
        QCOMPARE(store.active()->id, *idB);
        QVERIFY2(store.remove(*idB, &error), qPrintable(error)); // the last one: signed out
        QVERIFY(!QFile::exists(authPath));
        QVERIFY(store.accounts().isEmpty());
    }

    // ClaudeUsageService / ClaudeWebUsageService with a fake transport.
    void claudeQuotaFetchesLikeMacOS() {
        const auto usage = quota::parseClaudeUsage(R"({"five_hour":{"utilization":12,"resets_at":"2026-11-20T15:00:00Z"},
            "seven_day":{"utilization":40.5,"resets_at":"2026-11-25T00:00:00Z"}, "seven_day_opus":{"utilization":true},
            "limits":[{"kind":"weekly_scoped","group":"weekly","percent":7,"scope":{"model":{"display_name":"Fable","id":"fable-5"}}},
                      {"kind":"weekly_scoped","group":"weekly","percent":9,"scope":{"model":{"display_name":"All models"}}}],
            "extra_usage":{"is_enabled":true,"used_credits":1234,"monthly_limit":5000,"currency":"usd"}})");
        QVERIFY(usage.has_value());
        QCOMPARE(usage->windows.size(), 3); // five_hour, seven_day, scoped Fable (a boolean is not a number)
        QCOMPARE(usage->windows[2].id, QString("scoped-fable-5"));
        QCOMPARE(*usage->extraUsed, 12.34);
        QCOMPARE(usage->extraCurrency, QString("USD"));

        quota::ClaudeCredentials credentials{"tok", std::nullopt, "max", "id"};
        QStringList agents;
        const quota::Http oauth = [&](const quota::HttpRequest &r) {
            quota::HttpResponse response;
            for (const auto &[k, v] : r.headers) if (k == "User-Agent") agents.append(QString::fromLatin1(v));
            const QString url = r.url.toString();
            if (url.endsWith("?cedar_ember=1")) response.status = 404; // retried without the query
            else if (url.endsWith("/usage")) { response.status = 200; response.body = R"({"five_hour":{"utilization":50}})"; }
            else if (url.endsWith("/profile")) { response.status = 200; response.body = R"({"account":{"email_address":"me@x.com"}})"; }
            return response;
        };
        const quota::ClaudeResult ok = quota::fetchClaudeOAuth(credentials, "2.3.4", oauth, 0);
        QVERIFY2(ok.ok, qPrintable(ok.error));
        QCOMPARE(ok.usage.email, QString("me@x.com"));
        QCOMPARE(ok.usage.plan, QString("max"));
        QCOMPARE(agents.value(0), QString("claude-cli/2.3.4 (external, cli)"));
        QCOMPARE(agents.value(1), QString("claude-code/2.3.4"));

        const quota::Http limited = [](const quota::HttpRequest &) {
            quota::HttpResponse response;
            response.status = 429;
            response.headers.insert("retry-after", "5");
            return response;
        };
        const quota::ClaudeResult rate = quota::fetchClaudeOAuth(credentials, "", limited, 1000);
        QCOMPARE(rate.error, QString("rateLimited"));
        QCOMPARE(rate.retryAfterMs, 1000 + 60'000); // clamped to at least 60 s
        credentials.expiresAtMs = 10;
        QCOMPARE(quota::fetchClaudeOAuth(credentials, "", oauth, 20).error, QString("loginRequired"));

        const quota::Http web = [](const quota::HttpRequest &r) {
            quota::HttpResponse response;
            const QString url = r.url.toString();
            response.status = 200;
            if (url.endsWith("/organizations")) response.body = R"([{"uuid":"o1","name":"Mine"},{"uuid":"o2","name":"Work"}])";
            else if (url.contains("/usage")) response.body = R"({"seven_day":{"utilization":10}})";
            else if (url.endsWith("/prepaid/credits")) response.body = R"({"amount":2500,"currency":"eur"})";
            else response.body = "{}";
            return response;
        };
        const quota::ClaudeResult choose = quota::fetchClaudeWeb("sessionKey=x", "", web);
        QCOMPARE(choose.error, QString("chooseOrganization"));
        QCOMPARE(choose.organizations.size(), 2);
        const quota::ClaudeResult chosen = quota::fetchClaudeWeb("sessionKey=x", "o2", web);
        QVERIFY2(chosen.ok, qPrintable(chosen.error));
        QCOMPARE(chosen.usage.organization, QString("Work"));
        QCOMPARE(*chosen.usage.prepaidBalance, 25.0);
        QCOMPARE(chosen.usage.prepaidCurrency, QString("EUR"));

        // The reply-state labels: exact stop buttons only.
        QVERIFY(claudeui::isStopLabel(" Stop Response "));
        QVERIFY(claudeui::isStopLabel(QString::fromUtf8("停止回复")));
        QVERIFY(!claudeui::isStopLabel("Stop"));
        QVERIFY(!claudeui::isStopLabel(QString::fromUtf8("任务运行中")));
        QVERIFY(claudeui::isMessagesGroup("Conversation messages"));
        const auto roundTrip = secrets::unprotect(*secrets::protect("secret"));
        QCOMPARE(*roundTrip, QByteArray("secret"));
    }

    // Install CLI edits the user PATH as a string; the registry calls are not exercised here.
    void cliPathAddsAndRemovesOnlyItsFolder() {
        const QString dir = "C:\\Users\\me\\AppData\\Local\\Programs\\AgentSignalBar";
        const clipath::Expand expand = [](const QString &value) {
            return QString(value).replace("%LOCALAPPDATA%", "C:\\Users\\me\\AppData\\Local", Qt::CaseInsensitive);
        };
        const QString original = "%USERPROFILE%\\bin;;C:\\Tools\\";
        QVERIFY(!clipath::contains(original, dir, expand));
        const QString added = clipath::withDirectory(original, dir, true, expand);
        QCOMPARE(added, "%USERPROFILE%\\bin;C:\\Tools\\;" + dir);
        QVERIFY(clipath::contains(added, dir, expand));
        QCOMPARE(clipath::withDirectory(added, dir, true, expand), added); // no duplicate

        // Another spelling of the same folder counts as present and is removed with it.
        const QString spelled = original + ";%LocalAppData%\\Programs\\agentsignalbar\\;\"c:/users/me/appdata/local/programs/AgentSignalBar\"";
        QVERIFY(clipath::contains(spelled, dir, expand));
        QCOMPARE(clipath::withDirectory(spelled, dir, false, expand), QString("%USERPROFILE%\\bin;C:\\Tools\\"));
        QCOMPARE(clipath::withDirectory("", dir, true, expand), dir);
        QVERIFY(!clipath::contains("C:\\Users\\me\\AppData\\Local\\Programs", dir, expand));
    }

    void installerLeavesUnreadableSettingsAlone() {
        QTemporaryDir dir;
        const QString exe = dir.path() + "/agent-signal.exe";
        writeText(exe, "fake");
        writeText(dir.path() + "/settings.json", "{ \"hooks\": [ broken");
        hooks::ClaudeHookInstaller installer(dir.path(), exe);
        installer.allowTemporaryLocationForTests();
        QVERIFY(!installer.install().ok);
        QFile f(dir.path() + "/settings.json");
        QVERIFY(f.open(QIODevice::ReadOnly));
        QCOMPARE(f.readAll(), QByteArray("{ \"hooks\": [ broken"));
        QVERIFY(QDir(dir.path()).entryList({"settings.json.bak-*"}).isEmpty());
#ifndef Q_OS_WIN
        QTemporaryDir linked;
        QVERIFY(QFile::link(dir.path() + "/settings.json", linked.path() + "/settings.json"));
        hooks::ClaudeHookInstaller viaLink(linked.path(), exe);
        viaLink.allowTemporaryLocationForTests();
        QVERIFY(!viaLink.install().ok);
#endif
    }

    void displayDeduplicatesBySourceAndLabelsRuntime() {
        const qint64 t0 = 1'800'000'000'000;
        SignalSnapshot snapshot;
        snapshot.aggregate = "working";
        snapshot.sessions = {session("codex-cli:a", "working", t0 - 1000, "codex-cli", "DesktopMessage"),
                             session("codex-cli:b", "thinking", t0 - 500, "codex-cli", "DesktopTaskStarted"),
                             session("codex-vscode:c", "working", t0 - 800, "codex-vscode", "DesktopToolCall:x")};
        const auto shown = display::displaySnapshot(snapshot, t0);
        QCOMPARE(shown.sessions.size(), 2); // one terminal source, one VS Code source
        QCOMPARE(shown.sessions[0].sessionID, QString("codex-cli:b"));
        QCOMPARE(display::runtimeKind("codex-cli", "codex-cli:b", ""), display::RuntimeKind::Terminal);
        QCOMPARE(display::runtimeKind("codex-vscode", "codex-vscode:c", ""), display::RuntimeKind::Ide);
        QCOMPARE(display::sourceDetail("codex-vscode", "codex-vscode:c", "").value(), QString("VS Code"));
        QCOMPARE(display::runtimeKind("codex-desktop", "codex-desktop:d", ""), display::RuntimeKind::Desktop);
        QCOMPARE(display::activitySourceKey("codex-vscode", "codex-vscode:c", ""), QString("codex:ide:vs-code"));
    }
};

QTEST_GUILESS_MAIN(CodexTest)
#include "tst_codex.moc"

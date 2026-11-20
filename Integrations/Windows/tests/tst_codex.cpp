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
        QCOMPARE(settings.value("hooks").toObject().value("PermissionRequest").toArray()[0].toObject()
                     .value("hooks").toArray()[0].toObject().value("timeout").toInt(), 10);

        QVERIFY(installer.check().configured);
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

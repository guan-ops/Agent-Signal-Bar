// Codex data layer: the parser and the store replay tests/golden/codex_golden.jsonl
// (generated from the Swift sources); the monitor and display rules are checked against
// hand-written scenarios in temporary directories. Nothing here reads the real ~/.codex.
#include "../src/ActivityDisplay.h"
#include "../src/CodexActivityMonitor.h"
#include "../src/CodexSessionParser.h"
#include "../src/SignalStore.h"

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
        QCOMPARE(codex::primaryCodexHome("/home/u", "", ""), QString("/home/u/.codex"));
        QCOMPARE(codex::primaryCodexHome("/home/u", " /data/codex ", ""), QString("/data/codex"));
        QCOMPARE(codex::primaryCodexHome("/home/u", "/data/codex", "~/picked"), QString("/home/u/picked"));
        QCOMPARE(codex::activityRoots("/home/u", "", "").first().path, QString("/home/u/.codex/sessions"));
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

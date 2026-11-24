// Replays tests/golden/lamp_golden.jsonl (generated from the Swift AgentSignalLightCore)
// against the C++ port, so the Windows lamp blinks exactly like the macOS one.
#include "../src/SignalModel.h"

#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QtTest>

using namespace asb;

namespace {
EffectCustomization parseCustomization(const QString &key) {
    EffectCustomization c;
    if (key == QLatin1String("default")) return c;
    for (const QString &part : key.split(',')) {
        const QString name = part.section('=', 0, 0);
        const QString value = part.section('=', 1);
        if (name == "active") c.activeEffect = *activeEffectFromKey(value);
        else if (name == "thinking") c.thinkingEffect = *activeEffectFromKey(value);
        else if (name == "activeSpeed") c.activeSpeed = *effectSpeedFromKey(value);
        else if (name == "alertSpeed") c.alertSpeed = *effectSpeedFromKey(value);
        else if (name == "completed") c.completedEffect = *completedEffectFromKey(value);
        else if (name == "needsReview") c.needsReviewEffect = *alertEffectFromKey(value);
        else if (name == "permission") c.permissionEffect = *alertEffectFromKey(value);
        else if (name == "blocked") c.blockedEffect = *alertEffectFromKey(value);
        else qFatal("unknown customization key %s", qPrintable(name));
    }
    return c;
}
} // namespace

class SignalModelTest : public QObject {
    Q_OBJECT
private slots:
    void normalizesAliases() {
        QCOMPARE(normalizedSignal(" Tool-Use ").value(), QString("working"));
        QCOMPARE(normalizedSignal("PermissionRequest").value(), QString("permission_request"));
        QCOMPARE(normalizedSignal("failed").value(), QString("failure"));
        QVERIFY(!normalizedSignal("nonsense").has_value());
        QCOMPARE(displayState("max_tokens"), DisplayState::Blocked);
        QCOMPARE(displayState("notification"), DisplayState::NeedsReview);
    }

    void dominantPrefersGreenOnTies() {
        QCOMPARE(dominantColor("idle", 0, true).value(), LampColor::Green);
        QVERIFY(!dominantColor("paused", 0).has_value());
        QCOMPARE(dominantColor("permission", 0).value(), LampColor::Red);
    }

    // Values from MenuBarStatusModel.{lowPower,newZealand}AnimationTickCadence.
    void cadenceMatchesMacRuntime() {
        const EffectCustomization def;
        QCOMPARE(tickCadence("working", def, false, false), (TickCadence{1, 1}));
        QCOMPARE(tickCadence("working", def, true, false), (TickCadence{1, 2}));      // slow flash
        QCOMPARE(tickCadence("thinking", def, true, false), (TickCadence{1, 1}));     // fast flash
        QCOMPARE(tickCadence("blocked", def, true, false), (TickCadence{1, 1}));      // fast flash
        QCOMPARE(tickCadence("permission", def, true, false), (TickCadence{1, 2}));   // slow flash
        QCOMPARE(tickCadence("stale", def, true, false), (TickCadence{1, 2}));
        QCOMPARE(tickCadence("idle", def, true, false), (TickCadence{1, 1}));
        QCOMPARE(tickCadence("working", def, false, true), (TickCadence{2, 3}));      // 0.9 s on / 0.9 s off
        QCOMPARE(tickCadence("working", def, true, true), (TickCadence{1, 3}));
        QCOMPARE(tickCadence("permission", def, false, true), (TickCadence{2, 3}));
        QCOMPARE(tickCadence("idle", def, false, true), (TickCadence{1, 1}));
        QCOMPARE(tickCadence("stale", def, true, true), (TickCadence{1, 2}));
        EffectCustomization cycle;
        cycle.activeEffect = ActiveEffect::TrafficCycle;
        cycle.blockedEffect = AlertEffect::TrafficCycle;
        QCOMPARE(tickCadence("working", cycle, false, true), (TickCadence{4, 4}));
        QCOMPARE(tickCadence("blocked", cycle, true, false), (TickCadence{2, 4}));
        EffectCustomization pulse;
        pulse.completedEffect = CompletedEffect::GreenPulse;
        QCOMPARE(tickCadence("done", pulse, false, true), (TickCadence{2, 2}));
        QCOMPARE(tickCadence("done", pulse, true, false), (TickCadence{1, 2}));
    }

    void matchesSwiftGolden() {
        QFile file(QStringLiteral(GOLDEN_PATH));
        QVERIFY2(file.open(QIODevice::ReadOnly), qPrintable(file.fileName()));
        int rows = 0;
        while (!file.atEnd()) {
            const QByteArray line = file.readLine().trimmed();
            if (line.isEmpty()) continue;
            const QJsonObject row = QJsonDocument::fromJson(line).object();
            const QString signal = row["signal"].toString();
            const bool allOn = row["allOn"].toBool();
            const EffectCustomization custom = parseCustomization(row["custom"].toString());
            const QString state = row["state"].toString();
            if (state == "unknown") {
                QVERIFY2(!normalizedSignal(signal).has_value(), qPrintable(signal));
                ++rows;
                continue;
            }
            QCOMPARE(displayStateKey(displayState(signal)), state);
            for (const char *name : {"red", "yellow", "green"}) {
                const LampColor color = *lampColorFromKey(name);
                const QJsonArray expected = row[name].toArray();
                const QJsonArray expectedScale = row[QString(name) + "Scale"].toArray();
                for (int tick = 0; tick < expected.size(); ++tick) {
                    const double got = intensity(color, signal, tick, allOn, custom);
                    const double gotScale = scale(color, signal, tick, allOn, custom);
                    if (!qFuzzyCompare(1 + got, 1 + expected[tick].toDouble())
                        || !qFuzzyCompare(1 + gotScale, 1 + expectedScale[tick].toDouble())) {
                        QFAIL(qPrintable(QString("%1 %2 %3 tick %4 allOn %5: got %6/%7 want %8/%9")
                                             .arg(row["custom"].toString(), signal, name)
                                             .arg(tick).arg(allOn).arg(got).arg(gotScale)
                                             .arg(expected[tick].toDouble()).arg(expectedScale[tick].toDouble())));
                    }
                }
            }
            ++rows;
        }
        QVERIFY(rows > 1000);
    }
};

QTEST_APPLESS_MAIN(SignalModelTest)
#include "tst_signalmodel.moc"

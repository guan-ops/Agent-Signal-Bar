// Agent Signal Bar for Windows: Qt 6 tray app. Same layering as CodexBar's
// Integrations/Linux desktop: a C++ controller plus QML windows.
//
//   --capture <dir>    render every surface and tray icon variant to PNGs (demo data), then quit
//   --settings <file>  use this INI file instead of the per-user settings
//   --signal <name>    demo mode: show this signal (working, permission, done, ...) instead of
//                      following Codex activity
//   --probe <seconds>  print what the Codex monitor sees (roots, lamp, sessions), no windows
//   --codex-dir <dir>  use this Codex data directory (replaying its recent history) for the
//                      app, --probe or --capture; with --capture the screenshots show live data
//   --claude-dir <dir> Claude Code config folder for the hook installer (development builds
//                      outside Windows change Claude settings only with this)
//
// The state lives in status.json (SignalStateFile::defaultPath), shared with agent-signal.exe,
// which Claude Code hooks run.
//
// Without --capture or --signal the lamp follows the Codex rollout files under
// <prefs codexDataDir | CODEX_HOME | %USERPROFILE%\.codex>\sessions.
#include "AppController.h"
#include "ActivityText.h"
#include "SignalRuntime.h"
#include "SignalStateFile.h"
#include "TrayIconRenderer.h"

#include <QApplication>
#include <QCommandLineParser>
#include <QDateTime>
#include <QDir>
#include <QFileInfo>
#include <QTemporaryDir>
#include <QTextStream>
#include <algorithm>
#include <cstdio>

#ifdef Q_OS_WIN
#include <windows.h>
#endif
#include <QPainter>
#include <QQmlApplicationEngine>
#include <QQuickStyle>
#include <QQuickWindow>
#include <QSystemTrayIcon>

namespace {

TrayIconSpec currentSpec(const AppController &app) {
    TrayIconSpec spec;
    spec.signal = app.signalName();
    spec.tick = app.tick();
    spec.style = app.prefs()->value("statusStyle").toString();
    spec.layout = app.prefs()->value("statusLayout").toString();
    spec.lightTaskbar = TrayIconRenderer::taskbarUsesLightTheme();
    spec.customization = app.effectCustomization();
    return spec;
}

// One sheet with every style × layout × state at 16/24/32 px, for review on any OS.
void writeTraySheet(const QString &dir) {
    const QStringList states = {"idle", "thinking", "working", "done", "attention", "permission", "blocked", "stale", "paused"};
    const QList<QPair<QString, QString>> variants = {
        {"trafficLight", "horizontal"}, {"trafficLight", "vertical"}, {"macOS", "horizontal"},
        {"macOS", "vertical"}, {"singleLamp", "horizontal"}};
    const int cell = 40;
    for (bool light : {false, true}) {
        QImage sheet(cell * states.size(), cell * variants.size() * 3, QImage::Format_ARGB32_Premultiplied);
        sheet.fill(light ? QColor(243, 243, 243) : QColor(32, 32, 32));
        QPainter p(&sheet);
        int row = 0;
        for (const auto &variant : variants) {
            for (int size : {16, 24, 32}) {
                for (int col = 0; col < states.size(); ++col) {
                    TrayIconSpec spec;
                    spec.signal = states[col];
                    spec.tick = 2;
                    spec.style = variant.first;
                    spec.layout = variant.second;
                    spec.lightTaskbar = light;
                    const QImage icon = TrayIconRenderer::render(spec, size);
                    p.drawImage(col * cell + (cell - size) / 2, row * cell + (cell - size) / 2, icon);
                }
                ++row;
            }
        }
        p.end();
        sheet.save(dir + (light ? "/tray-sheet-light.png" : "/tray-sheet-dark.png"));
    }
}

// --probe: run the live Codex pipeline without any window and print what it sees, so the
// data directory can be checked from a terminal (also on Windows, where the GUI app
// attaches to the calling console).
int runProbe(QApplication &app, int seconds, const QString &dataDir) {
#ifdef Q_OS_WIN
    // A GUI-subsystem exe has no console of its own; borrow the caller's (use `start /wait`).
    if (AttachConsole(ATTACH_PARENT_PROCESS)) {
        std::freopen("CONOUT$", "w", stdout);
        SetConsoleOutputCP(CP_UTF8);
    }
#endif
    QTextStream out(stdout);
    const QList<asb::codex::Root> roots = dataDir.isEmpty()
        ? asb::codex::activityRoots(QDir::homePath(), qEnvironmentVariable("CODEX_HOME"), dataDir)
        : asb::codex::rootsForDirectory(QDir::homePath(), dataDir);
    out << "Codex home: "
        << QDir::toNativeSeparators(asb::codex::primaryCodexHome(QDir::homePath(), qEnvironmentVariable("CODEX_HOME"), dataDir))
        << "\n";
    for (const auto &root : roots) out << "  root: " << QDir::toNativeSeparators(root.path) << "\n";
    // Work on a copy of status.json, so the probe never writes the app's state; Claude Code
    // hook sessions already in it still show.
    const QString realState = asb::SignalStateFile::defaultPath();
    out << "State file: " << QDir::toNativeSeparators(realState) << (QFileInfo::exists(realState) ? "" : " (not created yet)")
        << "\n";
    out.flush();
    QTemporaryDir scratch;
    const QString probeState = scratch.path() + "/status.json";
    QFile::copy(realState, probeState);

    SignalRuntime runtime(probeState);
    const bool zh = false;
    QString last;
    QObject::connect(&runtime, &SignalRuntime::changed, &app, [&] {
        if (!runtime.hasPolled()) return;
        const auto &health = runtime.connection();
        QString report;
        QTextStream line(&report);
        line << "existing roots " << health.existingRoots << ", recent files " << health.recentFiles;
        if (!health.unreadable.isEmpty()) line << ", unreadable: " << health.unreadable.join(", ");
        line << "\n";
        // Size, modification age and bytes consumed per file: shows whether appends are seen
        // and whether the file system's modification time keeps up while Codex writes.
        const qint64 now = QDateTime::currentMSecsSinceEpoch();
        for (const asb::codex::TrackedFile &f : runtime.trackedFiles())
            line << "  file " << QFileInfo(f.path).fileName() << " size " << f.size << " read " << f.consumed
                 << " modified " << (now - f.modifiedMs) / 1000 << "s ago\n";
        line << "lamp: " << runtime.display().aggregate << "\n";
        for (const asb::SessionStatus &s : runtime.visibleSessions())
            line << "  session " << asb::text::sessionTitle(s, zh) << " | " << asb::text::sessionSubtitle(s, zh) << " | "
                 << QDateTime::fromMSecsSinceEpoch(s.updatedAt).toString("HH:mm:ss") << "\n";
        if (report == last) return;
        last = report;
        out << QDateTime::currentDateTime().toString("HH:mm:ss") << " " << report;
        out.flush();
    });
    runtime.start(roots, false, /*replayRecentHistory=*/true); // show work already in progress
    QTimer::singleShot(seconds * 1000, &app, &QCoreApplication::quit);
    return app.exec();
}

} // namespace

int main(int argc, char *argv[]) {
    QQuickWindow::setDefaultAlphaBuffer(true); // translucent popups and Mica-backed settings
    QApplication app(argc, argv);
    QApplication::setApplicationName("Agent Signal Bar");
    QApplication::setOrganizationName("AgentSignalBar");
    QApplication::setQuitOnLastWindowClosed(false);
    QQuickStyle::setStyle("Basic");

    QCommandLineParser parser;
    parser.addHelpOption();
    QCommandLineOption captureOption("capture", "Render all surfaces to PNG files in <dir> and quit.", "dir");
    QCommandLineOption settingsOption("settings", "Settings INI file.", "file");
    QCommandLineOption signalOption("signal", "Initial demo signal.", "name", "working");
    QCommandLineOption probeOption("probe", "Print what the Codex monitor sees for <seconds>, then quit.", "seconds");
    QCommandLineOption codexDirOption("codex-dir", "Codex data directory (default: settings, CODEX_HOME or ~/.codex).", "dir");
    QCommandLineOption claudeDirOption("claude-dir", "Claude Code config folder for the hook installer (default: CLAUDE_CONFIG_DIR or ~/.claude).", "dir");
    parser.addOptions({captureOption, settingsOption, signalOption, probeOption, codexDirOption, claudeDirOption});
    parser.process(app);
    if (parser.isSet(probeOption)) return runProbe(app, std::max(1, parser.value(probeOption).toInt()), parser.value(codexDirOption));

    const QString captureDir = parser.value(captureOption);
    QString settingsFile = parser.value(settingsOption);
    if (!captureDir.isEmpty()) {
        QDir().mkpath(captureDir);
        // Capture runs never read or write the user's real settings.
        if (settingsFile.isEmpty()) {
            settingsFile = captureDir + "/capture-settings.ini";
            QFile::remove(settingsFile);
        }
        writeTraySheet(captureDir);
    }

    // --codex-dir makes even a capture run live, against that (fixture) directory only.
    const QString codexDir = parser.value(codexDirOption);
    const bool live = !codexDir.isEmpty() || (captureDir.isEmpty() && !parser.isSet(signalOption));
    AppController controller(settingsFile, captureDir, live, codexDir, parser.value(claudeDirOption));
    controller.setDemoSignal(parser.value(signalOption));
    qmlRegisterSingletonInstance("AgentSignal", 1, 0, "App", &controller);

    QSystemTrayIcon tray;
    TrayIconSpec lastSpec;
    const auto refreshTray = [&] {
        const TrayIconSpec spec = currentSpec(controller);
        if (!(spec == lastSpec) || tray.icon().isNull()) {
            lastSpec = spec;
            tray.setIcon(TrayIconRenderer::icon(spec));
        }
        tray.setToolTip("Agent Signal Bar · " + controller.displayStateTitle());
        tray.setVisible(controller.prefs()->value("statusBarEnabled").toBool());
        controller.setTrayGeometry(tray.geometry());
    };
    QObject::connect(&controller, &AppController::tickChanged, &tray, refreshTray);
    QObject::connect(&controller, &AppController::signalNameChanged, &tray, refreshTray);
    QObject::connect(controller.prefs(), &QQmlPropertyMap::valueChanged, &tray, refreshTray);
    QObject::connect(&tray, &QSystemTrayIcon::activated, &controller, [&](QSystemTrayIcon::ActivationReason reason) {
        controller.setTrayGeometry(tray.geometry());
        if (reason == QSystemTrayIcon::Trigger) {
            if (controller.prefs()->value("menuMode").toString() == "simple") controller.showSystemMenu();
            else controller.showPanel();
        } else if (reason == QSystemTrayIcon::Context) {
            controller.showSystemMenu();
        } else if (reason == QSystemTrayIcon::DoubleClick) {
            controller.openSettings();
        }
    });
    if (captureDir.isEmpty()) refreshTray();

    QQmlApplicationEngine engine;
    QObject::connect(&engine, &QQmlApplicationEngine::objectCreationFailed, &app, [] { QCoreApplication::exit(1); },
                     Qt::QueuedConnection);
    engine.load(QUrl("qrc:/qml/Main.qml"));
    return app.exec();
}

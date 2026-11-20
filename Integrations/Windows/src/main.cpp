// Agent Signal Bar for Windows: Qt 6 tray app. Same layering as CodexBar's
// Integrations/Linux desktop: a C++ controller plus QML windows.
//
//   --capture <dir>    render every surface and tray icon variant to PNGs, then quit
//   --settings <file>  use this INI file instead of the per-user settings
//   --signal <name>    start with this demo signal (working, permission, done, ...)
#include "AppController.h"
#include "TrayIconRenderer.h"

#include <QApplication>
#include <QCommandLineParser>
#include <QDir>
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
    parser.addOptions({captureOption, settingsOption, signalOption});
    parser.process(app);

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

    AppController controller(settingsFile, captureDir);
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

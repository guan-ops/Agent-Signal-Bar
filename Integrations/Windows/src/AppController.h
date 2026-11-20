#pragma once

#include "SignalModel.h"

#include <QColor>
#include <QObject>
#include <QPoint>
#include <QQmlPropertyMap>
#include <QRect>
#include <QSettings>
#include <QTimer>
#include <memory>

class QWindow;

// The bridge between QML and the platform: preferences, the shared animation tick,
// the displayed signal, localisation and Windows integration (tray placement,
// backdrop, start-at-login). Exposed to QML as the `App` singleton.
class AppController : public QObject {
    Q_OBJECT
    Q_PROPERTY(int tick READ tick NOTIFY tickChanged)
    Q_PROPERTY(QString signalName READ signalName NOTIFY signalNameChanged)
    Q_PROPERTY(QString displayState READ displayState NOTIFY signalNameChanged)
    Q_PROPERTY(bool paused READ paused NOTIFY signalNameChanged)
    Q_PROPERTY(bool lightDebugActive READ lightDebugActive NOTIFY signalNameChanged)
    Q_PROPERTY(QString language READ language NOTIFY languageChanged)
    Q_PROPERTY(bool dark READ dark NOTIFY themeChanged)
    Q_PROPERTY(QColor accent READ accent NOTIFY themeChanged)
    Q_PROPERTY(QQmlPropertyMap *prefs READ prefs CONSTANT)
    Q_PROPERTY(QString platform READ platform CONSTANT)
    Q_PROPERTY(QString version READ version CONSTANT)
    Q_PROPERTY(QString captureDir READ captureDir CONSTANT)
    Q_PROPERTY(QString uiFont READ uiFont CONSTANT)
    // DWMWA_SYSTEMBACKDROP_TYPE needs Windows 11 22H2 (build 22621); older systems stay opaque.
    Q_PROPERTY(bool supportsBackdrop READ supportsBackdrop CONSTANT)

public:
    explicit AppController(const QString &settingsFile, const QString &captureDir, QObject *parent = nullptr);

    int tick() const { return m_tick; }
    QString signalName() const;
    QString displayState() const;
    QString displayStateTitle() const;
    bool paused() const { return m_paused; }
    bool lightDebugActive() const { return !m_debugSignal.isEmpty(); }
    QString language() const;
    bool dark() const;
    QColor accent() const;
    QQmlPropertyMap *prefs() const { return m_prefs; }
    QString platform() const;
    QString version() const;
    QString captureDir() const { return m_captureDir; }
    QString uiFont() const;
    bool supportsBackdrop() const;

    asb::EffectCustomization effectCustomization() const;
    void setTrayGeometry(const QRect &rect) { m_trayGeometry = rect; }

    Q_INVOKABLE QString text(const QString &zhHans, const QString &english) const;
    // `signal` is explicit so QML bindings re-evaluate when App.signalName changes.
    Q_INVOKABLE double lampIntensity(const QString &color, const QString &signal, int tick, bool allLightsOn) const;
    Q_INVOKABLE double lampScale(const QString &color, const QString &signal, int tick, bool allLightsOn,
                                 const QString &style) const;
    Q_INVOKABLE QString dominantLamp(const QString &signal, int tick) const;
    Q_INVOKABLE QPoint popupPosition(int width, int height) const;
    // Bottom-right of the primary screen's work area; also used to rescue a saved
    // position that is no longer on any screen (monitor unplugged).
    Q_INVOKABLE QPoint floatingPosition(int x, int y, int width, int height) const;
    Q_INVOKABLE void openSettings(const QString &page = QString());
    Q_INVOKABLE void showPanel();
    Q_INVOKABLE void showSystemMenu();
    Q_INVOKABLE void togglePause();
    Q_INVOKABLE void setDebugSignal(const QString &signal);
    Q_INVOKABLE void setDemoSignal(const QString &signal);
    Q_INVOKABLE void copyText(const QString &text) const;
    Q_INVOKABLE void openUrl(const QString &url) const;
    Q_INVOKABLE void previewSound(const QString &kind, const QString &sound) const;
    Q_INVOKABLE void applyBackdrop(QWindow *window, const QString &kind) const;
    Q_INVOKABLE QString settingsFilePath() const;
    Q_INVOKABLE void quit();

signals:
    void tickChanged();
    void signalNameChanged();
    void languageChanged();
    void themeChanged();
    void settingsRequested(const QString &page);
    void panelRequested();
    void systemMenuRequested();

private:
    void onPrefChanged(const QString &key, const QVariant &value);
    void restartTimer();
    void applyLaunchAtLogin(bool enabled) const;

    QQmlPropertyMap *m_prefs;
    std::unique_ptr<QSettings> m_settings;
    QString m_captureDir;
    QTimer m_timer;
    QRect m_trayGeometry;
    QString m_demoSignal = QStringLiteral("working");
    QString m_debugSignal;
    bool m_paused = false;
    int m_tick = 0;
    int m_frameSkip = 0;
};

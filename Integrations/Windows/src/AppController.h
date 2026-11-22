#pragma once

#include "SignalModel.h"

#include <QColor>
#include <QVariantList>
#include <QObject>
#include <QPoint>
#include <QQmlPropertyMap>
#include <QRect>
#include <QSettings>
#include <QTimer>
#include <QUrl>
#include <memory>
#include <optional>

class QScreen;
class QWindow;
class SignalRuntime;

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
    Q_PROPERTY(QString uiFont READ uiFont NOTIFY languageChanged)
    // DWMWA_SYSTEMBACKDROP_TYPE needs Windows 11 22H2 (build 22621); older systems stay opaque.
    Q_PROPERTY(bool supportsBackdrop READ supportsBackdrop CONSTANT)
    // True when the lamp follows Codex activity; false for capture and --signal demo runs.
    Q_PROPERTY(bool liveData READ liveData CONSTANT)
    // Visible sessions and recent events as QML-ready maps (title, detail, state, time, ...).
    Q_PROPERTY(QVariantList sessions READ sessions NOTIFY activityChanged)
    Q_PROPERTY(QVariantList events READ events NOTIFY activityChanged)
    // home, roots, existingRoots, recentFiles, unreadable, polled, lastActivity.
    Q_PROPERTY(QVariantMap codexConnection READ codexConnection NOTIFY activityChanged)
    // state (configured | missing | repair | error | unchecked), message, tone, settingsPath,
    // canModify, result (last action), stateFile.
    Q_PROPERTY(QVariantMap claudeHook READ claudeHook NOTIFY claudeHookChanged)

public:
    // `live` starts the Codex monitor; capture and demo runs keep the synthetic signal.
    // `codexDirOverride` replaces the data directory (and replays its recent history), for
    // fixture-driven captures; it is not saved to the preferences.
    // `claudeDirOverride` points the hook installer at another Claude config folder; on
    // systems other than Windows, Install/Uninstall are enabled only with it.
    AppController(const QString &settingsFile, const QString &captureDir, bool live,
                  const QString &codexDirOverride = QString(), const QString &claudeDirOverride = QString(),
                  QObject *parent = nullptr);
    ~AppController() override;

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
    bool liveData() const { return m_runtime != nullptr; }
    QVariantList sessions() const { return m_sessions; }
    QVariantList events() const { return m_events; }
    QVariantMap codexConnection() const { return m_codexConnection; }
    QVariantMap claudeHook() const { return m_claudeHook; }

    asb::EffectCustomization effectCustomization() const;
    void setTrayGeometry(const QRect &rect) { m_trayGeometry = rect; }
    // A tray click: the icon's rectangle and the cursor position, both in logical pixels.
    void setTrayActivation(const QRect &iconRect, const QPoint &clickPoint) {
        m_trayGeometry = iconRect;
        m_trayClick = clickPoint;
    }

    Q_INVOKABLE QString text(const QString &zhHans, const QString &english) const;
    // `signal` is explicit so QML bindings re-evaluate when App.signalName changes.
    Q_INVOKABLE double lampIntensity(const QString &color, const QString &signal, int tick, bool allLightsOn) const;
    Q_INVOKABLE double lampScale(const QString &color, const QString &signal, int tick, bool allLightsOn,
                                 const QString &style) const;
    Q_INVOKABLE QString dominantLamp(const QString &signal, int tick) const;
    // Where a tray popup opens. "panel": a flyout above the taskbar, centred on the icon;
    // "menu": like a native context menu, with a corner at the click point.
    Q_INVOKABLE QPoint popupPosition(int width, int height, const QString &placement = QStringLiteral("panel")) const;
    // Tallest a tray popup may be on the clicked screen; taller content scrolls.
    Q_INVOKABLE int popupMaxHeight() const;
    // A floating-lamp badge's panel, placed as on macOS: above the badge, right-aligned to it.
    Q_INVOKABLE QPoint badgePanelPosition(int badgeX, int badgeY, int badgeSize, int width, int height) const;
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
    Q_INVOKABLE void checkCodexConnection();
    Q_INVOKABLE void checkClaudeHook();
    Q_INVOKABLE void installClaudeHook();
    Q_INVOKABLE void uninstallClaudeHook();
    // Local path from a FolderDialog URL, so QML can store it in prefs.codexDataDir.
    Q_INVOKABLE QString localPath(const QUrl &url) const;
    Q_INVOKABLE void quit();

signals:
    void tickChanged();
    void signalNameChanged();
    void activityChanged();
    void claudeHookChanged();
    void languageChanged();
    void themeChanged();
    void settingsRequested(const QString &page);
    void panelRequested();
    void systemMenuRequested();

private:
    void onPrefChanged(const QString &key, const QVariant &value);
    void restartTimer();
    void applyLaunchAtLogin(bool enabled) const;
    QScreen *popupScreen() const; // the screen of the last tray click, else the primary
    void rebuildActivity();
    void runClaudeHook(const QString &action);
    void rebuildClaudeHook();
    QString hookExePath() const;
    QString claudeRoot() const;

    QQmlPropertyMap *m_prefs;
    SignalRuntime *m_runtime = nullptr;
    QVariantList m_sessions;
    QVariantList m_events;
    QVariantMap m_codexConnection;
    QString m_liveSignal = QStringLiteral("idle");
    QString m_codexDirOverride;
    QString m_claudeDirOverride;
    QVariantMap m_claudeHook;
    // Last hook check: nullopt until checked.
    std::optional<bool> m_claudeConfigured;
    QString m_claudeState = QStringLiteral("unchecked");
    QString m_claudeError;
    QString m_claudeResult;
    std::unique_ptr<QSettings> m_settings;
    QString m_captureDir;
    QTimer m_timer;
    QRect m_trayGeometry;
    std::optional<QPoint> m_trayClick;
    QString m_demoSignal = QStringLiteral("working");
    QString m_debugSignal;
    bool m_paused = false;
    int m_tick = 0;
    int m_frameSkip = 0;
};

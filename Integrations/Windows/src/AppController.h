#pragma once

#include "LightScope.h"
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
class UsageService;
namespace asb::usage { struct Report; }

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
    // Resolved interface language: zh-Hans, zh-Hant, en, ja, ko, es, fr, de or pt.
    Q_PROPERTY(QString language READ language NOTIFY languageChanged)
    // The macOS translation table for that language ({English: text}); empty for zh-Hans and en.
    Q_PROPERTY(QVariantMap translations READ translations NOTIFY languageChanged)
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
    // The same for the optional Codex hooks (<Codex home>\hooks.json).
    Q_PROPERTY(QVariantMap codexHook READ codexHook NOTIFY codexHookChanged)
    // Export diagnostics: running, message, tone, folder, archive.
    Q_PROPERTY(QVariantMap diagnostics READ diagnostics NOTIFY diagnosticsChanged)
    // Install CLI: installed (the install folder is on PATH), directory, canModify, message, tone.
    Q_PROPERTY(QVariantMap cli READ cli NOTIFY cliChanged)
    Q_PROPERTY(QString debugLogPath READ debugLogPath CONSTANT)
    // Local token usage (Usage page, tray card, floating token badge): {codex, claude}, each with
    // ready, scanning, status, scan, today/month {tokens, tokensText, costText, costLine},
    // days (30, for TokenChart), topModel, projects, badgeText, empty; plus rateNote.
    Q_PROPERTY(QVariantMap usage READ usage NOTIFY usageChanged)
    // Which agent the lamp shows (signalLightFollowingText): "自动跟随 · Codex 终端", "暂时显示
    // Claude 桌面版", or the manual selection; empty without live data.
    Q_PROPERTY(QString lightFollowingText READ lightFollowingText NOTIFY activityChanged)
    // signalLightAgentUnavailableHint: why a manual selection shows nothing, or what it borrows.
    Q_PROPERTY(QString lightAgentHint READ lightAgentHint NOTIFY activityChanged)
    // Open desktop apps (Codex / Claude desktop) as session rows, shown while nothing runs.
    Q_PROPERTY(QVariantList presenceSessions READ presenceSessions NOTIFY activityChanged)

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
    QVariantMap translations() const;
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
    QString lightFollowingText() const { return m_lightFollowingText; }
    QString lightAgentHint() const { return m_lightAgentHint; }
    QVariantList presenceSessions() const { return m_presenceSessions; }
    QVariantMap claudeHook() const { return m_claudeHook.map; }
    QVariantMap codexHook() const { return m_codexHook.map; }
    QVariantMap diagnostics() const { return m_diagnostics; }
    QVariantMap cli() const { return m_cli; }
    QString debugLogPath() const;
    QVariantMap usage() const { return m_usageMap; }

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
    Q_INVOKABLE void checkCodexHook();
    Q_INVOKABLE void installCodexHook();
    Q_INVOKABLE void uninstallCodexHook();
    Q_INVOKABLE void exportDiagnostics();
    // Shows a file or folder selected in Explorer.
    Q_INVOKABLE void revealPath(const QString &path) const;
    Q_INVOKABLE void openDebugLog() const;
    Q_INVOKABLE void copyDebugLog() const;
    Q_INVOKABLE void installCli();
    Q_INVOKABLE void uninstallCli();
    Q_INVOKABLE void refreshUsage();
    // Local path from a FolderDialog URL, so QML can store it in prefs.codexDataDir.
    Q_INVOKABLE QString localPath(const QUrl &url) const;
    Q_INVOKABLE void quit();

signals:
    void tickChanged();
    void signalNameChanged();
    void activityChanged();
    void claudeHookChanged();
    void codexHookChanged();
    void diagnosticsChanged();
    void cliChanged();
    void usageChanged();
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
    // Alert sounds (FloatingSignalWindowController.evaluateCompletionSound and
    // evaluateActiveGreenPulseSound): a chime when the lamp turns "done", a tick each time the
    // green lamp lights up while an agent works.
    void evaluateSounds();
    // Desktop app presence (pollDesktopAppPresence): every 20 s, 60 s in low-power mode.
    void pollPresence();
    void playSound(const QString &kind, const QString &sound, const QString &cue) const;
    void stopCue(const QString &cue) const;
    // What the Connect page shows for one hook target.
    struct HookUi {
        bool codex = false;
        QString state = QStringLiteral("unchecked");
        QString error;
        QString result; // the last install/uninstall
        QVariantMap map;
    };
    void runHook(HookUi &ui, const QString &action);
    void rebuildHook(HookUi &ui);
    QString hookExePath() const;
    QString claudeRoot() const;
    QString codexHome() const;
    void configureLogging();
    // Re-reads whether the install folder is on PATH; `message`/`tone` report the last action.
    void refreshCli(const QString &message = QString(), const QString &tone = QStringLiteral("neutral"));
    void setDiagnostics(const QVariantMap &state);
    void rebuildUsage();
    QVariantMap usageSide(const asb::usage::Report &report, bool claude) const;
    QString costText(std::optional<double> usd, bool partial) const;
    QString compactTokens(qint64 count) const;
    QStringList usageCodexRoots() const;

    QQmlPropertyMap *m_prefs;
    SignalRuntime *m_runtime = nullptr;
    QVariantList m_sessions;
    QVariantList m_events;
    QVariantMap m_codexConnection;
    asb::light::Selector m_lightSelector;
    asb::light::Selection m_light;
    QString m_lightFollowingText;
    QString m_lightAgentHint;
    QVariantList m_presenceSessions;
    QTimer m_presenceTimer;
    bool m_presenceInFlight = false;
    QString m_liveSignal = QStringLiteral("idle");
    QString m_codexDirOverride;
    QString m_claudeDirOverride;
    HookUi m_claudeHook;
    HookUi m_codexHook{true};
    QVariantMap m_diagnostics;
    QVariantMap m_cli;
    UsageService *m_usage = nullptr;
    QVariantMap m_usageMap;
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
    // Sounds: PlaySound reads the scaled WAV from this buffer while it plays asynchronously.
    mutable QByteArray m_soundBuffer;
    mutable QString m_activeCue; // completion | waiting | "" for a preview
    bool m_soundPrimed = false;   // the state found at start never chimes
    QString m_lastSoundSignature;
    bool m_greenWasLit = false;
};

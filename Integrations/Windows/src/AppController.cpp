#include "AppController.h"

#include "ActivityText.h"
#include "ClaudeHookInstaller.h"
#include "CliPath.h"
#include "DebugLog.h"
#include "Diagnostics.h"
#include "HookAdapters.h"
#include "SignalRuntime.h"
#include "PresenceMonitor.h"
#include "SignalStateFile.h"
#include "SoundFile.h"

#include <QClipboard>
#include <QDateTime>
#include <QOperatingSystemVersion>
#include <QCoreApplication>
#include <QDesktopServices>
#include <QDir>
#include <QFile>
#include <QFont>
#include <QGuiApplication>
#include <QLocale>
#include <QPalette>
#include <QProcess>
#include <QScreen>
#include <QStandardPaths>
#include <QStyleHints>
#include <QSysInfo>
#include <QUrl>
#include <QLoggingCategory>
#include <QPointer>
#include <QThreadPool>
#include <QWindow>

#include <algorithm>

#ifdef Q_OS_WIN
#include <windows.h>
#include <dwmapi.h>
#include <mmsystem.h>
#endif

#ifndef ASB_WINDOWS_VERSION
#define ASB_WINDOWS_VERSION "0.1.0"
#endif

// QT_LOGGING_RULES="asb.sound.debug=true" logs every sound played.
Q_LOGGING_CATEGORY(lcSound, "asb.sound", QtWarningMsg)

namespace {

// QQmlPropertyMap's public constructor is deprecated; subclasses use the two-argument one.
class PrefsMap : public QQmlPropertyMap {
public:
    explicit PrefsMap(QObject *parent) : QQmlPropertyMap(this, parent) {}
};

// Keys mirror the macOS UserDefaults where one exists, so a future settings import
// stays one-to-one.
const QVariantMap &defaultPrefs() {
    static const QVariantMap defaults = {
        {"language", "system"}, {"theme", "system"}, {"currency", "USD"},
        {"glassEnabled", true}, {"glassEffect", "reduced"},
        {"launchAtLogin", false}, {"lowPowerMode", false}, {"showDebugSettings", false},
        {"statusBarEnabled", true}, {"floatingEnabled", true}, {"menuMode", "detailed"},
        {"statusStyle", "trafficLight"}, {"statusLayout", "horizontal"},
        {"dotHorizontalSize", "standard"}, {"lampVerticalSize", "standard"},
        {"floatingLayout", "vertical"}, {"floatingSize", "standard"}, {"floatingScale", 1.0},
        {"floatingX", -1}, {"floatingY", -1},
        {"badgeRunning", true}, {"badgeQuota", true}, {"badgeToken", true},
        // Which corner each floating badge sits in; users move them by dragging.
        {"floatingSignalInfoBadgeCorner", "top-right"}, {"floatingSignalQuotaBadgeCorner", "top-left"},
        {"floatingSignalTokenBadgeCorner", "bottom-left"},
        {"thinkingEffect", "green_fast_flash"}, {"workingEffect", "green_slow_flash"},
        {"needsReviewEffect", "slow_flash"}, {"permissionEffect", "slow_flash"},
        {"blockedEffect", "fast_flash"}, {"doneEffect", "green_steady"},
        {"newZealandMode", false}, {"soundEnabled", true}, {"completionSound", "new_zealand"},
        {"waitingSound", "new_zealand"}, {"soundLevel", "standard"},
        {"autoUpdateCheck", true}, {"lightAgentMode", "following"}, {"showOtherAgentsWhenIdle", true},
        {"usagePlatform", "codex"}, {"fileLogging", false}, {"logLevel", "verbose"},
        {"codexDataDir", ""}};
    return defaults;
}

QString soundFileFor(const QString &kind, const QString &sound) {
    if (sound == "off") return {};
    if (sound == "new_zealand") return kind == "completion" ? "completion-signal-nz.wav" : "waiting-signal-nz.wav";
    if (kind == "completion") return sound == "ai_glow" ? "completion-ai-glow.wav" : "completion-ai-aurora.wav";
    return sound == "ai_orbit" ? "waiting-ai-orbit.wav" : "waiting-ai-tick.wav";
}


QList<asb::codex::Root> codexRoots(const QString &selectedPath) {
    return asb::codex::activityRoots(QDir::homePath(), qEnvironmentVariable("CODEX_HOME"), selectedPath);
}

QString shortTime(qint64 ms) {
    return QLocale::system().toString(QDateTime::fromMSecsSinceEpoch(ms).time(), QLocale::ShortFormat);
}

} // namespace

AppController::~AppController() {
    // Stop the monitor thread while this object (its signal receiver) is still whole.
    delete m_runtime;
    m_runtime = nullptr;
#ifdef Q_OS_WIN
    PlaySoundW(nullptr, nullptr, 0); // before m_soundBuffer goes away
#endif
}

AppController::AppController(const QString &settingsFile, const QString &captureDir, bool live,
                             const QString &codexDirOverride, const QString &claudeDirOverride, QObject *parent)
    : QObject(parent), m_prefs(new PrefsMap(this)), m_captureDir(captureDir) {
    m_codexDirOverride = codexDirOverride;
    m_claudeDirOverride = claudeDirOverride;
    m_settings = settingsFile.isEmpty()
        ? std::make_unique<QSettings>(QSettings::IniFormat, QSettings::UserScope, "AgentSignalBar", "AgentSignalBar")
        : std::make_unique<QSettings>(settingsFile, QSettings::IniFormat);
    const QVariantMap &defaults = defaultPrefs();
    for (auto it = defaults.cbegin(); it != defaults.cend(); ++it) {
        QVariant value = m_settings->value(it.key(), it.value());
        value.convert(it.value().metaType());
        m_prefs->insert(it.key(), value);
    }
    connect(m_prefs, &QQmlPropertyMap::valueChanged, this, &AppController::onPrefChanged);
    configureLogging();
    if (asb::debuglog::enabled()) asb::debuglog::append("app started " + version());
    connect(QGuiApplication::styleHints(), &QStyleHints::colorSchemeChanged, this, &AppController::themeChanged);
    connect(&m_timer, &QTimer::timeout, this, [this] {
        // Same clock as MenuBarStatusModel: skip frames, then advance by the cadence step.
        const asb::TickCadence cadence = asb::tickCadence(signalName(), effectCustomization(),
                                                          m_prefs->value("lowPowerMode").toBool(),
                                                          m_prefs->value("newZealandMode").toBool());
        if (++m_frameSkip < cadence.framesPerAdvance) return;
        m_frameSkip = 0;
        m_tick += cadence.tickAdvance;
        emit tickChanged();
        evaluateSounds(); // the flash tick follows the green lamp
    });
    restartTimer();
    connect(this, &AppController::languageChanged, this, &AppController::rebuildActivity);
    if (live) {
        // Capture runs keep their own state file next to the screenshots, unless the
        // environment names one explicitly (fixture runs seed it with hook events).
        QString statePath = asb::SignalStateFile::defaultPath();
        if (!m_captureDir.isEmpty() && !asb::SignalStateFile::hasExplicitLocation()) {
            statePath = m_captureDir + "/status.json";
            QFile::remove(statePath);
        }
        m_runtime = new SignalRuntime(statePath, this);
        connect(m_runtime, &SignalRuntime::changed, this, &AppController::rebuildActivity);
        const bool overridden = !m_codexDirOverride.isEmpty();
        // Like the Mac app: status.json carries the state across restarts, so the first poll
        // only primes the rollout cursors. A fixture directory replays its recent history.
        m_runtime->start(overridden ? asb::codex::rootsForDirectory(QDir::homePath(), m_codexDirOverride)
                                    : codexRoots(m_prefs->value("codexDataDir").toString()),
                         m_prefs->value("lowPowerMode").toBool(), overridden);
        // Capture runs stay deterministic: no scan of the apps running on this machine.
        if (m_captureDir.isEmpty()) {
            connect(&m_presenceTimer, &QTimer::timeout, this, &AppController::pollPresence);
            m_presenceTimer.start(m_prefs->value("lowPowerMode").toBool() ? 60000 : 20000);
            QTimer::singleShot(0, this, &AppController::pollPresence);
        }
    }
    rebuildActivity();
    refreshCli();
    // Capture runs never look at the real agent settings.
    if (m_captureDir.isEmpty()) {
        checkClaudeHook();
        checkCodexHook();
    } else {
        rebuildHook(m_claudeHook);
        rebuildHook(m_codexHook);
    }
}

QString AppController::hookExePath() const {
#ifdef Q_OS_WIN
    return QCoreApplication::applicationDirPath() + "/agent-signal.exe";
#else
    return QCoreApplication::applicationDirPath() + "/agent-signal";
#endif
}

QString AppController::claudeRoot() const {
    if (!m_claudeDirOverride.isEmpty()) return QDir::cleanPath(m_claudeDirOverride);
    return asb::hooks::ClaudeHookInstaller::defaultClaudeRoot(QDir::homePath(), qEnvironmentVariable("CLAUDE_CONFIG_DIR"));
}

// The Codex hooks go to the Codex home the monitor reads: --codex-dir, the chosen data
// directory, CODEX_HOME or %USERPROFILE%\.codex (as NativeHookInstaller's selectedCodexPath).
QString AppController::codexHome() const {
    return asb::codex::primaryCodexHome(QDir::homePath(), qEnvironmentVariable("CODEX_HOME"),
                                        m_codexDirOverride.isEmpty() ? m_prefs->value("codexDataDir").toString()
                                                                     : m_codexDirOverride);
}

void AppController::checkClaudeHook() { runHook(m_claudeHook, "check"); }
void AppController::installClaudeHook() { runHook(m_claudeHook, "install"); }
void AppController::uninstallClaudeHook() { runHook(m_claudeHook, "uninstall"); }
void AppController::checkCodexHook() { runHook(m_codexHook, "check"); }
void AppController::installCodexHook() { runHook(m_codexHook, "install"); }
void AppController::uninstallCodexHook() { runHook(m_codexHook, "uninstall"); }

void AppController::runHook(HookUi &ui, const QString &action) {
    if (!m_captureDir.isEmpty()) return;
    using asb::hooks::ClaudeHookInstaller;
    const ClaudeHookInstaller installer = ui.codex
        ? ClaudeHookInstaller(codexHome(), hookExePath(), ClaudeHookInstaller::Target::Codex)
        : ClaudeHookInstaller(claudeRoot(), hookExePath());
#ifndef Q_OS_WIN
    // Development builds must not rewrite this machine's real agent settings.
    if (action != "check" && (ui.codex ? m_codexDirOverride : m_claudeDirOverride).isEmpty()) {
        ui.result = ui.codex ? text("开发版只有在指定 --codex-dir 时才会修改 Codex 设置。",
                                    "Development builds change Codex settings only with --codex-dir.")
                             : text("开发版只有在指定 --claude-dir 时才会修改 Claude 设置。",
                                    "Development builds change Claude settings only with --claude-dir.");
        rebuildHook(ui);
        return;
    }
#endif
    const asb::hooks::HookReport report =
        action == "install" ? installer.install() : action == "uninstall" ? installer.uninstall() : installer.check();
    ui.error = report.ok ? QString() : report.error;
    if (!report.ok) {
        ui.state = "error";
    } else if (action == "uninstall") {
        ui.state = "missing";
    } else if (report.configured) {
        ui.state = "configured";
    } else {
        const int total = int((ui.codex ? asb::hooks::codex::installedEvents() : asb::hooks::claude::installedEvents()).size());
        ui.state = report.missing.size() == total && report.stale.isEmpty() ? "missing" : "repair";
    }
    if (action == "check") {
        ui.result.clear();
    } else if (report.ok) {
        ui.result = action == "install"
            ? (report.changed ? text("已安装 Hook。", "Hooks installed.") : text("Hook 已是最新，无需修改。", "Hooks already up to date."))
            : (report.changed ? text("已卸载 Hook。", "Hooks removed.") : text("没有需要卸载的 Hook。", "No hooks to remove."));
        if (!report.backup.isEmpty()) ui.result += text(" 备份：", " Backup: ") + report.backup;
    } else {
        ui.result.clear();
    }
    asb::debuglog::append(QString(ui.codex ? "codex" : "claude") + " hooks " + action + ": "
                          + (report.ok ? ui.state + (report.changed ? " (file changed)" : "") : "error " + report.error));
    rebuildHook(ui);
}

void AppController::rebuildHook(HookUi &ui) {
    // MenuBarStatusModel.claudeConnectionMessage. Codex events also come from its session
    // logs, so the Codex message names no "last hook event".
    QString message;
    QString tone = "neutral";
    if (m_paused) {
        message = text("监控已暂停", "Monitoring paused");
    } else if (ui.state == "error") {
        message = text("无法检查 Hook：", "Cannot check hooks: ") + ui.error;
        tone = "critical";
    } else if (ui.state == "unchecked") {
        message = text("尚未检查 Hook", "Hooks have not been checked");
    } else if (ui.state != "configured") {
        message = ui.codex ? text("Hook 未安装或需要修复。不装也可以：Codex 状态仍会从会话日志读取。",
                                  "Hooks are missing or need repair. They are optional: Codex state still comes from its session logs.")
                           : text("Hook 未配置或需要修复，请点击安装。", "Hooks are missing or need repair. Click Install.");
        tone = ui.state == "repair" ? "caution" : "neutral";
    } else if (ui.codex) {
        message = text("Hook 已配置。新开的 Codex 会话会立即上报权限请求和工具步骤。",
                       "Hooks configured. New Codex sessions report permission requests and tool steps right away.");
        tone = "positive";
    } else if (const auto latest = m_runtime ? m_runtime->lastEventAt("claude") : std::nullopt) {
        message = text("Hook 已配置 · 最近事件：", "Hooks configured · Last event: ")
            + QLocale::system().toString(QDateTime::fromMSecsSinceEpoch(*latest), QLocale::ShortFormat);
        tone = "positive";
    } else {
        message = text("Hook 已配置，尚未收到事件。请新建 Claude Code 会话并发送任务。",
                       "Hooks configured; no event received yet. Start a new Claude Code session and send a task.");
        tone = "positive";
    }
#ifdef Q_OS_WIN
    const bool canModify = m_captureDir.isEmpty();
#else
    const bool canModify = m_captureDir.isEmpty() && !(ui.codex ? m_codexDirOverride : m_claudeDirOverride).isEmpty();
#endif
    const QString file = ui.codex ? codexHome() + "/hooks.json" : claudeRoot() + "/settings.json";
    const QVariantMap hook{
        {"state", ui.state}, {"message", message}, {"tone", tone},
        {"settingsPath", QDir::toNativeSeparators(file)}, {"canModify", canModify},
        {"result", ui.result},
        {"stateFile", m_runtime ? QDir::toNativeSeparators(m_runtime->stateFilePath()) : QString()}};
    if (hook != ui.map) {
        ui.map = hook;
        if (ui.codex) emit codexHookChanged();
        else emit claudeHookChanged();
    }
}

QString AppController::signalName() const {
    if (!m_debugSignal.isEmpty()) return m_debugSignal;
    if (m_paused) return QStringLiteral("paused");
    return m_runtime ? m_liveSignal : m_demoSignal;
}

void AppController::rebuildActivity() {
    rebuildHook(m_claudeHook); // its message names the latest Claude event
    rebuildHook(m_codexHook);  // and both say when monitoring is paused
    if (!m_runtime) return;
    const bool zh = language() == "zh";
    const auto sessionRow = [zh](const asb::SessionStatus &s) {
        return QVariantMap{{"id", s.sessionID}, {"title", asb::text::sessionTitle(s, zh)},
                           {"agent", asb::text::friendlyAgentName(s.agent, zh)},
                           {"pill", asb::text::runtimeLabel(s, zh)},
                           {"detail", asb::text::sessionSubtitle(s, zh)},
                           {"state", asb::displayStateKey(asb::displayState(s.signal))},
                           {"time", shortTime(s.updatedAt)}};
    };
    QVariantList sessions;
    for (const asb::SessionStatus &s : m_runtime->visibleSessions()) sessions.append(sessionRow(s));
    QVariantList presence;
    for (const asb::SessionStatus &s : asb::display::visibleDesktopPresenceSessions(m_runtime->display().sessions, 6))
        presence.append(sessionRow(s));
    QVariantList events;
    for (const asb::SignalEvent &e : m_runtime->recentEvents()) {
        events.append(QVariantMap{{"title", asb::text::eventTitle(e, zh)}, {"detail", asb::text::eventSubtitle(e, zh)},
                                  {"state", asb::displayStateKey(asb::displayState(e.signal))},
                                  {"time", shortTime(e.updatedAt)}});
    }
    const asb::codex::ConnectionHealth &health = m_runtime->connection();
    const auto lastActivity = m_runtime->lastActivityAt();
    // MenuBarStatusModel.codexConnectionMessage
    QString message;
    QString tone = "neutral";
    if (m_paused) {
        message = text("监控已暂停", "Monitoring paused");
    } else if (!m_runtime->hasPolled()) {
        message = text("正在检查会话目录…", "Checking session directories…");
    } else if (!health.unreadable.isEmpty()) {
        message = text("无法读取目录：", "Cannot read directory: ") + health.unreadable.join(", ");
        tone = "critical";
    } else if (health.existingRoots == 0) {
        message = text("未找到会话目录。请启动 Codex 任务或选择数据目录。",
                       "No session directory found. Start a Codex task or select its data directory.");
        tone = "caution";
    } else if (health.recentFiles == 0) {
        message = text("尚未找到会话日志。请在 Codex 中发起任务。", "No session logs yet. Start a task in Codex.");
        tone = "caution";
    } else if (lastActivity) {
        message = text("已连接 · 最近事件：", "Connected · Last event: ")
            + QLocale::system().toString(QDateTime::fromMSecsSinceEpoch(*lastActivity), QLocale::ShortFormat);
        tone = "positive";
    } else {
        message = text("已找到日志，等待新事件。请在 Codex 中发起任务。",
                       "Logs found; waiting for an event. Start a task in Codex.");
        tone = "positive";
    }
    const QVariantMap connection{
        {"message", message}, {"tone", tone},
        {"home", QDir::toNativeSeparators(asb::codex::primaryCodexHome(
                     QDir::homePath(), qEnvironmentVariable("CODEX_HOME"),
                     m_codexDirOverride.isEmpty() ? m_prefs->value("codexDataDir").toString() : m_codexDirOverride))},
        {"roots", health.roots}, {"existingRoots", health.existingRoots}, {"recentFiles", health.recentFiles},
        {"unreadable", health.unreadable}, {"polled", m_runtime->hasPolled()},
        {"lastActivity", lastActivity ? shortTime(*lastActivity) : QString()}};

    // The lamp shows the followed or chosen agents only (signalLightAgentScopes).
    const QString mode = m_prefs->value("lightAgentMode").toString();
    const bool following = mode == "following" || asb::light::scopesForPreference(mode).isEmpty();
    const QStringList selected = asb::light::scopesForPreference(mode);
    m_light = m_lightSelector.select(m_runtime->display(), following, selected,
                                     m_prefs->value("showOtherAgentsWhenIdle").toBool());
    const QString followingText = asb::light::followingText(m_light, following, zh);
    const QString hint = asb::light::unavailableHint(m_light, selected, following, m_runtime->visibleSessions(), zh);

    const bool listsChanged = sessions != m_sessions || events != m_events || connection != m_codexConnection
        || followingText != m_lightFollowingText || hint != m_lightAgentHint || presence != m_presenceSessions;
    m_sessions = sessions;
    m_presenceSessions = presence;
    m_events = events;
    m_codexConnection = connection;
    m_lightFollowingText = followingText;
    m_lightAgentHint = hint;
    if (listsChanged) emit activityChanged();
    const QString aggregate = m_light.aggregate;
    if (aggregate != m_liveSignal) {
        asb::debuglog::append("signal " + m_liveSignal + " -> " + aggregate + " (" + m_lightFollowingText + ')');
        m_liveSignal = aggregate;
        emit signalNameChanged();
    }
    evaluateSounds(); // the completion chime follows the snapshot
}

void AppController::pollPresence() {
    if (!m_runtime || !m_presenceTimer.isActive()) return;
    if (m_paused) {
        m_runtime->setPresence({}); // shouldPollPlatformPresence: nothing while paused
        return;
    }
    if (m_presenceInFlight) return;
    m_presenceInFlight = true;
    // Enumerating processes and windows takes a few milliseconds; keep it off the GUI thread.
    QPointer<AppController> self(this);
    QThreadPool::globalInstance()->start([self] {
        const QList<asb::SessionStatus> sessions =
            asb::presence::detect(asb::presence::runningProcesses(), QDateTime::currentMSecsSinceEpoch());
        QMetaObject::invokeMethod(QCoreApplication::instance(), [self, sessions] {
            if (!self) return;
            self->m_presenceInFlight = false;
            if (self->m_runtime && !self->m_paused) self->m_runtime->setPresence(sessions);
        }, Qt::QueuedConnection);
    });
}

void AppController::checkCodexConnection() {
    if (m_runtime) m_runtime->pollNow();
}

QString AppController::localPath(const QUrl &url) const { return QDir::toNativeSeparators(url.toLocalFile()); }

QString AppController::displayState() const { return asb::displayStateKey(asb::displayState(signalName())); }

QString AppController::displayStateTitle() const {
    switch (asb::displayState(signalName())) {
    case asb::DisplayState::Ready: return text("空闲", "Idle");
    case asb::DisplayState::Active: return text("工作中", "Working");
    case asb::DisplayState::Completed: return text("已完成", "Done");
    case asb::DisplayState::NeedsReview: return text("需要查看", "Needs Review");
    case asb::DisplayState::Permission: return text("等待授权", "Waiting for Permission");
    case asb::DisplayState::Blocked: return text("阻塞/失败", "Blocked");
    case asb::DisplayState::Stale: return text("状态不可信", "Stale");
    case asb::DisplayState::Paused: return text("已暂停", "Paused");
    }
    return {};
}

QString AppController::language() const {
    const QString pref = m_prefs->value("language").toString();
    if (pref == "zh-Hans" || pref == "zh-Hant") return "zh";
    if (pref == "system") return QLocale::system().language() == QLocale::Chinese ? "zh" : "en";
    return "en";
}

bool AppController::dark() const {
    const QString theme = m_prefs->value("theme").toString();
    if (theme == "dark") return true;
    if (theme == "light") return false;
    return QGuiApplication::styleHints()->colorScheme() == Qt::ColorScheme::Dark;
}

QColor AppController::accent() const {
#ifdef Q_OS_WIN
    // QPalette::Accent follows the system's light/dark mode, so a light theme on a dark system
    // got the dark-mode accent (a light tint) on white: invisible icons and selections. Take the
    // shade Windows 11 itself uses for the app's own theme from the accent palette instead:
    // AccentLight2 in dark mode, AccentDark1 in light mode (entries 1 and 4, RGBA each).
    BYTE palette[32] = {};
    DWORD size = sizeof(palette);
    if (RegGetValueW(HKEY_CURRENT_USER, L"Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Accent",
                     L"AccentPalette", RRF_RT_REG_BINARY, nullptr, palette, &size) == ERROR_SUCCESS
        && size >= sizeof(palette)) {
        const BYTE *c = palette + (dark() ? 1 : 4) * 4;
        return QColor(c[0], c[1], c[2]);
    }
#endif
    return QGuiApplication::palette().color(QPalette::Accent);
}

QString AppController::platform() const {
#ifdef Q_OS_WIN
    return "windows";
#elif defined(Q_OS_MACOS)
    return "macos";
#else
    return "linux";
#endif
}

QString AppController::version() const { return QStringLiteral(ASB_WINDOWS_VERSION); }

QString AppController::uiFont() const {
#ifdef Q_OS_WIN
    return language() == "zh" ? "Microsoft YaHei UI" : "Segoe UI Variable Text";
#else
    return QGuiApplication::font().family();
#endif
}

bool AppController::supportsBackdrop() const {
#ifdef Q_OS_WIN
    return QOperatingSystemVersion::current() >= QOperatingSystemVersion(QOperatingSystemVersion::Windows, 10, 0, 22621);
#else
    return false;
#endif
}

asb::EffectCustomization AppController::effectCustomization() const {
    asb::EffectCustomization c;
    const auto pref = [this](const char *key) { return m_prefs->value(key).toString(); };
    c.thinkingEffect = asb::activeEffectFromKey(pref("thinkingEffect")).value_or(c.thinkingEffect);
    c.activeEffect = asb::activeEffectFromKey(pref("workingEffect")).value_or(c.activeEffect);
    c.needsReviewEffect = asb::alertEffectFromKey(pref("needsReviewEffect")).value_or(c.needsReviewEffect);
    c.permissionEffect = asb::alertEffectFromKey(pref("permissionEffect")).value_or(c.permissionEffect);
    c.blockedEffect = asb::alertEffectFromKey(pref("blockedEffect")).value_or(c.blockedEffect);
    c.completedEffect = asb::completedEffectFromKey(pref("doneEffect")).value_or(c.completedEffect);
    return c;
}

QString AppController::text(const QString &zhHans, const QString &english) const {
    return language() == "zh" ? zhHans : english;
}

double AppController::lampIntensity(const QString &color, const QString &signal, int tick, bool allLightsOn) const {
    const auto lamp = asb::lampColorFromKey(color);
    return lamp ? asb::intensity(*lamp, signal, tick, allLightsOn, effectCustomization()) : 0;
}

double AppController::lampScale(const QString &color, const QString &signal, int tick, bool allLightsOn,
                                const QString &style) const {
    const auto lamp = asb::lampColorFromKey(color);
    if (!lamp) return 1;
    const auto custom = effectCustomization();
    const double base = asb::scale(*lamp, signal, tick, allLightsOn, custom);
    const double value = asb::intensity(*lamp, signal, tick, allLightsOn, custom);
    return asb::visualLampScale(base, value,
                                style == "macOS" ? asb::VisualStyle::MacOS : asb::VisualStyle::TrafficLight,
                                asb::BreathingStrength::Pronounced);
}

QString AppController::dominantLamp(const QString &signal, int tick) const {
    const auto color = asb::dominantColor(signal, tick, false, effectCustomization());
    if (!color) return QString();
    return *color == asb::LampColor::Red ? "red" : *color == asb::LampColor::Yellow ? "yellow" : "green";
}

QPoint AppController::popupPosition(int width, int height, const QString &placement) const {
    // Anchor to where the tray icon was clicked. The icon rectangle alone is not enough: on
    // Windows 11 a new icon sits in the hidden-icons flyout, and Shell_NotifyIconGetRect then
    // reports the "^" chevron on the taskbar, not the icon that was clicked. Without a click
    // (capture runs) fall back to the icon, then to the primary screen's bottom-right corner.
    const bool clickOnIcon = m_trayClick && m_trayGeometry.isValid() && m_trayGeometry.contains(*m_trayClick);
    std::optional<QPoint> anchor = m_trayClick;
    if (clickOnIcon || (!anchor && m_trayGeometry.isValid())) anchor = m_trayGeometry.center();
    const QScreen *screen = popupScreen();
    const QRect full = screen->geometry();
    const QRect avail = screen->availableGeometry();
    const int gap = 8;
    enum class Edge { Bottom, Top, Left, Right };
    const Edge taskbar = avail.top() > full.top()     ? Edge::Top
                       : avail.left() > full.left()   ? Edge::Left
                       : avail.right() < full.right() ? Edge::Right
                                                      : Edge::Bottom;

    if (placement == QLatin1String("menu") && m_trayClick) {
        // A native context menu: one corner at the click point, opening away from the taskbar
        // and towards the side with room. Like those menus it may overlap the taskbar.
        const QPoint c = *m_trayClick;
        int x = taskbar == Edge::Right ? c.x() - width : c.x();
        if (taskbar != Edge::Left && x + width > full.left() + full.width()) x = c.x() - width;
        int y = taskbar == Edge::Top ? c.y() : c.y() - height;
        if (y < full.top()) y = c.y(); // no room above: open downwards
        x = std::clamp(x, full.left(), std::max(full.left(), full.left() + full.width() - width));
        y = std::clamp(y, full.top(), std::max(full.top(), full.top() + full.height() - height));
        return {x, y};
    }

    // A flyout: just off the taskbar, centred on the icon (or on the click in the flyout).
    int x = avail.right() - width - gap;
    int y = avail.bottom() - height - gap;
    if (anchor) {
        switch (taskbar) {
        case Edge::Bottom: x = anchor->x() - width / 2; break;
        case Edge::Top: x = anchor->x() - width / 2; y = avail.top() + gap; break;
        case Edge::Left: x = avail.left() + gap; y = anchor->y() - height / 2; break;
        case Edge::Right: x = avail.right() - width - gap; y = anchor->y() - height / 2; break;
        }
    }
    x = std::clamp(x, avail.left() + gap, std::max(avail.left() + gap, avail.right() - width - gap));
    y = std::clamp(y, avail.top() + gap, std::max(avail.top() + gap, avail.bottom() - height - gap));
    return {x, y};
}

QScreen *AppController::popupScreen() const {
    const bool known = m_trayClick || m_trayGeometry.isValid();
    QScreen *screen = known ? QGuiApplication::screenAt(m_trayClick.value_or(m_trayGeometry.center())) : nullptr;
    return screen ? screen : QGuiApplication::primaryScreen();
}

int AppController::popupMaxHeight() const {
    // The work area of the clicked screen, less the gap above and below: on a 1080p screen at
    // 125 % or 150 % the system menu and the card panel are taller than that.
    return std::max(240, popupScreen()->availableGeometry().height() - 16);
}

QPoint AppController::badgePanelPosition(int badgeX, int badgeY, int badgeSize, int width, int height) const {
    // FloatingSignal{Info,Quota,Token}PanelAnchor.position (macOS): the panel window sits above
    // the badge, its right edge 4 pt past the badge's and its bottom 2 pt below the badge's top,
    // and draws its surface inside an 8 pt margin. The visible panel therefore ends 4 pt inside
    // the badge's right edge and 6 pt above it; this window has no margin, so place it there.
    // Kept inside the work area of the badge's own screen (screens left of or above the primary
    // have negative coordinates, and Qt leaves gaps between scaled screens).
    const QRect badge(badgeX, badgeY, badgeSize, badgeSize);
    QScreen *screen = QGuiApplication::screenAt(badge.center());
    if (!screen) screen = QGuiApplication::primaryScreen();
    const QRect avail = screen->availableGeometry();
    const int margin = 8;
    const int x = badge.left() + badge.width() - 4 - width;
    const int y = badge.top() - 6 - height;
    return {std::clamp(x, avail.left() + margin, std::max(avail.left() + margin, avail.left() + avail.width() - width - margin)),
            std::clamp(y, avail.top() + margin, std::max(avail.top() + margin, avail.top() + avail.height() - height - margin))};
}

QPoint AppController::floatingPosition(int x, int y, int width, int height) const {
    const QRect saved(x, y, width, height);
    // (-1, -1) means never placed. Any other position is kept while a screen still shows the
    // lamp, including negative ones on a monitor left of or above the primary.
    if (x != -1 || y != -1) {
        for (QScreen *screen : QGuiApplication::screens()) {
            if (screen->availableGeometry().intersects(saved)) return saved.topLeft();
        }
    }
    const QRect avail = QGuiApplication::primaryScreen()->availableGeometry();
    return {avail.right() - width - 40, avail.bottom() - height - 80};
}

void AppController::openSettings(const QString &page) { emit settingsRequested(page); }
void AppController::showPanel() { emit panelRequested(); }
void AppController::showSystemMenu() { emit systemMenuRequested(); }

void AppController::togglePause() {
    m_paused = !m_paused;
    if (m_runtime) m_runtime->setPaused(m_paused);
    pollPresence(); // clears the open apps while paused, looks again on resume
    rebuildActivity();
    emit signalNameChanged();
}

void AppController::setDebugSignal(const QString &signal) {
    m_debugSignal = signal.isEmpty() ? QString() : asb::normalizedSignal(signal).value_or(QString());
    asb::debuglog::append(m_debugSignal.isEmpty() ? QStringLiteral("debug light cleared") : "debug light signal " + m_debugSignal);
    emit signalNameChanged();
}

// --- Logs, diagnostics, CLI --------------------------------------------------------------

QString AppController::debugLogPath() const { return QDir::toNativeSeparators(asb::debuglog::path()); }

void AppController::configureLogging() {
    // Capture runs stay out of the user's log.
    asb::debuglog::configure(m_captureDir.isEmpty() && m_prefs->value("fileLogging").toBool(),
                             m_prefs->value("logLevel").toString());
}

void AppController::openDebugLog() const {
    asb::debuglog::ensureExists();
    QDesktopServices::openUrl(QUrl::fromLocalFile(asb::debuglog::path()));
}

void AppController::copyDebugLog() const { QGuiApplication::clipboard()->setText(asb::debuglog::readAll()); }

void AppController::revealPath(const QString &path) const {
    if (path.isEmpty() || !QFileInfo::exists(path)) return;
#ifdef Q_OS_WIN
    QProcess explorer;
    explorer.setProgram("explorer.exe");
    explorer.setNativeArguments("/select,\"" + QDir::toNativeSeparators(path) + '"');
    explorer.startDetached();
#else
    QDesktopServices::openUrl(QUrl::fromLocalFile(QFileInfo(path).absolutePath()));
#endif
}

void AppController::setDiagnostics(const QVariantMap &state) {
    if (state == m_diagnostics) return;
    m_diagnostics = state;
    emit diagnosticsChanged();
}

void AppController::exportDiagnostics() {
    if (m_diagnostics.value("running").toBool() || !m_captureDir.isEmpty()) return;
    setDiagnostics({{"running", true}, {"message", text("正在导出诊断…", "Exporting diagnostics…")}, {"tone", "neutral"}});
    asb::diagnostics::Request request;
    request.outputRoot = QFileInfo(asb::debuglog::path()).absolutePath() + "/Diagnostics";
    request.cliExe = hookExePath();
    request.stateFile = m_runtime ? m_runtime->stateFilePath() : asb::SignalStateFile::defaultPath();
    request.settingsFile = m_settings->fileName();
    request.logFile = asb::debuglog::path();
    request.systemLines = {
        "Agent Signal Bar for Windows " + version(),
        "app: " + QDir::toNativeSeparators(QCoreApplication::applicationFilePath()),
        "os: " + QSysInfo::prettyProductName() + " (kernel " + QSysInfo::kernelVersion() + ", "
            + QSysInfo::currentCpuArchitecture() + ')',
        "qt: " + QString::fromLatin1(qVersion()),
        "language: " + language() + ", locale: " + QLocale::system().name(),
        "live data: " + QString(m_runtime ? "yes" : "no") + ", paused: " + (m_paused ? "yes" : "no"),
        "codex home: " + QDir::toNativeSeparators(codexHome()),
        "claude root: " + QDir::toNativeSeparators(claudeRoot()),
        "light: " + m_liveSignal + " (" + m_lightFollowingText + ')',
        "file logging: " + QString(asb::debuglog::enabled() ? "on" : "off") + " (" + m_prefs->value("logLevel").toString() + ')'};
    asb::debuglog::append("diagnostics export started");
    QPointer<AppController> self(this);
    QThreadPool::globalInstance()->start([self, request] {
        const asb::diagnostics::Result result = asb::diagnostics::exportBundle(request);
        QMetaObject::invokeMethod(qApp, [self, result] {
            if (!self) return;
            if (!result.ok) {
                self->setDiagnostics({{"running", false}, {"tone", "critical"},
                                      {"message", self->text("导出失败：", "Export failed: ") + result.error}});
                asb::debuglog::append("diagnostics export failed: " + result.error);
                return;
            }
            const QString shown = result.archive.isEmpty() ? result.folder : result.archive;
            QString message = self->text("诊断已导出：", "Diagnostics exported: ") + shown;
            if (result.archive.isEmpty())
                message += self->text("（无法压缩，已保留文件夹）", " (could not zip; the folder is kept)");
            self->setDiagnostics({{"running", false}, {"tone", "positive"}, {"message", message},
                                  {"folder", result.folder}, {"archive", result.archive}});
            asb::debuglog::append("diagnostics exported: " + shown);
            self->revealPath(shown); // like macOS: select the archive in the file manager
        });
    });
}

void AppController::refreshCli(const QString &message, const QString &tone) {
    const QString directory = QDir::toNativeSeparators(QCoreApplication::applicationDirPath());
    const auto user = asb::clipath::userPath();
    const bool installed = asb::clipath::contains(user.value_or(QString()), directory, asb::clipath::expandEnvironment)
        || asb::clipath::contains(asb::clipath::systemPath(), directory, asb::clipath::expandEnvironment);
#ifdef Q_OS_WIN
    // A temporary folder would leave a dead PATH entry behind; capture runs change nothing.
    const bool canModify = m_captureDir.isEmpty() && user.has_value() && QFileInfo(hookExePath()).isFile()
        && !asb::hooks::ClaudeHookInstaller::isTemporaryLocation(hookExePath());
#else
    const bool canModify = false;
#endif
    QString note = message;
    QString noteTone = tone;
    if (note.isEmpty() && !canModify && m_captureDir.isEmpty()) {
        note = !QFileInfo(hookExePath()).isFile() ? text("找不到 agent-signal.exe。", "agent-signal.exe not found.")
             : text("程序在临时文件夹中运行，请先安装到固定位置。", "Running from a temporary folder; install the app first.");
        noteTone = "caution";
    }
    const QVariantMap state{{"installed", installed}, {"directory", directory}, {"canModify", canModify},
                            {"message", note}, {"tone", noteTone}};
    if (state != m_cli) {
        m_cli = state;
        emit cliChanged();
    }
}

void AppController::installCli() {
    if (!m_cli.value("canModify").toBool()) return;
    const QString directory = m_cli.value("directory").toString();
    const auto user = asb::clipath::userPath();
    if (!user) return refreshCli(text("无法读取用户 PATH。", "Cannot read the user PATH."), "critical");
    if (asb::clipath::contains(*user, directory, asb::clipath::expandEnvironment))
        return refreshCli(text("已在 PATH 中：", "Already on PATH: ") + directory, "positive");
    QString error;
    if (!asb::clipath::setUserPath(asb::clipath::withDirectory(*user, directory, true, asb::clipath::expandEnvironment), &error))
        return refreshCli(text("安装失败：", "Install failed: ") + error, "critical");
    asb::debuglog::append("cli added to PATH: " + directory);
    refreshCli(text("已加入 PATH：", "Added to PATH: ") + directory
                   + text("。新开的终端可以直接运行 agent-signal。", ". New terminals can run agent-signal."),
               "positive");
}

void AppController::uninstallCli() {
    if (!m_cli.value("canModify").toBool()) return;
    const QString directory = m_cli.value("directory").toString();
    const auto user = asb::clipath::userPath();
    if (!user) return refreshCli(text("无法读取用户 PATH。", "Cannot read the user PATH."), "critical");
    if (!asb::clipath::contains(*user, directory, asb::clipath::expandEnvironment))
        return refreshCli(text("用户 PATH 中没有这个文件夹。", "This folder is not on the user PATH."), "neutral");
    QString error;
    if (!asb::clipath::setUserPath(asb::clipath::withDirectory(*user, directory, false, asb::clipath::expandEnvironment), &error))
        return refreshCli(text("移除失败：", "Remove failed: ") + error, "critical");
    asb::debuglog::append("cli removed from PATH: " + directory);
    refreshCli(text("已从 PATH 移除。", "Removed from PATH."), "neutral");
}

void AppController::setDemoSignal(const QString &signal) {
    if (const auto normalized = asb::normalizedSignal(signal)) {
        m_demoSignal = *normalized;
        emit signalNameChanged();
    }
}

void AppController::copyText(const QString &text) const { QGuiApplication::clipboard()->setText(text); }

void AppController::openUrl(const QString &url) const { QDesktopServices::openUrl(QUrl(url)); }

void AppController::previewSound(const QString &kind, const QString &sound) const {
    // Previews play whatever the sound switches say, at the chosen volume (macOS preview()).
    playSound(kind, sound, QString());
}

void AppController::playSound(const QString &kind, const QString &sound, const QString &cue) const {
    const QString name = soundFileFor(kind, sound);
    if (name.isEmpty()) return;
    QFile file(":/sounds/" + name);
    if (!file.open(QIODevice::ReadOnly)) return;
    const double volume = asb::sound::volume(m_prefs->value("soundLevel").toString());
    qCDebug(lcSound) << "play" << (cue.isEmpty() ? QStringLiteral("preview") : cue) << name << "volume" << volume
                     << "signal" << signalName() << "tick" << m_tick;
#ifdef Q_OS_WIN
    PlaySoundW(nullptr, nullptr, 0); // stop first: the playing sound may still read the old buffer
    m_soundBuffer = asb::sound::scaledWav(file.readAll(), volume);
    PlaySoundW(reinterpret_cast<LPCWSTR>(m_soundBuffer.constData()), nullptr, SND_MEMORY | SND_ASYNC | SND_NODEFAULT);
#elif defined(Q_OS_MACOS)
    // afplay needs a real file; the bundled resource is copied out once.
    const QString dir = QStandardPaths::writableLocation(QStandardPaths::CacheLocation) + "/sounds";
    QDir().mkpath(dir);
    const QString path = dir + "/" + name;
    if (!QFile::exists(path)) QFile::copy(file.fileName(), path);
    QProcess::startDetached("/usr/bin/afplay", {"-v", QString::number(volume), path});
#else
    Q_UNUSED(volume);
#endif
    m_activeCue = cue;
}

void AppController::stopCue(const QString &cue) const {
    if (cue.isEmpty() || m_activeCue != cue) return; // a preview or the other cue keeps playing
#ifdef Q_OS_WIN
    PlaySoundW(nullptr, nullptr, 0);
#endif
    m_activeCue.clear();
}

void AppController::evaluateSounds() {
    // isSignalSoundSurfaceEnabled: the tray icon or the floating lamp is shown. Capture runs
    // stay silent.
    const bool surface = m_prefs->value("statusBarEnabled").toBool() || m_prefs->value("floatingEnabled").toBool();
    const bool enabled = m_captureDir.isEmpty() && surface && m_prefs->value("soundEnabled").toBool();
    const QString signal = signalName();
    const asb::DisplayState state = asb::displayState(signal);
    if (!enabled) {
        m_soundPrimed = true;
        m_lastSoundSignature.clear();
        m_greenWasLit = false;
        stopCue("completion");
        stopCue("waiting");
        return;
    }

    // Completion: once for each new "done" state, told apart by aggregate, updated_at and
    // session count as on macOS; the state found at start does not chime.
    const QString completion = m_prefs->value("completionSound").toString();
    if (completion == "off") {
        stopCue("completion");
    } else if (state != asb::DisplayState::Completed) {
        m_soundPrimed = true;
        m_lastSoundSignature.clear();
        stopCue("completion");
    } else {
        // floatingSignalLightSnapshot: the shown agents' newest session and session count.
        const qint64 updatedAt = m_runtime ? m_light.updatedAt.value_or(0) : 0;
        const qsizetype sessions = m_runtime ? m_light.sessionCount : 0;
        const QString signature = signal + '|' + QString::number(updatedAt / 1000) + '|' + QString::number(sessions);
        if (!m_soundPrimed) {
            m_soundPrimed = true;
            m_lastSoundSignature = signature;
        } else if (signature != m_lastSoundSignature) {
            m_lastSoundSignature = signature;
            playSound("completion", completion, "completion");
        }
    }

    // Flash: a tick each time the green lamp lights up while an agent works.
    const QString flash = m_prefs->value("waitingSound").toString();
    if (flash == "off" || state != asb::DisplayState::Active) {
        m_greenWasLit = false;
        stopCue("waiting");
        return;
    }
    const bool lit = asb::intensity(asb::LampColor::Green, signal, m_tick, false, effectCustomization()) > 0;
    if (lit && !m_greenWasLit) playSound("waiting", flash, "waiting");
    m_greenWasLit = lit;
}

void AppController::applyBackdrop(QWindow *window, const QString &kind) const {
#ifdef Q_OS_WIN
    if (!window) return;
    if (!supportsBackdrop()) return;
    const HWND hwnd = reinterpret_cast<HWND>(window->winId());
    const BOOL useDark = dark() ? TRUE : FALSE;
    DwmSetWindowAttribute(hwnd, 20 /* DWMWA_USE_IMMERSIVE_DARK_MODE */, &useDark, sizeof(useDark));
    const int corner = 2; // DWMWCP_ROUND
    DwmSetWindowAttribute(hwnd, 33 /* DWMWA_WINDOW_CORNER_PREFERENCE */, &corner, sizeof(corner));
    // Windows 11 22H2+: 1 none, 2 Mica, 3 Acrylic, 4 Mica Alt. Older builds ignore it.
    int backdrop = 1;
    if (m_prefs->value("glassEnabled").toBool()) {
        if (kind == "popup") backdrop = 3;
        else backdrop = m_prefs->value("glassEffect").toString() == "standard" ? 4 : 2;
    }
    DwmSetWindowAttribute(hwnd, 38 /* DWMWA_SYSTEMBACKDROP_TYPE */, &backdrop, sizeof(backdrop));
    // Let the backdrop reach the client area behind the translucent QML surfaces.
    const MARGINS margins = backdrop == 1 ? MARGINS{0, 0, 0, 0} : MARGINS{-1, -1, -1, -1};
    DwmExtendFrameIntoClientArea(hwnd, &margins);
#else
    Q_UNUSED(window);
    Q_UNUSED(kind);
#endif
}

QString AppController::settingsFilePath() const { return m_settings->fileName(); }

void AppController::quit() { QCoreApplication::quit(); }

void AppController::onPrefChanged(const QString &key, const QVariant &value) {
    m_settings->setValue(key, value);
    if (key == "language") {
        emit languageChanged();
    } else if (key == "theme") {
        emit themeChanged();
    } else if (key == "lowPowerMode") {
        restartTimer();
        if (m_runtime) m_runtime->setLowPower(value.toBool());
        if (m_presenceTimer.isActive()) m_presenceTimer.start(value.toBool() ? 60000 : 20000);
    } else if (key == "codexDataDir") {
        if (m_runtime && m_codexDirOverride.isEmpty()) m_runtime->setRoots(codexRoots(value.toString()), true);
        rebuildActivity();
        if (m_captureDir.isEmpty() && m_codexDirOverride.isEmpty()) checkCodexHook(); // another hooks.json
    } else if (key == "fileLogging" || key == "logLevel") {
        configureLogging();
        if (key == "fileLogging" && value.toBool()) asb::debuglog::append("file logging enabled");
        if (key == "logLevel") asb::debuglog::append("log level set to " + value.toString());
    } else if (key == "launchAtLogin") {
        applyLaunchAtLogin(value.toBool());
    } else if (key == "lightAgentMode" || key == "showOtherAgentsWhenIdle") {
        if (key == "lightAgentMode") m_lightSelector.reset(); // a new choice drops the sticky agents
        rebuildActivity();
    } else if (key == "newZealandMode" && value.toBool()) {
        // Like setNewZealandTrafficLightModeEnabled: NZ mode also switches both sounds.
        m_prefs->insert("completionSound", "new_zealand");
        m_prefs->insert("waitingSound", "new_zealand");
        m_settings->setValue("completionSound", "new_zealand");
        m_settings->setValue("waitingSound", "new_zealand");
    }
    if (key == "newZealandMode") {
        m_frameSkip = 0;
        m_tick = 0;
    }
    if (key.endsWith("Effect") || key == "newZealandMode") emit signalNameChanged();
}

void AppController::restartTimer() {
    // 0.45 s per frame, 0.9 s in low-power mode (RuntimeTimingProfile on macOS).
    m_timer.start(m_prefs->value("lowPowerMode").toBool() ? 900 : 450);
}

void AppController::applyLaunchAtLogin(bool enabled) const {
#ifdef Q_OS_WIN
    if (!m_captureDir.isEmpty()) return; // never touch the real Run key from capture runs
    QSettings run("HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Run", QSettings::NativeFormat);
    if (enabled) {
        run.setValue("AgentSignalBar",
                     "\"" + QDir::toNativeSeparators(QCoreApplication::applicationFilePath()) + "\"");
    } else {
        run.remove("AgentSignalBar");
    }
#else
    Q_UNUSED(enabled);
#endif
}

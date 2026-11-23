#include "AppController.h"

#include "ActivityText.h"
#include "ClaudeHookInstaller.h"
#include "ClaudeUiMonitor.h"
#include "CodexAccounts.h"
#include "CliPath.h"
#include "DebugLog.h"
#include "I18n.h"
#include "Diagnostics.h"
#include "HookAdapters.h"
#include "SignalRuntime.h"
#include "PresenceMonitor.h"
#include "SignalStateFile.h"
#include "SoundFile.h"
#include "UsageScanner.h"
#include "UsageService.h"
#include "QuotaService.h"

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
#include <cmath>

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
        // The floating token badge counts today or the last 30 days (FloatingSignalTokenBadgeWindow).
        {"floatingSignalTokenBadgeWindow", "today"},
        // Account quota (MenuBarStatusModel / ClaudeSupportModel keys).
        {"floatingSignalQuotaBadgeWindow", "five-hours"}, {"codexUsageDataSource", "automatic"},
        {"codexOpenAICookieMode", "off"}, {"claudeProviderSource", "oauth"}, {"claudeCredentialConsent", false},
        {"claudeWebOrganization", ""}, {"claudeFloatingQuotaWindow", "five_hour"}, {"claudeUIStatusMonitoring", false},
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
    asb::i18n::setLanguage(language());
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
        // Local token usage. A fixture run (--codex-dir) scans that directory only and never
        // goes online for prices.
        m_usage = new UsageService(this);
        m_usage->setLowPower(m_prefs->value("lowPowerMode").toBool());
        m_usage->setCurrency(m_prefs->value("currency").toString());
        const QStringList claudeRoots = !m_claudeDirOverride.isEmpty()
            ? QStringList{QDir::cleanPath(m_claudeDirOverride + "/projects")}
            : asb::usage::ClaudeScanner::defaultRoots(QDir::homePath(), qEnvironmentVariable("CLAUDE_CONFIG_DIR"),
                                                      qEnvironmentVariable("APPDATA"));
        m_usage->start(usageCodexRoots(), m_captureDir.isEmpty() ? claudeRoots : QStringList(),
                       QFileInfo(asb::debuglog::path()).absolutePath() + "/Cache", m_captureDir.isEmpty());
        connect(m_usage, &UsageService::changed, this, &AppController::rebuildUsage);
        connect(this, &AppController::languageChanged, this, &AppController::rebuildUsage);
        // Account quota reads this user's real logins, so capture runs keep the demo numbers.
        if (m_captureDir.isEmpty()) {
            m_quota = new QuotaService(qEnvironmentVariable("APPDATA") + "/AgentSignalBar", QDir::homePath(), this);
            m_quota->setCodexSource(m_prefs->value("codexUsageDataSource").toString());
            m_quota->setCookieMode(m_prefs->value("codexOpenAICookieMode").toString());
            m_quota->setClaudeSource(m_prefs->value("claudeProviderSource").toString());
            m_quota->setClaudeOrganization(m_prefs->value("claudeWebOrganization").toString());
            m_quota->setClaudeConsent(m_prefs->value("claudeCredentialConsent").toBool());
            connect(m_quota, &QuotaService::changed, this, &AppController::rebuildQuota);
            connect(this, &AppController::languageChanged, this, &AppController::rebuildQuota);
            m_quota->start(true);
        }
    }
    rebuildActivity();
    rebuildUsage();
    rebuildQuota();
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
    const bool zh = language() == "zh-Hans"; // other languages: English through the translation table
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
    // A working agent spends tokens: scan on the short cadence (liveTokenUsageRevision).
    if (m_usage && asb::displayState(aggregate) == asb::DisplayState::Active) m_usage->noteActivity();
    rebuildUsage(); // the floating token badge follows the lamp's agent
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
    const bool checkClaudeUi = m_prefs->value("claudeUIStatusMonitoring").toBool();
    QThreadPool::globalInstance()->start([self, checkClaudeUi] {
        const qint64 now = QDateTime::currentMSecsSinceEpoch();
        QList<asb::SessionStatus> sessions = asb::presence::detect(asb::presence::runningProcesses(), now);
        // The optional reply-state check: a replying Claude desktop replaces its idle presence row.
        QString uiState;
        if (checkClaudeUi) {
            const asb::claudeui::State state = asb::claudeui::observe();
            uiState = asb::claudeui::stateKey(state);
            if (state == asb::claudeui::State::Working) {
                sessions.removeIf([](const asb::SessionStatus &s) { return s.sessionID == "platform-presence:claude-desktop"; });
                sessions.append(asb::claudeui::workingSession(now));
            }
        }
        QMetaObject::invokeMethod(QCoreApplication::instance(), [self, sessions, uiState] {
            if (!self) return;
            self->m_presenceInFlight = false;
            if (self->m_runtime && !self->m_paused) self->m_runtime->setPresence(sessions);
            if (self->m_claudeUiState != uiState) {
                self->m_claudeUiState = uiState;
                self->rebuildQuota();
            }
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

QString AppController::language() const { return asb::i18n::resolve(m_prefs->value("language").toString()); }

QVariantMap AppController::translations() const { return asb::i18n::table(language()); }

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
    // The Windows UI face for each script; Segoe UI for the Latin-script languages.
    const QString lang = language();
    if (lang == "zh-Hans") return "Microsoft YaHei UI";
    if (lang == "zh-Hant") return "Microsoft JhengHei UI";
    if (lang == "ja") return "Yu Gothic UI";
    if (lang == "ko") return "Malgun Gothic";
    return "Segoe UI Variable Text";
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
    return asb::i18n::text(zhHans, english);
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
    if (m_usage) m_usage->setPaused(m_paused); // keeps the last confirmed usage
    if (m_quota) m_quota->setPaused(m_paused);
    pollPresence(); // clears the open apps while paused, looks again on resume
    rebuildActivity();
    emit signalNameChanged();
}

void AppController::setDebugSignal(const QString &signal) {
    m_debugSignal = signal.isEmpty() ? QString() : asb::normalizedSignal(signal).value_or(QString());
    asb::debuglog::append(m_debugSignal.isEmpty() ? QStringLiteral("debug light cleared") : "debug light signal " + m_debugSignal);
    emit signalNameChanged();
}

// --- Account quota -------------------------------------------------------------------------

// AppLanguage.displayName(for: quota window): 5 小时, 一周, 30 天, ...
QString AppController::quotaWindowTitle(std::optional<int> minutes) const {
    if (!minutes || *minutes <= 0) return text("5 小时", "5 hours");
    if (*minutes % (24 * 60) == 0) {
        const int days = *minutes / (24 * 60);
        return days == 7 ? text("一周", "1 week") : text(QString("%1 天").arg(days), QString("%1d").arg(days));
    }
    if (*minutes % 60 == 0) return text(QString("%1 小时").arg(*minutes / 60), QString("%1 hours").arg(*minutes / 60));
    return text(QString("%1 分钟").arg(*minutes), QString("%1 minutes").arg(*minutes));
}

// quotaResetText: "重置 18:25", or with the date for weekly windows.
QString AppController::quotaResetText(std::optional<qint64> resetsAtMs, bool withDate) const {
    if (!resetsAtMs) return text("重置时间未知", "reset time unavailable");
    const QDateTime at = QDateTime::fromMSecsSinceEpoch(*resetsAtMs);
    const QLocale locale = asb::i18n::locale();
    const QString time = locale.toString(at.time(), "HH:mm");
    QString when = time;
    if (withDate) {
        const QString lang = language();
        when = (lang.startsWith("zh") || lang == "ja" ? QStringLiteral("%1月%2日 ").arg(at.date().month()).arg(at.date().day())
                : lang == "ko" ? QStringLiteral("%1월 %2일 ").arg(at.date().month()).arg(at.date().day())
                : locale.toString(at.date(), "MMM d, ")) + time;
    }
    return text("重置 " + when, "resets " + when);
}

void AppController::refreshQuota(const QString &provider) {
    if (!m_quota) return;
    if (provider != "claude") m_quota->refreshCodex();
    if (provider != "codex") m_quota->refreshClaude();
}
void AppController::saveCodexAccount() { if (m_quota) m_quota->saveCurrentAccount(); }
void AppController::switchCodexAccount(const QString &id) { if (m_quota) m_quota->switchAccount(id); }
void AppController::removeCodexAccount(const QString &id) { if (m_quota) m_quota->removeAccount(id); }
void AppController::addCodexAccount() { if (m_quota) m_quota->addAccount(); }
void AppController::cancelAddCodexAccount() { if (m_quota) m_quota->cancelAddAccount(); }

bool AppController::setCodexCookie(const QString &pasted) {
    if (!m_quota) return false;
    if (!pasted.trimmed().isEmpty() && asb::quota::sanitizeCookieHeader(pasted).isEmpty()) return false;
    m_quota->setCookie(pasted);
    return true;
}

bool AppController::setClaudeSession(const QString &pasted) { return m_quota && m_quota->setClaudeSession(pasted); }

void AppController::rebuildQuota() {
    QVariantMap map;
    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    const auto updatedText = [this](qint64 ms) {
        return ms > 0 ? text("更新 ", "Updated ") + QLocale::system().toString(QDateTime::fromMSecsSinceEpoch(ms).time(), QLocale::ShortFormat)
                      : QString();
    };
    const auto remainingText = [this](double remaining) {
        const int value = qRound(remaining);
        return text(QString("剩余 %1%").arg(value), QString("%1% left").arg(value));
    };
    const auto tone = [](double remaining) {
        return remaining <= 0 ? QStringLiteral("critical") : remaining < 20 ? QStringLiteral("caution") : QStringLiteral("positive");
    };

    if (m_quota) {
        // Codex.
        const QuotaService::CodexState &state = m_quota->codex();
        const auto active = m_quota->accounts().active();
        QVariantList accounts;
        for (const asb::codexauth::Account &a : m_quota->accounts().accounts()) {
            const QString title = !a.label.isEmpty() ? a.label : !a.email.isEmpty() ? a.email
                : "Codex " + a.fingerprint.left(6) + "…" + a.fingerprint.right(4);
            accounts.append(QVariantMap{{"id", a.id}, {"title", title}, {"plan", a.plan},
                                        {"active", active && active->id == a.id}});
        }
        const auto identity = [&]() -> std::optional<asb::codexauth::Identity> {
            QFile file(m_quota->codexAuthPath());
            return file.open(QIODevice::ReadOnly) ? asb::codexauth::parseIdentity(file.readAll()) : std::nullopt;
        }();
        QString plan = state.hasResult ? state.result.usage.plan : QString();
        if (plan.isEmpty() && identity) plan = identity->plan;
        if (!plan.isEmpty()) plan[0] = plan[0].toUpper();

        // FloatingSignalQuotaBadgeWindow: exact 5-hour / weekly windows; a lone short window
        // stands in for the 5-hour slot.
        const QString badgeKey = m_prefs->value("floatingSignalQuotaBadgeWindow").toString();
        QList<asb::quota::Window> windows;
        if (state.hasResult && state.result.usage.primary) windows.append(*state.result.usage.primary);
        if (state.hasResult && state.result.usage.secondary) windows.append(*state.result.usage.secondary);
        const auto windowFor = [&](const QString &key) -> std::optional<asb::quota::Window> {
            const int exact = key == "weekly" ? 7 * 24 * 60 : 5 * 60;
            for (const auto &w : windows) {
                if (w.minutes == exact) return w;
            }
            if (windows.size() == 1 && key == "five-hours" && windows[0].minutes != 7 * 24 * 60) return windows[0];
            return std::nullopt;
        };
        QVariantList windowRows;
        for (const auto &w : windows) {
            QString key;
            for (const QString &k : {QStringLiteral("five-hours"), QStringLiteral("weekly")}) {
                const auto match = windowFor(k);
                if (match && match->id == w.id && key.isEmpty()) key = k;
            }
            const double remaining = 100 - w.usedPercent;
            windowRows.append(QVariantMap{
                {"title", quotaWindowTitle(w.minutes)}, {"remaining", qRound(remaining)},
                {"valueText", remainingText(remaining)},
                {"reset", quotaResetText(w.resetsAtMs, key == "weekly" || w.minutes.value_or(0) >= 24 * 60)},
                {"key", key}, {"selected", !key.isEmpty() && key == badgeKey}});
        }
        QString badge = QStringLiteral("--"), badgeTone = QStringLiteral("neutral");
        if (const auto selected = windowFor(badgeKey)) {
            badge = QString::number(qRound(100 - selected->usedPercent)) + '%';
            badgeTone = tone(100 - selected->usedPercent);
        } else if (state.hasResult && windows.isEmpty() && state.result.usage.credits && state.result.usage.credits->remaining) {
            const double credits = *state.result.usage.credits->remaining;
            badge = credits < 1 ? QStringLiteral("<1c") : credits >= 1000 ? QString::number(credits / 1000, 'f', 1) + "Kc"
                                                                            : QString::number(qRound(credits)) + 'c';
        }
        QString creditsText;
        if (state.hasResult && state.result.usage.credits) {
            const asb::quota::Credit &c = *state.result.usage.credits;
            creditsText = c.limit ? text("每月额度 · 剩余 ", "Monthly credit limit · ") + QString::number(c.remaining.value_or(0), 'f', 0)
                                        + " / " + QString::number(*c.limit, 'f', 0) + text("", " left")
                                  : text("额度余额 ", "Credits ") + QString::number(c.balance.value_or(0), 'f', 0);
        }
        // Limit reset credits: count plus up to four expiry countdowns.
        QVariantMap resetCredits;
        if (state.hasResult && state.result.resetCredits) {
            const QList<asb::quota::ResetCredit> available = asb::quota::availableResetCredits(*state.result.resetCredits, now);
            QStringList items;
            for (const auto &c : available.mid(0, 4)) {
                if (!c.expiresAtMs) {
                    items.append(text("无到期时间", "No expiry"));
                    continue;
                }
                const qint64 minutes = std::max<qint64>(0, (*c.expiresAtMs - now) / 60'000);
                items.append(minutes >= 1440 ? QString("%1d %2h").arg(minutes / 1440).arg(minutes % 1440 / 60)
                             : minutes >= 60 ? QString("%1h %2m").arg(minutes / 60).arg(minutes % 60)
                                             : QString("%1m").arg(minutes));
            }
            if (available.size() > 4) items.append(QString("+%1").arg(available.size() - 4));
            resetCredits = {{"title", text(QString("%1 次可用").arg(available.size()), QString("%1 available").arg(available.size()))},
                            {"detail", items.isEmpty() ? text("暂无可用额度", "No credits available") : items.join(" · ")}};
        }
        QString status;
        const QString error = state.error;
        if (error == "noCredentials") status = text("未登录 Codex：请在 Codex 中登录，或添加账号。", "Not signed in to Codex. Sign in with Codex or add an account.");
        else if (error == "apiKey") status = text("当前用 API Key 登录，无法读取订阅额度。", "Signed in with an API key; subscription quota is unavailable.");
        else if (error == "unauthorized" || error == "refreshRejected") status = text("登录已失效，请在 Codex 中重新登录。", "Sign-in expired. Sign in to Codex again.");
        else if (error == "credentialsChanged") status = text("登录信息刚刚变化，稍后重试。", "The sign-in just changed; retrying shortly.");
        else if (error == "noRateLimits") status = text("账号没有返回额度信息。", "The account returned no limits.");
        else if (error == "network") status = text("网络不可用，稍后重试。", "Network unavailable; retrying later.");
        else if (error.startsWith("server ")) status = text("服务器返回 ", "Server returned ") + error.mid(7);
        if (!status.isEmpty() && state.hasResult) status = text("上次读取结果 · ", "Previous snapshot · ") + status;
        const QString message = m_quota->accountMessage();
        const QString accountMessage = message == "codexCliMissing"
            ? text("找不到 Codex CLI。请先安装（npm i -g @openai/codex），或在 Codex 中登录后点“保存当前账号”。",
                   "Codex CLI not found. Install it (npm i -g @openai/codex), or sign in with Codex and click Save Current.")
            : message == "loginStarted" ? text("已打开登录页面，完成登录后会自动添加。", "Sign-in page opened; the account is added when you finish.")
            : message == "accountAdded" ? text("已添加账号。", "Account added.")
            : message == "loginFailed" ? text("登录没有完成。", "Sign-in did not finish.")
            : message == "saved" ? text("已保存当前账号。", "Current account saved.") : message;
        const QString limitTitle = state.hasResult && !state.result.usage.limitName.isEmpty() ? state.result.usage.limitName
            : state.hasResult && !state.result.usage.limitId.isEmpty() ? state.result.usage.limitId : text("Codex 配额", "Codex quota");
        map.insert("codex", QVariantMap{
            {"accounts", accounts},
            {"activeId", active ? active->id : QString()},
            {"email", identity ? identity->email : QString()},
            {"signedIn", identity.has_value()},
            {"plan", plan},
            {"needsSave", m_quota->accounts().currentNeedsSaving()},
            {"cliFound", m_quota->codexCliFound()},
            {"adding", m_quota->addingAccount()},
            {"message", accountMessage},
            {"fetching", state.fetching},
            {"ready", state.hasResult},
            {"status", status},
            {"source", state.result.source == "Cookie" ? QStringLiteral("OpenAI Cookie") : QStringLiteral("Codex OAuth")},
            {"updated", updatedText(state.updatedAtMs)},
            {"limitTitle", limitTitle},
            {"limitId", state.hasResult ? state.result.usage.limitId : QString()},
            {"windows", windowRows},
            {"credits", creditsText},
            {"resetCredits", resetCredits},
            {"badgeText", badge},
            {"badgeTone", badgeTone},
            {"hasCookie", m_quota->hasCookie()}});

        // Claude.
        const QuotaService::ClaudeState &claude = m_quota->claude();
        const asb::quota::ClaudeUsage &usage = claude.result.usage;
        const QString claudeBadgeKey = m_prefs->value("claudeFloatingQuotaWindow").toString();
        QVariantList claudeWindows;
        std::optional<double> claudeBadge;
        double worstUsed = -1;
        for (const asb::quota::Window &w : claude.hasResult ? usage.windows : QList<asb::quota::Window>()) {
            const QStringList titles = w.title.split(" / ");
            const QString title = titles.size() == 2 ? text(titles[0], titles[1]) : w.title;
            const double remaining = 100 - w.usedPercent;
            claudeWindows.append(QVariantMap{{"id", w.id}, {"title", title}, {"remaining", qRound(remaining)},
                                             {"valueText", remainingText(remaining)},
                                             {"reset", quotaResetText(w.resetsAtMs, w.id != "five_hour")},
                                             {"selected", w.id == claudeBadgeKey}});
            if (w.id == claudeBadgeKey) claudeBadge = remaining;
            const bool current = !w.resetsAtMs || *w.resetsAtMs > now;
            if (claudeBadgeKey == "automatic" && current && w.usedPercent > worstUsed) {
                worstUsed = w.usedPercent;
                claudeBadge = remaining;
            }
        }
        const auto money = [](std::optional<double> value, const QString &currency) {
            return value ? currency + ' ' + QString::number(*value, 'f', 2) : QStringLiteral("—");
        };
        QStringList balances;
        if (claude.hasResult) {
            if (usage.extraUsed || usage.extraLimit)
                balances.append(text("额外用量 · 已用 ", "Extra usage · Used ") + money(usage.extraUsed, usage.extraCurrency)
                                + text(" · 月上限 ", " · Monthly limit ") + money(usage.extraLimit, usage.extraCurrency));
            if (usage.prepaidBalance)
                balances.append(text("预充值余额 ", "Prepaid balance ") + money(usage.prepaidBalance, usage.prepaidCurrency));
            if (usage.cloudLimit)
                balances.append(text("云端额度 · 剩余 ", "Cloud credits · ") + money(usage.cloudRemaining, "USD")
                                + " / " + money(usage.cloudLimit, "USD") + text("", " left"));
            if (usage.resetsLeft)
                balances.append(text(QString("限额重置 · %1 次可用").arg(*usage.resetsLeft),
                                     QString("Limit resets · %1 available").arg(*usage.resetsLeft)));
            if (usage.renewsAtMs)
                balances.append(text("下次续费 ", "Renews ")
                                + QLocale::system().toString(QDateTime::fromMSecsSinceEpoch(*usage.renewsAtMs).date(), QLocale::ShortFormat));
        }
        QString claudeStatus;
        const QString claudeError = claude.error;
        if (claudeError == "consentRequired") claudeStatus = text("需要先允许读取 Claude Code 凭据。", "Allow reading the Claude Code credentials first.");
        else if (claudeError == "noCredentials") claudeStatus = text("没有找到 Claude Code 登录（.credentials.json）。请先在 Claude Code 中登录。", "No Claude Code sign-in (.credentials.json). Sign in with Claude Code first.");
        else if (claudeError == "noSession") claudeStatus = text("请粘贴 claude.ai 的 sessionKey。", "Paste the claude.ai sessionKey.");
        else if (claudeError == "loginRequired") claudeStatus = text("Claude 登录已过期，请重新登录。", "Claude sign-in expired. Sign in again.");
        else if (claudeError == "unauthorized") claudeStatus = text("Claude 拒绝了请求（403）。", "Claude refused the request (403).");
        else if (claudeError == "rateLimited")
            claudeStatus = text("请求过于频繁，", "Rate limited; retrying at ")
                + QLocale::system().toString(QDateTime::fromMSecsSinceEpoch(claude.retryAfterMs).time(), QLocale::ShortFormat)
                + text(" 后重试。", ".");
        else if (claudeError == "challenge") claudeStatus = text("claude.ai 要求浏览器验证。请在浏览器中打开 claude.ai 后重新粘贴 sessionKey。", "claude.ai asked for a browser check. Open claude.ai in a browser, then paste the sessionKey again.");
        else if (claudeError == "chooseOrganization") claudeStatus = text("请选择组织。", "Choose an organization.");
        else if (claudeError == "network") claudeStatus = text("网络不可用，稍后重试。", "Network unavailable; retrying later.");
        else if (claudeError == "invalidResponse") claudeStatus = text("Claude 返回的数据无法识别。", "Claude returned data that could not be read.");
        else if (claudeError.startsWith("server ")) claudeStatus = text("服务器返回 ", "Server returned ") + claudeError.mid(7);
        if (!claudeStatus.isEmpty() && claude.hasResult) claudeStatus = text("上次读取结果 · ", "Previous snapshot · ") + claudeStatus;
        QVariantList organizations;
        for (const QString &entry : claude.result.organizations) {
            const QStringList parts = entry.split('\t');
            organizations.append(QVariantMap{{"value", parts.value(0)}, {"label", parts.value(1).isEmpty() ? parts.value(0) : parts.value(1)}});
        }
        map.insert("claude", QVariantMap{
            {"consent", m_prefs->value("claudeCredentialConsent").toBool()},
            {"hasCredentials", m_quota->hasClaudeCredentials()},
            {"hasSession", m_quota->hasClaudeSession()},
            {"organizations", organizations},
            {"fetching", claude.fetching},
            {"ready", claude.hasResult},
            {"status", claudeStatus},
            {"email", claude.hasResult ? usage.email : QString()},
            {"plan", claude.hasResult ? usage.plan : QString()},
            {"organization", claude.hasResult ? usage.organization : QString()},
            {"source", claude.hasResult ? usage.source : QString()},
            {"updated", updatedText(claude.updatedAtMs)},
            {"windows", claudeWindows},
            {"balances", balances},
            {"badgeText", claudeBadge ? QString::number(qRound(*claudeBadge)) + '%' : QStringLiteral("—")},
            {"badgeTone", claudeBadge ? tone(*claudeBadge) : QStringLiteral("neutral")}});
    }

    // Claude desktop reply state (claudeUIConnectionMessage).
    const bool uiEnabled = m_prefs->value("claudeUIStatusMonitoring").toBool();
    const QString ui = m_claudeUiState;
    const QString uiMessage = !uiEnabled ? text("已关闭", "Off")
        : ui.isEmpty() ? text("正在检查…", "Checking…")
        : ui == "notRunning" ? text("Claude 桌面版未运行。", "Claude desktop is not running.")
        : ui == "working" ? text("Claude 正在回复。", "Claude is responding.")
        : ui == "notResponding" ? text("未检测到正在回复；后台任务是否完成无法判断。", "Not responding now; background completion is unknown.")
        : text("暂时无法读取 Claude 窗口，可能是 Claude 更新了界面。", "Cannot read the Claude window right now; its interface may have changed.");
    const QVariantMap claudeUi{{"enabled", uiEnabled}, {"state", ui}, {"message", uiMessage}};
    if (map != m_quotaMap || claudeUi != m_claudeUi) {
        m_quotaMap = map;
        m_claudeUi = claudeUi;
        emit quotaChanged();
    }
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

// --- Local token usage -------------------------------------------------------------------

// CodexTokenActivityScanner.defaultSessionRootURLs: the activity roots plus archived_sessions.
QStringList AppController::usageCodexRoots() const {
    const QString selected = m_codexDirOverride.isEmpty() ? m_prefs->value("codexDataDir").toString() : m_codexDirOverride;
    const QList<asb::codex::Root> roots = m_codexDirOverride.isEmpty()
        ? codexRoots(selected) : asb::codex::rootsForDirectory(QDir::homePath(), m_codexDirOverride);
    QStringList paths;
    for (const asb::codex::Root &root : roots) paths.append(root.path);
    paths.append(asb::codex::primaryCodexHome(QDir::homePath(), qEnvironmentVariable("CODEX_HOME"), selected)
                 + "/archived_sessions");
    paths.removeDuplicates();
    return paths;
}

void AppController::refreshUsage() {
    if (m_usage) m_usage->requestScan();
}

// AppLanguage.compactTokenCountText: 万/亿 in Chinese, K/M/B in English, two decimals.
QString AppController::compactTokens(qint64 count) const {
    const double value = double(std::max<qint64>(0, count));
    const QLocale locale = asb::i18n::locale();
    const auto scaled = [&](double divisor, const char *suffix) {
        return locale.toString(value / divisor, 'f', 2) + QString::fromUtf8(suffix);
    };
    if (asb::i18n::usesChineseNumbers()) {
        if (value >= 1e8) return scaled(1e8, "亿");
        if (value >= 1e4) return scaled(1e4, "万");
    } else {
        if (value >= 1e9) return scaled(1e9, "B");
        if (value >= 1e6) return scaled(1e6, "M");
        if (value >= 1e3) return scaled(1e3, "K");
    }
    return locale.toString(qint64(value));
}

// CostCurrencyStore.format with ISO code presentation; "≥ " marks a confirmed subtotal.
QString AppController::costText(std::optional<double> usd, bool partial) const {
    if (!usd || !std::isfinite(*usd)) return QStringLiteral("—");
    const auto [rate, code] = m_usage ? m_usage->rate(m_prefs->value("currency").toString())
                                      : std::pair<double, QString>{1.0, QStringLiteral("USD")};
    const double value = std::max(0.0, *usd) * rate;
    const int decimals = code == "JPY" || code == "KRW" ? 0 : 2;
    const QLocale locale = asb::i18n::locale();
    return (partial ? QStringLiteral("≥ ") : QString()) + code + ' ' + locale.toString(value, 'f', decimals);
}

QVariantMap AppController::usageSide(const asb::usage::Report &report, bool claude) const {
    // Token counts read "token" in Chinese and "tokens" elsewhere, as on macOS.
    const bool ready = m_usage && m_usage->hasResult();
    const bool scanning = m_usage && m_usage->scanning();
    const QString tokenSuffix = text(QStringLiteral(" token"), QStringLiteral(" tokens"));
    const QDate today = QDate::currentDate();
    QHash<QString, const asb::usage::Day *> byKey;
    for (const asb::usage::Day &day : report.days) byKey.insert(day.key, &day);

    struct Window {
        qint64 tokens = 0;
        std::optional<double> cost;
        bool partial = false;
    };
    Window todayWindow, monthWindow;
    QHash<QString, qint64> modelTotals;
    QVariantList days;
    for (int back = 29; back >= 0; --back) {
        const QDate date = today.addDays(-back);
        const asb::usage::Day *day = byKey.value(date.toString("yyyy-MM-dd"));
        QVariantList models;
        if (day) {
            struct Item {
                QString name;
                asb::usage::ModelPresentation presentation;
                asb::usage::ModelDay usage;
            };
            QList<Item> items;
            for (auto it = day->models.cbegin(); it != day->models.cend(); ++it) {
                if (it->totalTokens <= 0) continue;
                items.append({it.key(), claude ? asb::usage::claudeModelPresentation(it.key())
                                               : asb::usage::codexModelPresentation(it.key()), it.value()});
            }
            std::sort(items.begin(), items.end(), [](const Item &a, const Item &b) {
                if (a.presentation.sortRank != b.presentation.sortRank) return a.presentation.sortRank < b.presentation.sortRank;
                return a.usage.totalTokens > b.usage.totalTokens;
            });
            for (const Item &item : items) {
                const bool partial = item.usage.unpricedTokens > 0 || !item.usage.cost;
                models.append(QVariantMap{
                    {"name", item.presentation.displayName},
                    {"tokens", double(item.usage.totalTokens) / 1e6},
                    {"tokensText", compactTokens(item.usage.totalTokens) + tokenSuffix},
                    {"costText", costText(item.usage.cost, partial && item.usage.cost.has_value())},
                    {"share", day->totalTokens > 0 ? qRound(100.0 * item.usage.totalTokens / day->totalTokens) : 0},
                    {"color", item.presentation.color.isEmpty() ? QStringLiteral("#8E8E93") : item.presentation.color}});
                modelTotals[item.presentation.displayName] += item.usage.totalTokens;
            }
            monthWindow.tokens += day->totalTokens;
            if (day->cost) monthWindow.cost = monthWindow.cost.value_or(0) + *day->cost;
            monthWindow.partial = monthWindow.partial || day->partial;
            if (back == 0) todayWindow = {day->totalTokens, day->cost, day->partial};
        }
        const qint64 total = day ? day->totalTokens : 0;
        const std::optional<double> cost = day ? day->cost : (ready ? std::optional<double>(0) : std::nullopt);
        // Month and day in the interface language (tokenActivityShortDateText).
        const QString lang = language();
        const QString shortDate = lang == "zh-Hans" || lang == "zh-Hant" || lang == "ja"
            ? QStringLiteral("%1月%2日").arg(date.month()).arg(date.day())
            : lang == "ko" ? QStringLiteral("%1월 %2일").arg(date.month()).arg(date.day())
            : lang == "en" ? QLocale(QLocale::English).toString(date, "MMM d")
            : asb::i18n::locale().toString(date, "d MMM");
        days.append(QVariantMap{
            {"label", shortDate},
            {"total", double(total) / 1e6},
            {"tokensText", compactTokens(total) + tokenSuffix},
            {"costText", costText(cost, day && day->partial && cost.has_value())},
            {"models", models}});
    }
    if (ready && monthWindow.tokens == 0) monthWindow.cost = 0;
    if (ready && todayWindow.tokens == 0 && !todayWindow.cost) todayWindow.cost = 0;

    const auto windowMap = [&](const Window &w, const QString &title) {
        const QString cost = costText(w.cost, w.partial && w.cost.has_value());
        return QVariantMap{
            {"tokens", ready ? QVariant(w.tokens) : QVariant()},
            {"tokensText", ready ? compactTokens(w.tokens) + tokenSuffix : text("暂无数据", "Unavailable")},
            {"costText", cost},
            {"costLine", w.cost ? text("费用 ", "cost ") + cost
                                : (scanning ? text("正在计算…", "calculating…") : text("费用未知", "cost unavailable"))},
            {"titleLine", ready ? title + " · " + compactTokens(w.tokens) + tokenSuffix : title + " · — " + tokenSuffix.trimmed()}};
    };

    QString topModel = QStringLiteral("—");
    qint64 topTokens = 0;
    for (auto it = modelTotals.cbegin(); it != modelTotals.cend(); ++it) {
        if (it.value() > topTokens || (it.value() == topTokens && it.key() < topModel)) {
            topModel = it.key();
            topTokens = it.value();
        }
    }

    // Projects: sessions grouped by working folder (CodexUsageDetails.projects).
    struct Project {
        QString path;
        int sessions = 0;
        qint64 tokens = 0;
        std::optional<double> cost;
        bool partial = false;
    };
    QHash<QString, Project> grouped;
    qint64 projectTokens = 0;
    for (const asb::usage::Session &session : report.sessions) {
        Project &p = grouped[session.projectPath];
        p.path = session.projectPath;
        ++p.sessions;
        p.tokens += session.totalTokens;
        if (session.cost) p.cost = p.cost.value_or(0) + *session.cost;
        p.partial = p.partial || session.partial;
        projectTokens += session.totalTokens;
    }
    QList<Project> projectList = grouped.values();
    std::sort(projectList.begin(), projectList.end(), [](const Project &a, const Project &b) {
        return a.tokens != b.tokens ? a.tokens > b.tokens : a.path < b.path;
    });
    QVariantList projects;
    for (const Project &p : projectList.mid(0, 10)) {
        const QString name = p.path.isEmpty() ? text("未知项目", "Unknown project")
                                              : (QFileInfo(p.path).fileName().isEmpty() ? p.path : QFileInfo(p.path).fileName());
        projects.append(QVariantMap{{"name", name}, {"path", p.path}, {"sessions", p.sessions},
                                    {"tokens", compactTokens(p.tokens)},
                                    {"cost", costText(p.cost, p.partial && p.cost.has_value())},
                                    {"share", projectTokens > 0 ? double(p.tokens) / double(projectTokens) : 0.0}});
    }

    QString status;
    if (m_paused) status = text("监控已暂停；这里保留上次已确认的用量。", "Monitoring is paused; showing the last confirmed usage.");
    else if (scanning && ready) status = text("正在扫描本机会话；已确认的数据会保留。", "Scanning local sessions; confirmed usage is retained.");
    else if (!ready) status = text("等待本机会话扫描；暂无结果不代表用量为零。", "Waiting for a local scan; unavailable usage does not mean zero.");
    else if (report.excludedSessions > 0)
        status = text(QString("%1 个会话存在记录冲突，暂未计入历史；其余可信用量已显示。").arg(report.excludedSessions),
                      QString("%1 sessions have conflicting records and are excluded from history; trusted usage is shown.")
                          .arg(report.excludedSessions));

    const bool badgeToday = m_prefs->value("floatingSignalTokenBadgeWindow").toString() != "last-30-days";
    const qint64 badgeTokens = badgeToday ? todayWindow.tokens : monthWindow.tokens;
    QString badge = QStringLiteral("--");
    if (ready) {
        // AppLanguage.compactTokenBadgeText: one decimal below 10, a bigger unit from 999.5.
        const double value = double(std::max<qint64>(0, badgeTokens));
        if (value < 1000) {
            badge = QString::number(qint64(value));
        } else {
            static const QList<QPair<double, QString>> units = {{1e3, "K"}, {1e6, "M"}, {1e9, "B"}};
            int unit = 0;
            while (unit + 1 < units.size() && value >= units[unit + 1].first) ++unit;
            double s = value / units[unit].first;
            if (s >= 999.5 && unit + 1 < units.size()) s = value / units[++unit].first;
            badge = QLocale(QLocale::English).toString(s, 'f', s < 10 ? 1 : 0);
            if (badge.endsWith(".0")) badge.chop(2);
            badge += units[unit].second;
        }
    }

    return QVariantMap{
        {"ready", ready}, {"scanning", scanning}, {"status", status},
        {"scan", ready ? text("扫描完成 · ", "Scan complete · ")
                             + QLocale::system().toString(QDateTime::fromMSecsSinceEpoch(m_usage->completedAtMs()).time(),
                                                          QLocale::ShortFormat)
                       : text("正在扫描…", "Scanning…")},
        {"today", windowMap(todayWindow, text("今日", "Today"))},
        {"month", windowMap(monthWindow, text("近 30 天", "Last 30 days"))},
        {"days", days}, {"topModel", topModel}, {"projects", projects},
        {"empty", ready && monthWindow.tokens == 0
             ? (claude ? text("近 30 天未发现本地 Claude Code 用量记录。", "No local Claude Code usage records in the last 30 days.")
                       : text("近 30 天未发现本地 Codex 用量记录。", "No local Codex usage records in the last 30 days."))
             : QString()},
        {"badgeText", badge},
        {"badgeToday", badgeToday}};
}

void AppController::rebuildUsage() {
    QVariantMap map;
    if (m_usage) {
        map.insert("codex", usageSide(m_usage->codex(), false));
        map.insert("claude", usageSide(m_usage->claude(), true));
        // The floating token badge counts the agent the lamp shows (selectedSignalLightProvider):
        // Claude when every displayed scope is a Claude one, else Codex.
        const bool claudeLamp = !m_light.scopes.isEmpty()
            && std::all_of(m_light.scopes.cbegin(), m_light.scopes.cend(),
                           [](const QString &scope) { return scope.startsWith("claude-"); });
        map.insert("floatingProvider", claudeLamp ? QStringLiteral("claude") : QStringLiteral("codex"));
        const QString currency = m_prefs->value("currency").toString();
        if (currency != "USD") {
            const auto [rate, code] = m_usage->rate(currency);
            Q_UNUSED(rate);
            map.insert("rateNote", code == currency
                ? text("按 ", "Converted at the ")
                      + QLocale::system().toString(QDateTime::fromMSecsSinceEpoch(m_usage->ratesUpdatedAtMs()).date(),
                                                   QLocale::ShortFormat)
                      + text(" 的汇率折算", " rate")
                : text("暂无 ", "No ") + currency + text(" 汇率，按美元显示", " rate yet; showing USD"));
        }
    }
    if (map != m_usageMap) {
        m_usageMap = map;
        emit usageChanged();
    }
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
        asb::i18n::setLanguage(language());
        emit languageChanged();
    } else if (key == "theme") {
        emit themeChanged();
    } else if (key == "lowPowerMode") {
        restartTimer();
        if (m_runtime) m_runtime->setLowPower(value.toBool());
        if (m_presenceTimer.isActive()) m_presenceTimer.start(value.toBool() ? 60000 : 20000);
        if (m_usage) m_usage->setLowPower(value.toBool());
    } else if (key == "currency") {
        if (m_usage) m_usage->setCurrency(value.toString());
        rebuildUsage();
    } else if (key == "floatingSignalTokenBadgeWindow") {
        rebuildUsage();
    } else if (key == "floatingSignalQuotaBadgeWindow" || key == "claudeFloatingQuotaWindow") {
        rebuildQuota();
    } else if (key == "codexUsageDataSource" || key == "codexOpenAICookieMode" || key == "claudeProviderSource"
               || key == "claudeWebOrganization" || key == "claudeCredentialConsent") {
        if (m_quota) {
            if (key == "codexUsageDataSource") m_quota->setCodexSource(value.toString());
            else if (key == "codexOpenAICookieMode") m_quota->setCookieMode(value.toString());
            else if (key == "claudeProviderSource") m_quota->setClaudeSource(value.toString());
            else if (key == "claudeWebOrganization") m_quota->setClaudeOrganization(value.toString());
            else m_quota->setClaudeConsent(value.toBool());
        }
        rebuildQuota();
    } else if (key == "claudeUIStatusMonitoring") {
        if (!value.toBool()) m_claudeUiState.clear();
        pollPresence();
        rebuildQuota();
    } else if (key == "codexDataDir") {
        if (m_runtime && m_codexDirOverride.isEmpty()) m_runtime->setRoots(codexRoots(value.toString()), true);
        if (m_usage && m_codexDirOverride.isEmpty()) m_usage->setCodexRoots(usageCodexRoots());
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

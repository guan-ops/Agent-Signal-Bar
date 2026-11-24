#include "QuotaService.h"

#include "CodexAccounts.h"
#include "Secrets.h"

#include <QCoreApplication>
#include <QDateTime>
#include <QDesktopServices>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QProcess>
#include <QProcessEnvironment>
#include <QRegularExpression>
#include <QStandardPaths>
#include <QThreadPool>
#include <QUuid>

namespace {

constexpr qint64 kFetchIntervalMs = 60'000; // CodexRateLimitFetcher / ClaudeSupportModel throttle
constexpr int kLoginTimeoutMs = 120'000;

qint64 nowMs() { return QDateTime::currentMSecsSinceEpoch(); }

QString firstExisting(const QStringList &candidates) {
    for (const QString &path : candidates) {
        if (!path.isEmpty() && QFileInfo(path).isFile()) return QDir::cleanPath(path);
    }
    return QString();
}

} // namespace

QuotaService::QuotaService(QString dataDir, QString home, QObject *parent)
    : QObject(parent), m_dataDir(std::move(dataDir)), m_home(std::move(home)) {
    setCodexHome(qEnvironmentVariable("CODEX_HOME"));
    if (const auto cookie = asb::secrets::readProtected(m_dataDir + "/secrets/openai-cookie.bin"))
        m_cookie = QString::fromUtf8(*cookie);
    if (const auto session = asb::secrets::readProtected(m_dataDir + "/secrets/claude-session.bin"))
        m_sessionKey = QString::fromUtf8(*session);
    m_codexCli = findCodexCli();
    connect(&m_timer, &QTimer::timeout, this, &QuotaService::tick);
}

QuotaService::~QuotaService() {
    if (m_login) m_login->kill();
}

void QuotaService::setCodexHome(const QString &codexHomeEnv) {
    m_authPath = asb::codexauth::authFilePath(m_home, codexHomeEnv);
    m_configPath = QFileInfo(m_authPath).absolutePath() + "/config.toml";
    m_accounts = std::make_unique<asb::codexauth::AccountStore>(m_dataDir, m_authPath);
}

void QuotaService::start(bool network) {
    m_started = true;
    m_network = network;
    m_timer.start(2000); // the macOS poll timer; fetches stay throttled to one a minute
    QTimer::singleShot(0, this, &QuotaService::tick);
}

void QuotaService::setPaused(bool paused) {
    m_paused = paused;
    if (!paused) tick();
}

void QuotaService::tick() {
    if (!m_started || !m_network || m_paused) return;
    const qint64 now = nowMs();
    if (!m_codex.fetching && (m_codexPending || now - m_codexFetchedAtMs >= kFetchIntervalMs)) startCodexFetch();
    if (!m_claude.fetching && (m_claudePending || now - m_claudeFetchedAtMs >= kFetchIntervalMs)) startClaudeFetch();
}

// --- Codex -----------------------------------------------------------------------------------

void QuotaService::setCodexSource(const QString &source) {
    if (source == m_codexSource) return;
    m_codexSource = source;
    ++m_codexGeneration;
    refreshCodex();
}

void QuotaService::setCookieMode(const QString &mode) {
    if (mode == m_cookieMode) return;
    m_cookieMode = mode;
    ++m_codexGeneration;
    refreshCodex();
}

void QuotaService::setCookie(const QString &pasted) {
    const QString path = m_dataDir + "/secrets/openai-cookie.bin";
    if (pasted.trimmed().isEmpty()) {
        m_cookie.clear();
        QFile::remove(path);
    } else {
        const QString cookie = asb::quota::sanitizeCookieHeader(pasted);
        if (cookie.isEmpty() || !asb::secrets::writeProtected(path, cookie.toUtf8())) return;
        m_cookie = cookie;
    }
    refreshCodex();
}

void QuotaService::refreshCodex() {
    m_codexPending = true;
    tick();
    emit changed();
}

void QuotaService::startCodexFetch() {
    m_codexPending = false;
    m_codex.fetching = true;
    m_codexFetchedAtMs = nowMs();
    emit changed();
    asb::quota::CodexOptions options;
    options.authPath = m_authPath;
    options.configPath = m_configPath;
    if (m_codexSource == "automatic" && m_cookieMode == "manual") options.cookieHeader = m_cookie;
    const QString dataDir = m_dataDir;
    const QString authPath = m_authPath;
    options.persistRefreshed = [dataDir, authPath](const QString &oldFingerprint, const QByteArray &data) {
        asb::codexauth::AccountStore(dataDir, authPath).persistRefreshed(oldFingerprint, data);
    };
    QPointer<QuotaService> self(this);
    const quint64 generation = m_codexGeneration;
    QThreadPool::globalInstance()->start([self, options, generation] {
        const asb::quota::CodexResult result = asb::quota::fetchCodex(options, asb::quota::blockingHttp, nowMs());
        QMetaObject::invokeMethod(QCoreApplication::instance(), [self, result, generation] {
            if (!self) return;
            CodexState &state = self->m_codex;
            state.fetching = false;
            // Started for an account (or source) that is no longer current: its numbers or errors
            // belong to that account, so drop them and fetch again for the current one.
            if (generation != self->m_codexGeneration) {
                emit self->changed();
                self->tick();
                return;
            }
            state.error = result.ok ? QString() : result.error;
            if (result.ok) {
                state.result = result;
                state.hasResult = true;
                state.updatedAtMs = nowMs();
            } else if (result.error == "noCredentials" || result.error == "apiKey" || result.error == "unauthorized"
                       || result.error == "refreshRejected") {
                // An auth failure makes the old numbers someone else's: drop them (as macOS does).
                state.hasResult = false;
            }
            emit self->changed();
            if (self->m_codexPending) self->tick();
        }, Qt::QueuedConnection);
    });
}

void QuotaService::saveCurrentAccount() {
    QString error;
    m_accountMessage = m_accounts->saveCurrent(&error) ? tr("saved") : error;
    emit changed();
}

void QuotaService::switchAccount(const QString &id) {
    QString error;
    m_accountMessage = m_accounts->switchTo(id, &error) ? QString() : error;
    codexAccountChanged();
}

void QuotaService::removeAccount(const QString &id) {
    QString error;
    m_accountMessage = m_accounts->remove(id, &error) ? QString() : error;
    codexAccountChanged();
}

void QuotaService::codexAccountChanged() {
    // The old account's quota must not show under the new one, including a fetch still in flight.
    ++m_codexGeneration;
    m_codex.hasResult = false;
    m_codex.error.clear();
    refreshCodex();
}

QString QuotaService::findCodexCli() const {
    // CodexExecutableResolver: explicit variables, PATH (with PATHEXT), then the npm / bun / local
    // install folders.
    for (const char *name : {"CODEX_BINARY", "CODEX_CLI_PATH"}) {
        const QString explicitPath = qEnvironmentVariable(name).trimmed();
        if (QFileInfo(explicitPath).isFile()) return explicitPath;
    }
    const QString onPath = QStandardPaths::findExecutable("codex");
    if (!onPath.isEmpty()) return onPath;
    const QString appData = qEnvironmentVariable("APPDATA");
    return firstExisting({appData + "/npm/codex.cmd", m_home + "/.local/bin/codex.exe", m_home + "/.bun/bin/codex.exe",
                          qEnvironmentVariable("LOCALAPPDATA") + "/Programs/codex/codex.exe"});
}

void QuotaService::addAccount() {
    if (m_login) return;
    if (m_codexCli.isEmpty()) m_codexCli = findCodexCli();
    if (m_codexCli.isEmpty()) {
        m_accountMessage = QStringLiteral("codexCliMissing");
        emit changed();
        return;
    }
    // A throwaway CODEX_HOME: the current login stays untouched until the new one is saved.
    m_loginHome = m_dataDir + "/managed-codex-homes/" + QUuid::createUuid().toString(QUuid::WithoutBraces);
    QDir().mkpath(m_loginHome);
    auto *process = new QProcess(this);
    QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
    env.insert("CODEX_HOME", QDir::toNativeSeparators(m_loginHome));
    process->setProcessEnvironment(env);
    process->setProcessChannelMode(QProcess::MergedChannels);
    if (m_codexCli.endsWith(".cmd", Qt::CaseInsensitive) || m_codexCli.endsWith(".bat", Qt::CaseInsensitive)) {
        process->setProgram("cmd.exe");
        process->setArguments({"/d", "/c", QDir::toNativeSeparators(m_codexCli), "login"});
    } else {
        process->setProgram(m_codexCli);
        process->setArguments({"login"});
    }
    m_login = process;
    m_accountMessage = QStringLiteral("loginStarted");
    auto opened = std::make_shared<bool>(false);
    connect(process, &QProcess::readyRead, this, [process, opened] {
        static const QRegularExpression url("https://auth\\.openai\\.com/[^\\s\"'<>)]+");
        const auto match = url.match(QString::fromUtf8(process->peek(1 << 20)));
        if (match.hasMatch() && !*opened) {
            *opened = true;
            QDesktopServices::openUrl(QUrl(match.captured(0)));
        }
    });
    // Runs once: after `finished`, or after FailedToStart, which never emits `finished`.
    const auto finish = [this, process](bool ok, const QString &message) {
        if (m_login != process) return;
        m_accountMessage = message;
        QDir(m_loginHome).removeRecursively();
        process->deleteLater();
        m_login = nullptr;
        if (ok) codexAccountChanged();
        else emit changed();
    };
    connect(process, &QProcess::finished, this, [this, process, finish](int code, QProcess::ExitStatus status) {
        QString error;
        const bool ok = status == QProcess::NormalExit && code == 0
            && m_accounts->addFromFile(m_loginHome + "/auth.json", &error).has_value();
        finish(ok, ok ? QStringLiteral("accountAdded") : (error.isEmpty() ? QStringLiteral("loginFailed") : error));
    });
    connect(process, &QProcess::errorOccurred, this, [this, finish](QProcess::ProcessError error) {
        if (error != QProcess::FailedToStart) return; // the other errors are followed by `finished`
        m_codexCli.clear(); // the cached path may be stale (a CLI update): look it up again next time
        finish(false, QStringLiteral("loginFailed"));
    });
    QTimer::singleShot(kLoginTimeoutMs, process, [process] { process->kill(); });
    process->start();
    emit changed();
}

void QuotaService::cancelAddAccount() {
    if (m_login) m_login->kill();
}

// --- Claude ----------------------------------------------------------------------------------

void QuotaService::setClaudeConsent(bool allowed) {
    if (allowed == m_claudeConsent) return;
    m_claudeConsent = allowed;
    if (!allowed && m_claudeSource != "web") {
        ++m_claudeGeneration; // an OAuth read still in flight must not publish after the user said no
        m_claude.hasResult = false;
    }
    refreshClaude();
}

void QuotaService::setClaudeSource(const QString &source) {
    if (source == m_claudeSource) return;
    m_claudeSource = source;
    ++m_claudeGeneration;
    m_claude.hasResult = false;
    refreshClaude();
}

void QuotaService::setClaudeOrganization(const QString &uuid) {
    if (uuid == m_claudeOrganization) return;
    m_claudeOrganization = uuid;
    refreshClaude();
}

bool QuotaService::setClaudeSession(const QString &pasted) {
    const QString path = m_dataDir + "/secrets/claude-session.bin";
    if (pasted.trimmed().isEmpty()) {
        m_sessionKey.clear();
        QFile::remove(path);
        refreshClaude();
        return true;
    }
    const QString key = asb::quota::sanitizeClaudeSessionKey(pasted);
    if (key.isEmpty() || !asb::secrets::writeProtected(path, key.toUtf8())) return false;
    m_sessionKey = key;
    m_claude.retryAfterMs = 0;
    refreshClaude();
    return true;
}

bool QuotaService::hasClaudeCredentials() const {
    return asb::quota::readClaudeCredentials(m_home, qEnvironmentVariable("CLAUDE_CONFIG_DIR")).has_value();
}

void QuotaService::refreshClaude() {
    m_claudePending = true;
    tick();
    emit changed();
}

QString QuotaService::claudeCliVersion() {
    // ClaudeCodeVersion: `claude --version`, else the macOS fallback; looked up once.
    if (m_claudeVersionChecked) return m_claudeVersion;
    m_claudeVersionChecked = true;
    QString exe = QStandardPaths::findExecutable("claude");
    if (exe.isEmpty())
        exe = firstExisting({m_home + "/.local/bin/claude.exe", qEnvironmentVariable("APPDATA") + "/npm/claude.cmd"});
    if (exe.isEmpty()) return m_claudeVersion;
    QProcess process;
    if (exe.endsWith(".cmd", Qt::CaseInsensitive)) process.start("cmd.exe", {"/d", "/c", QDir::toNativeSeparators(exe), "--version"});
    else process.start(exe, {"--version"});
    if (process.waitForFinished(5000)) {
        static const QRegularExpression version("(\\d+\\.\\d+\\.\\d+)");
        const auto match = version.match(QString::fromUtf8(process.readAllStandardOutput()));
        if (match.hasMatch()) m_claudeVersion = match.captured(1);
    } else {
        process.kill();
    }
    return m_claudeVersion;
}

void QuotaService::startClaudeFetch() {
    m_claudePending = false;
    m_claudeFetchedAtMs = nowMs();
    const bool useOAuth = m_claudeSource != "web";
    const bool useWeb = m_claudeSource != "oauth" && !m_sessionKey.isEmpty();
    if (m_claude.retryAfterMs > nowMs()) return; // a 429 asked us to wait
    std::optional<asb::quota::ClaudeCredentials> credentials;
    if (useOAuth && m_claudeConsent)
        credentials = asb::quota::readClaudeCredentials(m_home, qEnvironmentVariable("CLAUDE_CONFIG_DIR"));
    if (!credentials && !useWeb) {
        m_claude.error = m_claudeSource == "web" ? QStringLiteral("noSession")
            : !m_claudeConsent ? QStringLiteral("consentRequired") : QStringLiteral("noCredentials");
        m_claude.hasResult = false;
        emit changed();
        return;
    }
    m_claude.fetching = true;
    emit changed();
    const QString version = claudeCliVersion();
    const QString sessionKey = useWeb ? m_sessionKey : QString();
    const QString organization = m_claudeOrganization;
    QPointer<QuotaService> self(this);
    const quint64 generation = m_claudeGeneration;
    QThreadPool::globalInstance()->start([self, credentials, version, sessionKey, organization, generation] {
        asb::quota::ClaudeResult result;
        if (credentials) result = asb::quota::fetchClaudeOAuth(*credentials, version, asb::quota::blockingHttp, nowMs());
        // automatic: OAuth first, then the web session; a 429 ends the chain.
        if ((!credentials || !result.ok) && !sessionKey.isEmpty() && result.error != "rateLimited")
            result = asb::quota::fetchClaudeWeb(sessionKey, organization, asb::quota::blockingHttp);
        QMetaObject::invokeMethod(QCoreApplication::instance(), [self, result, generation] {
            if (!self) return;
            ClaudeState &state = self->m_claude;
            state.fetching = false;
            if (generation != self->m_claudeGeneration) { // another source, or consent withdrawn
                emit self->changed();
                self->tick();
                return;
            }
            state.error = result.ok ? QString() : result.error;
            if (result.error == "rateLimited") state.retryAfterMs = result.retryAfterMs;
            if (result.ok) {
                state.result = result;
                state.hasResult = true;
                state.updatedAtMs = nowMs();
            } else {
                state.result.organizations = result.organizations;
                if (result.error == "loginRequired" || result.error == "unauthorized") state.hasResult = false;
            }
            emit self->changed();
            if (self->m_claudePending) self->tick();
        }, Qt::QueuedConnection);
    });
}

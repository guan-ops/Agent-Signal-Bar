// Account quota for the Usage page, the tray card and the floating quota badge
// (MenuBarStatusModel's Codex usage refresh and ClaudeSupportModel). Fetches run on a worker
// thread, one per provider at a time, at most once a minute unless forced; paused monitoring
// stops them and keeps the last result.
//
// Codex: the saved accounts (CodexAccounts), quota and limit reset credits (QuotaFetcher). The data
// source is "automatic" (a pasted chatgpt.com cookie first when the cookie mode is "manual") or
// "oauth-api". "Add account" runs `codex login` with a temporary CODEX_HOME and opens the sign-in
// page it prints.
// Claude: nothing is read until the user allows reading the Claude Code credentials; the source is
// "oauth" (default), "web" (a pasted claude.ai sessionKey) or "automatic" (OAuth, then web).
// Pasted cookies are stored DPAPI-encrypted in %APPDATA%\AgentSignalBar\secrets.
#pragma once

#include "QuotaFetcher.h"

#include <QObject>
#include <QPointer>
#include <QProcess>
#include <QTimer>
#include <memory>



namespace asb::codexauth {
class AccountStore;
}

class QuotaService : public QObject {
    Q_OBJECT
public:
    struct CodexState {
        bool fetching = false;
        bool hasResult = false;
        qint64 updatedAtMs = 0;
        QString error; // last failure code (QuotaFetcher), "" after a success
        asb::quota::CodexResult result;
    };
    struct ClaudeState {
        bool fetching = false;
        bool hasResult = false;
        qint64 updatedAtMs = 0;
        QString error; // consentRequired, noCredentials, rateLimited, ... (QuotaFetcher)
        qint64 retryAfterMs = 0;
        asb::quota::ClaudeResult result;
    };

    // `dataDir`: %APPDATA%\AgentSignalBar; `home`: the user profile.
    QuotaService(QString dataDir, QString home, QObject *parent = nullptr);
    ~QuotaService() override;

    void start(bool network);
    void setPaused(bool paused);
    void setCodexHome(const QString &codexHomeEnv);

    // Codex.
    const CodexState &codex() const { return m_codex; }
    asb::codexauth::AccountStore &accounts() const { return *m_accounts; }
    QString codexAuthPath() const { return m_authPath; }
    bool codexCliFound() const { return !m_codexCli.isEmpty(); }
    bool addingAccount() const { return m_login != nullptr; }
    QString accountMessage() const { return m_accountMessage; }
    void setCodexSource(const QString &source); // automatic | oauth-api
    void setCookieMode(const QString &mode);    // off | manual
    bool hasCookie() const { return !m_cookie.isEmpty(); }
    void setCookie(const QString &pasted); // "" clears; invalid input is refused
    void refreshCodex();
    void saveCurrentAccount();
    void switchAccount(const QString &id);
    void removeAccount(const QString &id);
    void addAccount();
    void cancelAddAccount();

    // Claude.
    const ClaudeState &claude() const { return m_claude; }
    void setClaudeConsent(bool allowed);
    void setClaudeSource(const QString &source); // oauth | web | automatic
    void setClaudeOrganization(const QString &uuid);
    bool hasClaudeSession() const { return !m_sessionKey.isEmpty(); }
    bool setClaudeSession(const QString &pasted); // "" clears; false when invalid
    bool hasClaudeCredentials() const;
    void refreshClaude();

signals:
    void changed();

private:
    void tick();
    void startCodexFetch();
    void codexAccountChanged();
    void claudeSessionChanged();
    void startClaudeFetch();
    QString findCodexCli() const;
    QString claudeCliVersion();

    QString m_dataDir;
    QString m_home;
    QString m_authPath;
    QString m_configPath;
    std::unique_ptr<asb::codexauth::AccountStore> m_accounts;
    QTimer m_timer;
    bool m_started = false;
    bool m_network = false;
    bool m_paused = false;

    CodexState m_codex;
    QString m_codexSource = QStringLiteral("automatic");
    QString m_cookieMode = QStringLiteral("off");
    QString m_cookie;
    qint64 m_codexFetchedAtMs = 0;
    bool m_codexPending = false;
    quint64 m_codexGeneration = 0; // bumped when the account or source changes; older results are dropped
    QString m_codexCli;
    QPointer<QProcess> m_login;
    QString m_loginHome;
    QString m_accountMessage;

    ClaudeState m_claude;
    bool m_claudeConsent = false;
    QString m_claudeSource = QStringLiteral("oauth");
    QString m_claudeOrganization;
    QString m_sessionKey;
    qint64 m_claudeFetchedAtMs = 0;
    bool m_claudePending = false;
    quint64 m_claudeGeneration = 0; // bumped when the source changes or consent is withdrawn
    QString m_claudeVersion;
    bool m_claudeVersionChecked = false;
};

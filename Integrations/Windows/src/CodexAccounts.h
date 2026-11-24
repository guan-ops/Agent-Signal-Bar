// Codex credentials and saved accounts, ported from CodexAccountManager.swift and the
// credential half of CodexRateLimitFetcher.swift.
//
// The active login is <CODEX_HOME or %USERPROFILE%\.codex>\auth.json, owned by the Codex CLI.
// Saved accounts keep a full copy of that file each: the list (labels, emails, plan, ids, no
// secrets) is %APPDATA%\AgentSignalBar\codex-accounts.json, and every copy is a DPAPI-encrypted
// file under codex-accounts\ (the macOS Keychain items). Switching writes the chosen copy over
// auth.json; every write to auth.json first checks that the file still has the bytes it was read
// with, so a concurrent `codex login` or token refresh is never overwritten.
#pragma once

#include <QByteArray>
#include <QList>
#include <QString>
#include <optional>

namespace asb::codexauth {

struct Identity {
    QString email;
    QString accountId;
    QString plan;
    QString kind; // oauth | apiKey | unknown
};

struct Credentials {
    QString accessToken;
    QString refreshToken;
    QString idToken;
    QString accountId; // tokens.account_id only (the fetcher's rule)
    QString email;     // from the id_token
    std::optional<qint64> lastRefreshMs;
    bool apiKey = false;
    QByteArray fileData;
    QString fingerprint;
};

// CODEX_HOME (trimmed, "~" expanded) else <home>/.codex, plus /auth.json.
QString authFilePath(const QString &home, const QString &codexHomeEnv);
QString fingerprint(const QByteArray &data); // SHA-256 hex of the raw bytes
std::optional<Identity> parseIdentity(const QByteArray &authJson);
// nullopt when there is neither an API key nor an access token.
std::optional<Credentials> parseCredentials(const QByteArray &authJson);
// refreshedAuthData: the same document with new tokens and last_refresh = now (ISO 8601).
QByteArray refreshedAuthData(const QByteArray &original, const Credentials &refreshed, qint64 nowMs);
// Writes `data` to `path` atomically when the file's current fingerprint is `expected` (an empty
// `expected` means the file must not exist). False, with `error`, otherwise.
bool replaceIfUnchanged(const QString &path, const QString &expected, const QByteArray &data, QString *error);

struct Account {
    QString id; // UUID
    QString label;
    QString email;
    QString accountId;
    QString kind;
    QString plan;
    QString fingerprint; // of the saved copy
    qint64 createdAtMs = 0;
    qint64 updatedAtMs = 0;
};

class AccountStore {
public:
    // `dir`: where codex-accounts.json and codex-accounts\ live.
    AccountStore(QString dir, QString authPath);

    QList<Account> accounts() const;
    // The saved account that matches the current auth.json: account id first, then email (only
    // without an account id, same credential kind), then the exact bytes.
    std::optional<Account> active() const;
    // auth.json exists and is not saved with these exact bytes.
    bool currentNeedsSaving() const;
    std::optional<QByteArray> secret(const QString &id) const;

    // Copies the current auth.json into a new or the matching account. Returns its id.
    std::optional<QString> saveCurrent(QString *error);
    // Saves the current login if needed, then writes the account's copy over auth.json.
    bool switchTo(const QString &id, QString *error);
    // Forgets the account; if it was active, activates the first remaining one or removes auth.json.
    bool remove(const QString &id, QString *error);
    // Adds the auth.json a `codex login` wrote into a temporary CODEX_HOME, then switches to it.
    std::optional<QString> addFromFile(const QString &authPath, QString *error);
    // A token refresh rewrote the copy that had `oldFingerprint`: keep the saved copy current.
    // Called from a worker thread; every method that changes the saved accounts shares one lock.
    void persistRefreshed(const QString &oldFingerprint, const QByteArray &data);

private:
    QList<Account> load() const;
    bool save(const QList<Account> &accounts) const;
    QString secretPath(const QString &id) const;
    std::optional<int> match(const QList<Account> &accounts, const Identity &identity, const QString &fp) const;
    std::optional<QString> store(const QByteArray &data, QString *error);
    // Saves the current login (possibly refreshed since it was saved) before it is replaced.
    // `current` / `exists`: what auth.json held, for replaceIfUnchanged.
    bool keepCurrentLogin(QByteArray *current, bool *exists, QString *error);

    QString m_dir;
    QString m_authPath;
};

} // namespace asb::codexauth

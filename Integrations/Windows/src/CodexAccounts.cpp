#include "CodexAccounts.h"

#include "Secrets.h"

#include <QCryptographicHash>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QMutexLocker>
#include <QRecursiveMutex>
#include <QSaveFile>
#include <QTimeZone>
#include <QUuid>

#ifdef Q_OS_WIN
#include <windows.h>
#endif

namespace asb::codexauth {
namespace {

// Every load-modify-save of codex-accounts.json and the secret copies: a token refresh writes
// back from a worker thread while the account buttons change the list on the UI thread, and
// QSaveFile makes each write atomic but cannot stop one from overwriting the other's update.
// Recursive: switchTo and addFromFile call store.
QRecursiveMutex &accountsLock() {
    static QRecursiveMutex lock;
    return lock;
}

QString firstString(std::initializer_list<QJsonValue> values) {
    for (const QJsonValue &value : values) {
        const QString text = value.toString().trimmed();
        if (!text.isEmpty()) return text;
    }
    return QString();
}

QJsonObject jwtPayload(const QString &token) {
    const QStringList parts = token.split('.');
    if (parts.size() < 2) return {};
    const QByteArray decoded = QByteArray::fromBase64(parts.at(1).toLatin1(),
                                                      QByteArray::Base64UrlEncoding | QByteArray::OmitTrailingEquals);
    return QJsonDocument::fromJson(decoded).object();
}

QJsonObject parseObject(const QByteArray &data) { return QJsonDocument::fromJson(data).object(); }

QByteArray readAll(const QString &path, bool *exists = nullptr) {
    QFile file(path);
    if (exists) *exists = file.exists();
    if (!file.open(QIODevice::ReadOnly)) return QByteArray();
    return file.readAll();
}

} // namespace

QString authFilePath(const QString &home, const QString &codexHomeEnv) {
    QString root = codexHomeEnv.trimmed();
    if (root.isEmpty()) root = home + "/.codex";
    else if (root == "~") root = home;
    else if (root.startsWith("~/") || root.startsWith("~\\")) root = home + '/' + root.mid(2);
    return QDir::cleanPath(root + "/auth.json");
}

QString fingerprint(const QByteArray &data) {
    return QString::fromLatin1(QCryptographicHash::hash(data, QCryptographicHash::Sha256).toHex());
}

std::optional<Identity> parseIdentity(const QByteArray &authJson) {
    QJsonParseError error;
    const QJsonDocument document = QJsonDocument::fromJson(authJson, &error);
    if (error.error != QJsonParseError::NoError || !document.isObject()) return std::nullopt;
    const QJsonObject json = document.object();
    Identity identity;
    if (!json.value("OPENAI_API_KEY").toString().trimmed().isEmpty()) {
        identity.kind = QStringLiteral("apiKey");
        return identity;
    }
    const QJsonObject tokens = json.value("tokens").toObject();
    const QJsonObject payload = jwtPayload(firstString({tokens.value("id_token"), tokens.value("idToken")}));
    const QJsonObject auth = payload.value("https://api.openai.com/auth").toObject();
    identity.email = firstString({payload.value("email"), payload.value("preferred_username"), auth.value("email")});
    identity.accountId = firstString({tokens.value("account_id"), tokens.value("accountId"), json.value("account_id"),
                                      json.value("accountId"), auth.value("chatgpt_account_id"),
                                      payload.value("chatgpt_account_id")});
    identity.plan = firstString({auth.value("plan"), auth.value("plan_name"), auth.value("plan_type"),
                                 auth.value("chatgpt_plan"), auth.value("chatgpt_plan_name"),
                                 auth.value("chatgpt_plan_type"), payload.value("plan"), payload.value("plan_name"),
                                 payload.value("plan_type"), payload.value("chatgpt_plan"),
                                 payload.value("chatgpt_plan_name"), payload.value("chatgpt_plan_type"),
                                 json.value("plan"), json.value("plan_name"), json.value("plan_type")});
    identity.kind = firstString({tokens.value("access_token"), tokens.value("accessToken")}).isEmpty()
        ? QStringLiteral("unknown") : QStringLiteral("oauth");
    return identity;
}

std::optional<Credentials> parseCredentials(const QByteArray &authJson) {
    const QJsonObject json = parseObject(authJson);
    if (json.isEmpty()) return std::nullopt;
    Credentials c;
    c.fileData = authJson;
    c.fingerprint = fingerprint(authJson);
    if (!json.value("OPENAI_API_KEY").toString().trimmed().isEmpty()) {
        c.apiKey = true;
        return c;
    }
    const QJsonObject tokens = json.value("tokens").toObject();
    c.accessToken = firstString({tokens.value("access_token"), tokens.value("accessToken")});
    if (c.accessToken.isEmpty()) return std::nullopt;
    c.refreshToken = firstString({tokens.value("refresh_token"), tokens.value("refreshToken")});
    c.idToken = firstString({tokens.value("id_token"), tokens.value("idToken")});
    c.accountId = tokens.value("account_id").toString().trimmed();
    const QJsonObject payload = jwtPayload(c.idToken);
    c.email = firstString({payload.value("email"), payload.value("preferred_username"),
                           payload.value("https://api.openai.com/auth").toObject().value("email")});
    const QString last = json.value("last_refresh").toString();
    QDateTime when = QDateTime::fromString(last, Qt::ISODateWithMs);
    if (!when.isValid()) when = QDateTime::fromString(last, Qt::ISODate);
    if (when.isValid()) c.lastRefreshMs = when.toMSecsSinceEpoch();
    return c;
}

QByteArray refreshedAuthData(const QByteArray &original, const Credentials &refreshed, qint64 nowMs) {
    QJsonObject json = parseObject(original);
    QJsonObject tokens = json.value("tokens").toObject();
    tokens.insert("access_token", refreshed.accessToken);
    tokens.insert("refresh_token", refreshed.refreshToken);
    if (!refreshed.idToken.isEmpty()) tokens.insert("id_token", refreshed.idToken);
    if (!refreshed.accountId.isEmpty()) tokens.insert("account_id", refreshed.accountId);
    json.insert("tokens", tokens);
    json.insert("last_refresh", QDateTime::fromMSecsSinceEpoch(nowMs, QTimeZone::UTC).toString(Qt::ISODate));
    return QJsonDocument(json).toJson(QJsonDocument::Indented);
}

bool replaceIfUnchanged(const QString &path, const QString &expected, const QByteArray &data, QString *error) {
    bool exists = false;
    const QByteArray current = readAll(path, &exists);
    const bool unchanged = expected.isEmpty() ? !exists : (exists && fingerprint(current) == expected);
    if (!unchanged) {
        if (error) *error = QStringLiteral("auth.json changed meanwhile");
        return false;
    }
    QDir().mkpath(QFileInfo(path).absolutePath());
    QSaveFile file(path); // a temporary file renamed over the original
    if (!file.open(QIODevice::WriteOnly) || file.write(data) != data.size() || !file.commit()) {
        if (error) *error = QStringLiteral("cannot write ") + QDir::toNativeSeparators(path);
        return false;
    }
    return true;
}

// --- Saved accounts --------------------------------------------------------------------------

AccountStore::AccountStore(QString dir, QString authPath) : m_dir(std::move(dir)), m_authPath(std::move(authPath)) {}

QString AccountStore::secretPath(const QString &id) const { return m_dir + "/codex-accounts/" + id + ".bin"; }

QList<Account> AccountStore::load() const {
    QList<Account> accounts;
    const QJsonArray list = parseObject(readAll(m_dir + "/codex-accounts.json")).value("accounts").toArray();
    for (const QJsonValue &value : list) {
        const QJsonObject o = value.toObject();
        Account a;
        a.id = o.value("id").toString();
        if (a.id.isEmpty()) continue;
        a.label = o.value("label").toString();
        a.email = o.value("email").toString();
        a.accountId = o.value("accountID").toString();
        a.kind = o.value("credentialKind").toString();
        a.plan = o.value("planName").toString();
        a.fingerprint = o.value("authFingerprint").toString();
        a.createdAtMs = qint64(o.value("createdAt").toDouble());
        a.updatedAtMs = qint64(o.value("updatedAt").toDouble());
        accounts.append(a);
    }
    return accounts;
}

bool AccountStore::save(const QList<Account> &accounts) const {
    QJsonArray list;
    for (const Account &a : accounts) {
        list.append(QJsonObject{{"id", a.id}, {"label", a.label}, {"email", a.email}, {"accountID", a.accountId},
                                {"credentialKind", a.kind}, {"planName", a.plan}, {"authFingerprint", a.fingerprint},
                                {"createdAt", double(a.createdAtMs)}, {"updatedAt", double(a.updatedAtMs)}});
    }
    QDir().mkpath(m_dir);
    QSaveFile file(m_dir + "/codex-accounts.json");
    const QByteArray data = QJsonDocument(QJsonObject{{"version", 1}, {"accounts", list}}).toJson(QJsonDocument::Indented);
    return file.open(QIODevice::WriteOnly) && file.write(data) == data.size() && file.commit();
}

QList<Account> AccountStore::accounts() const { return load(); }

std::optional<int> AccountStore::match(const QList<Account> &accounts, const Identity &identity, const QString &fp) const {
    if (!identity.accountId.isEmpty()) {
        for (int i = 0; i < accounts.size(); ++i) {
            if (accounts[i].accountId.compare(identity.accountId, Qt::CaseInsensitive) == 0) return i;
        }
    }
    if (identity.accountId.isEmpty() && !identity.email.isEmpty()) {
        for (int i = 0; i < accounts.size(); ++i) {
            if (accounts[i].accountId.isEmpty() && accounts[i].kind == identity.kind
                && accounts[i].email.compare(identity.email, Qt::CaseInsensitive) == 0)
                return i;
        }
    }
    for (int i = 0; i < accounts.size(); ++i) {
        if (accounts[i].fingerprint == fp) return i;
    }
    return std::nullopt;
}

std::optional<Account> AccountStore::active() const {
    const QByteArray data = readAll(m_authPath);
    const auto identity = parseIdentity(data);
    if (data.isEmpty() || !identity) return std::nullopt;
    const QList<Account> accounts = load();
    const auto index = match(accounts, *identity, fingerprint(data));
    return index ? std::optional<Account>(accounts.at(*index)) : std::nullopt;
}

bool AccountStore::currentNeedsSaving() const {
    const QByteArray data = readAll(m_authPath);
    if (data.isEmpty() || !parseIdentity(data)) return false;
    const auto account = active();
    return !account || account->fingerprint != fingerprint(data);
}

std::optional<QByteArray> AccountStore::secret(const QString &id) const { return secrets::readProtected(secretPath(id)); }

std::optional<QString> AccountStore::store(const QByteArray &data, QString *error) {
    const QMutexLocker locker(&accountsLock());
    const auto identity = parseIdentity(data);
    if (!identity) {
        if (error) *error = QStringLiteral("auth.json is not valid JSON");
        return std::nullopt;
    }
    QList<Account> accounts = load();
    const QString fp = fingerprint(data);
    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    const auto index = match(accounts, *identity, fp);
    Account account = index ? accounts.at(*index) : Account{};
    if (!index) {
        account.id = QUuid::createUuid().toString(QUuid::WithoutBraces).toUpper();
        account.createdAtMs = now;
    }
    account.email = identity->email;
    account.accountId = identity->accountId;
    account.kind = identity->kind;
    if (!identity->plan.isEmpty()) account.plan = identity->plan;
    account.fingerprint = fp;
    account.updatedAtMs = now;
    if (!secrets::writeProtected(secretPath(account.id), data)) {
        if (error) *error = QStringLiteral("cannot store the account securely");
        return std::nullopt;
    }
    if (index) accounts[*index] = account;
    else accounts.append(account);
    if (!save(accounts)) {
        if (error) *error = QStringLiteral("cannot write codex-accounts.json");
        return std::nullopt;
    }
    return account.id;
}

std::optional<QString> AccountStore::saveCurrent(QString *error) {
    const QMutexLocker locker(&accountsLock());
    const QByteArray data = readAll(m_authPath);
    if (data.isEmpty()) {
        if (error) *error = QStringLiteral("no Codex login (auth.json) to save");
        return std::nullopt;
    }
    return store(data, error);
}

bool AccountStore::keepCurrentLogin(QByteArray *current, bool *exists, QString *error) {
    const QMutexLocker locker(&accountsLock());
    *current = readAll(m_authPath, exists);
    if (!*exists || current->isEmpty() || !parseIdentity(*current) || !currentNeedsSaving()) return true;
    return store(*current, error).has_value();
}

bool AccountStore::switchTo(const QString &id, QString *error) {
    const QMutexLocker locker(&accountsLock());
    const QList<Account> accounts = load();
    const auto target = std::find_if(accounts.cbegin(), accounts.cend(), [&](const Account &a) { return a.id == id; });
    if (target == accounts.cend()) {
        if (error) *error = QStringLiteral("unknown account");
        return false;
    }
    bool exists = false;
    QByteArray current;
    if (!keepCurrentLogin(&current, &exists, error)) return false;
    const auto data = secret(id);
    if (!data) {
        if (error) *error = QStringLiteral("the saved copy of this account cannot be read");
        return false;
    }
    return replaceIfUnchanged(m_authPath, exists ? fingerprint(current) : QString(), *data, error);
}

bool AccountStore::remove(const QString &id, QString *error) {
    const QMutexLocker locker(&accountsLock());
    QList<Account> accounts = load();
    const auto it = std::find_if(accounts.begin(), accounts.end(), [&](const Account &a) { return a.id == id; });
    if (it == accounts.end()) return true;
    const auto activeAccount = active();
    const bool wasActive = activeAccount && activeAccount->id == id;
    accounts.erase(it);
    QFile::remove(secretPath(id));
    if (!save(accounts)) {
        if (error) *error = QStringLiteral("cannot write codex-accounts.json");
        return false;
    }
    if (!wasActive) return true;
    bool exists = false;
    const QByteArray current = readAll(m_authPath, &exists);
    if (!accounts.isEmpty()) {
        const auto next = secret(accounts.first().id);
        return next && replaceIfUnchanged(m_authPath, fingerprint(current), *next, error);
    }
    // No account left: sign out of Codex, as on macOS.
    if (exists && !QFile::remove(m_authPath)) {
        if (error) *error = QStringLiteral("cannot remove auth.json");
        return false;
    }
    return true;
}

std::optional<QString> AccountStore::addFromFile(const QString &authPath, QString *error) {
    const QMutexLocker locker(&accountsLock());
    const QByteArray data = readAll(authPath);
    if (data.isEmpty()) {
        if (error) *error = QStringLiteral("codex login wrote no auth.json");
        return std::nullopt;
    }
    // Keep the outgoing login first: when it is the same account (signing in again to replace an
    // expired login), storing it afterwards would put the old credentials back over the new ones.
    bool exists = false;
    QByteArray current;
    if (!keepCurrentLogin(&current, &exists, error)) return std::nullopt;
    const auto id = store(data, error);
    if (!id || !replaceIfUnchanged(m_authPath, exists ? fingerprint(current) : QString(), data, error))
        return std::nullopt;
    return id;
}

void AccountStore::persistRefreshed(const QString &oldFingerprint, const QByteArray &data) {
    const QMutexLocker locker(&accountsLock());
    QList<Account> accounts = load();
    for (Account &account : accounts) {
        if (account.fingerprint != oldFingerprint) continue;
        if (!secrets::writeProtected(secretPath(account.id), data)) return;
        account.fingerprint = fingerprint(data);
        account.updatedAtMs = QDateTime::currentMSecsSinceEpoch();
        save(accounts);
        return;
    }
}

} // namespace asb::codexauth

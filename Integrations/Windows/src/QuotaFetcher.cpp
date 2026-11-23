#include "QuotaFetcher.h"

#include "CodexAccounts.h"

#include <QCryptographicHash>
#include <QDateTime>
#include <QEventLoop>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QRegularExpression>
#include <QSet>
#include <QUrlQuery>
#include <algorithm>
#include <cmath>

namespace asb::quota {
namespace {

constexpr qint64 kRefreshAgeMs = 8LL * 24 * 3600'000; // CodexRateLimitFetcher: refresh after 8 days
constexpr char kUserAgent[] = "AgentSignalBar";
constexpr char kOpenAIClientId[] = "app_EMoamEEZ73f0CkXaXp7hrann";

std::optional<double> flexibleDouble(const QJsonValue &value) {
    if (value.isDouble()) return std::isfinite(value.toDouble()) ? std::optional<double>(value.toDouble()) : std::nullopt;
    if (value.isString()) {
        bool ok = false;
        const double d = value.toString().trimmed().toDouble(&ok);
        if (ok && std::isfinite(d)) return d;
    }
    return std::nullopt;
}

std::optional<double> number(const QJsonValue &value) { // a JSON number, not a boolean
    return value.isDouble() && std::isfinite(value.toDouble()) ? std::optional<double>(value.toDouble()) : std::nullopt;
}

std::optional<qint64> isoMs(const QJsonValue &value) {
    const QString text = value.toString();
    if (text.isEmpty()) return std::nullopt;
    QDateTime dt = QDateTime::fromString(text, Qt::ISODateWithMs);
    if (!dt.isValid()) dt = QDateTime::fromString(text, Qt::ISODate);
    return dt.isValid() ? std::optional<qint64>(dt.toMSecsSinceEpoch()) : std::nullopt;
}

QJsonObject object(const QByteArray &body) { return QJsonDocument::fromJson(body).object(); }

std::optional<Window> codexWindow(const QJsonValue &value, const QString &id) {
    const QJsonObject w = value.toObject();
    const auto used = number(w.value("used_percent"));
    if (!used || !w.value("reset_at").isDouble() || !w.value("limit_window_seconds").isDouble()) return std::nullopt;
    Window window;
    window.id = id;
    window.usedPercent = std::clamp(*used, 0.0, 100.0);
    window.resetsAtMs = qint64(w.value("reset_at").toDouble()) * 1000;
    window.minutes = int(w.value("limit_window_seconds").toDouble()) / 60;
    return window;
}

QJsonObject individualLimit(const QJsonObject &o) {
    return o.value("individual_limit").isObject() ? o.value("individual_limit").toObject()
                                                  : o.value("individualLimit").toObject();
}

// SpendControlLimitSnapshot.creditStatus
std::optional<Credit> limitCredit(const QJsonObject &l) {
    const auto limit = flexibleDouble(l.value("limit"));
    const auto usedValue = flexibleDouble(l.value("used"));
    auto remainingPercent = flexibleDouble(l.value("remainingPercent"));
    if (!remainingPercent) remainingPercent = flexibleDouble(l.value("remaining_percent"));
    if (!limit || *limit <= 0 || (!usedValue && !remainingPercent)) return std::nullopt;
    const double used = usedValue ? std::max(0.0, *usedValue)
                                  : *limit * std::clamp(100 - *remainingPercent, 0.0, 100.0) / 100;
    Credit credit;
    credit.title = QStringLiteral("Monthly credit limit");
    credit.used = used;
    credit.limit = *limit;
    credit.remaining = std::max(0.0, *limit - used);
    credit.remainingPercent = remainingPercent ? *remainingPercent : std::clamp(100 - used / *limit * 100, 0.0, 100.0);
    auto resets = flexibleDouble(l.value("resetsAt"));
    if (!resets) resets = flexibleDouble(l.value("resets_at"));
    if (resets && *resets > 0) credit.resetsAtMs = qint64(*resets) * 1000;
    return credit;
}

QString findEmail(const QJsonValue &value, int depth = 0) {
    if (depth > 8) return QString();
    if (value.isObject()) {
        const QJsonObject o = value.toObject();
        if (o.value("email").isString() && !o.value("email").toString().trimmed().isEmpty())
            return o.value("email").toString().trimmed();
        for (auto it = o.constBegin(); it != o.constEnd(); ++it) {
            const QString found = findEmail(it.value(), depth + 1);
            if (!found.isEmpty()) return found;
        }
    } else if (value.isArray()) {
        for (const QJsonValue &item : value.toArray()) {
            const QString found = findEmail(item, depth + 1);
            if (!found.isEmpty()) return found;
        }
    }
    return QString();
}

QString chatgptBaseUrl(const QString &configPath) {
    QFile file(configPath);
    if (file.open(QIODevice::ReadOnly)) {
        static const QRegularExpression line("^\\s*chatgpt_base_url\\s*=\\s*[\"']([^\"']+)[\"']", QRegularExpression::MultilineOption);
        const auto match = line.match(QString::fromUtf8(file.readAll()));
        if (match.hasMatch()) {
            QString base = match.captured(1).trimmed();
            while (base.endsWith('/')) base.chop(1);
            if (base.startsWith("https://")) return base;
        }
    }
    return QStringLiteral("https://chatgpt.com/backend-api");
}

HttpRequest get(const QString &url, int timeoutMs = 30'000) {
    HttpRequest request;
    request.url = QUrl(url);
    request.timeoutMs = timeoutMs;
    request.headers.emplaceBack("Accept", "application/json");
    return request;
}

} // namespace

// --- HTTP ------------------------------------------------------------------------------------

HttpResponse blockingHttp(const HttpRequest &request) {
    QNetworkAccessManager network;
    network.setRedirectPolicy(QNetworkRequest::ManualRedirectPolicy);
    QNetworkRequest r(request.url);
    r.setTransferTimeout(request.timeoutMs);
    r.setAttribute(QNetworkRequest::CookieLoadControlAttribute, QNetworkRequest::Manual);
    r.setAttribute(QNetworkRequest::CookieSaveControlAttribute, QNetworkRequest::Manual);
    for (const auto &[name, value] : request.headers) r.setRawHeader(name, value);
    QNetworkReply *reply = network.sendCustomRequest(r, request.method, request.body);
    QEventLoop loop;
    QObject::connect(reply, &QNetworkReply::finished, &loop, &QEventLoop::quit);
    loop.exec();
    HttpResponse response;
    response.status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    response.body = reply->readAll();
    for (const auto &[name, value] : reply->rawHeaderPairs()) response.headers.insert(name.toLower(), value);
    delete reply;
    return response;
}

// --- Codex -----------------------------------------------------------------------------------

std::optional<CodexUsage> parseCodexUsage(const QByteArray &json) {
    const QJsonObject root = object(json);
    if (root.isEmpty()) return std::nullopt;
    const QJsonObject rate = root.value("rate_limit").toObject();
    CodexUsage usage;
    usage.plan = root.value("plan_type").toString();
    usage.limitId = rate.value("limit_id").toString(root.value("limit_id").toString());
    usage.limitName = rate.value("limit_name").toString(root.value("limit_name").toString());
    const auto primary = codexWindow(rate.value("primary_window"), "primary");
    const auto secondary = codexWindow(rate.value("secondary_window"), "secondary");
    usage.primary = primary ? primary : secondary;
    if (primary) usage.secondary = secondary;

    QJsonObject limit = individualLimit(root);
    if (limit.isEmpty()) limit = individualLimit(rate);
    if (limit.isEmpty()) limit = individualLimit(root.value("spend_control").toObject());
    auto balance = flexibleDouble(root.value("credits").toObject().value("balance"));
    if (balance && *balance < 0) balance.reset();
    if (auto credit = limitCredit(limit)) {
        credit->balance = balance;
        usage.credits = credit;
    } else if (balance) {
        Credit credit;
        credit.title = QStringLiteral("Credits");
        credit.remaining = *balance;
        credit.balance = balance;
        usage.credits = credit;
    }
    if (!usage.primary && !usage.credits) return std::nullopt;
    return usage;
}

std::optional<ResetCredits> parseResetCredits(const QByteArray &json) {
    const QJsonObject root = object(json);
    if (root.isEmpty() || !root.value("available_count").isDouble()) return std::nullopt;
    ResetCredits credits;
    credits.availableCount = root.value("available_count").toInt();
    for (const QJsonValue &value : root.value("credits").toArray()) {
        const QJsonObject c = value.toObject();
        credits.credits.append({c.value("status").toString(), isoMs(c.value("expires_at"))});
    }
    return credits;
}

QList<ResetCredit> availableResetCredits(const ResetCredits &credits, qint64 nowMs) {
    QList<ResetCredit> out;
    for (const ResetCredit &c : credits.credits) {
        if (c.status == "available" && (!c.expiresAtMs || *c.expiresAtMs > nowMs)) out.append(c);
    }
    std::stable_sort(out.begin(), out.end(), [](const ResetCredit &a, const ResetCredit &b) {
        if (a.expiresAtMs.has_value() != b.expiresAtMs.has_value()) return a.expiresAtMs.has_value();
        return a.expiresAtMs.value_or(0) < b.expiresAtMs.value_or(0);
    });
    return out;
}

QString sanitizeCookieHeader(const QString &pasted) {
    const QString text = pasted.trimmed();
    if (text.isEmpty() || text.contains('\r') || (text.contains('\n') && !text.contains("curl"))) return QString();
    static const QRegularExpression header("(?:-H|--header)\\s+(['\"])\\s*cookie\\s*:\\s*(.*?)\\1",
                                           QRegularExpression::CaseInsensitiveOption);
    static const QRegularExpression cookieFlag("(?:-b|--cookie)\\s+(['\"])(.*?)\\1");
    QString cookies;
    if (const auto m = header.match(text); m.hasMatch()) cookies = m.captured(2);
    else if (const auto m2 = cookieFlag.match(text); m2.hasMatch()) cookies = m2.captured(2);
    else if (text.startsWith("cookie:", Qt::CaseInsensitive)) cookies = text.mid(7);
    else cookies = text;
    cookies = cookies.trimmed();
    if (cookies.contains('\n') || !cookies.contains('=')) return QString();
    return cookies;
}

namespace {

struct Refreshed {
    bool ok = false;
    bool rejected = false;
    codexauth::Credentials credentials;
};

Refreshed refreshToken(const codexauth::Credentials &credentials, const Http &http) {
    Refreshed result;
    if (credentials.refreshToken.isEmpty()) return result;
    HttpRequest request;
    request.method = "POST";
    request.url = QUrl(QStringLiteral("https://auth.openai.com/oauth/token"));
    request.headers.emplaceBack("Content-Type", "application/json");
    request.headers.emplaceBack("Accept", "application/json");
    request.body = QJsonDocument(QJsonObject{{"client_id", kOpenAIClientId}, {"grant_type", "refresh_token"},
                                             {"refresh_token", credentials.refreshToken},
                                             {"scope", "openid profile email"}})
                       .toJson(QJsonDocument::Compact);
    const HttpResponse response = http(request);
    if (response.status == 400 || response.status == 401 || response.status == 403) {
        result.rejected = true;
        return result;
    }
    const QJsonObject json = object(response.body);
    if (response.status < 200 || response.status > 299 || json.isEmpty()) return result;
    result.credentials = credentials;
    result.credentials.accessToken = json.value("access_token").toString(credentials.accessToken);
    result.credentials.refreshToken = json.value("refresh_token").toString(credentials.refreshToken);
    result.credentials.idToken = json.value("id_token").toString(credentials.idToken);
    result.credentials.accountId = json.value("account_id").toString(credentials.accountId);
    result.ok = true;
    return result;
}

HttpRequest codexUsageRequest(const QString &url, const codexauth::Credentials &credentials) {
    HttpRequest request = get(url);
    request.headers.emplaceBack("Authorization", "Bearer " + credentials.accessToken.toUtf8());
    request.headers.emplaceBack("User-Agent", kUserAgent);
    if (!credentials.accountId.isEmpty()) request.headers.emplaceBack("ChatGPT-Account-Id", credentials.accountId.toUtf8());
    return request;
}

} // namespace

CodexResult fetchCodex(const CodexOptions &options, const Http &http, qint64 nowMs) {
    CodexResult result;
    // Closed right away: Windows cannot replace a file that is still open (the refresh write-back).
    const QByteArray authData = [&] {
        QFile file(options.authPath);
        return file.open(QIODevice::ReadOnly) ? file.readAll() : QByteArray();
    }();
    std::optional<codexauth::Credentials> credentials = codexauth::parseCredentials(authData);
    const QString base = chatgptBaseUrl(options.configPath);
    const QString usageUrl = base.contains("/backend-api") ? base + "/wham/usage" : base + "/api/codex/usage";
    if (credentials) result.authFingerprint = credentials->fingerprint;

    const auto fetchResetCredits = [&](const codexauth::Credentials &c) {
        HttpRequest request = get(base + "/wham/rate-limit-reset-credits", 4000);
        request.headers.emplaceBack("Authorization", "Bearer " + c.accessToken.toUtf8());
        request.headers.emplaceBack("OpenAI-Beta", "codex-1");
        request.headers.emplaceBack("originator", "Codex Desktop");
        request.headers.emplaceBack("User-Agent", kUserAgent);
        if (!c.accountId.isEmpty()) request.headers.emplaceBack("ChatGPT-Account-ID", c.accountId.toUtf8());
        const HttpResponse response = http(request);
        if (response.status >= 200 && response.status <= 299) result.resetCredits = parseResetCredits(response.body);
    };

    // A pasted browser session: only for the fixed chatgpt.com endpoint, and only when it belongs
    // to the same person as the Codex login.
    if (!options.cookieHeader.isEmpty() && !(credentials && credentials->email.isEmpty())) {
        bool sameUser = !credentials;
        if (!sameUser) {
            for (const char *url : {"https://chatgpt.com/backend-api/me", "https://chatgpt.com/api/auth/session"}) {
                HttpRequest probe = get(QString::fromLatin1(url), 8000);
                probe.headers.emplaceBack("Cookie", options.cookieHeader.toUtf8());
                probe.headers.emplaceBack("User-Agent", kUserAgent);
                const HttpResponse response = http(probe);
                const QString email = findEmail(QJsonDocument::fromJson(response.body).object());
                if (!email.isEmpty()) {
                    sameUser = email.compare(credentials->email, Qt::CaseInsensitive) == 0;
                    break;
                }
            }
        }
        if (sameUser) {
            HttpRequest request = get(QStringLiteral("https://chatgpt.com/backend-api/wham/usage"));
            request.headers.emplaceBack("Cookie", options.cookieHeader.toUtf8());
            request.headers.emplaceBack("User-Agent", kUserAgent);
            if (credentials && !credentials->accountId.isEmpty())
                request.headers.emplaceBack("ChatGPT-Account-Id", credentials->accountId.toUtf8());
            const HttpResponse response = http(request);
            if (response.status >= 200 && response.status <= 299) {
                if (auto usage = parseCodexUsage(response.body)) {
                    result.ok = true;
                    result.usage = *usage;
                    result.source = QStringLiteral("Cookie");
                    if (credentials && !credentials->apiKey) fetchResetCredits(*credentials);
                    return result;
                }
            }
        }
    }

    if (!credentials) {
        result.error = QStringLiteral("noCredentials");
        return result;
    }
    if (credentials->apiKey) {
        result.error = QStringLiteral("apiKey");
        return result;
    }

    bool refreshed = false;
    const auto refresh = [&]() -> bool {
        const Refreshed r = refreshToken(*credentials, http);
        if (r.rejected) {
            result.error = QStringLiteral("refreshRejected");
            return false;
        }
        if (!r.ok) return true; // keep the current token
        const QByteArray data = codexauth::refreshedAuthData(credentials->fileData, r.credentials, nowMs);
        if (options.persistRefreshed) options.persistRefreshed(credentials->fingerprint, data);
        QString error;
        if (!codexauth::replaceIfUnchanged(options.authPath, credentials->fingerprint, data, &error)) {
            result.error = QStringLiteral("credentialsChanged");
            return false;
        }
        credentials = codexauth::parseCredentials(data);
        result.authFingerprint = credentials->fingerprint;
        refreshed = true;
        return true;
    };
    if ((!credentials->lastRefreshMs || nowMs - *credentials->lastRefreshMs > kRefreshAgeMs) && !refresh())
        return result;

    HttpResponse response = http(codexUsageRequest(usageUrl, *credentials));
    if ((response.status == 401 || response.status == 403) && !refreshed) {
        if (!refresh()) return result;
        response = http(codexUsageRequest(usageUrl, *credentials));
    }
    if (response.status == 401 || response.status == 403) {
        result.error = QStringLiteral("unauthorized");
        return result;
    }
    if (response.status == 0) {
        result.error = QStringLiteral("network");
        return result;
    }
    if (response.status < 200 || response.status > 299) {
        result.error = QStringLiteral("server %1").arg(response.status);
        return result;
    }
    const auto usage = parseCodexUsage(response.body);
    if (!usage) {
        result.error = QStringLiteral("noRateLimits");
        return result;
    }
    result.ok = true;
    result.usage = *usage;
    result.source = QStringLiteral("OAuth");
    fetchResetCredits(*credentials);
    return result;
}

// --- Claude ----------------------------------------------------------------------------------

QString sanitizeClaudeSessionKey(const QString &pasted) {
    QString text = pasted.trimmed();
    if (text.isEmpty() || text.size() > 16 * 1024 || text.contains('\r') || text.contains('\n')) return QString();
    static const QRegularExpression inHeader("(?:^|[;\\s])sessionKey=([^;\\s]+)");
    if (const auto m = inHeader.match(text); m.hasMatch()) text = m.captured(1);
    else if (text.startsWith("cookie:", Qt::CaseInsensitive)) return QString();
    static const QRegularExpression token("^[\\x21\\x23-\\x2B\\x2D-\\x3A\\x3C-\\x5B\\x5D-\\x7E]+$");
    if (!token.match(text).hasMatch()) return QString();
    return "sessionKey=" + text;
}

std::optional<ClaudeCredentials> readClaudeCredentials(const QString &home, const QString &configDirEnv) {
    const QString dir = configDirEnv.trimmed().isEmpty() ? home + "/.claude" : configDirEnv.trimmed();
    QFile file(dir + "/.credentials.json");
    if (!file.open(QIODevice::ReadOnly)) return std::nullopt;
    const QJsonObject oauth = object(file.readAll()).value("claudeAiOauth").toObject();
    ClaudeCredentials c;
    c.accessToken = oauth.value("accessToken").toString().trimmed();
    if (c.accessToken.isEmpty()) return std::nullopt;
    if (oauth.value("expiresAt").isDouble()) c.expiresAtMs = qint64(oauth.value("expiresAt").toDouble());
    c.subscriptionType = oauth.value("subscriptionType").toString();
    c.identity = QString::fromLatin1(QCryptographicHash::hash(c.accessToken.toUtf8(), QCryptographicHash::Sha256).toHex());
    return c;
}

std::optional<ClaudeUsage> parseClaudeUsage(const QByteArray &json, bool allowEmpty) {
    const QJsonObject root = object(json);
    if (root.isEmpty()) return std::nullopt;
    ClaudeUsage usage;
    static const QList<QPair<QString, QString>> keys = {
        {"five_hour", "5 小时 / 5 hours"}, {"seven_day", "7 天 / 7 days"},
        {"seven_day_opus", "Opus · 7 天 / Opus · 7 days"}, {"seven_day_sonnet", "Sonnet · 7 天 / Sonnet · 7 days"},
        {"seven_day_oauth_apps", "OAuth Apps · 7 天 / OAuth Apps · 7 days"}};
    for (const auto &[key, title] : keys) {
        const QJsonObject row = root.value(key).toObject();
        const auto used = number(row.value("utilization"));
        if (!used || *used < 0 || *used > 100) continue;
        usage.windows.append({key, title, *used, isoMs(row.value("resets_at")), std::nullopt});
    }
    QSet<QString> seen;
    static const QRegularExpression nonWord("[^\\p{L}\\p{N}]+");
    for (const QJsonValue &entry : root.value("limits").toArray()) {
        const QJsonObject limit = entry.toObject();
        if (limit.value("is_active") == QJsonValue(false) || limit.value("kind").toString() != "weekly_scoped"
            || limit.value("group").toString() != "weekly")
            continue;
        const QJsonObject model = limit.value("scope").toObject().value("model").toObject();
        const QString title = model.value("display_name").toString().trimmed();
        const QString rawId = model.value("id").toString().trimmed();
        const QString id = (rawId.isEmpty() ? title : rawId).toLower().split(nonWord, Qt::SkipEmptyParts).join('-');
        const QString name = title.toLower().split(nonWord, Qt::SkipEmptyParts).join('-');
        const auto percent = number(limit.value("percent"));
        if (title.isEmpty() || id.isEmpty() || name == "all-models" || id.endsWith("all-models") || !percent
            || *percent < 0 || *percent > 100 || seen.contains(id))
            continue;
        seen.insert(id);
        usage.windows.append({"scoped-" + id, title + " · 7 天 / " + title + " · 7 days", *percent,
                              isoMs(limit.value("resets_at")), std::nullopt});
    }
    for (const char *key : {"seven_day_routines", "seven_day_claude_routines", "claude_routines", "routines", "routine",
                            "seven_day_cowork", "cowork"}) {
        const QJsonObject row = root.value(QLatin1String(key)).toObject();
        if (row.isEmpty()) continue;
        if (const auto used = number(row.value("utilization")); used && *used <= 100)
            usage.windows.append({"claude-routines", "日常任务 / Daily Routines", *used, isoMs(row.value("resets_at")),
                                  std::nullopt});
        break;
    }
    const QJsonObject extra = root.value("extra_usage").toObject();
    if (extra.value("is_enabled").toBool()) {
        if (const auto used = number(extra.value("used_credits")); used && *used >= 0) usage.extraUsed = *used / 100;
        if (const auto limit = number(extra.value("monthly_limit")); limit && *limit >= 0) usage.extraLimit = *limit / 100;
    }
    const QString currency = extra.value("currency").toString().trimmed().toUpper();
    if (!currency.isEmpty()) usage.extraCurrency = currency;
    const QJsonObject cloud = root.value("iguana_necktie").toObject();
    usage.cloudLimit = number(cloud.value("limit_dollars"));
    usage.cloudUsed = number(cloud.value("used_dollars"));
    usage.cloudRemaining = number(cloud.value("remaining_dollars"));
    const QJsonObject grants = root.value("cedar_ember").toObject();
    if (grants.value("eligible").toBool()) {
        int left = 0;
        for (const QJsonValue &grant : grants.value("grants").toArray()) left += grant.toObject().value("resets_left").toInt();
        usage.resetsLeft = left;
    }
    if (!allowEmpty && usage.windows.isEmpty() && !usage.extraLimit && !usage.cloudLimit) return std::nullopt;
    return usage;
}

namespace {

ClaudeResult statusError(const HttpResponse &response, qint64 nowMs) {
    ClaudeResult result;
    if (response.status == 0) result.error = QStringLiteral("network");
    else if (response.status == 401) result.error = QStringLiteral("loginRequired");
    else if (response.status == 403 && (response.body.contains("cloudflare") || response.headers.contains("cf-mitigated")))
        result.error = QStringLiteral("challenge");
    else if (response.status == 403) result.error = QStringLiteral("unauthorized");
    else if (response.status == 429) {
        result.error = QStringLiteral("rateLimited");
        bool ok = false;
        qint64 seconds = response.headers.value("retry-after").trimmed().toLongLong(&ok);
        if (!ok) seconds = 300;
        result.retryAfterMs = nowMs + std::clamp<qint64>(seconds, 60, 24 * 3600) * 1000;
    } else {
        result.error = QStringLiteral("server %1").arg(response.status);
    }
    return result;
}

} // namespace

ClaudeResult fetchClaudeOAuth(const ClaudeCredentials &credentials, const QString &cliVersion, const Http &http,
                              qint64 nowMs) {
    if (credentials.expiresAtMs && *credentials.expiresAtMs <= nowMs) {
        ClaudeResult result;
        result.error = QStringLiteral("loginRequired");
        return result;
    }
    const QString version = cliVersion.isEmpty() ? QStringLiteral("2.1.0") : cliVersion;
    const auto request = [&](const QString &url, const QString &userAgent, int timeoutMs) {
        HttpRequest r = get(url, timeoutMs);
        r.headers.emplaceBack("Authorization", "Bearer " + credentials.accessToken.toUtf8());
        r.headers.emplaceBack("anthropic-beta", "oauth-2025-04-20");
        r.headers.emplaceBack("Content-Type", "application/json");
        r.headers.emplaceBack("User-Agent", userAgent.toUtf8());
        return r;
    };
    HttpResponse response = http(request(QStringLiteral("https://api.anthropic.com/api/oauth/usage?cedar_ember=1"),
                                         "claude-cli/" + version + " (external, cli)", 30'000));
    if (response.status == 400 || response.status == 404 || response.status == 422
        || (response.status == 403 && !response.body.contains("user:profile")))
        response = http(request(QStringLiteral("https://api.anthropic.com/api/oauth/usage"), "claude-code/" + version, 30'000));
    if (response.status < 200 || response.status > 299) return statusError(response, nowMs);
    const auto usage = parseClaudeUsage(response.body);
    ClaudeResult result;
    if (!usage) {
        result.error = QStringLiteral("invalidResponse");
        return result;
    }
    result.ok = true;
    result.usage = *usage;
    result.usage.plan = credentials.subscriptionType;
    result.usage.source = QStringLiteral("Claude Code OAuth");
    const HttpResponse profile = http(request(QStringLiteral("https://api.anthropic.com/api/oauth/profile"),
                                              "claude-cli/" + version + " (external, cli)", 2000));
    if (profile.status >= 200 && profile.status <= 299) {
        const QJsonObject root = object(profile.body);
        const QJsonObject account = root.value("account").toObject();
        for (const char *key : {"email", "email_address", "emailAddress"}) {
            const QString email = account.value(QLatin1String(key)).toString();
            if (!email.isEmpty()) {
                result.usage.email = email;
                break;
            }
        }
        result.usage.organization = root.value("organization").toObject().value("name").toString();
    }
    return result;
}

ClaudeResult fetchClaudeWeb(const QString &sessionKey, const QString &organization, const Http &http) {
    const auto request = [&](const QString &path, int timeoutMs) {
        HttpRequest r = get("https://claude.ai/api/" + path, timeoutMs);
        r.headers.emplaceBack("Cookie", sessionKey.toUtf8());
        r.headers.emplaceBack("User-Agent", kUserAgent);
        return r;
    };
    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    const HttpResponse orgs = http(request(QStringLiteral("organizations"), 30'000));
    if (orgs.status < 200 || orgs.status > 299) return statusError(orgs, now);
    const QJsonArray list = QJsonDocument::fromJson(orgs.body).array();
    QString uuid, name;
    QStringList choices;
    for (const QJsonValue &value : list) {
        const QJsonObject o = value.toObject();
        choices.append(o.value("uuid").toString() + '\t' + o.value("name").toString());
        if (o.value("uuid").toString() == organization) {
            uuid = organization;
            name = o.value("name").toString();
        }
    }
    if (uuid.isEmpty() && list.size() == 1) {
        uuid = list.first().toObject().value("uuid").toString();
        name = list.first().toObject().value("name").toString();
    }
    ClaudeResult result;
    if (uuid.isEmpty()) {
        result.error = list.isEmpty() ? QStringLiteral("invalidResponse") : QStringLiteral("chooseOrganization");
        result.organizations = choices;
        return result;
    }
    HttpResponse usageResponse = http(request("organizations/" + uuid + "/usage?cedar_ember=1", 30'000));
    if (usageResponse.status == 400 || usageResponse.status == 404 || usageResponse.status == 422)
        usageResponse = http(request("organizations/" + uuid + "/usage", 30'000));
    if (usageResponse.status < 200 || usageResponse.status > 299) return statusError(usageResponse, now);
    const auto usage = parseClaudeUsage(usageResponse.body, true);
    if (!usage) {
        result.error = QStringLiteral("invalidResponse");
        return result;
    }
    result.ok = true;
    result.usage = *usage;
    result.usage.organization = name;
    result.usage.source = QStringLiteral("claude.ai");
    // Optional extras, 2 s each.
    const QJsonObject account = object(http(request(QStringLiteral("account"), 2000)).body);
    result.usage.email = account.value("email_address").toString(account.value("email").toString());
    const QJsonObject overage = object(http(request("organizations/" + uuid + "/overage_spend_limit", 2000)).body);
    if (overage.value("is_enabled").toBool()) {
        if (const auto used = number(overage.value("used_credits"))) result.usage.extraUsed = *used / 100;
        if (const auto limit = number(overage.value("monthly_credit_limit"))) result.usage.extraLimit = *limit / 100;
        if (!overage.value("currency").toString().isEmpty()) result.usage.extraCurrency = overage.value("currency").toString().toUpper();
    }
    const QJsonObject prepaid = object(http(request("organizations/" + uuid + "/prepaid/credits", 2000)).body);
    if (const auto amount = number(prepaid.value("amount"))) {
        result.usage.prepaidBalance = *amount / 100;
        if (!prepaid.value("currency").toString().isEmpty()) result.usage.prepaidCurrency = prepaid.value("currency").toString().toUpper();
    }
    const QJsonObject subscription = object(http(request("organizations/" + uuid + "/subscription_details", 2000)).body);
    for (const char *key : {"next_charge_at", "next_charge_date", "plan_ending_at", "current_period_end"}) {
        if (const auto at = isoMs(subscription.value(QLatin1String(key)))) {
            result.usage.renewsAtMs = at;
            break;
        }
    }
    return result;
}

} // namespace asb::quota

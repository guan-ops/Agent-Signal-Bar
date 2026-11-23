// Account quota, ported from CodexRateLimitFetcher.swift and ClaudeUsageService /
// ClaudeWebUsageService. Requests go only to the fixed provider endpoints below, with no
// redirects followed and no cookies stored; nothing here runs on the GUI thread.
//
// Codex: GET {chatgpt_base_url or https://chatgpt.com/backend-api}/wham/usage with the OAuth
// token from auth.json (Bearer, ChatGPT-Account-Id). The token is refreshed at
// auth.openai.com/oauth/token when last_refresh is missing or older than 8 days, or after a
// 401/403, and written back to auth.json only if the file still holds the bytes it was read with
// (the saved account copy is updated too). Limit reset credits come from
// .../wham/rate-limit-reset-credits. A pasted chatgpt.com Cookie header (off by default) is tried
// first, but only when its /backend-api/me email matches the login's email; any cookie failure
// falls back to OAuth.
//
// Claude: GET https://api.anthropic.com/api/oauth/usage with the Claude Code OAuth token from
// .credentials.json, read-only (never refreshed or written), and /api/oauth/profile for the
// email. Or claude.ai with a pasted sessionKey cookie: organizations, usage, overage, prepaid
// credits and subscription details. A 429 pauses requests for its Retry-After (60 s to 24 h).
#pragma once

#include <QByteArray>
#include <QHash>
#include <QList>
#include <QPair>
#include <QString>
#include <QStringList>
#include <QUrl>
#include <functional>
#include <optional>

namespace asb::quota {

struct HttpRequest {
    QByteArray method = "GET";
    QUrl url;
    QList<QPair<QByteArray, QByteArray>> headers;
    QByteArray body;
    int timeoutMs = 30'000;
};
struct HttpResponse {
    int status = 0; // 0: no response (network error, timeout)
    QByteArray body;
    QHash<QByteArray, QByteArray> headers; // lower-case names
};
using Http = std::function<HttpResponse(const HttpRequest &)>;
// QNetworkAccessManager in a local event loop: call it from a worker thread.
HttpResponse blockingHttp(const HttpRequest &request);

struct Window {
    QString id;    // Codex: primary / secondary; Claude: five_hour, seven_day, ...
    QString title; // Claude: "中文 / English"; Codex: from the duration
    double usedPercent = 0;
    std::optional<qint64> resetsAtMs;
    std::optional<int> minutes;
};

struct Credit {
    QString title; // "Monthly credit limit" or "Credits"
    std::optional<double> used, limit, remaining, remainingPercent, balance;
    std::optional<qint64> resetsAtMs;
};

struct ResetCredit {
    QString status;
    std::optional<qint64> expiresAtMs;
};
struct ResetCredits {
    int availableCount = 0;
    QList<ResetCredit> credits;
};
// Available, unexpired credits, soonest expiry first (no expiry last).
QList<ResetCredit> availableResetCredits(const ResetCredits &credits, qint64 nowMs);

struct CodexUsage {
    QString plan, limitId, limitName;
    std::optional<Window> primary, secondary;
    std::optional<Credit> credits;
};
// CodexUsageResponse + usageStatus: nullopt when it has neither windows nor credits.
std::optional<CodexUsage> parseCodexUsage(const QByteArray &json);
std::optional<ResetCredits> parseResetCredits(const QByteArray &json);

struct CodexOptions {
    QString authPath;   // ...\.codex\auth.json
    QString configPath; // ...\.codex\config.toml (chatgpt_base_url)
    QString cookieHeader; // pasted Cookie header, empty = cookies off
    std::function<void(const QString &oldFingerprint, const QByteArray &data)> persistRefreshed;
};
struct CodexResult {
    bool ok = false;
    // noCredentials, apiKey, unauthorized, refreshRejected, credentialsChanged, noRateLimits,
    // network, server <code>
    QString error;
    CodexUsage usage;
    std::optional<ResetCredits> resetCredits;
    QString source; // OAuth | Cookie
    QString authFingerprint;
};
CodexResult fetchCodex(const CodexOptions &options, const Http &http, qint64 nowMs);

// Reduces a pasted header, curl command (-H 'Cookie: ...', -b/--cookie) or "cookie:" line to the
// cookie list; "" when it holds line breaks or nothing usable.
QString sanitizeCookieHeader(const QString &pasted);
// "sessionKey=<value>" from a pasted header or bare value; "" when invalid (16 KB at most).
QString sanitizeClaudeSessionKey(const QString &pasted);

struct ClaudeCredentials {
    QString accessToken;
    std::optional<qint64> expiresAtMs;
    QString subscriptionType;
    QString identity; // SHA-256 of the token
};
// CLAUDE_CONFIG_DIR/.credentials.json, else <home>/.claude/.credentials.json.
std::optional<ClaudeCredentials> readClaudeCredentials(const QString &home, const QString &configDirEnv);

struct ClaudeUsage {
    QList<Window> windows;
    std::optional<double> extraUsed, extraLimit; // monthly extra usage budget (cents / 100)
    QString extraCurrency = QStringLiteral("USD");
    std::optional<double> prepaidBalance;
    QString prepaidCurrency = QStringLiteral("USD");
    std::optional<double> cloudLimit, cloudUsed, cloudRemaining; // iguana_necktie, USD
    std::optional<int> resetsLeft;                               // cedar_ember grants
    std::optional<qint64> renewsAtMs;                            // subscription_details
    QString email, organization, plan, source;
};
std::optional<ClaudeUsage> parseClaudeUsage(const QByteArray &json, bool allowEmpty = false);

struct ClaudeResult {
    bool ok = false;
    // loginRequired, unauthorized, rateLimited, challenge, network, invalidResponse,
    // chooseOrganization, server <code>
    QString error;
    qint64 retryAfterMs = 0;
    ClaudeUsage usage;
    QStringList organizations; // web: "uuid\tname", when one must be chosen
};
ClaudeResult fetchClaudeOAuth(const ClaudeCredentials &credentials, const QString &cliVersion, const Http &http,
                              qint64 nowMs);
ClaudeResult fetchClaudeWeb(const QString &sessionKey, const QString &organization, const Http &http);

} // namespace asb::quota

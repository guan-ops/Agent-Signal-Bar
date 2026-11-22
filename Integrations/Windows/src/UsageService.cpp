#include "UsageService.h"

#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QPointer>
#include <QSaveFile>
#include <QThreadPool>
#include <algorithm>
#include <cmath>

namespace {

constexpr int kHistoryDays = 30;
constexpr qint64 kActiveIntervalMs = 60'000;   // tokenActivityRefreshInterval
constexpr qint64 kIdleIntervalMs = 300'000;    // tokenActivityIdleRefreshInterval
constexpr qint64 kCatalogTtlMs = 24 * 3600'000; // ModelsDevCache.ttlSeconds
constexpr qint64 kRetryMs = 3600'000;
constexpr qint64 kCatalogMaxBytes = 32 * 1024 * 1024;
constexpr qint64 kRatesMaxBytes = 128 * 1024;

qint64 nowMs() { return QDateTime::currentMSecsSinceEpoch(); }

bool writeAtomically(const QString &path, const QByteArray &data) {
    QDir().mkpath(QFileInfo(path).absolutePath());
    QSaveFile file(path);
    return file.open(QIODevice::WriteOnly) && file.write(data) == data.size() && file.commit();
}

QByteArray readFile(const QString &path, qint64 maxBytes) {
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly) || file.size() > maxBytes) return QByteArray();
    return file.readAll();
}

} // namespace

UsageService::UsageService(QObject *parent) : QObject(parent) {
    connect(&m_timer, &QTimer::timeout, this, &UsageService::tick);
}

UsageService::~UsageService() = default;

void UsageService::start(const QStringList &codexRoots, const QStringList &claudeRoots, const QString &cacheDir,
                         bool network) {
    m_codexScanner = std::make_shared<asb::usage::CodexScanner>(codexRoots);
    m_claudeScanner = std::make_shared<asb::usage::ClaudeScanner>(claudeRoots);
    m_cacheDir = cacheDir;
    if (network) m_network = new QNetworkAccessManager(this);
    m_started = true;
    loadCatalog();
    loadRates();
    m_timer.start(15'000);
    QTimer::singleShot(0, this, &UsageService::tick);
}

void UsageService::setCodexRoots(const QStringList &roots) {
    if (!m_started) return;
    m_codexScanner = std::make_shared<asb::usage::CodexScanner>(roots);
    requestScan();
}

void UsageService::setPaused(bool paused) {
    m_paused = paused;
    if (!paused) tick();
}

void UsageService::setCurrency(const QString &code) {
    m_currency = code.trimmed().toUpper();
    if (m_started) tick();
    emit changed();
}

void UsageService::requestScan() {
    if (!m_started || m_paused) return;
    if (m_scanning) {
        m_rescanPending = true;
        return;
    }
    startScan();
}

void UsageService::tick() {
    if (!m_started) return;
    const qint64 now = nowMs();
    if (m_network) {
        if ((m_catalogFetchedAtMs == 0 || now - m_catalogFetchedAtMs > kCatalogTtlMs)
            && now - m_lastCatalogAttemptMs > kRetryMs)
            fetchCatalog();
        if (m_currency != "USD" && (m_rates.isEmpty() || now >= m_ratesNextUpdateMs) && now - m_lastRatesAttemptMs > kRetryMs)
            fetchRates();
    }
    if (m_paused || m_scanning) return;
    qint64 interval = m_activity ? kActiveIntervalMs : kIdleIntervalMs;
    if (m_lowPower) interval *= 2;
    if (m_completedAtMs == 0 || now - m_lastScanMs >= interval) startScan();
}

void UsageService::startScan() {
    m_scanning = true;
    m_activity = false;
    m_lastScanMs = nowMs();
    emit changed();
    QPointer<UsageService> self(this);
    auto codex = m_codexScanner;
    auto claude = m_claudeScanner;
    auto catalog = m_catalog;
    const qint64 now = m_lastScanMs;
    QThreadPool::globalInstance()->start([self, codex, claude, catalog, now] {
        const asb::usage::Report codexReport = codex->scan(now, kHistoryDays, catalog.get());
        const asb::usage::Report claudeReport = claude->scan(now, kHistoryDays, catalog.get());
        QMetaObject::invokeMethod(self.data(), [self, codexReport, claudeReport] {
            if (!self) return;
            self->m_codex = codexReport;
            self->m_claude = claudeReport;
            self->m_scanning = false;
            self->m_completedAtMs = nowMs();
            emit self->changed();
            if (self->m_rescanPending) {
                self->m_rescanPending = false;
                self->requestScan();
            }
        }, Qt::QueuedConnection);
    });
}

std::pair<double, QString> UsageService::rate(const QString &code) const {
    const QString wanted = code.trimmed().toUpper();
    if (wanted != "USD" && m_rates.contains(wanted)) return {m_rates.value(wanted), wanted};
    return {1.0, QStringLiteral("USD")};
}

// --- models.dev ------------------------------------------------------------------------------

void UsageService::loadCatalog() {
    const QString path = m_cacheDir + "/models-dev.json";
    const QByteArray data = readFile(path, kCatalogMaxBytes);
    if (data.isEmpty()) return;
    if (auto catalog = asb::usage::ModelsDevCatalog::fromJson(data); catalog && catalog->isPlausible()) {
        m_catalog = std::make_shared<const asb::usage::ModelsDevCatalog>(std::move(*catalog));
        m_catalogFetchedAtMs = QFileInfo(path).lastModified().toMSecsSinceEpoch();
    }
}

void UsageService::fetchCatalog() {
    m_lastCatalogAttemptMs = nowMs();
    QNetworkRequest request(QUrl(QStringLiteral("https://models.dev/api.json")));
    request.setTransferTimeout(20'000);
    QNetworkReply *reply = m_network->get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply] {
        reply->deleteLater();
        if (reply->error() != QNetworkReply::NoError
            || reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt() != 200)
            return;
        const QByteArray data = reply->read(kCatalogMaxBytes + 1);
        if (data.size() > kCatalogMaxBytes) return;
        auto catalog = asb::usage::ModelsDevCatalog::fromJson(data);
        // An empty or partial response must not replace a good cache.
        if (!catalog || !catalog->isPlausible()) return;
        writeAtomically(m_cacheDir + "/models-dev.json", data);
        m_catalog = std::make_shared<const asb::usage::ModelsDevCatalog>(std::move(*catalog));
        m_catalogFetchedAtMs = nowMs();
        requestScan(); // re-price with the new catalog
    });
}

// --- Exchange rates --------------------------------------------------------------------------

bool UsageService::parseRates(const QByteArray &json, qint64 now, QHash<QString, double> *rates, qint64 *updatedAtMs,
                              qint64 *nextUpdateAtMs) {
    if (json.size() > kRatesMaxBytes) return false;
    const QJsonObject root = QJsonDocument::fromJson(json).object();
    if (root.value("result").toString() != "success" || root.value("base_code").toString() != "USD") return false;
    const qint64 updated = qint64(root.value("time_last_update_unix").toDouble() * 1000);
    const qint64 next = qint64(root.value("time_next_update_unix").toDouble() * 1000);
    const QJsonObject values = root.value("rates").toObject();
    QHash<QString, double> parsed;
    for (auto it = values.constBegin(); it != values.constEnd(); ++it) {
        const QString code = it.key();
        const double value = it.value().toDouble();
        const bool upper = code.size() == 3 && std::all_of(code.cbegin(), code.cend(), [](QChar c) {
            return c >= 'A' && c <= 'Z';
        });
        if (!upper || !std::isfinite(value) || value <= 0) return false;
        parsed.insert(code, value);
    }
    // CurrencyRateSnapshot.isValid
    if (updated <= 0 || updated > now + 300'000 || next <= updated || next - updated > 172'800'000
        || parsed.value("USD") != 1.0 || parsed.size() < 2)
        return false;
    *rates = parsed;
    *updatedAtMs = updated;
    *nextUpdateAtMs = next;
    return true;
}

void UsageService::loadRates() {
    const QByteArray data = readFile(m_cacheDir + "/currency-rates.json", kRatesMaxBytes);
    QHash<QString, double> rates;
    qint64 updated = 0, next = 0;
    if (!data.isEmpty() && parseRates(data, nowMs(), &rates, &updated, &next)) {
        m_rates = rates;
        m_ratesUpdatedAtMs = updated;
        m_ratesNextUpdateMs = next;
    }
}

void UsageService::fetchRates() {
    m_lastRatesAttemptMs = nowMs();
    QNetworkRequest request(QUrl(QStringLiteral("https://open.er-api.com/v6/latest/USD")));
    request.setTransferTimeout(20'000);
    QNetworkReply *reply = m_network->get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply] {
        reply->deleteLater();
        if (reply->error() != QNetworkReply::NoError
            || reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt() != 200)
            return;
        const QByteArray data = reply->read(kRatesMaxBytes + 1);
        QHash<QString, double> rates;
        qint64 updated = 0, next = 0;
        if (!parseRates(data, nowMs(), &rates, &updated, &next)) return;
        writeAtomically(m_cacheDir + "/currency-rates.json", data);
        m_rates = rates;
        m_ratesUpdatedAtMs = updated;
        m_ratesNextUpdateMs = next;
        emit changed();
    });
}
